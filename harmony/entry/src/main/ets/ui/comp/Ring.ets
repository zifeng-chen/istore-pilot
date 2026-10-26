import { Pal } from '../Theme';

/**
 * 环形进度：仪表盘弧，起始 135°，扫过 270°，缺口在底部。
 *
 * Canvas 的 onReady 只跑一次，所以数值变化必须靠 @Watch 手动重绘。
 * 另外 onReady 有可能在第一次 @Watch 之后才触发，用一个 ready 标记挡住，
 * 否则会往还没初始化的 context 里画东西（表现为空白环）。
 */
@Component
export struct Ring {
  @Prop @Watch('onValueChange') ratio: number;
  @Prop label: string;
  @Prop caption: string;
  /** 主色，默认走品牌绿；温度这类告警场景由外部传 danger/warn */
  @Prop accent: string;
  @Prop diameter: number;

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private ready: boolean = false;

  private static readonly START: number = 135 * Math.PI / 180;
  private static readonly SWEEP: number = 270 * Math.PI / 180;

  onValueChange(): void {
    if (this.ready) {
      this.draw();
    }
  }

  build() {
    Column() {
      Stack() {
        Canvas(this.ctx)
          .width(this.diameter)
          .height(this.diameter)
          .onReady(() => {
            this.ready = true;
            this.draw();
          });
        Column() {
          Text(this.label)
            .fontSize(this.diameter >= 88 ? 20 : 17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textAlign(TextAlign.Center);
          Text(this.caption)
            .fontSize(10.5)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: 1 })
            .maxLines(1);
        }
        .justifyContent(FlexAlign.Center);
      }
      .width(this.diameter)
      .height(this.diameter);
    }
    .alignItems(HorizontalAlign.Center);
  }

  private draw(): void {
    const w: number = this.diameter;
    const cx: number = w / 2;
    const cy: number = w / 2;
    const lw: number = w >= 88 ? 7 : 6;
    const r: number = w / 2 - lw / 2 - 1;

    this.ctx.clearRect(0, 0, w, w);

    // 底轨
    this.ctx.beginPath();
    this.ctx.arc(cx, cy, r, Ring.START, Ring.START + Ring.SWEEP, false);
    this.ctx.lineWidth = lw;
    this.ctx.lineCap = 'round';
    this.ctx.strokeStyle = Pal.track();
    this.ctx.stroke();

    const v: number = Math.max(0, Math.min(1, this.ratio));
    if (v <= 0.001) {
      return;
    }

    // 按数值取色：正常绿，偏高橙，很高红。外部传了 accent 就用外部的
    let color: string = this.accent;
    if (color.length === 0) {
      color = v >= 0.9 ? Pal.danger() : (v >= 0.75 ? Pal.warn() : Pal.primary());
    }

    this.ctx.beginPath();
    this.ctx.arc(cx, cy, r, Ring.START, Ring.START + Ring.SWEEP * v, false);
    this.ctx.lineWidth = lw;
    this.ctx.lineCap = 'round';
    this.ctx.strokeStyle = color;
    this.ctx.stroke();
  }
}
