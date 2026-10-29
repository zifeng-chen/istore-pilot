package com.chaof.istoreos.widget;

import android.content.Context;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import android.widget.TextView;

import com.chaof.istoreos.R;
import com.chaof.istoreos.util.Ui;

/**
 * 一条横向占用条：左侧「名字 · 细节」，右侧百分比，下面一根进度条。
 *
 * 替换掉原来的三个环形图。环的问题不是不好看，而是**占地方**：三个环并排
 * 要吃掉半屏高度，可它们只表达三个百分比；横条一行一个，同样的信息量
 * 只需要三分之一的高度，还能把「4 核 1.2 GHz」「3.2 / 8 GB」这种细节
 * 直接写在名字后面。
 */
public class MeterBar extends LinearLayout {

    private final String label;
    private final TextView tvLabel;
    private final TextView tvValue;
    private final LinearLayout track;
    private final View fill;

    public MeterBar(Context c, String label) {
        super(c);
        this.label = label;
        setOrientation(VERTICAL);

        LinearLayout head = new LinearLayout(c);
        head.setOrientation(HORIZONTAL);
        head.setGravity(Gravity.CENTER_VERTICAL);

        tvLabel = Ui.text(c, label, 13f, R.color.text_primary);
        head.addView(tvLabel, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        tvValue = Ui.text(c, "—", 13f, R.color.text_primary);
        tvValue.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        tvValue.setGravity(Gravity.END);
        head.addView(tvValue);
        addView(head);

        track = new LinearLayout(c);
        track.setOrientation(HORIZONTAL);
        GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(Ui.dp(c, 4));
        bg.setColor(Ui.alpha(Ui.color(c, R.color.text_primary), 0.08f));
        track.setBackground(bg);

        fill = new View(c);
        track.addView(fill, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.MATCH_PARENT, 1f));
        // 另一半占位：fill 用 weight 表示比例，剩下的由它吃掉
        track.addView(new View(c), new LinearLayout.LayoutParams(0, 1, 1f));

        LinearLayout.LayoutParams tlp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, Ui.dp(c, 7));
        tlp.topMargin = Ui.dp(c, 7);
        addView(track, tlp);

        setRatio(0f);
    }

    /** 0..1。低于 70% 用主色，70~90 橙，90 以上红 —— 和温度的配色一致 */
    public void setRatio(float ratio) {
        float r = Math.max(0f, Math.min(1f, ratio));
        int color = r >= 0.9f ? Ui.color(getContext(), R.color.danger)
                : (r >= 0.7f ? Ui.color(getContext(), R.color.warn)
                : Ui.color(getContext(), R.color.primary));

        GradientDrawable bar = new GradientDrawable();
        bar.setCornerRadius(Ui.dp(getContext(), 4));
        bar.setColor(color);
        fill.setBackground(bar);

        LinearLayout.LayoutParams lp = (LinearLayout.LayoutParams) fill.getLayoutParams();
        // weight 用 0 会让整条消失，留一个极小值保证「几乎为 0」时还有一点点
        lp.weight = Math.max(0.001f, r);
        fill.setLayoutParams(lp);

        LinearLayout parent = (LinearLayout) fill.getParent();
        if (parent != null && parent.getChildCount() > 1) {
            View rest = parent.getChildAt(1);
            LinearLayout.LayoutParams rlp = (LinearLayout.LayoutParams) rest.getLayoutParams();
            rlp.weight = Math.max(0.001f, 1f - r);
            rest.setLayoutParams(rlp);
        }
    }

    /** 右侧百分比文案 */
    public void setValue(String text) {
        tvValue.setText(text);
    }

    /** 名字后面的细节：「4 核 1.2 GHz」「3.2 / 8 GB 可用」 */
    public void setDetail(String text) {
        tvLabel.setText(text == null || text.isEmpty() ? label : label + " · " + text);
    }

}
