import { FileTextReader } from './FileTextReader';
import { HtmlNode, HtmlParser } from './HtmlParser';
import { XhtmlConverter } from './XhtmlConverter';
import { ParsedChapter, ParsedWork, emptyWork } from './ParserTypes';
import { SourceType } from '../model/Models';

/**
 * 单文件 HTML 解析。
 *
 * 默认整篇按一个章节处理 —— AO3 单章作品、浏览器"另存为"
 * 得到的页面都属于这种形态，不需要再切分。
 * 例外：body 顶层出现 ≥2 个 <h1> 时按 <h1> 分章 —— 这是
 * html_to_book（网页抓书）生成的拼接文档格式，每个网页一章。
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

    const sections = HtmlFileParser.splitByH1(root);
    if (sections !== null) {
      work.chapters = sections;
      return work;
    }

    const paragraphs = XhtmlConverter.toParagraphs(root);
    if (paragraphs.length === 0) {
      throw new Error('未能从 HTML 中提取到正文');
    }

    const chapter: ParsedChapter = { title: title, paragraphs: paragraphs };
    work.chapters = [chapter];
    return work;
  }

  /**
   * body 顶层有 ≥2 个 <h1> 时按它们切章；否则返回 null 走整篇一章。
   * 只数 body 的直接子节点，正文深处偶尔出现的 h1 不会误触发切分。
   * 空章节（h1 后没有内容）直接丢弃；全都为空返回 null。
   */
  private static splitByH1(root: HtmlNode): ParsedChapter[] | null {
    const body = HtmlParser.findFirst(root, 'body');
    if (body === null) {
      return null;
    }
    let marks = 0;
    for (let i = 0; i < body.children.length; i++) {
      if (body.children[i].tag === 'h1') {
        marks++;
      }
    }
    if (marks < 2) {
      return null;
    }
    const chapters: ParsedChapter[] = [];
    let curTitle = '';
    let cur: HtmlNode[] = [];

    const flush = (): void => {
      if (cur.length === 0 && curTitle.length === 0) {
        return;
      }
      const wrap = new HtmlNode('#root', new Map<string, string>(), '', false);
      wrap.children = cur;
      const paras = XhtmlConverter.toParagraphs(wrap);
      cur = [];
      if (paras.length === 0) {
        return;
      }
      const name = curTitle.length > 0 ? curTitle : `第 ${chapters.length + 1} 章`;
      chapters.push({ title: name, paragraphs: paras });
    };

    for (let i = 0; i < body.children.length; i++) {
      const node = body.children[i];
      if (node.tag === 'h1') {
        flush();
        curTitle = XhtmlConverter.normalizeSpace(HtmlParser.textOf(node));
      } else {
        cur.push(node);
      }
    }
    flush();
    return chapters.length > 0 ? chapters : null;
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
