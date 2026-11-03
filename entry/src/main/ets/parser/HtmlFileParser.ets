import { FileTextReader } from './FileTextReader';
import { HtmlParser } from './HtmlParser';
import { XhtmlConverter } from './XhtmlConverter';
import { ParsedChapter, ParsedWork, emptyWork } from './ParserTypes';
import { SourceType } from '../model/Models';

/**
 * 单文件 HTML 解析。整篇按一个章节处理 —— AO3 单章作品、浏览器"另存为"
 * 得到的页面都属于这种形态，不需要再切分。
 */
export class HtmlFileParser {
  static async parse(path: string, fileName: string): Promise<ParsedWork> {
    const text = FileTextReader.read(path);
    const root = HtmlParser.parse(text);

    const work = emptyWork();
    work.sourceType = SourceType.HTML;

    const titleNode = HtmlParser.findFirst(root, 'title');
    let title = titleNode === null ? '' : XhtmlConverter.normalizeSpace(HtmlParser.textOf(titleNode));
    if (title.length === 0) {
      title = XhtmlConverter.firstHeadingText(root);
    }
    if (title.length === 0) {
      title = HtmlFileParser.titleFromFileName(fileName);
    }
    work.title = title;

    const paragraphs = XhtmlConverter.toParagraphs(root);
    if (paragraphs.length === 0) {
      throw new Error('未能从 HTML 中提取到正文');
    }

    const chapter: ParsedChapter = { title: title, paragraphs: paragraphs };
    work.chapters = [chapter];
    return work;
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
