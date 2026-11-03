import { Chapter, ParaStatus, ParaType, Paragraph, Run, parseRuns } from '../model/Models';

/**
 * HTML 片段生成：把 Run[] 段落模型翻译成 HTML 标签。
 *
 * 单独成文件的原因：HTML 导出（Exporter）和 EPUB 导出（Epub）都要用这套映射，
 * 但 Exporter 又需要调用 Epub —— 放一起会形成循环 import。抽出来后两边都只
 * 单向依赖本文件。
 *
 * 拿到的片段同时要能被 XHTML 接受（EPUB 内部是 XML）：所以标签全部自闭合
 * （<hr/>），属性值不出现裸 & 或 <，文本统一转义。
 */
export class HtmlFrag {

  /** 转义文本节点里的 & < > */
  static esc(s: string): string {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }

  /** Run[] → 行内 HTML，样式位逐层包裹 */
  static runsHtml(runs: Run[]): string {
    let html = '';
    for (let i = 0; i < runs.length; i++) {
      let t = HtmlFrag.esc(runs[i].text);
      if (runs[i].bold) {
        t = `<strong>${t}</strong>`;
      }
      if (runs[i].italic) {
        t = `<em>${t}</em>`;
      }
      if (runs[i].underline) {
        t = `<u>${t}</u>`;
      }
      if (runs[i].strike) {
        t = `<s>${t}</s>`;
      }
      html += t;
    }
    return html;
  }

  /** 按段落类型套外层容器 */
  static paraCoreHtml(type: string, runs: Run[]): string {
    const inner = HtmlFrag.runsHtml(runs);
    if (type === ParaType.HEADING) {
      return `<h3>${inner}</h3>`;
    }
    if (type === ParaType.QUOTE) {
      return `<blockquote><p>${inner}</p></blockquote>`;
    }
    return `<p>${inner}</p>`;
  }

  /**
   * 单段 HTML。
   *
   * 双语对照：原文作为 .src 灰色小字参考段，译文是正文；
   * 未翻译的段落用原文顶上（与阅读器「译文模式」同一策略，不留空洞）。
   */
  static paraHtml(p: Paragraph, bilingual: boolean): string {
    if (p.type === ParaType.DIVIDER) {
      return '<hr/>';
    }
    const src = parseRuns(p.runs);
    const translated = p.status === ParaStatus.DONE && p.translatedRuns.length > 0
      ? parseRuns(p.translatedRuns)
      : null;

    if (bilingual && translated !== null && p.type !== ParaType.HEADING) {
      return `<p class="src">${HtmlFrag.runsHtml(src)}</p>\n` +
        HtmlFrag.paraCoreHtml(p.type, translated);
    }
    if (translated !== null) {
      return HtmlFrag.paraCoreHtml(p.type, translated);
    }
    return HtmlFrag.paraCoreHtml(p.type, src);
  }

  /** 一章的 HTML：标题 + 段落 + 摘要附注 */
  static chapterHtml(ch: Chapter, paras: Paragraph[], bilingual: boolean): string {
    const lines: string[] = [];
    lines.push(`<h2>${HtmlFrag.esc(ch.title)}</h2>`);
    for (let i = 0; i < paras.length; i++) {
      lines.push(HtmlFrag.paraHtml(paras[i], bilingual));
    }
    if (ch.summary.length > 0) {
      lines.push(`<p class="note">〔本章梗概〕${HtmlFrag.esc(ch.summary)}</p>`);
    }
    return lines.join('\n');
  }
}
