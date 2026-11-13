import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
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

/** 远端仓库里的一个安装包 */
interface PkgItem {
  backend: string;
  label: string;
  version: string;
  /** 本机装着的版本，没装是空串 */
  local: string;
  newer: boolean;
  file: string;
  /** 与哪个后端互斥，空串表示不冲突 */
  conflict: string;
}

/** 下载通道的探测结果：ok=false 表示这条域名不通 */
interface ChanItem {
  id: string;
  label: string;
  ok: boolean;
  ms: number;
}

/**
 * 整包安装任务。
 *
 * 跟 InstallState 是两条独立的线：那个走 opkg 源 / GitHub release 的单个 ipk，
 * 这个走「一个完整 .run」——要么从仓库下，要么用户从手机里传上来。
 */
interface PkgTask {
  running: boolean;
  done: boolean;
  ok: boolean;
  pct: number;
  step: string;
  target: string;
  source: string;
  name: string;
  channel: string;
  got: number;
  total: number;
  /** 非空表示 Agent 停下来等用户确认（当前只有 hosts_fix 一种） */
  waiting: string;
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
  /** 节点区为什么空着（如「OpenClash 没在运行，启动后才看得到节点」） */
  @Local groupsErr: string = '';
  /**
   * 「配置与订阅」卡点名的后端。
   *
   * 订阅和节点**每个后端各一套**（OpenClash 的在 uci + 内核里，PassWall 的在
   * uci 里），一张卡不可能同时管两个。有后端在跑时默认跟它，但允许切到另一个
   * 去整理订阅 —— 切走后副标题会写明「只改配置」，别让人以为把代理切走了。
   */
  @Local comboPick: string = '';
  @Local nodeCount: number = 0;
  @Local backend: string = '';
  @Local mode: string = '';
  /** 弹窗里正在看的分组下标，-1 表示没打开 */
  @Local openIdx: number = -1;
  @Local showGroup: boolean = false;
  /** 配置文件选择弹层：十几个配置全铺在页面上会把节点列表挤到三屏以外 */
  @Local showConfig: boolean = false;
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
  /** 下拉刷新：Refresh 组件要求绑一个布尔，松手后由代码收回去 */
  @Local pulling: boolean = false;
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

  // ---- 整包安装：本地选文件 / 从仓库下载
  @Local showPkg: boolean = false;
  @Local pkgItems: PkgItem[] = [];
  @Local pkgChans: ChanItem[] = [];
  @Local pkgLoading: boolean = false;
  @Local pkgMsg: string = '';
  /** 当前系统画像（如「24.10 · x86_64」），让用户确认按版本选对了包 */
  @Local pkgSys: string = '';
  /** 正在等用户二次确认的后端 id，空串表示没有 */
  @Local pkgConfirm: string = '';
  @Local uploading: boolean = false;
  @Local uploadName: string = '';
  /** 等确认时暂存的来源与文件名（本地包必须带上名字，Agent 才知道装哪个） */
  @Local pendingSource: string = 'github';
  @Local pendingName: string = '';
  @Local pkgTask: PkgTask = {
    running: false, done: false, ok: false, pct: 0, step: '', target: '',
    source: '', name: '', channel: '', got: 0, total: 0, waiting: '',
    err: { code: '', title: '', detail: '', suggest: [] }
  };
  /** 「改 hosts 加速」确认框是否已经弹过（Agent 侧最多等 5 分钟，只问一次） */
  private hostsAsked: boolean = false;

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

  /** 已安装的后端 id */
  private installedIds(): string[] {
    const out: string[] = [];
    for (let i = 0; i < this.backends.length; i++) {
      if (this.backends[i].installed) {
        out.push(this.backends[i].id);
      }
    }
    return out;
  }

  /**
   * 「配置与订阅」这张卡管哪个后端：点名 > 正在运行 > 已装的（PassWall 优先）。
   *
   * 点名优先于「正在运行」是故意的：运行中的那个要跟（改配置立刻生效），
   * 但另一个的订阅也得能整理，不能因为它在跑就把这张卡焊死。
   */
  private comboBackend(): string {
    const ids: string[] = this.installedIds();
    if (this.comboPick.length > 0 && ids.indexOf(this.comboPick) >= 0) {
      return this.comboPick;
    }
    if (this.active.length > 0 && this.active !== 'none') {
      return this.active;
    }
    if (ids.indexOf('passwall') >= 0) {
      return 'passwall';
    }
    return ids.length > 0 ? ids[0] : '';
  }

  /** 管的后端是不是「正在跑的那个」：不是的话副标题要提醒只改配置 */
  private comboIsActive(): boolean {
    return this.active.length > 0 && this.active !== 'none'
      && this.comboBackend() === this.active;
  }

  private comboSub(): string {
    if (this.active.length > 0 && this.active !== 'none' && !this.comboIsActive()) {
      return '只改配置，不影响正在运行的 ' + this.labelOf(this.active);
    }
    if (this.comboBackend() === 'passwall') {
      return 'PassWall 的节点来自订阅，没有配置文件';
    }
    if (!this.comboIsActive()) {
      return 'OpenClash 没在运行，启动后才看得到节点';
    }
    return '换配置会重启内核，断网十几秒';
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
    // 整包安装是另一条任务线，同一个接口顺带返回，接上就行
    this.applyPkg(j.obj('pkg'));
  }

  private applyPkg(j: J): void {
    const e: J = j.obj('error');
    this.pkgTask = {
      running: j.bool('running', false),
      done: j.bool('done', false),
      ok: j.bool('ok', false),
      pct: j.num('pct', 0),
      step: j.str('step', ''),
      target: j.str('target', ''),
      source: j.str('source', ''),
      name: j.str('name', ''),
      channel: j.str('channel', ''),
      got: j.num('got', 0),
      total: j.num('total', 0),
      waiting: j.str('waiting', ''),
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

  // ------------------------------------------------- 整包安装：本地 / 仓库
  //
  // 这是「软件源里根本没有这两个包」的正解，两条路：
  //   1. 用户自己从手机/电脑传 .run 上来 —— 完全不依赖路由器能不能上外网
  //   2. 从 Are-u-ok 仓库下 —— 只解析 3.4KB 的 README，不走 GitHub API
  //     （api.github.com 在这类网络里常 403，jsDelivr 又卡 20MB 单文件上限）
  // 两条最终都是 `sh <文件>` 跑 Makeself 包，包内自带内核。

  private openPkg(): void {
    this.showPkg = true;
    this.pkgMsg = '';
    this.pkgConfirm = '';
    this.loadPkg(false);
  }

  private async loadPkg(force: boolean): Promise<void> {
    this.pkgLoading = true;
    const r: ApiResult = await Api.get(this.ctx(),
      '/api/v1/proxy/pkg/catalog' + (force ? '?force=1' : ''));
    if (!r.ok) {
      this.pkgLoading = false;
      this.pkgMsg = '拿不到插件清单：' + r.error;
      return;
    }
    const list: J[] = r.data.arr('items');
    const out: PkgItem[] = [];
    for (let i = 0; i < list.length; i++) {
      const it: J = list[i];
      out.push({
        backend: it.str('backend', ''),
        label: it.str('label', ''),
        version: it.str('version', ''),
        local: it.str('local', ''),
        newer: it.bool('newer', false),
        file: it.str('file', ''),
        conflict: it.str('conflict', '')
      });
    }
    this.pkgItems = out;
    this.pkgLoading = false;
    const fam: string = r.data.str('family', '');
    const arch: string = r.data.str('arch', '');
    this.pkgSys = fam.length > 0
      ? (fam + (arch.length > 0 ? ' · ' + arch : ''))
      : '';
    if (!r.data.bool('ok', false)) {
      this.pkgMsg = '仓库里没找到安装包，可以改用本地文件安装';
    }
    await this.probePkg();
  }

  /** 探一遍下载通道，让用户点之前就知道「现在哪条路通」 */
  private async probePkg(): Promise<void> {
    const p: ApiResult = await Api.post(this.ctx(), '/api/v1/proxy/pkg/probe',
      { 'probe': 1 });
    if (!p.ok) {
      return;
    }
    const list: J[] = p.data.arr('channels');
    const out: ChanItem[] = [];
    for (let i = 0; i < list.length; i++) {
      const c: J = list[i];
      out.push({
        id: c.str('id', ''),
        label: c.str('label', ''),
        ok: c.bool('ok', false),
        ms: c.num('ms', -1)
      });
    }
    this.pkgChans = out;
  }

  /** 文件名推后端：AUK9527 的包名里一定带 OpenClash / PassWall */
  private targetOfName(name: string): string {
    const low: string = name.toLowerCase();
    if (low.indexOf('openclash') >= 0) {
      return 'openclash';
    }
    if (low.indexOf('passwall') >= 0) {
      return 'passwall';
    }
    return '';
  }

  private fmtMB(n: number): string {
    if (n <= 0) {
      return '—';
    }
    if (n < 1048576) {
      return Math.round(n / 1024) + ' KB';
    }
    return (n / 1048576).toFixed(1) + ' MB';
  }

  /** 选文件 → 读进内存 → 传到路由器 → 等二次确认 */
  private async pickPkg(): Promise<void> {
    if (this.uploading) {
      return;
    }
    let uri: string = '';
    try {
      const opt = new picker.DocumentSelectOptions();
      opt.maxSelectNumber = 1;
      opt.fileSuffixFilters = ['.run', '.ipk', '.apk'];
      const p = new picker.DocumentViewPicker(this.ctx());
      const uris: string[] = await p.select(opt);
      if (uris.length === 0) {
        return;
      }
      uri = uris[0];
    } catch (e) {
      this.pkgMsg = '打开文件选择器失败';
      return;
    }

    const name: string = decodeURIComponent(uri.substring(uri.lastIndexOf('/') + 1));
    if (this.targetOfName(name).length === 0) {
      this.pkgMsg = '文件名里要带 OpenClash 或 PassWall，否则分不清装哪个';
      return;
    }

    let buf: ArrayBuffer = new ArrayBuffer(0);
    try {
      const f = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      const st = fileIo.statSync(f.fd);
      if (st.size <= 0) {
        fileIo.closeSync(f);
        this.pkgMsg = '这个文件是空的';
        return;
      }
      if (st.size > 128 * 1024 * 1024) {
        fileIo.closeSync(f);
        this.pkgMsg = '文件超过 128 MB，路由器收不下';
        return;
      }
      buf = new ArrayBuffer(st.size);
      fileIo.readSync(f.fd, buf);
      fileIo.closeSync(f);
    } catch (e) {
      this.pkgMsg = '读文件失败，换个位置再试';
      return;
    }

    this.uploading = true;
    this.uploadName = name;
    this.pkgMsg = '';
    const r: ApiResult = await Api.uploadPkg(name, buf);
    this.uploading = false;
    if (!r.ok) {
      this.pkgMsg = '上传失败：' + r.error;
      return;
    }
    this.askPkg(this.targetOfName(name), 'local', r.data.str('name', name));
  }

  /** 点按钮 → 先弹一个内联确认，确认了才真的调 Agent */
  private askPkg(target: string, source: string, name: string): void {
    this.pkgConfirm = target;
    this.pkgMsg = '';
    this.pendingSource = source;
    this.pendingName = name;
  }

  private async doPkgInstall(): Promise<void> {
    const target: string = this.pkgConfirm;
    if (target.length === 0) {
      return;
    }
    this.pkgConfirm = '';
    this.pkgMsg = '';
    // 每次新装都允许再问一次「要不要改 hosts」
    this.hostsAsked = false;
    const body: Record<string, Object> = {
      'target': target, 'source': this.pendingSource,
      'name': this.pendingName, 'confirm': 'install'
    };
    const r: ApiResult = await Api.post(this.ctx(), '/api/v1/proxy/pkg/install', body);
    if (!r.ok) {
      this.pkgMsg = '连不上 Agent：' + r.error;
      return;
    }
    if (!r.data.bool('ok', false)) {
      this.pkgMsg = r.data.str('error', '启动安装失败');
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
    // 必须 getFresh：快照里是上一次安装的结果，拿它判断「这一次」结束
    // 会在点下开始的瞬间弹失败，而服务端其实还在下载
    const r: ApiResult = await Api.getFresh(this.ctx(), '/api/v1/proxy/install');
    if (!r.ok) {
      return;
    }
    this.applyInstall(r.data);

    // 所有下载通道都失败时 Agent 会停下来等用户决定要不要改 hosts。
    // 不接这一步，进度会一直停着，直到 5 分钟超时才报错
    if (this.pkgTask.waiting === 'hosts_fix' && !this.hostsAsked) {
      this.hostsAsked = true;
      this.askHosts();
    }

    // 两条任务线的失败共用一个弹窗；同一时刻只弹一次
    if (!this.showSheet) {
      if (this.inst.err.code.length > 0) {
        this.failCode = this.inst.err.code;
        this.failTitle = this.inst.err.title;
        this.failDetail = this.inst.err.detail;
        this.failSuggest = this.inst.err.suggest;
        this.sheetMode = 'fail';
        this.showSheet = true;
      } else if (this.pkgTask.done && !this.pkgTask.ok
        && this.pkgTask.err.code.length > 0) {
        this.failCode = this.pkgTask.err.code;
        this.failTitle = this.pkgTask.err.title;
        this.failDetail = this.pkgTask.err.detail;
        this.failSuggest = this.pkgTask.err.suggest;
        this.sheetMode = 'fail';
        this.showSheet = true;
      }
    }

    const busy: boolean = this.inst.running || this.pkgTask.running;
    if (!busy && (this.inst.done || this.pkgTask.done)) {
      this.stopInstallPoll();
      this.load(true);
      if (this.inst.ok || this.pkgTask.ok) {
        this.toast = '装好了 · 导入订阅后再启动';
      }
    }
  }

  /** GitHub 所有通道都失败：问用户要不要让 Agent 改 hosts 后重试 */
  private askHosts(): void {
    this.getUIContext().showAlertDialog({
      title: 'GitHub 下载失败',
      message: '所有加速通道都连不上。是否修改 hosts 后重试？',
      primaryButton: {
        value: '修改并重试',
        fontColor: Pal.primary(),
        action: () => {
          this.postPkgConfirm('yes');
        }
      },
      secondaryButton: {
        value: '取消',
        fontColor: Pal.textSecondary(),
        action: () => {
          this.postPkgConfirm('no');
        }
      }
    });
  }

  /** 回应 Agent 的等待：yes 改 hosts 后重试，no 中止安装 */
  private async postPkgConfirm(choice: string): Promise<void> {
    const body: Record<string, Object> = { 'choice': choice };
    const r: ApiResult = await Api.post(this.ctx(), '/api/v1/proxy/pkg/confirm', body);
    if (!r.ok) {
      this.toast = r.error;
    }
  }

  /** 已安装的后端 —— 卸载入口只列这些 */
  private installedList(): Backend[] {
    return this.backends.filter((b: Backend) => b.installed);
  }

  private askUninstall(id: string, label: string): void {
    this.getUIContext().showAlertDialog({
      title: '卸载 ' + label + '？',
      message: '会删掉插件本体。实测 OpenClash 的包会连配置和订阅一起清掉，'
        + '重装后要重新粘一次订阅地址。',
      primaryButton: {
        value: '卸载',
        fontColor: Pal.danger(),
        action: () => {
          this.doUninstall(id, label);
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

  private async doUninstall(id: string, label: string): Promise<void> {
    this.toast = '正在卸载 ' + label + '…';
    const body: Record<string, Object> = { 'target': id, 'confirm': 'remove' };
    const r: ApiResult = await Api.post(this.ctx(), '/api/v1/proxy/uninstall', body);
    if (!r.ok) {
      this.toast = '卸载失败：' + r.error;
      return;
    }
    if (!r.data.bool('ok', false)) {
      this.toast = '卸载失败：' + r.data.str('error', '看日志确认');
      return;
    }
    this.toast = label + ' 已卸载';
    await this.load(true);
  }

  /** 重进页面时接上还在跑的任务（任务在 Agent 侧，杀 App 也不中断） */
  private async resumeInstall(): Promise<void> {
    const r: ApiResult = await Api.getFresh(this.ctx(), '/api/v1/proxy/install');
    if (!r.ok) {
      return;
    }
    this.applyInstall(r.data);
    if (this.inst.running || this.pkgTask.running) {
      this.startInstallPoll();
    } else if (this.pkgTask.done && !this.pkgTask.ok
      && this.pkgTask.err.code.length > 0) {
      // 不在页面时任务失败了，回来要补上提示，否则用户不知道装没装上
      this.failCode = this.pkgTask.err.code;
      this.failTitle = this.pkgTask.err.title;
      this.failDetail = this.pkgTask.err.detail;
      this.failSuggest = this.pkgTask.err.suggest;
      this.sheetMode = 'fail';
      this.showSheet = true;
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

  /**
   * 下拉一次。除了页面主数据，插件状态也要一起刷 ——
   * 装完插件回来下拉一下就想看到「已安装」，不该等下一轮轮询。
   */
  private async pull(): Promise<void> {
    this.pulling = true;
    await this.load(false);
    await this.loadPkg(true);
    this.pulling = false;
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
    // 必须带 backend：节点每个后端一套，不带就会落到「正在跑的那个」，
    // 看 PassWall 的卡片却显示 OpenClash 的节点
    const be: string = this.comboBackend();
    const path: string = be.length > 0
      ? '/api/v1/proxy/groups?backend=' + be
      : '/api/v1/proxy/groups';
    const r: ApiResult = await Api.get(this.ctx(), path);
    if (!r.ok) {
      return;
    }
    this.backend = r.data.str('backend', '');
    this.groupsErr = r.data.str('error', '');
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
    // 配置文件只有 OpenClash 有；PassWall 的节点直接来自订阅。
    // 这张卡在 PassWall 上会被藏掉，就别白拉一次接口
    if (this.comboBackend() !== 'openclash') {
      this.configs = [];
      this.currentPath = '';
      return;
    }
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
    // 刚启停的这个就是接下来要跟的对象：清掉旧的点名，
    // 否则卡片会停在「只改配置」的旁观态
    if (r.ok) {
      this.comboPick = '';
    }
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
    const body: Record<string, Object> = {
      'group': name, 'timeout': 3000, 'backend': this.comboBackend()
    };
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
    // 必须带 backend：这张卡可能正管着没在跑的那个后端，
    // 不带就会落到「正在运行的那个」身上，等于改了另一套节点
    const body: Record<string, Object> = {
      'name': name, 'group': group, 'backend': this.comboBackend()
    };
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
    Column() {
      // 大标题固定在滚动区外
      Row() {
        Text('代理')
          .fontSize(T.F_TITLE)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1);
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
      .constraintSize({ maxWidth: Bp.CONTENT_MAX })
      .padding({
        left: this.rail() ? 20 : T.PAD,
        right: this.rail() ? 20 : T.PAD,
        top: 8,
        bottom: 8
      });

      Refresh({ refreshing: $$this.pulling }) {
        Scroll() {
          Column() {
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
                // 「运行模式」切的是「正在跑的那个后端」的流量走向，没跑就没得切。
                // 摆出来只会让人以为自己在挑模式，其实点下去空转
                if (this.anyRunning()) {
                  this.modeCard();
                }
                // 配置文件只有 OpenClash 有；这张卡跟着「当前管哪个后端」走
                if (this.comboBackend() === 'openclash') {
                  this.configCard();
                }
                this.subsEntry();
                this.groupList();
              }
              .width('100%');
            }

            // 安装包入口放在最后：空态时是「源里没有就自己传」，已装时是「重装/升级」
            this.pkgEntry();

            Row().width('100%').height(24);
          }
          .width('100%')
          .constraintSize({ maxWidth: Bp.CONTENT_MAX })
          .padding({
            left: this.rail() ? 20 : T.PAD,
            right: this.rail() ? 20 : T.PAD,
            top: 2
          });
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .backgroundColor($r('app.color.app_bg'))
        .align(Alignment.Top);
      }
      .layoutWeight(1)
      .width('100%')
      .onRefreshing(() => {
        this.pull();
      });
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_bg'))
    // ★ 一个组件只能挂一个 bindSheet：之前 nodeSheet 和 configSheet 各挂了一个，
    // 后挂的把前一个顶掉，点节点分组完全没反应。合并成一个，内容按状态分派
    .bindSheet(this.sheetOpen(), this.anySheet(), {
      height: this.showGroup ? 560 : 520,
      dragBar: true,
      // 系统自带的关闭叉会和我们标题栏里那个圆形关闭叠在一起
      showClose: false,
      backgroundColor: $r('app.color.app_bg'),
      onDisappear: () => {
        this.showGroup = false;
        this.showConfig = false;
      }
    });
  }

  private sheetOpen(): boolean {
    return this.showGroup || this.showConfig;
  }

  @Builder
  anySheet() {
    Column() {
      if (this.showGroup) {
        this.nodeSheet();
      } else {
        this.configSheet();
      }
    }
    .width('100%')
    .height('100%');
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
      height: this.sheetMode === 'ask' ? 320 : 380,
      dragBar: false,
      // showClose 默认 true 会在右上角画一个系统关闭图标（圆底 + X），
      // 正好和我们自己的「关闭」文字叠在一起 —— 看着像被一条横线穿过
      showClose: false,
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
    // top 32 是给系统拖拽条让位：18 的时候「关闭」正好被那条横线穿过
    .padding({ left: 20, right: 20, top: 32, bottom: 20 });
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

  /**
   * 顶部 hero 卡：和 iOS / Android 的「代理」页同一套。
   *
   * 原来这里是普通白卡 + 独立「运行模式」卡，另两端却是一张深绿 hero 把
   * 「谁在跑、跑的哪个配置、几个节点、两个后端怎么切」全装进去 ——
   * 摆在一排白卡里既看不出来重点是它，颜色也和另两端对不上。
   */
  @Builder
  backendCard() {
    Column() {
      // ① 状态行：点 + 一句话 + 右侧胶囊
      Row() {
        Row()
          .width(7)
          .height(7)
          .borderRadius(4)
          .backgroundColor(this.anyRunning() ? Pal.heroOn() : Pal.heroOff())
          .margin({ right: 7 });
        Text(this.anyRunning() ? '运行中' : '都没在运行')
          .fontSize(12.5)
          .fontWeight(FontWeight.Medium)
          .fontColor(Pal.heroFg());
        Blank();
        Text(this.anyRunning()
          ? this.activeLabel()
          : this.installedCount().toString() + ' 个已安装')
          .fontSize(T.F_TINY)
          .fontColor(Pal.heroFgSoft())
          .padding({ left: 9, right: 9, top: 3, bottom: 3 })
          .borderRadius(99)
          .backgroundColor('#29FFFFFF');
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      // ② 大标题：运行中显示当前配置名，没跑写「未启用」
      Text(this.heroTitle())
        .fontSize(26)
        .fontWeight(FontWeight.Medium)
        .fontColor(Pal.heroFg())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 10 });

      // ③ 说明行
      Text(this.heroSub())
        .fontSize(T.F_SUB)
        .fontColor(Pal.heroFgSoft())
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 4 });

      // ④ 后端列表
      Text('代理后端 · 用右侧按钮启停')
        .fontSize(11)
        .fontColor(Pal.heroFgSoft())
        .width('100%')
        .margin({ top: 16, bottom: 2 });

      ForEach(this.backends, (b: Backend, i: number) => {
        Column() {
          if (i > 0) {
            // hero 是深绿底，普通的 divider 色在上面看不见
            Row()
              .width('100%')
              .height(0.7)
              .backgroundColor(Pal.heroFg())
              .opacity(0.16)
              .margin({ top: 2 });
          }
          Row({ space: 9 }) {
            GlyphIcon({
              kind: Glyph.POWER,
              color: b.running ? Pal.heroFg() : Pal.alpha(Pal.heroFg(), 0.5),
              side: 16,
              lineWidth: 2
            });

            Column() {
              // 运行中的那个要一眼认出来：加粗 + 满白；没跑的半透明白
              Text(b.label)
                .fontSize(b.running ? T.F_H2 + 1 : T.F_H2)
                .fontWeight(b.running ? FontWeight.Bold : FontWeight.Medium)
                .fontColor(b.running ? Pal.heroFg() : Pal.alpha(Pal.heroFg(), 0.55));
              Text(b.installed
                ? (b.engine.length > 0 ? b.engine + ' · ' : '') + b.nodes + ' 个节点'
                : '未安装')
                .fontSize(T.F_TINY)
                .fontColor(Pal.alpha(Pal.heroFg(), b.running ? 0.72 : 0.45))
                .margin({ top: 3 });
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            .margin({ left: 10 });

            // 状态胶囊：一律白字，靠透明度区分（深绿底上再加彩色底反而是噪音）
            Text(!b.installed ? '未安装' : (b.running ? '运行中' : '未运行'))
              .fontSize(11)
              .fontWeight(b.running ? FontWeight.Medium : FontWeight.Normal)
              .fontColor(b.running ? Pal.heroFg() : Pal.alpha(Pal.heroFg(), 0.6))
              .padding({ left: 9, right: 9, top: 3, bottom: 3 })
              .borderRadius(99)
              .backgroundColor(b.running ? '#33FFFFFF' : '#1AFFFFFF');

            if (b.installed) {
              Text(this.busyBackend === b.id ? '处理中…' : (b.running ? '停止' : '启动'))
                .fontSize(T.F_SUB)
                .fontWeight(FontWeight.Medium)
                .fontColor(Pal.heroFg())
                .padding({ left: 10, right: 10, top: 3, bottom: 3 })
                .borderRadius(99)
                .backgroundColor('#29FFFFFF')
                .margin({ left: 6 })
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
    .width('100%')
    .padding({ left: 20, right: 20, top: 18, bottom: 14 })
    .borderRadius(T.R_CARD)
    .linearGradient({
      angle: 135,
      colors: [[Pal.heroFrom(), 0], [Pal.heroTo(), 1]]
    })
    .margin({ bottom: this.rail() ? Bp.gap(this.winW) : T.GAP });
  }

  @Builder
  modeCard() {
    Card({ gapBottom: T.GAP }) {
      CardTitle({ glyph: Glyph.BOLT, title: '运行模式', sub: '改完立即生效' });
      // 分段控件必须有「槽」：选中项原来用纯白做底，而卡片也是白的，
      // 三个选项看起来一模一样，根本看不出当前是规则还是全局
      Row({ space: 4 }) {
        // 两个后端的档位不一样：OpenClash 三档，PassWall 只有代理/直连
        if (this.active === 'openclash') {
          this.modeChip('rule', '规则');
          this.modeChip('global', '全局');
          this.modeChip('direct', '直连');
        } else {
          this.modeChip('proxy', '代理');
          this.modeChip('disable', '直连');
        }
      }
      .width('100%')
      .padding(3)
      .borderRadius(15)
      .backgroundColor($r('app.color.surface_hi'))
      .margin({ top: 12 });
    }
  }

  /**
   * 配置文件只露当前一个。
   *
   * 之前把 configs 全铺在页面上：一台路由器里存了十几个配置时，
   * 「节点分组」会被挤到三四屏以外，而常用的永远是正在跑的那个。
   * 现在点一下弹层选，列表和节点分组用同一套行样式。
   */
  @Builder
  configCard() {
    Card({ gapBottom: T.GAP }) {
      Column() {
        CardTitle({
          glyph: Glyph.BOX,
          title: '配置文件',
          sub: this.configs.length > 1
            ? ('共 ' + this.configs.length + ' 个 · 切换会重启内核')
            : '当前使用的配置'
        });
        Row({ space: 10 }) {
          Column() {
            Text(this.currentConfigName())
              .fontSize(T.F_BODY)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis });
            Text(this.configs.length > 1 ? '当前使用 · 点一下切换' : '当前使用')
              .fontSize(T.F_TINY)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: 3 });
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1);

          if (this.configs.length > 1) {
            Text('切换')
              .fontSize(T.F_SUB)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.primary'))
              .padding({ left: 12, right: 12, top: 5, bottom: 5 })
              .borderRadius(99)
              .backgroundColor($r('app.color.accent_soft'));
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ top: 10, bottom: 2 })
        .onClick(() => {
          if (this.configs.length > 1) {
            this.showConfig = true;
          }
        });
      }
      .width('100%');
    }
  }

  private currentConfigName(): string {
    for (let i = 0; i < this.configs.length; i++) {
      if (this.configs[i].current) {
        return this.configs[i].name;
      }
    }
    const t: string = this.heroTitle();
    return t === '未启用' ? '未选择' : t;
  }

  /** 配置文件选择弹层：行样式与节点列表一致（白底、单选打勾） */
  @Builder
  configSheet() {
    Column() {
      this.sheetHeader('选择配置文件');

      Scroll() {
        Column() {
          ForEach(this.configs, (c: ConfigItem, i: number) => {
            Column() {
              if (i > 0) {
                Hairline({ indent: 0 });
              }
              Row({ space: 10 }) {
                Column() {
                  Text(c.name)
                    .fontSize(T.F_BODY)
                    .fontWeight(c.current ? FontWeight.Medium : FontWeight.Normal)
                    .fontColor(c.current
                      ? $r('app.color.primary')
                      : $r('app.color.text_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis });
                  Text(this.fmtSize(c.size) + (c.current ? ' · 使用中' : ''))
                    .fontSize(T.F_TINY)
                    .fontColor(c.current
                      ? $r('app.color.primary')
                      : $r('app.color.text_secondary'))
                    .fontFeature("\"tnum\" on")
                    .margin({ top: 3 });
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1);

                if (c.current) {
                  GlyphIcon({
                    kind: Glyph.CHECK,
                    color: Pal.primary(),
                    side: 17,
                    lineWidth: 2.2
                  });
                }
              }
              .width('100%')
              .padding({ left: 14, right: 14, top: 12, bottom: 12 })
              .alignItems(VerticalAlign.Center)
              .onClick(() => {
                this.showConfig = false;
                if (!c.current) {
                  this.switchConfig(c.path);
                }
              });
            }
            .width('100%');
          }, (c: ConfigItem) => c.path + (c.current ? '1' : '0'));
        }
        .width('100%')
        .backgroundColor($r('app.color.surface'))
        .borderRadius(T.R_CARD)
        .border({ width: 0.7, color: $r('app.color.glass_stroke') });
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off);

      Button('取消')
        .type(ButtonType.Normal)
        .borderRadius(14)
        .height(44)
        .width('100%')
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .backgroundColor($r('app.color.surface_hi'))
        .margin({ top: 14 })
        .onClick(() => {
          this.showConfig = false;
        });
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 0, bottom: 20 })
    .backgroundColor($r('app.color.app_bg'));
  }

  /** 弹层通用标题栏：标题 + 右侧圆形关闭。三个 sheet 共用，避免各写一套 */
  @Builder
  sheetHeader(title: string) {
    Row() {
      Text(title)
        .fontSize(T.F_H1)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis });
      Stack() {
        Stack() {
          GlyphIcon({ kind: Glyph.CLOSE, color: Pal.textSecondary(), side: 14, lineWidth: 2.1 });
        }
        .width(30)
        .height(30)
        .borderRadius(15)
        .backgroundColor($r('app.color.surface_hi'));
      }
      .width(44)
      .height(44)
      .onClick(() => {
        this.showGroup = false;
        this.showPkg = false;
        this.showConfig = false;
      });
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 12 })
    .alignItems(VerticalAlign.Center);
  }

  @Builder
  subsEntry() {
    Card({ gapBottom: T.GAP }) {
      Column() {
        // 两个都装着就得点名管哪个：订阅、节点、配置文件全是各一套，
        // 不点名只能默默按某一个展示，用户以为在配另一个
        if (this.installedIds().length >= 2) {
          Row({ space: 4 }) {
            this.comboChip('openclash', 'OpenClash');
            this.comboChip('passwall', 'PassWall');
          }
          .width('100%')
          .padding(3)
          .borderRadius(15)
          .backgroundColor($r('app.color.surface_hi'))
          .margin({ bottom: 6 });
        }

        Row() {
          // 自定义组件后面不能直接链 .margin()，套一层 Row
          Row() {
            GlyphIcon({ kind: Glyph.LINK, color: Pal.primary(), side: 18, lineWidth: 1.9 });
          }
          .margin({ right: 10 });
          Text(this.comboBackend().length > 0
            ? '订阅管理 · ' + this.labelOf(this.comboBackend())
            : '订阅管理')
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
          router.pushUrl({
            url: 'pages/SubscriptionPage',
            params: { backend: this.comboBackend() }
          });
        });

        Text(this.comboSub())
          .fontSize(T.F_TINY)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .margin({ top: 2 });
      }
      .width('100%');
    }
  }

  /** 后端切换器里的一个格子 */
  @Builder
  comboChip(id: string, text: string) {
    Text(text)
      .fontSize(T.F_SUB)
      .fontWeight(this.comboBackend() === id ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(this.comboBackend() === id
        ? $r('app.color.text_primary')
        : $r('app.color.text_secondary'))
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(30)
      .borderRadius(12)
      .backgroundColor(this.comboBackend() === id
        ? $r('app.color.segment_thumb')
        : Color.Transparent)
      .onClick(() => {
        this.pickCombo(id);
      });
  }

  /** 换后端：节点、配置文件都按新的重拉；正在跑的那个不受影响 */
  private async pickCombo(id: string): Promise<void> {
    if (this.comboPick === id || this.comboBackend() === id) {
      return;
    }
    this.comboPick = id;
    await this.loadGroups();
    await this.loadConfigs();
  }

  /** 安装包入口。空态和已装态都要有 —— 装不上时正好用本地上传兜底 */
  @Builder
  pkgEntry() {
    // Card 是自定义组件，后面不能直接链 .bindSheet()，所以套一层 Column
    Column() {
      Card({ gapBottom: T.GAP }) {
        CardTitle({
          glyph: Glyph.UPLOAD,
          title: '插件管理',
          sub: '装、重装或升级 OpenClash / Passwall'
        });
        Row({ space: 10 }) {
          Column() {
            Text(this.pkgTask.running
              ? '正在安装'
              : (this.uploading ? '正在上传' : '从本地文件或仓库安装'))
              .fontSize(T.F_BODY)
              .fontColor($r('app.color.text_primary'));
            Text(this.pkgSub())
              .fontSize(T.F_TINY)
              .fontColor($r('app.color.text_secondary'))
              .margin({ top: 2 });
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1);
          Text('›')
            .fontSize(18)
            .fontColor($r('app.color.text_tertiary'));
        }
        .width('100%')
        .padding({ top: 11, bottom: 2 })
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.openPkg();
        });
      }
    }
    .width('100%')
    .bindSheet($$this.showPkg, this.pkgSheet(), {
      height: 680,
      dragBar: true,
      showClose: false,
      backgroundColor: $r('app.color.app_bg'),
      onDisappear: () => {
        this.showPkg = false;
      }
    });
  }

  private pkgSub(): string {
    if (this.pkgTask.running) {
      return '正在安装 · ' + this.pkgTask.step;
    }
    if (this.uploading) {
      return '正在上传 ' + this.uploadName;
    }
    return '从本地文件装，或从仓库下载';
  }

  @Builder
  pkgSheet() {
    Column() {
      Row() {
        Text('安装包')
          .fontSize(T.F_H1)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1);
        Stack() {
          Stack() {
            GlyphIcon({ kind: Glyph.CLOSE, color: Pal.textSecondary(), side: 14, lineWidth: 2.1 });
          }
          .width(30)
          .height(30)
          .borderRadius(15)
          .backgroundColor($r('app.color.surface_hi'));
        }
        .width(44)
        .height(44)
        .onClick(() => {
          this.showPkg = false;
        });
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ bottom: 14 });

      Scroll() {
        Column() {
          // ---- 1. 本地文件：不依赖路由器能不能上外网。
          // 原来是整块主色底的大按钮，和页面里其它入口（白卡 + 图标 + 箭头）不是一路；
          // 这里改成同样的卡片行，主色只留给图标底
          Row({ space: 12 }) {
            Stack() {
              GlyphIcon({ kind: Glyph.UPLOAD, color: Pal.primary(), side: 17, lineWidth: 1.9 });
            }
            .width(32)
            .height(32)
            .borderRadius(10)
            .backgroundColor($r('app.color.accent_soft'))
            .alignContent(Alignment.Center);

            Column() {
              Text(this.uploading ? '正在上传 ' + this.uploadName : '从本地文件安装')
                .fontSize(T.F_BODY)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis });
              Text(this.uploading ? '传完会自动问你要不要装' : '选 .run / .ipk，手机里有包就能装')
                .fontSize(T.F_TINY)
                .fontColor($r('app.color.text_secondary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ top: 3 });
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1);

            GlyphIcon({ kind: Glyph.CHEVRON, color: Pal.textTertiary(), side: 14, lineWidth: 1.9 });
          }
          .width('100%')
          .padding({ left: 14, right: 14, top: 13, bottom: 13 })
          .borderRadius(T.R_CARD)
          .backgroundColor($r('app.color.surface'))
          .border({ width: 0.7, color: $r('app.color.glass_stroke') })
          .opacity(this.uploading ? 0.6 : 1)
          .onClick(() => {
            if (!this.uploading) {
              this.pickPkg();
            }
          });

          if (this.pkgMsg.length > 0) {
            Text(this.pkgMsg)
              .fontSize(T.F_TINY)
              .fontColor($r('app.color.warn'))
              .width('100%')
              .margin({ top: 8 })
              .lineHeight(18);
          }

          // ---- 2. 任务进度
          if (this.pkgTask.running || (this.pkgTask.done && this.pkgTask.ok)) {
            this.pkgProgress();
          }

          // ---- 3. 已安装：只能装不能卸的界面是残的
          if (this.installedList().length > 0) {
            Text('已安装')
              .fontSize(T.F_SUB)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .margin({ top: T.GAP, bottom: 2 });

            ForEach(this.installedList(), (b: Backend) => {
              Row() {
                Text(b.label)
                  .fontSize(T.F_SUB)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1);
                Text('卸载')
                  .fontSize(T.F_TINY)
                  .fontColor($r('app.color.danger'))
                  .padding({ left: 12, top: 6, bottom: 6 })
                  .onClick(() => {
                    this.askUninstall(b.id, b.label);
                  });
              }
              .width('100%')
              .padding({ top: 4, bottom: 4 })
              .alignItems(VerticalAlign.Center);
            }, (b: Backend) => b.id);
          }

          // ---- 4. 仓库下载
          Row() {
            Text('从仓库下载')
              .fontSize(T.F_SUB)
              .fontColor($r('app.color.text_secondary'));
            Blank();
            if (this.pkgLoading) {
              Text('读取中…')
                .fontSize(T.F_TINY)
                .fontColor($r('app.color.text_tertiary'));
            } else {
              Text('刷新')
                .fontSize(T.F_TINY)
                .fontColor($r('app.color.primary'))
                .onClick(() => {
                  this.loadPkg(true);
                });
            }
          }
          .width('100%')
          .margin({ top: T.GAP, bottom: 2 })
          .alignItems(VerticalAlign.Center);

          // 仓库是按系统版本 + 架构分开发的：24.10 和 25.12 在另一个仓库的
          // release 里，同一版本里还分 x86_64 / aarch64_a53 / _a72 / _generic。
          // 这行是在告诉用户「我选的是哪一套」，装错了要先看见才知道。
          if (this.pkgSys.length > 0) {
            Text('已按当前系统匹配：' + this.pkgSys)
              .fontSize(T.F_TINY)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
              .margin({ top: 2 });
          }

          if (this.pkgItems.length === 0) {
            Text(this.pkgLoading ? '正在读取仓库…' : '没读到仓库清单')
              .fontSize(T.F_TINY)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
              .margin({ top: 6 });
          } else {
            ForEach(this.pkgItems, (it: PkgItem) => {
              this.pkgRow(it);
            }, (it: PkgItem) => it.backend + '|' + it.version + '|' + it.local);
          }

          // ---- 4. 通道状态
          if (this.pkgChans.length > 0) {
            Text('下载通道：' + this.chanLine())
              .fontSize(T.F_TINY)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')
              .margin({ top: 10 })
              .lineHeight(18);
          }

          Note({ text: 'PassWall 的包约 80 MB，按现在这条线路可能要十几分钟；'
            + '着急就直接用上面的本地文件安装。' });
        }
        .width('100%');
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top);
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 32, bottom: 16 });
  }

  @Builder
  pkgProgress() {
    Column() {
      Text(this.pkgTask.step)
        .fontSize(T.F_TINY)
        .fontColor($r('app.color.text_secondary'))
        .width('100%');
      Stack({ alignContent: Alignment.Start }) {
        Row()
          .width('100%')
          .height(6)
          .borderRadius(3)
          .backgroundColor($r('app.color.track'));
        Row()
          .width(Math.max(0, Math.min(100, this.pkgTask.pct)) + '%')
          .height(6)
          .borderRadius(3)
          .backgroundColor($r('app.color.primary'));
      }
      .width('100%')
      .height(6)
      .margin({ top: 8, bottom: 4 });

      if (this.pkgTask.total > 0) {
        Text(this.fmtMB(this.pkgTask.got) + ' / ' + this.fmtMB(this.pkgTask.total)
          + (this.pkgTask.channel.length > 0 ? ' · ' + this.pkgTask.channel : ''))
          .fontSize(T.F_TINY)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%');
      }
    }
    .width('100%')
    .margin({ top: 12 });
  }

  private chanLine(): string {
    const parts: string[] = [];
    for (let i = 0; i < this.pkgChans.length; i++) {
      const c: ChanItem = this.pkgChans[i];
      parts.push(c.ok ? (c.label + ' ' + (c.ms / 1000).toFixed(1) + 's') : (c.label + ' 不通'));
    }
    return parts.join(' · ');
  }

  private pkgNote(it: PkgItem): string {
    let s: string = '';
    if (it.local.length === 0) {
      s = '未安装';
    } else if (it.newer) {
      s = '本机 ' + it.local + ' · 可升级';
    } else {
      s = '本机 ' + it.local + ' · 仓库里的更旧';
    }
    if (it.conflict.length > 0) {
      s = s + ' · 与 ' + (it.conflict === 'passwall' ? 'PassWall' : 'PassWall2') + ' 冲突';
    }
    return s;
  }

  @Builder
  pkgRow(it: PkgItem) {
    Column() {
      Row() {
        Column() {
          Row() {
            Text(it.label)
              .fontSize(T.F_BODY)
              .fontColor($r('app.color.text_primary'));
            Text('  ' + it.version)
              .fontSize(T.F_TINY)
              .fontColor($r('app.color.text_tertiary'));
          }
          Text(this.pkgNote(it))
            .fontSize(T.F_TINY)
            .fontColor(it.newer || it.local.length === 0
              ? $r('app.color.text_secondary')
              : $r('app.color.text_tertiary'))
            .margin({ top: 2 });
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1);

        if (this.pkgConfirm === it.backend) {
          Row({ space: 8 }) {
            Text('取消')
              .fontSize(T.F_TINY)
              .fontColor($r('app.color.text_secondary'))
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .borderRadius(99)
              .backgroundColor($r('app.color.surface_sunken'))
              .onClick(() => {
                this.pkgConfirm = '';
              });
            Text('确认安装')
              .fontSize(T.F_TINY)
              .fontColor($r('app.color.on_primary'))
              .padding({ left: 12, right: 12, top: 5, bottom: 5 })
              .borderRadius(99)
              .backgroundColor($r('app.color.primary'))
              .onClick(() => {
                this.doPkgInstall();
              });
          }
          .margin({ left: 8 });
        } else {
          Text('下载安装')
            .fontSize(T.F_SUB)
            .fontColor($r('app.color.primary'))
            .padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .borderRadius(99)
            .backgroundColor($r('app.color.accent_soft'))
            .margin({ left: 8 })
            .onClick(() => {
              this.askPkg(it.backend, 'github', it.file);
            });
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);
      Hairline();
    }
    .width('100%')
    .padding({ top: 10, bottom: 2 });
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

  /**
   * 节点分组：和其他块一样是一张卡片。
   *
   * 之前这里是「标题行 + 一格格浮在页面底色上的小卡」，和上下两张白卡不是一套
   * 语言，插件管理又紧贴在后面 —— 看起来像没分组的一堆散块。现在收进一张卡：
   * 分组名做卡标题，格子改成卡内的浅色块，间距由 Card 自己保证。
   */
  @Builder
  groupList() {
    if (this.groups.length > 0) {
      Card({ gapBottom: T.GAP }) {
        CardTitle({
          glyph: Glyph.LIST,
          title: '节点分组',
          sub: '共 ' + this.groups.length + ' 组 · 点一组选节点'
        }) {
          // 隐藏超时节点：开关放标题行右侧，不占一整行。
          // 状态存在服务端，另一台设备改过这里也会跟着变
          Row({ space: 5 }) {
            Text(this.hideTimeout
              ? (this.hiddenCount > 0 ? '隐藏 ' + this.hiddenCount : '隐藏中')
              : '隐藏超时')
              .fontSize(10.5)
              .fontColor($r('app.color.text_secondary'));
            Toggle({ type: ToggleType.Switch, isOn: this.hideTimeout })
              .selectedColor($r('app.color.primary'))
              .onChange((on: boolean) => {
                // 程序化改 isOn（数据回填 / 其他端改过）也会回调，
                // 状态没变就别打接口 —— 否则每次进代理页都白发一次请求
                if (on !== this.hideTimeout) {
                  this.setHideTimeout(on);
                }
              });
          }
        }

        ForEach(this.groupRows(), (row: NodeGroup[]) => {
          Row({ space: 8 }) {
            ForEach(row, (g: NodeGroup) => {
              this.groupCard(g, this.indexOfGroup(g.name));
            }, (g: NodeGroup) => this.groupKey(g));
            if (row.length < this.groupCols()) {
              Blank();
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          .margin({ top: 8 });
        }, (row: NodeGroup[]) => this.groupRowKey(row));
      }
    } else if (this.loaded) {
      // 这里原来一律写「没有正在运行的代理后端」，可上面的卡片明明显示「运行中 ·
      // 63 节点」—— 自相矛盾。分成两种：后端在跑但分组没读到，和后端确实没跑。
      Card({ gapBottom: T.GAP }) {
        CardTitle({ glyph: Glyph.LIST, title: '节点分组', sub: '暂时是空的' });
        // 服务端会说明为什么空着（OpenClash 停着时就是「启动后才看得到」），
        // 直接用它，别在这儿另编一句
        Text(this.groupsErr.length > 0
          ? this.groupsErr
          : (this.anyRunning() ? '节点分组还没读取到' : '没有可用的节点'))
          .fontSize(T.F_H2)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%');
        Text(this.groupsErr.length > 0
          ? '点上面的后端启动，节点就会出现'
          : (this.anyRunning()
            ? '后端正在启动或刚切换过配置，这一块会自动重试，不用手动刷新'
            : '在上面选一个后端启动，节点分组和测速才会出现'))
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
          .fontSize(10.5)
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
          .fontSize(10.5)
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
    // 现在这一格套在白色卡片里，用浅底块区分层级（不会再和页面底色撞色）
    .backgroundColor($r('app.color.surface_sunken'))
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
      // 标题栏与 configSheet 同一套：标题占满 + 测速胶囊 + 圆形关闭。
      // 原来「关闭」是右边缘的一行文字，正好压在 bindSheet 自带的系统关闭图标上，
      // 屏幕上看着是两个「关闭」叠着 —— 现在系统那个已关掉（showClose: false）
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
        Stack() {
          Stack() {
            GlyphIcon({ kind: Glyph.CLOSE, color: Pal.textSecondary(), side: 14, lineWidth: 2.1 });
          }
          .width(30)
          .height(30)
          .borderRadius(15)
          .backgroundColor($r('app.color.surface_hi'));
        }
        .width(44)
        .height(44)
        .onClick(() => {
          this.showGroup = false;
        });
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 12 })
      .alignItems(VerticalAlign.Center);

      if (this.openIdx >= 0 && this.openIdx < this.groups.length) {
        Scroll() {
          Column() {
            // 左右留 16：GroupBox 自己不能链式写 margin（自定义组件），套一层
            Column() {
              GroupBox() {
                ForEach(this.groups[this.openIdx].members, (m: NodeItem, i: number) => {
                  Column() {
                    if (i > 0) {
                      Hairline({ indent: 16 });
                    }
                    Row({ space: 10 }) {
                      Stack() {
                        Circle()
                          .width(16)
                          .height(16)
                          .fill(Color.Transparent)
                          .stroke(m.name === this.groups[this.openIdx].now
                            ? $r('app.color.primary')
                            : $r('app.color.text_tertiary'))
                          .strokeWidth(1.4);
                        if (m.name === this.groups[this.openIdx].now) {
                          Circle()
                            .width(8)
                            .height(8)
                            .fill($r('app.color.primary'));
                        }
                      }
                      .width(16)
                      .height(16);

                      Text(m.name)
                        .fontSize(T.F_BODY)
                        .fontWeight(m.name === this.groups[this.openIdx].now
                          ? FontWeight.Medium
                          : FontWeight.Normal)
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
                    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
                    .alignItems(VerticalAlign.Center)
                    .onClick(() => {
                      this.pickNode(this.groups[this.openIdx].name, m.name);
                    });
                  }
                  .width('100%');
                }, (m: NodeItem) => this.groups[this.openIdx].name + '/' + m.name + '|' + m.delay);
              }
            }
            .width('100%')
            .padding({ left: 16, right: 16 });

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

  private installedCount(): number {
    let n: number = 0;
    for (let i = 0; i < this.backends.length; i++) {
      if (this.backends[i].installed) {
        n++;
      }
    }
    return n;
  }

  /** hero 大标题：运行中显示当前配置名（去掉目录和 .yaml），没跑写「未启用」 */
  private heroTitle(): string {
    if (!this.anyRunning()) {
      return '未启用';
    }
    const p: string = this.currentPath;
    if (p.length === 0) {
      return this.activeLabel();
    }
    const seg: string[] = p.split('/');
    let name: string = seg[seg.length - 1];
    if (name.endsWith('.yaml')) {
      name = name.substring(0, name.length - 5);
    }
    return name.length > 0 ? name : this.activeLabel();
  }

  /** hero 说明行：引擎 · 节点数 · 模式；没跑时改成一句引导 */
  private heroSub(): string {
    if (!this.anyRunning()) {
      return '点上面任意一行启用；启用后这里显示当前出口';
    }
    const parts: string[] = [];
    for (let i = 0; i < this.backends.length; i++) {
      if (this.backends[i].id === this.active && this.backends[i].engine.length > 0) {
        parts.push(this.backends[i].engine);
      }
    }
    if (this.nodeCount > 0) {
      parts.push(this.nodeCount.toString() + ' 个节点可用');
    }
    const ml: string = this.modeLabel();
    if (ml.length > 0) {
      parts.push(ml);
    }
    return parts.length > 0 ? parts.join('　·　') : '正在读取…';
  }

  private modeLabel(): string {
    if (this.mode === 'rule') {
      return '规则';
    }
    if (this.mode === 'global') {
      return '全局';
    }
    if (this.mode === 'proxy') {
      return '代理';
    }
    if (this.mode === 'direct' || this.mode === 'disable') {
      return '直连';
    }
    return '';
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
