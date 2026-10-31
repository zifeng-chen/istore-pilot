import { common } from '@kit.AbilityKit';
import { promptAction, router } from '@kit.ArkUI';
import { Api, ApiResult } from '../api/Api';
import { J } from '../core/Json';
import { Fmt } from '../util/Fmt';
import { Pal, T } from '../ui/Theme';
import { Card, GroupBox, Hairline, Kv } from '../ui/Comp';

/**
 * 设备详情（二级页）。
 *
 * 之前鸿蒙点设备没有任何反应：`devices/detail`、`rename`、`block`、`bind`、
 * `unbind`、`wol` 六个接口一个都没接，只有一张只读清单。
 * 这一页按 iOS `DeviceDetailView` / 安卓 `DeviceDetailActivity` 的字段与动作补齐：
 *   基本信息 / 流量 / 应用占用 / 四个动作（改名、禁网、静态绑定、唤醒）
 *
 * 为什么用路由页而不是内嵌面板：清单本身是 `Tabs` 里的一个页签，
 * 内嵌浮层要改它的根容器结构（Scroll → Stack），风险比新增一页大得多。
 */
@Entry
@Component
struct DeviceDetailPage {
  @State mac: string = '';
  @State dev: J = J.empty();
  @State apps: J[] = [];
  @State loading: boolean = true;
  @State busy: boolean = false;
  @State err: string = '';
  @State renaming: boolean = false;
  @State nameDraft: string = '';
  @State safeTop: number = 0;

  aboutToAppear(): void {
    const p = router.getParams() as Record<string, string>;
    if (p !== undefined && p !== null && p['mac'] !== undefined) {
      this.mac = p['mac'];
    }
    const top = AppStorage.get<number>('safeTop');
    this.safeTop = top !== undefined ? top : 0;
    this.load();
  }

  private ctx(): common.Context {
    return this.getUIContext().getHostContext() as common.Context;
  }

  private async load(): Promise<void> {
    if (this.mac.length === 0) {
      this.err = '缺少设备标识';
      this.loading = false;
      return;
    }
    const r: ApiResult = await Api.getFresh(this.ctx(),
      '/api/v1/devices/detail?mac=' + this.mac);
    this.loading = false;
    if (!r.ok) {
      this.err = r.error.length > 0 ? r.error : '读取失败';
      return;
    }
    this.err = '';
    this.dev = r.data.obj('device');
    this.apps = r.data.arr('apps');
    this.nameDraft = this.dev.str('label', '');
  }

  /** 四个动作共用的收尾：提示 + 重新拉一次（后端会改别处状态） */
  private async act(path: string, body: Record<string, Object>, done: string): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    const r: ApiResult = await Api.post(this.ctx(), path, body);
    this.busy = false;
    if (r.ok) {
      promptAction.showToast({ message: done });
      await this.load();
    } else {
      promptAction.showToast({ message: r.error.length > 0 ? r.error : '操作失败' });
    }
  }

  private blocked(): boolean {
    return this.dev.bool('blocked', false);
  }

  private reserved(): boolean {
    return this.dev.obj('dhcp').bool('reserved', false);
  }

  private title(): string {
    const name: string = this.dev.str('label', '');
    if (name.length > 0) {
      return name;
    }
    return this.dev.str('ip', this.mac);
  }

  build() {
    Column() {
      // 顶栏：返回 + 标题 + 在线状态
      Row({ space: 6 }) {
        Text('‹')
          .fontSize(26)
          .fontColor($r('app.color.primary'))
          .width(34)
          .height(34)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            router.back();
          });
        Text(this.title())
          .fontSize(T.F_H1)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1);
        Text(this.dev.bool('online', false) ? '在线' : '离线')
          .fontSize(T.F_TINY)
          .fontColor(this.dev.bool('online', false)
            ? $r('app.color.primary')
            : $r('app.color.text_tertiary'));
      }
      .width('100%')
      .padding({ left: 8, right: T.PAD, top: 6, bottom: 4 })
      .alignItems(VerticalAlign.Center);

      if (this.loading) {
        Column() {
          Text('读取中…')
            .fontSize(T.F_SUB)
            .fontColor($r('app.color.text_secondary'));
        }
        .width('100%')
        .padding({ top: 40 });
      } else if (this.err.length > 0) {
        Text('读取失败：' + this.err)
          .fontSize(T.F_SUB)
          .fontColor($r('app.color.danger'))
          .width('100%')
          .padding(T.PAD);
      } else {
        Scroll() {
          Column() {
            this.infoCard();
            this.trafficCard();
            this.appsCard();
            this.actionCard();
            Row().height(24);
          }
          .width('100%')
          .padding({ left: T.PAD, right: T.PAD, top: 6 });
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top);
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.safeTop })
    .backgroundColor($r('app.color.app_bg'));
  }

  @Builder
  infoCard() {
    Card({ gapTop: 8 }) {
      Column() {
        Row() {
          Text('基本信息')
            .fontSize(T.F_H2)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1);
          if (this.blocked()) {
            Text('已禁网')
              .fontSize(T.F_TINY)
              .fontColor($r('app.color.danger'))
              .padding({ left: 8, right: 8, top: 2, bottom: 2 })
              .borderRadius(99)
              .backgroundColor(Pal.alpha(Pal.danger(), 0.14));
          }
        }
        .width('100%')
        .margin({ bottom: 6 });

        Kv({ label: 'IP 地址', value: this.dev.str('ip', '—'), valueSize: 0, accent: false });
        Hairline({ indent: 0 });
        Kv({ label: '厂商', value: Fmt.orDash(this.dev.str('vendor', '')), valueSize: 0, accent: false });
        Hairline({ indent: 0 });
        Kv({ label: '型号', value: Fmt.orDash(this.dev.str('model', '')), valueSize: 0, accent: false });
        Hairline({ indent: 0 });
        Kv({ label: '类型', value: Fmt.orDash(this.dev.str('type', '')), valueSize: 0, accent: false });
        Hairline({ indent: 0 });
        Kv({
          label: '接入',
          value: accessText(this.dev.obj('access')),
          valueSize: 0,
          accent: false
        });
        Hairline({ indent: 0 });
        Kv({
          label: '今天在线',
          value: this.dev.bool('online', false)
            ? '现在在线'
            : Fmt.dur(this.dev.num('last_seen', 0)),
          valueSize: 0,
          accent: false
        });
        Hairline({ indent: 0 });
        Kv({
          label: '静态绑定',
          value: this.reserved() ? this.dev.obj('dhcp').str('reserved_ip', '已绑定') : '未绑定',
          valueSize: 0,
          accent: this.reserved()
        });
      }
      .width('100%');
    }
  }

  @Builder
  trafficCard() {
    Card({ gapTop: T.GAP }) {
      Column() {
        Text('流量')
          .fontSize(T.F_H2)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .margin({ bottom: 10 });

        Row({ space: 10 }) {
          this.stat('今日下行', Fmt.bytes(this.dev.obj('net').num('rx_today', 0)));
          this.stat('今日上行', Fmt.bytes(this.dev.obj('net').num('tx_today', 0)));
        }
        .width('100%');

        Row({ space: 10 }) {
          this.stat('累计下行', Fmt.bytes(this.dev.obj('net').num('rx_total', 0)));
          this.stat('累计上行', Fmt.bytes(this.dev.obj('net').num('tx_total', 0)));
        }
        .width('100%')
        .margin({ top: 10 });

        Row() {
          Text('当前速率')
            .fontSize(T.F_SUB)
            .fontColor($r('app.color.text_secondary'));
          Blank();
          Text(this.dev.bool('online', false)
            ? ('↓ ' + Fmt.bps(this.dev.obj('net').num('rx_bps', 0))
              + '  ↑ ' + Fmt.bps(this.dev.obj('net').num('tx_bps', 0)))
            : '—')
            .fontSize(T.F_SUB)
            .fontColor($r('app.color.text_primary'))
            .fontFeature("\"tnum\" on");
        }
        .width('100%')
        .margin({ top: 12 });
      }
      .width('100%');
    }
  }

  @Builder
  stat(label: string, value: string) {
    Column() {
      Text(value)
        .fontSize(T.F_H2)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .fontFeature("\"tnum\" on")
        .maxLines(1);
      Text(label)
        .fontSize(10.5)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: 2 });
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .padding(10)
    .borderRadius(T.R_INNER)
    .backgroundColor($r('app.color.surface_sunken'));
  }

  @Builder
  appsCard() {
    if (this.apps.length > 0) {
      Card({ gapTop: T.GAP }) {
        Column() {
          Text('应用占用')
            .fontSize(T.F_H2)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
            .margin({ bottom: 8 });

          ForEach(this.apps.slice(0, 6), (a: J, i: number) => {
            Row({ space: 8 }) {
              Text(a.str('name', '未知'))
                .fontSize(T.F_BODY)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1);
              Text(a.num('share', 0).toFixed(1) + '%')
                .fontSize(T.F_TINY)
                .fontColor($r('app.color.text_secondary'))
                .fontFeature("\"tnum\" on");
              Text(Fmt.bytes(a.num('total', 0)))
                .fontSize(T.F_TINY)
                .fontColor($r('app.color.text_tertiary'))
                .fontFeature("\"tnum\" on")
                .width(70)
                .textAlign(TextAlign.End);
            }
            .width('100%')
            .padding({ top: 7, bottom: 7 });
            if (i < Math.min(5, this.apps.length - 1)) {
              Hairline({ indent: 0 });
            }
          }, (a: J, i: number) => a.str('name', '') + i);
        }
        .width('100%');
      }
    }
  }

  @Builder
  actionCard() {
    Card({ gapTop: T.GAP }) {
      Column() {
        Row() {
          Text('操作')
            .fontSize(T.F_H2)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1);
          if (this.busy) {
            Text('处理中…')
              .fontSize(T.F_TINY)
              .fontColor($r('app.color.text_secondary'));
          }
        }
        .width('100%')
        .margin({ bottom: 10 });

        if (this.renaming) {
          Row({ space: 8 }) {
            TextInput({ text: this.nameDraft, placeholder: '给这台设备起个名字' })
              .layoutWeight(1)
              .height(38)
              .fontSize(T.F_BODY)
              .borderRadius(T.R_INNER)
              .backgroundColor($r('app.color.surface_sunken'))
              .onChange((v: string) => {
                this.nameDraft = v;
              });
            Text('保存')
              .fontSize(T.F_SUB)
              .fontColor($r('app.color.primary'))
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .onClick(() => {
                const body: Record<string, Object> = { 'mac': this.mac, 'alias': this.nameDraft };
                this.act('/api/v1/devices/rename', body, '已改名').then(() => {
                  this.renaming = false;
                });
              });
            Text('取消')
              .fontSize(T.F_SUB)
              .fontColor($r('app.color.text_secondary'))
              .padding({ left: 6, right: 2, top: 6, bottom: 6 })
              .onClick(() => {
                this.renaming = false;
              });
          }
          .width('100%')
          .margin({ bottom: 12 });
        }

        this.actionRow('改名', this.renaming ? '正在输入…' : '给这台设备起个名字',
          $r('app.color.primary'), () => {
            this.nameDraft = this.dev.str('label', '');
            this.renaming = !this.renaming;
          });

        this.actionRow(this.blocked() ? '解除禁网' : '禁止上网',
          this.blocked() ? '恢复这台设备的联网权限' : '拦掉这台设备的全部外网访问',
          this.blocked() ? $r('app.color.primary') : $r('app.color.danger'), () => {
            const body: Record<string, Object> = {
              'mac': this.mac,
              'enabled': !this.blocked()
            };
            this.act('/api/v1/devices/block', body, this.blocked() ? '已解除' : '已禁网');
          });

        this.actionRow(this.reserved() ? '取消静态绑定' : '静态绑定',
          this.reserved() ? '恢复由 DHCP 自动分配' : ('固定使用 ' + this.dev.str('ip', '当前地址')),
          $r('app.color.primary'), () => {
            if (this.reserved()) {
              const body: Record<string, Object> = { 'mac': this.mac };
              this.act('/api/v1/devices/unbind', body, '已取消绑定');
            } else {
              const body: Record<string, Object> = {
                'mac': this.mac,
                'ip': this.dev.str('ip', '')
              };
              this.act('/api/v1/devices/bind', body, '已绑定');
            }
          });

        this.actionRow('唤醒', '发一个 WOL 魔术包',
          $r('app.color.primary'), () => {
            const body: Record<string, Object> = { 'mac': this.mac };
            this.act('/api/v1/devices/wol', body, '已发送唤醒包');
          });
      }
      .width('100%');
    }
  }

  @Builder
  actionRow(title: string, sub: string, color: ResourceColor, tap: () => void) {
    Row() {
      Column() {
        Text(title)
          .fontSize(T.F_BODY)
          .fontColor(color);
        Text(sub)
          .fontSize(T.F_TINY)
          .fontColor($r('app.color.text_tertiary'))
          .margin({ top: 2 });
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);

      Text('›')
        .fontSize(18)
        .fontColor($r('app.color.text_tertiary'));
    }
    .width('100%')
    .padding({ top: 9, bottom: 9 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      if (!this.busy) {
        tap();
      }
    });
  }
}

/** 接入方式的完整描述：和清单里的徽标（5G / LAN）是同一条信息，这里写全 */
function accessText(a: J): string {
  const type: string = a.str('type', '');
  const band: string = a.str('band', '');
  const ap: string = a.str('ap', '');
  if (type === 'wifi') {
    const seg: string = band.length > 0 ? band : 'WiFi';
    return ap.length > 0 ? (seg + ' · AP ' + ap) : seg;
  }
  if (type === 'wired') {
    return '有线';
  }
  return '—';
}
