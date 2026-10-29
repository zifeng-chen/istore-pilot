/** 数字与单位的格式化。路由器返回的都是原始字节 / bps / 秒，界面统一走这里。 */
export class Fmt {
  private static readonly UNITS: string[] = ['KB', 'MB', 'GB', 'TB'];

  static bytes(v: number): string {
    if (!Number.isFinite(v) || v < 0) {
      return '—';
    }
    if (v < 1024) {
      return Math.round(v) + ' B';
    }
    let d: number = v;
    let i: number = -1;
    while (d >= 1024 && i < 3) {
      d = d / 1024;
      i++;
    }
    const s: string = d >= 100 ? d.toFixed(0) : d.toFixed(1);
    return s + ' ' + Fmt.UNITS[i];
  }

  /** 速率：入参是字节/秒 */
  static bps(v: number): string {
    return Fmt.bytes(Math.max(0, v)) + '/s';
  }

  /**
   * 图表 Y 轴专用：越短越好。
   * 一行能放下 3 个标签的宽度才是好刻度，「12.4 MB/s」这种会互相叠在一起，
   * 所以这里砍掉小数和单位斜杠，只留数字 + 一个字母。
   */
  static bpsAxis(v: number): string {
    if (v <= 0) {
      return '0';
    }
    if (v < 1024) {
      return Math.round(v) + 'B';
    }
    if (v < 1024 * 1024) {
      return Math.round(v / 1024) + 'K';
    }
    if (v < 1024 * 1024 * 1024) {
      const m: number = v / (1024 * 1024);
      return (m >= 10 ? m.toFixed(0) : m.toFixed(1)) + 'M';
    }
    return (v / (1024 * 1024 * 1024)).toFixed(1) + 'G';
  }

  static count(v: number): string {
    if (!Number.isFinite(v)) {
      return '—';
    }
    const s: string = Math.round(v).toString();
    let out: string = '';
    let n: number = 0;
    for (let i = s.length - 1; i >= 0; i--) {
      out = s.charAt(i) + out;
      n++;
      if (n % 3 === 0 && i > 0) {
        out = ',' + out;
      }
    }
    return out;
  }

  static pct(v: number): string {
    if (!Number.isFinite(v)) {
      return '—';
    }
    return v.toFixed(1) + '%';
  }

  static temp(c: number): string {
    if (!Number.isFinite(c) || c <= 0) {
      return '—';
    }
    return c.toFixed(0) + '°C';
  }

  /** 秒 → 「3 天 4 小时」/「2 小时 15 分」/「5 分钟」 */
  static dur(seconds: number): string {
    if (!Number.isFinite(seconds) || seconds <= 0) {
      return '—';
    }
    const d: number = Math.floor(seconds / 86400);
    const h: number = Math.floor((seconds % 86400) / 3600);
    const m: number = Math.floor((seconds % 3600) / 60);
    if (d > 0) {
      return h > 0 ? d + ' 天 ' + h + ' 小时' : d + ' 天';
    }
    if (h > 0) {
      return m > 0 ? h + ' 小时 ' + m + ' 分' : h + ' 小时';
    }
    if (m > 0) {
      return m + ' 分钟';
    }
    return Math.floor(seconds) + ' 秒';
  }

  /** 秒 → 「3 天 04:12:33」/「04:12:33」。
   *  运行时长是拿来「看它还在跑」的，`dur()` 只到分钟，界面上像定住了 */
  static uptime(seconds: number): string {
    const s: number = Number.isFinite(seconds) && seconds > 0 ? Math.floor(seconds) : 0;
    const pad = (n: number): string => (n < 10 ? '0' + n : '' + n);
    const hms: string = pad(Math.floor((s % 86400) / 3600)) + ':' +
      pad(Math.floor((s % 3600) / 60)) + ':' + pad(s % 60);
    const d: number = Math.floor(s / 86400);
    return d > 0 ? d + ' 天 ' + hms : hms;
  }

  /** 链路速率：2500 → 2.5G */
  static speed(mbps: number): string {
    if (!Number.isFinite(mbps) || mbps <= 0) {
      return '—';
    }
    if (mbps >= 1000) {
      return (mbps / 1000).toFixed(1) + 'G';
    }
    return Math.round(mbps) + 'M';
  }

  static orDash(v: string): string {
    return v === undefined || v === null || v.length === 0 ? '—' : v;
  }

  /**
   * 网口卡片里的极短速率：12.3M / 380K，不带 /s。
   * 一张卡要同时放下 ↓ 和 ↑，加单位就挤不进去了。
   */
  static shortBps(v: number): string {
    if (!Number.isFinite(v) || v <= 0) {
      return '0';
    }
    if (v < 1024) {
      return Math.round(v).toString() + 'B';
    }
    if (v < 1024 * 1024) {
      return Math.round(v / 1024).toString() + 'K';
    }
    if (v < 1024 * 1024 * 1024) {
      const m: number = v / (1024 * 1024);
      return (m >= 10 ? m.toFixed(0) : m.toFixed(1)) + 'M';
    }
    return (v / (1024 * 1024 * 1024)).toFixed(1) + 'G';
  }

  /** "2026-10-25T17:02:07+08:00" → "昨天 17:02" / "10-25 17:02" */
  static friendlyISO(iso: string): string {
    if (iso.length < 16) {
      return '';
    }
    const day: string = iso.substring(5, 10);
    const clock: string = iso.substring(11, 16);
    const now: Date = new Date();
    const today: string = Fmt.pad2(now.getMonth() + 1) + '-' + Fmt.pad2(now.getDate());
    if (day === today) {
      return clock;
    }
    const y: Date = new Date(now.getTime() - 86400000);
    const yday: string = Fmt.pad2(y.getMonth() + 1) + '-' + Fmt.pad2(y.getDate());
    return (day === yday ? '昨天 ' : day + ' ') + clock;
  }

  /** 时:分:秒，用于「快照时间」这类提示 */
  static clock(millis: number): string {
    const d: Date = new Date(millis);
    return Fmt.pad2(d.getHours()) + ':' + Fmt.pad2(d.getMinutes()) + ':' + Fmt.pad2(d.getSeconds());
  }

  static pad2(n: number): string {
    return n < 10 ? '0' + n.toString() : n.toString();
  }
}
