import { NetworkPage } from '../ui/tabs/NetworkPage';

/**
 * 网络设置（二级页）。
 *
 * 原来「网络」是底部五个页签之一，但里面大半是只读信息（局域网现状、防火墙摘要），
 * 看完就走；真正要动手的只有重拨和改宽带参数。现在它从概览的「网络设置」入口进来，
 * 底部让出来的位置还给主页面 —— 和 Android、iOS 三端一致。
 *
 * 内容本体仍然是 NetworkPage（含手机单列 / 平板两栏两套版式），
 * 这里只负责挂一条返回路径。
 */
@Entry
@Component
struct NetSettingsPage {
  build() {
    Column() {
      NetworkPage({ showBack: true })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_bg'));
  }
}
