import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { webview } from '@kit.ArkWeb';
import { DuplicateError, Importer } from '../parser/Importer';
import { FicHub, FicMeta } from '../fetch/FicHub';
import { AgentHooks, FinderResult, RunControl } from '../fetch/FinderTypes';
import { FinderAgent } from '../fetch/FinderAgent';
import { HeadlessRenderer } from '../fetch/HeadlessRenderer';
import { PendingItem, PendingStore } from '../fetch/PendingStore';
import { Bubble, SessionData, SessionMeta, SessionStore } from '../fetch/SessionStore';
import { ChatMessage } from '../provider/LlmProvider';
import { ProviderConfig, Settings } from '../common/Settings';
import { Log } from '../common/Logger';

/** 从系统分享进入时带进来的路由参数 */
interface SearchPageParams {
  sharedUrl: string;
}

const EXAMPLES: string[] = [
  'Snape 主角的经典长文',
  'HP 时间旅行同人，要长一点的',
  'Draco 视角的战后文'
];

/**
 * AI 找文（对话式）：用户和模型来回聊，模型边想边搜边核实，
 * 命中即下载到待入库区，确认后再进书架。
 *
 * 与上一版的区别：不再是"一次检索一个结果页"，而是完整的会话 ——
 * 每一轮对话都带着上文，用户可以直接追问"换一套""要更长的"；
 * 模型的思考过程（每次调工具前的判断）实时上屏。
 * 待入库区固定在列表底部，不混进对话流。
 */
@Entry
@Component
struct SearchPage {
  private scroller: Scroller = new Scroller();
  /** 发给模型的消息历史（跨回合复用，就是"对话记忆"） */
  private history: ChatMessage[] = [];
  /** 当前回合的停止闸门：点「停止」时用它打断在途请求 */
  private run: RunControl = new RunControl();
  private seq: number = 0;
  private lastScrollAt: number = 0;

  @State bubbles: Bubble[] = [];
  @State busy: boolean = false;
  @State statusText: string = '';
  @State query: string = '';
  @State pendingList: PendingItem[] = [];
  /** 本次会话里已经入架的作品 sourceUrl，用于把按钮置灰 */
  @State shelfUrls: string[] = [];
  @State expandedIds: string[] = [];
  @State showPending: boolean = false;
  /** 正在流式输出的文本（模型一边生成一边覆盖这里） */
  /** 正在流式输出的文本（模型一边生成一边覆盖这里） */
  @State streamText: string = '';
  @State streaming: boolean = false;

  /** 当前会话：空串表示还没落盘（发出第一条消息时才建） */
  private sessionId: string = '';
  private sessionCreatedAt: number = 0;
  @State sessionTitle: string = '';
  /** 历史会话列表（最近更新在前） */
  @State sessions: SessionMeta[] = [];
  @State showSessions: boolean = false;
  /** 落盘节流：一轮对话里气泡会密集变化，攒 400ms 写一次就够 */
  private persistTimer: number = -1;

  /** 内置渲染器的隐藏 Web 组件：首次渲染请求才挂载（惰性），省启动内存 */
  @State showRendererWeb: boolean = false;
  private renderCtrl: webview.WebviewController = new webview.WebviewController();

  aboutToAppear(): void {
    this.readRouteParams();
    this.loadPending();
    this.restoreLastSession();
    HeadlessRenderer.setHost({
      requestMount: (): void => {
        this.showRendererWeb = true;
      },
      remount: (): void => {
        // 旧 controller 已和 Web 组件脱钩：把隐藏组件卸掉再挂一个新的。
        // 中间隔一帧，否则属性没变化 ArkUI 不会重建节点。
        this.showRendererWeb = false;
        setTimeout((): void => {
          this.showRendererWeb = true;
        }, 50);
      }
    });
  }

  /**
   * 页面销毁时通知渲染器：静态 ctrl 必须清空。
   * 否则页面重建后仍指向上一页那个已卸载组件的 controller，
   * loadUrl 会抛「must be associated with a Web component」。
   */
  aboutToDisappear(): void {
    // 离开页面前把最后一版气泡写下去（节流器里可能还有没落盘的内容）
    this.flushPersist();
    HeadlessRenderer.detachController(this.renderCtrl);
  }

  /**
   * 回到页面时接着上次的会话。
   * 有分享链接进来（query 已被预填）时不恢复：那是新任务，不该混进旧对话。
   */
  private restoreLastSession(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (this.query.length > 0) {
      this.refreshSessions();
      return;
    }
    SessionStore.list(ctx).then((list: SessionMeta[]) => {
      this.sessions = list;
      if (list.length === 0) {
        return;
      }
      return SessionStore.load(ctx, list[0].id).then((data: SessionData | null) => {
        if (data === null) {
          return;
        }
        this.applySession(data);
      });
    }).catch((e: Error) => {
      Log.w(`恢复会话失败：${e.message}`);
    });
  }

  private applySession(data: SessionData): void {
    this.sessionId = data.id;
    this.sessionCreatedAt = data.createdAt;
    this.sessionTitle = data.title;
    this.bubbles = data.bubbles;
    // 历史里的 system 是存那一刻的提示词，换成当前这份再接着聊
    const kept: ChatMessage[] = [];
    for (let i = 0; i < data.history.length; i++) {
      if (data.history[i].role !== 'system') {
        kept.push(data.history[i]);
      }
    }
    const sys: ChatMessage = { role: 'system', content: FinderAgent.systemPrompt() };
    this.history = [sys].concat(kept);
    // 气泡 id 里带着旧的 seq（b12/h13…），接着往下编号才不会再撞 id
    let maxSeq = 0;
    for (let i = 0; i < data.bubbles.length; i++) {
      const n = Number(data.bubbles[i].id.replace(/[^0-9]/g, ''));
      if (n > maxSeq) {
        maxSeq = n;
      }
    }
    this.seq = maxSeq + 1;
    this.expandedIds = [];
    this.streamText = '';
    this.streaming = false;
    this.statusText = '';
    this.scrollToBottom();
  }

  private refreshSessions(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    SessionStore.list(ctx).then((list: SessionMeta[]) => {
      this.sessions = list;
    }).catch(() => {
    });
  }

  /** 发出第一条消息时建会话，标题取用户这句的前 24 字 */
  private ensureSession(firstText: string): void {
    if (this.sessionId.length > 0) {
      return;
    }
    this.sessionId = SessionStore.newId();
    this.sessionCreatedAt = Date.now();
    const t = firstText.replace(/\s+/g, ' ').trim();
    this.sessionTitle = t.length > 24 ? `${t.substring(0, 24)}…` : t;
  }

  private schedulePersist(): void {
    if (this.sessionId.length === 0 || this.persistTimer >= 0) {
      return;
    }
    this.persistTimer = setTimeout(() => {
      this.persistTimer = -1;
      this.persist();
    }, 400);
  }

  private flushPersist(): void {
    if (this.persistTimer >= 0) {
      clearTimeout(this.persistTimer);
      this.persistTimer = -1;
    }
    this.persist();
  }

  /** 落盘当前会话；没有气泡就不写（新建后还没说话的空会话不占列表） */
  private persist(): void {
    if (this.sessionId.length === 0 || this.bubbles.length === 0) {
      return;
    }
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const data: SessionData = {
      id: this.sessionId,
      title: this.sessionTitle.length > 0 ? this.sessionTitle : '未命名会话',
      createdAt: this.sessionCreatedAt,
      updatedAt: Date.now(),
      bubbles: this.bubbles,
      history: this.history
    };
    SessionStore.save(ctx, data).then(() => {
      this.refreshSessions();
    }).catch((e: Error) => {
      Log.w(`保存会话失败：${e.message}`);
    });
  }

  /** 打开历史会话：先把当前这版存好，再换过去 */
  private openSession(id: string): void {
    if (this.busy) {
      this.getUIContext().getPromptAction().showToast({ message: '先点输入框右边的「停止」结束这一轮' });
      return;
    }
    if (id === this.sessionId) {
      this.showSessions = false;
      return;
    }
    this.flushPersist();
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    SessionStore.load(ctx, id).then((data: SessionData | null) => {
      if (data === null) {
        this.getUIContext().getPromptAction().showToast({ message: '这个会话已经读不到了' });
        this.refreshSessions();
        return;
      }
      this.applySession(data);
      this.showSessions = false;
    }).catch((e: Error) => {
      Log.w(`打开会话失败：${e.message}`);
    });
  }

  /** 删除一个会话；删的是当前这个就顺手清屏，回到空态 */
  private removeSession(id: string): void {
    if (this.busy) {
      this.getUIContext().getPromptAction().showToast({ message: '先点输入框右边的「停止」结束这一轮' });
      return;
    }
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    SessionStore.remove(ctx, id).then(() => {
      if (id === this.sessionId) {
        this.resetToBlank();
      }
      this.refreshSessions();
      this.getUIContext().getPromptAction().showToast({ message: '会话已删除' });
    }).catch((e: Error) => {
      Log.w(`删除会话失败：${e.message}`);
    });
  }

  /** 系统分享进来时预填链接，用户确认后自己发出去 */
  private readRouteParams(): void {
    const params = this.getUIContext().getRouter().getParams() as SearchPageParams;
    if (params !== undefined && params !== null && params.sharedUrl !== undefined) {
      this.query = params.sharedUrl;
    }
  }

  private loadPending(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    PendingStore.list(ctx).then((items: PendingItem[]) => {
      this.pendingList = items;
    }).catch(() => {
    });
  }

  private pushBubble(kind: string, text: string): void {
    this.seq++;
    const b: Bubble = { id: `b${this.seq}`, kind: kind, text: text, meta: null };
    this.bubbles = this.bubbles.concat([b]);
    this.scrollToBottom();
    this.schedulePersist();
  }

  private pushHit(m: FicMeta): void {
    this.seq++;
    const b: Bubble = { id: `h${this.seq}`, kind: 'hit', text: m.title, meta: m };
    this.bubbles = this.bubbles.concat([b]);
    this.scrollToBottom();
    this.schedulePersist();
  }

  private isExpanded(id: string): boolean {
    return this.expandedIds.indexOf(id) >= 0;
  }

  private toggleExpand(id: string): void {
    if (this.isExpanded(id)) {
      this.expandedIds = this.expandedIds.filter((x: string) => x !== id);
    } else {
      this.expandedIds = this.expandedIds.concat([id]);
    }
  }

  private scrollToBottom(): void {
    setTimeout(() => {
      try {
        this.scroller.scrollEdge(Edge.Bottom);
      } catch (e) {
        Log.d('滚动到底部失败');
      }
    }, 60);
  }

  /** 流式期间每秒几十个 delta，滚动要节流，否则 setTimeout 会堆积 */
  private scrollToBottomThrottled(): void {
    const now = Date.now();
    if (now - this.lastScrollAt < 200) {
      return;
    }
    this.lastScrollAt = now;
    this.scrollToBottom();
  }

  /** 发送一条消息，跑一个回合 */
  private async send(): Promise<void> {
    if (this.busy) {
      return;
    }
    const text = this.query.trim();
    if (text.length === 0) {
      return;
    }
    // 会话在第一次真正说话时建立（标题也取这句），空会话不占历史列表
    this.ensureSession(text);
    const cfg = await Settings.load();
    if (!Settings.ready(cfg)) {
      this.pushBubble('user', text);
      this.pushBubble('error', '还没配置模型 API Key，先去设置里填一下');
      this.query = '';
      return;
    }

    this.query = '';
    this.pushBubble('user', text);
    this.busy = true;
    this.run = new RunControl();
    this.statusText = '模型正在思考…';
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;

    try {
      await this.runAgentTurn(text, cfg, ctx);
    } catch (e) {
      const why = (e as Error).message;
      this.pushBubble('error', why);
      Log.e(`找文失败：${why}`);
    } finally {
      this.busy = false;
      this.statusText = '';
      this.streaming = false;
      this.streamText = '';
      this.scrollToBottom();
      // 这一轮的最终回复和工具调用都定稿了，立刻写盘
      this.flushPersist();
    }
  }

  /**
   * 交给 Agent 跑一个回合：模型自己决定用哪些工具、要不要过 FicHub。
   * 思考与工具动作按发生顺序实时上屏。
   */
  private async runAgentTurn(text: string, cfg: ProviderConfig, ctx: common.UIAbilityContext): Promise<void> {
    const userMsg: ChatMessage = { role: 'user', content: text };
    this.history.push(userMsg);
    if (cfg.searchKey.trim().length === 0) {
      this.pushBubble('think', '还没配搜索 Key，我用不了联网搜索，但可以处理你直接给的链接（作品页或文件直链）。想让它自己找文，去设置里填个 Tavily Key。');
    }

    const hooks: AgentHooks = {
      onRoundStart: (): string => {
        this.seq++;
        this.streamText = '';
        this.streaming = true;
        this.scrollToBottom();
        return `t${this.seq}`;
      },
      onThinkDelta: (id: string, text: string) => {
        this.streamText = text;
        this.scrollToBottomThrottled();
      },
      onRoundEnd: (id: string, isFinal: boolean) => {
        const text = this.streamText;
        this.streamText = '';
        this.streaming = false;
        if (text.trim().length === 0) {
          return;
        }
        // 中间轮是思考（灰底小字），收尾轮是最终回复（白底正文）
        const b: Bubble = { id: id, kind: isFinal ? 'reply' : 'think', text: text, meta: null };
        this.bubbles = this.bubbles.concat([b]);
        this.scrollToBottom();
        this.schedulePersist();
      },
      onAction: (t: string) => {
        this.pushBubble('action', t);
      },
      onHit: (m: FicMeta) => {
        this.pushHit(m);
      },
      onDownloaded: (item: PendingItem) => {
        // 立刻把新条目塞进列表并展开、滚到底：否则卡片躺在对话流末尾，
        // 用户只看得到一句「已下载到待入库区」，屏幕上却什么都没有
        this.pendingList =
          [item].concat(this.pendingList.filter((p: PendingItem) => p.epubPath !== item.epubPath));
        this.showPending = true;
        this.scrollToBottom();
      },
      onStatus: (t: string) => {
        this.statusText = t;
      }
    };
    const res: FinderResult = await FinderAgent.chatTurn(this.history, cfg, ctx, hooks, this.run);
    if (res.downloaded.length > 0) {
      this.showPending = true;
      this.loadPending();
      this.scrollToBottom();
      this.getUIContext().getPromptAction().showToast({
        message: `已下载 ${res.downloaded.length} 本到待入库区`
      });
    }
  }

  /** 停止当前回合：立刻打断在途请求，循环在下一个检查点退出 */
  private stop(): void {
    if (!this.busy) {
      return;
    }
    // 正在下载文件时没法中途掐断网络流，会把当前这一步走完再退出
    this.statusText = '正在停止…（正在下载的那本会先完成）';
    this.run.cancel();
  }

  private newChat(): void {
    if (this.busy) {
      this.getUIContext().getPromptAction().showToast({ message: '先点输入框右边的「停止」结束这一轮' });
      return;
    }
    // 先把当前这版存进历史，再开新的——否则「新对话」等于把上文丢了
    this.flushPersist();
    this.resetToBlank();
    this.showSessions = false;
  }

  /** 清屏回到空态，并断开与当前会话的绑定（下次说话才建新会话） */
  private resetToBlank(): void {
    this.sessionId = '';
    this.sessionTitle = '';
    this.sessionCreatedAt = 0;
    this.history = [];
    this.bubbles = [];
    this.expandedIds = [];
    this.statusText = '';
    this.streamText = '';
    this.streaming = false;
    this.seq = 0;
  }

  /** 待入库 → 书架 */
  private async importPending(p: PendingItem): Promise<void> {
    if (this.busy) {
      return;
    }
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.busy = true;
    this.statusText = `正在导入《${p.title}》…`;
    try {
      const res = await Importer.importFromPath(ctx, p.epubPath,
        `${FicHub.fileSafeName(p.title)}.epub`, (msg: string) => {
          this.statusText = msg;
        }, false);
      await PendingStore.remove(ctx, p);
      this.shelfUrls = this.shelfUrls.concat([p.sourceUrl]);
      this.pushBubble('action', `✅《${res.title}》已加入书架（${res.chapters} 章）`);
      this.getUIContext().getPromptAction().showToast({ message: `《${res.title}》已加入书架` });
    } catch (e) {
      if (e instanceof DuplicateError) {
        await PendingStore.remove(ctx, p);
        this.shelfUrls = this.shelfUrls.concat([p.sourceUrl]);
        this.pushBubble('action', `《${(e as DuplicateError).existingTitle}》已在书架，待入库文件已清除`);
      } else {
        this.pushBubble('error', `导入失败：${(e as Error).message}`);
        Log.e(`待入库导入失败：${(e as Error).message}`);
      }
    } finally {
      this.busy = false;
      this.statusText = '';
      this.pendingList = await PendingStore.list(ctx);
      if (this.pendingList.length === 0) {
        this.showPending = false;
      }
    }
  }

  /**
   * 一键把待入库区全部加入书架。
   *
   * 模型现在一次会下 2-3 本候选，逐本点「加入书架」太啰嗦 ——
   * 用户的预期是「搜完点一下就都有书读」。
   */
  private async importAllPending(): Promise<void> {
    if (this.busy) {
      return;
    }
    const snapshot: PendingItem[] = this.pendingList;
    if (snapshot.length === 0) {
      return;
    }
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.busy = true;
    let done = 0;
    let failed = 0;
    try {
      for (let i = 0; i < snapshot.length; i++) {
        const p = snapshot[i];
        this.statusText = `正在导入《${p.title}》…（${i + 1}/${snapshot.length}）`;
        try {
          const res = await Importer.importFromPath(ctx, p.epubPath,
            `${FicHub.fileSafeName(p.title)}.epub`, (msg: string) => {
              this.statusText = msg;
            }, false);
          await PendingStore.remove(ctx, p);
          this.shelfUrls = this.shelfUrls.concat([p.sourceUrl]);
          done++;
          Log.i(`批量入库：《${res.title}》`);
        } catch (e) {
          if (e instanceof DuplicateError) {
            await PendingStore.remove(ctx, p);
            this.shelfUrls = this.shelfUrls.concat([p.sourceUrl]);
            done++;
          } else {
            failed++;
            Log.e(`批量入库失败《${p.title}》：${(e as Error).message}`);
          }
        }
      }
      let msg = `✅ 已加入书架 ${done} 部`;
      if (failed > 0) {
        msg = `${msg}，${failed} 部失败（文件可能不完整，可以单独移除后重下）`;
      }
      this.pushBubble('action', msg);
      this.getUIContext().getPromptAction().showToast({ message: `已加入书架 ${done} 部` });
    } finally {
      this.busy = false;
      this.statusText = '';
      this.pendingList = await PendingStore.list(ctx);
      if (this.pendingList.length === 0) {
        this.showPending = false;
      }
    }
  }

  private async removePending(p: PendingItem): Promise<void> {
    if (this.busy) {
      return;
    }
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await PendingStore.remove(ctx, p);
    this.pendingList = await PendingStore.list(ctx);
    if (this.pendingList.length === 0) {
      this.showPending = false;
    }
  }

  /** 这个链接是否已经在待入库区（模型自动下载的，等用户确认） */
  private isPending(srcUrl: string): boolean {
    return this.findPending(srcUrl) !== null;
  }

  private findPending(srcUrl: string): PendingItem | null {
    for (let i = 0; i < this.pendingList.length; i++) {
      if (this.pendingList[i].sourceUrl === srcUrl) {
        return this.pendingList[i];
      }
    }
    return null;
  }

  /** 按钮文案：已入架 / 已有文件待入库 / 还没下 */
  private hitLabel(srcUrl: string): string {
    if (this.inShelf(srcUrl)) {
      return '已在书架';
    }
    if (this.isPending(srcUrl)) {
      return '加入书架';
    }
    return '下载';
  }

  /** 只有「已在书架」和「正在忙」时不可点：待入库的那本可以直接入架，不用重下 */
  private hitBusy(srcUrl: string): boolean {
    return this.busy || this.inShelf(srcUrl);
  }

  /**
   * 点命中卡片的「下载」按钮：下载 → 解析 → 直接进书架。
   *
   * 用户的预期是「点一下就有书读」，所以这里不再经过待入库区中转：
   * 下载产物落在 cacheDir，喂给 Importer 解析完就删掉。
   * （模型自动下载的仍然进待入库区，等用户确认。）
   */
  private async downloadHit(meta: FicMeta): Promise<void> {
    if (this.busy) {
      return;
    }
    if (this.inShelf(meta.sourceUrl)) {
      this.getUIContext().getPromptAction().showToast({ message: '这本已经在书架了' });
      return;
    }
    // 模型已经下过了：文件就在待入库区，直接入架，不再重下一遍
    const queued = this.findPending(meta.sourceUrl);
    if (queued !== null) {
      await this.importPending(queued);
      return;
    }
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.busy = true;
    this.statusText = `正在下载《${meta.title}》…`;
    let epubPath = '';
    try {
      epubPath = await FicHub.downloadEpub(ctx, meta, (msg: string) => {
        this.statusText = msg;
      });
      this.statusText = `正在解析《${meta.title}》…`;
      const res = await Importer.importFromPath(ctx, epubPath,
        `${FicHub.fileSafeName(meta.title)}.epub`, (msg: string) => {
          this.statusText = msg;
        }, false);
      this.shelfUrls = this.shelfUrls.concat([meta.sourceUrl]);
      this.pushBubble('action', `✅《${res.title}》已加入书架（${res.chapters} 章）`);
      this.getUIContext().getPromptAction().showToast({ message: `《${res.title}》已加入书架` });
    } catch (e) {
      if (e instanceof DuplicateError) {
        this.shelfUrls = this.shelfUrls.concat([meta.sourceUrl]);
        this.pushBubble('action', `《${(e as DuplicateError).existingTitle}》已经在书架里了`);
      } else {
        const why = (e as Error).message;
        this.pushBubble('error', `下载失败：${why}`);
        Log.e(`命中卡片下载失败：${why}`);
      }
    } finally {
      this.busy = false;
      this.statusText = '';
      if (epubPath.length > 0) {
        try {
          fs.unlinkSync(epubPath);
        } catch (err) {
          // 临时文件，删不掉也无所谓
        }
      }
      this.pendingList = await PendingStore.list(ctx);
    }
  }

  /** 这次会话里已经下载并入架的作品（按钮据此变成「已在书架」） */
  private inShelf(srcUrl: string): boolean {
    return this.shelfUrls.indexOf(srcUrl) >= 0;
  }

  private goBack(): void {
    this.getUIContext().getRouter().back();
  }

  @Builder
  header() {
    Row({ space: 10 }) {
      Text('AI 找文')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
      Blank()
      Text('历史')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .padding({ left: 10, right: 10, top: 5, bottom: 5 })
        .backgroundColor($r('app.color.card_background'))
        .borderRadius(13)
        .onClick(() => {
          this.refreshSessions();
          this.showSessions = true;
        })
      Text('新对话')
        .fontSize(13)
        .fontColor($r('app.color.brand_primary'))
        .padding({ left: 10, right: 10, top: 5, bottom: 5 })
        .backgroundColor($r('app.color.card_background'))
        .borderRadius(13)
        .onClick(() => this.newChat())
      Text('返回')
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
        .onClick(() => this.goBack())
    }
    .width('100%')
    .padding({ left: $r('app.float.page_padding'), right: $r('app.float.page_padding'), top: 12, bottom: 10 })
  }

  @Builder
  emptyState() {
    Column({ space: 14 }) {
      Text('想找什么样的文？')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      Text('说一句想找什么，或者直接把作品链接丢给它。怎么找由它自己判断——搜网页、读页面、转 EPUB、下直链都由模型决定，过程和思考实时显示在这里。')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .lineHeight(20)
        .textAlign(TextAlign.Center)
      Column({ space: 8 }) {
        ForEach(EXAMPLES, (q: string) => {
          Text(q)
            .fontSize(13)
            .fontColor($r('app.color.brand_primary'))
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .backgroundColor($r('app.color.card_background'))
            .borderRadius(16)
            .onClick(() => {
              this.query = q;
              this.send();
            })
        }, (q: string) => q)
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 40, bottom: 20 })
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  hitCard(m: FicMeta) {
    Column({ space: 5 }) {
      Row({ space: 6 }) {
        Text('📖').fontSize(13)
        Text(m.title)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      Text(`${m.author.length > 0 ? m.author + ' · ' : ''}${m.chapters} 章 · ${m.words} 词`)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      if (m.info.length > 0) {
        Text(m.info)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      Row() {
        Blank()
        Button(this.hitLabel(m.sourceUrl))
          .height(30)
          .fontSize(12)
          .backgroundColor($r('app.color.brand_primary'))
          .fontColor(Color.White)
          .borderRadius(15)
          .padding({ left: 18, right: 18 })
          .opacity(this.hitBusy(m.sourceUrl) ? 0.45 : 1)
          .enabled(!this.hitBusy(m.sourceUrl))
          .onClick(() => {
            this.downloadHit(m);
          })
      }
      .width('100%')
      .margin({ top: 3 })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(12)
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(12)
  }

  @Builder
  bubble(b: Bubble) {
    if (b.kind === 'user') {
      Row() {
        Blank()
        Text(b.text)
          .fontSize(14)
          .fontColor(Color.White)
          .lineHeight(21)
          .constraintSize({ maxWidth: '80%' })
          .padding({ left: 13, right: 13, top: 9, bottom: 9 })
          .backgroundColor($r('app.color.brand_primary'))
          .borderRadius(14)
      }
      .width('100%')
    } else if (b.kind === 'think') {
      Row({ space: 7 }) {
        Text('💭').fontSize(12)
        Text(b.text)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .lineHeight(19)
          .maxLines(this.isExpanded(b.id) ? 200 : 5)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .alignItems(VerticalAlign.Top)
      .width('100%')
      .padding({ left: 10, right: 10, top: 8, bottom: 8 })
      .backgroundColor($r('app.color.card_background'))
      .borderRadius(10)
      .onClick(() => this.toggleExpand(b.id))
    } else if (b.kind === 'action') {
      Text(b.text)
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
        .lineHeight(17)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .padding({ left: 10, right: 4 })
    } else if (b.kind === 'hit') {
      this.hitCard(b.meta as FicMeta)
    } else if (b.kind === 'reply') {
      Text(b.text)
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .lineHeight(21)
        .width('100%')
        .padding(12)
        .backgroundColor($r('app.color.card_background'))
        .borderRadius(12)
    } else {
      Text(b.text)
        .fontSize(12)
        .fontColor($r('app.color.danger'))
        .lineHeight(18)
        .width('100%')
        .padding(10)
        .backgroundColor($r('app.color.card_background'))
        .borderRadius(10)
    }
  }

  /** 正在生成的这一轮：边流边显示，结束后由 onRoundEnd 定格成正式气泡 */
  @Builder
  streamingBubble() {
    Row({ space: 7 }) {
      Text('💭').fontSize(12)
      Text(this.streamText.length > 0 ? this.streamText : '思考中…')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .lineHeight(19)
        .layoutWeight(1)
    }
    .alignItems(VerticalAlign.Top)
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(10)
  }

  @Builder
  thinkingIndicator() {
    Row({ space: 8 }) {
      LoadingProgress().width(15).height(15).color($r('app.color.brand_primary'))
      Text(this.statusText.length > 0 ? this.statusText : '模型正在思考…')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ left: 10, top: 6, bottom: 6 })
  }

  @Builder
  pendingCard() {
    Column({ space: 2 }) {
      Row() {
        Text('📥 待入库')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text(`${this.pendingList.length} 部已下载`)
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
      }
      .width('100%')

      // 模型一次会下几本候选，用户只该点一次
      if (this.pendingList.length > 1) {
        Button(`全部加入书架（${this.pendingList.length} 部）`)
          .width('100%')
          .height(32)
          .fontSize(12)
          .backgroundColor($r('app.color.brand_primary'))
          .fontColor(Color.White)
          .borderRadius(16)
          .margin({ top: 6, bottom: 2 })
          .enabled(!this.busy)
          .onClick(() => {
            this.importAllPending();
          })
      }

      ForEach(this.pendingList, (p: PendingItem) => {
        Column({ space: 5 }) {
          Text(p.title)
            .fontSize(13)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(`${p.author.length > 0 ? p.author + ' · ' : ''}${p.chapters} 章 · ${p.words} 词`)
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Row({ space: 8 }) {
            Button('加入书架')
              .height(28)
              .fontSize(11)
              .backgroundColor($r('app.color.brand_primary'))
              .fontColor(Color.White)
              .borderRadius(14)
              .padding({ left: 12, right: 12 })
              .enabled(!this.busy)
              .onClick(() => {
                this.importPending(p);
              })
            Button('移除')
              .height(28)
              .fontSize(11)
              .backgroundColor($r('app.color.page_background'))
              .fontColor($r('app.color.text_secondary'))
              .borderRadius(14)
              .padding({ left: 12, right: 12 })
              .enabled(!this.busy)
              .onClick(() => {
                this.removePending(p);
              })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding({ top: 8, bottom: 8 })
      }, (p: PendingItem) => p.epubPath)
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(12)
  }

  @Builder
  inputBar() {
    Row({ space: 8 }) {
      TextInput({ text: this.query, placeholder: this.busy ? '正在找…可以点右边停止' : '说一句想看的文，或追问「换一批」…' })
        .layoutWeight(1)
        .height(42)
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_tertiary'))
        .backgroundColor($r('app.color.card_background'))
        .borderRadius(21)
        .enabled(!this.busy)
        .onChange((v: string) => {
          this.query = v;
        })
        .onSubmit(() => {
          this.send();
        })
      if (this.busy) {
        Button('停止')
          .width(66)
          .height(42)
          .fontSize(14)
          .backgroundColor($r('app.color.card_background'))
          .fontColor($r('app.color.danger'))
          .borderRadius(21)
          .onClick(() => {
            this.stop();
          })
      } else {
        Button('发送')
          .width(66)
          .height(42)
          .fontSize(14)
          .backgroundColor(this.query.trim().length === 0 ? '#B9AFA4' : $r('app.color.brand_primary'))
          .fontColor(Color.White)
          .borderRadius(21)
          .enabled(this.query.trim().length > 0)
          .onClick(() => {
            this.send();
          })
      }
    }
    .width('100%')
    .padding({ left: $r('app.float.page_padding'), right: $r('app.float.page_padding'), top: 8, bottom: 10 })
  }

  /** 列表里的时间：今年内只显示月-日 时:分，跨年补上年份 */
  private sessionTime(ms: number): string {
    const d = new Date(ms);
    const now = new Date();
    const p = (n: number): string => n < 10 ? `0${n}` : `${n}`;
    if (d.getFullYear() === now.getFullYear()) {
      return `${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
    }
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
  }

  /**
   * 历史会话面板：底部抽屉式，点上半屏空白处关闭。
   * 当前会话高亮，右侧「删除」逐条删；底部「新对话」等于存好当前再开一个。
   */
  @Builder
  sessionSheet() {
    Column() {
      Column()
        .layoutWeight(1)
        .width('100%')
        .onClick(() => {
          this.showSessions = false;
        })

      Column() {
        Row() {
          Text('历史会话')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Blank()
          Text('关闭')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .padding(4)
            .onClick(() => {
              this.showSessions = false;
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 10 })

        if (this.sessions.length === 0) {
          Text('还没有历史会话。发出第一条消息后会自动保存到这里。')
            .fontSize(13)
            .fontColor($r('app.color.text_tertiary'))
            .lineHeight(20)
            .width('100%')
            .padding({ left: 16, right: 16, top: 8, bottom: 16 })
        } else {
          List() {
            ForEach(this.sessions, (m: SessionMeta) => {
              ListItem() {
                Row({ space: 8 }) {
                  Column({ space: 4 }) {
                    Text(m.title)
                      .fontSize(14)
                      .fontColor($r('app.color.text_primary'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%')
                    Text(`${m.count} 条 · ${this.sessionTime(m.updatedAt)}`)
                      .fontSize(11)
                      .fontColor($r('app.color.text_tertiary'))
                      .width('100%')
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)

                  if (m.id === this.sessionId) {
                    Text('当前')
                      .fontSize(10)
                      .fontColor($r('app.color.brand_primary'))
                      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                      .backgroundColor($r('app.color.card_background'))
                      .borderRadius(8)
                  }
                  Text('删除')
                    .fontSize(12)
                    .fontColor($r('app.color.danger'))
                    .padding({ left: 8, right: 4, top: 8, bottom: 8 })
                    .onClick(() => {
                      this.removeSession(m.id);
                    })
                }
                .width('100%')
                .padding({ left: 16, right: 12, top: 10, bottom: 10 })
                .backgroundColor(m.id === this.sessionId ? $r('app.color.card_background') : Color.Transparent)
                .onClick(() => {
                  this.openSession(m.id);
                })
              }
            }, (m: SessionMeta) => `${m.id}_${m.updatedAt}`)
          }
          .layoutWeight(1)
          .width('100%')
          .scrollBar(BarState.Off)
        }

        Row() {
          Button('＋ 新对话')
            .width('100%')
            .height(40)
            .fontSize(14)
            .backgroundColor($r('app.color.brand_primary'))
            .fontColor(Color.White)
            .borderRadius(20)
            .enabled(!this.busy)
            .onClick(() => {
              this.newChat();
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 6, bottom: 12 })
      }
      .width('100%')
      .height('55%')
      .backgroundColor($r('app.color.page_background'))
      .borderRadius({ topLeft: 16, topRight: 16 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#66000000')
  }

  build() {
    Stack() {
      Column() {
      this.header()

      Scroll(this.scroller) {
        Column({ space: 10 }) {
          if (this.bubbles.length === 0) {
            this.emptyState()
          }

          ForEach(this.bubbles, (b: Bubble) => {
            this.bubble(b)
          }, (b: Bubble) => `${this.sessionId}:${b.id}`)

          // 流式输出中的这一轮
          if (this.streaming) {
            this.streamingBubble()
          }

          if (this.busy && this.statusText.length > 0 && !this.streaming) {
            this.thinkingIndicator()
          }

          // 待入库区固定在对话流末尾，不混进消息里
          if (this.pendingList.length > 0 && this.showPending) {
            this.pendingCard()
          }
        }
        .width('100%')
        .padding({ left: $r('app.float.page_padding'), right: $r('app.float.page_padding'), bottom: 16 })
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)

      // 常驻入口：用户滚上去了也总能看见「有几本已下好」，点一下直达
      if (this.pendingList.length > 0) {
        Row({ space: 6 }) {
          Text(`📥 待入库 ${this.pendingList.length} 部`)
            .fontSize(12)
            .fontColor($r('app.color.brand_primary'))
          Blank()
          Text(this.showPending ? '收起' : '展开')
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
        }
        .width('100%')
        .padding({ left: $r('app.float.page_padding'), right: $r('app.float.page_padding'), top: 6, bottom: 6 })
        .onClick(() => {
          if (this.showPending) {
            this.showPending = false;
          } else {
            this.showPending = true;
            this.scrollToBottom();
          }
        })
      }

      this.inputBar()

      // 内置渲染器宿主：1×1 隐藏组件，只有 JS 渲染降级时才真正加载页面。
      // 挂载由 HeadlessRenderer 首次请求触发（showRendererWeb），平时不存在。
      if (this.showRendererWeb) {
        Web({ src: 'about:blank', controller: this.renderCtrl })
          .width(1)
          .height(1)
          .onControllerAttached(() => {
            HeadlessRenderer.attachController(this.renderCtrl);
          })
          .onPageEnd((event: OnPageEndEvent) => {
            HeadlessRenderer.notifyPageEnd(event.url);
          })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))

      // 历史会话面板盖在最上层
      if (this.showSessions) {
        this.sessionSheet()
      }
    }
    .width('100%')
    .height('100%')
  }
}
