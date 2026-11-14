import { router } from '@kit.ArkUI';
import { Agreements } from '../core/Agreements';
import { UI } from '../core/UIState';
import { Pal, T } from '../ui/Theme';
import { Card, LineIcon } from '../ui/Comp';
import { Ico } from '../ui/comp/Icons';

/**
 * 用户协议 / 隐私政策（本地页）。
 *
 * 不从外部网址加载：本项目没有服务端，挂 GitHub 之类的外链在国内也不稳，
 * 审核要求的是「应用内能打开」，所以文本随包发布，断网也能看。
 *
 * 入口：登录页勾选行、设置 → 关于。
 */
@Entry
@ComponentV2
struct AgreementPage {
  @Local safeTop: number = UI.safeTop;
  /** privacy | terms */
  @Local kind: string = 'privacy';

  aboutToAppear(): void {
    this.safeTop = UI.safeTop;
    const p = router.getParams() as Record<string, string>;
    if (p !== undefined && p !== null && p['kind'] !== undefined && p['kind'].length > 0) {
      this.kind = p['kind'];
    }
  }

  private isPrivacy(): boolean {
    return this.kind === 'privacy';
  }

  private body(): string {
    return this.isPrivacy() ? Agreements.privacy() : Agreements.terms();
  }

  build() {
    Column() {
      Row({ space: 4 }) {
        Row() {
          LineIcon({
            path: Ico.CHEVRON,
            color: Pal.textPrimary(),
            side: 20,
            lineWidth: 1.9,
            spin: 180
          });
        }
        .width(44)
        .height(44)
        .justifyContent(FlexAlign.Center)
        .accessibilityText('返回')
        .clickEffect({ level: ClickEffectLevel.LIGHT })
        .onClick(() => {
          router.back();
        });

        Text(this.isPrivacy() ? '隐私政策' : '用户协议')
          .fontSize(T.F_H1)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1);
      }
      .width('100%')
      .padding({ left: 6, right: T.PAD, top: 6, bottom: 8 })
      .alignItems(VerticalAlign.Center);

      Scroll() {
        Column() {
          Card({ gapBottom: T.GAP }) {
            Text(this.body())
              .fontSize(T.F_SUB)
              .lineHeight(22)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .copyOption(CopyOptions.LocalDevice);
          }

          Row().width('100%').height(24);
        }
        .width('100%')
        .padding({ left: T.PAD, right: T.PAD });
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
      .edgeEffect(EdgeEffect.Spring);
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.safeTop, left: UI.safeLeft, right: UI.safeRight })
    .backgroundColor($r('app.color.app_bg'));
  }
}
