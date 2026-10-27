import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { Api, ApiResult } from '../../api/Api';
import { J } from '../../core/Json';
import { Fmt } from '../../util/Fmt';
import { Pal, T } from '../Theme';
import { Bp } from '../Breakpoint';
import { Card, CardHeader, Comp, Kv } from '../Comp';

/**
 * 网络：这台路由器「怎么上网、内网怎么分、谁能进来」。
 *
 * 以前这些信息是散着的 —— 宽带塞在概览页的 WAN 卡里，
 * LAN 哪都没有，防火墙只能去网页端看。
 * 但「我家网段是多少、DHCP 发到哪、外面能不能直接连进来」，
 * 恰恰是路由器管理 App 最该回答的问题。
 *
 * 三块对应三个决策层级：宽带（可改）、局域网（只读）、防火墙（只读）。
 * 只读不是偷懒：LAN 一改，手机到路由器的连接立刻失效，
 * 用户看到的是「App 崩了」而不是「配置生效了请注意重连」。
 */
@Component
export struct NetworkPage {
  /** 作为二级页打开时显示返回箭头（底部四个页签里没有它了） */
  @Prop showBack: boolean = false;

  @State loaded: boolean = false;
  @State err: string = '';

  // WAN
  @State wanUp: boolean = false;
  @State wanNote: string = '';
  @State wanIp: string = '';
  @State proto: string = '';
  @State gateway: string = '';
  @State uptime: number = 0;
  @State dns: string = '';
  @State account: string = '';

  // LAN
  @State lanCidr: string = '';
  @State lanHosts: number = 0;
  @State lanDhcp: boolean = true;
  @State lanPool: string = '';
  @State lanLeases: number = 0;
  @State lanLease: string = '';
  @State lanV6: string = '';

  // 防火墙
  @State fwDefault: string = '';
  @State fwWanIn: string = '';
  @State fwLanIn: string = '';
  @State fwRules: number = 0;
  @State fwRedirects: number = 0;
  @State fwRisks: string[] = [];
  @State fwOld: boolean = false;

  /** 待确认事务：改完配置后不回来点确认，服务端 60 秒自动回滚 */
  @State pendOn: boolean = false;
  @State pendNote: string = '';
  @State pendLeft: number = 0;
  @State pendToken: string = '';
  @State pendExpired: boolean = false;

  @State acting: boolean = false;
  @State actNote: string = '重拨只重建链路，不改配置；断开后点「连接」即可恢复。';

  @State winW: number = 360;
  @StorageProp('winW') @Watch('onWidth') winWStore: number = 360;
  @StorageProp('tab') @Watch('onTab') tab: number = 1;

  private timer: number = -1;

  aboutToAppear(): void {
    this.winW = this.winWStore;
    this.load(true);
    // 作为二级页时它是当前页面，直接开始轮询；不再看 tab 是谁
    this.startPoll();
  }

  aboutToDisappear(): void {
    this.stopPoll();
  }

  private onWidth(): void {
    this.winW = this.winWStore;
  }

  private onTab(): void {
    if (this.tab === 1) {
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
    // 拨号状态和租约变化都慢，8 秒够了；轮询太快反而让 hero 的数字在闪
    this.timer = setInterval(() => {
      this.load(false);
    }, 8000);
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
      const c: ApiResult = await Api.peek(ctx, '/api/v1/network/wan');
      if (c.ok) {
        this.applyWan(c.data);
      }
    }
    const r: ApiResult = await Api.get(ctx, '/api/v1/network/wan');
    if (r.ok) {
      this.applyWan(r.data);
      this.loaded = true;
      this.err = '';
    } else {
      this.err = r.error;
      this.loaded = true;
    }

    const f: ApiResult = await Api.get(ctx, '/api/v1/network/firewall');
    if (f.ok) {
      this.applyFw(f.data);
    } else {
      this.fwOld = true;
    }

    // 待确认状态：老版本 Agent 没有这个接口，失败就当没有
    const p: ApiResult = await Api.get(ctx, '/api/v1/net/pending');
    if (p.ok) {
      this.pendOn = p.data.bool('pending', false);
      this.pendNote = p.data.str('note', '');
      this.pendLeft = p.data.num('left', 0);
      this.pendToken = p.data.str('token', '');
      this.pendExpired = p.data.bool('expired', false);
    } else {
      this.pendOn = false;
    }
  }

  private applyWan(b: J): void {
    const st: J = b.obj('status');
    const cfg: J = b.obj('config');
    this.wanUp = st.bool('up', false);
    this.wanNote = st.str('note', '');
    this.wanIp = st.str('ipv4', '');
    this.proto = cfg.str('proto_label', '');
    this.account = cfg.str('username', '');
    this.gateway = st.str('gateway', '');
    this.uptime = st.num('uptime', 0);

    const parts: string[] = st.strs('dns');
    this.dns = parts.slice(0, 3).join('  ');

    const lan: J = b.obj('lan');
    this.lanCidr = lan.str('cidr', '');
    this.lanHosts = lan.num('hosts', 0);
    this.lanDhcp = lan.bool('dhcp_enabled', true);
    this.lanPool = lan.str('dhcp_pool', '');
    this.lanLeases = lan.num('dhcp_leases', 0);
    this.lanLease = lan.str('dhcp_lease', '');
    this.lanV6 = lan.str('ipv6_prefix', '');
  }

  private applyFw(b: J): void {
    this.fwOld = false;
    const def: J = b.obj('defaults');
    this.fwDefault = this.label(def.str('input', ''));
    this.fwRules = b.num('rules', 0);
    this.fwRedirects = b.num('redirects', 0);

    const zones: J[] = b.arr('zones');
    for (let i = 0; i < zones.length; i++) {
      const z: J = zones[i];
      const name: string = z.str('name', '');
      if (name === 'wan') {
        this.fwWanIn = this.label(z.str('input', ''));
      } else if (name === 'lan') {
        this.fwLanIn = this.label(z.str('input', ''));
      }
    }

    this.fwRisks = b.strs('risks');

  }

  /** uci 的 ACCEPT / DROP / REJECT 翻成人话 */
  private label(v: string): string {
    if (v === 'ACCEPT') {
      return '允许全部';
    }
    if (v === 'REJECT') {
      return '拒绝并回包';
    }
    if (v === 'DROP') {
      return '静默丢弃';
    }
    return v.length > 0 ? v : '—';
  }

  private subLine(): string {
    const parts: string[] = [];
    if (this.gateway.length > 0) {
      parts.push('网关 ' + this.gateway);
    }
    if (this.uptime > 0) {
      parts.push('已连接 ' + Fmt.dur(this.uptime));
    }
    return parts.length > 0 ? parts.join('  ·  ') : '—';
  }

  // ---------------------------------------------------------------- 视图

  @Builder
  heroCard() {
    Column() {
      Row() {
        Row()
          .width(7)
          .height(7)
          .borderRadius(4)
          .backgroundColor(this.wanUp ? $r('app.color.hero_fg') : Color.Transparent)
          .border({
            width: this.wanUp ? 0 : 1.6,
            color: $r('app.color.hero_fg')
          })
          .margin({ right: 7 });

        Text(this.wanUp ? '已拨通' : (this.wanNote.length > 0 ? this.wanNote : '未连接'))
          .fontSize(12.5)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.hero_fg'))
          .layoutWeight(1);

        Text(this.proto.length > 0 ? this.proto : '未配置')
          .fontSize(11)
          .fontColor($r('app.color.hero_fg'))
          .opacity(0.86)
          .padding({ left: 9, right: 9, top: 4, bottom: 4 })
          .borderRadius(T.R_PILL)
          .backgroundColor(Comp.alpha('#FFFFFF', 0.16));
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      Text(this.wanIp.length > 0 ? this.wanIp : '—')
        .fontSize(this.rail() ? 30 : 27)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.hero_fg'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 12 });

      Text(this.subLine())
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

  /** 重拨 / 断开：不动配置，所以不需要回滚那套吓唬话 */
  @Builder
  actionCard() {
    Card() {
      CardHeader({ title: '连接操作', sub: '只动链路，不改配置' });
      Row({ space: 10 }) {
        Button(this.acting ? '执行中…' : '重拨')
          .layoutWeight(1)
          .height(38)
          .fontSize(T.F_BODY)
          .fontColor($r('app.color.on_primary'))
          .backgroundColor($r('app.color.primary'))
          .borderRadius(19)
          .enabled(!this.acting)
          .onClick(() => this.askAction('reconnect'));

        Button(this.wanUp ? '断开' : '连接')
          .layoutWeight(1)
          .height(38)
          .fontSize(T.F_BODY)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.surface_sunken'))
          .borderRadius(19)
          .enabled(!this.acting)
          .onClick(() => this.askAction(this.wanUp ? 'down' : 'up'));
      }
      .width('100%');

      Text(this.actNote)
        .fontSize(T.F_TINY)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ top: 10 });
    }
  }

  private askAction(action: string): void {
    let title: string = '重拨？';
    let msg: string = 'PPPoE 会重新协商，全家断网 10-30 秒。不改配置，失败也不会丢宽带账号。';
    if (action === 'down') {
      title = '断开 WAN？';
      msg = '断开后全家立刻上不了网，点「连接」可恢复。这个操作不改配置。';
    } else if (action === 'up') {
      title = '重新连接？';
      msg = '向上级设备请求地址，通常 5-10 秒恢复。';
    }
    this.getUIContext().showAlertDialog({
      title: title,
      message: msg,
      primaryButton: {
        value: '确定',
        fontColor: Pal.primary(),
        action: () => {
          this.doAction(action);
        }
      },
      secondaryButton: {
        value: '取消',
        fontColor: Pal.textSecondary(),
        action: () => {
        }
      }
    });
  }

  private async doAction(action: string): Promise<void> {
    this.acting = true;
    this.actNote = action === 'down' ? '正在断开…' : '正在重拨…';
    const r: ApiResult = await Api.post(this.ctx(), '/api/v1/net/wan/action', { action: action });
    this.acting = false;
    if (r.ok && r.data.bool('ok')) {
      this.actNote = r.data.str('detail', '已发出指令');
      // 拨号要 10-30 秒，页面的定时轮询会把状态带回来，这里只补一句进度
      if (action !== 'down') {
        this.actNote = '正在重拨，等 10-30 秒看上面的状态。';
      }
      this.load(false);
    } else {
      this.actNote = '操作失败：' + (r.ok ? r.data.str('error', '路由器没有回应') : '网络不通');
    }
  }

  @Builder
  kvRow(label: string, value: string) {
    Kv({ label: label, value: value, valueSize: T.F_BODY, accent: false });
  }

  @Builder
  wanCardBody() {
    Column() {
      this.kvRow('接入方式', this.proto.length > 0 ? this.proto : '—');
      if (this.account.length > 0) {
        this.kvRow('账号', this.account);
      }
      this.kvRow('地址获取', this.wanIp.length > 0 ? '自动下发' : '未获取');
      this.kvRow('DNS', this.dns.length > 0 ? this.dns : '—');
    }
    .width('100%');
  }

  @Builder
  lanCardBody() {
    Column() {
      this.kvRow('管理地址', this.lanCidr.length > 0 ? this.lanCidr : '—');
      if (this.lanHosts > 0) {
        this.kvRow('可用地址', this.lanHosts + ' 个');
      }
      this.kvRow('DHCP 服务', this.lanDhcp ? '已开启' : '已关闭，设备需手动配置');
      if (this.lanDhcp && this.lanPool.length > 0) {
        this.kvRow('地址池', this.lanPool);
      }
      if (this.lanDhcp) {
        this.kvRow('已分配租约', this.lanLeases + ' 个'
          + (this.lanLease.length > 0 ? '  ·  租期 ' + this.lanLease : ''));
      }
      if (this.lanV6.length > 0) {
        this.kvRow('IPv6 前缀', this.lanV6);
      }
    }
    .width('100%');
  }

  @Builder
  fwCardBody() {
    Column() {
      if (this.fwOld) {
        Text('Agent 版本过旧，未提供防火墙摘要')
          .fontSize(T.F_SUB)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .padding({ top: 6, bottom: 6 });
      } else {
        if (this.fwDefault.length > 0) {
          this.kvRow('默认入站', this.fwDefault);
        }
        if (this.fwLanIn.length > 0) {
          this.kvRow('LAN 入站', this.fwLanIn);
        }
        if (this.fwWanIn.length > 0) {
          this.kvRow('WAN 入站', this.fwWanIn);
        }
        this.kvRow('转发规则', this.fwRules + ' 条');
        if (this.fwRedirects > 0) {
          this.kvRow('端口转发', this.fwRedirects + ' 条');
        }
      }

      if (this.fwRisks.length > 0) {
        Column() {
          ForEach(this.fwRisks, (r: string) => {
            Text('⚠ ' + r)
              .fontSize(T.F_SUB)
              .fontColor($r('app.color.warn'))
              .width('100%')
              .padding({ left: 12, right: 12, top: 9, bottom: 9 })
              .borderRadius(T.R_INNER)
              .backgroundColor(Comp.alpha('#FF9500', 0.12))
              .margin({ top: 6 });
          }, (r: string) => r);
        }
        .width('100%')
        .margin({ top: 4, bottom: 6 });
      }

    }
    .width('100%');
  }

  /** 待确认横幅：改完网络配置后，还差用户一句「没问题」 */
  @Builder
  pendingCard() {
    // Card 是自定义组件，后面不能再链 .margin() —— 通用属性只能写在容器上，
    // 所以这里套一层 Column 专门承载间距
    Column() {
      Card() {
      Row() {
        Text('⚠')
          .fontSize(T.F_SUB)
          .fontColor($r('app.color.warn'));
        Text(this.pendExpired ? '正在还原改动…'
          : (this.pendNote.length > 0 ? this.pendNote : '改动等待确认'))
          .fontSize(T.F_BODY)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: 6 })
          .layoutWeight(1);
        Text(this.pendExpired ? '请稍候' : (this.pendLeft + ' 秒'))
          .fontSize(T.F_SUB)
          .fontColor($r('app.color.warn'));
      }
      .width('100%');

      Text('能连上就说明没问题。不点确认的话，时间一到路由器会自己还原。')
        .fontSize(T.F_TINY)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ top: 5 });

      Row({ space: 10 }) {
        Text('撤销改动')
          .fontSize(T.F_SUB)
          .fontColor($r('app.color.text_secondary'))
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .padding({ top: 11, bottom: 11 })
          .borderRadius(T.R_PILL)
          .backgroundColor($r('app.color.surface_sunken'))
          .onClick(() => {
            this.doRollback();
          });
        Text('确认，一切正常')
          .fontSize(T.F_SUB)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_primary'))
          .textAlign(TextAlign.Center)
          .layoutWeight(1.4)
          .padding({ top: 11, bottom: 11 })
          .borderRadius(T.R_PILL)
          .backgroundColor($r('app.color.primary'))
          .onClick(() => {
            this.doConfirm();
          });
      }
      .width('100%')
      .margin({ top: 12 });
      }
    }
    .width('100%')
    .margin({ bottom: T.GAP });
  }

  // ---------------------------------------------------------------- 动作

  private async doConfirm(): Promise<void> {
    if (this.pendToken.length === 0) {
      return;
    }
    const r: ApiResult = await Api.post(this.ctx(), '/api/v1/net/confirm',
      { 'token': this.pendToken } as Record<string, Object>);
    if (!r.ok) {
      await this.toast(r.error);
      return;
    }
    this.pendOn = false;
    await this.toast('已确认，配置保留');
    await this.load(false);
  }

  private async doRollback(): Promise<void> {
    if (this.pendToken.length === 0) {
      return;
    }
    const r: ApiResult = await Api.post(this.ctx(), '/api/v1/net/rollback',
      { 'token': this.pendToken } as Record<string, Object>);
    if (!r.ok) {
      await this.toast(r.error);
      return;
    }
    this.pendOn = false;
    await this.toast('已还原');
    await this.load(false);
  }

  private async toast(msg: string): Promise<void> {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2200 });
  }

  @Builder
  pageBody() {
    Column({ space: T.GAP }) {
      if (this.pendOn) {
        this.pendingCard();
      }
      this.heroCard();
      this.actionCard();

      if (this.err.length > 0) {
        Text('读取失败：' + this.err)
          .fontSize(T.F_SUB)
          .fontColor($r('app.color.danger'))
          .width('100%');
      }

      Card() {
        CardHeader({ title: '宽带接入', sub: '对外那一根线' });
        this.wanCardBody();
        Row() {
          Text('保存会重新拨号，期间全网断约 10 秒')
            .fontSize(T.F_TINY)
            .fontColor($r('app.color.text_tertiary'))
            .layoutWeight(1);
        }
        .width('100%')
        .padding({ top: 6 });
      }

      Card() {
        CardHeader({ title: '局域网', sub: '内网网段与 DHCP' });
        this.lanCardBody();
        Text('修改 LAN 网段会导致 App 立即失联，请在路由器网页端操作')
          .fontSize(T.F_TINY)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')
          .margin({ top: 8 });
      }

      Card() {
        CardHeader({ title: '防火墙', sub: '谁能从外面进来' });
        this.fwCardBody();
      }
    }
    .width('100%');
  }

  build() {
    Scroll() {
      Column() {
        Row({ space: 8 }) {
          if (this.showBack) {
            Text('‹')
              .fontSize(26)
              .fontColor($r('app.color.text_primary'))
              .width(32)
              .textAlign(TextAlign.Center)
              .onClick(() => router.back());
          }
          Text('网络')
            .fontSize(T.F_TITLE)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1);
          Text(this.wanUp ? '外网已连接' : '外网未连接')
            .fontSize(T.F_TINY)
            .fontColor(this.wanUp ? $r('app.color.text_secondary') : $r('app.color.warn'));
        }
        .width('100%')
        .alignItems(VerticalAlign.Bottom)
        .padding({ bottom: 10 });

        if (this.rail()) {
          // Pad：左边「线路」，右边「内网与边界」，一屏放完不用滚
          Row({ space: T.GAP }) {
            Column({ space: T.GAP }) {
              this.heroCard();
              this.actionCard();
              Card() {
                CardHeader({ title: '宽带接入', sub: '对外那一根线' });
                this.wanCardBody();
              }
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start);

            Column({ space: T.GAP }) {
              Card() {
                CardHeader({ title: '局域网', sub: '内网网段与 DHCP' });
                this.lanCardBody();
              }
              Card() {
                CardHeader({ title: '防火墙', sub: '谁能从外面进来' });
                this.fwCardBody();
              }
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start);
          }
          .width('100%')
          .alignItems(VerticalAlign.Top);
        } else {
          this.pageBody();
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
