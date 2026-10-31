import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const PREF_NAME: string = 'istore_session';
const KEY_BASE: string = 'base';
const KEY_TOKEN: string = 'token';
const KEY_USER: string = 'user';

/**
 * 服务器地址与登录令牌。
 *
 * 和 Android 端 Session 一一对应：地址与令牌都落在本机，
 * 令牌失效时由 Http 层统一回调到登录页，不在各页里各自判断。
 *
 * 这里刻意不用 AppStorage 存令牌 —— 它会被所有订阅者一起刷新，
 * 而令牌只在登录/登出时变化，没必要进响应式链路。
 */
export class Session {
  private static pref: preferences.Preferences | null = null;
  private static baseUrl: string = '';
  private static authToken: string = '';
  private static userName: string = '';

  /** 首次启动时调一次，之后所有读写都走内存 + 异步落盘 */
  static async init(ctx: common.Context): Promise<void> {
    if (Session.pref !== null) {
      return;
    }
    const p = await preferences.getPreferences(ctx, PREF_NAME);
    Session.pref = p;
    Session.baseUrl = (await p.get(KEY_BASE, '')) as string;
    Session.authToken = (await p.get(KEY_TOKEN, '')) as string;
    Session.userName = (await p.get(KEY_USER, '')) as string;
  }

  static base(): string {
    return Session.baseUrl;
  }

  /**
   * 把用户随手输入的地址整理成可用的 base url。
   *
   * 和安卓 `Session.normalize`、iOS `Session.normalize` 完全同一套规则：
   * 不写协议补 http://，不写端口补 8443，去掉尾斜杠。
   * 三端都能只输 `192.168.100.1`。
   */
  static normalize(raw: string): string {
    let v: string = raw.length > 0 ? raw.trim() : '';
    if (v.length === 0) {
      return 'http://192.168.100.1:8443';
    }
    if (!v.startsWith('http://') && !v.startsWith('https://')) {
      v = 'http://' + v;
    }
    while (v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    const after: string = v.substring(v.indexOf('://') + 3);
    if (after.indexOf(':') < 0 && after.indexOf('/') < 0) {
      v = v + ':8443';
    }
    return v;
  }

  /** 不含协议的展示用地址（输入框占位符） */
  static defaultHost(): string {
    return '192.168.100.1:8443';
  }

  static token(): string {
    return Session.authToken;
  }

  static user(): string {
    return Session.userName;
  }

  static loggedIn(): boolean {
    return Session.authToken.length > 0 && Session.baseUrl.length > 0;
  }

  static async signIn(ctx: common.Context, base: string, token: string, user: string): Promise<void> {
    Session.baseUrl = base;
    Session.authToken = token;
    Session.userName = user;
    const p = await Session.ready(ctx);
    await p.put(KEY_BASE, base);
    await p.put(KEY_TOKEN, token);
    await p.put(KEY_USER, user);
    await p.flush();
  }

  /** 令牌失效：只清令牌，保留服务器地址，省得用户重新输一遍 IP */
  static async signOut(ctx: common.Context): Promise<void> {
    Session.authToken = '';
    const p = await Session.ready(ctx);
    await p.put(KEY_TOKEN, '');
    await p.flush();
  }

  /** 改服务器地址。令牌不动 —— 换了地址多半还是同一台机器，省一次登录 */
  static async setBase(ctx: common.Context, base: string): Promise<void> {
    Session.baseUrl = base;
    const p = await Session.ready(ctx);
    await p.put(KEY_BASE, base);
    await p.flush();
  }

  private static async ready(ctx: common.Context): Promise<preferences.Preferences> {
    if (Session.pref === null) {
      Session.pref = await preferences.getPreferences(ctx, PREF_NAME);
    }
    return Session.pref;
  }
}
