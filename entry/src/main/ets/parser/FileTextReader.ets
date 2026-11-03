import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Log } from '../common/Logger';

export class FileKind {
  static readonly EPUB: string = 'epub';
  static readonly PDF: string = 'pdf';
  static readonly HTML: string = 'html';
  static readonly TEXT: string = 'text';
  static readonly UNKNOWN: string = 'unknown';
}

/**
 * 统一文件读取。
 *
 * 两个真实世界的坑都在这里解决：
 * 1) 下载来的 "txt" 常常是 HTML 甚至是 zip(epub)，扩展名不可信，必须嗅探魔数；
 * 2) 中文网文常见 GBK，少数编辑器会存成带 BOM 的 UTF-16，
 *    HarmonyOS 的 readTextSync 只认 UTF-8，直接读会得到空串或乱码。
 */
export class FileTextReader {
  /** 读原始字节 */
  static readBytes(path: string): ArrayBuffer {
    const stat = fs.statSync(path);
    const size = stat.size;
    if (size <= 0) {
      return new ArrayBuffer(0);
    }
    const buf = new ArrayBuffer(size);
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      // readSync 单次调用不保证读满，必须循环到 EOF。
      // 大体积章节文件被截断会表现为"正文只解析出一半"，很难察觉。
      const view = new Uint8Array(buf);
      let offset = 0;
      while (offset < size) {
        const chunk = new ArrayBuffer(size - offset);
        const read = fs.readSync(file.fd, chunk);
        if (read <= 0) {
          break;
        }
        view.set(new Uint8Array(chunk, 0, read), offset);
        offset += read;
      }
      if (offset < size) {
        Log.w(`文件未读满: ${path}，期望 ${size} 实际 ${offset}`);
        return buf.slice(0, offset);
      }
    } finally {
      fs.closeSync(file);
    }
    return buf;
  }

  /** 按 BOM/编码探测解码为字符串 */
  static read(path: string): string {
    return FileTextReader.decode(FileTextReader.readBytes(path));
  }

  static decode(buf: ArrayBuffer): string {
    const bytes = new Uint8Array(buf);
    const n = bytes.length;
    if (n === 0) {
      return '';
    }

    // UTF-16 BOM
    if (n >= 2 && bytes[0] === 0xFF && bytes[1] === 0xFE) {
      return FileTextReader.decodeUtf16(bytes, 2, true);
    }
    if (n >= 2 && bytes[0] === 0xFE && bytes[1] === 0xFF) {
      return FileTextReader.decodeUtf16(bytes, 2, false);
    }
    // UTF-8 BOM
    if (n >= 3 && bytes[0] === 0xEF && bytes[1] === 0xBB && bytes[2] === 0xBF) {
      const body = bytes.subarray(3);
      const t = FileTextReader.decodeUtf8(body);
      return t.length > 0 ? t : FileTextReader.decodeGbk(body, 0);
    }

    let text = FileTextReader.decodeUtf8(bytes);
    const bad = FileTextReader.countBad(text);
    if (bad > 0 || text.length === 0) {
      const gbk = FileTextReader.decodeGbk(bytes, bad);
      if (gbk.length > 0) {
        text = gbk;
      }
    }
    return text;
  }

  private static decodeUtf8(bytes: Uint8Array): string {
    try {
      return util.TextDecoder.create('utf-8').decodeToString(bytes);
    } catch (e) {
      return '';
    }
  }

  private static decodeGbk(bytes: Uint8Array, currentBad: number): string {
    try {
      const t = util.TextDecoder.create('gbk').decodeToString(bytes);
      if (t.length > 0 && FileTextReader.countBad(t) <= currentBad) {
        return t;
      }
    } catch (e) {
      Log.w('设备不支持 GBK 解码，保持 UTF-8 结果');
    }
    return '';
  }

  /** 手写 UTF-16 解码，避免依赖设备是否支持该编码名 */
  private static decodeUtf16(bytes: Uint8Array, offset: number, little: boolean): string {
    const codes: number[] = [];
    for (let i = offset; i + 1 < bytes.length; i += 2) {
      const c = little ? (bytes[i] | (bytes[i + 1] << 8)) : ((bytes[i] << 8) | bytes[i + 1]);
      codes.push(c);
    }
    let out = '';
    for (let i = 0; i < codes.length; i++) {
      out += String.fromCharCode(codes[i]);
    }
    return out;
  }

  private static countBad(s: string): number {
    let n = 0;
    for (let i = 0; i < s.length; i++) {
      if (s.charCodeAt(i) === 0xFFFD) {
        n++;
      }
    }
    return n;
  }

  /**
   * 用魔数判断真实格式。扩展名只作为兜底参考。
   */
  static sniff(path: string): string {
    let buf: ArrayBuffer;
    try {
      const stat = fs.statSync(path);
      const head = Math.min(64, stat.size);
      buf = new ArrayBuffer(head);
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        fs.readSync(file.fd, buf);
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      return FileKind.UNKNOWN;
    }
    return FileTextReader.sniffBytes(new Uint8Array(buf));
  }

  static sniffBytes(b: Uint8Array): string {
    if (b.length >= 4 && b[0] === 0x50 && b[1] === 0x4B &&
      (b[2] === 0x03 || b[2] === 0x05 || b[2] === 0x07)) {
      // ZIP 容器。epub 的 mimetype 文件在尾部，这里只看得到 PK 开头，
      // 交给调用方按扩展名或后续解包判断
      return FileKind.EPUB;
    }
    if (b.length >= 4 && b[0] === 0x25 && b[1] === 0x50 && b[2] === 0x44 && b[3] === 0x46) {
      return FileKind.PDF;
    }
    // 跳过 BOM/空白后看是否是 HTML
    let i = 0;
    if (b.length >= 3 && b[0] === 0xEF && b[1] === 0xBB && b[2] === 0xBF) {
      i = 3;
    }
    while (i < b.length && (b[i] === 0x20 || b[i] === 0x09 || b[i] === 0x0A || b[i] === 0x0D)) {
      i++;
    }
    if (i < b.length && b[i] === 0x3C) {
      let head = '';
      const end = Math.min(b.length, i + 40);
      for (let k = i; k < end; k++) {
        head += String.fromCharCode(b[k]);
      }
      const low = head.toLowerCase();
      if (low.startsWith('<!doctype html') || low.startsWith('<html') ||
        low.startsWith('<?xml') || low.startsWith('<body') || low.startsWith('<head')) {
        return FileKind.HTML;
      }
    }
    if (b.length > 0) {
      return FileKind.TEXT;
    }
    return FileKind.UNKNOWN;
  }
}
