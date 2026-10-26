import { Ico } from './Icons';
import { Pal, T } from '../Theme';

interface NavItem {
  label: string;
  path: string;
}

/**
 * 底部导航栏。
 *
 * 选中态用三重信号区分：胶囊底色 + 主色描边 + 文字加粗。
 * 未选中图标单独用 icon_off，不复用 text_secondary ——
 * 图标是 22 的细线条，比正文更需要对比度补偿，
 * 用正文色会在浅色下淡到几乎看不见（Android 端踩过这个坑）。
 */
@Component
export struct NavBar {
  @Link current: number;

  private items: NavItem[] = [
    { label: '概览', path: Ico.OVERVIEW },
    { label: '网络', path: Ico.NETWORK },
    { label: '设备', path: Ico.DEVICES },
    { label: '代理', path: Ico.PROXY },
    { label: '设置', path: Ico.SETTINGS }
  ];

  build() {
    Row() {
      ForEach(this.items, (item: NavItem, i: number) => {
        this.slot(item, i);
      }, (item: NavItem) => item.label)
    }
    .width('100%')
    .height(T.NAV_H)
    .padding({ left: 4, right: 4 })
    .backgroundColor($r('app.color.surface_glass'))
    .backdropBlur(24)
    .border({ width: { top: 0.5 }, color: $r('app.color.divider') })
  }

  @Builder
  slot(item: NavItem, i: number) {
    Column() {
      Stack() {
        if (this.current === i) {
          Row()
            .width(46)
            .height(28)
            .borderRadius(14)
            .backgroundColor($r('app.color.accent_soft2'));
        }
        Path()
          .commands(item.path)
          .width(22)
          .height(22)
          .fill(Color.Transparent)
          .stroke(this.current === i ? Pal.primary() : Pal.iconOff())
          .strokeWidth(this.current === i ? 1.85 : 1.6)
          .strokeLineCap(LineCapStyle.Round)
          .strokeLineJoin(LineJoinStyle.Round);
      }
      .width(46)
      .height(28);

      Text(item.label)
        .fontSize(10.5)
        .fontWeight(this.current === i ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.current === i
          ? $r('app.color.primary')
          : $r('app.color.text_secondary'))
        .margin({ top: 1 });
    }
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.current = i;
    });
  }
}
