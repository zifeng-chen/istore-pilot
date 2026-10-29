import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';

export interface HttpResult {
  ok: boolean;
  code: number;
  body: string;
  error: string;
}

/**
 * 极简 HTTP 客户端。
 *
 * 只用系统自带的 @kit.NetworkKit，不引 axios —— 请求形态很单一（GET/POST + Bearer），
 * 引一个第三方库只会多一层要跟着升级的依赖。
 *
 * 超时设得比 Android 端短一点：路由器就在局域网里，6 秒还没响应基本就是挂了，
 * 让用户等着转圈不如早点报错。
 */
export class Http {
  private static readonly CONNECT_TIMEOUT: number = 6000;
  private static readonly READ_TIMEOUT: number = 12000;

  static async send(base: string, token: string, method: string, path: string,
    body: string): Promise<HttpResult> {
    const url: string = Http.join(base, path);
    if (url.length === 0) {
      return {
        ok: false, code: -1, body: '', error: '服务器地址为空'
      };
    }

    const req = http.createHttp();
    try {
      const headers: Record<string, string> = {
        'Content-Type': 'application/json',
        'Accept': 'application/json'
      };
      if (token.length > 0) {
        headers['Authorization'] = 'Bearer ' + token;
      }

      const options: http.HttpRequestOptions = {
        method: method === 'POST' ? http.RequestMethod.POST : http.RequestMethod.GET,
        header: headers,
        connectTimeout: Http.CONNECT_TIMEOUT,
        readTimeout: Http.READ_TIMEOUT,
        expectDataType: http.HttpDataType.STRING
      };
      if (method === 'POST' && body.length > 0) {
        options.extraData = body;
      }

      const res = await req.request(url, options);
      let text: string = '';
      if (typeof res.result === 'string') {
        text = res.result as string;
      } else if (res.result !== null && res.result !== undefined) {
        text = JSON.stringify(res.result);
      }
      const code: number = res.responseCode;
      return {
        ok: code >= 200 && code < 300,
        code: code,
        body: text,
        error: ''
      };
    } catch (e) {
      const err = e as BusinessError;
      const raw: string = err.message === undefined ? '' : err.message;
      return {
        ok: false, code: -1, body: '', error: Http.zhError(raw)
      };
    } finally {
      req.destroy();
    }
  }

  /**
   * 系统抛的是英文错误（`Failed to connect to the server`、`Timeout was reached`…），
   * 直接甩到界面上，整页中文里夹一句英文很难看，用户也读不出该做什么。
   * 这里只做「能对应上就换成人话」，认不出来的保留原文，免得丢掉排查线索。
   */
  private static zhError(raw: string): string {
    const s: string = raw.toLowerCase();
    if (s.length === 0) {
      return '网络请求失败';
    }
    if (s.includes('timeout') || s.includes('timed out')) {
      return '请求超时，路由器没响应';
    }
    if (s.includes('connect') || s.includes('unreachable') || s.includes('refused')) {
      return '连不上路由器，检查地址与局域网';
    }
    if (s.includes('401') || s.includes('unauthorized')) {
      return '凭证已失效，请重新登录';
    }
    if (s.includes('cleartext') || s.includes('permission')) {
      return '被系统拦截：检查网络权限配置';
    }
    return raw;
  }

  /** base 可能带也可能不带尾斜杠，统一收一次 */
  private static join(base: string, path: string): string {
    if (base.length === 0) {
      return '';
    }
    let b: string = base;
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    if (!b.startsWith('http://') && !b.startsWith('https://')) {
      b = 'http://' + b;
    }
    if (!path.startsWith('/')) {
      return b + '/' + path;
    }
    return b + path;
  }
}
