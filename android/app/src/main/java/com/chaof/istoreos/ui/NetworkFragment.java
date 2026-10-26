package com.chaof.istoreos.ui;

import android.content.Context;
import android.content.Intent;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
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
import com.chaof.istoreos.core.Session;
import com.chaof.istoreos.util.Fmt;
import com.chaof.istoreos.util.Ui;
import com.chaof.istoreos.widget.Glyph;
import com.chaof.istoreos.widget.Hero;
import com.chaof.istoreos.widget.Sheet;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/**
 * 网络：这台路由器的「怎么上网、内网怎么分、谁能进来」。
 *
 * 这一版是纯重构，取数与判定逻辑一行没动，改的是信息怎么摆：
 *
 *   1. 顶部 hero 直接回答「通不通」—— 状态点 + 接入方式 + WAN 地址 + 网关/时长。
 *      以前这四样分散在一张渐变卡和一张键值卡里，同一件事要读两个地方。
 *   2. 三张卡按「对外 / 对内 / 准入」排，卡片标题带图标和一句副标题，
 *      和设置页、设备页是同一套语言（图标块 28dp + 16.5sp 标题 + 12sp 灰副标）。
 *   3. 行统一走 {@link Ui#kv}：标签 13.5sp 灰色、值 14.5sp 主色 + 等宽数字。
 *      路由器的数据页（设备详情、硬件、宽带）都是这个口径，网络页不再自成一套。
 *   4. 删掉原来那张「还不能在这里改」的占位卡 —— 它占了半屏却什么也不能做。
 *      换成一行真的能用的入口：打开路由器网页端。改 LAN 网段、静态路由、DDNS
 *      这些确实不适合放进 App（改完手机就失联），但「去哪儿改」应该指得出来。
 *
 * 「只读」不是偷懒：LAN 一改，手机到路由器的 TCP 连接立刻失效，
 * 用户拿到的表现是 App 崩了，而不是「配置生效了请重连」。
 */
public class NetworkFragment extends BaseFragment {

    /** 顶部的结论卡 */
    private Hero hero;

    private LinearLayout wanBox;
    private LinearLayout lanBox;
    private LinearLayout fwBox;
    /** 防火墙风险：有问题才显示，没问题时整张卡 GONE，不留空壳 */
    private Ui.Card riskCard;
    private LinearLayout riskBox;
    private TextView tvRiskTitle;

    /** 待确认横幅：改完配置等客户端回来点确认，超时服务端自动回滚 */
    private View pendingCard;
    private TextView tvPendingTitle;
    private TextView tvPendingNote;
    private LinearLayout pendingBar;
    private String pendingToken = "";

    private boolean fwLoaded = false;

    @Override
    protected String title() {
        return "网络";
    }

    @Override
    protected void build(LinearLayout root) {
        Context c = ctx();

        // ---------------------------------------------------------- 待确认横幅
        // 放在最顶上：改完网络配置后用户第一眼要看到的就是「还差你一句话」，
        // 而不是继续往下翻卡片。服务端 60 秒没收到确认就自动回滚。
        root.addView(buildPendingCard(c), 0);

        // ---------------------------------------------------------- 结论
        hero = new Hero(c);
        root.addView(hero);

        // ---------------------------------------------------------- 宽带接入
        Ui.Card wan = Ui.card(c);
        wan.setPadding(0, Ui.dp(c, 16), 0, Ui.dp(c, 10));
        LinearLayout wanHead = Ui.cardTitle(c, wan, Glyph.GLOBE, "宽带接入", "对外那一根线");
        TextView cfg = Ui.text(c, "配置", 13f, R.color.primary);
        cfg.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        cfg.setPadding(Ui.dp(c, 8), 0, Ui.dp(c, 2), 0);
        cfg.setOnClickListener(v -> openWan());
        wanHead.addView(cfg);

        wanBox = Ui.column(c);
        wanBox.setPadding(Ui.dp(c, 16), 0, Ui.dp(c, 16), 0);
        LinearLayout.LayoutParams wlp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        wlp.topMargin = Ui.dp(c, 6);
        wan.addView(wanBox, wlp);
        root.addView(wan);

        // ---------------------------------------------------------- 局域网
        Ui.Card lan = Ui.card(c);
        lan.setPadding(0, Ui.dp(c, 16), 0, Ui.dp(c, 12));
        Ui.cardTitle(c, lan, Glyph.LINK, "局域网", "内网网段与 DHCP");

        lanBox = Ui.column(c);
        lanBox.setPadding(Ui.dp(c, 16), 0, Ui.dp(c, 16), 0);
        LinearLayout.LayoutParams llp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        llp.topMargin = Ui.dp(c, 6);
        lan.addView(lanBox, llp);
        root.addView(lan);

        // ---------------------------------------------------------- 防火墙
        Ui.Card fw = Ui.card(c);
        fw.setPadding(0, Ui.dp(c, 16), 0, Ui.dp(c, 10));
        Ui.cardTitle(c, fw, Glyph.SHIELD, "防火墙", "谁能从外面进来");

        fwBox = Ui.column(c);
        fwBox.setPadding(Ui.dp(c, 16), 0, Ui.dp(c, 16), 0);
        LinearLayout.LayoutParams flp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        flp.topMargin = Ui.dp(c, 6);
        fw.addView(fwBox, flp);
        root.addView(fw);

        // ---------------------------------------------------------- 风险（按需）
        riskCard = Ui.warnCard(c);
        riskCard.setPadding(Ui.dp(c, 16), Ui.dp(c, 14), Ui.dp(c, 16), Ui.dp(c, 12));
        LinearLayout riskHead = Ui.row(c);
        tvRiskTitle = Ui.text(c, "需要注意", 15f, R.color.warn);
        tvRiskTitle.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        riskHead.addView(tvRiskTitle, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        riskHead.addView(Ui.pill(c, "只读", R.color.text_secondary));
        riskCard.addView(riskHead);

        riskBox = Ui.column(c);
        LinearLayout.LayoutParams rlp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        rlp.topMargin = Ui.dp(c, 4);
        riskCard.addView(riskBox, rlp);
        riskCard.setVisibility(View.GONE);
        root.addView(riskCard);

        // ---------------------------------------------------------- 更多设置
        // 一行，点到网页端。App 不碰拓扑，但也不该让用户自己去猜地址。
        Ui.Card more = Ui.card(c);
        more.setPadding(0, Ui.dp(c, 4), 0, Ui.dp(c, 4));
        Ui.settingRow(c, more, Glyph.BOX, "路由器网页端",
                "改网段、地址池、端口转发、DDNS", "", true, false, this::openLuci);
        root.addView(more);
    }

    private void toast(String msg) {
        if (isAdded()) {
            Toast.makeText(ctx(), msg, Toast.LENGTH_SHORT).show();
        }
    }

    private void openWan() {
        startActivity(new Intent(ctx(), WanActivity.class));
    }

    /**
     * 打开 LuCI。Agent 在 8443，网页后台在 80 —— 不能直接用 Session.base，
     * 否则会打开 Agent 的 API 端口，浏览器里是一坨 JSON。
     */
    private void openLuci() {
        try {
            String host = Session.base(ctx()).replaceFirst("^https?://", "");
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
            toast("这台机器上没有能打开网页的浏览器");
        }
    }

    // ---------------------------------------------------------------- 待确认

    private View buildPendingCard(Context c) {
        Ui.Card card = Ui.warnCard(c);
        card.setPadding(Ui.dp(c, 16), Ui.dp(c, 14), Ui.dp(c, 16), Ui.dp(c, 14));

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
        pendingBar.addView(Ui.bar(ctx(), (float) left / total, R.color.warn));
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

    // ---------------------------------------------------------------- 取数

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
        String protoLabel = cfg.optString("proto_label", "");

        hero.dot(up ? R.color.hero_fg : R.color.warn, !up);
        hero.state.setText(up ? "已拨通" : Fmt.orDash(st.optString("note", "未连接")));
        hero.badge.setText(protoLabel.isEmpty() ? "未配置" : protoLabel);
        hero.title.setText(ip.isEmpty() ? "—" : ip);

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
        hero.note.setText(sub.length() == 0 ? "没有拿到网关信息" : sub.toString());

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
        renderLan(c, b.optJSONObject("lan"));
    }

    /**
     * 局域网。
     *
     * 地址池不再是一行「地址池 100 – 249」+ 一行「已分配 12 个」——
     * 那两行说的是同一件事，而且用户真正关心的是「还剩多少」。
     * 改成一根占用条：上面区间、下面「12 / 150 已分配 · 租期 12h」。
     */
    private void renderLan(Context c, JSONObject lan) {
        lanBox.removeAllViews();
        if (lan == null) {
            lanBox.addView(Ui.kv(lanBox, "状态", "读取失败"));
            return;
        }
        Ui.kv(lanBox, "管理地址", lan.optString("cidr", "—"));
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
                blp.topMargin = Ui.dp(c, 9);
                View bar = Ui.bar(c, (float) leases / limit, R.color.primary);
                bar.setLayoutParams(blp);
                lanBox.addView(bar);

                StringBuilder cap = new StringBuilder();
                cap.append(leases).append(" / ").append(limit).append(" 已分配");
                if (!leaseTime.isEmpty()) {
                    cap.append("　·　租期 ").append(leaseTime);
                }
                TextView note = Ui.text(c, cap.toString(), 11.5f, R.color.text_secondary);
                note.setPadding(0, Ui.dp(c, 6), 0, 0);
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
        fwLoaded = true;
        Context c = ctx();
        fwBox.removeAllViews();
        riskBox.removeAllViews();

        JSONObject defaults = b.optJSONObject("defaults");
        String defIn = defaults == null ? "" : defaults.optString("input", "");

        // 先取出来再按固定顺序摆：接口返回的 zone 顺序不保证，
        // 而「WAN 放行」是这一页唯一的真风险，必须排在第二行，不能等接口高兴
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
            // WAN 放行是真实的暴露风险，值直接给红色，不用等风险列表来提示
            TextView v = Ui.kv(fwBox, "WAN 入站", label(wanIn));
            if ("ACCEPT".equals(wanIn)) {
                v.setTextColor(Ui.color(c, R.color.danger));
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
            TextView n = Ui.text(c, note, 11.5f, R.color.text_tertiary);
            n.setLineSpacing(Ui.dp(c, 2), 1f);
            n.setPadding(0, Ui.dp(c, 10), 0, 0);
            fwBox.addView(n);
        }

        // ---- 风险块：有才显示
        JSONArray risks = b.optJSONArray("risks");
        int count = 0;
        if (risks != null) {
            for (int i = 0; i < risks.length(); i++) {
                String r = risks.optString(i, "");
                if (r.isEmpty()) {
                    continue;
                }
                if (count > 0) {
                    riskBox.addView(Ui.hairline(c, 8));
                }
                riskBox.addView(riskRow(c, r));
                count++;
            }
        }
        if (riskCard != null) {
            riskCard.setVisibility(count > 0 ? View.VISIBLE : View.GONE);
            tvRiskTitle.setText("需要注意 · " + count + " 条");
        }
    }

    /** 一条风险：小圆点 + 说明文字。不用 ⚠ 字符 —— 不同 ROM 的字形差异很大 */
    private View riskRow(Context c, String text) {
        LinearLayout row = Ui.row(c);
        row.setPadding(0, Ui.dp(c, 9), 0, Ui.dp(c, 9));
        row.setGravity(Gravity.TOP);

        View dot = new View(c);
        GradientDrawable bg = new GradientDrawable();
        bg.setShape(GradientDrawable.OVAL);
        bg.setColor(Ui.color(c, R.color.warn));
        dot.setBackground(bg);
        LinearLayout.LayoutParams dlp = new LinearLayout.LayoutParams(Ui.dp(c, 6), Ui.dp(c, 6));
        dlp.topMargin = Ui.dp(c, 6);
        dlp.rightMargin = Ui.dp(c, 9);
        row.addView(dot, dlp);

        TextView t = Ui.text(c, text, 12.5f, R.color.text_primary);
        t.setLineSpacing(Ui.dp(c, 2), 1f);
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
}
