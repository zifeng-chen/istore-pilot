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
      let msg: string = err.message;
      if (msg === undefined || msg.length === 0) {
        msg = '网络请求失败';
      }
      return {
        ok: false, code: -1, body: '', error: msg
      };
    } finally {
      req.destroy();
    }
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
