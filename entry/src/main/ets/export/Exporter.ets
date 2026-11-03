import { picker } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { Chapter, ParaType, ParaStatus, Paragraph, Run, Work, parseRuns, runsToPlainText } from '../model/Models';
import { ChapterDao } from '../data/ChapterDao';
import { ParagraphDao } from '../data/ParagraphDao';
import { FicHub } from '../fetch/FicHub';

/** 导出格式 */
export class ExportFormat {
  static readonly TXT: string = 'txt';
  static readonly HTML: string = 'html';
}

/** 导出内容：纯译文 / 双语对照 */
export class ExportContent {
  static readonly TRANSLATION: string = 'translation';
  static readonly BILINGUAL: string = 'bilingual';
}

/** 导出范围：全书 / 单章 */
export class ExportScope {
  static readonly BOOK: string = 'book';
  static readonly CHAPTER: string = 'chapter';
}

export interface ExportResult {
  /** 组装好的完整文件内容 */
  body: string;
  /** 建议的文件名（已做过文件名安全化） */
  fileName: string;
  mime: string;
}

/**
 * 排版导出：把书库里的作品组装成 TXT / HTML。
 *
 * 数据基础是 M1 定下的 Run[] 段落模型 —— 原文与译文都是片段数组，
 * 斜体/加粗/下划线/删除线的样式位直接映射成 HTML 标签，不需要任何新解析。
 * TXT 是纯文本，样式位丢弃（文本内容完整）。
 *
 * 译文缺失的段落按阅读器「纯译文模式」的同一策略处理：用原文顶上，
 * 保证导出内容没有空洞。
 */
export class Exporter {

  /**
   * 组装导出内容。
   *
   * @param scope CHAPTER 时只导 chapterId 对应一章，BOOK 导整本
   */
  static async build(work: Work, scope: string, chapterId: string,
    content: string, format: string): Promise<ExportResult> {

    let chapters: Chapter[] = [];
    if (scope === ExportScope.CHAPTER) {
      const c = await ChapterDao.find(chapterId);
      if (c !== null) {
        chapters.push(c);
      }
    } else {
      chapters = await ChapterDao.listByWork(work.id);
    }
    if (chapters.length === 0) {
      throw new Error('没有可导出的章节');
    }

    // 逐章取段落并组装正文
    const parts: string[] = [];
    let translatedCount = 0;
    for (let i = 0; i < chapters.length; i++) {
      const paras = await ParagraphDao.listByChapter(chapters[i].id);
      for (let p = 0; p < paras.length; p++) {
        if (paras[p].status === ParaStatus.DONE) {
          translatedCount++;
        }
      }
      parts.push(Exporter.chapterBlock(chapters[i], paras, content, format));
      // 控制单文件体积提示：整本导出时把翻译完成度带给调用方决策（当前直接导出，不截断）
    }

    const header = format === ExportFormat.HTML
      ? Exporter.htmlHeader(work, chapters.length, translatedCount)
      : Exporter.txtHeader(work);
    const footer = format === ExportFormat.HTML ? '\n</body>\n</html>\n' : '';

    const ext = format === ExportFormat.HTML ? 'html' : 'txt';
    const mode = content === ExportContent.BILINGUAL ? '双语' : '译文';
    const scopeTag = scope === ExportScope.CHAPTER ? '' : `_${chapters.length}章`;
    const fileName = `${FicHub.fileSafeName(work.title) || 'export'}_${mode}${scopeTag}.${ext}`;

    return {
      body: header + parts.join(Exporter.blockGap(format)) + footer,
      fileName: fileName,
      mime: format === ExportFormat.HTML ? 'text/html' : 'text/plain'
    };
  }

  /** 章节块：标题 + 段落 + 摘要附注 */
  private static chapterBlock(ch: Chapter, paras: Paragraph[], content: string, format: string): string {
    const lines: string[] = [];
    if (format === ExportFormat.HTML) {
      lines.push(`<h2>${Exporter.esc(ch.title)}</h2>`);
      for (let i = 0; i < paras.length; i++) {
        lines.push(Exporter.paraHtml(paras[i], content));
      }
      if (ch.summary.length > 0) {
        lines.push(`<p class="note">〔本章梗概〕${Exporter.esc(ch.summary)}</p>`);
      }
    } else {
      lines.push(`\n▍${ch.title}\n`);
      for (let i = 0; i < paras.length; i++) {
        lines.push(Exporter.paraTxt(paras[i], content));
      }
      if (ch.summary.length > 0) {
        lines.push(`〔本章梗概〕${ch.summary}`);
      }
    }
    return lines.join('\n');
  }

  /** 单段 HTML。双语对照时原文是灰色小字参考，译文是正文 */
  private static paraHtml(p: Paragraph, content: string): string {
    if (p.type === ParaType.DIVIDER) {
      return '<hr/>';
    }
    const src = parseRuns(p.runs);
    const translated = p.status === ParaStatus.DONE && p.translatedRuns.length > 0
      ? parseRuns(p.translatedRuns)
      : null;

    if (content === ExportContent.BILINGUAL && translated !== null && p.type !== ParaType.HEADING) {
      let html = `<p class="src">${Exporter.runsHtml(src)}</p>\n`;
      html += Exporter.paraCoreHtml(p.type, translated);
      return html;
    }
    if (translated !== null) {
      return Exporter.paraCoreHtml(p.type, translated);
    }
    // 未翻译：原文当正文（和阅读器纯译文模式同策略）
    return Exporter.paraCoreHtml(p.type, src);
  }

  private static paraCoreHtml(type: string, runs: Run[]): string {
    const inner = Exporter.runsHtml(runs);
    if (type === ParaType.HEADING) {
      return `<h3>${inner}</h3>`;
    }
    if (type === ParaType.QUOTE) {
      return `<blockquote><p>${inner}</p></blockquote>`;
    }
    return `<p>${inner}</p>`;
  }

  private static runsHtml(runs: Run[]): string {
    let html = '';
    for (let i = 0; i < runs.length; i++) {
      let t = Exporter.esc(runs[i].text);
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

  /** 单段 TXT。双语对照：原文行 → 空行 → 译文行 */
  private static paraTxt(p: Paragraph, content: string): string {
    if (p.type === ParaType.DIVIDER) {
      return '────────────';
    }
    const src = parseRuns(p.runs);
    const translated = p.status === ParaStatus.DONE && p.translatedRuns.length > 0
      ? parseRuns(p.translatedRuns)
      : null;

    const srcText = runsToPlainText(src);
    if (content === ExportContent.BILINGUAL && translated !== null && p.type !== ParaType.HEADING) {
      return `${srcText}\n${runsToPlainText(translated)}`;
    }
    if (translated !== null) {
      return runsToPlainText(translated);
    }
    return srcText;
  }

  private static blockGap(format: string): string {
    return format === ExportFormat.HTML ? '\n' : '\n\n';
  }

  private static txtHeader(work: Work): string {
    const d = new Date();
    const pad = (n: number): string => n < 10 ? `0${n}` : `${n}`;
    return `${work.title}\n${work.author.length > 0 ? work.author : '佚名'}` +
      `\n由同人译站翻译导出 · ${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}\n`;
  }

  private static htmlHeader(work: Work, chapterTotal: number, translated: number): string {
    const d = new Date();
    const pad = (n: number): string => n < 10 ? `0${n}` : `${n}`;
    return `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>${Exporter.esc(work.title)}</title>
<style>
body { max-width: 44em; margin: 0 auto; padding: 24px 20px 64px;
  font-family: Georgia, 'Songti SC', SimSun, serif; line-height: 1.9; color: #222; }
h1 { font-size: 1.5em; margin: 0 0 4px; }
h2 { font-size: 1.2em; margin: 2.4em 0 0.8em; border-bottom: 1px solid #ddd; padding-bottom: 4px; }
h3 { font-size: 1.05em; margin: 1.6em 0 0.6em; }
p { margin: 0.9em 0; text-align: justify; }
p.src { color: #999; font-size: 0.86em; margin-bottom: 0.1em; }
p.note, .note { color: #8a7f70; font-size: 0.9em; }
blockquote { margin: 1em 0; padding: 2px 14px; border-left: 3px solid #d8d2c6; color: #555; }
hr { border: none; border-top: 1px solid #ddd; margin: 1.8em auto; width: 40%; }
.meta { color: #8a7f70; font-size: 0.9em; margin-bottom: 2em; }
</style>
</head>
<body>
<h1>${Exporter.esc(work.title)}</h1>
<p class="meta">${Exporter.esc(work.author.length > 0 ? work.author : '佚名')} · 由同人译站翻译导出 · ${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}</p>
`;
  }

  private static esc(s: string): string {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }

  /**
   * 落盘：DocumentSavePicker 让用户选保存位置（下载/文档等公共目录）。
   * 写入必须用 picker 返回的 uri 打开 —— 自己拼公共目录路径会被沙箱拒绝。
   * 注意 SDK 里没有独立的 DocumentSavePicker 类，save() 挂在 DocumentViewPicker 上。
   */
  static async save(ctx: common.UIAbilityContext, result: ExportResult): Promise<string> {
    const saveOptions = new picker.DocumentSaveOptions();
    saveOptions.newFileNames = [result.fileName];
    const docPicker = new picker.DocumentViewPicker(ctx);
    const uris: Array<string> = await docPicker.save(saveOptions);
    if (!uris || uris.length === 0) {
      return '';
    }
    const f = fs.openSync(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(f.fd, result.body);
    } finally {
      fs.closeSync(f);
    }
    return uris[0];
  }
}
