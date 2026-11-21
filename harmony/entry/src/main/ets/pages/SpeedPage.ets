import { router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { Api, ApiResult } from '../api/Api';
import { J } from '../core/Json';
import { UI } from '../core/UIState';
import { Pal, T } from '../ui/Theme';
import { Card, CardTitle, GlyphIcon, Note } from '../ui/Comp';
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
 * 测速本身不是我们实现的：路由器上的 FastNet 提供 SSE 接口，agent 把它转成
 * 「后台任务 + 状态落盘」，这里轮询展示。
 *
 * 布局顺序是刻意的：**操作卡在最上面**（选节点 + 开始），结果其次，历史最后。
 * 之前把结果卡放第一位、按钮塞在卡底，手指要滑一下才够得到。
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
  @Local server: string = '';
  @Local err: string = '';
  @Local installing: boolean = false;
  @Local installMsg: string = '';
  @Local rows: SpeedRow[] = [];
  @Local servers: Srv[] = [];
  @Local serverId: string = '';
  @Local picking: boolean = false;
  @Local elapsed: number = 0;
  @Local timer: number = -1;
  @Local clock: number = -1;

  aboutToAppear(): void {
    this.refresh();
    this.loadHistory();
    this.loadServers();
  }

  aboutToDisappear(): void {
    this.stopTimer();
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
      }, 1200);
    }
    if (this.clock < 0) {
      // 秒表单独走：状态接口 1.2 秒才回来一次，秒数要每秒都动才有在跑的感觉
      this.clock = setInterval(() => {
        if (this.running) {
          this.elapsed += 1;
        }
      }, 1000);
    }
  }

  async refresh(): Promise<void> {
    const r: ApiResult = await Api.getFresh(this.ctx(), '/api/v1/speedtest/status');
    if (!r.ok) {
      this.err = r.data.str('error', '读取失败');
      this.stopTimer();
      return;
    }
    this.err = '';
    const wasRunning: boolean = this.running;
    this.state = r.data.str('state', 'unknown');
    this.running = r.data.bool('running', false);
    this.stage = r.data.str('stage', '');
    this.msg = r.data.str('msg', '');
    this.ping = r.data.num('ping', 0);
    this.down = r.data.num('down', 0);
    this.up = r.data.num('up', 0);
    this.server = r.data.str('server', '');
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
    }
  }

  async loadHistory(): Promise<void> {
    const r: ApiResult = await Api.getFresh(this.ctx(), '/api/v1/speedtest/history');
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
    this.ping = 0;
    this.down = 0;
    this.up = 0;
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

  async startService(): Promise<void> {
    const r: ApiResult = await Api.post(this.ctx(), '/api/v1/speedtest/service', this.body({}));
    this.toast(r.data.str('msg', r.data.str('error', '已发送启动指令')));
    this.refresh();
  }

  private toast(text: string): void {
    promptAction.showToast({ message: text, duration: 2200 });
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
              this.actionCard();
              if (this.running) {
                this.progressCard();
              }
              this.resultCard();
              if (this.rows.length > 0) {
                this.historyCard();
              }
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
          .fontSize(T.F_H1)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'));
        Text(this.running ? '测速中 · 已 ' + this.elapsed.toString() + ' 秒'
          : (this.state === 'ready' ? 'FastNet · Ookla 节点' : '读取中…'))
          .fontSize(T.F_TINY)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 2 });
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 2 });
    }
    .width('100%')
    .padding({ left: T.PAD, right: T.PAD, top: UI.safeTop + 6, bottom: 6 })
    .alignItems(VerticalAlign.Center);
  }

  /** 操作卡：选节点 + 开始。放最上面，别让用户先划过结果卡才够到按钮 */
  @Builder
  actionCard() {
    Card() {
      Column({ space: 12 }) {
        Row() {
          Column({ space: 2 }) {
            Text('测速节点')
              .fontSize(T.F_TINY)
              .fontColor($r('app.color.text_secondary'));
            Text(this.serverLabel())
              .fontSize(T.F_BODY)
              .fontColor($r('app.color.text_primary'));
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1);

          Row() {
            Text(this.picking ? '收起' : '选择')
              .fontSize(T.F_TINY)
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

        Button(this.running ? '测速中… ' + this.elapsed.toString() + 's' : '开始测速')
          .type(ButtonType.Normal)
          .borderRadius(T.R_PILL)
          .height(46)
          .width('100%')
          .fontSize(T.F_BODY)
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

  @Builder
  progressCard() {
    Card() {
      Column({ space: 9 }) {
        Text(this.stageTitle())
          .fontSize(T.F_BODY)
          .fontColor($r('app.color.text_primary'))
          .width('100%');
        Text(this.msg.length > 0 ? this.msg : '正在与测速服务器握手…')
          .fontSize(T.F_TINY)
          .fontColor($r('app.color.text_secondary'))
          .width('100%');
        Row({ space: 6 }) {
          this.segment('延迟', this.stage === 'speedtest');
          this.segment('下行', this.stage === 'download');
          this.segment('上行', this.stage === 'upload');
        }
        .width('100%');
        Text(this.elapsed.toString() + ' 秒')
          .fontSize(T.F_TINY)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%');
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start);
    }
  }

  @Builder
  segment(label: string, active: boolean) {
    Text(label)
      .fontSize(T.F_TINY)
      .fontColor(active ? $r('app.color.on_primary') : $r('app.color.text_secondary'))
      .backgroundColor(active ? $r('app.color.primary') : $r('app.color.surface_hi'))
      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
      .borderRadius(T.R_PILL);
  }

  @Builder
  resultCard() {
    Card() {
      Column({ space: 4 }) {
        Text(this.down > 0 || this.up > 0 ? '最近一次结果' : '还没有测过')
          .fontSize(T.F_TINY)
          .fontColor($r('app.color.text_secondary'))
          .width('100%');

        Row({ space: 8 }) {
          this.metric('延迟', this.ping > 0 ? this.ping.toFixed(0) : '—', 'ms');
          this.metric('下行 ↓', this.down > 0 ? this.down.toFixed(1) : '—', 'Mbps');
          this.metric('上行 ↑', this.up > 0 ? this.up.toFixed(1) : '—', 'Mbps');
        }
        .width('100%')
        .margin({ top: 6 });

        if (this.server.length > 0) {
          Text('服务器 ' + this.server)
            .fontSize(T.F_TINY)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .margin({ top: 4 });
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start);
    }
  }

  @Builder
  metric(label: string, value: string, unit: string) {
    Column({ space: 2 }) {
      Text(label)
        .fontSize(T.F_TINY)
        .fontColor($r('app.color.text_secondary'));
      Row() {
        Text(value)
          .fontSize(T.F_H2)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'));
        Text(' ' + unit)
          .fontSize(T.F_TINY)
          .fontColor($r('app.color.text_secondary'))
          .margin({ left: 2, bottom: 2 });
      }
      .alignItems(VerticalAlign.Bottom);
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start);
  }

  @Builder
  historyCard() {
    Card() {
      Column() {
        CardTitle({ glyph: Glyph.DOWNLOAD_SPEED, title: '历史记录',
          sub: '最近 ' + this.rows.length.toString() + ' 次' });

        Row() {
          Text('时间 / 节点 / 延迟')
            .fontSize(T.F_TINY)
            .fontColor($r('app.color.text_tertiary'))
            .layoutWeight(1);
          Text('下行 ↓')
            .fontSize(T.F_TINY)
            .fontColor($r('app.color.text_tertiary'))
            .width(66)
            .textAlign(TextAlign.End);
          Text('上行 ↑')
            .fontSize(T.F_TINY)
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
                .fontSize(T.F_SUB)
                .fontColor($r('app.color.text_primary'));
              Text((r.server.length > 0 ? r.server : '自动') + ' · ' + r.ping.toFixed(0) + ' ms')
                .fontSize(T.F_TINY)
                .fontColor($r('app.color.text_tertiary'));
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1);
            Text(r.down.toFixed(1))
              .fontSize(T.F_SUB)
              .fontColor($r('app.color.text_primary'))
              .width(66)
              .textAlign(TextAlign.End);
            Text(r.up.toFixed(1))
              .fontSize(T.F_SUB)
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

  /** 节点选择：盖在页面上的一层，选完立刻回到测速 */
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
            .fontSize(T.F_BODY)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1);
          Text('关闭')
            .fontSize(T.F_SUB)
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
          .fontSize(T.F_BODY)
          .fontColor($r('app.color.text_primary'));
        Text(sub)
          .fontSize(T.F_TINY)
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
          .fontSize(T.F_BODY)
          .fontColor($r('app.color.text_primary'))
          .width('100%');
        Text('FastNet 提供测速服务，约 8 MB，从软件源安装，装完自动启动。')
          .fontSize(T.F_SUB)
          .fontColor($r('app.color.text_secondary'))
          .width('100%');
        Button('安装测速组件')
          .type(ButtonType.Normal)
          .borderRadius(T.R_PILL)
          .height(40)
          .fontSize(T.F_SUB)
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
          .fontSize(T.F_BODY)
          .fontColor($r('app.color.text_primary'))
          .width('100%');
        Text(this.installMsg.length > 0 ? this.installMsg : '更新软件源并安装')
          .fontSize(T.F_SUB)
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
        .fontSize(T.F_SUB)
        .fontColor($r('app.color.danger'))
        .width('100%');
    }
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

  private stageTitle(): string {
    if (this.stage === 'download') {
      return '正在测下行';
    }
    if (this.stage === 'upload') {
      return '正在测上行';
    }
    if (this.stage === 'speedtest') {
      return '正在测延迟';
    }
    return '准备中';
  }
}
