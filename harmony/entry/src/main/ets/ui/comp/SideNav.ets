import { Ico } from './Icons';
import { Pal, T } from '../Theme';

interface RailItem {
  label: string;
  path: string;
  hint: string;
}

/**
 * 平板用的侧边导航。
 *
 * 为什么 Pad 上必须换掉底部页签：
 *  1. 平板横屏时底部横条离手指最远，还在屏幕最外侧，单手根本够不到；
 *  2. 800+ 宽的世界里把 5 个页签铺满是浪费，侧栏能把「当前在哪」一直亮着；
 *  3. HarmonyOS 自家的设置 / 图库在 Pad 上都是左栏，用户不用重新学。
 *
 * 每项带一句说明：Pad 上空间够，一句 hint 能省掉「代理到底是干什么的」这类误点。
 */
@Component
export struct SideNav {
  @Link current: number;
  /** 顶部品牌区的机型名，让侧栏不是一条空白的图标列 */
  @Prop hostname: string;

  // 四个页签，和手机端、Android、iOS 保持一致
  private items: RailItem[] = [
    { label: '概览', path: Ico.OVERVIEW, hint: '状态与速率' },
    { label: '设备', path: Ico.DEVICES, hint: '在线与拦截' },
    { label: '代理', path: Ico.PROXY, hint: '节点与分流' },
    { label: '设置', path: Ico.SETTINGS, hint: '连接与维护' }
  ];

  build() {
    Column() {
      // ---------------- 品牌 ----------------
      Column() {
        Row() {
          Stack() {
            Row()
              .width(30)
              .height(30)
              .borderRadius(9)
              .backgroundColor($r('app.color.accent_soft2'));
            Path()
              .commands('M7 9 L11.5 5.5 M7 9 L11.5 12.5 M7 9 L7 9.1')
              .width(22)
              .height(22)
              .fill(Color.Transparent)
              .stroke(Pal.primary())
              .strokeWidth(1.8)
              .strokeLineCap(LineCapStyle.Round);
          }
          .width(30)
          .height(30);

          Column() {
            Text('iStore Pilot')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'));
            Text(this.hostname.length > 0 ? this.hostname : 'iStoreOS')
              .fontSize(10.5)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis });
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          .margin({ left: 9 });
        }
        .width('100%')
        .alignItems(VerticalAlign.Center);
      }
      .width('100%')
      .padding({ left: 16, right: 12, top: 14, bottom: 16 });

      // ---------------- 导航项 ----------------
      ForEach(this.items, (item: RailItem, i: number) => {
        this.slot(item, i);
      }, (item: RailItem) => item.label);

      Blank();

      Text('v' + (AppStorage.get<string>('agentVer') ?? '2.14.0'))
        .fontSize(10.5)
        .fontColor($r('app.color.text_tertiary'))
        .padding({ left: 20, bottom: 16 });
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    .backgroundColor($r('app.color.surface'))
    .border({ width: { right: 0.5 }, color: $r('app.color.divider') });
  }

  @Builder
  slot(item: RailItem, i: number) {
    Row() {
      // 选中时左侧一条主色竖条 —— 侧栏里这个信号比底色更清楚，
      // 因为整行都有淡底时，眼睛很难判断哪一行「更亮」
      Row()
        .width(3)
        .height(this.current === i ? 22 : 0)
        .borderRadius(2)
        .backgroundColor(Pal.primary());

      Path()
        .commands(item.path)
        .width(21)
        .height(21)
        .fill(Color.Transparent)
        .stroke(this.current === i ? Pal.primary() : Pal.iconOff())
        .strokeWidth(this.current === i ? 1.85 : 1.6)
        .strokeLineCap(LineCapStyle.Round)
        .strokeLineJoin(LineJoinStyle.Round)
        .margin({ left: 12 });

      Column() {
        Text(item.label)
          .fontSize(14)
          .fontWeight(this.current === i ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(this.current === i
            ? $r('app.color.primary')
            : $r('app.color.text_primary'));
        Text(item.hint)
          .fontSize(10)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 1 });
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 10 });
    }
    .width('100%')
    .height(52)
    .alignItems(VerticalAlign.Center)
    .borderRadius(12)
    .backgroundColor(this.current === i ? $r('app.color.accent_soft') : Color.Transparent)
    .margin({ left: 8, right: 8, bottom: 2 })
    .onClick(() => {
      this.current = i;
    });
  }
}
