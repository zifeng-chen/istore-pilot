import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { Api, ApiResult } from '../../api/Api';
import { J } from '../../core/Json';
import { Fmt } from '../../util/Fmt';
import { Bp } from '../Breakpoint';
import { Pal, T } from '../Theme';
import { Card, CardHeader, CardTitle, GlyphIcon, Hairline, Kv, Pill } from '../Comp';
import { Glyph } from '../comp/Icons';
import { TrendChart } from '../comp/TrendChart';
import { PortTile } from '../comp/PortTile';

interface PortVM {
  name: string;
  role: string;
  up: boolean;
  speedMbps: number;
  speedText: string;
  rx: number;
  tx: number;
  rxText: string;
  txText: string;
  rxTotal: number;
  txTotal: number;
  mac: string;
  hist: number[];
}

/**
 * 概览页。手机单列、平板双列。
 *
 * 双列不是「把手机版拉宽」，而是重新分组：
 *   左列放「现在怎么样」—— 结论卡 + 实时流量曲线
 *   右列放「里面装了什么」—— 负载三环 + 网口 + 机器
 * 这样平板横屏时第一屏能同时看到曲线和三环，不用上下滚。
 *
 * 所有卡片都抽成 @Builder，两种布局共用同一份实现 ——
 * 否则改一个数字要改两处，迟早两边长得不一样。
 */
@Component
export struct OverviewPage {
  @State hostname: string = '';
  @State model: string = '';
  @State kernel: string = '';
  @State osVersion: string = '';
  @State uptime: string = '';
  @State cpuPct: number = 0;
  @State memPct: number = 0;
  @State diskPct: number = 0;
  @State cpuText: string = '—';
  @State memText: string = '—';
  @State diskText: string = '—';
  @State temp: string = '';
  @State tempWarm: boolean = false;
  @State load1: string = '—';
  @State threads: string = '—';
  @State rxNow: string = '—';
  @State txNow: string = '—';
  @State rxTotal: string = '—';
  /** 峰值：图表右上角那个数，和安卓一样按窗口内最大速率算 */
  @State peakText: string = '—';
  @State txTotal: string = '—';
  @State wanUp: boolean = false;
  @State wanProto: string = '';
  @State onlineCount: number = 0;
  @State wanIp: string = '—';
  @State wanGw: string = '—';
  @State wanDns: string = '—';
  @State wanUpSec: number = 0;
  @State memDetail: string = '';
  @State diskDetail: string = '';
  @State ports: PortVM[] = [];
  @State downHist: number[] = [];
  @State upHist: number[] = [];
  @State loaded: boolean = false;
  @State verdict: string = '';
  @State winW: number = 360;

  @StorageProp('tab') @Watch('onTab') tab: number = 0;
  @StorageProp('winW') @Watch('onWidth') winWStore: number = 360;

  private timer: number = -1;
  private liveTimer: number = -1;
  /** 运行时长的走秒器：5 秒轮询只校准基准，中间靠它一秒一跳 */
  private upTimer: number = -1;
  private upBase: number = 0;
  private upAt: number = 0;

  aboutToAppear(): void {
    this.winW = this.winWStore;
    this.refreshAll(true);
    if (this.tab === 0) {
      this.startPoll();
    }
  }

  aboutToDisappear(): void {
    this.stopPoll();
  }

  private onWidth(): void {
    this.winW = this.winWStore;
  }

  private onTab(): void {
    if (this.tab === 0) {
      this.startPoll();
      this.refreshAll(false);
    } else {
      this.stopPoll();
    }
  }

  private startPoll(): void {
    this.stopPoll();
    // 概览 5 秒、流量 3 秒：流量要够密曲线才有意义，系统指标没必要那么勤
    this.timer = setInterval(() => {
      this.refreshAll(false);
    }, 5000);
    this.liveTimer = setInterval(() => {
      this.refreshTraffic(true);
    }, 3000);
    this.upTimer = setInterval(() => {
      this.tickUptime();
    }, 1000);
  }

  /** 运行时长按秒跳，轮询来的基准值 5 秒才更新一次 */
  private tickUptime(): void {
    if (this.upBase <= 0) {
      return;
    }
    this.uptime = Fmt.uptime(this.upBase + Math.floor((Date.now() - this.upAt) / 1000));
  }

  private stopPoll(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    if (this.liveTimer >= 0) {
      clearInterval(this.liveTimer);
      this.liveTimer = -1;
    }
    if (this.upTimer >= 0) {
      clearInterval(this.upTimer);
      this.upTimer = -1;
    }
  }

  private ctx(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private rail(): boolean {
    return Bp.rail(this.winW);
  }

  private async refreshAll(withCache: boolean): Promise<void> {
    const ctx = this.ctx();
    if (withCache) {
      const c: ApiResult = await Api.peek(ctx, '/api/v1/overview');
      if (c.ok) {
        this.applyOverview(c.data);
      }
      const ct: ApiResult = await Api.peek(ctx, '/api/v1/traffic');
      if (ct.ok) {
        this.applyTraffic(ct.data);
      }
    }
    const r: ApiResult = await Api.get(ctx, '/api/v1/overview');
    if (r.ok) {
      this.applyOverview(r.data);
    }
    await this.refreshTraffic(false);

    // 在线设备数：概览接口里没有，单独问一次（安卓 hero 的第三栏也是这么来的）
    const dv: ApiResult = await Api.get(ctx, '/api/v1/devices');
    if (dv.ok) {
      this.onlineCount = dv.data.obj('summary').num('online', 0);
    }
    this.loaded = true;
  }

  private async refreshTraffic(append: boolean): Promise<void> {
    const r: ApiResult = await Api.get(this.ctx(), '/api/v1/traffic');
    if (!r.ok) {
      return;
    }
    this.applyTraffic(r.data);
    if (append) {
      this.pushPoint(this.lastRx, this.lastTx);
    }
  }

  private lastRx: number = 0;
  private lastTx: number = 0;

  private applyTraffic(j: J): void {
    const wan: J = j.obj('wan');
    this.lastRx = wan.num('rx_bps', 0);
    this.lastTx = wan.num('tx_bps', 0);
    this.rxNow = Fmt.bps(this.lastRx);
    this.txNow = Fmt.bps(this.lastTx);
    this.rxTotal = Fmt.bytes(wan.num('rx_total', 0));
    this.txTotal = Fmt.bytes(wan.num('tx_total', 0));

    // /traffic 里的 ports 是实时的，用它刷新每口的当前速率；
    // 累计值和 mac 沿用 overview 里那份（两边字段一致，重算也没差）
    const list: J[] = j.arr('ports');
    for (let i = 0; i < list.length; i++) {
      const p: J = list[i];
      this.updatePort(p);
    }
  }

  private pushPoint(rx: number, tx: number): void {
    let d: number[] = this.downHist.slice();
    d.push(rx);
    while (d.length > 40) {
      d.shift();
    }
    this.downHist = d;

    let u: number[] = this.upHist.slice();
    u.push(tx);
    while (u.length > 40) {
      u.shift();
    }
    this.upHist = u;

    // 峰值跟着窗口走：取两条线的最大值，和趋势图自己的量程口径一致
    let peak: number = 0;
    for (let i = 0; i < d.length; i++) {
      peak = Math.max(peak, d[i]);
    }
    for (let i = 0; i < u.length; i++) {
      peak = Math.max(peak, u[i]);
    }
    this.peakText = Fmt.bps(peak);
  }

  /** 按名字更新单个网口：不存在就补一条，趋势线保留最近 32 个点 */
  private updatePort(p: J): void {
    const name: string = p.str('name', '');
    if (name.length === 0) {
      return;
    }
    const rows: PortVM[] = this.ports.slice();
    let idx: number = -1;
    for (let i = 0; i < rows.length; i++) {
      if (rows[i].name === name) {
        idx = i;
        break;
      }
    }
    const rx: number = p.num('rx_bps', 0);
    const tx: number = p.num('tx_bps', 0);
    const hist: number[] = idx >= 0 ? rows[idx].hist.slice() : [];
    hist.push(rx + tx);
    while (hist.length > 32) {
      hist.shift();
    }
    const vm: PortVM = {
      name: name,
      role: p.str('role', ''),
      up: p.bool('up', false),
      speedMbps: p.num('speed_mbps', 0),
      speedText: Fmt.speed(p.num('speed_mbps', 0)),
      rx: rx,
      tx: tx,
      rxText: Fmt.shortBps(rx),
      txText: Fmt.shortBps(tx),
      rxTotal: p.num('rx_total', 0),
      txTotal: p.num('tx_total', 0),
      mac: p.str('mac', ''),
      hist: hist
    };
    if (idx >= 0) {
      rows[idx] = vm;
    } else {
      rows.push(vm);
    }
    // WAN 排最前，其余按接口名 —— 每次重排，插拔网卡后顺序也稳定
    rows.sort((a: PortVM, b: PortVM) => {
      const wa: number = a.role === 'wan' ? 0 : 1;
      const wb: number = b.role === 'wan' ? 0 : 1;
      if (wa !== wb) {
        return wa - wb;
      }
      return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0);
    });
    this.ports = rows;
  }

  private applyOverview(j: J): void {
    const board: J = j.obj('board');
    const cpu: J = j.obj('cpu');
    const mem: J = j.obj('memory');
    const load: J = j.obj('load');
    const net: J = j.obj('network');
    const wan: J = net.obj('wan');

    this.hostname = board.str('hostname', 'iStoreOS');
    this.model = cpu.str('model', board.str('model', ''));
    this.kernel = board.str('kernel', '');
    this.osVersion = board.str('version', '');
    this.upBase = j.num('uptime', 0);
    this.upAt = Date.now();
    this.uptime = Fmt.uptime(this.upBase);
    this.load1 = load.num('load1', 0).toFixed(2);
    this.threads = load.str('threads', '—');

    this.cpuPct = cpu.num('percent', 0) / 100;
    this.cpuText = cpu.num('percent', 0).toFixed(0) + '%';

    this.memPct = mem.num('percent', 0) / 100;
    this.memText = mem.num('percent', 0).toFixed(0) + '%';
    this.memDetail = Fmt.bytes(mem.num('used', 0)) + ' / ' + Fmt.bytes(mem.num('total', 0));

    // 磁盘取容量最大的那个挂载点：overlay 只有 2G，跟装了多少东西没多少关系
    const disks: J[] = j.arr('storage');
    let bestPct: number = 0;
    let bestTotal: number = -1;
    let bestFree: number = 0;
    for (let i = 0; i < disks.length; i++) {
      const total: number = disks[i].num('total', 0);
      if (total > bestTotal) {
        bestTotal = total;
        bestPct = disks[i].num('percent', 0);
        bestFree = disks[i].num('free', 0);
      }
    }
    this.diskPct = bestPct / 100;
    this.diskText = bestPct.toFixed(0) + '%';
    this.diskDetail = Fmt.bytes(bestFree) + ' 可用';

    // 温度优先取 CPU 封装温度，acpitz 那路是主板环境温度，参考价值低
    const temps: J[] = j.arr('temperature');
    let celsius: number = 0;
    for (let i = 0; i < temps.length; i++) {
      const label: string = temps[i].str('label', '');
      if (label.indexOf('pkg') >= 0 || label.indexOf('core') >= 0) {
        celsius = temps[i].num('celsius', 0);
        break;
      }
    }
    if (celsius <= 0 && temps.length > 0) {
      celsius = temps[0].num('celsius', 0);
    }
    this.temp = Fmt.temp(celsius);
    this.tempWarm = celsius >= 65;

    this.wanUp = wan.bool('up', false);
    this.wanProto = wan.str('proto', '').toUpperCase();
    this.wanIp = wan.str('ipv4', '—');
    this.wanGw = wan.str('gateway', '—');
    const dnsList: string[] = wan.strs('dns');
    this.wanDns = dnsList.length === 0 ? '自动' : dnsList.join('  ');
    this.wanUpSec = wan.num('uptime', 0);

    const list: J[] = net.arr('ports');
    for (let i = 0; i < list.length; i++) {
      this.updatePort(list[i]);
    }

    this.verdict = this.buildVerdict();
  }

  /** 一句话结论：先说好不好，再说为什么 */
  private buildVerdict(): string {
    if (!this.wanUp) {
      return '外网没有连上';
    }
    if (this.cpuPct >= 0.85) {
      return 'CPU 占用偏高';
    }
    if (this.memPct >= 0.9) {
      return '内存快用满了';
    }
    if (this.tempWarm) {
      return '温度有点高';
    }
    return '路由器运行正常';
  }

  private onlinePorts(): number {
    let n: number = 0;
    for (let i = 0; i < this.ports.length; i++) {
      if (this.ports[i].up) {
        n++;
      }
    }
    return n;
  }

  /** 网口两列排布时按行切：ArkTS 里嵌套 ForEach 做算术比 Grid 定高更稳 */
  private portRows(): number[] {
    const n: number = this.ports.length;
    const cols: number = 2;
    const rows: number[] = [];
    for (let i = 0; i < Math.ceil(n / cols); i++) {
      rows.push(i);
    }
    return rows;
  }

  private portIndex(row: number, col: number): number {
    return row * 2 + col;
  }

  build() {
    Scroll() {
      Column() {
        Text('概览')
          .fontSize(T.F_TITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .margin({ bottom: 10 });

        if (this.rail()) {
          Row({ space: Bp.gap(this.winW) }) {
            Column() {
              this.heroCard();
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start);

            Column() {
              this.ringCard();
              this.wanCard();
              this.portCard();
              this.machineCard();
              this.netEntryCard();
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start);
          }
          .width('100%')
          .alignItems(VerticalAlign.Top);
        } else {
          Column() {
            this.heroCard();
            this.ringCard();
            this.wanCard();
            this.portCard();
            this.machineCard();
            this.netEntryCard();
          }
          .width('100%');
        }

        Row().width('100%').height(24);
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .padding({
        left: this.rail() ? 20 : T.PAD,
        right: this.rail() ? 20 : T.PAD,
        top: 8
      });
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .backgroundColor($r('app.color.app_bg'))
    .align(Alignment.Top);
  }

  // ================================================================ 卡片

  @Builder
  heroCard() {
    Column() {
      // 顶部一行：状态点 + 一句话结论 + 系统版本胶囊（与安卓 Ui.gradient 那段一一对应）
      Row() {
        Row()
          .width(7)
          .height(7)
          .borderRadius(4)
          .backgroundColor($r('app.color.hero_fg'))
          .margin({ right: 7 });
        Text(this.verdict.length > 0 ? this.verdict : '正在读取…')
          .fontSize(12.5)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.hero_fg'))
          .maxLines(1);
        Blank();
        Text('iStoreOS ' + Fmt.orDash(this.osVersion))
          .fontSize(11)
          .fontColor($r('app.color.hero_fg'))
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(T.R_PILL)
          .backgroundColor(Pal.heroStroke());
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      // 大字是主机名 —— 安卓那边也是「机器叫什么」，结论在上一行
      Text(this.hostname)
        .fontSize(27)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.hero_fg'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 12 });

      Text('内核 ' + Fmt.orDash(this.kernel) + ' · 在线 ' + this.uptime)
        .fontSize(T.F_SUB)
        .fontColor($r('app.color.hero_fg_soft'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 5 });

      // 0.7 的分隔线：渐变底上不能用 divider 色，得用 on-primary 的透明版
      Row()
        .width('100%')
        .height(1)
        .backgroundColor(Pal.heroStroke())
        .margin({ top: 16, bottom: 14 });

      Row() {
        HeroStat({ label: '↓ 当前下载', value: this.rxNow }).layoutWeight(1)
        HeroStat({ label: '↑ 当前上传', value: this.txNow }).layoutWeight(1)
        HeroStat({ label: '在线设备',
          value: this.onlineCount > 0 ? this.onlineCount.toString() : '—' })
          .layoutWeight(1)
      }
      .width('100%');

      // 趋势图并进 hero（与安卓一致）：网快不快是同一件事，
      // 拆成下面另一张卡看得来回对照
      Column() {
        Row() {
          Text('流量趋势 · 最近 2 分钟')
            .fontSize(T.F_TINY)
            .fontColor($r('app.color.hero_fg_soft'))
            .layoutWeight(1);
          Text('峰值 ' + this.peakText)
            .fontSize(T.F_TINY)
            .fontColor($r('app.color.hero_fg_soft'));
        }
        .width('100%');

        TrendChart({
          down: this.downHist,
          up: this.upHist,
          chartHeight: Bp.chartH(this.winW, 96)
        })
          .margin({ top: 8 });

        // 图例：颜色必须和曲线一致，否则等于没有
        Row({ space: 12 }) {
          this.heroLegend('下载', Pal.primaryDim());
          this.heroLegend('上传', Pal.warn());
        }
        .width('100%')
        .margin({ top: 8 });
      }
      .width('100%')
      .margin({ top: 18 });
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 18, bottom: 18 })
    .borderRadius(T.R_CARD)
    .linearGradient({
      angle: 135,
      colors: [[Pal.heroFrom(), 0.0], [Pal.heroTo(), 1.0]]
    })
    .border({ width: 0.7, color: $r('app.color.hero_stroke') })
    .margin({ bottom: this.rail() ? Bp.gap(this.winW) : T.GAP });
  }

  /** hero 里的小图例：一个色点 + 文字 */
  @Builder
  heroLegend(label: string, color: string) {
    Row({ space: 6 }) {
      Row()
        .width(8)
        .height(8)
        .borderRadius(4)
        .backgroundColor(color);
      Text(label)
        .fontSize(T.F_TINY)
        .fontColor($r('app.color.hero_fg_soft'));
    }
    .alignItems(VerticalAlign.Center);
  }

  @Builder
  ringCard() {
    Card({ gapTop: 0, gapBottom: this.rail() ? Bp.gap(this.winW) : T.GAP }) {
      CardTitle({ glyph: Glyph.CHIP, title: '系统负载', sub: 'CPU · 内存 · 磁盘' }) {
        Text('负载 ' + this.load1)
          .fontSize(T.F_TINY)
          .fontColor($r('app.color.text_secondary'));
      }
      MeterRow({
        label: 'CPU',
        ratio: this.cpuPct,
        value: this.cpuText,
        detail: this.threads + ' 线程'
          + (this.temp.length > 0 && this.temp !== '—' ? ' · ' + this.temp : '')
      })
      MeterRow({ label: '内存', ratio: this.memPct, value: this.memText, detail: this.memDetail })
      MeterRow({ label: '磁盘', ratio: this.diskPct, value: this.diskText, detail: this.diskDetail })
    }
  }

  /** 宽带连接：四项关键信息 + 网络设置入口（安卓概览里也是独立一张） */
  @Builder
  wanCard() {
    Card({ gapTop: 0, gapBottom: this.rail() ? Bp.gap(this.winW) : T.GAP }) {
      CardTitle({ glyph: Glyph.GLOBE, title: '宽带连接', sub: this.wanUp ? '已拨通' : '未连接' }) {
        Pill({
          text: this.wanProto.length > 0 ? this.wanProto : '配置',
          tone: this.wanUp ? Pal.ok() : Pal.textSecondary()
        });
      }

      Column({ space: 9 }) {
        Kv({ label: 'WAN 地址', value: this.wanIp, valueSize: 0, accent: false });
        Kv({ label: '网关', value: this.wanGw, valueSize: 0, accent: false });
        Kv({ label: 'DNS', value: this.wanDns, valueSize: 0, accent: false });
        Kv({
          label: '拨号时长',
          value: this.wanUpSec > 0 ? Fmt.uptime(this.wanUpSec) : '—',
          valueSize: 0,
          accent: false
        });
      }
      .width('100%')
      .margin({ top: 12 });

      Hairline({ indent: 0 });

      Row() {
        GlyphIcon({ kind: Glyph.LINK, color: Pal.primary(), side: 16, lineWidth: 1.9 });
        Column() {
          Text('网络设置')
            .fontSize(T.F_BODY)
            .fontColor($r('app.color.text_primary'));
          Text('WAN / LAN / 无线 / 端口转发')
            .fontSize(T.F_TINY)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: 2 });
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 10 });
        GlyphIcon({ kind: Glyph.CHEVRON, color: Pal.textTertiary(), side: 15, lineWidth: 1.9 });
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ top: 12, bottom: 4 })
      .onClick(() => {
        router.pushUrl({ url: 'pages/NetSettingsPage' });
      });
    }
  }

  @Builder
  portCard() {
    Card({ gapTop: 0, gapBottom: this.rail() ? Bp.gap(this.winW) : T.GAP }) {
      CardTitle({ glyph: Glyph.BOX, title: '网口', sub: '点开看累计收发' }) {
        Pill({
          text: this.ports.length === 0
            ? '—'
            : this.onlinePorts().toString() + '/' + this.ports.length.toString() + ' 在线',
          tone: this.onlinePorts() > 0 ? Pal.primary() : Pal.textSecondary()
        });
      }

      if (this.ports.length === 0) {
        Text('没有检测到物理网口')
          .fontSize(T.F_SUB)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 12, bottom: 6 });
      } else {
        ForEach(this.portRows(), (row: number) => {
          Row({ space: 9 }) {
            ForEach([0, 1], (col: number) => {
              if (this.portIndex(row, col) < this.ports.length) {
                Row() {
                  PortTile({
                    name: this.ports[this.portIndex(row, col)].name,
                    role: this.ports[this.portIndex(row, col)].role,
                    up: this.ports[this.portIndex(row, col)].up,
                    speedText: this.ports[this.portIndex(row, col)].speedText,
                    rxText: this.ports[this.portIndex(row, col)].rxText,
                    txText: this.ports[this.portIndex(row, col)].txText,
                    totalText: Fmt.bytes(this.ports[this.portIndex(row, col)].rxTotal),
                    hist: this.ports[this.portIndex(row, col)].hist,
                    sparkH: this.rail() ? 32 : 26
                  });
                }
                .layoutWeight(1)
                .alignItems(VerticalAlign.Top);
              } else {
                // 单数个口时补一个透明占位，最后一张卡才不会横跨两列
                Row().layoutWeight(1);
              }
            }, (col: number) => row.toString() + '-' + col.toString());
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          .margin({ top: 9 });
        }, (row: number) => row.toString());
      }
    }
  }

  @Builder
  machineCard() {
    Card({ gapTop: 0, gapBottom: 0 }) {
      CardHeader({ title: '机器', sub: '' });
      Kv({ label: '型号', value: Fmt.orDash(this.model), valueSize: 0, accent: false });
      Hairline({ indent: 0 });
      Kv({ label: '系统', value: 'iStoreOS ' + Fmt.orDash(this.osVersion), valueSize: 0, accent: false });
      Hairline({ indent: 0 });
      Kv({ label: '内核', value: Fmt.orDash(this.kernel), valueSize: 0, accent: false });
      Hairline({ indent: 0 });
      Kv({ label: '在线时长', value: this.uptime, valueSize: 0, accent: false });
    }
  }

  /** 网络设置入口：原来那个「网络」页签现在从这儿进 */
  @Builder
  netEntryCard() {
    Card({ gapTop: 0, gapBottom: this.rail() ? Bp.gap(this.winW) : T.GAP }) {
      Row({ space: 12 }) {
        Stack() {
          GlyphIcon({ kind: Glyph.SWAP, color: Pal.primary(), side: 17, lineWidth: 1.7 });
        }
        .width(30)
        .height(30)
        .borderRadius(9)
        .backgroundColor($r('app.color.accent_soft'))
        .alignContent(Alignment.Center);
        Column({ space: 3 }) {
          Text('网络设置')
            .fontSize(T.F_BODY)
            .fontColor($r('app.color.text_primary'));
          Text('宽带参数、重拨、局域网与防火墙')
            .fontSize(T.F_TINY)
            .fontColor($r('app.color.text_secondary'));
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1);
        GlyphIcon({ kind: Glyph.CHEVRON, color: Pal.textTertiary(),
          side: 14, lineWidth: 1.9 });
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        router.pushUrl({ url: 'pages/NetSettingsPage' });
      });
    }
  }

}

/**
 * 概览 hero 的一格：大数字在上、标签在下。
 *
 * 为什么是 @Component 而不是 @Builder：
 * ArkUI 的 @Builder 默认按值传参，**状态变量变化不会刷新 builder 内的 UI**；
 * 传两个以上参数时连"按引用传递"也不生效。这里原来就是 @Builder，结果
 * 数据到了界面不动 —— 三格永远是初始值「—」。换成 @Prop 后父组件状态一变，
 * 子组件就会跟着重绘。
 */
@Component
struct HeroStat {
  @Prop label: string = '';
  @Prop value: string = '';
  build() {
    Column() {
      Text(this.label)
        .fontSize(11)
        .fontColor($r('app.color.hero_fg_soft'))
        .maxLines(1);
      Text(this.value)
        .fontSize(T.F_H1)
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

/** 系统负载的一行：标签 + 说明 + 百分比 + 进度条。同上是 @Component，不是 @Builder。 */
@Component
struct MeterRow {
  @Prop label: string = '';
  @Prop ratio: number = 0;
  @Prop value: string = '';
  @Prop detail: string = '';

  private pctWidth(): string {
    const v: number = Math.max(0, Math.min(1, this.ratio));
    return (v * 100).toFixed(0) + '%';
  }

  build() {
    Column() {
      Row() {
        Text(this.label)
          .fontSize(T.F_BODY)
          .fontColor($r('app.color.text_primary'));
        if (this.detail.length > 0) {
          Text(this.detail)
            .fontSize(T.F_TINY)
            .fontColor($r('app.color.text_secondary'))
            .margin({ left: 8 });
        }
        Blank();
        Text(this.value)
          .fontSize(T.F_BODY)
          .fontColor($r('app.color.text_primary'));
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      Stack({ alignContent: Alignment.Start }) {
        Row()
          .width('100%')
          .height(6)
          .borderRadius(3)
          .backgroundColor($r('app.color.track'));
        Row()
          .width(this.pctWidth())
          .height(6)
          .borderRadius(3)
          .backgroundColor($r('app.color.primary'));
      }
      .width('100%')
      .margin({ top: 6 });
    }
    .width('100%')
    .margin({ top: 14 });
  }
}
