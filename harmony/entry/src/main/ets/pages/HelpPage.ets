import { router } from '@kit.ArkUI';
import { UI } from '../core/UIState';
import { Pal, T } from '../ui/Theme';
import { Card, CardHeader, LineIcon, Note } from '../ui/Comp';
import { Ico } from '../ui/comp/Icons';

/**
 * 使用帮助：从「路由器上还没有 Agent」讲到「四个页签怎么用」。
 *
 * 以前这个页面不存在 —— 新用户拿到 App 只看到两个输入框，地址填什么、
 * 口令是哪个、路由器上要不要先装东西，全靠猜。放在设置里没用：
 * 卡住的正是还没登录进来的人，所以入口在登录页。
 *
 * 三端同一份文案与顺序（Android ui/HelpActivity、iOS HelpView），改这里要同步那两处。
 */
@Entry
@ComponentV2
struct HelpPage {
  @Local safeTop: number = UI.safeTop;

  build() {
    Column() {
      // 顶栏：和另外几个二级页同一套（只有箭头，不写「返回」），路由页整页压上来
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
        .onClick(() => {
          router.back();
        });

        Text('使用帮助')
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
          this.installCard();
          this.loginCard();
          this.tabsCard();
          this.pitfallCard();
          Row().width('100%').height(28);
        }
        .width('100%')
        .padding({ left: T.PAD, right: T.PAD });
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .align(Alignment.Top);
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_bg'))
    .padding({ top: this.safeTop });
  }

  // ---------------------------------------------------------------- 一、装 Agent

  @Builder
  installCard() {
    Card({ gapBottom: T.GAP }) {
      Column() {
        this.head('一、先在路由器上装 Agent', '只需一次');

        this.step(1, '下载安装包',
          '打开 github.com/zifeng-chen/istore-pilot/releases/latest ，'
            + '按架构挑一个 .run：Intel / AMD 选 x86_64，ARM 选 arm64。');
        this.step(2, '传到路由器',
          '方式一（推荐）：iStoreOS 自带「iStore 商店」，进商店 → 上传插件，'
            + '把下载好的 .run 传上去，它会在商店里自动安装。'
            + '\n方式二：scp，或 LuCI 的「系统 → 文件传输」，放到 /tmp/ 下再手动执行。');
        this.step(3, '先检查再安装', 'SSH 登录路由器，执行下面两行：');
        this.code('sh /tmp/istore-pilot_<版本>_x86_64.run --check\n'
          + 'sh /tmp/istore-pilot_<版本>_x86_64.run');
        this.step(4, '确认装好了',
          '浏览器打开 http://路由器IP:8443 ，能看到登录框就成了 —— '
            + '这个 8443 就是下面要填的端口。');

        Note({
          text: '24.10 及更早也可以用 .ipk（系统 → 软件包 → 上传软件包）；'
            + '25.12 起包管理器换成了 apk，只能用 .run。两种不要同时装。'
        });
      }
      .width('100%');
    }
  }

  // ---------------------------------------------------------------- 二、登录

  @Builder
  loginCard() {
    Card({ gapBottom: T.GAP }) {
      Column() {
        this.head('二、回到这里登录', '');

        this.bullet('地址', '局域网填「路由器IP:8443」，例如 192.168.100.1:8443；'
          + '外网填 DDNS 域名加端口。');
        this.bullet('密码', '与路由器后台、SSH 是同一个，也就是安装时设的 AGENT_PASSWORD。');

        Text('连不上，按这个顺序查：')
          .fontSize(T.F_BODY)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .margin({ top: 14, bottom: 2 });

        this.bullet('①', '点上面的「测试连接」，看它报什么错');
        this.bullet('②', 'Agent 在不在跑：/etc/init.d/istore-agent status');
        this.bullet('③', '8443 有没有被防火墙拦住');
        this.bullet('④', '外网访问要先在路由器上做端口映射');
      }
      .width('100%');
    }
  }

  // ---------------------------------------------------------------- 三、页签

  @Builder
  tabsCard() {
    Card({ gapBottom: T.GAP }) {
      Column() {
        this.head('三、App 里有什么', '');

        this.bullet('概览', '外网状态、实时上下行、网口速率、CPU / 内存 / 运行时长。');
        this.bullet('设备', '谁在线、各自跑了多少流量，点进去看连接明细；'
          + '拦截（AdGuard Home）也在这里。');
        this.bullet('代理', '装 OpenClash / PassWall、切运行模式、选节点、管订阅。'
          + '两个插件的配置各一套，不通用。');
        this.bullet('设置', '改服务器地址、配置备份、固件与软件包更新、重启。');
      }
      .width('100%');
    }
  }

  // ---------------------------------------------------------------- 四、坑

  @Builder
  pitfallCard() {
    Card({ gapBottom: T.GAP }) {
      Column() {
        this.head('四、容易踩的几个点', '');

        this.bullet('·', '安装包一定放 /tmp —— 它是内存盘，重启自动清空，不占闪存。');
        this.bullet('·', '恢复配置备份后会问「保留 / 撤销」，90 秒内不点会自动退回原样。');
        this.bullet('·', '装代理插件时如果所有下载通道都不通，会问要不要改 hosts 加速。');
        this.bullet('·', '数据 3 秒自动刷新一次；等不及就下拉一下。');
      }
      .width('100%');
    }
  }

  // ---------------------------------------------------------------- 零件

  @Builder
  head(title: string, sub: string) {
    Column() {
      CardHeader({ title: title, sub: sub });
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }

  @Builder
  step(n: number, title: string, detail: string) {
    Row() {
      Text(n.toString())
        .fontSize(T.F_TINY)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.primary'))
        .textAlign(TextAlign.Center)
        .width(20)
        .height(20)
        .borderRadius(10)
        .backgroundColor($r('app.color.accent_soft'));

      Column() {
        Text(title)
          .fontSize(T.F_SUB + 1)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%');
        Text(detail)
          .fontSize(T.F_SUB)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .margin({ top: 3 });
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 10 });
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .margin({ top: 12 });
  }

  @Builder
  bullet(mark: string, text: string) {
    Row() {
      Text(mark)
        .fontSize(T.F_SUB)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.primary'))
        .width(34);
      Text(text)
        .fontSize(T.F_SUB)
        .fontColor($r('app.color.text_secondary'))
        .layoutWeight(1);
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .margin({ top: 8 });
  }

  /** 命令行块：底色压一层，长按可以选中复制 */
  @Builder
  code(text: string) {
    Text(text)
      .fontSize(12.5)
      .fontColor($r('app.color.text_primary'))
      .lineHeight(19)
      .copyOption(CopyOptions.LocalDevice)
      .width('100%')
      .padding({ left: 11, right: 11, top: 9, bottom: 9 })
      .borderRadius(10)
      .backgroundColor($r('app.color.surface_sunken'))
      .margin({ top: 8 });
  }
}
