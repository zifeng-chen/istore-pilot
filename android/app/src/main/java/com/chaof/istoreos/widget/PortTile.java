package com.chaof.istoreos.widget;

import android.content.Context;
import android.content.res.ColorStateList;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.graphics.Shader;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import android.widget.TextView;

import com.chaof.istoreos.R;
import com.chaof.istoreos.util.Fmt;
import com.chaof.istoreos.util.Ui;

/**
 * 一个网口 = 一张小卡：RJ45 图标 + 速率徽标 + 迷你趋势线 + 实时收发。
 *
 * 为什么不用「每口一行字」：
 * 六行文字谁也记不住自己在看第几个口，而且「哪个口是外网」得逐个读标签。
 * 做成网格之后，WAN 口靠主色描边和角标一眼就能挑出来，
 * 每个口的流量有没有在动看趋势线就够，不用去比两个数字。
 *
 * 趋势线是自己维护的环形缓冲：概览页每 3 秒喂一次，
 * 32 个点 ≈ 1 分半，足够看出「在传东西」还是「闲着」。
 * 画的时候按窗口内最大值归一化 —— 网口平时可能只有几十 K，
 * 用绝对值画会是一条贴着底边的直线，什么都看不出来。
 */
public class PortTile extends LinearLayout {

    private static final int HIST = 32;

    private final Jack jack;
    private final TextView tvName;
    private final TextView tvState;
    private final TextView tvSpeed;
    private final TextView tvDown;
    private final TextView tvUp;
    private final Spark spark;

    private final float[] hist = new float[HIST];
    private int histAt = 0;
    private int histCount = 0;

    private String portName = "";
    private String role = "";
    private boolean up = false;
    private int speedMbps = 0;
    private String mac = "";
    private long rxTotal = 0;
    private long txTotal = 0;

    public PortTile(Context c) {
        super(c);
        setOrientation(VERTICAL);
        int pad = Ui.dp(c, 13);
        setPadding(pad, Ui.dp(c, 11), pad, Ui.dp(c, 12));
        setClickable(true);
        setFocusable(true);

        // ---------------------------------------------------------- 第一行：图标 + 速率
        LinearLayout head = Ui.row(c);

        jack = new Jack(c);
        head.addView(jack, new LinearLayout.LayoutParams(
                Ui.dp(c, 26), Ui.dp(c, 20)));

        head.addView(new View(c), new LinearLayout.LayoutParams(0, 1, 1f));

        tvSpeed = Ui.text(c, "—", 11f, R.color.text_secondary);
        tvSpeed.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        tvSpeed.setGravity(Gravity.CENTER);
        tvSpeed.setSingleLine(true);
        tvSpeed.setPadding(Ui.dp(c, 7), Ui.dp(c, 3), Ui.dp(c, 8), Ui.dp(c, 3));
        head.addView(tvSpeed);
        addView(head);

        // ---------------------------------------------------------- 名称
        tvName = Ui.text(c, "—", 15.5f, R.color.text_primary);
        tvName.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        tvName.setIncludeFontPadding(false);
        tvName.setSingleLine(true);
        tvName.setEllipsize(android.text.TextUtils.TruncateAt.END);
        LinearLayout.LayoutParams nlp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        nlp.topMargin = Ui.dp(c, 9);
        addView(tvName, nlp);

        tvState = Ui.text(c, "—", 11.5f, R.color.text_secondary);
        tvState.setSingleLine(true);
        tvState.setEllipsize(android.text.TextUtils.TruncateAt.END);
        LinearLayout.LayoutParams slp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        slp.topMargin = Ui.dp(c, 3);
        addView(tvState, slp);

        // ---------------------------------------------------------- 趋势线
        spark = new Spark(c);
        LinearLayout.LayoutParams klp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, Ui.dp(c, 26));
        klp.topMargin = Ui.dp(c, 9);
        addView(spark, klp);

        // ---------------------------------------------------------- 实时收发
        LinearLayout rates = Ui.row(c);
        LinearLayout.LayoutParams rlp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        rlp.topMargin = Ui.dp(c, 7);
        rates.setLayoutParams(rlp);

        tvDown = Ui.num(c, "—", 12f, R.color.primary);
        rates.addView(tvDown, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        tvUp = Ui.num(c, "—", 12f, R.color.warn);
        tvUp.setGravity(Gravity.END);
        rates.addView(tvUp);
        addView(rates);

        paint();
    }

    // ---------------------------------------------------------------- 数据

    /**
     * 每次刷新调用。字段没变时也会更新趋势线，所以这里不做「跳过」优化。
     */
    public void set(String name, String role, boolean up, int speedMbps,
                    double rxBps, double txBps, long rxTotal, long txTotal, String mac) {
        this.portName = name == null ? "" : name;
        this.role = role == null ? "" : role;
        this.up = up;
        this.speedMbps = speedMbps;
        this.rxTotal = rxTotal;
        this.txTotal = txTotal;
        this.mac = mac == null ? "" : mac;

        double total = Math.max(0, rxBps) + Math.max(0, txBps);
        push((float) total);

        tvName.setText(this.portName);
        tvSpeed.setText(up ? Fmt.speed(speedMbps) : "—");
        tvState.setText(stateText());

        if (up) {
            // 速率小到没有意义时不要显示「0 B/s」，那看着像坏了
            tvDown.setText("↓ " + shortRate(rxBps));
            tvUp.setText("↑ " + shortRate(txBps));
        } else {
            tvDown.setText("↓ —");
            tvUp.setText("↑ —");
        }

        spark.setColor(Ui.color(getContext(), up ? R.color.primary : R.color.text_tertiary));
        spark.setActive(up && total > 1);
        jack.set(up, role);
        paint();
    }

    /** 网口详情用的原始值，点击时弹层展示 */
    public String detailText() {
        Context c = getContext();
        return "接口　" + orDash(portName) + "\n"
                + "角色　" + ("wan".equals(role) ? "WAN（外网）"
                : "lan".equals(role) ? "LAN（内网）" : "未分配") + "\n"
                + "状态　" + (up ? "已连接 · " + Fmt.speed(speedMbps) : "未连接") + "\n"
                + "MAC　" + orDash(mac) + "\n"
                + "累计接收　" + Fmt.bytes(rxTotal) + "\n"
                + "累计发送　" + Fmt.bytes(txTotal);
    }

    public String portName() {
        return portName;
    }

    private String stateText() {
        if (!up) {
            return "未连接";
        }
        String link = "已连接";
        if ("wan".equals(role)) {
            return "WAN · " + link;
        }
        if ("lan".equals(role)) {
            return "LAN · " + link;
        }
        return link;
    }

    private static String orDash(String v) {
        return v == null || v.isEmpty() ? "—" : v;
    }

    /** 趋势线里用的短数字：12.3M / 380K */
    private static String shortRate(double bps) {
        if (bps < 1) {
            return "0";
        }
        return Fmt.bpsAxis((float) Math.max(0, bps));
    }

    private void push(float v) {
        hist[histAt] = v;
        histAt = (histAt + 1) % HIST;
        if (histCount < HIST) {
            histCount++;
        }
        spark.invalidate();
    }

    // ---------------------------------------------------------------- 外观

    private void paint() {
        Context c = getContext();
        boolean wan = "wan".equals(role);

        GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(Ui.dp(c, 16));
        bg.setColor(Ui.color(c, up ? R.color.surface_hi : R.color.surface_sunken));
        int stroke = up
                ? Ui.alpha(Ui.color(c, wan ? R.color.primary : R.color.primary_dim),
                wan ? 0.55f : 0.26f)
                : Ui.color(c, R.color.glass_stroke);
        bg.setStroke(Math.max(1, Ui.dp(c, wan && up ? 1.1f : 0.7f)), stroke);
        setBackground(new RippleDrawable(
                ColorStateList.valueOf(Ui.color(c, R.color.ripple)), bg, bg));

        tvName.setTextColor(Ui.color(c, up ? R.color.text_primary : R.color.text_secondary));
        tvDown.setTextColor(Ui.color(c, up ? R.color.primary : R.color.text_tertiary));
        tvUp.setTextColor(Ui.color(c, up ? R.color.warn : R.color.text_tertiary));

        // 速率徽标：左边一个小圆点当链路灯，连着亮绿、断了灰
        GradientDrawable badge = new GradientDrawable();
        badge.setCornerRadius(Ui.dp(c, 100));
        badge.setColor(Ui.color(c, up ? R.color.accent_soft : R.color.surface_sunken));
        tvSpeed.setBackground(badge);
        tvSpeed.setTextColor(Ui.color(c, up ? R.color.primary : R.color.text_tertiary));

        GradientDrawable led = new GradientDrawable();
        led.setShape(GradientDrawable.OVAL);
        led.setColor(Ui.color(c, up ? R.color.ok : R.color.text_tertiary));
        int d = Ui.dp(c, 5);
        led.setSize(d, d);
        tvSpeed.setCompoundDrawablesRelativeWithIntrinsicBounds(led, null, null, null);
        tvSpeed.setCompoundDrawablePadding(Ui.dp(c, 4));
    }

    // ================================================================ 图标

    /**
     * RJ45 图标。全部现画，不引 vector：
     * 断线状态下要跟连线状态换配色，用 drawable 反而要写两套。
     *
     * 造型是「插座 + 内侧五个触点」—— 比画一个真实的网口按钮在 26dp 下更清楚，
     * 因为真实的网口下半部是空的，缩到 20dp 高就只剩一个黑块。
     */
    private static final class Jack extends View {
        private final Paint pen = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final RectF body = new RectF();
        private final Path path = new Path();
        private boolean up = false;
        private boolean wan = false;

        Jack(Context c) {
            super(c);
            pen.setStyle(Paint.Style.STROKE);
            fill.setStyle(Paint.Style.FILL);
        }

        void set(boolean up, String role) {
            this.up = up;
            this.wan = "wan".equals(role);
            invalidate();
        }

        @Override
        protected void onDraw(Canvas canvas) {
            Context c = getContext();
            float w = getWidth();
            float h = getHeight();
            if (w <= 0 || h <= 0) {
                return;
            }
            float sw = Math.max(2f, Ui.dp(c, 1.5f));
            int tone = Ui.color(c, up ? R.color.primary : R.color.text_tertiary);

            // 外壳：先填一层很淡的色再描边。
            // 之前是「描边 + 外发光」，缩到 20dp 高时发光会把轮廓糊成一圈，
            // 整体看着像个包袋 —— 填充比发光更能立住「插座」这个形状。
            float top = h * 0.26f;
            body.set(sw, top, w - sw, h - sw * 0.55f);
            float r = Ui.dp(c, 3.4f);
            fill.setColor(Ui.alpha(tone, up ? (wan ? 0.20f : 0.13f) : 0.07f));
            canvas.drawRoundRect(body, r, r, fill);

            pen.setStrokeWidth(sw);
            pen.setColor(tone);
            canvas.drawRoundRect(body, r, r, pen);

            // 卡扣：下宽上窄的梯形，从顶边向上凸出。
            // 这是「网口」区别于「盒子」的唯一特征，宽度必须够、必须居中。
            float bw = w * 0.42f;
            float tw = w * 0.30f;
            float tabH = h * 0.20f;
            path.reset();
            path.moveTo(w / 2 - bw / 2, top + sw * 0.4f);
            path.lineTo(w / 2 - tw / 2, tabH);
            path.lineTo(w / 2 + tw / 2, tabH);
            path.lineTo(w / 2 + bw / 2, top + sw * 0.4f);
            canvas.drawPath(path, pen);

            // 内侧五个触点
            float inset = sw * 2.1f;
            float y1 = top + inset * 1.5f;
            float y2 = h - sw * 1.7f;
            pen.setStrokeWidth(Math.max(1.5f, sw * 0.7f));
            pen.setColor(Ui.alpha(tone, up ? 0.9f : 0.5f));
            for (int i = 0; i < 5; i++) {
                float x = inset + (w - inset * 2) * (i / 4f);
                canvas.drawLine(x, y1, x, y2, pen);
            }
        }
    }

    // ================================================================ 迷你趋势线

    /**
     * 面积图的迷你版。
     * 断线或没流量时画一条贴底的静默线，不要留空 —— 空着会让人以为是没加载出来。
     */
    private final class Spark extends View {
        private final Paint line = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Paint area = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Path path = new Path();
        private final Path fillPath = new Path();
        private int tint = Color.GRAY;
        private boolean active = false;

        Spark(Context c) {
            super(c);
            line.setStyle(Paint.Style.STROKE);
            line.setStrokeWidth(Math.max(2f, Ui.dp(c, 1.4f)));
            line.setStrokeCap(Paint.Cap.ROUND);
            line.setStrokeJoin(Paint.Join.ROUND);
            area.setStyle(Paint.Style.FILL);
        }

        void setColor(int color) {
            if (tint != color) {
                tint = color;
                line.setColor(color);
                invalidate();
            }
        }

        void setActive(boolean on) {
            if (active != on) {
                active = on;
                invalidate();
            }
        }

        @Override
        protected void onDraw(Canvas canvas) {
            float w = getWidth();
            float h = getHeight();
            if (w <= 0 || h <= 0) {
                return;
            }
            float pad = line.getStrokeWidth() / 2f + 1f;

            if (histCount < 2) {
                // 只有一个点的时候画一条平线，代表「刚开始采」
                line.setColor(Ui.alpha(tint, 0.35f));
                canvas.drawLine(pad, h - pad, w - pad, h - pad, line);
                return;
            }

            float max = 1f;
            for (int i = 0; i < histCount; i++) {
                max = Math.max(max, hist[i]);
            }

            // 从最老的一个点开始画：环形缓冲的读起点是 histAt - histCount
            path.reset();
            fillPath.reset();
            float stepX = (w - pad * 2) / (HIST - 1);
            int start = (histAt - histCount + HIST * 2) % HIST;
            float baseY = h - pad;
            float firstX = 0;

            for (int i = 0; i < histCount; i++) {
                int idx = (start + i) % HIST;
                // 窗口没填满时把曲线右对齐贴到最新的一侧，
                // 否则刚打开 App 那几秒线会只画在左边一小段
                int slot = HIST - histCount + i;
                float x = pad + slot * stepX;
                float v = hist[idx] / max;
                // 对数压缩：网口流量跨度大（几 K 到 2.5G），线性画小流量全是平的
                float shaped = (float) (Math.log1p(v * 24) / Math.log(25));
                float y = baseY - shaped * (h - pad * 2);
                if (i == 0) {
                    firstX = x;
                    path.moveTo(x, y);
                } else {
                    path.lineTo(x, y);
                }
            }

            fillPath.addPath(path);
            fillPath.lineTo(pad + (HIST - 1) * stepX, baseY);
            fillPath.lineTo(firstX, baseY);
            fillPath.close();

            area.setShader(new LinearGradient(0, pad, 0, baseY,
                    Ui.alpha(tint, active ? 0.30f : 0.12f),
                    Ui.alpha(tint, 0f), Shader.TileMode.CLAMP));
            canvas.drawPath(fillPath, area);

            line.setColor(Ui.alpha(tint, active ? 1f : 0.55f));
            canvas.drawPath(path, line);
        }
    }
}
