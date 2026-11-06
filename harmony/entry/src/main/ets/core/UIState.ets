import { AppStorageV2 } from '@kit.ArkUI';

/**
 * 跨页共享的「壳」状态（V2 版 AppStorage）。
 *
 * V1 里这些是散落在 AppStorage 里的字符串键：tab / winW / safeTop / safeBottom /
 * forceLogin / shellSubTitle / shellBackTick / hostname / agentVer，各页面用
 * @StorageProp/@StorageLink + @Watch 读，写入方用 AppStorage.setOrCreate 写。
 *
 * 问题：@StorageProp/@StorageLink 是 V1 专属装饰器，在 @ComponentV2 里直接编译报错。
 * V2 的等价物就是这里 —— 一个 @ObservedV2 类 + AppStorageV2.connect 拿全局单例，
 * 字段用 @Trace 标记，任何页面读 this.ui.xxx 都会建立依赖，改了自动刷新。
 *
 * 页面侧的标准接法（见各 tab 页）：
 *   @Local ui: UIState = UI;
 *   @Local tab: number = UI.tab;
 *   @Monitor('ui.tab') onTab() { this.tab = this.ui.tab; ... }
 */
@ObservedV2
export class UIState {
  /** 当前页签索引（0 概览 / 1 网络 / 2 设备 / 3 代理 / 4 设置） */
  @Trace tab: number = 0;
  /** 窗口宽度（vp），Index 的 onAreaChange 写入，各页做响应式布局 */
  @Trace winW: number = 360;
  /** 状态栏安全区（vp），全屏窗口下页面自己让出顶部 */
  @Trace safeTop: number = 0;
  /** 强制登录信号：令牌失效时 EntryAbility 置时间戳，Index 跳登录页 */
  @Trace forceLogin: number = 0;
  /** 页内二级页标题；空串 = 停在一级页（见 core/Shell.ets） */
  @Trace subTitle: string = '';
  /** 壳请求「退回一级页」的计数，页面收到就关掉自己的二级页 */
  @Trace backTick: number = 0;
  /** 主机名（boot 后写入，暂供侧栏/其它显示） */
  @Trace hostname: string = '';
  /** Agent 版本号，侧栏底部展示 */
  @Trace agentVer: string = '';
}

/** 全局单例：所有页面 connect 同一个 key，拿到的是同一个对象 */
export const UI: UIState = AppStorageV2.connect(UIState, 'iStoreUI', () => new UIState())!;
