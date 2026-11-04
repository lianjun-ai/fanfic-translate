import { fileIo as fs } from '@kit.CoreFileKit';
import { Log } from '../common/Logger';
import { HtmlNode, HtmlParser } from '../parser/HtmlParser';
import { XhtmlConverter } from '../parser/XhtmlConverter';
import { ParsedParagraph } from '../parser/ParserTypes';
import { ParaType } from '../model/Models';

/**
 * 站点抓取规则引擎。
 *
 * 「壳 + 内嵌 JSON 数据」类站点（LOFTER、Next.js/Nuxt 系…）的正文都在
 * 静态源码里，只是每家的 JSON 结构不同。把「怎么抽」做成数据（规则表）
 * 而不是硬编码，找文模型就能用 manage_site_rules 自己适配新站：
 * debug_fetch 看结构 → 写规则 → 重试验证，全程不需要重新编译发版。
 *
 * 规则两种形态（可并存，JSON 优先）：
 * - 内嵌数据：marker 定位 JSON 起点，json_title / json_content 是点分路径；
 * - 元素定位：selector 定位正文容器（形如 tag.class / .class / #id / tag）。
 *
 * 内置规则不可删除，用户规则可增删、按 urlPattern 覆盖。
 */

export interface SiteRule {
  /** URL 子串匹配（indexOf），命中即用 */
  urlPattern: string;
  /** 内嵌 JSON 的定位标记，如 __initialize_data__；空串表示纯 selector 规则 */
  marker: string;
  /** 标题在 JSON 里的点分路径，如 postData.data.postData.postView.title */
  jsonTitle: string;
  /** 正文 HTML 在 JSON 里的点分路径 */
  jsonContent: string;
  /** 正文容器选择器，形如 div.post-content / .content / #main / article */
  selector: string;
  /** 无标题时取首段前 40 字当书名（LOFTER 帖子常态） */
  titleFromFirstParagraph: boolean;
  note: string;
  builtin: boolean;
}

export interface SiteRuleHit {
  rule: SiteRule;
  title: string;
  paragraphs: ParsedParagraph[];
}

/** 内置规则：LOFTER 帖子详情页 */
const BUILTIN_RULES: SiteRule[] = [
  {
    urlPattern: 'lofter.com/post', marker: '__initialize_data__',
    jsonTitle: 'postData.data.postData.postView.title',
    jsonContent: 'postData.data.postData.postView.textPostView.content',
    selector: '', titleFromFirstParagraph: true,
    note: 'LOFTER 帖子（内嵌数据）', builtin: true
  }
];

/** 内嵌数据常见标记：debug_fetch 体检报告用 */
export const EMBEDDED_MARKERS: string[] = [
  '__NEXT_DATA__', '__INITIAL_STATE__', '__NUXT__',
  '__INITIAL_DATA__', '__APP_DATA__', '__initialize_data__'
];

export class SiteRules {
  /** 用户规则存放目录（FinderAgent 回合开始时 init 一次） */
  private static dir: string = '';

  static init(filesDir: string): void {
    SiteRules.dir = filesDir;
  }

  private static filePath(): string {
    return `${SiteRules.dir}/site_rules.json`;
  }

  static loadUserRules(): SiteRule[] {
    if (SiteRules.dir.length === 0) {
      return [];
    }
    try {
      const raw = fs.readTextSync(SiteRules.filePath());
      const parsed = JSON.parse(raw) as SiteRule[];
      return Array.isArray(parsed) ? parsed : [];
    } catch (e) {
      return [];
    }
  }

  private static saveUserRules(rules: SiteRule[]): boolean {
    try {
      const file = fs.openSync(SiteRules.filePath(),
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, JSON.stringify(rules));
      } finally {
        fs.closeSync(file);
      }
      return true;
    } catch (e) {
      Log.w(`站点规则保存失败：${(e as Error).message}`);
      return false;
    }
  }

  static allRules(): SiteRule[] {
    // 用户规则在前：同 urlPattern 时用户改过的优先于内置
    return SiteRules.loadUserRules().concat(BUILTIN_RULES);
  }

  static match(url: string): SiteRule | null {
    if (url.length === 0) {
      return null;
    }
    const rules = SiteRules.allRules();
    for (let i = 0; i < rules.length; i++) {
      if (url.indexOf(rules[i].urlPattern) >= 0) {
        return rules[i];
      }
    }
    return null;
  }

  /** 按规则从页面源码抽标题 + 正文段落；抽不到返回 null */
  static extract(text: string, url: string): SiteRuleHit | null {
    const rule = SiteRules.match(url);
    if (rule === null) {
      return null;
    }
    return SiteRules.extractWithRule(text, rule);
  }

  static extractWithRule(text: string, rule: SiteRule): SiteRuleHit | null {
    if (rule.marker.length > 0 && rule.jsonContent.length > 0) {
      const hit = SiteRules.fromEmbeddedJson(text, rule);
      if (hit !== null) {
        return hit;
      }
    }
    if (rule.selector.length > 0) {
      const hit = SiteRules.fromSelector(text, rule);
      if (hit !== null) {
        return hit;
      }
    }
    return null;
  }

  private static fromEmbeddedJson(text: string, rule: SiteRule): SiteRuleHit | null {
    const json = SiteRules.extractJsonAfter(text, rule.marker);
    if (json === null) {
      return null;
    }
    let data: Object;
    try {
      data = JSON.parse(json) as Object;
    } catch (e) {
      Log.w(`站点规则 ${rule.urlPattern}：内嵌 JSON 解析失败`);
      return null;
    }
    let title = '';
    if (rule.jsonTitle.length > 0) {
      const t = SiteRules.getPath(data, rule.jsonTitle);
      title = typeof t === 'string' ? XhtmlConverter.normalizeSpace(t as string) : '';
    }
    const contentV = SiteRules.getPath(data, rule.jsonContent);
    const content = typeof contentV === 'string' ? contentV as string : '';
    if (content.length === 0) {
      return null;
    }
    const paragraphs = SiteRules.htmlToParagraphs(content);
    if (paragraphs.length === 0) {
      return null;
    }
    if (title.length === 0 && rule.titleFromFirstParagraph && paragraphs.length > 0) {
      title = SiteRules.firstText(paragraphs[0]).trim().substring(0, 40);
    }
    Log.i(`站点规则命中「${rule.note}」：${title.length > 0 ? title : '（无标题）'}`);
    return { rule: rule, title: title, paragraphs: paragraphs };
  }

  private static fromSelector(text: string, rule: SiteRule): SiteRuleHit | null {
    const root = HtmlParser.parse(text);
    const node = SiteRules.querySelector(root, rule.selector);
    if (node === null) {
      return null;
    }
    const paragraphs = XhtmlConverter.toParagraphs(node);
    if (paragraphs.length === 0) {
      return null;
    }
    let title = XhtmlConverter.firstHeadingText(node);
    if (title.length === 0 && rule.titleFromFirstParagraph) {
      title = SiteRules.firstText(paragraphs[0]).trim().substring(0, 40);
    }
    Log.i(`站点规则命中「${rule.note}」（selector）：${title.length > 0 ? title : '（无标题）'}`);
    return { rule: rule, title: title, paragraphs: paragraphs };
  }

  /**
   * 极简选择器：tag.class / .class / #id / tag#id / tag。
   * 自研 HTML 解析器没有 DOM API，这里按选择器语义在树上找第一个匹配节点。
   */
  private static querySelector(root: HtmlNode, selector: string): HtmlNode | null {
    const sel = selector.trim();
    if (sel.length === 0) {
      return null;
    }
    let tag = '';
    let cls = '';
    let id = '';
    const parts = sel.split('.');
    const head = parts[0];
    const idHash = head.indexOf('#');
    if (idHash >= 0) {
      tag = head.substring(0, idHash).trim().toLowerCase();
      id = head.substring(idHash + 1).trim();
    } else {
      tag = head.trim().toLowerCase();
    }
    if (parts.length > 1) {
      cls = parts[1].trim();
    }
    const out: HtmlNode[] = [];
    SiteRules.walkElements(root, out);
    for (let i = 0; i < out.length; i++) {
      const n = out[i];
      if (tag.length > 0 && n.tag !== tag) {
        continue;
      }
      if (id.length > 0 && n.attr('id') !== id) {
        continue;
      }
      if (cls.length > 0 && n.attr('class').split(/\s+/).indexOf(cls) < 0) {
        continue;
      }
      return n;
    }
    return null;
  }

  /** 深度优先收集所有元素节点（含 root 自身） */
  private static walkElements(node: HtmlNode, out: HtmlNode[]): void {
    if (!node.isText) {
      out.push(node);
    }
    for (let i = 0; i < node.children.length; i++) {
      SiteRules.walkElements(node.children[i], out);
    }
  }

  /** 正文 HTML → 段落：无块级标签时把 br 拆成独立 <p>，再滤掉空段 */
  private static htmlToParagraphs(content: string): ParsedParagraph[] {
    let html = content;
    if (html.indexOf('<p') < 0 && html.indexOf('<div') < 0) {
      html = `<p>${html.replace(/<br\s*\/?>/gi, '</p><p>')}</p>`;
    }
    let paragraphs: ParsedParagraph[] = [];
    try {
      paragraphs = XhtmlConverter.toParagraphs(HtmlParser.parse(html));
    } catch (e) {
      Log.w(`站点规则正文解析异常：${(e as Error).message}`);
      return [];
    }
    return paragraphs.filter((p): boolean => {
      if (p.type === ParaType.DIVIDER) {
        return true;
      }
      return SiteRules.firstText(p).trim().length > 0;
    });
  }

  private static firstText(p: ParsedParagraph): string {
    let s = '';
    for (let i = 0; i < p.runs.length; i++) {
      s += p.runs[i].text;
    }
    return s;
  }

  /**
   * 从 marker 之后抽出完整的顶层 JSON 对象。
   * 用括号配对而不是懒惰正则：正文里出现 </script> 或大括号也不会截断。
   */
  static extractJsonAfter(text: string, marker: string): string | null {
    const i = text.indexOf(marker);
    if (i < 0) {
      return null;
    }
    const start = text.indexOf('{', i);
    if (start < 0) {
      return null;
    }
    let depth = 0;
    let inStr = false;
    let esc = false;
    for (let j = start; j < text.length; j++) {
      const c = text.charAt(j);
      if (inStr) {
        if (esc) {
          esc = false;
        } else if (c === '\\') {
          esc = true;
        } else if (c === '"') {
          inStr = false;
        }
      } else if (c === '"') {
        inStr = true;
      } else if (c === '{') {
        depth++;
      } else if (c === '}') {
        depth--;
        if (depth === 0) {
          return text.substring(start, j + 1);
        }
      }
    }
    return null;
  }

  /** 点分路径取值，段可以是对象键或数组下标；取不到返回 null */
  static getPath(obj: Object, path: string): Object | null {
    let cur: Object | null = obj;
    const segs = path.split('.');
    for (let i = 0; i < segs.length; i++) {
      if (cur === null) {
        return null;
      }
      const seg = segs[i];
      if (Array.isArray(cur)) {
        const idx = parseInt(seg, 10);
        if (isNaN(idx) || idx < 0 || idx >= (cur as Object[]).length) {
          return null;
        }
        cur = (cur as Object[])[idx] as Object;
        continue;
      }
      const rec = cur as Record<string, Object>;
      const v = rec[seg];
      cur = v === undefined ? null : v as Object;
    }
    return cur;
  }

  /**
   * 内嵌 JSON 的结构速览：给 debug_fetch 用。
   * 输出形如「postData.data.postData.postView.title (字符串，6 字)」的路径清单，
   * 找文模型据此猜 json_title / json_content 的点分路径，不用看到整个 JSON。
   */
  static outline(obj: Object, out: string[], max: number): void {
    SiteRules.walkOutline(obj, '', 0, out, max);
  }

  private static walkOutline(obj: Object, prefix: string, depth: number, out: string[], max: number): void {
    if (depth > 4 || out.length >= max) {
      return;
    }
    const rec = obj as Record<string, Object>;
    let keys: string[] = [];
    try {
      keys = Object.keys(rec);
    } catch (e) {
      return;
    }
    for (let i = 0; i < keys.length; i++) {
      if (out.length >= max) {
        return;
      }
      const k = keys[i];
      let v: Object | null = null;
      try {
        v = rec[k] as Object;
      } catch (e) {
        continue;
      }
      const p = `${prefix}${k}`;
      if (typeof v === 'string') {
        const s = v as string;
        out.push(`${p} (字符串，${s.length} 字${s.length > 0 ? `：「${s.length > 24 ? `${s.substring(0, 24)}…` : s}」` : ''})`);
      } else if (typeof v === 'number' || typeof v === 'boolean') {
        out.push(`${p} = ${v}`);
      } else if (v === null || v === undefined) {
        out.push(`${p} = null`);
      } else if (Array.isArray(v)) {
        const arr = v as Object[];
        out.push(`${p} (数组，${arr.length} 项)`);
        if (arr.length > 0) {
          SiteRules.walkOutline(arr[0] as Object, `${p}.0.`, depth + 1, out, max);
        }
      } else if (typeof v === 'object') {
        out.push(`${p}.{…}`);
        SiteRules.walkOutline(v as Object, `${p}.`, depth + 1, out, max);
      }
    }
  }

  /** 页面源码里检测到哪些内嵌数据标记 */
  static markersIn(text: string): string[] {
    const found: string[] = [];
    for (let i = 0; i < EMBEDDED_MARKERS.length; i++) {
      if (text.indexOf(EMBEDDED_MARKERS[i]) >= 0) {
        found.push(EMBEDDED_MARKERS[i]);
      }
    }
    return found;
  }

  /** 新增或覆盖一条用户规则（按 urlPattern 去重），返回给模型的提示 */
  static addRule(urlPattern: string, marker: string, jsonTitle: string, jsonContent: string,
    selector: string, titleFromFirstParagraph: boolean, note: string): string {
    if (urlPattern.length === 0) {
      return 'url_pattern 不能为空';
    }
    if (marker.length > 0 && jsonContent.length === 0) {
      return '给了 marker 就必须给 json_content（正文在 JSON 里的路径）';
    }
    if (marker.length === 0 && selector.length === 0) {
      return 'marker + json_content 和 selector 至少要给一组，否则规则抽不到正文';
    }
    const user = SiteRules.loadUserRules();
    const rule: SiteRule = {
      urlPattern: urlPattern, marker: marker, jsonTitle: jsonTitle,
      jsonContent: jsonContent, selector: selector,
      titleFromFirstParagraph: titleFromFirstParagraph,
      note: note.length > 0 ? note : urlPattern, builtin: false
    };
    let replaced = false;
    for (let i = 0; i < user.length; i++) {
      if (user[i].urlPattern === urlPattern) {
        user[i] = rule;
        replaced = true;
        break;
      }
    }
    if (!replaced) {
      user.push(rule);
    }
    if (!SiteRules.saveUserRules(user)) {
      return '规则保存失败（写文件出错）';
    }
    return replaced ? `已覆盖规则「${urlPattern}」，下次抓取立即生效` : `已添加规则「${urlPattern}」，下次抓取立即生效`;
  }

  static removeRule(urlPattern: string): string {
    const user = SiteRules.loadUserRules();
    const kept: SiteRule[] = [];
    let removed = false;
    for (let i = 0; i < user.length; i++) {
      if (user[i].urlPattern === urlPattern) {
        removed = true;
      } else {
        kept.push(user[i]);
      }
    }
    if (!removed) {
      return `没有找到自定义规则「${urlPattern}」（内置规则不可删除）`;
    }
    if (!SiteRules.saveUserRules(kept)) {
      return '规则保存失败（写文件出错）';
    }
    return `已删除规则「${urlPattern}」`;
  }
}
