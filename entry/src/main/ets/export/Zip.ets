import { util } from '@kit.ArkTS';

/** 一个待打包的 zip 条目。data 是已编码好的原始字节 */
export interface ZipEntry {
  name: string;
  data: Uint8Array;
}

/**
 * 最小化的 zip 打包器（stored 模式，不压缩）。
 *
 * 为什么不用 zlib：EPUB 规范要求 `mimetype` 条目「不压缩 + 无 extra field +
 * 排在压缩包第一个」。zlib 的 Options 只有 level/memLevel/strategy，没有
 * "存储不压缩" 模式，compressFiles 也控制不了条目顺序 —— 出来的包不合规，
 * 阅读器会直接拒读。所以这里手工写 zip 结构，完全掌控顺序与方法位。
 *
 * 结构（全部小端）：
 *   [local header + data] × N → [central directory header] × N → [EOCD]
 *
 * 文本类 EPUB 不压缩体积也能接受（正文多为 UTF-8 文本，压缩收益约 3 倍，
 * 但换来的是零依赖 + 100% 合规）。
 */
export class Zip {

  /** CRC32 查找表，首次使用时构建 */
  private static crcTable: number[] | null = null;

  private static table(): number[] {
    if (Zip.crcTable !== null) {
      return Zip.crcTable;
    }
    const t: number[] = [];
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) {
        c = (c & 1) === 1 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
      }
      t.push(c >>> 0);
    }
    Zip.crcTable = t;
    return t;
  }

  /** 标准 CRC-32（多项式 0xEDB88320），返回无符号 32 位 */
  static crc32(data: Uint8Array): number {
    const t = Zip.table();
    let c = 0xFFFFFFFF;
    for (let i = 0; i < data.length; i++) {
      c = t[(c ^ data[i]) & 0xFF] ^ (c >>> 8);
    }
    return (c ^ 0xFFFFFFFF) >>> 0;
  }

  /** 把字符串按 UTF-8 编码成字节 */
  static utf8(s: string): Uint8Array {
    return new util.TextEncoder().encodeInto(s);
  }

  /**
   * 打包。顺序严格按传入顺序，调用方负责把 mimetype 放第一个。
   *
   * 先把所有条目的元信息算完（CRC、偏移），再一次性分配缓冲写入 ——
   * 两遍扫描，避免中间数组反复扩容。
   */
  static pack(entries: ZipEntry[]): Uint8Array {
    const nameBytes: Uint8Array[] = [];
    const crcs: number[] = [];
    const offsets: number[] = [];
    let total = 0;

    for (let i = 0; i < entries.length; i++) {
      const nb = Zip.utf8(entries[i].name);
      nameBytes.push(nb);
      crcs.push(Zip.crc32(entries[i].data));
      offsets.push(total);
      total += 30 + nb.length + entries[i].data.length;
    }

    const cdStart = total;
    for (let i = 0; i < entries.length; i++) {
      total += 46 + nameBytes[i].length;
    }
    total += 22; // EOCD

    const out = new Uint8Array(total);
    const view = new DataView(out.buffer);

    // DOS 时间格式：秒数只有 2 秒精度，年份从 1980 起算
    const now = new Date();
    const dosTime = (now.getHours() << 11) | (now.getMinutes() << 5) | (now.getSeconds() >> 1);
    const dosDate = ((now.getFullYear() - 1980) << 9) | ((now.getMonth() + 1) << 5) | now.getDate();

    let p = 0;
    // ---- local file headers + data ----
    for (let i = 0; i < entries.length; i++) {
      const nb = nameBytes[i];
      const data = entries[i].data;
      view.setUint32(p, 0x04034B50, true);      // 签名
      view.setUint16(p + 4, 20, true);          // 解压所需版本 2.0
      view.setUint16(p + 6, 0, true);           // 通用标志（文件名全 ASCII，无需 UTF-8 位）
      view.setUint16(p + 8, 0, true);           // 压缩方法 0 = stored
      view.setUint16(p + 10, dosTime, true);
      view.setUint16(p + 12, dosDate, true);
      view.setUint32(p + 14, crcs[i], true);
      view.setUint32(p + 18, data.length, true); // 压缩后大小 = 原大小
      view.setUint32(p + 22, data.length, true); // 原始大小
      view.setUint16(p + 26, nb.length, true);
      view.setUint16(p + 28, 0, true);           // extra field 长度必须为 0
      p += 30;
      out.set(nb, p);
      p += nb.length;
      out.set(data, p);
      p += data.length;
    }

    // ---- central directory ----
    for (let i = 0; i < entries.length; i++) {
      const nb = nameBytes[i];
      const size = entries[i].data.length;
      view.setUint32(p, 0x02014B50, true);
      view.setUint16(p + 4, 20, true);          // version made by
      view.setUint16(p + 6, 20, true);          // version needed
      view.setUint16(p + 8, 0, true);           // flags
      view.setUint16(p + 10, 0, true);          // method
      view.setUint16(p + 12, dosTime, true);
      view.setUint16(p + 14, dosDate, true);
      view.setUint32(p + 16, crcs[i], true);
      view.setUint32(p + 20, size, true);
      view.setUint32(p + 24, size, true);
      view.setUint16(p + 28, nb.length, true);
      view.setUint16(p + 30, 0, true);          // extra
      view.setUint16(p + 32, 0, true);          // comment
      view.setUint16(p + 34, 0, true);          // disk number start
      view.setUint16(p + 36, 0, true);          // internal attrs
      view.setUint32(p + 38, 0, true);          // external attrs
      view.setUint32(p + 42, offsets[i], true); // 对应 local header 偏移
      p += 46;
      out.set(nb, p);
      p += nb.length;
    }

    // ---- EOCD ----
    const cdSize = p - cdStart;
    view.setUint32(p, 0x06054B50, true);
    view.setUint16(p + 4, 0, true);             // 当前磁盘号
    view.setUint16(p + 6, 0, true);             // 中央目录起始磁盘
    view.setUint16(p + 8, entries.length, true);
    view.setUint16(p + 10, entries.length, true);
    view.setUint32(p + 12, cdSize, true);
    view.setUint32(p + 16, cdStart, true);
    view.setUint16(p + 20, 0, true);            // 注释长度

    return out;
  }
}
