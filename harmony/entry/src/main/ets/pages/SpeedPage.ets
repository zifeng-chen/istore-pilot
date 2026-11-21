import { LengthMetrics, router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { Api, ApiResult } from '../api/Api';
import { J } from '../core/Json';
import { UI } from '../core/UIState';
import { Fmt } from '../util/Fmt';
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

/**
 * 网络测速。
 *
 * 测速本身不是我们实现的：路由器上的 FastNet 插件提供 SSE 接口，agent 把它
 * 转成「后台任务 + 状态落盘」，这里只负责轮询和展示。
 *
 * 三种前置状态必须在界面上说清，否则用户点「测速」没反应会以为坏了：
 * absent（没装）/ stopped（装了没起）/ ready（可用）。
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
  @Local timer: number = -1;

  aboutToAppear(): void {
    this.refresh();
    this.loadHistory();
  }

  aboutToDisappear(): void {
    this.stopTimer();
  }

  /** Api.post 要求 Record<string, Object>，空对象也要显式构造 */
  private body(extra: Record<string, Object>): Record<string, Object> {
    return extra;
  }

  private ctx(): Context {
    return this.getUIContext().getHostContext() as Context;
  }

  private stopTimer(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private tick(): void {
    if (this.timer >= 0) {
      return;
    }
    this.timer = setInterval(() => {
      this.refresh();
    }, 1500);
  }

  async refresh(): Promise<void> {
    const r: ApiResult = await Api.getFresh(this.ctx(), '/api/v1/speedtest/status');
    if (!r.ok) {
      this.err = r.data.str('error', '读取失败');
      this.stopTimer();
      return;
    }
    this.err = '';
    this.state = r.data.str('state', 'unknown');
    this.running = r.data.bool('running', false);
    this.stage = r.data.str('stage', '');
    this.msg = r.data.str('msg', '');
    this.ping = r.data.num('ping', 0);
    this.down = r.data.num('down', 0);
    this.up = r.data.num('up', 0);
    this.server = r.data.str('server', '');
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
      if (this.state === 'ready' && this.stage.length > 0) {
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

  async startTest(): Promise<void> {
    if (this.running) {
      return;
    }
    this.stage = '';
    this.ping = 0;
    this.down = 0;
    this.up = 0;
    const r: ApiResult = await Api.post(this.ctx(), '/api/v1/speedtest/start', this.body({}));
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

  build() {
    Column() {
      this.head();

      Scroll() {
        Column({ space: T.GAP }) {
          if (this.err.length > 0) {
            this.errCard();
          }

          if (this.installing) {
            this.stateCard('正在安装测速组件…', this.installMsg, false);
          } else if (this.state === 'absent') {
            this.stateCard('路由器上没有装测速组件',
              'FastNet 提供测速服务，约 8 MB，从软件源安装。', true);
          } else if (this.state === 'stopped') {
            this.stateCard('测速组件已安装但没有运行', '启动服务后即可使用。', false);
          } else {
            this.resultCard();
            if (this.running) {
              this.progressCard();
            }
          }

          if (this.rows.length > 0) {
            this.historyCard();
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
        Text(this.running ? '测速中，请勿关闭' : 'FastNet · Ookla 节点')
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

  @Builder
  stateCard(title: string, sub: string, needInstall: boolean) {
    Card() {
      Column({ space: 10 }) {
        Text(title)
          .fontSize(T.F_BODY)
          .fontColor($r('app.color.text_primary'))
          .width('100%');
        Text(sub)
          .fontSize(T.F_SUB)
          .fontColor($r('app.color.text_secondary'))
          .width('100%');
        Row() {
          if (needInstall) {
            Button('安装测速组件')
              .type(ButtonType.Normal)
              .borderRadius(T.R_PILL)
              .height(38)
              .fontSize(T.F_SUB)
              .backgroundColor($r('app.color.primary'))
              .fontColor($r('app.color.on_primary'))
              .onClick(() => {
                this.installFastnet();
              });
          } else if (this.state === 'stopped') {
            Button('启动服务')
              .type(ButtonType.Normal)
              .borderRadius(T.R_PILL)
              .height(38)
              .fontSize(T.F_SUB)
              .backgroundColor($r('app.color.primary'))
              .fontColor($r('app.color.on_primary'))
              .onClick(() => {
                this.startService();
              });
          }
        }
        .width('100%')
        .justifyContent(FlexAlign.Start);
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start);
    }
  }

  @Builder
  resultCard() {
    Card() {
      Column({ space: 4 }) {
        Text(this.stage.length === 0 ? '还没测过' : '最近一次结果')
          .fontSize(T.F_TINY)
          .fontColor($r('app.color.text_secondary'))
          .width('100%');

        Row({ space: 8 }) {
          this.metric('延迟', this.ping > 0 ? this.ping.toFixed(0) : '—', 'ms');
          this.metric('下行', this.down > 0 ? this.down.toFixed(1) : '—', 'Mbps');
          this.metric('上行', this.up > 0 ? this.up.toFixed(1) : '—', 'Mbps');
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

        Button(this.running ? '测速中…' : '开始测速')
          .type(ButtonType.Normal)
          .borderRadius(T.R_PILL)
          .height(42)
          .width('100%')
          .fontSize(T.F_BODY)
          .fontWeight(FontWeight.Medium)
          .backgroundColor($r('app.color.primary'))
          .fontColor($r('app.color.on_primary'))
          .enabled(!this.running)
          .opacity(this.running ? 0.55 : 1)
          .margin({ top: 12 })
          .onClick(() => {
            this.startTest();
          });
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
          .fontSize(T.F_HERO)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'));
        Text(' ' + unit)
          .fontSize(T.F_TINY)
          .fontColor($r('app.color.text_secondary'))
          .margin({ left: 2, bottom: 4 });
      }
      .alignItems(VerticalAlign.Bottom);
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start);
  }

  @Builder
  progressCard() {
    Card() {
      Column({ space: 8 }) {
        Text(this.stageTitle())
          .fontSize(T.F_SUB)
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
        .width('100%')
        .margin({ top: 2 });
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

  @Builder
  historyCard() {
    Card() {
      Column({ space: 0 }) {
        CardTitle({ glyph: Glyph.DOWNLOAD_SPEED, title: '历史记录', sub: '最近 ' + this.rows.length.toString() + ' 次' });
        ForEach(this.rows, (r: SpeedRow) => {
          Row() {
            Column({ space: 1 }) {
              Text(this.timeText(r.time))
                .fontSize(T.F_SUB)
                .fontColor($r('app.color.text_primary'));
              Text(r.server.length > 0 ? r.server : '自动选择')
                .fontSize(T.F_TINY)
                .fontColor($r('app.color.text_tertiary'));
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1);
            Text(r.down.toFixed(1) + ' / ' + r.up.toFixed(1) + ' Mbps')
              .fontSize(T.F_TINY)
              .fontColor($r('app.color.text_secondary'));
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
  errCard() {
    Card() {
      Text(this.err)
        .fontSize(T.F_SUB)
        .fontColor($r('app.color.danger'))
        .width('100%');
    }
  }
}
