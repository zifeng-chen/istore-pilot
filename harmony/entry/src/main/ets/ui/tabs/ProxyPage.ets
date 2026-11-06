import { common } from '@kit.AbilityKit';
import { promptAction, router } from '@kit.ArkUI';
import { Api, ApiResult } from '../../api/Api';
import { J } from '../../core/Json';
import { UI, UIState } from '../../core/UIState';
import { Bp } from '../Breakpoint';
import { Pal, T } from '../Theme';
import { Card, CardTitle, Comp, GlyphIcon, GroupBox, Hairline, Note, Pill } from '../Comp';
import { Glyph } from '../comp/Icons';

interface Backend {
  id: string;
  label: string;
  installed: boolean;
  running: boolean;
  nodes: number;
  engine: string;
  /** 包名（luci-app-xxx），安装时显示用 */
  pkg: string;
  /** 内核是否已下载：installed=true 而这里是 false，就是「装了却启不来」 */
  coreReady: boolean;
}

/** 安装环境：决定空态那屏能不能一键装、按钮给什么文案 */
interface SysInfo {
  pkgManager: string;
  distro: string;
  release: string;
  arch: string;
  freeMb: number;
  /** yes | no | unknown —— no 表示源里没有，点了也装不上 */
  repoOc: string;
  repoPw: string;
}

interface InstallErr {
  code: string;
  title: string;
  detail: string;
  suggest: string[];
}

interface InstallState {
  running: boolean;
  done: boolean;
  ok: boolean;
  pct: number;
  step: string;
  index: number;
  total: number;
  installed: string[];
  failed: string[];
  partial: boolean;
  err: InstallErr;
}

interface NodeItem {
  name: string;
  type: string;
  group: string;
  delay: number;
}

interface NodeGroup {
  name: string;
  now: string;
  type: string;
  members: NodeItem[];
}

interface ConfigItem {
  name: string;
  file: string;
  path: string;
  current: boolean;
  size: number;
}

/**
 * 代理页。
 *
 * 两个后端互斥：同一时刻只有一方在跑，因为它们抢 53 端口和转发链。
 * 界面上把「谁是当前生效」放在最前面，而不是列出两个各自的状态 ——
 * 用户关心的是现在走哪条线，不是两个服务各自的开关。
 */
@ComponentV2
export struct ProxyPage {
  @Local backends: Backend[] = [];
  @Local active: string = '';
  @Local groups: NodeGroup[] = [];
  @Local nodeCount: number = 0;
  @Local backend: string = '';
  @Local mode: string = '';
  /** 弹窗里正在看的分组下标，-1 表示没打开 */
  @Local openIdx: number = -1;
  @Local showGroup: boolean = false;
  @Local busy: string = '';
  /** 正在测速的分组名，空串表示空闲 */
  @Local testingGroup: string = '';
  @Local toast: string = '';
  @Local loaded: boolean = false;
  /** 「隐藏超时节点」：偏好存在路由器上，不是本机设置，几台设备看到的是同一份列表 */
  @Local hideTimeout: boolean = false;
  /** 服务端按偏好裁掉了几个，显示在标题右边 */
  @Local hiddenCount: number = 0;

  @Local ui: UIState = UI;
  @Local tab: number = UI.tab;
  @Local winW: number = 360;
  /** 后端启停中，占位防止连点 */
  @Local busyBackend: string = '';
  /** 配置文件列表与当前生效的那个 */
  @Local configs: ConfigItem[] = [];
  @Local currentPath: string = '';
  @Local configBusy: boolean = false;

  // ---- 插件安装（只在「两个都没装」时用得上）
  @Local sys: SysInfo = {
    pkgManager: '', distro: '', release: '', arch: '', freeMb: 0,
    repoOc: '', repoPw: ''
  };
  @Local inst: InstallState = {
    running: false, done: false, ok: false, pct: 0, step: '',
    index: 0, total: 0, installed: [], failed: [], partial: false,
    err: { code: '', title: '', detail: '', suggest: [] }
  };
  /** 安装相关的弹窗（确认 / 失败共用一个 sheet，靠 sheetMode 分辨内容） */
  @Local showSheet: boolean = false;
  @Local sheetMode: string = '';
  @Local askTarget: string = '';
  @Local showFail: boolean = false;
  @Local failTitle: string = '';
  @Local failCode: string = '';
  @Local failDetail: string = '';
  @Local failSuggest: string[] = [];

  private timer: number = -1;
  private installTimer: number = -1;

  aboutToAppear(): void {
    this.winW = this.ui.winW;
    this.load(true);
    // 任务在 Agent 侧跑，切走再回来要能接上进度
    this.resumeInstall();
    if (this.tab === 2) {
      this.startPoll();
    }
  }

  aboutToDisappear(): void {
    this.stopPoll();
    this.stopInstallPoll();
  }

  @Monitor('ui.winW')
  onWidth(): void {
    this.winW = this.ui.winW;
  }

  private rail(): boolean {
    return Bp.rail(this.winW);
  }

  @Monitor('ui.tab')
  onTab(): void {
    this.tab = this.ui.tab;
    if (this.tab === 2) {
      this.startPoll();
      this.load(false);
    } else {
      this.stopPoll();
    }
  }

  private startPoll(): void {
    this.stopPoll();
    // 节点延迟是实时量，但没必要太密：15 秒足够
    this.timer = setInterval(() => {
      this.loadGroups();
    }, 15000);
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

  // ------------------------------------------------------- 插件安装
  //
  // 空态（两个都没装）时这一页要回答一个问题：「我该装哪个」。
  // 所以不摆两行「未安装」的空卡片，改成解释 + 一键装 + 单独装。

  private noneInstalled(): boolean {
    if (this.backends.length === 0) {
      return false;
    }
    for (let i = 0; i < this.backends.length; i++) {
      if (this.backends[i].installed) {
        return false;
      }
    }
    return true;
  }

  private repoOf(id: string): string {
    return id === 'openclash' ? this.sys.repoOc : this.sys.repoPw;
  }

  private labelOf(id: string): string {
    return id === 'openclash' ? 'OpenClash' : 'Passwall';
  }

  private descOf(id: string): string {
    return id === 'openclash'
      ? '按域名规则分流，支持 fake-ip'
      : '轻量，Xray 内核，依赖少';
  }

  private pkgOf(id: string): string {
    return id === 'openclash' ? 'luci-app-openclash' : 'luci-app-passwall';
  }

  /** 源里有就走源；没有就得从官方发布页下（国内常失败，文案要说明） */
  private repoHint(id: string): string {
    const r: string = this.repoOf(id);
    if (r === 'yes') {
      return '软件源里有 · 可直接安装';
    }
    if (r === 'no') {
      return '软件源里没有 · 从官方发布页下载';
    }
    return '还没刷新软件源 · 可以试试';
  }

  private sysLine(): string {
    const bits: string[] = [];
    const dr: string = this.sys.distro;
    if (dr.length > 0) {
      bits.push(this.sys.release.length > 0 ? dr + ' ' + this.sys.release : dr);
    }
    if (this.sys.pkgManager.length > 0) {
      bits.push(this.sys.pkgManager);
    }
    if (this.sys.arch.length > 0) {
      bits.push(this.sys.arch);
    }
    return bits.join(' · ');
  }

  /** @Local 只追踪整体赋值 —— 改 this.inst.xxx 不会刷新，必须造新对象 */
  private freshInst(step: string, total: number, running: boolean): InstallState {
    return {
      running: running, done: false, ok: false, pct: 0, step: step,
      index: 0, total: total, installed: [], failed: [], partial: false,
      err: { code: '', title: '', detail: '', suggest: [] }
    };
  }

  private applyInstall(j: J): void {
    const e: J = j.obj('error');
    this.inst = {
      running: j.bool('running', false),
      done: j.bool('done', false),
      ok: j.bool('ok', false),
      pct: j.num('pct', 0),
      step: j.str('step', ''),
      index: j.num('index', 0),
      total: j.num('total', 0),
      installed: j.strs('installed'),
      failed: j.strs('failed'),
      partial: j.bool('partial', false),
      err: {
        code: e.str('error_code', ''),
        title: e.str('error_title', ''),
        detail: e.str('detail', ''),
        suggest: e.strs('suggest')
      }
    };
  }

  private applyFailRaw(code: string, title: string, detail: string,
    suggest: string[]): void {
    this.failCode = code;
    this.failTitle = title;
    this.failDetail = detail;
    this.failSuggest = suggest;
    this.sheetMode = 'fail';
    this.showSheet = true;
  }

  /** 服务端的失败结构是平的（error_code / error_title / detail / suggest） */
  private applyFailOf(j: J): void {
    this.applyFailRaw(j.str('error_code', 'unknown'),
      j.str('error_title', '安装失败'), j.str('detail', ''), j.strs('suggest'));
  }

  private askInstall(target: string): void {
    this.askTarget = target;
    this.sheetMode = 'ask';
    this.showSheet = true;
  }

  private async doInstall(force: boolean): Promise<void> {
    const target: string = this.askTarget;
    this.showSheet = false;
    const total: number = target === 'all' ? 2 : 1;
    this.inst = this.freshInst('准备中', total, true);

    const body: Record<string, Object> = {
      'target': target, 'confirm': 'install', 'force': force
    };
    const r: ApiResult = await Api.post(this.ctx(), '/api/v1/proxy/install', body);
    if (!r.ok) {
      this.inst = this.freshInst('', total, false);
      this.applyFailRaw('net_unreachable', '连不上 Agent', r.error, ['retry']);
      return;
    }
    if (!r.data.bool('ok', true)) {
      this.inst = this.freshInst('', total, false);
      this.applyFailOf(r.data);
      return;
    }
    this.startInstallPoll();
  }

  private startInstallPoll(): void {
    this.stopInstallPoll();
    this.installTimer = setInterval(() => {
      this.pollInstall();
    }, 1000);
  }

  private stopInstallPoll(): void {
    if (this.installTimer >= 0) {
      clearInterval(this.installTimer);
      this.installTimer = -1;
    }
  }

  private async pollInstall(): Promise<void> {
    const r: ApiResult = await Api.get(this.ctx(), '/api/v1/proxy/install');
    if (!r.ok) {
      return;
    }
    this.applyInstall(r.data);
    if (this.inst.err.code.length > 0 && !this.showSheet) {
      this.failCode = this.inst.err.code;
      this.failTitle = this.inst.err.title;
      this.failDetail = this.inst.err.detail;
      this.failSuggest = this.inst.err.suggest;
      this.sheetMode = 'fail';
      this.showSheet = true;
    }
    if (!this.inst.running && this.inst.done) {
      this.stopInstallPoll();
      this.load(true);
      if (this.inst.ok) {
        this.toast = '装好了 · 导入订阅后再启动';
      }
    }
  }

  /** 重进页面时接上还在跑的任务（任务在 Agent 侧，杀 App 也不中断） */
  private async resumeInstall(): Promise<void> {
    const r: ApiResult = await Api.get(this.ctx(), '/api/v1/proxy/install');
    if (!r.ok) {
      return;
    }
    this.applyInstall(r.data);
    if (this.inst.running) {
      this.startInstallPoll();
    }
  }

  private async load(withCache: boolean): Promise<void> {
    const ctx = this.ctx();
    if (withCache) {
      const c: ApiResult = await Api.peek(ctx, '/api/v1/proxy');
      if (c.ok) {
        this.applyBackends(c.data);
      }
    }
    const r: ApiResult = await Api.get(ctx, '/api/v1/proxy');
    if (r.ok) {
      this.applyBackends(r.data);
    }
    await this.loadGroups();
    await this.loadMode();
    await this.loadConfigs();
    this.loaded = true;
  }

  private applyBackends(j: J): void {
    this.active = j.str('active', 'none');
    const list: J[] = j.arr('backends');
    const out: Backend[] = [];
    for (let i = 0; i < list.length; i++) {
      const b: J = list[i];
      out.push({
        id: b.str('id', ''),
        label: b.str('label', ''),
        installed: b.bool('installed', false),
        running: b.bool('running', false),
        nodes: b.num('node_count', 0),
        engine: b.str('engine', ''),
        pkg: b.str('pkg', ''),
        coreReady: b.bool('core_ready', false)
      });
    }
    this.backends = out;

    const sys: J = j.obj('system');
    const repo: J = sys.obj('repo');
    this.sys = {
      pkgManager: sys.str('pkg_manager', ''),
      distro: sys.str('distro', ''),
      release: sys.str('release', ''),
      arch: sys.str('arch', ''),
      freeMb: sys.num('free_mb', 0),
      repoOc: repo.str('openclash', 'unknown'),
      repoPw: repo.str('passwall', 'unknown')
    };
  }

  private async loadGroups(): Promise<void> {
    const r: ApiResult = await Api.get(this.ctx(), '/api/v1/proxy/groups');
    if (!r.ok) {
      return;
    }
    this.backend = r.data.str('backend', '');
    this.nodeCount = r.data.num('node_count', 0);
    // 开关状态跟服务端对齐：可能在另一台手机上改过
    this.hideTimeout = r.data.bool('hide_timeout', this.hideTimeout);
    this.hiddenCount = r.data.num('hidden', 0);

    const list: J[] = r.data.arr('groups');
    const out: NodeGroup[] = [];
    for (let i = 0; i < list.length; i++) {
      const g: J = list[i];
      const members: J[] = g.arr('members');
      const nodes: NodeItem[] = [];
      for (let k = 0; k < members.length; k++) {
        const m: J = members[k];
        nodes.push({
          name: m.str('name', ''),
          type: m.str('type', ''),
          group: g.str('name', ''),
          delay: m.num('delay', 0)
        });
      }
      out.push({
        name: g.str('name', ''),
        now: g.str('now', ''),
        type: g.str('type', ''),
        members: nodes
      });
    }
    this.groups = out;
  }

  /**
   * 切换「隐藏超时节点」。
   *
   * 写的是路由器上的偏好（/api/v1/proxy/prefs），不是这台手机的设置：
   * 同一张网里每台设备、以及 Web 端读到的是同一个值。
   * 写完重新拉一次分组 —— 过滤在服务端做，客户端只负责显示。
   */
  private async setHideTimeout(on: boolean): Promise<void> {
    if (on === this.hideTimeout) {
      return;
    }
    this.hideTimeout = on;
    const r: ApiResult = await Api.post(this.ctx(), '/api/v1/proxy/prefs',
      { 'hide_timeout': on });
    if (!r.ok) {
      this.hideTimeout = !on;
      promptAction.showToast({ message: r.error.length > 0 ? r.error : '设置没保存' });
      return;
    }
    this.hideTimeout = r.data.bool('hide_timeout', on);
    await this.loadGroups();
  }

  private async loadConfigs(): Promise<void> {
    const r: ApiResult = await Api.get(this.ctx(), '/api/v1/proxy/configs');
    if (!r.ok) {
      return;
    }
    this.currentPath = r.data.str('current', '');
    const list: J[] = r.data.arr('configs');
    const out: ConfigItem[] = [];
    for (let i = 0; i < list.length; i++) {
      const c: J = list[i];
      out.push({
        name: c.str('name', ''),
        file: c.str('file', ''),
        path: c.str('path', ''),
        current: c.bool('current', false),
        size: c.num('size', 0)
      });
    }
    this.configs = out;
  }

  /** 后端启停：两个后端互斥，切过去 = 改 uci + 重启内核 */
  private async toggleBackend(id: string, start: boolean): Promise<void> {
    if (this.busyBackend.length > 0) {
      return;
    }
    this.busyBackend = id;
    const body: Record<string, Object> = { 'action': start ? 'start' : 'stop', 'backend': id };
    const r: ApiResult = await Api.post(this.ctx(), '/api/v1/proxy/service', body);
    this.busyBackend = '';
    this.toast = r.ok ? (start ? '已启动，正在生效' : '已停止')
      : ('操作失败：' + (r.error.length > 0 ? r.error : '未知错误'));
    await this.load(false);
  }

  /** 切换配置文件 = uci set + commit + 重启内核，断网十几秒 */
  private async switchConfig(path: string): Promise<void> {
    if (this.configBusy) {
      return;
    }
    this.configBusy = true;
    this.toast = '切换中（会重启内核，断网十几秒）…';
    const r: ApiResult = await Api.post(this.ctx(), '/api/v1/proxy/config', { 'path': path });
    this.configBusy = false;
    this.toast = r.ok ? '已切换' : ('切换失败：' + r.error);
    await this.loadConfigs();
  }

  private async loadMode(): Promise<void> {
    const r: ApiResult = await Api.get(this.ctx(), '/api/v1/proxy/mode');
    if (r.ok) {
      let m: string = r.data.str('mode', '');
      if (m.length === 0) {
        m = r.data.obj('data').str('mode', '');
      }
      if (m.length > 0) {
        this.mode = m;
      }
    }
  }

  /** 延迟三档配色：绿 <150 / 琥珀 <350 / 红 */
  private delayHex(ms: number): string {
    if (ms <= 0) {
      return Pal.textSecondary();
    }
    if (ms < 150) {
      return Pal.ok();
    }
    if (ms < 350) {
      return Pal.warn();
    }
    return Pal.danger();
  }

  /** 整组测速：OpenClash 由内核并发打完，Passwall 走并发 TCP 探测 */
  private async testGroup(name: string): Promise<void> {
    if (this.testingGroup.length > 0) {
      this.toast = '正在测速，稍等';
      return;
    }
    this.testingGroup = name;
    const body: Record<string, Object> = { 'group': name, 'timeout': 3000 };
    const r: ApiResult = await Api.post(this.ctx(), '/api/v1/proxy/delays', body);
    this.testingGroup = '';
    if (!r.ok || !r.data.bool('ok', false)) {
      this.toast = '测速失败：' + (r.ok ? r.data.str('error', '没有结果') : r.error);
      return;
    }
    const delays: Record<string, number> = r.data.numMap('delays');
    const next: NodeGroup[] = [];
    let ok: number = 0;
    for (let i = 0; i < this.groups.length; i++) {
      const g: NodeGroup = this.groups[i];
      const members: NodeItem[] = [];
      for (let k = 0; k < g.members.length; k++) {
        const m: NodeItem = g.members[k];
        const ms: number | undefined = delays[m.name];
        if (ms !== undefined && ms > 0) {
          ok = ok + 1;
        }
        members.push({
          name: m.name,
          type: m.type,
          group: m.group,
          delay: ms === undefined ? m.delay : ms
        });
      }
      next.push({ name: g.name, now: g.now, type: g.type, members: members });
    }
    this.groups = next;
    this.toast = ok > 0 ? ('测速完成：' + ok + ' 个节点可达') : '测速完成，没有可用结果';
  }

  private async pickNode(group: string, name: string): Promise<void> {
    if (this.busy.length > 0) {
      return;
    }
    this.busy = group + '/' + name;
    const body: Record<string, Object> = { 'name': name, 'group': group };
    const r: ApiResult = await Api.post(this.ctx(), '/api/v1/proxy/select', body);
    this.busy = '';
    if (r.ok && r.data.bool('ok', true)) {
      this.toast = '已切换到 ' + name;
      this.showGroup = false;
      await this.loadGroups();
    } else {
      this.toast = r.ok ? r.data.str('error', '切换失败') : r.error;
    }
    setTimeout(() => {
      this.toast = '';
    }, 2400);
  }

  private async setMode(m: string): Promise<void> {
    if (this.mode === m) {
      return;
    }
    const body: Record<string, Object> = { 'mode': m };
    const r: ApiResult = await Api.post(this.ctx(), '/api/v1/proxy/mode', body);
    if (r.ok) {
      this.mode = m;
      this.toast = '模式已切换';
    } else {
      this.toast = r.error;
    }
    setTimeout(() => {
      this.toast = '';
    }, 2400);
  }

  build() {
    Scroll() {
      Column() {
        Row() {
          Text('代理')
            .fontSize(T.F_TITLE)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1);
          Text(this.nodeCount > 0 ? this.nodeCount + ' 个节点' : '')
            .fontSize(T.F_SUB)
            .fontColor($r('app.color.text_secondary'));
        }
        .width('100%')
        .alignItems(VerticalAlign.Bottom)
        .padding({ bottom: 12 });

        if (this.noneInstalled()) {
          // 两个都没装：整页换成「教你装」。摆两行未安装的空卡片对用户没信息量，
          // 下面的运行模式、节点分组更是死的
          this.installGuide();
        } else if (this.rail()) {
          // 平板：左边「走哪条线」（后端 + 模式），右边「能选哪些线」（节点分组）
          Row({ space: Bp.gap(this.winW) }) {
            Column() {
              this.backendCard();
              this.modeCard();
              this.configCard();
              this.subsEntry();
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start);

            Column() {
              this.groupList();
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start);
          }
          .width('100%')
          .alignItems(VerticalAlign.Top);
        } else {
          Column() {
            this.backendCard();
            this.modeCard();
            this.configCard();
            this.subsEntry();
            this.groupList();
          }
          .width('100%');
        }

        Row().width('100%').height(24);
      }
      .width('100%')
      .constraintSize({ maxWidth: Bp.CONTENT_MAX })
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
    .align(Alignment.Top)
    .bindSheet($$this.showGroup, this.nodeSheet(), {
      height: 560,
      dragBar: true,
      backgroundColor: $r('app.color.app_bg'),
      onDisappear: () => {
        this.showGroup = false;
      }
    });
  }

  // ------------------------------------------------- 空态：装插件
  //
  // 两个都没装时，这一页的价值不是「报告没装」，而是「教你怎么装」。
  // 所以不摆两行未安装的空卡片，改成：解释 → 一键装 → 单独装。

  @Builder
  installGuide() {
    Column() {
      Card() {
        Row() {
          GlyphIcon({ kind: Glyph.POWER, color: Pal.primary(), side: 22 });
          Column() {
            Text('还没有代理插件')
              .fontSize(T.F_H2)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'));
            Text('装一个才能在这里选节点、切模式')
              .fontSize(T.F_TINY)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: 3 });
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          .margin({ left: 12 });
        }
        .width('100%')
        .alignItems(VerticalAlign.Center);
      }

      if (this.inst.running) {
        this.installProgress();
      } else {
        this.installChoices();
      }
    }
    .width('100%')
    .bindSheet($$this.showSheet, this.installSheet(), {
      height: this.sheetMode === 'ask' ? 360 : 440,
      dragBar: true,
      backgroundColor: $r('app.color.app_bg'),
      onDisappear: () => {
        this.showSheet = false;
      }
    });
  }

  @Builder
  installChoices() {
    Column() {
      // 一键：省掉「选哪个」这一步决策
      Column() {
        Text('一键全部安装')
          .fontSize(T.F_H2)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_primary'));
        Text('两个都装 · 之后选一个启动')
          .fontSize(T.F_TINY)
          .fontColor($r('app.color.on_primary'))
          .opacity(0.82)
          .margin({ top: 3 });
      }
      .width('100%')
      .padding({ top: 15, bottom: 15 })
      .backgroundColor($r('app.color.primary'))
      .borderRadius(T.R_CARD)
      .margin({ top: T.GAP })
      .onClick(() => {
        this.askInstall('all');
      });

      Text('或者只装一个')
        .fontSize(T.F_TINY)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ top: T.GAP, bottom: 2 });

      this.oneCard('openclash');
      this.oneCard('passwall');

      Note({ text: this.sysLine() + (this.sysLine().length > 0 ? '\n' : '')
        + '装完不会自动启动：先导入订阅，再回这里启动' });
    }
    .width('100%');
  }

  @Builder
  oneCard(id: string) {
    Card({ gapTop: T.GAP }) {
      Row() {
        Column() {
          Text(this.labelOf(id))
            .fontSize(T.F_H2)
            .fontColor($r('app.color.text_primary'));
          Text(this.descOf(id))
            .fontSize(T.F_TINY)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: 2 });
          Text(this.repoHint(id))
            .fontSize(T.F_TINY)
            .fontColor(this.repoOf(id) === 'no'
              ? $r('app.color.warn')
              : $r('app.color.text_tertiary'))
            .margin({ top: 4 });
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1);

        Text(this.repoOf(id) === 'yes' ? '安装' : '下载安装')
          .fontSize(T.F_SUB)
          .fontColor($r('app.color.primary'))
          .padding({ left: 12, right: 12, top: 5, bottom: 5 })
          .borderRadius(99)
          .backgroundColor($r('app.color.accent_soft'))
          .margin({ left: 8 })
          .onClick(() => {
            this.askInstall(id);
          });
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);
    }
  }

  @Builder
  installProgress() {
    Card({ gapTop: T.GAP }) {
      CardTitle({
        glyph: Glyph.BOLT,
        title: this.inst.index > 0 && this.inst.total > 0
          ? '正在安装 ' + this.inst.index + ' / ' + this.inst.total
          : '正在安装',
        sub: this.inst.step
      });
      // 进度条自己画：复用组件里没有细长条，为一个地方加一个不划算
      Stack({ alignContent: Alignment.Start }) {
        Row()
          .width('100%')
          .height(6)
          .borderRadius(3)
          .backgroundColor($r('app.color.track'));
        Row()
          .width(Math.max(0, Math.min(100, this.inst.pct)) + '%')
          .height(6)
          .borderRadius(3)
          .backgroundColor($r('app.color.primary'));
      }
      .width('100%')
      .height(6)
      .margin({ top: 14, bottom: 10 });

      Text('装第二个之前会等 opkg 锁释放，别退出')
        .fontSize(T.F_TINY)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%');
    }
  }

  /** 确认与失败共用一个 sheet：同一个组件上挂两个 bindSheet 会打架 */
  @Builder
  installSheet() {
    Column() {
      Row() {
        Text(this.sheetMode === 'ask'
          ? (this.askTarget === 'all' ? '安装两个插件' : '安装 ' + this.labelOf(this.askTarget))
          : this.failTitle)
          .fontSize(T.F_H1)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
          .maxLines(2);
        Text('关闭')
          .fontSize(T.F_SUB)
          .fontColor($r('app.color.text_secondary'))
          .padding({ left: 8, top: 4, bottom: 4 })
          .onClick(() => {
            this.showSheet = false;
          });
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .padding({ bottom: 14 });

      if (this.sheetMode === 'ask') {
        this.askBody();
      } else {
        this.failBody();
      }
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 18, bottom: 20 });
  }

  @Builder
  askBody() {
    Column() {
      Text(this.askTarget === 'all'
        ? '会把 OpenClash 和 Passwall 都装上（约 20 MB），装完选一个启动。'
        : '安装 ' + this.pkgOf(this.askTarget) + '，装完不会自动启动。')
        .fontSize(T.F_SUB)
        .fontColor($r('app.color.text_primary'))
        .lineHeight(20)
        .width('100%');

      Text('安装包会以 root 权限执行安装脚本，过程中请不要关闭 App 或重启路由器。')
        .fontSize(T.F_TINY)
        .fontColor($r('app.color.text_secondary'))
        .lineHeight(18)
        .width('100%')
        .margin({ top: 10 });

      Row({ space: 10 }) {
        Text('取消')
          .fontSize(T.F_SUB)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .padding({ top: 11, bottom: 11 })
          .borderRadius(99)
          .backgroundColor($r('app.color.surface_sunken'))
          .onClick(() => {
            this.showSheet = false;
          });
        Text('开始安装')
          .fontSize(T.F_SUB)
          .fontColor($r('app.color.on_primary'))
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .padding({ top: 11, bottom: 11 })
          .borderRadius(99)
          .backgroundColor($r('app.color.primary'))
          .onClick(() => {
            this.doInstall(false);
          });
      }
      .width('100%')
      .margin({ top: 18 });
    }
    .width('100%');
  }

  @Builder
  failBody() {
    Column() {
      if (this.failDetail.length > 0) {
        Text(this.failDetail)
          .fontSize(T.F_SUB)
          .fontColor($r('app.color.text_primary'))
          .lineHeight(20)
          .width('100%');
      }
      Text(this.failCode === 'net_unreachable' || this.failCode === 'dns_failed'
        ? '路由器当前可能上不了外网，或软件源/官方发布页不可达。'
        : '可以重试一次；反复失败就先更新软件源，或手动下载 ipk 上传安装。')
        .fontSize(T.F_TINY)
        .fontColor($r('app.color.text_secondary'))
        .lineHeight(18)
        .width('100%')
        .margin({ top: 10 });

      Row({ space: 10 }) {
        Text('仍然尝试')
          .fontSize(T.F_SUB)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .padding({ top: 11, bottom: 11 })
          .borderRadius(99)
          .backgroundColor($r('app.color.surface_sunken'))
          .onClick(() => {
            this.doInstall(true);
          });
        Text('重试')
          .fontSize(T.F_SUB)
          .fontColor($r('app.color.on_primary'))
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .padding({ top: 11, bottom: 11 })
          .borderRadius(99)
          .backgroundColor($r('app.color.primary'))
          .onClick(() => {
            this.doInstall(false);
          });
      }
      .width('100%')
      .margin({ top: 18 });
    }
    .width('100%');
  }

  @Builder
  backendCard() {
    Card() {
      CardTitle({
        glyph: Glyph.POWER,
        title: '代理后端',
        sub: this.active === 'none' ? '当前没有代理在运行' : '当前生效：' + this.activeLabel()
      });
      ForEach(this.backends, (b: Backend, i: number) => {
        Column() {
          if (i > 0) {
            Hairline({ indent: 0 });
          }
          Row() {
            Column() {
              Text(b.label)
                .fontSize(T.F_H2)
                .fontColor($r('app.color.text_primary'));
              // 未安装时只写「未安装」：之前无条件拼 engine+nodes，
              // Passwall 的 engine 是硬编码 "Xray"，于是胶囊说未安装、
              // 副标题却写着「Xray · 0 节点」，自相矛盾。
              // 已安装时 engine 可能为空（uci 没读到），也要避免拼出「 · N 个节点」
              Text(b.installed
                ? (b.engine.length > 0 ? b.engine + ' · ' : '') + b.nodes + ' 个节点'
                : '未安装')
                .fontSize(T.F_TINY)
                .fontColor($r('app.color.text_secondary'))
                .margin({ top: 2 });
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1);

            if (!b.installed) {
              Pill({ text: '未安装', tone: Pal.textSecondary() });
            } else if (b.running) {
              Pill({ text: '运行中', tone: Pal.primary() });
            } else {
              Pill({ text: '未运行', tone: Pal.textSecondary() });
            }

            if (b.installed) {
              Text(this.busyBackend === b.id ? '处理中…'
                : (b.running ? '停止' : '启动'))
                .fontSize(T.F_SUB)
                .fontColor(b.running ? $r('app.color.danger') : $r('app.color.primary'))
                .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                .borderRadius(99)
                .backgroundColor(b.running
                  ? Pal.alpha(Pal.danger(), 0.12)
                  : $r('app.color.accent_soft'))
                .margin({ left: 8 })
                .onClick(() => {
                  this.toggleBackend(b.id, !b.running);
                });
            }
          }
          .width('100%')
          .padding({ top: 10, bottom: 10 })
          .alignItems(VerticalAlign.Center);
        }
        .width('100%');
      }, (b: Backend) => b.id + '|' + (b.running ? '1' : '0') + '|' + b.nodes);
    }
  }

  @Builder
  modeCard() {
    Card({ gapTop: T.GAP }) {
      CardTitle({ glyph: Glyph.BOLT, title: '运行模式', sub: '规则模式按域名分流，全局模式全部走代理' });
      // 分段控件必须有「槽」：选中项原来用纯白做底，而卡片也是白的，
      // 三个选项看起来一模一样，根本看不出当前是规则还是全局
      Row({ space: 4 }) {
        this.modeChip('rule', '规则');
        this.modeChip('global', '全局');
        this.modeChip('direct', '直连');
      }
      .width('100%')
      .padding(3)
      .borderRadius(15)
      .backgroundColor($r('app.color.surface_hi'))
      .margin({ top: 12 });
    }
  }

  @Builder
  configCard() {
    Card({ gapTop: T.GAP }) {
      Column() {
        CardTitle({
          glyph: Glyph.BOX,
          title: '配置文件',
          sub: this.configs.length > 0
            ? ('共 ' + this.configs.length + ' 个，点一个切换')
            : '切换会重启内核、断网十几秒'
        });
        ForEach(this.configs, (c: ConfigItem, i: number) => {
          Row({ space: 8 }) {
            Row()
              .width(6)
              .height(6)
              .borderRadius(3)
              .backgroundColor(c.current
                ? $r('app.color.primary')
                : $r('app.color.text_tertiary'))
              .margin({ top: 6 });
            Column() {
              Text(c.name)
                .fontSize(T.F_BODY)
                .fontColor(c.current
                  ? $r('app.color.primary')
                  : $r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis });
              Text(this.fmtSize(c.size))
                .fontSize(T.F_TINY)
                .fontColor($r('app.color.text_tertiary'))
                .fontFeature("\"tnum\" on")
                .margin({ top: 2 });
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1);

            if (c.current) {
              Text('使用中')
                .fontSize(T.F_TINY)
                .fontColor($r('app.color.primary'))
                .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                .borderRadius(99)
                .backgroundColor($r('app.color.accent_soft'));
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          .padding({ top: 9, bottom: 9 })
          .onClick(() => {
            if (!c.current) {
              this.switchConfig(c.path);
            }
          });
          if (i < this.configs.length - 1) {
            Hairline({ indent: 14 });
          }
        }, (c: ConfigItem) => c.path + (c.current ? '1' : '0'));
      }
      .width('100%');
    }
  }

  @Builder
  subsEntry() {
    Card({ gapTop: T.GAP }) {
      Row() {
        // 自定义组件后面不能直接链 .margin()，套一层 Row
        Row() {
          GlyphIcon({ kind: Glyph.LINK, color: Pal.primary(), side: 18, lineWidth: 1.9 });
        }
        .margin({ right: 10 });
        Text('订阅管理')
          .fontSize(T.F_BODY)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1);
        Text('›')
          .fontSize(18)
          .fontColor($r('app.color.text_tertiary'));
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })
      .alignItems(VerticalAlign.Center)
      .onClick(() => {
        router.pushUrl({ url: 'pages/SubscriptionPage' });
      });
    }
  }

  private fmtSize(n: number): string {
    if (n <= 0) {
      return '—';
    }
    if (n < 1048576) {
      return Math.round(n / 1024) + ' KB';
    }
    return (n / 1048576).toFixed(1) + ' MB';
  }

  @Builder
  groupList() {
    if (this.groups.length > 0) {
      Row() {
        Text('节点分组')
          .fontSize(T.F_SUB)
          .fontColor($r('app.color.text_secondary'));
        Blank();
        // 隐藏超时节点：开关放标题行右侧，不占一整行；
        // 状态来自服务端，所以另一台手机 / Web 端改过这里也会跟着变
        Text(this.hideTimeout
          ? (this.hiddenCount > 0 ? '已隐藏 ' + this.hiddenCount + ' 个' : '无超时节点')
          : '隐藏超时')
          .fontSize(T.F_TINY)
          .fontColor($r('app.color.text_secondary'));
        Toggle({ type: ToggleType.Switch, isOn: this.hideTimeout })
          .selectedColor($r('app.color.primary'))
          .margin({ left: 6 })
          .onChange((on: boolean) => {
            // 程序化改 isOn（数据回填 / 其他端改过）也会回调，
            // 状态没变就别打接口 —— 否则每次进代理页都白发一次请求
            if (on !== this.hideTimeout) {
              this.setHideTimeout(on);
            }
          });
      }
      .width('100%')
      .padding({ left: 4, right: 4 })
      .margin({ top: this.rail() ? 0 : 18, bottom: 8 });

      ForEach(this.groupRows(), (row: NodeGroup[]) => {
        Row({ space: 10 }) {
          ForEach(row, (g: NodeGroup) => {
            this.groupCard(g, this.indexOfGroup(g.name));
          }, (g: NodeGroup) => this.groupKey(g));
          if (row.length < this.groupCols()) {
            Blank();
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Top);
      }, (row: NodeGroup[]) => this.groupRowKey(row));
    } else if (this.loaded) {
      // 这里原来一律写「没有正在运行的代理后端」，可上面的卡片明明显示「运行中 ·
      // 63 节点」—— 自相矛盾。分成两种：后端在跑但分组没读到，和后端确实没跑。
      Card({ gapTop: this.rail() ? 0 : T.GAP }) {
        Text(this.anyRunning() ? '节点分组还没读取到' : '没有正在运行的代理后端')
          .fontSize(T.F_H2)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%');
        Text(this.anyRunning()
          ? '后端正在启动或刚切换过配置，这一块会自动重试，不用手动刷新'
          : '在上面选一个后端启动，节点分组和测速才会出现')
          .fontSize(T.F_SUB)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .margin({ top: 4 });
      }
    }
  }

  private groupCols(): number {
    return this.rail() ? 2 : 1;
  }

  private groupRows(): NodeGroup[][] {
    const n: number = this.groupCols();
    const out: NodeGroup[][] = [];
    for (let i = 0; i < this.groups.length; i += n) {
      out.push(this.groups.slice(i, i + n));
    }
    return out;
  }

  private groupRowKey(row: NodeGroup[]): string {
    let k: string = 'g';
    for (let i = 0; i < row.length; i++) {
      k += '|' + this.groupKey(row[i]);
    }
    return k;
  }

  private groupKey(g: NodeGroup): string {
    return g.name + '|' + g.now + '|' + g.members.length;
  }

  private indexOfGroup(name: string): number {
    for (let i = 0; i < this.groups.length; i++) {
      if (this.groups[i].name === name) {
        return i;
      }
    }
    return -1;
  }

  private groupType(t: string): string {
    const k: string = t.toLowerCase();
    if (k === 'selector') {
      return '手动';
    }
    if (k === 'urltest') {
      return '自动测速';
    }
    if (k === 'fallback') {
      return '故障转移';
    }
    if (k === 'loadbalance') {
      return '负载均衡';
    }
    return t.length > 0 ? t : '分组';
  }

  /** 一张分组卡：类型、组名、当前节点、节点数。点开是弹窗里的完整节点表 */
  @Builder
  groupCard(g: NodeGroup, idx: number) {
    Column() {
      Row({ space: 6 }) {
        Text(this.groupType(g.type))
          .fontSize(10)
          .fontColor($r('app.color.text_secondary'))
          .padding({ left: 6, right: 6, top: 2.5, bottom: 2.5 })
          .borderRadius(99)
          .backgroundColor($r('app.color.surface_hi'));
        Blank();
        Text('›')
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_tertiary'))
          .textAlign(TextAlign.Center)
          .width(16)
          .height(16)
          .borderRadius(5)
          .backgroundColor($r('app.color.surface_hi'));
      }
      .width('100%');

      Text(g.name)
        .fontSize(T.F_H2)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 7 });

      Blank();

      Text(g.now.length > 0 ? g.now : '未选择')
        .fontSize(T.F_SUB)
        .fontColor(g.now.length > 0
          ? $r('app.color.primary')
          : $r('app.color.text_tertiary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis });

      Row() {
        Text(g.members.length + ' 个节点')
          .fontSize(10)
          .fontColor($r('app.color.text_tertiary'))
          .fontFeature("\"tnum\" on");
      }
      .width('100%')
      .margin({ top: 4 });
    }
    .layoutWeight(1)
    .height(104)
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .borderRadius(14)
    .backgroundColor($r('app.color.surface_sunken'))
    .border({ width: 0.5, color: $r('app.color.divider') })
    .onClick(() => {
      if (idx >= 0) {
        this.openIdx = idx;
        this.showGroup = true;
      }
    });
  }

  /** 弹窗：一个分组的完整节点表，带测速 */
  @Builder
  nodeSheet() {
    Column() {
      Row({ space: 8 }) {
        Text(this.openIdx >= 0 && this.openIdx < this.groups.length
          ? this.groups[this.openIdx].name
          : '节点')
          .fontSize(T.F_H1)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        Text(this.testingGroup.length > 0 ? '测速中…' : '测速')
          .fontSize(T.F_SUB)
          .fontColor(this.testingGroup.length > 0
            ? $r('app.color.text_secondary')
            : $r('app.color.primary'))
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .borderRadius(99)
          .backgroundColor($r('app.color.accent_soft'))
          .onClick(() => {
            if (this.openIdx >= 0 && this.openIdx < this.groups.length) {
              this.testGroup(this.groups[this.openIdx].name);
            }
          });
        Text('关闭')
          .fontSize(T.F_SUB)
          .fontColor($r('app.color.text_secondary'))
          .padding({ left: 8, right: 2, top: 4, bottom: 4 })
          .onClick(() => {
            this.showGroup = false;
          });
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 16, bottom: 10 });

      if (this.openIdx >= 0 && this.openIdx < this.groups.length) {
        Scroll() {
          Column() {
            GroupBox() {
              ForEach(this.groups[this.openIdx].members, (m: NodeItem) => {
                Row({ space: 10 }) {
                  Stack() {
                    Circle()
                      .width(15)
                      .height(15)
                      .fill(Color.Transparent)
                      .stroke(m.name === this.groups[this.openIdx].now
                        ? $r('app.color.primary')
                        : $r('app.color.text_tertiary'))
                      .strokeWidth(1.4);
                    if (m.name === this.groups[this.openIdx].now) {
                      Circle()
                        .width(7)
                        .height(7)
                        .fill($r('app.color.primary'));
                    }
                  }
                  .width(15)
                  .height(15);

                  Text(m.name)
                    .fontSize(T.F_BODY)
                    .fontColor(m.name === this.groups[this.openIdx].now
                      ? $r('app.color.primary')
                      : $r('app.color.text_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1);

                  if (this.busy === this.groups[this.openIdx].name + '/' + m.name) {
                    Text('切换中…')
                      .fontSize(T.F_TINY)
                      .fontColor($r('app.color.text_secondary'));
                  } else if (m.delay > 0) {
                    Text(m.delay + 'ms')
                      .fontSize(T.F_TINY)
                      .fontColor(this.delayHex(m.delay))
                      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                      .borderRadius(99)
                      .backgroundColor(Comp.alpha(this.delayHex(m.delay), 0.16))
                      .fontFeature("\"tnum\" on");
                  } else if (m.name === this.groups[this.openIdx].now) {
                    Text('使用中')
                      .fontSize(T.F_TINY)
                      .fontColor($r('app.color.primary'));
                  } else {
                    Text('—')
                      .fontSize(T.F_TINY)
                      .fontColor($r('app.color.text_tertiary'));
                  }
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 10, bottom: 10 })
                .alignItems(VerticalAlign.Center)
                .onClick(() => {
                  this.pickNode(this.groups[this.openIdx].name, m.name);
                });
              }, (m: NodeItem) => this.groups[this.openIdx].name + '/' + m.name + '|' + m.delay);
            }
            Row().height(24);
          }
          .width('100%');
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off);
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_bg'));
  }

  /** 有没有任意一个后端处于运行中：用来区分「没装/没启动」和「启动了但没读到分组」 */
  private anyRunning(): boolean {
    for (let i = 0; i < this.backends.length; i++) {
      if (this.backends[i].running) {
        return true;
      }
    }
    return false;
  }

  private activeLabel(): string {
    for (let i = 0; i < this.backends.length; i++) {
      if (this.backends[i].id === this.active) {
        return this.backends[i].label;
      }
    }
    return this.active;
  }

  @Builder
  modeChip(value: string, text: string) {
    Text(text)
      .fontSize(T.F_BODY)
      .fontWeight(this.mode === value ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.mode === value
        ? $r('app.color.primary')
        : $r('app.color.text_secondary'))
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(32)
      .borderRadius(12)
      .backgroundColor(this.mode === value
        ? $r('app.color.segment_thumb')
        : Color.Transparent)
      .shadow({
        radius: this.mode === value ? 3 : 0,
        color: '#14000000',
        offsetY: 1
      })
      .onClick(() => {
        this.setMode(value);
      });
  }
}
