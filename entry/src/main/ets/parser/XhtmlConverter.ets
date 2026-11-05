import { HtmlNode, HtmlParser } from './HtmlParser';
import { ParsedParagraph } from './ParserTypes';
import { ParaType, Run, plainRun, runsToPlainText } from '../model/Models';

class Style {
  bold: boolean;
  italic: boolean;
  underline: boolean;
  strike: boolean;

  constructor(bold: boolean, italic: boolean, underline: boolean, strike: boolean) {
    this.bold = bold;
    this.italic = italic;
    this.underline = underline;
    this.strike = strike;
  }

  static base(): Style {
    return new Style(false, false, false, false);
  }

  copy(): Style {
    return new Style(this.bold, this.italic, this.underline, this.strike);
  }

  sameAs(o: Style): boolean {
    return this.bold === o.bold && this.italic === o.italic &&
      this.underline === o.underline && this.strike === o.strike;
  }
}

/** 段落级块元素 */
const BLOCK_TAGS: string[] = [
  'p', 'div', 'section', 'article', 'blockquote', 'li', 'pre',
  'figcaption', 'dd', 'dt', 'td', 'th', 'center'
];

/** 标题元素 */
const HEADING_TAGS: string[] = ['h1', 'h2', 'h3', 'h4', 'h5', 'h6'];

/** 整体丢弃的元素：不影响正文语义 */
const SKIP_TAGS: string[] = [
  'script', 'style', 'head', 'nav', 'noscript', 'svg', 'iframe',
  'button', 'form', 'select', 'input', 'textarea', 'template'
];

/** 行内强调标签 → 样式标记 */
const ITALIC_TAGS: string[] = ['em', 'i', 'cite', 'var', 'dfn'];
const BOLD_TAGS: string[] = ['strong', 'b'];
const UNDERLINE_TAGS: string[] = ['u', 'ins'];
const STRIKE_TAGS: string[] = ['s', 'del', 'strike'];

const DIVIDER_RE = new RegExp('^[*\\-—–·#=~•_.\\s]{3,}$');

/**
 * XHTML → 段落数组。
 * 输出的每个段落都带 Run[]，斜体/加粗在解析阶段就被记录下来，
 * 后续无论是渲染原文还是注入译文，样式分布都不会丢。
 */
export class XhtmlConverter {
  static toParagraphs(root: HtmlNode): ParsedParagraph[] {
    const out: ParsedParagraph[] = [];
    const body = HtmlParser.findFirst(root, 'body');
    const scope: HtmlNode = body === null ? root : body;
    XhtmlConverter.walk(scope, out);
    return out;
  }

  /** 首个标题作为章节名，没有则返回空串 */
  static firstHeadingText(root: HtmlNode): string {
    for (let i = 0; i < HEADING_TAGS.length; i++) {
      const h = HtmlParser.findFirst(root, HEADING_TAGS[i]);
      if (h !== null) {
        const t = XhtmlConverter.normalizeSpace(HtmlParser.textOf(h));
        if (t.length > 0) {
          return t;
        }
      }
    }
    return '';
  }

  private static walk(node: HtmlNode, out: ParsedParagraph[]): void {
    for (let i = 0; i < node.children.length; i++) {
      const child = node.children[i];
      if (child.isText) {
        const t = XhtmlConverter.normalizeSpace(child.text);
        if (t.length > 0) {
          const p: ParsedParagraph = { type: ParaType.TEXT, runs: [plainRun(t)] };
          out.push(p);
        }
        continue;
      }

      const tag = child.tag;
      if (SKIP_TAGS.indexOf(tag) >= 0) {
        continue;
      }
      if (tag === 'hr') {
        XhtmlConverter.pushDivider(out);
        continue;
      }
      if (HEADING_TAGS.indexOf(tag) >= 0) {
        const runs: Run[] = [];
        XhtmlConverter.flatten(child, Style.base(), runs);
        if (runs.length > 0) {
          const hp: ParsedParagraph = { type: ParaType.HEADING, runs: runs };
          out.push(hp);
        }
        continue;
      }
      if (BLOCK_TAGS.indexOf(tag) >= 0) {
        if (XhtmlConverter.hasBlockChild(child)) {
          // div 套 p 这类包装层：下钻，避免整块被压成一段
          XhtmlConverter.walk(child, out);
        } else {
          const runs: Run[] = [];
          XhtmlConverter.flatten(child, Style.base(), runs);
          if (runs.length === 0) {
            continue;
          }
          // 老式页面用 <br><br> 当段落分隔（晋江整章都在一个 div 里，130 个 <br>），
          // 只把 <br> 变成换行符会把整章压成一段：译文成一大块、阅读视图也不分段。
          // 这里按换行切开，每段独立成段。
          const groups = XhtmlConverter.splitByBreak(runs);
          for (let g = 0; g < groups.length; g++) {
            const grp = groups[g];
            const text = XhtmlConverter.normalizeSpace(runsToPlainText(grp));
            if (text.length === 0) {
              continue;
            }
            if (DIVIDER_RE.test(text) && text.length <= 40) {
              XhtmlConverter.pushDivider(out);
              continue;
            }
            const bp: ParsedParagraph = { type: ParaType.TEXT, runs: grp };
            out.push(bp);
          }
        }
        continue;
      }

      // 行内元素或未知容器：继续下钻
      XhtmlConverter.walk(child, out);
    }
  }

  private static hasBlockChild(node: HtmlNode): boolean {
    for (let i = 0; i < node.children.length; i++) {
      const c = node.children[i];
      if (c.isText) {
        continue;
      }
      if (BLOCK_TAGS.indexOf(c.tag) >= 0 || HEADING_TAGS.indexOf(c.tag) >= 0 && c.tag !== node.tag) {
        return true;
      }
      if (SKIP_TAGS.indexOf(c.tag) < 0 && XhtmlConverter.hasBlockChild(c)) {
        return true;
      }
    }
    return false;
  }

  /**
   * 按 <br> 产生的换行把 Run[] 切成多组，每组一段。
   * 样式随片段带走，切段不丢加粗/斜体。
   */
  private static splitByBreak(runs: Run[]): Run[][] {
    const groups: Run[][] = [];
    let cur: Run[] = [];
    for (let i = 0; i < runs.length; i++) {
      const r = runs[i];
      const segs = r.text.split('\n');
      for (let s = 0; s < segs.length; s++) {
        if (s > 0) {
          groups.push(cur);
          cur = [];
        }
        if (segs[s].length === 0) {
          continue;
        }
        const nr: Run = {
          text: segs[s], bold: r.bold, italic: r.italic,
          underline: r.underline, strike: r.strike
        };
        cur.push(nr);
      }
    }
    groups.push(cur);
    return groups;
  }

  /** 把一个块内的行内内容拍平成 Run[] */
  private static flatten(node: HtmlNode, style: Style, out: Run[]): void {
    for (let i = 0; i < node.children.length; i++) {
      const child = node.children[i];
      if (child.isText) {
        XhtmlConverter.pushText(out, style, child.text);
        continue;
      }
      const tag = child.tag;
      if (SKIP_TAGS.indexOf(tag) >= 0) {
        continue;
      }
      if (tag === 'br') {
        XhtmlConverter.pushBreak(out, style);
        continue;
      }
      const next = style.copy();
      if (ITALIC_TAGS.indexOf(tag) >= 0) {
        next.italic = true;
      } else if (BOLD_TAGS.indexOf(tag) >= 0) {
        next.bold = true;
      } else if (UNDERLINE_TAGS.indexOf(tag) >= 0) {
        next.underline = true;
      } else if (STRIKE_TAGS.indexOf(tag) >= 0) {
        next.strike = true;
      }
      XhtmlConverter.flatten(child, next, out);
    }
  }

  /** 空白归一 + 同样式片段合并，避免产生大量零碎片段 */
  private static pushText(out: Run[], style: Style, raw: string): void {
    if (raw.length === 0) {
      return;
    }
    const collapsed = raw.indexOf('\n') >= 0 && raw.trim().length === 0
      ? ' '
      : raw.replace(/[\r\n\t]+/g, ' ').replace(/ {2,}/g, ' ');
    if (collapsed.length === 0) {
      return;
    }
    if (out.length > 0) {
      const last = out[out.length - 1];
      if (last.bold === style.bold && last.italic === style.italic &&
        last.underline === style.underline && last.strike === style.strike) {
        last.text += collapsed;
        return;
      }
    }
    out.push({
      text: collapsed,
      bold: style.bold,
      italic: style.italic,
      underline: style.underline,
      strike: style.strike
    });
  }

  static normalizeSpace(s: string): string {
    return s.replace(/[\s\u00A0]+/g, ' ').trim();
  }

  /** 连续分隔符（<hr/> 与 "* * *" 相邻）只保留一个 */
  private static pushDivider(out: ParsedParagraph[]): void {
    if (out.length === 0) {
      return;
    }
    if (out[out.length - 1].type === ParaType.DIVIDER) {
      return;
    }
    const p: ParsedParagraph = { type: ParaType.DIVIDER, runs: [plainRun('* * *')] };
    out.push(p);
  }

  /** <br> 保留为真正的换行：诗歌、歌词类排版依赖它 */
  private static pushBreak(out: Run[], style: Style): void {
    if (out.length === 0) {
      return;
    }
    const last = out[out.length - 1];
    if (last.bold === style.bold && last.italic === style.italic &&
      last.underline === style.underline && last.strike === style.strike) {
      last.text += '\n';
      return;
    }
    out.push({
      text: '\n',
      bold: style.bold,
      italic: style.italic,
      underline: style.underline,
      strike: style.strike
    });
  }
}
