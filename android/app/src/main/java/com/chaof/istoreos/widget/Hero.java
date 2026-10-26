package com.chaof.istoreos.widget;

import android.content.Context;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import android.widget.TextView;

import com.chaof.istoreos.R;
import com.chaof.istoreos.util.Ui;

/**
 * 页面顶部的「一句话结论」卡。
 *
 * 五个月前这张卡是每页各写一遍的：概览、网络、设备、代理、设置各有一段
 * 几乎一样的代码（圆点 7dp / 状态 12.5sp / 胶囊 0.16 透明 / 大标题 27sp），
 * 数值稍有出入就会露出「这页好像不太一样」的破绽 —— 改一个数值得翻五个文件。
 * 现在收成一个组件，页面只填四个字符串。
 *
 * 结构固定为四层，顺序不可变：
 *   ● 状态文字 ············· [胶囊：来源/类型]
 *   大标题（身份：主机名 / IP / 配置名）
 *   说明（一句补充，超长省略，永远单行）
 *
 * 圆点有三种态：实心（正常）、空心（未启用）、告警色（异常）。
 * 直接用主色画的圆点在深绿渐变上几乎看不见，所以统一用 hero_fg。
 */
public class Hero extends LinearLayout {

    /** 状态圆点，需要单独改颜色时用 {@link #dot(int, boolean)} */
    public final View dot;
    /** 圆点右侧的状态文字，例如「已拨通」 */
    public final TextView state;
    /** 右上角胶囊，例如「PPPoE 拨号」 */
    public final TextView badge;
    /** 大标题：这一页的身份（IP / 主机名 / 配置名） */
    public final TextView title;
    /** 大标题下面那行说明 */
    public final TextView note;

    public Hero(Context c) {
        super(c);
        setOrientation(VERTICAL);
        setPadding(Ui.dp(c, 20), Ui.dp(c, 18), Ui.dp(c, 20), Ui.dp(c, 18));

        GradientDrawable bg = new GradientDrawable(
                GradientDrawable.Orientation.TL_BR,
                new int[]{Ui.color(c, R.color.hero_from), Ui.color(c, R.color.hero_to)});
        bg.setCornerRadius(Ui.dp(c, 22));
        bg.setStroke(Math.max(1, Ui.dp(c, 0.7f)), Ui.color(c, R.color.hero_stroke));
        setBackground(bg);
        setElevation(Ui.dp(c, 1.2f));
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.bottomMargin = Ui.dp(c, 12);
        setLayoutParams(lp);

        LinearLayout top = Ui.row(c);
        dot = new View(c);
        GradientDrawable d = new GradientDrawable();
        d.setShape(GradientDrawable.OVAL);
        d.setColor(Ui.color(c, R.color.hero_fg));
        dot.setBackground(d);
        LinearLayout.LayoutParams dlp = new LinearLayout.LayoutParams(Ui.dp(c, 7), Ui.dp(c, 7));
        dlp.rightMargin = Ui.dp(c, 7);
        top.addView(dot, dlp);

        state = Ui.heroNote(c, "正在读取…", 1.0f);
        state.setTextSize(12.5f);
        state.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        state.setSingleLine(true);
        state.setEllipsize(TextUtils.TruncateAt.END);
        top.addView(state, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        badge = Ui.heroNote(c, "—", 0.86f);
        badge.setTextSize(11f);
        badge.setPadding(Ui.dp(c, 9), Ui.dp(c, 4), Ui.dp(c, 9), Ui.dp(c, 4));
        GradientDrawable bb = new GradientDrawable();
        bb.setCornerRadius(Ui.dp(c, 100));
        bb.setColor(Ui.alpha(Ui.color(c, R.color.hero_fg), 0.16f));
        badge.setBackground(bb);
        badge.setSingleLine(true);
        top.addView(badge);
        addView(top);

        title = Ui.text(c, "—", 27f, R.color.hero_fg);
        title.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        title.setIncludeFontPadding(false);
        title.setLetterSpacing(-0.02f);
        title.setSingleLine(true);
        title.setEllipsize(TextUtils.TruncateAt.END);
        LinearLayout.LayoutParams tlp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        tlp.topMargin = Ui.dp(c, 12);
        addView(title, tlp);

        note = Ui.heroNote(c, "—", 0.86f);
        note.setTextSize(12f);
        note.setPadding(0, Ui.dp(c, 5), 0, 0);
        note.setSingleLine(true);
        note.setEllipsize(TextUtils.TruncateAt.END);
        addView(note);
    }

    /**
     * 圆点状态。
     *
     * @param colorRes hero_fg / warn / danger，注意别传主色调的 primary ——
     *                 深绿底上绿色圆点等于没画
     * @param hollow   true 画成空心环，用于「未启用」这种「存在但没在跑」
     */
    public void dot(int colorRes, boolean hollow) {
        GradientDrawable d = new GradientDrawable();
        d.setShape(GradientDrawable.OVAL);
        if (hollow) {
            d.setColor(0x00000000);
            d.setStroke(Math.max(1, Ui.dp(getContext(), 1.6f)), Ui.color(getContext(), colorRes));
        } else {
            d.setColor(Ui.color(getContext(), colorRes));
        }
        dot.setBackground(d);
    }

    /** 依次填四段文字，null 表示「保留原样」，空串表示「清空」 */
    public void set(String stateText, String badgeText, String titleText, String noteText) {
        if (stateText != null) {
            state.setText(stateText);
        }
        if (badgeText != null) {
            badge.setText(badgeText);
            badge.setVisibility(badgeText.isEmpty() ? GONE : VISIBLE);
        }
        if (titleText != null) {
            title.setText(titleText);
        }
        if (noteText != null) {
            note.setText(noteText);
        }
    }

    /** 在说明下面加一行「标签 + 数值」的小块，最多三个（三等分，再多就挤了） */
    public TextView[] stats(String... labels) {
        View line = new View(getContext());
        line.setBackgroundColor(Ui.alpha(Ui.color(getContext(), R.color.hero_fg), 0.18f));
        LinearLayout.LayoutParams llp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, Math.max(1, Ui.dp(getContext(), 0.7f)));
        llp.topMargin = Ui.dp(getContext(), 16);
        llp.bottomMargin = Ui.dp(getContext(), 14);
        addView(line, llp);

        LinearLayout row = Ui.row(getContext());
        row.setBaselineAligned(false);
        TextView[] out = new TextView[labels.length];
        for (int i = 0; i < labels.length; i++) {
            LinearLayout box = Ui.column(getContext());
            TextView l = Ui.heroNote(getContext(), labels[i], 0.86f);
            l.setTextSize(11.5f);
            l.setIncludeFontPadding(false);
            l.setSingleLine(true);
            box.addView(l);

            TextView v = Ui.text(getContext(), "—", 20f, R.color.hero_fg);
            v.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
            v.setIncludeFontPadding(false);
            v.setSingleLine(true);
            v.setEllipsize(TextUtils.TruncateAt.END);
            v.setPadding(0, Ui.dp(getContext(), 5), 0, 0);
            v.setGravity(Gravity.START);
            box.addView(v);

            row.addView(box, new LinearLayout.LayoutParams(0,
                    ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
            out[i] = v;
        }
        addView(row);
        return out;
    }
}
