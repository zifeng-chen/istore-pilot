import { appIconOf } from '../../core/AppIcons';

/**
 * 应用图标：优先用 media 里的官方图（与安卓 drawable-nodpi 同一批，
 * 由 scripts/sync_app_icons.py 同步），认不出来的名字退回「首字 + 稳定色块」。
 *
 * 圆角 24% 与安卓 `AppIcon.RoundIconView` 一致 —— 抓来的图都是方图，
 * 圆角是 App Store 客户端加上去的，不裁就是方的。
 */
@Component
export struct AppIcon {
  @Prop name: string;
  /** 边长。不能叫 size —— 与 ArkUI CustomComponent 的同名属性冲突 */
  side: number = 32;
  @State private icon: Resource | undefined = undefined;

  aboutToAppear(): void {
    this.icon = appIconOf(this.name);
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.icon !== undefined) {
        Image(this.icon)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover);
      } else {
        Text(this.glyph())
          .fontSize(this.side * 0.42)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .textAlign(TextAlign.Center)
          .maxLines(1);
      }
    }
    .width(this.side)
    .height(this.side)
    .borderRadius(this.side * 0.24)
    .clip(true)
    .backgroundColor(this.tint());
  }

  /** 没有官方图时的首字：中文取第一个字，英文取前两个单词首字母 */
  private glyph(): string {
    const n: string = this.name.trim();
    if (n.length === 0) {
      return '?';
    }
    const first: string = n.charAt(0);
    if (first >= '0' && first <= '9') {
      return n.substring(0, 2);
    }
    if (n.charCodeAt(0) > 0x2E80) {
      return first;
    }
    const parts: string[] = n.split(' ');
    if (parts.length >= 2 && parts[1].length > 0) {
      return (parts[0].charAt(0) + parts[1].charAt(0)).toUpperCase();
    }
    return first.toUpperCase();
  }

  /** 稳定色：按字符编码求和，同一个应用每次都是同一个颜色 */
  private tint(): string {
    const palette: string[] = [
      '#FF5A2D', '#FF7A00', '#FB7299', '#00BE06', '#1E9FFF', '#FF6C00',
      '#FF3B30', '#161823', '#07C160', '#12B7F5', '#FFAA00', '#2577E3',
      '#CF0A2C', '#0A59F7', '#10A37F', '#7C3AED'
    ];
    let seed: number = 0;
    for (let i = 0; i < this.name.length; i++) {
      seed = (seed + this.name.charCodeAt(i)) % 9973;
    }
    return palette[seed % palette.length];
  }
}
