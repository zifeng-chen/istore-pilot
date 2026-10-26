package com.chaof.istoreos.util;

import android.app.Activity;
import android.content.Context;
import android.content.res.ColorStateList;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Rect;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.os.Build;
import android.os.IBinder;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.InputMethodManager;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;

import com.chaof.istoreos.R;

/**
 * 界面小工具箱（iOS 27 观感）。
 *
 * 卡片、行、标题全部用代码构建而不是写一堆 XML：
 * 视觉能保证完全一致，改一处圆角/颜色全局生效，也不用为每种组合新建布局文件。
 *
 * iOS 观感的几个关键点，都收在这里：
 *  - 大圆角（22dp）＋ 极细描边，不用阴影分层
 *  - 字重克制：正文用常规体，只有数字和标题用 medium
 *  - 分隔线只在两侧留白之间，不顶到卡片边缘
 *  - 分组标题是小号大写灰字
 */
public final class Ui {

    /** 卡片圆角，改这一处全局生效 */
    private static final float CARD_RADIUS = 22f;

    private Ui() {
    }

    // ---------------------------------------------------------------- 输入法

    /**
     * 点空白处收起键盘。
     *
     * 放在 dispatchTouchEvent 里做，而不是给每个列表/卡片挨个 setOnTouchListener：
     * 一个页面里可点的东西有几十个，逐个挂监听既容易漏，又会跟已有的点击逻辑打架。
     * 这里只在「按下」时判断一次落点是否在输入框外，**不消费事件**，
     * 所以收键盘的同时按钮、开关该响应的照样响应。
     *
     * @return true 表示这次按下顺手收了键盘
     */
    public static boolean tapOutsideDismissKeyboard(Activity a, MotionEvent ev) {
        if (a == null || ev == null || ev.getAction() != MotionEvent.ACTION_DOWN) {
            return false;
        }
        View focus = a.getCurrentFocus();
        if (!(focus instanceof EditText)) {
            return false;
        }
        if (isInside(focus, ev)) {
            return false;
        }
        focus.clearFocus();
        hideKeyboard(a);
        return true;
    }

    /** 弹层版：Dialog 有自己的窗口，currentFocus 要从 Dialog 上取 */
    public static boolean tapOutsideDismissKeyboard(View rootInDialog, View focus, MotionEvent ev) {
        if (ev == null || ev.getAction() != MotionEvent.ACTION_DOWN) {
            return false;
        }
        if (!(focus instanceof EditText) || isInside(focus, ev)) {
            return false;
        }
        focus.clearFocus();
        if (rootInDialog != null) {
            hideKeyboard(rootInDialog);
        }
        return true;
    }

    private static boolean isInside(View v, MotionEvent ev) {
        Rect r = new Rect();
        if (!v.getGlobalVisibleRect(r)) {
            return false;
        }
        int slop = dp(v.getContext(), 8);   // 手指粗，边界放 8dp
        return r.contains((int) ev.getRawX(), (int) ev.getRawY())
                || new Rect(r.left - slop, r.top - slop, r.right + slop, r.bottom + slop)
                .contains((int) ev.getRawX(), (int) ev.getRawY());
    }

    public static void hideKeyboard(Activity a) {
        if (a == null) {
            return;
        }
        View focus = a.getCurrentFocus();
        if (focus != null) {
            hideKeyboard(focus);
            return;
        }
        View decor = a.getWindow() == null ? null : a.getWindow().getDecorView();
        if (decor != null) {
            hideKeyboard(decor);
        }
    }

    public static void hideKeyboard(View any) {
        if (any == null) {
            return;
        }
        IBinder token = any.getWindowToken();
        if (token == null) {
            return;
        }
        InputMethodManager imm =
                (InputMethodManager) any.getContext().getSystemService(Context.INPUT_METHOD_SERVICE);
        if (imm != null) {
            imm.hideSoftInputFromWindow(token, 0);
        }
    }

    public static int dp(Context c, float v) {
        return Math.round(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v,
                c.getResources().getDisplayMetrics()));
    }

    public static int color(Context c, int res) {
        return c.getResources().getColor(res, c.getTheme());
    }

    // ---------------------------------------------------------------- 基础控件

    public static LinearLayout column(Context c) {
        LinearLayout l = new LinearLayout(c);
        l.setOrientation(LinearLayout.VERTICAL);
        return l;
    }

    public static LinearLayout row(Context c) {
        LinearLayout l = new LinearLayout(c);
        l.setOrientation(LinearLayout.HORIZONTAL);
        l.setGravity(Gravity.CENTER_VERTICAL);
        return l;
    }

    public static TextView text(Context c, CharSequence s, float sp, int colorRes) {
        TextView t = new TextView(c);
        t.setText(s);
        t.setTextSize(sp);
        t.setTextColor(color(c, colorRes));
        return t;
    }

    public static TextView value(Context c, CharSequence s) {
        TextView t = text(c, s, 15f, R.color.text_primary);
        t.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        t.setGravity(Gravity.END);
        return t;
    }

    public static TextView label(Context c, CharSequence s) {
        return text(c, s, 13f, R.color.text_secondary);
    }

    public static TextView big(Context c, CharSequence s) {
        TextView t = text(c, s, 28f, R.color.text_primary);
        t.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        t.setIncludeFontPadding(false);
        return t;
    }

    /** iOS 大标题：34sp 半粗，页面顶部随内容滚走 */
    public static TextView largeTitle(Context c, CharSequence s) {
        TextView t = text(c, s, 33f, R.color.text_primary);
        t.setTypeface(Typeface.create("sans-serif", Typeface.BOLD));
        t.setIncludeFontPadding(false);
        t.setLetterSpacing(-0.02f);
        return t;
    }

    /**
     * 小号彩色标签，比如「运行中」「已接管」。
     *
     * 底色以前是文字色的 13%（0x22），灰字配灰底等于什么都没画 ——
     * 「未运行」这种状态在深色下几乎看不出来。现在底提到 19%，
     * 并且强制用文字色自己当底，保证「底和字同色系但一亮一暗」。
     */
    public static TextView pill(Context c, CharSequence s, int colorRes) {
        TextView t = text(c, s, 11.5f, colorRes);
        t.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        t.setPadding(dp(c, 9), dp(c, 4), dp(c, 9), dp(c, 4));
        GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(dp(c, 100));
        int base = color(c, colorRes);
        bg.setColor((base & 0x00FFFFFF) | 0x30000000);
        t.setBackground(bg);
        t.setGravity(Gravity.CENTER);
        return t;
    }

    /** 实心胶囊（主要操作按钮） */
    public static TextView filled(Context c, CharSequence s, int bgRes, int fgRes) {
        TextView t = text(c, s, 15f, fgRes);
        t.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        t.setPadding(dp(c, 16), dp(c, 11), dp(c, 16), dp(c, 11));
        GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(dp(c, 100));
        bg.setColor(color(c, bgRes));
        t.setBackground(bg);
        t.setGravity(Gravity.CENTER);
        return t;
    }

    /** 细进度条，用来表示占比（应用流量、规则命中）。按权重分两段，父容器多宽都能自适应。 */
    public static View bar(Context c, float ratio, int colorRes) {
        int h = dp(c, 5);
        float r = Math.max(0f, Math.min(1f, ratio));

        GradientDrawable track = new GradientDrawable();
        track.setCornerRadius(h);
        track.setColor(color(c, R.color.track));

        LinearLayout wrap = row(c);
        wrap.setBackground(track);
        wrap.setLayoutParams(new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, h));

        GradientDrawable fill = new GradientDrawable();
        fill.setCornerRadius(h);
        fill.setColor(color(c, colorRes));

        View fg = new View(c);
        fg.setBackground(fill);
        LinearLayout.LayoutParams flp = new LinearLayout.LayoutParams(0, h);
        flp.weight = Math.max(0.0001f, r);
        wrap.addView(fg, flp);

        LinearLayout.LayoutParams rest = new LinearLayout.LayoutParams(0, h);
        rest.weight = Math.max(0.0001f, 1f - r);
        wrap.addView(new View(c), rest);
        return wrap;
    }

    /**
     * 渐变进度条。同样按权重分两段，但要额外说明一点：渐变是画在**整条轨道**上的，
     * 所以占比短的条目颜色会偏左端色、长的偏右端。视觉上刚好形成「越长越深」的层次，
     * 比每条都取同一个纯色更像数据图表。
     */
    public static View barGradient(Context c, float ratio, int fromRes, int toRes) {
        int h = dp(c, 6);
        float r = Math.max(0f, Math.min(1f, ratio));

        GradientDrawable track = new GradientDrawable();
        track.setCornerRadius(h);
        track.setColor(color(c, R.color.track));

        LinearLayout wrap = row(c);
        wrap.setBackground(track);
        wrap.setLayoutParams(new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, h));

        GradientDrawable fill = new GradientDrawable();
        fill.setCornerRadius(h);
        fill.setColors(new int[]{color(c, fromRes), color(c, toRes)});
        fill.setGradientType(GradientDrawable.LINEAR_GRADIENT);
        fill.setOrientation(GradientDrawable.Orientation.LEFT_RIGHT);

        View fg = new View(c);
        fg.setBackground(fill);
        LinearLayout.LayoutParams flp = new LinearLayout.LayoutParams(0, h);
        flp.weight = Math.max(0.0001f, r);
        wrap.addView(fg, flp);

        LinearLayout.LayoutParams rest = new LinearLayout.LayoutParams(0, h);
        rest.weight = Math.max(0.0001f, 1f - r);
        wrap.addView(new View(c), rest);
        return wrap;
    }

    /**
     * 数字专用 TextView：medium 字重 + tabular figures。
     * 列表里一列数字如果不等宽，小数点会左右跳，看着很毛躁 —— 这是排版细节里最划算的一条。
     */
    public static TextView num(Context c, CharSequence s, float sp, int colorRes) {
        TextView t = text(c, s, sp, colorRes);
        t.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        t.setIncludeFontPadding(false);
        try {
            t.setFontFeatureSettings("'tnum'");
        } catch (Throwable ignored) {
            // 个别 ROM 的字体不认这个特性，退回默认比例字宽即可
        }
        return t;
    }

    /** 统计块：上面小灰字，下面大数字 */
    public static TextView stat(Context c, LinearLayout parent, String label, String value) {
        LinearLayout box = column(c);
        TextView l = text(c, label, 12f, R.color.text_secondary);
        l.setIncludeFontPadding(false);
        box.addView(l);
        TextView v = text(c, value, 20f, R.color.text_primary);
        v.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        v.setIncludeFontPadding(false);
        v.setPadding(0, dp(c, 5), 0, 0);
        box.addView(v);
        parent.addView(box);
        return v;
    }

    /**
     * 分隔线。iOS 的分隔线不会顶到卡片边缘，左边留出文字起点，
     * 所以这里左右各缩进一点，视觉上像 inset grouped。
     */
    public static View divider(Context c) {
        View v = new View(c);
        v.setBackgroundColor(color(c, R.color.divider));
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, Math.max(1, dp(c, 0.7f)));
        lp.topMargin = dp(c, 10);
        lp.bottomMargin = dp(c, 10);
        lp.leftMargin = dp(c, 2);
        v.setLayoutParams(lp);
        return v;
    }

    /** 贯穿整个卡片宽度的细线（列表行之间用） */
    public static View hairline(Context c) {
        View v = new View(c);
        v.setBackgroundColor(color(c, R.color.divider));
        v.setLayoutParams(new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, Math.max(1, dp(c, 0.7f))));
        return v;
    }

    // ---------------------------------------------------------------- 卡片

    /** 圆角卡片：大圆角 + 极细描边，按下去有淡淡的水波纹 */
    public static class Card extends LinearLayout {
        public Card(Context c) {
            super(c);
            setOrientation(VERTICAL);
            int pad = dp(c, 18);
            setPadding(pad, pad, pad, pad);
            GradientDrawable bg = new GradientDrawable();
            bg.setColor(color(c, R.color.surface));
            bg.setCornerRadius(dp(c, CARD_RADIUS));
            bg.setStroke(Math.max(1, dp(c, 0.7f)), color(c, R.color.glass_stroke));
            setBackground(new RippleDrawable(
                    ColorStateList.valueOf(color(c, R.color.ripple)), bg, bg));
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            lp.bottomMargin = dp(c, 12);
            setLayoutParams(lp);
            setClipToOutline(false);
            // 1.2dp 的极轻投影：卡片从底色上「浮」起来一点点就有了层次感。
            // 千万不能给大，深色主题下投影会变成一圈脏边，比没有还难看
            setElevation(dp(c, 1.2f));
        }

        public Card tap(View.OnClickListener l) {
            setClickable(true);
            setFocusable(true);
            setOnClickListener(l);
            return this;
        }
    }

    public static Card card(Context c) {
        return new Card(c);
    }

    /**
     * 分组容器：一个卡片里装若干 {@link #listRow}，行间用 {@link #hairline} 分隔。
     *
     * 为什么要有这个：55 台设备如果每台一张卡，就是 55 层圆角 + 55 层投影，
     * 滚动时又卡又碎，视觉上也没有「它们属于同一组」的感觉。
     * iOS 的 inset grouped list 就是这个问题的最优解 —— 一组一个容器。
     */
    public static Card group(Context c) {
        Card card = new Card(c);
        card.setPadding(0, dp(c, 2), 0, dp(c, 2));
        return card;
    }

    /** 分组列表里的一行：没有外框，只有点击涟漪（整组共用外层 Card 的底） */
    public static LinearLayout listRow(Context c) {
        LinearLayout row = column(c);
        int px = dp(c, 18);
        int py = dp(c, 12);
        row.setPadding(px, py, px, py);
        GradientDrawable mask = new GradientDrawable();
        mask.setColor(0xFFFFFFFF);
        row.setBackground(new RippleDrawable(
                ColorStateList.valueOf(color(c, R.color.ripple)), null, mask));
        row.setClickable(true);
        row.setFocusable(true);
        return row;
    }

    /** 分组内的细分隔线，左侧缩进对齐文字起点 */
    public static View hairline(Context c, float indentDp) {
        View v = new View(c);
        v.setBackgroundColor(color(c, R.color.divider));
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, Math.max(1, dp(c, 0.7f)));
        lp.leftMargin = dp(c, indentDp);
        v.setLayoutParams(lp);
        return v;
    }

    /** 给颜色加透明度，0..1。压在主色卡片上的次要文字用这个，别写死 0x33FFFFFF */
    public static int alpha(int base, float a) {
        int v = Math.round(Math.max(0f, Math.min(1f, a)) * 255);
        return (base & 0x00FFFFFF) | (v << 24);
    }

    /**
     * 主色渐变卡：页面顶部的「一句话结论」区域用。
     *
     * 颜色走 hero_from / hero_to 而不是 primary：
     * hero 卡在浅色和深色下都必须是「深底浅字」，否则白字压在中亮绿上
     * 只有 3:1 左右，长段说明文字会糊成一片。文字一律用 hero_fg。
     * 深色下再补一圈极淡的绿描边，避免深绿卡和近黑背景黏在一起。
     */
    public static Card gradient(Context c, int fromRes, int toRes) {
        Card card = new Card(c);
        GradientDrawable bg = new GradientDrawable(
                GradientDrawable.Orientation.TL_BR,
                new int[]{color(c, fromRes), color(c, toRes)});
        bg.setCornerRadius(dp(c, CARD_RADIUS));
        bg.setStroke(Math.max(1, dp(c, 0.7f)), color(c, R.color.hero_stroke));
        card.setBackground(bg);
        card.setClickable(false);
        card.setFocusable(false);
        card.setElevation(dp(c, 1.2f));
        return card;
    }

    /** 渐变卡上的标题字（用 hero_fg） */
    public static TextView heroTitle(Context c, CharSequence s) {
        TextView t = text(c, s, 18f, R.color.hero_fg);
        t.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        t.setIncludeFontPadding(false);
        return t;
    }

    /** 渐变卡上的大数字 */
    public static TextView heroNumber(Context c, CharSequence s) {
        TextView t = text(c, s, 36f, R.color.hero_fg);
        t.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        t.setIncludeFontPadding(false);
        t.setLetterSpacing(-0.03f);
        return t;
    }

    /**
     * 渐变卡上的说明字。
     *
     * 以前这里按传入的 alpha 把文字压透明，0.66 实际只剩 2~4:1 ——
     * 12sp 的小字在渐变上基本读不出来。现在 alpha 只用来做「层级感」，
     * 最低不低于 0.82，并直接走已经算好的 hero_fg_soft，不再逐字叠透明。
     */
    public static TextView heroNote(Context c, CharSequence s, float alpha) {
        TextView t = text(c, s, 12f, R.color.hero_fg_soft);
        if (alpha >= 0.9f) {
            t.setTextColor(color(c, R.color.hero_fg));
        }
        t.setIncludeFontPadding(false);
        return t;
    }

    /**
     * 链路节点：左侧圆点 + 竖向连线，右侧「名称 + 详情」。
     * 用来画 DNS 链路、代理链路这类「A 把请求交给 B 再交给 C」的结构，
     * 比三行键值对直观得多。
     *
     * 竖线**在 onDraw 里画**，不另建 View。之前的写法是在横向 LinearLayout 里
     * 放一个 MATCH_PARENT 高的竖线 View，它得等父高度确定后二次测量，
     * 和右边 weight=1 的文字列撞在一起时文字行被压扁 —— 2.7.0 广告拦截页
     * 就踩了这个坑：标题只有 25px 高，正常 44px，上半截字直接被切掉。
     * 现在线和点都不参与测量，行高完全由文字决定，互相挤不到。
     */
    public static FrameLayout node(Context c, String name, String detail,
                                   int dotColorRes, boolean last) {
        final int railW = dp(c, 24);
        Node line = new Node(c, last, railW / 2);

        // 注意：轨道区域**不能**用 Node 的 paddingLeft 来留。
        // FrameLayout 的子 View 定位是「padding + margin」，padding 和 margin
        // 都算一遍就把圆点推进右侧文字里了（圆点会压在第一个字上）。
        // 所以轨道靠给 body 加 leftMargin 让出来，圆点直接用 margin 定在左边缘。
        View dot = new View(c);
        GradientDrawable dbg = new GradientDrawable();
        dbg.setShape(GradientDrawable.OVAL);
        dbg.setColor(color(c, dotColorRes));
        dot.setBackground(dbg);
        dot.setTag("dot");
        int ds = dp(c, 9);
        FrameLayout.LayoutParams dlp = new FrameLayout.LayoutParams(ds, ds);
        dlp.gravity = Gravity.TOP | Gravity.START;
        dlp.leftMargin = railW / 2 - ds / 2;
        dlp.topMargin = dp(c, 4);
        line.addView(dot, dlp);

        LinearLayout body = column(c);
        FrameLayout.LayoutParams blp = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        blp.leftMargin = railW;
        blp.bottomMargin = last ? 0 : dp(c, 16);
        body.setLayoutParams(blp);
        line.addView(body);

        TextView t = text(c, name, 14.5f, R.color.text_primary);
        t.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        t.setIncludeFontPadding(false);
        body.addView(t);

        if (detail != null && !detail.isEmpty()) {
            TextView d = text(c, detail, 12.5f, R.color.text_secondary);
            d.setPadding(0, dp(c, 4), 0, 0);
            d.setLineSpacing(dp(c, 2), 1f);
            body.addView(d);
            // 调用方拿这个 TextView 就地改文案：((TextView) node.getTag()).setText(...)
            line.setTag(d);
        }
        return line;
    }

    /**
     * 链路节点本体：只负责把「从圆点底部到底边」的那截竖线画出来。
     *
     * 竖线不占测量空间，所以行高永远是文字的高度；它在 onDraw 里按
     * getHeight() 现算，文字换行变高时线也跟着变长，不需要任何手动同步。
     */
    private static final class Node extends FrameLayout {
        private final Paint line = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final boolean last;
        private final int railX;
        private final int lineTop;

        Node(Context c, boolean last, int railX) {
            super(c);
            this.last = last;
            this.railX = railX;
            // ViewGroup 默认不回调 onDraw（没有背景时），必须显式打开
            setWillNotDraw(false);
            line.setStrokeWidth(Math.max(2, dp(c, 1.2f)));
            line.setStrokeCap(Paint.Cap.ROUND);
            line.setColor(color(c, R.color.divider));
            // 从圆点下方 3dp 起笔，避免压到圆点
            lineTop = dp(c, 4) + dp(c, 9) + dp(c, 3);
        }

        @Override
        protected void onDraw(Canvas canvas) {
            super.onDraw(canvas);
            if (last) {
                return;
            }
            canvas.drawLine(railX, lineTop, railX, getHeight(), line);
        }
    }

    /** 分组标题，卡片外面用 */
    public static TextView section(Context c, String title) {
        TextView t = text(c, title, 12.5f, R.color.text_secondary);
        t.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        t.setLetterSpacing(0.05f);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.leftMargin = dp(c, 6);
        lp.bottomMargin = dp(c, 7);
        lp.topMargin = dp(c, 2);
        t.setLayoutParams(lp);
        return t;
    }

    // ---------------------------------------------------------------- 键值行

    /**
     * 往卡片里加一行「左侧标签 + 右侧数值」。
     *
     * 值的宽度必须靠 weight=1 吃掉剩余空间，不能是 WRAP_CONTENT：
     * WRAP_CONTENT 时 LinearLayout 先按内容把值测到它想要的宽度，
     * 再让标签去分剩下的，遇到 IPv6（39 个字符）这种长值，
     * 值会直接顶穿卡片右边距被裁掉。用 weight 之后长值在剩余宽度内换行。
     *
     * 另外要关掉 hyphenation 并把断行策略调成 SIMPLE：
     * IPv6 / MAC 这种整串没有空格，HIGH_QUALITY 找不到断点时会拒绝换行。
     */
    public static TextView kv(LinearLayout card, String key, String val) {
        Context c = card.getContext();
        LinearLayout line = row(c);
        LinearLayout.LayoutParams lineLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lineLp.topMargin = dp(c, 8);
        line.setLayoutParams(lineLp);

        TextView k = text(c, key, 15f, R.color.text_secondary);
        k.setSingleLine(true);
        line.addView(k, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        TextView v = value(c, val);
        v.setPadding(dp(c, 12), 0, 0, 0);
        v.setSingleLine(false);
        v.setMaxLines(3);
        if (Build.VERSION.SDK_INT >= 23) {
            v.setBreakStrategy(android.text.Layout.BREAK_STRATEGY_SIMPLE);
            v.setHyphenationFrequency(android.text.Layout.HYPHENATION_FREQUENCY_NONE);
        }
        line.addView(v, new LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        card.addView(line);
        return v;
    }

    /**
     * 可点击的键值行，尾部带一个 › 箭头，用于「点进去选」的项。
     * 返回右侧的值 TextView，方便调用方自己刷新显示。
     */
    public static TextView kvClick(LinearLayout card, String key, String val,
                                   Runnable onClick) {
        Context c = card.getContext();
        card.addView(hairline(c));
        LinearLayout line = row(c);
        int pad = dp(c, 12);
        line.setPadding(0, pad, 0, pad);
        line.setClickable(true);
        line.setFocusable(true);
        line.setOnClickListener(v -> onClick.run());

        TextView k = text(c, key, 15f, R.color.text_primary);
        line.addView(k, new LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        TextView v = value(c, val);
        v.setPadding(dp(c, 12), 0, 0, 0);
        line.addView(v, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        TextView arrow = text(c, "\u203A", 17f, R.color.text_tertiary);
        arrow.setPadding(dp(c, 8), 0, 0, 0);
        line.addView(arrow);
        card.addView(line);
        return v;
    }

    /** 卡片顶部的标题行，返回右侧容器方便塞状态标签 */
    public static LinearLayout header(LinearLayout card, String title, String sub) {
        Context c = card.getContext();
        LinearLayout line = row(c);
        LinearLayout left = column(c);

        TextView t = text(c, title, 16.5f, R.color.text_primary);
        t.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        t.setIncludeFontPadding(false);
        left.addView(t);

        if (sub != null && !sub.isEmpty()) {
            TextView s = text(c, sub, 12.5f, R.color.text_secondary);
            s.setPadding(0, dp(c, 4), 0, 0);
            left.addView(s);
        }
        line.addView(left, new LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        LinearLayout right = row(c);
        line.addView(right);
        card.addView(line);
        return right;
    }

    public static void space(Context c, LinearLayout parent, int heightDp) {
        View v = new View(c);
        v.setLayoutParams(new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(c, heightDp)));
        parent.addView(v);
    }

    // ---------------------------------------------------------------- 表单行

    /**
     * 卡片里的一行输入：左边标签固定宽度，右边输入框右对齐。
     * 返回 EditText 供调用方取值 / 设置键盘类型。
     *
     * 用右对齐是因为「标签 : 值」的对齐关系和只读行一致，
     * 表单行和展示行混在同一张卡里时不会跳版。
     */
    public static android.widget.EditText inputRow(LinearLayout card, String key,
                                                   String value, String hint, boolean secret) {
        Context c = card.getContext();
        card.addView(hairline(c));
        LinearLayout line = row(c);
        line.setPadding(0, dp(c, 6), 0, dp(c, 6));
        line.setMinimumHeight(dp(c, 48));

        TextView k = text(c, key, 15f, R.color.text_primary);
        line.addView(k, new LinearLayout.LayoutParams(
                dp(c, 92), ViewGroup.LayoutParams.WRAP_CONTENT));

        android.widget.EditText e = new android.widget.EditText(c);
        e.setText(value == null ? "" : value);
        e.setHint(hint == null ? "" : hint);
        e.setTextSize(15f);
        e.setTextColor(color(c, R.color.text_primary));
        e.setHintTextColor(color(c, R.color.text_tertiary));
        e.setGravity(Gravity.END | Gravity.CENTER_VERTICAL);
        e.setSingleLine(true);
        e.setIncludeFontPadding(false);
        e.setBackground(null);
        e.setPadding(0, dp(c, 10), 0, dp(c, 10));
        if (secret) {
            e.setInputType(android.text.InputType.TYPE_CLASS_TEXT
                    | android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD);
            e.setTransformationMethod(
                    android.text.method.PasswordTransformationMethod.getInstance());
        }
        line.addView(e, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        card.addView(line);
        return e;
    }

    /** 只读行，但值用强调色（比如「当前 IP」），用于状态卡 */
    public static TextView kvAccent(LinearLayout card, String key, String val, int colorRes) {
        TextView v = kv(card, key, val);
        v.setTextColor(color(card.getContext(), colorRes));
        return v;
    }

    // ---------------------------------------------------------------- 图标行

    /**
     * 设置/列表里带图标的一行：左侧圆角小方块图标 + 标题 + 说明 + 右侧值 + 箭头。
     *
     * 为什么不再用「一行纯文字 + divider」：
     * 设置页有二十多行，全是同样粗细同样颜色的字，扫视时找不到入口，
     * 只能逐行读。图标给每一行一个锚点，说明文字承担「这行到底做什么」，
     * 右侧值承担「现在是什么」，三种信息各归其位，不用挤在一行里。
     *
     * @param first    组内第一行不画分隔线
     * @param danger   危险操作用红色图标和红字
     * @param onClick  为 null 时不带箭头、不可点
     * @return 右侧值那个 TextView，调用方可以就地改文案
     */
    public static TextView settingRow(Context c, LinearLayout card, int glyph,
                                      String title, String subtitle, String value,
                                      boolean first, boolean danger, Runnable onClick) {
        if (!first) {
            // 分隔线起点对齐标题文字，图标区域留空 —— 和 iOS inset grouped 一致
            card.addView(hairline(c, 60));
        }
        int tintRes = danger ? R.color.danger : R.color.text_primary;
        LinearLayout row = row(c);
        int px = dp(c, 16);
        row.setPadding(px, dp(c, 11), px, dp(c, 11));

        // 图标底：主色淡底（危险操作用红色淡底），图标本身用主色
        com.chaof.istoreos.widget.Glyph g = new com.chaof.istoreos.widget.Glyph(c);
        g.setKind(glyph);
        g.setColor(color(c, danger ? R.color.danger : R.color.primary));
        int box = dp(c, 32);
        GradientDrawable tile = new GradientDrawable();
        tile.setCornerRadius(dp(c, 10));
        int base = color(c, danger ? R.color.danger : R.color.primary);
        tile.setColor((base & 0x00FFFFFF) | 0x1F000000);
        LinearLayout iconWrap = row(c);
        iconWrap.setGravity(Gravity.CENTER);
        iconWrap.setBackground(tile);
        LinearLayout.LayoutParams ilp = new LinearLayout.LayoutParams(box, box);
        ilp.rightMargin = dp(c, 12);
        iconWrap.addView(g, new LinearLayout.LayoutParams(dp(c, 19), dp(c, 19)));
        row.addView(iconWrap, ilp);

        LinearLayout col = column(c);
        TextView t = text(c, title, 15f, tintRes);
        t.setIncludeFontPadding(false);
        t.setSingleLine(true);
        t.setEllipsize(android.text.TextUtils.TruncateAt.END);
        col.addView(t);
        if (subtitle != null && !subtitle.isEmpty()) {
            TextView s = text(c, subtitle, 11.5f, R.color.text_secondary);
            s.setPadding(0, dp(c, 4), 0, 0);
            s.setSingleLine(true);
            s.setEllipsize(android.text.TextUtils.TruncateAt.END);
            col.addView(s);
        }
        row.addView(col, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        TextView v = text(c, value == null ? "" : value, 13.5f, R.color.text_secondary);
        v.setPadding(dp(c, 8), 0, 0, 0);
        v.setSingleLine(true);
        v.setGravity(Gravity.END);
        row.addView(v);

        if (onClick != null) {
            TextView arrow = text(c, "\u203A", 17f, R.color.text_tertiary);
            arrow.setPadding(dp(c, 7), 0, 0, 0);
            row.addView(arrow);
            row.setClickable(true);
            row.setFocusable(true);
            // 整行可点，但涟漪只铺在行上：Card 底是圆角的，行是方的，
            // 所以给行单独套一层透明遮罩，边界靠 clipToOutline 收在卡片里
            GradientDrawable mask = new GradientDrawable();
            mask.setColor(0xFFFFFFFF);
            row.setBackground(new RippleDrawable(
                    ColorStateList.valueOf(color(c, R.color.ripple)), null, mask));
            row.setOnClickListener(x -> onClick.run());
        } else {
            arrowPlaceholder(c, row);
        }
        card.addView(row);
        return v;
    }

    /** 不可点的行也补一个和箭头等宽的占位，保证右侧值能对齐成一条线 */
    private static void arrowPlaceholder(Context c, LinearLayout row) {
        TextView arrow = text(c, "\u203A", 17f, R.color.text_tertiary);
        arrow.setPadding(dp(c, 7), 0, 0, 0);
        arrow.setAlpha(0f);
        row.addView(arrow);
    }

    /**
     * 卡片标题左边的小图标，让每张卡的「身份」也能一眼认出。
     * 自带左右 16dp 内边距（配合 padding 为 0 的卡片使用），返回右侧容器。
     */
    public static LinearLayout cardTitle(Context c, LinearLayout card, int glyph,
                                         String title, String sub) {
        LinearLayout row = row(c);
        row.setPadding(dp(c, 16), 0, dp(c, 16), dp(c, 2));
        com.chaof.istoreos.widget.Glyph g = new com.chaof.istoreos.widget.Glyph(c);
        g.setKind(glyph);
        g.setColor(color(c, R.color.primary));
        LinearLayout iconWrap = row(c);
        iconWrap.setGravity(Gravity.CENTER);
        GradientDrawable tile = new GradientDrawable();
        tile.setCornerRadius(dp(c, 9));
        int base = color(c, R.color.primary);
        tile.setColor((base & 0x00FFFFFF) | 0x1F000000);
        iconWrap.setBackground(tile);
        LinearLayout.LayoutParams ilp = new LinearLayout.LayoutParams(dp(c, 28), dp(c, 28));
        ilp.rightMargin = dp(c, 10);
        iconWrap.addView(g, new LinearLayout.LayoutParams(dp(c, 17), dp(c, 17)));
        row.addView(iconWrap, ilp);

        LinearLayout left = column(c);
        TextView t = text(c, title, 16.5f, R.color.text_primary);
        t.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        t.setIncludeFontPadding(false);
        left.addView(t);
        if (sub != null && !sub.isEmpty()) {
            TextView s = text(c, sub, 12f, R.color.text_secondary);
            s.setPadding(0, dp(c, 4), 0, 0);
            left.addView(s);
        }
        row.addView(left, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        LinearLayout right = row(c);
        row.addView(right);
        card.addView(row);
        return right;
    }

    // ---------------------------------------------------------------- 分段控件

    public interface OnSegment {
        void onPick(int index);
    }

    /**
     * iOS 分段控件：底槽 + 选中项浮起。
     * 返回的容器宽度跟随父布局，每段均分。
     *
     * 槽和滑块用 segment_track / segment_thumb 两个专用色：
     * 浅色是「浅槽 + 白滑块」，深色是「暗槽 + 亮滑块」。
     * 之前两套都图省事用 track + surface，结果深色下滑块比槽还暗，
     * 选中的那块看起来像被按进去的凹坑。
     */
    public static LinearLayout segmented(Context c, String[] items, int selected,
                                         OnSegment onPick) {
        int h = dp(c, 34);
        LinearLayout wrap = row(c);
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(color(c, R.color.segment_track));
        bg.setCornerRadius(dp(c, 10));
        wrap.setBackground(bg);
        wrap.setPadding(dp(c, 3), dp(c, 3), dp(c, 3), dp(c, 3));

        for (int i = 0; i < items.length; i++) {
            boolean on = i == selected;
            TextView t = text(c, items[i], 13.5f,
                    on ? R.color.text_primary : R.color.text_on_track);
            t.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
            t.setGravity(Gravity.CENTER);
            int vp = dp(c, 6);
            t.setPadding(dp(c, 10), vp, dp(c, 10), vp);
            t.setSingleLine(true);

            GradientDrawable item = new GradientDrawable();
            item.setCornerRadius(dp(c, 8));
            if (on) {
                item.setColor(color(c, R.color.segment_thumb));
                item.setStroke(Math.max(1, dp(c, 0.7f)), color(c, R.color.glass_stroke));
                t.setBackground(item);
            } else {
                item.setColor(Color.TRANSPARENT);
                t.setBackground(new RippleDrawable(
                        ColorStateList.valueOf(color(c, R.color.ripple)), item, item));
            }

            final int index = i;
            t.setOnClickListener(v -> {
                if (onPick != null) {
                    onPick.onPick(index);
                }
            });
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, h - dp(c, 6));
            lp.weight = 1f;
            wrap.addView(t, lp);
        }
        return wrap;
    }
}
