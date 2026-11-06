import { UI } from './UIState';

/**
 * 一级 / 二级页之间的「壳」状态。
 *
 * 鸿蒙这边进二级页有两种走法：
 *
 *   1. 路由页（DeviceDetailPage / NetSettingsPage / SubscriptionPage / WebPage）：
 *      整页压上来，Index 连同底部导航一起被盖住，系统返回手势弹回上一页 —— 不用管。
 *
 *   2. 页内二级页（SecurityPage 的 sub：设备清单 / 应用流量 / 拦截）：
 *      同一个 @Component 里换内容。底部导航是 Index 画的**浮层**，它不知道里面换页了，
 *      于是二级页底下还压着四个页签；系统返回键也找不到路由栈，按一下就**直接退出 App**。
 *
 * 第二种必须把状态挂到全局（V2 的 AppStorageV2 单例 UI，见 core/UIState.ets），
 * 让壳（Index）知道「现在在二级页」：藏掉底部导航、把返回键改成「退回一级页」。
 * 页面自己 @Monitor 这个计数，收到就关掉 sub。
 */
export class Shell {
  /** 进入二级页：记下标题（空串 = 停在一级页） */
  static enter(title: string): void {
    UI.subTitle = title;
  }

  /** 退回一级页 */
  static leave(): void {
    UI.subTitle = '';
  }

  static title(): string {
    return UI.subTitle;
  }

  /** 壳请求「退回一级页」：计数器 +1，页面 @Monitor 到就关掉自己的 sub */
  static requestBack(): void {
    UI.backTick++;
  }
}
