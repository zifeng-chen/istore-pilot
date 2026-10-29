package com.chaof.istoreos;

import android.content.Context;
import android.graphics.Typeface;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import androidx.annotation.Nullable;

import com.chaof.istoreos.api.Api;
import com.chaof.istoreos.api.Cb;
import com.chaof.istoreos.core.BaseActivity;
import com.chaof.istoreos.util.AppIcon;
import com.chaof.istoreos.util.Fmt;
import com.chaof.istoreos.util.Theme;
import com.chaof.istoreos.util.Ui;
import com.google.android.material.appbar.MaterialToolbar;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.HashMap;
import java.util.Map;

/**
 * 应用流量排行（二级页面）。
 *
 * 设备页只放一张卡片看前几名，完整的 60 多个应用放这里 —— 一张卡片塞不下，
 * 塞进去也没人往下翻。数据来自 `/api/v1/apps`，按累计用量排序，
 * 「IP 直连」由服务端固定在末尾（它不是应用，是认不出域名的那些连接）。
 */
public class AppsActivity extends BaseActivity {

    private static final long TICK_MS = 3000L;

    private final Handler ticker = new Handler(Looper.getMainLooper());
    private final Runnable tick = new Runnable() {
        @Override
        public void run() {
            load(true);
            ticker.postDelayed(this, TICK_MS);
        }
    };

    private TextView tvTotal;
    private TextView tvSplit;
    private TextView tvSession;
    private TextView tvDays;
    private LinearLayout listBox;
    private TextView tvEmpty;

    private JSONArray rows = new JSONArray();
    private String structure = "";
    private final Map<String, TextView> amountViews = new HashMap<>();
    private final Map<String, TextView> rateViews = new HashMap<>();

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        Theme.apply(this);
        super.onCreate(savedInstanceState);

        MaterialToolbar toolbar = new MaterialToolbar(this);
        toolbar.setTitle("应用流量");
        toolbar.setNavigationIcon(R.drawable.ic_back);
        toolbar.setNavigationIconTint(Ui.color(this, R.color.text_primary));
        toolbar.setNavigationOnClickListener(v -> finish());
        toolbar.setBackgroundColor(Ui.color(this, R.color.app_bg));

        // 汇总卡钉在顶部不滚：它回答的是「总共用了多少」，翻到第 40 个应用时
        // 还想拿它跟眼前这行的数字对照。只有下面的列表滚
        int pad = Ui.dp(this, 16);
        LinearLayout head = Ui.column(this);
        head.setBackgroundColor(Ui.color(this, R.color.app_bg));
        head.setPadding(pad, Ui.dp(this, 8), pad, Ui.dp(this, 10));
        head.addView(summaryCard(this));

        ScrollView scroller = new ScrollView(this);
        scroller.setBackgroundColor(Ui.color(this, R.color.app_bg));
        scroller.setClipToPadding(false);

        LinearLayout root = Ui.column(this);
        root.setPadding(pad, 0, pad, Ui.dp(this, 28));

        listBox = Ui.column(this);
        root.addView(listBox);

        tvEmpty = Ui.text(this, "还没有捕获到应用流量", 14f, R.color.text_secondary);
        tvEmpty.setGravity(Gravity.CENTER);
        tvEmpty.setPadding(0, Ui.dp(this, 24), 0, 0);
        tvEmpty.setVisibility(android.view.View.GONE);
        root.addView(tvEmpty);

        scroller.addView(root);

        LinearLayout page = Ui.column(this);
        page.setBackgroundColor(Ui.color(this, R.color.app_bg));
        page.addView(toolbar, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        page.addView(head, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        page.addView(scroller, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));
        setContentView(page);

        load(false);
    }

    @Override
    protected void onResume() {
        super.onResume();
        ticker.removeCallbacks(tick);
        ticker.postDelayed(tick, TICK_MS);
    }

    @Override
    protected void onPause() {
        super.onPause();
        ticker.removeCallbacks(tick);
    }

    // ---------------------------------------------------------------- 骨架

    private LinearLayout summaryCard(Context c) {
        Ui.Card card = Ui.card(c);

        tvDays = Ui.text(c, "累计用量", 12.5f, R.color.text_secondary);
        card.addView(tvDays);

        tvTotal = Ui.text(c, "—", 30f, R.color.text_primary);
        tvTotal.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        tvTotal.setPadding(0, Ui.dp(c, 2), 0, 0);
        card.addView(tvTotal);

        tvSplit = Ui.text(c, "↓ —　↑ —", 13f, R.color.text_secondary);
        tvSplit.setPadding(0, Ui.dp(c, 4), 0, 0);
        card.addView(tvSplit);

        card.addView(Ui.divider(c));

        tvSession = Ui.text(c, "正在统计…", 12.5f, R.color.text_secondary);
        tvSession.setLineSpacing(Ui.dp(c, 3), 1f);
        card.addView(tvSession);

        LinearLayout box = Ui.column(c);
        box.addView(card);
        return box;
    }

    // ---------------------------------------------------------------- 数据

    private void load(boolean quiet) {
        Api.get(this, "/api/v1/apps", new Cb() {
            @Override
            public void onData(JSONObject body, boolean fromCache) {
                render(body);
            }

            @Override
            public void onError(String message) {
                if (!quiet && tvSession != null) {
                    tvSession.setText("读取失败：" + message);
                }
            }
        });
    }

    private void render(JSONObject body) {
        JSONObject overall = body.optJSONObject("all");
        JSONObject session = body.optJSONObject("session");
        JSONObject clash = body.optJSONObject("clash");
        int days = body.optInt("days", 1);
        int conns = clash == null ? 0 : clash.optInt("connections", 0);

        long up = overall == null ? 0 : overall.optLong("up", 0);
        long down = overall == null ? 0 : overall.optLong("down", 0);
        long sUp = session == null ? 0 : session.optLong("up", 0);
        long sDown = session == null ? 0 : session.optLong("down", 0);

        tvDays.setText(days > 1 ? "累计用量　·　已统计 " + days + " 天" : "累计用量");
        tvTotal.setText(Fmt.bytes(up + down));
        tvSplit.setText("↓ " + Fmt.bytes(down) + "　↑ " + Fmt.bytes(up));
        tvSession.setText("本次运行 " + Fmt.bytes(sUp + sDown)
                + "　·　当前 " + conns + " 条连接"
                + "\n右边的大数字是该应用的总用量，重启不清零；"
                + "「IP 直连」是认不出域名的连接，排在最后");

        JSONArray arr = body.optJSONArray("apps");
        rows = arr == null ? new JSONArray() : arr;

        tvEmpty.setVisibility(rows.length() == 0 ? android.view.View.VISIBLE : android.view.View.GONE);

        // 结构没变就只刷新文字：60 多行每 3 秒整表重建会卡
        StringBuilder sig = new StringBuilder();
        for (int i = 0; i < rows.length(); i++) {
            JSONObject a = rows.optJSONObject(i);
            if (a != null) {
                sig.append(a.optString("name")).append(';');
            }
        }
        if (!sig.toString().equals(structure)) {
            structure = sig.toString();
            rebuild();
        } else {
            refreshLive();
        }
    }

    private void rebuild() {
        Context c = listBox.getContext();
        listBox.removeAllViews();
        amountViews.clear();
        rateViews.clear();
        for (int i = 0; i < rows.length(); i++) {
            JSONObject a = rows.optJSONObject(i);
            if (a != null) {
                listBox.addView(row(c, a));
            }
        }
    }

    private void refreshLive() {
        for (int i = 0; i < rows.length(); i++) {
            JSONObject a = rows.optJSONObject(i);
            if (a == null) {
                continue;
            }
            String name = a.optString("name");
            TextView amount = amountViews.get(name);
            if (amount != null) {
                amount.setText(Fmt.bytes(a.optLong("all_total", 0)));
            }
            TextView rate = rateViews.get(name);
            if (rate != null) {
                double bps = a.optDouble("down_bps", 0) + a.optDouble("up_bps", 0);
                rate.setText(bps < 1024 ? "" : Fmt.bps(bps));
            }
        }
    }

    private android.view.View row(Context c, JSONObject a) {
        String name = a.optString("name");
        String category = a.optString("category");
        int conns = a.optInt("conns", 0);
        long total = a.optLong("all_total", 0);
        long down = a.optLong("all_down", 0);
        long up = a.optLong("all_up", 0);
        double share = a.optDouble("share", 0);
        double bps = a.optDouble("down_bps", 0) + a.optDouble("up_bps", 0);

        Ui.Card card = Ui.card(c);
        LinearLayout line = Ui.row(c);

        line.addView(AppIcon.make(c, name, category, 44));

        LinearLayout mid = Ui.column(c);
        mid.setPadding(Ui.dp(c, 12), 0, Ui.dp(c, 6), 0);

        LinearLayout nameRow = Ui.row(c);
        TextView title = Ui.text(c, name, 15f, R.color.text_primary);
        title.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        title.setSingleLine(true);
        title.setEllipsize(android.text.TextUtils.TruncateAt.END);
        nameRow.addView(title, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        TextView rate = Ui.text(c, bps < 1024 ? "" : Fmt.bps(bps), 11.5f, R.color.primary);
        rate.setSingleLine(true);
        rate.setPadding(Ui.dp(c, 6), 0, 0, 0);
        nameRow.addView(rate);
        mid.addView(nameRow);

        // 占比比「多少 GB」更能说明「谁在吃带宽」，放这一行的开头。
        // 上下行**不能**再挤在这行里：一行塞四项，窄屏上「↑ x」会被省略号吃掉，
        // 看着像没统计 —— 它挪到右边金额下面单独一行
        StringBuilder meta = new StringBuilder();
        if (share > 0) {
            meta.append("占 ").append(String.format(java.util.Locale.US, "%.1f", share)).append("%");
        }
        if (category != null && !category.isEmpty() && !"其他".equals(category)) {
            meta.append(meta.length() > 0 ? "　·　" : "").append(category);
        }
        if (conns > 0) {
            meta.append(meta.length() > 0 ? "　·　" : "").append(conns).append(" 连接");
        }
        TextView metaView = Ui.text(c, meta.toString(), 11.5f, R.color.text_secondary);
        metaView.setSingleLine(true);
        metaView.setEllipsize(android.text.TextUtils.TruncateAt.END);
        metaView.setPadding(0, Ui.dp(c, 3), 0, 0);
        mid.addView(metaView);

        line.addView(mid, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        LinearLayout tail = Ui.column(c);
        tail.setGravity(Gravity.END);
        TextView amount = Ui.text(c, Fmt.bytes(total), 17f, R.color.text_primary);
        amount.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        amount.setSingleLine(true);
        tail.addView(amount);

        TextView io = Ui.text(c, "↓ " + Fmt.bytes(down) + "　↑ " + Fmt.bytes(up),
                10.5f, R.color.text_secondary);
        io.setGravity(Gravity.END);
        io.setSingleLine(true);
        io.setPadding(0, Ui.dp(c, 3), 0, 0);
        tail.addView(io);

        LinearLayout.LayoutParams tailLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        tailLp.leftMargin = Ui.dp(c, 10);
        line.addView(tail, tailLp);

        card.addView(line);
        amountViews.put(name, amount);
        rateViews.put(name, rate);
        return card;
    }
}
