import { relationalStore } from '@kit.ArkData';
import { ParsedWork } from '../parser/ParserTypes';
import { runsToPlainText } from '../model/Models';
import { Log } from '../common/Logger';

/**
 * 导入去重。
 *
 * 两道判据，先强后弱：
 *
 * 1. **内容指纹**——同几段文字、同章节数，基本可以断定是同一本书。
 *    它免疫改名：用户把《雪落无声》存成《雪落无声(1)》，指纹不变。
 * 2. **标题 + 作者**——指纹不同但书名作者都被归一化成同一个串，视为同作品。
 *    这条兜住"重新下载了修订版"这类情况：内容变了，但读者心里那是同一本。
 *
 * 归一化只保留中文、数字和小写字母，标点、空白、书名号、全角括号全部丢弃，所以
 * 「《星河坠落》（修订版）」与「星河坠落 修订版」会得到同一个键。
 */
export class Dedupe {
  /** 只留中文、数字、小写字母，其余（标点/括号/书名号/空白/emoji）全部丢掉 */
  static norm(s: string): string {
    let out = '';
    for (let i = 0; i < s.length; i++) {
      const c = s.charCodeAt(i);
      if ((c >= 0x4E00 && c <= 0x9FFF) || (c >= 0x30 && c <= 0x39)) {
        out += s.charAt(i);
      } else if (c >= 0x61 && c <= 0x7A) {
        out += s.charAt(i);
      } else if (c >= 0x41 && c <= 0x5A) {
        out += String.fromCharCode(c + 32);
      }
    }
    return out;
  }

  static keyOf(title: string, author: string): string {
    const t = Dedupe.norm(title);
    const a = Dedupe.norm(author);
    if (t.length === 0 && a.length === 0) {
      return '';
    }
    return `${t}|${a}`;
  }

  private static fnv(text: string, seed: number): string {
    let h = seed;
    for (let i = 0; i < text.length; i++) {
      h ^= text.charCodeAt(i);
      // Math.imul 保证 32 位整数乘法不丢精度，直接乘会变成浮点
      h = Math.imul(h, 16777619);
    }
    const v = h >>> 0;
    return v.toString(16).padStart(8, '0');
  }

  /**
   * 内容指纹。
   *
   * 不 hash 全文（十几万字要遍历一遍，导入大书时是白花的开销），
   * 而是取"每章标题 + 每章前三段 + 章节数 + 总段数"——
   * 这些足以区分两本书，又对同一本书的不同重打包保持不变。
   */
  static fingerprintOf(parsed: ParsedWork): string {
    let sample = '';
    let paraCount = 0;
    for (let c = 0; c < parsed.chapters.length; c++) {
      const ch = parsed.chapters[c];
      sample += ch.title;
      const take = Math.min(3, ch.paragraphs.length);
      for (let p = 0; p < take; p++) {
        sample += runsToPlainText(ch.paragraphs[p].runs);
      }
      paraCount += ch.paragraphs.length;
    }
    if (sample.length === 0) {
      return '';
    }
    const head = Dedupe.fnv(sample, 0x811c9dc5);
    const tail = Dedupe.fnv(sample, 0x01000193);
    return `${head}${tail}-${parsed.chapters.length}-${paraCount}`;
  }

  /**
   * 老数据回填。
   *
   * 加列之前导入的书 dedupe_key 是空的，不清一次的话它们永远查不出重复。
   * 只回填键不回填指纹：指纹要重新解析原文件才能算，代价太大；
   * 而书名作者这一条已能覆盖绝大多数重复导入。
   */
  static async backfill(store: relationalStore.RdbStore): Promise<void> {
    const rs = await store.querySql("SELECT id, title, author FROM work WHERE dedupe_key = ''");
    const ids: string[] = [];
    const keys: string[] = [];
    try {
      while (rs.goToNextRow()) {
        ids.push(rs.getString(rs.getColumnIndex('id')));
        keys.push(Dedupe.keyOf(rs.getString(rs.getColumnIndex('title')),
          rs.getString(rs.getColumnIndex('author'))));
      }
    } finally {
      rs.close();
    }
    for (let i = 0; i < ids.length; i++) {
      try {
        const bucket: relationalStore.ValuesBucket = { 'dedupe_key': keys[i] };
        const pred = new relationalStore.RdbPredicates('work');
        pred.equalTo('id', ids[i]);
        await store.update(bucket, pred);
      } catch (e) {
        Log.w(`回填去重键失败 ${ids[i]}：${(e as Error).message}`);
      }
    }
    if (ids.length > 0) {
      Log.i(`去重键回填完成：${ids.length} 本`);
    }
  }
}
