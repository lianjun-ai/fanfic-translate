import { promptAction } from '@kit.ArkUI';
import { Chapter, ChapterStatus, ParaStatus, ParaType, Paragraph, Run, Work, parseRuns } from '../model/Models';
import { WorkDao } from '../data/WorkDao';
import { ChapterDao } from '../data/ChapterDao';
import { ParagraphDao } from '../data/ParagraphDao';
import { ProgressDao } from '../data/ProgressDao';
import { TermDao } from '../data/TermDao';
import { ProviderConfig, Settings } from '../common/Settings';
import { UiPrefs } from '../common/UiPrefs';
import { TranslateHooks, Translator } from '../translator/Translator';
import { StoryContext } from '../translator/StoryContext';
import { Log } from '../common/Logger';

/** 路由参数。用接口而不是 Record，避免 ArkTS 的动态键限制 */
interface ReaderParams {
  workId: string;
  chapterId: string;
}

/** 单章翻译的结果，供单章与连翻两条路径共用 */
interface ChapterOutcome {
  ok: number;
  failed: number;
  reason: string;
}

const FONT_STEPS: number[] = [15, 17, 19, 21, 23];
const DEFAULT_STEP: number = 1;

/** 显示模式 */
const MODE_SOURCE: number = 0;
const MODE_TARGET: number = 1;
const MODE_BOTH: number = 2;
const MODE_NAMES: string[] = ['原文', '译文', '对照'];

/**
 * 阅读器。
 *
 * 段落不是字符串而是 Run[]，这里把每个 Run 映射成一个 Span：
 * 斜体、加粗、下划线、删除线全部按原样还原。译文同样以 Run[] 存储，
 * 渲染路径完全复用 —— 这是"译文不被压成一段白开水"的落地点。
 *
 * 三种显示模式：原文 / 译文 / 对照。对照模式下原文在上、译文在下：
 * 先读原文，再对照译文。已译段落把原文压成次级色小一号，居下位的译文才是阅读主体。
 */
@Entry
@Component
struct Reader {
  @State work: Work | null = null;
  @State chapters: Chapter[] = [];
  @State current: number = 0;
  @State paragraphs: Paragraph[] = [];
  @State loading: boolean = true;
  @State errorMsg: string = '';
  @State showToc: boolean = false;
  @State fontStep: number = DEFAULT_STEP;

  /* ---- 翻译相关 ---- */
  @State mode: number = MODE_SOURCE;
  @State translating: boolean = false;
  /** 本次翻译会话的进度 */
  @State transDone: number = 0;
  @State transTotal: number = 0;
  /** 本章整体统计，用于按钮的"翻译 / 补译 / 已译" */
  @State doneCount: number = 0;
  @State allCount: number = 0;
  /** 正在流式输出的段落与当前累计译文 */
  @State partialId: string = '';
  @State partialText: string = '';
  @State partialTick: number = 0;

  /* ---- 连续翻译 ---- */
  @State seqRunning: boolean = false;
  /** 本次连翻计划覆盖几章 */
  @State seqTotal: number = 0;
  /** 正在翻第几章（1 基） */
  @State seqChapter: number = 0;

  /**
   * 当前屏幕顶部可见的段落下标。
   * 刻意不用 @State：它在滚动时每一帧都会变，做成状态会触发整屏重渲染，
   * 长章节滚动会直接掉帧。用普通成员变量 + 节流落库即可。
   */
  private firstVisible: number = 0;
  private lastSavedAt: number = 0;
  private lastPartialAt: number = 0;
  /** 用户是否亲手选过显示模式，选过就不再自动切换 */
  private modeChosen: boolean = false;
  /** 连翻被用户主动停止 */
  private seqCancelled: boolean = false;

  private listScroller: Scroller = new Scroller();
  private tocScroller: Scroller = new Scroller();
  private workId: string = '';
  private startChapterId: string = '';
  private translator: Translator | null = null;

  aboutToAppear(): void {
    this.readParams();
    this.restoreFont();
    this.load();
  }

  aboutToDisappear(): void {
    this.seqCancelled = true;
    this.persistProgress();
    this.cancelTranslate();
  }

  onPageHide(): void {
    this.persistProgress();
  }

  /** 字号是长期偏好，跨启动沿用上次的设定 */
  private async restoreFont(): Promise<void> {
    const step = await UiPrefs.fontStep(DEFAULT_STEP);
    if (step >= 0 && step < FONT_STEPS.length) {
      this.fontStep = step;
    }
  }

  private readParams(): void {
    try {
      const raw = this.getUIContext().getRouter().getParams();
      if (raw === undefined || raw === null) {
        return;
      }
      const p = raw as ReaderParams;
      this.workId = p.workId;
      this.startChapterId = p.chapterId;
    } catch (e) {
      Log.e(`读取路由参数失败：${(e as Error).message}`);
    }
  }

  private async load(): Promise<void> {
    if (this.workId.length === 0) {
      this.errorMsg = '没有拿到作品 ID，无法打开';
      this.loading = false;
      return;
    }
    try {
      this.work = await WorkDao.find(this.workId);
      this.chapters = await ChapterDao.listByWork(this.workId);
      if (this.chapters.length === 0) {
        this.errorMsg = '这本书没有章节，请重新导入';
        this.loading = false;
        return;
      }

      // 定位：优先用路由指定的章节，其次用上次阅读进度，最后从第一章开始
      let index = 0;
      let para = 0;
      const routeIdx = this.indexOfChapter(this.startChapterId);
      if (routeIdx >= 0) {
        index = routeIdx;
      } else {
        const saved = await ProgressDao.get(this.workId);
        if (saved !== null) {
          const i = this.indexOfChapter(saved.chapterId);
          if (i >= 0) {
            index = i;
            para = saved.paragraphIndex;
          }
        }
      }
      await this.loadChapter(index, para);
    } catch (e) {
      this.errorMsg = `打开失败：${(e as Error).message}`;
      this.loading = false;
      Log.e(this.errorMsg);
    }
  }

  private indexOfChapter(chapterId: string): number {
    for (let i = 0; i < this.chapters.length; i++) {
      if (this.chapters[i].id === chapterId) {
        return i;
      }
    }
    return -1;
  }

  private async loadChapter(index: number, scrollTo: number = 0): Promise<void> {
    if (index < 0 || index >= this.chapters.length) {
      return;
    }
    this.loading = true;
    this.current = index;
    this.firstVisible = 0;
    this.partialId = '';
    this.partialText = '';
    try {
      const ch = this.chapters[index];
      this.paragraphs = await ParagraphDao.listByChapter(ch.id);
      this.recount();
      if (!this.modeChosen) {
        // 有译文就直接进对照模式，省得用户每次都要手动切
        this.mode = this.doneCount > 0 ? MODE_BOTH : MODE_SOURCE;
      }
      this.errorMsg = '';
    } catch (e) {
      this.errorMsg = `读取章节失败：${(e as Error).message}`;
      Log.e(this.errorMsg);
    } finally {
      this.loading = false;
    }
    this.restoreScroll(scrollTo);
  }

  /** 重算本章的翻译统计 */
  private recount(): void {
    let done = 0;
    let total = 0;
    for (let i = 0; i < this.paragraphs.length; i++) {
      const p = this.paragraphs[i];
      if (p.type === ParaType.DIVIDER) {
        continue;
      }
      total++;
      if (p.status === ParaStatus.DONE) {
        done++;
      }
    }
    this.doneCount = done;
    this.allCount = total;
  }

  /** 等一帧布局完成后再定位，否则 scrollToIndex 会被列表的初始位置覆盖 */
  private restoreScroll(index: number): void {
    setTimeout(() => {
      if (this.paragraphs.length === 0) {
        return;
      }
      const target = index > 0 && index < this.paragraphs.length ? index : 0;
      this.listScroller.scrollToIndex(target, false, ScrollAlign.START);
      this.firstVisible = target;
    }, 80);
  }

  private async persistProgress(): Promise<void> {
    const ch = this.chapters[this.current];
    if (ch === undefined) {
      return;
    }
    try {
      await ProgressDao.save(this.workId, ch.id, this.firstVisible);
    } catch (e) {
      Log.w(`保存进度失败：${(e as Error).message}`);
    }
  }

  /**
   * 滚动时节流落库。退出时才保存是不可靠的：
   * 组件销毁后发起的异步写很可能根本没执行完，进度就丢了。
   * 每 4 秒最多写一次，代价可以忽略。
   */
  private saveProgressThrottled(): void {
    const now = Date.now();
    if (now - this.lastSavedAt < 4000) {
      return;
    }
    this.lastSavedAt = now;
    this.persistProgress().catch((e: Error) => {
      Log.w(`节流保存进度失败：${e.message}`);
    });
  }

  private async gotoChapter(index: number): Promise<void> {
    if (index < 0 || index >= this.chapters.length || index === this.current) {
      return;
    }
    // 连翻期间由循环自己推进章节，手动跳转会与它抢同一份状态
    if (this.seqRunning) {
      this.getUIContext().getPromptAction().showToast({ message: '连翻进行中，先停止再跳章' });
      return;
    }
    this.cancelTranslate();
    await this.persistProgress();
    await this.loadChapter(index, 0);
  }

  private fontSize(): number {
    const i = Math.min(Math.max(this.fontStep, 0), FONT_STEPS.length - 1);
    return FONT_STEPS[i];
  }

  private lineHeightOf(): number {
    return Math.round(this.fontSize() * 1.75);
  }

  private adjustFont(delta: number): void {
    const next = this.fontStep + delta;
    if (next >= 0 && next < FONT_STEPS.length) {
      this.fontStep = next;
      UiPrefs.setFontStep(next);
    }
  }

  private sizeFor(p: Paragraph): number {
    return p.type === ParaType.HEADING ? this.fontSize() + 3 : this.fontSize();
  }

  private lineFor(p: Paragraph): number {
    return p.type === ParaType.HEADING ? this.lineHeightOf() + 4 : this.lineHeightOf();
  }

  private weightFor(p: Paragraph): FontWeight {
    return p.type === ParaType.HEADING ? FontWeight.Bold : FontWeight.Normal;
  }

  /**
   * 对照模式下原文是否退为「参考态」：只有这一段已经有译文时才成立。
   * 没有译文的段落，原文就是唯一内容，仍按正文样式显示 ——
   * 否则整章会变成一片失焦的灰字，读到未译处像是内容丢了。
   */
  private refOnly(p: Paragraph): boolean {
    return this.mode === MODE_BOTH && p.status === ParaStatus.DONE && p.translatedRuns.length > 0;
  }

  private srcSize(p: Paragraph): number {
    return this.refOnly(p) ? Math.max(this.sizeFor(p) - 1, 13) : this.sizeFor(p);
  }

  private srcLine(p: Paragraph): number {
    return this.refOnly(p) ? this.lineFor(p) - 2 : this.lineFor(p);
  }

  private goBack(): void {
    this.getUIContext().getRouter().back();
  }

  private goSettings(): void {
    this.getUIContext().getRouter().pushUrl({ url: 'pages/SettingsPage' }).catch(() => {
      this.getUIContext().getPromptAction().showToast({ message: '打开设置失败' });
    });
  }

  private goTerms(): void {
    /*
     * 必须先收口半模态、再等一拍跳转。
     * sheet 的关闭动画与路由转场同帧进行时，部分系统版本会在窗口层
     * 原生崩溃（表现为点击「术语表」应用直接闪退）。其他入口没有这个问题，
     * 因为它们不经过浮层。
     */
    this.showToc = false;
    setTimeout(() => {
      this.getUIContext().getRouter().pushUrl({
        url: 'pages/TermPage',
        params: { workId: this.workId, workTitle: this.work?.title ?? '' }
      }).catch(() => {
        this.getUIContext().getPromptAction().showToast({ message: '打开术语表失败' });
      });
    }, 350);
  }

  private cycleMode(): void {
    this.modeChosen = true;
    this.mode = (this.mode + 1) % 3;
  }

  /* ------------------------- 翻译 ------------------------- */

  private translateLabel(): string {
    if (this.seqRunning) {
      return `停止 ${this.seqChapter}/${this.seqTotal}`;
    }
    if (this.translating) {
      return `${this.transDone}/${this.transTotal}`;
    }
    if (this.allCount === 0) {
      return '翻译';
    }
    if (this.doneCount >= this.allCount) {
      return '已译';
    }
    return this.doneCount > 0 ? '补译' : '翻译';
  }

  private async startTranslate(): Promise<void> {
    if (this.translating) {
      this.cancelTranslate();
      return;
    }
    const ch = this.chapters[this.current];
    if (ch === undefined || this.paragraphs.length === 0) {
      return;
    }
    if (this.allCount > 0 && this.doneCount >= this.allCount) {
      // 已全部译完，再点就是重译：先清空本章译文
      this.getUIContext().getPromptAction().showDialog({
        title: '重新翻译本章？',
        message: '已有的本章译文会被覆盖。',
        buttons: [
          { text: '取消', color: '#FF6B6259' },
          { text: '重译', color: '#FF8C5A3C' }
        ]
      }).then((r: promptAction.ShowDialogSuccessResponse) => {
        if (r.index === 1) {
          this.resetChapterTranslation();
        }
      }).catch(() => {
      });
      return;
    }

    const cfg = await Settings.load();
    if (!Settings.ready(cfg)) {
      this.showNoConfig();
      return;
    }

    /*
     * 从当前读到的地方开始翻，而不是从本章第一段。
     * 一章上千段时，从头翻要等好几分钟才轮到眼前这一段，
     * 用户会以为没反应。按当前位置轮转，第一批译文立刻出现在视野里。
     */
    const start = this.firstVisible > 0 && this.firstVisible < this.paragraphs.length ? this.firstVisible : 0;
    const ordered = this.paragraphs.slice(start).concat(this.paragraphs.slice(0, start));

    const r = await this.runOne(ch, cfg, ordered, this.current);
    this.finalizeChapter(ch, r, false);
  }

  /**
   * 翻一章。单章按钮与连续翻译共用这一条路径，
   * 否则两条路径的进度、写库、状态回写会慢慢走偏。
   */
  private async runOne(ch: Chapter, cfg: ProviderConfig, paras: Paragraph[],
    chapterIndex: number): Promise<ChapterOutcome> {
    const terms = await TermDao.listByWork(this.workId);
    // 前情只取本章之前的章节，避免把本章自己的旧摘要喂回去
    const story = StoryContext.compose(this.chapters, chapterIndex);
    this.translator = new Translator(cfg, story);
    this.translating = true;
    this.transDone = 0;
    this.transTotal = 0;
    this.partialId = '';
    this.partialText = '';

    let ok = 0;
    let failed = 0;
    let reason = '';

    const hooks: TranslateHooks = {
      onPlan: (total: number) => {
        this.transTotal = total;
      },
      onPartial: (pid: string, text: string) => {
        this.updatePartial(pid, text);
      },
      onDone: (pid: string, runsJson: string) => {
        this.applyDone(pid, runsJson);
      },
      onFailed: (pid: string, why: string) => {
        this.applyFailed(pid, why);
      },
      onSummary: (text: string) => {
        this.applySummary(ch, text);
      },
      onFinish: (o: number, f: number, r: string) => {
        ok = o;
        failed = f;
        reason = r;
      }
    };

    try {
      await this.translator.translateChapter(ch, paras, hooks, terms);
    } catch (e) {
      reason = (e as Error).message;
    }
    const outcome: ChapterOutcome = { ok: ok, failed: failed, reason: reason };
    return outcome;
  }

  /** 收尾：同步界面状态。连翻时静默，避免每章弹一次提示 */
  private finalizeChapter(ch: Chapter, r: ChapterOutcome, silent: boolean): void {
    this.translating = false;
    this.translator = null;
    this.partialId = '';
    this.partialText = '';
    this.paragraphs = this.paragraphs.slice();
    this.recount();

    if (this.doneCount >= this.allCount && this.allCount > 0) {
      ch.status = ChapterStatus.TRANSLATED;
    } else if (this.doneCount > 0) {
      ch.status = ChapterStatus.PARTIAL;
    } else {
      ch.status = ChapterStatus.PENDING;
    }
    // 重新赋值数组，目录里的"已译"标记才会跟着刷新
    this.chapters = this.chapters.slice();

    if (silent) {
      return;
    }
    let msg = '';
    if (r.reason.length > 0) {
      msg = `已中断：${r.reason}`;
    } else if (r.failed > 0) {
      msg = `完成 ${r.ok} 段，${r.failed} 段失败`;
    } else if (r.ok > 0) {
      msg = `本章翻译完成（${r.ok} 段）`;
    } else {
      msg = '本章已全部翻译';
    }
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  /** 摘要刚生成，写回内存里的章节对象，目录里立刻能看到 */
  private applySummary(ch: Chapter, text: string): void {
    ch.summary = text;
    this.chapters = this.chapters.slice();
  }

  /* ------------------------- 连续翻译 ------------------------- */

  /**
   * 从当前章往后连翻。
   *
   * 存在的理由很实际：一部长篇几十上百章，一章一章点、等、切下一章，
   * 实际上把用户绑在了屏幕前。连翻把「翻」和「守着」解耦 ——
   * 点一次，剩下的交给循环，中途可以随时停。
   *
   * 有意不做成真的后台服务（continuous task）：翻译需要实时把流式译文
   * 渲染到当前章，用户切走就看不见，也没有意义。切页即中止是诚实的边界。
   */
  private async startSequence(count: number): Promise<void> {
    if (this.seqRunning || this.translating) {
      return;
    }
    if (this.paragraphs.length === 0) {
      return;
    }
    const cfg = await Settings.load();
    if (!Settings.ready(cfg)) {
      this.showNoConfig();
      return;
    }

    this.showToc = false;
    this.seqCancelled = false;
    this.seqRunning = true;
    const start = this.current;
    const remain = this.chapters.length - start;
    this.seqTotal = count <= 0 ? remain : Math.min(count, remain);
    this.seqChapter = 0;

    let stopped = '';
    let finished = 0;

    for (let k = 0; k < this.seqTotal; k++) {
      if (this.seqCancelled) {
        stopped = '已停止';
        break;
      }
      const idx = start + k;
      const ch = this.chapters[idx];
      if (ch === undefined) {
        break;
      }
      this.seqChapter = k + 1;
      if (idx !== this.current) {
        await this.persistProgress();
        await this.loadChapter(idx, 0);
      }
      const r = await this.runOne(ch, cfg, this.paragraphs.slice(), idx);
      this.finalizeChapter(ch, r, true);
      if (r.reason.length > 0) {
        stopped = r.reason;
        break;
      }
      finished++;
    }

    this.seqRunning = false;
    this.seqChapter = 0;
    const msg = stopped.length > 0
      ? `连翻中断：${stopped}（已完成 ${finished} 章）`
      : `连续翻译完成，共 ${finished} 章`;
    this.getUIContext().getPromptAction().showToast({ message: msg });
    await this.persistProgress();
  }

  private stopSequence(): void {
    if (!this.seqRunning) {
      return;
    }
    this.seqCancelled = true;
    this.cancelTranslate();
  }

  private showNoConfig(): void {
    this.getUIContext().getPromptAction().showDialog({
      title: '还没有配置翻译服务',
      message: '翻译需要填写你自己的 API Key。密钥只保存在本机，不会上传到任何第三方。',
      buttons: [
        { text: '去设置', color: '#FF8C5A3C' },
        { text: '取消', color: '#FF6B6259' }
      ]
    }).then((r: promptAction.ShowDialogSuccessResponse) => {
      if (r.index === 0) {
        this.goSettings();
      }
    }).catch(() => {
    });
  }

  private cancelTranslate(): void {
    const t = this.translator;
    if (t !== null) {
      t.abort();
    }
  }

  /**
   * 流式增量节流。
   * 不节流的话每个网络分片都要重渲染一次正在翻译的那一段，
   * 长段落会明显发烫掉帧；120ms 的间隔肉眼看依然是"实时打字"。
   */
  private updatePartial(pid: string, text: string): void {
    const now = Date.now();
    if (pid === this.partialId && now - this.lastPartialAt < 120) {
      return;
    }
    this.lastPartialAt = now;
    this.partialId = pid;
    this.partialText = text;
    this.partialTick = this.partialTick >= 9999 ? 0 : this.partialTick + 1;
  }

  private applyDone(pid: string, runsJson: string): void {
    const list = this.paragraphs;
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === pid) {
        list[i].translatedRuns = runsJson;
        list[i].status = ParaStatus.DONE;
        break;
      }
    }
    this.paragraphs = list.slice();
    if (this.partialId === pid) {
      this.partialId = '';
      this.partialText = '';
    }
    this.transDone++;
    this.doneCount++;
    if (!this.modeChosen && this.mode === MODE_SOURCE) {
      this.mode = MODE_BOTH;
    }
  }

  private applyFailed(pid: string, reason: string): void {
    const list = this.paragraphs;
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === pid) {
        list[i].status = ParaStatus.FAILED;
        break;
      }
    }
    this.paragraphs = list.slice();
    this.transDone++;
    Log.w(`段落 ${pid} 翻译失败：${reason}`);
  }

  private async resetChapterTranslation(): Promise<void> {
    try {
      const list = this.paragraphs;
      for (let i = 0; i < list.length; i++) {
        list[i].translatedRuns = '';
        list[i].status = ParaStatus.PENDING;
      }
      this.paragraphs = list.slice();
      this.doneCount = 0;
      const ids: string[] = [];
      for (let i = 0; i < list.length; i++) {
        if (list[i].type !== ParaType.DIVIDER) {
          ids.push(list[i].id);
        }
      }
      await ParagraphDao.updateStatus(ids, ParaStatus.PENDING);
      await this.startTranslate();
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: `重置失败：${(e as Error).message}` });
    }
  }

  /* ------------------------- 正文渲染 ------------------------- */

  @Builder
  runsText(runs: Run[], size: number, lineH: number, weight: FontWeight, dim: boolean) {
    Text() {
      ForEach(runs, (r: Run) => {
        Span(r.text)
          .fontWeight(r.bold ? FontWeight.Bold : weight)
          .fontStyle(r.italic ? FontStyle.Italic : FontStyle.Normal)
          .decoration({
            type: r.underline ? TextDecorationType.Underline :
              (r.strike ? TextDecorationType.LineThrough : TextDecorationType.None),
            color: $r('app.color.text_primary')
          })
      }, (r: Run, i: number) => `${i}_${r.text.length}`)
    }
    .fontSize(size)
    .lineHeight(lineH)
    .fontColor(dim ? $r('app.color.text_secondary') : $r('app.color.text_primary'))
    .textAlign(TextAlign.Start)
    .width('100%')
  }

  /** 译文部分：已译、流式中、失败、未译四种状态各有对应表现 */
  @Builder
  translatedPart(p: Paragraph) {
    if (p.status === ParaStatus.DONE && p.translatedRuns.length > 0) {
      this.runsText(parseRuns(p.translatedRuns), this.sizeFor(p), this.lineFor(p), this.weightFor(p), false)
    } else if (p.id === this.partialId && this.partialText.length > 0) {
      Text(this.partialText)
        .fontSize(this.sizeFor(p))
        .lineHeight(this.lineFor(p))
        .fontWeight(this.weightFor(p))
        .fontColor($r('app.color.brand_primary'))
        .width('100%')
    } else if (p.id === this.partialId) {
      Text('翻译中…')
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
    } else if (p.status === ParaStatus.FAILED) {
      Text('这一段翻译失败，可再次点击翻译重试')
        .fontSize(12)
        .fontColor($r('app.color.danger'))
        .width('100%')
    } else if (this.mode === MODE_TARGET) {
      // 纯译文模式下还没翻译：用浅色保留原文，避免整章空白
      this.runsText(parseRuns(p.runs), this.sizeFor(p), this.lineFor(p), this.weightFor(p), true)
    }
  }

  @Builder
  paragraphView(p: Paragraph) {
    if (p.type === ParaType.DIVIDER) {
      Text('* * *')
        .fontSize(this.fontSize() - 2)
        .fontColor($r('app.color.text_tertiary'))
        .textAlign(TextAlign.Center)
        .width('100%')
        .margin({ top: 10, bottom: 10 })
    } else {
      Column({ space: 6 }) {
        if (this.mode === MODE_SOURCE) {
          this.runsText(parseRuns(p.runs), this.sizeFor(p), this.lineFor(p), this.weightFor(p), false)
        } else if (this.mode === MODE_BOTH) {
          // 对照模式：原文在上、译文在下
          this.runsText(parseRuns(p.runs), this.srcSize(p), this.srcLine(p),
            this.refOnly(p) ? FontWeight.Normal : this.weightFor(p), this.refOnly(p))
          this.translatedPart(p)
        } else {
          this.translatedPart(p)
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }

  /**
   * 列表项 key 必须带上状态与流式计数。
   * ArkUI 的 ForEach 只按 key 差量更新，key 不变就不会重绘 ——
   * 译文到位、流式文本变化都必须体现在 key 上，否则界面不会刷新。
   */
  private itemKey(p: Paragraph, i: number): string {
    const tick = p.id === this.partialId ? this.partialTick : 0;
    return `${p.id}_${p.status}_${tick}_${this.mode}_${this.fontStep}`;
  }

  /* ------------------------- 目录 ------------------------- */

  @Builder
  tocSheet() {
    Column() {
      Row() {
        Text('目录')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text(`${this.current + 1} / ${this.chapters.length} 章`)
          .fontSize(13)
          .fontColor($r('app.color.text_tertiary'))
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 4, bottom: 10 })

      Divider().color($r('app.color.divider')).margin({ left: 20, right: 20 })

      List({ scroller: this.tocScroller, space: 0 }) {
        ForEach(this.chapters, (c: Chapter, i: number) => {
          ListItem() {
            Column({ space: 4 }) {
              Row() {
                Text(c.title.length > 0 ? c.title : `第 ${i + 1} 章`)
                  .fontSize(15)
                  .fontColor(i === this.current ? $r('app.color.brand_primary') : $r('app.color.text_primary'))
                  .fontWeight(i === this.current ? FontWeight.Medium : FontWeight.Normal)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                if (c.status === ChapterStatus.TRANSLATED) {
                  Text('已译')
                    .fontSize(10)
                    .fontColor($r('app.color.brand_primary'))
                    .backgroundColor($r('app.color.brand_soft'))
                    .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                    .borderRadius(6)
                    .margin({ left: 8 })
                }
                if (i === this.current) {
                  Text('· 阅读中')
                    .fontSize(11)
                    .fontColor($r('app.color.brand_primary'))
                    .margin({ left: 8 })
                }
              }
              .width('100%')

              // 摘要不进正文，只在目录里露一行：忘了前情时扫一眼就够，
              // 同时它也是「这一章确实读完并记住了」的可见凭据
              if (c.summary.length > 0) {
                Text(c.summary)
                  .fontSize(11)
                  .fontColor($r('app.color.text_tertiary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding({ left: 20, right: 20, top: 12, bottom: 12 })
            .onClick(() => {
              this.showToc = false;
              this.gotoChapter(i);
            })
          }
        }, (c: Chapter) => `${c.id}_${c.status}_${c.summary.length}`)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)

      Divider().color($r('app.color.divider')).margin({ left: 20, right: 20 })

      // 整本书级别的操作放在目录里：它们本来就属于「全书」而不是「当前这一屏」
      Column({ space: 8 }) {
        Row({ space: 10 }) {
          Button('术语表')
            .fontSize(13)
            .height(38)
            .layoutWeight(1)
            .backgroundColor($r('app.color.page_background'))
            .fontColor($r('app.color.text_primary'))
            .onClick(() => {
              this.goTerms();
            })
          Button('连翻 5 章')
            .fontSize(13)
            .height(38)
            .layoutWeight(1)
            .backgroundColor($r('app.color.brand_soft'))
            .fontColor($r('app.color.brand_primary'))
            .enabled(!this.seqRunning && !this.translating && this.current < this.chapters.length - 1)
            .onClick(() => {
              this.startSequence(5);
            })
        }
        .width('100%')

        Row({ space: 10 }) {
          Button('连翻 10 章')
            .fontSize(13)
            .height(38)
            .layoutWeight(1)
            .backgroundColor($r('app.color.brand_soft'))
            .fontColor($r('app.color.brand_primary'))
            .enabled(!this.seqRunning && !this.translating && this.current < this.chapters.length - 1)
            .onClick(() => {
              this.startSequence(10);
            })
          Button('翻完剩余')
            .fontSize(13)
            .height(38)
            .layoutWeight(1)
            .backgroundColor($r('app.color.brand_primary'))
            .fontColor(Color.White)
            .enabled(!this.seqRunning && !this.translating && this.current < this.chapters.length - 1)
            .onClick(() => {
              this.startSequence(0);
            })
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 10 })

      Divider().color($r('app.color.divider')).margin({ left: 20, right: 20, top: 10 })

      Row({ space: 14 }) {
        Text('字号')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
        Button('A-')
          .fontSize(13)
          .height(32)
          .width(52)
          .backgroundColor($r('app.color.page_background'))
          .fontColor($r('app.color.text_primary'))
          .enabled(this.fontStep > 0)
          .onClick(() => this.adjustFont(-1))
        Text(`${this.fontSize()}`)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width(24)
          .textAlign(TextAlign.Center)
        Button('A+')
          .fontSize(13)
          .height(32)
          .width(52)
          .backgroundColor($r('app.color.page_background'))
          .fontColor($r('app.color.text_primary'))
          .enabled(this.fontStep < FONT_STEPS.length - 1)
          .onClick(() => this.adjustFont(1))
        Blank()
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 10, bottom: 16 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.card_background'))
  }

  /* ------------------------- 页面 ------------------------- */

  build() {
    Column() {
      // 顶栏
      Row({ space: 10 }) {
        Text('返回')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .onClick(() => this.goBack())

        Text(this.chapters.length > 0 ? this.chapters[this.current].title : (this.work?.title ?? ''))
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .textAlign(TextAlign.Center)

        Text(MODE_NAMES[this.mode])
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .backgroundColor($r('app.color.page_background'))
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .borderRadius(10)
          .onClick(() => this.cycleMode())

        Text('目录')
          .fontSize(14)
          .fontColor($r('app.color.brand_primary'))
          .onClick(() => {
            this.showToc = true;
            setTimeout(() => {
              this.tocScroller.scrollToIndex(Math.max(this.current - 2, 0));
            }, 60);
          })
      }
      .width('100%')
      .padding({ left: $r('app.float.page_padding'), right: $r('app.float.page_padding'), top: 12, bottom: 10 })

      // 连翻横幅：明确告诉用户「还在跑、跑到第几章」，并且随时能停
      if (this.seqRunning) {
        Row({ space: 10 }) {
          Text(`连续翻译 ${this.seqChapter}/${this.seqTotal} 章`)
            .fontSize(12)
            .fontColor($r('app.color.brand_primary'))
          Blank()
          Text('停止')
            .fontSize(12)
            .fontColor($r('app.color.brand_primary'))
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .borderRadius(10)
            .backgroundColor($r('app.color.page_background'))
            .onClick(() => this.stopSequence())
        }
        .width('100%')
        .padding({ left: $r('app.float.page_padding'), right: $r('app.float.page_padding'), top: 6, bottom: 6 })
        .backgroundColor($r('app.color.brand_soft'))
      }

      // 翻译进度条：只在翻译时占位，平时不打扰
      if (this.translating) {
        Row() {
          Row()
            .height(2)
            .width(this.transTotal > 0 ? `${Math.min(100, Math.round(this.transDone * 100 / this.transTotal))}%` : '10%')
            .backgroundColor($r('app.color.brand_primary'))
        }
        .width('100%')
        .height(2)
        .backgroundColor($r('app.color.divider'))
      }

      Divider().color($r('app.color.divider'))

      // 正文
      if (this.loading) {
        Column() {
          LoadingProgress().width(36).height(36).color($r('app.color.brand_primary'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.errorMsg.length > 0) {
        Column({ space: 12 }) {
          Text(this.errorMsg)
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
            .padding({ left: 24, right: 24 })
          Button('返回书架').onClick(() => this.goBack())
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ scroller: this.listScroller, space: 14 }) {
          ForEach(this.paragraphs, (p: Paragraph, i: number) => {
            ListItem() {
              this.paragraphView(p)
            }
          }, (p: Paragraph, i: number) => this.itemKey(p, i))
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 22, right: 22, top: 16 })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .contentEndOffset(40)
        .onScrollIndex((start: number) => {
          this.firstVisible = start;
          this.saveProgressThrottled();
        })
      }

      Divider().color($r('app.color.divider'))

      // 底栏
      Row({ space: 10 }) {
        Button('上一章')
          .fontSize(13)
          .height(36)
          .width(84)
          .backgroundColor($r('app.color.page_background'))
          .fontColor(this.current > 0 ? $r('app.color.text_primary') : $r('app.color.text_tertiary'))
          .enabled(this.current > 0 && !this.loading && !this.seqRunning)
          .onClick(() => this.gotoChapter(this.current - 1))

        Button(this.translateLabel())
          .fontSize(13)
          .height(36)
          .layoutWeight(1)
          .backgroundColor(this.translating ? $r('app.color.brand_soft') : $r('app.color.brand_primary'))
          .fontColor(this.translating ? $r('app.color.brand_primary') : Color.White)
          .enabled(!this.loading && this.paragraphs.length > 0)
          .onClick(() => {
            if (this.seqRunning) {
              this.stopSequence();
            } else {
              this.startTranslate();
            }
          })

        Button('下一章')
          .fontSize(13)
          .height(36)
          .width(84)
          .backgroundColor($r('app.color.brand_primary'))
          .fontColor(Color.White)
          .enabled(this.current < this.chapters.length - 1 && !this.loading && !this.seqRunning)
          .onClick(() => this.gotoChapter(this.current + 1))
      }
      .width('100%')
      .padding({ left: $r('app.float.page_padding'), right: $r('app.float.page_padding'), top: 8, bottom: 12 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .bindSheet($$this.showToc, this.tocSheet(), {
      height: SheetSize.LARGE,
      dragBar: true,
      showClose: false,
      backgroundColor: $r('app.color.card_background')
    })
  }
}
