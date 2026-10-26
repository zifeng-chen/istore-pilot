package com.chaof.istoreos.util;

import java.util.Locale;

/** 数字与单位的格式化。路由器返回的都是原始字节 / bps / 秒，界面统一走这里。 */
public final class Fmt {

    private Fmt() {
    }

    public static String bytes(long v) {
        if (v < 1024L) {
            return v + " B";
        }
        double d = v;
        String[] units = {"KB", "MB", "GB", "TB"};
        int i = -1;
        while (d >= 1024D && i < units.length - 1) {
            d /= 1024D;
            i++;
        }
        return String.format(Locale.US, d >= 100 ? "%.0f %s" : "%.1f %s", d, units[i]);
    }

    /** 速率：入参是字节/秒 */
    public static String bps(double v) {
        return bytes((long) Math.max(0, v)) + "/s";
    }

    /**
     * 图表 Y 轴专用：越短越好。
     * 一行能放下 3 个标签的宽度才是好刻度，「12.4 MB/s」这种会互相叠在一起，
     * 所以这里砍掉小数和单位斜杠，只留数字 + 一个字母。
     */
    public static String bpsAxis(float v) {
        if (v <= 0) {
            return "0";
        }
        if (v < 1024f) {
            return Math.round(v) + "B";
        }
        if (v < 1024f * 1024f) {
            return Math.round(v / 1024f) + "K";
        }
        if (v < 1024f * 1024f * 1024f) {
            float m = v / (1024f * 1024f);
            return (m >= 10f ? String.format(Locale.US, "%.0f", m)
                    : String.format(Locale.US, "%.1f", m)) + "M";
        }
        return String.format(Locale.US, "%.1f", v / (1024f * 1024f * 1024f)) + "G";
    }

    public static String count(long v) {
        return String.format(Locale.US, "%,d", v);
    }

    public static String pct(double v) {
        return String.format(Locale.US, "%.1f%%", v);
    }

    public static String temp(double c) {
        return String.format(Locale.US, "%.0f°C", c);
    }

    /** 秒 → 「3 天 4 小时」/「2 小时 15 分」/「5 分钟」 */
    public static String dur(long seconds) {
        if (seconds <= 0) {
            return "—";
        }
        long d = seconds / 86400;
        long h = (seconds % 86400) / 3600;
        long m = (seconds % 3600) / 60;
        if (d > 0) {
            return h > 0 ? d + " 天 " + h + " 小时" : d + " 天";
        }
        if (h > 0) {
            return m > 0 ? h + " 小时 " + m + " 分" : h + " 小时";
        }
        if (m > 0) {
            return m + " 分钟";
        }
        return seconds + " 秒";
    }

    /**
     * hero 卡片里的极短时长：6 天 / 23 小时 / 45 分。
     * 那里三列并排，每列只有屏宽的 1/3，「6 天 5 小时」必被截成「6 天 5…」。
     */
    public static String shortDur(long seconds) {
        if (seconds <= 0) {
            return "—";
        }
        if (seconds >= 86400) {
            return Math.round(seconds / 86400f) + " 天";
        }
        if (seconds >= 3600) {
            return Math.round(seconds / 3600f) + " 小时";
        }
        return Math.max(1, Math.round(seconds / 60f)) + " 分";
    }

    /** 链路速率：2500 → 2.5G */
    public static String speed(int mbps) {
        if (mbps <= 0) {
            return "—";
        }
        if (mbps >= 1000) {
            return String.format(Locale.US, "%.1fG", mbps / 1000.0);
        }
        return mbps + "M";
    }

    public static String orDash(String v) {
        return v == null || v.isEmpty() ? "—" : v;
    }

    /** 时:分:秒，用于「快照时间」这类提示 */
    public static String clock(long millis) {
        java.text.SimpleDateFormat f = new java.text.SimpleDateFormat("HH:mm:ss", Locale.US);
        return f.format(new java.util.Date(millis));
    }
}
