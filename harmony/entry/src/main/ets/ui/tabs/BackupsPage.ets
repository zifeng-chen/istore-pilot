import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { Api, ApiResult } from '../../api/Api';
import { J } from '../../core/Json';
import { Fmt } from '../../util/Fmt';
import { Pal, T } from '../Theme';
import { Card, CardHeader } from '../Comp';

interface BakItem {
  id: string;
  name: string;
  ts: number;
  size: number;
  files: number;
  auto: boolean;
}

/**
 * 配置备份。
 *
 * 备份的是整个 /etc/config，不含 Agent 自己的口令文件 —— 把口令打进备份，
 * 「恢复旧配置」就会变成「把口令泄露到旧备份里」。
 *
 * 恢复走服务端同一条事务：铺完 60 秒内不确认就自动退回。因为备份里的
 * network 会把 LAN 地址一起改掉，手机拿的还是旧地址，连不回来就是个死局。
 */
@Component
export struct BackupsPage {
  @State items: BakItem[] = [];
  @State count: number = 0;
  @State total: number = 0;
  @State loaded: boolean = false;
  @State err: string = '';
  @State busy: string = '';

  aboutToAppear(): void {
    this.load();
  }

  private ctx(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private async load(): Promise<void> {
    const r: ApiResult = await Api.get(this.ctx(), '/api/v1/config/backups');
    if (!r.ok) {
      this.err = r.error;
      this.loaded = true;
      return;
    }
    this.err = '';
    this.count = r.data.num('count', 0);
    this.total = r.data.num('bytes', 0);
    const raw: J[] = r.data.arr('items');
    const list: BakItem[] = [];
    for (let i = 0; i < raw.length; i++) {
      const it: J = raw[i];
      list.push({
        id: it.str('id', ''),
        name: it.str('name', ''),
        ts: it.num('ts', 0),
        size: it.num('size', 0),
        files: it.num('files', 0),
        auto: it.bool('auto', false),
      });
    }
    this.items = list;
    this.loaded = true;
  }

  private async toast(msg: string): Promise<void> {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 2200 });
  }

  // ---------------------------------------------------------------- 动作

  private create(): void {
    this.getUIContext().showAlertDialog({
      title: '新建备份',
      message: '会给当前的全部配置文件存一份，方便以后退回来。',
      primaryButton: {
        value: '备份',
        fontColor: Pal.primary(),
        action: () => {
          this.doCreate();
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

  private async doCreate(): Promise<void> {
    const body: Record<string, Object> = {};
    const r: ApiResult = await Api.post(this.ctx(), '/api/v1/config/backups', body);
    if (!r.ok) {
      await this.toast(r.error);
      return;
    }
    if (!r.data.bool('ok', false)) {
      await this.toast(r.data.str('error', '备份失败'));
      return;
    }
    await this.toast(r.data.str('message', '已备份'));
    await this.load();
  }

  private pick(it: BakItem): void {
    this.getUIContext().getPromptAction().showDialog({
      title: it.name,
      message: it.files + ' 个文件 · ' + Fmt.bytes(it.size) + '\n\n'
        + '恢复会把配置整份覆盖回去（宽带、局域网、防火墙、代理），'
        + '60 秒内不确认就自动退回。删除则不可找回。',
      buttons: [
        { text: '恢复这份配置', color: Pal.primary() },
        { text: '删除', color: Pal.danger() },
        { text: '取消', color: Pal.textSecondary() },
      ],
    }).then((r: promptAction.ShowDialogSuccessResponse) => {
      if (r.index === 0) {
        this.doRestore(it);
      } else if (r.index === 1) {
        this.doDelete(it);
      }
    });
  }

  private async doRestore(it: BakItem): Promise<void> {
    this.busy = it.id;
    const body: Record<string, Object> = { 'id': it.id };
    const r: ApiResult = await Api.post(this.ctx(), '/api/v1/config/backups/restore', body);
    this.busy = '';
    if (!r.ok) {
      await this.toast(r.error);
      return;
    }
    if (!r.data.bool('ok', false)) {
      await this.toast(r.data.str('error', '没有恢复'));
      return;
    }
    await this.toast(r.data.str('message', '已恢复') + '，请到网络页确认');
    await this.load();
  }

  private async doDelete(it: BakItem): Promise<void> {
    const body: Record<string, Object> = { 'id': it.id };
    const r: ApiResult = await Api.post(this.ctx(), '/api/v1/config/backups/delete', body);
    if (!r.ok) {
      await this.toast(r.error);
      return;
    }
    if (!r.data.bool('ok', false)) {
      await this.toast(r.data.str('error', '没有删除'));
      return;
    }
    await this.load();
  }

  // ---------------------------------------------------------------- 视图

  @Builder
  heroCard() {
    Column() {
      Card() {
      Text('本机备份')
        .fontSize(T.F_SUB)
        .fontColor($r('app.color.text_secondary'))
        .width('100%');
      Text(this.loaded ? this.count + ' 份' : '—')
        .fontSize(27)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .fontFeature("\"tnum\" on")
        .width('100%')
        .margin({ top: 6 });
        Text(this.count === 0 ? '还没有备份' : ('共占用 ' + Fmt.bytes(this.total)))
          .fontSize(T.F_SUB)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .margin({ top: 4 });
      }
    }
    .width('100%')
    .margin({ bottom: T.GAP });
  }

  @Builder
  rowItem(it: BakItem) {
    Column() {
      Row() {
        Column() {
          Text(it.name.length > 0 ? it.name : it.id)
            .fontSize(T.F_BODY)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%');
          Text(Fmt.clock(it.ts) + '　·　' + it.files + ' 个文件' + (it.auto ? '　·　自动' : ''))
            .fontSize(T.F_TINY)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: 3 });
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1);

        Text(this.busy === it.id ? '处理中…' : Fmt.bytes(it.size))
          .fontSize(T.F_SUB)
          .fontColor($r('app.color.text_secondary'))
          .margin({ left: 10 });
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 11, bottom: 11 })
    .onClick(() => {
      if (this.busy.length === 0) {
        this.pick(it);
      }
    });
  }

  @Builder
  listCard() {
    Column() {
      Card({ pad: 0 }) {
      Column() {
        Row() {
          CardHeader({ title: '备份列表', sub: '点一项可以恢复或删除' });
        }
        .padding({ left: 16, right: 16, top: 16 });

        if (this.err.length > 0) {
          Text('读取失败：' + this.err)
            .fontSize(T.F_SUB)
            .fontColor($r('app.color.danger'))
            .padding({ left: 16, right: 16, top: 8, bottom: 12 });
        } else if (this.items.length === 0) {
          Text(this.loaded ? '还没有备份。建议在动网络配置之前先建一份。' : '正在读取…')
            .fontSize(T.F_SUB)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .padding({ left: 16, right: 16, top: 8, bottom: 12 });
        } else {
          ForEach(this.items, (it: BakItem) => {
            this.rowItem(it);
          }, (it: BakItem) => it.id);
        }
      }
        .width('100%')
        .padding({ bottom: 8 });
      }
    }
    .width('100%')
    .margin({ bottom: T.GAP });
  }

  build() {
    Scroll() {
      Column() {
        this.heroCard();
        this.listCard();

        Text('新建备份')
          .fontSize(T.F_BODY)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.on_primary'))
          .textAlign(TextAlign.Center)
          .width('100%')
          .padding({ top: 12, bottom: 12 })
          .borderRadius(T.R_PILL)
          .backgroundColor($r('app.color.primary'))
          .onClick(() => {
            this.create();
          });

        Text('恢复前会先自动存一份「恢复前自动备份」，所以恢复错了也还能退回来。')
          .fontSize(T.F_TINY)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .margin({ top: 10 });
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 30 });
    }
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
    .width('100%')
    .height('100%');
  }
}
