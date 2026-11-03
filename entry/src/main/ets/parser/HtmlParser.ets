/**
 * 轻量 HTML/XHTML 分词与建树。
 *
 * 为什么不用三方库：ArkTS 侧没有 DOMParser，而 epub 里的 XHTML 与抓取到的
 * HTML 结构都相当规整。一个约两百行的分词器足够，且能完全控制"哪个标签
 * 映射成哪种行内样式"，这是后续译文保真的前提。
 */
export class HtmlNode {
  tag: string;
  attrs: Map<string, string>;
  children: HtmlNode[];
  text: string;
  isText: boolean;

  constructor(tag: string, attrs: Map<string, string>, text: string, isText: boolean) {
    this.tag = tag;
    this.attrs = attrs;
    this.children = [];
    this.text = text;
    this.isText = isText;
  }

  attr(name: string): string {
    const v = this.attrs.get(name);
    return v === undefined ? '' : v;
  }
}

const VOID_TAGS: string[] = [
  'area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input',
  'link', 'meta', 'param', 'source', 'track', 'wbr'
];

const RAW_TEXT_TAGS: string[] = ['script', 'style'];

const ENTITY_MAP: Map<string, string> = new Map<string, string>([
  ['amp', '&'], ['lt', '<'], ['gt', '>'], ['quot', '"'], ['apos', "'"],
  ['nbsp', ' '], ['mdash', '—'], ['ndash', '–'], ['hellip', '…'],
  ['ldquo', '“'], ['rdquo', '”'], ['lsquo', '‘'], ['rsquo', '’'],
  ['copy', '©'], ['reg', '®'], ['trade', '™'], ['deg', '°'],
  ['laquo', '«'], ['raquo', '»'], ['middot', '·'], ['bull', '•'],
  ['times', '×'], ['divide', '÷'], ['eacute', 'é'], ['egrave', 'è'],
  ['agrave', 'à'], ['ccedil', 'ç'], ['uuml', 'ü'], ['ouml', 'ö'],
  ['auml', 'ä'], ['szlig', 'ß'], ['aacute', 'á'], ['iacute', 'í'],
  ['oacute', 'ó'], ['uacute', 'ú'], ['ntilde', 'ñ'], ['thinsp', ' '],
  ['ensp', ' '], ['emsp', ' '], ['zwsp', ''], ['shy', '']
]);

export class HtmlParser {
  static isVoid(tag: string): boolean {
    return VOID_TAGS.indexOf(tag) >= 0;
  }

  static parse(html: string): HtmlNode {
    const root = new HtmlNode('#root', new Map<string, string>(), '', false);
    const stack: HtmlNode[] = [root];
    let i = 0;
    const n = html.length;

    while (i < n) {
      const lt = html.indexOf('<', i);
      if (lt < 0) {
        HtmlParser.appendText(stack, html.substring(i));
        break;
      }
      if (lt > i) {
        HtmlParser.appendText(stack, html.substring(i, lt));
      }

      // 注释
      if (html.startsWith('<!--', lt)) {
        const end = html.indexOf('-->', lt);
        i = end < 0 ? n : end + 3;
        continue;
      }
      // CDATA
      if (html.startsWith('<![CDATA[', lt)) {
        const end = html.indexOf(']]>', lt);
        if (end < 0) {
          break;
        }
        HtmlParser.appendRaw(stack, html.substring(lt + 9, end));
        i = end + 3;
        continue;
      }
      // DOCTYPE / 处理指令
      if (html.startsWith('<!', lt) || html.startsWith('<?', lt)) {
        const end = html.indexOf('>', lt);
        i = end < 0 ? n : end + 1;
        continue;
      }

      const gt = HtmlParser.findTagEnd(html, lt + 1);
      if (gt < 0) {
        HtmlParser.appendText(stack, html.substring(lt));
        break;
      }
      const raw = html.substring(lt + 1, gt);
      i = gt + 1;

      if (raw.length === 0) {
        continue;
      }
      if (raw.charAt(0) === '/') {
        HtmlParser.closeTag(stack, raw.substring(1).trim().toLowerCase());
        continue;
      }

      const selfClose = raw.charAt(raw.length - 1) === '/';
      const body = selfClose ? raw.substring(0, raw.length - 1) : raw;
      const tagName = HtmlParser.readTagName(body);
      if (tagName.length === 0) {
        continue;
      }
      const attrs = HtmlParser.readAttrs(body, tagName.length);
      const node = new HtmlNode(tagName, attrs, '', false);
      stack[stack.length - 1].children.push(node);

      // script / style 内容整体跳过，不参与正文
      if (RAW_TEXT_TAGS.indexOf(tagName) >= 0) {
        const closeIdx = html.toLowerCase().indexOf('</' + tagName, i);
        i = closeIdx < 0 ? n : closeIdx;
        continue;
      }

      if (!selfClose && !HtmlParser.isVoid(tagName)) {
        stack.push(node);
      }
    }
    return root;
  }

  /** 找标签结束的 '>'，跳过属性值引号内的内容 */
  private static findTagEnd(s: string, from: number): number {
    let quote = '';
    for (let i = from; i < s.length; i++) {
      const c = s.charAt(i);
      if (quote.length > 0) {
        if (c === quote) {
          quote = '';
        }
      } else if (c === '"' || c === "'") {
        quote = c;
      } else if (c === '>') {
        return i;
      }
    }
    return -1;
  }

  private static readTagName(body: string): string {
    let i = 0;
    while (i < body.length) {
      const c = body.charAt(i);
      if (c === ' ' || c === '\t' || c === '\n' || c === '\r' || c === '/') {
        break;
      }
      i++;
    }
    return body.substring(0, i).toLowerCase();
  }

  private static readAttrs(body: string, from: number): Map<string, string> {
    const map = new Map<string, string>();
    let i = from;
    const n = body.length;
    while (i < n) {
      while (i < n && HtmlParser.isSpace(body.charAt(i))) {
        i++;
      }
      if (i >= n) {
        break;
      }
      let start = i;
      while (i < n) {
        const c = body.charAt(i);
        if (c === '=' || HtmlParser.isSpace(c)) {
          break;
        }
        i++;
      }
      const name = body.substring(start, i).toLowerCase();
      while (i < n && HtmlParser.isSpace(body.charAt(i))) {
        i++;
      }
      if (i < n && body.charAt(i) === '=') {
        i++;
        while (i < n && HtmlParser.isSpace(body.charAt(i))) {
          i++;
        }
        let value = '';
        if (i < n) {
          const q = body.charAt(i);
          if (q === '"' || q === "'") {
            i++;
            start = i;
            while (i < n && body.charAt(i) !== q) {
              i++;
            }
            value = body.substring(start, i);
            i++;
          } else {
            start = i;
            while (i < n && !HtmlParser.isSpace(body.charAt(i))) {
              i++;
            }
            value = body.substring(start, i);
          }
        }
        if (name.length > 0) {
          map.set(name, HtmlParser.decodeEntities(value));
        }
      } else if (name.length > 0) {
        map.set(name, '');
      }
    }
    return map;
  }

  private static isSpace(c: string): boolean {
    return c === ' ' || c === '\t' || c === '\n' || c === '\r' || c === '\f';
  }

  private static closeTag(stack: HtmlNode[], name: string): void {
    for (let i = stack.length - 1; i > 0; i--) {
      if (stack[i].tag === name) {
        stack.length = i;
        return;
      }
    }
  }

  private static appendText(stack: HtmlNode[], raw: string): void {
    if (raw.length === 0) {
      return;
    }
    HtmlParser.appendRaw(stack, HtmlParser.decodeEntities(raw));
  }

  private static appendRaw(stack: HtmlNode[], text: string): void {
    if (text.length === 0) {
      return;
    }
    const parent = stack[stack.length - 1];
    const last = parent.children.length > 0 ? parent.children[parent.children.length - 1] : null;
    if (last !== null && last.isText) {
      last.text += text;
      return;
    }
    parent.children.push(new HtmlNode('#text', new Map<string, string>(), text, true));
  }

  /** 手写实体解码：ArkTS 的 replace 回调签名受限，扫描更稳 */
  static decodeEntities(s: string): string {
    if (s.indexOf('&') < 0) {
      return s;
    }
    let out = '';
    let i = 0;
    const n = s.length;
    while (i < n) {
      const c = s.charAt(i);
      if (c !== '&') {
        out += c;
        i++;
        continue;
      }
      const semi = s.indexOf(';', i + 1);
      if (semi < 0 || semi - i > 12) {
        out += c;
        i++;
        continue;
      }
      const token = s.substring(i + 1, semi);
      let replaced = '';
      let ok = false;
      if (token.charAt(0) === '#') {
        let code = -1;
        if (token.charAt(1) === 'x' || token.charAt(1) === 'X') {
          code = parseInt(token.substring(2), 16);
        } else {
          code = parseInt(token.substring(1), 10);
        }
        if (!isNaN(code) && code > 0) {
          replaced = String.fromCharCode(code);
          ok = true;
        }
      } else {
        const v = ENTITY_MAP.get(token);
        if (v !== undefined) {
          replaced = v;
          ok = true;
        }
      }
      if (ok) {
        out += replaced;
        i = semi + 1;
      } else {
        out += c;
        i++;
      }
    }
    return out;
  }

  /** 深度优先查找首个满足条件的节点 */
  static findFirst(node: HtmlNode, tagName: string): HtmlNode | null {
    if (node.tag === tagName) {
      return node;
    }
    for (let i = 0; i < node.children.length; i++) {
      const r = HtmlParser.findFirst(node.children[i], tagName);
      if (r !== null) {
        return r;
      }
    }
    return null;
  }

  /** 查找全部同名节点 */
  static findAll(node: HtmlNode, tagName: string, out: HtmlNode[]): void {
    if (node.tag === tagName) {
      out.push(node);
    }
    for (let i = 0; i < node.children.length; i++) {
      HtmlParser.findAll(node.children[i], tagName, out);
    }
  }

  /** 取节点全部纯文本 */
  static textOf(node: HtmlNode): string {
    if (node.isText) {
      return node.text;
    }
    let s = '';
    for (let i = 0; i < node.children.length; i++) {
      s += HtmlParser.textOf(node.children[i]);
    }
    return s;
  }
}
