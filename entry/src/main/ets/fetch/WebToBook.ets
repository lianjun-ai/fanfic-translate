import { fileIo as fs } from '@kit.CoreFileKit';
import { HttpFetch } from './HttpFetch';
import { HeadlessRenderer } from './HeadlessRenderer';
import { FileTextReader } from '../parser/FileTextReader';
import { HtmlNode, HtmlParser } from '../parser/HtmlParser';
import { XhtmlConverter } from '../parser/XhtmlConverter';
import { ParsedChapter, ParsedParagraph } from '../parser/ParserTypes';
import { ParaType, Run } from '../model/Models';
import { Log } from '../common/Logger';

/** 单页正文字符上限：超过截断并提示，防止一个无限长页面撑爆一本书 */
const MAX_PAGE_CHARS: number = 200000;

/* LOFTER 帖子详情页把完整帖子数据内嵌在 window.__initialize_data__ 里，
 * 只定义用到的字段（JSON.parse 后按接口断言取值）。 */
interface LofterInitData {
  postData?: LofterPostWrap;
}
interface LofterPostWrap {
  data?: LofterPostData;
}
interface LofterPostData {
  blogInfo?: LofterBlogInfo;
  postData?: LofterPostInner;
}
interface LofterPostInner {
  postView?: LofterPostView;
}
interface LofterPostView {
  id?: number;
  title?: string;
  type?: number;
  textPostView?: LofterTextPostView;
}
interface LofterTextPostView {
  content?: string;
}
interface LofterBlogInfo {
  blogNickName?: string;
  blogName?: string;
}

/** capParagraphs 的返回 */
interface CappedParagraphs {
  list: ParsedParagraph[];
  chars: number;
  truncated: boolean;
}

/** 抓取结果（成功时 paragraphs 非空） */
export interface WebPageFetched {
  ok: boolean;
  note: string;
  title: string;
  paragraphs: ParsedParagraph[];
  chars: number;
}

/** 拼接用的一章 */
export interface WebChapter {
  title: string;
  paragraphs: ParsedParagraph[];
}

/**
 * 网页 → 本地书。
 *
 * 与 fetch_page 的本质区别：fetch_page 是「读给你看」，这里是「收成一本」——
 * 走完整条正文抽取管线（和本地导入 HTML 同一套解析器），再序列化回带
 * <h1> 分章标记的合并文档，由 HtmlFileParser 在导入时拆成多章。
 *
 * 两级取正文：先直抓源码（便宜，覆盖静态页）；抽不到正文说明页面是
 * JS 动态渲染，自动降级到隐藏 ArkWeb 真渲染一次再抽（见 HeadlessRenderer）。
 * 仍拿不到（需要登录 / 强反爬）才报失败，由调用方建议用户走分享入口。
 */
export class WebToBook {
  /** 抓单个网页并抽取正文段落（直抓失败于空壳时自动用内置渲染重试） */
  static async fetchPage(url: string, tmpDir: string): Promise<WebPageFetched> {
    const res = await HttpFetch.toFile(url, tmpDir);
    if (!res.ok) {
      return { ok: false, note: res.note, title: '', paragraphs: [], chars: 0 };
    }
    let text = '';
    try {
      text = FileTextReader.read(res.path);
    } catch (e) {
      return { ok: false, note: `读取网页失败：${(e as Error).message}`, title: '', paragraphs: [], chars: 0 };
    } finally {
      try {
        fs.unlinkSync(res.path);
      } catch (e) {
        // 临时文件删不掉不影响结果
      }
    }
    if (text.indexOf('<') < 0) {
      return { ok: false, note: '返回内容不是网页（可能被反爬拦截）', title: '', paragraphs: [], chars: 0 };
    }
    const direct = WebToBook.processHtml(text, '');
    if (direct.ok) {
      return direct;
    }
    // 直抓空壳：多半是 JS 动态渲染，用隐藏 ArkWeb 真渲染一次
    const rendered = await WebToBook.renderFallback(url);
    if (rendered !== null) {
      return rendered;
    }
    return direct;
  }

  /** 用隐藏 ArkWeb 渲染后重新抽取；仍抽不到正文返回 null（沿用直抓的失败说明） */
  private static async renderFallback(url: string): Promise<WebPageFetched | null> {
    const res = await HeadlessRenderer.render(url);
    if (!res.ok) {
      Log.w(`内置渲染降级失败：${res.note}`);
      return null;
    }
    const out = WebToBook.processHtml(res.html, '已用内置浏览器渲染；');
    if (!out.ok) {
      Log.w('内置渲染完成但未抽出正文');
      return null;
    }
    return out;
  }

  /** 解析 HTML 文本 → 标题 + 截断后的正文段落。prefix 拼在成功时的 note 前面。 */
  private static processHtml(text: string, notePrefix: string): WebPageFetched {
    // LOFTER 帖子页：正文以内嵌 JSON 形式放在空壳 HTML 里，优先从那里提取
    const lofter = WebToBook.lofterEmbedded(text);
    if (lofter !== null) {
      return lofter;
    }
    const root = HtmlParser.parse(text);
    let title = '';
    const titleNode = HtmlParser.findFirst(root, 'title');
    if (titleNode !== null) {
      title = XhtmlConverter.normalizeSpace(HtmlParser.textOf(titleNode));
    }
    if (title.length === 0 || WebToBook.isShellTitle(title)) {
      const og = WebToBook.metaContent(root, 'og:title');
      if (og.length > 0) {
        title = og;
      }
    }
    if (title.length === 0 || WebToBook.isShellTitle(title)) {
      title = XhtmlConverter.firstHeadingText(root);
    }
    let paragraphs: ParsedParagraph[] = [];
    try {
      paragraphs = XhtmlConverter.toParagraphs(root);
    } catch (e) {
      // 解析器对某些页面结构抛异常时兜住，给出可读的失败原因而不是让整个工具调用崩掉
      Log.w(`正文抽取异常：${(e as Error).message}`);
      return {
        ok: false, title: title, paragraphs: [], chars: 0,
        note: `解析页面时出错：${(e as Error).message}`
      };
    }
    if (paragraphs.length === 0) {
      return {
        ok: false, title: title, paragraphs: [], chars: 0,
        note: '页面里没有正文（需要登录才能看、内容主要是图片、或反爬拦截；JS 动态渲染的页面已自动用内置浏览器渲染过）' + WebToBook.embeddedStateHint(text)
      };
    }
    const capped = WebToBook.capParagraphs(paragraphs);
    const note = capped.truncated ? `${notePrefix}正文超过 ${MAX_PAGE_CHARS} 字，已截断` : notePrefix;
    return { ok: true, note: note, title: title, paragraphs: capped.list, chars: capped.chars };
  }

  /** 截断保护：单页正文字符超过 MAX_PAGE_CHARS 时停手 */
  private static capParagraphs(paragraphs: ParsedParagraph[]): CappedParagraphs {
    let chars = 0;
    const list: ParsedParagraph[] = [];
    let truncated = false;
    for (let i = 0; i < paragraphs.length; i++) {
      const p = paragraphs[i];
      let len = 0;
      for (let j = 0; j < p.runs.length; j++) {
        len += p.runs[j].text.length;
      }
      if (chars + len > MAX_PAGE_CHARS) {
        truncated = true;
        break;
      }
      list.push(p);
      chars += len;
    }
    return { list: list, chars: chars, truncated: truncated };
  }

  /**
   * LOFTER 帖子详情页的正文提取。
   *
   * LOFTER 的 h5 空壳页面把整篇帖子内嵌在 window.__initialize_data__ JSON 里
   * （title 在 postView.title，正文 HTML 在 postView.textPostView.content），
   * 直抓就能拿到，无需内置渲染 —— 实测同一链接渲染路径会间歇性挂不出内容
   * （DOM 2.5 万字符但正文文本 0）。内嵌数据缺失或结构对不上时返回 null，
   * 交给后续的常规解析 / 渲染降级。
   */
  private static lofterEmbedded(text: string): WebPageFetched | null {
    if (text.indexOf('__initialize_data__') < 0) {
      return null;
    }
    const m = /window\.__initialize_data__ = (\{[\s\S]*?\});?\s*<\/script>/.exec(text);
    if (m === null || m.length < 2) {
      return null;
    }
    let data: LofterInitData;
    try {
      data = JSON.parse(m[1]) as LofterInitData;
    } catch (e) {
      Log.w('LOFTER 内嵌数据 JSON 解析失败，回退常规解析');
      return null;
    }
    const pv = data.postData?.data?.postData?.postView;
    const content = pv?.textPostView?.content ?? '';
    if (content.length === 0) {
      return null;
    }
    // 正文 HTML 以 <br> 分段（LOFTER 编辑器的常见形态），没有块级标签时
    // 把 br 拆成独立 <p>，读起来才是正常分段；本身带 <p> 的就原样交解析器
    let html = content;
    if (html.indexOf('<p') < 0 && html.indexOf('<div') < 0) {
      html = `<p>${html.replace(/<br\s*\/?>/gi, '</p><p>')}</p>`;
    }
    const root = HtmlParser.parse(html);
    let paragraphs: ParsedParagraph[] = [];
    try {
      paragraphs = XhtmlConverter.toParagraphs(root);
    } catch (e) {
      Log.w(`LOFTER 正文解析异常：${(e as Error).message}`);
      return null;
    }
    paragraphs = paragraphs.filter((p): boolean => {
      if (p.type === ParaType.DIVIDER) {
        return true;
      }
      for (let i = 0; i < p.runs.length; i++) {
        if (p.runs[i].text.trim().length > 0) {
          return true;
        }
      }
      return false;
    });
    if (paragraphs.length === 0) {
      return null;
    }
    let title = XhtmlConverter.normalizeSpace(pv?.title ?? '');
    if (title.length === 0) {
      title = XhtmlConverter.firstHeadingText(root);
    }
    if (title.length === 0 && paragraphs.length > 0) {
      // LOFTER 帖子常无标题：拿首段前 40 字当书名
      const first = paragraphs[0];
      let firstText = '';
      for (let i = 0; i < first.runs.length; i++) {
        firstText += first.runs[i].text;
      }
      title = firstText.trim().substring(0, 40);
    }
    const capped = WebToBook.capParagraphs(paragraphs);
    Log.i(`LOFTER 内嵌数据提取成功：${title.length > 0 ? title : '（无标题）'}，约 ${capped.chars} 字`);
    return {
      ok: true, note: '已从 LOFTER 页面内嵌数据提取正文', title: title,
      paragraphs: capped.list, chars: capped.chars
    };
  }

  /**
   * 门户壳标题：SPA 详情页的 <title> 常常是站点品牌口号而非内容标题
   * （如 LOFTER 详情页固定为「LOFTER（乐乎） - 让兴趣，更有趣」），
   * 识别到就跳过，改用 og:title / 正文首个标题。
   */
  private static isShellTitle(t: string): boolean {
    return t.indexOf('让兴趣，更有趣') >= 0;
  }

  /**
   * 失败诊断提示：页面抽不到正文时，扫一眼源码里有没有「壳 + 内嵌 JSON 数据」
   * 的常见标记。这类页面数据其实在源码里，只是本应用的解析器还没适配该站
   * 的 JSON 结构 —— 把线索写进失败回包，调用方（找文模型）才能转告用户
   * 「不是真抓不到，是差一个适配」，而不是误报成登录墙/反爬。
   */
  static embeddedStateHint(text: string): string {
    const markers: string[] = [
      '__NEXT_DATA__',        // Next.js
      '__INITIAL_STATE__',    // Vue/Nuxt 等
      '__NUXT__',
      '__INITIAL_DATA__',
      '__APP_DATA__',
      '__initialize_data__'   // LOFTER
    ];
    const found: string[] = [];
    for (let i = 0; i < markers.length; i++) {
      if (text.indexOf(markers[i]) >= 0) {
        found.push(markers[i]);
      }
    }
    if (found.length === 0) {
      return '';
    }
    return `；检测到页面源码内嵌了数据（${found.join('、')}），正文可能在里面但本应用尚未适配该站的数据结构`;
  }

  /** 取 <meta property|name="..."> 的 content */
  private static metaContent(root: HtmlNode, key: string): string {
    const metas: HtmlNode[] = [];
    HtmlParser.findAll(root, 'meta', metas);
    for (let i = 0; i < metas.length; i++) {
      const m = metas[i];
      if (m.attr('property') === key || m.attr('name') === key) {
        return XhtmlConverter.normalizeSpace(m.attr('content'));
      }
    }
    return '';
  }

  /**
   * 多章拼成一个 HTML 文档。
   *
   * 每章用 <h1> 开头 —— HtmlFileParser 看到 body 顶层有 ≥2 个 <h1>
   * 就会按它们分章；单页只有一个 h1，维持整篇一章的旧行为。
   * 段落序列化回 <p>/<h2>/<hr>，行内样式还原成 <b>/<i>/<u>/<s>，
   * 与本地 HTML 导入的解析方向正好互逆，样式不丢。
   */
  static buildHtml(workTitle: string, chapters: WebChapter[]): string {
    let out = '<!DOCTYPE html><html><head><meta charset="utf-8"><title>';
    out += WebToBook.esc(workTitle);
    out += '</title></head><body>';
    for (let i = 0; i < chapters.length; i++) {
      const ch = chapters[i];
      out += '<h1>';
      out += WebToBook.esc(ch.title);
      out += '</h1>';
      for (let j = 0; j < ch.paragraphs.length; j++) {
        const p = ch.paragraphs[j];
        if (p.type === ParaType.DIVIDER) {
          out += '<hr/>';
          continue;
        }
        const tag = p.type === ParaType.HEADING ? 'h2' : 'p';
        out += `<${tag}>`;
        for (let k = 0; k < p.runs.length; k++) {
          out += WebToBook.serializeRun(p.runs[k]);
        }
        out += `</${tag}>`;
      }
    }
    out += '</body></html>';
    return out;
  }

  private static serializeRun(r: Run): string {
    let s = WebToBook.esc(r.text);
    if (r.bold) {
      s = `<b>${s}</b>`;
    }
    if (r.italic) {
      s = `<i>${s}</i>`;
    }
    if (r.underline) {
      s = `<u>${s}</u>`;
    }
    if (r.strike) {
      s = `<s>${s}</s>`;
    }
    return s;
  }

  private static esc(s: string): string {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }
}
