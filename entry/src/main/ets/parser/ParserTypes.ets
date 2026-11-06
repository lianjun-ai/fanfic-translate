import { Run } from '../model/Models';

export interface ParsedParagraph {
  type: string;
  runs: Run[];
}

export interface ParsedChapter {
  title: string;
  paragraphs: ParsedParagraph[];
  /**
   * 这一章的来源网页（可选）。从文件解析时通常未知（undefined）；
   * 抓取/合并管线在内存里组装章节时会带上，落库进 chapter.source_url。
   */
  url?: string;
}

export interface ParsedWork {
  title: string;
  author: string;
  language: string;
  sourceType: string;
  sourceUrl: string;
  tags: string[];
  chapters: ParsedChapter[];
}

export function emptyWork(): ParsedWork {
  return {
    title: '',
    author: '',
    language: 'en',
    sourceType: 'file',
    sourceUrl: '',
    tags: [],
    chapters: []
  };
}
