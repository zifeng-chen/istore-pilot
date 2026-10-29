package com.chaof.istoreos.util;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.graphics.Typeface;
import android.graphics.drawable.BitmapDrawable;
import android.graphics.drawable.Drawable;
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
            // 抓来的图全是 144x144 的**方图**（圆角是 App Store 客户端自己加的），
            // 直接贴就是方的，跟旁边的字母块不是一套形状
            RoundIconView iv = new RoundIconView(c, ROUND_RATIO);
            iv.setImageResource(res);
            iv.setScaleType(ImageView.ScaleType.FIT_CENTER);
            iv.setLayoutParams(new LinearLayout.LayoutParams(s, s));

            if (iv.isWhiteBg()) {
                // 「白底 + 内缩 logo」这一类（番茄小说、百度、QQ 音乐…），图案常常
                // 一直铺到某几条边。按 24% 裁圆角时，角上那圈会啃到图案，把它的
                // 圆角切成斜边（看着像八角形）。先把图缩进 8%，让圆角只吃背景
                int pad = Math.round(s * 0.08f);
                iv.setPadding(pad, pad, pad, pad);
            }
            return iv;
        }
        return tile(c, name, category, sizeDp);
    }

    /**
     * 图标圆角占边长的比例。iOS 的图标是超椭圆，等效圆角约 22%；这里取 24%，
     * 字母块和图片图标共用同一个值，摆在一起才是一套形状
     */
    private static final float ROUND_RATIO = 0.24f;

    /**
     * 强制圆角的图标 View。
     *
     * 不用 `setClipToOutline` + `ViewOutlineProvider`：那套依赖 RenderNode 的轮廓裁剪，
     * 个别机型/图层（软件层、被父容器强制 layer）下会静默失效，图标又变回方的。
     * 直接在 canvas 上裁路径没有这些前提 —— 拿到多大画多大，四个角一定是圆的。
     */
    private static final class RoundIconView extends ImageView {

        private final float ratio;
        private final Path path = new Path();
        private final RectF rect = new RectF();
        private final Paint stroke = new Paint(Paint.ANTI_ALIAS_FLAG);
        /** 四角是不是白的。null = 还没判断过 */
        private Boolean whiteBg;

        RoundIconView(Context c, float ratio) {
            super(c);
            this.ratio = ratio;
            setWillNotDraw(false);
            stroke.setStyle(Paint.Style.STROKE);
            // 7% 黑：在白底上是一道很淡的灰线，刚好勾出圆角；彩色图标上几乎看不见
            stroke.setColor(0x12000000);
        }

        /**
         * 图标是不是「白底 + 内缩 logo」。
         *
         * 不能只看四角：番茄小说的橙色番茄一直铺到**底部两角**，四角判断会漏掉它。
         * 改为看顶部一整行 —— 满铺的图标（苹果蓝、抖音黑、华为红）上边是清一色的
         * 品牌色，白底图标上边绝大部分是白的。取 12 个采样点，六成以上是白就算。
         */
        boolean isWhiteBg() {
            if (whiteBg != null) {
                return whiteBg;
            }
            whiteBg = false;
            Drawable d = getDrawable();
            if (d instanceof BitmapDrawable) {
                Bitmap b = ((BitmapDrawable) d).getBitmap();
                if (b != null && b.getWidth() > 12 && b.getHeight() > 12) {
                    int w = b.getWidth();
                    int y = Math.max(2, b.getHeight() / 40);
                    int hits = 0;
                    int total = 12;
                    for (int i = 0; i < total; i++) {
                        int x = 4 + i * (w - 8) / (total - 1);
                        int col = b.getPixel(x, y);
                        if (Color.alpha(col) > 200
                                && Color.red(col) > 238
                                && Color.green(col) > 238
                                && Color.blue(col) > 238) {
                            hits++;
                        }
                    }
                    whiteBg = hits >= total * 0.6f;
                }
            }
            return whiteBg;
        }

        @Override
        protected void onDraw(Canvas canvas) {
            int w = getWidth();
            int h = getHeight();
            if (w <= 0 || h <= 0) {
                super.onDraw(canvas);
                return;
            }
            float r = Math.min(w, h) * ratio;
            path.reset();
            rect.set(0, 0, w, h);
            path.addRoundRect(rect, r, r, Path.Direction.CW);
            int save = canvas.save();
            canvas.clipPath(path);
            super.onDraw(canvas);
            canvas.restoreToCount(save);

            // 白底图标和卡片同色，光裁圆角看不出来 —— 补一道内描边把轮廓勾出来。
            // 彩色图标不画：它们自己就有边界，加线反而脏
            if (isWhiteBg()) {
                float sw = Math.max(1f, Math.min(w, h) * 0.008f);
                stroke.setStrokeWidth(sw);
                rect.set(sw / 2f, sw / 2f, w - sw / 2f, h - sw / 2f);
                canvas.drawRoundRect(rect, r, r, stroke);
            }
        }
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
        bgDrawable.setCornerRadius(Ui.dp(c, sizeDp * ROUND_RATIO));
        v.setBackground(bgDrawable);

        int s = Ui.dp(c, sizeDp);
        v.setLayoutParams(new LinearLayout.LayoutParams(s, s));
        return v;
    }

    /**
     * 没有官方图标的品牌，颜色得手动钉死 —— KEYS/COLORS 是按顺序一一对应的，
     * 中间插一条就会整列错位，所以不在那张表里改。
     */
    private static final String[][] BRAND_EXACT = {
            {"华为", "0xFFCF0A2C"}, {"荣耀", "0xFF0A59F7"}, {"X", "0xFF000000"},
            {"支付宝", "0xFF1677FF"}, {"腾讯", "0xFF0052D9"},
    };

    public static int brand(String name, String category) {
        // 大小写不敏感：账本里会出现 apple.com、Apple 服务两种写法，都该落到同一色
        String n = name == null ? "" : name.toLowerCase(java.util.Locale.ROOT);
        for (String[] pair : BRAND_EXACT) {
            if (pair[0].equalsIgnoreCase(name == null ? "" : name.trim())) {
                return (int) Long.parseLong(pair[1].substring(2), 16);
            }
        }
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
    /**
     * 少数名字的首字没有信息量（「AI 编程助手」只取「A」跟「Apple」撞车，
     * 「遥测 / 统计」取「遥」没人看得懂），这里直接给缩写。
     */
    private static final String[][] GLYPH_OVERRIDE = {
            {"AI 编程", "AI"}, {"CDN 加速", "CDN"}, {"广告联盟", "AD"},
            {"应用推送", "推"}, {"遥测", "统计"}, {"IP 直连", "IP"},
            {"开发仓库", "GH"}, {"腾讯", "腾"}, {"未知设备", "?"},
    };

    public static String glyph(String name) {
        if (name == null || name.isEmpty()) {
            return "?";
        }
        for (String[] pair : GLYPH_OVERRIDE) {
            if (name.contains(pair[0])) {
                return pair[1];
            }
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
