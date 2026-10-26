/**
 * 断点系统：手机 / 小平板 / 大平板三档。
 *
 * 为什么不用系统自带的 GridRow + breakpoints：
 * 那套东西是按「栅格宽度」算的，页面里大量卡片是自定义高度、
 * 并不遵循 12 栏栅格；而且 ArkTS 的断点回调里改状态会触发整页重建，
 * 折叠屏开合时会看到明显闪烁。这里改成把窗口宽度写进 AppStorage，
 * 各页面自己按宽度算列数 —— 只有真正需要变的组件会重建。
 *
 * 三档的由来（vp）：
 *   compact  < 600   手机竖屏
 *   medium   600–840 手机横屏、小折叠展开、7 寸平板
 *   expanded ≥ 840   8 寸以上平板、折叠屏完全展开
 * 840 是 HarmonyOS 官方给「是否显示侧边栏」的经验值，和侧栏 208 的宽度也配套。
 */
export enum Form {
  Compact,
  Medium,
  Expanded
}

export class Bp {
  static readonly MD: number = 600;
  static readonly LG: number = 840;

  /** 侧边导航栏宽度。太窄放不下「概览」两个字 + 图标，太宽会把内容区挤得太瘦 */
  static readonly RAIL_W: number = 208;

  /** 内容区最大宽度：Pad 横屏铺满 1400vp 时，一行文字拉得太长反而难读 */
  static readonly CONTENT_MAX: number = 1100;

  static form(w: number): Form {
    if (w >= Bp.LG) {
      return Form.Expanded;
    }
    if (w >= Bp.MD) {
      return Form.Medium;
    }
    return Form.Compact;
  }

  /** 平板布局：显示侧边导航，不再有底部页签 */
  static rail(w: number): boolean {
    return w >= Bp.LG;
  }

  /** 页面左右留白。平板上一律加宽，否则内容贴着边框很难看 */
  static pad(w: number): number {
    const f: Form = Bp.form(w);
    if (f === Form.Expanded) {
      return 28;
    }
    if (f === Form.Medium) {
      return 22;
    }
    return 18;
  }

  static gap(w: number): number {
    return Bp.rail(w) ? 16 : 12;
  }

  /**
   * 按「一张卡至少多宽」算列数。
   * 上限 3 列 —— 再多每列都放不下 IPv6 或设备名，全都会折行。
   */
  static cols(w: number, minCard: number): number {
    const usable: number = Bp.contentWidth(w) - Bp.pad(w) * 2;
    const n: number = Math.floor((usable + Bp.gap(w)) / (minCard + Bp.gap(w)));
    return Math.max(1, Math.min(3, n));
  }

  /** 内容区实际可用宽度：扣掉侧栏，再按最大宽度收口 */
  static contentWidth(w: number): number {
    const raw: number = Bp.rail(w) ? w - Bp.RAIL_W : w;
    return Math.min(raw, Bp.CONTENT_MAX);
  }

  /** 图表高度：平板上按比例放大，手机上保持紧凑 */
  static chartH(w: number, compactH: number): number {
    const f: Form = Bp.form(w);
    if (f === Form.Expanded) {
      return compactH + 40;
    }
    if (f === Form.Medium) {
      return compactH + 18;
    }
    return compactH;
  }

  /** 环图直径 */
  static ring(w: number, compactD: number): number {
    const f: Form = Bp.form(w);
    if (f === Form.Expanded) {
      return compactD + 24;
    }
    if (f === Form.Medium) {
      return compactD + 10;
    }
    return compactD;
  }
}
