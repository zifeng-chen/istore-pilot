package com.chaof.istoreos.ui;

import android.content.Context;
import android.content.Intent;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import com.chaof.istoreos.R;
import com.chaof.istoreos.WanActivity;
import com.chaof.istoreos.api.Api;
import com.chaof.istoreos.api.Cb;
import com.chaof.istoreos.util.Fmt;
import com.chaof.istoreos.util.Ui;
import com.chaof.istoreos.widget.Glyph;
import com.chaof.istoreos.widget.Sheet;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * 网络：这台路由器的「怎么上网、内网怎么分、谁能进来」。
 *
 * 以前这些信息是散着的 —— 宽带在概览页的 WAN 卡里，LAN 哪都没有，
 * 防火墙只能去网页端看。用户想知道「我家网段是什么、DHCP 发到哪」
 * 只能去翻 LuCI，而这是路由器管理 App 最该回答的问题之一。
 *
 * 分成三块，对应三个决策层级：
 *   1. 宽带接入 —— 对外那一根线（WAN，可改）
 *   2. 局域网   —— 对内那张网（LAN / DHCP，只读，改了就失联）
 *   3. 防火墙   —— 谁能从外面进来（只读，含现有配置的风险提示）
 *
 * 「只读」不是偷懒：LAN 一改，手机到路由器的 TCP 连接立刻失效，
 * 用户拿到的表现是 App 崩了，而不是「配置生效了请重连」。
 * 这类操作要先解决「改完怎么找回设备」再谈在线修改。
 */
public class NetworkFragment extends BaseFragment {

    private View heroDot;
    private TextView tvHeroState;
    private TextView tvHeroPill;
    private TextView tvHeroIp;
    private TextView tvHeroSub;

    private LinearLayout wanBox;
    private LinearLayout lanBox;
    private LinearLayout fwBox;
    private LinearLayout fwRiskBox;

    /** 待确认横幅：改完配置等客户端回来点确认，超时服务端自动回滚 */
    private View pendingCard;
    private TextView tvPendingTitle;
    private TextView tvPendingNote;
    private LinearLayout pendingBar;
    private String pendingToken = "";

    private boolean wanLoaded = false;
    private boolean fwLoaded = false;

    @Override
    protected String title() {
        return "网络";
    }

    @Override
    protected void build(LinearLayout root) {
        final Context c = ctx();

        // ---------------------------------------------------------- 待确认横幅
        // 放在最顶上：改完网络配置后用户第一眼要看到的就是「还差你一句话」，
        // 而不是继续往下翻卡片。服务端 60 秒没收到确认就自动回滚。
        root.addView(buildPendingCard(c), 0);

        // ---------------------------------------------------------- hero
        Ui.Card hero = Ui.gradient(c, R.color.hero_from, R.color.hero_to);
        hero.setPadding(Ui.dp(c, 20), Ui.dp(c, 18), Ui.dp(c, 20), Ui.dp(c, 18));

        LinearLayout top = Ui.row(c);
        heroDot = new View(c);
        GradientDrawable hd = new GradientDrawable();
        hd.setShape(GradientDrawable.OVAL);
        hd.setColor(Ui.alpha(Ui.color(c, R.color.hero_fg), 0.45f));
        heroDot.setBackground(hd);
        LinearLayout.LayoutParams dlp = new LinearLayout.LayoutParams(Ui.dp(c, 7), Ui.dp(c, 7));
        dlp.rightMargin = Ui.dp(c, 7);
        top.addView(heroDot, dlp);

        tvHeroState = Ui.heroNote(c, "正在读取…", 1.0f);
        tvHeroState.setTextSize(12.5f);
        tvHeroState.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        top.addView(tvHeroState, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        tvHeroPill = Ui.heroNote(c, "—", 0.86f);
        tvHeroPill.setTextSize(11f);
        tvHeroPill.setPadding(Ui.dp(c, 9), Ui.dp(c, 4), Ui.dp(c, 9), Ui.dp(c, 4));
        GradientDrawable bb = new GradientDrawable();
        bb.setCornerRadius(Ui.dp(c, 100));
        bb.setColor(Ui.alpha(Ui.color(c, R.color.hero_fg), 0.16f));
        tvHeroPill.setBackground(bb);
        top.addView(tvHeroPill);
        hero.addView(top);

        tvHeroIp = Ui.heroNote(c, "—", 1.0f);
        tvHeroIp.setTextSize(27f);
        tvHeroIp.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        tvHeroIp.setPadding(0, Ui.dp(c, 12), 0, 0);
        tvHeroIp.setSingleLine(true);
        tvHeroIp.setEllipsize(android.text.TextUtils.TruncateAt.MIDDLE);
        hero.addView(tvHeroIp);

        tvHeroSub = Ui.heroNote(c, "—", 0.78f);
        tvHeroSub.setTextSize(12f);
        tvHeroSub.setPadding(0, Ui.dp(c, 4), 0, 0);
        hero.addView(tvHeroSub);
        root.addView(hero);

        // ---------------------------------------------------------- 宽带
        Ui.Card wan = Ui.card(c);
        wan.setPadding(0, Ui.dp(c, 16), 0, Ui.dp(c, 4));
        LinearLayout wanHead = Ui.cardTitle(c, wan, Glyph.GLOBE, "宽带接入", "对外那一根线");
        TextView cfg = Ui.text(c, "配置 ›", 13f, R.color.primary);
        cfg.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        cfg.setPadding(Ui.dp(c, 8), 0, Ui.dp(c, 4), 0);
        cfg.setOnClickListener(v -> openWan());
        wanHead.addView(cfg);

        wanBox = Ui.column(c);
        wanBox.setPadding(Ui.dp(c, 16), 0, Ui.dp(c, 16), 0);
        LinearLayout.LayoutParams wlp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        wlp.topMargin = Ui.dp(c, 6);
        wanBox.setLayoutParams(wlp);
        wan.addView(wanBox);
        root.addView(wan);

        // ---------------------------------------------------------- 局域网
        Ui.Card lan = Ui.card(c);
        lan.setPadding(0, Ui.dp(c, 16), 0, Ui.dp(c, 6));
        Ui.cardTitle(c, lan, Glyph.LINK, "局域网", "内网网段与 DHCP");

        lanBox = Ui.column(c);
        lanBox.setPadding(Ui.dp(c, 16), 0, Ui.dp(c, 16), 0);
        LinearLayout.LayoutParams llp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        llp.topMargin = Ui.dp(c, 6);
        lanBox.setLayoutParams(llp);
        lan.addView(lanBox);
        root.addView(lan);

        // ---------------------------------------------------------- 防火墙
        Ui.Card fw = Ui.card(c);
        fw.setPadding(0, Ui.dp(c, 16), 0, Ui.dp(c, 6));
        Ui.cardTitle(c, fw, Glyph.SHIELD, "防火墙", "谁能从外面进来");

        fwBox = Ui.column(c);
        fwBox.setPadding(Ui.dp(c, 16), 0, Ui.dp(c, 16), 0);
        LinearLayout.LayoutParams flp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        flp.topMargin = Ui.dp(c, 6);
        fwBox.setLayoutParams(flp);
        fw.addView(fwBox);

        fwRiskBox = Ui.column(c);
        fw.addView(fwRiskBox);

        root.addView(fw);

        // ---------------------------------------------------------- 还没做的
        Ui.Card gap = Ui.card(c);
        gap.setPadding(0, Ui.dp(c, 16), 0, Ui.dp(c, 6));
        Ui.cardTitle(c, gap, Glyph.LIST, "还不能在这里改", "点开看缺什么、为什么");
        TextView gapNote = Ui.text(c, "LAN 管理地址、DHCP 范围、端口转发、静态路由、DDNS"
                + " —— 这些都会直接改变网络拓扑", 12f, R.color.text_secondary);
        gapNote.setLineSpacing(Ui.dp(c, 3), 1f);
        gapNote.setPadding(Ui.dp(c, 16), Ui.dp(c, 8), Ui.dp(c, 16), Ui.dp(c, 10));
        gap.addView(gapNote);

        TextView gapBtn = Ui.text(c, "查看规划", 13.5f, R.color.primary);
        gapBtn.setGravity(Gravity.CENTER);
        gapBtn.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        GradientDrawable gb = new GradientDrawable();
        gb.setCornerRadius(Ui.dp(c, 11));
        gb.setColor(Ui.color(c, R.color.accent_soft));
        gapBtn.setBackground(gb);
        gapBtn.setPadding(0, Ui.dp(c, 10), 0, Ui.dp(c, 10));
        gapBtn.setOnClickListener(v -> showGaps());
        LinearLayout.LayoutParams glp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        glp.leftMargin = Ui.dp(c, 16);
        glp.rightMargin = Ui.dp(c, 16);
        glp.bottomMargin = Ui.dp(c, 12);
        gap.addView(gapBtn, glp);
        root.addView(gap);
    }

    private void toast(String msg) {
        if (isAdded()) {
            Toast.makeText(ctx(), msg, Toast.LENGTH_SHORT).show();
        }
    }

    private void openWan() {
        startActivity(new Intent(ctx(), WanActivity.class));
    }

    // ---------------------------------------------------------------- 待确认

    private View buildPendingCard(Context c) {
        Ui.Card card = Ui.card(c);
        card.setPadding(Ui.dp(c, 16), Ui.dp(c, 14), Ui.dp(c, 16), Ui.dp(c, 14));
        // 用告警底色区分：这不是普通信息卡，是一个有时限的决定
        GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(Ui.dp(c, 22));
        bg.setColor(Ui.color(c, R.color.surface));
        bg.setStroke(Math.max(1, Ui.dp(c, 1.2f)), 0x66FFB454);
        card.setBackground(bg);

        LinearLayout head = Ui.row(c);
        tvPendingTitle = Ui.text(c, "改动等待确认", 15f, R.color.warn);
        tvPendingTitle.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        head.addView(tvPendingTitle, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        tvPendingNote = Ui.text(c, "", 12.5f, R.color.text_secondary);
        tvPendingNote.setGravity(Gravity.END);
        head.addView(tvPendingNote);
        card.addView(head);

        TextView desc = Ui.text(c, "能连上就说明没问题。不点确认的话，时间一到路由器会自己还原。",
                11.5f, R.color.text_secondary);
        desc.setLineSpacing(Ui.dp(c, 2), 1f);
        desc.setPadding(0, Ui.dp(c, 5), 0, Ui.dp(c, 10));
        card.addView(desc);

        pendingBar = Ui.row(c);
        card.addView(pendingBar);

        LinearLayout btns = Ui.row(c);
        btns.setPadding(0, Ui.dp(c, 12), 0, 0);
        TextView undo = Ui.text(c, "撤销改动", 14f, R.color.text_secondary);
        undo.setGravity(Gravity.CENTER);
        undo.setPadding(0, Ui.dp(c, 11), 0, Ui.dp(c, 11));
        GradientDrawable ub = new GradientDrawable();
        ub.setCornerRadius(Ui.dp(c, 100));
        ub.setColor(Ui.color(c, R.color.surface_sunken));
        undo.setBackground(ub);
        undo.setOnClickListener(v -> rollbackPending());
        btns.addView(undo, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        TextView ok = Ui.filled(c, "确认，一切正常", R.color.primary, R.color.on_primary);
        ok.setOnClickListener(v -> confirmPending());
        LinearLayout.LayoutParams olp = new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1.4f);
        olp.leftMargin = Ui.dp(c, 10);
        btns.addView(ok, olp);
        card.addView(btns);

        card.setVisibility(View.GONE);
        pendingCard = card;
        return card;
    }

    private void renderPending(JSONObject b) {
        if (pendingCard == null || tvPendingNote == null) {
            return;
        }
        if (!b.optBoolean("pending", false)) {
            pendingToken = "";
            pendingCard.setVisibility(View.GONE);
            return;
        }
        pendingToken = b.optString("token", "");
        int left = b.optInt("left", 0);
        String note = b.optString("note", "");
        boolean expired = b.optBoolean("expired", false);
        // 过期那几秒守护正在铺回配置，界面要如实说「正在还原」，
        // 不能再显示一个点不动的 0 秒
        tvPendingTitle.setText(expired ? "正在还原改动…"
                : (note.isEmpty() ? "改动等待确认" : note));
        tvPendingNote.setText(expired ? "请稍候" : (left + " 秒"));

        pendingBar.removeAllViews();
        // 进度条按 60 秒总长画：拿 deadline 反推会得到「现在 + left」，
        // 算出来永远是半满，读起来像是卡在某个固定位置
        int total = Math.max(left, 60);
        View bar = Ui.bar(ctx(), (float) left / total, R.color.warn);
        pendingBar.addView(bar);
        pendingCard.setVisibility(View.VISIBLE);
    }

    private void confirmPending() {
        if (pendingToken.isEmpty()) {
            return;
        }
        JSONObject body = new JSONObject();
        try {
            body.put("token", pendingToken);
        } catch (JSONException ignored) {
            return;
        }
        Api.post(ctx(), "/api/v1/net/confirm", body, new Cb() {
            @Override
            public void onData(JSONObject b, boolean fromCache) {
                if (!isAdded()) {
                    return;
                }
                pendingToken = "";
                if (pendingCard != null) {
                    pendingCard.setVisibility(View.GONE);
                }
                toast("已确认，配置保留");
                reload();
            }

            @Override
            public void onError(String message) {
                if (isAdded()) {
                    toast(message);
                }
            }
        });
    }

    private void rollbackPending() {
        if (pendingToken.isEmpty()) {
            return;
        }
        Sheet.confirm(ctx(), "撤销这次改动？",
                "路由器会立刻恢复到改动之前的配置，并重新加载防火墙。", "撤销", true,
                () -> {
                    JSONObject body = new JSONObject();
                    try {
                        body.put("token", pendingToken);
                    } catch (JSONException ignored) {
                        return;
                    }
                    Api.post(ctx(), "/api/v1/net/rollback", body, new Cb() {
                        @Override
                        public void onData(JSONObject b, boolean fromCache) {
                            if (!isAdded()) {
                                return;
                            }
                            pendingToken = "";
                            if (pendingCard != null) {
                                pendingCard.setVisibility(View.GONE);
                            }
                            toast("已还原");
                            reload();
                        }

                        @Override
                        public void onError(String message) {
                            if (isAdded()) {
                                toast(message);
                            }
                        }
                    });
                });
    }

    private void reload() {
        fwLoaded = false;
        load(false);
    }

    // ---------------------------------------------------------------- 规划说明

    private void showGaps() {
        Sheet.message(ctx(), "网络配置的下一步",
                "已经有的：宽带（PPPoE / DHCP / 静态）、LAN 与 DHCP 现状、防火墙摘要。\n\n"
                        + "还没做的：\n"
                        + "1. LAN 管理地址 —— 改完手机立刻连不上，需要「失败自动回滚 + 提示新地址」\n"
                        + "2. DHCP 地址池 / 租约时长 —— 影响新设备能不能拿到 IP\n"
                        + "3. 静态地址绑定（DHCP 固定分配）—— 设备列表里已经能拿到 MAC，只差写入\n"
                        + "4. DDNS、静态路由、VLAN、QoS 限速\n\n"
                        + "防火墙策略不在 App 里改。这里只做展示，"
                        + "所有调整都请到路由器网页端（LuCI → 网络 → 防火墙），"
                        + "避免一次误操作把全家的网关换掉。");
    }

    @Override
    protected void load(boolean quiet) {
        Api.get(ctx(), "/api/v1/network/wan", new Cb() {
            @Override
            public void onData(JSONObject body, boolean fromCache) {
                if (!isAdded()) {
                    return;
                }
                renderWan(body);
                if (!fromCache) {
                    setRefreshing(false);
                }
                wanLoaded = true;
                markLoaded();
            }

            @Override
            public void onError(String message) {
                if (isAdded()) {
                    fail(message);
                    markLoaded();
                }
            }
        });

        Api.get(ctx(), "/api/v1/network/firewall", new Cb() {
            @Override
            public void onData(JSONObject body, boolean fromCache) {
                if (isAdded()) {
                    renderFirewall(body);
                }
            }

            @Override
            public void onError(String message) {
                if (isAdded() && fwBox != null && !fwLoaded) {
                    fwBox.addView(Ui.kv(fwBox, "状态", "Agent 版本过旧，未提供防火墙摘要"));
                }
            }
        });

        // 待确认状态：3 秒轮询一次，倒计时跟着刷新走，不用另起定时器
        Api.get(ctx(), "/api/v1/net/pending", new Cb() {
            @Override
            public void onData(JSONObject body, boolean fromCache) {
                if (isAdded()) {
                    renderPending(body);
                }
            }

            @Override
            public void onError(String message) {
                // 老版本 Agent 没有这个接口，静默忽略即可
            }
        });
    }

    private void renderWan(JSONObject b) {
        JSONObject cfg = b.optJSONObject("config");
        JSONObject st = b.optJSONObject("status");
        Context c = ctx();
        if (cfg == null || st == null) {
            return;
        }
        boolean up = st.optBoolean("up", false);
        String ip = st.optString("ipv4", "");

        GradientDrawable dot = new GradientDrawable();
        dot.setShape(GradientDrawable.OVAL);
        dot.setColor(Ui.color(c, up ? R.color.hero_fg : R.color.warn));
        if (!up) {
            dot.setColor(0x00000000);
            dot.setStroke(Math.max(1, Ui.dp(c, 1.6f)), Ui.color(c, R.color.hero_fg));
        }
        heroDot.setBackground(dot);
        tvHeroState.setText(up ? "已拨通" : Fmt.orDash(st.optString("note", "未连接")));
        tvHeroIp.setText(ip.isEmpty() ? "—" : ip);

        String protoLabel = cfg.optString("proto_label", "");
        tvHeroPill.setText(protoLabel.isEmpty() ? "未配置" : protoLabel);

        StringBuilder sub = new StringBuilder();
        String gw = st.optString("gateway", "");
        if (!gw.isEmpty()) {
            sub.append("网关 ").append(gw);
        }
        long uptime = st.optLong("uptime", 0);
        if (uptime > 0) {
            if (sub.length() > 0) {
                sub.append("　·　");
            }
            sub.append("已连接 ").append(Fmt.dur(uptime));
        }
        tvHeroSub.setText(sub.length() == 0 ? "—" : sub.toString());

        // ---- 宽带卡
        wanBox.removeAllViews();
        Ui.kv(wanBox, "接入方式", protoLabel.isEmpty() ? "—" : protoLabel);
        String user = cfg.optString("username", "");
        if (!user.isEmpty()) {
            Ui.kv(wanBox, "账号", user);
        }
        Ui.kv(wanBox, "地址获取", ip.isEmpty() ? "未获取"
                : ("static".equals(cfg.optString("proto")) ? "静态指定" : "自动下发"));
        String mask = cfg.optString("netmask", "");
        if (!mask.isEmpty() && !"255.255.255.255".equals(mask)) {
            Ui.kv(wanBox, "子网掩码", mask);
        }
        JSONArray dns = st.optJSONArray("dns");
        StringBuilder dsb = new StringBuilder();
        if (dns != null) {
            for (int i = 0; i < dns.length() && i < 3; i++) {
                if (dsb.length() > 0) {
                    dsb.append("　");
                }
                dsb.append(dns.optString(i, ""));
            }
        }
        Ui.kv(wanBox, "DNS", dsb.length() == 0 ? "—" : dsb.toString());
        int mtu = cfg.optInt("mtu", 0);
        if (mtu > 0) {
            Ui.kv(wanBox, "MTU", String.valueOf(mtu));
        }

        // ---- 局域网卡
        JSONObject lan = b.optJSONObject("lan");
        lanBox.removeAllViews();
        if (lan == null) {
            lanBox.addView(Ui.kv(lanBox, "状态", "读取失败"));
        } else {
            Ui.kv(lanBox, "管理地址", lan.optString("cidr", "—"));
            int hosts = lan.optInt("hosts", 0);
            if (hosts > 0) {
                Ui.kv(lanBox, "可用地址", Fmt.count(hosts) + " 个");
            }
            boolean dhcpOn = lan.optBoolean("dhcp_enabled", true);
            String pool = lan.optString("dhcp_pool", "");
            // 池子单独一行：塞进同一行会让值折成两行，右侧对齐就散了
            Ui.kv(lanBox, "DHCP 服务", dhcpOn ? "已开启" : "已关闭，设备需手动配置");
            if (dhcpOn && !pool.isEmpty()) {
                Ui.kv(lanBox, "地址池", pool);
            }
            int leases = lan.optInt("dhcp_leases", 0);
            if (dhcpOn) {
                String lease = lan.optString("dhcp_lease", "");
                Ui.kv(lanBox, "已分配租约", leases + " 个" + (lease.isEmpty() ? "" : "　·　租期 " + lease));
            }
            String v6 = lan.optString("ipv6_prefix", "");
            if (!v6.isEmpty()) {
                Ui.kv(lanBox, "IPv6 前缀", v6);
            }
            String note = lan.optString("note", "");
            if (!note.isEmpty()) {
                TextView n = Ui.text(c, note, 11.5f, R.color.text_tertiary);
                n.setLineSpacing(Ui.dp(c, 2), 1f);
                n.setPadding(0, Ui.dp(c, 8), 0, Ui.dp(c, 4));
                lanBox.addView(n);
            }
        }
    }

    private void renderFirewall(JSONObject b) {
        fwLoaded = true;
        Context c = ctx();
        fwBox.removeAllViews();
        fwRiskBox.removeAllViews();

        JSONObject defaults = b.optJSONObject("defaults");
        String defIn = defaults == null ? "" : defaults.optString("input", "");
        if (!defIn.isEmpty()) {
            Ui.kv(fwBox, "默认入站", label(defIn));
        }

        JSONArray zones = b.optJSONArray("zones");
        if (zones != null) {
            for (int i = 0; i < zones.length(); i++) {
                JSONObject z = zones.optJSONObject(i);
                if (z == null) {
                    continue;
                }
                String name = z.optString("name", "");
                if (name.isEmpty()) {
                    continue;
                }
                StringBuilder sb = new StringBuilder();
                sb.append(label(z.optString("input", "")));
                if ("wan".equals(name)) {
                    Ui.kv(fwBox, "WAN 入站", sb.toString());
                } else if ("lan".equals(name)) {
                    Ui.kv(fwBox, "LAN 入站", sb.toString());
                }
            }
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

        JSONArray risks = b.optJSONArray("risks");
        if (risks != null && risks.length() > 0) {
            for (int i = 0; i < risks.length(); i++) {
                String r = risks.optString(i, "");
                if (r.isEmpty()) {
                    continue;
                }
                TextView t = Ui.text(c, "⚠ " + r, 12f, R.color.warn);
                t.setLineSpacing(Ui.dp(c, 3), 1f);
                GradientDrawable bg = new GradientDrawable();
                bg.setCornerRadius(Ui.dp(c, 12));
                bg.setColor(0x1AFFB454);
                t.setBackground(bg);
                t.setPadding(Ui.dp(c, 12), Ui.dp(c, 9), Ui.dp(c, 12), Ui.dp(c, 9));
                LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT,
                        ViewGroup.LayoutParams.WRAP_CONTENT);
                lp.leftMargin = Ui.dp(c, 16);
                lp.rightMargin = Ui.dp(c, 16);
                lp.topMargin = Ui.dp(c, 6);
                fwRiskBox.addView(t, lp);
            }
            Ui.space(c, fwRiskBox, 6);
        }

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
}
