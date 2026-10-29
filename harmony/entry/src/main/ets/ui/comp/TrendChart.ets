import { Pal } from '../Theme';
import { Fmt } from '../../util/Fmt';

/**
 * 流量趋势折线图：上行一条、下行一条，带面积渐变。
 *
 * 不引图表库 —— 需求就是两条线 + 三条网格，
 * 引 MPAndroidChart 那种体量的库反而要跟着它的坐标轴行为调半天，
 * 而 Android 端正好在 Y 轴下限、刻度裁切、窗口点数量上连踩三个坑。
 *
 * 刻度取舍：右侧只标最大值和中值。
 * 一行挤三个标签在窄屏上必然互相叠（Android 端的「12.4 MB/s」叠字就是这么来的），
 * 所以标签走 Fmt.bpsAxis 的短格式，并只留两个。
 */
@Component
export struct TrendChart {
  @Prop @Watch('redraw') down: number[];
  @Prop @Watch('redraw') up: number[];
  @Prop chartHeight: number;

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private ready: boolean = false;

  private static readonly PAD_L: number = 2;
  private static readonly PAD_R: number = 34;
  private static readonly PAD_T: number = 12;
  private static readonly PAD_B: number = 16;

  redraw(): void {
    if (this.ready) {
      this.draw();
    }
  }

  build() {
    Canvas(this.ctx)
      .width('100%')
      .height(this.chartHeight)
      .onReady(() => {
        this.ready = true;
        this.draw();
      });
  }

  private draw(): void {
    // 尺寸从 context 拿：Canvas 宽度是 '100%'，只有渲染后才算得出来
    const w: number = this.ctx.width;
    const h: number = this.chartHeight;
    this.ctx.clearRect(0, 0, w, h);

    const x0: number = TrendChart.PAD_L;
    const x1: number = w - TrendChart.PAD_R;
    const y0: number = TrendChart.PAD_T;
    const y1: number = h - TrendChart.PAD_B;
    const plotW: number = x1 - x0;
    const plotH: number = y1 - y0;

    const n: number = Math.max(this.down.length, this.up.length);
    if (n < 2 || plotW <= 0) {
      this.ctx.fillStyle = Pal.textTertiary();
      this.ctx.font = '11vp sans-serif';
      this.ctx.textAlign = 'center';
      this.ctx.fillText('正在采样…', (x0 + x1) / 2, (y0 + y1) / 2);
      return;
    }

    // 量程：取两条线的峰值，向上取整到好看的 1/2/5 档
    let peak: number = 0;
    for (let i = 0; i < n; i++) {
      if (i < this.down.length) {
        peak = Math.max(peak, this.down[i]);
      }
      if (i < this.up.length) {
        peak = Math.max(peak, this.up[i]);
      }
    }
    const top: number = TrendChart.niceCeil(peak);

    // 三条网格 + 右侧两个刻度
    this.ctx.font = '9vp sans-serif';
    this.ctx.textAlign = 'right';
    for (let g = 0; g <= 2; g++) {
      const y: number = y0 + plotH * g / 2;
      this.ctx.beginPath();
      this.ctx.moveTo(x0, y);
      this.ctx.lineTo(x1, y);
      this.ctx.lineWidth = g === 2 ? 0.8 : 0.5;
      this.ctx.strokeStyle = Pal.divider();
      this.ctx.stroke();

      if (g === 0 || g === 1) {
        this.ctx.fillStyle = Pal.textTertiary();
        const v: number = top * (1 - g / 2);
        this.ctx.fillText(Fmt.bpsAxis(v), w - 2, y + 3);
      }
    }

    // 先画面积再画线，线压在面积上才干净
    // 这张图长在深绿 hero 上：primaryDim(#007F5E) 和底色几乎同色，
    // 之前下行线等于没画出来；下行改用亮薄荷，和橙色上传线也分得开
    this.area(this.down, x0, y0, plotW, plotH, n, top, Pal.primaryBright(), 0.20);
    this.area(this.up, x0, y0, plotW, plotH, n, top, Pal.warn(), 0.12);
    this.line(this.down, x0, y0, plotW, plotH, n, top, Pal.primaryBright(), 2.0);
    this.line(this.up, x0, y0, plotW, plotH, n, top, Pal.warn(), 1.6);
  }

  private line(series: number[], x0: number, y0: number, plotW: number, plotH: number,
    n: number, top: number, color: string, width: number): void {
    if (series.length < 2) {
      return;
    }
    this.ctx.beginPath();
    for (let i = 0; i < series.length; i++) {
      const px: number = x0 + plotW * i / Math.max(1, n - 1);
      const py: number = y0 + plotH * (1 - Math.min(1, series[i] / top));
      if (i === 0) {
        this.ctx.moveTo(px, py);
      } else {
        this.ctx.lineTo(px, py);
      }
    }
    this.ctx.lineWidth = width;
    this.ctx.lineCap = 'round';
    this.ctx.lineJoin = 'round';
    this.ctx.strokeStyle = color;
    this.ctx.stroke();
  }

  private area(series: number[], x0: number, y0: number, plotW: number, plotH: number,
    n: number, top: number, color: string, opacity: number): void {
    if (series.length < 2) {
      return;
    }
    const baseY: number = y0 + plotH;
    this.ctx.beginPath();
    for (let i = 0; i < series.length; i++) {
      const px: number = x0 + plotW * i / Math.max(1, n - 1);
      const py: number = y0 + plotH * (1 - Math.min(1, series[i] / top));
      if (i === 0) {
        this.ctx.moveTo(px, py);
      } else {
        this.ctx.lineTo(px, py);
      }
    }
    const lastX: number = x0 + plotW * (series.length - 1) / Math.max(1, n - 1);
    const firstX: number = x0;
    this.ctx.lineTo(lastX, baseY);
    this.ctx.lineTo(firstX, baseY);
    this.ctx.closePath();

    const grad = this.ctx.createLinearGradient(0, y0, 0, baseY);
    grad.addColorStop(0, TrendChart.alpha(color, opacity));
    grad.addColorStop(1, TrendChart.alpha(color, 0.01));
    this.ctx.fillStyle = grad;
    this.ctx.fill();
  }

  /** 峰值向上取到 1/2/5 的整数倍，避免 Y 轴出现 3.7M 这种读不出来的刻度 */
  private static niceCeil(v: number): number {
    if (!Number.isFinite(v) || v <= 0) {
      return 128 * 1024;
    }
    // 下限 128KB：全静默时曲线贴底比拉满一片空白好看
    let x: number = Math.max(v, 128 * 1024);
    let unit: number = 1;
    while (x >= 10) {
      x = x / 10;
      unit = unit * 10;
    }
    let m: number = 1;
    if (x > 5) {
      m = 10;
    } else if (x > 2) {
      m = 5;
    } else if (x > 1) {
      m = 2;
    }
    return Math.ceil(v / (m * unit)) * m * unit;
  }

  /** '#RRGGBB' → 带 alpha 的 '#AARRGGBB' */
  private static alpha(hex: string, a: number): string {
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
