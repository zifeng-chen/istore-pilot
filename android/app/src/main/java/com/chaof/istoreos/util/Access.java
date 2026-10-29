package com.chaof.istoreos.util;

import android.content.Context;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.view.Gravity;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import android.widget.TextView;

import com.chaof.istoreos.R;

import org.json.JSONObject;

/**
 * 接入方式标签（无线 / 有线）。
 *
 * 数据有两个来源：
 *   source="ap"    —— 中兴 AP 的接入设备表，是事实
 *   source="guess" —— 靠私有 MAC / 设备类型推的，必须带「(推测)」
 *
 * 合并逻辑放在这里，是因为列表页和设备详情页都要用，两处写法一旦不一致，
 * 用户会以为其中一处是准的。
 */
public final class Access {

    private Access() {
    }

    public static String label(JSONObject access) {
        if (access == null) {
            return "";
        }
        String type = access.optString("type", "");
        // 只有「AP 报的 + 高置信」才算事实；从节点读不到时退回类型推断，
        // 那种也带着 source=ap，但必须标「推测」
        boolean real = isReal(access);
        String band = access.optString("band", "");
        if ("wifi".equals(type)) {
            String text = "无线";
            if (!band.isEmpty()) {
                text += " " + band;
            }
            return real ? text : text + "(推测)";
        }
        if ("wired".equals(type)) {
            return real ? "有线" : "有线(推测)";
        }
        return "";
    }

    /**
     * 列表前面的接入方式徽标：5G / 2.4G / WiFi / LAN / —。
     *
     * 以前这里是「在线状态圆点」—— 一列绿点看不出任何信息。接入方式是用户
     * 真正想知道的（这设备是插线的还是连无线的、连的哪个频段）。
     *
     * 事实画实心、推测画描边：从节点读不到时，主节点会把经它接入的无线
     * 设备报成有线，这类条目只能算「类型对、细节不明」，用描边标出来比
     * 在文字后面挂一串「?」干净得多 —— 55 行里 15 个问号，看着像坏了。
     */
    public static TextView badge(Context c, JSONObject access, boolean online) {
        String text = shortLabel(access);
        boolean real = isReal(access);
        int color;
        if (!online) {
            color = Ui.color(c, R.color.text_tertiary);
        } else if ("5G".equals(text)) {
            color = Ui.color(c, R.color.primary);
        } else if ("2.4G".equals(text)) {
            color = Ui.color(c, R.color.warn);
        } else {
            color = Ui.color(c, R.color.text_secondary);
        }

        TextView v = new TextView(c);
        v.setText(text);
        v.setTextSize(10f);
        v.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        v.setTextColor(color);
        v.setGravity(Gravity.CENTER);
        v.setIncludeFontPadding(false);
        v.setSingleLine(true);
        v.setPadding(Ui.dp(c, 6), Ui.dp(c, 3), Ui.dp(c, 6), Ui.dp(c, 3));

        GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(Ui.dp(c, 7));
        if (real) {
            bg.setColor(Ui.alpha(color, 0.14f));
        } else {
            bg.setColor(android.graphics.Color.TRANSPARENT);
            bg.setStroke(Ui.dp(c, 1), Ui.alpha(color, 0.42f));
        }
        v.setBackground(bg);

        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.rightMargin = Ui.dp(c, 9);
        v.setLayoutParams(lp);
        return v;
    }

    /**
     * 徽标文字：能缩写就缩写（`short` 是 Java 关键字，只能用 shortLabel）。
     * 频段不明就只说类型，类型也不明给一个破折号 —— 问号满屏比留白更像故障
     */
    public static String shortLabel(JSONObject access) {
        if (access == null) {
            return "—";
        }
        String type = access.optString("type", "");
        String band = access.optString("band", "");
        if ("wifi".equals(type)) {
            if (band.startsWith("5")) {
                return "5G";
            }
            if (band.startsWith("2")) {
                return "2.4G";
            }
            return "WiFi";
        }
        if ("wired".equals(type)) {
            return "LAN";
        }
        return "—";
    }

    /** 设备详情里用的长文案：事实只写来源，推测把依据一并带上 */
    public static String describe(JSONObject access) {
        String shortText = label(access);
        if (shortText.isEmpty()) {
            return "";
        }
        if (isReal(access)) {
            String ap = access.optString("ap", "");
            return ap.isEmpty() ? shortText : shortText + "（" + ap + "）";
        }
        String why = access.optString("reason", "");
        return why.isEmpty() ? shortText : shortText + "（" + why + "）";
    }

    /** 「AP 报表 + 高置信」才算事实，其余都是推断 */
    private static boolean isReal(JSONObject access) {
        return "ap".equals(access.optString("source", ""))
                && "high".equals(access.optString("conf", ""));
    }
}
