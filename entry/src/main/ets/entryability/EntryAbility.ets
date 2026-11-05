import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { systemShare } from '@kit.ShareKit';
import { Db } from '../data/Db';
import { Settings } from '../common/Settings';
import { UiPrefs } from '../common/UiPrefs';
import { LOG_DOMAIN, TAG } from '../common/Logger';

/** 待路由的分享链接。冷启动时 Ability 直接 pushUrl 往往早于页面栈就绪（静默失败），
 *  所以统一写进 AppStorage，由书架页 onPageShow 消费——那时栈一定就绪。 */
export const PENDING_SHARE_KEY: string = 'pendingSharedUrl';

export default class EntryAbility extends UIAbility {
  private mainWindowStage: window.WindowStage | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(LOG_DOMAIN, TAG, '%{public}s', 'Ability onCreate');
    // 分享没跳转时靠这几行定位：是没拿到链接，还是拿到了没路由
    hilog.info(LOG_DOMAIN, TAG, 'onCreate want action=%{public}s uri=%{public}s launchReason=%{public}d',
      want.action, want.uri === undefined ? '(none)' : want.uri, launchParam.launchReason);
    // 数据库在 UI 加载前完成初始化，页面侧无需再关心上下文获取时序
    Db.init(this.context).catch((err: Error) => {
      hilog.error(LOG_DOMAIN, TAG, 'init db failed: %{public}s', err.message);
    });
    // 配置存储同样需要上下文，一并在这里备好
    Settings.init(this.context);
    UiPrefs.init(this.context);
    // 冷启动即被分享：取链接是异步 IPC，loadContent 常常先跑完，
    // 所以这里只负责把结果落进 AppStorage，路由交给书架页 onPageShow。
    EntryAbility.extractSharedUrl(want).then((url: string) => {
      if (url.length > 0) {
        AppStorage.setOrCreate(PENDING_SHARE_KEY, url);
        hilog.info(LOG_DOMAIN, TAG, '冷启动收到分享链接：%{public}s', url);
      }
    }).catch(() => {
    });
  }

  onDestroy(): void {
    hilog.info(LOG_DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    this.mainWindowStage = windowStage;
    windowStage.loadContent('pages/Bookshelf', (err) => {
      if (err.code) {
        hilog.error(LOG_DOMAIN, TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(LOG_DOMAIN, TAG, 'Succeeded in loading the content.');
    });

    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(LOG_DOMAIN, TAG, 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * 应用已在后台时又被分享。这条路上页面栈是就绪的，可以直接 pushUrl；
   * 仍先写 AppStorage 兜底——pushUrl 若失败，回前台时书架页 onPageShow 会补一次。
   */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    EntryAbility.extractSharedUrl(want).then((url: string) => {
      if (url.length > 0) {
        AppStorage.setOrCreate(PENDING_SHARE_KEY, url);
        this.routeToImport(url);
      }
    }).catch(() => {
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(LOG_DOMAIN, TAG, '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(LOG_DOMAIN, TAG, '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(LOG_DOMAIN, TAG, '%{public}s', 'Ability onBackground');
  }

  /**
   * 从分享 Want 里取 URL。优先走 Share Kit 的 SharedData
   * （浏览器/其它应用分享的链接一般以 general.hyperlink 或 general.text 记录），
   * 取不到再退回 want.uri。不是分享意图时返回空串。
   */
  private static async extractSharedUrl(want: Want): Promise<string> {
    try {
      const data = await systemShare.getSharedData(want);
      const records = data.getRecords();
      for (let i = 0; i < records.length; i++) {
        const rec: systemShare.SharedRecord = records[i];
        const content: string | object | undefined = rec.content;
        if (typeof content === 'string') {
          const t = content.trim();
          if (t.startsWith('http://') || t.startsWith('https://')) {
            return t;
          }
        }
      }
    } catch (e) {
      // 不是分享 Want，静默走 uri 兜底
    }
    const uri = want.uri;
    if (uri !== undefined && uri !== null) {
      const t = uri.trim();
      if (t.startsWith('http://') || t.startsWith('https://')) {
        return t;
      }
    }
    // 最后一层兜底：不同来源的分享字段不一，parameters 里扫一遍字符串值
    const params = want.parameters;
    if (params !== undefined && params !== null) {
      const keys = Object.keys(params);
      for (let i = 0; i < keys.length; i++) {
        const v = params[keys[i]];
        if (typeof v === 'string') {
          const t = (v as string).trim();
          if (t.startsWith('http://') || t.startsWith('https://')) {
            return t;
          }
        }
      }
    }
    return '';
  }

  private routeToImport(url: string): void {
    const ws = this.mainWindowStage;
    if (ws === null) {
      return;
    }
    try {
      const main = ws.getMainWindowSync();
      main.getUIContext().getRouter().pushUrl({
        url: 'pages/SearchPage',
        params: { sharedUrl: url }
      }).then(() => {
        // 推成功了就清掉兜底，避免回前台时书架页再推一次
        AppStorage.setOrCreate(PENDING_SHARE_KEY, '');
      }).catch((err: Error) => {
        hilog.error(LOG_DOMAIN, TAG, 'route to search failed: %{public}s', err.message);
      });
    } catch (e) {
      hilog.error(LOG_DOMAIN, TAG, 'route to search threw: %{public}s', (e as Error).message);
    }
  }
}
