import { common2D, drawing } from '@kit.ArkGraphics2D';
import { T, Pal } from './Theme';
import { Glyph } from './comp/Icons';
import { IconRes } from './comp/IconData';

/**
 * 卡片容器。
 * 只有一层圆角 + 一条 0.7 描边 + 极淡投影 —— 投影再重一点，
 * 深色主题下卡片边缘就会糊成一圈脏边（Android 端试过 3dp，退回到 1.2）。
 */
@ComponentV2
export struct Card {
  @BuilderParam body: () => void = this.emptyBody;
  @Param pad: number = T.CARD_PAD;
  /** 卡片外间距。ArkTS 不允许在自定义组件后面链式写 .margin()，
   *  所以间距只能当参数传进来，在根容器上生效。 */
  @Param gapTop: number = 0;
  @Param gapBottom: number = 0;

  @Builder
  emptyBody() {
  }

  build() {
    Column() {
      this.body();
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(this.pad)
    .margin({ top: this.gapTop, bottom: this.gapBottom })
    .backgroundColor($r('app.color.surface'))
    .borderRadius(T.R_CARD)
    .border({ width: 0.7, color: $r('app.color.glass_stroke') })
    .shadow({ radius: 12, color: $r('app.color.shadow_2'), offsetX: 0, offsetY: 3 });
  }
}

/** 分组容器：一组只有一层圆角，行与行之间用细线分开 */
@ComponentV2
export struct GroupBox {
  @BuilderParam body: () => void = this.emptyBody;
  /** 同 Card：链式 .margin() 不合法，间距走参数 */
  @Param gapTop: number = 0;
  @Param gapBottom: number = 0;

  @Builder
  emptyBody() {
  }

  build() {
    Column() {
      this.body();
    }
    .width('100%')
    .margin({ top: this.gapTop, bottom: this.gapBottom })
    .backgroundColor($r('app.color.surface'))
    .borderRadius(T.R_CARD)
    .border({ width: 0.7, color: $r('app.color.glass_stroke') })
    .clip(true);
  }
}

/** 细分隔线。indent 用来让线从文字左边开始，不顶到卡片边缘 */
@ComponentV2
export struct Hairline {
  @Param indent: number = 0;

  build() {
    Row()
      .width('100%')
      .height(0.5)
      .backgroundColor($r('app.color.divider'))
      .margin({ left: this.indent });
  }
}

/** 键值行：左侧标签、右侧值。值用等宽数字，否则一列数字小数点左右跳 */
@ComponentV2
export struct Kv {
  @Param label: string = '';
  @Param value: string = '';
  @Param valueSize: number = 0;
  @Param accent: boolean = false;

  build() {
    Row() {
      Text(this.label)
        .fontSize(T.fs(T.F_BODY))
        .fontColor($r('app.color.text_secondary'))
        .flexShrink(0);
      Blank();
      Text(this.value)
        .fontSize(this.valueSize > 0 ? this.valueSize : T.F_BODY)
        .fontColor(this.accent ? $r('app.color.primary') : $r('app.color.text_primary'))
        .fontFeature("\"tnum\" on")
        .textAlign(TextAlign.End)
        .layoutWeight(1)
        .margin({ left: 12 });
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 9, bottom: 9 });
  }
}

/**
 * 图标上色。
 *
 * media 里的 SVG 是纯黑的（#000000），颜色在运行时用 SRC_IN 叠上去：
 * 保留图形的 alpha、把 RGB 换成目标色，描边和实心点一起上色，
 * 同一个图标就不用为每种颜色各存一份文件。
 *
 * 色值只有十来个，按色值缓存 —— 一屏几十个图标，没必要每次 build
 * 都新建一个 native 滤镜对象。
 */
export class Tint {
  private static cache: Map<string, drawing.ColorFilter> = new Map();

  static of(hex: string): drawing.ColorFilter {
    const hit: drawing.ColorFilter | undefined = Tint.cache.get(hex);
    if (hit !== undefined) {
      return hit;
    }
    const c: common2D.Color = Tint.rgba(hex);
    const f: drawing.ColorFilter =
      drawing.ColorFilter.createBlendModeColorFilter(c, drawing.BlendMode.SRC_IN);
    Tint.cache.set(hex, f);
    return f;
  }

  /** '#RRGGBB' / '#AARRGGBB' → common2D.Color（每一位都是 0-255） */
  private static rgba(hex: string): common2D.Color {
    let body: string = hex.startsWith('#') ? hex.substring(1) : hex;
    if (body.length === 6) {
      body = 'FF' + body;
    } else if (body.length !== 8) {
      body = 'FF000000';
    }
    const v: number = Number.parseInt(body, 16);
    if (Number.isNaN(v)) {
      return { alpha: 255, red: 0, green: 0, blue: 0 };
    }
    return {
      alpha: (v >>> 24) & 0xFF,
      red: (v >>> 16) & 0xFF,
      green: (v >>> 8) & 0xFF,
      blue: v & 0xFF
    };
  }
}

/**
 * 深绿 hero 卡里的一格：小标签在上、数值在下（和安卓 heroStat 同规格 11 / 20）。
 *
 * 为什么是 @ComponentV2 而不是 @Builder：
 * ArkUI 的 @Builder 默认按值传参，**状态变量变化不会刷新 builder 内的 UI**；
 * 传两个以上参数时连"按引用传递"也不生效。这里原来就是 @Builder，结果
 * 数据到了界面不动 —— 三格永远是初始值「—」。换成 @Prop 后父组件状态一变，
 * 子组件就会跟着重绘。
 */
@ComponentV2
export struct HeroStat {
  @Param label: string = '';
  @Param value: string = '';
  /** 三列并排时 21fp 放不下，调用方可以降一档 */
  @Param valueSize: number = T.F_H1;
  build() {
    Column() {
      Text(this.label)
        .fontSize(T.fs(T.F_TINY))
        .fontColor($r('app.color.hero_fg_soft'))
        .maxLines(1);
      Text(this.value)
        .fontSize(this.valueSize)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.hero_fg'))
        .fontFeature("\"tnum\" on")
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 5 });
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .layoutWeight(1);
  }
}

/** 小号彩色标签，比如「运行中」「已接管」 */
@ComponentV2
export struct Pill {
  @Param text: string = '';
  @Param tone: string = '';

  build() {
    Text(this.text)
      .fontSize(T.fs(T.F_TINY))
      .fontWeight(FontWeight.Medium)
      .fontColor(this.tone.length > 0 ? this.tone : Pal.textSecondary())
      .padding({ left: 9, right: 9, top: 4, bottom: 4 })
      .borderRadius(T.R_PILL)
      .backgroundColor(Comp.alpha(this.tone.length > 0 ? this.tone : Pal.textSecondary(), 0.19));
  }
}

/** 卡片标题 + 可选副标题 */
@ComponentV2
export struct CardHeader {
  @Param title: string = '';
  @Param sub: string = '';

  build() {
    Column() {
      Text(this.title)
        .fontSize(T.fs(T.F_H2))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'));
      if (this.sub.length > 0) {
        Text(this.sub)
          .fontSize(T.fs(T.F_SUB))
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 3 });
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .margin({ bottom: 4 });
  }
}

/**
 * 线性图标。
 *
 * 图形来自 design/icons，由 scripts/gen_icons.py 落成 media 里的 SVG
 * （26 视口、描边 2），这里只负责尺寸、颜色和朝向。
 *
 * 为什么不再用 Canvas 自绘：应用市场审核按控件类型量两件事 ——
 * Canvas 会被当成「没有背景色的文本」量对比度（实测 1.03），
 * 也会被量边缘锯齿（31px 的小箭头 94.67，阈值 90）。换成 Image 渲染矢量
 * 资源后，控件类型变了、光栅化交给系统，两个指标都不再成立；
 * 顺带也不用再等 onReady 才能画第一次。
 */
@ComponentV2
export struct GlyphIcon {
  @Param kind: string = '';
  @Param color: string = '';
  /** 组件边长（vp）。不能叫 size —— 那是 CustomComponent 自带的属性方法 */
  @Param side: number = 20;
  /** 历史参数：描边已经烘进 SVG，这里不再使用，保留只为不动几百处调用点 */
  @Param lineWidth: number = 2;
  /** 旋转角度（返回箭头用 180 把「向右」变成「向左」） */
  @Param spin: number = 0;

  build() {
    Image(IconRes.of(this.kind))
      .width(this.side)
      .height(this.side)
      .objectFit(ImageFit.Contain)
      .colorFilter(Tint.of(this.color))
      .rotate({ angle: this.spin })
      .draggable(false);
  }
}

/**
 * 设置页用的卡片：标题自带左右留白，行由 SettingRow 自己带 padding。
 *
 * 不用 Card 是因为它的 pad 是四边同一个值 —— 这里必须「左右 0、上下有」，
 * 否则行内的细线会被再往里推 16，跟卡片边缘差出两截。
 */
@ComponentV2
export struct RowCard {
  @BuilderParam body: () => void = this.emptyBody;
  @Param gapTop: number = 0;
  @Param gapBottom: number = 0;

  @Builder
  emptyBody() {
  }

  build() {
    Column() {
      this.body();
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 15, bottom: 5 })
    .margin({ top: this.gapTop, bottom: this.gapBottom })
    .backgroundColor($r('app.color.surface'))
    .borderRadius(T.R_CARD)
    .border({ width: 0.7, color: $r('app.color.glass_stroke') })
    .shadow({ radius: 6, color: $r('app.color.shadow_1'), offsetX: 0, offsetY: 1 })
    .clip(true);
  }
}

/** 带图标的卡片标题：一个小图标 + 主标题 + 可选副标题 */
@ComponentV2
export struct CardTitle {
  @Param glyph: string = '';
  @Param title: string = '';
  @Param sub: string = '';
  @Param tone: string = '';
  /** 左右留白。RowCard 只给上下，放进 RowCard 时必须传 16，
   *  否则图标直接贴到卡片边框上；Card 自身已有 16 内边距，保持默认 0 */
  @Param pad: number = 0;
  /** 右侧插槽：在线数、状态胶囊之类 */
  @BuilderParam trailing: () => void = this.emptyTrailing;

  @Builder
  emptyTrailing() {
  }

  build() {
    Row() {
      // 28 的淡色圆角块 + 16 的图标：和安卓 Ui.glyphTile 同规格。
      // 原来这里只有一枚裸图标，安卓那边是彩色方块 —— 同一个 App 两个长相
      Stack({ alignContent: Alignment.Center }) {
        GlyphIcon({
          kind: this.glyph,
          color: this.tone.length > 0 ? this.tone : Pal.primary(),
          side: 16,
          lineWidth: 1.9
        });
      }
      .width(28)
      .height(28)
      .borderRadius(T.R_XS)
      .backgroundColor($r('app.color.accent_soft'));

      Column() {
        Text(this.title)
          .fontSize(T.fs(T.F_H2))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'));
        if (this.sub.length > 0) {
          Text(this.sub)
            .fontSize(T.fs(T.F_TINY))
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: 2 });
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 10 });

      this.trailing();
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: this.pad, right: this.pad, bottom: 2 });
  }
}

/**
 * 一行设置项：图标 + 标题/说明 + 右侧值 + 箭头。
 *
 * 值支持两行（BREAK_ALL）：IPv6 有 39 个字符，单行放不下，
 * 省略号截断会让用户看不到后半段，而那段恰恰是能用的部分。
 */
@ComponentV2
export struct SettingRow {
  @Param glyph: string = '';
  @Param title: string = '';
  @Param subtitle: string = '';
  @Param value: string = '';
  @Param valueSize: number = 0;
  /** 组内第一行不画上分割线 */
  @Param first: boolean = false;
  @Param danger: boolean = false;
  @Param arrow: boolean = false;
  @Event onTap: () => void = () => {
  };

  private tone(): string {
    return this.danger ? Pal.danger() : Pal.primary();
  }

  private iconBg(): ResourceColor {
    return this.danger ? Comp.alpha(Pal.danger(), 0.12) : $r('app.color.accent_soft');
  }

  build() {
    Column() {
      if (!this.first) {
        Hairline({ indent: 16 });
      }
      Row() {
        Stack() {
          GlyphIcon({
            kind: this.glyph,
            color: this.tone(),
            side: 17,
            lineWidth: 1.9
          });
        }
        .width(30)
        .height(30)
        .borderRadius(T.R_XS)
        .backgroundColor(this.iconBg());

        Column() {
          Text(this.title)
            .fontSize(T.fs(T.F_BODY))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.danger ? $r('app.color.danger') : $r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
          if (this.subtitle.length > 0) {
            Text(this.subtitle)
              .fontSize(T.fs(T.F_TINY))
              .fontColor($r('app.color.text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 2 });
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 11 });

        if (this.value.length > 0) {
          Text(this.value)
            .fontSize(this.valueSize > 0 ? this.valueSize : 13)
            .fontColor($r('app.color.text_secondary'))
            .fontFeature("\"tnum\" on")
            .textAlign(TextAlign.End)
            .maxLines(2)
            .wordBreak(WordBreak.BREAK_ALL)
            .constraintSize({ maxWidth: '50%' })
            .margin({ left: 8 });
        }

        if (this.arrow) {
          GlyphIcon({
            kind: Glyph.CHEVRON,
            color: Pal.textTertiary(),
            side: 13,
            lineWidth: 2.1
          });
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 10 })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.onTap();
      });
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }
}

/** 卡片底部的说明文字 */
@ComponentV2
export struct Note {
  @Param text: string = '';

  build() {
    Text(this.text)
      .fontSize(T.fs(T.F_TINY))
      .fontColor($r('app.color.text_secondary'))
      .lineHeight(17)
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 13 });
  }
}

/** 可选中的胶囊按钮，用于「6 小时 / 12 小时 / 每天」这类互斥选项 */
@ComponentV2
export struct Chip {
  @Param label: string = '';
  @Param on: boolean = false;
  @Event onTap: () => void = () => {
  };

  build() {
    Text(this.label)
      .fontSize(T.fs(T.F_SUB))
      .fontWeight(FontWeight.Medium)
      .fontColor(this.on ? $r('app.color.primary') : $r('app.color.text_secondary'))
      .textAlign(TextAlign.Center)
      .width('100%')
      .padding({ top: 9, bottom: 9 })
      .borderRadius(T.R_PILL)
      .backgroundColor(this.on ? $r('app.color.accent_soft2') : $r('app.color.surface_hi'))
      .border({
        width: this.on ? 0.9 : 0,
        color: Comp.alpha(Pal.primary(), 0.55)
      })
      .onClick(() => {
        this.onTap();
      });
  }
}

/** 极小的颜色工具，只给需要 alpha 的地方用 */
export class Comp {
  /** '#RRGGBB' → 带 alpha 的 '#AARRGGBB' */
  static alpha(hex: string, a: number): string {
    let rgb: string = hex;
    if (hex.length === 7) {
      rgb = hex.substring(1);
    } else if (hex.length === 9) {
      rgb = hex.substring(3);
    }
    const v: number = Math.round(Math.max(0, Math.min(1, a)) * 255);
    const s: string = v.toString(16);
    return '#' + (s.length === 1 ? '0' + s : s) + rgb;
  }
}
