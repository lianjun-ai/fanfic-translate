import { HttpFetch } from './HttpFetch';
import { HtmlNode, HtmlParser } from '../parser/HtmlParser';
import { Log } from '../common/Logger';

/** 一条链接清单条目 */
export interface LinkItem {
  title: string;
  url: string;
  date: string;
  /** 发布时间（毫秒），通用链接来源为 0 */
  time: number;
}

/** list_links 的返回 */
export interface LinkListResult {
  ok: boolean;
  note: string;
  items: LinkItem[];
}

/** DWR 解析用的帖子对象：字段名 → 原始值（字符串带引号、数字裸值） */
type DwrObject = Map<string, string>;

/** 单次归档请求返回的帖子数（LOFTER 归档接口的 DWR 页大小） */
const PAGE_SIZE: number = 50;
/** 最多翻几页，防止死循环（3 页 × 50 = 150 篇足够覆盖绝大多数博客） */
const MAX_PAGES: number = 3;
/** 通用链接清单上限 */
const MAX_LINKS: number = 100;

/**
 * 网页链接清单引擎，供 list_links 工具使用。
 *
 * LOFTER 博客主页/搜索/标签页都要登录才能看，但归档接口
 * （POST {博客子域}/dwr/call/plaincall/ArchiveBean.getArchivePostByTime.dwr）
 * 免登录且返回全部文章的标题、永久链接和发布时间——这是抓 LOFTER
 * 系列文/合集的目录来源。其它站点退化为解析页面里的站内 <a> 链接。
 */
export class WebList {
  static async list(url: string, keyword: string): Promise<LinkListResult> {
    if (url.indexOf('lofter.com') >= 0) {
      return WebList.lofter(url, keyword);
    }
    return WebList.anchors(url);
  }

  /** LOFTER：从帖子/主页 URL 解析 blogId，再走归档接口分页拉全清单 */
  private static async lofter(url: string, keyword: string): Promise<LinkListResult> {
    const host = WebList.lofterHost(url);
    if (host.length === 0) {
      return { ok: false, note: '没认出 LOFTER 博客地址，请传形如 xxx.lofter.com 的博客主页链接或任意一篇帖子的链接', items: [] };
    }
    const blogId = await WebList.resolveBlogId(url);
    if (blogId.length === 0) {
      return {
        ok: false, items: [],
        note: '无法解析博客 ID：LOFTER 博客主页/搜索页/标签页都要登录，只有帖子页能免登录访问。请提供一个该博客任意一篇帖子的链接（形如 xxx.lofter.com/post/xxxx），从那里就能列出整个博客的文章清单'
      };
    }
    const all: LinkItem[] = [];
    const times: Map<string, number> = new Map();
    let seen = new Set<string>();
    let ts = Date.now();
    for (let page = 0; page < MAX_PAGES; page++) {
      const batch = await WebList.archivePage(host, blogId, ts);
      if (batch.length === 0) {
        break;
      }
      let oldest = Number.MAX_VALUE;
      for (let i = 0; i < batch.length; i++) {
        const p = batch[i];
        if (p.time > 0 && p.time < oldest) {
          oldest = p.time;
        }
        if (!seen.has(p.url)) {
          seen.add(p.url);
          all.push(p);
          times.set(p.url, p.time);
        }
      }
      if (batch.length < PAGE_SIZE || oldest >= Number.MAX_VALUE) {
        break;
      }
      ts = oldest - 1;
    }
    if (all.length === 0) {
      return { ok: false, note: '归档接口没有返回任何文章（博客可能只有图片/视频帖，或文章都被删除）', items: [] };
    }
    // 时间正序 = 发布顺序，正好是章节顺序
    all.sort((a, b): number => {
      const ta = times.get(a.url) ?? 0;
      const tb = times.get(b.url) ?? 0;
      return ta - tb;
    });
    let filtered = all;
    if (keyword.length > 0) {
      filtered = all.filter((p): boolean => p.title.indexOf(keyword) >= 0);
    }
    Log.i(`LOFTER 归档清单：${all.length} 篇（关键字过滤后 ${filtered.length}）`);
    const note = `共列出 ${all.length} 篇文章${keyword.length > 0 ? `，标题含「${keyword}」的 ${filtered.length} 篇` : ''}（按发布时间正序）。要抓哪些章，把对应 url 数组传给 html_to_book 即可`;
    return { ok: true, note: note, items: filtered };
  }

  /** 从 URL 抠博客子域（xxx.lofter.com 的 xxx），www/m 开头的返回空 */
  private static lofterHost(url: string): string {
    const m = /https?:\/\/([a-zA-Z0-9-]+)\.lofter\.com/.exec(url);
    if (m === null || m.length < 2) {
      return '';
    }
    const sub = m[1];
    if (sub === 'www' || sub === 'm' || sub === 'api') {
      return '';
    }
    return `${sub}.lofter.com`;
  }

  /** blogId 解析：帖子页免登录，内嵌 JSON 里带 blogId；主页被 302 到登录页就拿不到 */
  private static async resolveBlogId(url: string): Promise<string> {
    const resp = await HttpFetch.getText(url, '');
    if (!resp.ok || resp.text.length === 0) {
      return '';
    }
    const m = /"?blogId"?\s*[:=]\s*(\d+)/.exec(resp.text);
    return m !== null && m.length > 1 ? m[1] : '';
  }

  /** 调一次归档接口，解析出帖子清单 */
  private static async archivePage(host: string, blogId: string, ts: number): Promise<LinkItem[]> {
    const form: Record<string, string> = {
      'callCount': '1',
      'scriptSessionId': '${scriptSessionId}187',
      'c0-scriptName': 'ArchiveBean',
      'c0-methodName': 'getArchivePostByTime',
      'c0-id': '0',
      'c0-param0': 'boolean:false',
      'c0-param1': `number:${blogId}`,
      'c0-param2': `number:${ts}`,
      'c0-param3': `number:${PAGE_SIZE}`,
      'c0-param4': 'boolean:false',
      'batchId': '1'
    };
    const resp = await HttpFetch.postForm(`https://${host}/dwr/call/plaincall/ArchiveBean.getArchivePostByTime.dwr`, form, `https://${host}/view`);
    if (!resp.ok || resp.text.length === 0) {
      Log.w(`LOFTER 归档接口失败：HTTP ${resp.code} ${resp.note}`);
      return [];
    }
    return WebList.parseDwr(resp.text, host);
  }

  /**
   * 解析 DWR 文本。结构：先 var s0={}，再逐对象赋值 sN.field=value;，
   * 最后 _remoteHandleCallback('1','0',[s0,s1,...]) 给出帖子顺序。
   * sN（摘要，含 time/type/values）的 values 指向 sM（详情，含 title/permalink）。
   */
  private static parseDwr(text: string, host: string): LinkItem[] {
    const cbIdx = text.indexOf('_remoteHandleCallback');
    const objs = WebList.parseDwrObjects(cbIdx >= 0 ? text.substring(0, cbIdx) : text);
    if (objs.size === 0) {
      return [];
    }
    const out: LinkItem[] = [];
    // 遍历所有对象，把摘要对象（有 values 引用详情）展开成条目
    objs.forEach((fields, key): void => {
      const refRaw = fields.get('values');
      if (refRaw === undefined) {
        return;
      }
      // 引用是裸标识符（s0.values=s50;，可能带引号），对象表的键是不带 s 的数字
      const detailKey = refRaw.replace(/"/g, '').replace(/^s/, '').trim();
      const detail = objs.get(detailKey);
      if (detail === undefined) {
        return;
      }
      const permalink = WebList.dwrString(detail.get('permalink'));
      if (permalink.length === 0) {
        return;
      }
      let title = WebList.dwrString(detail.get('title'));
      if (title.length === 0) {
        title = WebList.dwrString(detail.get('noticeLinkTitle'));
      }
      if (title.length === 0) {
        title = '（无标题）';
      }
      let ms = 0;
      const t = fields.get('time');
      if (t !== undefined) {
        ms = parseInt(t, 10);
        if (isNaN(ms)) {
          ms = 0;
        }
      }
      const date = ms > 0 ? WebList.formatDate(ms) : '';
      out.push({ title: title, url: `https://${host}/post/${permalink}`, date: date, time: ms });
    });
    return out;
  }

  /** 把 DWR 赋值段落解析成 对象名 → 字段表 */
  private static parseDwrObjects(body: string): Map<string, DwrObject> {
    const objs: Map<string, DwrObject> = new Map();
    const re = /s(\d+)\.(\w+)=/g;
    let m: RegExpExecArray | null;
    const marks: RegExpExecArray[] = [];
    while ((m = re.exec(body)) !== null) {
      marks.push(m);
    }
    for (let i = 0; i < marks.length; i++) {
      const key = marks[i][1];
      const field = marks[i][2];
      let end: number;
      if (i + 1 < marks.length) {
        end = marks[i + 1].index;
      } else {
        end = body.length;
      }
      let val = body.substring(marks[i].index + marks[i][0].length, end);
      // 字符串值带引号且可能含分号，引号内原样保留；其余截到第一个分号
      val = val.replace(/^\s+/, '');
      if (val.startsWith('"')) {
        val = WebList.readQuoted(val);
      } else {
        const semi = val.indexOf(';');
        if (semi >= 0) {
          val = val.substring(0, semi);
        }
        val = val.trim();
      }
      let fields = objs.get(key);
      if (fields === undefined) {
        fields = new Map<string, string>();
        objs.set(key, fields);
      }
      fields.set(field, val);
    }
    return objs;
  }

  /** 读一个以 " 开头的 DWR 字符串字面量，返回含引号的原文 */
  private static readQuoted(s: string): string {
    for (let i = 1; i < s.length; i++) {
      const c = s.charAt(i);
      if (c === '\\') {
        i++;
        continue;
      }
      if (c === '"') {
        return s.substring(0, i + 1);
      }
    }
    return s;
  }

  /** DWR 字符串值（形如 "\u3010AM\u3011..."）解码为普通文本 */
  private static dwrString(raw: string | undefined): string {
    if (raw === undefined) {
      return '';
    }
    let v = raw.trim();
    if (v.startsWith('"') && v.endsWith('"') && v.length >= 2) {
      v = v.substring(1, v.length - 1);
      try {
        const decoded = JSON.parse(`"${v}"`) as string;
        return decoded;
      } catch (e) {
        return v;
      }
    }
    return v;
  }

  private static formatDate(ms: number): string {
    const d = new Date(ms);
    const mo = `${d.getMonth() + 1}`;
    const da = `${d.getDate()}`;
    return `${d.getFullYear()}-${mo.length < 2 ? '0' + mo : mo}-${da.length < 2 ? '0' + da : da}`;
  }

  /** 非 LOFTER 站点：解析页面里的站内 <a> 链接（带链接文字） */
  private static async anchors(url: string): Promise<LinkListResult> {
    const resp = await HttpFetch.getText(url, '');
    if (!resp.ok || resp.text.length === 0) {
      return { ok: false, note: resp.note.length > 0 ? resp.note : `HTTP ${resp.code}，页面没抓下来`, items: [] };
    }
    const root = HtmlParser.parse(resp.text);
    const nodes: HtmlNode[] = [];
    HtmlParser.findAll(root, 'a', nodes);
    const origin = WebList.originOf(url);
    const items: LinkItem[] = [];
    const seen = new Set<string>();
    for (let i = 0; i < nodes.length && items.length < MAX_LINKS; i++) {
      const href = nodes[i].attrs.get('href');
      if (href === undefined || href.length < 2 || href.startsWith('#') || href.indexOf('javascript:') === 0) {
        continue;
      }
      let abs = '';
      if (href.startsWith('http://') || href.startsWith('https://')) {
        abs = href;
      } else if (href.startsWith('/') && origin.length > 0) {
        abs = origin + href;
      } else {
        continue;
      }
      // 只留站内链接，外链对拼章节目录没意义
      if (WebList.hostOf(abs) !== WebList.hostOf(url)) {
        continue;
      }
      if (seen.has(abs)) {
        continue;
      }
      const text = HtmlParser.textOf(nodes[i]).trim();
      if (text.length === 0) {
        continue;
      }
      seen.add(abs);
      items.push({ title: text.substring(0, 80), url: abs, date: '', time: 0 });
    }
    if (items.length === 0) {
      return { ok: false, note: '页面里没有找到站内链接（可能要登录、或内容由 JS 动态生成）', items: [] };
    }
    return { ok: true, note: `列出 ${items.length} 条站内链接`, items: items };
  }

  private static originOf(url: string): string {
    const m = /^(https?:\/\/[^/]+)/.exec(url);
    return m !== null && m.length > 1 ? m[1] : '';
  }

  private static hostOf(url: string): string {
    const m = /^https?:\/\/([^/]+)/.exec(url);
    return m !== null && m.length > 1 ? m[1].toLowerCase() : '';
  }
}
