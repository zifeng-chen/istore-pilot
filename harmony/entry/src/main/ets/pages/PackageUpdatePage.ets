import { common } from '@kit.AbilityKit';
import { LengthMetrics, router } from '@kit.ArkUI';
import { promptAction } from '@kit.ArkUI';
import { Api, ApiResult } from '../api/Api';
import { J } from '../core/Json';
import { UI } from '../core/UIState';
import { Pal, T } from '../ui/Theme';
import { Card, CardTitle, Comp, GlyphIcon, Hairline, Note } from '../ui/Comp';
import { Glyph } from '../ui/comp/Icons';

/** 一个可升级的软件包 */
interface PkgUpd {
  name: string;
  current: string;
  latest: string;
}

/**
 * 软件包更新。
 *
 * 原来这个功能是「弹一个纯文本弹层，列前 10 个包名」—— 看得见、动不了。
 * 现在给它一个正经页面：搜索、勾选、全选、按选中的升级。
 *
 * 为什么单独一页而不是塞回设置页：可升级包通常几十上百个，列表要能滚、
 * 要能搜索、选中状态要跨滚动保留 —— 这些都不是一个弹层能装下的。
 */
@Entry
@ComponentV2
struct PackageUpdatePage {
  @Local safeTop: number = 0;
  @Local items: PkgUpd[] = [];
  @Local q: string = '';
  /** 选中的包名。用数组而不是 Set：ArkUI 对数组的增删感知更可靠 */
  @Local picked: string[] = [];
  @Local loading: boolean = true;
  @Local refreshing: boolean = false;
  @Local starting: boolean = false;
  /** 升级任务在后台跑，这里只显示状态 */
  @Local running: boolean = false;
  @Local logTail: string = '';
  @Local err: string = '';
  @Local firmware: string = '';

  private timer: number = -1;

  aboutToAppear(): void {
    this.safeTop = UI.safeTop;
    this.load(false);
  }

  aboutToDisappear(): void {
    this.stopPoll();
  }

  // ================================================================ 数据

  private async load(refresh: boolean): Promise<void> {
    const ctx = this.ctx();
    if (refresh) {
      this.refreshing = true;
    } else {
      this.loading = true;
    }
    this.err = '';
    const body: Record<string, Object> = { 'action': 'check', 'refresh': refresh };
    const r: ApiResult = await Api.post(ctx, '/api/v1/system/update', body);
    this.loading = false;
    this.refreshing = false;

    if (!r.ok || !r.data.bool('ok', false)) {
      this.err = r.data.str('error', r.ok ? '' : r.error);
      if (this.err.length === 0) {
        this.err = '读取软件源失败，检查路由器能不能上网';
      }
      return;
    }
    const raw: J[] = r.data.arr('packages');
    const out: PkgUpd[] = [];
    for (let i = 0; i < raw.length; i++) {
      out.push({
        name: raw[i].str('name', ''),
        current: raw[i].str('current', ''),
        latest: raw[i].str('latest', '')
      });
    }
    this.items = out;
    this.firmware = r.data.obj('firmware').str('version', '');
    // 刷新后把已经不存在的包从选中里剔掉，否则「升级 3 个」里有两个是幽灵
    const keep: string[] = [];
    for (let i = 0; i < this.picked.length; i++) {
      for (let j = 0; j < out.length; j++) {
        if (out[j].name === this.picked[i]) {
          keep.push(this.picked[i]);
          break;
        }
      }
    }
    this.picked = keep;
  }

  /** 搜索过滤：包名不区分大小写包含即可，够用 */
  private shown(): PkgUpd[] {
    const key: string = this.q.trim().toLowerCase();
    if (key.length === 0) {
      return this.items;
    }
    const out: PkgUpd[] = [];
    for (let i = 0; i < this.items.length; i++) {
      if (this.items[i].name.toLowerCase().indexOf(key) >= 0) {
        out.push(this.items[i]);
      }
    }
    return out;
  }

  private isPicked(name: string): boolean {
    for (let i = 0; i < this.picked.length; i++) {
      if (this.picked[i] === name) {
        return true;
      }
    }
    return false;
  }

  private toggle(name: string): void {
    const next: string[] = [];
    let hit: boolean = false;
    for (let i = 0; i < this.picked.length; i++) {
      if (this.picked[i] === name) {
        hit = true;
      } else {
        next.push(this.picked[i]);
      }
    }
    if (!hit) {
      next.push(name);
    }
    this.picked = next;
  }

  private allPicked(): boolean {
    const list: PkgUpd[] = this.shown();
    if (list.length === 0) {
      return false;
    }
    for (let i = 0; i < list.length; i++) {
      if (!this.isPicked(list[i].name)) {
        return false;
      }
    }
    return true;
  }

  /** 全选只作用于「当前筛选结果」—— 搜了 luci 再全选，不该把别的 200 个也勾上 */
  private toggleAll(): void {
    const list: PkgUpd[] = this.shown();
    if (this.allPicked()) {
      const next: string[] = [];
      for (let i = 0; i < this.picked.length; i++) {
        let inView: boolean = false;
        for (let j = 0; j < list.length; j++) {
          if (list[j].name === this.picked[i]) {
            inView = true;
            break;
          }
        }
        if (!inView) {
          next.push(this.picked[i]);
        }
      }
      this.picked = next;
      return;
    }
    const next: string[] = this.picked.slice();
    for (let i = 0; i < list.length; i++) {
      if (!this.isPicked(list[i].name)) {
        next.push(list[i].name);
      }
    }
    this.picked = next;
  }

  // ================================================================ 升级

  private async upgrade(): Promise<void> {
    if (this.picked.length === 0 || this.starting) {
      return;
    }
    this.getUIContext().showAlertDialog({
      title: '升级 ' + this.picked.length.toString() + ' 个软件包？',
      message: '升级在路由器后台跑，中途不要断电。个别包（内核、驱动）升级时会断网一两分钟。',
      primaryButton: {
        value: '开始升级',
        fontColor: Pal.danger(),
        action: () => {
          this.doUpgrade();
        }
      },
      secondaryButton: {
        value: '取消',
        fontColor: Pal.textSecondary(),
        action: () => {
        }
      }
    });
  }

  private async doUpgrade(): Promise<void> {
    this.starting = true;
    const ctx = this.ctx();
    // 升级前先 opkg update 拉索引：不拉的话「最新版」可能是一周前的，
    // 升完还是旧版本，用户会以为没生效
    const body: Record<string, Object> = {
      'action': 'upgrade',
      'packages': this.picked.slice()
    };
    const r: ApiResult = await Api.post(ctx, '/api/v1/system/update', body);
    this.starting = false;
    if (!r.ok || !r.data.bool('ok', false)) {
      promptAction.showToast({
        message: r.data.str('error', r.ok ? '升级没被受理' : r.error)
      });
      return;
    }
    this.running = true;
    this.logTail = '';
    this.startPoll();
    promptAction.showToast({ message: '已开始升级，进度在下面' });
  }

  private startPoll(): void {
    this.stopPoll();
    this.timer = setInterval(() => {
      this.poll();
    }, 2000);
  }

  private stopPoll(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private async poll(): Promise<void> {
    const r: ApiResult = await Api.getFresh(this.ctx(), '/api/v1/system/update');
    if (!r.ok) {
      return;
    }
    const log: string = r.data.str('log', '');
    // 日志只留尾部：opkg 一次升级能刷几百行，整段塞进界面没意义
    const lines: string[] = log.split('\n');
    const from: number = Math.max(0, lines.length - 12);
    const tail: string[] = [];
    for (let i = from; i < lines.length; i++) {
      if (lines[i].trim().length > 0) {
        tail.push(lines[i]);
      }
    }
    this.logTail = tail.join('\n');
    if (!r.data.bool('running', false)) {
      this.running = false;
      this.stopPoll();
      promptAction.showToast({ message: '升级结束，正在重新检查' });
      await this.load(false);
    }
  }

  private ctx(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  // ================================================================ 界面

  build() {
    Column() {
      this.head();

      if (this.items.length > 0 || this.q.length > 0) {
        this.searchBar();
      }

      Scroll() {
        Column() {
          if (this.loading) {
            this.stateCard('正在读取可升级的包…');
          } else if (this.err.length > 0) {
            this.errCard();
          } else if (this.items.length === 0) {
            this.stateCard('这台路由器上的软件包都是最新版');
          } else if (this.shown().length === 0) {
            this.stateCard('没有匹配「' + this.q + '」的包');
          } else {
            this.listCard();
          }

          if (this.running || this.logTail.length > 0) {
            this.progressCard();
          }

          Note({ text: '软件包升级只动系统包，不改固件本体。' +
            '固件升级在上一个入口「检查系统更新」。' });
          Row().height(24);
        }
        .width('100%');
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
      .align(Alignment.Top);

      if (this.picked.length > 0 && !this.running) {
        this.bottomBar();
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.safeTop, left: UI.safeLeft, right: UI.safeRight })
    .backgroundColor($r('app.color.app_bg'));
  }

  @Builder
  head() {
    Row() {
      Stack() {
        Stack() {
          GlyphIcon({ kind: Glyph.BACK, color: Pal.textPrimary(), side: 17, lineWidth: 2 });
        }
        .width(30)
        .height(30);
      }
      .width(44)
      .height(44)
      .accessibilityText('返回')
      .clickEffect({ level: ClickEffectLevel.LIGHT })
      .onClick(() => {
        router.back();
      });

      Column() {
        Text('软件包更新')
          .fontSize(T.F_H1)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'));
        Text(this.firmware.length > 0
          ? 'iStoreOS ' + this.firmware + (this.items.length > 0
            ? ' · ' + this.items.length.toString() + ' 个可升级' : ' · 已是最新')
          : '读取中…')
          .fontSize(T.F_TINY)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 2 });
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 2 });
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: T.PAD - 4, right: T.PAD, top: 6, bottom: 8 });
  }

  @Builder
  searchBar() {
    Row({ space: 8 }) {
      Row() {
        GlyphIcon({ kind: Glyph.SEARCH, color: Pal.textTertiary(), side: 15, lineWidth: 1.9 });
        TextInput({ text: this.q, placeholder: '搜索包名' })
          .placeholderColor($r('app.color.text_tertiary'))
          .placeholderFont({ size: T.F_BODY })
          .fontSize(T.F_BODY)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor(Color.Transparent)
          .padding({ left: 6 })
          .layoutWeight(1)
          .height(40)
          .onChange((v: string) => {
            this.q = v;
          });
        if (this.q.length > 0) {
          Text('×')
            .fontSize(T.F_H1)
            .fontColor($r('app.color.text_tertiary'))
            .padding({ left: 6, right: 10 })
            .onClick(() => {
              this.q = '';
            });
        }
      }
      .layoutWeight(1)
      .height(40)
      .borderRadius(T.R_SM)
      .backgroundColor($r('app.color.surface'))
      .border({ width: 0.7, color: $r('app.color.glass_stroke') })
      .padding({ left: 11 })
      .alignItems(VerticalAlign.Center);

      Text(this.refreshing ? '刷新中' : '刷新')
        .fontSize(T.F_SUB)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.refreshing ? $r('app.color.text_tertiary') : $r('app.color.primary'))
        .padding({ left: 12, right: 12, top: 5, bottom: 5 })
        .borderRadius(T.R_SM)
        .backgroundColor($r('app.color.accent_soft'))
        .constraintSize({ minHeight: 40, minWidth: 44 })
        .textAlign(TextAlign.Center)
        .clickEffect({ level: ClickEffectLevel.LIGHT })
        .onClick(() => {
          if (!this.refreshing) {
            // refresh=true 会先 opkg update 拉一次索引，慢几秒但结果可信
            this.load(true);
          }
        });
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: T.PAD, right: T.PAD, bottom: 10 });
  }

  @Builder
  stateCard(text: string) {
    Card({ gapBottom: T.GAP }) {
      Text(text)
        .fontSize(T.F_BODY)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 18, bottom: 18 });
    }
  }

  @Builder
  errCard() {
    Card({ gapBottom: T.GAP }) {
      Row({ space: 8 }) {
        GlyphIcon({ kind: Glyph.STATUS_WARNING, color: Pal.warn(), side: 17, lineWidth: 1.9 });
        Text('读取失败')
          .fontSize(T.F_BODY)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'));
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      Text(this.err)
        .fontSize(T.F_SUB)
        .fontColor($r('app.color.text_secondary'))
        .lineHeight(20)
        .width('100%')
        .margin({ top: 8 });

      Text('重新读取')
        .fontSize(T.F_SUB)
        .fontColor($r('app.color.primary'))
        .padding({ left: 14, right: 14, top: 6, bottom: 6 })
        .borderRadius(T.R_SM)
        .backgroundColor($r('app.color.accent_soft'))
        .constraintSize({ minHeight: 44 })
        .textAlign(TextAlign.Center)
        .margin({ top: 12 })
        .onClick(() => {
          this.load(true);
        });
    }
  }

  @Builder
  listCard() {
    Card({ pad: 0, gapBottom: T.GAP }) {
      // 表头：全选 + 计数
      Row() {
        Row({ space: 8 }) {
          Checkbox()
            .select(this.allPicked())
            .selectedColor($r('app.color.primary'))
            .width(22)
            .height(22)
            .onChange((on: boolean) => {
              if (on !== this.allPicked()) {
                this.toggleAll();
              }
            });
          Text(this.allPicked() ? '取消全选' : '全选')
            .fontSize(T.F_SUB)
            .fontColor($r('app.color.text_primary'));
        }
        .constraintSize({ minHeight: 44 })
        .onClick(() => {
          this.toggleAll();
        });

        Blank();

        Text(this.items.length.toString() + ' 个可升级')
          .fontSize(T.F_TINY)
          .fontColor($r('app.color.text_secondary'));
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: T.CARD_PAD, right: T.CARD_PAD, top: 10, bottom: 6 });

      ForEach(this.shown(), (it: PkgUpd) => {
        Column() {
          Hairline({ indent: T.CARD_PAD });
          Row({ space: 10 }) {
            Checkbox()
              .select(this.isPicked(it.name))
              .selectedColor($r('app.color.primary'))
              .width(22)
              .height(22)
              .onChange(() => {
                this.toggle(it.name);
              });
            Column() {
              Text(it.name)
                .fontSize(T.F_BODY)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .fontFeature("\"tnum\" on");
              Text(it.current.length > 0
                ? it.current + ' → ' + it.latest
                : it.latest)
                .fontSize(T.F_TINY)
                .fontColor($r('app.color.text_tertiary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ top: 3 })
                .fontFeature("\"tnum\" on");
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1);
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)
          .padding({ left: T.CARD_PAD, right: T.CARD_PAD, top: 10, bottom: 10 })
          .onClick(() => {
            this.toggle(it.name);
          });
        }
        .width('100%');
      }, (it: PkgUpd) => it.name + '|' + it.latest);
    }
  }

  @Builder
  progressCard() {
    Card({ gapBottom: T.GAP }) {
      CardTitle({
        glyph: Glyph.UPGRADE_PROGRESS,
        title: this.running ? '正在升级' : '升级日志',
        sub: this.running ? '别断电，升完会自动重新检查' : '最后一次升级的输出'
      });

      if (this.running) {
        Row() {
          Row()
            .width(6)
            .height(6)
            .borderRadius(3)
            .backgroundColor($r('app.color.primary'))
            .margin({ right: 7 });
          Text('任务在路由器上跑，这一步可能几分钟')
            .fontSize(T.F_TINY)
            .fontColor($r('app.color.text_secondary'));
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ top: 8 });
      }

      if (this.logTail.length > 0) {
        Scroll() {
          Text(this.logTail)
            .fontSize(T.F_TINY)
            .fontColor($r('app.color.text_secondary'))
            .fontFamily('monospace')
            .width('100%');
        }
        .width('100%')
        .height(150)
        .scrollBar(BarState.Off)
        .padding(10)
        .margin({ top: 10 })
        .borderRadius(T.R_XS)
        .backgroundColor($r('app.color.surface_sunken'))
        .align(Alignment.TopStart);
      }
    }
  }

  @Builder
  bottomBar() {
    Row({ space: 10 }) {
      Column() {
        Text('已选 ' + this.picked.length.toString() + ' 个')
          .fontSize(T.F_BODY)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'));
        Text('只升级勾选的包')
          .fontSize(T.F_TINY)
          .fontColor($r('app.color.text_secondary'))
          .margin({ top: 2 });
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);

      Text(this.starting ? '提交中…' : '升级选中')
        .fontSize(T.F_BODY)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.on_primary'))
        .padding({ left: 20, right: 20, top: 10, bottom: 10 })
        .borderRadius(T.R_SM)
        .backgroundColor($r('app.color.primary'))
        .constraintSize({ minHeight: 44 })
        .textAlign(TextAlign.Center)
        .opacity(this.starting ? 0.6 : 1)
        .clickEffect({ level: ClickEffectLevel.LIGHT })
        .onClick(() => {
          this.upgrade();
        });
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: T.PAD, right: T.PAD, top: 10, bottom: 12 })
    .backgroundColor($r('app.color.surface'))
    .border({ width: { top: 0.7 }, color: $r('app.color.glass_stroke') });
  }
}
