import { common } from '@kit.AbilityKit';
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
      const row: DevRow = {
        mac: d.str('mac', ''),
        ip: d.str('ip', ''),
        name: name,
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

        if (this.rail()) {
          // 平板：在线 / 离线并排。分组语义本来就是两支，
          // 横着放能一眼对比「现在谁在、谁不在」，不用上下滚
          Row({ space: Bp.gap(this.winW) }) {
            Column() {
              this.onlineGroup(0);
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start);

            Column() {
              this.offlineGroup(0);
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start);
          }
          .width('100%')
          .alignItems(VerticalAlign.Top);
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
        }, (d: DevRow) => 'on' + d.mac);
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
        }, (d: DevRow) => 'off' + d.mac);
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

          Text(d.ip + (d.vendor.length > 0 ? ' · ' + d.vendor : ''))
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
    .width('100%');
  }
}
