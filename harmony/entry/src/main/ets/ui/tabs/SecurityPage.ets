import { common } from '@kit.AbilityKit';
import { Api, ApiResult } from '../../api/Api';
import { J } from '../../core/Json';
import { Fmt } from '../../util/Fmt';
import { Pal, T } from '../Theme';
import { Bp } from '../Breakpoint';
import { Card, CardHeader, Comp, GlyphIcon, Hairline, Pill } from '../Comp';
import { Glyph, Ico } from '../comp/Icons';
import { DevicesPage } from './DevicesPage';
import { ShieldPage } from './ShieldPage';

interface DevRow {
  mac: string;
  name: string;
  ip: string;
  bps: number;
  online: boolean;
  blocked: boolean;
}

/**
 * 设备（设备 + 拦截的一级页）。
 *
 * 原来「设备」和「拦截」是两个并列页签，各自都是一整套管理界面。
 * 但打开 App 的人通常只想知道「几台连着 / 今天挡了多少」，
 * 真正要动手的事一周才发生一次 —— 搜索框、规则表、日志全都摆在首页，
 * 反而把「一眼看完」这件事挤掉了。
 *
 * 合成一个入口后，一级只留三件：
 *   1. 在线 / 离线 / 已禁网 各多少台
 *   2. 拦截在不在工作、今天挡了多少
 *   3. 两个最大开关（接管全网 / 进清单）
 * 其余全部下沉到二级页，用 sub 状态切换 —— 手机上没有侧栏，
 * 一个「返回」顶栏比多一层 Tabs 更省纵向空间。
 */
@Component
export struct SecurityPage {
  @State loaded: boolean = false;
  @State err: string = '';

  /** 0 一级页 / 1 设备清单 / 2 拦截配置 */
  @State sub: number = 0;
  /** 进二级页时的预设筛选：0 全部 / 1 在线 / 2 离线 */
  @State subFilter: number = 0;

  @State online: number = 0;
  @State total: number = 0;
  @State blocked: number = 0;
  @State recent: DevRow[] = [];

  @State adInstalled: boolean = false;
  @State adRunning: boolean = false;
  @State adTakeover: boolean = false;
  @State adBlocked: number = 0;
  @State adQueries: number = 0;
  @State adPct: number = 0;
  @State busy: boolean = false;

  @State winW: number = 360;
  @StorageProp('winW') @Watch('onWidth') winWStore: number = 360;
  @StorageProp('tab') @Watch('onTab') tab: number = 2;

  private timer: number = -1;

  aboutToAppear(): void {
    this.winW = this.winWStore;
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

  private onTab(): void {
    if (this.tab === 2) {
      this.startPoll();
      this.load(false);
    } else {
      this.stopPoll();
    }
  }

  private rail(): boolean {
    return Bp.rail(this.winW);
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
        this.applyDevices(c.data);
      }
    }
    const r: ApiResult = await Api.get(ctx, '/api/v1/devices');
    if (r.ok) {
      this.applyDevices(r.data);
      this.loaded = true;
      this.err = '';
    } else {
      this.err = r.error;
      this.loaded = true;
    }

    const a: ApiResult = await Api.get(ctx, '/api/v1/adblock');
    if (a.ok) {
      this.applyAd(a.data);
    }
  }

  private applyDevices(b: J): void {
    const sum: J = b.obj('summary');
    this.online = sum.num('online', 0);
    this.total = sum.num('total', 0);
    this.blocked = sum.num('blocked', 0);

    const list: J[] = b.arr('devices');
    const rows: DevRow[] = [];
    for (let i = 0; i < list.length; i++) {
      const d: J = list[i];
      if (!d.bool('online', false)) {
        continue;
      }
      const net: J = d.obj('net');
      const bps: number = Math.max(
        net.num('rx_bps', 0) + net.num('tx_bps', 0), net.num('avg_bps', 0));
      let name: string = d.str('label', '');
      if (name.length === 0) {
        name = d.str('hostname', '');
      }
      if (name.length === 0) {
        name = d.str('vendor', '');
      }
      if (name.length === 0) {
        name = d.str('ip', '');
      }
      if (name.length === 0) {
        name = d.str('mac', '');
      }
      rows.push({
        mac: d.str('mac', ''),
        name: name,
        ip: d.str('ip', ''),
        bps: bps,
        online: true,
        blocked: d.bool('blocked', false)
      });
    }
    // 一级页只看「谁在用网」，按实时速率取前三
    rows.sort((x: DevRow, y: DevRow) => y.bps - x.bps);
    this.recent = rows.slice(0, 3);
  }

  private applyAd(b: J): void {
    this.adInstalled = b.bool('installed', false);
    this.adRunning = b.bool('running', false);
    this.adTakeover = b.str('mode', '') === 'takeover';
    const stats: J = b.obj('stats');
    this.adBlocked = stats.num('blocked', 0);
    this.adQueries = stats.num('queries', 0);
    this.adPct = stats.num('percent', 0);
  }

  private async setTakeover(want: boolean): Promise<void> {
    this.busy = true;
    const ctx = this.ctx();
    const r: ApiResult = await Api.post(
      ctx, want ? '/api/v1/adblock/takeover' : '/api/v1/adblock/release', {});
    this.busy = false;
    if (r.ok) {
      this.load(false);
    }
  }

  private openSub(n: number, filter: number): void {
    this.subFilter = filter;
    this.sub = n;
  }

  private offline(): number {
    const n = this.total - this.online;
    return n > 0 ? n : 0;
  }

  private adStateText(): string {
    if (!this.adInstalled) {
      return '未安装';
    }
    if (!this.adRunning) {
      return '未运行';
    }
    return this.adTakeover ? '运行中 · 接管' : '运行中';
  }

  // ---------------------------------------------------------------- 视图

  @Builder
  backBar(title: string) {
    Row() {
      Row() {
        Path()
          .commands(Ico.CHEVRON)
          .width(18)
          .height(18)
          .fill(Color.Transparent)
          .stroke(Pal.textPrimary())
          .strokeWidth(1.9)
          .strokeLineCap(LineCapStyle.Round)
          .rotate({ angle: 180 });
        Text('返回')
          .fontSize(T.F_BODY)
          .fontColor($r('app.color.primary'))
          .margin({ left: 2 });
      }
      .layoutWeight(0)
      .onClick(() => {
        this.sub = 0;
      });

      Blank();

      Text(title)
        .fontSize(T.F_H2)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'));

      Blank();

      Text('').width(56);
    }
    .width('100%')
    .height(44)
    .padding({ left: T.PAD, right: T.PAD })
    .alignItems(VerticalAlign.Center)
    .backgroundColor($r('app.color.app_bg'));
  }

  @Builder
  heroCard() {
    Column() {
      Row() {
        Row()
          .width(7)
          .height(7)
          .borderRadius(4)
          .backgroundColor($r('app.color.hero_fg'))
          .margin({ right: 7 });
        Text('局域网')
          .fontSize(12.5)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.hero_fg'))
          .layoutWeight(1);
        Text(this.adTakeover ? '拦截已接管' : (this.adInstalled ? '拦截未接管' : '拦截未装'))
          .fontSize(11)
          .fontColor($r('app.color.hero_fg'))
          .opacity(0.86)
          .padding({ left: 9, right: 9, top: 4, bottom: 4 })
          .borderRadius(T.R_PILL)
          .backgroundColor(Comp.alpha('#FFFFFF', 0.16));
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      Row() {
        Text(this.online.toString())
          .fontSize(this.rail() ? 36 : 34)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.hero_fg'));
        Text('台设备在线')
          .fontSize(13)
          .fontColor($r('app.color.hero_fg'))
          .opacity(0.9)
          .margin({ left: 8, bottom: 4 });
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
      .margin({ top: 10 });

      Text(this.blocked > 0
        ? '共 ' + this.total + ' 台  ·  ' + this.blocked + ' 台已禁网'
        : '共 ' + this.total + ' 台')
        .fontSize(12)
        .fontColor($r('app.color.hero_fg'))
        .opacity(0.8)
        .width('100%')
        .margin({ top: 4 });
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ left: 20, right: 20, top: 18, bottom: 18 })
    .borderRadius(T.R_CARD)
    .linearGradient({
      angle: 135,
      colors: [[$r('app.color.hero_from'), 0], [$r('app.color.hero_to'), 1]]
    });
  }

  @Builder
  statCell(label: string, value: number, tone: string, filter: number) {
    Column() {
      Text(value.toString())
        .fontSize(25)
        .fontWeight(FontWeight.Medium)
        .fontColor(tone)
        .fontFeature("\"tnum\" on");
      Text(label)
        .fontSize(T.F_TINY)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: 3 });
    }
    .layoutWeight(1)
    .onClick(() => {
      this.openSub(1, filter);
    });
  }

  @Builder
  recentRow(d: DevRow, first: boolean) {
    Column() {
      if (!first) {
        Hairline({ indent: 0 });
      }
      Row() {
        Column() {
          Text(d.name)
            .fontSize(14.5)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
          Text(d.ip.length > 0 ? d.ip : d.mac)
            .fontSize(T.F_TINY)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: 3 });
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1);

        Column() {
          Text(d.bps < 1024 ? '空闲' : Fmt.bps(d.bps))
            .fontSize(12)
            .fontColor(d.bps < 1024 ? $r('app.color.text_secondary') : $r('app.color.primary'))
            .fontFeature("\"tnum\" on");
          if (d.blocked) {
            Text('已禁网')
              .fontSize(T.F_TINY)
              .fontColor($r('app.color.danger'))
              .margin({ top: 2 });
          }
        }
        .alignItems(HorizontalAlign.End);
      }
      .width('100%')
      .padding({ top: 9, bottom: 9 })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        this.openSub(1, 0);
      });
    }
    .width('100%');
  }

  @Builder
  entryRow(glyph: string, title: string, note: string, target: number) {
    Row() {
      Row() {
        GlyphIcon({ kind: glyph, color: Pal.primary(), side: 17, lineWidth: 1.9 });
      }
      .width(30)
      .height(30)
      .justifyContent(FlexAlign.Center)
      .borderRadius(9)
      .backgroundColor($r('app.color.accent_soft'))
      .margin({ right: 11 });

      Column() {
        Text(title)
          .fontSize(14.5)
          .fontColor($r('app.color.text_primary'));
        Text(note)
          .fontSize(T.F_TINY)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 3 });
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);

      Path()
        .commands(Ico.CHEVRON)
        .width(16)
        .height(16)
        .fill(Color.Transparent)
        .stroke(Pal.textTertiary())
        .strokeWidth(1.6)
        .strokeLineCap(LineCapStyle.Round);
    }
    .width('100%')
    .padding({ top: 11, bottom: 11 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.sub = target;
    });
  }

  @Builder
  deviceCard() {
    Card() {
      CardHeader({ title: '设备', sub: '点数字进清单，点行看详情' });

      Row() {
        this.statCell('在线', this.online, Pal.primary(), 1);
        this.statCell('离线', this.offline(), Pal.textPrimary(), 2);
        this.statCell('已禁网', this.blocked, Pal.danger(), 0);
      }
      .width('100%')
      .margin({ top: 12, bottom: 8 });

      Hairline({ indent: 0 });

      Text('最近活跃')
        .fontSize(T.F_TINY)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ top: 10, bottom: 2 });

      if (this.recent.length === 0) {
        Text('还没有设备上线')
          .fontSize(T.F_BODY)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .padding({ top: 10, bottom: 10 });
      } else {
        ForEach(this.recent, (d: DevRow, i: number) => {
          this.recentRow(d, i === 0);
        }, (d: DevRow) => d.mac);
      }
    }
  }

  @Builder
  adCard() {
    Card() {
      Row() {
        Column() {
          CardHeader({ title: '拦截', sub: 'AdGuard Home' });
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start);

        Pill({
          text: this.adStateText(),
          tone: this.adRunning ? Pal.primary() : Pal.textSecondary()
        });
      }
      .width('100%')
      .alignItems(VerticalAlign.Top);

      Row() {
        Text(Fmt.count(this.adBlocked))
          .fontSize(30)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .fontFeature("\"tnum\" on");
        Text('次拦截')
          .fontSize(T.F_SUB)
          .fontColor($r('app.color.text_secondary'))
          .margin({ left: 7, bottom: 5 });
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
      .margin({ top: 12 });

      Text('今日共查询 ' + Fmt.count(this.adQueries) + ' 次')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ top: 4 });

      Text(this.adPct > 0 ? '拦截率 ' + Math.round(this.adPct) + '%' : '今天还没有拦截记录')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ top: 2 });

      Row() {
        Column() {
          Text('接管全网 DNS')
            .fontSize(T.F_BODY)
            .fontColor($r('app.color.text_primary'));
          Text('关闭后所有设备改回运营商 DNS')
            .fontSize(T.F_TINY)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: 3 });
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1);

        Toggle({ type: ToggleType.Switch, isOn: this.adTakeover })
          .selectedColor(Pal.primary())
          .enabled(this.adInstalled && !this.busy)
          .onChange((on: boolean) => {
            // 先确认再改：它动的是全网的 DNS 走向
            this.confirmTakeover(on);
          });
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: 14 });

      Column() {
        Hairline({ indent: 0 });
      }
      .width('100%')
      .margin({ top: 10 });

      this.entryRow(Glyph.REFRESH, '规则与更新', '自动更新频率、规则表开关', 2);
      Hairline({ indent: 0 });
      this.entryRow(Glyph.LIST, '拦截日志', '最近被挡掉的域名查询', 2);
    }
  }

  private confirmTakeover(want: boolean): void {
    this.getUIContext().showAlertDialog({
      title: want ? '让所有设备走 AdGuard Home 解析？' : '退出 DNS 接管？',
      message: want
        ? '会把全网域名查询切到 AdGuard Home。已连设备在租约续期后生效，中途有一两秒解析抖动；'
          + '如果 AGH 已停用，全网会短时无法解析域名。'
        : '退出后所有设备改回运营商 DNS：广告拦截立即失效，已建立的连接不受影响。',
      primaryButton: {
        value: want ? '接管' : '退出接管',
        fontColor: Pal.danger(),
        action: () => {
          this.setTakeover(want);
        }
      },
      secondaryButton: {
        value: '取消',
        action: () => {
          // 开关是绑在 adTakeover 上的，取消后状态不变，不需要回滚
        }
      }
    });
  }

  build() {
    if (this.sub === 1) {
      Column() {
        this.backBar('设备清单');
        Row() {
          DevicesPage({ presetFilter: this.subFilter })
        }
        .layoutWeight(1)
        .width('100%');
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.app_bg'));
    } else if (this.sub === 2) {
      Column() {
        this.backBar('拦截');
        Row() {
          ShieldPage()
        }
        .layoutWeight(1)
        .width('100%');
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.app_bg'));
    } else {
      Scroll() {
        Column() {
          Row() {
            Text('设备')
              .fontSize(T.F_TITLE)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .layoutWeight(1);
            Text(this.online + ' 在线 / ' + this.total + ' 台')
              .fontSize(T.F_TINY)
              .fontColor($r('app.color.text_secondary'));
          }
          .width('100%')
          .alignItems(VerticalAlign.Bottom)
          .padding({ bottom: 10 });

          if (this.err.length > 0 && this.total === 0) {
            Text('读取失败：' + this.err)
              .fontSize(T.F_SUB)
              .fontColor($r('app.color.danger'))
              .width('100%')
              .margin({ bottom: 10 });
          }

          if (this.rail()) {
            Row({ space: T.GAP }) {
              Column({ space: T.GAP }) {
                this.heroCard();
                this.deviceCard();
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start);

              Column({ space: T.GAP }) {
                this.adCard();
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start);
            }
            .width('100%')
            .alignItems(VerticalAlign.Top);
          } else {
            Column({ space: T.GAP }) {
              this.heroCard();
              this.deviceCard();
              this.adCard();
            }
            .width('100%');
          }

          Row().width('100%').height(24);
        }
        .width('100%')
        .padding({ left: T.PAD, right: T.PAD, top: 8 });
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .backgroundColor($r('app.color.app_bg'))
      .align(Alignment.Top);
    }
  }
}
