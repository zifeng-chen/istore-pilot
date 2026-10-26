import { common } from '@kit.AbilityKit';
import { router, window } from '@kit.ArkUI';
import { Api, ApiResult } from '../api/Api';
import { Session } from '../core/Session';
import { Pal, T } from '../ui/Theme';
import { Appearance } from '../ui/Appearance';
import { Bp } from '../ui/Breakpoint';
import { NavBar } from '../ui/comp/NavBar';
import { SideNav } from '../ui/comp/SideNav';
import { OverviewPage } from '../ui/tabs/OverviewPage';
import { NetworkPage } from '../ui/tabs/NetworkPage';
import { SecurityPage } from '../ui/tabs/SecurityPage';
import { ProxyPage } from '../ui/tabs/ProxyPage';
import { SettingsPage } from '../ui/tabs/SettingsPage';

/**
 * 应用外壳：手机走底部页签，平板走左侧导航栏。
 *
 * 判断依据只有一个 —— 窗口宽度（vp），不猜设备类型。
 * 折叠屏展开/折叠、手机横屏、分屏，本质上都是「宽度变了」，
 * 按设备型号判断反而会在这些场景里翻车。
 *
 * 宽度写进 AppStorage('winW')，各页面自己读：
 * 只有真正需要改布局的组件会重建，比把宽度当参数一层层往下传省事得多。
 */
@Entry
@Component
struct Index {
  @State current: number = 0;
  @State booted: boolean = false;
  @State safeBottom: number = 0;
  @State winW: number = 360;
  @State hostname: string = '';
  @StorageProp('forceLogin') @Watch('onForceLogin') forceLogin: number = 0;

  aboutToAppear(): void {
    this.boot();
  }

  private async boot(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await Session.init(ctx);
    Pal.bind(ctx.getApplicationContext());
    // 深浅色要在第一帧之前定下来，否则会先闪一下系统色再跳到用户选的
    await Appearance.init(ctx);

    if (!Session.loggedIn()) {
      router.replaceUrl({ url: 'pages/LoginPage' });
      return;
    }

    await this.measureSafeArea(ctx);
    // 各页签靠这个值决定自己要不要轮询：切走的页面立刻停定时器
    AppStorage.setOrCreate('tab', 0);
    this.booted = true;
    this.fetchHost();
  }

  /** 侧栏顶部要显示机型名，单独取一次，取不到就用默认名 */
  private async fetchHost(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const r: ApiResult = await Api.get(ctx, '/api/v1/overview');
    if (r.ok) {
      const name: string = r.data.obj('board').str('hostname', '');
      if (name.length > 0) {
        this.hostname = name;
        AppStorage.setOrCreate('hostname', name);
      }
      const ver: string = r.data.obj('board').str('agent', '');
      if (ver.length > 0) {
        AppStorage.setOrCreate('agentVer', ver);
      }
    }
  }

  /** 记下状态栏与导航条高度，子页面靠 AppStorage 里的值自己留白 */
  private async measureSafeArea(ctx: common.UIAbilityContext): Promise<void> {
    try {
      const win = await window.getLastWindow(ctx);
      const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const indicator = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      AppStorage.setOrCreate('safeTop', px2vp(sys.topRect.height));
      this.safeBottom = px2vp(indicator.bottomRect.height);
      AppStorage.setOrCreate('safeBottom', this.safeBottom);
    } catch (e) {
      AppStorage.setOrCreate('safeTop', 0);
      this.safeBottom = 0;
      AppStorage.setOrCreate('safeBottom', 0);
    }
  }

  private onForceLogin(): void {
    if (this.forceLogin > 0) {
      router.replaceUrl({ url: 'pages/LoginPage' });
    }
  }

  private railMode(): boolean {
    return Bp.rail(this.winW);
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.booted) {
        if (this.railMode()) {
          Row() {
            // 侧栏
            Column() {
              SideNav({ current: $current, hostname: this.hostname })
            }
            .width(Bp.RAIL_W)
            .height('100%');

            // 内容区
            Column() {
              this.pages(0);
            }
            .layoutWeight(1)
            .height('100%');
          }
          .width('100%')
          .height('100%')
          .alignItems(VerticalAlign.Top);
        } else {
          Stack({ alignContent: Alignment.Bottom }) {
            this.pages(T.NAV_H + this.safeBottom);

            Column() {
              NavBar({ current: $current })
            }
            .width('100%')
            .padding({ bottom: this.safeBottom })
            .backgroundColor($r('app.color.surface_glass'));
          }
          .width('100%')
          .height('100%');
        }
      } else {
        Column().width('100%').height('100%');
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_bg'))
    // 只在宽度真的变了才写状态：onAreaChange 在滚动、键盘弹出时也会触发，
    // 不加判断会导致整页频繁重建（表格类页面会明显卡顿）
    .onAreaChange((oldArea: Area, newArea: Area) => {
      const w: number = Number(newArea.width);
      if (w > 0 && Math.abs(w - this.winW) > 1) {
        this.winW = w;
        AppStorage.setOrCreate('winW', w);
      }
    });
  }

  @Builder
  pages(padBottom: number) {
    Tabs({ barPosition: BarPosition.End, index: this.current }) {
      TabContent() {
        OverviewPage()
      }

      TabContent() {
        NetworkPage()
      }

      TabContent() {
        SecurityPage()
      }

      TabContent() {
        ProxyPage()
      }

      TabContent() {
        SettingsPage()
      }
    }
    .barHeight(0)
    .scrollable(false)
    .animationDuration(0)
    .onChange((i: number) => {
      this.current = i;
      AppStorage.setOrCreate('tab', i);
    })
    .width('100%')
    .height('100%')
    // 手机模式让出底部导航栏高度，否则最后一屏内容会被浮动的导航栏压住；
    // 平板模式没有底部栏，传 0
    .padding({ bottom: padBottom });
  }
}
