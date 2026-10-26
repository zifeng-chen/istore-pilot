package com.chaof.istoreos;

import android.content.Context;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.Editable;
import android.text.TextUtils;
import android.text.TextWatcher;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import androidx.annotation.Nullable;
import androidx.appcompat.app.AppCompatActivity;

import com.chaof.istoreos.api.Api;
import com.chaof.istoreos.api.Cb;
import com.chaof.istoreos.util.Ui;
import com.chaof.istoreos.util.Theme;
import com.google.android.material.appbar.MaterialToolbar;

import org.json.JSONArray;
import org.json.JSONObject;
import com.chaof.istoreos.core.BaseActivity;

/**
 * 拦截日志（二级页面）：主页面只放「拦截最多的前 5 条」，明细都在这里。
 *
 * 为什么要分页：接管全网后一天几千条 DNS 查询，全塞进一张卡片既卡又看不清。
 * 这里默认只看拦截（用户点进来就是想知道谁被拦了），可以切到全部查询，
 * 也可以按域名搜。
 */
public class AdblockLogActivity extends BaseActivity {

    private static final int PAGE = 100;
    private static final int MAX_LIMIT = 500;

    private MaterialToolbar toolbar;
    private LinearLayout segBox;
    private LinearLayout listBox;
    private EditText search;
    private TextView tvSummary;
    private TextView tvMore;

    private boolean onlyBlocked = true;
    private int limit = PAGE;
    private String keyword = "";
    private boolean loading = false;

    private final Handler ui = new Handler(Looper.getMainLooper());
    private Runnable pendingSearch;

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        Theme.apply(this);
        super.onCreate(savedInstanceState);

        toolbar = new MaterialToolbar(this);
        toolbar.setTitle("拦截日志");
        toolbar.setNavigationIcon(R.drawable.ic_back);
        toolbar.setNavigationIconTint(Ui.color(this, R.color.text_primary));
        toolbar.setNavigationOnClickListener(v -> finish());
        toolbar.setBackgroundColor(Ui.color(this, R.color.app_bg));

        ScrollView scroller = new ScrollView(this);
        scroller.setBackgroundColor(Ui.color(this, R.color.app_bg));
        scroller.setClipToPadding(false);
        scroller.setFillViewport(true);

        LinearLayout root = Ui.column(this);
        int pad = Ui.dp(this, 16);
        root.setPadding(pad, Ui.dp(this, 8), pad, Ui.dp(this, 28));

        buildFilter(root);
        buildList(root);

        scroller.addView(root);

        LinearLayout page = Ui.column(this);
        page.setBackgroundColor(Ui.color(this, R.color.app_bg));
        page.addView(toolbar, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        page.addView(scroller, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));
        setContentView(page);

        load();
    }

    // ---------------------------------------------------------------- 骨架

    private void buildFilter(LinearLayout root) {
        Ui.Card card = Ui.card(this);

        segBox = Ui.column(this);
        card.addView(segBox);
        renderSeg();

        search = new EditText(this);
        search.setHint("搜索域名");
        search.setTextSize(14f);
        search.setSingleLine(true);
        search.setTextColor(Ui.color(this, R.color.text_primary));
        search.setHintTextColor(Ui.color(this, R.color.text_secondary));
        GradientDrawable sbg = new GradientDrawable();
        sbg.setCornerRadius(Ui.dp(this, 14));
        sbg.setColor(Ui.color(this, R.color.surface_hi));
        search.setBackground(sbg);
        int ph = Ui.dp(this, 12), pv = Ui.dp(this, 10);
        search.setPadding(ph, pv, ph, pv);
        LinearLayout.LayoutParams slp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        slp.topMargin = Ui.dp(this, 10);
        card.addView(search, slp);

        search.addTextChangedListener(new TextWatcher() {
            @Override
            public void beforeTextChanged(CharSequence s, int a, int b, int d) {
            }

            @Override
            public void onTextChanged(CharSequence s, int a, int b, int d) {
                if (pendingSearch != null) {
                    ui.removeCallbacks(pendingSearch);
                }
                // 打字时不要每敲一个字就查一次，停 400ms 再发
                pendingSearch = () -> {
                    keyword = s.toString().trim();
                    limit = PAGE;
                    load();
                };
                ui.postDelayed(pendingSearch, 400);
            }

            @Override
            public void afterTextChanged(Editable s) {
            }
        });

        LinearLayout foot = Ui.row(this);
        foot.setPadding(0, Ui.dp(this, 12), 0, 0);
        tvSummary = Ui.text(this, "读取中…", 11.5f, R.color.text_secondary);
        foot.addView(tvSummary, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        TextView refresh = Ui.text(this, "刷新", 12.5f, R.color.primary);
        refresh.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        refresh.setPadding(Ui.dp(this, 12), 0, 0, 0);
        refresh.setOnClickListener(v -> load());
        foot.addView(refresh);
        card.addView(foot);

        root.addView(card);
    }

    private void buildList(LinearLayout root) {
        Ui.Card card = Ui.card(this);
        listBox = Ui.column(this);
        card.addView(listBox);
        root.addView(card);

        // 「加载更多」放在卡片外面，长列表里更好点
        tvMore = Ui.text(this, "加载更多", 14f, R.color.primary);
        tvMore.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        tvMore.setGravity(Gravity.CENTER);
        tvMore.setPadding(0, Ui.dp(this, 6), 0, Ui.dp(this, 6));
        tvMore.setVisibility(View.GONE);
        tvMore.setOnClickListener(v -> {
            limit = Math.min(MAX_LIMIT, limit + PAGE);
            load();
        });
        root.addView(tvMore);
    }

    private void renderSeg() {
        if (segBox == null) {
            return;
        }
        segBox.removeAllViews();
        segBox.addView(Ui.segmented(this, new String[]{"只看拦截", "全部查询"},
                onlyBlocked ? 0 : 1, index -> {
                    boolean want = index == 0;
                    if (want == onlyBlocked) {
                        return;
                    }
                    onlyBlocked = want;
                    limit = PAGE;
                    // 视图替换延后一拍：在点击回调里直接 removeAllViews 会把自己拆掉，
                    // 新分段的选中态有时来不及生效
                    segBox.post(this::renderSeg);
                    load();
                }));
    }

    // ---------------------------------------------------------------- 数据

    private void load() {
        if (loading) {
            return;
        }
        loading = true;
        tvSummary.setText("读取中…");

        String path = "/api/v1/adblock/log?limit=" + limit
                + (onlyBlocked ? "&only_blocked=1" : "")
                + (keyword.isEmpty() ? "" : "&search=" + android.net.Uri.encode(keyword));

        Api.getFresh(this, path, new Cb() {
            @Override
            public void onData(JSONObject body, boolean fromCache) {
                loading = false;
                if (isFinishing()) {
                    return;
                }
                render(body);
            }

            @Override
            public void onError(String message) {
                loading = false;
                if (isFinishing()) {
                    return;
                }
                tvSummary.setText("读取失败：" + message);
                listBox.removeAllViews();
                listBox.addView(Ui.label(AdblockLogActivity.this, "拉不到日志：" + message));
                tvMore.setVisibility(View.GONE);
            }
        });
    }

    private void render(JSONObject body) {
        Context c = this;
        listBox.removeAllViews();

        if (!body.optBoolean("ok", false)) {
            tvSummary.setText("读取失败");
            listBox.addView(Ui.label(c, body.optString("error", "AGH 没有返回日志")));
            tvMore.setVisibility(View.GONE);
            return;
        }

        JSONArray items = body.optJSONArray("items");
        int count = items == null ? 0 : items.length();
        int blocked = body.optInt("blocked", 0);

        String label = onlyBlocked ? "拦截记录" : "查询记录";
        tvSummary.setText(label + " " + count + " 条"
                + (onlyBlocked ? "" : "　·　其中拦截 " + blocked + " 条")
                + (keyword.isEmpty() ? "" : "　·　匹配「" + keyword + "」"));

        if ("observe".equals(body.optString("mode", ""))) {
            TextView tip = Ui.text(c,
                    "当前是观察模式，AGH 只服务路由器本机，日志几乎都是路由器自己的查询。",
                    12.5f, R.color.warn);
            tip.setLineSpacing(Ui.dp(c, 2), 1f);
            tip.setPadding(0, 0, 0, Ui.dp(c, 8));
            listBox.addView(tip);
        }

        if (count == 0) {
            TextView empty = Ui.label(c, keyword.isEmpty()
                    ? (onlyBlocked ? "这段时间没有被拦截的记录" : "暂无查询记录")
                    : "没有匹配「" + keyword + "」的记录");
            empty.setPadding(0, Ui.dp(c, 8), 0, Ui.dp(c, 8));
            listBox.addView(empty);
            tvMore.setVisibility(View.GONE);
            return;
        }

        for (int i = 0; i < count; i++) {
            JSONObject it = items.optJSONObject(i);
            if (it == null) {
                continue;
            }
            if (i > 0) {
                listBox.addView(Ui.hairline(c));
            }
            addRow(c, it);
        }

        tvMore.setVisibility(count >= limit && limit < MAX_LIMIT ? View.VISIBLE : View.GONE);
        tvMore.setText(limit >= MAX_LIMIT ? "" : "加载更多（已显示 " + count + " 条）");
    }

    private void addRow(Context c, JSONObject it) {
        boolean blocked = it.optBoolean("blocked", false);

        LinearLayout line = Ui.row(c);
        line.setPadding(0, Ui.dp(c, 9), 0, Ui.dp(c, 9));

        TextView dot = Ui.text(c, "●", 9f, blocked ? R.color.danger : R.color.text_tertiary);
        line.addView(dot, new LinearLayout.LayoutParams(Ui.dp(c, 16),
                ViewGroup.LayoutParams.WRAP_CONTENT));

        LinearLayout col = Ui.column(c);

        TextView name = Ui.text(c, it.optString("domain", ""), 13.5f, R.color.text_primary);
        name.setSingleLine(true);
        name.setEllipsize(TextUtils.TruncateAt.END);
        col.addView(name);

        String time = hhmmss(it.optString("time", ""));
        String list = it.optString("list", "");
        String rule = it.optString("rule", "");
        StringBuilder sub = new StringBuilder(time);
        // 客户端地址在接管后基本都是 192.168.100.1（nft 转发后的源），
        // 摆出来只会误导，所以只展示命中的规则/列表
        if (blocked && !list.isEmpty()) {
            sub.append("　·　").append(list);
        } else if (!rule.isEmpty()) {
            sub.append("　·　").append(rule.length() > 22 ? rule.substring(0, 20) + "…" : rule);
        } else if (blocked) {
            sub.append("　·　").append(it.optString("reason", ""));
        }
        TextView meta = Ui.text(c, sub.toString(), 11f, R.color.text_secondary);
        meta.setSingleLine(true);
        meta.setEllipsize(TextUtils.TruncateAt.END);
        meta.setPadding(0, Ui.dp(c, 2), 0, 0);
        col.addView(meta);

        line.addView(col, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        if (blocked) {
            line.addView(Ui.pill(c, "已拦截", R.color.danger));
        } else {
            double ms = it.optDouble("elapsed", 0);
            TextView t = Ui.text(c, ms > 0
                            ? String.format(java.util.Locale.US, "%.0fms", ms) : "放行",
                    11f, R.color.text_tertiary);
            t.setPadding(Ui.dp(c, 8), 0, 0, 0);
            line.addView(t);
        }

        listBox.addView(line);
    }

    /** AGH 返回的是 2026-10-24T17:02:43.118942863+08:00，只取时分秒 */
    private static String hhmmss(String iso) {
        int t = iso.indexOf('T');
        if (t >= 0 && iso.length() >= t + 9) {
            return iso.substring(t + 1, t + 9);
        }
        return iso.length() > 8 ? iso.substring(11) : iso;
    }
}
