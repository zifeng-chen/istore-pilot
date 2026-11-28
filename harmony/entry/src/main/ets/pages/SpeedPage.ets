import { display, router, window } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { Api, ApiResult } from '../api/Api';
import { J } from '../core/Json';
import { UI } from '../core/UIState';
import { Pal, T } from '../ui/Theme';
import { Card, CardTitle, GlyphIcon, Hairline, Note } from '../ui/Comp';
import { Glyph } from '../ui/comp/Icons';

/** 一次历史记录 */
interface SpeedRow {
  time: number;
  ping: number;
  down: number;
  up: number;
  server: string;
}

/** 可选的 Ookla 节点 */
interface Srv {
  id: string;
  name: string;
  isp: string;
}

/**
 * 网络测速。
 *
 * 一张卡搞定「选节点 + 开始 + 进度 + 结果」：之前拆成三张卡，点一下测速，
 * 节点卡、进度卡、结果卡同时出现，屏幕上全是框，用户以为按错了。
 * 现在同一张卡里切换内容，卡片总数始终不变。
 *
 * 实时数值来自 agent 侧对 WAN 网口字节数的采样 —— FastNet 的 SSE 只在每段
 * 结束时给一个最终值，中间过程是黑的，只能自己算瞬时速率。
 */
@Entry
@ComponentV2
struct SpeedPage {
  @Local state: string = 'unknown';
  @Local stage: string = '';
  @Local msg: string = '';
  @Local running: boolean = false;
  @Local ping: number = 0;
  @Local down: number = 0;
  @Local up: number = 0;
  @Local liveDown: number = 0;
  @Local liveUp: number = 0;
  @Local server: string = '';
  @Local err: string = '';
  @Local installing: boolean = false;
  @Local installMsg: string = '';
  @Local rows: SpeedRow[] = [];
  @Local servers: Srv[] = [];
  @Local serverId: string = '';
  @Local picking: boolean = false;
  @Local elapsed: number = 0;
  /** 状态栏高度（vp）。这里自己量一次：只依赖 UI.safeTop 时，
   *  冷启动/子窗口场景拿到的可能是 0，标题就会顶进状态栏 */
  @Local topPad: number = 24;
  /** 服务端时间戳：和上一条相同说明响应被中间层缓存了 */
  @Local dataTs: number = 0;
  @Local staleHint: boolean = false;
  @Local timer: number = -1;
  @Local clock: number = -1;

  aboutToAppear(): void {
    this.measureTop();
    this.refresh();
    this.loadHistory();
    this.loadServers();
  }

  aboutToDisappear(): void {
    this.stopTimer();
    // 二级页是 router 页，返回时不会走 Shell.leave，
    // 这里手动敲一下 backTick，让概览页立刻刷新测速卡
    UI.backTick += 1;
  }

  private async measureTop(): Promise<void> {
    try {
      const win = await window.getLastWindow(this.ctx());
      const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const d: number = display.getDefaultDisplaySync().densityPixels;
      const h: number = d > 0 ? sys.topRect.height / d : 0;
      const pad: number = (h > 0 ? h : UI.safeTop) + 2;
      if (pad > 0) {
        this.topPad = pad;
      }
    } catch (e) {
      this.topPad = UI.safeTop > 0 ? UI.safeTop + 2 : 48;
    }
  }

  private ctx(): Context {
    return this.getUIContext().getHostContext() as Context;
  }

  private body(extra: Record<string, Object>): Record<string, Object> {
    return extra;
  }

  private stopTimer(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    if (this.clock >= 0) {
      clearInterval(this.clock);
      this.clock = -1;
    }
  }

  private tick(): void {
    if (this.timer < 0) {
      this.timer = setInterval(() => {
        this.refresh();
      }, 1000);
    }
    if (this.clock < 0) {
      this.clock = setInterval(() => {
        if (this.running) {
          this.elapsed += 1;
        }
      }, 1000);
    }
  }

  async refresh(): Promise<void> {
    try {
      await this.doRefresh();
    } catch (e) {
      // 之前这里不兜异常：轮询里一旦抛出，定时器继续跑但数据永远停在旧值，
      // 页面上只看到秒表在跳、数字不动。现在把原因显示出来
      this.err = '状态读取异常：' + (e === undefined ? '未知' : String(e)).slice(0, 80);
      this.stopTimer();
    }
  }

  private async doRefresh(): Promise<void> {
    const r: ApiResult = await Api.getFresh(this.ctx(), '/api/v1/speedtest/status?t=' + Date.now().toString());
    if (!r.ok) {
      this.err = r.data.str('error', '读取失败');
      this.stopTimer();
      return;
    }
    this.err = '';
    const wasRunning: boolean = this.running;
    const newTs: number = r.data.num('ts', 0);
    if (newTs > 0) {
      this.staleHint = wasRunning && newTs === this.dataTs;
      this.dataTs = newTs;
    }
    this.state = r.data.str('state', 'unknown');
    this.running = r.data.bool('running', false);
    const st: string = r.data.str('stage', '');
    if (st.length > 0) {
      this.stage = st;
    }
    const mg: string = r.data.str('msg', '');
    if (mg.length > 0) {
      this.msg = mg;
    }
    // 数值只在拿到正数时覆盖：接口偶尔先回 0（上一轮清零或刚启动），
    // 直接用会把界面上已有的结果擦成「—」
    const p: number = r.data.num('ping', 0);
    const d: number = r.data.num('down', 0);
    const u: number = r.data.num('up', 0);
    if (p > 0) {
      this.ping = p;
    }
    if (d > 0) {
      this.down = d;
    }
    if (u > 0) {
      this.up = u;
    }
    const ld: number = r.data.num('liveDown', 0);
    const lu: number = r.data.num('liveUp', 0);
    this.liveDown = this.running ? ld : 0;
    this.liveUp = this.running ? lu : 0;
    const sv: string = r.data.str('server', '');
    if (sv.length > 0) {
      this.server = sv;
    }
    if (this.running && !wasRunning) {
      this.elapsed = r.data.num('elapsed', 0);
    }
    const inst: J = r.data.obj('install');
    this.installing = inst.has('state')
      && (inst.str('state', '') === 'installing' || inst.str('state', '') === 'starting');
    if (inst.has('state')) {
      this.installMsg = inst.str('msg', '');
      if (inst.str('state', '') === 'failed') {
        this.installing = false;
        this.installMsg = inst.str('msg', '安装失败');
      }
    }
    if (this.running || this.installing) {
      this.tick();
    } else {
      this.stopTimer();
      if (wasRunning) {
        this.loadHistory();
      }
      // 结果卡以历史为准：/status 的数值偶发取不到，但历史列表一直是对的
      if (this.rows.length > 0) {
        this.applyRow(this.rows[0]);
      }
    }
  }

  /** 用一条历史记录填充「最近一次结果」 */
  private applyRow(r: SpeedRow): void {
    if (r.ping > 0) {
      this.ping = r.ping;
    }
    if (r.down > 0) {
      this.down = r.down;
    }
    if (r.up > 0) {
      this.up = r.up;
    }
    if (r.server.length > 0 && this.server.length === 0) {
      this.server = r.server;
    }
  }

  async loadHistory(): Promise<void> {
    const r: ApiResult = await Api.getFresh(this.ctx(), '/api/v1/speedtest/history?t=' + Date.now().toString());
    if (!r.ok) {
      return;
    }
    const arr: SpeedRow[] = [];
    r.data.arr('rows').forEach((it: J) => {
      arr.push({
        time: it.num('time', 0),
        ping: it.num('ping', 0),
        down: it.num('down', 0),
        up: it.num('up', 0),
        server: it.str('server', '')
      });
    });
    this.rows = arr;
    if (arr.length > 0) {
      this.applyRow(arr[0]);
    }
  }

  async loadServers(): Promise<void> {
    const r: ApiResult = await Api.getFresh(this.ctx(), '/api/v1/speedtest/servers');
    if (!r.ok) {
      return;
    }
    const arr: Srv[] = [];
    r.data.arr('servers').forEach((it: J) => {
      const name: string = it.str('name', '');
      if (name.length === 0) {
        return;
      }
      arr.push({ id: it.str('id', ''), name: name, isp: it.str('isp', '') });
    });
    this.servers = arr;
  }

  async startTest(): Promise<void> {
    if (this.running) {
      return;
    }
    this.stage = '';
    this.msg = '准备测速';
    this.liveDown = 0;
    this.liveUp = 0;
    this.elapsed = 0;
    const payload: Record<string, Object> = { 'serverId': this.serverId };
    const r: ApiResult = await Api.post(this.ctx(), '/api/v1/speedtest/start', payload);
    if (!r.ok || !r.data.bool('ok', false)) {
      this.toast(r.data.str('error', '启动失败'));
      return;
    }
    this.running = true;
    this.tick();
  }

  async installFastnet(): Promise<void> {
    this.getUIContext().showAlertDialog({
      title: '安装网络测速组件？',
      message: '将从软件源安装 FastNet（约 8 MB），装完会自动启动。'
        + '这会占用路由器约 20 秒，期间不影响上网。',
      primaryButton: {
        value: '安装',
        action: () => {
          this.doInstall();
        }
      },
      secondaryButton: {
        value: '取消',
        action: () => {
        }
      }
    });
  }

  async doInstall(): Promise<void> {
    const r: ApiResult = await Api.post(this.ctx(), '/api/v1/speedtest/install', this.body({}));
    if (!r.ok || !r.data.bool('ok', false)) {
      this.toast(r.data.str('error', '安装失败'));
      return;
    }
    this.installing = true;
    this.installMsg = '正在安装…';
    this.tick();
  }

  private toast(text: string): void {
    promptAction.showToast({ message: text, duration: 2200 });
  }

  /** 节点一行显示完：自动选择：上次服务器 Shanghai */
  private nodeLine(): string {
    const base: string = this.serverLabel();
    if (this.server.length > 0) {
      return base + '：上次服务器 ' + this.server;
    }
    return base;
  }

  private serverLabel(): string {
    if (this.serverId.length === 0) {
      return '自动选择';
    }
    for (let i = 0; i < this.servers.length; i += 1) {
      if (this.servers[i].id === this.serverId) {
        return this.servers[i].name;
      }
    }
    return '自动选择';
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        this.head();

        Scroll() {
          Column({ space: T.GAP }) {
            if (this.err.length > 0) {
              this.errCard();
            }

            if (this.installing) {
              this.installCard();
            } else if (this.state === 'absent') {
              this.absentCard();
            } else {
              this.speedCard();
            }

            if (this.rows.length > 0) {
              this.historyCard();
            }

            if (this.dataTs > 0) {
              Text('数据时间 ' + this.clockText(this.dataTs)
                + (this.staleHint ? ' · 未刷新（疑似被代理缓存）' : ''))
                .fontSize(T.fs(T.F_TINY))
                .fontColor(this.staleHint ? $r('app.color.danger') : $r('app.color.text_tertiary'))
                .width('100%');
            }
            Note({ text: '测速会占满带宽约 20 秒，期间的下载和视频通话会变慢。' });
            Row().height(24);
          }
          .width('100%')
          .padding({ left: T.PAD, right: T.PAD });
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring);
      }
      .width('100%')
      .height('100%');

      if (this.picking) {
        this.pickerSheet();
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_bg'));
  }

  @Builder
  head() {
    Row() {
      Stack() {
        GlyphIcon({ kind: Glyph.BACK, color: Pal.textPrimary(), side: 17, lineWidth: 2 });
      }
      .width(44)
      .height(44)
      .accessibilityText('返回')
      .clickEffect({ level: ClickEffectLevel.LIGHT })
      .onClick(() => {
        router.back();
      });

      Column() {
        Text('网络测速')
          .fontSize(T.fs(T.F_H1))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'));
        Text(this.running ? '测速中 · 已 ' + this.elapsed.toString() + ' 秒'
          : (this.state === 'ready' || this.state === 'done' || this.down > 0
            ? 'FastNet · Ookla 节点' : '读取中…'))
          .fontSize(T.fs(T.F_TINY))
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 2 });
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 2 });
    }
    .width('100%')
    .padding({ left: T.PAD, right: T.PAD, top: this.topPad, bottom: 2 })
    .alignItems(VerticalAlign.Center);
  }

  /** 唯一的主卡：节点、按钮、进度、结果都在这里，卡片总数不变 */
  @Builder
  speedCard() {
    Card() {
      Column({ space: 12 }) {
        Row() {
          Column({ space: 2 }) {
            Text('测速节点')
              .fontSize(T.fs(T.F_TINY))
              .fontColor($r('app.color.text_secondary'));
            Text(this.nodeLine())
              .fontSize(T.fs(T.F_BODY))
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis });
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1);

          Row() {
            Text(this.picking ? '收起' : '选择')
              .fontSize(T.fs(T.F_TINY))
              .fontColor(Pal.primary());
            GlyphIcon({ kind: Glyph.CHEVRON, color: Pal.primary(), side: 12, lineWidth: 1.9 });
          }
          .padding({ left: 10, right: 8, top: 5, bottom: 5 })
          .borderRadius(T.R_PILL)
          .backgroundColor($r('app.color.accent_soft2'))
          .onClick(() => {
            this.picking = !this.picking;
          });
        }
        .width('100%')
        .alignItems(VerticalAlign.Center);

        Hairline({ indent: 0 });

        if (this.running) {
          this.liveBlock();
        } else {
          this.resultBlock();
        }

        Button(this.running ? '测速中… ' + this.elapsed.toString() + 's' : '开始测速')
          .type(ButtonType.Normal)
          .borderRadius(T.R_PILL)
          .height(46)
          .width('100%')
          .fontSize(T.fs(T.F_BODY))
          .fontWeight(FontWeight.Medium)
          .backgroundColor($r('app.color.primary'))
          .fontColor($r('app.color.on_primary'))
          .enabled(!this.running)
          .opacity(this.running ? 0.6 : 1)
          .onClick(() => {
            this.startTest();
          });
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start);
    }
  }

  /** 测速中：三段进度条 + 三个数值，延迟一有就显示 */
  @Builder
  liveBlock() {
    Column({ space: 10 }) {
      Row({ space: 4 }) {
        Stack({ alignContent: Alignment.Start }) {
          Row().width('100%').height(6).borderRadius(3)
            .backgroundColor($r('app.color.surface_hi'));
          Row().width(this.segPct(0).toString() + '%').height(6).borderRadius(3)
            .backgroundColor($r('app.color.primary'));
        }
        .layoutWeight(1);

        Stack({ alignContent: Alignment.Start }) {
          Row().width('100%').height(6).borderRadius(3)
            .backgroundColor($r('app.color.surface_hi'));
          Row().width(this.segPct(1).toString() + '%').height(6).borderRadius(3)
            .backgroundColor($r('app.color.primary'));
        }
        .layoutWeight(1);

        Stack({ alignContent: Alignment.Start }) {
          Row().width('100%').height(6).borderRadius(3)
            .backgroundColor($r('app.color.surface_hi'));
          Row().width(this.segPct(2).toString() + '%').height(6).borderRadius(3)
            .backgroundColor($r('app.color.primary'));
        }
        .layoutWeight(1);
      }
      .width('100%');

      Row() {
        Text(this.segState(0)).layoutWeight(1).fontSize(T.fs(T.F_TINY)).textAlign(TextAlign.Center)
          .fontColor(this.stage === 'speedtest' ? $r('app.color.primary') : $r('app.color.text_tertiary'));
        Text(this.segState(1)).layoutWeight(1).fontSize(T.fs(T.F_TINY)).textAlign(TextAlign.Center)
          .fontColor(this.stage === 'download' ? $r('app.color.primary') : $r('app.color.text_tertiary'));
        Text(this.segState(2)).layoutWeight(1).fontSize(T.fs(T.F_TINY)).textAlign(TextAlign.Center)
          .fontColor(this.stage === 'upload' ? $r('app.color.primary') : $r('app.color.text_tertiary'));
      }
      .width('100%');

      Row({ space: 12 }) {
        Column({ space: 2 }) {
          Text('延迟')
            .fontSize(T.fs(T.F_TINY))
            .fontColor($r('app.color.text_secondary'));
          Row() {
            Text(this.ping > 0 ? this.ping.toFixed(0) : '—')
              .fontSize(T.fs(T.F_H2))
              .fontWeight(FontWeight.Medium)
              .fontColor(this.ping > 0 ? $r('app.color.text_primary') : $r('app.color.text_tertiary'));
            Text(' ms')
              .fontSize(T.fs(T.F_TINY))
              .fontColor($r('app.color.text_secondary'))
              .margin({ bottom: 2 });
          }
          .alignItems(VerticalAlign.Bottom);
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center);

        Column({ space: 2 }) {
          Text('下行 ↓')
            .fontSize(T.fs(T.F_TINY))
            .fontColor(this.stage === 'download' ? $r('app.color.primary') : $r('app.color.text_secondary'));
          Row() {
            Text(this.downLiveText())
              .fontSize(T.fs(T.F_H2))
              .fontWeight(FontWeight.Medium)
              .fontColor(this.stage === 'download' ? $r('app.color.primary') : $r('app.color.text_primary'));
            Text(' Mbps')
              .fontSize(T.fs(T.F_TINY))
              .fontColor($r('app.color.text_secondary'))
              .margin({ bottom: 2 });
          }
          .alignItems(VerticalAlign.Bottom);
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center);

        Column({ space: 2 }) {
          Text('上行 ↑')
            .fontSize(T.fs(T.F_TINY))
            .fontColor(this.stage === 'upload' ? $r('app.color.primary') : $r('app.color.text_secondary'));
          Row() {
            Text(this.upLiveText())
              .fontSize(T.fs(T.F_H2))
              .fontWeight(FontWeight.Medium)
              .fontColor(this.stage === 'upload' ? $r('app.color.primary') : $r('app.color.text_primary'));
            Text(' Mbps')
              .fontSize(T.fs(T.F_TINY))
              .fontColor($r('app.color.text_secondary'))
              .margin({ bottom: 2 });
          }
          .alignItems(VerticalAlign.Bottom);
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center);
      }
      .width('100%')
      .margin({ top: 2 });

      Text(this.progressHint())
        .fontSize(T.fs(T.F_TINY))
        .fontColor($r('app.color.text_tertiary'))
        .width('100%');
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }

  /** 段进度：0 延迟 / 1 下行 / 2 上行。没有真实进度，按秒数估个像样的值 */
  private segPct(i: number): number {
    const t: number = this.elapsed;
    if (i === 0) {
      if (this.stage !== 'speedtest') {
        return 100;
      }
      return Math.min(90, t * 18);
    }
    if (i === 1) {
      if (this.stage === 'upload' || !this.running) {
        return 100;
      }
      if (this.stage === 'download') {
        return Math.min(95, (t - 3) * 9);
      }
      return 0;
    }
    if (!this.running) {
      return 100;
    }
    if (this.stage === 'upload') {
      return Math.min(95, (t - 12) * 9);
    }
    return 0;
  }

  /** 每段下方那行状态字 */
  private segState(i: number): string {
    if (i === 0) {
      return this.stage === 'speedtest' ? '延迟 · 测速中' : '延迟 · 完成';
    }
    if (i === 1) {
      if (this.stage === 'download') {
        return '下行 · 测速中';
      }
      return this.stage === 'upload' || !this.running ? '下行 · 完成' : '下行 · 等待';
    }
    if (this.stage === 'upload') {
      return '上行 · 测速中';
    }
    return this.running ? '上行 · 等待' : '上行 · 完成';
  }

  private downLiveText(): string {
    if (this.stage === 'download') {
      return this.liveDown.toFixed(1);
    }
    if (this.down > 0) {
      return this.down.toFixed(1);
    }
    return '—';
  }

  private upLiveText(): string {
    if (this.stage === 'upload') {
      return this.liveUp.toFixed(1);
    }
    return '—';
  }

  private progressHint(): string {
    if (this.stage === 'speedtest') {
      return '正在测延迟 · ' + this.elapsed.toString() + ' 秒';
    }
    if (this.stage === 'download') {
      return '正在测下行 · ' + this.elapsed.toString() + ' 秒';
    }
    if (this.stage === 'upload') {
      return '正在测上行 · ' + this.elapsed.toString() + ' 秒';
    }
    return this.msg.length > 0 ? this.msg : '准备中';
  }

  @Builder
  resultBlock() {
    Column({ space: 6 }) {
      Text(this.lastDown() > 0 || this.lastUp() > 0 ? '最近一次结果' : '还没有测过')
        .fontSize(T.fs(T.F_TINY))
        .fontColor($r('app.color.text_secondary'))
        .width('100%');

      Row({ space: 8 }) {
        Column({ space: 2 }) {
          Text('延迟')
            .fontSize(T.fs(T.F_TINY))
            .fontColor($r('app.color.text_secondary'));
          Row() {
            Text(this.lastPing() > 0 ? this.lastPing().toFixed(0) : '—')
              .fontSize(T.fs(T.F_H2))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'));
            Text(' ms')
              .fontSize(T.fs(T.F_TINY))
              .fontColor($r('app.color.text_secondary'))
              .margin({ bottom: 2 });
          }
          .alignItems(VerticalAlign.Bottom);
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center);

        Column({ space: 2 }) {
          Text('下行 ↓')
            .fontSize(T.fs(T.F_TINY))
            .fontColor($r('app.color.text_secondary'));
          Row() {
            Text(this.lastDown() > 0 ? this.lastDown().toFixed(1) : '—')
              .fontSize(T.fs(T.F_H2))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'));
            Text(' Mbps')
              .fontSize(T.fs(T.F_TINY))
              .fontColor($r('app.color.text_secondary'))
              .margin({ bottom: 2 });
          }
          .alignItems(VerticalAlign.Bottom);
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center);

        Column({ space: 2 }) {
          Text('上行 ↑')
            .fontSize(T.fs(T.F_TINY))
            .fontColor($r('app.color.text_secondary'));
          Row() {
            Text(this.lastUp() > 0 ? this.lastUp().toFixed(1) : '—')
              .fontSize(T.fs(T.F_H2))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'));
            Text(' Mbps')
              .fontSize(T.fs(T.F_TINY))
              .fontColor($r('app.color.text_secondary'))
              .margin({ bottom: 2 });
          }
          .alignItems(VerticalAlign.Bottom);
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start);
      }
      .width('100%');

    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }

  /** 结果一律先看历史第一条：列表能渲染出来，这几个数就一定在 */
  private lastPing(): number {
    return this.rows.length > 0 ? this.rows[0].ping : this.ping;
  }

  private lastDown(): number {
    return this.rows.length > 0 ? this.rows[0].down : this.down;
  }

  private lastUp(): number {
    return this.rows.length > 0 ? this.rows[0].up : this.up;
  }


  @Builder
  historyCard() {
    Card() {
      Column() {
        CardTitle({ glyph: Glyph.DOWNLOAD_SPEED, title: '历史记录',
          sub: '最近 ' + this.rows.length.toString() + ' 次' });

        Row() {
          Text('时间 / 节点 / 延迟')
            .fontSize(T.fs(T.F_TINY))
            .fontColor($r('app.color.text_tertiary'))
            .layoutWeight(1);
          Text('下行 ↓')
            .fontSize(T.fs(T.F_TINY))
            .fontColor($r('app.color.text_tertiary'))
            .width(66)
            .textAlign(TextAlign.End);
          Text('上行 ↑')
            .fontSize(T.fs(T.F_TINY))
            .fontColor($r('app.color.text_tertiary'))
            .width(66)
            .textAlign(TextAlign.End);
        }
        .width('100%')
        .padding({ top: 6, bottom: 4 });

        ForEach(this.rows, (r: SpeedRow) => {
          Row() {
            Column({ space: 1 }) {
              Text(this.timeText(r.time))
                .fontSize(T.fs(T.F_SUB))
                .fontColor($r('app.color.text_primary'));
              Text((r.server.length > 0 ? r.server : '自动') + ' · ' + r.ping.toFixed(0) + ' ms')
                .fontSize(T.fs(T.F_TINY))
                .fontColor($r('app.color.text_tertiary'));
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1);
            Text(r.down.toFixed(1))
              .fontSize(T.fs(T.F_SUB))
              .fontColor($r('app.color.text_primary'))
              .width(66)
              .textAlign(TextAlign.End);
            Text(r.up.toFixed(1))
              .fontSize(T.fs(T.F_SUB))
              .fontColor($r('app.color.text_primary'))
              .width(66)
              .textAlign(TextAlign.End);
          }
          .width('100%')
          .padding({ top: 9, bottom: 9 })
          .alignItems(VerticalAlign.Center);
        }, (r: SpeedRow) => r.time.toString());
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start);
    }
  }

  @Builder
  pickerSheet() {
    Column() {
      Column()
        .width('100%')
        .layoutWeight(1)
        .backgroundColor('#33000000')
        .hitTestBehavior(HitTestMode.Block)
        .onClick(() => {
          this.picking = false;
        });

      Column() {
        Row() {
          Text('选择测速节点')
            .fontSize(T.fs(T.F_BODY))
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1);
          Text('关闭')
            .fontSize(T.fs(T.F_SUB))
            .fontColor(Pal.textSecondary())
            .onClick(() => {
              this.picking = false;
            });
        }
        .width('100%')
        .padding({ bottom: 8 });

        this.serverRow('', '自动选择', '按延迟就近挑选');

        List({ space: 2 }) {
          ForEach(this.servers, (s: Srv) => {
            ListItem() {
              this.serverRow(s.id, s.name, s.isp);
            }
          }, (s: Srv) => s.id);
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off);
      }
      .width('100%')
      .height('62%')
      .padding({ left: T.PAD, right: T.PAD, top: 14, bottom: 8 })
      .backgroundColor($r('app.color.surface'))
      .borderRadius({ topLeft: 20, topRight: 20 });
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  serverRow(id: string, name: string, sub: string) {
    Row() {
      Column({ space: 1 }) {
        Text(name)
          .fontSize(T.fs(T.F_BODY))
          .fontColor($r('app.color.text_primary'));
        Text(sub)
          .fontSize(T.fs(T.F_TINY))
          .fontColor($r('app.color.text_tertiary'));
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);
      if (this.serverId === id) {
        GlyphIcon({ kind: Glyph.CHECK, color: Pal.primary(), side: 16, lineWidth: 2.2 });
      }
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.serverId = id;
      this.picking = false;
    });
  }

  @Builder
  absentCard() {
    Card() {
      Column({ space: 10 }) {
        Text('路由器上没有装测速组件')
          .fontSize(T.fs(T.F_BODY))
          .fontColor($r('app.color.text_primary'))
          .width('100%');
        Text('FastNet 提供测速服务，约 8 MB，从软件源安装，装完自动启动。')
          .fontSize(T.fs(T.F_SUB))
          .fontColor($r('app.color.text_secondary'))
          .width('100%');
        Button('安装测速组件')
          .type(ButtonType.Normal)
          .borderRadius(T.R_PILL)
          .height(40)
          .fontSize(T.fs(T.F_SUB))
          .backgroundColor($r('app.color.primary'))
          .fontColor($r('app.color.on_primary'))
          .onClick(() => {
            this.installFastnet();
          });
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start);
    }
  }

  @Builder
  installCard() {
    Card() {
      Column({ space: 8 }) {
        Text('正在安装测速组件…')
          .fontSize(T.fs(T.F_BODY))
          .fontColor($r('app.color.text_primary'))
          .width('100%');
        Text(this.installMsg.length > 0 ? this.installMsg : '更新软件源并安装')
          .fontSize(T.fs(T.F_SUB))
          .fontColor($r('app.color.text_secondary'))
          .width('100%');
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start);
    }
  }

  @Builder
  errCard() {
    Card() {
      Text(this.err)
        .fontSize(T.fs(T.F_SUB))
        .fontColor($r('app.color.danger'))
        .width('100%');
    }
  }

  private clockText(ts: number): string {
    const d: Date = new Date(ts * 1000);
    const hh: string = d.getHours().toString().padStart(2, '0');
    const mi: string = d.getMinutes().toString().padStart(2, '0');
    const ss: string = d.getSeconds().toString().padStart(2, '0');
    return hh + ':' + mi + ':' + ss;
  }

  private timeText(ts: number): string {
    if (ts <= 0) {
      return '—';
    }
    const d: Date = new Date(ts * 1000);
    const mm: string = (d.getMonth() + 1).toString().padStart(2, '0');
    const dd: string = d.getDate().toString().padStart(2, '0');
    const hh: string = d.getHours().toString().padStart(2, '0');
    const mi: string = d.getMinutes().toString().padStart(2, '0');
    return mm + '-' + dd + ' ' + hh + ':' + mi;
  }
}
