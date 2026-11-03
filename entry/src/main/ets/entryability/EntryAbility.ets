import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { systemShare } from '@kit.ShareKit';
import { Db } from '../data/Db';
import { Settings } from '../common/Settings';
import { UiPrefs } from '../common/UiPrefs';
import { LOG_DOMAIN, TAG } from '../common/Logger';

export default class EntryAbility extends UIAbility {
  private mainWindowStage: window.WindowStage | null = null;
  /** 窗口还没就绪时收到的分享先存着，loadContent 完成后再路由 */
  private pendingSharedUrl: string = '';

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(LOG_DOMAIN, TAG, '%{public}s', 'Ability onCreate');
    // 数据库在 UI 加载前完成初始化，页面侧无需再关心上下文获取时序
    Db.init(this.context).catch((err: Error) => {
      hilog.error(LOG_DOMAIN, TAG, 'init db failed: %{public}s', err.message);
    });
    // 配置存储同样需要上下文，一并在这里备好
    Settings.init(this.context);
    UiPrefs.init(this.context);
    // 冷启动即被分享（浏览器里点分享选本应用）：先取链接，窗口就绪后跳导入页
    EntryAbility.extractSharedUrl(want).then((url: string) => {
      this.pendingSharedUrl = url;
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
      if (this.pendingSharedUrl.length > 0) {
        const url = this.pendingSharedUrl;
        this.pendingSharedUrl = '';
        this.routeToImport(url);
      }
    });

    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(LOG_DOMAIN, TAG, 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
  }

  /** 应用已在后台时又被分享：直接补路由 */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    EntryAbility.extractSharedUrl(want).then((url: string) => {
      if (url.length > 0) {
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
    return '';
  }

  private routeToImport(url: string): void {
    const ws = this.mainWindowStage;
    if (ws === null) {
      this.pendingSharedUrl = url;
      return;
    }
    try {
      const main = ws.getMainWindowSync();
      main.getUIContext().getRouter().pushUrl({
        url: 'pages/SearchPage',
        params: { sharedUrl: url }
      }).catch((err: Error) => {
        hilog.error(LOG_DOMAIN, TAG, 'route to search failed: %{public}s', err.message);
      });
    } catch (e) {
      // 窗口还没完全就绪，存下来等 loadContent 回调补路由
      this.pendingSharedUrl = url;
    }
  }
}
