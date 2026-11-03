import { ExportContent, ExportFormat, ExportScope } from '../export/Exporter';

/**
 * 导出配置弹窗：范围 / 内容 / 格式三组选项。
 *
 * Reader（有「当前章」概念）显示范围选择；Bookshelf 只导全书，
 * 传 onlyBook=true 隐藏范围组。
 *
 * 注意 chip 的高亮判定写在 @Builder 内部直接读 @State（this.content === value），
 * 不能把「是否选中」当参数传进来 —— @Builder 按值传参不建立依赖，
 * 选中态会像书架分组计数那样卡在初始值不动。
 */
@CustomDialog
export struct ExportDialog {
  controller?: CustomDialogController;
  onConfirm: (scope: string, content: string, format: string) => void = () => {
  };
  onlyBook: boolean = false;
  @State scope: string = ExportScope.BOOK;
  @State content: string = ExportContent.TRANSLATION;
  @State format: string = ExportFormat.HTML;

  private confirm(): void {
    const scope = this.onlyBook ? ExportScope.BOOK : this.scope;
    this.onConfirm(scope, this.content, this.format);
    this.controller?.close();
  }

  @Builder
  chip(label: string, value: string, group: string) {
    Text(label)
      .fontSize(13)
      .fontColor(this.pickState(group) === value ? Color.White : $r('app.color.text_secondary'))
      .padding({ left: 14, right: 14, top: 7, bottom: 7 })
      .borderRadius(15)
      .backgroundColor(this.pickState(group) === value
        ? $r('app.color.brand_primary') : $r('app.color.page_background'))
      .onClick(() => {
        this.setPick(group, value);
      })
  }

  private pickState(group: string): string {
    if (group === 'scope') {
      return this.scope;
    }
    if (group === 'format') {
      return this.format;
    }
    return this.content;
  }

  private setPick(group: string, value: string): void {
    if (group === 'scope') {
      this.scope = value;
    } else if (group === 'format') {
      this.format = value;
    } else {
      this.content = value;
    }
  }

  @Builder
  optionRow(label: string, group: string) {
    Column({ space: 8 }) {
      Text(label)
        .fontSize(13)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
      Row({ space: 8 }) {
        if (group === 'scope') {
          this.chip('全书', ExportScope.BOOK, group)
          this.chip('仅当前章', ExportScope.CHAPTER, group)
        } else if (group === 'content') {
          this.chip('纯译文', ExportContent.TRANSLATION, group)
          this.chip('双语对照', ExportContent.BILINGUAL, group)
        } else {
          this.chip('HTML', ExportFormat.HTML, group)
          this.chip('TXT', ExportFormat.TXT, group)
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column({ space: 16 }) {
      Text('导出')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')

      if (!this.onlyBook) {
        this.optionRow('范围', 'scope')
      }
      this.optionRow('内容', 'content')
      this.optionRow('格式', 'format')

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
        Button('导出')
          .layoutWeight(1)
          .height(42)
          .fontSize(14)
          .backgroundColor($r('app.color.brand_primary'))
          .fontColor(Color.White)
          .borderRadius(21)
          .onClick(() => {
            this.confirm();
          })
      }
      .width('100%')
    }
    .padding(20)
    .backgroundColor($r('app.color.card_background'))
    .borderRadius(16)
  }
}
