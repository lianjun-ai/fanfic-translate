import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { ChatMessage } from '../provider/LlmProvider';
import { FicMeta } from './FicHub';
import { Log } from '../common/Logger';

/**
 * 对话流里的一条气泡。
 * kind: user（我说的话）/ think（模型思考）/ action（工具动作）/ hit（命中作品卡片）
 *       / reply（模型回复）/ error（失败）
 */
export interface Bubble {
  id: string;
  kind: string;
  text: string;
  meta: FicMeta | null;
}

/** 会话列表里的一行（只有摘要，列表页不用读全文） */
export interface SessionMeta {
  id: string;
  title: string;
  updatedAt: number;
  /** 气泡条数：给用户一个「这个会话多长」的直观量 */
  count: number;
}

/** 一份完整会话 */
export interface SessionData {
  id: string;
  title: string;
  createdAt: number;
  updatedAt: number;
  bubbles: Bubble[];
  history: ChatMessage[];
}

/**
 * 找文会话的本地存储。
 *
 * 一个会话一个 JSON 文件，另有一份 index.json 记录摘要——列表页只读 index，
 * 切到某个会话才读它自己的文件，几百条消息的会话也不会拖慢列表。
 *
 * 放 filesDir 而不是 cacheDir：cacheDir 会被系统随时清理，会话就没了
 * （待入库区的边车文件踩过同样的坑）。
 */
export class SessionStore {
  /** 最多保留多少个会话，超了删最旧的，避免无限增长 */
  private static readonly MAX_SESSIONS: number = 30;

  private static dir(ctx: common.UIAbilityContext): string {
    return `${ctx.filesDir}/finder_sessions`;
  }

  private static ensureDir(ctx: common.UIAbilityContext): void {
    const d = SessionStore.dir(ctx);
    try {
      if (!fs.accessSync(d)) {
        fs.mkdirSync(d);
      }
    } catch (e) {
      Log.w(`创建会话目录失败：${(e as Error).message}`);
    }
  }

  private static indexPath(ctx: common.UIAbilityContext): string {
    return `${SessionStore.dir(ctx)}/index.json`;
  }

  private static filePath(ctx: common.UIAbilityContext, id: string): string {
    return `${SessionStore.dir(ctx)}/${id}.json`;
  }

  /** 会话 id：时间戳 + 计数，本地唯一即可 */
  static newId(): string {
    return `s${Date.now()}${Math.floor(Math.random() * 1000)}`;
  }

  private static readIndex(ctx: common.UIAbilityContext): SessionMeta[] {
    SessionStore.ensureDir(ctx);
    try {
      const txt = fs.readTextSync(SessionStore.indexPath(ctx));
      const list = JSON.parse(txt) as SessionMeta[];
      return list === null || list === undefined ? [] : list;
    } catch (e) {
      // 第一次用没有 index.json，正常
      return [];
    }
  }

  private static writeIndex(ctx: common.UIAbilityContext, list: SessionMeta[]): void {
    SessionStore.ensureDir(ctx);
    const f = fs.openSync(SessionStore.indexPath(ctx),
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(f.fd, JSON.stringify(list));
    } finally {
      fs.closeSync(f);
    }
  }

  /** 会话列表，最近更新的在最前 */
  static async list(ctx: common.UIAbilityContext): Promise<SessionMeta[]> {
    const list = SessionStore.readIndex(ctx);
    return list.sort((a: SessionMeta, b: SessionMeta) => b.updatedAt - a.updatedAt);
  }

  static async load(ctx: common.UIAbilityContext, id: string): Promise<SessionData | null> {
    try {
      const txt = fs.readTextSync(SessionStore.filePath(ctx, id));
      const data = JSON.parse(txt) as SessionData;
      if (data === null || data === undefined) {
        return null;
      }
      if (data.bubbles === undefined || data.bubbles === null) {
        data.bubbles = [];
      }
      if (data.history === undefined || data.history === null) {
        data.history = [];
      }
      return data;
    } catch (e) {
      Log.w(`读会话 ${id} 失败：${(e as Error).message}`);
      return null;
    }
  }

  static async save(ctx: common.UIAbilityContext, data: SessionData): Promise<void> {
    SessionStore.ensureDir(ctx);
    data.updatedAt = Date.now();
    const f = fs.openSync(SessionStore.filePath(ctx, data.id),
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(f.fd, JSON.stringify(data));
    } finally {
      fs.closeSync(f);
    }
    const list = SessionStore.readIndex(ctx);
    const kept = list.filter((m: SessionMeta) => m.id !== data.id);
    kept.push({
      id: data.id,
      title: data.title,
      updatedAt: data.updatedAt,
      count: data.bubbles.length
    });
    kept.sort((a: SessionMeta, b: SessionMeta) => b.updatedAt - a.updatedAt);
    const remain = kept.slice(0, SessionStore.MAX_SESSIONS);
    // 超出上限的老会话连同文件一起清掉，别只从索引里抹掉留一堆孤儿文件
    for (let i = remain.length; i < kept.length; i++) {
      try {
        fs.unlinkSync(SessionStore.filePath(ctx, kept[i].id));
      } catch (e) {
        // 删不掉就留着，下次再说
      }
    }
    SessionStore.writeIndex(ctx, remain);
  }

  /** 删除一个会话；当前正打开的那个由调用方负责清屏 */
  static async remove(ctx: common.UIAbilityContext, id: string): Promise<void> {
    try {
      fs.unlinkSync(SessionStore.filePath(ctx, id));
    } catch (e) {
      // 文件不在了也算删掉
    }
    const list = SessionStore.readIndex(ctx).filter((m: SessionMeta) => m.id !== id);
    SessionStore.writeIndex(ctx, list);
  }

  /** 清空全部会话（设置页/排障用） */
  static async clear(ctx: common.UIAbilityContext): Promise<void> {
    const list = SessionStore.readIndex(ctx);
    for (let i = 0; i < list.length; i++) {
      try {
        fs.unlinkSync(SessionStore.filePath(ctx, list[i].id));
      } catch (e) {
        // 忽略
      }
    }
    SessionStore.writeIndex(ctx, []);
  }
}
