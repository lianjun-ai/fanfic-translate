import { picker } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { Chapter, ParaStatus, ParaType, Paragraph, Work, parseRuns, runsToPlainText } from '../model/Models';
import { ChapterDao } from '../data/ChapterDao';
import { ParagraphDao } from '../data/ParagraphDao';
import { FicHub } from '../fetch/FicHub';
import { HtmlFrag } from './HtmlFrag';
import { ChapterData, Epub } from './Epub';

/** 导出格式 */
export class ExportFormat {
  static readonly TXT: string = 'txt';
  static readonly HTML: string = 'html';
  static readonly EPUB: string = 'epub';
}

/** 导出内容：纯译文 / 双语对照 */
export class ExportContent {
  static readonly TRANSLATION: string = 'translation';
  static readonly BILINGUAL: string = 'bilingual';
}

/** 导出范围：全书 / 单章 */
export class ExportScope {
  static readonly BOOK: string = 'book';
  static readonly CHAPTER: string = 'chapter';
}

export interface ExportResult {
  /** 文本格式（TXT / HTML）的完整内容；二进制格式时为空串 */
  body: string;
  /** 二进制格式（EPUB）的字节流；文本格式时为 null */
  bytes: Uint8Array | null;
  /** 建议的文件名（已做过文件名安全化） */
  fileName: string;
  mime: string;
}

/**
 * 排版导出：把书库里的作品组装成 TXT / HTML / EPUB。
 *
 * 数据基础是 M1 定下的 Run[] 段落模型 —— 原文与译文都是片段数组，
 * 斜体/加粗/下划线/删除线的样式位直接映射成 HTML 标签，不需要任何新解析。
 * TXT 是纯文本，样式位丢弃（文本内容完整）。
 *
 * 译文缺失的段落按阅读器「纯译文模式」的同一策略处理：用原文顶上，
 * 保证导出内容没有空洞。
 *
 * 三种格式只在「组装」这一步分叉，取数（章节 + 段落）只做一遍。
 */
export class Exporter {

  /**
   * 组装导出内容。
   *
   * @param scope CHAPTER 时只导 chapterId 对应一章，BOOK 导整本
   */
  static async build(work: Work, scope: string, chapterId: string,
    content: string, format: string): Promise<ExportResult> {

    let chapters: Chapter[] = [];
    if (scope === ExportScope.CHAPTER) {
      const c = await ChapterDao.find(chapterId);
      if (c !== null) {
        chapters.push(c);
      }
    } else {
      chapters = await ChapterDao.listByWork(work.id);
    }
    if (chapters.length === 0) {
      throw new Error('没有可导出的章节');
    }

    // 取数只做一遍：三种格式共用这份数据
    const data: ChapterData[] = [];
    for (let i = 0; i < chapters.length; i++) {
      data.push({ chapter: chapters[i], paras: await ParagraphDao.listByChapter(chapters[i].id) });
    }

    const bilingual = content === ExportContent.BILINGUAL;
    const mode = bilingual ? '双语' : '译文';
    const scopeTag = scope === ExportScope.CHAPTER ? '' : `_${chapters.length}章`;
    const baseName = `${FicHub.fileSafeName(work.title) || 'export'}_${mode}${scopeTag}`;

    if (format === ExportFormat.EPUB) {
      return {
        body: '',
        bytes: Epub.build(work, data, bilingual),
        fileName: `${baseName}.epub`,
        mime: 'application/epub+zip'
      };
    }

    if (format === ExportFormat.HTML) {
      const blocks: string[] = [];
      let translatedCount = 0;
      for (let i = 0; i < data.length; i++) {
        for (let p = 0; p < data[i].paras.length; p++) {
          if (data[i].paras[p].status === ParaStatus.DONE) {
            translatedCount++;
          }
        }
        blocks.push(HtmlFrag.chapterHtml(data[i].chapter, data[i].paras, bilingual));
      }
      return {
        body: Exporter.htmlHeader(work, data.length, translatedCount) + blocks.join('\n') + '\n</body>\n</html>\n',
        bytes: null,
        fileName: `${baseName}.html`,
        mime: 'text/html'
      };
    }

    // TXT
    const blocks: string[] = [];
    for (let i = 0; i < data.length; i++) {
      blocks.push(Exporter.chapterTxt(data[i].chapter, data[i].paras, bilingual));
    }
    return {
      body: Exporter.txtHeader(work) + blocks.join('\n\n'),
      bytes: null,
      fileName: `${baseName}.txt`,
      mime: 'text/plain'
    };
  }

  /** 一章的纯文本块：标题 + 段落 + 摘要附注 */
  private static chapterTxt(ch: Chapter, paras: Paragraph[], bilingual: boolean): string {
    const lines: string[] = [];
    lines.push(`\n▍${ch.title}\n`);
    for (let i = 0; i < paras.length; i++) {
      lines.push(Exporter.paraTxt(paras[i], bilingual));
    }
    if (ch.summary.length > 0) {
      lines.push(`〔本章梗概〕${ch.summary}`);
    }
    return lines.join('\n');
  }

  /** 单段 TXT。双语对照：原文行 → 换行 → 译文行 */
  private static paraTxt(p: Paragraph, bilingual: boolean): string {
    if (p.type === ParaType.DIVIDER) {
      return '────────────';
    }
    const src = parseRuns(p.runs);
    const translated = p.status === ParaStatus.DONE && p.translatedRuns.length > 0
      ? parseRuns(p.translatedRuns)
      : null;

    const srcText = runsToPlainText(src);
    if (bilingual && translated !== null && p.type !== ParaType.HEADING) {
      return `${srcText}\n${runsToPlainText(translated)}`;
    }
    if (translated !== null) {
      return runsToPlainText(translated);
    }
    return srcText;
  }

  private static txtHeader(work: Work): string {
    const d = new Date();
    const pad = (n: number): string => n < 10 ? `0${n}` : `${n}`;
    return `${work.title}\n${work.author.length > 0 ? work.author : '佚名'}` +
      `\n由同人译站翻译导出 · ${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}\n`;
  }

  private static htmlHeader(work: Work, chapterTotal: number, translated: number): string {
    const d = new Date();
    const pad = (n: number): string => n < 10 ? `0${n}` : `${n}`;
    return `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>${HtmlFrag.esc(work.title)}</title>
<style>
body { max-width: 44em; margin: 0 auto; padding: 24px 20px 64px;
  font-family: Georgia, 'Songti SC', SimSun, serif; line-height: 1.9; color: #222; }
h1 { font-size: 1.5em; margin: 0 0 4px; }
h2 { font-size: 1.2em; margin: 2.4em 0 0.8em; border-bottom: 1px solid #ddd; padding-bottom: 4px; }
h3 { font-size: 1.05em; margin: 1.6em 0 0.6em; }
p { margin: 0.9em 0; text-align: justify; }
p.src { color: #999; font-size: 0.86em; margin-bottom: 0.1em; }
p.note, .note { color: #8a7f70; font-size: 0.9em; }
blockquote { margin: 1em 0; padding: 2px 14px; border-left: 3px solid #d8d2c6; color: #555; }
hr { border: none; border-top: 1px solid #ddd; margin: 1.8em auto; width: 40%; }
.meta { color: #8a7f70; font-size: 0.9em; margin-bottom: 2em; }
</style>
</head>
<body>
<h1>${HtmlFrag.esc(work.title)}</h1>
<p class="meta">${HtmlFrag.esc(work.author.length > 0 ? work.author : '佚名')} · 由同人译站翻译导出 · ${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}</p>
`;
  }

  /**
   * 落盘：弹系统保存对话框让用户选位置（下载/文档等公共目录）。
   * 写入必须用 picker 返回的 uri 打开 —— 自己拼公共目录路径会被沙箱拒绝。
   * 注意 SDK 里没有独立的 DocumentSavePicker 类，save() 挂在 DocumentViewPicker 上。
   */
  static async save(ctx: common.UIAbilityContext, result: ExportResult): Promise<string> {
    const saveOptions = new picker.DocumentSaveOptions();
    saveOptions.newFileNames = [result.fileName];
    const docPicker = new picker.DocumentViewPicker(ctx);
    const uris: Array<string> = await docPicker.save(saveOptions);
    if (!uris || uris.length === 0) {
      return '';
    }
    const f = fs.openSync(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      if (result.bytes !== null) {
        // 二进制按 ArrayBuffer 写入；这里 slice 出独立缓冲，避免写入超出字节范围
        const ab: ArrayBuffer = result.bytes.buffer.slice(
          result.bytes.byteOffset, result.bytes.byteOffset + result.bytes.byteLength) as ArrayBuffer;
        fs.writeSync(f.fd, ab);
      } else {
        fs.writeSync(f.fd, result.body);
      }
    } finally {
      fs.closeSync(f);
    }
    return uris[0];
  }
}
