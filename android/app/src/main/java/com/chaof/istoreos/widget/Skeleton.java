package com.chaof.istoreos.widget;

import android.animation.ObjectAnimator;
import android.animation.ValueAnimator;
import android.content.Context;
import android.graphics.drawable.GradientDrawable;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.animation.AccelerateDecelerateInterpolator;
import android.widget.LinearLayout;

import com.chaof.istoreos.R;
import com.chaof.istoreos.util.Ui;

/**
 * 首屏骨架屏。
 *
 * 打开 App 的头几百毫秒原来是一片空白 + 转圈，看起来像卡住了。
 * 骨架屏先画出布局的形状，数据到了再换成真实内容，用户感知从
 * 「等加载」变成「内容正在填进来」。
 *
 * 为什么没用 Shimmer：试过，它给整棵子树套一层 SRC_IN 着色遮罩，
 * 于是「白色卡片 + 灰色文字块」两层结构被染成同一个颜色，形状彻底糊掉 ——
 * 截图里只剩一块均匀的浅灰矩形。而骨架的核心恰恰是形状，
 * 所以改成自绘的「脉冲」：保留真实颜色与层次，只让整体透明度呼吸。
 * 这也是 iOS 与多数大厂 App 的做法，观感比扫光更克制。
 */
public final class Skeleton {

    private Skeleton() {
    }

    /**
     * 通用骨架：主卡 + 图卡 + 三个圆 + 列表组。
     * 各页真实布局不同，但节奏（高块 → 中块 → 短行）一致，
     * 所以一套给所有页面用，不必逐页单独画。
     */
    public static View generic(Context c) {
        Pulse root = new Pulse(c);
        root.setLayoutParams(new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        // 主卡
        root.addView(card(c, 96, new int[]{0, 1, 2}));

        // 图表卡
        root.addView(card(c, 132, new int[]{0, 1}));

        // 三个环
        LinearLayout rings = Ui.row(c);
        LinearLayout.LayoutParams rlp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        rlp.bottomMargin = Ui.dp(c, 12);
        rings.setLayoutParams(rlp);
        for (int i = 0; i < 3; i++) {
            ringBlock(c, rings, i);
        }
        root.addView(rings);

        // 列表组
        root.addView(card(c, 132, new int[]{0, 0, 0}));
        return root;
    }

    /** 停掉脉冲。reveal 前必须调，否则会和淡出动画抢 alpha */
    public static void stop(View skeleton) {
        if (skeleton == null) {
            return;
        }
        Object tag = skeleton.getTag();
        if (tag instanceof ObjectAnimator) {
            ((ObjectAnimator) tag).cancel();
        }
    }

    private static void ringBlock(Context c, LinearLayout parent, int i) {
        LinearLayout holder = Ui.column(c);
        holder.setGravity(Gravity.CENTER_HORIZONTAL);
        int pad = Ui.dp(c, 10);
        holder.setPadding(pad, pad, pad, pad);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
        lp.rightMargin = i < 2 ? Ui.dp(c, 10) : 0;

        View circle = new View(c);
        GradientDrawable bg = new GradientDrawable();
        bg.setShape(GradientDrawable.OVAL);
        bg.setColor(Ui.color(c, R.color.skeleton_base));
        circle.setBackground(bg);
        int d = Ui.dp(c, 78);
        holder.addView(circle, new LinearLayout.LayoutParams(d, d));

        View line = new View(c);
        GradientDrawable lbg = new GradientDrawable();
        lbg.setCornerRadius(Ui.dp(c, 4));
        lbg.setColor(Ui.color(c, R.color.skeleton_base));
        line.setBackground(lbg);
        LinearLayout.LayoutParams llp = new LinearLayout.LayoutParams(
                Ui.dp(c, 40), Ui.dp(c, 9));
        llp.topMargin = Ui.dp(c, 9);
        holder.addView(line, llp);

        parent.addView(holder, lp);
    }

    /** 一张卡片形状的灰块，内部叠几行模拟文字 */
    private static View card(Context c, int heightDp, int[] rows) {
        LinearLayout card = Ui.column(c);
        GradientDrawable bg = new GradientDrawable();
        // 卡片用真实卡片的底色（白）。骨架不画「灰色卡片」——
        // 那样整页会变成一块大灰板，看起来更像报错而不是加载
        bg.setColor(Ui.color(c, R.color.surface));
        bg.setCornerRadius(Ui.dp(c, 22));
        bg.setStroke(Math.max(1, Ui.dp(c, 0.7f)), Ui.color(c, R.color.glass_stroke));
        card.setBackground(bg);
        int pad = Ui.dp(c, 18);
        card.setPadding(pad, pad, pad, pad);

        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, Ui.dp(c, heightDp));
        lp.bottomMargin = Ui.dp(c, 12);
        card.setLayoutParams(lp);

        for (int i = 0; i < rows.length; i++) {
            int h = rows[i] == 0 ? 11 : (rows[i] == 1 ? 15 : 26);
            int w = rows[i] == 0 ? 120 : (rows[i] == 1 ? 180 : 96);
            LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(
                    Ui.dp(c, w), Ui.dp(c, h));
            if (i > 0) {
                blp.topMargin = Ui.dp(c, i == 1 && rows[0] == 2 ? 12 : 9);
            }
            card.addView(block(c, h), blp);
        }
        return card;
    }

    private static View block(Context c, int hDp) {
        View v = new View(c);
        GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(Ui.dp(c, hDp / 2f));
        bg.setColor(Ui.color(c, R.color.skeleton_base));
        v.setBackground(bg);
        return v;
    }

    /** 会呼吸的容器：透明度在 0.42 与 1 之间来回 */
    private static final class Pulse extends LinearLayout {
        private ObjectAnimator anim;

        Pulse(Context c) {
            super(c);
            setOrientation(VERTICAL);
        }

        @Override
        protected void onAttachedToWindow() {
            super.onAttachedToWindow();
            anim = ObjectAnimator.ofFloat(this, View.ALPHA, 0.42f, 1f);
            anim.setDuration(820);
            anim.setRepeatCount(ValueAnimator.INFINITE);
            anim.setRepeatMode(ValueAnimator.REVERSE);
            anim.setInterpolator(new AccelerateDecelerateInterpolator());
            anim.start();
            // 存到 tag 上，外层移除骨架前用它 cancel
            setTag(anim);
        }

        @Override
        protected void onDetachedFromWindow() {
            if (anim != null) {
                anim.cancel();
                anim = null;
            }
            super.onDetachedFromWindow();
        }
    }
}
