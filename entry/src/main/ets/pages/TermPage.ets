import { Term } from '../model/Models';
import { TermDao } from '../data/TermDao';
import { TermCandidate, TermCandidateItem } from '../translator/TermCandidate';
import { Log } from '../common/Logger';

interface TermParams {
  workId: string;
  workTitle: string;
}

const SHEET_EDIT: number = 0;
const SHEET_CANDIDATE: number = 1;

/**
 * 术语表。
 *
 * 它不是一个「方便用户整理」的附属功能，而是翻译质量的直接输入：
 * 每次请求的系统提示词末尾都会带上整张表，模型被要求按给定译名输出。
 * 所以这里的交互刻意做得极短 —— 加一条术语不该超过两步。
 *
 * 候选提取走规则而不是模型（理由见 TermCandidate）：用户对候选的心理预期是
 * 「立刻看到一堆名字」，等一次网络往返再看结果会打断心流。
 */
@Entry
@Component
struct TermPage {
  @State terms: Term[] = [];
  @State loading: boolean = true;
  @State errorMsg: string = '';
  @State keyword: string = '';

  /* 表单 */
  @State showSheet: boolean = false;
  @State sheetMode: number = SHEET_EDIT;
  @State editingId: string = '';
  @State formSource: string = '';
  @State formTarget: string = '';
  @State formNote: string = '';
  @State saving: boolean = false;

  /* 候选 */
  @State candidates: TermCandidateItem[] = [];
  @State candLoading: boolean = false;
  @State candEmpty: string = '';

  private workId: string = '';
  private workTitle: string = '';

  aboutToAppear(): void {
    this.readParams();
    this.load();
  }

  private readParams(): void {
    try {
      const raw = this.getUIContext().getRouter().getParams();
      if (raw === undefined || raw === null) {
        return;
      }
      const p = raw as TermParams;
      this.workId = p.workId;
      this.workTitle = p.workTitle;
    } catch (e) {
      Log.e(`读取路由参数失败：${(e as Error).message}`);
    }
  }

  private async load(): Promise<void> {
    if (this.workId.length === 0) {
      this.errorMsg = '没有拿到作品 ID';
      this.loading = false;
      return;
    }
    try {
      this.terms = await TermDao.listByWork(this.workId);
      this.errorMsg = '';
    } catch (e) {
      this.errorMsg = `读取术语失败：${(e as Error).message}`;
    } finally {
      this.loading = false;
    }
  }

  private filtered(): Term[] {
    const k = this.keyword.trim().toLowerCase();
    if (k.length === 0) {
      return this.terms;
    }
    const out: Term[] = [];
    for (let i = 0; i < this.terms.length; i++) {
      const t = this.terms[i];
      if (t.source.toLowerCase().indexOf(k) >= 0 || t.target.toLowerCase().indexOf(k) >= 0) {
        out.push(t);
      }
    }
    return out;
  }

  /* ------------------------- 表单 ------------------------- */

  private openNew(source: string = ''): void {
    this.editingId = '';
    this.formSource = source;
    this.formTarget = '';
    this.formNote = '';
    this.sheetMode = SHEET_EDIT;
    this.showSheet = true;
  }

  private openEdit(t: Term): void {
    this.editingId = t.id;
    this.formSource = t.source;
    this.formTarget = t.target;
    this.formNote = t.note;
    this.sheetMode = SHEET_EDIT;
    this.showSheet = true;
  }

  private async save(): Promise<void> {
    const src = this.formSource.trim();
    const dst = this.formTarget.trim();
    if (src.length === 0) {
      this.toast('请填写原文');
      return;
    }
    if (dst.length === 0) {
      this.toast('请填写译名');
      return;
    }
    if (this.saving) {
      return;
    }
    this.saving = true;
    try {
      await TermDao.upsert(this.workId, src, dst, this.formNote);
      this.showSheet = false;
      await this.load();
      this.toast('已保存');
    } catch (e) {
      this.toast(`保存失败：${(e as Error).message}`);
    } finally {
      this.saving = false;
    }
  }

  private async remove(t: Term): Promise<void> {
    try {
      await TermDao.remove(t.id);
      this.showSheet = false;
      await this.load();
      this.toast('已删除');
    } catch (e) {
      this.toast(`删除失败：${(e as Error).message}`);
    }
  }

  /* ------------------------- 候选 ------------------------- */

  private async openCandidates(): Promise<void> {
    this.sheetMode = SHEET_CANDIDATE;
    this.showSheet = true;
    if (this.candidates.length > 0) {
      return;
    }
    this.candLoading = true;
    this.candEmpty = '';
    try {
      const corpus = await TermDao.corpus(this.workId, 900);
      if (!TermCandidate.worthExtracting(corpus)) {
        this.candEmpty = '这本的原文里拉丁字母太少，自动挑不出候选，请手动添加。';
        return;
      }
      const list = TermCandidate.extract(corpus, 3, 40);
      const existing = new Map<string, boolean>();
      for (let i = 0; i < this.terms.length; i++) {
        existing.set(this.terms[i].source.toLowerCase(), true);
      }
      const fresh: TermCandidateItem[] = [];
      for (let i = 0; i < list.length; i++) {
        if (!existing.has(list[i].text.toLowerCase())) {
          fresh.push(list[i]);
        }
      }
      this.candidates = fresh;
      if (fresh.length === 0) {
        this.candEmpty = '没有新的候选专名了，常见词与已收录的都已排除。';
      }
    } catch (e) {
      this.candEmpty = `提取失败：${(e as Error).message}`;
    } finally {
      this.candLoading = false;
    }
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  private goBack(): void {
    this.getUIContext().getRouter().back();
  }

  /* ------------------------- 视图 ------------------------- */

  @Builder
  editSheet() {
    Column({ space: 14 }) {
      Row() {
        Text(this.editingId.length > 0 ? '编辑术语' : '新增术语')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Blank()
        if (this.editingId.length > 0) {
          Text('删除')
            .fontSize(14)
            .fontColor($r('app.color.danger'))
            .padding(6)
            .onClick(() => {
              const id = this.editingId;
              for (let i = 0; i < this.terms.length; i++) {
                if (this.terms[i].id === id) {
                  this.remove(this.terms[i]);
                  break;
                }
              }
            })
        }
      }
      .width('100%')

      Column({ space: 6 }) {
        Text('原文')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
        TextInput({ text: $$this.formSource, placeholder: '如 Sherlock Holmes' })
          .fontSize(15)
          .height(44)
          .backgroundColor($r('app.color.page_background'))
          .borderRadius(10)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Column({ space: 6 }) {
        Text('译名')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
        TextInput({ text: $$this.formTarget, placeholder: '如 夏洛克·福尔摩斯' })
          .fontSize(15)
          .height(44)
          .backgroundColor($r('app.color.page_background'))
          .borderRadius(10)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Column({ space: 6 }) {
        Text('备注（可选，会一起写给模型）')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
        TextInput({ text: $$this.formNote, placeholder: '如 全名用全称，昵称用「夏洛」' })
          .fontSize(15)
          .height(44)
          .backgroundColor($r('app.color.page_background'))
          .borderRadius(10)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Text('同一原文再次保存会覆盖译名。改完不影响已有译文，只作用于之后的翻译。')
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .lineHeight(18)

      Row({ space: 12 }) {
        Button('取消')
          .fontSize(15)
          .height(44)
          .layoutWeight(1)
          .backgroundColor($r('app.color.page_background'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => {
            this.showSheet = false;
          })
        Button(this.saving ? '保存中…' : '保存')
          .fontSize(15)
          .height(44)
          .layoutWeight(1)
          .backgroundColor($r('app.color.brand_primary'))
          .fontColor(Color.White)
          .enabled(!this.saving)
          .onClick(() => {
            this.save();
          })
      }
      .width('100%')
      .margin({ top: 4 })
    }
    .width('100%')
    .padding({ left: 22, right: 22, top: 18, bottom: 24 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  candidateSheet() {
    Column({ space: 12 }) {
      Row() {
        Text('专名候选')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text('关闭')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .onClick(() => {
            this.showSheet = false;
          })
      }
      .width('100%')

      Text('从原文里按出现频次挑出的专名。点一个填进表单，补上译名即可。')
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .lineHeight(18)

      if (this.candLoading) {
        Row() {
          LoadingProgress().width(24).height(24).color($r('app.color.brand_primary'))
          Text('正在扫原文…')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .margin({ left: 10 })
        }
        .width('100%')
        .padding({ top: 20, bottom: 20 })
      } else if (this.candEmpty.length > 0) {
        Text(this.candEmpty)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .padding({ top: 8, bottom: 8 })
      } else {
        List({ space: 8 }) {
          ForEach(this.candidates, (c: TermCandidateItem) => {
            ListItem() {
              Row() {
                Text(c.text)
                  .fontSize(15)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text('添加')
                  .fontSize(12)
                  .fontColor($r('app.color.brand_primary'))
                  .margin({ left: 12 })
              }
              .width('100%')
              .padding({ top: 11, bottom: 11 })
              .onClick(() => {
                this.openNew(c.text);
              })
            }
          }, (c: TermCandidateItem) => c.text)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 22, right: 22, top: 18 })
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      Row({ space: 10 }) {
        Text('返回')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .onClick(() => this.goBack())
        Text('术语表')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        Text('候选')
          .fontSize(14)
          .fontColor($r('app.color.brand_primary'))
          .onClick(() => {
            this.openCandidates();
          })
      }
      .width('100%')
      .padding({ left: $r('app.float.page_padding'), right: $r('app.float.page_padding'), top: 12, bottom: 10 })

      // 说明条：让用户明白为什么值得填
      Column({ space: 4 }) {
        Text(this.workTitle.length > 0 ? this.workTitle : '本作品')
          .fontSize(12)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text('这张表会随每次翻译请求一起发给模型，用来锁死人名与专有名词的译法。')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .lineHeight(18)
      }
      .width('100%')
      .padding(12)
      .backgroundColor($r('app.color.card_background'))
      .borderRadius(10)
      .margin({ left: $r('app.float.page_padding'), right: $r('app.float.page_padding'), bottom: 10 })
      .alignItems(HorizontalAlign.Start)

      // 搜索
      TextInput({ text: $$this.keyword, placeholder: '搜索原文或译名' })
        .fontSize(14)
        .height(40)
        .backgroundColor($r('app.color.card_background'))
        .borderRadius(10)
        .margin({ left: $r('app.float.page_padding'), right: $r('app.float.page_padding'), bottom: 10 })

      Divider().color($r('app.color.divider'))

      if (this.loading) {
        Column() {
          LoadingProgress().width(32).height(32).color($r('app.color.brand_primary'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.errorMsg.length > 0) {
        Text(this.errorMsg)
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .padding({ top: 40 })
      } else if (this.terms.length === 0) {
        Column({ space: 10 }) {
          Text('还没有术语')
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
          Text('点右上角「候选」让程序从原文里挑名字，\n或者直接新增一条。')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
            .lineHeight(20)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 0 }) {
          ForEach(this.filtered(), (t: Term) => {
            ListItem() {
              Column({ space: 4 }) {
                Row({ space: 8 }) {
                  Text(t.source)
                    .fontSize(15)
                    .fontColor($r('app.color.text_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                  Text('→')
                    .fontSize(12)
                    .fontColor($r('app.color.text_tertiary'))
                  Text(t.target)
                    .fontSize(15)
                    .fontColor($r('app.color.brand_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                    .textAlign(TextAlign.End)
                }
                .width('100%')
                if (t.note.length > 0) {
                  Text(t.note)
                    .fontSize(12)
                    .fontColor($r('app.color.text_tertiary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                }
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding({ left: $r('app.float.page_padding'), right: $r('app.float.page_padding'), top: 13, bottom: 13 })
              .onClick(() => {
                this.openEdit(t);
              })
            }
            .swipeAction({
              end: {
                builder: () => {
                  this.deleteButton(t)
                }
              }
            })
          }, (t: Term) => `${t.id}_${t.target}_${t.note}`)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
        .divider({ strokeWidth: 0.5, color: $r('app.color.divider'), startMargin: 16, endMargin: 16 })
      }

      Divider().color($r('app.color.divider'))
      Row() {
        Button('+ 新增术语')
          .fontSize(15)
          .height(42)
          .width('100%')
          .backgroundColor($r('app.color.brand_primary'))
          .fontColor(Color.White)
          .onClick(() => {
            this.openNew();
          })
      }
      .width('100%')
      .padding({ left: $r('app.float.page_padding'), right: $r('app.float.page_padding'), top: 8, bottom: 14 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .bindSheet($$this.showSheet, this.sheetContent(), {
      // 高度刻意用固定值：SheetOptions 里带运行时表达式会增加一层不确定性
      height: SheetSize.MEDIUM,
      dragBar: true,
      showClose: false,
      backgroundColor: $r('app.color.card_background')
    })
  }

  /** 一个 sheet 承载两种内容：ArkUI 同一节点上多个 bindSheet 会互相覆盖 */
  @Builder
  sheetContent() {
    if (this.sheetMode === SHEET_CANDIDATE) {
      this.candidateSheet()
    } else {
      this.editSheet()
    }
  }

  /** 左滑删除按钮。swipeAction 的 builder 指向 @Builder 方法，是工程内已验证的写法 */
  @Builder
  deleteButton(t: Term) {
    Text('删除')
      .fontSize(14)
      .fontColor(Color.White)
      .width(72)
      .height('100%')
      .textAlign(TextAlign.Center)
      .backgroundColor('#FF6B5B')
      .borderRadius({ topRight: 12, bottomRight: 12 })
      .margin({ left: 8 })
      .onClick(() => {
        this.remove(t);
      })
  }
}
