import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { EpubParser } from './EpubParser';
import { TxtParser } from './TxtParser';
import { HtmlFileParser } from './HtmlFileParser';
import { FileKind, FileTextReader } from './FileTextReader';
import { ParsedWork } from './ParserTypes';
import { Work } from '../model/Models';
import { WorkDao } from '../data/WorkDao';
import { WorkRepo } from '../data/WorkRepo';
import { Log } from '../common/Logger';

export interface ImportResult {
  workId: string;
  title: string;
  chapters: number;
  paragraphs: number;
  /** > 0 表示本次是替换导入：书架旧版有这么章，已被新版覆盖 */
  replacedFrom: number;
}

/**
 * 外部已知的元信息（如待入库边车里来自站点的标题/作者）。
 * HTML/TXT 文件本身往往不带作者，解析只能猜出「佚名」；
 * 边车里的值比文件解析更权威，查重键也因此更准。
 */
export interface MetaOverride {
  title: string;
  author: string;
}

/** 待导入的一个文件 */
export interface FilePick {
  uri: string;
  name: string;
}

/** 批量导入单条结果 */
export interface BatchOutcome {
  fileName: string;
  /** ok / duplicate / fail */
  status: string;
  title: string;
  detail: string;
  chapters: number;
  paragraphs: number;
  workId: string;
}

export class ImportError extends Error {
  constructor(msg: string) {
    super(msg);
    this.name = 'ImportError';
  }
}

/** 已经在书架里。单独一个类型，UI 才能把它和真失败区分开 */
export class DuplicateError extends Error {
  existingId: string;
  existingTitle: string;
  chapterCount: number;

  constructor(existing: Work) {
    super(`《${existing.title}》已在书架（${existing.chapterCount} 章）`);
    this.name = 'DuplicateError';
    this.existingId = existing.id;
    this.existingTitle = existing.title;
    this.chapterCount = existing.chapterCount;
  }
}

const SUPPORTED: string[] = ['epub', 'txt', 'html', 'htm'];

/**
 * 导入管线：文件选择器给的 uri → 拷到沙箱 → 按格式解析 → 统一作品模型 → 落库。
 * 拷贝是必须的：picker 给的 uri 属于公共目录，只能读，且 epub 解压需要本地路径。
 */
export class Importer {
  static isSupported(fileName: string): boolean {
    return SUPPORTED.indexOf(Importer.extOf(fileName)) >= 0;
  }

  static async importFromUri(ctx: common.UIAbilityContext, uri: string, fileName: string,
    onProgress: (msg: string) => void, allowDuplicate: boolean = false): Promise<ImportResult> {
    // 落盘一律用 .zip 后缀：zlib.decompressFile 的硬性要求是"源文件后缀必须是 .zip"，
    // 否则直接报 900001（源码文件无效）。而扩展名本身并不可信，
    // 真实格式由魔数嗅探决定，所以后缀在这里只是一个让解压器接受的载体。
    // 批量导入时这本书和下一本可能在同一毫秒开始，只靠 Date.now() 会撞名，
    // 撞上就是"解压到了上一个文件的残留目录"。加随机后缀避免。
    const stamp = `${Date.now()}_${Math.floor(Math.random() * 100000)}`;
    const tmpPath = `${ctx.cacheDir}/import_${stamp}.zip`;
    const extractDir = `${ctx.cacheDir}/epub_${stamp}`;

    try {
      onProgress('正在读取文件…');
      Importer.copyToSandbox(uri, tmpPath);
      return await Importer.importLocal(tmpPath, extractDir, fileName, onProgress, allowDuplicate);
    } finally {
      Importer.cleanup(tmpPath, extractDir);
    }
  }

  /**
   * 本地已有文件时走这里（网络下载的 EPUB 等）。
   * 与 importFromUri 共享同一条解析管线，只差入口：uri 拷贝 vs 路径拷贝。
   */
  static async importFromPath(ctx: common.UIAbilityContext, localPath: string, fileName: string,
    onProgress: (msg: string) => void, allowDuplicate: boolean = false,
    metaOverride: MetaOverride | null = null, allowReplace: boolean = false): Promise<ImportResult> {
    const stamp = `${Date.now()}_${Math.floor(Math.random() * 100000)}`;
    const tmpPath = `${ctx.cacheDir}/import_${stamp}.zip`;
    const extractDir = `${ctx.cacheDir}/epub_${stamp}`;

    try {
      onProgress('正在读取文件…');
      fs.copyFileSync(localPath, tmpPath);
      return await Importer.importLocal(tmpPath, extractDir, fileName, onProgress,
        allowDuplicate, metaOverride, allowReplace);
    } finally {
      Importer.cleanup(tmpPath, extractDir);
    }
  }

  /** 管线主体：沙箱内 .zip 临时文件 → 魔数嗅探 → 路由解析 → 查重 → 落库。不负责清理临时文件 */
  private static async importLocal(tmpPath: string, extractDir: string, fileName: string,
    onProgress: (msg: string) => void, allowDuplicate: boolean,
    metaOverride: MetaOverride | null = null, allowReplace: boolean = false): Promise<ImportResult> {
    const ext = Importer.extOf(fileName);

    let size = 0;
    let kind = FileKind.UNKNOWN;

    try {
      // 扩展名不可信：网盘/浏览器下载的文件经常名不副实，按魔数判断真实格式
      size = fs.statSync(tmpPath).size;
      kind = FileTextReader.sniff(tmpPath);
      Log.i(`导入：${fileName} / ${size} 字节 / 扩展名 ${ext} / 实际格式 ${kind}`);

      if (size === 0) {
        throw new ImportError('这个文件是空的（0 字节），可能没有下载完整，请重新下载后再导入');
      }
      if (kind === FileKind.PDF) {
        throw new ImportError('这是 PDF 文件。PDF 已丢失斜体等行内样式，无法保证译文保真，本期不支持；建议改用 EPUB 或 TXT');
      }

      // 路由由"真实内容"决定，扩展名只用于提示。下载来的文件经常名不副实：
      // 叫 .txt 的其实是网页，叫 .epub 的其实是被改名过的 zip。
      let route = '';
      if (kind === FileKind.EPUB) {
        route = 'epub';
      } else if (kind === FileKind.HTML) {
        route = 'html';
      } else if (kind === FileKind.TEXT) {
        route = 'txt';
      }
      if (route.length === 0) {
        throw new ImportError(`无法识别文件内容（${size} 字节，扩展名 .${ext}）。` +
          `当前支持 EPUB / TXT / HTML`);
      }
      if (route !== ext && !(route === 'html' && ext === 'htm')) {
        onProgress(`文件实际是 ${route.toUpperCase()} 格式，按该格式解析…`);
      }

      let parsed: ParsedWork;
      if (route === 'epub') {
        parsed = await EpubParser.parse(tmpPath, extractDir, onProgress);
      } else if (route === 'html') {
        onProgress('正在解析网页…');
        parsed = await HtmlFileParser.parse(tmpPath, fileName);
      } else {
        onProgress('正在解析文本…');
        parsed = await TxtParser.parse(tmpPath, fileName);
      }

      let paragraphCount = 0;
      for (let i = 0; i < parsed.chapters.length; i++) {
        paragraphCount += parsed.chapters[i].paragraphs.length;
      }
      if (paragraphCount === 0) {
        throw new ImportError(`没有解析到正文（${size} 字节，实际格式 ${kind}，` +
          `解析出 ${parsed.chapters.length} 个章节但内容为空）`);
      }

      // 边车等外部来源的标题/作者比文件解析出来的更权威：
      // 不覆盖的话 HTML 抓来的书作者永远是「佚名」，查重键也跟着失准
      if (metaOverride !== null) {
        if (metaOverride.title.length > 0) {
          parsed.title = metaOverride.title;
        }
        if (metaOverride.author.length > 0) {
          parsed.author = metaOverride.author;
        }
      }

      let replacedFrom = 0;
      // 查重要在解析之后：指纹得从正文算，只凭文件名判不准
      if (!allowDuplicate) {
        const dup = await WorkRepo.findDuplicate(parsed);
        if (dup !== null) {
          // 新版章节数严格多于书架旧版 → 视为「连载更新/上次没抓全」，替换旧版。
          // 只允许显式开启（待入库/命中下载流程）：批量导入选文件时保持
          // 原来的「重复即跳过」，不替用户做删除书架数据的决定。
          if (allowReplace && parsed.chapters.length > dup.chapterCount) {
            onProgress(`书架旧版 ${dup.chapterCount} 章，新版 ${parsed.chapters.length} 章，正在替换…`);
            await WorkDao.remove(dup.id);
            replacedFrom = dup.chapterCount;
            Log.i(`替换导入：《${dup.title}》${dup.chapterCount} 章 → ${parsed.chapters.length} 章`);
          } else {
            throw new DuplicateError(dup);
          }
        }
      }

      onProgress('正在写入书架…');
      const workId = await WorkRepo.saveParsed(parsed, '');

      const result: ImportResult = {
        workId: workId,
        title: parsed.title,
        chapters: parsed.chapters.length,
        paragraphs: paragraphCount,
        replacedFrom: replacedFrom
      };
      return result;
    } catch (e) {
      if (e instanceof ImportError || e instanceof DuplicateError) {
        throw e as Error;
      }
      // 任何非预期异常都要带上文件上下文，否则用户只能看到一句无信息量的系统报错
      const raw = (e as Error).message;
      Log.e(`导入异常：${fileName} / ${size} 字节 / ${kind} / ${raw}`);
      throw new ImportError(`${raw}〔文件：${fileName}，${size} 字节，识别为 ${kind}〕`);
    }
  }

  /**
   * 批量导入。一本一本串行处理，单本失败不影响后面的 ——
   * 用户一次选十本，不该因为第三本损坏而让其余九本全部作废。
   */
  static async importBatch(ctx: common.UIAbilityContext, files: FilePick[],
    onProgress: (index: number, total: number, name: string, msg: string) => void,
    allowDuplicate: boolean = false): Promise<BatchOutcome[]> {
    const out: BatchOutcome[] = [];
    for (let i = 0; i < files.length; i++) {
      const f = files[i];
      onProgress(i + 1, files.length, f.name, '准备导入…');
      try {
        const res = await Importer.importFromUri(ctx, f.uri, f.name,
          (msg: string) => {
            onProgress(i + 1, files.length, f.name, msg);
          }, allowDuplicate);
        const ok: BatchOutcome = {
          fileName: f.name,
          status: 'ok',
          title: res.title,
          detail: '',
          chapters: res.chapters,
          paragraphs: res.paragraphs,
          workId: res.workId
        };
        out.push(ok);
      } catch (e) {
        if (e instanceof DuplicateError) {
          const dup: BatchOutcome = {
            fileName: f.name,
            status: 'duplicate',
            title: e.existingTitle,
            detail: `已在书架，本次跳过`,
            chapters: e.chapterCount,
            paragraphs: 0,
            workId: e.existingId
          };
          out.push(dup);
        } else {
          const bad: BatchOutcome = {
            fileName: f.name,
            status: 'fail',
            title: '',
            detail: (e as Error).message,
            chapters: 0,
            paragraphs: 0,
            workId: ''
          };
          out.push(bad);
        }
      }
    }
    return out;
  }

  private static copyToSandbox(uri: string, destPath: string): void {
    const src = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    try {
      fs.copyFileSync(src.fd, destPath);
    } finally {
      fs.closeSync(src);
    }
  }

  private static cleanup(tmpPath: string, extractDir: string): void {
    try {
      if (fs.accessSync(tmpPath)) {
        fs.unlinkSync(tmpPath);
      }
    } catch (e) {
      Log.w('清理临时文件失败');
    }
    try {
      if (fs.accessSync(extractDir)) {
        fs.rmdirSync(extractDir);
      }
    } catch (e) {
      Log.w('清理解压目录失败');
    }
  }

  private static extOf(fileName: string): string {
    const dot = fileName.lastIndexOf('.');
    if (dot < 0) {
      return '';
    }
    return fileName.substring(dot + 1).toLowerCase();
  }
}
