import { Pal, T } from '../Theme';
import { Comp } from '../Comp';

/**
 * 一个网口 = 一张小卡。
 *
 * 图标是纯布局拼出来的（外壳 + 卡扣 + 五个触点），不用 Path：
 * Path 的坐标是死数，换尺寸就得重算一遍；
 * 用 border/borderRadius 拼出来的形状会跟着宽高自动缩放，20 和 28 都好看。
 *
 * 趋势线用 Canvas：ArkTS 的声明式图形画不出一条按数组变化的折线，
 * 而 Canvas 每次 onReady 只挂一次，数据变了在 @Watch 里重画，开销最小。
 */
@Component
export struct PortTile {
  @Prop name: string;
  @Prop role: string;
  @Prop up: boolean;
  @Prop speedText: string;
  @Prop rxText: string;
  @Prop txText: string;
  @Prop totalText: string;
  @Prop @Watch('redraw') hist: number[];
  /** 平板两列时卡片更高，趋势线跟着长 */
  @Prop sparkH: number;

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private cv: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);

  private redraw(): void {
    this.drawSpark();
  }

  private tone(): string {
    return this.up ? Pal.primary() : Pal.textTertiary();
  }

  private drawSpark(): void {
    const w: number = this.cv.width;
    const h: number = this.cv.height;
    if (w <= 0 || h <= 0) {
      return;
    }
    this.cv.clearRect(0, 0, w, h);
    const pad: number = 1.5;
    const data: number[] = this.hist;

    if (data.length < 2) {
      // 刚开始采的时候画一条贴底的平线，空着会让人以为是没加载出来
      this.cv.beginPath();
      this.cv.strokeStyle = Comp.alpha(this.tone(), 0.3);
      this.cv.lineWidth = 1.4;
      this.cv.moveTo(pad, h - pad);
      this.cv.lineTo(w - pad, h - pad);
      this.cv.stroke();
      return;
    }

    let max: number = 1;
    for (let i = 0; i < data.length; i++) {
      if (data[i] > max) {
        max = data[i];
      }
    }

    const stepX: number = (w - pad * 2) / 31;
    const offset: number = 32 - data.length;
    const baseY: number = h - pad;
    let firstX: number = pad;

    this.cv.beginPath();
    for (let i = 0; i < data.length; i++) {
      const x: number = pad + (offset + i) * stepX;
      const norm: number = Math.max(0, Math.min(1, data[i] / max));
      // log 压缩：网口平时可能只有几十 K，线性画出来全贴着底边
      const shaped: number = Math.log(1 + norm * 24) / Math.log(25);
      const y: number = baseY - shaped * (h - pad * 2);
      if (i === 0) {
        firstX = x;
        this.cv.moveTo(x, y);
      } else {
        this.cv.lineTo(x, y);
      }
    }

    // 先把当前路径拓成面积填色，再描线
    this.cv.lineTo(pad + 31 * stepX, baseY);
    this.cv.lineTo(firstX, baseY);
    this.cv.closePath();
    const g: CanvasGradient = this.cv.createLinearGradient(0, 0, 0, baseY);
    g.addColorStop(0, Comp.alpha(this.tone(), this.up ? 0.30 : 0.12));
    g.addColorStop(1, Comp.alpha(this.tone(), 0));
    this.cv.fillStyle = g;
    this.cv.fill();

    this.cv.beginPath();
    for (let i = 0; i < data.length; i++) {
      const x: number = pad + (offset + i) * stepX;
      const norm: number = Math.max(0, Math.min(1, data[i] / max));
      const shaped: number = Math.log(1 + norm * 24) / Math.log(25);
      const y: number = baseY - shaped * (h - pad * 2);
      if (i === 0) {
        this.cv.moveTo(x, y);
      } else {
        this.cv.lineTo(x, y);
      }
    }
    this.cv.strokeStyle = Comp.alpha(this.tone(), this.up ? 1 : 0.55);
    this.cv.lineWidth = 1.5;
    this.cv.lineJoin = 'round';
    this.cv.lineCap = 'round';
    this.cv.stroke();
  }

  private stateText(): string {
    if (!this.up) {
      return '未连接';
    }
    if (this.role === 'wan') {
      return 'WAN · 已连接';
    }
    if (this.role === 'lan') {
      return 'LAN · 已连接';
    }
    return '已连接';
  }

  build() {
    Column() {
      // ---------------- 图标 + 速率 ----------------
      Row() {
        // 插卡图标：外壳 + 卡扣 + 五个触点
        Column() {
          // 卡扣
          Row()
            .width(10)
            .height(4)
            .borderRadius({ topLeft: 1.5, topRight: 1.5 })
            .border({
              width: { left: 1.5, right: 1.5, top: 1.5 },
              color: this.tone()
            });
          // 外壳 + 触点
          Column() {
            Row({ space: 1.6 }) {
              ForEach([0, 1, 2, 3, 4], (i: number) => {
                Row()
                  .width(1.5)
                  .height(7)
                  .borderRadius(1)
                  .backgroundColor(Comp.alpha(this.tone(), this.up ? 0.85 : 0.45));
              }, (i: number) => i.toString());
            }
            .justifyContent(FlexAlign.Center);
          }
          .width(24)
          .height(15)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .borderRadius(3)
          .border({ width: 1.5, color: this.tone() })
          .backgroundColor(Comp.alpha(this.tone(), this.up ? 0.12 : 0.05));
        }
        .alignItems(HorizontalAlign.Center)
        .width(26);

        Blank();

        // 速率徽标：左边一个链路灯
        Row({ space: 4 }) {
          Row()
            .width(5)
            .height(5)
            .borderRadius(3)
            .backgroundColor(this.up ? Pal.ok() : Pal.textTertiary());
          Text(this.up ? this.speedText : '—')
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.up ? $r('app.color.primary') : $r('app.color.text_tertiary'))
            .fontFeature("\"tnum\" on");
        }
        .padding({ left: 7, right: 8, top: 3, bottom: 3 })
        .borderRadius(T.R_PILL)
        .backgroundColor(this.up ? $r('app.color.accent_soft') : $r('app.color.surface_sunken'));
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      Text(this.name)
        .fontSize(15.5)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.up ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
        .margin({ top: 9 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis });

      Text(this.stateText())
        .fontSize(11.5)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: 3 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis });

      Canvas(this.cv)
        .width('100%')
        .height(this.sparkH)
        .margin({ top: 9 })
        .onReady(() => {
          this.drawSpark();
        });

      Row() {
        Text(this.up ? '↓ ' + this.rxText : '↓ —')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.up ? $r('app.color.primary') : $r('app.color.text_tertiary'))
          .fontFeature("\"tnum\" on")
          .layoutWeight(1);
        Text(this.up ? '↑ ' + this.txText : '↑ —')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.up ? $r('app.color.warn') : $r('app.color.text_tertiary'))
          .fontFeature("\"tnum\" on")
          .textAlign(TextAlign.End);
      }
      .width('100%')
      .margin({ top: 7 });
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 13, right: 13, top: 11, bottom: 12 })
    .borderRadius(16)
    .backgroundColor(this.up ? $r('app.color.surface_hi') : $r('app.color.surface_sunken'))
    .border({
      width: this.up && this.role === 'wan' ? 1.1 : 0.7,
      color: this.up
        ? Comp.alpha(this.role === 'wan' ? Pal.primary() : Pal.primaryDim(),
            this.role === 'wan' ? 0.55 : 0.26)
        : $r('app.color.glass_stroke')
    });
  }
}
