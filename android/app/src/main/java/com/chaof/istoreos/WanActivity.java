package com.chaof.istoreos;

import android.content.Context;
import android.content.Intent;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
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

import com.chaof.istoreos.api.Api;
import com.chaof.istoreos.api.Cb;
import com.chaof.istoreos.core.BaseActivity;
import com.chaof.istoreos.core.Session;
import com.chaof.istoreos.util.Fmt;
import com.chaof.istoreos.util.Theme;
import com.chaof.istoreos.util.Ui;
import com.chaof.istoreos.widget.Glyph;
import com.chaof.istoreos.widget.Hero;
import com.chaof.istoreos.widget.Sheet;
import com.google.android.material.appbar.MaterialToolbar;

import org.json.JSONArray;
import org.json.JSONObject;

/**
 * 网络设置（概览 →「配置网络」进来）。
 *
 * 这一版把原来独立的「网络」页签整个搬了进来。理由：
 * 那个页签里有大半是只读信息（局域网现状、防火墙摘要、风险提示），
 * 用户看完就走，为它占一个底部入口不值；真正要动手的只有两件事 ——
 * 改宽带参数、重拨。既然动作都在这里，信息也跟着在这里，才不用来回跳。
 *
 * 页面顺序按「手会去点的地方」排：
 *   1. 结论（Hero）：通不通、什么接入方式、拿到什么地址
 *   2. 连接操作：重拨 / 断开（不动配置，随便点）
 *   3. 接入方式 + 参数 + 保存并重拨（会断线，所以放最后并带确认）
 *   4. 只读：局域网现状、防火墙摘要、风险
 *   5. 出口：改网段、静态路由这些还是去网页端
 *
 * 密码框留空表示不修改：后端拿到空串会沿用原密码，
 * 这样用户只想改账号时不用重新输一遍密码，也避免把掩码写进配置。
 */
public class WanActivity extends BaseActivity {

    private static final long POLL_MS = 2500L;

    private final Handler ticker = new Handler(Looper.getMainLooper());

    // hero
    private Hero hero;
    private TextView tvStatGw;
    private TextView tvStatUp;

    // 连接操作
    private TextView tvActionNote;
    private TextView btnToggle;
    private boolean wanUp = false;

    private LinearLayout formBox;
    private LinearLayout lanBox;
    private LinearLayout fwBox;
    private LinearLayout riskBox;
    private Ui.Card riskCard;
    private TextView tvRiskTitle;

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
    private String formSig = "";

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

        buildHero(root);
        buildActions(root);
        buildProto(root);
        buildForm(root);
        buildSave(root);
        buildLan(root);
        buildFirewall(root);
        buildWeb(root);

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

    /** 顶部结论：通不通、怎么通的、拿到什么地址、三个短指标 */
    private void buildHero(LinearLayout root) {
        hero = new Hero(this);
        root.addView(hero);
        // 只放两个指标：IPv6 在 wan6 接口上，这个接口看不到，
        // 硬塞一格写「无」等于告诉用户「没有 IPv6」，是假信息
        TextView[] stats = hero.stats("网关", "在线");
        tvStatGw = stats[0];
        tvStatUp = stats[1];
    }

    /**
     * 连接操作：重拨 / 断开。
     *
     * 和「保存并重拨」的区别写在副标题里：这两个不动配置，
     * 所以不需要确认弹窗里的那套回滚吓唬话 —— 手滑点错了再点回来就行。
     */
    private void buildActions(LinearLayout root) {
        Context c = this;
        Ui.Card card = Ui.card(c);
        card.setPadding(0, Ui.dp(c, 16), 0, Ui.dp(c, 14));
        Ui.cardTitle(c, card, Glyph.BOLT, "连接操作", "只动链路，不改配置");

        LinearLayout row = Ui.row(c);
        row.setPadding(Ui.dp(c, 16), Ui.dp(c, 14), Ui.dp(c, 16), 0);

        TextView redial = Ui.filled(c, "重拨", R.color.primary, R.color.on_primary);
        redial.setOnClickListener(v -> askAction("reconnect"));
        row.addView(redial, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        btnToggle = Ui.text(c, "断开", 15f, R.color.text_primary);
        btnToggle.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        btnToggle.setGravity(Gravity.CENTER);
        btnToggle.setPadding(0, Ui.dp(c, 11), 0, Ui.dp(c, 11));
        GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(Ui.dp(c, 100));
        bg.setColor(Ui.color(c, R.color.surface_sunken));
        btnToggle.setBackground(bg);
        btnToggle.setOnClickListener(v -> askAction(wanUp ? "down" : "up"));
        LinearLayout.LayoutParams tlp = new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
        tlp.leftMargin = Ui.dp(c, 10);
        row.addView(btnToggle, tlp);

        card.addView(row);

        tvActionNote = Ui.text(c, "重拨只重建链路，不改配置；断开后点「连接」即可恢复。",
                11.5f, R.color.text_secondary);
        tvActionNote.setPadding(Ui.dp(c, 16), Ui.dp(c, 10), Ui.dp(c, 16), 0);
        tvActionNote.setLineSpacing(Ui.dp(c, 2), 1f);
        card.addView(tvActionNote);
        root.addView(card);
    }

    /** 接入方式：分段控件，切换后重画表单 */
    private void buildProto(LinearLayout root) {
        Ui.Card card = Ui.card(this);
        card.setPadding(0, Ui.dp(this, 16), 0, Ui.dp(this, 14));
        Ui.cardTitle(this, card, Glyph.GLOBE, "接入方式", "改这里会重拨");
        segHost = Ui.column(this);
        segHost.setPadding(Ui.dp(this, 16), 0, Ui.dp(this, 16), 0);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.topMargin = Ui.dp(this, 12);
        card.addView(segHost, lp);
        root.addView(card);
    }

    /** 表单：字段随接入方式变化 */
    private void buildForm(LinearLayout root) {
        Ui.Card card = Ui.card(this);
        card.setPadding(0, Ui.dp(this, 16), 0, Ui.dp(this, 10));
        Ui.cardTitle(this, card, Glyph.KEY, "参数", "密码留空表示不修改");
        formBox = Ui.column(this);
        formBox.setPadding(Ui.dp(this, 16), 0, Ui.dp(this, 16), 0);
        card.addView(formBox);
        root.addView(card);
    }

    private void buildSave(LinearLayout root) {
        TextView save = Ui.filled(this, "保存并重拨", R.color.primary, R.color.on_primary);
        save.setOnClickListener(v -> askSave());
        LinearLayout.LayoutParams slp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        slp.topMargin = Ui.dp(this, 2);
        slp.bottomMargin = Ui.dp(this, 6);
        save.setLayoutParams(slp);
        root.addView(save);

        TextView warn = Ui.text(this,
                "改完会自动重拨。如果 90 秒内上不了网，路由器会自动还原成现在的配置，"
                        + "不会留下连不上的状态。",
                11.5f, R.color.text_secondary);
        warn.setLineSpacing(Ui.dp(this, 2), 1f);
        warn.setPadding(Ui.dp(this, 16), 0, Ui.dp(this, 16), Ui.dp(this, 12));
        root.addView(warn);
    }

    private void buildLan(LinearLayout root) {
        Ui.Card card = Ui.card(this);
        card.setPadding(0, Ui.dp(this, 16), 0, Ui.dp(this, 12));
        Ui.cardTitle(this, card, Glyph.LINK, "局域网", "内网网段与 DHCP（只读）");
        lanBox = Ui.column(this);
        lanBox.setPadding(Ui.dp(this, 16), 0, Ui.dp(this, 16), 0);
        card.addView(lanBox);
        root.addView(card);
    }

    private void buildFirewall(LinearLayout root) {
        Context c = this;
        Ui.Card card = Ui.card(c);
        card.setPadding(0, Ui.dp(c, 16), 0, Ui.dp(c, 10));
        Ui.cardTitle(c, card, Glyph.SHIELD, "防火墙", "谁能从外面进来（只读）");
        fwBox = Ui.column(c);
        fwBox.setPadding(Ui.dp(c, 16), 0, Ui.dp(c, 16), 0);
        card.addView(fwBox);
        root.addView(card);

        riskCard = Ui.warnCard(c);
        riskCard.setPadding(Ui.dp(c, 16), Ui.dp(c, 14), Ui.dp(c, 16), Ui.dp(c, 12));
        LinearLayout head = Ui.row(c);
        tvRiskTitle = Ui.text(c, "需要注意", 15f, R.color.warn);
        tvRiskTitle.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        head.addView(tvRiskTitle, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        head.addView(Ui.pill(c, "只读", R.color.text_secondary));
        riskCard.addView(head);

        riskBox = Ui.column(c);
        LinearLayout.LayoutParams rlp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        rlp.topMargin = Ui.dp(c, 4);
        riskCard.addView(riskBox, rlp);
        riskCard.setVisibility(View.GONE);
        root.addView(riskCard);
    }

    /** App 不碰拓扑，但「去哪儿改」要说清楚 */
    private void buildWeb(LinearLayout root) {
        Ui.Card card = Ui.card(this);
        card.setPadding(0, Ui.dp(this, 4), 0, Ui.dp(this, 4));
        Ui.settingRow(this, card, Glyph.BOX, "路由器网页端",
                "改网段、地址池、端口转发、DDNS", "", true, false, this::openLuci);
        root.addView(card);
    }

    private void openLuci() {
        try {
            String host = Session.base(this).replaceFirst("^https?://", "");
            int slash = host.indexOf('/');
            if (slash > 0) {
                host = host.substring(0, slash);
            }
            int colon = host.lastIndexOf(':');
            if (colon > 0) {
                host = host.substring(0, colon);
            }
            startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse("http://" + host + "/")));
        } catch (Exception e) {
            Toast.makeText(this, "这台机器上没有能打开网页的浏览器", Toast.LENGTH_SHORT).show();
        }
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
                    hero.state.setText("正在重拨，等待网络恢复…");
                } else {
                    hero.state.setText("读取失败：" + message);
                }
            }
        });

        Api.get(this, "/api/v1/network/firewall", new Cb() {
            @Override
            public void onData(JSONObject body, boolean fromCache) {
                if (!isFinishing()) {
                    renderFirewall(body);
                }
            }

            @Override
            public void onError(String message) {
                if (!isFinishing() && fwBox != null && fwBox.getChildCount() == 0) {
                    Ui.kv(fwBox, "状态", "Agent 版本过旧，未提供防火墙摘要");
                }
            }
        });
    }

    private void render(JSONObject b) {
        JSONObject cfg = b.optJSONObject("config");
        JSONObject st = b.optJSONObject("status");
        JSONObject lan = b.optJSONObject("lan");

        boolean up = st != null && st.optBoolean("up", false);
        wanUp = up;
        String ip = st == null ? "" : st.optString("ipv4", "");
        String protoLabel = cfg == null ? "" : cfg.optString("proto_label", "");

        hero.dot(up ? R.color.hero_fg : R.color.warn, !up);

        if (waiting) {
            long elapsed = (System.currentTimeMillis() - waitSince) / 1000;
            if (up) {
                waiting = false;
                ticker.removeCallbacks(poll);
                hero.state.setText("已拨通，网络已恢复");
                Toast.makeText(this, "网络已恢复", Toast.LENGTH_SHORT).show();
            } else if (elapsed > 95) {
                waiting = false;
                ticker.removeCallbacks(poll);
                hero.state.setText("重拨超时，可能已自动回滚");
            } else {
                hero.state.setText("正在重拨… 已等待 " + elapsed + " 秒");
            }
        } else {
            hero.state.setText(up ? "已拨通" : (st == null ? "未知"
                    : Fmt.orDash(st.optString("note", "未连接"))));
        }

        hero.badge.setText(protoLabel.isEmpty() ? "未配置" : protoLabel);
        hero.title.setText(ip.isEmpty() ? "—" : ip);

        // 三个短指标：长句放进 note 会挤爆三列，这里只给「一眼能读完」的值
        String gw = st == null ? "" : st.optString("gateway", "");
        tvStatGw.setText(gw.isEmpty() ? "—" : gw);
        tvStatUp.setText(Fmt.shortDur(st == null ? 0 : st.optLong("uptime", 0)));

        hero.note.setText(up ? "点「重拨」可重新协商链路，不会改配置"
                : "未连接时可以先重拨一次，再检查账号或线路");

        // 断开 / 连接按钮跟着实际状态走
        btnToggle.setText(up ? "断开" : "连接");

        // 表单只在配置真的变了之后重建，否则每次轮询都会清掉用户正在输入的内容
        String sig = cfg == null ? "" : cfg.toString();
        if (!sig.equals(formSig)) {
            formSig = sig;
            rebuildForm(cfg);
        }
        renderLan(lan);
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

    /** 分段控件只有 1/3 屏宽，「自动获取（DHCP）」这种标签会被截成「自动获取（DHC」 */
    private static String shortProto(String key, String fallback) {
        switch (key == null ? "" : key) {
            case "pppoe":
                return "PPPoE";
            case "dhcp":
                return "DHCP";
            case "static":
                return "静态 IP";
            default:
                return fallback;
        }
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
            keys[i] = o == null ? "" : o.optString("key", "");
            labels[i] = shortProto(keys[i], o == null ? "" : o.optString("label", ""));
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

    /**
     * 局域网只读。
     *
     * 地址池不再拆成「起始 + 数量」两行 —— 用户真正关心的是「还剩多少」，
     * 所以给一根占用条：上面区间、下面「42 / 150 已分配 · 租期 24h」。
     */
    private void renderLan(JSONObject lan) {
        if (lanBox == null) {
            return;
        }
        lanBox.removeAllViews();
        if (lan == null) {
            return;
        }
        Ui.kv(lanBox, "管理地址", lan.optString("cidr", lan.optString("ipaddr", "—")));
        int hosts = lan.optInt("hosts", 0);
        if (hosts > 0) {
            Ui.kv(lanBox, "可用地址", Fmt.count(hosts) + " 个");
        }
        boolean dhcpOn = lan.optBoolean("dhcp_enabled", true);
        Ui.kv(lanBox, "DHCP 服务", dhcpOn ? "已开启" : "已关闭，设备需手动配置");

        String pool = lan.optString("dhcp_pool", "");
        int limit = parseInt(lan.optString("dhcp_limit", ""));
        int leases = lan.optInt("dhcp_leases", 0);
        String leaseTime = lan.optString("dhcp_lease", "");
        if (dhcpOn && !pool.isEmpty()) {
            Ui.kv(lanBox, "地址池", pool);
            if (limit > 0) {
                LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
                blp.topMargin = Ui.dp(this, 9);
                View bar = Ui.bar(this, (float) leases / limit, R.color.primary);
                bar.setLayoutParams(blp);
                lanBox.addView(bar);

                StringBuilder cap = new StringBuilder();
                cap.append(leases).append(" / ").append(limit).append(" 已分配");
                if (!leaseTime.isEmpty()) {
                    cap.append("　·　租期 ").append(leaseTime);
                }
                TextView note = Ui.text(this, cap.toString(), 11.5f, R.color.text_secondary);
                note.setPadding(0, Ui.dp(this, 6), 0, 0);
                lanBox.addView(note);
            }
        } else if (dhcpOn && !leaseTime.isEmpty()) {
            Ui.kv(lanBox, "租约时长", leaseTime);
        }
        String v6 = lan.optString("ipv6_prefix", "");
        if (!v6.isEmpty()) {
            Ui.kv(lanBox, "IPv6 前缀", v6);
        }
    }

    private static int parseInt(String s) {
        try {
            return Integer.parseInt(s.trim());
        } catch (Exception e) {
            return 0;
        }
    }

    private void renderFirewall(JSONObject b) {
        if (fwBox == null) {
            return;
        }
        fwBox.removeAllViews();
        riskBox.removeAllViews();

        JSONObject defaults = b.optJSONObject("defaults");
        String defIn = defaults == null ? "" : defaults.optString("input", "");

        // 先取出来再按固定顺序摆：接口返回的 zone 顺序不保证，
        // 而「WAN 放行」是这一页唯一的真风险，必须紧跟默认策略出现
        String wanIn = null;
        String lanIn = null;
        JSONArray zones = b.optJSONArray("zones");
        if (zones != null) {
            for (int i = 0; i < zones.length(); i++) {
                JSONObject z = zones.optJSONObject(i);
                if (z == null) {
                    continue;
                }
                String name = z.optString("name", "");
                if ("wan".equals(name)) {
                    wanIn = z.optString("input", "");
                } else if ("lan".equals(name)) {
                    lanIn = z.optString("input", "");
                }
            }
        }

        if (!defIn.isEmpty()) {
            Ui.kv(fwBox, "默认入站", label(defIn));
        }
        if (wanIn != null) {
            TextView v = Ui.kv(fwBox, "WAN 入站", label(wanIn));
            if ("ACCEPT".equals(wanIn)) {
                v.setTextColor(Ui.color(this, R.color.danger));
            }
        }
        if (lanIn != null) {
            Ui.kv(fwBox, "LAN 入站", label(lanIn));
        }
        Ui.kv(fwBox, "转发规则", b.optInt("rules", 0) + " 条");
        int redirs = b.optInt("redirects", 0);
        if (redirs > 0) {
            Ui.kv(fwBox, "端口转发", redirs + " 条");
        }
        int blocked = b.optInt("blocked_rules", 0);
        if (blocked > 0) {
            Ui.kv(fwBox, "禁网规则", blocked + " 条（本 App 创建）");
        }

        String note = b.optString("note", "");
        if (!note.isEmpty()) {
            TextView n = Ui.text(this, note, 11.5f, R.color.text_tertiary);
            n.setLineSpacing(Ui.dp(this, 2), 1f);
            n.setPadding(0, Ui.dp(this, 10), 0, 0);
            fwBox.addView(n);
        }

        JSONArray risks = b.optJSONArray("risks");
        int count = 0;
        if (risks != null) {
            for (int i = 0; i < risks.length(); i++) {
                String r = risks.optString(i, "");
                if (r.isEmpty()) {
                    continue;
                }
                if (count > 0) {
                    riskBox.addView(Ui.hairline(this, 8));
                }
                riskBox.addView(riskRow(r));
                count++;
            }
        }
        if (riskCard != null) {
            riskCard.setVisibility(count > 0 ? View.VISIBLE : View.GONE);
            tvRiskTitle.setText("需要注意 · " + count + " 条");
        }
    }

    /** 一条风险：小圆点 + 说明文字。不用 ⚠ 字符 —— 不同 ROM 的字形差异很大 */
    private View riskRow(String text) {
        LinearLayout row = Ui.row(this);
        row.setPadding(0, Ui.dp(this, 9), 0, Ui.dp(this, 9));
        row.setGravity(Gravity.TOP);

        View dot = new View(this);
        GradientDrawable bg = new GradientDrawable();
        bg.setShape(GradientDrawable.OVAL);
        bg.setColor(Ui.color(this, R.color.warn));
        dot.setBackground(bg);
        LinearLayout.LayoutParams dlp = new LinearLayout.LayoutParams(
                Ui.dp(this, 6), Ui.dp(this, 6));
        dlp.topMargin = Ui.dp(this, 6);
        dlp.rightMargin = Ui.dp(this, 9);
        row.addView(dot, dlp);

        TextView t = Ui.text(this, text, 12.5f, R.color.text_primary);
        t.setLineSpacing(Ui.dp(this, 2), 1f);
        row.addView(t, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        return row;
    }

    /** uci 里的 ACCEPT / DROP / REJECT 翻成人话 */
    private static String label(String v) {
        switch (v) {
            case "ACCEPT":
                return "允许全部";
            case "REJECT":
                return "拒绝并回包";
            case "DROP":
                return "静默丢弃";
            default:
                return v.isEmpty() ? "—" : v;
        }
    }

    // ---------------------------------------------------------------- 操作

    /** 重拨 / 断开 / 连接：不动配置，所以只做一次轻确认 */
    private void askAction(String action) {
        if (waiting) {
            Toast.makeText(this, "上一次操作还没结束", Toast.LENGTH_SHORT).show();
            return;
        }
        String title;
        String body;
        boolean danger = false;
        switch (action) {
            case "down":
                title = "断开 WAN？";
                body = "断开后全家立刻上不了网，点「连接」可恢复。";
                danger = true;
                break;
            case "up":
                title = "重新连接？";
                body = "会向上级设备请求地址，通常 5-10 秒恢复。";
                break;
            default:
                title = "重拨？";
                body = "PPPoE 会重新协商，全家断网 10-30 秒。"
                        + "这个操作不改配置，失败也不会丢宽带账号。";
        }
        Sheet.confirm(this, title, body, action.equals("down") ? "断开" : "确定", danger,
                () -> doAction(action));
    }

    private void doAction(String action) {
        JSONObject body = new JSONObject();
        try {
            body.put("action", action);
        } catch (Exception ignored) {
            return;
        }
        tvActionNote.setText("正在" + ("down".equals(action) ? "断开" : "重拨") + "…");

        Api.post(this, "/api/v1/net/wan/action", body, new Cb() {
            @Override
            public void onData(JSONObject data, boolean fromCache) {
                if (isFinishing()) {
                    return;
                }
                if (!data.optBoolean("ok", true)) {
                    tvActionNote.setText(data.optString("error", "操作失败"));
                    return;
                }
                tvActionNote.setText(data.optString("detail", ""));
                if ("down".equals(action)) {
                    waiting = false;
                    ticker.removeCallbacks(poll);
                    btnToggle.setText("连接");
                    hero.state.setText("WAN 已断开");
                    hero.dot(R.color.warn, true);
                } else {
                    waiting = true;
                    waitSince = System.currentTimeMillis();
                    ticker.removeCallbacks(poll);
                    ticker.postDelayed(poll, POLL_MS);
                }
            }

            @Override
            public void onError(String message) {
                if (!isFinishing()) {
                    tvActionNote.setText("操作失败：" + message);
                }
            }
        });
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
                    hero.state.setText("正在重拨…");
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
