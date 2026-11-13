import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { Api, ApiResult } from '../../api/Api';
import { J } from '../../core/Json';
import { AppInfo } from '../../core/AppInfo';
import { UI, UIState } from '../../core/UIState';
import { Session } from '../../core/Session';
import { Shell } from '../../core/Shell';
import { Snap } from '../../core/Snap';
import { Fmt } from '../../util/Fmt';
import { Appearance } from '../Appearance';
import { Bp } from '../Breakpoint';
import { Pal, T } from '../Theme';
import { Card, CardTitle, Comp, GlyphIcon, Hairline, LineIcon, Note, RowCard, SettingRow } from '../Comp';
import { Glyph, Ico } from '../comp/Icons';
import { BackupsPage } from './BackupsPage';
import { HardwarePage } from './HardwarePage';

const SHEET_THEME: string = 'theme';
const SHEET_BASE: string = 'base';
const SHEET_PWD_APP: string = 'pwdApp';
const SHEET_PWD_ROOT: string = 'pwdRoot';
const SHEET_INFO: string = 'info';
const SHEET_ADDR: string = 'addr';

/**
 * 设置页。
 *
 * 这一版做了三处结构性调整：
 *  1. hero 里放「响应 / 凭证 / Agent」三个数，原来占三行的信息压成一行，
 *     省下来的位置给「连的是哪台」——那才是用户第一眼要看的东西；
 *  2. 全部改成「图标 + 标题 + 说明 + 右侧值」的行，眼睛能顺着图标往下扫；
 *  3. 没有退出登录。退出属于登录态的事，不该混在设置里，需要重新登录时
 *     走「重新登录」那一行 —— 它做的是清令牌再跳登录页。
 *
 * 弹层用页面内的浮层而不是 CustomDialog：CustomDialog 拿不到主题色变量，
 * 深浅色下会白底配白字，而且底部安全区还得自己补。
 */
@ComponentV2
export struct SettingsPage {
  @Local server: string = '';
  @Local agentVersion: string = '';
  @Local latency: string = '';
  @Local online: boolean = false;
  @Local userName: string = '';
  @Local tokenOk: boolean = false;
  /**
   * 设置页的子页：'' 停在一级页，'backup' 配置备份，'hardware' 硬件详情。
   * 用状态切换而不是路由：这两个页面带的是「从设置进去」的上下文，
   * 走路由会把底部页签一起盖掉，和安卓两个 Activity 的手感对不上。
   */
  @Local sub: string = '';

  @Local protoText: string = '';
  @Local wanUp: boolean = false;
  @Local ipv4: string = '—';
  @Local ipv6: string = '—';
  @Local wanUptime: string = '—';
  @Local lanV4: string = '—';
  /** 主题名，操作卡片里显示 */
  @Local themeName: string = '跟随系统';

  @Local sheet: string = '';
  @Local sheetTitle: string = '';
  /** 地址弹窗里要显示的完整值（IPv6 有 39 个字符，行里放不下） */
  @Local addrValue: string = '';
  @Local infoTitle: string = '';
  @Local infoBody: string = '';
  @Local f1: string = '';
  @Local f2: string = '';
  @Local busy: boolean = false;
  @Local toast: string = '';

  @Local winW: number = 360;
  /** 下拉刷新：Refresh 组件要求绑一个布尔，松手后由代码收回去 */
  @Local pulling: boolean = false;
  /** 电源：先点一次变「再点一次确认」，避免误触 */
  @Local pendingPower: string = '';
  @Local powerBusy: boolean = false;
  /** 硬件信息（system/hardware 只读） */
  @Local hw: J = J.empty();
  @Local hwLoaded: boolean = false;
  @Local ui: UIState = UI;
  @Local tab: number = UI.tab;

  aboutToAppear(): void {
    this.winW = this.ui.winW;
    this.server = Session.base();
    this.userName = Session.user();
    this.themeName = Appearance.label();
    this.tokenOk = Session.token().length > 0;
    this.load();
  }

  @Monitor('ui.winW')
  onWidth(): void {
    this.winW = this.ui.winW;
  }

  private onTab(): void {
    // 从别的页签切回来时重算一次：设置页显示的 WAN 地址可能已经换了
    if (this.tab === 3) {
      this.load();
    }
  }

  /** 进子页：同时告诉壳层，藏掉底部导航、把返回手势改成「退回一级页」 */
  private openSub(s: string): void {
    Shell.enter(s === 'backup' ? '配置备份' : '硬件信息');
    this.getUIContext().animateTo({ duration: 220, curve: Curve.EaseOut }, () => {
      this.sub = s;
    });
  }

  private closeSub(): void {
    this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseIn }, () => {
      this.sub = '';
    });
    Shell.leave();
  }

  /** 壳收到系统返回手势：关掉子页 */
  @Monitor('ui.backTick')
  onBackAsked(): void {
    if (this.sub.length > 0) {
      this.closeSub();
    }
  }

  private ctx(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private rail(): boolean {
    return Bp.rail(this.winW);
  }

  // ================================================================ 数据

  private async load(): Promise<void> {
    const ctx = this.ctx();
    this.server = Session.base();
    this.tokenOk = Session.token().length > 0;

    this.loadHardware();

    const started: number = Date.now();
    const ping: ApiResult = await Api.getFresh(ctx, '/api/v1/ping');
    if (ping.ok) {
      const v: string = ping.data.str('version', '');
      const ms: number = Date.now() - started;
      this.agentVersion = v;
      this.latency = ms.toString();
      this.online = true;
    } else {
      this.agentVersion = '';
      this.latency = '';
      this.online = false;
    }

    // overview 只需要确认在线，主机名不再单独取 —— hero 大标题改成了用户名，
    // 地址在「关于」卡里有一行，网络卡里也有内网网关，不需要第三处
    const ov: ApiResult = await Api.get(ctx, '/api/v1/overview');
    if (ov.ok) {
      // 保留在线探测本身，避免单独为它再发一次 ping
    }

    const n: ApiResult = await Api.get(ctx, '/api/v1/network');
    if (!n.ok) {
      return;
    }
    const wan: J = n.data.obj('wan');
    this.wanUp = wan.bool('up', false);
    this.protoText = wan.str('proto', '').toUpperCase();
    this.ipv4 = this.firstAddr(wan.arr('ipv4'));
    this.ipv6 = this.pickV6(wan.arr('ipv6'));
    const up: number = wan.num('uptime', 0);
    this.wanUptime = up > 0 ? Fmt.dur(up) : '—';
    this.lanV4 = this.firstAddr(n.data.obj('lan').arr('ipv4'));
  }

  /** 下拉一次：这一页的数字多半是「别人改完我来看」，随手拉一下是最自然的确认动作 */
  private async pull(): Promise<void> {
    this.pulling = true;
    // 硬件缓存会挡住重新读取，先放开
    this.hwLoaded = false;
    await this.load();
    this.pulling = false;
  }

  /** "192.168.100.1/24" 这种带前缀的写法比裸地址有用 */
  private firstAddr(list: J[]): string {
    if (list.length === 0) {
      return '—';
    }
    const a: string = list[0].str('address', '');
    if (a.length === 0) {
      return '—';
    }
    const p: number = list[0].num('prefixlen', -1);
    return p >= 0 ? a + '/' + p : a;
  }

  /** ubus 返回的第一条常是 fe80 链路本地地址，优先显示能用的全局地址 */
  private pickV6(list: J[]): string {
    let preferred: string = '';
    let first: string = '';
    for (let i = 0; i < list.length; i++) {
      const a: string = list[i].str('address', '');
      if (a.length === 0) {
        continue;
      }
      if (first.length === 0) {
        first = a;
      }
      if (preferred.length === 0 && a.indexOf('fe80') !== 0) {
        preferred = a;
      }
    }
    const pick: string = preferred.length > 0 ? preferred : first;
    return pick.length > 0 ? pick : '—';
  }

  private flash(text: string): void {
    this.toast = text;
    setTimeout(() => {
      this.toast = '';
    }, 2000);
  }

  // ================================================================ 布局

  build() {
    if (this.sub.length > 0) {
      Column() {
        this.backBar(this.sub === 'backup' ? '配置备份' : '硬件信息');
        Row() {
          if (this.sub === 'backup') {
            BackupsPage()
          } else {
            HardwarePage()
          }
        }
        .layoutWeight(1)
        .width('100%');
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.app_bg'))
      .padding({
        left: this.rail() ? 20 : T.PAD,
        right: this.rail() ? 20 : T.PAD,
        top: 8
      })
      // 从右边推进来，和另两个二级页同一个手感
      .transition(TransitionEffect.OPACITY
        .combine(TransitionEffect.translate({ x: 32 })));
    } else {
      Stack({ alignContent: Alignment.Bottom }) {
        Column() {
          // 大标题固定在滚动区外，不跟着内容滚走
          Text('设置')
            .fontSize(T.F_TITLE)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
            .padding({
              left: this.rail() ? 20 : T.PAD,
              right: this.rail() ? 20 : T.PAD,
              top: 8,
              bottom: 10
            });

          Refresh({ refreshing: $$this.pulling }) {
            Scroll() {
              Column() {
                if (this.rail()) {
                  // 平板：左「我是谁 / 连到哪」，右「怎么用 / 怎么改」
                  Row({ space: Bp.gap(this.winW) }) {
                    Column() {
                      this.heroCard();
                      this.netCard();
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start);

                    Column() {
                      this.systemCard();
                      this.powerCard();
                      this.hardwareCard();
                      this.securityCard();
                      this.aboutCard();
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start);
                  }
                  .width('100%')
                  .alignItems(VerticalAlign.Top);
                } else {
                  Column() {
                    this.heroCard();
                    this.netCard();
                    this.systemCard();
                    this.powerCard();
                    this.hardwareCard();
                    this.securityCard();
                    this.aboutCard();
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
                top: 2
              });
            }
            .width('100%')
            .height('100%')
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring)
            .align(Alignment.Top);
          }
          .layoutWeight(1)
          .width('100%')
          .onRefreshing(() => {
            this.pull();
          });
        }
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.app_bg'));

      if (this.toast.length > 0) {
        Text(this.toast)
          .fontSize(13)
          .fontColor($r('app.color.hero_fg'))
          .padding({ left: 16, right: 16, top: 9, bottom: 9 })
          .borderRadius(T.R_PILL)
          .backgroundColor('#CC1F2A26')
          .margin({ bottom: 88 })
          .hitTestBehavior(HitTestMode.None);
      }

      if (this.sheet === SHEET_ADDR) {
        // 地址要「屏幕居中 + 一次看全」：底部弹层贴边、正文区还限高，
        // 长地址在那种布局里永远像被截了一半
        this.addrOverlay();
      } else if (this.sheet.length > 0) {
        this.sheetOverlay();
      }
      }
      .width('100%')
      .height('100%');
    }
  }

  // ================================================================ 卡片

  /** 子页返回栏。和 SecurityPage 的那一条保持一致，避免两个二级页两种返回样式 */
  /** 二级页返回栏：只留箭头，不写字 —— 「返回」两个字在中文界面里是噪音 */
  @Builder
  backBar(title: string) {
    Row() {
      Row() {
        LineIcon({
          path: Ico.CHEVRON,
          color: Pal.textPrimary(),
          side: 20,
          lineWidth: 1.9,
          spin: 180
        });
      }
      .layoutWeight(0)
      .padding({ left: 2, right: 10, top: 4, bottom: 4 })
      .onClick(() => {
        this.closeSub();
      });

      Blank();

      Text(title)
        .fontSize(T.F_BODY)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'));
      Blank();

      // 与左侧返回同宽，标题才真正居中
      Row().width(32).height(1);
    }
    .width('100%')
    .height(44)
    .alignItems(VerticalAlign.Center);
  }

  @Builder
  heroCard() {
    Column() {
      // 状态行
      Row() {
        Row()
          .width(7)
          .height(7)
          .borderRadius(4)
          .backgroundColor(this.online ? $r('app.color.hero_fg') : Pal.warn())
          .margin({ right: 7 });
        Text(this.online ? '已连接' : '连不上')
          .fontSize(12.5)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.hero_fg'))
          .layoutWeight(1);
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      // 大标题放「我是谁」，下一行才是「连到哪」。
      // 原来标题是路由器的主机名，而主机名在概览页已经出现过一次；
      // 这一页真正需要一眼确认的是「我现在用哪个账号、连的是哪台」。
      Text(this.userName.length > 0 ? this.userName : '未登录')
        .fontSize(24)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.hero_fg'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Start)
        .width('100%')
        .margin({ top: 10 });

      Text(this.hostText())
        .fontSize(12.5)
        .fontColor($r('app.color.hero_fg_soft'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Start)
        .width('100%')
        .margin({ top: 4 });

      Row() {
        HeroStat({ label: '响应', value: this.latency.length > 0 ? this.latency + ' ms' : '—' });
        HeroStat({ label: '时长', value: this.wanUptime });
        HeroStat({ label: '凭证', value: this.tokenOk ? (this.online ? '有效' : '已保存') : '缺失' });
      }
      .width('100%')
      .margin({ top: 16 });
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 22, bottom: 22 })
    .borderRadius(T.R_CARD)
    .linearGradient({
      angle: 135,
      colors: [[Pal.heroFrom(), 0.0], [Pal.heroTo(), 1.0]]
    })
    .border({ width: 0.7, color: $r('app.color.hero_stroke') })
    .margin({ bottom: this.rail() ? Bp.gap(this.winW) : T.GAP });
  }

  /**
   * 长地址在行里只能显示一半（IPv6 有 39 个字符），点一下弹出来看全的，
   * 顺手给个「复制」。
   *
   * 之前用 showAlertDialog：它的 message 区域限高，三四十个字符的 IPv6
   * 会被折成两三行、尾部还要滚动才能看全 —— 用户以为「只显示了一部分」。
   * 改成页内 sheet，文本自动换行 + 长按也可选中。
   */
  private showAddr(title: string, value: string): void {
    if (value.length === 0 || value === '—') {
      this.flash(title + '还没读到');
      return;
    }
    this.addrValue = value;
    this.openSheet(SHEET_ADDR);
    this.sheetTitle = title;
  }

  private copyAddr(): void {
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.addrValue);
    pasteboard.getSystemPasteboard().setData(data).then(() => {
      this.closeSheet();
      this.flash('已复制');
    }).catch(() => {
      this.flash('复制失败');
    });
  }

  @Builder
  netCard() {
    RowCard({ gapBottom: this.rail() ? 0 : T.GAP }) {
      CardTitle({ pad: 16,
        glyph: Glyph.GLOBE,
        title: '网络',
        sub: this.protoText.length > 0 ? (this.protoText + ' · 外网与内网网关') : '外网与内网网关'
      });
      SettingRow({
        glyph: Glyph.LINK,
        title: '外网状态',
        subtitle: '拨号与链路',
        value: this.wanUp ? '已连接' : '未连接',
        valueSize: 0,
        first: true,
        danger: !this.wanUp,
        arrow: false,
        onTap: () => {
        }
      });
      SettingRow({
        glyph: Glyph.GLOBE,
        title: 'IPv4',
        subtitle: '运营商分配的地址 · 点开看完整',
        value: Fmt.maskAddr(this.ipv4),
        valueSize: 0,
        first: false,
        danger: false,
        arrow: true,
        onTap: () => {
          this.showAddr('外网 IPv4', this.ipv4);
        }
      });
      SettingRow({
        glyph: Glyph.GLOBE,
        title: 'IPv6',
        subtitle: '外网入口 · 点开看完整',
        value: Fmt.maskAddr(this.ipv6),
        valueSize: 12,
        first: false,
        danger: false,
        arrow: true,
        onTap: () => {
          this.showAddr('外网 IPv6', this.ipv6);
        }
      });
      SettingRow({
        glyph: Glyph.CHIP,
        title: '内网网关',
        subtitle: '设备默认走这个地址 · 点开看完整',
        value: Fmt.maskAddr(this.lanV4),
        valueSize: 0,
        first: false,
        danger: false,
        arrow: true,
        onTap: () => {
          this.showAddr('内网网关', this.lanV4);
        }
      });
      Note({ text: '外网访问走 IPv6，DNS 里配好 AAAA 记录就能用域名连回来。点地址那一行可以看完整地址并复制。' });
    }
  }

  @Builder
  powerCard() {
    // 只留 gapBottom：原来写的是 gapTop，结果上面和「系统维护」叠成两份间距、
    // 下面和「设备信息」一点空隙都没有
    Card({ gapBottom: T.GAP }) {
      Column() {
        CardTitle({ glyph: Glyph.POWER, title: '电源', sub: '重启与关机都会短暂断网' });
        this.powerRow(Glyph.REFRESH, '重启网络服务', '只重拨 WAN，局域网不掉线', 'restart_network');
        Hairline({ indent: 0 });
        this.powerRow(Glyph.REFRESH, '重启路由器', '整机重启，约一分钟', 'reboot');
        Hairline({ indent: 0 });
        this.powerRow(Glyph.POWER, '关机', '关机后只能按电源键开机', 'poweroff');
      }
      .width('100%');
    }
  }

  @Builder
  powerRow(glyph: string, title: string, sub: string, action: string) {
    Row({ space: 10 }) {
      Stack() {
        GlyphIcon({
          kind: glyph,
          color: action === 'poweroff' ? Pal.danger() : Pal.primary(),
          side: 17,
          lineWidth: 1.9
        });
      }
      .width(30)
      .height(30)
      .borderRadius(10)
      .backgroundColor(action === 'poweroff'
        ? Comp.alpha(Pal.danger(), 0.12)
        : $r('app.color.accent_soft'));

      Column() {
        Text(this.pendingPower === action ? '再点一次确认' : title)
          .fontSize(T.F_BODY)
          .fontColor(this.pendingPower === action
            ? $r('app.color.danger')
            : $r('app.color.text_primary'));
        Text(sub)
          .fontSize(T.F_TINY)
          .fontColor($r('app.color.text_tertiary'))
          .margin({ top: 2 });
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);

      Text(this.powerBusy && this.pendingPower === action ? '执行中…' : '›')
        .fontSize(this.powerBusy && this.pendingPower === action ? 12 : 18)
        .fontColor($r('app.color.text_tertiary'));
    }
    .width('100%')
    .padding({ top: 9, bottom: 9 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.doPower(action);
    });
  }

  private async doPower(action: string): Promise<void> {
    if (this.powerBusy) {
      return;
    }
    if (this.pendingPower !== action) {
      this.pendingPower = action;
      return;
    }
    this.powerBusy = true;
    const body: Record<string, Object> = { 'action': action, 'confirm': action };
    const r: ApiResult = await Api.post(this.ctx(), '/api/v1/power', body);
    this.powerBusy = false;
    this.pendingPower = '';
    this.toast = r.ok ? (action === 'poweroff' ? '正在关机' : '已重启')
      : ('失败：' + (r.error.length > 0 ? r.error : '未知错误'));
  }

  /**
   * 设备信息卡。三端统一成「三行概览 + 查看全部硬件」：
   * 概览页只回答「什么 CPU / 多大内存 / 多大的盘」，内存条、网卡、温度、PCI
   * 这些翻一次就够的内容挪进子页 —— 设置页里铺六行，往后加一项就要往下挪一屏。
   */
  @Builder
  hardwareCard() {
    RowCard({ gapBottom: T.GAP }) {
      CardTitle({ pad: 16, glyph: Glyph.CHIP, title: '设备信息', sub: '处理器、内存与系统盘' });
      // 长字符串一律放副标题（单行省略），右侧值只放短数字。
      // 之前型号放在值里，SettingRow 的值列最宽 50% 会折成两行，一行字变成两行高
      SettingRow({
        glyph: Glyph.CHIP,
        title: '处理器',
        subtitle: this.hwLoaded ? Fmt.orDash(this.hw.obj('cpu').str('model', '')) : '型号',
        value: this.hwLoaded
          ? this.hw.obj('cpu').num('cores', 0) + ' 核 ' + this.hw.obj('cpu').num('threads', 0) + ' 线程'
          : '—',
        valueSize: 0,
        first: true,
        danger: false,
        arrow: false,
        onTap: () => {
        }
      });
      SettingRow({
        glyph: Glyph.CHIP,
        title: '内存',
        subtitle: this.hwLoaded
          ? Fmt.bytes(this.hw.obj('memory').num('used', 0)) + ' / '
            + Fmt.bytes(this.hw.obj('memory').num('total', 0))
          : '',
        value: this.hwLoaded
          ? this.hw.obj('memory').num('percent', 0).toFixed(0) + '%' : '—',
        valueSize: 0,
        first: false,
        danger: false,
        arrow: false,
        onTap: () => {
        }
      });
      SettingRow({
        glyph: Glyph.BOX,
        title: '系统盘',
        subtitle: this.hw.arr('disks').length > 0
          ? Fmt.orDash(this.hw.arr('disks')[0].str('model', '')) + '　·　'
            + this.hw.arr('disks')[0].str('transport', '')
          : '',
        value: this.hw.arr('disks').length > 0
          ? this.hw.arr('disks')[0].str('size_text', '—') : '—',
        valueSize: 0,
        first: false,
        danger: false,
        arrow: false,
        onTap: () => {
        }
      });
      SettingRow({
        glyph: Glyph.LIST,
        title: '查看全部硬件',
        subtitle: '内存条、网卡、温度、PCI 设备',
        value: '',
        valueSize: 0,
        first: false,
        danger: false,
        arrow: true,
        onTap: () => {
          this.openSub('hardware');
        }
      });
    }
  }

  private async loadHardware(): Promise<void> {
    if (this.hwLoaded) {
      return;
    }
    const r: ApiResult = await Api.get(this.ctx(), '/api/v1/system/hardware');
    if (r.ok) {
      this.hw = r.data;
      this.hwLoaded = true;
    }
  }


  @Builder
  systemCard() {
    RowCard({ gapBottom: T.GAP }) {
      CardTitle({ pad: 16, glyph: Glyph.BOX, title: '系统维护', sub: '备份、固件与软件包' });
      // 备份排第一：它是后面所有危险操作的前提，放最下面用户往往是「改坏了」才想起来找它
      SettingRow({
        glyph: Glyph.BOX,
        title: '配置备份',
        subtitle: '动网络之前先存一份，随时能退回来',
        value: '',
        valueSize: 0,
        first: true,
        danger: false,
        arrow: true,
        onTap: () => {
          this.openSub('backup');
        }
      });
      SettingRow({
        glyph: Glyph.BOLT,
        title: '检查系统更新',
        subtitle: '查的是 iStoreOS 固件镜像',
        value: '',
        valueSize: 0,
        first: false,
        danger: false,
        arrow: true,
        onTap: () => {
          this.checkFirmware();
        }
      });
      SettingRow({
        glyph: Glyph.BOX,
        title: '检查软件包更新',
        subtitle: '查的是 opkg 软件包',
        value: '',
        valueSize: 0,
        first: false,
        danger: false,
        arrow: true,
        onTap: () => {
          this.checkPackages();
        }
      });
      SettingRow({
        glyph: Glyph.CLOCK,
        title: '查看升级进度',
        subtitle: '升级过程中的实时日志',
        value: '',
        valueSize: 0,
        first: false,
        danger: false,
        arrow: true,
        onTap: () => {
          this.showProgress();
        }
      });
      Note({ text: '「系统更新」和「软件包更新」是两条互不相干的链路，固件不动软件包，软件包也不动固件。' });
    }
  }

  @Builder
  securityCard() {
    RowCard({ gapBottom: T.GAP }) {
      CardTitle({ pad: 16, glyph: Glyph.SHIELD, title: '安全', sub: '两个密码，别记混' });
      SettingRow({
        glyph: Glyph.KEY,
        title: '修改 App 登录密码',
        subtitle: '只管这个 App',
        value: '',
        valueSize: 0,
        first: true,
        danger: false,
        arrow: true,
        onTap: () => {
          this.openPassword(SHEET_PWD_APP);
        }
      });
      SettingRow({
        // 这一行改的是 root 口令，和上面那行一样是「钥匙」语义；
        // 之前用的是电源图标，看着像要重启路由器
        glyph: Glyph.KEY,
        title: '修改路由器密码',
        subtitle: 'root 账号，影响后台与 SSH',
        value: '',
        valueSize: 0,
        first: false,
        danger: true,
        arrow: true,
        onTap: () => {
          this.openPassword(SHEET_PWD_ROOT);
        }
      });
      Note({ text: 'App 登录密码是给这个客户端用的；路由器密码是 root 账号，同时影响 iStoreOS 后台和 SSH 登录。' });
    }
  }

  /**
   * 关于 + 操作合成一张卡。
   *
   * 分成两张时「关于」只有图标和三行字，自己占一张卡很空；
   * 真正要点的几行（地址 / 主题 / 缓存 / 退出）反而被推到屏幕更下面。
   * 合起来之后顺序是：这是谁 → 连到哪（可改）→ 个性化 → 清缓存 → 退出。
   */
  @Builder
  aboutCard() {
    RowCard({ gapBottom: T.GAP }) {
      Row() {
        Image($r('app.media.app_icon'))
          .width(52)
          .height(52)
          .borderRadius(14)
          .margin({ right: 13 });
        Column() {
          Text('iStore Pilot')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'));
          // 版本号问系统要（AppScope/app.json5 的 versionName），不再写死
          Text('版本 ' + AppInfo.version() + ' · HarmonyOS')
            .fontSize(12.5)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: 4 });
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1);
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 2, bottom: 8 })
      .alignItems(VerticalAlign.Center);

      Text('iStoreOS 路由器的随身管理台：状态、设备、代理、拦截、硬件，一处看完，不用再开浏览器后台。')
        .fontSize(T.F_TINY)
        .lineHeight(18)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 10 });

      Hairline({ indent: 16 });

      SettingRow({
        glyph: Glyph.MOON,
        title: '主题',
        subtitle: '跟随系统或固定深浅色',
        value: this.themeName,
        valueSize: 0,
        first: true,
        danger: false,
        arrow: true,
        onTap: () => {
          this.pickTheme();
        }
      });
      SettingRow({
        glyph: Glyph.TRASH,
        title: '清缓存',
        subtitle: '只清手机上的快照，不动路由器',
        value: '',
        valueSize: 0,
        first: false,
        danger: false,
        arrow: true,
        onTap: () => {
          this.clearCache();
        }
      });
      SettingRow({
        glyph: Glyph.LOGOUT,
        title: '退出登录',
        subtitle: '清除凭证并返回登录页',
        value: '',
        valueSize: 0,
        first: false,
        danger: false,
        arrow: true,
        onTap: () => {
          this.relogin();
        }
      });
    }
  }

  private hostText(): string {
    let s: string = this.server;
    if (s.indexOf('http://') === 0) {
      s = s.substring(7);
    } else if (s.indexOf('https://') === 0) {
      s = s.substring(8);
    }
    return s.length > 0 ? s : '—';
  }

  // ================================================================ 动作

  private relogin(): void {
    const ctx = this.ctx();
    Session.signOut(ctx).then(() => {
      router.replaceUrl({ url: 'pages/LoginPage' });
    });
  }

  private clearCache(): void {
    Snap.clear(this.ctx()).then(() => {
      this.flash('本地快照已清除');
    });
  }

  private pickTheme(): void {
    this.openSheet(SHEET_THEME);
  }

  // ================================================================ 弹层

  private openSheet(kind: string): void {
    this.f1 = '';
    this.f2 = '';
    this.infoBody = '';
    this.busy = false;
    if (kind === SHEET_THEME) {
      this.sheetTitle = '外观';
    } else if (kind === SHEET_BASE) {
      this.sheetTitle = '服务器地址';
      this.f1 = this.hostText();
    } else if (kind === SHEET_PWD_APP) {
      this.sheetTitle = '修改 App 登录密码';
    } else if (kind === SHEET_PWD_ROOT) {
      this.sheetTitle = '修改路由器密码';
    } else if (kind === SHEET_ADDR) {
      this.sheetTitle = '完整地址';
    } else {
      this.sheetTitle = this.infoTitle;
    }
    this.sheet = kind;
  }

  private openPassword(kind: string): void {
    this.openSheet(kind);
  }

  private closeSheet(): void {
    this.sheet = '';
  }

  /** 地址弹窗：屏幕正中，宽度固定，长地址整段换行显示 */
  @Builder
  addrOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
        .onClick(() => {
          this.closeSheet();
        });

      Column() {
        Row() {
          Text(this.sheetTitle)
            .fontSize(T.F_H2)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
          Stack() {
            Stack() {
              GlyphIcon({ kind: Glyph.CLOSE, color: Pal.textSecondary(), side: 14, lineWidth: 2.1 });
            }
            .width(30)
            .height(30)
            .borderRadius(15)
            .backgroundColor($r('app.color.surface_hi'));
          }
          .width(44)
          .height(44)
          .onClick(() => {
            this.closeSheet();
          });
        }
        .width('100%')
        .alignItems(VerticalAlign.Center);

        Text(this.addrValue)
          .fontSize(16)
          .lineHeight(24)
          .fontColor($r('app.color.text_primary'))
          .fontFeature("\"tnum\" on")
          .wordBreak(WordBreak.BREAK_ALL)
          .width('100%')
          .copyOption(CopyOptions.LocalDevice)
          .margin({ top: 12 })
          .padding(14)
          .borderRadius(13)
          .backgroundColor($r('app.color.surface_hi'));

        Text('长按地址可以直接选中')
          .fontSize(T.F_TINY)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .margin({ top: 8 });

        Row({ space: 10 }) {
          Button('关闭')
            .type(ButtonType.Normal)
            .borderRadius(14)
            .height(44)
            .layoutWeight(1)
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .backgroundColor($r('app.color.surface_hi'))
            .onClick(() => {
              this.closeSheet();
            });
          Button('复制')
            .type(ButtonType.Normal)
            .borderRadius(14)
            .height(44)
            .layoutWeight(1)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.on_primary'))
            .backgroundColor($r('app.color.primary'))
            .onClick(() => {
              this.copyAddr();
            });
        }
        .width('100%')
        .margin({ top: 16 });
      }
      .width('86%')
      .constraintSize({ maxWidth: 420 })
      .alignItems(HorizontalAlign.Start)
      .padding(18)
      .borderRadius(20)
      .backgroundColor($r('app.color.surface'))
      .shadow({ radius: 24, color: '#33000000', offsetX: 0, offsetY: 8 });
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  sheetOverlay() {
    Column() {
      // 遮罩：点一下关掉，不用非得去够右上角的叉
      Column()
        .width('100%')
        .layoutWeight(1)
        .onClick(() => {
          this.closeSheet();
        });

      Column() {
        Row() {
          Text(this.sheetTitle)
            .fontSize(T.F_H2)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1);
          Stack() {
            Stack() {
              GlyphIcon({ kind: Glyph.CLOSE, color: Pal.textSecondary(), side: 14, lineWidth: 2.1 });
            }
            .width(30)
            .height(30)
            .borderRadius(15)
            .backgroundColor($r('app.color.surface_hi'));
          }
          .width(44)
          .height(44)
          .onClick(() => {
            this.closeSheet();
          });
        }
        .width('100%')
        .alignItems(VerticalAlign.Center);

        if (this.sheet === SHEET_THEME) {
          this.themeBody();
        } else if (this.sheet === SHEET_BASE) {
          this.baseBody();
        } else if (this.sheet === SHEET_PWD_APP || this.sheet === SHEET_PWD_ROOT) {
          this.pwdBody();
        } else {
          this.infoSheetBody();
        }

        if (this.sheet === SHEET_INFO) {
          Button('知道了')
            .type(ButtonType.Normal)
            .borderRadius(14)
            .height(44)
            .width('100%')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.on_primary'))
            .backgroundColor($r('app.color.primary'))
            .margin({ top: 18 })
            .onClick(() => {
              this.closeSheet();
            });
        } else {
          Row({ space: 10 }) {
            Button('取消')
              .type(ButtonType.Normal)
              .borderRadius(14)
              .height(44)
              .layoutWeight(1)
              .fontSize(15)
              .fontColor($r('app.color.text_primary'))
              .backgroundColor($r('app.color.surface_hi'))
              .onClick(() => {
                this.closeSheet();
              });
            Button(this.busy ? '处理中…' : '保存')
              .type(ButtonType.Normal)
              .borderRadius(14)
              .height(44)
              .layoutWeight(1)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.on_primary'))
              .backgroundColor($r('app.color.primary'))
              .enabled(!this.busy)
              .onClick(() => {
                this.submit();
              });
          }
          .width('100%')
          .margin({ top: 18 });
        }
      }
      .width('100%')
      .constraintSize({ maxWidth: 520 })
      .padding({ left: 20, right: 20, top: 18, bottom: 22 })
      .borderRadius({ topLeft: 26, topRight: 26 })
      .backgroundColor($r('app.color.surface'))
      .border({ width: 0.7, color: $r('app.color.glass_stroke') });
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#66000000');
  }

  @Builder
  themeBody() {
    Column({ space: 8 }) {
      ForEach(Appearance.NAMES, (name: string, i: number) => {
        Row() {
          Text(name)
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1);
          if (Appearance.current() === i) {
            GlyphIcon({ kind: Glyph.CHECK, color: Pal.primary(), side: 16, lineWidth: 2.2 });
          }
        }
        .width('100%')
        .height(46)
        .padding({ left: 14, right: 14 })
        .borderRadius(13)
        .backgroundColor(Appearance.current() === i
          ? $r('app.color.accent_soft')
          : $r('app.color.surface_hi'))
        .onClick(() => {
          this.applyTheme(i);
        });
      }, (name: string) => name);
    }
    .width('100%')
    .margin({ top: 14 });
  }

  @Builder
  baseBody() {
    Column() {
      Text('内网填路由器 IP，外网填 DDNS 域名。端口默认 8443')
        .fontSize(T.F_TINY)
        .fontColor($r('app.color.text_secondary'))
        .width('100%');
      TextInput({ text: this.f1, placeholder: '192.168.100.1:8443' })
        .height(46)
        .fontSize(15)
        .borderRadius(13)
        .backgroundColor($r('app.color.surface_hi'))
        .padding({ left: 13, right: 13 })
        .margin({ top: 10 })
        .onChange((v: string) => {
          this.f1 = v;
        });
    }
    .width('100%')
    .margin({ top: 14 });
  }

  @Builder
  pwdBody() {
    Column() {
      Text(this.sheet === SHEET_PWD_APP
        ? '新密码至少 8 位。修改后所有设备都需要重新登录。'
        : '这是 root 账号的密码，改完 iStoreOS 后台和 SSH 都用新密码登录。')
        .fontSize(T.F_TINY)
        .fontColor($r('app.color.text_secondary'))
        .width('100%');
      TextInput({ text: this.f1, placeholder: '当前密码' })
        .type(InputType.Password)
        .height(46)
        .fontSize(15)
        .borderRadius(13)
        .backgroundColor($r('app.color.surface_hi'))
        .padding({ left: 13, right: 13 })
        .margin({ top: 10 })
        .onChange((v: string) => {
          this.f1 = v;
        });
      TextInput({ text: this.f2, placeholder: '新密码（至少 8 位）' })
        .type(InputType.Password)
        .height(46)
        .fontSize(15)
        .borderRadius(13)
        .backgroundColor($r('app.color.surface_hi'))
        .padding({ left: 13, right: 13 })
        .margin({ top: 8 })
        .onChange((v: string) => {
          this.f2 = v;
        });
    }
    .width('100%')
    .margin({ top: 14 });
  }

  @Builder
  infoSheetBody() {
    Text(this.infoBody)
      .fontSize(13.5)
      .lineHeight(21)
      .fontColor($r('app.color.text_secondary'))
      .width('100%')
      .margin({ top: 12 });
  }

  /** 弹层里点「保存」：按 sheet 类型分发 */
  private submit(): void {
    if (this.busy) {
      return;
    }
    if (this.sheet === SHEET_THEME) {
      this.closeSheet();
      return;
    }
    if (this.sheet === SHEET_BASE) {
      const raw: string = this.f1.trim();
      if (raw.length === 0) {
        this.flash('地址不能为空');
        return;
      }
      let base: string = raw;
      if (base.indexOf('http://') !== 0 && base.indexOf('https://') !== 0) {
        base = 'http://' + base;
      }
      const ctx = this.ctx();
      Session.setBase(ctx, base).then(() => {
        this.server = base;
        this.closeSheet();
        this.flash('地址已更新');
        this.load();
      });
      return;
    }
    // 改密码：两个分支都要求新密码 ≥ 8 位，长度校验放前端只是为了少跑一趟
    if (this.f2.length < 8) {
      this.flash('新密码至少 8 位');
      return;
    }
    if (this.sheet === SHEET_PWD_APP) {
      this.submitAppPassword();
    } else {
      this.submitRootPassword();
    }
  }

  private applyTheme(mode: number): void {
    this.closeSheet();
    this.themeName = Appearance.NAMES[mode];
    Appearance.select(this.ctx(), mode);
  }

  private async submitAppPassword(): Promise<void> {
    this.busy = true;
    const ctx = this.ctx();
    const body: Record<string, Object> = { 'current': this.f1, 'new': this.f2 };
    const r: ApiResult = await Api.post(ctx, '/api/v1/password', body);
    this.busy = false;
    if (!r.ok) {
      this.flash(r.error.length > 0 ? r.error : '修改失败');
      return;
    }
    if (!r.data.bool('ok', false)) {
      this.flash(r.data.str('error', '修改失败'));
      return;
    }
    this.closeSheet();
    this.flash('密码已修改，请重新登录');
    // 令牌跟着旧密码一起失效，直接回登录页比留在这里看 401 友好
    await Session.signOut(ctx);
    router.replaceUrl({ url: 'pages/LoginPage' });
  }

  private async submitRootPassword(): Promise<void> {
    this.busy = true;
    const ctx = this.ctx();
    const body: Record<string, Object> = { 'current': this.f1, 'new': this.f2 };
    const r: ApiResult = await Api.post(ctx, '/api/v1/system/root_password', body);
    this.busy = false;
    const ok: boolean = r.ok && r.data.bool('ok', false);
    this.infoTitle = ok ? '已修改' : '修改失败';
    this.infoBody = ok
      ? r.data.str('note', '路由器密码已更新。')
      : (r.data.str('error', '') || r.error || '路由器没有接受这次修改');
    this.sheet = SHEET_INFO;
    this.sheetTitle = this.infoTitle;
  }

  // ================================================================ 系统维护

  private async checkFirmware(): Promise<void> {
    const ctx = this.ctx();
    this.infoTitle = '正在检查固件';
    this.infoBody = '正在向 iStoreOS 更新服务器查询最新固件…';
    this.sheet = SHEET_INFO;
    this.sheetTitle = this.infoTitle;

    const r: ApiResult = await Api.getFresh(ctx, '/api/v1/system/firmware');
    if (!r.ok) {
      this.infoTitle = '检查失败';
      this.infoBody = (r.error.length > 0 ? r.error : '读取更新服务器失败') +
        '\n\n这一步要路由器能访问 fw.koolcenter.com，和 opkg 软件源无关。';
      this.sheetTitle = this.infoTitle;
      return;
    }
    const state: string = r.data.str('state', '');
    const cur: string = r.data.str('current', '—');
    const latest: string = r.data.str('latest', '—');
    const okState: boolean = r.data.bool('ok', false);

    if (!okState) {
      this.infoTitle = '检查失败';
      this.infoBody = r.data.str('error', '读取更新服务器失败') + '\n\n当前 ' + cur;
      this.sheetTitle = this.infoTitle;
      return;
    }
    if (state === 'busy') {
      this.infoTitle = '有固件任务在跑';
      this.infoBody = '路由器上已经有固件下载任务，等它结束再检查。\n\n当前 ' + cur;
      this.sheetTitle = this.infoTitle;
      return;
    }
    if (!r.data.bool('has_update', false)) {
      this.infoTitle = '固件已是最新';
      this.infoBody = '当前版本 ' + cur + '\n\n没有可升级的固件。';
      this.sheetTitle = this.infoTitle;
      return;
    }

    let sb: string = '当前  ' + cur + '\n最新  ' + latest;
    const image: string = r.data.str('image', '');
    if (image.length > 0) {
      sb += '\n\n镜像  ' + image;
    }
    sb += '\n\n升级入口：iStoreOS 后台 → 系统 → OTA。';
    sb += '\n刷固件会重启路由器，中途断电有变砖风险，所以不在 App 里代跑。';
    const log: string = r.data.str('changelog', '');
    if (log.length > 0) {
      sb += '\n\n————\n' + (log.length > 700 ? log.substring(0, 700) + '…' : log);
    }
    this.infoTitle = '发现新固件';
    this.infoBody = sb;
    this.sheetTitle = this.infoTitle;
  }

  private async checkPackages(): Promise<void> {
    const ctx = this.ctx();
    this.infoTitle = '正在检查软件包';
    this.infoBody = '正在读取已安装软件包与本地索引…';
    this.sheet = SHEET_INFO;
    this.sheetTitle = this.infoTitle;

    // refresh=false：只读现有索引，秒回；拉索引留给真正的升级动作
    const body: Record<string, Object> = { 'action': 'check', 'refresh': false };
    const r: ApiResult = await Api.post(ctx, '/api/v1/system/update', body);
    if (!r.ok || !r.data.bool('ok', false)) {
      this.infoTitle = '检查失败';
      this.infoBody = r.data.str('error', r.error.length > 0 ? r.error : '读取软件源失败，稍后再试。');
      this.sheetTitle = this.infoTitle;
      return;
    }
    const pkgs: J[] = r.data.arr('packages');
    if (pkgs.length === 0) {
      this.infoTitle = '软件包已是最新';
      this.infoBody = '系统 iStoreOS ' + r.data.obj('firmware').str('version', '') +
        ' 上装的软件包全部是最新版。\n\n想要固件本体升级，用上面的「检查系统更新」。';
      this.sheetTitle = this.infoTitle;
      return;
    }
    let sb: string = '共 ' + pkgs.length + ' 个软件包可以升级：\n\n';
    const show: number = Math.min(pkgs.length, 10);
    for (let i = 0; i < show; i++) {
      sb += '· ' + pkgs[i].str('name', '') + '\n  ' +
        pkgs[i].str('current', '') + ' → ' + pkgs[i].str('latest', '') + '\n';
    }
    if (pkgs.length > show) {
      sb += '… 还有 ' + (pkgs.length - show) + ' 个\n';
    }
    sb += '\n升级在路由器后台跑，中途不要断电，会断网一两分钟。';
    this.infoTitle = '发现 ' + pkgs.length + ' 个可升级';
    this.infoBody = sb;
    this.sheetTitle = this.infoTitle;
  }

  private async showProgress(): Promise<void> {
    const ctx = this.ctx();
    this.infoTitle = '升级进度';
    this.infoBody = '正在读取…';
    this.sheet = SHEET_INFO;
    this.sheetTitle = this.infoTitle;

    const r: ApiResult = await Api.getFresh(ctx, '/api/v1/system/update');
    if (!r.ok) {
      this.infoBody = r.error.length > 0 ? r.error : '读不到升级状态';
      return;
    }
    const running: boolean = r.data.bool('running', false);
    const log: string = r.data.str('log', '');
    this.infoTitle = running ? '正在升级' : '升级日志';
    this.sheetTitle = this.infoTitle;
    this.infoBody = (running ? '后台任务还在跑…\n\n' : '') +
      (log.length > 0 ? log : '还没有升级记录。');
  }
}

/**
 * hero 底部的一格读数。用 @Component 而不是 @Builder —— ArkUI 里 @Builder
 * 按值传参时状态变化不会刷新，页面上会一直停在初始值。
 */
@ComponentV2
struct HeroStat {
  @Param label: string = '';
  @Param value: string = '';

  build() {
    Column() {
      Text(this.label)
        .fontSize(11)
        .fontColor($r('app.color.hero_fg_soft'));
      Text(this.value)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.hero_fg'))
        .fontFeature("\"tnum\" on")
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 3 });
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .layoutWeight(1);
  }
}
