import { ParaType, Paragraph, parseRuns, runsToPlainText } from '../model/Models';

/** 一个待翻译的段落及其纯文本 */
export interface Segment {
  paragraph: Paragraph;
  text: string;
}

/**
 * 分批器。
 *
 * 一段一请求是 token 灾难：五十章的书会变成几千次 HTTP 往返，
 * 每次都要重传系统提示词。按 ~1200 token 分组后请求数降一个数量级，
 * 而且同一组内的段落天然共享上下文，译名更容易统一。
 *
 * 上限还有第二重意义：组太大，模型越容易漏段、串号。
 * 所以除了 token 阈值，还额外限制每组段数。
 */
export class Chunker {
  /**
   * 单批段落数上限。
   * 对话密集的同人段落常常只有十来个 token，纯按 token 分组会让每批
   * 只装十几段，系统提示词的开销反而超过正文。上限放到 40 段，
   * 让短段落也能把预算用满；偶尔漏段由补翻兜住。
   */
  static readonly MAX_ITEMS: number = 40;

  /**
   * 粗略估算 token 数。不需要精确 —— 只要量级对，分批就是对的。
   * 中日韩字符按 1.1 计（多数分词器在 0.6~1.5 之间），其余按 4 字符 1 token。
   */
  static estimate(text: string): number {
    let cjk = 0;
    let other = 0;
    for (let i = 0; i < text.length; i++) {
      const c = text.charCodeAt(i);
      if ((c >= 0x2E80 && c <= 0x9FFF) || (c >= 0xF900 && c <= 0xFAFF) || (c >= 0xFF00 && c <= 0xFF60)) {
        cjk++;
      } else {
        other++;
      }
    }
    return Math.ceil(cjk * 1.1 + other / 4) + 1;
  }

  /** 取出需要翻译的段落：分隔符与空段落跳过 */
  static segments(paras: Paragraph[]): Segment[] {
    const out: Segment[] = [];
    for (let i = 0; i < paras.length; i++) {
      const p = paras[i];
      if (p.type === ParaType.DIVIDER) {
        continue;
      }
      const text = runsToPlainText(parseRuns(p.runs)).trim();
      if (text.length === 0) {
        continue;
      }
      const seg: Segment = { paragraph: p, text: text };
      out.push(seg);
    }
    return out;
  }

  static batch(segs: Segment[], maxTokens: number): Segment[][] {
    const limit = maxTokens > 200 ? maxTokens : 1200;
    const out: Segment[][] = [];
    let cur: Segment[] = [];
    let tokens = 0;
    for (let i = 0; i < segs.length; i++) {
      const t = Chunker.estimate(segs[i].text);
      const full = tokens + t > limit || cur.length >= Chunker.MAX_ITEMS;
      if (cur.length > 0 && full) {
        out.push(cur);
        cur = [];
        tokens = 0;
      }
      cur.push(segs[i]);
      tokens += t;
    }
    if (cur.length > 0) {
      out.push(cur);
    }
    return out;
  }
}
