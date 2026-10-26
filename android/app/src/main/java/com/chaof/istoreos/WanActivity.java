package com.chaof.istoreos;

import android.content.Context;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.Nullable;
import androidx.appcompat.app.AppCompatActivity;

import com.chaof.istoreos.api.Api;
import com.chaof.istoreos.api.Cb;
import com.chaof.istoreos.util.Fmt;
import com.chaof.istoreos.util.Theme;
import com.chaof.istoreos.util.Ui;
import com.chaof.istoreos.widget.Sheet;
import com.google.android.material.appbar.MaterialToolbar;

import org.json.JSONArray;
import org.json.JSONObject;
import com.chaof.istoreos.core.BaseActivity;

/**
 * 网络配置：WAN 接入方式（PPPoE / DHCP / 静态 IP）。
 *
 * 这是唯一会「改坏就断网」的页面，所以界面本身要承担告知义务：
 *  - 顶部先说清「现在是怎么上网的、拨通了没有、拿到什么 IP」
 *  - 保存前弹确认，明确写出「会断线 10-30 秒」「90 秒不通用自动回滚」
 *  - 保存后进入「等待重拨」状态，每 2 秒轮询一次，通了就变绿，不用用户自己猜
 *
 * 密码框留空表示不修改：后端拿到空串会沿用原密码，
 * 这样用户只想改账号时不用重新输一遍密码，也避免把掩码写进配置。
 */
public class WanActivity extends BaseActivity {

    private static final long POLL_MS = 2500L;

    private final Handler ticker = new Handler(Looper.getMainLooper());

    private TextView tvState;
    private TextView tvIp;
    private TextView tvProtoNow;
    private View stateDot;

    private LinearLayout formBox;
    private LinearLayout lanBox;
    private LinearLayout statusBox;

    private EditText inUser;
    private EditText inPass;
    private EditText inIp;
    private EditText inMask;
    private EditText inGw;
    private EditText inDns;
    private EditText inMtu;

    private LinearLayout segHost;
    private String proto = "pppoe";
    private boolean waiting = false;
    private long waitSince = 0;

    private final Runnable poll = new Runnable() {
        @Override
        public void run() {
            load(true);
            if (waiting) {
                ticker.postDelayed(this, POLL_MS);
            }
        }
    };

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        Theme.apply(this);
        super.onCreate(savedInstanceState);

        MaterialToolbar toolbar = new MaterialToolbar(this);
        toolbar.setTitle("网络");
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

        buildState(root);
        buildProto(root);
        buildForm(root);
        buildLan(root);

        TextView save = Ui.filled(this, "保存并重拨", R.color.primary, R.color.on_primary);
        save.setOnClickListener(v -> askSave());
        LinearLayout.LayoutParams slp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        slp.topMargin = Ui.dp(this, 4);
        slp.bottomMargin = Ui.dp(this, 8);
        save.setLayoutParams(slp);
        root.addView(save);

        TextView warn = Ui.text(this,
                "改完会自动重拨。如果 90 秒内上不了网，路由器会自动还原成现在的配置，"
                        + "不会留下连不上的状态。",
                11.5f, R.color.text_secondary);
        warn.setLineSpacing(Ui.dp(this, 2), 1f);
        warn.setPadding(Ui.dp(this, 6), 0, Ui.dp(this, 6), 0);
        root.addView(warn);

        scroller.addView(root);

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
        ticker.removeCallbacks(poll);
        ticker.postDelayed(poll, POLL_MS);
    }

    @Override
    protected void onPause() {
        super.onPause();
        ticker.removeCallbacks(poll);
    }

    // ---------------------------------------------------------------- 骨架

    /** 顶部状态卡：现在通不通、怎么通的、拿到什么 IP */
    private void buildState(LinearLayout root) {
        Ui.Card card = Ui.gradient(this, R.color.hero_from, R.color.hero_to);

        LinearLayout top = Ui.row(this);
        stateDot = new View(this);
        android.graphics.drawable.GradientDrawable dot =
                new android.graphics.drawable.GradientDrawable();
        dot.setShape(android.graphics.drawable.GradientDrawable.OVAL);
        dot.setColor(Ui.alpha(Ui.color(this, R.color.hero_fg), 0.55f));
        stateDot.setBackground(dot);
        LinearLayout.LayoutParams dlp = new LinearLayout.LayoutParams(
                Ui.dp(this, 8), Ui.dp(this, 8));
        dlp.rightMargin = Ui.dp(this, 7);
        top.addView(stateDot, dlp);

        tvState = Ui.heroNote(this, "读取中", 1.0f);
        tvState.setTextSize(13f);
        top.addView(tvState, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        tvProtoNow = Ui.heroNote(this, "—", 0.9f);
        tvProtoNow.setTextSize(11.5f);
        tvProtoNow.setPadding(Ui.dp(this, 10), Ui.dp(this, 4), Ui.dp(this, 10), Ui.dp(this, 4));
        android.graphics.drawable.GradientDrawable chip =
                new android.graphics.drawable.GradientDrawable();
        chip.setCornerRadius(Ui.dp(this, 100));
        chip.setColor(Ui.alpha(Ui.color(this, R.color.hero_fg), 0.16f));
        tvProtoNow.setBackground(chip);
        top.addView(tvProtoNow);
        card.addView(top);

        tvIp = Ui.heroNumber(this, "—");
        tvIp.setTextSize(28f);
        tvIp.setLetterSpacing(0f);
        tvIp.setPadding(0, Ui.dp(this, 14), 0, 0);
        card.addView(tvIp);

        TextView label = Ui.heroNote(this, "WAN 地址", 0.86f);
        label.setPadding(0, Ui.dp(this, 4), 0, 0);
        card.addView(label);

        View hair = new View(this);
        hair.setBackgroundColor(Ui.alpha(Ui.color(this, R.color.hero_fg), 0.18f));
        LinearLayout.LayoutParams hlp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, Math.max(1, Ui.dp(this, 0.7f)));
        hlp.topMargin = Ui.dp(this, 14);
        card.addView(hair, hlp);

        statusBox = Ui.column(this);
        statusBox.setPadding(0, Ui.dp(this, 12), 0, 0);
        card.addView(statusBox);

        root.addView(card);
    }

    /** 接入方式：分段控件，切换后重画表单 */
    private void buildProto(LinearLayout root) {
        Ui.Card card = Ui.card(this);
        Ui.header(card, "接入方式", "现在是 PPPoE 拨号");
        segHost = Ui.column(this);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.topMargin = Ui.dp(this, 12);
        segHost.setLayoutParams(lp);
        card.addView(segHost);
        root.addView(card);
    }

    /** 表单：字段随接入方式变化 */
    private void buildForm(LinearLayout root) {
        Ui.Card card = Ui.card(this);
        Ui.header(card, "参数", "");
        formBox = Ui.column(this);
        formBox.setLayoutParams(new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        card.addView(formBox);
        root.addView(card);
    }

    private void buildLan(LinearLayout root) {
        Ui.Card card = Ui.card(this);
        Ui.header(card, "局域网", "");
        lanBox = Ui.column(this);
        lanBox.setLayoutParams(new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        card.addView(lanBox);
        root.addView(card);
    }

    // ---------------------------------------------------------------- 数据

    private void load(boolean quiet) {
        Api.get(this, "/api/v1/network/wan", new Cb() {
            @Override
            public void onData(JSONObject body, boolean fromCache) {
                if (isFinishing()) {
                    return;
                }
                render(body);
            }

            @Override
            public void onError(String message) {
                if (isFinishing()) {
                    return;
                }
                // 重拨期间连不上是预期内的，别弹错误吓人
                if (waiting) {
                    tvState.setText("正在重拨，等待网络恢复…");
                } else {
                    tvState.setText("读取失败：" + message);
                }
            }
        });
    }

    private void render(JSONObject b) {
        JSONObject cfg = b.optJSONObject("config");
        JSONObject st = b.optJSONObject("status");
        JSONObject lan = b.optJSONObject("lan");

        boolean up = st != null && st.optBoolean("up", false);
        String ip = st == null ? "" : st.optString("ipv4", "");
        String protoLabel = cfg == null ? "" : cfg.optString("proto_label", "");

        // 状态点与文案
        int color = up ? R.color.hero_fg : R.color.warn;
        android.graphics.drawable.GradientDrawable dot =
                new android.graphics.drawable.GradientDrawable();
        dot.setShape(android.graphics.drawable.GradientDrawable.OVAL);
        dot.setColor(Ui.color(this, color));
        stateDot.setBackground(dot);

        if (waiting) {
            long elapsed = (System.currentTimeMillis() - waitSince) / 1000;
            if (up) {
                waiting = false;
                ticker.removeCallbacks(poll);
                tvState.setText("已拨通，网络已恢复");
                Toast.makeText(this, "网络已恢复", Toast.LENGTH_SHORT).show();
            } else if (elapsed > 95) {
                waiting = false;
                ticker.removeCallbacks(poll);
                tvState.setText("重拨超时，可能已自动回滚");
            } else {
                tvState.setText("正在重拨… 已等待 " + elapsed + " 秒");
            }
        } else {
            tvState.setText(up ? "已连接" : (st == null ? "未知"
                    : Fmt.orDash(st.optString("note", "未连接"))));
        }

        tvProtoNow.setText(protoLabel.isEmpty() ? "—" : protoLabel);
        tvIp.setText(ip.isEmpty() ? "—" : ip);

        // 状态明细
        statusBox.removeAllViews();
        if (st != null) {
            if (!ip.isEmpty()) {
                heroLine("网关", st.optString("gateway", "—"), up);
                heroLine("拨号时长", Fmt.dur(st.optLong("uptime", 0)), up);
                JSONArray dns = st.optJSONArray("dns");
                if (dns != null && dns.length() > 0) {
                    StringBuilder sb = new StringBuilder();
                    for (int i = 0; i < dns.length(); i++) {
                        if (i > 0) {
                            sb.append("　");
                        }
                        sb.append(dns.optString(i, ""));
                    }
                    heroLine("运营商 DNS", sb.toString(), up);
                }
                JSONArray v6 = st.optJSONArray("ipv6");
                if (v6 != null && v6.length() > 0) {
                    heroLine("IPv6", v6.optString(0, ""), up);
                }
            } else {
                TextView t = Ui.heroNote(this,
                        "还没有拿到地址。如果是刚保存的配置，重拨需要 10-30 秒；"
                                + "超过 90 秒仍不行会自动还原。", 0.8f);
                t.setLineSpacing(Ui.dp(this, 2), 1f);
                statusBox.addView(t);
            }
        }

        // 表单只在首次或配置真的变了之后重建，否则每次轮询都会清掉用户正在输入的内容
        String sig = cfg == null ? "" : cfg.toString();
        if (!sig.equals(formSig)) {
            formSig = sig;
            rebuildForm(cfg);
        }
        renderLan(lan);
    }

    private String formSig = "";

    private void heroLine(String key, String value, boolean bright) {
        LinearLayout line = Ui.row(this);
        line.setPadding(0, Ui.dp(this, 4), 0, Ui.dp(this, 4));
        TextView k = Ui.heroNote(this, key, 0.86f);
        k.setTextSize(12.5f);
        line.addView(k, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        TextView v = Ui.heroNote(this, value, bright ? 1.0f : 0.86f);
        v.setTextSize(12.5f);
        v.setGravity(Gravity.END);
        line.addView(v);
        statusBox.addView(line);
    }

    private void rebuildForm(JSONObject cfg) {
        if (formBox == null) {
            return;
        }
        formBox.removeAllViews();
        if (cfg == null) {
            return;
        }
        proto = cfg.optString("proto", "pppoe");
        buildSegment(cfg);

        if ("pppoe".equals(proto)) {
            inUser = Ui.inputRow(formBox, "宽带账号",
                    cfg.optString("username", ""), "手机号或宽带账号", false);
            inPass = Ui.inputRow(formBox, "宽带密码",
                    "", cfg.optBoolean("password_set", false)
                            ? "留空则保持原密码" : "请输入宽带密码", true);
            inIp = null;
            inMask = null;
            inGw = null;
        } else if ("static".equals(proto)) {
            inUser = null;
            inPass = null;
            inIp = Ui.inputRow(formBox, "IP 地址", cfg.optString("ipaddr", ""), "192.168.1.2", false);
            inMask = Ui.inputRow(formBox, "子网掩码",
                    cfg.optString("netmask", "255.255.255.0"), "255.255.255.0", false);
            inGw = Ui.inputRow(formBox, "网关", cfg.optString("gateway", ""), "192.168.1.1", false);
        } else {
            inUser = null;
            inPass = null;
            inIp = null;
            inMask = null;
            inGw = null;
            TextView tip = Ui.text(this, "自动从光猫或上级路由获取地址，不需要填参数。",
                    13f, R.color.text_secondary);
            tip.setPadding(0, Ui.dp(this, 12), 0, Ui.dp(this, 6));
            formBox.addView(tip);
        }

        // 高级项：DNS / MTU
        JSONArray dns = cfg.optJSONArray("dns");
        StringBuilder dnsText = new StringBuilder();
        if (dns != null) {
            for (int i = 0; i < dns.length(); i++) {
                if (i > 0) {
                    dnsText.append(" ");
                }
                dnsText.append(dns.optString(i, ""));
            }
        }
        inDns = Ui.inputRow(formBox, "DNS", dnsText.toString(),
                cfg.optBoolean("peerdns", true) ? "留空用运营商下发" : "例如 223.5.5.5", false);
        inMtu = Ui.inputRow(formBox, "MTU", cfg.optString("mtu", ""), "留空用默认 1492", false);
    }

    private void buildSegment(JSONObject cfg) {
        segHost.removeAllViews();
        JSONArray protos = cfg.optJSONArray("protos");
        if (protos == null || protos.length() == 0) {
            return;
        }
        String[] labels = new String[protos.length()];
        final String[] keys = new String[protos.length()];
        int selected = 0;
        for (int i = 0; i < protos.length(); i++) {
            JSONObject o = protos.optJSONObject(i);
            labels[i] = o == null ? "" : o.optString("label", "");
            keys[i] = o == null ? "" : o.optString("key", "");
            if (keys[i].equals(proto)) {
                selected = i;
            }
        }
        segHost.addView(Ui.segmented(this, labels, selected, index -> {
            if (keys[index].equals(proto)) {
                return;
            }
            proto = keys[index];
            // 本地先切一次表单，用户能立刻看到字段变化；保存时以当前选择为准
            JSONObject fake = new JSONObject();
            try {
                fake.put("proto", proto);
                fake.put("username", cfg.optString("username", ""));
                fake.put("password_set", cfg.optBoolean("password_set", false));
                fake.put("protos", protos);
                fake.put("dns", cfg.optJSONArray("dns"));
                fake.put("peerdns", cfg.optBoolean("peerdns", true));
            } catch (Exception ignored) {
                // ignore
            }
            rebuildForm(fake);
        }));
    }

    private void renderLan(JSONObject lan) {
        if (lanBox == null) {
            return;
        }
        lanBox.removeAllViews();
        if (lan == null) {
            return;
        }
        Ui.kv(lanBox, "路由器地址", lan.optString("ipaddr", "—"));
        Ui.kv(lanBox, "子网掩码", lan.optString("netmask", "—"));
        String start = lan.optString("dhcp_start", "");
        String limit = lan.optString("dhcp_limit", "");
        if (!start.isEmpty()) {
            Ui.kv(lanBox, "DHCP 地址池", ".100 起，共 " + limit + " 个");
        }
        TextView note = Ui.text(this, lan.optString("note", ""), 11.5f, R.color.text_secondary);
        note.setLineSpacing(Ui.dp(this, 2), 1f);
        note.setPadding(0, Ui.dp(this, 10), 0, 0);
        lanBox.addView(note);
    }

    // ---------------------------------------------------------------- 保存

    private void askSave() {
        if (waiting) {
            Toast.makeText(this, "上一次重拨还没结束", Toast.LENGTH_SHORT).show();
            return;
        }
        String tip;
        if ("pppoe".equals(proto)) {
            if (inUser == null || inUser.getText().toString().trim().isEmpty()) {
                Toast.makeText(this, "请填写宽带账号", Toast.LENGTH_SHORT).show();
                return;
            }
            tip = "将改为 PPPoE 拨号，账号 " + inUser.getText().toString().trim() + "。";
        } else if ("static".equals(proto)) {
            if (inIp == null || inIp.getText().toString().trim().isEmpty()) {
                Toast.makeText(this, "请填写 IP 地址", Toast.LENGTH_SHORT).show();
                return;
            }
            tip = "将改为静态 IP。";
        } else {
            tip = "将改为自动获取（DHCP）。";
        }

        Sheet.confirm(this, "保存并重拨？",
                tip + "\n\n保存后会立即重拨，全家断网 10-30 秒。"
                        + "90 秒内上不了网会自动还原成现在的配置。",
                "保存并重拨", false, this::save);
    }

    private void save() {
        JSONObject body = new JSONObject();
        try {
            body.put("proto", proto);
            if ("pppoe".equals(proto)) {
                body.put("username", inUser == null ? "" : inUser.getText().toString().trim());
                body.put("password", inPass == null ? "" : inPass.getText().toString());
            } else if ("static".equals(proto)) {
                body.put("ipaddr", inIp == null ? "" : inIp.getText().toString().trim());
                body.put("netmask", inMask == null ? "" : inMask.getText().toString().trim());
                body.put("gateway", inGw == null ? "" : inGw.getText().toString().trim());
            }
            String dnsRaw = inDns == null ? "" : inDns.getText().toString().trim();
            if (!dnsRaw.isEmpty()) {
                JSONArray arr = new JSONArray();
                for (String d : dnsRaw.split("[\\s,;]+")) {
                    if (!d.isEmpty()) {
                        arr.put(d);
                    }
                }
                body.put("dns", arr);
                body.put("peerdns", false);
            }
            String mtu = inMtu == null ? "" : inMtu.getText().toString().trim();
            if (!mtu.isEmpty()) {
                body.put("mtu", mtu);
            }
        } catch (Exception ignored) {
            return;
        }

        Api.post(this, "/api/v1/network/wan", body, new Cb() {
            @Override
            public void onData(JSONObject data, boolean fromCache) {
                if (isFinishing()) {
                    return;
                }
                if (data.optBoolean("ok", false)) {
                    waiting = true;
                    waitSince = System.currentTimeMillis();
                    tvState.setText("正在重拨…");
                    ticker.removeCallbacks(poll);
                    ticker.postDelayed(poll, POLL_MS);
                    Sheet.message(WanActivity.this, "已开始重拨",
                            data.optString("detail", "网络会在 10-30 秒内恢复。"));
                } else {
                    Sheet.message(WanActivity.this, "保存失败",
                            data.optString("error", "未知错误，配置未修改"));
                }
            }

            @Override
            public void onError(String message) {
                if (!isFinishing()) {
                    Sheet.message(WanActivity.this, "保存失败", message + "\n\n配置未修改。");
                }
            }
        });
    }
}
