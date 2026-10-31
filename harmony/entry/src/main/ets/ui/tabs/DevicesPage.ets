import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { Api, ApiResult } from '../../api/Api';
import { J } from '../../core/Json';
import { Fmt } from '../../util/Fmt';
import { Bp } from '../Breakpoint';
import { Pal, T } from '../Theme';
import { GroupBox, Hairline } from '../Comp';

/**
 * 徽标文字：能缩写就缩写（5G / 2.4G / WiFi / LAN），与安卓 `Access.shortLabel`、
 * iOS `F.accessShort` 同一套规则。频段不明只说类型，类型不明给破折号 ——
 * 问号满屏比留白更像故障
 */
function accessShort(a: J): string {
  const type: string = a.str('type', '');
  const band: string = a.str('band', '');
  if (type === 'wifi') {
    if (band.startsWith('5')) {
      return '5G';
    }
    if (band.startsWith('2')) {
      return '2.4G';
    }
    return 'WiFi';
  }
  if (type === 'wired') {
    return 'LAN';
  }
  return '—';
}

/** 「AP 报的 + 高置信」才算事实，其余都是推断（徽标画描边） */
function accessReal(a: J): boolean {
  return a.str('source', '') === 'ap' && a.str('conf', '') === 'high';
}

/** IPv4 取末两段（100.243）；IPv6 或异常形态原样返回 */
function shortIp(ip: string): string {
  const parts: string[] = ip.split('.');
  if (parts.length === 4) {
    return parts[2] + '.' + parts[3];
  }
  return ip;
}

interface DevRow {
  mac: string;
  ip: string;
  name: string;
  vendor: string;
  type: string;
  /** 接入方式徽标文字：5G / 2.4G / WiFi / LAN / — */
  badge: string;
  /** 徽标是不是事实（实心）。false 画描边，表示是从设备类型推的 */
  badgeReal: boolean;
  /** 卡片标题：没命名的设备用 IP 末两段，130vp 宽放不下整串 */
  shortName: string;
  /** 副标题：IP/厂商，名字已经由 IP 派生时不再重复 IP */
  meta: string;
  online: boolean;
  blocked: boolean;
  staticIp: boolean;
  rate: string;
  rateNum: number;
  total: string;
}

/**
 * 设备页。
 *
 * 分组容器（一组一层圆角 + 行间细线），不是一个设备一张卡：
 * 家里 55 台设备，逐张卡会出现 55 层圆角和 55 层投影，列表又碎又卡。
 */
@Component
export struct DevicesPage {
  @State online: DevRow[] = [];
  @State offline: DevRow[] = [];
  @State totalCount: number = 0;
  @State blockedCount: number = 0;
  @State loaded: boolean = false;
  @State err: string = '';

  /** 从「设备」一级页进来时预设的筛选：0 全部 / 1 在线 / 2 离线 */
  @Prop presetFilter: number = 0;
  @State filter: number = 0;

  @StorageProp('tab') @Watch('onTab') tab: number = 2;
  @State winW: number = 360;
  @StorageProp('winW') @Watch('onWidth') winWStore: number = 360;

  private timer: number = -1;

  aboutToAppear(): void {
    this.winW = this.winWStore;
    this.filter = this.presetFilter;
    this.load(true);
    if (this.tab === 2) {
      this.startPoll();
    }
  }

  aboutToDisappear(): void {
    this.stopPoll();
  }

  private onWidth(): void {
    this.winW = this.winWStore;
  }

  private rail(): boolean {
    return Bp.rail(this.winW);
  }

  private onTab(): void {
    if (this.tab === 2) {
      this.startPoll();
      this.load(false);
    } else {
      this.stopPoll();
    }
  }

  private startPoll(): void {
    this.stopPoll();
    this.timer = setInterval(() => {
      this.load(false);
    }, 5000);
  }

  private stopPoll(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private ctx(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private async load(withCache: boolean): Promise<void> {
    const ctx = this.ctx();
    if (withCache) {
      const c: ApiResult = await Api.peek(ctx, '/api/v1/devices');
      if (c.ok) {
        this.apply(c.data);
      }
    }
    const r: ApiResult = await Api.get(ctx, '/api/v1/devices');
    if (r.ok) {
      this.err = '';
      this.apply(r.data);
    } else {
      this.err = r.error;
    }
    this.loaded = true;
  }

  private apply(j: J): void {
    const list: J[] = j.arr('devices');
    const on: DevRow[] = [];
    const off: DevRow[] = [];
    let blocked: number = 0;

    for (let i = 0; i < list.length; i++) {
      const d: J = list[i];
      const net: J = d.obj('net');
      const isBlocked: boolean = d.bool('blocked', false);
      if (isBlocked) {
        blocked++;
      }
      let name: string = d.str('label', '');
      if (name.length === 0) {
        name = d.str('alias', '');
      }
      if (name.length === 0) {
        name = d.str('hostname', '');
      }
      if (name.length === 0) {
        name = d.str('vendor', '');
      }
      if (name.length === 0) {
        name = d.str('mac', '');
      }

      const acc: J = d.obj('access');
      const ip4: string = d.str('ip', '');
      const vendor4: string = d.str('vendor', '');
      const label4: string = d.str('label', '');
      // 卡片标题：有名字用名字，没有就用 IP 末两段（整串在 130vp 里会被截断）
      const cardName: string = label4.length > 0
        ? label4
        : (ip4.length > 0 ? shortIp(ip4) : name);
      const bits: string[] = [];
      if (ip4.length > 0 && ip4 !== cardName && shortIp(ip4) !== cardName) {
        bits.push(ip4);
      }
      if (vendor4.length > 0) {
        bits.push(vendor4);
      }
      const row: DevRow = {
        mac: d.str('mac', ''),
        ip: ip4,
        name: name,
        shortName: cardName,
        meta: bits.length > 0 ? bits.join(' · ') : d.str('mac', ''),
        vendor: d.str('vendor', ''),
        badge: accessShort(acc),
        badgeReal: accessReal(acc),
        type: d.str('type', ''),
        online: d.bool('online', false),
        blocked: isBlocked,
        staticIp: d.obj('dhcp').bool('reserved', false),
        rate: Fmt.bps(net.num('rx_bps', 0) + net.num('tx_bps', 0)),
        rateNum: net.num('rx_bps', 0) + net.num('tx_bps', 0),
        total: Fmt.bytes(net.num('rx_total', 0) + net.num('tx_total', 0))
      };
      if (row.online) {
        on.push(row);
      } else {
        off.push(row);
      }
    }

    // 在线的按实时速率排，离线的按名字排 —— 离线设备排速率没意义
    on.sort((a: DevRow, b: DevRow) => b.rateNum - a.rateNum);
    off.sort((a: DevRow, b: DevRow) => a.name.localeCompare(b.name));

    this.online = on;
    this.offline = off;
    this.totalCount = list.length;
    this.blockedCount = blocked;
  }

  build() {
    Scroll() {
      Column() {
        Row() {
          Text('设备')
            .fontSize(T.F_TITLE)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1);
          Text(this.online.length + ' 在线 / ' + this.totalCount + ' 台')
            .fontSize(T.F_SUB)
            .fontColor($r('app.color.text_secondary'));
        }
        .width('100%')
        .alignItems(VerticalAlign.Bottom)
        .padding({ bottom: 4 });


        Row({ space: 8 }) {
          ForEach([0, 1, 2], (v: number) => {
            Text(v === 0 ? '全部' : (v === 1 ? '在线' : '离线'))
              .fontSize(T.F_SUB)
              .fontWeight(this.filter === v ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(this.filter === v
                ? $r('app.color.primary')
                : $r('app.color.text_secondary'))
              .textAlign(TextAlign.Center)
              .layoutWeight(1)
              .height(34)
              .borderRadius(T.R_INNER)
              .backgroundColor(this.filter === v
                ? $r('app.color.accent_soft')
                : $r('app.color.surface_sunken'))
              .onClick(() => {
                this.filter = v;
              });
          }, (v: number) => String(v));
        }
        .width('100%')
        .margin({ bottom: 12 });

        if (this.blockedCount > 0) {
          Text(this.blockedCount + ' 台已禁网')
            .fontSize(T.F_TINY)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .margin({ bottom: 10 });
        } else {
          Row().width('100%').height(10);
        }

        if (this.err.length > 0 && this.totalCount === 0) {
          Text('读取失败：' + this.err)
            .fontSize(T.F_SUB)
            .fontColor($r('app.color.danger'))
            .width('100%')
            .padding(16);
        }

        if (this.cols() > 1) {
          // 宽画布：一张卡一台设备，按列铺开。
          // 原来是「在线 / 离线」左右分栏 —— 一天里大半时间离线那一栏是空的，
          // 等于把右半屏让给了没有内容的列表；改成网格后同样宽度能看到三倍的设备。
          Column() {
            this.gridOnline(0);
            this.gridOffline(18);
          }
          .width('100%');
        } else {
          Column() {
            this.onlineGroup(0);
            this.offlineGroup(18);
          }
          .width('100%');
        }

        Row().width('100%').height(24);
      }
      .width('100%')
      .constraintSize({ maxWidth: Bp.CONTENT_MAX })
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

  @Builder
  onlineGroup(topGap: number) {
    if (this.filter !== 2 && this.online.length > 0) {
      Text('在线')
        .fontSize(T.F_SUB)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ top: topGap, bottom: 6, left: 4 });

      GroupBox() {
        ForEach(this.online, (d: DevRow, i: number) => {
          this.row(d, i);
        }, (d: DevRow) => this.rowKey('on', d));
      }
    }
  }

  @Builder
  offlineGroup(topGap: number) {
    if (this.filter !== 1 && this.offline.length > 0) {
      Text('离线')
        .fontSize(T.F_SUB)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ top: topGap, bottom: 6, left: 4 });

      GroupBox() {
        ForEach(this.offline, (d: DevRow, i: number) => {
          this.row(d, i);
        }, (d: DevRow) => this.rowKey('off', d));
      }
    }
  }

  /** 徽标配色：5G 用主色、2.4G 用警示色，离线整体压灰 —— 与安卓一致 */
  private badgeColor(d: DevRow): string {
    if (!d.online) {
      return Pal.textTertiary();
    }
    if (d.badge === '5G') {
      return Pal.primary();
    }
    if (d.badge === '2.4G') {
      return Pal.warn();
    }
    return Pal.textSecondary();
  }

  /**
   * ForEach 的 key。**不能只写 MAC** —— 键不变时 ArkUI 会复用节点、不重跑行内容，
   * 结果是行里的实时速率、累计流量永远停在第一次渲染的值（5 秒一轮的刷新等于没刷）。
   * 把会变的显示字段一起编进 key，速率一变就重建这一行；列表只有几十行，代价可接受。
   */
  private rowKey(prefix: string, d: DevRow): string {
    return prefix + d.mac + '|' + d.rate + '|' + d.total + '|' + d.name + '|' + d.ip
      + '|' + d.badge + '|' + (d.badgeReal ? '1' : '0') + '|' + (d.blocked ? '1' : '0');
  }

  @Builder
  row(d: DevRow, i: number) {
    Column() {
      if (i > 0) {
        Hairline({ indent: 16 });
      }
      Row({ space: 10 }) {
        // 接入方式徽标（5G / 2.4G / LAN）替掉原来的首字方块：
        // 一排方块看不出「插线还是无线、连的哪个频段」，而那才是用户想知道的
        Text(d.badge)
          .fontSize(10)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.badgeColor(d))
          .textAlign(TextAlign.Center)
          .padding({ left: 6, right: 6, top: 3, bottom: 3 })
          .borderRadius(7)
          .backgroundColor(d.badgeReal ? Pal.alpha(this.badgeColor(d), 0.14) : Color.Transparent)
          .border({ width: d.badgeReal ? 0 : 1, color: Pal.alpha(this.badgeColor(d), 0.42) });

        Column() {
          Row({ space: 6 }) {
            Text(d.name)
              .fontSize(T.F_H2)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1);
            if (d.blocked) {
              Text('禁网')
                .fontSize(T.F_TINY)
                .fontColor($r('app.color.danger'))
                .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                .borderRadius(T.R_PILL)
                .backgroundColor(Pal.accentSoft());
            }
          }
          .width('100%');

          Text(d.meta)
            .fontSize(T.F_TINY)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 2 });
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1);

        Column() {
          Text(d.online ? d.rate : '—')
            .fontSize(T.F_SUB)
            .fontColor(d.online ? $r('app.color.primary') : $r('app.color.text_tertiary'))
            .fontFeature("\"tnum\" on");
          Text('累计 ' + d.total)
            .fontSize(T.F_TINY)
            .fontColor($r('app.color.text_tertiary'))
            .fontFeature("\"tnum\" on")
            .margin({ top: 2 });
        }
        .alignItems(HorizontalAlign.End);
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 11, bottom: 11 })
      .alignItems(VerticalAlign.Center);
    }
    .width('100%')
    .onClick(() => {
      this.openDetail(d.mac);
    });
  }

  /** 打开设备详情（独立路由页，见 pages/DeviceDetailPage） */
  private openDetail(mac: string): void {
    if (mac.length === 0) {
      return;
    }
    router.pushUrl({ url: 'pages/DeviceDetailPage', params: { mac: mac } });
  }

  // MARK: - 宽屏网格

  /** 内容区真实可用宽度：扣掉侧栏、页面留白 */
  private usableWidth(): number {
    const pad: number = this.rail() ? 20 : T.PAD;
    return Bp.contentWidth(this.winW) - pad * 2;
  }

  /**
   * 手机竖屏仍是分组列表（单列小卡又小又空），宽画布一屏 4–5 台。
   * 124vp 是「名字 + IP + 速率」在 12.5 字号下不折行的下限，
   * 和 iOS 的 `GridCols` 同一套算法。
   */
  private cols(): number {
    const w: number = this.usableWidth();
    if (w < 460) {
      return 1;
    }
    const n: number = Math.floor((w + 8) / (124 + 8));
    return Math.max(2, Math.min(5, n));
  }

  /** 方形卡的边长，托底 112、封顶 168 */
  private cardSide(): number {
    const n: number = this.cols();
    const raw: number = (this.usableWidth() - 8 * (n - 1)) / n;
    return Math.max(112, Math.min(168, raw));
  }

  /**
   * 按列数把列表切成一行一行。
   *
   * 不用 `Flex(wrap)` 是因为最后一行只有两张卡时会各自撑到半屏宽，
   * 和上一行对不齐；切成定长行之后，缺的位置用 Blank 补齐，网格永远齐。
   */
  private chunks(list: DevRow[]): DevRow[][] {
    const n: number = this.cols();
    const out: DevRow[][] = [];
    for (let i = 0; i < list.length; i += n) {
      out.push(list.slice(i, i + n));
    }
    return out;
  }

  /** 补齐最后一行缺的格子。返回值本身不重要，只要个数对 */
  private fillers(len: number): number[] {
    const out: number[] = [];
    for (let i = len; i < this.cols(); i++) {
      out.push(i);
    }
    return out;
  }

  /** 行 key 要把整行会变的字段编进去，否则速率刷新时这一行不重建 */
  private chunkKey(chunk: DevRow[]): string {
    let k: string = 'g';
    for (let i = 0; i < chunk.length; i++) {
      k += '|' + this.rowKey('g', chunk[i]);
    }
    return k;
  }

  @Builder
  gridOnline(topGap: number) {
    if (this.filter !== 2 && this.online.length > 0) {
      Row() {
        Text('在线')
          .fontSize(T.F_SUB)
          .fontColor($r('app.color.text_secondary'));
        Blank();
        Text(this.online.length + ' 台')
          .fontSize(T.F_TINY)
          .fontColor($r('app.color.text_tertiary'))
          .fontFeature("\"tnum\" on");
      }
      .width('100%')
      .padding({ left: 4, right: 4 })
      .margin({ top: topGap, bottom: 7 });

      Column({ space: 8 }) {
        ForEach(this.chunks(this.online), (chunk: DevRow[]) => {
          Row({ space: 8 }) {
            ForEach(chunk, (d: DevRow) => {
              this.card(d);
            }, (d: DevRow) => this.rowKey('g', d));
            ForEach(this.fillers(chunk.length), (n: number) => {
              Blank();
            }, (n: number) => 'f' + n);
          }
          .width('100%')
          .alignItems(VerticalAlign.Top);
        }, (chunk: DevRow[]) => this.chunkKey(chunk));
      }
      .width('100%');
    }
  }

  @Builder
  gridOffline(topGap: number) {
    if (this.filter !== 1 && this.offline.length > 0) {
      Row() {
        Text('离线')
          .fontSize(T.F_SUB)
          .fontColor($r('app.color.text_secondary'));
        Blank();
        Text(this.offline.length + ' 台')
          .fontSize(T.F_TINY)
          .fontColor($r('app.color.text_tertiary'))
          .fontFeature("\"tnum\" on");
      }
      .width('100%')
      .padding({ left: 4, right: 4 })
      .margin({ top: topGap, bottom: 7 });

      Column({ space: 8 }) {
        ForEach(this.chunks(this.offline), (chunk: DevRow[]) => {
          Row({ space: 8 }) {
            ForEach(chunk, (d: DevRow) => {
              this.card(d);
            }, (d: DevRow) => this.rowKey('g', d));
            ForEach(this.fillers(chunk.length), (n: number) => {
              Blank();
            }, (n: number) => 'f' + n);
          }
          .width('100%')
          .alignItems(VerticalAlign.Top);
        }, (chunk: DevRow[]) => this.chunkKey(chunk));
      }
      .width('100%');
    }
  }

  /**
   * 宽屏的一张设备卡。信息顺序和窄屏的行一致：状态 · 名字 · 接入 / IP · 厂商 / 速率 · 累计。
   * 状态不写字：在线用主色圆点，离线整卡压成浅底 + 速率破折号，
   * 因为网格里大半是离线设备，逐张写「离线」只会变成噪音。
   */
  @Builder
  card(d: DevRow) {
    Column() {
      Row({ space: 5 }) {
        Row()
          .width(5)
          .height(5)
          .borderRadius(3)
          .backgroundColor(d.online ? $r('app.color.primary') : $r('app.color.text_tertiary'));
        Text(d.shortName)
          .fontSize(12.5)
          .fontWeight(FontWeight.Medium)
          .fontColor(d.online ? $r('app.color.text_primary') : $r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1);
        // 角标 = 「点得进去」：方形卡放不下整行 chevron，右上角一枚小箭头就够
        if (d.blocked) {
          Text('禁')
            .fontSize(9)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.danger'))
            .textAlign(TextAlign.Center)
            .width(16)
            .height(16)
            .borderRadius(5)
            .backgroundColor(Pal.accentSoft());
        } else {
          Text('›')
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor(d.online ? $r('app.color.primary') : $r('app.color.text_tertiary'))
            .textAlign(TextAlign.Center)
            .width(16)
            .height(16)
            .borderRadius(5)
            .backgroundColor(d.online
              ? $r('app.color.accent_soft')
              : $r('app.color.surface_hi'));
        }
      }
      .width('100%');

      Text(d.meta)
        .fontSize(10)
        .fontColor(d.online ? $r('app.color.text_secondary') : $r('app.color.text_tertiary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 2 });

      Text(d.badge)
        .fontSize(9.5)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.badgeColor(d))
        .padding({ left: 5, right: 5, top: 1.5, bottom: 1.5 })
        .borderRadius(6)
        .backgroundColor(d.badgeReal ? Pal.alpha(this.badgeColor(d), 0.14) : Color.Transparent)
        .border({ width: d.badgeReal ? 0 : 1, color: Pal.alpha(this.badgeColor(d), 0.42) })
        .margin({ top: 5 });

      Blank();

      Text(d.online ? d.rate : '—')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(d.online ? $r('app.color.primary') : $r('app.color.text_tertiary'))
        .fontFeature("\"tnum\" on")
        .maxLines(1);
      Text('共 ' + d.total)
        .fontSize(10)
        .fontColor($r('app.color.text_tertiary'))
        .fontFeature("\"tnum\" on")
        .maxLines(1)
        .margin({ top: 1 });
    }
    .layoutWeight(1)
    .height(this.cardSide())
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 10, right: 10, top: 10, bottom: 10 })
    .borderRadius(14)
    .backgroundColor(d.online ? $r('app.color.surface') : $r('app.color.surface_sunken'))
    .border({ width: 0.5, color: $r('app.color.divider') })
    .onClick(() => {
      this.openDetail(d.mac);
    });
  }
}
