import { Term } from '../model/Models';
import { langName } from '../common/Settings';
import { Segment } from './Chunker';

/**
 * 提示词构造。
 *
 * 翻译质量的关键不是"请翻译得优美"，而是让模型**不敢改结构**：
 * 一旦它合并、拆分或省略段落，段落级对齐就崩了，读者会看到错位的双语。
 * 所以系统提示里用编号协议把结构锁死，其余才是风格要求。
 */
export class Prompt {
  static system(srcLang: string, targetLang: string, terms: Term[], story: string = ''): string {
    const target = langName(targetLang);
    const src = srcLang === 'auto' ? '原文语言' : langName(srcLang);

    let s = `你是一位资深的文学翻译，长期翻译同人小说（fanfiction），熟悉网络流行语、二次元语境和人物对话的语感。\n` +
      `请把用户给出的编号段落从${src}翻译成${target}。\n\n` +
      `【格式要求 —— 必须严格遵守】\n` +
      `1. 每个段落以 [[编号]] 开头，编号与原文完全一致，一个编号一段，段内不要换行。\n` +
      `2. 不得合并、拆分、调换、遗漏任何段落；即使某段只有标点或语气词，也要原样输出并保留编号。\n` +
      `3. 只输出译文本身。不要加解释、注释、译注、前言、结语，也不要用 markdown 语法。\n\n` +
      `【翻译要求】\n` +
      `1. 忠实原意，不要自行增删情节或对话。\n` +
      `2. 人物对话要像真人说话，避免翻译腔和过度书面化；内心独白保留其跳跃感。\n` +
      `3. 人名、地名、专有名词必须前后一致。\n` +
      `4. 原文的语气词、称呼习惯、亲疏关系要尽量保留。`;

    // 前情仅作为一致性约束存在。必须明确禁止翻译/复述，
    // 否则模型很容易把它当成待译内容一起处理，输出里凭空多出几段。
    if (story.length > 0) {
      s += `\n\n【前情提要 —— 仅用于保持人物、称呼与情节连续】\n` +
        `以下内容不是待翻译的正文，不要翻译它，也不要在输出里复述它。\n${story}`;
    }

    if (terms.length > 0) {
      s += `\n\n【术语表 —— 出现时必须按此译名】\n`;
      for (let i = 0; i < terms.length; i++) {
        const t = terms[i];
        if (t.source.trim().length === 0 || t.target.trim().length === 0) {
          continue;
        }
        s += t.note.length > 0
          ? `${t.source} => ${t.target}（${t.note}）\n`
          : `${t.source} => ${t.target}\n`;
      }
    }
    return s;
  }

  static user(segs: Segment[]): string {
    let s = '';
    for (let i = 0; i < segs.length; i++) {
      s += `[[${i + 1}]] ${segs[i].text}\n`;
    }
    return s;
  }
}
