import { common } from '@kit.AbilityKit';
import { Api, ApiResult } from '../../api/Api';
import { J } from '../../core/Json';
import { Bp } from '../Breakpoint';
import { Pal, T } from '../Theme';
import { Card, CardHeader, GroupBox, Hairline, Pill } from '../Comp';
import { Ico } from '../comp/Icons';

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
  @State expanded: string = '';
  @State busy: string = '';
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
      this.expanded = '';
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
    .align(Alignment.Top);
  }

  @Builder
  backendCard() {
    Card() {
      CardHeader({
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
      }, (b: Backend) => b.id);
    }
  }

  @Builder
  modeCard() {
    Card({ gapTop: T.GAP }) {
      CardHeader({ title: '运行模式', sub: '规则模式按域名分流，全局模式全部走代理' });
      Row({ space: 6 }) {
        this.modeChip('rule', '规则');
        this.modeChip('global', '全局');
        this.modeChip('direct', '直连');
      }
      .width('100%')
      .margin({ top: 10 });
    }
  }

  @Builder
  groupList() {
    if (this.groups.length > 0) {
      Text('节点分组')
        .fontSize(T.F_SUB)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ top: this.rail() ? 0 : 18, bottom: 6, left: 4 });

      ForEach(this.groups, (g: NodeGroup) => {
        GroupBox({ gapBottom: 10 }) {
          Column() {
            Row({ space: 10 }) {
              Column() {
                Text(g.name)
                  .fontSize(T.F_H2)
                  .fontColor($r('app.color.text_primary'));
                Text(g.now.length > 0 ? '当前：' + g.now : g.type)
                  .fontSize(T.F_TINY)
                  .fontColor($r('app.color.text_secondary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .margin({ top: 2 });
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1);

              Text(g.members.length + ' 个')
                .fontSize(T.F_TINY)
                .fontColor($r('app.color.text_tertiary'));
              Path()
                .commands(Ico.CHEVRON)
                .width(16)
                .height(16)
                .fill(Color.Transparent)
                .stroke(Pal.textTertiary())
                .strokeWidth(1.6)
                .strokeLineCap(LineCapStyle.Round)
                .rotate({ angle: this.expanded === g.name ? 90 : 0 });
            }
            .width('100%')
            .padding({ left: 16, right: 14, top: 12, bottom: 12 })
            .alignItems(VerticalAlign.Center)
            .onClick(() => {
              this.expanded = this.expanded === g.name ? '' : g.name;
            });

            if (this.expanded === g.name) {
              ForEach(g.members, (m: NodeItem, mi: number) => {
                Column() {
                  Hairline({ indent: 16 });
                  Row() {
                    Text(m.name)
                      .fontSize(T.F_BODY)
                      .fontColor(m.name === g.now
                        ? $r('app.color.primary')
                        : $r('app.color.text_primary'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1);
                    if (this.busy === g.name + '/' + m.name) {
                      Text('切换中…')
                        .fontSize(T.F_TINY)
                        .fontColor($r('app.color.text_secondary'));
                    } else if (m.name === g.now) {
                      Text('使用中')
                        .fontSize(T.F_TINY)
                        .fontColor($r('app.color.primary'));
                    } else if (m.delay > 0) {
                      Text(m.delay + 'ms')
                        .fontSize(T.F_TINY)
                        .fontColor(m.delay > 500
                          ? $r('app.color.warn')
                          : $r('app.color.text_secondary'))
                        .fontFeature("\"tnum\" on");
                    }
                  }
                  .width('100%')
                  .padding({ left: 16, right: 16, top: 10, bottom: 10 })
                  .alignItems(VerticalAlign.Center)
                  .onClick(() => {
                    this.pickNode(g.name, m.name);
                  });
                }
                .width('100%');
              }, (m: NodeItem) => g.name + '/' + m.name);
            }
          }
          .width('100%');
        }
      }, (g: NodeGroup) => g.name);
    } else if (this.loaded) {
      Card({ gapTop: this.rail() ? 0 : T.GAP }) {
        Text('没有正在运行的代理后端')
          .fontSize(T.F_BODY)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .margin({ top: T.GAP });
      }
    }
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
        ? $r('app.color.text_primary')
        : $r('app.color.text_secondary'))
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(38)
      .borderRadius(T.R_INNER)
      .backgroundColor(this.mode === value
        ? $r('app.color.segment_thumb')
        : Color.Transparent)
      .border({
        width: this.mode === value ? 0.7 : 0,
        color: $r('app.color.glass_stroke')
      })
      .onClick(() => {
        this.setMode(value);
      });
  }
}
