import { ProviderConfig } from '../common/Settings';
import { ChatMessage, LlmProvider } from '../provider/LlmProvider';
import { Log } from '../common/Logger';

/** 送给模型的正文字数上限。摘要只需要事件与人物，不需要读完全章 */
const MAX_INPUT: number = 3600;
/** 摘要本身的字数硬上限，超过就截断 —— 注入提示词的额度很贵 */
const MAX_OUTPUT: number = 120;

const SYSTEM: string = `你在为一部连载小说的翻译做前情记录。阅读给定章节的正文，用简体中文写 1-2 句剧情摘要。

要求：
1. 只写这一章实际发生的事：谁做了什么、人物关系有何变化、出现了什么重要物件或地点。
2. 不超过 80 字。不要评价文笔，不要写「本章讲述了」这类套话，不要预告后文。
3. 直接输出摘要正文，不要前缀、不要引号、不要 markdown。`;

/**
 * 章节摘要生成器。
 *
 * 一次摘要大约一两百 token，相对于整章翻译的开销可以忽略，
 * 但它换来的是跨章一致性 —— 这是长篇同人翻译里最容易崩、也最难事后修补的地方。
 * 摘要失败绝不阻断翻译：拿不到就退化成没有前情，翻译本身照常完成。
 */
export class Summarizer {
  static async summarize(cfg: ProviderConfig, title: string, plain: string): Promise<string> {
    const body = plain.length > MAX_INPUT ? plain.substring(0, MAX_INPUT) : plain;
    if (body.trim().length < 80) {
      // 太短的章节（分隔页、作者的话）不值得花一次请求
      return '';
    }
    const messages: ChatMessage[] = [
      { role: 'system', content: SYSTEM },
      { role: 'user', content: `章节标题：${title.length > 0 ? title : '（无标题）'}\n\n正文：\n${body}` }
    ];
    const provider = new LlmProvider(cfg);
    // 摘要不需要流式展示，回调留空即可；签名仍走流式，逻辑与翻译共用一条通路
    const raw = await provider.complete(messages, (acc: string) => {
    });
    return Summarizer.clean(raw);
  }

  /** 模型很爱加「摘要：」前缀或把整句包在引号里，这里统一剥掉 */
  private static clean(raw: string): string {
    let s = raw.trim();
    if (s.length === 0) {
      return '';
    }
    // 去掉 markdown 标记与可能的列表符号
    s = s.replace(/^[-*#>\s]+/, '');
    s = s.replace(/^(摘要|前情|本章摘要|Summary)\s*[:：]\s*/i, '');
    s = s.replace(/["“”'']/g, '');
    s = s.replace(/\s+/g, ' ');
    if (s.length > MAX_OUTPUT) {
      s = `${s.substring(0, MAX_OUTPUT)}…`;
    }
    return s.trim();
  }

  /** 供调用方复用的容错包装：任何异常都退化成空摘要 */
  static async trySummarize(cfg: ProviderConfig, title: string, plain: string): Promise<string> {
    try {
      return await Summarizer.summarize(cfg, title, plain);
    } catch (e) {
      Log.w(`生成章节摘要失败：${(e as Error).message}`);
      return '';
    }
  }
}
