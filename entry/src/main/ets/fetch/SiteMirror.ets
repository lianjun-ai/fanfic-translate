/**
 * 站点镜像改写：少数站的原始链接在匿名环境里拿不到内容，
 * 但同一个帖子有个更好拿的等价地址。
 *
 * 现在只有一条：贴吧的 /p/{tid} 链接现在会 302 到「贴吧小程序」空壳页
 * （直抓、渲染都一样空），而 wap 版 /mo/m?kz={tid} 免登录、免渲染、
 * 免安全验证就能拿到全部楼层；再加 see_lz=1（只看楼主）——小说帖的正文
 * 都在楼主楼层，其它回复全是噪声（真机实测：整帖 467 楼里只看楼主只有 7 页）。
 *
 * 改写放在抓取入口统一做，模型和用户都不用记这些站内细节。
 */
export class SiteMirror {
  /** 贴吧一页 30 楼，pn 是楼层偏移（0、30、60…），不是页码 */
  private static readonly TIEBA_PAGE: number = 30;

  /**
   * 把链接换成同一内容里最好抓的等价地址；不认识的站原样返回。
   *
   * 贴吧要统一成「一个地址」的不止 /p/：模型自己探路时很容易拼出
   * /mo/q/m?kz=…&pn=2（贴吧真实存在的移动路由，能返回内容，但匿名请求
   * 忽略 pn，第几页都给第 1 页），或者省掉 see_lz 拿到一堆灌水回复。
   * 这些变体在这里一起归一到 /mo/m + 只看楼主 + 楼层偏移，模型拼什么
   * 都不会偏 —— 比在提示词里教它地址可靠（模型记的是模式不是字面）。
   */
  static url(url: string): string {
    const tid = SiteMirror.tiebaTid(url);
    if (tid.length > 0) {
      // 只有「要不要看别人的回复」这一个语义留给调用方；没写就默认只看楼主
      const lz = SiteMirror.query(url, 'see_lz');
      const lzFlag = lz === '0' ? '0' : '1';
      return `https://tieba.baidu.com/mo/m?kz=${tid}&see_lz=${lzFlag}&pn=${SiteMirror.tiebaOffset(url)}`;
    }
    return url;
  }

  /** 这个链接是不是被改写过（回包里可以据此交代一句） */
  static changed(url: string): boolean {
    return SiteMirror.url(url) !== url;
  }

  /** 从 /p/{tid}、/mo/m?kz={tid}、/mo/q/m?kz={tid}、?kz={tid} 里取帖子 id */
  private static tiebaTid(url: string): string {
    if (url.indexOf('tieba.baidu.com') < 0 && url.indexOf('tieba.com') < 0) {
      return '';
    }
    const path = url.match(/\/p\/(\d+)/);
    if (path !== null && path.length > 1) {
      return path[1];
    }
    const kz = url.match(/[?&]kz=(\d+)/);
    if (kz !== null && kz.length > 1) {
      return kz[1];
    }
    return '';
  }

  /**
   * 统一算成楼层偏移。
   * 只有 /mo/m 这一支的 pn 是楼层偏移（0、30、60）；/p/ 和 /mo/q/m 的 pn
   * 都是页码（1、2、3）。混用会「第 2 页」变成「从第 2 楼开始」——模型上次
   * 只拿到第 1 页，一半是错接口、一半是这种语义串台。
   */
  private static tiebaOffset(url: string): string {
    const pn = SiteMirror.query(url, 'pn');
    if (pn.length === 0 || !/^\d+$/.test(pn)) {
      return '0';
    }
    const n = Number(pn);
    const isFloorOffset = url.indexOf('/mo/m?') >= 0 || url.indexOf('/mo/m/') >= 0;
    const offset = isFloorOffset ? n : (n > 1 ? (n - 1) * SiteMirror.TIEBA_PAGE : 0);
    return `${offset}`;
  }

  private static query(url: string, key: string): string {
    const q = url.indexOf('?');
    if (q < 0) {
      return '';
    }
    const segs = url.substring(q + 1).split('&');
    for (let i = 0; i < segs.length; i++) {
      const kv = segs[i].split('=');
      if (kv.length > 1 && kv[0] === key) {
        return kv[1];
      }
    }
    return '';
  }

  /**
   * 贴吧 wap 页源码里有 "total_page":7、"page_size":30 —— 直接告诉模型
   * 这帖一共几页、下一批链接怎么给，省掉它反复试探 pn 的步数。
   * 返回空串表示这页没有分页线索（不是贴吧，或单页帖）。
   */
  static paginationHint(html: string, url: string): string {
    if (url.indexOf('tieba.baidu.com') < 0) {
      return '';
    }
    const total = SiteMirror.jsonNumber(html, 'total_page');
    const size = SiteMirror.jsonNumber(html, 'page_size');
    if (total <= 1 || size <= 0) {
      return '';
    }
    const pn = SiteMirror.query(url, 'pn');
    const cur = pn.length > 0 && /^\d+$/.test(pn) ? Math.floor(Number(pn) / size) + 1 : 1;
    if (cur >= total) {
      return `这是最后一页（第 ${total} 页，共 ${total} 页）`;
    }
    const next: string[] = [];
    for (let p = cur; p < total && next.length < 3; p++) {
      next.push(`${p * size}`);
    }
    return `这帖「只看楼主」共 ${total} 页（每页 ${size} 楼），当前是第 ${cur} 页；` +
      `后续页把 pn 依次改成 ${next.join('、')}… 再放进 urls 数组，一次最多 30 个链接`;
  }

  private static jsonNumber(html: string, key: string): number {
    const marker = `"${key}":`;
    const at = html.indexOf(marker);
    if (at < 0) {
      return 0;
    }
    let i = at + marker.length;
    while (i < html.length && (html.charAt(i) === ' ' || html.charAt(i) === '"')) {
      i++;
    }
    let digits = '';
    while (i < html.length) {
      const c = html.charAt(i);
      if (c >= '0' && c <= '9') {
        digits += c;
        i++;
      } else {
        break;
      }
    }
    return digits.length > 0 ? Number(digits) : 0;
  }
}
