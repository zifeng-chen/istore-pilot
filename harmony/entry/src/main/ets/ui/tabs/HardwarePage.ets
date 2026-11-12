import { common } from '@kit.AbilityKit';
import { Api, ApiResult } from '../../api/Api';
import { J } from '../../core/Json';
import { Fmt } from '../../util/Fmt';
import { Pal, T } from '../Theme';
import { Card, Hairline, HeroStat, Pill } from '../Comp';

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

  /**
   * 大标题用 CPU 型号，不再用主机名。
   *
   * 绝大多数 iStoreOS 的主机名就是出厂默认的 "iStoreOS"，写在 hero 上等于
   * 什么都没说；这一页是「看硬件」，最该第一眼看到的是这台机器装了什么 U。
   */
  private title(): string {
    const model: string = this.hw.obj('cpu').str('model', '');
    if (model.length > 0) {
      return model;
    }
    const host: string = this.hw.obj('system').str('hostname', '');
    return host.length > 0 ? host : 'iStoreOS';
  }

  /** 所有磁盘容量之和，hero 里一格展示 */
  private diskTotal(): string {
    const list: J[] = this.hw.arr('disks');
    let total: number = 0;
    for (let i = 0; i < list.length; i++) {
      total += list[i].num('size', 0);
    }
    return total > 0 ? Fmt.bytes(total) : '—';
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

  /**
   * 顶部概览：这是台什么机器 + 三个最该一眼看到的数。
   *
   * 大标题给 CPU 型号（主机名多半是出厂的 iStoreOS，没有信息量），
   * 下面一行是系统与内核，再下面三格：核心线程 / 内存 / 磁盘。
   * 三格用 18fp 的值 + 短文案，360vp 宽的屏也放得下，不会再出现省略号。
   */
  @Builder
  heroCard() {
    Column() {
      Row() {
        Row()
          .width(6)
          .height(6)
          .borderRadius(3)
          .backgroundColor($r('app.color.hero_fg'))
          .margin({ right: 6 });
        Text(this.hw.obj('system').str('hostname', 'iStoreOS'))
          .fontSize(T.F_TINY)
          .fontColor($r('app.color.hero_fg_soft'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1);
        Text('已运行 ' + this.upText)
          .fontSize(10.5)
          .fontColor($r('app.color.hero_fg'))
          .maxLines(1)
          .padding({ left: 9, right: 9, top: 3, bottom: 3 })
          .borderRadius(99)
          .backgroundColor('#29FFFFFF')
          .margin({ left: 8 });
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      Text(this.title())
        .fontSize(19)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.hero_fg'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 8 });

      Text(this.hw.obj('system').str('distro', 'iStoreOS') + ' '
        + this.hw.obj('system').str('version', '') + '　·　内核 '
        + this.hw.obj('system').str('kernel', '—') + '　·　'
        + this.hw.obj('system').str('arch', '—'))
        .fontSize(11)
        .fontColor($r('app.color.hero_fg_soft'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 6 });

      Row()
        .width('100%')
        .height(0.7)
        .backgroundColor($r('app.color.hero_fg'))
        .opacity(0.18)
        .margin({ top: 12, bottom: 12 });

      Row({ space: 12 }) {
        HeroStat({
          label: '核心 / 线程',
          value: this.hw.obj('cpu').num('cores', 0) + ' / '
            + this.hw.obj('cpu').num('threads', 0),
          valueSize: 18
        });
        HeroStat({
          label: '内存',
          value: Fmt.bytes(this.hw.obj('memory').num('total', 0)),
          valueSize: 18
        });
        HeroStat({ label: '磁盘', value: this.diskTotal(), valueSize: 18 });
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

  /**
   * 卡片标题行。
   *
   * 不能写成 `Row { CardHeader(); Text(右侧) }` —— CardHeader 自身是 width('100%')，
   * 会把整行占满，右边那行字被挤出卡片边界（真机上 x86_64 只显示出 x86_6）。
   * 这里自己拼一层：左边标题撑满，右侧信息限宽 + 省略。
   */
  @Builder
  sectionHead(title: string, trailing: string) {
    Row() {
      Text(title)
        .fontSize(T.F_H2)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
        .maxLines(1);
      if (trailing.length > 0) {
        Text(trailing)
          .fontSize(T.F_TINY)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: '48%' })
          .flexShrink(0)
          .margin({ left: 8 });
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .margin({ bottom: 10 });
  }

  /** 2×2 小格：处理器那卡用它，比四行 Kv 短一截，也更有「卡片感」 */
  @Builder
  cell(label: string, value: string) {
    Column() {
      Text(label)
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
        .maxLines(1);
      Text(value)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .fontFeature("\"tnum\" on")
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 3 });
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .borderRadius(12)
    .backgroundColor($r('app.color.surface_sunken'));
  }

  @Builder
  cpuCard() {
    Card({ gapBottom: T.GAP }) {
      Column() {
        this.sectionHead('处理器', this.hw.obj('cpu').str('arch', ''));

        // 型号独占一行：它是这一卡里最长也最该被看清的东西，
        // 塞进 Kv 的右侧值列会被挤成两行、还贴到卡片边
        Text(Fmt.orDash(this.hw.obj('cpu').str('model', '')))
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ bottom: 12 });

        Row({ space: 8 }) {
          this.cell('核心 / 线程', this.hw.obj('cpu').num('cores', 0) + ' / '
            + this.hw.obj('cpu').num('threads', 0));
          this.cell('当前频率', this.hw.obj('cpu').num('mhz', 0) > 0
            ? this.hw.obj('cpu').num('mhz', 0).toString() + ' MHz' : '—');
        }
        .width('100%');

        Row({ space: 8 }) {
          this.cell('频率范围',
            this.hw.obj('cpu').num('min_mhz', 0).toString() + '–'
              + this.hw.obj('cpu').num('max_mhz', 0).toString() + ' MHz');
          this.cell('缓存', Fmt.orDash(this.hw.obj('cpu').str('cache', '')));
        }
        .width('100%')
        .margin({ top: 8 });

        Row({ space: 8 }) {
          this.flag('VT 虚拟化', this.hw.obj('cpu').bool('vt', false));
          this.flag('AES 指令集', this.hw.obj('cpu').bool('aes', false));
        }
        .width('100%')
        .margin({ top: 10 });
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
        this.sectionHead('内存', '已用 ' + this.memPercent().toFixed(0) + '%');

        Text(Fmt.bytes(this.hw.obj('memory').num('used', 0)) + ' / '
          + Fmt.bytes(this.hw.obj('memory').num('total', 0)))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .fontFeature("\"tnum\" on")
          .width('100%');

        Stack({ alignContent: Alignment.Start }) {
          Row()
            .width('100%')
            .height(8)
            .borderRadius(4)
            .backgroundColor($r('app.color.track'));
          Row()
            .width(Math.max(1.5, this.memPercent()).toFixed(1) + '%')
            .height(8)
            .borderRadius(4)
            .backgroundColor(this.memPercent() > 85
              ? $r('app.color.danger')
              : $r('app.color.primary'));
        }
        .width('100%')
        .height(8)
        .margin({ top: 8 });

        if (this.hw.obj('memory').arr('modules').length === 0) {
          Text('读不到内存条信息（部分主板不提供 SMBIOS Type 17）')
            .fontSize(T.F_TINY)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: 10 });
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
    Column() {
      Row({ space: 8 }) {
        Text(Fmt.orDash(m.str('size', '')))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'));
        Text((m.str('type', '') + (m.num('speed', 0) > 0
          ? ' ' + m.num('speed', 0).toString() : '')
          + (m.str('form', '').length > 0 ? ' · ' + m.str('form', '') : '')).trim())
          .fontSize(10.5)
          .fontColor($r('app.color.text_secondary'))
          .padding({ left: 7, right: 7, top: 2.5, bottom: 2.5 })
          .borderRadius(99)
          .backgroundColor($r('app.color.surface_sunken'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .flexShrink(1);
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      Text((m.str('vendor', '') + ' ' + m.str('part', '')).trim())
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 4 });

      Text(m.str('slot', ''))
        .fontSize(10.5)
        .fontColor($r('app.color.text_tertiary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 2 });
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 10, bottom: 10 });
  }

  @Builder
  diskCard() {
    Card({ gapBottom: T.GAP }) {
      Column() {
        this.sectionHead('存储', this.hw.arr('disks').length.toString() + ' 块');

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
        this.sectionHead('网卡', this.nicUpCount().toString() + '/'
          + this.hw.arr('nics').length.toString() + ' 已连接');

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
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .constraintSize({ maxWidth: '32%' })
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
        this.sectionHead('温度', this.hw.obj('sensors').num('cpu', 0) > 0
          ? 'CPU ' + Fmt.temp(this.hw.obj('sensors').num('cpu', 0)) : '');

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
        this.sectionHead('PCI 设备', this.hw.arr('pci').length.toString() + ' 项');

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
