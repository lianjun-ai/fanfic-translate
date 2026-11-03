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

/**
 * 裸 HTTP 文件下载，供 download_file 与网页抓书共用。
 * 只做「把字节落到临时目录」这一件事，格式判断和入库都由调用方决定。
 */
export class HttpFetch {
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
