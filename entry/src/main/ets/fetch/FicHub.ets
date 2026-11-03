import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { FicCache } from './FicCache';
import { Log } from '../common/Logger';

/**
 * FicHub（fichub.net）客户端。
 *
 * 抓取同人文不走 ArkWeb 爬页面：FicHub 是专门把同人站作品转成标准 EPUB 的
 * 开源服务，支持 AO3 / FanFiction.net / SpaceBattles / SufficientVelocity /
 * FictionPress 等。拿到 EPUB 后直接进本应用既有的解析管线 —— 章节结构、
 * 斜体样式全部保真，还天然避开了各站点反爬和登录墙。
 *
 * API：GET https://fichub.net/api/v0/epub?q=<url 编码的作品链接>
 * 返回 JSON：err=0 成功，epub_url 是 EPUB 的下载地址（相对路径），meta 是作品元信息。
 * 未缓存的作品首次导出要在 FicHub 服务端现场抓源站，可能耗时一两分钟。
 */

interface FicApiMeta {
  title: string;
  author: string;
  chapters: number;
  words: number;
}

/** /api/v0/epub 的返回结构（只声明用到的字段） */
interface FicApiResponse {
  err: number;
  error: string;
  info: string;
  epub_url: string;
  meta: FicApiMeta;
}

/** 给 UI 展示的作品元信息 */
export interface FicMeta {
  title: string;
  author: string;
  chapters: number;
  words: number;
  /** FicHub 原样返回的一句话状态（字数/连载状态/更新时间） */
  info: string;
  /** 绝对地址，直接 GET 即得 EPUB 文件 */
  epubUrl: string;
  /** 源站作品页地址（探测/展示用，下载只认 epubUrl） */
  sourceUrl: string;
}

const API: string = 'https://fichub.net/api/v0/epub?q=';
const SITE: string = 'https://fichub.net';
/** 未缓存作品要等 FicHub 现场抓源站，读超时必须给足 */
const READ_TIMEOUT: number = 300000;

export class FicHubError extends Error {
  constructor(msg: string) {
    super(msg);
    this.name = 'FicHubError';
  }
}

/**
 * 缓存探测的分型结果。探测不能只回"中/不中"——限流造成的假阴性
 * 会把明明在缓存里的作品显示成 0 命中，必须让调用方能区分原因。
 */
export interface ProbeResult {
  /** hit=已缓存可下载；miss=未缓存或响应慢；rejected=FicHub 明确拒绝；limited=被限流；error=其它错误 */
  status: 'hit' | 'miss' | 'rejected' | 'limited' | 'error';
  /** status=hit 时有效 */
  meta: FicMeta | null;
  /** 非 hit 时给人类可读的原因 */
  note: string;
}

export class FicHub {
  /** 修一修用户输入：去空白、补协议、最低限度的合法性检查 */
  static normalizeUrl(input: string): string {
    let s = input.trim();
    if (s.length === 0) {
      throw new FicHubError('请先粘贴作品链接');
    }
    if (!s.startsWith('http://') && !s.startsWith('https://')) {
      s = `https://${s}`;
    }
    const schemeEnd = s.indexOf('://') + 3;
    const slashAt = s.indexOf('/', schemeEnd);
    const host = slashAt < 0 ? s.substring(schemeEnd) : s.substring(schemeEnd, slashAt);
    if (!host.includes('.')) {
      throw new FicHubError('这不像一个有效的链接，请检查后重试');
    }
    return s;
  }

  /**
   * 缓存探测：这个 URL 对应的作品是否在 FicHub 缓存里。
   *
   * 命中 → status=hit，带真实元信息。它是智能检索的反幻觉闸门：
   * 模型编造的 URL 在这里必然死掉（变成 rejected 或超时）。
   *
   * 两层加速：ctx 给了就先查本地落盘缓存（TTL 内零网络请求）；
   * 未命中再打 FicHub，命中后回写本地。限流冷却时间戳也随 ctx 持久化。
   *
   * 注意：探测一个未缓存的真实作品会触发 FicHub 去源站现场确认，
   * 要等较久 —— 所以 timeoutMs 必须短（十几秒），
   * 宁可把"冷门但真实"误判成未命中，也不能让一次检索干等几分钟。
   */
  static async probeCache(storyUrl: string, timeoutMs: number,
    ctx?: common.UIAbilityContext): Promise<ProbeResult> {
    // 本地缓存优先：命中不花任何 FicHub 配额，冷却期也照常可用
    if (ctx !== undefined) {
      const cached = await FicCache.getMeta(ctx, storyUrl);
      if (cached !== null) {
        Log.i(`探测命中本地缓存：${storyUrl}`);
        return { status: 'hit', meta: cached, note: '' };
      }
    }
    // 冷却期内直接报限流，不再消耗对方的配额
    if (ctx !== undefined) {
      const saved = await FicCache.getCooldown(ctx);
      if (saved > FicHub.lastLimitedAt) {
        FicHub.lastLimitedAt = saved;
      }
    }
    const remain = FicHub.cooldownRemain();
    if (remain > 0) {
      return { status: 'limited', meta: null, note: `FicHub 对本网络限流中（约 ${Math.ceil(remain / 1000)} 秒后恢复）` };
    }
    const req = http.createHttp();
    try {
      const header: Record<string, string> = { 'Accept': 'application/json' };
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: header,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 10000,
        readTimeout: timeoutMs
      };
      const resp = await req.request(`${API}${encodeURIComponent(storyUrl)}`, options);
      if (resp.responseCode === 429) {
        FicHub.lastLimitedAt = Date.now();
        if (ctx !== undefined) {
          await FicCache.setCooldown(ctx, FicHub.lastLimitedAt);
        }
        return { status: 'limited', meta: null, note: 'FicHub 正在限流，这次没核实到，稍后再搜可能就有' };
      }
      if (resp.responseCode !== 200) {
        return { status: 'error', meta: null, note: `FicHub 返回 HTTP ${resp.responseCode}` };
      }
      const data = JSON.parse(resp.result as string) as FicApiResponse;
      if (data.err !== 0) {
        // FicHub 明确拒绝：多半是模型记错了链接（编造的 ID 会死在这），或站点不支持
        const why = data.error !== undefined && data.error.length > 0 ? data.error :
          (data.info !== undefined && data.info.length > 0 ? data.info : '无法导出');
        return { status: 'rejected', meta: null, note: why };
      }
      let epubUrl = data.epub_url ?? '';
      if (epubUrl.length === 0) {
        return { status: 'rejected', meta: null, note: 'FicHub 未返回下载地址' };
      }
      if (!epubUrl.startsWith('http')) {
        epubUrl = SITE + epubUrl;
      }
      const meta = data.meta ?? ({} as FicApiMeta);
      const out: FicMeta = {
        title: meta.title ?? '未知作品',
        author: meta.author ?? '',
        chapters: meta.chapters ?? 0,
        words: meta.words ?? 0,
        info: data.info ?? '',
        epubUrl: epubUrl,
        sourceUrl: storyUrl
      };
      if (ctx !== undefined) {
        await FicCache.putMeta(ctx, out);
      }
      return { status: 'hit', meta: out, note: '' };
    } catch (e) {
      // 超时占绝大多数：可能是未缓存（FicHub 在现场抓源站），也可能只是网络慢
      const raw = (e as Error).message;
      Log.i(`探测未命中（${raw}）：${storyUrl}`);
      if (raw.includes('timeout') || raw.includes('Timeout')) {
        return { status: 'miss', meta: null, note: '响应超时：可能未缓存，也可能网络较慢' };
      }
      return { status: 'error', meta: null, note: `网络错误：${raw}` };
    } finally {
      req.destroy();
    }
  }

  /**
   * 应用级限流冷却。FicHub 按 IP 限流，而手机流量的出口是运营商 NAT，
   * IP 配额与他人共享 —— 一旦撞上 429，短时间内的重试只会火上浇油。
   * 记住被限流的时刻，冷却期内直接快速失败，把恢复的主动权交给时间。
   */
  private static lastLimitedAt: number = 0;
  private static readonly COOLDOWN_MS: number = 60000;

  private static cooldownRemain(): number {
    const passed = Date.now() - FicHub.lastLimitedAt;
    return passed < FicHub.COOLDOWN_MS ? FicHub.COOLDOWN_MS - passed : 0;
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }

  /** 服务端给的 Retry-After 头（秒），没有或非法返回 0 */
  private static retryAfterMs(resp: http.HttpResponse): number {
    try {
      const h = JSON.parse(JSON.stringify(resp.header)) as Record<string, string>;
      const keys = Object.keys(h);
      for (let i = 0; i < keys.length; i++) {
        if (keys[i].toLowerCase() === 'retry-after') {
          const v = parseInt(h[keys[i]], 10);
          if (!Number.isNaN(v) && v > 0) {
            return v * 1000;
          }
        }
      }
    } catch (e) {
      // 头拿不到就按自家退避节奏走
    }
    return 0;
  }

  /**
   * 带限流退避的 GET。429/5xx 依次等 5s/10s/20s/30s（尊重 Retry-After，取两者较大值），
   * 共发最多 5 次；onWait 把每次等待告诉 UI，让"卡住"变成"看得见的重试"。
   * 重试耗尽后返回最后一次响应，由调用方决定怎么报错。
   */
  private static async getWithRetry(url: string, expect: http.HttpDataType, timeoutMs: number,
    accept: string, onWait: (attempt: number, waitMs: number) => void,
    ctx?: common.UIAbilityContext): Promise<http.HttpResponse> {
    if (ctx !== undefined) {
      const saved = await FicCache.getCooldown(ctx);
      if (saved > FicHub.lastLimitedAt) {
        FicHub.lastLimitedAt = saved;
      }
    }
    const remain = FicHub.cooldownRemain();
    if (remain > 0) {
      throw new FicHubError(`FicHub 刚刚对本网络限流，约 ${Math.ceil(remain / 1000)} 秒后恢复。稍等片刻再试即可`);
    }
    const waits: number[] = [5000, 10000, 20000, 30000];
    let resp: http.HttpResponse | null = null;
    for (let attempt = 0; attempt <= waits.length; attempt++) {
      if (attempt > 0) {
        let wait = waits[attempt - 1];
        if (resp !== null) {
          const ra = FicHub.retryAfterMs(resp);
          if (ra > wait) {
            wait = ra;
          }
        }
        onWait(attempt, wait);
        await FicHub.sleep(wait);
      }
      const req = http.createHttp();
      try {
        const header: Record<string, string> = { 'Accept': accept };
        const options: http.HttpRequestOptions = {
          method: http.RequestMethod.GET,
          header: header,
          expectDataType: expect,
          connectTimeout: 15000,
          readTimeout: timeoutMs
        };
        resp = await req.request(url, options);
        if (resp.responseCode === 429) {
          FicHub.lastLimitedAt = Date.now();
          if (ctx !== undefined) {
            await FicCache.setCooldown(ctx, FicHub.lastLimitedAt);
          }
        }
        if (resp.responseCode !== 429 && resp.responseCode < 500) {
          return resp;
        }
      } finally {
        req.destroy();
      }
    }
    return resp as http.HttpResponse;
  }

  /** 请求导出任务，拿到作品元信息和 EPUB 下载地址 */
  static async fetchMeta(storyUrl: string, onProgress: (msg: string) => void,
    ctx?: common.UIAbilityContext): Promise<FicMeta> {
    onProgress('正在请求 FicHub…（首次导出可能要等一两分钟，请勿退出）');
    try {
      const resp = await FicHub.getWithRetry(`${API}${encodeURIComponent(storyUrl)}`,
        http.HttpDataType.STRING, READ_TIMEOUT, 'application/json', (attempt: number, waitMs: number) => {
          onProgress(`FicHub 在限流，${Math.round(waitMs / 1000)} 秒后自动重试（第 ${attempt} 次）…`);
        }, ctx);
      if (resp.responseCode === 429) {
        throw new FicHubError('FicHub 正在限流（HTTP 429）。手机流量的出口 IP 常与他人共享配额，换 Wi-Fi 或等一两分钟通常能恢复');
      }
      if (resp.responseCode !== 200) {
        throw new FicHubError(`FicHub 服务返回 HTTP ${resp.responseCode}`);
      }
      const data = JSON.parse(resp.result as string) as FicApiResponse;
      if (data.err !== 0) {
        const why = data.error !== undefined && data.error.length > 0 ? data.error :
          (data.info !== undefined && data.info.length > 0 ? data.info : 'FicHub 无法导出这个链接');
        throw new FicHubError(`${why}。FicHub 支持 AO3、FanFiction.net、SpaceBattles 等站点，可换一个链接试试`);
      }
      let epubUrl = data.epub_url ?? '';
      if (epubUrl.length === 0) {
        throw new FicHubError('FicHub 没有返回下载地址');
      }
      if (!epubUrl.startsWith('http')) {
        epubUrl = SITE + epubUrl;
      }
      const meta = data.meta ?? ({} as FicApiMeta);
      const out: FicMeta = {
        title: meta.title ?? '未知作品',
        author: meta.author ?? '',
        chapters: meta.chapters ?? 0,
        words: meta.words ?? 0,
        info: data.info ?? '',
        epubUrl: epubUrl,
        sourceUrl: storyUrl
      };
      return out;
    } catch (e) {
      if (e instanceof FicHubError) {
        throw e as Error;
      }
      const raw = (e as Error).message;
      Log.e(`FicHub 请求失败：${raw}`);
      if (raw.includes('timeout') || raw.includes('Timeout')) {
        throw new FicHubError('等待 FicHub 超时了。冷门作品首次导出很慢，稍后再试通常能命中它的缓存');
      }
      throw new FicHubError(`网络请求失败：${raw}`);
    }
  }

  /** 下载 EPUB 到应用缓存目录，返回本地路径（供 Importer.importFromPath 接力） */
  static async downloadEpub(ctx: common.UIAbilityContext, meta: FicMeta,
    onProgress: (msg: string) => void): Promise<string> {
    onProgress(`正在下载《${meta.title}》的 EPUB…`);
    try {
      const resp = await FicHub.getWithRetry(meta.epubUrl,
        http.HttpDataType.ARRAY_BUFFER, READ_TIMEOUT, '*/*', (attempt: number, waitMs: number) => {
          onProgress(`FicHub 在限流，${Math.round(waitMs / 1000)} 秒后自动重试（第 ${attempt} 次）…`);
        }, ctx);
      if (resp.responseCode === 429) {
        throw new FicHubError('FicHub 正在限流（HTTP 429）。手机流量的出口 IP 常与他人共享配额，换 Wi-Fi 或等一两分钟通常能恢复');
      }
      if (resp.responseCode !== 200) {
        throw new FicHubError(`下载 EPUB 失败（HTTP ${resp.responseCode}）`);
      }
      const buf = resp.result as ArrayBuffer;
      if (buf.byteLength === 0) {
        throw new FicHubError('下载到的文件是空的，请稍后重试');
      }
      const path = `${ctx.cacheDir}/fetch_${Date.now()}_${FicHub.fileSafeName(meta.title)}.epub`;
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, buf);
      } finally {
        fs.closeSync(file);
      }
      Log.i(`FicHub EPUB 已下载：${path}（${buf.byteLength} 字节）`);
      return path;
    } catch (e) {
      if (e instanceof FicHubError) {
        throw e as Error;
      }
      const raw = (e as Error).message;
      Log.e(`FicHub 下载失败：${raw}`);
      throw new FicHubError(`下载 EPUB 失败：${raw}`);
    }
  }

  /** 标题里常有标点，直接当文件名在部分场景会出问题 */
  static fileSafeName(title: string): string {
    const cleaned = title.replace(/[\\/:*?"<>|\r\n]+/g, '_').trim();
    if (cleaned.length === 0) {
      return 'fic';
    }
    return cleaned.length > 40 ? cleaned.substring(0, 40) : cleaned;
  }
}
