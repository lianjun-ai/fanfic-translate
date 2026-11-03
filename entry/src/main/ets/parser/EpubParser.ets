import { zlib, BusinessError } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { HtmlNode, HtmlParser } from './HtmlParser';
import { XhtmlConverter } from './XhtmlConverter';
import { FileTextReader } from './FileTextReader';
import { ParsedChapter, ParsedParagraph, ParsedWork, emptyWork } from './ParserTypes';
import { SourceType } from '../model/Models';
import { Log } from '../common/Logger';

class ManifestItem {
  id: string = '';
  href: string = '';
  mediaType: string = '';
  properties: string = '';
}

/**
 * EPUB 解析。EPUB 本质是 zip 包着的 XHTML：
 * 解压 → META-INF/container.xml 定位 opf → 读 manifest/spine → 按序解析 XHTML。
 *
 * 现实中不少 epub 是第三方工具重新打包的，spine 路径、大小写、编码都可能不标准。
 * 因此主链路（spine）失败时会退化到"扫描解压目录里所有 xhtml 按路径排序"，
 * 宁可章节顺序不完美，也不让用户看到"没有解析到正文"。
 */
export class EpubParser {
  private static fileCount: number = 0;

  static async parse(epubPath: string, extractDir: string,
    onProgress?: (msg: string) => void): Promise<ParsedWork> {
    EpubParser.prepareDir(extractDir);
    EpubParser.report(onProgress, '正在解压 EPUB…');

    // zlib.decompressFile 只接受 .zip 后缀。这里做最后一道保险：
    // 如果调用方给的不是 .zip（例如历史路径），就复制一份 .zip 再解压，
    // 避免直接以 900001 失败、而用户只看到"没有解析到正文"。
    let zipPath = epubPath;
    let zipTemp = '';
    if (!epubPath.toLowerCase().endsWith('.zip')) {
      zipTemp = `${epubPath}.zip`;
      try {
        fs.copyFileSync(epubPath, zipTemp);
        zipPath = zipTemp;
      } catch (e) {
        Log.w(`准备 .zip 副本失败，直接尝试解压原路径: ${(e as Error).message}`);
      }
    }

    try {
      await zlib.decompressFile(zipPath, extractDir);
    } catch (e) {
      const err = e as BusinessError;
      throw new Error(`EPUB 解压失败（错误码 ${err.code}：${err.message}）。` +
        `常见原因：文件未下载完整、不是真正的 ZIP 容器，或后缀不是 .zip`);
    } finally {
      if (zipTemp.length > 0) {
        try {
          fs.unlinkSync(zipTemp);
        } catch (e) {
          Log.w('清理 zip 副本失败');
        }
      }
    }

    // 解压后必须真的有文件落盘，否则后续所有"文件找不到"都是假象
    const unpacked = EpubParser.countFiles(extractDir);
    Log.i(`EPUB 解压完成：${unpacked} 个文件 → ${extractDir}`);
    if (unpacked === 0) {
      throw new Error('EPUB 解压后没有任何文件，文件可能已损坏或加密（DRM 保护的电子书无法解析）');
    }

    const work = emptyWork();
    work.sourceType = SourceType.EPUB;

    const containerPath = `${extractDir}/META-INF/container.xml`;
    if (!fs.accessSync(containerPath)) {
      // 没有 container.xml：可能不是标准 epub（例如改名的普通 zip），直接扫页面
      EpubParser.fillMetaFromAnyOpf(extractDir, work);
      const scanned = EpubParser.scanXhtml(extractDir);
      EpubParser.fileCount = scanned.length;
      EpubParser.buildFromFiles(scanned, work, onProgress);
      if (work.chapters.length === 0) {
        throw new Error(`这不是标准的 EPUB：解压后既没有 META-INF/container.xml，也没有找到可读的 xhtml 页面（解压出 ${EpubParser.fileCount} 个页面文件）`);
      }
      EpubParser.normalizeTitle(work);
      return work;
    }

    const containerRoot = HtmlParser.parse(FileTextReader.read(containerPath));
    const rootfile = HtmlParser.findFirst(containerRoot, 'rootfile');
    let opfPath = rootfile === null ? '' : EpubParser.decodeUriPath(rootfile.attr('full-path'));

    let opfRoot: HtmlNode | null = null;
    if (opfPath.length > 0 && fs.accessSync(`${extractDir}/${opfPath}`)) {
      opfRoot = HtmlParser.parse(FileTextReader.read(`${extractDir}/${opfPath}`));
    } else {
      const anyOpf = EpubParser.findFirstFile(extractDir, '.opf');
      if (anyOpf !== null) {
        opfPath = anyOpf;
        opfRoot = HtmlParser.parse(FileTextReader.read(`${extractDir}/${opfPath}`));
      }
    }
    if (opfRoot === null) {
      throw new Error('EPUB 结构异常：找不到包描述文件 .opf');
    }

    const baseDir = EpubParser.dirOf(opfPath);
    work.title = EpubParser.firstText(opfRoot, 'dc:title', 'title');
    work.author = EpubParser.firstText(opfRoot, 'dc:creator', 'creator');
    work.language = EpubParser.firstText(opfRoot, 'dc:language', 'language');
    if (work.language.length === 0) {
      work.language = 'en';
    }
    work.tags = EpubParser.collectSubjects(opfRoot);

    const manifest = new Map<string, ManifestItem>();
    const items: HtmlNode[] = [];
    HtmlParser.findAll(opfRoot, 'item', items);
    for (let i = 0; i < items.length; i++) {
      const it = new ManifestItem();
      it.id = items[i].attr('id');
      it.href = items[i].attr('href');
      it.mediaType = items[i].attr('media-type');
      it.properties = items[i].attr('properties');
      if (it.id.length > 0) {
        manifest.set(it.id, it);
      }
    }

    const spine: string[] = [];
    const refs: HtmlNode[] = [];
    HtmlParser.findAll(opfRoot, 'itemref', refs);
    for (let i = 0; i < refs.length; i++) {
      if (refs[i].attr('linear') === 'no') {
        continue;
      }
      const idref = refs[i].attr('idref');
      const item = manifest.get(idref);
      if (item === undefined) {
        continue;
      }
      if (item.properties.indexOf('nav') >= 0) {
        continue;
      }
      if (item.mediaType !== '' && item.mediaType.indexOf('xhtml') < 0 &&
        item.mediaType.indexOf('html') < 0 && item.mediaType.indexOf('xml') < 0) {
        continue;
      }
      spine.push(item.href);
    }

    // 主链路：严格按 spine 顺序
    let hit = 0;
    let missing = 0;
    for (let i = 0; i < spine.length; i++) {
      const rel = EpubParser.decodeUriPath(spine[i]);
      const full = `${extractDir}/${EpubParser.resolve(baseDir, rel)}`;
      if (!fs.accessSync(full)) {
        missing++;
        continue;
      }
      EpubParser.report(onProgress, `正在解析 ${i + 1}/${spine.length} 个章节文件…`);
      const chapter = EpubParser.parseChapterFile(full, i);
      if (chapter.paragraphs.length > 0) {
        work.chapters.push(chapter);
        hit++;
      }
    }
    Log.i(`epub spine：manifest ${items.length}，spine ${spine.length}，命中 ${hit}，缺失 ${missing}`);

    // 兜底：spine 拿不到正文时，扫描整个解压目录
    if (work.chapters.length === 0) {
      Log.w('spine 未产出章节，退化为扫描解压目录');
      const scanned = EpubParser.scanXhtml(extractDir);
      EpubParser.fileCount = scanned.length;
      EpubParser.buildFromFiles(scanned, work, onProgress, true);
      if (work.chapters.length === 0) {
        EpubParser.buildFromFiles(scanned, work, onProgress, false);
      }
    }

    if (work.chapters.length === 0) {
      const scanned = EpubParser.scanXhtml(extractDir);
      const wantList = EpubParser.peek(spine, 3);
      const gotList = EpubParser.peek(EpubParser.toRelative(extractDir, scanned), 5);
      throw new Error(`EPUB 里没有可读的章节：manifest ${items.length} 项，spine ${spine.length} 项，` +
        `其中 ${missing} 项文件找不到；解压目录内 xhtml ${scanned.length} 个。` +
        `[spine 期望] ${wantList} [实际解压] ${gotList}`);
    }

    EpubParser.normalizeTitle(work);
    return work;
  }

  private static normalizeTitle(work: ParsedWork): void {
    if (work.title.length === 0 && work.chapters.length > 0) {
      work.title = work.chapters[0].title;
    }
    if (work.title.length === 0) {
      work.title = '未命名作品';
    }
  }

  private static buildFromFiles(files: string[], work: ParsedWork,
    onProgress?: (msg: string) => void, skipNav: boolean = false): void {
    for (let i = 0; i < files.length; i++) {
      if (skipNav && EpubParser.looksLikeNav(files[i])) {
        continue;
      }
      EpubParser.report(onProgress, `正在解析 ${i + 1}/${files.length} 个页面…`);
      try {
        const chapter = EpubParser.parseChapterFile(files[i], work.chapters.length);
        if (chapter.paragraphs.length > 0) {
          work.chapters.push(chapter);
        }
      } catch (e) {
        Log.w(`跳过无法解析的页面 ${files[i]}: ${(e as Error).message}`);
      }
    }
  }

  private static looksLikeNav(path: string): boolean {
    const low = path.toLowerCase();
    return low.indexOf('nav') >= 0 || low.indexOf('toc') >= 0 || low.indexOf('cover') >= 0;
  }

  private static scanXhtml(dir: string): string[] {
    const out: string[] = [];
    EpubParser.scanInner(dir, out, true);
    out.sort(EpubParser.naturalCompare);
    return out;
  }

  /**
   * 自然序比较：按"人类阅读顺序"排文件。
   * 纯字典序会把 chapter10 排到 chapter2 前面，兜底扫描时章节顺序会全乱。
   */
  static naturalCompare(a: string, b: string): number {
    let i = 0;
    let j = 0;
    while (i < a.length && j < b.length) {
      const ca = a.charAt(i);
      const cb = b.charAt(j);
      const da = ca >= '0' && ca <= '9';
      const db = cb >= '0' && cb <= '9';
      if (da && db) {
        let na = 0;
        while (i < a.length && a.charAt(i) >= '0' && a.charAt(i) <= '9') {
          na = na * 10 + (a.charCodeAt(i) - 48);
          i++;
        }
        let nb = 0;
        while (j < b.length && b.charAt(j) >= '0' && b.charAt(j) <= '9') {
          nb = nb * 10 + (b.charCodeAt(j) - 48);
          j++;
        }
        if (na !== nb) {
          return na - nb;
        }
        continue;
      }
      if (ca !== cb) {
        return ca < cb ? -1 : 1;
      }
      i++;
      j++;
    }
    return (a.length - i) - (b.length - j);
  }

  private static scanAny(dir: string): string[] {
    const out: string[] = [];
    EpubParser.scanInner(dir, out, false);
    out.sort(EpubParser.naturalCompare);
    return out;
  }

  private static scanInner(dir: string, out: string[], onlyPages: boolean): void {
    let names: string[] = [];
    try {
      names = fs.listFileSync(dir);
    } catch (e) {
      return;
    }
    for (let i = 0; i < names.length; i++) {
      const full = `${dir}/${names[i]}`;
      let isDir = false;
      try {
        isDir = fs.statSync(full).isDirectory();
      } catch (e) {
        continue;
      }
      if (isDir) {
        EpubParser.scanInner(full, out, onlyPages);
        continue;
      }
      if (!onlyPages) {
        out.push(full);
        continue;
      }
      const low = names[i].toLowerCase();
      if (low.endsWith('.xhtml') || low.endsWith('.html') || low.endsWith('.htm')) {
        out.push(full);
      }
    }
  }

  /** 取前 n 项拼成一行，用于错误信息里的"实际 vs 期望"对照 */
  private static peek(arr: string[], n: number): string {
    if (arr.length === 0) {
      return '（空）';
    }
    let s = '';
    const limit = Math.min(n, arr.length);
    for (let i = 0; i < limit; i++) {
      if (i > 0) {
        s += ' | ';
      }
      s += arr[i];
    }
    if (arr.length > limit) {
      s += ` …共 ${arr.length} 项`;
    }
    return s;
  }

  private static toRelative(dir: string, paths: string[]): string[] {
    const out: string[] = [];
    const prefix = dir.length + 1;
    for (let i = 0; i < paths.length; i++) {
      out.push(paths[i].length > prefix ? paths[i].substring(prefix) : paths[i]);
    }
    return out;
  }

  private static findFirstFile(dir: string, suffix: string): string | null {
    const all = EpubParser.scanAny(dir);
    for (let i = 0; i < all.length; i++) {
      if (all[i].toLowerCase().endsWith(suffix)) {
        return all[i].substring(dir.length + 1);
      }
    }
    return null;
  }

  private static fillMetaFromAnyOpf(extractDir: string, work: ParsedWork): void {
    const opf = EpubParser.findFirstFile(extractDir, '.opf');
    if (opf === null) {
      return;
    }
    try {
      const root = HtmlParser.parse(FileTextReader.read(`${extractDir}/${opf}`));
      work.title = EpubParser.firstText(root, 'dc:title', 'title');
      work.author = EpubParser.firstText(root, 'dc:creator', 'creator');
    } catch (e) {
      Log.w('读取 opf 元数据失败');
    }
  }

  private static parseChapterFile(path: string, order: number): ParsedChapter {
    const text = FileTextReader.read(path);
    if (text.length === 0) {
      Log.w(`章节文件解码后为空: ${path}`);
    }
    const root = HtmlParser.parse(text);
    const paragraphs: ParsedParagraph[] = XhtmlConverter.toParagraphs(root);

    let title = XhtmlConverter.firstHeadingText(root);
    if (title.length === 0) {
      const t = HtmlParser.findFirst(root, 'title');
      if (t !== null) {
        title = XhtmlConverter.normalizeSpace(HtmlParser.textOf(t));
      }
    }
    if (title.length === 0) {
      title = `第 ${order + 1} 章`;
    }

    // 正文首段若与标题重复，去掉，避免阅读器里标题出现两次
    if (paragraphs.length > 0) {
      let first = '';
      for (let i = 0; i < paragraphs[0].runs.length; i++) {
        first += paragraphs[0].runs[i].text;
      }
      if (XhtmlConverter.normalizeSpace(first) === title) {
        paragraphs.shift();
      }
    }

    const chapter: ParsedChapter = { title: title, paragraphs: paragraphs };
    return chapter;
  }

  private static collectSubjects(opfRoot: HtmlNode): string[] {
    const out: string[] = [];
    const nodes: HtmlNode[] = [];
    HtmlParser.findAll(opfRoot, 'dc:subject', nodes);
    HtmlParser.findAll(opfRoot, 'subject', nodes);
    for (let i = 0; i < nodes.length; i++) {
      const t = XhtmlConverter.normalizeSpace(HtmlParser.textOf(nodes[i]));
      if (t.length > 0) {
        out.push(t);
      }
    }
    return out;
  }

  private static firstText(root: HtmlNode, tagA: string, tagB: string): string {
    let n = HtmlParser.findFirst(root, tagA);
    if (n === null) {
      n = HtmlParser.findFirst(root, tagB);
    }
    if (n === null) {
      return '';
    }
    return XhtmlConverter.normalizeSpace(HtmlParser.textOf(n));
  }

  private static dirOf(path: string): string {
    const idx = path.lastIndexOf('/');
    return idx < 0 ? '' : path.substring(0, idx);
  }

  /** 相对路径解析，处理 ../ 与 ./ */
  private static resolve(baseDir: string, rel: string): string {
    if (rel.startsWith('/')) {
      return rel;
    }
    const segs: string[] = [];
    if (baseDir.length > 0) {
      const bs = baseDir.split('/');
      for (let i = 0; i < bs.length; i++) {
        if (bs[i].length > 0) {
          segs.push(bs[i]);
        }
      }
    }
    const rs = rel.split('/');
    for (let i = 0; i < rs.length; i++) {
      const s = rs[i];
      if (s.length === 0 || s === '.') {
        continue;
      }
      if (s === '..') {
        if (segs.length > 0) {
          segs.pop();
        }
        continue;
      }
      segs.push(s);
    }
    return segs.join('/');
  }

  private static decodeUriPath(p: string): string {
    if (p.indexOf('%') < 0) {
      return p;
    }
    try {
      return decodeURIComponent(p);
    } catch (e) {
      return p;
    }
  }

  private static prepareDir(dir: string): void {
    // 上一次失败可能留下非空目录，rmdirSync 删不掉非空目录，
    // 残留文件会让本次解压读到旧内容，因此必须递归清理。
    if (fs.accessSync(dir)) {
      EpubParser.removeTree(dir);
    }
    fs.mkdirSync(dir, true);
  }

  private static removeTree(dir: string): void {
    let names: string[] = [];
    try {
      names = fs.listFileSync(dir);
    } catch (e) {
      return;
    }
    for (let i = 0; i < names.length; i++) {
      const full = `${dir}/${names[i]}`;
      try {
        if (fs.statSync(full).isDirectory()) {
          EpubParser.removeTree(full);
          fs.rmdirSync(full);
        } else {
          fs.unlinkSync(full);
        }
      } catch (e) {
        Log.w(`清理残留失败: ${full}`);
      }
    }
  }

  /** 统计解压目录下的文件总数，用于判断解压是否真的产出了内容 */
  private static countFiles(dir: string): number {
    let total = 0;
    let names: string[] = [];
    try {
      names = fs.listFileSync(dir);
    } catch (e) {
      return 0;
    }
    for (let i = 0; i < names.length; i++) {
      const full = `${dir}/${names[i]}`;
      try {
        if (fs.statSync(full).isDirectory()) {
          total += EpubParser.countFiles(full);
        } else {
          total++;
        }
      } catch (e) {
        continue;
      }
    }
    return total;
  }

  private static report(cb: ((msg: string) => void) | undefined, msg: string): void {
    if (cb !== undefined) {
      cb(msg);
    }
  }
}
