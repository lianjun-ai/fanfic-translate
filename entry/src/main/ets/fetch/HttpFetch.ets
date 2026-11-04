import { fileIo as fs } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { Log } from '../common/Logger';

export interface FetchFileResult {
  ok: boolean;
  path: string;
  contentType: string;
  bytes: number;
  note: string;
}

/** 单文件下载上限，超过直接拒绝（同人文 EPUB 通常几 MB） */
const MAX_DOWNLOAD_BYTES: number = 60 * 1024 * 1024;

const UA: string = 'Mozilla/5.0 (Linux; HarmonyOS) AppleWebKit/537.36 (KHTML, like Gecko) Mobile Safari/537.36';

/** getText / postForm / request 的返回 */
export interface FetchTextResult {
  ok: boolean;
  code: number;
  text: string;
  note: string;
  /** 响应 Content-Type，request 会填，其它方法留空 */
  contentType: string;
}

/**
 * 裸 HTTP 文件下载，供 download_file 与网页抓书共用。
 * 只做「把字节落到临时目录」这一件事，格式判断和入库都由调用方决定。
 */
export class HttpFetch {
  /** GET 一个 URL，返回响应文本（跟随重定向后的最终内容） */
  static async getText(url: string, referer: string): Promise<FetchTextResult> {
    const req = http.createHttp();
    try {
      const header: Record<string, string> = {
        'Accept': 'text/html,application/json,*/*',
        'User-Agent': UA
      };
      if (referer.length > 0) {
        header['Referer'] = referer;
      }
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: header,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: 30000
      };
      const resp = await req.request(url, options);
      const text = typeof resp.result === 'string' ? resp.result : '';
      return { ok: resp.responseCode >= 200 && resp.responseCode < 300, code: resp.responseCode, text: text, note: '', contentType: '' };
    } catch (e) {
      return { ok: false, code: 0, text: '', note: `网络错误：${(e as Error).message}`, contentType: '' };
    } finally {
      req.destroy();
    }
  }

  /** POST 表单（application/x-www-form-urlencoded），返回响应文本 */
  static async postForm(url: string, form: Record<string, string>, referer: string): Promise<FetchTextResult> {
    const req = http.createHttp();
    try {
      const parts: string[] = [];
      const keys = Object.keys(form);
      for (let i = 0; i < keys.length; i++) {
        parts.push(`${encodeURIComponent(keys[i])}=${encodeURIComponent(form[keys[i]])}`);
      }
      const header: Record<string, string> = {
        'Accept': '*/*',
        'User-Agent': UA,
        'Content-Type': 'application/x-www-form-urlencoded'
      };
      if (referer.length > 0) {
        header['Referer'] = referer;
      }
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: header,
        extraData: parts.join('&'),
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: 30000
      };
      const resp = await req.request(url, options);
      const text = typeof resp.result === 'string' ? resp.result : '';
      return { ok: resp.responseCode >= 200 && resp.responseCode < 300, code: resp.responseCode, text: text, note: '', contentType: '' };
    } catch (e) {
      return { ok: false, code: 0, text: '', note: `网络错误：${(e as Error).message}`, contentType: '' };
    } finally {
      req.destroy();
    }
  }

  /**
   * 受限的原始请求：只支持 GET / POST，头部只允许 Referer 与 bodyType 决定的
   * Content-Type。给 finder 智能体探接口用 —— 没有任意头、没有 Cookie，
   * 避免它带着会话凭证乱发请求。
   */
  static async request(method: string, url: string, referer: string, body: string, bodyType: string): Promise<FetchTextResult> {
    const req = http.createHttp();
    try {
      const isPost = method.toUpperCase() === 'POST';
      const header: Record<string, string> = { 'Accept': '*/*', 'User-Agent': UA };
      if (referer.length > 0) {
        header['Referer'] = referer;
      }
      const options: http.HttpRequestOptions = {
        method: isPost ? http.RequestMethod.POST : http.RequestMethod.GET,
        header: header,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 15000,
        readTimeout: 30000
      };
      if (isPost && body.length > 0) {
        header['Content-Type'] = bodyType === 'json'
          ? 'application/json'
          : 'application/x-www-form-urlencoded';
        options.extraData = body;
      }
      const resp = await req.request(url, options);
      const text = typeof resp.result === 'string' ? resp.result : '';
      return {
        ok: resp.responseCode >= 200 && resp.responseCode < 300,
        code: resp.responseCode, text: text, note: '',
        contentType: HttpFetch.headerOf(resp, 'content-type')
      };
    } catch (e) {
      return { ok: false, code: 0, text: '', note: `网络错误：${(e as Error).message}`, contentType: '' };
    } finally {
      req.destroy();
    }
  }

  static async toFile(url: string, dir: string): Promise<FetchFileResult> {
    if (!fs.accessSync(dir)) {
      fs.mkdirSync(dir, true);
    }
    const req = http.createHttp();
    try {
      const header: Record<string, string> = { 'Accept': '*/*', 'User-Agent': UA };
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: header,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 15000,
        readTimeout: 120000
      };
      const resp = await req.request(url, options);
      if (resp.responseCode < 200 || resp.responseCode >= 300) {
        return { ok: false, path: '', contentType: '', bytes: 0, note: `HTTP ${resp.responseCode}` };
      }
      const buf = resp.result as ArrayBuffer;
      if (buf.byteLength === 0) {
        return { ok: false, path: '', contentType: '', bytes: 0, note: '下载到的文件是空的' };
      }
      if (buf.byteLength > MAX_DOWNLOAD_BYTES) {
        return { ok: false, path: '', contentType: '', bytes: buf.byteLength, note: '文件超过 60MB，已放弃' };
      }
      const ct = HttpFetch.headerOf(resp, 'content-type');
      const ext = HttpFetch.extOf(url, ct);
      const path = `${dir}/dl_${Date.now()}_${buf.byteLength}.${ext.length > 0 ? ext : 'bin'}`;
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, buf);
      } finally {
        fs.closeSync(file);
      }
      Log.i(`下载完成：${path}（${buf.byteLength} 字节，${ct}）`);
      return { ok: true, path: path, contentType: ct, bytes: buf.byteLength, note: '' };
    } catch (e) {
      const raw = (e as Error).message;
      const timeout = raw.includes('timeout') || raw.includes('Timeout');
      return { ok: false, path: '', contentType: '', bytes: 0, note: timeout ? '下载超时' : `网络错误：${raw}` };
    } finally {
      req.destroy();
    }
  }

  private static headerOf(resp: http.HttpResponse, key: string): string {
    try {
      const h = JSON.parse(JSON.stringify(resp.header)) as Record<string, string>;
      const keys = Object.keys(h);
      for (let i = 0; i < keys.length; i++) {
        if (keys[i].toLowerCase() === key) {
          return h[keys[i]];
        }
      }
    } catch (e) {
      Log.d('响应头解析失败');
    }
    return '';
  }

  /** 从 URL 或 Content-Type 推断电子书格式，认不出返回空串 */
  static extOf(url: string, contentType: string): string {
    const lower = url.toLowerCase();
    const q = lower.indexOf('?');
    const clean = q >= 0 ? lower.substring(0, q) : lower;
    if (clean.endsWith('.epub')) {
      return 'epub';
    }
    if (clean.endsWith('.txt')) {
      return 'txt';
    }
    if (clean.endsWith('.html') || clean.endsWith('.htm')) {
      return 'html';
    }
    const ct = contentType.toLowerCase();
    if (ct.indexOf('epub') >= 0) {
      return 'epub';
    }
    if (ct.indexOf('text/plain') >= 0) {
      return 'txt';
    }
    return '';
  }
}
