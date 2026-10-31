import { common } from '@kit.AbilityKit';
import { Api, ApiResult } from '../../api/Api';
import { J } from '../../core/Json';
import { Fmt } from '../../util/Fmt';
import { Bp } from '../Breakpoint';
import { Pal, T } from '../Theme';
import { Card, CardTitle, Chip, Hairline, Note, Pill, RowCard } from '../Comp';
import { Glyph } from '../comp/Icons';

interface RankItem {
  domain: string;
  count: number;
  share: number;
  list: string;
}

interface DnsHop {
  title: string;
  detail: string;
  tone: string;
  dot: boolean;
}

interface RuleItem {
  id: number;
  name: string;
  enabled: boolean;
  rules: number;
  last: string;
  err: string;
}

/** 可选的自动更新间隔（小时）与短标签。0 = 关闭自动更新 */
const INTERVALS: number[] = [0, 6, 12, 24, 48, 72];
const INTERVAL_TEXT: string[] = ['关闭', '6 小时', '12 小时', '每天', '2 天', '3 天'];

/**
 * 拦截页。
 *
 * DNS 链路用完全自绘的行（圆点 + 竖线 + 两行文字），
 * 不用嵌套布局去拼 —— Android 端这里踩过两次：
 * MATCH_PARENT 高的装饰 View 塞进 wrap_content 的横排会把文字压扁，
 * 而 FrameLayout 里 padding 和 margin 同时设会让圆点偏两次。
 * 直接画最省事。
 *
 * 这一版把「规则更新」单独做成一张卡：在此之前界面上根本看不出规则
 * 到底是谁在更新 —— AGH 自带定时任务（默认 24 小时），按钮只是补一次。
 */
/** 体检项：一条检查 = 名称 + 是否通过 + 一句人话解释 */
interface CheckItem {
  label: string;
  ok: boolean;
  detail: string;
}

/** 查询日志的一行 */
interface LogItem {
  domain: string;
  client: string;
  blocked: boolean;
  clock: string;
}

/** 日志里的客户端：IPv6 太长，只留最后一段（和清单里的短地址一个思路） */
function shortClient(c: string): string {
  if (c.length === 0) {
    return '—';
  }
  if (c.indexOf(':') >= 0) {
    const parts: string[] = c.split(':');
    const tail: string = parts[parts.length - 1];
    return tail.length > 0 ? ('…' + tail) : c;
  }
  const seg: string[] = c.split('.');
  return seg.length === 4 ? (seg[2] + '.' + seg[3]) : c;
}

@Component
export struct ShieldPage {
  @State blocked: number = 0;
  @State queries: number = 0;
  @State percent: number = 0;
  @State modeLabel: string = '';
  @State running: boolean = false;
  @State rules: number = 0;
  @State window: string = '';
  @State top: RankItem[] = [];
  @State hops: DnsHop[] = [];
  @State loaded: boolean = false;
  /** 拦截体检：原来只有安卓有，鸿蒙/iOS 都没有入口 */
  @State checks: CheckItem[] = [];
  @State preflightReady: boolean = false;
  @State preflightMode: string = '';
  /** 查询日志（最近几十条），默认只看被拦的 */
  @State logItems: LogItem[] = [];
  @State logOnlyBlocked: boolean = true;
  @State logTotal: number = 0;

  // ---- 规则更新
  @State ruleAuto: boolean = false;
  @State ruleInterval: number = 0;
  @State ruleNext: string = '';
  @State ruleMsg: string = '';
  @State ruleBusy: boolean = false;
  @State ruleLists: RuleItem[] = [];

  @State winW: number = 360;
  @StorageProp('winW') @Watch('onWidth') winWStore: number = 360;
  @StorageProp('tab') @Watch('onTab') tab: number = 2;

  private timer: number = -1;

  aboutToAppear(): void {
    this.winW = this.winWStore;
    this.load(true);
    if (this.tab === 2) {
      this.startPoll();
    }
  }

  aboutToDisappear(): void {
    this.stopPoll();
  }

  private onWidth(): void {
    this.winW = this.winWStore;
  }

  private onTab(): void {
    if (this.tab === 2) {
      this.startPoll();
      this.load(false);
    } else {
      this.stopPoll();
    }
  }

  private rail(): boolean {
    return Bp.rail(this.winW);
  }

  private startPoll(): void {
    this.stopPoll();
    this.timer = setInterval(() => {
      this.load(false);
    }, 10000);
  }

  private stopPoll(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private ctx(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private async load(withCache: boolean): Promise<void> {
    const ctx = this.ctx();
    if (withCache) {
      const c: ApiResult = await Api.peek(ctx, '/api/v1/adblock');
      if (c.ok) {
        this.apply(c.data);
      }
    }
    const r: ApiResult = await Api.get(ctx, '/api/v1/adblock');
    if (r.ok) {
      this.apply(r.data);
    }
    const t: ApiResult = await Api.get(ctx, '/api/v1/adblock/top?limit=5');
    if (t.ok) {
      this.applyTop(t.data);
    }
    // 规则配置是静态信息，没必要每次轮询都拉
    if (this.ruleLists.length === 0) {
      this.loadRules();
    }
    // 体检和日志只在第一次进来时拉一次：它们不是每 5 秒都会变的东西
    if (this.checks.length === 0) {
      this.loadPreflight();
    }
    if (this.logItems.length === 0) {
      this.loadLog();
    }
    this.loaded = true;
  }

  private apply(j: J): void {
    const stats: J = j.obj('stats');
    this.blocked = stats.num('blocked', 0);
    this.queries = stats.num('queries', 0);
    this.percent = stats.num('percent', 0);
    this.modeLabel = j.str('mode_label', '');
    this.running = j.bool('running', false);
    this.rules = j.obj('filters').num('rules', 0);

    const listening: J = j.obj('listening');
    const port: number = listening.num('port', 53);
    const dnsmasqPort: number = j.num('dnsmasq_port', 0);
    const upstream: string[] = j.strArr('upstream');

    const hops: DnsHop[] = [];
    hops.push({
      title: '内网客户端',
      detail: '所有设备的 DNS 都指向路由器',
      tone: Pal.textSecondary(),
      dot: false
    });
    hops.push({
      title: 'AdGuard Home :' + port,
      detail: this.running ? '正在过滤广告与追踪域名' : '未运行',
      tone: this.running ? Pal.primary() : Pal.textSecondary(),
      dot: true
    });

    // 上游第一条通常是代理的 DNS，后面是分流域名（/lan/ 这类）
    for (let i = 0; i < upstream.length && i < 3; i++) {
      const u: string = upstream[i];
      let label: string = u;
      let note: string = '上游';
      if (u.indexOf('[/') === 0) {
        note = '本地域名分流';
      } else if (u.indexOf(':7874') > 0) {
        note = '走 OpenClash（fake-ip）';
      }
      hops.push({
        title: label,
        detail: note,
        tone: Pal.textSecondary(),
        dot: false
      });
    }

    if (dnsmasqPort > 0) {
      hops.push({
        title: 'dnsmasq :' + dnsmasqPort,
        detail: '.lan / 静态绑定 / hosts 由它兜底',
        tone: Pal.textTertiary(),
        dot: false
      });
    }
    this.hops = hops;
  }

  private applyTop(j: J): void {
    this.window = j.str('window', '');
    const items: J[] = j.arr('items');
    const out: RankItem[] = [];
    for (let i = 0; i < items.length; i++) {
      out.push({
        domain: items[i].str('domain', ''),
        count: items[i].num('count', 0),
        share: items[i].num('share', 0),
        list: items[i].str('list', '')
      });
    }
    this.top = out;
  }

  // ================================================================ 规则更新

  /** 拦截体检：8 项检查，一次读全 */
  private async loadPreflight(): Promise<void> {
    const r: ApiResult = await Api.get(this.ctx(), '/api/v1/adblock/preflight');
    if (!r.ok) {
      return;
    }
    this.preflightReady = r.data.bool('ready', false);
    this.preflightMode = r.data.str('mode_label', '');
    const list: J[] = r.data.arr('checks');
    const out: CheckItem[] = [];
    for (let i = 0; i < list.length; i++) {
      out.push({
        label: list[i].str('label', ''),
        ok: list[i].bool('ok', false),
        detail: list[i].str('detail', '')
      });
    }
    this.checks = out;
  }

  /** 查询日志。只被拦截的 / 全部由 `logOnlyBlocked` 决定 */
  private async loadLog(): Promise<void> {
    const flag: string = this.logOnlyBlocked ? '1' : '0';
    const r: ApiResult = await Api.get(this.ctx(),
      '/api/v1/adblock/log?limit=40&only_blocked=' + flag);
    if (!r.ok) {
      return;
    }
    this.logTotal = r.data.num('total', 0);
    const list: J[] = r.data.arr('items');
    const out: LogItem[] = [];
    for (let i = 0; i < list.length && i < 20; i++) {
      const t: string = list[i].str('time', '');
      out.push({
        domain: list[i].str('domain', ''),
        client: shortClient(list[i].str('client', '')),
        blocked: list[i].bool('blocked', false),
        clock: t.length >= 19 ? t.substring(11, 19) : t
      });
    }
    this.logItems = out;
  }

  private async loadRules(): Promise<void> {
    const r: ApiResult = await Api.get(this.ctx(), '/api/v1/adblock/rules');
    if (r.ok) {
      this.applyRules(r.data);
    }
  }

  private applyRules(j: J): void {
    this.ruleAuto = j.bool('auto', false);
    this.ruleInterval = j.num('interval', 0);

    if (!this.ruleAuto) {
      this.ruleNext = '已关闭，只能手动更新';
    } else {
      const at: string = j.str('next_update', '');
      const left: number = j.num('minutes_left', 0);
      let when: string = '随时';
      if (left > 0 && left < 60) {
        when = Math.round(left) + ' 分钟后';
      } else if (left >= 60) {
        when = Math.round(left / 60) + ' 小时后';
      }
      // next_update 是 "2026-10-26 17:02"，只截到日期够用，时分已经在 when 里
      this.ruleNext = at.length > 5 ? when + '（' + at.substring(5, 10) + '）' : when;
    }

    const list: RuleItem[] = [];
    const items: J[] = j.arr('lists');
    for (let i = 0; i < items.length; i++) {
      const f: J = items[i];
      list.push({
        id: f.num('id', 0),
        name: f.str('name', '—'),
        enabled: f.bool('enabled', false),
        rules: f.num('rules', 0),
        last: f.str('last_updated', ''),
        err: f.str('last_error', '')
      });
    }
    this.ruleLists = list;
  }

  private async setInterval(hours: number): Promise<void> {
    if (this.ruleBusy || hours === this.ruleInterval) {
      return;
    }
    this.ruleBusy = true;
    const body: Record<string, Object> = { 'action': 'set_interval', 'interval': hours };
    const r: ApiResult = await Api.post(this.ctx(), '/api/v1/adblock/rules', body);
    this.ruleBusy = false;
    if (r.ok && r.data.bool('ok', false)) {
      this.applyRules(r.data);
      this.ruleMsg = r.data.str('message', '已更新');
    } else {
      this.ruleMsg = r.ok ? r.data.str('error', '设置失败') : r.error;
      // 失败时把 chip 拉回真实值，别让界面停在用户的意图上
      this.loadRules();
    }
  }

  private async toggleList(id: number, want: boolean): Promise<void> {
    if (this.ruleBusy) {
      return;
    }
    this.ruleBusy = true;
    const body: Record<string, Object> = { 'action': 'toggle', 'id': id, 'enabled': want };
    const r: ApiResult = await Api.post(this.ctx(), '/api/v1/adblock/rules', body);
    this.ruleBusy = false;
    if (r.ok && r.data.bool('ok', false)) {
      // 启用一张大表会真去下载，条数会变，整块重画
      this.applyRules(r.data);
      this.ruleMsg = r.data.str('message', '已更新');
    } else {
      this.ruleMsg = r.ok ? r.data.str('error', '开关失败') : r.error;
      this.loadRules();
    }
  }

  private async refreshNow(): Promise<void> {
    if (this.ruleBusy) {
      return;
    }
    this.ruleBusy = true;
    this.ruleMsg = '正在下载规则，约十秒…';
    const body: Record<string, Object> = { 'action': 'refresh_now' };
    const r: ApiResult = await Api.post(this.ctx(), '/api/v1/adblock/rules', body);
    this.ruleBusy = false;
    if (r.ok && r.data.bool('ok', false)) {
      this.ruleMsg = r.data.str('message', '规则已更新');
      this.applyRules(r.data);
    } else {
      this.ruleMsg = r.ok ? r.data.str('error', '更新失败') : r.error;
    }
  }

  private ruleSub(item: RuleItem): string {
    let s: string = '';
    if (!item.enabled) {
      s = '已停用';
      if (item.rules > 0) {
        s += '　·　上次下载过 ' + Fmt.count(item.rules) + ' 条';
      }
    } else {
      s = Fmt.count(item.rules) + ' 条规则';
      if (item.last.length > 0) {
        s += '　·　' + Fmt.friendlyISO(item.last) + '更新';
      }
    }
    if (item.err.length > 0) {
      s += '　·　上次失败';
    }
    return s;
  }

  // ================================================================ 布局

  build() {
    Scroll() {
      Column() {
        if (this.rail()) {
          // 平板：左「拦了多少」，右「怎么拦的」
          Row({ space: Bp.gap(this.winW) }) {
            Column() {
              this.heroCard();
              this.preflightCard();
              this.dnsCard();
              this.logCard();
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start);

            Column() {
              this.rulesCard();
              this.rankCard();
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start);
          }
          .width('100%')
          .alignItems(VerticalAlign.Top);
        } else {
          Column() {
            this.heroCard();
            this.preflightCard();
            this.dnsCard();
            this.rankCard();
            this.rulesCard();
            this.logCard();
          }
          .width('100%');
        }

        Row().width('100%').height(24);
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .padding({
        left: this.rail() ? 20 : T.PAD,
        right: this.rail() ? 20 : T.PAD,
        top: 8
      });
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .backgroundColor($r('app.color.app_bg'))
    .align(Alignment.Top);
  }

  @Builder
  preflightCard() {
    Card({ gapTop: T.GAP }) {
      Column() {
        Row() {
          Text('拦截体检')
            .fontSize(T.F_H2)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1);
          Text(this.preflightReady ? '全部就绪' : '有待处理')
            .fontSize(T.F_TINY)
            .fontColor(this.preflightReady
              ? $r('app.color.primary')
              : $r('app.color.warn'))
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .borderRadius(99)
            .backgroundColor(this.preflightReady
              ? $r('app.color.accent_soft')
              : Pal.alpha(Pal.warn(), 0.14));
        }
        .width('100%')
        .margin({ bottom: 8 });

        if (this.checks.length === 0) {
          Text('读取中…')
            .fontSize(T.F_SUB)
            .fontColor($r('app.color.text_secondary'));
        } else {
          ForEach(this.checks, (c: CheckItem, i: number) => {
            Row({ space: 8 }) {
              Row()
                .width(6)
                .height(6)
                .borderRadius(3)
                .backgroundColor(c.ok
                  ? $r('app.color.primary')
                  : $r('app.color.warn'))
                .margin({ top: 6 });
              Column() {
                Text(c.label)
                  .fontSize(T.F_BODY)
                  .fontColor($r('app.color.text_primary'));
                Text(c.detail)
                  .fontSize(T.F_TINY)
                  .fontColor($r('app.color.text_tertiary'))
                  .margin({ top: 2 });
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1);
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
            .padding({ top: 7, bottom: 7 });
            if (i < this.checks.length - 1) {
              Hairline({ indent: 14 });
            }
          }, (c: CheckItem, i: number) => c.label + i);
        }
      }
      .width('100%');
    }
  }

  @Builder
  logCard() {
    Card({ gapTop: T.GAP }) {
      Column() {
        Row() {
          Text('最近查询')
            .fontSize(T.F_H2)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1);
          Text(this.logOnlyBlocked ? '只看拦截' : '全部')
            .fontSize(T.F_TINY)
            .fontColor($r('app.color.primary'))
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .borderRadius(99)
            .backgroundColor($r('app.color.accent_soft'))
            .onClick(() => {
              this.logOnlyBlocked = !this.logOnlyBlocked;
              this.logItems = [];
              this.loadLog();
            });
        }
        .width('100%')
        .margin({ bottom: 6 });

        if (this.logItems.length === 0) {
          Text(this.logTotal > 0 ? '这段时间没有被拦截的记录' : '还没有查询记录')
            .fontSize(T.F_SUB)
            .fontColor($r('app.color.text_secondary'))
            .padding({ top: 6, bottom: 6 });
        } else {
          ForEach(this.logItems, (it: LogItem, i: number) => {
            Row({ space: 8 }) {
              Text(it.clock)
                .fontSize(10.5)
                .fontColor($r('app.color.text_tertiary'))
                .fontFeature("\"tnum\" on")
                .width(52);
              Text(it.domain)
                .fontSize(T.F_SUB)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1);
              Text(it.client)
                .fontSize(10.5)
                .fontColor($r('app.color.text_tertiary'))
                .maxLines(1)
                .width(76)
                .textAlign(TextAlign.End);
              if (it.blocked) {
                Text('拦')
                  .fontSize(9.5)
                  .fontColor($r('app.color.danger'))
                  .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                  .borderRadius(5)
                  .backgroundColor(Pal.alpha(Pal.danger(), 0.14));
              }
            }
            .width('100%')
            .padding({ top: 5, bottom: 5 })
            .alignItems(VerticalAlign.Center);
          }, (it: LogItem, i: number) => it.clock + it.domain + i);
        }
      }
      .width('100%');
    }
  }

  @Builder
  heroCard() {
    Column() {
      Row() {
        Text('拦截')
          .fontSize(T.F_TITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.hero_fg'))
          .layoutWeight(1);
        Text(this.modeLabel.length > 0 ? this.modeLabel : '状态未知')
          .fontSize(T.F_TINY)
          .fontColor($r('app.color.hero_fg'))
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .borderRadius(T.R_PILL)
          .backgroundColor(Pal.heroStroke());
      }
      .width('100%')
      .alignItems(VerticalAlign.Top);

      Text(this.percent.toFixed(0) + '%')
        .fontSize(44)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.hero_fg'))
        .fontFeature("\"tnum\" on")
        .margin({ top: 12 });

      Text('的查询请求被拦截')
        .fontSize(T.F_SUB)
        .fontColor($r('app.color.hero_fg_soft'))
        .margin({ top: 2 });

      Row() {
        ShieldStat({ value: Fmt.count(this.blocked), label: '已拦截' }).layoutWeight(1);
        ShieldStat({ value: Fmt.count(this.queries), label: '总查询' }).layoutWeight(1);
        ShieldStat({ value: Fmt.count(this.rules), label: '规则数' }).layoutWeight(1);
      }
      .width('100%')
      .margin({ top: 18 });
    }
    .width('100%')
    .padding(20)
    .borderRadius(T.R_CARD)
    .linearGradient({
      angle: 135,
      colors: [[Pal.heroFrom(), 0.0], [Pal.heroTo(), 1.0]]
    })
    .border({ width: 0.7, color: $r('app.color.hero_stroke') })
    .margin({ bottom: this.rail() ? Bp.gap(this.winW) : T.GAP });
  }

  @Builder
  dnsCard() {
    RowCard({ gapBottom: this.rail() ? 0 : T.GAP }) {
      CardTitle({ glyph: Glyph.GLOBE, title: 'DNS 链路', sub: '请求从设备到解析的完整路径' });
      Column() {
        ForEach(this.hops, (h: DnsHop, i: number) => {
          Column() {
            Row() {
              // 圆点：实心表示这一跳正在生效
              Stack() {
                if (h.dot) {
                  Row()
                    .width(9)
                    .height(9)
                    .borderRadius(5)
                    .backgroundColor(h.tone);
                } else {
                  Row()
                    .width(9)
                    .height(9)
                    .borderRadius(5)
                    .border({ width: 1.4, color: h.tone });
                }
              }
              .width(11)
              .height(11);

              Column() {
                Text(h.title)
                  .fontSize(T.F_BODY)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis });
                Text(h.detail)
                  .fontSize(T.F_TINY)
                  .fontColor($r('app.color.text_secondary'))
                  .maxLines(2)
                  .margin({ top: 2 });
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              .margin({ left: 12 });
            }
            .width('100%')
            .alignItems(VerticalAlign.Top);

            // 竖线：最后一跳不画
            if (i < this.hops.length - 1) {
              Row()
                .width(1.4)
                .height(14)
                .backgroundColor($r('app.color.divider'))
                .margin({ left: 5, top: 3, bottom: 3 });
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start);
        }, (h: DnsHop) => h.title + '|' + h.detail + '|' + h.tone);
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 14 })
      .alignItems(HorizontalAlign.Start);
    }
  }

  @Builder
  rankCard() {
    RowCard({ gapBottom: T.GAP }) {
      CardTitle({
        glyph: Glyph.LIST,
        title: '拦截排行',
        sub: this.window.length > 0 ? this.window : '前 5 名'
      });
      if (this.top.length === 0) {
        Text('还没有拦截记录')
          .fontSize(T.F_BODY)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .padding({ left: 16, right: 16, top: 10, bottom: 14 });
      }
      Column() {
        ForEach(this.top, (r: RankItem, i: number) => {
          Column() {
            if (i > 0) {
              Row()
                .width('100%')
                .height(0.5)
                .backgroundColor($r('app.color.divider'));
            }
            Row({ space: 10 }) {
              Stack() {
                Text((i + 1).toString())
                  .fontSize(T.F_TINY)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(i === 0 ? $r('app.color.hero_fg') : $r('app.color.text_secondary'));
              }
              .width(20)
              .height(20)
              .borderRadius(10)
              .backgroundColor(i === 0 ? $r('app.color.primary') : $r('app.color.surface_hi'));

              Column() {
                Text(r.domain)
                  .fontSize(T.F_BODY)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis });
                Text(r.list.length > 0 ? r.list : r.share.toFixed(1) + '% 的拦截量')
                  .fontSize(T.F_TINY)
                  .fontColor($r('app.color.text_secondary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .margin({ top: 2 });
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1);

              Text(Fmt.count(r.count))
                .fontSize(T.F_SUB)
                .fontColor($r('app.color.text_secondary'))
                .fontFeature("\"tnum\" on");
            }
            .width('100%')
            .padding({ top: 10, bottom: 4 })
            .alignItems(VerticalAlign.Center);

            // 占比条：宽度按 share 归一化，最大项占满
            Row() {
              Row()
                .width(this.barWidth(r.share) + '%')
                .height(3)
                .borderRadius(2)
                .linearGradient({
                  angle: 90,
                  colors: [[Pal.primary(), 0.0], [Pal.primaryDim(), 1.0]]
                });
            }
            .width('100%')
            .height(3)
            .borderRadius(2)
            .backgroundColor($r('app.color.track'))
            .margin({ bottom: 8 });
          }
          .width('100%');
        }, (r: RankItem) => r.domain + '|' + r.count);
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 6 });
    }
  }

  @Builder
  rulesCard() {
    RowCard({ gapBottom: T.GAP }) {
      Row() {
        Column() {
          Text('规则更新')
            .fontSize(T.F_H2)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'));
          Text('自动更新开着的时候，「立即更新」只是提前补一次')
            .fontSize(T.F_TINY)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: 2 });
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1);

        Pill({
          text: this.ruleAuto ? '自动' : '手动',
          tone: this.ruleAuto ? Pal.primary() : Pal.textSecondary()
        });
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 16, right: 16, bottom: 4 });

      // ---- 频率
      Text('自动更新频率')
        .fontSize(12.5)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .padding({ left: 16, right: 16, top: 12 });

      // 两行三列：六个挤一行会把「12 小时」压成两个字
      Column({ space: 8 }) {
        ForEach([0, 1], (rowIdx: number) => {
          Row({ space: 8 }) {
            ForEach([0, 1, 2], (col: number) => {
              Row() {
                Chip({
                  label: INTERVAL_TEXT[rowIdx * 3 + col],
                  on: INTERVALS[rowIdx * 3 + col] === this.ruleInterval,
                  onTap: () => {
                    this.setInterval(INTERVALS[rowIdx * 3 + col]);
                  }
                });
              }
              .layoutWeight(1);
            }, (col: number) => 'c' + col);
          }
          .width('100%');
        }, (rowIdx: number) => 'r' + rowIdx);
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 9 });

      Row() {
        Text('下次更新')
          .fontSize(13.5)
          .fontColor($r('app.color.text_secondary'));
        Blank();
        Text(this.ruleNext.length > 0 ? this.ruleNext : '—')
          .fontSize(13.5)
          .fontColor(this.ruleAuto ? $r('app.color.text_primary') : $r('app.color.warn'))
          .fontFeature("\"tnum\" on");
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 16, right: 16, top: 14, bottom: 2 });

      Row() {
        Button(this.ruleBusy ? '处理中…' : '立即更新规则')
          .type(ButtonType.Normal)
          .borderRadius(13)
          .height(42)
          .width('100%')
          .fontSize(14.5)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.primary'))
          .backgroundColor($r('app.color.accent_soft'))
          .enabled(!this.ruleBusy)
          .onClick(() => {
            this.refreshNow();
          });
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12 });

      if (this.ruleMsg.length > 0) {
        Text(this.ruleMsg)
          .fontSize(T.F_TINY)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .padding({ left: 16, right: 16, top: 8 });
      }

      // ---- 单表开关
      Column() {
        ForEach(this.ruleLists, (item: RuleItem, i: number) => {
          Column() {
            if (i > 0) {
              Row()
                .width('100%')
                .height(0.5)
                .backgroundColor($r('app.color.divider'));
            }
            Row() {
              Column() {
                Text(item.name)
                  .fontSize(14.5)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(item.enabled
                    ? $r('app.color.text_primary')
                    : $r('app.color.text_secondary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis });
                Text(this.ruleSub(item))
                  .fontSize(T.F_TINY)
                  .fontColor(item.err.length > 0
                    ? $r('app.color.danger')
                    : $r('app.color.text_secondary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .margin({ top: 3 });
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1);

              Toggle({ type: ToggleType.Switch, isOn: item.enabled })
                .selectedColor($r('app.color.primary'))
                .switchPointColor($r('app.color.on_primary'))
                .margin({ left: 10 })
                .onChange((v: boolean) => {
                  // 程序化改 isOn 也会回调，状态没变就别打接口
                  if (v !== item.enabled) {
                    this.toggleList(item.id, v);
                  }
                });
            }
            .width('100%')
            .padding({ top: 11, bottom: 11 })
            .alignItems(VerticalAlign.Center);
          }
          .width('100%');
        }, (item: RuleItem) => item.id + '|' + (item.enabled ? '1' : '0') + '|' + item.rules + '|' + item.last);
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 2, bottom: 6 });

      Note({ text: '规则列表越多、拦截越全，但内存和更新流量也越多。停用的表不会参与过滤。' });
    }
  }

  /** 最大 share 占满整条，其余按比例 —— 否则峰值只有 13% 时所有条都很短 */
  private barWidth(share: number): number {
    let max: number = 0.001;
    for (let i = 0; i < this.top.length; i++) {
      max = Math.max(max, this.top[i].share);
    }
    const v: number = Math.max(4, Math.min(100, share / max * 100));
    return Math.round(v);
  }

}

/** 拦截卡的三格。@Builder 按值传参不会刷新，必须用 @Prop 组件 */
@Component
struct ShieldStat {
  @Prop value: string = '';
  @Prop label: string = '';

  build() {
    Column() {
      Text(this.value)
        .fontSize(19)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.hero_fg'))
        .fontFeature("\"tnum\" on")
        .maxLines(1);
      Text(this.label)
        .fontSize(T.F_TINY)
        .fontColor($r('app.color.hero_fg_soft'))
        .margin({ top: 2 });
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .layoutWeight(1);
  }
}
