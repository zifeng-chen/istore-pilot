import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { Api, ApiResult } from '../api/Api';
import { Session } from '../core/Session';
import { T } from '../ui/Theme';

/**
 * 内置浏览器：路由器网页端（LuCI）。对应 Android 的 WebActivity 与 iOS 的 WebScreen。
 *
 * 为什么不交给系统浏览器：出去就是另一个 App，回来还得从最近任务里翻；
 * 更要紧的是 LuCI 会再验一次密码 —— 而 App 刚刚才用同一个口令登录过。
 * 所以进来先向 Agent 要一张「已登录的通行证」：Agent 就在这台路由器上、
 * 又是 root，替用户登一次 LuCI，只把会话 id（sysauth_http cookie）交给客户端，
 * **口令不出路由器**。把它塞进 WebCookieManager 再加载 /cgi-bin/luci/，
 * 用户看到的就是后台首页，不是那张登录页。
 *
 * 顺序不能反：ArkUI 的 Web 组件在 build 时就开始加载，所以必须等票据到手、
 * cookie 写进去了才创建它（这也是 ready 这个开关存在的唯一理由）。
 */
@Entry
@Component
struct WebPage {
  private ctrl: webview.WebviewController = new webview.WebviewController();

  @State url: string = '';
  @State host: string = '';
  @State ready: boolean = false;
  @State progress: number = 0;
  @State err: string = '';

  aboutToAppear(): void {
    this.open();
  }

  private ctx(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  /** Agent 在 8443、LuCI 在 80：直接拿 Session.base 会把 API 端口当网页打开 */
  private guessUrl(): string {
    let host: string = Session.base().replace('https://', '').replace('http://', '');
    const slash: number = host.indexOf('/');
    if (slash > 0) {
      host = host.substring(0, slash);
    }
    if (host.startsWith('[')) {
      const end: number = host.indexOf(']');
      if (end > 0) {
        host = host.substring(0, end + 1);
      }
    } else {
      const colon: number = host.lastIndexOf(':');
      if (colon > 0) {
        host = host.substring(0, colon);
      }
    }
    return 'http://' + host + '/cgi-bin/luci/';
  }

  private async open(): Promise<void> {
    const fallback: string = this.guessUrl();
    this.host = fallback.replace('http://', '').replace('/cgi-bin/luci/', '');

    const r: ApiResult = await Api.getFresh(this.ctx(), '/api/v1/luci/session');
    let target: string = fallback;
    let ok: boolean = false;
    if (r.ok && r.data.bool('ok', false)) {
      const name: string = r.data.str('cookie_name', '');
      const value: string = r.data.str('cookie_value', '');
      const u: string = r.data.str('url', fallback);
      if (name.length > 0 && value.length > 0) {
        try {
          // 先清空：LuCI 自己下发的 cookie 路径是 /cgi-bin/luci/，我们这张是 /，
          // 两个同名 cookie 同时存在时服务端取哪一条没保证
          webview.WebCookieManager.clearAllCookiesSync();
          webview.WebCookieManager.configCookieSync(u, name + '=' + value + '; path=/');
          target = u;
          ok = true;
        } catch (e) {
          ok = false;
        }
      }
      if (ok) {
        this.host = r.data.str('host', this.host);
      }
    }

    this.url = target;
    this.ready = true;
    if (!ok) {
      // 拿不到票据不是错误：照样打开网页端，让用户自己登一次
      this.err = '';
    }
  }

  /**
   * 装不下就整体缩小，别让右半页被切掉。
   *
   * LuCI 的 argon 主题给主容器写了 min-width:600px，iStoreOS 首页的卡片栅格
   * 又是固定两列 —— 在手机上右侧必然溢出，桌面浏览器拉窄也一样。改不了路由器，
   * 就在客户端补：量出真实内容宽度，把 viewport 改成那个宽度再等比缩小；
   * 缩完字偏小，所以顺手放开 user-scalable，双指还能放大。
   */
  private fitToWidth(): void {
    const js: string = '(function(){'
      + 'var d=document,w=window,h=d.documentElement;'
      + 'var iw=w.innerWidth||h.clientWidth;'
      + 'var sw=Math.max(h.scrollWidth,d.body?d.body.scrollWidth:0);'
      + 'if(!iw||!sw||sw<=iw+8)return "ok";'
      + 'var k=iw/sw;'
      + 'var m=d.querySelector("meta[name=viewport]");'
      + 'if(!m){m=d.createElement("meta");m.name="viewport";d.head.appendChild(m);}'
      + 'm.setAttribute("content","width="+sw+",initial-scale="+k.toFixed(4)'
      + ' +",maximum-scale=3,user-scalable=yes");'
      + 'return "fit";'
      + '})()';
    this.ctrl.runJavaScript(js).catch(() => {
    });
  }

  private close(): void {
    if (this.ctrl.accessBackward()) {
      this.ctrl.backward();
      return;
    }
    router.back();
  }

  build() {
    Column() {
      Row({ space: 8 }) {
        Text('‹')
          .fontSize(26)
          .fontColor($r('app.color.text_primary'))
          .width(32)
          .textAlign(TextAlign.Center)
          .onClick(() => this.close());
        Column({ space: 2 }) {
          Text('路由器网页端')
            .fontSize(T.F_BODY)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'));
          Text(this.host)
            .fontSize(T.F_TINY)
            .fontColor($r('app.color.text_secondary'));
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1);
        Text('刷新')
          .fontSize(T.F_BODY)
          .fontColor($r('app.color.primary'))
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .onClick(() => {
            this.err = '';
            this.ctrl.refresh();
          });
      }
      .width('100%')
      .padding({ left: 8, right: 8, top: 8, bottom: 6 })
      .alignItems(VerticalAlign.Center);

      // 细进度条：LuCI 是服务端渲染，跳一次 200-600ms，没有提示会以为点了没反应
      Progress({
        value: this.progress,
        total: 100,
        type: ProgressType.Linear
      })
        .width('100%')
        .height(2)
        .color($r('app.color.primary'))
        .backgroundColor(Color.Transparent)
        .visibility(this.progress > 0 && this.progress < 100 ? Visibility.Visible : Visibility.None);

      if (!this.ready) {
        Column({ space: 12 }) {
          LoadingProgress()
            .width(28)
            .color($r('app.color.primary'));
          Text('正在获取登录凭证…')
            .fontSize(T.F_TINY)
            .fontColor($r('app.color.text_secondary'));
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center);
      } else {
        Web({ src: this.url, controller: this.ctrl })
          .javaScriptAccess(true)
          .domStorageAccess(true)
          .fileAccess(true)
          .zoomAccess(true)
          .mixedMode(MixedMode.Compatible)
          .darkMode(WebDarkMode.Auto)
          .forceDarkAccess(false)
          .backgroundColor($r('app.color.app_bg'))
          .width('100%')
          .layoutWeight(1)
          .onProgressChange((e) => {
            if (e) {
              this.progress = e.newProgress;
            }
          })
          .onPageEnd(() => {
            this.progress = 0;
            this.fitToWidth();
            // iStoreOS 首页那几张卡是 JS 画出来的，第一帧还没有它们
            setTimeout(() => {
              this.fitToWidth();
            }, 600);
          })
          .onErrorReceive((e) => {
            if (e) {
              this.err = '打不开 ' + this.host + '，确认手机还连着这个路由器的 Wi-Fi。';
            }
          });
      }

      if (this.err.length > 0) {
        Text(this.err)
          .fontSize(T.F_TINY)
          .fontColor($r('app.color.danger'))
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 12 });
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_bg'));
  }
}
