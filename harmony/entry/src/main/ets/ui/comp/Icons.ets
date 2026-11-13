import { IconData } from './IconData';

/**
 * 页签图标里只留下「控件装饰」：返回箭头、行尾箭头、对勾、关闭。
 *
 * 这些是 22×22 手算的坐标，和 24 格的设计稿混用会因为缩放比例不同而粗细不一，
 * 所以它们留在 Ico，由 LineIcon 用 design=22 画；语义图标一律走 Glyph。
 */
export class Ico {
  static readonly CHEVRON: string = 'M8.5 5.5 L14.5 11 L8.5 16.5';
  static readonly CHECK: string = 'M4.5 11.5 L9 16 L17.5 6.5';
  static readonly CLOSE: string = 'M6.6 6.6 L17.4 17.4 M17.4 6.6 L6.6 17.4';
}

/**
 * 小图标（卡片标题、设置行、按钮）。
 *
 * 图形来自 design/icons（iStore Pilot SVG Icon Library），由
 * scripts/gen_icons.py 归一化成 24×24 的 M/L/C/Z，运行时交给 GlyphIcon
 * 用 Canvas 回放。常量名 = 文件名（kebab-case → UPPER_SNAKE）。
 *
 * 22 格那套手算路径已经退到 Ico，只服务返回/行尾箭头这类「控件装饰」。
 */
export class Glyph {
  static readonly ADD: string = 'add';
  static readonly ALL_HARDWARE: string = 'all-hardware';
  static readonly APP_PASSWORD: string = 'app-password';
  static readonly APP_TRAFFIC: string = 'app-traffic';
  static readonly BACK: string = 'back';
  static readonly BACKUP: string = 'backup';
  static readonly BROADBAND: string = 'broadband';
  static readonly CHECK: string = 'check';
  static readonly CHEVRON_DOWN: string = 'chevron-down';
  static readonly CHEVRON_RIGHT: string = 'chevron-right';
  static readonly CLEAR_CACHE: string = 'clear-cache';
  static readonly CLOSE: string = 'close';
  static readonly CONFIG_FILE: string = 'config-file';
  static readonly COPY: string = 'copy';
  static readonly DELETE: string = 'delete';
  static readonly DEVICE_INFO: string = 'device-info';
  static readonly DEVICES: string = 'devices';
  static readonly DOWNLOAD: string = 'download';
  static readonly DOWNLOAD_SPEED: string = 'download-speed';
  static readonly EDIT: string = 'edit';
  static readonly EMPTY: string = 'empty';
  static readonly ETHERNET_PORT: string = 'ethernet-port';
  static readonly EYE: string = 'eye';
  static readonly EYE_OFF: string = 'eye-off';
  static readonly INTERCEPT: string = 'intercept';
  static readonly INTERCEPT_LOGS: string = 'intercept-logs';
  static readonly INTERNET_STATUS: string = 'internet-status';
  static readonly IPV4: string = 'ipv4';
  static readonly IPV6: string = 'ipv6';
  static readonly LAN_GATEWAY: string = 'lan-gateway';
  static readonly LATENCY: string = 'latency';
  static readonly LINK: string = 'link';
  static readonly LOCK: string = 'lock';
  static readonly LOGIN_USER: string = 'login-user';
  static readonly LOGOUT: string = 'logout';
  static readonly MEMORY: string = 'memory';
  static readonly MORE: string = 'more';
  static readonly NETWORK: string = 'network';
  static readonly NETWORK_SETTINGS: string = 'network-settings';
  static readonly PACKAGE: string = 'package';
  static readonly PACKAGE_UPDATE: string = 'package-update';
  static readonly PACKET_LOSS: string = 'packet-loss';
  static readonly PERMISSION: string = 'permission';
  static readonly POWER: string = 'power';
  static readonly PROCESSOR: string = 'processor';
  static readonly PROXY: string = 'proxy';
  static readonly REFRESH: string = 'refresh';
  static readonly RESTART_NETWORK: string = 'restart-network';
  static readonly RESTART_ROUTER: string = 'restart-router';
  static readonly ROUTER_PASSWORD: string = 'router-password';
  static readonly RULES_REFRESH: string = 'rules-refresh';
  static readonly SEARCH: string = 'search';
  static readonly SECURITY: string = 'security';
  static readonly SERVER_ADDRESS: string = 'server-address';
  static readonly SHUTDOWN: string = 'shutdown';
  static readonly SIGNAL: string = 'signal';
  static readonly STATUS_ERROR: string = 'status-error';
  static readonly STATUS_INFO: string = 'status-info';
  static readonly STATUS_LOADING: string = 'status-loading';
  static readonly STATUS_OFFLINE: string = 'status-offline';
  static readonly STATUS_ONLINE: string = 'status-online';
  static readonly STATUS_SUCCESS: string = 'status-success';
  static readonly STATUS_WARNING: string = 'status-warning';
  static readonly SYNC: string = 'sync';
  static readonly SYSTEM_DISK: string = 'system-disk';
  static readonly SYSTEM_LOAD: string = 'system-load';
  static readonly SYSTEM_SETTINGS: string = 'system-settings';
  static readonly SYSTEM_UPDATE: string = 'system-update';
  static readonly THEME: string = 'theme';
  static readonly TIMEOUT: string = 'timeout';
  static readonly TOGGLE: string = 'toggle';
  static readonly UNLOCK: string = 'unlock';
  static readonly UPGRADE_PROGRESS: string = 'upgrade-progress';
  static readonly UPLOAD: string = 'upload';
  static readonly UPLOAD_SPEED: string = 'upload-speed';
  static readonly WIFI_2_4G: string = 'wifi-2-4g';
  static readonly WIFI_5G: string = 'wifi-5g';
  static readonly WIFI_OFFLINE: string = 'wifi-offline';
  static readonly WIRED_CONNECTION: string = 'wired-connection';

  // 旧名保留：漏改的调用点仍然能画出近义图标，不会变成空白
  static readonly GLOBE: string = 'network';
  static readonly PALETTE: string = 'theme';
  static readonly BOX: string = 'package';
  static readonly SHIELD: string = 'security';
  static readonly INFO: string = 'status-info';
  static readonly KEY: string = 'app-password';
  static readonly CLOCK: string = 'timeout';
  static readonly CHIP: string = 'processor';
  static readonly LIST: string = 'intercept-logs';
  static readonly BOLT: string = 'restart-network';
  static readonly CHEVRON: string = 'chevron-right';
  static readonly CHEVRON_LEFT: string = 'back';
  static readonly SWAP: string = 'sync';
  static readonly TRASH: string = 'delete';
  static readonly MOON: string = 'theme';

  static stroke(kind: string): string {
    return IconData.stroke(kind);
  }

  static fill(kind: string): string {
    return IconData.fill(kind);
  }
}
