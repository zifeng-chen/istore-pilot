import { Ico } from './Icons';
import { Pal, T } from '../Theme';
import { LineIcon } from '../Comp';

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

  // 和 Android / iOS 一致：四个页签。「网络」并进了概览 →「网络设置」二级页
  private items: NavItem[] = [
    { label: '概览', path: Ico.OVERVIEW },
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
    // 悬浮胶囊，不是贴边通栏条：安卓那边是圆角 26 + 0.7 描边 + 投影，
    // 外面还留 14 的边。原来这里是一条通栏 + 顶部细线，两个 App 一眼就不像。
    .borderRadius(26)
    .border({ width: 0.7, color: $r('app.color.glass_stroke') })
    .shadow({ radius: 22, color: '#1A000000', offsetY: 8 })
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
        LineIcon({
          path: item.path,
          color: this.current === i ? Pal.primary() : Pal.iconOff(),
          side: 21,
          lineWidth: this.current === i ? 1.85 : 1.6
        })
      }
      .width(46)
      .height(28);

      Text(item.label)
        .fontSize(10.5)
        .fontWeight(this.current === i ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.current === i
          ? $r('app.color.primary')
          : $r('app.color.icon_off'))
        .margin({ top: 3 });
    }
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.current = i;
    });
  }
}
