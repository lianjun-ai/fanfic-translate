import { Chapter, ChapterStatus, ParaStatus, ParaType, Paragraph, Run, Term, parseRuns, stringifyRuns } from '../model/Models';
import { ParagraphDao } from '../data/ParagraphDao';
import { ChapterDao } from '../data/ChapterDao';
import { ProviderConfig } from '../common/Settings';
import { ChatMessage, LlmProvider } from '../provider/LlmProvider';
import { Chunker, Segment } from './Chunker';
import { Prompt } from './Prompt';
import { ResponseParser } from './ResponseParser';
import { Aligner } from './Aligner';
import { Summarizer } from './Summarizer';
import { Log } from '../common/Logger';

export interface TranslateHooks {
  /** 本次需要翻译多少段（不含已完成的） */
  onPlan: (total: number) => void;
  /** 正在翻译的段落 + 当前累计译文，用于边生成边显示 */
  onPartial: (paragraphId: string, text: string) => void;
  onDone: (paragraphId: string, runsJson: string) => void;
  onFailed: (paragraphId: string, reason: string) => void;
  /** reason 非空表示中途中断（网络、鉴权、连续失败） */
  onFinish: (ok: number, failed: number, reason: string) => void;
  /** 整章译完后生成的摘要；拿不到时不会调用 */
  onSummary?: (text: string) => void;
}

const MAX_INLINE_RETRY: number = 6;
const MAX_FAIL_STREAK: number = 3;

/**
 * 单章翻译的执行者。
 *
 * 流程：分段 → 分批 → 请求 → 按编号对齐 → 逐段落库。
 * 三处刻意的设计：
 *
 * 1. 译文一落地就写库，不等整章结束。长章节可能几十次请求，
 *    中途退出、切后台被杀都不会白翻。
 * 2. 编号对不上时先整批按空行兜底对齐，仍有缺口才单段补翻；
 *    补翻还失败就标 failed 交给用户重试，绝不猜位置硬塞。
 * 3. 连续三批整体失败就停手 —— 通常是 Key 错或没网，
 *    继续重试只是徒劳地烧时间和请求配额。
 */
export class Translator {
  private cfg: ProviderConfig;
  private provider: LlmProvider;
  private aborted: boolean = false;
  /** 前几章的摘要，注入提示词用于跨章一致 */
  private story: string;

  constructor(cfg: ProviderConfig, story: string = '') {
    this.cfg = cfg;
    this.provider = new LlmProvider(cfg);
    this.story = story;
  }

  abort(): void {
    this.aborted = true;
    this.provider.abort();
  }

  async translateChapter(chapter: Chapter, paras: Paragraph[], hooks: TranslateHooks,
    terms: Term[] = []): Promise<void> {
    const all = Chunker.segments(paras);
    const todo: Segment[] = [];
    for (let i = 0; i < all.length; i++) {
      if (all[i].paragraph.status !== ParaStatus.DONE) {
        todo.push(all[i]);
      }
    }
    hooks.onPlan(todo.length);
    if (todo.length === 0) {
      /*
       * 整章早就译完。但老版本没有摘要，直接返回会让这些章节永远进不了前情，
       * 后续章节继续在没有上下文的情况下翻译。顺手补一次摘要 ——
       * 连翻时跳过已译章节，正好成了低成本的补录通道。
       */
      if (chapter.summary.trim().length === 0) {
        const backfilled = await this.summarizeChapter(chapter, paras, chapter.status);
        if (backfilled.length > 0 && hooks.onSummary !== undefined) {
          hooks.onSummary(backfilled);
        }
      }
      hooks.onFinish(0, 0, '');
      return;
    }

    const system = Prompt.system(this.cfg.sourceLang, this.cfg.targetLang, terms, this.story);
    const batches = Chunker.batch(todo, this.cfg.batchTokens);
    let ok = 0;
    let failed = 0;
    let failStreak = 0;
    let stopReason = '';

    for (let b = 0; b < batches.length; b++) {
      if (this.aborted) {
        stopReason = '已取消';
        break;
      }
      const batch = batches[b];

      let text = '';
      try {
        text = await this.request(system, batch, hooks);
      } catch (e) {
        const msg = (e as Error).message;
        Log.w(`第 ${b + 1} 批失败：${msg}`);
        failStreak++;
        for (let i = 0; i < batch.length; i++) {
          failed++;
          hooks.onFailed(batch[i].paragraph.id, msg);
        }
        if (failStreak >= MAX_FAIL_STREAK) {
          stopReason = msg;
          break;
        }
        continue;
      }
      failStreak = 0;

      const result = this.align(batch, text);
      const missing: Segment[] = [];
      for (let i = 0; i < batch.length; i++) {
        const seg = batch[i];
        const tr = result.get(seg.paragraph.id);        if (tr === undefined || tr.length === 0) {
          missing.push(seg);
          continue;
        }
        await this.commit(seg, tr);
        ok++;
        hooks.onDone(seg.paragraph.id, this.toRunsJson(seg.paragraph.runs, tr));
      }

      // 少量缺口：单段补翻一次。缺口太多说明整批错位，补翻代价不划算
      if (missing.length > 0 && missing.length <= MAX_INLINE_RETRY && !this.aborted) {
        for (let i = 0; i < missing.length; i++) {
          if (this.aborted) {
            break;
          }
          const seg = missing[i];
          try {
            const one = await this.request(system, [seg], hooks);
            const single = this.align([seg], one);
            const tr = single.get(seg.paragraph.id);
            if (tr === undefined || tr.length === 0) {
              throw new Error('补翻仍未取到对应段落');
            }
            await this.commit(seg, tr);
            ok++;
            hooks.onDone(seg.paragraph.id, this.toRunsJson(seg.paragraph.runs, tr));
          } catch (e) {
            failed++;
            hooks.onFailed(seg.paragraph.id, (e as Error).message);
          }
        }
      } else {
        for (let i = 0; i < missing.length; i++) {
          failed++;
          hooks.onFailed(missing[i].paragraph.id, '模型返回的段落编号与请求不一致');
        }
      }
    }

    const status = await this.settleChapter(chapter);

    /*
     * 只有整章干净译完才写摘要。
     * 残缺的章节生成摘要会把「没翻到的情节」一起漏掉，
     * 后续所有章节都会带着这个错误的记忆继续翻 —— 不如没有摘要。
     */
    if (ok > 0 && failed === 0 && stopReason.length === 0 && !this.aborted) {
      const summary = await this.summarizeChapter(chapter, paras, status);
      if (summary.length > 0 && hooks.onSummary !== undefined) {
        hooks.onSummary(summary);
      }
    }

    hooks.onFinish(ok, failed, stopReason);
  }

  /** 发一批请求，并把流式增量转成"当前段落的部分译文" */
  private async request(system: string, batch: Segment[], hooks: TranslateHooks): Promise<string> {
    const messages: ChatMessage[] = [
      { role: 'system', content: system },
      { role: 'user', content: Prompt.user(batch) }
    ];

    const onDelta = (acc: string): void => {
      const parsed = ResponseParser.parse(acc);
      if (parsed.length === 0) {
        return;
      }
      const last = parsed[parsed.length - 1];
      const target = batch[last.index - 1];
      if (target !== undefined && last.text.length > 0) {
        hooks.onPartial(target.paragraph.id, last.text);
      }
    };

    return this.provider.complete(messages, onDelta);
  }

  /**
   * 把模型输出落回段落。对齐规则见 Aligner ——
   * 这里只负责把"第几个"翻译成"哪一段"。
   */
  private align(batch: Segment[], text: string): Map<string, string> {
    const out = new Map<string, string>();
    const byPos = Aligner.align(batch.length, text);
    byPos.forEach((value: string, pos: number) => {
      const target = batch[pos - 1];
      if (target !== undefined) {
        out.set(target.paragraph.id, value);
      }
    });
    return out;
  }

  private async commit(seg: Segment, text: string): Promise<void> {
    const runs = this.toRunsJson(seg.paragraph.runs, text);
    await ParagraphDao.saveTranslation(seg.paragraph.id, runs, ParaStatus.DONE);
  }

  /**
   * 译文样式继承。
   *
   * 模型返回的是纯文本，逐片段的样式分布已经丢失。这里只做一件事：
   * 如果整段原文都是斜体（同人里常用来表示内心独白），整段译文也给斜体；
   * 部分斜体则不强加 —— 猜错位置比丢掉斜体更难看。
   */
  private toRunsJson(sourceJson: string, text: string): string {
    const src = parseRuns(sourceJson);
    let total = 0;
    let italic = 0;
    let bold = 0;
    let underline = 0;
    let strike = 0;
    for (let i = 0; i < src.length; i++) {
      const r = src[i];
      const n = r.text.trim().length;
      if (n === 0) {
        continue;
      }
      total += n;
      if (r.italic) {
        italic += n;
      }
      if (r.bold) {
        bold += n;
      }
      if (r.underline) {
        underline += n;
      }
      if (r.strike) {
        strike += n;
      }
    }
    const uniform = (n: number): boolean => total > 0 && n >= total * 0.9;
    const run: Run = {
      text: text,
      bold: uniform(bold),
      italic: uniform(italic),
      underline: uniform(underline),
      strike: uniform(strike)
    };
    return stringifyRuns([run]);
  }

  /** 收尾：根据段落实际状态回写章节状态，并把最终状态返回给调用方 */
  private async settleChapter(chapter: Chapter): Promise<string> {
    let status = ChapterStatus.PARTIAL;
    try {
      const list = await ParagraphDao.listByChapter(chapter.id);
      let done = 0;
      let total = 0;
      for (let i = 0; i < list.length; i++) {
        if (list[i].type === ParaType.DIVIDER) {
          continue;
        }
        total++;
        if (list[i].status === ParaStatus.DONE) {
          done++;
        }
      }
      if (done === 0) {
        status = ChapterStatus.PENDING;
      } else if (done >= total) {
        status = ChapterStatus.TRANSLATED;
      }
      await ChapterDao.updateStatus(chapter.id, status);
    } catch (e) {
      Log.w(`回写章节状态失败：${(e as Error).message}`);
    }
    return status;
  }

  /**
   * 生成并落库本章摘要。
   * 摘要以译文语境写（中文），因为它唯一的消费者是下一次提示词。
   */
  private async summarizeChapter(chapter: Chapter, paras: Paragraph[], status: string): Promise<string> {
    try {
      const segs = Chunker.segments(paras);
      // 单章翻译时传入的段落是从当前阅读位置轮转过的，摘要必须按原始顺序读
      segs.sort((a: Segment, b: Segment) => a.paragraph.indexNo - b.paragraph.indexNo);
      let plain = '';
      for (let i = 0; i < segs.length; i++) {
        plain += `${segs[i].text}\n`;
        if (plain.length >= 4000) {
          break;
        }
      }
      const summary = await Summarizer.trySummarize(this.cfg, chapter.title, plain);
      if (summary.length === 0) {
        return '';
      }
      await ChapterDao.saveSummary(chapter.id, summary, status);
      return summary;
    } catch (e) {
      Log.w(`写入章节摘要失败：${(e as Error).message}`);
      return '';
    }
  }
}
