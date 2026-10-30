import { common } from '@kit.AbilityKit';
import { Api, ApiResult } from '../../api/Api';
import { J } from '../../core/Json';
import { Bp } from '../Breakpoint';
import { Pal, T } from '../Theme';
import { Card, CardHeader, CardTitle, Comp, GroupBox, Hairline, LineIcon, Pill } from '../Comp';
import { Glyph, Ico } from '../comp/Icons';

interface Backend {
  id: string;
  label: string;
  installed: boolean;
  running: boolean;
  nodes: number;
  engine: string;
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

/**
 * 代理页。
 *
 * 两个后端互斥：同一时刻只有一方在跑，因为它们抢 53 端口和转发链。
 * 界面上把「谁是当前生效」放在最前面，而不是列出两个各自的状态 ——
 * 用户关心的是现在走哪条线，不是两个服务各自的开关。
 */
@Component
export struct ProxyPage {
  @State backends: Backend[] = [];
  @State active: string = '';
  @State groups: NodeGroup[] = [];
  @State nodeCount: number = 0;
  @State backend: string = '';
  @State mode: string = '';
  /** 弹窗里正在看的分组下标，-1 表示没打开 */
  @State openIdx: number = -1;
  @State showGroup: boolean = false;
  @State busy: string = '';
  /** 正在测速的分组名，空串表示空闲 */
  @State testingGroup: string = '';
  @State toast: string = '';
  @State loaded: boolean = false;

  @StorageProp('tab') @Watch('onTab') tab: number = 2;
  @State winW: number = 360;
  @StorageProp('winW') @Watch('onWidth') winWStore: number = 360;

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

  private rail(): boolean {
    return Bp.rail(this.winW);
  }

  private onTab(): void {
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
        engine: b.str('engine', '')
      });
    }
    this.backends = out;
  }

  private async loadGroups(): Promise<void> {
    const r: ApiResult = await Api.get(this.ctx(), '/api/v1/proxy/groups');
    if (!r.ok) {
      return;
    }
    this.backend = r.data.str('backend', '');
    this.nodeCount = r.data.num('node_count', 0);

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
      return '#8E8E93';
    }
    if (ms < 150) {
      return '#34C759';
    }
    if (ms < 350) {
      return '#FF9500';
    }
    return '#FF3B30';
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

        if (this.rail()) {
          // 平板：左边「走哪条线」（后端 + 模式），右边「能选哪些线」（节点分组）
          Row({ space: Bp.gap(this.winW) }) {
            Column() {
              this.backendCard();
              this.modeCard();
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
              Text(b.engine + ' · ' + b.nodes + ' 节点')
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
              Pill({ text: '已停止', tone: Pal.textSecondary() });
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
  groupList() {
    if (this.groups.length > 0) {
      Row() {
        Text('节点分组')
          .fontSize(T.F_SUB)
          .fontColor($r('app.color.text_secondary'));
        Blank();
        Text('点一张卡换节点')
          .fontSize(T.F_TINY)
          .fontColor($r('app.color.text_tertiary'));
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
