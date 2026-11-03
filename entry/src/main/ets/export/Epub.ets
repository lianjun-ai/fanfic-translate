import { util } from '@kit.ArkTS';
import { Chapter, Paragraph, Work } from '../model/Models';
import { HtmlFrag } from './HtmlFrag';
import { Zip, ZipEntry } from './Zip';

/** 一章的完整数据（章节 + 段落），避免导出时重复查库 */
export interface ChapterData {
  chapter: Chapter;
  paras: Paragraph[];
}

/**
 * EPUB 3 导出。
 *
 * 产出是标准的 EPUB 3 包，同时带 toc.ncx 以兼容只认 EPUB 2 的旧阅读器。
 * 目录结构：
 *
 *   mimetype                     ← 必须第一个且未压缩，内容是 application/epub+zip
 *   META-INF/container.xml       ← 指向 OPF
 *   OEBPS/content.opf            ← 书脊 + manifest + 元数据
 *   OEBPS/nav.xhtml              ← EPUB3 目录（properties="nav"）
 *   OEBPS/toc.ncx                ← EPUB2 兼容目录
 *   OEBPS/style.css
 *   OEBPS/text/c0001.xhtml ...   ← 每章一个 XHTML
 *
 * 打包用自己写的 stored-zip（见 Zip.ets）：zlib 做不出合规的 mimetype 条目。
 */
export class Epub {

  /** CSS 与 HTML 导出保持同一套视觉，只是去掉行宽限制（交给阅读器控制） */
  private static readonly CSS: string = `body { font-family: Georgia, 'Songti SC', SimSun, serif;
  line-height: 1.9; color: #222; margin: 0 4%; }
h1 { font-size: 1.5em; margin: 0 0 4px; }
h2 { font-size: 1.2em; margin: 2.4em 0 0.8em; border-bottom: 1px solid #ddd; padding-bottom: 4px; }
h3 { font-size: 1.05em; margin: 1.6em 0 0.6em; }
p { margin: 0.9em 0; text-align: justify; }
p.src { color: #999; font-size: 0.86em; margin-bottom: 0.1em; }
p.note, .note { color: #8a7f70; font-size: 0.9em; }
blockquote { margin: 1em 0; padding: 2px 14px; border-left: 3px solid #d8d2c6; color: #555; }
hr { border: none; border-top: 1px solid #ddd; margin: 1.8em auto; width: 40%; }
.meta { color: #8a7f70; font-size: 0.9em; margin-bottom: 2em; }
nav ol { list-style: none; padding-left: 0; }
nav li { margin: 0.5em 0; }
`;

  /** chapter_0001.xhtml 这类文件名（ASCII，避免阅读器对中文路径处理不一致） */
  private static chapterFile(index: number): string {
    const n = index + 1;
    const pad = n < 10 ? `000${n}` : (n < 100 ? `00${n}` : (n < 1000 ? `0${n}` : `${n}`));
    return `text/c${pad}.xhtml`;
  }

  private static xhtmlDoc(title: string, bodyHtml: string, cssHref: string): string {
    return `<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="zh-CN" lang="zh-CN">
<head>
<meta charset="utf-8"/>
<title>${HtmlFrag.esc(title)}</title>
<link rel="stylesheet" type="text/css" href="${cssHref}"/>
</head>
<body>
${bodyHtml}
</body>
</html>
`;
  }

  private static containerXml(): string {
    return `<?xml version="1.0" encoding="utf-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
`;
  }

  private static navXhtml(work: Work, data: ChapterData[]): string {
    const items: string[] = [];
    for (let i = 0; i < data.length; i++) {
      items.push(`<li><a href="${Epub.chapterFile(i)}">${HtmlFrag.esc(data[i].chapter.title)}</a></li>`);
    }
    const body = `<nav epub:type="toc" id="toc">
<h1>目录</h1>
<ol>
${items.join('\n')}
</ol>
</nav>`;
    // nav 在 OEBPS 根目录，样式表同目录
    return Epub.xhtmlDoc(`目录 - ${work.title}`, body, 'style.css');
  }

  /** EPUB2 兼容目录。playOrder 必须连续递增 */
  private static tocNcx(work: Work, data: ChapterData[], uuid: string): string {
    const points: string[] = [];
    for (let i = 0; i < data.length; i++) {
      const order = i + 1;
      points.push(`    <navPoint id="np${order}" playOrder="${order}">
      <navLabel><text>${HtmlFrag.esc(data[i].chapter.title)}</text></navLabel>
      <content src="${Epub.chapterFile(i)}"/>
    </navPoint>`);
    }
    return `<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="${uuid}"/>
    <meta name="dtb:depth" content="1"/>
    <meta name="dtb:totalPageCount" content="0"/>
    <meta name="dtb:maxPageNumber" content="0"/>
  </head>
  <docTitle><text>${HtmlFrag.esc(work.title)}</text></docTitle>
  <navMap>
${points.join('\n')}
  </navMap>
</ncx>
`;
  }

  /** OPF：元数据 + manifest + spine。nav 项必须带 properties="nav" */
  private static contentOpf(work: Work, data: ChapterData[], uuid: string, bilingual: boolean): string {
    const manifest: string[] = [
      '    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>',
      '    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
      '    <item id="css" href="style.css" media-type="text/css"/>'
    ];
    const spine: string[] = [];
    for (let i = 0; i < data.length; i++) {
      manifest.push(`    <item id="c${i + 1}" href="${Epub.chapterFile(i)}" media-type="application/xhtml+xml"/>`);
      spine.push(`    <itemref idref="c${i + 1}"/>`);
    }

    const d = new Date();
    const pad = (n: number): string => n < 10 ? `0${n}` : `${n}`;
    // dcterms:modified 必须是 UTC 的 CCYY-MM-DDThh:mm:ssZ
    const utc = `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}` +
      `T${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}:${pad(d.getUTCSeconds())}Z`;
    const author = work.author.length > 0 ? work.author : '佚名';
    const note = bilingual ? '双语对照 · 同人译站导出' : '同人译站导出';

    return `<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid" xml:lang="zh-CN">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bookid">${uuid}</dc:identifier>
    <dc:title>${HtmlFrag.esc(work.title)}</dc:title>
    <dc:creator>${HtmlFrag.esc(author)}</dc:creator>
    <dc:language>zh-CN</dc:language>
    <dc:description>${HtmlFrag.esc(note)}</dc:description>
    <meta property="dcterms:modified">${utc}</meta>
  </metadata>
  <manifest>
${manifest.join('\n')}
  </manifest>
  <spine toc="ncx">
${spine.join('\n')}
  </spine>
</package>
`;
  }

  /**
   * 组装整本 EPUB。
   *
   * @param data 已按顺序排好的章节数据
   * @return 完整的 .epub 字节流
   */
  static build(work: Work, data: ChapterData[], bilingual: boolean): Uint8Array {
    if (data.length === 0) {
      throw new Error('没有可导出的章节');
    }
    const uuid = `urn:uuid:${util.generateRandomUUID()}`;

    const entries: ZipEntry[] = [];
    // mimetype 必须是第一个条目，且方法为 stored（Zip 全程 stored，天然满足）
    entries.push({ name: 'mimetype', data: Zip.utf8('application/epub+zip') });
    entries.push({ name: 'META-INF/container.xml', data: Zip.utf8(Epub.containerXml()) });
    entries.push({ name: 'OEBPS/content.opf', data: Zip.utf8(Epub.contentOpf(work, data, uuid, bilingual)) });
    entries.push({ name: 'OEBPS/nav.xhtml', data: Zip.utf8(Epub.navXhtml(work, data)) });
    entries.push({ name: 'OEBPS/toc.ncx', data: Zip.utf8(Epub.tocNcx(work, data, uuid)) });
    entries.push({ name: 'OEBPS/style.css', data: Zip.utf8(Epub.CSS) });

    for (let i = 0; i < data.length; i++) {
      const body = HtmlFrag.chapterHtml(data[i].chapter, data[i].paras, bilingual);
      entries.push({
        name: `OEBPS/${Epub.chapterFile(i)}`,
        data: Zip.utf8(Epub.xhtmlDoc(data[i].chapter.title, body, '../style.css'))
      });
    }

    return Zip.pack(entries);
  }
}
