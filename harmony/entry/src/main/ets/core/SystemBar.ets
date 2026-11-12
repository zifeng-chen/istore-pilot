import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'SystemBar';

/** 页面底色（与 app_bg 的 color.json 保持一致），给导航条当底色用 */
const BG_LIGHT: string = '#F2F6F4';
const BG_DARK: string = '#0A100E';

/**
 * 系统栏（状态栏 / 导航条）适配。
 *
 * 窗口是 `setWindowLayoutFullScreen(true)` 的沉浸式：状态栏透明、内容延伸到它下面，
 * 留白由各页面自己用 `UI.safeTop` 让出来。这种模式下**必须显式指定图标颜色**，
 * 否则图标会跟着系统默认值走 —— 冷启动时启动页是深绿底、我们把它改成了白色图标，
 * 可未登录会直接跳转到浅色背景的登录页，白色图标压在浅底上就看不见了。
 * 上架检测报的「状态栏适配显示问题」就是这一处。
 *
 * 另一个容易漏的是导航条：不给底色的话，底部会多出一条和 app_bg 不同色的系统带。
 */
export class SystemBar {
  /** 当前是不是深色（问系统要实际色彩模式，不能只看用户选的「跟随系统」） */
  static isDark(ctx: common.Context): boolean {
    try {
      // common.Context 上没有 config，只有 UIAbilityContext 有
      const uiCtx = ctx as common.UIAbilityContext;
      return uiCtx.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } catch (e) {
      return false;
    }
  }

  /**
   * 按指定明暗刷新。页面底色是浅色就给深色图标，反之给白色图标。
   * 失败不影响功能（只是图标对比度不理想），所以整段吞掉异常。
   */
  static syncWin(win: window.Window, dark: boolean): void {
    try {
      win.setWindowSystemBarProperties({
        statusBarContentColor: dark ? '#FFFFFF' : '#000000',
        navigationBarContentColor: dark ? '#FFFFFF' : '#000000',
        statusBarColor: '#00000000',
        navigationBarColor: dark ? BG_DARK : BG_LIGHT
      }).catch((e: Error) => {
        hilog.warn(DOMAIN, TAG, 'setWindowSystemBarProperties failed: %{public}s', e.message);
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'syncWin threw');
    }
  }

  /** 拿窗口再刷新一次，给页面侧用 */
  static sync(ctx: common.Context, dark?: boolean): void {
    const isDark: boolean = dark === undefined ? SystemBar.isDark(ctx) : dark;
    window.getLastWindow(ctx).then((win: window.Window) => {
      SystemBar.syncWin(win, isDark);
    }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'getLastWindow failed: %{public}s', e.message);
    });
  }
}
