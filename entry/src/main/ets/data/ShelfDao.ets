import { relationalStore } from '@kit.ArkData';
import { Db } from './Db';
import { Shelf, newId } from '../model/Models';

const TABLE: string = 'shelf';

function toShelf(rs: relationalStore.ResultSet): Shelf {
  return {
    id: rs.getString(rs.getColumnIndex('id')),
    name: rs.getString(rs.getColumnIndex('name')),
    sortNo: rs.getLong(rs.getColumnIndex('sort_no')),
    createdAt: rs.getLong(rs.getColumnIndex('created_at'))
  };
}

/**
 * 书架分组。
 *
 * work.shelf_id 为空串表示「未分组」—— 不额外建一条虚拟分组记录，
 * 这样删除分组时只需要把成员的 shelf_id 清空，不用迁移数据。
 */
export class ShelfDao {
  static async list(): Promise<Shelf[]> {
    const store = await Db.get();
    const predicates = new relationalStore.RdbPredicates(TABLE);
    predicates.orderByAsc('sort_no');
    predicates.orderByAsc('created_at');
    const rs = await store.query(predicates);
    const out: Shelf[] = [];
    while (rs.goToNextRow()) {
      out.push(toShelf(rs));
    }
    rs.close();
    return out;
  }

  /** 同名分组直接复用，避免出现两个「HP 长篇」 */
  static async create(name: string): Promise<Shelf> {
    const trimmed = name.trim();
    const exist = await ShelfDao.findByName(trimmed);
    if (exist !== null) {
      return exist;
    }
    const store = await Db.get();
    const rs = await store.querySql(`SELECT MAX(sort_no) AS m FROM ${TABLE}`);
    let max = 0;
    try {
      if (rs.goToNextRow()) {
        max = rs.getLong(rs.getColumnIndex('m'));
      }
    } finally {
      rs.close();
    }
    const shelf: Shelf = {
      id: newId(),
      name: trimmed,
      sortNo: max + 1,
      createdAt: Date.now()
    };
    const bucket: relationalStore.ValuesBucket = {
      'id': shelf.id,
      'name': shelf.name,
      'sort_no': shelf.sortNo,
      'created_at': shelf.createdAt
    };
    await store.insert(TABLE, bucket);
    return shelf;
  }

  static async findByName(name: string): Promise<Shelf | null> {
    if (name.length === 0) {
      return null;
    }
    const store = await Db.get();
    const predicates = new relationalStore.RdbPredicates(TABLE);
    predicates.equalTo('name', name);
    const rs = await store.query(predicates);
    let result: Shelf | null = null;
    if (rs.goToNextRow()) {
      result = toShelf(rs);
    }
    rs.close();
    return result;
  }

  static async rename(id: string, name: string): Promise<void> {
    const store = await Db.get();
    const predicates = new relationalStore.RdbPredicates(TABLE);
    predicates.equalTo('id', id);
    const bucket: relationalStore.ValuesBucket = { 'name': name.trim() };
    await store.update(bucket, predicates);
  }

  /** 删分组不删书：成员统一退回未分组（由调用方先把 shelf_id 清空） */
  static async remove(id: string): Promise<void> {
    const store = await Db.get();
    const predicates = new relationalStore.RdbPredicates(TABLE);
    predicates.equalTo('id', id);
    await store.delete(predicates);
  }
}
