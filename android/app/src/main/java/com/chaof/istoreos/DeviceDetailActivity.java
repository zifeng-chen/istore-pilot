package com.chaof.istoreos;

import android.content.Context;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.InputType;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.Nullable;
import androidx.appcompat.app.AppCompatActivity;

import com.chaof.istoreos.api.Api;
import com.chaof.istoreos.api.Cb;
import com.chaof.istoreos.util.AppIcon;
import com.chaof.istoreos.util.Fmt;
import com.chaof.istoreos.util.Ui;
import com.chaof.istoreos.widget.Sheet;
import com.chaof.istoreos.util.Theme;
import com.google.android.material.appbar.MaterialToolbar;
import com.google.android.material.button.MaterialButton;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;
import com.chaof.istoreos.core.BaseActivity;

/**
 * 设备详情：这台设备是谁、占了多少流量、在访问什么、能对它做什么。
 *
 * 数据里最有价值的是「正在访问的域名」——开了 OpenClash 之后连接跟踪里
 * 全是 fake-ip，只看 IP 等于什么都没说，域名才是用户真正想知道的。
 */
public class DeviceDetailActivity extends BaseActivity {

    private static final long TICK_MS = 3000L;

    private final Handler ticker = new Handler(Looper.getMainLooper());

    private String mac;
    private String title;

    private MaterialToolbar toolbar;
    private LinearLayout headerBox;
    private LinearLayout liveBox;
    private LinearLayout appBox;
    private LinearLayout domainBox;
    private LinearLayout peerBox;
    private LinearLayout limitBox;

    private LinearLayout actionsRow1;
    private LinearLayout actionsRow2;

    private TextView tvName;
    private TextView tvSub;
    private TextView tvState;
    private TextView tvDown;
    private TextView tvUp;
    private TextView tvTotal;
    private TextView tvConns;
    private TextView tvDomainHint;

    private boolean blockedNow = false;
    private boolean staticNow = false;
    private String currentName = "";

    private final Runnable tick = new Runnable() {
        @Override
        public void run() {
            load(true);
            ticker.postDelayed(this, TICK_MS);
        }
    };

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        Theme.apply(this);
        super.onCreate(savedInstanceState);

        mac = getIntent().getStringExtra("mac");
        title = getIntent().getStringExtra("name");
        if (mac == null || mac.isEmpty()) {
            finish();
            return;
        }
        currentName = title == null ? "" : title;

        toolbar = new MaterialToolbar(this);
        toolbar.setTitle(currentName.isEmpty() ? "设备" : currentName);
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

        buildHeader(root);
        buildLive(root);
        buildApps(root);
        buildActions(root);
        buildDomains(root);
        buildPeers(root);
        buildLimits(root);

        scroller.addView(root);

        // 主题是 NoActionBar，工具栏得自己搭；用一层 LinearLayout 兜住，
        // 省掉给内容手动留状态栏和标题栏高度
        LinearLayout page = Ui.column(this);
        page.setBackgroundColor(Ui.color(this, R.color.app_bg));
        page.addView(toolbar, new LinearLayout.LayoutParams(
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

    @Override
    protected void onDestroy() {
        ticker.removeCallbacks(tick);
        super.onDestroy();
    }

    // ---------------------------------------------------------------- 骨架

    private void buildHeader(LinearLayout root) {
        Ui.Card card = Ui.card(this);
        headerBox = Ui.column(this);
        card.addView(headerBox);
        root.addView(card);
    }

    private void buildLive(LinearLayout root) {
        Ui.Card card = Ui.card(this);
        Ui.header(card, "实时流量", "本次统计");

        LinearLayout row = Ui.row(this);
        LinearLayout left = Ui.column(this);
        TextView dl = Ui.text(this, "↓ 下行", 11f, R.color.text_secondary);
        left.addView(dl);
        tvDown = Ui.text(this, "—", 20f, R.color.primary);
        tvDown.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        left.addView(tvDown);

        LinearLayout mid = Ui.column(this);
        TextView ul = Ui.text(this, "↑ 上行", 11f, R.color.text_secondary);
        mid.addView(ul);
        tvUp = Ui.text(this, "—", 20f, R.color.warn);
        tvUp.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        mid.addView(tvUp);

        row.addView(left, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        row.addView(mid, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        card.addView(row);

        card.addView(Ui.divider(this));
        tvTotal = Ui.kv(card, "累计流量", "—");
        tvConns = Ui.kv(card, "活跃连接", "—");

        liveBox = card;
        root.addView(card);
    }

    private void buildApps(LinearLayout root) {
        Ui.Card card = Ui.card(this);
        Ui.header(card, "应用流量", "这台设备用了什么");
        appBox = Ui.column(this);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.topMargin = Ui.dp(this, 6);
        card.addView(appBox, lp);
        root.addView(card);
    }

    private void buildActions(LinearLayout root) {
        Ui.Card card = Ui.card(this);
        Ui.header(card, "管理", "");
        actionsRow1 = actionButton(card);
        actionsRow2 = actionButton(card);
        root.addView(card);
    }

    private LinearLayout actionButton(LinearLayout card) {
        LinearLayout row = Ui.row(this);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.topMargin = Ui.dp(this, 8);
        row.setLayoutParams(lp);
        card.addView(row);
        return row;
    }

    private MaterialButton button(String text, boolean danger) {
        MaterialButton b = new MaterialButton(this);
        b.setText(text);
        b.setTextSize(13f);
        b.setAllCaps(false);
        b.setInsetTop(0);
        b.setInsetBottom(0);
        b.setMinHeight(Ui.dp(this, 40));
        if (danger) {
            b.setTextColor(Ui.color(this, R.color.danger));
        }
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
        lp.rightMargin = Ui.dp(this, 8);
        b.setLayoutParams(lp);
        return b;
    }

    private void buildDomains(LinearLayout root) {
        Ui.Card card = Ui.card(this);
        Ui.header(card, "正在访问", "按流量排序");
        tvDomainHint = Ui.text(this, "—", 12f, R.color.text_secondary);
        tvDomainHint.setPadding(0, Ui.dp(this, 6), 0, 0);
        card.addView(tvDomainHint);
        domainBox = Ui.column(this);
        card.addView(domainBox);
        root.addView(card);
    }

    private void buildPeers(LinearLayout root) {
        Ui.Card card = Ui.card(this);
        Ui.header(card, "连接明细", "对端地址");
        peerBox = Ui.column(this);
        card.addView(peerBox);
        root.addView(card);
    }

    private void buildLimits(LinearLayout root) {
        limitBox = Ui.column(this);
        root.addView(limitBox);
    }

    // ---------------------------------------------------------------- 取数

    private void load(boolean quiet) {
        if (isFinishing() || isDestroyed()) {
            return;
        }
        String path = "/api/v1/devices/detail?mac=" + mac;
        Cb cb = new Cb() {
            @Override
            public void onData(JSONObject body, boolean fromCache) {
                if (isFinishing() || isDestroyed()) {
                    return;
                }
                render(body);
            }

            @Override
            public void onError(String message) {
                if (!quiet && !isFinishing() && !isDestroyed()) {
                    Toast.makeText(DeviceDetailActivity.this, message, Toast.LENGTH_SHORT).show();
                }
            }
        };
        if (quiet) {
            Api.getFresh(this, path, cb);
        } else {
            Api.get(this, path, cb);
        }
    }

    // ---------------------------------------------------------------- 渲染

    private void render(JSONObject body) {
        JSONObject d = body.optJSONObject("device");
        if (d == null) {
            String err = body.optString("error", "读取失败");
            Toast.makeText(this, err, Toast.LENGTH_SHORT).show();
            return;
        }

        blockedNow = d.optBoolean("blocked");
        staticNow = d.optBoolean("static");
        String alias = d.optString("alias");
        String hostname = d.optString("hostname");
        String vendor = d.optString("vendor");
        String ip = d.optString("ip");
        boolean online = d.optBoolean("online");

        String name = d.optString("label");
        if (name.isEmpty()) {
            name = !alias.isEmpty() ? alias : (!hostname.isEmpty() ? hostname : (!vendor.isEmpty() ? vendor : ip));
        }
        currentName = name;
        toolbar.setTitle(name.isEmpty() ? "设备" : name);

        renderHeader(d, name, ip, vendor, hostname, online);
        renderLive(d, body);
        renderApps(body);
        renderActions(name, ip);
        renderDomains(body);
        renderPeers(body);
        renderLimits(body);
    }

    /** 「这台设备到底是谁在吃流量」——按域名归类后的应用明细。 */
    private void renderApps(JSONObject body) {
        if (appBox == null) {
            return;
        }
        appBox.removeAllViews();
        JSONArray arr = body.optJSONArray("apps");
        if (arr == null || arr.length() == 0) {
            TextView tip = Ui.label(this, "还没有可归类的流量。走直连的连接只看得到 IP，认不出是哪个应用。");
            tip.setLineSpacing(Ui.dp(this, 2), 1f);
            tip.setPadding(0, Ui.dp(this, 6), 0, Ui.dp(this, 2));
            appBox.addView(tip);
            return;
        }

        long total = 0;
        for (int i = 0; i < arr.length(); i++) {
            JSONObject a = arr.optJSONObject(i);
            if (a != null) {
                total += a.optLong("total", 0);
            }
        }
        long max = Math.max(1, total);

        for (int i = 0; i < arr.length(); i++) {
            JSONObject a = arr.optJSONObject(i);
            if (a == null) {
                continue;
            }
            if (i > 0) {
                appBox.addView(Ui.divider(this));
            }
            String appName = a.optString("name");
            String category = a.optString("category");
            long bytes = a.optLong("total", 0);

            LinearLayout row = Ui.row(this);
            row.setGravity(Gravity.CENTER_VERTICAL);
            row.setPadding(0, Ui.dp(this, 7), 0, Ui.dp(this, 7));
            row.addView(AppIcon.make(this, appName, category, 36));

            LinearLayout mid = Ui.column(this);
            mid.setPadding(Ui.dp(this, 10), 0, 0, 0);
            TextView title = Ui.text(this, appName, 14.5f, R.color.text_primary);
            title.setSingleLine(true);
            title.setEllipsize(TextUtils.TruncateAt.END);
            mid.addView(title);
            String sub = (category.isEmpty() || "其他".equals(category) ? "" : category + " · ")
                    + "↓ " + Fmt.bytes(a.optLong("down", 0))
                    + "　↑ " + Fmt.bytes(a.optLong("up", 0));
            // 累计值每秒只涨一点点，边看视频也几乎看不出变化 —— 正在跑的应用
            // 直接把此刻的速率顶到副标题最前面，动没动一眼就知道
            double live = a.optDouble("down_bps", 0) + a.optDouble("up_bps", 0);
            if (live >= 1024) {
                sub = "↓ " + Fmt.bps(a.optDouble("down_bps", 0))
                        + "  ↑ " + Fmt.bps(a.optDouble("up_bps", 0))
                        + " · " + sub;
            }
            TextView meta = Ui.text(this, sub, 11.5f, R.color.text_secondary);
            meta.setSingleLine(true);
            meta.setPadding(0, Ui.dp(this, 2), 0, 0);
            mid.addView(meta);
            row.addView(mid, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

            LinearLayout tail = Ui.column(this);
            tail.setGravity(Gravity.END);
            TextView amount = Ui.text(this, Fmt.bytes(bytes), 13.5f, R.color.text_primary);
            amount.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
            amount.setGravity(Gravity.END);
            tail.addView(amount);
            TextView pct = Ui.text(this, Math.round(bytes * 100f / max) + "%", 11f, R.color.text_secondary);
            pct.setGravity(Gravity.END);
            pct.setPadding(0, Ui.dp(this, 2), 0, 0);
            tail.addView(pct);
            row.addView(tail);
            appBox.addView(row);
            appBox.addView(Ui.bar(this, bytes / (float) max, R.color.primary));
        }
    }

    private void renderHeader(JSONObject d, String name, String ip, String vendor,
                              String hostname, boolean online) {
        headerBox.removeAllViews();

        LinearLayout line = Ui.row(this);
        LinearLayout left = Ui.column(this);
        tvName = Ui.text(this, name, 19f, R.color.text_primary);
        tvName.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        left.addView(tvName);

        String sub = ip.isEmpty() ? d.optString("mac") : ip;
        String kind = d.optString("type");
        String model = d.optString("model");
        List<String> who = new ArrayList<>();
        if (!vendor.isEmpty() && !"随机 MAC".equals(vendor) && !name.contains(vendor)) {
            who.add(vendor);
        }
        if (!kind.isEmpty() && !"其他".equals(kind) && !name.contains(kind)) {
            who.add(kind);
        }
        if (!model.isEmpty() && !name.contains(model)) {
            who.add(model);
        }
        // 接入方式是推测值（AP 桥接，上游分不出无线/有线），所以把依据也带上
        String accessText = com.chaof.istoreos.util.Access.describe(d.optJSONObject("access"));
        if (!accessText.isEmpty()) {
            who.add(accessText);
        }
        if (!who.isEmpty()) {
            sub = sub + " · " + TextUtils.join(" ", who);
        }
        tvSub = Ui.text(this, sub, 13f, R.color.text_secondary);
        tvSub.setPadding(0, Ui.dp(this, 3), 0, 0);
        left.addView(tvSub);
        line.addView(left, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        LinearLayout right = Ui.column(this);
        right.setGravity(Gravity.END);
        String stateText;
        int stateColor;
        if (d.optBoolean("blocked")) {
            stateText = "已禁网";
            stateColor = R.color.danger;
        } else if (online) {
            stateText = "在线";
            stateColor = R.color.primary;
        } else {
            stateText = "离线";
            stateColor = R.color.text_secondary;
        }
        right.addView(Ui.pill(this, stateText, stateColor));

        long last = d.optLong("last_seen", -1);
        if (!online && last >= 0) {
            TextView seen = Ui.text(this, last == 0 ? "刚离线" : Fmt.dur(last) + "前", 11f, R.color.text_secondary);
            seen.setGravity(Gravity.END);
            seen.setPadding(0, Ui.dp(this, 4), 0, 0);
            right.addView(seen);
        }
        line.addView(right);
        headerBox.addView(line);

        headerBox.addView(Ui.divider(this));
        Ui.kv(headerBox, "MAC", d.optString("mac"));
        String brand = vendor.isEmpty() ? "—" : vendor;
        Ui.kv(headerBox, "品牌", kind.isEmpty() || "其他".equals(kind) ? brand : brand + " · " + kind);
        if (!model.isEmpty()) {
            Ui.kv(headerBox, "型号", model);
        }
        if (!hostname.isEmpty()) {
            Ui.kv(headerBox, "主机名", hostname);
        }
        JSONObject net = d.optJSONObject("net");
        if (net != null) {
            long all = net.optLong("rx_total", 0) + net.optLong("tx_total", 0);
            long today = net.optLong("rx_today", 0) + net.optLong("tx_today", 0);
            Ui.kv(headerBox, "累计流量", Fmt.bytes(all) + "（今日 " + Fmt.bytes(today) + "）");
        }
        Ui.kv(headerBox, "连接状态", stateLabel(d.optString("state")));

        JSONObject dhcp = d.optJSONObject("dhcp");
        if (dhcp != null) {
            long left2 = dhcp.optLong("lease_left", -1);
            if (dhcp.optBoolean("reserved")) {
                Ui.kv(headerBox, "IP 绑定", "固定为 " + Fmt.orDash(dhcp.optString("reserved_ip")));
            } else if (left2 > 0 && dhcp.has("lease_left") && !dhcp.isNull("lease_left")) {
                Ui.kv(headerBox, "租约剩余", Fmt.dur(left2));
            } else {
                Ui.kv(headerBox, "IP 绑定", "动态分配");
            }
        }
    }

    private static String stateLabel(String state) {
        switch (state == null ? "" : state) {
            case "ACTIVE":
                // 邻居表没验证到，但连接跟踪里有它的活跃连接——
                // iPhone 锁屏后不回 ARP，条目会一直是 STALE，但网并没断
                return "在线，正在传输数据";
            case "REACHABLE":
                return "在线，近期有通信";
            case "DELAY":
            case "PROBE":
                return "在线，正在确认";
            case "STALE":
                return "缓存有效，暂无流量";
            case "FAILED":
            case "INCOMPLETE":
                return "不可达";
            case "":
                return "—";
            default:
                return state;
        }
    }

    private void renderLive(JSONObject d, JSONObject body) {
        JSONObject net = d.optJSONObject("net");
        double down = net == null ? 0 : net.optDouble("rx_bps", 0);
        double up = net == null ? 0 : net.optDouble("tx_bps", 0);
        tvDown.setText(down < 1 ? "0" : Fmt.bps(down));
        tvUp.setText(up < 1 ? "0" : Fmt.bps(up));

        long rxTotal = net == null ? 0 : net.optLong("rx_total", 0);
        long txTotal = net == null ? 0 : net.optLong("tx_total", 0);
        tvTotal.setText("↓ " + Fmt.bytes(rxTotal) + "　↑ " + Fmt.bytes(txTotal));
        tvConns.setText(body.optInt("conns", 0) + " 条");
    }

    private void renderActions(String name, String ip) {
        actionsRow1.removeAllViews();
        actionsRow2.removeAllViews();

        MaterialButton rename = button("改备注", false);
        rename.setOnClickListener(v -> askRename(name));
        actionsRow1.addView(rename);

        MaterialButton blockBtn = button(blockedNow ? "恢复上网" : "禁止上网", true);
        blockBtn.setOnClickListener(v -> askBlock());
        actionsRow1.addView(blockBtn);

        MaterialButton bind = button(staticNow ? "解除绑定" : "固定 IP", false);
        bind.setOnClickListener(v -> askBind(ip));
        actionsRow2.addView(bind);

        MaterialButton wake = button("网络唤醒", false);
        wake.setOnClickListener(v -> doWol());
        actionsRow2.addView(wake);
    }

    private void renderDomains(JSONObject body) {
        domainBox.removeAllViews();
        JSONArray arr = body.optJSONArray("domains");
        String source = body.optString("domains_source", "none");

        if (arr == null || arr.length() == 0) {
            tvDomainHint.setVisibility(View.VISIBLE);
            if ("unavailable".equals(source)) {
                tvDomainHint.setText("代理未运行或当前用 Passwall（没有运行时接口），拿不到域名，只能看 IP");
            } else {
                tvDomainHint.setText("当前没有活跃的外网连接");
            }
            return;
        }
        tvDomainHint.setVisibility(View.GONE);

        for (int i = 0; i < arr.length(); i++) {
            JSONObject o = arr.optJSONObject(i);
            if (o == null) {
                continue;
            }
            domainBox.addView(domainRow(o));
        }
    }

    private View domainRow(JSONObject o) {
        LinearLayout line = Ui.row(this);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.topMargin = Ui.dp(this, 8);
        line.setLayoutParams(lp);

        LinearLayout left = Ui.column(this);
        TextView host = Ui.text(this, o.optString("host"), 13.5f, R.color.text_primary);
        host.setSingleLine(true);
        host.setEllipsize(TextUtils.TruncateAt.MIDDLE);
        left.addView(host);

        String chain = o.optString("chain");
        String rule = o.optString("rule");
        StringBuilder sub = new StringBuilder();
        if (!rule.isEmpty()) {
            sub.append(rule);
        }
        if (!chain.isEmpty()) {
            if (sub.length() > 0) {
                sub.append(" · ");
            }
            sub.append(chain);
        }
        if (sub.length() > 0) {
            TextView meta = Ui.text(this, sub.toString(), 11f, R.color.text_secondary);
            meta.setSingleLine(true);
            meta.setEllipsize(TextUtils.TruncateAt.END);
            meta.setPadding(0, Ui.dp(this, 2), 0, 0);
            left.addView(meta);
        }
        line.addView(left, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        long down = o.optLong("down", 0);
        long up = o.optLong("up", 0);
        TextView bytes = Ui.text(this, "↓" + Fmt.bytes(down) + " ↑" + Fmt.bytes(up), 11f, R.color.text_secondary);
        bytes.setGravity(Gravity.END);
        line.addView(bytes);

        return line;
    }

    private void renderPeers(JSONObject body) {
        peerBox.removeAllViews();
        JSONArray arr = body.optJSONArray("peers");
        if (arr == null || arr.length() == 0) {
            TextView hint = Ui.text(this, "没有活跃连接", 12f, R.color.text_secondary);
            hint.setPadding(0, Ui.dp(this, 6), 0, 0);
            peerBox.addView(hint);
            return;
        }

        for (int i = 0; i < arr.length(); i++) {
            JSONObject o = arr.optJSONObject(i);
            if (o == null) {
                continue;
            }
            LinearLayout line = Ui.row(this);
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            lp.topMargin = Ui.dp(this, 7);
            line.setLayoutParams(lp);

            String arrow = o.optBoolean("outbound") ? "↑" : "↓";
            TextView dir = Ui.text(this, arrow, 12f, o.optBoolean("outbound") ? R.color.warn : R.color.primary);
            dir.setPadding(0, 0, Ui.dp(this, 6), 0);
            line.addView(dir);

            LinearLayout left = Ui.column(this);
            String addr = o.optString("ip") + ":" + o.optInt("port");
            TextView ipv = Ui.text(this, addr, 12.5f, R.color.text_primary);
            ipv.setSingleLine(true);
            ipv.setEllipsize(TextUtils.TruncateAt.MIDDLE);
            left.addView(ipv);

            String svc = o.optString("service");
            String proto = o.optString("proto").toUpperCase();
            String meta = svc.isEmpty() ? proto : proto + " · " + svc;
            TextView sm = Ui.text(this, meta, 10.5f, R.color.text_secondary);
            left.addView(sm);
            line.addView(left, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

            long total = o.optLong("up", 0) + o.optLong("down", 0);
            TextView sz = Ui.text(this, Fmt.bytes(total), 11f, R.color.text_secondary);
            sz.setGravity(Gravity.END);
            line.addView(sz);

            peerBox.addView(line);
        }
    }

    private void renderLimits(JSONObject body) {
        limitBox.removeAllViews();
        JSONObject caps = body.optJSONObject("capabilities");
        if (caps == null) {
            return;
        }
        JSONObject limits = body.optJSONObject("limits");
        StringBuilder sb = new StringBuilder();
        if (limits != null) {
            if (!caps.optBoolean("wifi_signal", true)) {
                sb.append("· 这台路由器没有无线网卡，看不到信号强度\n");
            }
            if (!caps.optBoolean("bandwidth_limit", true)) {
                sb.append("· 系统里没有 tc 命令，无法给设备限速\n");
            }
            if (!caps.optBoolean("kick", true)) {
                sb.append("· 没有 conntrack 工具，禁网只对新建连接立即生效，已建立的连接要等自然超时\n");
            }
        }
        if (sb.length() == 0) {
            return;
        }
        TextView t = Ui.text(this, sb.toString().trim(), 11f, R.color.text_secondary);
        t.setLineSpacing(Ui.dp(this, 3), 1f);
        t.setPadding(Ui.dp(this, 4), Ui.dp(this, 8), Ui.dp(this, 4), 0);
        limitBox.addView(t);
    }

    // ---------------------------------------------------------------- 操作

    private void askRename(String current) {
        Sheet.input(this, "给设备起个名字", "起个一眼能认出来的名字，比如「客厅电视」。留空则恢复自动识别。",
                new String[]{"名称:比如：客厅电视:" + (current == null ? "" : current)},
                "保存", values -> {
                    post("/api/v1/devices/rename",
                            json("mac", mac, "alias", values[0]), "名称已更新");
                    return true;
                });
    }

    private void askBlock() {
        boolean enable = !blockedNow;
        String message = enable
                ? "这台设备将无法访问外网，局域网内仍然可以互相访问。\n\n"
                  + "已建立的连接要等自然超时才会断，通常 1-2 分钟。"
                : "恢复这台设备的外网访问。";
        Sheet.confirm(this, enable ? "禁止上网" : "恢复上网", message,
                enable ? "禁止" : "恢复", enable, () ->
                        post("/api/v1/devices/block", bool("mac", mac, "enabled", enable),
                                enable ? "已禁止上网" : "已恢复上网"));
    }

    private void askBind(String ip) {
        if (staticNow) {
            Sheet.confirm(this, "解除 IP 绑定",
                    "解除后，这台设备下次获取的地址可能变化。", "解除", false, () ->
                            post("/api/v1/devices/unbind", json("mac", mac), "已解除绑定"));
            return;
        }
        if (ip == null || ip.isEmpty()) {
            Toast.makeText(this, "这台设备没有 IP，无法绑定", Toast.LENGTH_SHORT).show();
            return;
        }
        Sheet.confirm(this, "固定 IP",
                "把 " + ip + " 固定给这台设备，以后重启路由器也不会变。\n\n"
                        + "只重载 DHCP，不会断开当前连接。", "固定", false, () ->
                        post("/api/v1/devices/bind", json("mac", mac, "ip", ip), "已绑定 " + ip));
    }

    private void doWol() {
        Sheet.confirm(this, "网络唤醒",
                "向这台设备发送开机指令。\n\n"
                        + "需要设备本身支持网络唤醒，并且关机时网卡仍在通电。",
                "发送", false, () ->
                        post("/api/v1/devices/wol", json("mac", mac), "开机指令已发送"));
    }

    private void post(String path, JSONObject body, String okText) {
        Api.post(this, path, body, new Cb() {
            @Override
            public void onData(JSONObject data, boolean fromCache) {
                boolean ok = data.optBoolean("ok", false);
                String warning = data.optString("warning", "");
                String error = data.optString("error", "");
                if (!ok) {
                    Toast.makeText(DeviceDetailActivity.this, error.isEmpty() ? "操作失败" : error,
                            Toast.LENGTH_LONG).show();
                    return;
                }
                Toast.makeText(DeviceDetailActivity.this,
                        warning.isEmpty() ? okText : okText + "（" + warning + "）",
                        Toast.LENGTH_LONG).show();
                load(false);
            }

            @Override
            public void onError(String message) {
                Toast.makeText(DeviceDetailActivity.this, message, Toast.LENGTH_LONG).show();
            }
        });
    }

    private static JSONObject json(String k1, String v1, String k2, String v2) {
        try {
            JSONObject o = new JSONObject();
            o.put(k1, v1);
            o.put(k2, v2);
            return o;
        } catch (Exception e) {
            return new JSONObject();
        }
    }

    private static JSONObject json(String k, String v) {
        try {
            JSONObject o = new JSONObject();
            o.put(k, v);
            return o;
        } catch (Exception e) {
            return new JSONObject();
        }
    }

    private static JSONObject bool(String k1, String v1, String k2, boolean v2) {
        try {
            JSONObject o = new JSONObject();
            o.put(k1, v1);
            o.put(k2, v2);
            return o;
        } catch (Exception e) {
            return new JSONObject();
        }
    }
}
