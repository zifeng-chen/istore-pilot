import { T, Pal } from './Theme';
import { Glyph } from './comp/Icons';

/**
 * 卡片容器。
 * 只有一层圆角 + 一条 0.7 描边 + 极淡投影 —— 投影再重一点，
 * 深色主题下卡片边缘就会糊成一圈脏边（Android 端试过 3dp，退回到 1.2）。
 */
@Component
export struct Card {
  @BuilderParam body: () => void = this.emptyBody;
  pad: number = T.CARD_PAD;
  /** 卡片外间距。ArkTS 不允许在自定义组件后面链式写 .margin()，
   *  所以间距只能当参数传进来，在根容器上生效。 */
  gapTop: number = 0;
  gapBottom: number = 0;

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
    .shadow({ radius: 6, color: '#0D000000', offsetX: 0, offsetY: 1 });
  }
}

/** 分组容器：一组只有一层圆角，行与行之间用细线分开 */
@Component
export struct GroupBox {
  @BuilderParam body: () => void = this.emptyBody;
  /** 同 Card：链式 .margin() 不合法，间距走参数 */
  gapTop: number = 0;
  gapBottom: number = 0;

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
@Component
export struct Hairline {
  indent: number = 0;

  build() {
    Row()
      .width('100%')
      .height(0.5)
      .backgroundColor($r('app.color.divider'))
      .margin({ left: this.indent });
  }
}

/** 键值行：左侧标签、右侧值。值用等宽数字，否则一列数字小数点左右跳 */
@Component
export struct Kv {
  @Prop label: string;
  @Prop value: string;
  @Prop valueSize: number;
  @Prop accent: boolean;

  build() {
    Row() {
      Text(this.label)
        .fontSize(T.F_BODY)
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

/** 小号彩色标签，比如「运行中」「已接管」 */
@Component
export struct Pill {
  @Prop text: string;
  @Prop tone: string;

  build() {
    Text(this.text)
      .fontSize(T.F_TINY)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.tone.length > 0 ? this.tone : Pal.textSecondary())
      .padding({ left: 9, right: 9, top: 4, bottom: 4 })
      .borderRadius(T.R_PILL)
      .backgroundColor(Comp.alpha(this.tone.length > 0 ? this.tone : Pal.textSecondary(), 0.19));
  }
}

/** 卡片标题 + 可选副标题 */
@Component
export struct CardHeader {
  @Prop title: string;
  @Prop sub: string;

  build() {
    Column() {
      Text(this.title)
        .fontSize(T.F_H2)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'));
      if (this.sub.length > 0) {
        Text(this.sub)
          .fontSize(T.F_SUB)
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
 * 24×24 的 Path 指令由 viewPort 缩放，所以同一套路径在 15 和 22 上
 * 观感一致 —— 页签那套 Ico 是按 22 格手算的，尺寸一变粗细就漂。
 * viewPort 往外扩 1 格：描边 2 的话边缘会逃出去半个线宽，被裁掉就变方角了。
 */
@Component
export struct GlyphIcon {
  @Prop kind: string;
  @Prop color: string;
  /** 组件边长（vp）。不能叫 size —— 那是 CustomComponent 自带的属性方法 */
  side: number = 20;
  lineWidth: number = 2;

  build() {
    Shape() {
      Path()
        .commands(Glyph.stroke(this.kind))
        .fill(Color.Transparent)
        .stroke(this.color)
        .strokeWidth(this.lineWidth)
        .strokeLineCap(LineCapStyle.Round)
        .strokeLineJoin(LineJoinStyle.Round);

      // 色盘的孔、信息图标的点必须实心，混在描边 Path 里整条路径都会被填满
      if (Glyph.fill(this.kind).length > 0) {
        Path()
          .commands(Glyph.fill(this.kind))
          .fill(this.color)
          .stroke(Color.Transparent)
          .strokeWidth(0);
      }
    }
    .viewPort({ x: -1, y: -1, width: 26, height: 26 })
    .width(this.side)
    .height(this.side);
  }
}

/**
 * 设置页用的卡片：标题自带左右留白，行由 SettingRow 自己带 padding。
 *
 * 不用 Card 是因为它的 pad 是四边同一个值 —— 这里必须「左右 0、上下有」，
 * 否则行内的细线会被再往里推 16，跟卡片边缘差出两截。
 */
@Component
export struct RowCard {
  @BuilderParam body: () => void = this.emptyBody;
  gapTop: number = 0;
  gapBottom: number = 0;

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
    .shadow({ radius: 6, color: '#0D000000', offsetX: 0, offsetY: 1 })
    .clip(true);
  }
}

/** 带图标的卡片标题：一个小图标 + 主标题 + 可选副标题 */
@Component
export struct CardTitle {
  @Prop glyph: string;
  @Prop title: string;
  @Prop sub: string;
  tone: string = '';
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
      .borderRadius(9)
      .backgroundColor($r('app.color.accent_soft'));

      Column() {
        Text(this.title)
          .fontSize(T.F_H2)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'));
        if (this.sub.length > 0) {
          Text(this.sub)
            .fontSize(T.F_TINY)
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
    .padding({ bottom: 2 });
  }
}

/**
 * 一行设置项：图标 + 标题/说明 + 右侧值 + 箭头。
 *
 * 值支持两行（BREAK_ALL）：IPv6 有 39 个字符，单行放不下，
 * 省略号截断会让用户看不到后半段，而那段恰恰是能用的部分。
 */
@Component
export struct SettingRow {
  @Prop glyph: string;
  @Prop title: string;
  @Prop subtitle: string;
  @Prop value: string;
  @Prop valueSize: number;
  /** 组内第一行不画上分割线 */
  @Prop first: boolean;
  @Prop danger: boolean;
  @Prop arrow: boolean;
  onTap: () => void = () => {
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
        .borderRadius(10)
        .backgroundColor(this.iconBg());

        Column() {
          Text(this.title)
            .fontSize(14.5)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.danger ? $r('app.color.danger') : $r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
          if (this.subtitle.length > 0) {
            Text(this.subtitle)
              .fontSize(T.F_TINY)
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
@Component
export struct Note {
  @Prop text: string;

  build() {
    Text(this.text)
      .fontSize(T.F_TINY)
      .fontColor($r('app.color.text_secondary'))
      .lineHeight(17)
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 13 });
  }
}

/** 可选中的胶囊按钮，用于「6 小时 / 12 小时 / 每天」这类互斥选项 */
@Component
export struct Chip {
  @Prop label: string;
  @Prop on: boolean;
  onTap: () => void = () => {
  };

  build() {
    Text(this.label)
      .fontSize(13)
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

  /** 从 '#AARRGGBB' 里去掉 alpha，用于不能让底色透出来的场景 */
  static opaque(hex: string): string {
    if (hex.length === 9) {
      return '#' + hex.substring(3);
    }
    return hex;
  }
}
