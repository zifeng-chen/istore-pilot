import { common } from '@kit.AbilityKit';
import { settings } from '@kit.BasicServicesKit';

/**
 * 动效开关。
 *
 * 系统「设置 → 辅助功能 → 减弱动效」在 OpenHarmony 上没有公开的读取 API，
 * 但动画时长倍率是系统设置项 `animator_duration_scale`：
 * 关掉动画后它是 "0"。读不到（权限/键不存在）就按正常动效处理，
 * 不能因为读设置失败把整套转场变成不动。
 */
export class Motion {
  private static reduced: boolean = false;
  private static asked: boolean = false;

  static sync(ctx: common.Context): void {
    if (Motion.asked) {
      return;
    }
    Motion.asked = true;
    try {
      const v: string = settings.getValueSync(ctx, 'animator_duration_scale', '1');
      Motion.reduced = v === '0' || v === '0.0';
    } catch (e) {
      Motion.reduced = false;
    }
  }

  /** 给 animateTo 用：减弱动效时返回 0 */
  static ms(value: number): number {
    return Motion.reduced ? 0 : value;
  }
}
