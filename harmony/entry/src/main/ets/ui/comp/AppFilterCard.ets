/**
 * 应用过滤（OpenAppFilter）卡片：总开关 + 特征库升级。
 *
 * 为什么单独成组件
 * ----------------
 * 设置页已经有两千行，再往里塞状态和文件选择会失控。这里自带
 * 加载、切换、上传三件事，设置页只要摆一行 `AppFilterCard()`。
 *
 * 为什么升级要走原始字节
 * ----------------------
 * 特征库是 2 MB 的 tar.gz，Http.send 只发字符串。用 extraData 传 ArrayBuffer
 * 才能避免 base64 膨胀（2 MB → 2.7 MB，路由器内存吃不消）。
 */
import { picker } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { CardTitle, Note, RowCard } from '../Comp';
import { Glyph } from './Icons';
import { T, Pal } from '../Theme';
import { Http } from '../../api/Http';
import { Session } from '../../core/Session';
import { Demo } from '../../core/Demo';

interface FeatureInfo {
  version: string;
  format: string;
  rules: number;
  size: number;
  updated: number;
}

interface IdentifyInfo {
  available: boolean;
  patterns: number;
  apps: number;
}

interface UpgradeResult {
  ok?: boolean;
  after?: string;
  before?: string;
  error?: string;
  rules?: number;
}

interface FilterState {
  installed: boolean;
  running: boolean;
  enabled: boolean;
  disable_hnat: boolean;
  note: string;
  feature: FeatureInfo;
  identify: IdentifyInfo;
}

@ComponentV2
export struct AppFilterCard {
  @Local loading: boolean = true;
  @Local busy: boolean = false;
  @Local installed: boolean = false;
  @Local enabled: boolean = false;
  @Local running: boolean = false;
  @Local version: string = '';
  @Local rules: number = 0;
  @Local apps: number = 0;
  @Local err: string = '';

  aboutToAppear(): void {
    this.load();
  }

  /** 读一次状态。演示模式直接显示「不可用」，不去打扰假数据。 */
  async load(): Promise<void> {
    this.loading = true;
    this.err = '';
    if (Demo.isOn()) {
      this.installed = false;
      this.loading = false;
      this.err = '演示模式不连接路由器';
      return;
    }
    const res = await Http.send(Session.base(), Session.token(), 'GET', '/api/v1/appfilter', '');
    this.loading = false;
    if (!res.ok) {
      this.err = '读取失败';
      return;
    }
    try {
      const d = JSON.parse(res.body) as FilterState;
      this.installed = d.installed === true;
      this.enabled = d.enabled === true;
      this.running = d.running === true;
      if (d.feature) {
        this.version = d.feature.version === undefined ? '' : d.feature.version;
        this.rules = d.feature.rules === undefined ? 0 : d.feature.rules;
      }
      if (d.identify) {
        this.apps = d.identify.apps === undefined ? 0 : d.identify.apps;
      }
    } catch (e) {
      this.err = '数据格式不对';
    }
  }

  /** 开关。会关硬件加速，所以失败要把原因说出来，不能静默回弹。 */
  async toggle(on: boolean): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    const body: string = JSON.stringify({ enable: on } as Record<string, boolean>);
    const res = await Http.send(Session.base(), Session.token(), 'POST', '/api/v1/appfilter/toggle', body);
    this.busy = false;
    if (res.ok) {
      promptAction.showToast({ message: on ? '应用过滤已开启' : '应用过滤已关闭' });
    } else {
      promptAction.showToast({ message: '切换失败，请稍后重试' });
    }
    this.load();
  }

  /** 选文件 → 读字节 → 原始上传 → 回读版本号。 */
  async upgrade(): Promise<void> {
    if (this.busy) {
      return;
    }
    let uris: string[] = [];
    try {
      const dp = new picker.DocumentViewPicker(getContext(this));
      const opt = new picker.DocumentSelectOptions();
      opt.maxSelectNumber = 1;
      uris = await dp.select(opt);
    } catch (e) {
      return;                       // 用户取消，不提示
    }
    if (uris.length === 0) {
      return;
    }
    const uri: string = uris[0];
    this.busy = true;
    promptAction.showToast({ message: '正在上传，请稍候' });
    try {
      const f = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      const size = fs.statSync(f.fd).size;
      if (size <= 0 || size > 12 * 1024 * 1024) {
        fs.closeSync(f);
        this.busy = false;
        promptAction.showToast({ message: '文件大小不合规' });
        return;
      }
      const buf = new ArrayBuffer(size);
      fs.readSync(f.fd, buf);
      fs.closeSync(f);
      const name: string = uri.split('/').pop() ?? 'feature.bin';
      const res = await Http.sendRaw(Session.base(), Session.token(),
        '/api/v1/appfilter/upgrade', name, buf);
      this.busy = false;
      if (res.ok) {
        let msg: string = '特征库已更新';
        try {
          const d = JSON.parse(res.body) as UpgradeResult;
          if (d.after !== undefined && d.after.length > 0) {
            msg = '特征库已更新到 ' + d.after;
          }
        } catch (e) {
          msg = '特征库已更新';
        }
        promptAction.showToast({ message: msg });
      } else {
        let why: string = '上传失败';
        try {
          const d = JSON.parse(res.body) as UpgradeResult;
          if (d.error !== undefined && d.error.length > 0) {
            why = d.error;
          }
        } catch (e) {
          why = '上传失败';
        }
        promptAction.showToast({ message: why });
      }
    } catch (e) {
      this.busy = false;
      const err = e as BusinessError;
      promptAction.showToast({ message: '读取文件失败：' + (err.message ?? '') });
    }
    this.load();
  }

  build() {
    RowCard({ gapBottom: T.GAP }) {
      CardTitle({ pad: 16, glyph: Glyph.SECURITY, title: '应用过滤', sub: '按应用识别与拦截' });

      if (this.loading) {
        Text('读取中…').fontSize(T.F_SUB).fontColor(Pal.text_tertiary())
          .padding({ left: 16, right: 16, top: 6, bottom: 10 });
      } else if (!this.installed) {
        Note({ text: this.err.length > 0 ? this.err : '路由器未安装 OpenAppFilter 插件' });
      } else {
        Row() {
          Column() {
            Text('开启应用过滤').fontSize(T.F_BODY).fontColor(Pal.text_primary());
            Text(this.running ? '内核已在运行' : '内核未运行')
              .fontSize(T.F_TINY).fontColor(Pal.text_tertiary()).margin({ top: 2 });
          }.alignItems(HorizontalAlign.Start).layoutWeight(1);

          Toggle({ type: ToggleType.Switch, isOn: this.enabled })
            .selectedColor(Pal.primary())
            .enabled(!this.busy)
            .onChange((v: boolean) => {
              this.toggle(v);
            });
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 4, bottom: 10 });

        Divider().color(Pal.stroke()).margin({ left: 16, right: 16 });

        Row() {
          Column() {
            Text('特征库').fontSize(T.F_BODY).fontColor(Pal.text_primary());
            Text(this.version.length > 0
              ? this.version + ' · ' + this.rules + ' 条规则' + (this.apps > 0 ? ' · ' + this.apps + ' 个应用' : '')
              : '未读取到版本')
              .fontSize(T.F_TINY).fontColor(Pal.text_tertiary()).margin({ top: 2 });
          }.alignItems(HorizontalAlign.Start).layoutWeight(1);

          Button(this.busy ? '上传中…' : '升级')
            .fontSize(T.F_SUB)
            .fontColor(Pal.primary())
            .backgroundColor(Pal.accent_soft())
            .height(36)
            .constraintSize({ minWidth: 78 })
            .borderRadius(T.R_PILL)
            .enabled(!this.busy)
            .onClick(() => {
              this.upgrade();
            });
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 10, bottom: 6 });

        Note({ text: '开启后会关闭硬件加速（HNAT），大流量场景速率会下降；特征库是会员私有授权，只能自己上传，不随 App 分发。' });
      }
    }
  }
}
