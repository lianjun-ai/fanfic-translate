import { http } from '@kit.NetworkKit';
import { Log } from '../common/Logger';

/**
 * Tavily（tavily.com）联网搜索客户端。
 *
 * 智能检索的数据源：模型靠它拿到真实存在的网页链接，而不是凭记忆编。
 * API：POST https://api.tavily.com/search，Bearer 鉴权。
 * 免费档每月 1000 次调用，对本应用的个人使用量级绰绰有余。
 */

const ENDPOINT: string = 'https://api.tavily.com/search';

interface TavilyItem {
  title?: string;
  url?: string;
  content?: string;
}

/** 只声明用到的字段 */
interface TavilyResponse {
  results?: TavilyItem[];
}

/** 一条搜索结果（喂给模型的最小集，省 token） */
export interface TavilyHit {
  title: string;
  url: string;
  snippet: string;
}

export class TavilyError extends Error {
  constructor(msg: string) {
    super(msg);
    this.name = 'TavilyError';
  }
}

export class Tavily {
  /**
   * 搜一次，返回真实网页结果（可能为空数组，不代表失败）。
   *
   * 查询里的 `site:xxx` 会被解析成 Tavily 原生的 include_domains 参数——
   * 塞在查询串里 Tavily 不保证生效，站点限定必须走参数才可靠。
   * search_depth 用 advanced：同人文属于长尾内容，basic 档索引太浅。
   */
  static async search(key: string, query: string, maxResults: number): Promise<TavilyHit[]> {
    const k = key.trim();
    if (k.length === 0) {
      throw new TavilyError('还没有填写搜索 Key（Tavily）');
    }
    const domains: string[] = [];
    const kept: string[] = [];
    const words = query.split(/\s+/);
    for (let i = 0; i < words.length; i++) {
      const w = words[i];
      if (w.toLowerCase().startsWith('site:') && w.length > 5) {
        domains.push(w.substring(5));
      } else if (w.length > 0) {
        kept.push(w);
      }
    }
    const q = kept.join(' ').trim();
    const req = http.createHttp();
    try {
      const header: Record<string, string> = {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${k}`
      };
      const body: Record<string, Object> = {
        'query': q.length > 0 ? q : query,
        'max_results': maxResults,
        'search_depth': 'advanced',
        'include_answer': false
      };
      if (domains.length > 0) {
        body['include_domains'] = domains;
      }
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: header,
        extraData: JSON.stringify(body),
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: 30000
      };
      const resp = await req.request(ENDPOINT, options);
      if (resp.responseCode === 401 || resp.responseCode === 403) {
        throw new TavilyError('搜索 Key 无效或已过期，请到设置里检查 Tavily Key');
      }
      if (resp.responseCode === 429) {
        throw new TavilyError('Tavily 配额用完了（免费档每月 1000 次），或请求过于频繁');
      }
      if (resp.responseCode !== 200) {
        throw new TavilyError(`搜索服务返回 HTTP ${resp.responseCode}`);
      }
      const data = JSON.parse(resp.result as string) as TavilyResponse;
      const list = data.results ?? [];
      const out: TavilyHit[] = [];
      for (let i = 0; i < list.length && out.length < maxResults; i++) {
        const it = list[i];
        const url = it.url ?? '';
        if (!url.startsWith('http://') && !url.startsWith('https://')) {
          continue;
        }
        const snippet = it.content ?? '';
        const hit: TavilyHit = {
          title: it.title ?? url,
          url: url,
          snippet: snippet.length > 240 ? `${snippet.substring(0, 240)}…` : snippet
        };
        out.push(hit);
      }
      return out;
    } catch (e) {
      if (e instanceof TavilyError) {
        throw e as Error;
      }
      const raw = (e as Error).message;
      Log.e(`Tavily 搜索失败：${raw}`);
      if (raw.includes('timeout') || raw.includes('Timeout')) {
        throw new TavilyError('搜索请求超时了，稍后再试');
      }
      throw new TavilyError(`搜索请求失败：${raw}`);
    } finally {
      req.destroy();
    }
  }
}
