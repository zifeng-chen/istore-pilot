package com.chaof.istoreos.ui;

import android.content.Context;
import android.graphics.Typeface;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import android.widget.TextView;

import com.chaof.istoreos.R;
import com.chaof.istoreos.api.Api;
import com.chaof.istoreos.api.Cb;
import com.chaof.istoreos.util.AppIcon;
import com.chaof.istoreos.util.Fmt;
import com.chaof.istoreos.util.Ui;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.Locale;

/**
 * 「应用流量」卡片：一级页（设备）看前几名，点开是完整的排行页。
 *
 * 抽成独立控件是因为它要在多处复用，而且自带取数 —— 谁 add 进来谁负责
 * 在 onData/刷新时调 {@link #refresh()}，不用把加载逻辑散在各页面里。
 *
 * 口径只用**累计**：今日和累计两套数字摆在一起，用户总会怀疑哪个才是真的。
 */
public class AppsCard {

    private final Context c;
    private final LinearLayout box;
    private final TextView tvTotal;
    private final TextView tvMore;
    private final LinearLayout rows;

    public AppsCard(Context c, View.OnClickListener onClick) {
        this.c = c;

        box = Ui.column(c);

        Ui.Card card = Ui.card(c);
        // 和「设备」「拦截」两张卡一套结构：卡片本身左右零内边距，
        // 由标题行和每个列表行各自留 16dp —— 三张卡的行首才会对齐
        Ui.cardPadding(card, 10);   // 最后一行是应用行，行内 10
        card.setClickable(true);
        card.setFocusable(true);
        card.setOnClickListener(onClick);

        LinearLayout head = Ui.row(c);
        head.setPadding(Ui.dp(c, 16), 0, Ui.dp(c, 16), Ui.dp(c, 10));

        LinearLayout iconWrap = Ui.glyphTile(c, com.chaof.istoreos.widget.Glyph.BOLT,
                28, R.color.primary);
        LinearLayout.LayoutParams ilp = new LinearLayout.LayoutParams(
                Ui.dp(c, 28), Ui.dp(c, 28));
        ilp.rightMargin = Ui.dp(c, 10);
        head.addView(iconWrap, ilp);

        LinearLayout left = Ui.column(c);
        TextView title = Ui.text(c, "应用流量", 16.5f, R.color.text_primary);
        title.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        title.setIncludeFontPadding(false);
        left.addView(title);

        tvTotal = Ui.text(c, "统计中…", 12f, R.color.text_secondary);
        tvTotal.setPadding(0, Ui.dp(c, 4), 0, 0);
        left.addView(tvTotal);
        head.addView(left, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        tvMore = Ui.text(c, "全部 ›", 13f, R.color.primary);
        tvMore.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        head.addView(tvMore);
        card.addView(head);
        // 标题区与列表之间来一条线，跟「设备」卡的「最近活跃」上方那条一致
        card.addView(Ui.hairline(c, 16));

        rows = Ui.column(c);
        card.addView(rows);

        box.addView(card);
    }

    public View view() {
        return box;
    }

    public void refresh() {
        Api.get(c, "/api/v1/apps", new Cb() {
            @Override
            public void onData(JSONObject body, boolean fromCache) {
                render(body);
            }

            @Override
            public void onError(String message) {
                // 卡片失败不打扰页面其它内容
            }
        });
    }

    private void render(JSONObject body) {
        JSONObject overall = body.optJSONObject("all");
        JSONArray arr = body.optJSONArray("apps");
        int days = body.optInt("days", 1);
        long up = overall == null ? 0 : overall.optLong("up", 0);
        long down = overall == null ? 0 : overall.optLong("down", 0);
        int total = arr == null ? 0 : arr.length();

        // 应用个数已经在右上「全部 N 个 ›」里，副标题只说时间范围和总量
        tvTotal.setText((days > 1 ? "近 " + days + " 天 · " : "") + "共 " + Fmt.bytes(up + down));
        tvMore.setText("全部 " + total + " 个 ›");

        rows.removeAllViews();
        int shown = 0;
        for (int i = 0; i < total && shown < 3; i++) {
            JSONObject a = arr.optJSONObject(i);
            if (a == null || a.optLong("all_total", 0) < 1024) {
                continue;
            }
            if (shown > 0) {
                // 行间细分隔线，跟「设备」卡的「最近活跃」一致
                rows.addView(Ui.hairline(c, 16));
            }
            rows.addView(line(a));
            shown++;
        }
        if (shown == 0) {
            TextView empty = Ui.text(c, "正在统计…", 12f, R.color.text_secondary);
            empty.setPadding(Ui.dp(c, 16), Ui.dp(c, 10), Ui.dp(c, 16), Ui.dp(c, 4));
            rows.addView(empty);
        }
    }

    private View line(JSONObject a) {
        String name = a.optString("name");
        String category = a.optString("category");
        long total = a.optLong("all_total", 0);
        double share = a.optDouble("share", 0);
        double bps = a.optDouble("down_bps", 0) + a.optDouble("up_bps", 0);

        LinearLayout line = Ui.row(c);
        line.setGravity(Gravity.CENTER_VERTICAL);
        // 卡片左右是 0，行内自己留 16：与「设备」卡的「最近活跃」行对齐
        line.setPadding(Ui.dp(c, 16), Ui.dp(c, 10), Ui.dp(c, 16), Ui.dp(c, 10));

        line.addView(AppIcon.make(c, name, category, 32));

        TextView title = Ui.text(c, name, 14.5f, R.color.text_primary);
        title.setSingleLine(true);
        title.setEllipsize(android.text.TextUtils.TruncateAt.END);
        LinearLayout.LayoutParams tlp = new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
        tlp.leftMargin = Ui.dp(c, 11);
        line.addView(title, tlp);

        if (bps >= 1024) {
            TextView rate = Ui.text(c, Fmt.bps(bps), 11f, R.color.primary);
            rate.setPadding(Ui.dp(c, 6), 0, Ui.dp(c, 6), 0);
            line.addView(rate);
        }

        TextView amount = Ui.text(c, Fmt.bytes(total), 13.5f, R.color.text_primary);
        amount.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        amount.setSingleLine(true);
        line.addView(amount);

        // 占比写在最后，比再摆一条进度条省地方
        if (share > 0) {
            TextView pct = Ui.text(c, String.format(Locale.US, "%.0f%%", share),
                    11f, R.color.text_secondary);
            pct.setGravity(Gravity.END);
            LinearLayout.LayoutParams plp = new LinearLayout.LayoutParams(
                    Ui.dp(c, 34), ViewGroup.LayoutParams.WRAP_CONTENT);
            plp.leftMargin = Ui.dp(c, 6);
            line.addView(pct, plp);
        }
        return line;
    }
}
