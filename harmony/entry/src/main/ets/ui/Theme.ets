import { common } from '@kit.AbilityKit';

/**
 * 设计系统：颜色、尺寸、字重。
 *
 * 颜色分两种用法：
 *   1. 声明式组件 —— 直接写 $r('app.color.xxx')，系统自己跟随深浅色
 *   2. 自绘 Canvas —— fillStyle 只吃字符串，必须先用 Pal 把资源色取成 '#RRGGBB'
 *
 * 为什么不把色值抄成常量：抄一份就多一处会漂移的真源。
 * Pal 走 resourceManager.getColorSync，浅色/深色两套值仍然只在 color.json 里维护。
 */
export class T {
  // 圆角
  static readonly R_CARD: number = 22;
  static readonly R_INNER: number = 14;
  static readonly R_PILL: number = 100;

  // 间距
  static readonly PAD: number = 18;      // 页面左右留白
  static readonly GAP: number = 12;      // 卡片之间
  static readonly CARD_PAD: number = 16; // 卡片内边距

  // 字号
  static readonly F_TITLE: number = 33;  // 页面大标题
  static readonly F_HERO: number = 30;   // hero 大数字
  static readonly F_H1: number = 20;
  static readonly F_H2: number = 16;
  static readonly F_BODY: number = 15;
  static readonly F_SUB: number = 12.5;
  static readonly F_TINY: number = 11.5;

  static readonly NAV_H: number = 64;    // 底部导航栏高度
}

/**
 * 自绘用的颜色取值器。
 *
 * getColorSync 会按当前资源配置返回浅色或深色的值，
 * 所以深浅色切换时不需要改这里，只需要在配置变化后调 refresh() 清缓存。
 */
export class Pal {
  private static ctx: common.Context | null = null;
  private static cache: Map<number, string> = new Map();

  static bind(ctx: common.Context): void {
    Pal.ctx = ctx;
    Pal.cache.clear();
  }

  /** 深浅色切换后必须清缓存，否则 Canvas 还画着上一套颜色 */
  static refresh(): void {
    Pal.cache.clear();
  }

  private static of(res: Resource, fallback: string): string {
    // 先取到局部变量再判空：静态字段在方法调用间可能被改，
    // 直接对 Pal.ctx 做窄化在 ArkTS 里不一定成立
    const ctx = Pal.ctx;
    if (ctx === null) {
      return fallback;
    }
    if (Pal.cache.has(res.id)) {
      return Pal.cache.get(res.id) as string;
    }
    try {
      const n: number = ctx.resourceManager.getColorSync(res.id);
      const s: string = Pal.hex(n);
      Pal.cache.set(res.id, s);
      return s;
    } catch (e) {
      return fallback;
    }
  }

  private static hex(n: number): string {
    const a: number = (n >> 24) & 0xFF;
    const r: number = (n >> 16) & 0xFF;
    const g: number = (n >> 8) & 0xFF;
    const b: number = n & 0xFF;
    const body: string = '#' + Pal.h2(r) + Pal.h2(g) + Pal.h2(b);
    if (a === 255) {
      return body;
    }
    return '#' + Pal.h2(a) + Pal.h2(r) + Pal.h2(g) + Pal.h2(b);
  }

  private static h2(v: number): string {
    const s: string = v.toString(16);
    return s.length === 1 ? '0' + s : s;
  }

  static appBg(): string {
    return Pal.of($r('app.color.app_bg'), '#EDF3F0');
  }

  static surface(): string {
    return Pal.of($r('app.color.surface'), '#FFFFFF');
  }

  static surfaceSunken(): string {
    return Pal.of($r('app.color.surface_sunken'), '#F4F9F6');
  }

  static track(): string {
    return Pal.of($r('app.color.track'), '#E1E7E4');
  }

  static divider(): string {
    return Pal.of($r('app.color.divider'), '#DFE5E2');
  }

  static primary(): string {
    return Pal.of($r('app.color.primary'), '#00A87E');
  }

  static primaryDim(): string {
    return Pal.of($r('app.color.primary_dim'), '#007F5E');
  }

  static primaryBright(): string {
    return Pal.of($r('app.color.primary_bright'), '#2ED3A6');
  }

  static textPrimary(): string {
    return Pal.of($r('app.color.text_primary'), '#000000');
  }

  static textSecondary(): string {
    return Pal.of($r('app.color.text_secondary'), '#6F7A74');
  }

  static textTertiary(): string {
    return Pal.of($r('app.color.text_tertiary'), '#C7C7CC');
  }

  static danger(): string {
    return Pal.of($r('app.color.danger'), '#FF3B30');
  }

  static warn(): string {
    return Pal.of($r('app.color.warn'), '#FF9500');
  }

  static ok(): string {
    return Pal.of($r('app.color.ok'), '#34C759');
  }

  static heroFrom(): string {
    return Pal.of($r('app.color.hero_from'), '#00805E');
  }

  static heroTo(): string {
    return Pal.of($r('app.color.hero_to'), '#00553E');
  }

  static heroFg(): string {
    return Pal.of($r('app.color.hero_fg'), '#FFFFFF');
  }

  static heroStroke(): string {
    return Pal.of($r('app.color.hero_stroke'), '#24FFFFFF');
  }

  static iconOff(): string {
    return Pal.of($r('app.color.icon_off'), '#59635F');
  }

  static accentSoft(): string {
    return Pal.of($r('app.color.accent_soft'), '#1700A87E');
  }

  static skeletonBase(): string {
    return Pal.of($r('app.color.skeleton_base'), '#D8E3DE');
  }

  static skeletonHi(): string {
    return Pal.of($r('app.color.skeleton_highlight'), '#F7FBF9');
  }

  /**
   * 给实体色加透明度，返回 '#AARRGGBB'（ArkUI 把 alpha 写在最前面）。
   * 传进来的如果是 8 位色，先砍掉原来的 alpha —— 否则会拼出 10 位，界面直接变透明
   */
  static alpha(hex: string, a: number): string {
    let body: string = hex.startsWith('#') ? hex.substring(1) : hex;
    if (body.length === 8) {
      body = body.substring(2);
    }
    const aa: number = Math.round(Math.max(0, Math.min(1, a)) * 255);
    const s: string = aa.toString(16);
    return '#' + (s.length === 1 ? '0' + s : s) + body;
  }
}
