package com.izifeng.www.istorepilot;

import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.MenuItem;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.Nullable;

import com.izifeng.www.istorepilot.api.Api;
import com.izifeng.www.istorepilot.api.Cb;
import com.izifeng.www.istorepilot.util.Theme;
import com.izifeng.www.istorepilot.util.Ui;
import com.izifeng.www.istorepilot.widget.Sheet;
import com.google.android.material.appbar.MaterialToolbar;

import org.json.JSONArray;
import org.json.JSONObject;
import com.izifeng.www.istorepilot.core.BaseActivity;

/**
 * 订阅管理（**一个后端一套**：OpenClash 的订阅段，或 PassWall 的订阅节点）。
 *
 * 从代理页的「配置与节点」进来，带 backend 参数决定管哪个后端 —— 两边的订阅
 * 存在各自的 uci 包（openclash / passwall）里，互不通用，所以标题必须点名，
 * 否则用户以为这里能同时管两个。代理页本身只留一行入口，这里才是增删改的地方：
 * 右上角「添加」，列表点一行改成编辑/更新/删除。
 *
 * 订阅改的是 uci 里的 subscription 段，改完必须「更新」才会真正拉一次；
 * 这条链路慢（要访问订阅服务器），所以每个动作都先给提示再发请求。
 */
public class SubscriptionActivity extends BaseActivity {

    private LinearLayout listBox;
    private TextView tvCount;
    private TextView tvEmpty;
    private String backendId = "";
    /** 订阅刷新是异步的，60 秒后自动重拉一次列表看结果 */
    private final Handler handler = new Handler(Looper.getMainLooper());

    // 最近一次「更新」的结果（时间 / 成败 / 耗时 / 日志尾部）
    private LinearLayout logCard;
    private TextView logState;
    private TextView logLine;
    private TextView logTail;
    private LinearLayout logToggle;
    private boolean logOpen = false;
    private boolean logPolling = false;
    private String logTailText = "";

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        Theme.apply(this);
        super.onCreate(savedInstanceState);

        backendId = getIntent().getStringExtra("backend");
        if (backendId == null) {
            backendId = "";
        }

        MaterialToolbar toolbar = new MaterialToolbar(this);
        // 订阅是每个后端各一套（uci 里分属 openclash / passwall），标题必须点名
        // 管的是哪个 —— 只写「订阅管理」会让人以为这里能同时管两个后端
        toolbar.setTitle(backendId.isEmpty() ? "订阅管理"
                : "订阅管理 · " + ("passwall".equals(backendId) ? "PassWall" : "OpenClash"));
        toolbar.setNavigationIcon(R.drawable.ic_back);
        toolbar.setNavigationIconTint(Ui.color(this, R.color.text_primary));
        toolbar.setNavigationOnClickListener(v -> finish());
        toolbar.setBackgroundColor(Ui.color(this, R.color.app_bg));

        // 右上角「添加」：用菜单项而不是自绘按钮，位置和系统习惯一致
        MenuItem add = toolbar.getMenu().add(0, 1, 0, "添加");
        add.setShowAsAction(MenuItem.SHOW_AS_ACTION_ALWAYS);
        toolbar.setOnMenuItemClickListener(item -> {
            if (item.getItemId() == 1) {
                addSub();
                return true;
            }
            return false;
        });

        ScrollView scroller = new ScrollView(this);
        scroller.setBackgroundColor(Ui.color(this, R.color.app_bg));
        scroller.setClipToPadding(false);
        scroller.setFillViewport(true);

        LinearLayout root = Ui.column(this);
        int pad = Ui.dp(this, 16);
        root.setPadding(pad, Ui.dp(this, 8), pad, Ui.dp(this, 28));

        Ui.Card head = Ui.card(this);
        LinearLayout headRow = Ui.header(head, "订阅地址", "改完点「更新」才会重新拉取");
        tvCount = Ui.value(this, "—");
        headRow.addView(tvCount);

        tvEmpty = Ui.text(this, "", 12.5f, R.color.text_secondary);
        tvEmpty.setLineSpacing(Ui.dp(this, 2), 1f);
        LinearLayout.LayoutParams elp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        elp.topMargin = Ui.dp(this, 8);
        tvEmpty.setVisibility(android.view.View.GONE);
        head.addView(tvEmpty, elp);
        root.addView(head);

        root.addView(buildLogCard());

        Ui.Card list = Ui.card(this);
        Ui.header(list, "全部订阅", "");
        listBox = Ui.column(this);
        LinearLayout.LayoutParams llp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        llp.topMargin = Ui.dp(this, 4);
        list.addView(listBox, llp);
        root.addView(list);

        scroller.addView(root);

        LinearLayout wrap = Ui.column(this);
        wrap.addView(toolbar);
        wrap.addView(scroller, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));
        setContentView(wrap);

        load();
        loadLog();
    }


    // ---------------------------------------------------------------- 更新日志

    /** 「最近更新」卡：时间 / 成败 / 耗时，日志可展开 —— 更新是后台跑的，不给结果等于黑箱 */
    private LinearLayout buildLogCard() {
        logCard = Ui.card(this);
        LinearLayout headRow = Ui.header(logCard, "最近更新", "");
        logState = Ui.text(this, "", 11f, R.color.text_secondary);
        headRow.addView(logState);

        logLine = Ui.text(this, "", 12.5f, R.color.text_secondary);
        logLine.setLineSpacing(Ui.dp(this, 2), 1f);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.topMargin = Ui.dp(this, 7);
        logCard.addView(logLine, lp);

        logToggle = Ui.row(this);
        TextView tv = Ui.text(this, "查看日志", 12.5f, R.color.primary);
        tv.setPadding(0, Ui.dp(this, 8), 0, 0);
        tv.setOnClickListener(v -> {
            logOpen = !logOpen;
            applyLogTail();
        });
        logToggle.addView(tv);
        logCard.addView(logToggle);

        logTail = Ui.text(this, "", 10.5f, R.color.text_secondary);
        logTail.setTypeface(android.graphics.Typeface.MONOSPACE);
        logTail.setLineSpacing(Ui.dp(this, 2), 1f);
        int p = Ui.dp(this, 10);
        logTail.setPadding(p, p, p, p);
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(Ui.color(this, R.color.surface_sunken));
        bg.setCornerRadius(Ui.dp(this, 10));
        logTail.setBackground(bg);
        LinearLayout.LayoutParams tlp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        tlp.topMargin = Ui.dp(this, 6);
        logCard.addView(logTail, tlp);

        logCard.setVisibility(android.view.View.GONE);
        return logCard;
    }

    private void applyLogTail() {
        boolean has = !logTailText.isEmpty();
        logTail.setVisibility(logOpen && has
                ? android.view.View.VISIBLE : android.view.View.GONE);
        logToggle.setVisibility(has ? android.view.View.VISIBLE : android.view.View.GONE);
        if (logToggle.getChildCount() > 0) {
            ((TextView) logToggle.getChildAt(0)).setText(logOpen ? "收起日志" : "查看日志");
        }
    }

    private void loadLog() {
        Api.getFresh(this, "/api/v1/proxy/subscriptions/log", new Cb() {
            @Override
            public void onData(JSONObject body, boolean fromCache) {
                if (isFinishing()) {
                    return;
                }
                JSONObject lg = body.optJSONObject("log");
                if (lg == null || lg.optLong("started_at", 0) <= 0) {
                    logCard.setVisibility(android.view.View.GONE);
                    return;
                }
                renderLog(lg);
                if (lg.optBoolean("running", false)) {
                    scheduleLogPoll();
                } else {
                    logPolling = false;
                }
            }
        });
    }

    private void scheduleLogPoll() {
        if (logPolling) {
            return;
        }
        logPolling = true;
        handler.postDelayed(() -> {
            logPolling = false;
            loadLog();
        }, 2000);
    }

    private void renderLog(JSONObject lg) {
        boolean running = lg.optBoolean("running", false);
        boolean ok = lg.optBoolean("ok", false);
        int secs = lg.optInt("seconds", 0);
        logTailText = lg.optString("tail", "");
        logState.setText(running ? "进行中" : (ok ? "成功" : "失败"));
        logState.setTextColor(Ui.color(this,
                running || ok ? R.color.primary : R.color.danger));
        logLine.setText(clock(lg.optLong("started_at", 0)) + " · "
                + lg.optString("summary", "")
                + (!running && secs > 0 ? "（" + secs + " 秒）" : ""));
        logCard.setVisibility(android.view.View.VISIBLE);
        applyLogTail();
    }

    private static String clock(long ts) {
        if (ts <= 0) {
            return "";
        }
        return new java.text.SimpleDateFormat("MM-dd HH:mm", java.util.Locale.getDefault())
                .format(new java.util.Date(ts * 1000));
    }

    // ---------------------------------------------------------------- 数据

    private void load() {
        if (backendId.isEmpty()) {
            tvEmpty.setVisibility(android.view.View.VISIBLE);
            tvEmpty.setText("两个代理后端都没在运行，订阅列表不可用。");
            tvCount.setText("");
            return;
        }
        Api.getFresh(this, "/api/v1/proxy/subscriptions?backend=" + backendId, new Cb() {
            @Override
            public void onData(JSONObject body, boolean fromCache) {
                if (isFinishing()) {
                    return;
                }
                render(body.optJSONArray("items"));
            }

            @Override
            public void onError(String message) {
                if (isFinishing()) {
                    return;
                }
                listBox.removeAllViews();
                tvCount.setText("");
                tvEmpty.setVisibility(android.view.View.VISIBLE);
                tvEmpty.setText("读取失败：" + message);
            }
        });
    }

    private void render(JSONArray items) {
        listBox.removeAllViews();
        int n = items == null ? 0 : items.length();
        tvCount.setText(n == 0 ? "" : n + " 条");

        if (n == 0) {
            tvEmpty.setVisibility(android.view.View.VISIBLE);
            tvEmpty.setText("还没有订阅。点右上角「添加」把订阅链接粘进来。");
            return;
        }
        tvEmpty.setVisibility(android.view.View.GONE);

        for (int i = 0; i < n; i++) {
            final JSONObject item = items.optJSONObject(i);
            if (item == null) {
                continue;
            }
            if (i > 0) {
                listBox.addView(Ui.divider(this));
            }
            listBox.addView(subRow(item));
        }
    }

    private LinearLayout subRow(JSONObject item) {
        // 「启用」= 正在用的那一条。uci 里的 enabled 是「要不要包含在订阅列表里」，
        // 跟「现在生效的是谁」不是一回事，不能拿来当角标
        boolean inUse = item.optBoolean("in_use", false);
        String traffic = item.optString("traffic", "");
        String expired = item.optString("expired", "");
        final String id = item.optString("id", "");

        LinearLayout line = Ui.row(this);
        line.setPadding(0, Ui.dp(this, 12), 0, Ui.dp(this, 12));
        line.setClickable(true);

        LinearLayout col = Ui.column(this);

        // 名称 + 使用中角标同一行：角标放进右侧竖列会被挤窄，三个字只显示得下两个
        LinearLayout nameRow = Ui.row(this);
        nameRow.setGravity(Gravity.CENTER_VERTICAL);
        TextView name = Ui.text(this, item.optString("name", "未命名"), 15f, R.color.text_primary);
        name.setTypeface(android.graphics.Typeface.create(
                "sans-serif-medium", android.graphics.Typeface.NORMAL));
        name.setMaxLines(1);
        name.setEllipsize(android.text.TextUtils.TruncateAt.END);
        nameRow.addView(name);
        // 名称有上限，超了省略 —— 角标要紧跟在名字后面，不能被顶到最右边
        name.setMaxWidth(Ui.dp(this, 180));
        if (inUse) {
            TextView badge = Ui.pill(this, "使用中", R.color.primary);
            LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            blp.leftMargin = Ui.dp(this, 8);
            nameRow.addView(badge, blp);
        }
        col.addView(nameRow);

        // 地址里带 token，只显示首尾，避免截图把订阅送人
        TextView url = Ui.text(this, item.optString("url_masked", ""), 11.5f, R.color.text_secondary);
        url.setMaxLines(1);
        url.setEllipsize(android.text.TextUtils.TruncateAt.MIDDLE);
        url.setPadding(0, Ui.dp(this, 3), 0, 0);
        col.addView(url);

        String extra = "";
        if (!traffic.isEmpty()) {
            extra = "剩余 " + traffic;
        }
        if (!expired.isEmpty()) {
            extra = extra.isEmpty() ? "到期 " + expired : extra + " · 到期 " + expired;
        }
        if (!extra.isEmpty()) {
            TextView meta = Ui.text(this, extra, 11f, R.color.text_tertiary);
            meta.setPadding(0, Ui.dp(this, 3), 0, 0);
            col.addView(meta);
        }

        line.addView(col, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        // 右侧只留一个「更新」：状态已经挪到名称旁边了，
        // 更新是这一页最常用的动作，藏在长按菜单里每次都要多点两下
        LinearLayout right = Ui.column(this);
        right.setGravity(Gravity.END);

        // 更新做成描边：跟角标那种实底区分开，一眼看出是能点的
        TextView upd = Ui.text(this, "更新", 11.5f, R.color.primary);
        upd.setTypeface(android.graphics.Typeface.create(
                "sans-serif-medium", android.graphics.Typeface.NORMAL));
        upd.setGravity(Gravity.CENTER);
        upd.setPadding(Ui.dp(this, 14), Ui.dp(this, 4),
                Ui.dp(this, 14), Ui.dp(this, 4));
        GradientDrawable ubg = new GradientDrawable();
        ubg.setCornerRadius(Ui.dp(this, 100));
        ubg.setColor(0x00000000);
        ubg.setStroke(Ui.dp(this, 1.2f), Ui.color(this, R.color.primary));
        upd.setBackground(ubg);
        LinearLayout.LayoutParams ulp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        ulp.topMargin = Ui.dp(this, 8);
        upd.setOnClickListener(v -> refreshSub(id));
        right.addView(upd, ulp);

        line.addView(right);
        line.setOnClickListener(v -> openSub(item));
        return line;
    }

    // ---------------------------------------------------------------- 动作

    private void openSub(JSONObject item) {
        final String id = item.optString("id", "");
        if (id.isEmpty()) {
            return;
        }
        Sheet.actions(this, item.optString("name", ""),
                "订阅地址：\n" + item.optString("url", ""),
                new String[]{"更新（约 1 分钟）", "修改名称 / 地址", "删除订阅"},
                index -> {
                    if (index == 0) {
                        refreshSub(id);
                    } else if (index == 1) {
                        editSub(item);
                    } else {
                        deleteSub(item);
                    }
                });
    }

    private void addSub() {
        Sheet.input(this, "添加订阅",
                "保存后会自动更新一次，几十秒后节点就会出现。",
                new String[]{"名称::新订阅", "订阅地址:粘贴订阅链接:"},
                "添加", values -> {
                    String name = values[0].trim();
                    String url = values[1].trim();
                    if (url.isEmpty()) {
                        toast("订阅地址不能为空");
                        return false;
                    }
                    if (!url.startsWith("http://") && !url.startsWith("https://")) {
                        toast("地址要以 http:// 或 https:// 开头");
                        return false;
                    }
                    subAction("add", "", name, url, "添加中…");
                    return true;
                });
    }

    private void editSub(JSONObject item) {
        final String id = item.optString("id", "");
        String name = item.optString("name", "");
        String url = item.optString("url", "");
        Sheet.input(this, "修改订阅",
                "只改想改的那一项，另一项原样保留即可。",
                new String[]{"名称::" + name, "订阅地址::" + url},
                "保存", values -> {
                    String newName = values[0].trim();
                    String newUrl = values[1].trim();
                    if (newName.equals(name) && newUrl.equals(url)) {
                        toast("没有改动");
                        return false;
                    }
                    subAction("update", id, newName, newUrl, "保存中…");
                    return true;
                });
    }

    private void deleteSub(JSONObject item) {
        final String id = item.optString("id", "");
        Sheet.confirm(this, "删除订阅",
                "「" + item.optString("name", "") + "」会从路由器配置里移除。\n\n"
                        + "已经导入的节点不会跟着消失，需要的话在节点列表里单独处理。",
                "删除", true, () -> subAction("delete", id, "", "", "删除中…"));
    }

    private void refreshSub(String id) {
        subAction("refresh", id, "", "", "正在拉取订阅，节点会重新生成…");
    }

    /** 保存之后的自动更新：不弹二次提示，结果看「最近更新」卡 */
    private void refreshQuietly() {
        JSONObject body = new JSONObject();
        try {
            body.put("action", "refresh");
            body.put("backend", backendId);
        } catch (Exception e) {
            return;
        }
        Api.postSlow(this, "/api/v1/proxy/subscriptions", body, new Cb() {
            @Override
            public void onData(JSONObject data, boolean fromCache) {
                if (isFinishing()) {
                    return;
                }
                logPolling = false;
                loadLog();
                scheduleLogPoll();
                handler.postDelayed(SubscriptionActivity.this::load, 60000);
            }
        });
    }

    /** 订阅的增删改走同一个接口，用 action 区分 */
    private void subAction(String action, String id, String name, String url, String hint) {
        JSONObject body = new JSONObject();
        try {
            body.put("action", action);
            body.put("backend", backendId);
            if (!id.isEmpty()) {
                body.put("id", id);
            }
            if (!name.isEmpty()) {
                body.put("name", name);
            }
            if (!url.isEmpty()) {
                body.put("url", url);
            }
        } catch (Exception e) {
            return;
        }
        toast(hint);
        Api.postSlow(this, "/api/v1/proxy/subscriptions", body, new Cb() {
            @Override
            public void onData(JSONObject data, boolean fromCache) {
                if (isFinishing()) {
                    return;
                }
                if (!data.optBoolean("ok", true)) {
                    Sheet.message(SubscriptionActivity.this, "操作失败",
                            data.optString("error", "未知原因"));
                } else if ("refresh".equals(action)) {
                    // 刷新是异步的：接口立刻返回，配置要几十秒后才生成。
                    // 不说明白的话用户以为点空了，或者马上回去看配置发现没变
                    toast("已开始更新，约 20～60 秒后生成配置");
                    logPolling = false;
                    loadLog();
                    scheduleLogPoll();
                    handler.postDelayed(SubscriptionActivity.this::load, 60000);
                } else if ("add".equals(action) || "update".equals(action)) {
                    // 保存后自动更新：新订阅不拉一次，节点列表还是空的
                    toast("已保存，正在更新订阅…");
                    refreshQuietly();
                }
                load();
            }

            @Override
            public void onError(String message) {
                if (!isFinishing()) {
                    Sheet.message(SubscriptionActivity.this, "操作失败", message);
                }
            }
        });
    }

    private void toast(String text) {
        Toast.makeText(this, text, Toast.LENGTH_SHORT).show();
    }
}
