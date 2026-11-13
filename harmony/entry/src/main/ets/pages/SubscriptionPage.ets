import { common } from '@kit.AbilityKit';
import { promptAction, router } from '@kit.ArkUI';
import { Api, ApiResult } from '../api/Api';
import { J } from '../core/Json';
import { UI } from '../core/UIState';
import { Pal, T } from '../ui/Theme';
import { Card, Comp, Hairline } from '../ui/Comp';

interface SubItem {
  id: string;
  backend: string;
  name: string;
  url: string;
  masked: string;
  enabled: boolean;
  /** 正在用的那一条。只有它打角标，未启用的不显示 */
  inUse: boolean;
}

/**
 * 订阅管理（二级页）。
 *
 * 之前鸿蒙没有这一页：`proxy/subscriptions` 压根没接，换机场只能去 LuCI。
 * 对齐 iOS `SubscriptionView` / 安卓 `SubscriptionActivity`：列出全部订阅，
 * 支持添加、编辑、删除、立即刷新。地址只显示脱敏后的 `url_masked`，
 * 只有编辑时才会填回明文（后端存的是完整 URL，前端不展示）。
 */
@Entry
@Component
struct SubscriptionPage {
  @State items: SubItem[] = [];
  @State loading: boolean = true;
  @State busy: string = '';
  @State safeTop: number = 0;
  /**
   * 管的是哪个后端。订阅**每个后端各一套**（uci 里分属 openclash /
   * passwall 两个包），代理页带过来；以前这里不分后端把两边混在一列里，
   * 用户以为一条能管两个
   */
  @State backend: string = '';
  /** 新增/编辑表单 */
  @State editing: boolean = false;
  @State editId: string = '';
  @State editBackend: string = 'openclash';
  @State nameDraft: string = '';
  @State urlDraft: string = '';
  /** 最近一次「更新订阅」的结果。logHas=false 表示还没更新过 */
  @State logHas: boolean = false;
  @State logRunning: boolean = false;
  @State logOk: boolean = false;
  @State logSummary: string = '';
  @State logAt: number = 0;
  @State logSeconds: number = 0;
  @State logTail: string = '';
  /** 日志展开/收起 */
  @State logOpen: boolean = false;
  private pollId: number = -1;

  aboutToAppear(): void {
    this.safeTop = UI.safeTop;
    const p = router.getParams() as Record<string, string>;
    if (p !== undefined && p !== null && p['backend'] !== undefined) {
      this.backend = p['backend'];
    }
    this.load();
    this.loadLog();
  }

  aboutToDisappear(): void {
    this.stopPoll();
  }

  private stopPoll(): void {
    if (this.pollId >= 0) {
      clearInterval(this.pollId);
      this.pollId = -1;
    }
  }

  /** 更新是后台任务，拉一次不够 —— 没跑完就每 2 秒再看一眼 */
  private startPoll(): void {
    this.stopPoll();
    this.pollId = setInterval(() => {
      this.loadLog();
    }, 2000);
  }

  private async loadLog(): Promise<void> {
    const r: ApiResult = await Api.get(this.ctx(), '/api/v1/proxy/subscriptions/log');
    if (!r.ok) {
      return;
    }
    const l: J = r.data.obj('log');
    const at: number = l.num('started_at', 0);
    this.logHas = at > 0;
    this.logRunning = l.bool('running', false);
    this.logOk = l.bool('ok', false);
    this.logSummary = l.str('summary', '');
    this.logAt = at;
    this.logSeconds = l.num('seconds', 0);
    this.logTail = l.str('tail', '');
    if (!this.logRunning) {
      this.stopPoll();
    }
  }

  /** 触发一次更新：先把「正在更新」摆出来，再开始轮询结果 */
  private async triggerUpdate(backend: string, sec: string): Promise<boolean> {
    const body: Record<string, Object> = {
      'action': 'refresh',
      'backend': backend,
      'id': sec,
      'sec': sec
    };
    const r: ApiResult = await Api.post(this.ctx(), '/api/v1/proxy/subscriptions', body);
    if (!r.ok) {
      this.toast(r.error.length > 0 ? r.error : '更新失败');
      return false;
    }
    this.logHas = true;
    this.logRunning = true;
    this.logOk = false;
    this.logSummary = '正在更新…';
    this.logAt = Math.floor(Date.now() / 1000);
    this.logSeconds = 0;
    this.logTail = '';
    this.startPoll();
    return true;
  }

  /** 日志只留尾部若干行，整段塞进去会把卡撑得很长 */
  private logText(): string {
    const lines: string[] = this.logTail.split('\n');
    const start: number = Math.max(0, lines.length - 14);
    return lines.slice(start).join('\n').trim();
  }

  private logStateText(): string {
    if (this.logRunning) {
      return '进行中';
    }
    return this.logOk ? '成功' : '失败';
  }

  private logTone(): string {
    if (this.logRunning) {
      return Pal.primary();
    }
    return this.logOk ? Pal.ok() : Pal.danger();
  }

  private clockText(ts: number): string {
    const d: Date = new Date(ts * 1000);
    const mm: string = (d.getMonth() + 1).toString().padStart(2, '0');
    const dd: string = d.getDate().toString().padStart(2, '0');
    const hh: string = d.getHours().toString().padStart(2, '0');
    const mi: string = d.getMinutes().toString().padStart(2, '0');
    return mm + '-' + dd + ' ' + hh + ':' + mi;
  }

  private ctx(): common.Context {
    return this.getUIContext().getHostContext() as common.Context;
  }

  private async load(): Promise<void> {
    const path: string = this.backend.length > 0
      ? '/api/v1/proxy/subscriptions?backend=' + this.backend
      : '/api/v1/proxy/subscriptions';
    const r: ApiResult = await Api.get(this.ctx(), path);
    this.loading = false;
    if (!r.ok) {
      promptAction.showToast({ message: r.error.length > 0 ? r.error : '读取失败' });
      return;
    }
    const list: J[] = r.data.arr('items');
    const out: SubItem[] = [];
    for (let i = 0; i < list.length; i++) {
      const it: J = list[i];
      out.push({
        id: it.str('id', ''),
        backend: it.str('backend', ''),
        name: it.str('name', ''),
        url: it.str('url', ''),
        masked: it.str('url_masked', ''),
        enabled: it.bool('enabled', true),
        inUse: it.bool('in_use', false)
      });
    }
    this.items = out;
  }

  private toast(s: string): void {
    promptAction.showToast({ message: s });
  }

  /** 删除这类「对某一条」的动作 */
  private async act(action: string, it: SubItem): Promise<void> {
    if (this.busy.length > 0) {
      return;
    }
    if (action === 'refresh') {
      // 更新走 triggerUpdate：它会把「正在更新」写进日志卡并开始轮询，
      // 用户不用猜点了有没有反应
      this.busy = it.id;
      const ok: boolean = await this.triggerUpdate(it.backend, it.id);
      this.busy = '';
      if (ok) {
        this.toast('已开始更新，进度看页面顶部「最近更新」');
      }
      return;
    }
    this.busy = it.id;
    const body: Record<string, Object> = {
      'action': action,
      'backend': it.backend,
      'id': it.id,
      'sec': it.id
    };
    const r: ApiResult = await Api.post(this.ctx(), '/api/v1/proxy/subscriptions', body);
    this.busy = '';
    this.toast(r.ok ? '已删除' : (r.error.length > 0 ? r.error : '操作失败'));
    await this.load();
  }

  private async save(): Promise<void> {
    if (this.urlDraft.trim().length === 0) {
      this.toast('请填写订阅地址');
      return;
    }
    this.busy = 'save';
    const isEdit: boolean = this.editId.length > 0;
    const body: Record<string, Object> = {
      'action': isEdit ? 'update' : 'add',
      'backend': this.editBackend,
      'name': this.nameDraft.trim().length > 0 ? this.nameDraft.trim() : '未命名订阅',
      'url': this.urlDraft.trim(),
      'enabled': true
    };
    if (isEdit) {
      body['id'] = this.editId;
      body['sec'] = this.editId;
    }
    const r: ApiResult = await Api.post(this.ctx(), '/api/v1/proxy/subscriptions', body);
    this.busy = '';
    if (!r.ok) {
      this.toast(r.error.length > 0 ? r.error : '保存失败');
      return;
    }
    this.editing = false;
    this.editId = '';
    await this.load();
    // 保存完自动拉一次：新加的订阅不更新就一个节点都没有，
    // 用户会以为加失败了。结果在「最近更新」里能看
    const ok: boolean = await this.triggerUpdate(this.editBackend, '');
    this.toast(ok ? '已保存，正在更新订阅…' : '已保存，但更新没启动');
  }

  build() {
    Column() {
      // 顶栏
      Row({ space: 6 }) {
        Text('‹')
          .fontSize(T.F_HERO)
          .fontColor($r('app.color.primary'))
          .width(44)
          .height(44)
          .textAlign(TextAlign.Center)
          .accessibilityText('返回')
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => {
            router.back();
          });
        // 标题点名管的是哪个后端：只写「订阅管理」会让人以为这里能同时管两个
        Text(this.backend.length === 0
          ? '订阅管理'
          : '订阅管理 · ' + (this.backend === 'passwall' ? 'PassWall' : 'OpenClash'))
          .fontSize(T.F_H1)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1);
        Text('添加')
          .fontSize(T.F_SUB)
          .fontColor($r('app.color.primary'))
          .padding({ left: 14, right: 14, top: 4, bottom: 4 })
          .borderRadius(T.R_PILL)
          .backgroundColor($r('app.color.accent_soft'))
          // 视觉仍是小胶囊，热区撑到 44
          .constraintSize({ minHeight: 44, minWidth: 44 })
          .textAlign(TextAlign.Center)
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => {
            this.editId = '';
            // 新增的订阅必须落在当前这个后端上，否则会写进另一套
            this.editBackend = this.backend.length > 0 ? this.backend : 'openclash';
            this.nameDraft = '';
            this.urlDraft = '';
            this.editing = true;
          });
      }
      .width('100%')
      .padding({ left: 3, right: T.PAD, top: 6, bottom: 8 })
      .alignItems(VerticalAlign.Center);

      Scroll() {
        Column() {
          if (this.logHas) {
            this.logCard();
          }

          if (this.loading) {
            Text('读取中…')
              .fontSize(T.F_SUB)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding(20);
          } else if (this.items.length === 0) {
            Text('还没有订阅，点右上角「添加」')
              .fontSize(T.F_SUB)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding(20);
          } else {
            ForEach(this.items, (it: SubItem, i: number) => {
              Card({ gapTop: i === 0 && !this.editing ? 0 : T.GAP }) {
                Column() {
                  Row({ space: 8 }) {
                    Column() {
                      Text(it.name)
                        .fontSize(T.F_H2)
                        .fontColor($r('app.color.text_primary'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis });
                      Text(it.masked)
                        .fontSize(T.F_TINY)
                        .fontColor($r('app.color.text_tertiary'))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .margin({ top: 3 });
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1);

                    if (it.inUse) {
                      Text('使用中')
                        .fontSize(T.F_TINY)
                        .fontColor($r('app.color.primary'))
                        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                        .borderRadius(T.R_PILL)
                        .backgroundColor($r('app.color.accent_soft'));
                    }
                  }
                  .width('100%')
                  .padding({ top: 4, bottom: 4 });

                  Hairline({ indent: 0 });

                  Row() {
                    this.op('编辑', () => {
                      this.editId = it.id;
                      this.editBackend = it.backend;
                      this.nameDraft = it.name;
                      this.urlDraft = it.url;
                      this.editing = true;
                    });
                    this.op(this.busy === it.id ? '处理中…' : '更新', () => {
                      this.act('refresh', it);
                    });
                    this.op('删除', () => {
                      this.act('delete', it);
                    }, true);
                  }
                  .width('100%')
                  .padding({ top: 8 });
                }
                .width('100%');
              }
            }, (it: SubItem) => it.id);
          }

          Row().height(24);
        }
        .width('100%')
        .padding({ left: T.PAD, right: T.PAD });
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top);
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.safeTop, left: UI.safeLeft, right: UI.safeRight })
    .backgroundColor($r('app.color.app_bg'))
    // 添加/编辑做成弹层：原来是一张内联卡插在列表顶部，点「添加」页面往下跳一截，
    // 看起来像换了个页面
    .bindSheet($$this.editing, this.editSheet(), {
      height: 430,
      dragBar: true,
      showClose: false,
      backgroundColor: $r('app.color.app_bg'),
      onDisappear: () => {
        this.editing = false;
      }
    });
  }

  /** 最近一次更新的结果：时间、成败、耗时，日志可展开 */
  @Builder
  logCard() {
    Card({ gapBottom: T.GAP }) {
      Row() {
        Text('最近更新')
          .fontSize(T.F_H2)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1);
        Text(this.logStateText())
          .fontSize(T.F_TINY)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.logTone())
          .padding({ left: 9, right: 9, top: 3, bottom: 3 })
          .borderRadius(T.R_PILL)
          .backgroundColor(Comp.alpha(this.logTone(), 0.14));
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      Text(this.clockText(this.logAt) + ' · ' + this.logSummary
        + (this.logSeconds > 0 && !this.logRunning
          ? '（' + this.logSeconds.toString() + ' 秒）' : ''))
        .fontSize(T.F_TINY)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ top: 6 });

      if (this.logTail.length > 0) {
        Text(this.logOpen ? '收起日志' : '查看日志')
          .fontSize(T.F_SUB)
          .fontColor($r('app.color.primary'))
          .padding({ top: 8, bottom: 4 })
          .onClick(() => {
            this.logOpen = !this.logOpen;
          });
      }

      if (this.logOpen && this.logTail.length > 0) {
        Text(this.logText())
          .fontSize(T.F_TINY)
          .lineHeight(16)
          .fontColor($r('app.color.text_secondary'))
          .fontFamily('monospace')
          .wordBreak(WordBreak.BREAK_ALL)
          .width('100%')
          .padding(10)
          .borderRadius(T.R_XS)
          .backgroundColor($r('app.color.surface_sunken'));
      }
    }
  }

  @Builder
  op(text: string, tap: () => void, danger: boolean = false) {
    Text(text)
      .fontSize(T.F_SUB)
      .fontColor(danger ? $r('app.color.danger') : $r('app.color.primary'))
      .padding({ left: 12, right: 12, top: 5, bottom: 5 })
      .constraintSize({ minHeight: 44, minWidth: 44 })
      .textAlign(TextAlign.Center)
      .accessibilityText(text)
      .clickEffect({ level: ClickEffectLevel.LIGHT })
      .onClick(() => {
        tap();
      });
  }

  @Builder
  editSheet() {
    Column() {
      Column() {
        Row() {
          Text(this.editId.length > 0 ? '编辑订阅' : '添加订阅')
            .fontSize(T.F_H2)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1);
          Text('取消')
            .fontSize(T.F_SUB)
            .fontColor($r('app.color.text_secondary'))
            .padding({ left: 10, top: 4, bottom: 4 })
            .onClick(() => {
              this.editing = false;
            });
        }
        .width('100%')
        .margin({ bottom: 14 });

        Text('名称')
          .fontSize(T.F_TINY)
          .fontColor($r('app.color.text_secondary'))
          .width('100%');
        TextInput({ text: this.nameDraft, placeholder: '给自己看的名字' })
          .width('100%')
          .height(38)
          .fontSize(T.F_BODY)
          .margin({ top: 4, bottom: 12 })
          .borderRadius(T.R_INNER)
          .backgroundColor($r('app.color.surface_sunken'))
          .onChange((v: string) => {
            this.nameDraft = v;
          });

        Text('订阅地址')
          .fontSize(T.F_TINY)
          .fontColor($r('app.color.text_secondary'))
          .width('100%');
        TextInput({ text: this.urlDraft, placeholder: 'https://…' })
          .width('100%')
          .height(38)
          .fontSize(T.F_BODY)
          .margin({ top: 4 })
          .borderRadius(T.R_INNER)
          .backgroundColor($r('app.color.surface_sunken'))
          .onChange((v: string) => {
            this.urlDraft = v;
          });

        Row() {
          Blank();
          Text(this.busy === 'save' ? '保存中…' : '保存')
            .fontSize(T.F_BODY)
            .fontColor($r('app.color.on_primary'))
            .padding({ left: 22, right: 22, top: 8, bottom: 8 })
            .borderRadius(T.R_PILL)
            .backgroundColor($r('app.color.primary'))
            .onClick(() => {
              this.save();
            });
        }
        .width('100%')
        .margin({ top: 14 });
      }
      .width('100%');
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 18, right: 18, top: 4 });
  }
}
