import { common } from '@kit.AbilityKit';
import { router } from '@kit.ArkUI';
import { Api, ApiResult } from '../api/Api';
import { Session } from '../core/Session';
import { Snap } from '../core/Snap';
import { Pal, T } from '../ui/Theme';
import { LineIcon } from '../ui/Comp';
import { Ico } from '../ui/comp/Icons';

const DEFAULT_BASE: string = 'http://192.168.100.1:8443';

@Entry
@Component
struct LoginPage {
  @State host: string = DEFAULT_BASE;
  @State password: string = '';
  @State busy: boolean = false;
  @State err: string = '';
  @State probe: string = '';
  @State safeTop: number = 0;

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    Session.init(ctx).then(() => {
      // 上次填过的地址要带出来，省得每次重输 IP
      if (Session.base().length > 0) {
        this.host = Session.base();
      }
    });
    const top = AppStorage.get<number>('safeTop');
    this.safeTop = top !== undefined ? top : 0;
  }

  private async doLogin(): Promise<void> {
    if (this.busy) {
      return;
    }
    if (this.host.length === 0) {
      this.err = '请填写服务器地址';
      return;
    }
    if (this.password.length === 0) {
      this.err = '请填写密码';
      return;
    }
    this.busy = true;
    this.err = '';
    this.probe = '';

    const target: string = Session.normalize(this.host);
    this.host = target;
    try {
      const res: ApiResult = await Api.login(target, this.password);
      if (!res.ok) {
        this.err = res.error;
        this.busy = false;
        return;
      }
      const token: string = res.data.str('token', '');
      if (token.length === 0) {
        this.err = '服务器没有返回令牌';
        this.busy = false;
        return;
      }
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      // 换了服务器等于换了数据源，旧快照必须清掉，否则会先看到上一台路由的数字
      await Snap.clear(ctx);
      await Session.signIn(ctx, target, token, 'admin');
      router.replaceUrl({ url: 'pages/Index' });
    } catch (e) {
      this.err = '登录失败，请检查地址与网络';
    }
    this.busy = false;
  }

  private async doProbe(): Promise<void> {
    this.probe = '正在连接…';
    const res: ApiResult = await Api.ping(Session.normalize(this.host));
    if (res.ok) {
      const v: string = res.data.str('version', '');
      this.probe = v.length > 0 ? ('已连接 · Agent v' + v) : '已连接';
    } else {
      this.probe = '连不上：' + res.error;
    }
  }

  build() {
    Column() {
      Column() {
        // 品牌区
        Column() {
          Stack() {
            LineIcon({
              path: Ico.SHIELD,
              color: Pal.primary(),
              side: 46,
              lineWidth: 2
            })
          }
          .width(76)
          .height(76)
          .borderRadius(24)
          .backgroundColor($r('app.color.accent_soft'));

          Text('iStore Pilot')
            .fontSize(28)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .margin({ top: 18 });

          Text('连接你的 iStoreOS 路由器')
            .fontSize(T.F_BODY)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: 6 });
        }
        .alignItems(HorizontalAlign.Center)
        .width('100%')
        .margin({ top: this.safeTop + 56, bottom: 36 });

        // 表单
        Column() {
          Text('服务器地址')
            .fontSize(T.F_SUB)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .margin({ bottom: 6 });

          TextInput({ text: this.host, placeholder: DEFAULT_BASE })
            .type(InputType.URL)
            .height(48)
            .borderRadius(T.R_INNER)
            .backgroundColor($r('app.color.surface_sunken'))
            .fontSize(T.F_BODY)
            .onChange((v: string) => {
              this.host = v;
              this.err = '';
              this.probe = '';
            });

          Text('登录密码')
            .fontSize(T.F_SUB)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .margin({ top: 16, bottom: 6 });

          TextInput({ text: this.password, placeholder: '请输入密码' })
            .type(InputType.Password)
            .height(48)
            .borderRadius(T.R_INNER)
            .backgroundColor($r('app.color.surface_sunken'))
            .fontSize(T.F_BODY)
            .enterKeyType(EnterKeyType.Go)
            .onChange((v: string) => {
              this.password = v;
              this.err = '';
            })
            .onSubmit(() => {
              this.doLogin();
            });

          if (this.err.length > 0) {
            Text(this.err)
              .fontSize(T.F_SUB)
              .fontColor($r('app.color.danger'))
              .width('100%')
              .margin({ top: 10 });
          }
          if (this.probe.length > 0) {
            Text(this.probe)
              .fontSize(T.F_SUB)
              .fontColor(this.probe.startsWith('已连接')
                ? $r('app.color.primary')
                : $r('app.color.text_secondary'))
              .width('100%')
              .margin({ top: 8 });
          }

          Row({ space: 10 }) {
            Button('测试连接')
              .fontSize(T.F_H2)
              .fontColor($r('app.color.text_primary'))
              .backgroundColor($r('app.color.surface_hi'))
              .borderRadius(T.R_INNER)
              .height(48)
              .layoutWeight(1)
              .onClick(() => {
                this.doProbe();
              });

            Button(this.busy ? '登录中…' : '登录')
              .fontSize(T.F_H2)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.hero_fg'))
              .backgroundColor($r('app.color.primary'))
              .borderRadius(T.R_INNER)
              .height(48)
              .layoutWeight(1.4)
              .enabled(!this.busy)
              .onClick(() => {
                this.doLogin();
              });
          }
          .width('100%')
          .margin({ top: 24 });
        }
        .padding(20)
        .backgroundColor($r('app.color.surface'))
        .borderRadius(T.R_CARD)
        .border({ width: 0.7, color: $r('app.color.glass_stroke') });
      }
      .width('100%')
      .padding({ left: T.PAD, right: T.PAD });

      Blank();

      Text('与手机端共用同一个 Agent · 口令一致')
        .fontSize(T.F_TINY)
        .fontColor($r('app.color.text_tertiary'))
        .margin({ bottom: 28 });
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_bg'));
  }
}
