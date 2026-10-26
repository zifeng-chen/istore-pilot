import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { Pal } from './Theme';

const PREF_NAME: string = 'istore_ui';
const KEY_THEME: string = 'theme';

/**
 * 外观：跟随系统 / 浅色 / 深色。
 *
 * 鸿蒙没有「App 内换肤」的公开 API，能做的是给整个 UIAbility 指定
 * colorMode —— 效果和用户去系统设置里切换完全一样，所有 $r('app.color.*')
 * 会一起重算，这也是为什么颜色必须写在 color.json 而不是抄成常量。
 *
 * 自绘的 Canvas 拿不到资源配置，走的是 Pal 的字符串缓存，
 * 所以这里切完要顺手把缓存清掉，否则图表还画着上一套颜色。
 */
export class Appearance {
  static readonly NAMES: string[] = ['跟随系统', '浅色', '深色'];
  private static mode: number = 0;
  private static pref: preferences.Preferences | null = null;

  static current(): number {
    return Appearance.mode;
  }

  static label(): string {
    return Appearance.NAMES[Appearance.mode];
  }

  /** 启动时调一次：读出上次的选择并立刻应用 */
  static async init(ctx: common.Context): Promise<void> {
    try {
      const p = await Appearance.ready(ctx);
      const v = await p.get(KEY_THEME, 0);
      Appearance.mode = typeof v === 'number' ? v : 0;
    } catch (e) {
      Appearance.mode = 0;
    }
    Appearance.apply(ctx);
  }

  static async select(ctx: common.Context, mode: number): Promise<void> {
    Appearance.mode = mode;
    Appearance.apply(ctx);
    try {
      const p = await Appearance.ready(ctx);
      await p.put(KEY_THEME, mode);
      await p.flush();
    } catch (e) {
      // 落盘失败不影响本次生效，下次启动会退回「跟随系统」
    }
  }

  private static apply(ctx: common.Context): void {
    try {
      const app = ctx.getApplicationContext();
      if (Appearance.mode === 1) {
        app.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
      } else if (Appearance.mode === 2) {
        app.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
      } else {
        app.setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
      }
    } catch (e) {
      // 老设备上 setColorMode 可能不可用，保持系统色即可
    }
    // colorMode 变化是异步广播的，先把自绘颜色缓存清掉，避免出现半新半旧
    Pal.refresh();
  }

  private static async ready(ctx: common.Context): Promise<preferences.Preferences> {
    if (Appearance.pref === null) {
      Appearance.pref = await preferences.getPreferences(ctx, PREF_NAME);
    }
    return Appearance.pref;
  }
}
