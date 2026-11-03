import { FileTextReader } from './FileTextReader';
import { ParsedChapter, ParsedParagraph, ParsedWork, emptyWork } from './ParserTypes';
import { ParaType, SourceType, plainRun } from '../model/Models';

const CHAPTER_PATTERNS: RegExp[] = [
  new RegExp('^第[0-9零一二三四五六七八九十百千万两]+[章节回卷幕篇部集][\\s:：.、\\-—]*(.*)$'),
  new RegExp('^(?:Chapter|CHAPTER|chapter)\\s+[0-9IVXLCivxlc]+[\\s:：.、\\-—]*(.*)$'),
  new RegExp('^(?:序章|序言|序幕|楔子|引子|尾声|终章|后记|番外|前言)[\\s:：.、\\-—]*(.*)$'),
  new RegExp('^[0-9]{1,4}[.、]\\s*(\\S.{0,40})$')
];

const CJK_END: string = '。！？…」』”’!?';
/** 出现在行尾即说明这是一句正文，不是标题 */
const SENTENCE_MARKS: string = '。！？…；，、,;';

/**
 * 体量保险。
 * TXT 没有结构，遇到「整本无章节标题」或「整段无句末标点」的文件时，
 * 启发式会把全书聚成一个章节、甚至几万字聚成一个段落。阅读页虽然有
 * 懒加载兜底，但单段超长文本的测量渲染依然很慢，导入时就在源头把
 * 体量切开，阅读、翻译、落库的每一段链路都更稳。
 */
const MAX_PARA_CHARS: number = 2000;
const MAX_CHAPTER_CHARS: number = 60000;

class RawChapter {
  title: string = '';
  lines: string[] = [];

  constructor(title: string) {
    this.title = title;
  }
}

/**
 * TXT 解析。纯文本没有结构，只能靠启发式：
 * 1) 章节标题按中英常见模式匹配；
 * 2) 段落切分看行尾是否句末标点 —— 这一条同时覆盖了
 *    中文"一行一段"与英文"硬换行"两种排版。
 */
export class TxtParser {
  static async parse(path: string, fileName: string): Promise<ParsedWork> {
    const text = FileTextReader.read(path);

    const work = emptyWork();
    work.sourceType = SourceType.TXT;
    work.title = TxtParser.titleFromFileName(fileName);

    const lines = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n').split('\n');

    const raws: RawChapter[] = [];
    let current = new RawChapter('');
    let chapterChars = 0;

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (line.length === 0) {
        // 空行作为强制分段标记保留
        if (current.lines.length > 0) {
          current.lines.push('');
        }
        continue;
      }
      if (TxtParser.isHeading(line)) {
        if (current.lines.length > 0 || current.title.length > 0) {
          raws.push(current);
        }
        current = new RawChapter(line);
        chapterChars = 0;
        continue;
      }
      current.lines.push(line);
      chapterChars += line.length;
      // 无章节标题的超长文件：到体量上限就强制分章，避免"整本一章"。
      // 后续无标题章节会落到"第 N 章"的默认命名。
      if (chapterChars >= MAX_CHAPTER_CHARS) {
        raws.push(current);
        current = new RawChapter('');
        chapterChars = 0;
      }
    }
    if (current.lines.length > 0 || current.title.length > 0) {
      raws.push(current);
    }

    const chapters: ParsedChapter[] = [];
    for (let i = 0; i < raws.length; i++) {
      const paragraphs = TxtParser.mergeLines(raws[i].lines);
      if (paragraphs.length === 0) {
        continue;
      }
      let title = raws[i].title;
      if (title.length === 0) {
        title = chapters.length === 0 ? work.title : `第 ${chapters.length + 1} 章`;
      }
      const chapter: ParsedChapter = { title: title, paragraphs: paragraphs };
      chapters.push(chapter);
    }

    if (chapters.length === 0) {
      const fallbackText = text.trim();
      if (fallbackText.length === 0) {
        throw new Error('文件内容为空');
      }
      const only: ParsedChapter = {
        title: work.title,
        paragraphs: [{ type: ParaType.TEXT, runs: [plainRun(fallbackText)] }]
      };
      chapters.push(only);
    }

    work.chapters = chapters;
    return work;
  }

  /**
   * 行合并：行尾是句末标点即收束为一段，否则与下一行拼接。
   * 空串元素表示原文里的空行，强制断段。
   * 段落长度到 MAX_PARA_CHARS 也强制收束：整段无标点的文本不能聚成
   * 一个几万字的段落，渲染和翻译分批都吃不消。
   */
  private static mergeLines(lines: string[]): ParsedParagraph[] {
    const out: ParsedParagraph[] = [];
    let buf = '';
    for (let i = 0; i < lines.length; i++) {
      const t = lines[i];
      if (t.length === 0) {
        if (buf.length > 0) {
          out.push({ type: ParaType.TEXT, runs: [plainRun(buf)] });
          buf = '';
        }
        continue;
      }
      buf = buf.length === 0 ? t : TxtParser.joinLine(buf, t);
      if (CJK_END.indexOf(buf.charAt(buf.length - 1)) >= 0 || buf.length >= MAX_PARA_CHARS) {
        out.push({ type: ParaType.TEXT, runs: [plainRun(buf)] });
        buf = '';
      }
    }
    if (buf.length > 0) {
      out.push({ type: ParaType.TEXT, runs: [plainRun(buf)] });
    }
    return out;
  }

  /** 中文直接拼，西文补一个空格 */
  private static joinLine(prev: string, next: string): string {
    const a = prev.charCodeAt(prev.length - 1);
    const b = next.charCodeAt(0);
    if (a > 0x2E80 || b > 0x2E80) {
      return prev + next;
    }
    return prev + ' ' + next;
  }

  /**
   * 章节标题判据。除了模式匹配，还要排除"正文行恰好以第一章开头"的情况：
   * 标题不会以句末标点结尾，也基本不含逗号分号。这两条能把绝大多数
   * "第一章里讲到……" 这类误判挡掉。
   */
  private static isHeading(line: string): boolean {
    if (line.length > 60) {
      return false;
    }
    if (SENTENCE_MARKS.indexOf(line.charAt(line.length - 1)) >= 0) {
      return false;
    }
    if (line.indexOf('。') >= 0 || line.indexOf('，') >= 0 || line.indexOf('；') >= 0) {
      return false;
    }
    for (let i = 0; i < CHAPTER_PATTERNS.length; i++) {
      if (CHAPTER_PATTERNS[i].test(line)) {
        return true;
      }
    }
    return false;
  }

  private static titleFromFileName(fileName: string): string {
    let name = fileName;
    const slash = Math.max(name.lastIndexOf('/'), name.lastIndexOf('\\'));
    if (slash >= 0) {
      name = name.substring(slash + 1);
    }
    const dot = name.lastIndexOf('.');
    if (dot > 0) {
      name = name.substring(0, dot);
    }
    return name.length > 0 ? name : '未命名作品';
  }

}
