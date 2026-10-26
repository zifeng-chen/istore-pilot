import { AbilityConstant, Configuration, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Api } from '../api/Api';
import { Pal } from '../ui/Theme';

const DOMAIN: number = 0x0001;
const TAG: string = 'IStoreAbility';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'onCreate');

    // 令牌失效统一走这里：置一个时间戳，Index 页监听后跳登录页。
    // 不在每个页面各自判断 401 —— 那会漏，而且会把跳转逻辑散在各处。
    Api.setAuthFailHandler(() => {
      AppStorage.setOrCreate('forceLogin', Date.now());
    });
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // 内容延伸到状态栏和导航条下面，留白由页面自己的 SafeArea 处理 ——
    // 不然顶部会多出一条跟 app_bg 不完全同色的系统底色
    try {
      const win = windowStage.getMainWindowSync();
      win.setWindowLayoutFullScreen(true);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'setWindowLayoutFullScreen failed');
    }

    windowStage.loadContent('pages/Index', (err) => {
      if (err !== null && err !== undefined && err.code !== 0) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'content loaded');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onWindowStageDestroy');
  }

  onForeground(): void {
  }

  onBackground(): void {
  }

  /**
   * 深浅色切换。
   * Canvas 自绘的颜色是用 getColorSync 取出来缓存的字符串，
   * 配置一变必须清缓存，否则图表和环形还是上一套配色。
   */
  onConfigurationUpdate(newConfig: Configuration): void {
    hilog.info(DOMAIN, TAG, 'configuration updated');
    Pal.refresh();
  }
}
