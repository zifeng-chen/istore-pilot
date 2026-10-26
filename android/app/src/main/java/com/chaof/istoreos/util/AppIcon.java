package com.chaof.istoreos.util;

import android.content.Context;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.view.Gravity;
import android.view.View;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * 应用图标。
 *
 * 优先用打包进 APK 的官方图标（res/drawable-nodpi/ic_app_*.png，
 * 由 scripts/fetch_app_icons.py 从 App Store 抓取），认不出来的域名
 * 再退回「品牌主色 + 名称首字」自绘方案。
 *
 * 为什么图标要预置而不是运行时下载：路由器只按域名认应用，拿不到手机里的
 * 安装包图标；而 App 本身常年在内网跑，没网的时侯也不该变成一片灰块。
 */
public final class AppIcon {

    /** 品牌 / 分类 → 主色。**顺序即优先级**，越具体的写在越前面 */
    private static final String[] KEYS = {
            // ---- 视频
            "番茄小说", "腾讯视频", "哔哩哔哩", "爱奇艺", "优酷", "芒果", "西瓜", "快手", "抖音",
            "YouTube", "Netflix", "Disney", "Prime", "Plex", "Emby", "绿联", "群晖", "搜狐",
            // ---- 社交 / 内容
            "微信", "QQ", "Telegram", "WhatsApp", "小红书", "微博", "知乎", "豆瓣", "Discord",
            // ---- 音频 / 阅读
            "喜马拉雅", "网易云", "QQ 音乐", "酷狗", "咪咕", "Spotify", "起点", "七猫", "阅读",
            // ---- 游戏
            "Steam", "Epic", "米哈游", "暴雪", "Riot", "主机", "拓竹",
            // ---- AI / 开发
            "ChatGPT", "Claude", "DeepSeek", "Gemini", "AI 编程", "GitHub", "开发仓库",
            // ---- 购物 / 出行
            "淘宝", "京东", "拼多多", "美团", "饿了么", "苏宁", "携程", "高德", "百度地图",
            "12306", "滴滴",
            // ---- 智能家居 / 厂商
            "华为", "小米", "米家", "OPPO", "vivo", "美的", "海尔", "电视厂商", "摄像头", "扫地机",
            "路由器", "中兴",
            // ---- 系统 / 网络
            "Apple", "微软", "Google", "CDN", "时间", "百度", "夸克", "腾讯服务", "网易",
            "推送", "遥测", "IP 直连", "远程控制",
            // ---- 分类兜底
            "视频", "社交", "音频", "阅读", "游戏", "AI", "开发", "购物", "出行",
            "智能家居", "系统", "网络", "工具", "其他",
    };

    private static final int[] COLORS = {
            0xFF5A2D, 0xFF7A00, 0xFB7299, 0x00BE06, 0x1E9FFF, 0xFF6C00, 0xFF3B30, 0xFF4600, 0x161823,
            0xFF0033, 0xE50914, 0x113CCF, 0x00A8E1, 0xE5A00D, 0x52B54B, 0x2F80ED, 0x2C7BE5, 0xFF6A00,
            0x07C160, 0x12B7F5, 0x229ED9, 0x25D366, 0xFF2442, 0xE6162D, 0x0084FF, 0x2E963D, 0x5865F2,
            0xF5652A, 0xE4392F, 0x31C27C, 0x1EA7FD, 0xFF5A00, 0x1DB954, 0xC77B00, 0xFF7A00, 0xC77B00,
            0x1B2838, 0x2A2A2A, 0x4EA4DC, 0x148EFF, 0xD32936, 0x0070D1, 0x00A88E,
            0x10A37F, 0xD97757, 0x4D6BFE, 0x4285F4, 0x6E56CF, 0x24292E, 0x3C3C43,
            0xFF5000, 0xE1251B, 0xE02E24, 0xFFB000, 0x0085FF, 0xFFAA00, 0x2577E3, 0x34C759, 0x1F7FE0,
            0xFF7C1F, 0xFF7C1F,
            0xCF0A2C, 0xFF6900, 0x00A54F, 0x1FA84C, 0x415FFF, 0x00A0E9, 0x0F5FA6, 0x6E56CF, 0xE8453C,
            0x00B3A6, 0x12B886, 0x0055A5,
            0x8E8E93, 0x0078D4, 0x4285F4, 0x5AC8FA, 0x8E8E93, 0x2932E1, 0x4361EE, 0x1EA7FD, 0xDD001B,
            0xFF9F0A, 0xFF3B30, 0x8E8E93, 0x5E5CE6,
            0xFF375F, 0x34C759, 0xAF52DE, 0xFF9500, 0x5856D6, 0x0A84FF, 0x3C3C43, 0xFF9F0A, 0x30B0C7,
            0x00A87E, 0x8E8E93, 0x5AC8FA, 0x64748B, 0x8E8E93,
    };

    private static final int FALLBACK = 0x8E8E93;

    /**
     * KEYS 里「按名称匹配」的部分到此为止，之后是纯分类名。
     * 分开的原因：分类名里有 "AI" 这种两字母词，拿去做 contains 会把 baidu.com
     * （b-**ai**-du）染成 AI 蓝，只能按分类精确等于来匹配。
     */
    private static final int NAME_KEYS = 86;

    private AppIcon() {
    }

    /**
     * 造一个图标。有官方图标就直接用，没有才退回自绘。
     * 返回 View 而不是 TextView——两者都要能塞进列表里。
     */
    public static View make(Context c, String name, String category, int sizeDp) {
        int s = Ui.dp(c, sizeDp);
        int res = AppIcons.res(name);
        if (res != 0) {
            ImageView iv = new ImageView(c);
            iv.setImageResource(res);
            iv.setScaleType(ImageView.ScaleType.FIT_CENTER);
            iv.setLayoutParams(new LinearLayout.LayoutParams(s, s));
            return iv;
        }
        return tile(c, name, category, sizeDp);
    }

    private static TextView tile(Context c, String name, String category, int sizeDp) {
        TextView v = new TextView(c);
        String g = glyph(name);
        v.setText(g);
        int bg = brand(name, category);
        v.setTextColor(luminance(bg) > 0.74f ? 0xFF1C1C1E : 0xFFFFFFFF);
        // 两个字符（A编、PV）要小一号，否则会顶到圆角边上
        if (g.length() > 1) {
            v.setTextSize(sizeDp >= 52 ? 16f : 14f);
        } else {
            v.setTextSize(sizeDp >= 52 ? 19f : 16f);
        }
        v.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        v.setGravity(Gravity.CENTER);
        v.setIncludeFontPadding(false);
        v.setSingleLine(true);

        // 左上→右下略微提亮，平色块看起来太"贴纸"，渐变像真图标
        GradientDrawable bgDrawable = new GradientDrawable(
                GradientDrawable.Orientation.TL_BR,
                new int[]{mix(bg, 0xFFFFFF, 0.18f), bg});
        // iOS 那种超椭圆差不多是边长的 28%
        bgDrawable.setCornerRadius(Ui.dp(c, sizeDp * 0.28f));
        v.setBackground(bgDrawable);

        int s = Ui.dp(c, sizeDp);
        v.setLayoutParams(new LinearLayout.LayoutParams(s, s));
        return v;
    }

    public static int brand(String name, String category) {
        // 大小写不敏感：账本里会出现 apple.com、Apple 服务两种写法，都该落到同一色
        String n = name == null ? "" : name.toLowerCase(java.util.Locale.ROOT);
        int limit = Math.min(NAME_KEYS, Math.min(KEYS.length, COLORS.length));
        for (int i = 0; i < limit; i++) {
            if (n.contains(KEYS[i].toLowerCase(java.util.Locale.ROOT))) {
                return COLORS[i];
            }
        }
        String cat = category == null ? "" : category;
        for (int i = 0; i < KEYS.length && i < COLORS.length; i++) {
            if (KEYS[i].equals(cat)) {
                return COLORS[i];
            }
        }
        return FALLBACK;
    }

    /**
     * 图标里的字：中文取首字（「小米 / 米家」→「小」），
     * 英文取前两个单词首字母（「Prime Video」→「PV」），纯数字取前两位（「12306」→「12」）。
     */
    public static String glyph(String name) {
        if (name == null || name.isEmpty()) {
            return "?";
        }
        char c0 = name.charAt(0);
        if (c0 >= '0' && c0 <= '9') {
            return name.length() > 1 ? name.substring(0, 2) : String.valueOf(c0);
        }
        if (c0 > 0x2E80) {          // CJK：一个汉字足够认
            return String.valueOf(c0);
        }
        String[] parts = name.trim().split("[\\s/]+");
        if (parts.length >= 2 && !parts[1].isEmpty()) {
            char a = Character.toUpperCase(parts[0].charAt(0));
            char b = Character.toUpperCase(parts[1].charAt(0));
            if (Character.isLetter(a) && Character.isLetter(b)) {
                return new String(new char[]{a, b});
            }
        }
        return String.valueOf(Character.toUpperCase(c0));
    }

    private static float luminance(int color) {
        float r = Color.red(color) / 255f;
        float g = Color.green(color) / 255f;
        float b = Color.blue(color) / 255f;
        return 0.299f * r + 0.587f * g + 0.114f * b;
    }

    private static int mix(int base, int toward, float ratio) {
        int r = Math.round(Color.red(base) * (1 - ratio) + Color.red(toward) * ratio);
        int g = Math.round(Color.green(base) * (1 - ratio) + Color.green(toward) * ratio);
        int b = Math.round(Color.blue(base) * (1 - ratio) + Color.blue(toward) * ratio);
        return Color.rgb(r, g, b);
    }
}
