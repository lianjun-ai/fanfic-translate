import { Chapter } from '../model/Models';

/**
 * 前情提要。
 *
 * 段落级翻译有个天然缺陷：每一批请求都是孤立的一千多 token，
 * 模型看不到上一章发生了什么。长篇连载里这会导致两个典型问题 ——
 * 上一章刚确立的称呼（她开始叫他的名而不是姓）下一章又退回原名，
 * 前文交代过的人名到后面换了个译法。
 *
 * 解法不是把前文塞进请求（那会撑爆上下文且极贵），而是给每章留一句摘要，
 * 翻译新章时只带最近几章的摘要。这是「段落级翻译 + 章级摘要」的另一半：
 * 摘要不追求文学性，只要能拴住人物、称呼、关系和关键物件。
 */
export class StoryContext {
  /** 注入提示词的总字数上限，超了就从最早的章开始丢 */
  static readonly MAX_CHARS: number = 900;
  /** 最多带几章 */
  static readonly MAX_CHAPTERS: number = 6;

  /**
   * 取出 uptoIndex 之前已有摘要的章节，按时间正序拼成文本。
   * 从最近往前挑，保证离当前章最近的信息一定在。
   */
  static compose(chapters: Chapter[], uptoIndex: number): string {
    const picked: Chapter[] = [];
    let chars = 0;
    for (let i = uptoIndex - 1; i >= 0 && picked.length < StoryContext.MAX_CHAPTERS; i--) {
      const c = chapters[i];
      if (c === undefined || c === null) {
        continue;
      }
      const s = c.summary.trim();
      if (s.length === 0) {
        continue;
      }
      if (picked.length > 0 && chars + s.length > StoryContext.MAX_CHARS) {
        break;
      }
      picked.push(c);
      chars += s.length;
    }
    if (picked.length === 0) {
      return '';
    }
    picked.reverse();
    let out = '';
    for (let i = 0; i < picked.length; i++) {
      const c = picked[i];
      const title = c.title.trim().length > 0 ? c.title.trim() : `第 ${c.indexNo + 1} 章`;
      out += `${title}：${c.summary.trim()}\n`;
    }
    return out;
  }
}
