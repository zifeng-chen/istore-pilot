import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { display, window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Api } from '../api/Api';
import { UI } from '../core/UIState';
import { Motion } from '../core/Motion';
import { SystemBar } from '../core/SystemBar';
import { Pal } from '../ui/Theme';

const DOMAIN: number = 0x0001;
const TAG: string = 'IStoreAbility';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    Motion.sync(this.context);
    hilog.info(DOMAIN, TAG, 'onCreate');

    // 令牌失效统一走这里：置一个时间戳，Index 页监听后跳登录页。
    // 不在每个页面各自判断 401 —— 那会漏，而且会把跳转逻辑散在各处。
    Api.setAuthFailHandler(() => {
      UI.forceLogin = Date.now();
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
      // 在这里就把状态栏高度量出来写进 UI.safeTop：
      // 冷启动直接落在登录页时，Index 还没跑过 boot()，UI.safeTop 是 0 ——
      // 从登录页推开的帮助页、以及重新登录后的二级页都会顶到状态栏底下。
      // Index 里的 measureSafeArea() 保留，窗口尺寸变化时它会再校准一次。
      const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      // 不用 px2vp：它是 ArkUI 页面上下文里的全局函数，在 ability 里不保证可用
      // （一失败就退化成 0，登录页会顶到状态栏底下）。直接拿屏幕密度自己换算
      const density: number = display.getDefaultDisplaySync().densityPixels;
      if (density > 0) {
        UI.safeTop = sys.topRect.height / density;
        // 横屏时状态栏跑到侧边、挖孔也在侧边，只让顶部是不够的
        UI.safeLeft = sys.leftRect.width / density;
        UI.safeRight = sys.rightRect.width / density;
      }
      // 首帧是深绿启动页，先按深色给白色图标；登录页 / 主页各自还会再校正一次。
      // 不在这里设的话，第一帧会带着系统默认图标色，深底上直接看不见
      SystemBar.syncWin(win, true);
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
    // 系统切深浅色：沉浸式下图标颜色不会自动跟着变，必须手动再刷一次，
    // 否则浅色背景下还是白图标（上架检测里的状态栏问题之一）
    SystemBar.sync(this.context,
      newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
  }
}
