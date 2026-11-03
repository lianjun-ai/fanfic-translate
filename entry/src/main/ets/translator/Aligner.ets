import { ParsedSegment, ResponseParser } from './ResponseParser';
import { Log } from '../common/Logger';

/**
 * 把模型输出对齐回请求里的段落位置。
 *
 * 对齐的基准是**编号**，不是顺序 —— 模型偶尔会把某几段调换位置，
 * 按位置硬塞会把对话安到错误的人头上，读者看到的是一段读不通的译文；
 * 按编号取就完全不受影响。
 *
 * 编号整体缺失时退一步用"按空行切块"，但只有块数恰好等于段落数才采信，
 * 数量对不上宁可判失败交给用户重试，也不做任何猜测。
 */
export class Aligner {
  /** count 是本次请求的段落数；返回 1-based 位置 → 译文 */
  static align(count: number, raw: string): Map<number, string> {
    const out = new Map<number, string>();
    if (count <= 0) {
      return out;
    }
    let segs: ParsedSegment[] = ResponseParser.parse(raw);

    if (segs.length !== count) {
      const loose = ResponseParser.parseLoose(raw);
      if (loose.length === count) {
        segs = loose;
        Log.d(`标记不可用，按空行兜底对齐成功（${count} 段）`);
      }
    }

    for (let i = 0; i < segs.length; i++) {
      const s = segs[i];
      if (s.index < 1 || s.index > count || s.text.length === 0) {
        continue;
      }
      // 同一编号重复出现时保留第一条，后面的当模型在自我重复
      if (!out.has(s.index)) {
        out.set(s.index, s.text);
      }
    }
    return out;
  }
}
