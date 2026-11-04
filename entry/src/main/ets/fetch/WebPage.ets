import { http } from '@kit.NetworkKit';
import { HeadlessRenderer } from './HeadlessRenderer';
import { WebToBook } from './WebToBook';
import { Log } from '../common/Logger';

/**
 * 网页读取：把 URL 上的页面抓回来，去掉脚本样式标签，抽成可读文本。
 *
 * 这是模型"自己看网页"的能力 —— 搜索结果只有几行摘要，模型想确认
 * 某个链接是不是目标作品、章节列表有多少章、推荐榜单里都有什么，
 * 就得真的把页面内容读进来。
 *
 * 不追求完整的 HTML 解析（鸿蒙没有内置 DOM），只做够用的正文提取：
 * 去 script/style/注释 → 块级标签转换行 → 去标签 → 解实体 → 压空白。
 * 对 AO3 / FFN / reddit / 博客这类结构规整的页面效果足够。
 */
export interface PageResult {
  ok: boolean;
  /** HTTP 状态码，0 表示网络层失败 */
  status: number;
  title: string;
  text: string;
  /** 是否因为过长被截断 */
  truncated: boolean;
  note: string;
}

/** 单页最多收这么多字节，防止撞上巨型页面把内存撑爆 */
const MAX_BYTES: number = 1200000;
/** 可读文本少于此值视为 JS 渲染空壳，降级用内置渲染器重抽 */
const SHELL_TEXT_CHARS: number = 300;

export class WebPage {
  static async read(url: string, maxChars: number): Promise<PageResult> {
    const req = http.createHttp();
    try {
      const header: Record<string, string> = {
        'Accept': 'text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.8',
        'Accept-Language': 'en-US,en;q=0.9,zh-CN;q=0.8',
        'User-Agent': 'Mozilla/5.0 (Linux; HarmonyOS) AppleWebKit/537.36 (KHTML, like Gecko) Mobile Safari/537.36'
      };
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: header,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 12000,
        readTimeout: 20000
      };
      const resp = await req.request(url, options);
      if (resp.responseCode !== 200) {
        return { ok: false, status: resp.responseCode, title: '', text: '', truncated: false, note: `HTTP ${resp.responseCode}` };
      }
      let html = typeof resp.result === 'string' ? resp.result : '';
      if (html.length === 0) {
        return { ok: false, status: resp.responseCode, title: '', text: '', truncated: false, note: '页面内容为空' };
      }
      if (html.length > MAX_BYTES) {
        html = html.substring(0, MAX_BYTES);
      }
      let title = WebPage.titleOf(html);
      let text = WebPage.toText(html);
      let note = '';
      if (text.length < SHELL_TEXT_CHARS) {
        // 空壳页（SPA）：正文要靠 JS 调接口插入，直接抓只有骨架。
        // 用隐藏 ArkWeb 真渲染一次再抽 —— 站内搜索结果页（晋江/LOFTER 标签页）都靠这条路。
        const rendered = await HeadlessRenderer.render(url);
        if (rendered.ok) {
          const renderedTitle = WebPage.titleOf(rendered.html);
          if (renderedTitle.length > 0) {
            title = renderedTitle;
          }
          text = WebPage.toText(rendered.html);
          note = '已用内置浏览器渲染（页面为 JS 动态渲染）';
          Log.i(`fetch_page 渲染降级成功：${url}`);
        } else {
          Log.w(`fetch_page 渲染降级失败：${rendered.note}`);
          if (text.length < SHELL_TEXT_CHARS) {
            note = '页面是 JS 动态渲染但内置渲染后仍无正文' + WebToBook.embeddedStateHint(html);
          }
        }
      }
      let truncated = false;
      if (text.length > maxChars) {
        text = text.substring(0, maxChars);
        truncated = true;
      }
      return { ok: true, status: 200, title: title, text: text, truncated: truncated, note: note };
    } catch (e) {
      const raw = (e as Error).message;
      Log.i(`网页读取失败（${raw}）：${url}`);
      const timeout = raw.includes('timeout') || raw.includes('Timeout');
      return {
        ok: false,
        status: 0,
        title: '',
        text: '',
        truncated: false,
        note: timeout ? '读取超时（站点响应慢或需要登录）' : `网络错误：${raw}`
      };
    } finally {
      req.destroy();
    }
  }

  private static titleOf(html: string): string {
    const m = /<title[^>]*>([\s\S]*?)<\/title>/i.exec(html);
    if (m === null || m.length < 2) {
      return '';
    }
    return WebPage.decode(m[1]).replace(/\s+/g, ' ').trim();
  }

  /** HTML → 纯文本（debug_fetch 的体检报告也用它量可见文本量） */
  static toText(html: string): string {
    let s = html;
    s = s.replace(/<script[\s\S]*?<\/script>/gi, ' ');
    s = s.replace(/<style[\s\S]*?<\/style>/gi, ' ');
    s = s.replace(/<noscript[\s\S]*?<\/noscript>/gi, ' ');
    s = s.replace(/<!--[\s\S]*?-->/g, ' ');
    s = s.replace(/<br\s*\/?>/gi, '\n');
    s = s.replace(/<\/(p|div|li|tr|h[1-6]|section|article|blockquote)>/gi, '\n');
    s = s.replace(/<[^>]+>/g, ' ');
    s = WebPage.decode(s);
    s = s.replace(/[ \t\u00a0\u3000]+/g, ' ');
    s = s.replace(/ *\n */g, '\n');
    s = s.replace(/\n{3,}/g, '\n\n');
    return s.trim();
  }

  /** 只处理最常见的实体，够读正文就行 */
  private static decode(s: string): string {
    let out = s;
    out = out.replace(/&nbsp;/gi, ' ');
    out = out.replace(/&amp;/gi, '&');
    out = out.replace(/&lt;/gi, '<');
    out = out.replace(/&gt;/gi, '>');
    out = out.replace(/&quot;/gi, '"');
    out = out.replace(/&#0?39;/g, '\'');
    out = out.replace(/&apos;/gi, '\'');
    out = out.replace(/&mdash;/gi, '—');
    out = out.replace(/&ndash;/gi, '–');
    out = out.replace(/&hellip;/gi, '…');
    out = out.replace(/&rsquo;/gi, '\'');
    out = out.replace(/&lsquo;/gi, '\'');
    out = out.replace(/&ldquo;/gi, '"');
    out = out.replace(/&rdquo;/gi, '"');
    return out;
  }
}
