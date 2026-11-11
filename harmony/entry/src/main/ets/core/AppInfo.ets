import { bundleManager } from '@kit.AbilityKit';

/**
 * App 自身的版本号。
 *
 * 以前「关于」卡片里写死 `2.14.0`，页签侧栏也拿 `UI.agentVer` 当 App 版本显示 ——
 * 那是路由器上 Agent 的版本，和安装包版本根本不是一个东西，发版时也不会跟着变。
 * 这里直接问系统要 versionName（来自 AppScope/app.json5），发版脚本改一处就够。
 */
export class AppInfo {
  private static cached: string = '';

  static version(): string {
    if (AppInfo.cached.length > 0) {
      return AppInfo.cached;
    }
    try {
      const info = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      AppInfo.cached = info.versionName;
    } catch (e) {
      AppInfo.cached = '';
    }
    return AppInfo.cached;
  }
}
