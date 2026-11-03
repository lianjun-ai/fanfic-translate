import { promptAction, window } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { Shelf, Work, Chapter } from '../model/Models';
import { WorkDao } from '../data/WorkDao';
import { ShelfDao } from '../data/ShelfDao';
import { ChapterDao } from '../data/ChapterDao';
import { Exporter } from '../export/Exporter';
import { ExportDialog } from './ExportDialog';
import { Log } from '../common/Logger';

function pad2(n: number): string {
  return n < 10 ? `0${n}` : `${n}`;
}

function formatDate(ts: number): string {
  const d = new Date(ts);
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
}

function formatWords(n: number): string {
  if (n >= 10000) {
    return `${(n / 10000).toFixed(1)} 万字`;
  }
  return `${n} 字`;
}

function sourceLabel(t: string): string {
  if (t === 'epub') {
    return 'EPUB';
  }
  if (t === 'txt') {
    return 'TXT';
  }
  if (t === 'html') {
    return 'HTML';
  }
  if (t === 'web') {
    return '网页';
  }
  return t.toUpperCase();
}

/** 「全部」用哨兵值，避免和「未分组」的空串撞车 */
const SCOPE_ALL: string = '__all__';

/**
 * 分组栏的一个标签。
 *
 * 数量放进数据里、而不是当 @Builder 的入参：@Builder 按值传参时不会建立
 * 状态依赖，书架数据变了数字也不会刷新（要杀掉进程重进才对）。这里让
 * count 成为数组元素的一部分，并在 ForEach 的 key 里带上它，数量一变
 * 这个标签就会重建，数字必定是新的。
 */
interface ScopeTabData {
  label: string;
  scope: string;
  count: number;
}

/** 新建分组：书架里唯一需要键盘输入的地方 */
@CustomDialog
struct GroupNameDialog {
  controller?: CustomDialogController;
  onDone: (name: string) => void = () => {
  };
  @State text: string = '';

  build() {
    Column({ space: 16 }) {
      Text('新建分组')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      TextInput({ placeholder: '例如：HP 长篇、待读、已完结' })
        .height(44)
        .fontSize(14)
        .backgroundColor($r('app.color.page_background'))
        .borderRadius(10)
        .onChange((v: string) => {
          this.text = v;
        })
        .onSubmit(() => {
          this.submit();
        })
      Row({ space: 10 }) {
        Button('取消')
          .layoutWeight(1)
          .height(42)
          .fontSize(14)
          .backgroundColor($r('app.color.page_background'))
          .fontColor($r('app.color.text_secondary'))
          .borderRadius(21)
          .onClick(() => {
            this.controller?.close();
          })
        Button('创建')
          .layoutWeight(1)
          .height(42)
          .fontSize(14)
          .backgroundColor($r('app.color.brand_primary'))
          .fontColor(Color.White)
          .borderRadius(21)
          .opacity(this.text.trim().length === 0 ? 0.5 : 1)
          .enabled(this.text.trim().length > 0)
          .onClick(() => {
            this.submit();
          })
      }
      .width('100%')
    }
    .padding(20)
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(16)
  }

  private submit(): void {
    const name = this.text.trim();
    if (name.length === 0) {
      return;
    }
    this.onDone(name);
    this.controller?.close();
  }
}

@Entry
@Component
struct Bookshelf {
  @State works: Work[] = [];
  /** 当前分组过滤后要显示的书 */
  @State shown: Work[] = [];
  @State shelves: Shelf[] = [];
  /** 分组栏标签（含数量），随书架数据一起重建 */
  @State tabs: ScopeTabData[] = [];
  /** 当前选中的分组：SCOPE_ALL=全部，''=未分组，其它=分组 id */
  @State scope: string = SCOPE_ALL;
  /** 排序模式：卡片右侧出现上下移动按钮 */
  @State sorting: boolean = false;
  @State loading: boolean = true;
  @State errorMsg: string = '';
  /** 系统导航条高度，用于底部操作栏避让三键 */
  @State navBarHeight: number = 0;
  /** 从「新建分组并移入」进来的书，建完组顺手搬过去 */
  private pendingMove: Work | null = null;
  /** 正在导出的书（按钮置灰用） */
  @State exportingId: string = '';

  /** 每本书「最新章节梗概」：workId → 「章节名：梗概」，翻译过的书才有 */
  @State briefs: Record<string, string> = {};

  /** 剧情进展面板 */
  @State showBrief: boolean = false;
  @State briefWork: Work | null = null;
  @State briefChapters: Chapter[] = [];
  private exportDialog: CustomDialogController = new CustomDialogController({
    builder: ExportDialog({
      onlyBook: true,
      onConfirm: (scope: string, content: string, format: string) => {
        this.doExport(this.pendingExport, scope, content, format);
      }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    customStyle: true
  });
  /** 菜单点「导出全书」时记住是哪本（@Builder 按值传参，不能靠弹窗回传） */
  private pendingExport: Work | null = null;

  private groupDialog: CustomDialogController = new CustomDialogController({
    builder: GroupNameDialog({
      onDone: (name: string) => {
        this.createGroup(name);
      }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center,
    customStyle: true
  });

  aboutToAppear(): void {
    this.reload();
    this.measureNavBar();
  }

  onPageShow(): void {
    this.reload();
  }

  /**
   * 只在「全屏布局」时才需要额外避让。
   *
   * 默认情况下页面本来就排在安全区内，底栏天然贴在导航栏之上；
   * 此时再补一段 padding 反而会多出一条空白。所以先问窗口是不是全屏，
   * 是的话才去量系统栏高度。
   */
  private async measureNavBar(): Promise<void> {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const win = await window.getLastWindow(ctx);
      if (!win.getWindowProperties().isLayoutFullScreen) {
        this.navBarHeight = 0;
        return;
      }
      const area = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const h = px2vp(area.bottomRect.height);
      this.navBarHeight = h > 0 ? h : 0;
    } catch (e) {
      Log.w(`读取导航条高度失败：${(e as Error).message}`);
    }
  }

  private async reload(): Promise<void> {
    try {
      const list = await WorkDao.list();
      this.works = list;
      this.shelves = await ShelfDao.list();
      // 每本书的最新章节梗概，整表一次查齐（翻译过的书才有值）
      const latest = await ChapterDao.latestSummaries();
      const briefs: Record<string, string> = {};
      for (const wid of Object.keys(latest)) {
        const c = latest[wid];
        briefs[wid] = `${c.title}：${c.summary}`;
      }
      this.briefs = briefs;
      this.applyFilter();
      this.rebuildTabs();
      this.errorMsg = '';
    } catch (e) {
      this.errorMsg = `读取书架失败：${(e as Error).message}`;
      Log.e(this.errorMsg);
    } finally {
      this.loading = false;
    }
  }

  /** 卡片摘要文案，无翻译的书返回空串 */
  private briefOf(workId: string): string {
    const s = this.briefs[workId];
    return s === undefined ? '' : s;
  }

  /** 摘要长度参与 ForEach key，翻译进度更新时对应卡片才会重建刷新 */
  private briefLen(workId: string): number {
    return this.briefOf(workId).length;
  }

  /** 重算分组栏：数量变了数组就换新，ForEach 的 key 里带 count，数字一定跟着更新 */
  private rebuildTabs(): void {
    const out: ScopeTabData[] = [];
    out.push({ label: '全部', scope: SCOPE_ALL, count: this.works.length });
    out.push({ label: '未分组', scope: '', count: this.countOf('') });
    for (let i = 0; i < this.shelves.length; i++) {
      const s = this.shelves[i];
      out.push({ label: s.name, scope: s.id, count: this.countOf(s.id) });
    }
    this.tabs = out;
  }

  private applyFilter(): void {
    const out: Work[] = [];
    for (let i = 0; i < this.works.length; i++) {
      const w = this.works[i];
      if (this.scope === SCOPE_ALL) {
        out.push(w);
      } else if (this.scope.length === 0) {
        if (w.shelfId.length === 0) {
          out.push(w);
        }
      } else if (w.shelfId === this.scope) {
        out.push(w);
      }
    }
    this.shown = out;
  }

  private countOf(scope: string): number {
    let n = 0;
    for (let i = 0; i < this.works.length; i++) {
      const w = this.works[i];
      if (scope === SCOPE_ALL) {
        n++;
      } else if (scope.length === 0) {
        if (w.shelfId.length === 0) {
          n++;
        }
      } else if (w.shelfId === scope) {
        n++;
      }
    }
    return n;
  }

  private indexOf(w: Work): number {
    for (let i = 0; i < this.shown.length; i++) {
      if (this.shown[i].id === w.id) {
        return i;
      }
    }
    return -1;
  }

  private shelfByScope(scope: string): Shelf | null {
    for (let i = 0; i < this.shelves.length; i++) {
      if (this.shelves[i].id === scope) {
        return this.shelves[i];
      }
    }
    return null;
  }

  private goImport(): void {
    this.getUIContext().getRouter().pushUrl({ url: 'pages/ImportPage' }).catch(() => {
      this.getUIContext().getPromptAction().showToast({ message: '打开导入页失败' });
    });
  }

  /** AI 找文：对话式智能检索（独立入口，与本地导入分开） */
  private goSearch(): void {
    this.getUIContext().getRouter().pushUrl({ url: 'pages/SearchPage' }).catch(() => {
      this.getUIContext().getPromptAction().showToast({ message: '打开 AI 找文失败' });
    });
  }

  private goSettings(): void {
    this.getUIContext().getRouter().pushUrl({ url: 'pages/SettingsPage' }).catch(() => {
      this.getUIContext().getPromptAction().showToast({ message: '打开设置页失败' });
    });
  }

  private openReader(w: Work): void {
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/Reader',
      params: { workId: w.id, chapterId: '' }
    }).catch((e: Error) => {
      this.getUIContext().getPromptAction().showToast({ message: `打开失败：${e.message}` });
    });
  }

  /** 上移 / 下移一位：复用这批书原本的序号槽位，不影响别的分组 */
  private async moveWork(w: Work, delta: number): Promise<void> {
    const from = this.indexOf(w);
    const to = from + delta;
    if (from < 0 || to < 0 || to >= this.shown.length) {
      return;
    }
    const order: Work[] = [];
    for (let i = 0; i < this.shown.length; i++) {
      order.push(this.shown[i]);
    }
    const tmp = order[from];
    order[from] = order[to];
    order[to] = tmp;
    try {
      await WorkDao.reorder(order);
      await this.reload();
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: `调整顺序失败：${(e as Error).message}` });
    }
  }

  private async moveTo(w: Work, shelfId: string): Promise<void> {
    try {
      await WorkDao.moveToShelf(w.id, shelfId);
      await this.reload();
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: `移动失败：${(e as Error).message}` });
    }
  }

  private async createGroup(name: string): Promise<void> {
    try {
      const s = await ShelfDao.create(name);
      const moving = this.pendingMove;
      this.pendingMove = null;
      if (moving !== null) {
        await WorkDao.moveToShelf(moving.id, s.id);
      }
      await this.reload();
      this.scope = moving !== null ? s.id : this.scope;
      this.applyFilter();
      this.getUIContext().getPromptAction().showToast({
        message: moving !== null ? `《${moving.title}》已移入「${s.name}」` : `分组「${s.name}」已建好`
      });
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: `创建失败：${(e as Error).message}` });
    }
  }

  private confirmRemoveShelf(s: Shelf): void {
    this.getUIContext().getPromptAction().showDialog({
      title: `删除分组「${s.name}」`,
      message: '分组里的书不会被删除，会退回「未分组」。',
      buttons: [
        { text: '取消', color: '#6B6259' },
        { text: '删除', color: '#FF6B5B' }
      ]
    }).then((res: promptAction.ShowDialogSuccessResponse) => {
      if (res.index === 1) {
        this.removeShelf(s);
      }
    });
  }

  private async removeShelf(s: Shelf): Promise<void> {
    try {
      await WorkDao.clearShelf(s.id);
      await ShelfDao.remove(s.id);
      if (this.scope === s.id) {
        this.scope = SCOPE_ALL;
      }
      await this.reload();
      this.getUIContext().getPromptAction().showToast({ message: '分组已删除，书已退回未分组' });
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: `删除分组失败：${(e as Error).message}` });
    }
  }

  private async removeWork(w: Work): Promise<void> {
    try {
      await WorkDao.remove(w.id);
      this.reload();
      this.getUIContext().getPromptAction().showToast({ message: '已删除' });
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: `删除失败：${(e as Error).message}` });
    }
  }

  /** 卡片右上角「⋯」的菜单：移动分组 + 删除 */
  private workMenu(w: Work): MenuElement[] {
    const items: MenuElement[] = [];
    for (let i = 0; i < this.shelves.length; i++) {
      const s = this.shelves[i];
      if (s.id === w.shelfId) {
        continue;
      }
      items.push({
        value: `移到「${s.name}」`,
        action: () => {
          this.moveTo(w, s.id);
        }
      });
    }
    if (w.shelfId.length > 0) {
      items.push({
        value: '移出分组',
        action: () => {
          this.moveTo(w, '');
        }
      });
    }
    items.push({
      value: '新建分组并移入…',
      action: () => {
        this.pendingMove = w;
        this.groupDialog.open();
      }
    });
    items.push({
      value: this.exportingId === w.id ? '正在导出…' : '导出全书…',
      action: () => {
        if (this.exportingId === w.id) {
          return;
        }
        this.pendingExport = w;
        this.exportDialog.open();
      }
    });
    items.push({
      value: '删除',
      action: () => {
        this.confirmDelete(w);
      }
    });
    return items;
  }

  /** 书架入口固定导全书；scope 参数由弹窗给（onlyBook 时恒为 BOOK） */
  private async doExport(w: Work | null, scope: string, content: string, format: string): Promise<void> {
    if (w === null || this.exportingId.length > 0) {
      return;
    }
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.exportingId = w.id;
    this.getUIContext().getPromptAction().showToast({ message: '正在组装导出内容…' });
    try {
      const result = await Exporter.build(w, scope, '', content, format);
      const uri = await Exporter.save(ctx, result);
      if (uri.length === 0) {
        this.getUIContext().getPromptAction().showToast({ message: '已取消导出' });
      } else {
        this.getUIContext().getPromptAction().showToast({ message: `已保存《${w.title}》` });
      }
    } catch (e) {
      const why = (e as Error).message;
      this.getUIContext().getPromptAction().showToast({ message: `导出失败：${why}` });
      Log.e(`导出失败：${why}`);
    } finally {
      this.exportingId = '';
    }
  }

  @Builder
  emptyState() {
    Column({ space: 14 }) {
      Text('书架还是空的')
        .fontSize(19)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      Text('导入一本 EPUB 或 TXT，\n解析入库后就可以直接阅读了。')
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
        .lineHeight(22)
      Button('导入第一本书')
        .fontSize(15)
        .height(42)
        .padding({ left: 24, right: 24 })
        .backgroundColor($r('app.color.brand_primary'))
        .fontColor(Color.White)
        .borderRadius(21)
        .margin({ top: 8 })
        .onClick(() => {
          this.goImport();
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  /**
   * 一个分组标签。
   *
   * 数量走 ScopeTabData（数据侧）+ ForEach 的 key（含 count），不走 @Builder
   * 的入参：@Builder 是「按值传参」，传入的普通值不建立状态依赖——直接写
   * `scopeTab(name, id, count)` 时，书架数据变了数字也不会跟着刷新，只有
   * 杀掉进程重进（整页重建）才是对的。现在数量一变，标签 key 就变、节点
   * 重建，数字必定是新的。
   */
  @Builder
  scopeTab(t: ScopeTabData) {
    Row({ space: 5 }) {
      Text(t.label)
        .fontSize(13)
        .fontWeight(this.scope === t.scope ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.scope === t.scope ? Color.White : $r('app.color.text_secondary'))
        .maxLines(1)
      Text(`${t.count}`)
        .fontSize(11)
        .fontColor(this.scope === t.scope ? '#D9FFFFFF' : $r('app.color.text_tertiary'))
    }
    .padding({ left: 12, right: 12, top: 7, bottom: 7 })
    .backgroundColor(this.scope === t.scope ? $r('app.color.brand_primary') : $r('app.color.card_background'))
    .borderRadius(16)
    .onClick(() => {
      this.scope = t.scope;
      this.sorting = false;
      this.applyFilter();
    })
    .gesture(LongPressGesture().onAction(() => {
      const s = this.shelfByScope(t.scope);
      if (s !== null) {
        this.confirmRemoveShelf(s);
      }
    }))
  }

  @Builder
  groupBar() {
    Row({ space: 8 }) {
      Scroll() {
        Row({ space: 8 }) {
          ForEach(this.tabs, (t: ScopeTabData) => {
            this.scopeTab(t)
          }, (t: ScopeTabData) => `${t.scope}|${t.label}|${t.count}`)
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .layoutWeight(1)
      .align(Alignment.Start)

      Text('＋')
        .fontSize(18)
        .fontColor($r('app.color.brand_primary'))
        .width(34)
        .height(30)
        .textAlign(TextAlign.Center)
        .backgroundColor($r('app.color.card_background'))
        .borderRadius(15)
        .onClick(() => {
          this.pendingMove = null;
          this.groupDialog.open();
        })
    }
    .width('100%')
    .padding({ left: $r('app.float.page_padding'), right: $r('app.float.page_padding'), bottom: 10 })
  }

  @Builder
  workCard(w: Work) {
    Column({ space: 10 }) {
      Row({ space: 6 }) {
        Text(w.title)
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text('⋯')
          .fontSize(18)
          .fontColor($r('app.color.text_tertiary'))
          .constraintSize({ minWidth: 30, minHeight: 28 })
          .textAlign(TextAlign.Center)
          .bindMenu(this.workMenu(w))
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Text(w.author.length > 0 ? w.author : '佚名')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      // 剧情摘要：翻译流水线生成的「本章梗概」，取最新一章。
      // 没翻译过的书没有这行；点开可看全部章节的剧情进展。
      if (this.briefOf(w.id).length > 0) {
        Text(this.briefOf(w.id))
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
          .lineHeight(17)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .onClick(() => {
            this.openBrief(w);
          })
      }

      Row({ space: 8 }) {
        Text(sourceLabel(w.sourceType))
          .fontSize(11)
          .fontColor($r('app.color.brand_primary'))
          .padding({ left: 7, right: 7, top: 2, bottom: 2 })
          .backgroundColor($r('app.color.page_background'))
          .borderRadius(4)
        Text(`${w.chapterCount} 章`)
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
        Text(formatWords(w.wordCount))
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
        Blank()
        if (this.scope === SCOPE_ALL && w.shelfId.length > 0) {
          Text(this.shelfNameOf(w.shelfId))
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(1)
        } else {
          Text(formatDate(w.updatedAt))
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
        }
      }
      .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    .width('100%')
    .backgroundColor($r('app.color.card_background'))
    .borderRadius($r('app.float.card_radius'))
    .onClick(() => {
      if (!this.sorting) {
        this.openReader(w);
      }
    })
  }

  private shelfNameOf(id: string): string {
    const s = this.shelfByScope(id);
    return s === null ? '' : s.name;
  }

  @Builder
  sortButtons(w: Work) {
    Column({ space: 6 }) {
      Text('↑')
        .fontSize(16)
        .fontColor($r('app.color.brand_primary'))
        .width(34)
        .height(34)
        .textAlign(TextAlign.Center)
        .backgroundColor($r('app.color.page_background'))
        .borderRadius(17)
        .onClick(() => {
          this.moveWork(w, -1);
        })
      Text('↓')
        .fontSize(16)
        .fontColor($r('app.color.brand_primary'))
        .width(34)
        .height(34)
        .textAlign(TextAlign.Center)
        .backgroundColor($r('app.color.page_background'))
        .borderRadius(17)
        .onClick(() => {
          this.moveWork(w, 1);
        })
    }
    .margin({ left: 8 })
  }

  @Builder
  bottomBar() {
    Row({ space: 10 }) {
      Button('AI 找文')
        .layoutWeight(1)
        .height(46)
        .fontSize(15)
        .backgroundColor($r('app.color.card_background'))
        .fontColor($r('app.color.brand_primary'))
        .borderRadius(23)
        .onClick(() => {
          this.goSearch();
        })
      Button('导入本地文件')
        .layoutWeight(1)
        .height(46)
        .fontSize(15)
        .backgroundColor($r('app.color.brand_primary'))
        .fontColor(Color.White)
        .borderRadius(23)
        .onClick(() => {
          this.goImport();
        })
    }
    .width('100%')
    .padding({
      left: $r('app.float.page_padding'),
      right: $r('app.float.page_padding'),
      top: 10,
      bottom: 10 + this.navBarHeight
    })
    .backgroundColor($r('app.color.card_background'))
    .border({ width: { top: 0.5 }, color: '#14000000' })
  }

  build() {
    Column() {
      // 顶部标题栏
      Row() {
        Column({ space: 2 }) {
          Text('书架')
            .fontSize($r('app.float.title_size'))
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text(this.works.length > 0 ? `${this.works.length} 本作品 · 仅存本地` : '仅存本地')
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
        }
        .alignItems(HorizontalAlign.Start)

        Blank()

        if (this.works.length > 0) {
          Text(this.sorting ? '完成' : '排序')
            .fontSize(14)
            .fontColor(this.sorting ? $r('app.color.brand_primary') : $r('app.color.text_secondary'))
            .padding({ left: 8, right: 8, top: 6, bottom: 6 })
            .onClick(() => {
              this.sorting = !this.sorting;
            })
        }

        Text('设置')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .padding({ left: 8, right: 4, top: 6, bottom: 6 })
          .onClick(() => {
            this.goSettings();
          })
      }
      .width('100%')
      .padding({ left: $r('app.float.page_padding'), right: $r('app.float.page_padding'), top: 12, bottom: 10 })

      if (this.works.length > 0) {
        this.groupBar()
      }

      if (this.loading) {
        Column() {
          LoadingProgress().width(40).height(40).color($r('app.color.brand_primary'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.errorMsg.length > 0) {
        Column({ space: 10 }) {
          Text(this.errorMsg)
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
          Button('重试').onClick(() => this.reload())
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.works.length === 0) {
        Column() {
          this.emptyState()
        }
        .width('100%')
        .layoutWeight(1)
      } else if (this.shown.length === 0) {
        Column({ space: 8 }) {
          Text('这个分组还没有书')
            .fontSize(15)
            .fontColor($r('app.color.text_secondary'))
          Text('点书右上角的「⋯」可以把书移进来')
            .fontSize(13)
            .fontColor($r('app.color.text_tertiary'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 12 }) {
          ForEach(this.shown, (w: Work) => {
            ListItem() {
              Row() {
                Column() {
                  this.workCard(w)
                }
                .layoutWeight(1)

                if (this.sorting) {
                  this.sortButtons(w)
                }
              }
              .width('100%')
            }
            .swipeAction({
              end: {
                builder: () => {
                  this.deleteButton(w)
                }
              }
            })
          // key 里带上 shelfId：卡片上的分组标签和「⋯」菜单都读 w.shelfId，
          // 而 workCard 是 @Builder 按值收 w，只靠 id 做 key 时移动分组后不会重建，
          // 标签会一直显示旧分组。带上 shelfId 让这本书在换组时重建一次。
          // briefLen 参与 key：翻译出新章节梗概后，对应卡片才会重建显示新摘要。
          }, (w: Work) => `${w.id}|${w.shelfId}|${this.briefLen(w.id)}`)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: $r('app.float.page_padding'), right: $r('app.float.page_padding') })
        .scrollBar(BarState.Off)
        .contentEndOffset(24)
        .bindSheet($$this.showBrief, this.briefSheet(), {
          height: 560,
          showClose: true,
          title: { title: '剧情进展' }
        })
      }

      this.bottomBar()
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }

  /** 点卡片摘要：打开剧情进展面板，按章节顺序列出全部梗概 */
  private async openBrief(w: Work): Promise<void> {
    this.briefWork = w;
    this.showBrief = true;
    try {
      this.briefChapters = await ChapterDao.summariesOf(w.id);
    } catch (e) {
      Log.e(`读取剧情进展失败：${(e as Error).message}`);
      this.briefChapters = [];
    }
  }

  @Builder
  briefSheet() {
    Column({ space: 12 }) {
      Text(this.briefWork !== null ? `《${this.briefWork.title}》` : '')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      if (this.briefChapters.length === 0) {
        Text('还没有章节梗概。翻译章节时会自动生成。')
          .fontSize(13)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .layoutWeight(1)
      } else {
        List({ space: 16 }) {
          ForEach(this.briefChapters, (c: Chapter) => {
            ListItem() {
              Column({ space: 4 }) {
                Text(`第 ${c.indexNo + 1} 章 · ${c.title}`)
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                  .width('100%')
                Text(c.summary)
                  .fontSize(12)
                  .lineHeight(18)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%')
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
            }
          }, (c: Chapter) => `${c.id}_${c.summary.length}`)
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .width('100%')
      }
    }
    .padding(20)
    .width('100%')
    .height('100%')
  }

  @Builder
  deleteButton(w: Work) {
    Column() {
      Text('删除')
        .fontSize(14)
        .fontColor(Color.White)
    }
    .width(72)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#FF6B5B')
    .borderRadius({ topRight: 16, bottomRight: 16 })
    .margin({ left: 8 })
    .onClick(() => {
      this.confirmDelete(w);
    })
  }

  private confirmDelete(w: Work): void {
    this.getUIContext().getPromptAction().showDialog({
      title: '删除作品',
      message: `《${w.title}》及其全部章节、译文、术语都将被删除，无法恢复。`,
      buttons: [
        { text: '取消', color: '#6B6259' },
        { text: '删除', color: '#FF6B5B' }
      ]
    }).then((res: promptAction.ShowDialogSuccessResponse) => {
      if (res.index === 1) {
        this.removeWork(w);
      }
    });
  }
}
