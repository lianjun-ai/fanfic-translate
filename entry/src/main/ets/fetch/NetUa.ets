/**
 * 统一的浏览器标识（User-Agent）。
 *
 * 为什么不用真实设备标识：`Mozilla/5.0 (Linux; HarmonyOS) ...` 和 ArkWeb 默认
 * UA（带 ArkWeb 字样）会被知乎、小红书、微博这类风控站直接判定为爬虫，
 * 连内置渲染都返回 403 —— 真机实测知乎专栏三条路（直抓 / 带 Referer 探接口 /
 * 内置渲染）全部 403。伪装成常规 Android Chrome 移动端后这类站才肯发页面。
 *
 * 用途：HttpFetch 的直抓与 http_probe、WebPage 的 fetch_page、以及内置渲染
 * 的 Web 组件（setCustomUserAgent）统一走这一个值，避免各处不一致。
 */
export const MOBILE_UA: string =
  'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';
