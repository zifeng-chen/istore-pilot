import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { preferences } from '@kit.ArkData';

const RAW_FILE: string = 'demo.json';
const PREF_NAME: string = 'istore_session';
const KEY_DEMO: string = 'demo_mode';

/** 演示模式下所有写操作统一回这句 —— 别让用户以为点了没反应 */
const READ_ONLY: string = '演示模式只能浏览，这项操作需要连接真实路由器';

/**
 * 演示模式：把录制好的接口返回打进包里，不连路由器、不需要网络。
 *
 * 存在的理由只有一个 —— 应用商店审核。审核员没有你的路由器，打开 App 就
 * 停在登录页；有了这份数据，点「先看看演示」就能把五个页签完整看一遍。
 *
 * 两条硬规矩：
 *   1. **只读**。写操作在 Api 层就被拦掉并明确告知，不假装成功 ——
 *      假装成功会让审核员以为「禁网」真的生效了，反而更糟。
 *   2. **数据已脱敏**。MAC / 内网地址 / 机场名 / 订阅链接 / 访问日志全部
 *      换过，生成脚本是 scripts/record_demo.py，随时可以重录。
 *
 * 数据的形状和真实接口完全一致（就是录下来的真机返回），所以页面上没有
 * 任何「演示专用分支」—— 少一套分支就少一处线上线下不一致的 bug。
 */
export class Demo {
  private static active: boolean = false;
  private static loaded: boolean = false;
  /** 规范化 key → 接口返回的 JSON 文本（不是对象：上层直接当 HTTP body 用） */
  private static routes: Map<string, string> = new Map<string, string>();
  /** 供前缀回退用的原始 key 列表 */
  private static keys: string[] = [];

  static isOn(): boolean {
    return Demo.active;
  }

  /** 写操作被拒时给界面看的文案 */
  static readOnly(): string {
    return READ_ONLY;
  }

  /**
   * 首次启动调一次：读 rawfile、建索引、恢复上次是否停在演示模式。
   *
   * 放在 Session.init 旁边而不是各页 aboutToAppear 里 —— 一个 130 KB 的
   * JSON 反复解析会拖慢每次切页签。
   */
  static async init(ctx: common.Context): Promise<void> {
    if (Demo.loaded) {
      return;
    }
    Demo.loaded = true;
    try {
      const p = await preferences.getPreferences(ctx, PREF_NAME);
      Demo.active = (await p.get(KEY_DEMO, false)) as boolean;
    } catch (e) {
      Demo.active = false;
    }
    // 只有真的停在演示模式才解析那 130 KB —— 正常连接的用户不该为它付启动时间
    if (Demo.active) {
      await Demo.loadRoutes(ctx);
    }
  }

  private static async loadRoutes(ctx: common.Context): Promise<boolean> {
    if (Demo.routes.size > 0) {
      return true;
    }
    try {
      const bytes: Uint8Array = await ctx.resourceManager.getRawFileContent(RAW_FILE);
      const text: string = util.TextDecoder.create('utf-8').decodeToString(bytes);
      const doc = JSON.parse(text) as Record<string, Object>;
      const rs = doc['routes'] as Record<string, Object>;
      const names: string[] = Object.keys(rs);
      for (let i = 0; i < names.length; i++) {
        const item = rs[names[i]] as Record<string, Object>;
        Demo.routes.set(names[i], JSON.stringify(item['data']));
        Demo.keys.push(names[i]);
      }
    } catch (e) {
      // 读不到就当没有：登录页的入口会提示不可用，正常连接不受影响
      Demo.routes.clear();
    }
    return Demo.routes.size > 0;
  }

  /** 返回是否真的进得去（包里没数据就返回 false，由调用方提示） */
  static async enter(ctx: common.Context): Promise<boolean> {
    const ok: boolean = await Demo.loadRoutes(ctx);
    if (!ok) {
      return false;
    }
    Demo.active = true;
    await Demo.save(ctx, true);
    return true;
  }

  static async leave(ctx: common.Context): Promise<void> {
    Demo.active = false;
    await Demo.save(ctx, false);
  }

  /**
   * 取接口数据。命中返回 JSON 文本，没录到返回空串（上层按「无数据」处理）。
   *
   * 没录到的接口不编假数据：编出来的字段对不上界面，比空着更容易露馅。
   */
  static data(path: string): string {
    if (Demo.routes.size === 0) {
      return '';
    }
    const k: string = Demo.key(path);
    const hit: string | undefined = Demo.routes.get(k);
    if (hit !== undefined) {
      return hit;
    }
    // 前缀回退：带查询串的接口（devices/detail?mac=xx）只录了几台设备，
    // 其余设备拿同一条详情顶替 —— 反正演示数据里设备长得都一样
    const base: string = Demo.key(Demo.pathOf(path));
    for (let i = 0; i < Demo.keys.length; i++) {
      const key: string = Demo.keys[i];
      if (key === base || key.startsWith(base + '_')) {
        const v: string | undefined = Demo.routes.get(key);
        if (v !== undefined) {
          return v;
        }
      }
    }
    return '';
  }

  /** 路径 + 查询串 → key。规则和 scripts/record_demo.py 的 _key 必须一致 */
  private static key(path: string): string {
    let src: string = path;
    // 和 Python 的 path.strip("/") 对齐：只去首尾斜杠
    while (src.startsWith('/')) {
      src = src.substring(1);
    }
    while (src.endsWith('/')) {
      src = src.substring(0, src.length - 1);
    }
    let out: string = '';
    for (let i = 0; i < src.length; i++) {
      const code: number = src.charCodeAt(i);
      const alnum: boolean = (code >= 48 && code <= 57)
        || (code >= 65 && code <= 90)
        || (code >= 97 && code <= 122);
      out += alnum ? src.charAt(i) : '_';
    }
    return out;
  }

  private static pathOf(path: string): string {
    const q: number = path.indexOf('?');
    return q >= 0 ? path.substring(0, q) : path;
  }

  private static async save(ctx: common.Context, on: boolean): Promise<void> {
    try {
      const p = await preferences.getPreferences(ctx, PREF_NAME);
      await p.put(KEY_DEMO, on);
      await p.flush();
    } catch (e) {
      // 落盘失败只影响下次启动的默认状态，本次仍然生效
    }
  }
}
