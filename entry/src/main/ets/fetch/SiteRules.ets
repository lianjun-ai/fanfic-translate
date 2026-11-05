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
 *   加 all: 前缀（如 all:div.content）收集全部匹配容器并按文档顺序拼接，
 *   用于贴吧这类每层楼正文各占一个容器的页面。
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

/** 内置规则 */
const BUILTIN_RULES: SiteRule[] = [
  {
    urlPattern: 'lofter.com/post', marker: '__initialize_data__',
    jsonTitle: 'postData.data.postData.postView.title',
    jsonContent: 'postData.data.postData.postView.textPostView.content',
    selector: '', titleFromFirstParagraph: true,
    note: 'LOFTER 帖子（内嵌数据）', builtin: true
  },
  {
    // 晋江整章都塞在一个 div 里，用 <br><br> 分段；body 里其余全是导航、
    // 作者推文、打赏面板、长评和页脚。真机导出的一章 238 段里只有 1 段是正文。
    urlPattern: 'jjwxc.net/onebook.php', marker: '',
    jsonTitle: '', jsonContent: '',
    selector: '#paragraph_comment_content', titleFromFirstParagraph: false,
    note: '晋江章节页（正文容器）', builtin: true
  },
  {
    // B 站专栏正文在 .opus-module-content 里；容器外是「关注」「下载 App」、
    // 标签和「热门评论」，这些以前会跟着正文一起进书。
    // 注意：/read/cv{id} 现在常 302 到 /read/mobile 的 JS 壳，那时这条规则抽不到，
    // 该走下面的接口规则。
    urlPattern: 'bilibili.com/read/', marker: '',
    jsonTitle: '', jsonContent: '',
    selector: 'div.opus-module-content', titleFromFirstParagraph: false,
    note: 'B站专栏（正文容器）', builtin: true
  },
  {
    // 真机验证过：模型自己用 http_probe 探通了这个接口（HTTP 200，data.content 全文），
    // 但它当时是手写规则才用上的。直接内置成接口规则，html_to_book 拿到接口地址就能取正文。
    // 接口偶发 -509 限流，那时 JSON 里没有 data.content，会按「接口里没取到正文」报失败。
    urlPattern: 'api.bilibili.com/x/article/view', marker: '"data":',
    jsonTitle: 'data.title', jsonContent: 'data.content',
    selector: '', titleFromFirstParagraph: false,
    note: 'B站专栏接口（JSON）', builtin: true
  },
  {
    // 贴吧帖子（触屏版）：每层楼的正文在独立的 div.content 里，作者/时间/
    // 「操作/收藏 回复 举报」按钮和楼中楼都在容器外，所以单靠通用清洗总会
    // 混进楼层壳 —— 必须用 all: 前缀收集全部楼层容器（真机 wap 页 30 层验证无泄漏）。
    // /p/ 直抓常被百度安全验证拦，wap 版 /mo/m?kz={帖子id} 免验证，两版模板相同。
    urlPattern: 'tieba.baidu.com', marker: '', jsonTitle: '', jsonContent: '',
    selector: 'all:div.content', titleFromFirstParagraph: false,
    note: '百度贴吧帖子（每层楼一个容器）', builtin: true
  },
  {
    // 贴吧还有一套桌面/触屏老模板，楼层正文容器叫 d_post_content
    // （class 里常带 j_d_post_content）。抽不到就换这条，见 extract 的逐条试逻辑。
    urlPattern: 'tieba.baidu.com', marker: '', jsonTitle: '', jsonContent: '',
    selector: 'all:div.d_post_content', titleFromFirstParagraph: false,
    note: '百度贴吧帖子（d_post_content 容器）', builtin: true
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

  /* ---------- 临时停用 ---------- */

  /**
   * 被临时停用的 urlPattern 清单（单独存一个文件，不动规则本体）。
   *
   * 存在的理由：内置规则会让我们看不到「模型自己能不能解决」——
   * 想验证自愈能力（debug_fetch → 写规则 → 验证）或排查某条规则是不是
   * 唯一依赖时，必须先把它停掉，事后再恢复。删掉内置规则做不到这件事
   * （内置规则不可删除），所以单独记一份停用名单。
   */
  private static disabledPath(): string {
    return `${SiteRules.dir}/site_rules_off.json`;
  }

  static loadDisabled(): string[] {
    if (SiteRules.dir.length === 0) {
      return [];
    }
    try {
      const raw = fs.readTextSync(SiteRules.disabledPath());
      const parsed = JSON.parse(raw) as string[];
      return Array.isArray(parsed) ? parsed : [];
    } catch (e) {
      return [];
    }
  }

  private static saveDisabled(list: string[]): boolean {
    try {
      const file = fs.openSync(SiteRules.disabledPath(),
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, JSON.stringify(list));
      } finally {
        fs.closeSync(file);
      }
      return true;
    } catch (e) {
      Log.w(`停用名单保存失败：${(e as Error).message}`);
      return false;
    }
  }

  static isDisabled(urlPattern: string): boolean {
    return SiteRules.loadDisabled().indexOf(urlPattern) >= 0;
  }

  /** 停用 / 恢复某条规则，返回给模型的提示 */
  static setEnabled(urlPattern: string, enabled: boolean): string {
    const exists = SiteRules.allRules().filter((r): boolean => r.urlPattern === urlPattern).length > 0;
    if (!exists) {
      return `没有 url_pattern 为「${urlPattern}」的规则，先用 action=list 看一下现有规则`;
    }
    const off = SiteRules.loadDisabled();
    const at = off.indexOf(urlPattern);
    if (enabled) {
      if (at < 0) {
        return `规则「${urlPattern}」本来就是启用状态`;
      }
      off.splice(at, 1);
      if (!SiteRules.saveDisabled(off)) {
        return '停用名单保存失败（写文件出错）';
      }
      return `已恢复规则「${urlPattern}」，下次抓取立即生效`;
    }
    if (at >= 0) {
      return `规则「${urlPattern}」已经是停用状态`;
    }
    off.push(urlPattern);
    if (!SiteRules.saveDisabled(off)) {
      return '停用名单保存失败（写文件出错）';
    }
    return `已停用规则「${urlPattern}」：这个站接下来会走通用解析（直抓 → 渲染），内置规则不再替它兜底`;
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
    const off = SiteRules.loadDisabled();
    for (let i = 0; i < rules.length; i++) {
      if (url.indexOf(rules[i].urlPattern) >= 0 && off.indexOf(rules[i].urlPattern) < 0) {
        return rules[i];
      }
    }
    return null;
  }

  /** 所有匹配的启用规则（用户规则优先）。同一个站的不同模板各写一条，
   *  抽取时按顺序试，能兼容「同一站有多个页面模板」的情况。 */
  static matchAll(url: string): SiteRule[] {
    const out: SiteRule[] = [];
    if (url.length === 0) {
      return out;
    }
    const rules = SiteRules.allRules();
    const off = SiteRules.loadDisabled();
    for (let i = 0; i < rules.length; i++) {
      if (url.indexOf(rules[i].urlPattern) >= 0 && off.indexOf(rules[i].urlPattern) < 0) {
        out.push(rules[i]);
      }
    }
    return out;
  }

  /** 按规则从页面源码抽标题 + 正文段落；抽不到返回 null */
  static extract(text: string, url: string): SiteRuleHit | null {
    // 逐个试，而不是只试第一条：同站多模板时（如贴吧 wap 版和触屏版
    // 正文容器不同），第一条不命中要让后面的规则有机会兜住。
    const rules = SiteRules.matchAll(url);
    for (let i = 0; i < rules.length; i++) {
      const hit = SiteRules.extractWithRule(text, rules[i]);
      if (hit !== null) {
        return hit;
      }
    }
    return null;
  }

  static extractWithRule(text: string, rule: SiteRule): SiteRuleHit | null {
    // jsonContent 有值就试 JSON 抽取：接口响应靠整份解析，页面靠 marker 定位，
    // 两种情况都走 fromEmbeddedJson（里面按顺序试两个根对象）。
    if (rule.jsonContent.length > 0) {
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

  /**
   * 从两种来源里取 JSON 根对象，按顺序试：
   * ① 整个响应本身就是 JSON（站点接口返回，如 api.bilibili.com/x/article/view）——
   *    这时路径是相对顶层写的（data.content），不能按 marker 截断，否则会从
   *    data 子对象开始解析，data.content 反而找不到；
   * ② 页面源码里内嵌的 JSON（LOFTER 那类，按 marker 定位起点）。
   */
  private static fromEmbeddedJson(text: string, rule: SiteRule): SiteRuleHit | null {
    const roots: Object[] = [];
    const trimmed = text.trim();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        roots.push(JSON.parse(trimmed) as Object);
      } catch (e) {
        Log.w(`站点规则 ${rule.urlPattern}：响应声明是 JSON 但解析失败`);
      }
    }
    if (rule.marker.length > 0) {
      const json = SiteRules.extractJsonAfter(text, rule.marker);
      if (json !== null) {
        try {
          roots.push(JSON.parse(json) as Object);
        } catch (e) {
          Log.w(`站点规则 ${rule.urlPattern}：内嵌 JSON 解析失败`);
        }
      }
    }
    for (let i = 0; i < roots.length; i++) {
      const hit = SiteRules.hitFromRoot(roots[i], rule);
      if (hit !== null) {
        return hit;
      }
    }
    return null;
  }

  /** 按规则里的点分路径从某个 JSON 根对象里抽标题 + 正文 */
  private static hitFromRoot(data: Object, rule: SiteRule): SiteRuleHit | null {
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
    const nodes = SiteRules.querySelectorAll(root, rule.selector);
    if (nodes.length === 0) {
      return null;
    }
    // 多容器（all: 前缀）按文档顺序拼接：贴吧这类每层楼一个容器的页面，
    // 单容器选择器只能拿到第一层楼。
    let paragraphs: ParsedParagraph[] = [];
    for (let i = 0; i < nodes.length; i++) {
      paragraphs = paragraphs.concat(XhtmlConverter.toParagraphs(nodes[i]));
    }
    if (paragraphs.length === 0) {
      return null;
    }
    let title = XhtmlConverter.firstHeadingText(nodes[0]);
    if (title.length === 0 && rule.titleFromFirstParagraph) {
      title = SiteRules.firstText(paragraphs[0]).trim().substring(0, 40);
    }
    Log.i(`站点规则命中「${rule.note}」（selector，${nodes.length} 个容器）：${title.length > 0 ? title : '（无标题）'}`);
    return { rule: rule, title: title, paragraphs: paragraphs };
  }

  /**
   * 极简选择器：tag.class / .class / #id / tag#id / tag。
   * 加 all: 前缀（如 all:div.content）收集全部匹配节点（文档顺序），
   * 否则只返回第一个匹配。自研 HTML 解析器没有 DOM API，这里按选择器语义在树上找。
   */
  private static querySelectorAll(root: HtmlNode, selector: string): HtmlNode[] {
    const out: HtmlNode[] = [];
    const sel = selector.trim();
    if (sel.length === 0) {
      return out;
    }
    let body = sel;
    if (body.startsWith('all:')) {
      body = body.substring(4).trim();
    }
    let tag = '';
    let cls = '';
    let id = '';
    const parts = body.split('.');
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
    const walk: HtmlNode[] = [];
    SiteRules.walkElements(root, walk);
    for (let i = 0; i < walk.length; i++) {
      const n = walk[i];
      if (tag.length > 0 && n.tag !== tag) {
        continue;
      }
      if (id.length > 0 && n.attr('id') !== id) {
        continue;
      }
      if (cls.length > 0 && n.attr('class').split(/\s+/).indexOf(cls) < 0) {
        continue;
      }
      out.push(n);
      if (!sel.startsWith('all:')) {
        break;
      }
    }
    return out;
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

  /**
   * 内嵌 JSON 里最长的字符串长度。
   *
   * 用来区分两种「有标记但抽不到正文」：
   * - 标记里确实藏着正文（LOFTER 型，几万字）→ 值得写规则；
   * - 标记里只有标题、封面这类元信息（B 站专栏型，几十字）→ 正文是接口取的
   *   真 CSR，写规则怎么写都没用，只能走渲染。这个数字能让模型一次看明白。
   */
  static maxStrLen(obj: Object, depth: number): number {
    if (depth > 6) {
      return 0;
    }
    if (typeof obj === 'string') {
      return (obj as string).length;
    }
    let best = 0;
    if (Array.isArray(obj)) {
      const arr = obj as Object[];
      for (let i = 0; i < arr.length && i < 40; i++) {
        const n = SiteRules.maxStrLen(arr[i] as Object, depth + 1);
        if (n > best) {
          best = n;
        }
      }
      return best;
    }
    if (typeof obj === 'object' && obj !== null) {
      let keys: string[] = [];
      try {
        keys = Object.keys(obj as Record<string, Object>);
      } catch (e) {
        return 0;
      }
      for (let i = 0; i < keys.length && i < 60; i++) {
        let v: Object | null = null;
        try {
          v = (obj as Record<string, Object>)[keys[i]] as Object;
        } catch (e) {
          continue;
        }
        if (v === null || v === undefined) {
          continue;
        }
        const n = SiteRules.maxStrLen(v, depth + 1);
        if (n > best) {
          best = n;
        }
      }
    }
    return best;
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
