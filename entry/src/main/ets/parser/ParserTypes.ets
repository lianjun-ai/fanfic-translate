import { Run } from '../model/Models';

export interface ParsedParagraph {
  type: string;
  runs: Run[];
}

export interface ParsedChapter {
  title: string;
  paragraphs: ParsedParagraph[];
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
