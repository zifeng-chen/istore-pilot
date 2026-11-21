package com.izifeng.www.istorepilot;

import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.Nullable;

import com.izifeng.www.istorepilot.api.Api;
import com.izifeng.www.istorepilot.api.Cb;
import com.izifeng.www.istorepilot.core.BaseActivity;
import com.izifeng.www.istorepilot.util.Theme;
import com.izifeng.www.istorepilot.util.Ui;

import org.json.JSONArray;
import org.json.JSONObject;

/**
 * 网络测速。
 *
 * 测速不是 App 自己实现的：路由器上的 FastNet 提供 SSE，agent 把它转成
 * 「后台任务 + 状态落盘」，这里只轮询展示。所以本页没有测速逻辑，
 * 只有三件事：取状态、画进度、选节点。
 *
 * 布局按鸿蒙版对齐：一张卡里放「节点 + 进度条 + 三个数值 + 按钮」，
 * 点开始不会再多冒出一张卡。
 */
public class SpeedActivity extends BaseActivity {

    private static final long POLL_MS = 1000L;

    private final Handler ticker = new Handler(Looper.getMainLooper());

    private TextView tvNode;
    private TextView tvPing;
    private TextView tvDown;
    private TextView tvUp;
    private TextView tvHint;
    private TextView btnStart;
    private LinearLayout bars;
    private TextView[] stateLabels;
    private LinearLayout histBox;

    private JSONArray servers = new JSONArray();
    private String serverId = "";
    private boolean running;
    private int elapsed;

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(buildUi());
        loadServers();
        loadHistory();
        refresh();
    }

    @Override
    protected void onDestroy() {
        ticker.removeCallbacksAndMessages(null);
        super.onDestroy();
    }

    // ---------------------------------------------------------------- 界面

    private View buildUi() {
        ScrollView sc = new ScrollView(this);
        sc.setFillViewport(true);
        LinearLayout root = Ui.column(this);
        root.setPadding(Ui.dp(this, 16), Ui.dp(this, 8), Ui.dp(this, 16), Ui.dp(this, 24));

        // 头部
        LinearLayout head = Ui.row(this);
        head.setGravity(Gravity.CENTER_VERTICAL);
        TextView back = Ui.text(this, "‹", 26, R.color.text_primary);
        back.setPadding(Ui.dp(this, 8), 0, Ui.dp(this, 12), 0);
        back.setOnClickListener(v -> finish());
        head.addView(back);
        LinearLayout titles = Ui.column(this);
        titles.addView(Ui.largeTitle(this, "网络测速"));
        titles.addView(Ui.text(this, "FastNet · Ookla 节点", 12, R.color.text_secondary));
        head.addView(titles);
        root.addView(head);

        // 主卡
        Ui.Card card = new Ui.Card(this);
        LinearLayout nodeRow = Ui.row(this);
        nodeRow.setGravity(Gravity.CENTER_VERTICAL);
        LinearLayout nodeCol = Ui.column(this);
        nodeCol.addView(Ui.label(this, "测速节点"));
        tvNode = Ui.value(this, "自动选择");
        nodeCol.addView(tvNode);
        nodeRow.addView(nodeCol, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        TextView pick = Ui.pill(this, "选择", R.color.accent_soft);
        pick.setOnClickListener(v -> pickServer());
        nodeRow.addView(pick);
        card.addView(nodeRow);

        card.addView(Ui.divider(this));

        // 三段进度条（只在测速时显示）
        bars = Ui.row(this);
        bars.setPadding(0, Ui.dp(this, 10), 0, Ui.dp(this, 6));
        for (int i = 0; i < 3; i++) {
            LinearLayout holder = Ui.row(this);
            View bar = Ui.bar(this, 0f, R.color.primary);
            holder.addView(bar, new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, Ui.dp(this, 5)));
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0,
                    ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
            lp.rightMargin = i < 2 ? Ui.dp(this, 4) : 0;
            bars.addView(holder, lp);
        }
        bars.setVisibility(View.GONE);
        card.addView(bars);

        // 三段状态字：和进度条一一对应，各自居中
        LinearLayout states = Ui.row(this);
        states.setPadding(0, Ui.dp(this, 5), 0, 0);
        stateLabels = new TextView[3];
        for (int i = 0; i < 3; i++) {
            stateLabels[i] = Ui.text(this, "", 11, R.color.text_tertiary);
            stateLabels[i].setGravity(Gravity.CENTER);
            states.addView(stateLabels[i], weighted());
        }
        card.addView(states);

        // 三个数值：延迟 / 下行 / 上行，标签在上、数字在下，整列居中
        LinearLayout vals = Ui.row(this);
        vals.setPadding(0, Ui.dp(this, 10), 0, 0);
        tvPing = metric(vals, "延迟");
        tvDown = metric(vals, "下行 ↓");
        tvUp = metric(vals, "上行 ↑");
        card.addView(vals);

        tvHint = Ui.text(this, "还没有测过", 12, R.color.text_tertiary);
        tvHint.setPadding(0, Ui.dp(this, 10), 0, Ui.dp(this, 6));
        card.addView(tvHint);

        btnStart = Ui.filled(this, "开始测速", R.color.primary, R.color.on_primary);
        btnStart.setGravity(Gravity.CENTER);
        btnStart.setPadding(0, Ui.dp(this, 13), 0, Ui.dp(this, 13));
        btnStart.setOnClickListener(v -> startTest());
        card.addView(btnStart, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        root.addView(card);

        // 历史
        Ui.Card hist = new Ui.Card(this);
        hist.addView(Ui.label(this, "历史记录"));
        histBox = Ui.column(this);
        histBox.setPadding(0, Ui.dp(this, 6), 0, 0);
        hist.addView(histBox);
        root.addView(hist);

        sc.addView(root);
        return sc;
    }

    /** 一列数值：标签在上、数字在下，整列水平居中，返回数字本身 */
    private TextView metric(LinearLayout parent, String label) {
        LinearLayout col = Ui.column(this);
        col.setGravity(Gravity.CENTER_HORIZONTAL);
        col.addView(Ui.text(this, label, 11, R.color.text_secondary));
        TextView num = Ui.num(this, "—", 24, R.color.text_primary);
        col.addView(num);
        parent.addView(col, weighted());
        return num;
    }

    private LinearLayout.LayoutParams weighted() {
        return new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
    }

    // ---------------------------------------------------------------- 数据

    private void loadServers() {
        Api.getFresh(this, "/api/v1/speedtest/servers", new Cb() {
            @Override
            public void onData(JSONObject body, boolean fromCache) {
                servers = body.optJSONArray("servers");
                if (servers == null) {
                    servers = new JSONArray();
                }
            }
        });
    }

    private void refresh() {
        Api.getFresh(this, "/api/v1/speedtest/status", new Cb() {
            @Override
            public void onData(JSONObject body, boolean fromCache) {
                if (isFinishing()) {
                    return;
                }
                apply(body);
            }

            @Override
            public void onError(String message) {
                if (!isFinishing()) {
                    tvHint.setText("状态读取失败：" + message);
                }
            }
        });
    }

    private void apply(JSONObject b) {
        boolean wasRunning = running;
        running = b.optBoolean("running", false);
        String stage = b.optString("stage", "");
        double ping = b.optDouble("ping", 0);
        double down = b.optDouble("down", 0);
        double up = b.optDouble("up", 0);
        double liveDown = b.optDouble("liveDown", 0);
        double liveUp = b.optDouble("liveUp", 0);
        String server = b.optString("server", "");

        if (running && !wasRunning) {
            elapsed = b.optInt("elapsed", 0);
        }
        if (running) {
            elapsed += 0;
        }

        tvPing.setText(ping > 0 ? String.valueOf(Math.round(ping)) : "—");
        if ("download".equals(stage)) {
            tvDown.setText(String.format(java.util.Locale.US, "%.1f", liveDown));
            tvUp.setText("—");
        } else if ("upload".equals(stage)) {
            tvDown.setText(down > 0 ? String.format(java.util.Locale.US, "%.1f", down) : "—");
            tvUp.setText(String.format(java.util.Locale.US, "%.1f", liveUp));
        } else {
            tvDown.setText(down > 0 ? String.format(java.util.Locale.US, "%.1f", down) : "—");
            tvUp.setText(up > 0 ? String.format(java.util.Locale.US, "%.1f", up) : "—");
        }

        bars.setVisibility(running ? View.VISIBLE : View.GONE);
        btnStart.setText(running ? "测速中… " + (elapsed + 1) + "s" : "开始测速");
        btnStart.setAlpha(running ? 0.55f : 1f);
        btnStart.setEnabled(!running);

        if (running) {
            paintBars(stage);
            paintStates(stage);
            tvHint.setText(hint(stage));
            ticker.postDelayed(this::onTick, POLL_MS);
        } else {
            tvHint.setText(server.length() > 0 ? "服务器 " + server : "还没有测过");
            if (wasRunning) {
                loadHistory();
            }
        }
    }

    private void onTick() {
        if (!running) {
            return;
        }
        elapsed += 1;
        btnStart.setText("测速中… " + elapsed + "s");
        refresh();
    }

    private void paintStates(String stage) {
        if (stateLabels == null) {
            return;
        }
        String[] txt = new String[3];
        int[] color = new int[3];
        txt[0] = "speedtest".equals(stage) ? "延迟 · 测速中" : "延迟 · 完成";
        color[0] = "speedtest".equals(stage) ? R.color.primary : R.color.text_tertiary;
        if ("download".equals(stage)) {
            txt[1] = "下行 · 测速中";
            color[1] = R.color.primary;
        } else if ("upload".equals(stage) || !running) {
            txt[1] = "下行 · 完成";
            color[1] = R.color.text_tertiary;
        } else {
            txt[1] = "下行 · 等待";
            color[1] = R.color.text_tertiary;
        }
        if ("upload".equals(stage)) {
            txt[2] = "上行 · 测速中";
            color[2] = R.color.primary;
        } else if (!running) {
            txt[2] = "上行 · 完成";
            color[2] = R.color.text_tertiary;
        } else {
            txt[2] = "上行 · 等待";
            color[2] = R.color.text_tertiary;
        }
        for (int i = 0; i < 3; i++) {
            stateLabels[i].setText(txt[i]);
            stateLabels[i].setTextColor(Ui.color(this, color[i]));
        }
    }

    private void paintBars(String stage) {
        float[] pct = new float[3];
        if ("speedtest".equals(stage)) {
            pct[0] = Math.min(0.9f, elapsed * 0.18f);
        } else {
            pct[0] = 1f;
        }
        if ("download".equals(stage)) {
            pct[1] = Math.min(0.95f, Math.max(0f, (elapsed - 3) * 0.09f));
        } else if ("upload".equals(stage) || !running) {
            pct[1] = 1f;
        }
        if ("upload".equals(stage)) {
            pct[2] = Math.min(0.95f, Math.max(0f, (elapsed - 12) * 0.09f));
        } else if (!running) {
            pct[2] = 1f;
        }
        for (int i = 0; i < 3 && i < bars.getChildCount(); i++) {
            LinearLayout holder = (LinearLayout) bars.getChildAt(i);
            holder.removeAllViews();
            holder.addView(Ui.bar(this, pct[i], R.color.primary),
                    new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                            Ui.dp(this, 5)));
        }
    }

    private String hint(String stage) {
        if ("speedtest".equals(stage)) {
            return "正在测延迟 · " + elapsed + " 秒";
        }
        if ("download".equals(stage)) {
            return "正在测下行 · " + elapsed + " 秒";
        }
        if ("upload".equals(stage)) {
            return "正在测上行 · " + elapsed + " 秒";
        }
        return "准备中 · " + elapsed + " 秒";
    }

    private void startTest() {
        if (running) {
            return;
        }
        JSONObject body = new JSONObject();
        try {
            body.put("serverId", serverId);
        } catch (Exception ignored) {
            // serverId 只是个字符串，put 不会失败，忽略即可
        }
        elapsed = 0;
        Api.post(this, "/api/v1/speedtest/start", body, new Cb() {
            @Override
            public void onData(JSONObject b, boolean fromCache) {
                if (b.optBoolean("ok", false)) {
                    running = true;
                    bars.setVisibility(View.VISIBLE);
                    btnStart.setEnabled(false);
                    tvHint.setText("准备测速 · 0 秒");
                    ticker.postDelayed(SpeedActivity.this::onTick, POLL_MS);
                } else {
                    Toast.makeText(SpeedActivity.this, b.optString("error", "启动失败"),
                            Toast.LENGTH_SHORT).show();
                }
            }

            @Override
            public void onError(String message) {
                Toast.makeText(SpeedActivity.this, message, Toast.LENGTH_SHORT).show();
            }
        });
    }

    private void loadHistory() {
        Api.getFresh(this, "/api/v1/speedtest/history", new Cb() {
            @Override
            public void onData(JSONObject body, boolean fromCache) {
                if (isFinishing()) {
                    return;
                }
                renderHistory(body.optJSONArray("rows"));
            }
        });
    }

    private void renderHistory(JSONArray rows) {
        histBox.removeAllViews();
        if (rows == null || rows.length() == 0) {
            histBox.addView(Ui.text(this, "还没有记录", 12, R.color.text_tertiary));
            return;
        }
        for (int i = 0; i < rows.length() && i < 8; i++) {
            JSONObject r = rows.optJSONObject(i);
            if (r == null) {
                continue;
            }
            LinearLayout line = Ui.row(this);
            line.setGravity(Gravity.CENTER_VERTICAL);
            line.setPadding(0, Ui.dp(this, 8), 0, Ui.dp(this, 8));
            TextView time = Ui.text(this, android.text.format.DateFormat.format(
                    "MM-dd HH:mm", r.optLong("time", 0) * 1000L), 12, R.color.text_secondary);
            line.addView(time, new LinearLayout.LayoutParams(0,
                    ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
            String down = String.format(java.util.Locale.US, "%.1f", r.optDouble("down", 0));
            String up = String.format(java.util.Locale.US, "%.1f", r.optDouble("up", 0));
            line.addView(Ui.text(this, down, 12, R.color.text_primary),
                    new LinearLayout.LayoutParams(Ui.dp(this, 66),
                            ViewGroup.LayoutParams.WRAP_CONTENT));
            TextView tvUpRow = Ui.text(this, up, 12, R.color.text_primary);
            tvUpRow.setGravity(Gravity.END);
            line.addView(tvUpRow, new LinearLayout.LayoutParams(Ui.dp(this, 66),
                    ViewGroup.LayoutParams.WRAP_CONTENT));
            line.getChildAt(1).setTextAlignment(View.TEXT_ALIGNMENT_TEXT_END);
            histBox.addView(line);
        }
    }

    private void pickServer() {
        final java.util.List<String> names = new java.util.ArrayList<>();
        final java.util.List<String> ids = new java.util.ArrayList<>();
        names.add("自动选择");
        ids.add("");
        for (int i = 0; i < servers.length(); i++) {
            JSONObject s = servers.optJSONObject(i);
            if (s == null) {
                continue;
            }
            String name = s.optString("name", "");
            if (name.isEmpty()) {
                continue;
            }
            names.add(name + " · " + s.optString("isp", ""));
            ids.add(s.optString("id", ""));
        }
        new android.app.AlertDialog.Builder(this)
                .setTitle("选择测速节点")
                .setItems(names.toArray(new String[0]), (d, which) -> {
                    serverId = ids.get(which);
                    tvNode.setText(which == 0 ? "自动选择" : names.get(which).split(" · ")[0]);
                })
                .show();
    }
}
