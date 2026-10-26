import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const PREF_NAME: string = 'istore_snap';
const SUFFIX_TS: string = '__ts';

/**
 * 接口响应的本地快照。
 *
 * 「秒开」的关键：界面先拿上一次的 JSON 渲染，同时后台再请求真实数据，
 * 回来后原地替换。用户看到的是「立刻有内容」，而不是一个转圈的空白页。
 *
 * 和 Android 端的差别：这里存的是原始 JSON 文本，不做二次包装 ——
 * 解析交给上层，缓存层只管搬运。
 */
export class Snap {
  private static pref: preferences.Preferences | null = null;

  /** 路径里带 ? & 这类字符不能直接当 preferences 的键，统一压成下划线 */
  private static key(path: string): string {
    let out: string = '';
    for (let i = 0; i < path.length; i++) {
      const ch: string = path.charAt(i);
      if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
        (ch >= '0' && ch <= '9') || ch === '/' || ch === '_' || ch === '-') {
        out += ch;
      } else {
        out += '_';
      }
    }
    return out;
  }

  static async put(ctx: common.Context, path: string, body: string): Promise<void> {
    if (body.length === 0) {
      return;
    }
    const p = await Snap.ready(ctx);
    const k = Snap.key(path);
    await p.put(k, body);
    await p.put(k + SUFFIX_TS, Date.now());
    await p.flush();
  }

  static async get(ctx: common.Context, path: string): Promise<string> {
    const p = await Snap.ready(ctx);
    const v = await p.get(Snap.key(path), '');
    return v as string;
  }

  /** 快照距今多少秒，没有快照返回 -1 */
  static async ageSeconds(ctx: common.Context, path: string): Promise<number> {
    const p = await Snap.ready(ctx);
    const ts = (await p.get(Snap.key(path) + SUFFIX_TS, 0)) as number;
    if (ts <= 0) {
      return -1;
    }
    return Math.floor((Date.now() - ts) / 1000);
  }

  static async clear(ctx: common.Context): Promise<void> {
    const p = await Snap.ready(ctx);
    await p.clear();
    await p.flush();
  }

  private static async ready(ctx: common.Context): Promise<preferences.Preferences> {
    if (Snap.pref === null) {
      Snap.pref = await preferences.getPreferences(ctx, PREF_NAME);
    }
    return Snap.pref;
  }
}
