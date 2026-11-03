import { relationalStore } from '@kit.ArkData';
import { Db } from './Db';
import { WorkDao } from './WorkDao';
import { ChapterDao } from './ChapterDao';
import { ParagraphDao } from './ParagraphDao';
import { Chapter, ChapterStatus, Paragraph, ParaStatus, Work, countWords, newId, plainRun, stringifyRuns, runsToPlainText } from '../model/Models';
import { ParsedWork } from '../parser/ParserTypes';
import { Dedupe } from './Dedupe';
import { Log } from '../common/Logger';

export class WorkRepo {
  /**
   * 查重。
   *
   * 先比内容指纹（同一本书被改名也认得出），再比书名作者（修订版内容变了，
   * 但读者认为是同一本）。两条都空命中才算新书。
   */
  static async findDuplicate(parsed: ParsedWork): Promise<Work | null> {
    const fp = Dedupe.fingerprintOf(parsed);
    const same = await WorkDao.findByFingerprint(fp);
    if (same !== null) {
      return same;
    }
    return WorkDao.findByDedupeKey(Dedupe.keyOf(parsed.title, parsed.author));
  }

  /**
   * 解析结果落库。作品、章节、段落三张表必须同一事务，
   * 否则中途失败会留下"有作品没章节"的脏数据。
   */
  static async saveParsed(parsed: ParsedWork, sourceUrl: string): Promise<string> {
    const now = Date.now();
    const workId = newId();
    // 新书进书架时排在最后，用户想提前可以手动上移
    const sortNo = await WorkDao.nextSortNo();

    let totalWords = 0;
    const chapters: Chapter[] = [];
    const paragraphs: Paragraph[][] = [];

    for (let ci = 0; ci < parsed.chapters.length; ci++) {
      const pc = parsed.chapters[ci];
      const chapterId = newId();
      chapters.push({
        id: chapterId,
        workId: workId,
        indexNo: ci,
        title: pc.title,
        status: ChapterStatus.PENDING,
        summary: '',
        translatedAt: 0
      });

      const rows: Paragraph[] = [];
      for (let pi = 0; pi < pc.paragraphs.length; pi++) {
        const pp = pc.paragraphs[pi];
        const runs = pp.runs.length > 0 ? pp.runs : [plainRun('')];
        totalWords += countWords(runsToPlainText(runs));
        rows.push({
          id: newId(),
          chapterId: chapterId,
          indexNo: pi,
          type: pp.type,
          runs: stringifyRuns(runs),
          translatedRuns: '',
          status: ParaStatus.PENDING,
          updatedAt: now
        });
      }
      paragraphs.push(rows);
    }

    const work: Work = {
      id: workId,
      title: parsed.title,
      author: parsed.author,
      sourceType: parsed.sourceType,
      sourceUrl: sourceUrl,
      language: parsed.language,
      tags: parsed.tags.join(','),
      coverPath: '',
      wordCount: totalWords,
      chapterCount: chapters.length,
      dedupeKey: Dedupe.keyOf(parsed.title, parsed.author),
      fingerprint: Dedupe.fingerprintOf(parsed),
      shelfId: '',
      sortNo: sortNo,
      createdAt: now,
      updatedAt: now
    };

    await Db.transaction(async (store: relationalStore.RdbStore) => {
      await WorkDao.insertIn(store, work);
      for (let i = 0; i < chapters.length; i++) {
        await ChapterDao.insertIn(store, chapters[i]);
        await ParagraphDao.insertBatchIn(store, paragraphs[i]);
      }
    });

    Log.i(`入库完成: ${work.title} / ${chapters.length} 章 / ${totalWords} 字`);
    return workId;
  }
}
