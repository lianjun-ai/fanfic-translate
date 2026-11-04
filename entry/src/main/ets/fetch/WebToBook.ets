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
    const root = HtmlParser.parse(text);
    let title = '';
    const titleNode = HtmlParser.findFirst(root, 'title');
    if (titleNode !== null) {
      title = XhtmlConverter.normalizeSpace(HtmlParser.textOf(titleNode));
    }
    if (title.length === 0) {
      title = XhtmlConverter.firstHeadingText(root);
    }
    const paragraphs = XhtmlConverter.toParagraphs(root);
    if (paragraphs.length === 0) {
      return {
        ok: false, title: title, paragraphs: [], chars: 0,
        note: '页面里没有正文（多半是 JS 动态渲染或需要登录后才能看到内容）'
      };
    }
    let chars = 0;
    const capped: ParsedParagraph[] = [];
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
      capped.push(p);
      chars += len;
    }
    const note = truncated ? `${notePrefix}正文超过 ${MAX_PAGE_CHARS} 字，已截断` : notePrefix;
    return { ok: true, note: note, title: title, paragraphs: capped, chars: chars };
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
