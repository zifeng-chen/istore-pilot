package com.chaof.istoreos.widget;

import android.content.Context;
import android.content.res.ColorStateList;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

import androidx.core.content.ContextCompat;

import com.chaof.istoreos.R;
import com.chaof.istoreos.util.Ui;

/**
 * 悬浮底部标签栏（自绘，不用 BottomNavigationView）。
 *
 * 为什么自己画：
 *  - Material 的 itemActiveIndicator 只能做等宽下划线式胶囊，选中项跟图标宽度绑死，
 *    文字一长胶囊就被撑开，看起来像三个不同尺寸的色块
 *  - 无法在选中时同时改图标描边粗细、文字字重、胶囊缩放
 *  - 图标与文字的间距只能靠 post() 里递归改 padding 这种脏办法
 *
 * 现在的做法：每个标签是「胶囊底 + 图标 + 文字」三层，选中时
 * 胶囊淡入并从 0.86 弹到 1、图标着色成主色、文字换成 medium。
 * 切换只做透明度与缩放动画，不做位移，避免整条栏跟着抖。
 */
public class NavBar extends LinearLayout {

    public interface OnPick {
        void onPick(int index);
    }

    private final String[] titles;
    private final int[] icons;
    private final FrameLayout[] pills;
    private final ImageView[] marks;
    private final TextView[] labels;
    private final FrameLayout[] hits;
    private int selected = 0;

    private final int colorOn;
    private final int colorOff;
    private final int pillColor;

    public NavBar(Context c, String[] titles, int[] icons, int startIndex, OnPick onPick) {
        super(c);
        this.titles = titles;
        this.icons = icons;
        this.selected = Math.max(0, Math.min(startIndex, titles.length - 1));

        colorOn = ContextCompat.getColor(c, R.color.primary);
        // 未选中图标不能复用 text_secondary：
        // 浅色下 #8E8E93 压在 90% 白底上只有 3.22:1，21dp 的小图标直接糊没；
        // 深色下它又是 6.22:1，和选中项的 6.46:1 几乎一样，反而分不出谁被选中。
        // icon_off 是专门给导航算过的一组色：看得清，但明显弱于彩色的选中项。
        colorOff = ContextCompat.getColor(c, R.color.icon_off);
        pillColor = (colorOn & 0x00FFFFFF) | 0x2E000000;

        setOrientation(HORIZONTAL);
        setGravity(Gravity.CENTER_VERTICAL);
        setClipToOutline(false);

        GradientDrawable bg = new GradientDrawable();
        bg.setColor(ContextCompat.getColor(c, R.color.surface_glass));
        bg.setCornerRadius(Ui.dp(c, 26));
        bg.setStroke(Math.max(1, Ui.dp(c, 0.7f)),
                ContextCompat.getColor(c, R.color.glass_stroke));
        setBackground(bg);
        setElevation(Ui.dp(c, 10));

        marks = new ImageView[titles.length];
        labels = new TextView[titles.length];
        pills = new FrameLayout[titles.length];
        hits = new FrameLayout[titles.length];

        for (int i = 0; i < titles.length; i++) {
            addView(buildItem(c, i, onPick), new LinearLayout.LayoutParams(
                    0, ViewGroup.LayoutParams.MATCH_PARENT, 1f));
        }
        apply(false);
    }

    /**
     * 单个标签：上面是 46×28 的胶囊（选中才显形），里面 22dp 图标；下面是文字。
     * 胶囊比图标宽，视觉上像「图标坐在一块软垫上」，这是 iOS 26 标签栏的样子。
     */
    private View buildItem(Context c, int index, OnPick onPick) {
        FrameLayout hit = new FrameLayout(c);
        hit.setClipToOutline(false);
        hits[index] = hit;

        GradientDrawable rippleBg = new GradientDrawable();
        rippleBg.setColor(0x00000000);
        rippleBg.setCornerRadius(Ui.dp(c, 18));
        hit.setBackground(new RippleDrawable(
                ColorStateList.valueOf(ContextCompat.getColor(c, R.color.ripple)),
                null, rippleBg));
        hit.setClickable(true);
        hit.setFocusable(true);
        hit.setOnClickListener(v -> {
            if (selected != index) {
                select(index, true);
                if (onPick != null) {
                    onPick.onPick(index);
                }
            } else if (onPick != null) {
                onPick.onPick(index);
            }
        });

        LinearLayout box = new LinearLayout(c);
        box.setOrientation(VERTICAL);
        box.setGravity(Gravity.CENTER_HORIZONTAL);
        FrameLayout.LayoutParams blp = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        blp.gravity = Gravity.CENTER;
        box.setLayoutParams(blp);
        box.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);

        // 胶囊必须只当「背景层」，不能把图标装进去 ——
        // View.setAlpha() 会连同整棵子树一起变透明，图标装在里面时
        // 未选中（alpha=0）会把图标一起抹掉，只剩文字。
        // 所以这里用一个 pad 容器叠两层：底下是胶囊，上面是图标。
        FrameLayout pad = new FrameLayout(c);
        LinearLayout.LayoutParams plp = new LinearLayout.LayoutParams(
                Ui.dp(c, 46), Ui.dp(c, 28));
        box.addView(pad, plp);

        FrameLayout pill = new FrameLayout(c);
        GradientDrawable pillBg = new GradientDrawable();
        pillBg.setCornerRadius(Ui.dp(c, 14));
        pillBg.setColor(pillColor);
        pill.setBackground(pillBg);
        pill.setAlpha(0f);
        pad.addView(pill, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        pills[index] = pill;

        ImageView icon = new ImageView(c);
        icon.setImageResource(icons[index]);
        icon.setScaleType(ImageView.ScaleType.FIT_CENTER);
        FrameLayout.LayoutParams ilp = new FrameLayout.LayoutParams(
                Ui.dp(c, 21), Ui.dp(c, 21));
        ilp.gravity = Gravity.CENTER;
        pad.addView(icon, ilp);
        marks[index] = icon;

        TextView label = new TextView(c);
        label.setText(titles[index]);
        label.setTextSize(10.5f);
        label.setGravity(Gravity.CENTER);
        label.setIncludeFontPadding(false);
        label.setSingleLine(true);
        label.setLetterSpacing(0.01f);
        LinearLayout.LayoutParams tlp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        tlp.topMargin = Ui.dp(c, 3);
        box.addView(label, tlp);
        labels[index] = label;

        hit.addView(box);
        return hit;
    }

    private void apply(boolean animate) {
        Context c = getContext();
        for (int i = 0; i < titles.length; i++) {
            boolean on = i == selected;
            marks[i].setImageTintList(ColorStateList.valueOf(on ? colorOn : colorOff));
            labels[i].setTextColor(on ? colorOn : colorOff);
            labels[i].setTypeface(Typeface.create(
                    on ? "sans-serif-medium" : "sans-serif", Typeface.NORMAL));
            pills[i].animate().cancel();
            if (animate) {
                if (on) {
                    pills[i].setScaleX(0.86f);
                    pills[i].setScaleY(0.86f);
                    pills[i].animate().alpha(1f).scaleX(1f).scaleY(1f)
                            .setDuration(190).start();
                } else {
                    pills[i].animate().alpha(0f).setDuration(120).start();
                }
            } else {
                pills[i].setAlpha(on ? 1f : 0f);
                pills[i].setScaleX(1f);
                pills[i].setScaleY(1f);
            }
        }
    }

    /** 外部主动切换（比如返回键回到概览），不触发回调 */
    public void select(int index, boolean animate) {
        if (index < 0 || index >= titles.length || index == selected) {
            return;
        }
        selected = index;
        apply(animate);
    }

    public int selected() {
        return selected;
    }
}
