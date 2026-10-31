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
  /** 启动页覆盖层：三端同一套（对齐安卓 SplashActivity） */
  @State splash: boolean = true;
  @State prog: number = 0;
  @State splashTip: string = '正在启动…';
  @State logoIn: boolean = false;
  @State nameIn: boolean = false;
  @State tagIn: boolean = false;
  @State safeBottom: number = 0;
  /** 状态栏高度。窗口是全屏的（EntryAbility 里 setWindowLayoutFullScreen），
      不主动让出来，页面大标题就会被时钟、电量压住 */
  @StorageLink('safeTop') safeTop: number = 0;
  @State winW: number = 360;
  @State hostname: string = '';
  @StorageProp('forceLogin') @Watch('onForceLogin') forceLogin: number = 0;

  aboutToAppear(): void {
    this.boot();
  }

  private async boot(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const started: number = Date.now();

    await Session.init(ctx);
    Pal.bind(ctx.getApplicationContext());
    // 深浅色要在第一帧之前定下来，否则会先闪一下系统色再跳到用户选的
    await Appearance.init(ctx);
    // 启动页是深绿底：状态栏/导航条图标得转白，否则深底上根本看不见
    this.tintSystemBars('#FFFFFF');

    // 入场：图标放大淡入，名字晚 120ms、标语晚 220ms
    animateTo({ duration: 420, curve: Curve.EaseOut }, () => {
      this.logoIn = true;
    });
    await this.sleep(120);
    animateTo({ duration: 380, curve: Curve.Linear }, () => {
      this.nameIn = true;
    });
    await this.sleep(100);
    animateTo({ duration: 380, curve: Curve.Linear }, () => {
      this.tagIn = true;
    });

    await this.step(0.30, 380, '正在启动…');

    if (!Session.loggedIn()) {
      // 没登录：不等人，走完进度交给登录页
      await this.step(1, 520, '准备就绪');
      await this.holdMin(started);
      router.replaceUrl({ url: 'pages/LoginPage' });
      return;
    }

    this.splashTip = '正在连接路由器…';
    await this.step(0.82, 900, '');
    const ok: boolean = await this.probe(ctx);
    this.splashTip = ok ? '准备就绪' : '路由器暂时没响应，先进入界面';
    await this.step(1, 240, '');

    await this.holdMin(started);
    this.splash = false;
    // 退出启动页：状态栏图标跟着当前主题走
    this.tintSystemBars(Appearance.current() === 2 ? '#FFFFFF' : '#000000');

    await this.measureSafeArea(ctx);
    // 各页签靠这个值决定自己要不要轮询：切走的页面立刻停定时器
    AppStorage.setOrCreate('tab', 0);
    this.booted = true;
    this.fetchHost();
  }

  /** 推进到某个比例。text 为空表示保留当前文案 */
  private async step(target: number, duration: number, text: string): Promise<void> {
    if (text.length > 0) {
      this.splashTip = text;
    }
    animateTo({ duration: duration, curve: Curve.EaseOut }, () => {
      this.prog = target;
    });
    await this.sleep(duration);
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => resolve(), ms);
    });
  }

  /** 最短停 1.4s：不到这个时长品牌页就成了"闪一下" */
  private async holdMin(started: number): Promise<void> {
    const rest: number = 1400 - (Date.now() - started);
    if (rest > 0) {
      await this.sleep(rest);
    }
  }

  /** 拉一次首页接口，最多等 2.6 秒；成功失败都不挡人进界面 */
  private async probe(ctx: common.UIAbilityContext): Promise<boolean> {
    const req: Promise<ApiResult> = Api.get(ctx, '/api/v1/overview');
    const timeout: Promise<ApiResult | null> = new Promise<ApiResult | null>((resolve) => {
      setTimeout(() => resolve(null), 2600);
    });
    const r: ApiResult | null = await Promise.race([req, timeout]);
    return r !== null && r.ok;
  }

  /** 状态栏 / 导航条图标颜色 */
  private tintSystemBars(color: string): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    window.getLastWindow(ctx).then((win: window.Window) => {
      win.setWindowSystemBarProperties({
        statusBarContentColor: color,
        navigationBarContentColor: color
      });
    }).catch(() => {
    });
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
            .height('100%')
            .padding({ top: this.safeTop });

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
            // 底部要多让 16：导航条上下各留 4 / 12 的边（和安卓 navhost 一致），
            // 只让 NAV_H 的话最后一屏内容会被胶囊压住
            this.pages(T.NAV_H + 16 + this.safeBottom);

            NavBar({ current: $current })
              .width('100%')
              .padding({ left: 14, right: 14 })
              .margin({ top: 4, bottom: this.safeBottom + 12 });
          }
          .width('100%')
          .height('100%');
        }
      } else {
        Column().width('100%').height('100%');
      }

      if (this.splash) {
        this.splashLayer()
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
  splashLayer() {
    Column() {
      Image($r('app.media.app_icon'))
        .width(88)
        .height(88)
        .borderRadius(20)
        .opacity(this.logoIn ? 1 : 0)
        .scale({ x: this.logoIn ? 1 : 0.86, y: this.logoIn ? 1 : 0.86 });

      Text('iStore Pilot')
        .fontSize(27)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.hero_fg'))
        .margin({ top: 18 })
        .opacity(this.nameIn ? 1 : 0);

      Text('家庭网络，一屏看完')
        .fontSize(13)
        .fontColor($r('app.color.hero_fg'))
        .opacity(this.tagIn ? 0.72 : 0)
        .margin({ top: 8 });

      Column() {
        // 轨道 96×3，填充块按比例改宽度（安卓那边用 scaleX，效果一致）
        Stack({ alignContent: Alignment.Start }) {
          Row()
            .width(96)
            .height(3)
            .borderRadius(2)
            .backgroundColor($r('app.color.hero_fg'))
            .opacity(0.22);
          Row()
            .width(Math.max(2, 96 * this.prog))
            .height(3)
            .borderRadius(2)
            .backgroundColor($r('app.color.hero_fg'));
        }
        .width(96)
        .height(3);

        Text(this.splashTip)
          .fontSize(11.5)
          .fontColor($r('app.color.hero_fg'))
          .opacity(0.6)
          .margin({ top: 10 });
      }
      .margin({ top: 46 });
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .linearGradient({
      angle: 135,
      colors: [[$r('app.color.hero_from'), 0], [$r('app.color.hero_to'), 1]]
    });
  }

  @Builder
  pages(padBottom: number) {
    Tabs({ barPosition: BarPosition.End, index: this.current }) {
      TabContent() {
        OverviewPage()
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
    // 顶上让出状态栏，底下让出导航条：这个 App 是全屏窗口
    // （EntryAbility 里 setWindowLayoutFullScreen），不让出来内容会钻到系统栏底下。
    // 平板模式没有底部栏，padBottom 传 0
    .padding({ top: this.safeTop, bottom: padBottom });
  }
}
