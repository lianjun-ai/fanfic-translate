import { relationalStore } from '@kit.ArkData';
import { Db } from './Db';
import { Progress } from '../model/Models';

const TABLE: string = 'progress';

function toProgress(rs: relationalStore.ResultSet): Progress {
  return {
    workId: rs.getString(rs.getColumnIndex('work_id')),
    chapterId: rs.getString(rs.getColumnIndex('chapter_id')),
    paragraphIndex: rs.getLong(rs.getColumnIndex('paragraph_index')),
    offset: rs.getLong(rs.getColumnIndex('offset')),
    updatedAt: rs.getLong(rs.getColumnIndex('updated_at'))
  };
}

/**
 * 阅读进度。work_id 是主键，一本书记一条，重复保存直接覆盖。
 * 记录到"段落级"而不只是章节级：读到 2400 字一章的第 40 段时退出，
 * 下次要能回到那一段，而不是章节开头。
 */
export class ProgressDao {
  static async get(workId: string): Promise<Progress | null> {
    const store = await Db.get();
    const predicates = new relationalStore.RdbPredicates(TABLE);
    predicates.equalTo('work_id', workId);
    const rs = await store.query(predicates);
    let result: Progress | null = null;
    if (rs.goToNextRow()) {
      result = toProgress(rs);
    }
    rs.close();
    return result;
  }

  static async save(workId: string, chapterId: string, paragraphIndex: number): Promise<void> {
    if (workId.length === 0 || chapterId.length === 0) {
      return;
    }
    const store = await Db.get();
    const bucket: relationalStore.ValuesBucket = {
      'work_id': workId,
      'chapter_id': chapterId,
      'paragraph_index': paragraphIndex,
      'offset': 0,
      'updated_at': Date.now()
    };
    await store.insert(TABLE, bucket, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
  }

  static async clear(workId: string): Promise<void> {
    const store = await Db.get();
    const predicates = new relationalStore.RdbPredicates(TABLE);
    predicates.equalTo('work_id', workId);
    await store.delete(predicates);
  }
}
