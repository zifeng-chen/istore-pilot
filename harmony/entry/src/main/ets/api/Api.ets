import { common } from '@kit.AbilityKit';
import { Http, HttpResult } from './Http';
import { J } from '../core/Json';
import { Session } from '../core/Session';
import { Snap } from '../core/Snap';

export interface ApiResult {
  ok: boolean;
  fromCache: boolean;
  code: number;
  data: J;
  error: string;
}

export type AuthFailHandler = () => void;

/**
 * Agent 接口门面。
 *
 * 两条路径刻意分开：
 *   peek()  —— 只读本地快照，命中就立刻返回，用来让界面第一帧就有内容
 *   get()   —— 请求真实数据，成功后回写快照
 *
 * 页面里通常是「先 peek 渲染，再 get 覆盖」，这样从切页签到看到数字之间
 * 不会出现一段空白转圈 —— 这和 Android 端 Api 的策略一致。
 */
export class Api {
  private static authFail: AuthFailHandler | null = null;

  /** 令牌失效时统一跳登录页，由 EntryAbility 注册 */
  static setAuthFailHandler(h: AuthFailHandler): void {
    Api.authFail = h;
  }

  static async peek(ctx: common.Context, path: string): Promise<ApiResult> {
    const text: string = await Snap.get(ctx, path);
    if (text.length === 0) {
      return {
        ok: false, fromCache: true, code: -1, data: J.empty(), error: ''
      };
    }
    return {
      ok: true, fromCache: true, code: 200, data: J.parse(text), error: ''
    };
  }

  static async get(ctx: common.Context, path: string): Promise<ApiResult> {
    const r: HttpResult = await Http.send(Session.base(), Session.token(), 'GET', path, '');
    return Api.finish(ctx, path, r);
  }

  /** 不走快照，用于「先登录再请求」这类必须实时的场景 */
  static async getFresh(ctx: common.Context, path: string): Promise<ApiResult> {
    const r: HttpResult = await Http.send(Session.base(), Session.token(), 'GET', path, '');
    return Api.finish(ctx, path, r);
  }

  static async post(ctx: common.Context, path: string,
    body: Record<string, Object>): Promise<ApiResult> {
    const text: string = JSON.stringify(body);
    const r: HttpResult = await Http.send(Session.base(), Session.token(), 'POST', path, text);
    return Api.finish(ctx, path, r);
  }

  /**
   * 登录。此时还没有令牌，地址由用户输入。
   * 成功后写入 Session，后续请求自动带上 Authorization。
   */
  static async login(base: string, password: string): Promise<ApiResult> {
    const body: Record<string, Object> = { 'password': password };
    const r: HttpResult = await Http.send(base, '', 'POST', '/api/v1/login',
      JSON.stringify(body));
    if (!r.ok) {
      let msg: string = r.error;
      if (msg.length === 0) {
        msg = r.code === 401 ? '密码错误' : ('连接失败（HTTP ' + r.code + '）');
      }
      return {
        ok: false, fromCache: false, code: r.code, data: J.empty(), error: msg
      };
    }
    return {
      ok: true, fromCache: false, code: r.code, data: J.parse(r.body), error: ''
    };
  }

  /** 探活，登录页用来确认地址填对了 */
  static async ping(base: string): Promise<ApiResult> {
    const r: HttpResult = await Http.send(base, '', 'GET', '/api/v1/ping', '');
    if (!r.ok) {
      return {
        ok: false, fromCache: false, code: r.code, data: J.empty(),
        error: r.error.length > 0 ? r.error : ('HTTP ' + r.code)
      };
    }
    return {
      ok: true, fromCache: false, code: r.code, data: J.parse(r.body), error: ''
    };
  }

  private static async finish(ctx: common.Context, path: string,
    r: HttpResult): Promise<ApiResult> {
    if (r.code === 401) {
      if (Api.authFail !== null) {
        Api.authFail();
      }
      return {
        ok: false, fromCache: false, code: 401, data: J.empty(), error: '登录已失效'
      };
    }
    if (!r.ok) {
      // 请求失败不做任何缓存写入：旧快照比「空数据」有用得多
      return {
        ok: false, fromCache: false, code: r.code, data: J.empty(),
        error: r.error.length > 0 ? r.error : ('HTTP ' + r.code)
      };
    }
    await Snap.put(ctx, path, r.body);
    return {
      ok: true, fromCache: false, code: r.code, data: J.parse(r.body), error: ''
    };
  }
}
