export interface ParsedSegment {
  /** 从 1 开始，对应请求里的段落序号 */
  index: number;
  text: string;
}

/**
 * 把模型返回的文本按 [[编号]] 切成段落。
 *
 * 这里必须容忍三种现实：流式传输到一半的残句、模型把标记写成全角括号、
 * 以及完全不按协议输出的服务。前两种照常解析（用于边生成边显示），
 * 第三种交给调用方走"按空行切块"的兜底。
 */
export class ResponseParser {
  /** 全角括号标记归一成半角，模型经常在中文语境下自发作这个替换 */
  private static normalize(text: string): string {
    return text.replace(/【\s*(\d+)\s*】/g, '[[$1]]');
  }

  static parse(raw: string): ParsedSegment[] {
    const buffer = ResponseParser.normalize(raw);
    const starts: number[] = [];
    const ends: number[] = [];
    const nums: number[] = [];

    let i = 0;
    while (i < buffer.length) {
      const open = buffer.indexOf('[[', i);
      if (open < 0) {
        break;
      }
      const close = buffer.indexOf(']]', open + 2);
      if (close < 0) {
        // 标记还没收全，等下一个 chunk
        break;
      }
      const inner = buffer.substring(open + 2, close).trim();
      if (inner.length > 0 && inner.length <= 3 && ResponseParser.allDigits(inner)) {
        starts.push(open);
        ends.push(close + 2);
        nums.push(parseInt(inner, 10));
        i = close + 2;
      } else {
        i = open + 2;
      }
    }

    const out: ParsedSegment[] = [];
    if (nums.length === 0) {
      return out;
    }
    for (let k = 0; k < nums.length; k++) {
      const from = ends[k];
      const to = k + 1 < nums.length ? starts[k + 1] : buffer.length;
      const seg: ParsedSegment = {
        index: nums[k],
        text: ResponseParser.clean(buffer.substring(from, to))
      };
      out.push(seg);
    }
    return out;
  }

  /**
   * 兜底：没有任何标记时，按空行切块并按顺序编号。
   * 只有块数与段落数一致时调用方才采信 —— 数量对不上宁可判失败，
   * 也不能把内容错位地塞进段落里，那会让读者读到张冠李戴的译文。
   */
  static parseLoose(raw: string): ParsedSegment[] {
    const cleaned = ResponseParser.normalize(raw).replace(/\[\[\s*\d+\s*\]\]/g, '');
    const parts = cleaned.split(/\n\s*\n/);
    const out: ParsedSegment[] = [];
    for (let i = 0; i < parts.length; i++) {
      const t = ResponseParser.clean(parts[i]);
      if (t.length === 0) {
        continue;
      }
      const seg: ParsedSegment = { index: out.length + 1, text: t };
      out.push(seg);
    }
    return out;
  }

  static clean(text: string): string {
    let t = text;
    // 模型偶尔会补一行分隔线或"译文："前缀
    t = t.replace(/^\s*(译文|翻译|Translation)\s*[:：]\s*/i, '');
    t = t.replace(/^[-—=*\s]+$/, '');
    t = t.replace(/\s*[-—=]{3,}\s*$/g, '');
    // 段内换行压成空格：段落是一个整体，换行会破坏阅读器的段间距节奏
    t = t.replace(/\s*\n\s*/g, ' ');
    // 流式传输可能正好截在下一个标记中间，不剥掉的话屏幕会闪一下 "…… [[2"
    // 未闭合的 [ / [[ / [[2 / [[2] 一律连同后面一小截一起剥掉
    t = t.replace(/\[{1,2}\s*\d*\s*\]?\s*$/, '');
    t = t.replace(/【\s*\d*\s*】?\s*$/, '');
    t = t.replace(/[ \t]{2,}/g, ' ');
    return t.trim();
  }

  private static allDigits(s: string): boolean {
    for (let i = 0; i < s.length; i++) {
      const c = s.charCodeAt(i);
      if (c < 0x30 || c > 0x39) {
        return false;
      }
    }
    return true;
  }
}
