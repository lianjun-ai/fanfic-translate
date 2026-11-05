/**
 * 反爬拦截页识别。
 *
 * 有一类 403 不是「抓不到」，而是「浏览器有机会过、裸请求一定过不去」：
 * 站点返回一张几十字节到几百字节的挑战页，页面上挂一段 JS，脚本跑完算出
 * 一个 Cookie（知乎是 __zse_ck）、写入后自己 reload，第二次请求才是真内容。
 * 这种页面：
 *   - 直抓（HttpFetch）永远只能拿到挑战页，改 UA、加 Referer 都没用；
 *   - 探接口（http_probe）同样 403；
 *   - 内置 ArkWeb 渲染**有机会**过（它就是一个真浏览器），但不保证 ——
 *     真机上知乎反复渲染也只拿到 39 字符的空页，挑战脚本没跑通。
 *
 * 所以在「直抓失败」和「这个站不可抓」之间必须分开：先让渲染器跑一次，
 * 渲染器也过不去，才谈收手（而且同一链接不要重复渲染）。识别放在这里，
 * 抓取三层（直抓 / 渲染 / 提示词）共用同一套判定，避免各说各话。
 */

/** 识别到的拦截类型，空串表示没识别出拦截页 */
export type BlockKind = '' | 'zhihu' | 'cloudflare' | 'captcha' | 'login';

export class AntiBot {
  /**
   * 从响应文本判断是不是拦截页。只看少量稳定特征，不做通用爬虫启发式 ——
   * 误判的代价是让调用方白白多跑一次渲染（十几秒）。
   */
  static detect(text: string): BlockKind {
    const t = text;
    if (t.length === 0) {
      return '';
    }
    // 知乎：挑战页才有 meta#zh-zse-ck，正文页没有
    if (t.indexOf('zh-zse-ck') >= 0 || t.indexOf('__zse_ck') >= 0) {
      return 'zhihu';
    }
    if (t.indexOf('Just a moment') >= 0 || t.indexOf('__cf_chl_opt') >= 0 ||
      t.indexOf('cf-browser-verification') >= 0 || t.indexOf('challenge-platform') >= 0) {
      return 'cloudflare';
    }
    const lower = t.toLowerCase();
    if ((lower.indexOf('geetest') >= 0 || lower.indexOf('captcha') >= 0) &&
      (t.indexOf('验证') >= 0 || lower.indexOf('verify') >= 0)) {
      return 'captcha';
    }
    // 被重定向到登录页：抓到的其实是登录表单
    if (t.indexOf('passport.') >= 0 && (t.indexOf('登录') >= 0 || lower.indexOf('signin') >= 0)) {
      return 'login';
    }
    return '';
  }

  /** 给模型看的一句话判读：这是什么墙、还能怎么过 */
  static hint(kind: BlockKind): string {
    if (kind === 'zhihu') {
      return '这是知乎的反爬挑战页（__zse_ck）：直抓、探接口、换 UA 一定 403，只有内置浏览器会执行挑战脚本。' +
        '但实测内置渲染多数也停在这张校验页上（拿到的是几十字符的空页）——看到「仍停在站点校验页」就收手，' +
        '同一链接重复渲染结果不会变，别再试 api.zhihu.com，也别把它说成滑块/验证码';
    }
    if (kind === 'cloudflare') {
      return '这是 Cloudflare 的浏览器校验页（Just a moment / __cf_chl）：裸请求一定过不去，只有内置浏览器执行完校验脚本才放行';
    }
    if (kind === 'captcha') {
      return '这是人机验证页（验证码/滑块）：需要用户手动过一次，程序抓不到，直接建议用户换路';
    }
    if (kind === 'login') {
      return '抓到的其实是登录页：这个地址要登录态才能看，直抓和渲染都一样，只能建议用户换路';
    }
    return '';
  }

  /**
   * 渲染结果判定。这里要比 detect 更严格：正文页的源码里也可能出现
   * 挑战脚本的引用（知乎正文页同样会加载 zse-ck 脚本），宽松判据会把
   * 短文章误判成拦截页。只有「挑战页独有的结构」才算命中。
   */
  static detectRendered(html: string, visibleChars: number): BlockKind {
    if (visibleChars > 4000) {
      return '';
    }
    // 挑战页独有的 meta（正文页没有这个 id）
    if (html.indexOf('id="zh-zse-ck"') >= 0 || html.indexOf('id=\'zh-zse-ck\'') >= 0) {
      return 'zhihu';
    }
    if (html.indexOf('__cf_chl_opt') >= 0) {
      return 'cloudflare';
    }
    const m = /<title[^>]*>([\s\S]*?)<\/title>/i.exec(html);
    if (m !== null && m.length > 1 && (m[1].indexOf('Just a moment') >= 0 || m[1].indexOf('请稍候') >= 0)) {
      return 'cloudflare';
    }
    // 极短页面才退回宽判据（登录表单、验证码页通常就这么多字）
    if (visibleChars < 300) {
      return AntiBot.detect(html);
    }
    return '';
  }
}
