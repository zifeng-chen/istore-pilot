import { common } from '@kit.AbilityKit';
import { Api, ApiResult } from '../../api/Api';
import { J } from '../../core/Json';
import { Fmt } from '../../util/Fmt';
import { Pal, T } from '../Theme';
import { Card, CardHeader, Hairline, HeroStat, Kv, Pill } from '../Comp';

/**
 * 硬件详情页。
 *
 * 对应 Android `HardwareActivity`、iOS `HardwareView`：三端都是「设置 → 设备信息 →
 * 查看全部硬件」进到一个独立页。这一版之前鸿蒙只在设置页里挂了六个字段，
 * 内存条、磁盘、网卡、温度、PCI 都看不到 —— 形态和内容都跟两端对不上。
 *
 * 排布沿用另两端的顺序：先「这台机器是什么」，再「里面装了什么」，
 * 最后才是 PCI 这种翻一次就够的清单。
 */
@ComponentV2
export struct HardwarePage {
  @Local hw: J = J.empty();
  @Local loaded: boolean = false;
  @Local err: string = '';
  /** 运行时长：只载入一次，数字得自己走秒，否则永远是打开那一刻的值 */
  @Local upText: string = '—';

  private upBase: number = 0;
  private upAt: number = 0;
  private tick: number = -1;

  aboutToAppear(): void {
    this.load();
    this.tick = setInterval(() => {
      this.tickUptime();
    }, 1000);
  }

  aboutToDisappear(): void {
    if (this.tick >= 0) {
      clearInterval(this.tick);
      this.tick = -1;
    }
  }

  private async load(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const r: ApiResult = await Api.get(ctx, '/api/v1/system/hardware');
    if (r.ok) {
      this.hw = r.data;
      this.upBase = r.data.obj('system').num('uptime', 0);
      this.upAt = Date.now();
      this.tickUptime();
      this.loaded = true;
      this.err = '';
    } else {
      this.err = r.error.length > 0 ? r.error : '读取失败';
    }
  }

  private tickUptime(): void {
    if (this.upBase <= 0) {
      this.upText = '—';
      return;
    }
    const sec: number = this.upBase + Math.floor((Date.now() - this.upAt) / 1000);
    this.upText = Fmt.uptime(sec);
  }

  /** 主板 DMI 常是 BIOS 占位符（软路由通病），这时拿 CPU 型号当标题更有信息量 */
  private title(): string {
    const host: string = this.hw.obj('system').str('hostname', '');
    if (host.length > 0) {
      return host;
    }
    const model: string = this.hw.obj('cpu').str('model', '');
    return model.length > 0 ? model : 'iStoreOS';
  }

  private memPercent(): number {
    const p: number = this.hw.obj('memory').num('percent', 0);
    return p < 0 ? 0 : (p > 100 ? 100 : p);
  }

  // ================================================================ 视图

  build() {
    Scroll() {
      Column() {
        if (this.err.length > 0) {
          Card({ gapBottom: T.GAP }) {
            Text('硬件信息读取失败：' + this.err)
              .fontSize(T.F_SUB)
              .fontColor($r('app.color.danger'))
              .width('100%');
          }
        } else if (!this.loaded) {
          this.skeleton();
        } else {
          this.heroCard();
          this.cpuCard();
          this.memoryCard();
          this.diskCard();
          this.nicCard();
          this.thermalCard();
          this.pciCard();
        }

        Row().width('100%').height(24);
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8 });
    }
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .align(Alignment.Top)
    .width('100%')
    .height('100%');
  }

  @Builder
  skeleton() {
    Column() {
      Card({ gapBottom: T.GAP }) {
        Column({ space: 10 }) {
          Row()
            .width(100)
            .height(15)
            .borderRadius(4)
            .backgroundColor($r('app.color.skeleton_base'));
          Row()
            .width('100%')
            .height(10)
            .borderRadius(4)
            .backgroundColor($r('app.color.skeleton_base'));
          Row()
            .width('86%')
            .height(10)
            .borderRadius(4)
            .backgroundColor($r('app.color.skeleton_base'));
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start);
      }
      Card({ gapBottom: T.GAP }) {
        Column({ space: 10 }) {
          Row()
            .width(120)
            .height(13)
            .borderRadius(4)
            .backgroundColor($r('app.color.skeleton_base'));
          Row()
            .width('100%')
            .height(10)
            .borderRadius(4)
            .backgroundColor($r('app.color.skeleton_base'));
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start);
      }
    }
    .width('100%');
  }

  /** 顶部：谁、什么系统、什么架构 + 三个一眼要看的数 */
  @Builder
  heroCard() {
    Column() {
      Row() {
        Text(this.title())
          .fontSize(21)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.hero_fg'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1);
        Text(this.hw.obj('system').str('distro', '') + ' '
          + this.hw.obj('system').str('version', ''))
          .fontSize(T.F_TINY)
          .fontColor($r('app.color.hero_fg_soft'))
          .maxLines(1)
          .margin({ left: 8 });
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      Text(this.hw.obj('system').str('target', '—') + '　·　内核 '
        + this.hw.obj('system').str('kernel', '—') + '　·　'
        + this.hw.obj('system').str('arch', '—'))
        .fontSize(T.F_TINY)
        .fontColor($r('app.color.hero_fg_soft'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 5 });

      Row()
        .width('100%')
        .height(0.7)
        .backgroundColor($r('app.color.hero_fg'))
        .opacity(0.18)
        .margin({ top: 10, bottom: 12 });

      Row() {
        HeroStat({
          label: 'CPU',
          value: this.hw.obj('cpu').num('cores', 0) + ' 核 '
            + this.hw.obj('cpu').num('threads', 0) + ' 线程'
        });
        HeroStat({ label: '内存', value: Fmt.bytes(this.hw.obj('memory').num('total', 0)) });
        HeroStat({ label: '运行', value: this.upText });
      }
      .width('100%');
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 18, right: 18, top: 16, bottom: 16 })
    .borderRadius(T.R_CARD)
    .linearGradient({
      angle: 135,
      colors: [[Pal.heroFrom(), 0.0], [Pal.heroTo(), 1.0]]
    })
    .border({ width: 0.7, color: $r('app.color.hero_stroke') })
    .margin({ bottom: T.GAP });
  }

  @Builder
  cpuCard() {
    Card({ gapBottom: T.GAP }) {
      Column() {
        Row() {
          CardHeader({ title: '处理器' });
          Text(this.hw.obj('cpu').str('arch', ''))
            .fontSize(T.F_TINY)
            .fontColor($r('app.color.text_secondary'));
        }
        .width('100%')
        .alignItems(VerticalAlign.Center);

        Kv({ label: '型号', value: Fmt.orDash(this.hw.obj('cpu').str('model', '')) });
        Hairline({ indent: 0 });
        Kv({
          label: '核心 / 线程',
          value: this.hw.obj('cpu').num('cores', 0) + ' / '
            + this.hw.obj('cpu').num('threads', 0)
        });
        Hairline({ indent: 0 });
        Kv({
          label: '当前频率',
          value: this.hw.obj('cpu').num('mhz', 0) > 0
            ? this.hw.obj('cpu').num('mhz', 0).toString() + ' MHz' : '—'
        });
        Hairline({ indent: 0 });
        Kv({
          label: '频率范围',
          value: this.hw.obj('cpu').num('min_mhz', 0).toString() + '–'
            + this.hw.obj('cpu').num('max_mhz', 0).toString() + ' MHz'
        });
        Hairline({ indent: 0 });
        Kv({ label: '缓存', value: Fmt.orDash(this.hw.obj('cpu').str('cache', '')) });

        Row({ space: 8 }) {
          this.flag('VT 虚拟化', this.hw.obj('cpu').bool('vt', false));
          this.flag('AES 指令集', this.hw.obj('cpu').bool('aes', false));
        }
        .width('100%')
        .margin({ top: 8 });
      }
      .width('100%');
    }
  }

  @Builder
  flag(label: string, on: boolean) {
    Row({ space: 5 }) {
      Row()
        .width(6)
        .height(6)
        .borderRadius(3)
        .backgroundColor(on ? $r('app.color.ok') : $r('app.color.text_tertiary'));
      Text(label)
        .fontSize(T.F_TINY)
        .fontColor(on ? $r('app.color.text_primary') : $r('app.color.text_secondary'));
    }
    .padding({ left: 9, right: 9, top: 5, bottom: 5 })
    .borderRadius(T.R_PILL)
    .backgroundColor($r('app.color.surface_sunken'));
  }

  @Builder
  memoryCard() {
    Card({ gapBottom: T.GAP }) {
      Column() {
        Row() {
          CardHeader({ title: '内存' });
          Text(this.memPercent().toFixed(0) + '%')
            .fontSize(T.F_SUB)
            .fontColor($r('app.color.text_secondary'));
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
            .width(Math.max(1.5, this.memPercent()).toFixed(1) + '%')
            .height(6)
            .borderRadius(3)
            .backgroundColor(this.memPercent() > 85
              ? $r('app.color.danger')
              : $r('app.color.primary'));
        }
        .width('100%')
        .height(6)
        .margin({ top: 4 });

        Text(Fmt.bytes(this.hw.obj('memory').num('used', 0)) + ' / '
          + Fmt.bytes(this.hw.obj('memory').num('total', 0)))
          .fontSize(T.F_TINY)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 8 });

        if (this.hw.obj('memory').arr('modules').length === 0) {
          Text('读不到内存条信息（部分主板不提供 SMBIOS Type 17）')
            .fontSize(T.F_TINY)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: 8 });
        } else {
          ForEach(this.hw.obj('memory').arr('modules'), (m: J) => {
            Hairline({ indent: 0 });
            this.moduleRow(m);
          }, (m: J) => m.str('slot', '') + '|' + m.str('size', ''));
        }
      }
      .width('100%');
    }
  }

  @Builder
  moduleRow(m: J) {
    Row() {
      Column() {
        Row({ space: 6 }) {
          Text(Fmt.orDash(m.str('size', '')))
            .fontSize(T.F_BODY)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'));
          Text(m.str('type', '') + (m.num('speed', 0) > 0
            ? ' ' + m.num('speed', 0).toString() : ''))
            .fontSize(T.F_TINY)
            .fontColor($r('app.color.text_secondary'));
          Text(m.str('form', ''))
            .fontSize(T.F_TINY)
            .fontColor($r('app.color.text_secondary'));
        }
        .width('100%');

        Text((m.str('vendor', '') + ' ' + m.str('part', '')).trim())
          .fontSize(T.F_TINY)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 3 });

        Text(m.str('slot', ''))
          .fontSize(T.F_TINY)
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 2 });
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);
    }
    .width('100%')
    .padding({ top: 9, bottom: 9 });
  }

  @Builder
  diskCard() {
    Card({ gapBottom: T.GAP }) {
      Column() {
        Row() {
          CardHeader({ title: '存储' });
          Text(this.hw.arr('disks').length.toString() + ' 块')
            .fontSize(T.F_TINY)
            .fontColor($r('app.color.text_secondary'));
        }
        .width('100%')
        .alignItems(VerticalAlign.Center);

        if (this.hw.arr('disks').length === 0) {
          Text('没有检测到磁盘')
            .fontSize(T.F_TINY)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: 8 });
        } else {
          ForEach(this.hw.arr('disks'), (d: J) => {
            Hairline({ indent: 0 });
            Row() {
              Column() {
                Text(d.str('name', '—'))
                  .fontSize(T.F_BODY)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'));
                Text(d.str('model', '—') + '　·　' + d.str('transport', '—'))
                  .fontSize(T.F_TINY)
                  .fontColor($r('app.color.text_secondary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .margin({ top: 3 });
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1);

              Column() {
                Text(d.str('size_text', Fmt.bytes(d.num('size', 0))))
                  .fontSize(T.F_SUB)
                  .fontColor($r('app.color.text_primary'))
                  .fontFeature("\"tnum\" on");
                if (d.num('temp', 0) > 0) {
                  Text(Fmt.temp(d.num('temp', 0)))
                    .fontSize(T.F_TINY)
                    .fontColor(d.num('temp', 0) > 60
                      ? $r('app.color.warn')
                      : $r('app.color.text_secondary'))
                    .margin({ top: 3 });
                }
              }
              .alignItems(HorizontalAlign.End)
              .margin({ left: 8 });
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
            .padding({ top: 10, bottom: 10 });
          }, (d: J) => d.str('name', ''));
        }
      }
      .width('100%');
    }
  }

  @Builder
  nicCard() {
    Card({ gapBottom: T.GAP }) {
      Column() {
        Row() {
          CardHeader({ title: '网卡' });
          Text(this.nicUpCount().toString() + '/' + this.hw.arr('nics').length.toString()
            + ' 已连接')
            .fontSize(T.F_TINY)
            .fontColor($r('app.color.text_secondary'));
        }
        .width('100%')
        .alignItems(VerticalAlign.Center);

        if (this.hw.arr('nics').length === 0) {
          Text('没有检测到物理网卡')
            .fontSize(T.F_TINY)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: 8 });
        } else {
          ForEach(this.hw.arr('nics'), (n: J) => {
            Hairline({ indent: 0 });
            Row() {
              Column() {
                Row({ space: 6 }) {
                  Text(n.str('name', '—'))
                    .fontSize(T.F_BODY)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(n.bool('up', false)
                      ? $r('app.color.text_primary')
                      : $r('app.color.text_secondary'));
                  if (n.bool('up', false)) {
                    Pill({ text: Fmt.speed(n.num('speed_mbps', 0)), tone: Pal.primary() });
                  }
                }
                .width('100%');

                Text(Fmt.orDash(n.str('chip', '')))
                  .fontSize(T.F_TINY)
                  .fontColor($r('app.color.text_secondary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                  .margin({ top: 3 });

                Text(n.str('mac', ''))
                  .fontSize(T.F_TINY)
                  .fontColor($r('app.color.text_tertiary'))
                  .width('100%')
                  .margin({ top: 2 });
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1);

              if (n.str('driver', '').length > 0) {
                Text(n.str('driver', ''))
                  .fontSize(T.F_TINY)
                  .fontColor($r('app.color.text_secondary'))
                  .padding({ left: 7, right: 7, top: 3, bottom: 3 })
                  .borderRadius(T.R_PILL)
                  .backgroundColor($r('app.color.surface_sunken'))
                  .margin({ left: 8 });
              }
            }
            .width('100%')
            .padding({ top: 9, bottom: 9 });
          }, (n: J) => n.str('name', ''));
        }
      }
      .width('100%');
    }
  }

  private nicUpCount(): number {
    const list: J[] = this.hw.arr('nics');
    let n: number = 0;
    for (let i = 0; i < list.length; i++) {
      if (list[i].bool('up', false)) {
        n++;
      }
    }
    return n;
  }

  @Builder
  thermalCard() {
    Card({ gapBottom: T.GAP }) {
      Column() {
        CardHeader({ title: '温度' });

        Row({ space: 10 }) {
          this.tempBlock('CPU', this.hw.obj('sensors').num('cpu', 0));
          this.tempBlock('NVMe', this.hw.obj('sensors').num('nvme', 0));
          this.tempBlock('机箱', this.hottest());
        }
        .width('100%')
        .margin({ top: 4 });

        if (this.zonesText().length > 0) {
          Text(this.zonesText())
            .fontSize(T.F_TINY)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .margin({ top: 10 });
        }
      }
      .width('100%');
    }
  }

  @Builder
  tempBlock(label: string, c: number) {
    Column() {
      Text(c > 0 ? Fmt.temp(c) : '—')
        .fontSize(T.F_H1)
        .fontWeight(FontWeight.Medium)
        .fontColor(c > 75 ? $r('app.color.warn') : $r('app.color.text_primary'))
        .fontFeature("\"tnum\" on");
      Text(label)
        .fontSize(T.F_TINY)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: 3 });
    }
    .layoutWeight(1)
    .padding({ top: 10, bottom: 10 })
    .borderRadius(T.R_INNER)
    .backgroundColor($r('app.color.surface_sunken'));
  }

  private hottest(): number {
    const zones: J[] = this.hw.obj('sensors').arr('zones');
    let max: number = 0;
    for (let i = 0; i < zones.length; i++) {
      const c: number = zones[i].num('celsius', 0);
      if (c > max) {
        max = c;
      }
    }
    return max;
  }

  private zonesText(): string {
    const zones: J[] = this.hw.obj('sensors').arr('zones');
    const parts: string[] = [];
    for (let i = 0; i < zones.length; i++) {
      const z: J = zones[i];
      const name: string = z.str('label', '').length > 0 ? z.str('label', '') : z.str('zone', '');
      parts.push(name + ' ' + Fmt.temp(z.num('celsius', 0)));
    }
    return parts.join('　·　');
  }

  @Builder
  pciCard() {
    Card({ gapBottom: T.GAP }) {
      Column() {
        Row() {
          CardHeader({ title: 'PCI 设备' });
          Text(this.hw.arr('pci').length.toString() + ' 项')
            .fontSize(T.F_TINY)
            .fontColor($r('app.color.text_secondary'));
        }
        .width('100%')
        .alignItems(VerticalAlign.Center);

        ForEach(this.hw.arr('pci'), (p: J) => {
          Hairline({ indent: 0 });
          Column() {
            Text(p.str('name', '—'))
              .fontSize(T.F_SUB)
              .fontColor($r('app.color.text_primary'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%');
            Text(p.str('slot', '') + '　' + p.str('class', ''))
              .fontSize(T.F_TINY)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
              .margin({ top: 2 });
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding({ top: 8, bottom: 8 });
        }, (p: J) => p.str('slot', '') + p.str('name', ''));
      }
      .width('100%');
    }
  }
}
