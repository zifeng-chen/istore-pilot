/**
 * JSON 安全取值。
 *
 * ArkTS 里 `JSON.parse` 返回 Object，直接下标访问既拿不到类型也没法给默认值，
 * 而 Agent 的返回又大量是「字段可能不存在」的形态（比如 IPv6 没拿到就没有 ipv6 键）。
 * 统一用这层包一下，上层就不用到处写 try/catch 和空判断。
 */
export class J {
  private d: Record<string, Object> = {};

  static empty(): J {
    return new J();
  }

  static parse(text: string): J {
    const j = new J();
    if (text.length === 0) {
      return j;
    }
    try {
      const v = JSON.parse(text) as Record<string, Object>;
      if (v !== null && v !== undefined) {
        j.d = v;
      }
    } catch (e) {
      // 解析失败保持空对象，上层按默认值走，不抛给 UI
    }
    return j;
  }

  private static wrap(o: Object): J {
    const j = new J();
    if (o !== null && o !== undefined && typeof o === 'object') {
      j.d = o as Record<string, Object>;
    }
    return j;
  }

  /** 原始文本，仅调试用 */
  raw(): string {
    return JSON.stringify(this.d);
  }

  has(key: string): boolean {
    const v: Object = this.d[key];
    return v !== undefined && v !== null;
  }

  /** 字符串数组：Agent 很多字段是 ['1.1.1.1','8.8.8.8'] 这种裸数组 */
  strs(key: string): string[] {
    const out: string[] = [];
    const v: Object = this.d[key];
    if (!Array.isArray(v)) {
      return out;
    }
    const a = v as Object[];
    for (let i = 0; i < a.length; i++) {
      const e = a[i];
      if (e !== null && e !== undefined) {
        out.push(String(e));
      }
    }
    return out;
  }

  str(key: string, def: string): string {
    const v: Object = this.d[key];
    if (v === undefined || v === null) {
      return def;
    }
    if (typeof v === 'string') {
      return v as string;
    }
    return String(v);
  }

  num(key: string, def: number): number {
    const v: Object = this.d[key];
    if (v === undefined || v === null) {
      return def;
    }
    if (typeof v === 'number') {
      return v as number;
    }
    if (typeof v === 'string') {
      const n: number = Number.parseFloat(v as string);
      return Number.isFinite(n) ? n : def;
    }
    return def;
  }

  bool(key: string, def: boolean): boolean {
    const v: Object = this.d[key];
    if (v === undefined || v === null) {
      return def;
    }
    if (typeof v === 'boolean') {
      return v as boolean;
    }
    if (typeof v === 'number') {
      return (v as number) !== 0;
    }
    return def;
  }

  /** 取子对象；不存在时返回空 J，链式取值不会炸 */
  obj(key: string): J {
    const v: Object = this.d[key];
    if (v === undefined || v === null) {
      return J.empty();
    }
    return J.wrap(v);
  }

  /** 取对象数组；非数组或不存在时返回空数组 */
  arr(key: string): J[] {
    const v: Object = this.d[key];
    const out: J[] = [];
    if (v === undefined || v === null) {
      return out;
    }
    if (!Array.isArray(v)) {
      return out;
    }
    const list = v as Object[];
    for (let i = 0; i < list.length; i++) {
      out.push(J.wrap(list[i]));
    }
    return out;
  }

  /** 取字符串数组，过滤掉非字符串元素 */
  strArr(key: string): string[] {
    const v: Object = this.d[key];
    const out: string[] = [];
    if (v === undefined || v === null || !Array.isArray(v)) {
      return out;
    }
    const list = v as Object[];
    for (let i = 0; i < list.length; i++) {
      const e: Object = list[i];
      if (typeof e === 'string') {
        out.push(e as string);
      }
    }
    return out;
  }
}
