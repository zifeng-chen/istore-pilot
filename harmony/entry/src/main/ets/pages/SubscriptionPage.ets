import { common } from '@kit.AbilityKit';
import { promptAction, router } from '@kit.ArkUI';
import { Api, ApiResult } from '../api/Api';
import { J } from '../core/Json';
import { T } from '../ui/Theme';
import { Card, Hairline } from '../ui/Comp';

interface SubItem {
  id: string;
  backend: string;
  name: string;
  url: string;
  masked: string;
  enabled: boolean;
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
  /** 新增/编辑表单 */
  @State editing: boolean = false;
  @State editId: string = '';
  @State editBackend: string = 'openclash';
  @State nameDraft: string = '';
  @State urlDraft: string = '';

  aboutToAppear(): void {
    const top = AppStorage.get<number>('safeTop');
    this.safeTop = top !== undefined ? top : 0;
    this.load();
  }

  private ctx(): common.Context {
    return this.getUIContext().getHostContext() as common.Context;
  }

  private async load(): Promise<void> {
    const r: ApiResult = await Api.get(this.ctx(), '/api/v1/proxy/subscriptions');
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
        enabled: it.bool('enabled', true)
      });
    }
    this.items = out;
  }

  private toast(s: string): void {
    promptAction.showToast({ message: s });
  }

  /** 删除 / 刷新这类「对某一条」的动作 */
  private async act(action: string, it: SubItem): Promise<void> {
    if (this.busy.length > 0) {
      return;
    }
    this.busy = it.id;
    const body: Record<string, Object> = {
      'action': action,
      'backend': it.backend,
      'id': it.id
    };
    if (action === 'delete' || action === 'refresh') {
      body['sec'] = it.id;
    }
    const r: ApiResult = await Api.post(this.ctx(), '/api/v1/proxy/subscriptions', body);
    this.busy = '';
    this.toast(r.ok ? (action === 'delete' ? '已删除' : '已提交') : (r.error.length > 0 ? r.error : '操作失败'));
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
    this.toast(r.ok ? '已保存' : (r.error.length > 0 ? r.error : '保存失败'));
    if (r.ok) {
      this.editing = false;
      this.editId = '';
      await this.load();
    }
  }

  build() {
    Column() {
      // 顶栏
      Row({ space: 6 }) {
        Text('‹')
          .fontSize(26)
          .fontColor($r('app.color.primary'))
          .width(34)
          .height(34)
          .textAlign(TextAlign.Center)
          .onClick(() => {
            router.back();
          });
        Text('订阅管理')
          .fontSize(T.F_H1)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1);
        Text('添加')
          .fontSize(T.F_SUB)
          .fontColor($r('app.color.primary'))
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .borderRadius(99)
          .backgroundColor($r('app.color.accent_soft'))
          .onClick(() => {
            this.editId = '';
            this.nameDraft = '';
            this.urlDraft = '';
            this.editing = true;
          });
      }
      .width('100%')
      .padding({ left: 8, right: T.PAD, top: 6, bottom: 8 })
      .alignItems(VerticalAlign.Center);

      Scroll() {
        Column() {
          if (this.editing) {
            this.editCard();
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

                    if (!it.enabled) {
                      Text('停用')
                        .fontSize(T.F_TINY)
                        .fontColor($r('app.color.text_tertiary'))
                        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                        .borderRadius(99)
                        .backgroundColor($r('app.color.surface_sunken'));
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
                    this.op(this.busy === it.id ? '处理中…' : '刷新', () => {
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
    .padding({ top: this.safeTop })
    .backgroundColor($r('app.color.app_bg'));
  }

  @Builder
  op(text: string, tap: () => void, danger: boolean = false) {
    Text(text)
      .fontSize(T.F_SUB)
      .fontColor(danger ? $r('app.color.danger') : $r('app.color.primary'))
      .padding({ left: 12, right: 12, top: 5, bottom: 5 })
      .onClick(() => {
        tap();
      });
  }

  @Builder
  editCard() {
    Card({ gapTop: 0 }) {
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
            .onClick(() => {
              this.editing = false;
            });
        }
        .width('100%')
        .margin({ bottom: 12 });

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
            .borderRadius(99)
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
  }
}
