import { picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { BatchOutcome, FilePick, Importer } from '../parser/Importer';
import { Log } from '../common/Logger';

/**
 * 导入页：只管本地文件导入（EPUB / TXT / HTML 批量选择解析入库）。
 *
 * 网络相关入口已全部迁出：作品链接导入已移除（分享链接统一走
 * 智能检索页），智能检索在独立的 SearchPage —— 本页不再混杂网络逻辑。
 */
@Entry
@Component
struct ImportPage {
  @State busy: boolean = false;
  @State statusText: string = '';
  @State progressText: string = '';
  @State outcomes: BatchOutcome[] = [];
  /** 默认挡住重复导入；同名不同作品时才需要打开 */
  @State allowDuplicate: boolean = false;

  private async pickAndImport(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.outcomes = [];

    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    let files: FilePick[] = [];
    try {
      const docPicker = new picker.DocumentViewPicker(ctx);
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 50;
      options.fileSuffixFilters = ['电子书|.epub,.txt,.html,.htm'];
      const uris = await docPicker.select(options);
      if (uris.length === 0) {
        return;
      }
      const picked: FilePick[] = [];
      for (let i = 0; i < uris.length; i++) {
        const f: FilePick = { uri: uris[i], name: ImportPage.nameFromUri(uris[i]) };
        picked.push(f);
      }
      files = picked;
    } catch (e) {
      this.statusText = `打开文件选择器失败：${(e as Error).message}`;
      return;
    }

    this.busy = true;
    this.progressText = `0/${files.length}`;
    try {
      const res = await Importer.importBatch(ctx, files,
        (index: number, total: number, name: string, msg: string) => {
          this.progressText = `${index}/${total}`;
          this.statusText = files.length > 1 ? `${name} · ${msg}` : msg;
        }, this.allowDuplicate);

      this.outcomes = res;
      this.statusText = '';

      let ok = 0;
      let dup = 0;
      let bad = 0;
      for (let i = 0; i < res.length; i++) {
        if (res[i].status === 'ok') {
          ok++;
        } else if (res[i].status === 'duplicate') {
          dup++;
        } else {
          bad++;
        }
      }
      const parts: string[] = [];
      if (ok > 0) {
        parts.push(`导入 ${ok} 本`);
      }
      if (dup > 0) {
        parts.push(`${dup} 本已在书架`);
      }
      if (bad > 0) {
        parts.push(`${bad} 本失败`);
      }
      this.getUIContext().getPromptAction().showToast({ message: parts.join('，') });
    } catch (e) {
      this.statusText = (e as Error).message;
      Log.e(`批量导入中断: ${this.statusText}`);
    } finally {
      this.busy = false;
      this.progressText = '';
    }
  }

  private goBack(): void {
    this.getUIContext().getRouter().back();
  }

  private static nameFromUri(uri: string): string {
    let s = uri;
    try {
      s = decodeURIComponent(uri);
    } catch (e) {
      s = uri;
    }
    const idx = s.lastIndexOf('/');
    return idx >= 0 ? s.substring(idx + 1) : s;
  }

  private statusColor(status: string): Resource {
    if (status === 'ok') {
      return $r('app.color.brand_primary');
    }
    if (status === 'duplicate') {
      return $r('app.color.text_tertiary');
    }
    return $r('app.color.danger');
  }

  private statusLabel(status: string): string {
    if (status === 'ok') {
      return '已导入';
    }
    if (status === 'duplicate') {
      return '已在书架';
    }
    return '失败';
  }

  private static summaryOf(o: BatchOutcome): string {
    if (o.status === 'ok') {
      return `${o.chapters} 章 · ${o.paragraphs} 段`;
    }
    if (o.status === 'duplicate') {
      return o.detail;
    }
    return o.detail;
  }

  @Builder
  outcomeRow(o: BatchOutcome) {
    Row({ space: 10 }) {
      Text(this.statusLabel(o.status))
        .fontSize(11)
        .fontColor(this.statusColor(o.status))
        .width(56)
      Column({ space: 3 }) {
        Text(o.status === 'fail' ? o.fileName : o.title)
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(ImportPage.summaryOf(o))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
  }

  @Builder
  formatRow(ext: string, desc: string) {
    Row({ space: 10 }) {
      Text(ext)
        .fontSize(11)
        .fontColor($r('app.color.brand_primary'))
        .width(48)
        .textAlign(TextAlign.Center)
        .padding({ top: 3, bottom: 3 })
        .backgroundColor($r('app.color.page_background'))
        .borderRadius(4)
      Text(desc)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
  }

  build() {
    Column() {
      Row() {
        Text('导入作品')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
        Blank()
        Text('返回')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .onClick(() => this.goBack())
      }
      .width('100%')
      .padding({ left: $r('app.float.page_padding'), right: $r('app.float.page_padding'), top: 12, bottom: 12 })

      Scroll() {
        Column({ space: 16 }) {
          // 导入入口
          Column({ space: 12 }) {
            Text('从本地文件导入')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
            Text('可一次选择多个 EPUB、TXT 或 HTML 文件，逐本解析入库。文件只在本机处理，不会上传。想从网上找文，请用书架页的「AI 找文」。')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .lineHeight(20)
              .width('100%')

            Button(this.busy ? '处理中…' : '选择文件')
              .width('100%')
              .height(44)
              .fontSize(15)
              .backgroundColor(this.busy ? '#B9AFA4' : $r('app.color.brand_primary'))
              .fontColor(Color.White)
              .borderRadius(22)
              .enabled(!this.busy)
              .onClick(() => {
                this.pickAndImport();
              })

            Row() {
              Column({ space: 2 }) {
                Text('允许重复导入同名作品')
                  .fontSize(13)
                  .fontColor($r('app.color.text_primary'))
                  .width('100%')
                Text('默认会跳过书架里已有的书')
                  .fontSize(11)
                  .fontColor($r('app.color.text_tertiary'))
                  .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Toggle({ type: ToggleType.Switch, isOn: $$this.allowDuplicate })
                .selectedColor($r('app.color.brand_primary'))
                .enabled(!this.busy)
            }
            .width('100%')
            .margin({ top: 2 })

            if (this.busy) {
              Row({ space: 8 }) {
                LoadingProgress().width(18).height(18).color($r('app.color.brand_primary'))
                Text(this.statusText)
                  .fontSize(13)
                  .fontColor($r('app.color.text_secondary'))
                  .layoutWeight(1)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                if (this.progressText.length > 0) {
                  Text(this.progressText)
                    .fontSize(12)
                    .fontColor($r('app.color.text_tertiary'))
                }
              }
              .width('100%')
              .margin({ top: 4 })
            }
          }
          .padding(16)
          .width('100%')
          .backgroundColor($r('app.color.card_background'))
          .borderRadius($r('app.float.card_radius'))

          // 批量结果
          if (this.outcomes.length > 0) {
            Column() {
              Row() {
                Text('导入结果')
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                Blank()
                Text(`${this.outcomes.length} 个文件`)
                  .fontSize(12)
                  .fontColor($r('app.color.text_tertiary'))
              }
              .width('100%')
              .margin({ bottom: 4 })

              ForEach(this.outcomes, (o: BatchOutcome, i: number) => {
                this.outcomeRow(o)
              }, (o: BatchOutcome, i: number) => `${o.fileName}_${i}`)

              Button('返回书架')
                .width('100%')
                .height(40)
                .fontSize(14)
                .margin({ top: 10 })
                .backgroundColor($r('app.color.page_background'))
                .fontColor($r('app.color.text_primary'))
                .borderRadius(20)
                .onClick(() => this.goBack())
            }
            .padding(16)
            .width('100%')
            .backgroundColor($r('app.color.card_background'))
            .borderRadius($r('app.float.card_radius'))
          }

          // 支持范围
          Column({ space: 2 }) {
            Text('支持的格式')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
              .margin({ bottom: 6 })
            this.formatRow('EPUB', '推荐。结构完整，章节、标题、斜体都能保留')
            this.formatRow('TXT', '纯文本，靠标题模式自动分章，UTF-8 / GBK 均可')
            this.formatRow('HTML', '单页网页，整篇作为一个章节导入')
            this.formatRow('PDF', '本期不支持。PDF 已丢失行内样式，与译文保真冲突')
          }
          .padding(16)
          .width('100%')
          .backgroundColor($r('app.color.card_background'))
          .borderRadius($r('app.float.card_radius'))
        }
        .padding({ left: $r('app.float.page_padding'), right: $r('app.float.page_padding'), bottom: 32 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
