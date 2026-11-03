import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { FicMeta } from './FicHub';
import { Log } from '../common/Logger';

/**
 * FicHub 本地持久化缓存。
 *
 * 解决两个跨会话的痛点：
 * 1. 探测结果（命中缓存的作品元信息）只在单次检索内复用，换个检索、
 *    重启应用就丢，同样的作品反复打 FicHub → 撞限流。这里落盘后，
 *    TTL 内的重复搜索对 FicHub 零请求。
 * 2. 限流冷却时间戳在内存里，重启即失忆——刚被限流完就重启重试，
 *    只会火上浇油。冷却时间戳一并落盘。
 *
 * 存储用数组而非动态键对象：ArkTS 对嵌套 Record 的索引访问有严格
 * 限制，定长接口数组最稳。上限 80 条，线性查找毫无压力。
 */

/** 单条缓存的落盘形态 */
interface CachedFic {
  title: string;
  author: string;
  chapters: number;
  words: number;
  info: string;
  epubUrl: string;
  sourceUrl: string;
  cachedAt: number;
}

/** 限流状态文件的落盘形态 */
interface CooldownDoc {
  lastLimitedAt: number;
}

const CACHE_FILE: string = 'fic_cache.json';
const STATE_FILE: string = 'fic_state.json';
/** 元信息缓存有效期：章节数/字数会变，别缓存太久 */
const TTL_MS: number = 3 * 24 * 60 * 60 * 1000;
/** 缓存条目上限，超出淘汰最旧 */
const MAX_ITEMS: number = 80;

export class FicCache {
  private static pathOf(ctx: common.UIAbilityContext, name: string): string {
    return `${ctx.filesDir}/${name}`;
  }

  private static readText(ctx: common.UIAbilityContext, name: string): string | null {
    const path = FicCache.pathOf(ctx, name);
    if (!fs.accessSync(path)) {
      return null;
    }
    try {
      return fs.readTextSync(path);
    } catch (e) {
      Log.w(`FicCache 文件读取失败，重建：${name}`);
      return null;
    }
  }

  private static writeText(ctx: common.UIAbilityContext, name: string, text: string): void {
    const f = fs.openSync(FicCache.pathOf(ctx, name),
      fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(f.fd, text);
    } finally {
      fs.closeSync(f);
    }
  }

  private static readList(ctx: common.UIAbilityContext): CachedFic[] {
    const text = FicCache.readText(ctx, CACHE_FILE);
    if (text === null) {
      return [];
    }
    try {
      const parsed = JSON.parse(text) as CachedFic[];
      return Array.isArray(parsed) ? parsed : [];
    } catch (e) {
      Log.w('FicCache 缓存文件损坏，重建');
      return [];
    }
  }

  private static toMeta(item: CachedFic): FicMeta {
    const meta: FicMeta = {
      title: item.title,
      author: item.author,
      chapters: item.chapters,
      words: item.words,
      info: item.info,
      epubUrl: item.epubUrl,
      sourceUrl: item.sourceUrl
    };
    return meta;
  }

  /** TTL 内的探测命中直接复用，不打 FicHub */
  static async getMeta(ctx: common.UIAbilityContext, storyUrl: string): Promise<FicMeta | null> {
    try {
      const list = FicCache.readList(ctx);
      for (let i = 0; i < list.length; i++) {
        if (list[i].sourceUrl !== storyUrl) {
          continue;
        }
        if (Date.now() - list[i].cachedAt > TTL_MS) {
          // 过期：写回剔除该条后的列表
          const kept: CachedFic[] = [];
          for (let j = 0; j < list.length; j++) {
            if (list[j].sourceUrl !== storyUrl) {
              kept.push(list[j]);
            }
          }
          FicCache.writeText(ctx, CACHE_FILE, JSON.stringify(kept));
          return null;
        }
        return FicCache.toMeta(list[i]);
      }
      return null;
    } catch (e) {
      // 缓存读挂了不能影响主流程，当没有缓存处理
      return null;
    }
  }

  /** 探测命中后落盘；超额淘汰最旧 */
  static async putMeta(ctx: common.UIAbilityContext, meta: FicMeta): Promise<void> {
    try {
      const list = FicCache.readList(ctx);
      // 同一作品只保留最新一条
      const kept: CachedFic[] = [];
      for (let i = 0; i < list.length; i++) {
        if (list[i].sourceUrl !== meta.sourceUrl) {
          kept.push(list[i]);
        }
      }
      const item: CachedFic = {
        title: meta.title,
        author: meta.author,
        chapters: meta.chapters,
        words: meta.words,
        info: meta.info,
        epubUrl: meta.epubUrl,
        sourceUrl: meta.sourceUrl,
        cachedAt: Date.now()
      };
      kept.push(item);
      kept.sort((a: CachedFic, b: CachedFic) => b.cachedAt - a.cachedAt);
      const trimmed = kept.length > MAX_ITEMS ? kept.slice(0, MAX_ITEMS) : kept;
      FicCache.writeText(ctx, CACHE_FILE, JSON.stringify(trimmed));
    } catch (e) {
      Log.w(`FicCache 写入失败（不影响主流程）：${(e as Error).message}`);
    }
  }

  /** 上次被限流的时刻（毫秒时间戳），没有记录返回 0 */
  static async getCooldown(ctx: common.UIAbilityContext): Promise<number> {
    try {
      const text = FicCache.readText(ctx, STATE_FILE);
      if (text === null) {
        return 0;
      }
      const doc = JSON.parse(text) as CooldownDoc;
      return typeof doc.lastLimitedAt === 'number' ? doc.lastLimitedAt : 0;
    } catch (e) {
      return 0;
    }
  }

  static async setCooldown(ctx: common.UIAbilityContext, ts: number): Promise<void> {
    try {
      const doc: CooldownDoc = { lastLimitedAt: ts };
      FicCache.writeText(ctx, STATE_FILE, JSON.stringify(doc));
    } catch (e) {
      Log.w(`限流状态写入失败（不影响主流程）：${(e as Error).message}`);
    }
  }
}
