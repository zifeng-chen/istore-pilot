import { common } from '@kit.AbilityKit';
import { display, router, window } from '@kit.ArkUI';
import { Api, ApiResult } from '../api/Api';
import { Session } from '../core/Session';
import { Shell } from '../core/Shell';
import { UI, UIState } from '../core/UIState';
import { Motion } from '../core/Motion';
import { SystemBar } from '../core/SystemBar';
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
 * 宽度写进 UIState.winW，各页面自己读：
 * 只有真正需要改布局的组件会重建，比把宽度当参数一层层往下传省事得多。
 */
@Entry
@ComponentV2
struct Index {
  @Local current: number = 0;
  @Local booted: boolean = false;
  /** 启动页覆盖层：三端同一套（对齐安卓 SplashActivity） */
  @Local splash: boolean = true;
  @Local prog: number = 0;
  @Local splashTip: string = '正在启动…';
  @Local logoIn: boolean = false;
  @Local nameIn: boolean = false;
  @Local tagIn: boolean = false;
  @Local safeBottom: number = 0;
  @Local winW: number = 360;
  @Local hostname: string = '';
  /**
   * 跨页共享的壳状态（V2 AppStorageV2 单例 UI，见 core/UIState.ets）：
   *   - safeTop    状态栏高度，Index 测出后写，页面/侧栏读着让出顶部
   *   - subTitle   页内二级页标题（空串 = 停在一级页）。设备清单/应用流量/拦截
   *                是 SecurityPage 里换内容不是路由页，底部导航是这层画的浮层，
   *                不读它就永远压在二级页上面
   *   - forceLogin 令牌失效信号（EntryAbility 置时间戳），收到跳登录页
   *   - tab/winW   当前页签与窗口宽度，各 tab 页 @Monitor 跟随
   */
  @Local ui: UIState = UI;

  aboutToAppear(): void {
    // 冷启动 / 重新登录后一定是停在一级页：把上一条会话可能残留的
    // 「二级页」状态清掉，否则底部导航会一直藏着
    Shell.leave();
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
    this.tintSystemBars(true);

    // 入场：图标放大淡入，名字晚 120ms、标语晚 220ms
    animateTo({ duration: Motion.ms(420), curve: Curve.EaseOut }, () => {
      this.logoIn = true;
    });
    await this.sleep(120);
    animateTo({ duration: Motion.ms(380), curve: Curve.Linear }, () => {
      this.nameIn = true;
    });
    await this.sleep(100);
    animateTo({ duration: Motion.ms(380), curve: Curve.Linear }, () => {
      this.tagIn = true;
    });

    await this.step(0.30, 380, '正在启动…');

    if (!Session.loggedIn()) {
      // 没登录：不等人，走完进度交给登录页
      await this.step(1, 520, '准备就绪');
      await this.holdMin(started);
      // 登录页是浅色底：跳转前把状态栏图标切回深色，否则启动页的白图标
      // 会一路带到登录页，白压白看不见（上架检测报的就是这个）
      SystemBar.sync(ctx);
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
    SystemBar.sync(ctx);

    await this.measureSafeArea(ctx);
    // 各页签靠这个值决定自己要不要轮询：切走的页面立刻停定时器
    UI.tab = 0;
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

  /** 状态栏 / 导航条图标颜色。统一走 SystemBar，别在每个页面各写一套 */
  private tintSystemBars(dark: boolean): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    SystemBar.sync(ctx, dark);
  }

  /** 侧栏顶部要显示机型名，单独取一次，取不到就用默认名 */
  private async fetchHost(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const r: ApiResult = await Api.get(ctx, '/api/v1/overview');
    if (r.ok) {
      const name: string = r.data.obj('board').str('hostname', '');
      if (name.length > 0) {
        this.hostname = name;
        UI.hostname = name;
      }
      const ver: string = r.data.obj('board').str('agent', '');
      if (ver.length > 0) {
        UI.agentVer = ver;
      }
    }
  }

  /** 记下状态栏与导航条高度，子页面靠 UIState 里的值自己留白 */
  private async measureSafeArea(ctx: common.UIAbilityContext): Promise<void> {
    try {
      const win = await window.getLastWindow(ctx);
      const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const indicator = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      // 用屏幕密度自己换算，不依赖 px2vp（它在部分上下文里已废弃/不可用）
      const d: number = display.getDefaultDisplaySync().densityPixels;
      if (d > 0) {
        UI.safeTop = sys.topRect.height / d;
        // 横屏时状态栏与挖孔在侧边，只让顶部不够
        UI.safeLeft = sys.leftRect.width / d;
        UI.safeRight = sys.rightRect.width / d;
        this.safeBottom = indicator.bottomRect.height / d;
      }
    } catch (e) {
      UI.safeTop = 0;
      UI.safeLeft = 0;
      UI.safeRight = 0;
      this.safeBottom = 0;
    }
  }

  @Monitor('ui.forceLogin')
  onForceLogin(): void {
    if (this.ui.forceLogin > 0) {
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
              SideNav({
                current: this.current,
                hostname: this.hostname,
                onChange: (i: number): void => {
                  this.current = i;
                  UI.tab = i;
                }
              })
            }
            .width(Bp.RAIL_W)
            .height('100%')
            .padding({ top: this.ui.safeTop, left: this.ui.safeLeft });

            // 内容区
            Column() {
              this.pages();
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
            // 只让 NAV_H 的话最后一屏内容会被胶囊压住。进二级页时底栏收起来，
            // 这段留白跟着撤掉，否则二级页底下会空出一条
            this.pages();

            // 二级页推进来的时候把底部导航收起来（安卓那边整页覆盖、没有横条）。
            // 淡出 + 下沉，和 iOS 的 transition 同一个节奏
            if (this.ui.subTitle.length === 0) {
              NavBar({
                current: this.current,
                onChange: (i: number): void => {
                  this.current = i;
                  UI.tab = i;
                }
              })
                .width('100%')
                .padding({ left: 14, right: 14 })
                .margin({ top: 4, bottom: this.safeBottom + 12 })
                .transition(TransitionEffect.OPACITY
                  .combine(TransitionEffect.translate({ y: 24 })));
            }
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
        UI.winW = w;
      }
    });
  }

  @Builder
  splashLayer() {
    Column() {
      Image($r('app.media.app_icon'))
        .width(88)
        .height(88)
        .borderRadius(T.R_LG)
        .opacity(this.logoIn ? 1 : 0)
        .scale({ x: this.logoIn ? 1 : 0.86, y: this.logoIn ? 1 : 0.86 });

      Text('iStore Pilot')
        .fontSize(T.F_HERO)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.hero_fg'))
        .margin({ top: 18 })
        .opacity(this.nameIn ? 1 : 0);

      Text('家庭网络，一屏看完')
        .fontSize(T.F_SUB)
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
          .fontSize(T.F_TINY)
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

  /**
   * 底部要留多少：手机竖屏的浮层导航 62 + 上下边距，所以多让 16。
   * 进二级页后底栏收起，只需要让出系统手势条；平板侧栏模式一直是 0。
   *
   * 注意：不能把这个值当参数塞进 @Builder —— @Builder 按值传参不会刷新，
   * 进二级页时留白会原地不动。必须在 builder 内部读状态。
   */
  private bottomPad(): number {
    if (this.railMode()) {
      // 侧栏模式没有底部浮层，原来就是 0，别顺手改掉平板的手势条留白
      return 0;
    }
    if (this.ui.subTitle.length > 0) {
      return this.safeBottom;
    }
    return T.NAV_H + 16 + this.safeBottom;
  }

  @Builder
  pages() {
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
      UI.tab = i;
    })
    .width('100%')
    .height('100%')
    // 顶上让出状态栏，底下让出导航条：这个 App 是全屏窗口
    // （EntryAbility 里 setWindowLayoutFullScreen），不让出来内容会钻到系统栏底下。
    .padding({
      top: this.ui.safeTop,
      bottom: this.bottomPad(),
      left: this.ui.safeLeft,
      right: this.ui.safeRight
    });
  }

  /**
   * 系统返回键 / 返回手势。
   *
   * 页内二级页（设备清单 / 应用流量 / 拦截）没有路由栈，系统默认行为是**直接退出 App** ——
   * 用户在手势条上一划就回到桌面，看起来像崩了。
   * 这里接管：二级页先退回一级页，页签不在首页时退回首页；都在最外层才交还给系统。
   */
  onBackPress(): boolean {
    if (this.ui.subTitle.length > 0) {
      Shell.requestBack();
      return true;
    }
    if (this.current !== 0) {
      this.current = 0;
      UI.tab = 0;
      return true;
    }
    return false;
  }
}
