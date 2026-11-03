import { util } from '@kit.ArkTS';

/**
 * 行内片段。段落不是字符串，而是片段数组 —— 这是全项目最关键的一个类型。
 * 文本节点的样式在解析阶段被拍平到片段上，翻译阶段原样继承分布，
 * 阅读阶段直接映射成 Text + Span，斜体内心独白、加粗强调都能还原。
 */
export interface Run {
  text: string;
  bold: boolean;
  italic: boolean;
  underline: boolean;
  strike: boolean;
}

/** 段落类型 */
export class ParaType {
  static readonly TEXT: string = 'text';
  static readonly HEADING: string = 'heading';
  static readonly DIVIDER: string = 'divider';
  static readonly QUOTE: string = 'quote';
}

/** 段落翻译状态 */
export class ParaStatus {
  static readonly PENDING: string = 'pending';
  static readonly TRANSLATING: string = 'translating';
  static readonly DONE: string = 'done';
  static readonly FAILED: string = 'failed';
}

/** 章节翻译状态 */
export class ChapterStatus {
  static readonly PENDING: string = 'pending';
  static readonly PARTIAL: string = 'partial';
  static readonly TRANSLATED: string = 'translated';
  static readonly FAILED: string = 'failed';
}

/** 任务状态 */
export class JobStatus {
  static readonly QUEUED: string = 'queued';
  static readonly RUNNING: string = 'running';
  static readonly PAUSED: string = 'paused';
  static readonly COMPLETED: string = 'completed';
  static readonly CANCELLED: string = 'cancelled';
}

/** 作品来源 */
export class SourceType {
  static readonly EPUB: string = 'epub';
  static readonly TXT: string = 'txt';
  static readonly HTML: string = 'html';
  static readonly WEB: string = 'web';
}

/** 书架分组。shelf_id 为空串表示「未分组」 */
export interface Shelf {
  id: string;
  name: string;
  sortNo: number;
  createdAt: number;
}

export interface Work {
  id: string;
  title: string;
  author: string;
  sourceType: string;
  sourceUrl: string;
  language: string;
  tags: string;
  coverPath: string;
  wordCount: number;
  chapterCount: number;
  /** 归一化后的「标题|作者」，用于识别同一作品被重复导入 */
  dedupeKey: string;
  /** 内容指纹，免疫改名 */
  fingerprint: string;
  /** 所属分组，空串=未分组 */
  shelfId: string;
  /** 书架手动排序序号，越小越靠前 */
  sortNo: number;
  createdAt: number;
  updatedAt: number;
}

export interface Chapter {
  id: string;
  workId: string;
  indexNo: number;
  title: string;
  status: string;
  summary: string;
  translatedAt: number;
}

export interface Paragraph {
  id: string;
  chapterId: string;
  indexNo: number;
  type: string;
  runs: string;
  translatedRuns: string;
  status: string;
  updatedAt: number;
}

export interface Term {
  id: string;
  workId: string;
  source: string;
  target: string;
  note: string;
}

export interface Progress {
  workId: string;
  chapterId: string;
  paragraphIndex: number;
  offset: number;
  updatedAt: number;
}

export interface Job {
  id: string;
  workId: string;
  chapterId: string;
  status: string;
  total: number;
  done: number;
  failed: number;
  createdAt: number;
}

/* ---------------- 工具函数 ---------------- */

export function plainRun(text: string): Run {
  return { text: text, bold: false, italic: false, underline: false, strike: false };
}

export function runsToPlainText(runs: Run[]): string {
  let s = '';
  for (let i = 0; i < runs.length; i++) {
    s += runs[i].text;
  }
  return s;
}

export function parseRuns(json: string): Run[] {
  if (!json || json.length === 0) {
    return [];
  }
  try {
    const arr = JSON.parse(json) as Run[];
    if (!arr) {
      return [];
    }
    return arr;
  } catch (e) {
    return [];
  }
}

export function stringifyRuns(runs: Run[]): string {
  return JSON.stringify(runs);
}

export function countWords(text: string): number {
  // 中文按字计，西文按词计，近似足够用于书架展示
  let words = 0;
  let cjk = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    if (c >= 0x4E00 && c <= 0x9FFF) {
      cjk++;
    } else if (c === 0x20) {
      words++;
    }
  }
  return cjk + words;
}

export function newId(): string {
  return util.generateRandomUUID(true);
}
