package com.chaof.istoreos.ui;

import android.content.Context;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import android.widget.TextView;

import com.chaof.istoreos.R;
import com.chaof.istoreos.api.Api;
import com.chaof.istoreos.api.Cb;
import com.chaof.istoreos.util.Fmt;
import com.chaof.istoreos.util.Ui;
import com.chaof.istoreos.widget.PortTile;
import com.chaof.istoreos.widget.RingView;
import com.chaof.istoreos.widget.Sheet;
import com.chaof.istoreos.widget.TrendChart;

import org.json.JSONArray;
import org.json.JSONObject;

/**
 * 概览：一屏回答「这台机器现在好不好」。
 *
 * 结构按信息优先级排，而不是按数据分类排：
 *   1. 结论（渐变主卡）—— 正常/异常、主机名、当前速率、在线设备
 *   2. 趋势（大图表）—— 刚才那一刻好不好，和过去两分钟比
 *   3. 健康（三个环）—— CPU / 内存 / 磁盘的占比
 *   4. 明细 —— 宽带、网口
 *
 * 「设备信息」和「电源控制」已经搬到设置页：前者是查资料，后者是低频危险操作，
 * 都不属于「打开就要看」的内容。概览只留能一眼判断好坏的指标。
 *
 * 之前的版本把这些平铺成一堆同级卡片，每张都「重要」，结果没有重点：
 * 用户打开 App 最想知道的「现在到底通不通、快不快」要用眼睛去几个卡里找。
 */
public class OverviewFragment extends BaseFragment {

    // hero
    private View heroDot;
    private TextView tvHeroState;
    private TextView tvHeroHost;
    private TextView tvHeroSys;
    private TextView tvHeroBadge;
    private TextView tvHeroDown;
    private TextView tvHeroUp;
    private TextView tvHeroDevices;

    // 趋势
    private TrendChart chart;
    private TextView tvPeak;

    // 健康
    private RingView ringCpu;
    private RingView ringMem;
    private RingView ringDisk;
    private TextView tvCpuAbs;
    private TextView tvMemAbs;
    private TextView tvDiskAbs;
    private TextView tvFacts;

    // WAN
    private View wanDot;
    private TextView tvWanState;
    private TextView tvWanBadge;
    private TextView tvWanIp;
    private TextView tvWanGw;
    private TextView tvWanDns;
    private TextView tvWanUp;

    private LinearLayout portBox;
    private TextView tvPortSummary;
    /** 按网口名字复用同一个 PortTile：重建视图会清掉趋势线的历史 */
    private final java.util.LinkedHashMap<String, PortTile> portTiles =
            new java.util.LinkedHashMap<>();

    private boolean wanUp = false;
    private boolean wanKnown = false;

    @Override
    protected String title() {
        return "概览";
    }

    @Override
    protected void build(LinearLayout root) {
        final Context c = ctx();
        int wrap = ViewGroup.LayoutParams.WRAP_CONTENT;
        int match = ViewGroup.LayoutParams.MATCH_PARENT;

        // ---------------------------------------------------------- 1. 结论
        Ui.Card hero = Ui.gradient(c, R.color.hero_from, R.color.hero_to);
        hero.setPadding(Ui.dp(c, 20), Ui.dp(c, 18), Ui.dp(c, 20), Ui.dp(c, 18));

        LinearLayout topRow = Ui.row(c);
        heroDot = new View(c);
        GradientDrawable hd = new GradientDrawable();
        hd.setShape(GradientDrawable.OVAL);
        hd.setColor(Ui.color(c, R.color.hero_fg));
        heroDot.setBackground(hd);
        LinearLayout.LayoutParams hdlp = new LinearLayout.LayoutParams(
                Ui.dp(c, 7), Ui.dp(c, 7));
        hdlp.rightMargin = Ui.dp(c, 7);
        topRow.addView(heroDot, hdlp);

        tvHeroState = Ui.heroNote(c, "正在连接…", 1.0f);
        tvHeroState.setTextSize(12.5f);
        tvHeroState.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        topRow.addView(tvHeroState);
        topRow.addView(new View(c), new LinearLayout.LayoutParams(0, 1, 1f));

        tvHeroBadge = Ui.heroNote(c, "—", 0.86f);
        tvHeroBadge.setTextSize(11f);
        tvHeroBadge.setPadding(Ui.dp(c, 8), Ui.dp(c, 3), Ui.dp(c, 8), Ui.dp(c, 3));
        GradientDrawable bb = new GradientDrawable();
        bb.setCornerRadius(Ui.dp(c, 100));
        bb.setColor(Ui.alpha(Ui.color(c, R.color.hero_fg), 0.16f));
        tvHeroBadge.setBackground(bb);
        topRow.addView(tvHeroBadge);
        hero.addView(topRow);

        tvHeroHost = Ui.text(c, "—", 27f, R.color.hero_fg);
        tvHeroHost.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        tvHeroHost.setIncludeFontPadding(false);
        tvHeroHost.setLetterSpacing(-0.02f);
        LinearLayout.LayoutParams hlp = new LinearLayout.LayoutParams(match, wrap);
        hlp.topMargin = Ui.dp(c, 12);
        hero.addView(tvHeroHost, hlp);

        tvHeroSys = Ui.heroNote(c, "读取中…", 0.86f);
        tvHeroSys.setPadding(0, Ui.dp(c, 5), 0, 0);
        tvHeroSys.setSingleLine(true);
        tvHeroSys.setEllipsize(android.text.TextUtils.TruncateAt.END);
        hero.addView(tvHeroSys);

        // 半透明分隔线：在渐变上不能直接用 divider 色，必须是 on_primary 的透明版
        View heroLine = new View(c);
        heroLine.setBackgroundColor(Ui.alpha(Ui.color(c, R.color.hero_fg), 0.18f));
        LinearLayout.LayoutParams hllp = new LinearLayout.LayoutParams(match,
                Math.max(1, Ui.dp(c, 0.7f)));
        hllp.topMargin = Ui.dp(c, 16);
        hllp.bottomMargin = Ui.dp(c, 14);
        hero.addView(heroLine, hllp);

        LinearLayout stats = Ui.row(c);
        stats.setBaselineAligned(false);
        tvHeroDown = heroStat(c, stats, "↓ 当前下载");
        tvHeroUp = heroStat(c, stats, "↑ 当前上传");
        tvHeroDevices = heroStat(c, stats, "在线设备");
        hero.addView(stats);
        root.addView(hero);

        // ---------------------------------------------------------- 2. 趋势
        Ui.Card trend = Ui.card(c);
        LinearLayout right = Ui.header(trend, "流量趋势", "最近 2 分钟");
        tvPeak = Ui.num(c, "", 12f, R.color.text_secondary);
        tvPeak.setGravity(Gravity.END);
        right.addView(tvPeak);

        chart = new TrendChart(c);
        LinearLayout.LayoutParams clp = new LinearLayout.LayoutParams(match, Ui.dp(c, 148));
        clp.topMargin = Ui.dp(c, 14);
        trend.addView(chart, clp);

        LinearLayout legend = Ui.row(c);
        LinearLayout.LayoutParams llp = new LinearLayout.LayoutParams(match, wrap);
        llp.topMargin = Ui.dp(c, 10);
        legend.setLayoutParams(llp);
        legend.addView(legendItem(c, "下载", R.color.primary));
        legend.addView(legendItem(c, "上传", R.color.warn));
        legend.addView(new View(c), new LinearLayout.LayoutParams(0, 1, 1f));
        TextView hint = Ui.text(c, "按住图表看数值", 11f, R.color.text_tertiary);
        legend.addView(hint);
        trend.addView(legend);

        chart.setOnPeek((index, down, up) -> {
            if (tvPeak == null) {
                return;
            }
            if (index < 0) {
                tvPeak.setText("峰值 " + Fmt.bps(chart.peak()));
            } else {
                tvPeak.setText("↓ " + Fmt.bps(down) + "　↑ " + Fmt.bps(up));
            }
        });
        root.addView(trend);

        // ---------------------------------------------------------- 3. 健康
        Ui.Card rings = Ui.card(c);
        LinearLayout healthHead = Ui.header(rings, "系统负载", "");
        tvFacts = Ui.text(c, "", 12f, R.color.text_secondary);
        tvFacts.setGravity(Gravity.END);
        healthHead.addView(tvFacts);

        LinearLayout row = Ui.row(c);
        LinearLayout.LayoutParams rlp = new LinearLayout.LayoutParams(match, wrap);
        rlp.topMargin = Ui.dp(c, 10);
        row.setLayoutParams(rlp);

        ringCpu = new RingView(c);
        ringCpu.setLabel("CPU");
        ringMem = new RingView(c);
        ringMem.setLabel("内存");
        ringDisk = new RingView(c);
        ringDisk.setLabel("磁盘");

        // 环只表达比例，绝对值必须另给一行 —— 「内存 62%」到底剩多少，
        // 是每个看这个页面的人都会问的第二个问题
        tvCpuAbs = ringCell(c, row, ringCpu);
        tvMemAbs = ringCell(c, row, ringMem);
        tvDiskAbs = ringCell(c, row, ringDisk);
        rings.addView(row);
        root.addView(rings);

        // ---------------------------------------------------------- 4. 宽带
        Ui.Card wanCard = Ui.card(c);
        LinearLayout wanHead = Ui.row(c);
        LinearLayout wanLeft = Ui.column(c);
        LinearLayout wanTitleRow = Ui.row(c);
        wanDot = new View(c);
        GradientDrawable wd = new GradientDrawable();
        wd.setShape(GradientDrawable.OVAL);
        wd.setColor(Ui.color(c, R.color.text_tertiary));
        wanDot.setBackground(wd);
        LinearLayout.LayoutParams wdlp = new LinearLayout.LayoutParams(
                Ui.dp(c, 8), Ui.dp(c, 8));
        wdlp.rightMargin = Ui.dp(c, 7);
        wanTitleRow.addView(wanDot, wdlp);
        TextView wanTitle = Ui.text(c, "宽带连接", 16.5f, R.color.text_primary);
        wanTitle.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        wanTitle.setIncludeFontPadding(false);
        wanTitleRow.addView(wanTitle);
        wanLeft.addView(wanTitleRow);
        tvWanState = Ui.text(c, "读取中…", 12.5f, R.color.text_secondary);
        tvWanState.setPadding(0, Ui.dp(c, 4), 0, 0);
        wanLeft.addView(tvWanState);
        wanHead.addView(wanLeft, new LinearLayout.LayoutParams(0, wrap, 1f));

        tvWanBadge = Ui.pill(c, "—", R.color.text_secondary);
        tvWanBadge.setClickable(true);
        tvWanBadge.setOnClickListener(v -> openWan());
        wanHead.addView(tvWanBadge);
        wanCard.addView(wanHead);

        tvWanIp = Ui.kv(wanCard, "WAN 地址", "—");
        tvWanGw = Ui.kv(wanCard, "网关", "—");
        tvWanDns = Ui.kv(wanCard, "DNS", "—");
        tvWanUp = Ui.kv(wanCard, "拨号时长", "—");

        wanCard.addView(Ui.hairline(c));

        // 「配置网络」不能只是一行绿字 —— 它是这张卡唯一可点的东西，
        // 纯文字没有可点暗示，做成次级胶囊按钮（主色淡底 + 描边）才像按钮
        TextView cfgWan = Ui.text(c, "配置网络", 14f, R.color.primary);
        cfgWan.setGravity(Gravity.CENTER);
        cfgWan.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        GradientDrawable cfgBg = new GradientDrawable();
        cfgBg.setCornerRadius(Ui.dp(c, 100));
        cfgBg.setColor(Ui.color(c, R.color.accent_soft));
        cfgBg.setStroke(Math.max(1, Ui.dp(c, 0.8f)),
                Ui.alpha(Ui.color(c, R.color.primary), 0.34f));
        cfgWan.setBackground(new android.graphics.drawable.RippleDrawable(
                android.content.res.ColorStateList.valueOf(Ui.color(c, R.color.ripple)),
                cfgBg, cfgBg));
        cfgWan.setPadding(0, Ui.dp(c, 10), 0, Ui.dp(c, 10));
        cfgWan.setOnClickListener(v -> openWan());
        LinearLayout.LayoutParams cfgLp = new LinearLayout.LayoutParams(match, wrap);
        cfgLp.topMargin = Ui.dp(c, 12);
        wanCard.addView(cfgWan, cfgLp);
        root.addView(wanCard);

        // ---------------------------------------------------------- 6. 网口
        // 六行文字谁也记不住自己在看第几个口，所以改成网格：
        // 每口一张小卡，带 RJ45 图标、速率徽标、迷你趋势线。
        // WAN 口靠主色描边一眼挑出来，不用逐个读标签。
        Ui.Card ports = Ui.card(c);
        LinearLayout portHead = Ui.header(ports, "网口", "点开看累计收发");
        tvPortSummary = Ui.pill(c, "—", R.color.text_secondary);
        portHead.addView(tvPortSummary);

        portBox = Ui.column(c);
        LinearLayout.LayoutParams plp = new LinearLayout.LayoutParams(match, wrap);
        plp.topMargin = Ui.dp(c, 14);
        portBox.setLayoutParams(plp);
        ports.addView(portBox);
        root.addView(ports);

    }

    /** 一个环 + 下面一行的绝对值小字，返回那行小字 */
    private TextView ringCell(Context c, LinearLayout parent, RingView ring) {
        LinearLayout col = Ui.column(c);
        col.setGravity(Gravity.CENTER_HORIZONTAL);
        col.addView(ring, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        TextView abs = Ui.text(c, "", 11f, R.color.text_tertiary);
        abs.setGravity(Gravity.CENTER);
        abs.setSingleLine(true);
        abs.setEllipsize(android.text.TextUtils.TruncateAt.END);
        abs.setPadding(0, Ui.dp(c, 2), 0, 0);
        col.addView(abs);

        parent.addView(col, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        return abs;
    }

    /** hero 卡上的一个指标：小标签 + 大数字 */    private TextView heroStat(Context c, LinearLayout parent, String label) {
        LinearLayout col = Ui.column(c);
        TextView l = Ui.heroNote(c, label, 0.86f);
        l.setTextSize(11f);
        l.setIncludeFontPadding(false);
        col.addView(l);

        TextView v = Ui.text(c, "—", 20f, R.color.hero_fg);
        v.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        v.setIncludeFontPadding(false);
        v.setPadding(0, Ui.dp(c, 5), 0, 0);
        v.setSingleLine(true);
        v.setEllipsize(android.text.TextUtils.TruncateAt.END);
        try {
            v.setFontFeatureSettings("'tnum'");
        } catch (Throwable ignored) {
        }
        col.addView(v);

        parent.addView(col, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        return v;
    }

    private LinearLayout legendItem(Context c, String name, int colorRes) {
        LinearLayout box = Ui.row(c);
        View d = new View(c);
        GradientDrawable bg = new GradientDrawable();
        bg.setShape(GradientDrawable.OVAL);
        bg.setColor(Ui.color(c, colorRes));
        d.setBackground(bg);
        box.addView(d, new LinearLayout.LayoutParams(Ui.dp(c, 6), Ui.dp(c, 6)));
        TextView t = Ui.text(c, name, 11.5f, R.color.text_secondary);
        LinearLayout.LayoutParams tlp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        tlp.leftMargin = Ui.dp(c, 5);
        tlp.rightMargin = Ui.dp(c, 12);
        box.addView(t, tlp);
        return box;
    }

    @Override
    protected void load(boolean quiet) {
        Api.get(ctx(), "/api/v1/overview", new Cb() {
            @Override
            public void onData(JSONObject body, boolean fromCache) {
                if (!isAdded()) {
                    return;
                }
                render(body, fromCache);
                if (!fromCache) {
                    setRefreshing(false);
                }
                markLoaded();
            }

            @Override
            public void onError(String message) {
                if (isAdded()) {
                    fail(message);
                    // 请求失败也要收骨架：让用户看到「—」和提示条，
                    // 比一直转灰块更容易理解发生了什么
                    markLoaded();
                }
            }
        });

        // WAN / 硬件 / 设备 各自单独取：刷新节奏不同（拨号状态变化慢、
        // 硬件有 30 秒后端缓存、设备列表要扫 conntrack），
        // 塞进 overview 会把首屏拖慢，而且用户看不到卡片各自到位的过程
        Api.get(ctx(), "/api/v1/network/wan", new Cb() {
            @Override
            public void onData(JSONObject body, boolean fromCache) {
                if (isAdded()) {
                    renderWan(body);
                }
            }

            @Override
            public void onError(String message) {
                if (isAdded() && tvWanState != null) {
                    tvWanState.setText("读取失败：" + message);
                }
            }
        });

        Api.get(ctx(), "/api/v1/devices", new Cb() {
            @Override
            public void onData(JSONObject body, boolean fromCache) {
                if (!isAdded() || tvHeroDevices == null) {
                    return;
                }
                JSONObject sum = body.optJSONObject("summary");
                int online = sum == null ? 0 : sum.optInt("online", 0);
                int total = sum == null ? 0 : sum.optInt("total", 0);
                tvHeroDevices.setText(online > 0 ? String.valueOf(online) : "—");
                if (total > 0) {
                    tvHeroDevices.setTag(total);
                }
            }

            @Override
            public void onError(String message) {
                // 设备数只是锦上添花，失败就留「—」
            }
        });
    }

    private void openWan() {
        startActivity(new android.content.Intent(ctx(),
                com.chaof.istoreos.WanActivity.class));
    }

    /** WAN 卡 + hero 的结论一起更新：两者说的是同一件事 */
    private void renderWan(JSONObject b) {
        JSONObject cfg = b.optJSONObject("config");
        JSONObject st = b.optJSONObject("status");
        if (cfg == null || st == null) {
            return;
        }
        Context c = ctx();
        boolean up = st.optBoolean("up", false);
        wanUp = up;
        wanKnown = true;
        String ip = st.optString("ipv4", "");

        GradientDrawable dot = new GradientDrawable();
        dot.setShape(GradientDrawable.OVAL);
        dot.setColor(Ui.color(c, up ? R.color.ok : R.color.warn));
        if (wanDot != null) {
            wanDot.setBackground(dot);
        }

        tvWanState.setText(up ? "已拨通" : Fmt.orDash(st.optString("note", "未连接")));
        tvWanState.setTextColor(Ui.color(c, up ? R.color.text_secondary : R.color.warn));

        String protoLabel = cfg.optString("proto_label", "");
        int badgeColor = up ? R.color.ok : R.color.text_secondary;
        tvWanBadge.setText(protoLabel.isEmpty() ? "配置" : protoLabel);
        tvWanBadge.setTextColor(Ui.color(c, badgeColor));
        GradientDrawable chip = new GradientDrawable();
        chip.setCornerRadius(Ui.dp(c, 100));
        int base = Ui.color(c, badgeColor);
        chip.setColor((base & 0x00FFFFFF) | 0x22000000);
        tvWanBadge.setBackground(chip);

        tvWanIp.setText(ip.isEmpty() ? "—" : ip);
        tvWanGw.setText(Fmt.orDash(st.optString("gateway", "")));
        tvWanUp.setText(st.optLong("uptime", 0) > 0
                ? Fmt.dur(st.optLong("uptime", 0)) : "—");

        JSONArray dns = st.optJSONArray("dns");
        StringBuilder sb = new StringBuilder();
        if (dns != null) {
            for (int i = 0; i < dns.length() && i < 3; i++) {
                if (sb.length() > 0) {
                    sb.append("　");
                }
                sb.append(dns.optString(i, ""));
            }
        }
        tvWanDns.setText(sb.length() == 0 ? "—" : sb.toString());

        // hero 的结论以 WAN 为准：宽带不通时，后面所有数字都没有意义
        if (tvHeroState != null) {
            tvHeroState.setText(up ? "网络正常" : "宽带未连接");
        }
        if (heroDot != null) {
            GradientDrawable hd = new GradientDrawable();
            hd.setShape(GradientDrawable.OVAL);
            // 渐变卡上用 on_primary 的「实心/空心」表达状态：
            // ok 时实心，异常时只剩一圈描边（渐变底上画红点会脏）
            if (up) {
                hd.setColor(Ui.color(c, R.color.hero_fg));
            } else {
                hd.setColor(0x00000000);
                hd.setStroke(Math.max(1, Ui.dp(c, 1.6f)),
                        Ui.color(c, R.color.hero_fg));
            }
            heroDot.setBackground(hd);
        }
    }

    private void render(JSONObject b, boolean fromCache) {
        JSONObject board = b.optJSONObject("board");
        if (board != null) {
            String host = board.optString("hostname", "");
            String model = cleanModel(board.optString("model", ""));
            String distro = board.optString("distribution", "");
            String ver = board.optString("version", "");
            String kernel = board.optString("kernel", "");

            if (tvHeroHost != null) {
                tvHeroHost.setText(Fmt.orDash(host));
            }
            if (tvHeroSys != null) {
                // 主机名大字已经写了 distro（这台机器的 hostname 就是 iStoreOS），
                // 副标题再写一遍「iStoreOS 24.10.8」就是纯重复。
                // 这里只留「型号 · 内核 · 在线时长」，三项都不和标题重叠
                StringBuilder line = new StringBuilder();
                if (!model.isEmpty()) {
                    line.append(model).append("　·　");
                }
                if (!kernel.isEmpty()) {
                    line.append("内核 ").append(kernel);
                }
                long up = (long) b.optDouble("uptime", 0);
                if (up > 0) {
                    line.append(line.length() > 0 ? "　·　" : "").append("在线 ").append(Fmt.dur(up));
                }
                if (line.length() == 0) {
                    line.append(distro);
                }
                tvHeroSys.setText(line.toString());
            }
            if (tvHeroBadge != null) {
                tvHeroBadge.setText(ver.isEmpty() ? "iStoreOS" : "iStoreOS " + ver);
            }
        }

        if (!wanKnown && tvHeroState != null) {
            tvHeroState.setText(fromCache ? "离线快照" : "运行正常");
        }

        // ---- 健康 ----
        JSONObject cpu = b.optJSONObject("cpu");
        double cpuPct = cpu == null ? 0 : cpu.optDouble("percent", 0);
        if (ringCpu != null) {
            ringCpu.set((float) cpuPct, Math.round(cpuPct) + "%");
        }

        JSONObject mem = b.optJSONObject("memory");
        if (mem != null) {
            double memPct = mem.optDouble("percent", 0);
            if (ringMem != null) {
                ringMem.set((float) memPct, Math.round(memPct) + "%");
            }
            if (tvMemAbs != null) {
                // 只显示「已用」的小字：环里已经是百分比，再写总量没信息量
                tvMemAbs.setText(Fmt.bytes(mem.optLong("used")) + " / "
                        + Fmt.bytes(mem.optLong("total")));
            }
        }

        JSONArray storage = b.optJSONArray("storage");
        JSONObject disk = biggest(storage);
        if (disk != null) {
            double dp = disk.optDouble("percent", 0);
            if (ringDisk != null) {
                ringDisk.set((float) dp, Math.round(dp) + "%");
            }
            if (tvDiskAbs != null) {
                tvDiskAbs.setText(Fmt.bytes(disk.optLong("free")) + " 可用");
            }
        } else if (ringDisk != null) {
            ringDisk.set(0, "—");
        }

        // 环下面的文字：把「环看不出绝对值」的短板补上
        StringBuilder facts = new StringBuilder();
        JSONObject load = b.optJSONObject("load");
        if (load != null) {
            facts.append("负载 ").append(String.format(java.util.Locale.US, "%.2f",
                    load.optDouble("load1", 0)));
        }
        double temp = maxTemp(b.optJSONArray("temperature"));
        // 温度放 CPU 环下面比塞进右上角那行小字更合适：
        // 它就是 CPU 的运行状态，跟着 CPU 走
        if (temp > 0 && tvCpuAbs != null) {
            tvCpuAbs.setText(Fmt.temp(temp));
            tvCpuAbs.setTextColor(Ui.color(ctx(), temp >= 80 ? R.color.danger
                    : temp >= 65 ? R.color.warn : R.color.text_tertiary));
        }
        String threads = load == null ? "" : load.optString("threads", "");
        int slash = threads.indexOf('/');
        if (slash >= 0) {
            threads = threads.substring(slash + 1);
        }
        if (!threads.isEmpty()) {
            facts.append(facts.length() > 0 ? "　·　" : "").append(threads).append(" 线程");
        }
        if (tvFacts != null) {
            tvFacts.setText(facts.length() == 0 ? "" : facts.toString());
        }

        // ---- 速率 ----
        JSONObject net = b.optJSONObject("network");
        JSONObject wan = net == null ? null : net.optJSONObject("wan");
        double rx = wan == null ? 0 : wan.optDouble("rx_bps", 0);
        double tx = wan == null ? 0 : wan.optDouble("tx_bps", 0);

        if (tvHeroDown != null) {
            tvHeroDown.setText(Fmt.bps(rx));
        }
        if (tvHeroUp != null) {
            tvHeroUp.setText(Fmt.bps(tx));
        }
        if (chart != null) {
            chart.push(rx, tx);
            if (tvPeak != null && tvPeak.getTag() == null) {
                tvPeak.setText("峰值 " + Fmt.bps(chart.peak()));
            }
        }

        renderPorts(net == null ? null : net.optJSONArray("ports"));
    }

    /**
     * 网口网格。
     *
     * 三件事必须分开做，否则每 3 秒刷新一次界面就会「闪」：
     *  1. 网口集合变了才重建行列（拔插 USB 网卡、改 LAN 口数）
     *  2. 集合没变就只往里喂数据，PortTile 自己更新文字和趋势线
     *  3. 趋势线历史存在 PortTile 内部，所以第 2 步不能改成「清空重建」
     */
    private void renderPorts(JSONArray ports) {
        if (portBox == null) {
            return;
        }
        Context c = portBox.getContext();
        int wrap = ViewGroup.LayoutParams.WRAP_CONTENT;

        // ---- 读出来并排好序：WAN 在最前，其余按接口名
        java.util.List<JSONObject> list = new java.util.ArrayList<>();
        if (ports != null) {
            for (int i = 0; i < ports.length(); i++) {
                JSONObject p = ports.optJSONObject(i);
                if (p != null && !p.optString("name", "").isEmpty()) {
                    list.add(p);
                }
            }
        }
        list.sort((a, b) -> {
            boolean wa = "wan".equals(a.optString("role", ""));
            boolean wb = "wan".equals(b.optString("role", ""));
            if (wa != wb) {
                return wa ? -1 : 1;
            }
            return a.optString("name", "").compareTo(b.optString("name", ""));
        });

        java.util.List<String> names = new java.util.ArrayList<>();
        for (JSONObject p : list) {
            names.add(p.optString("name", ""));
        }

        // ---- 集合变了才重建布局
        if (!names.equals(lastPortNames)) {
            lastPortNames = new java.util.ArrayList<>(names);
            // 已经拔掉的网口把 tile 一起扔掉，免得历史越攒越多
            portTiles.keySet().retainAll(names);
            rebuildPortGrid(c, names);
        }

        // ---- 喂数据
        int online = 0;
        for (JSONObject p : list) {
            String name = p.optString("name", "");
            PortTile tile = portTiles.get(name);
            if (tile == null) {
                continue;
            }
            boolean up = p.optBoolean("up", false);
            if (up) {
                online++;
            }
            tile.set(name,
                    p.optString("role", ""),
                    up,
                    p.optInt("speed_mbps", 0),
                    p.optDouble("rx_bps", 0),
                    p.optDouble("tx_bps", 0),
                    p.optLong("rx_total", 0),
                    p.optLong("tx_total", 0),
                    p.optString("mac", ""));
        }

        if (tvPortSummary != null) {
            int total = list.size();
            tvPortSummary.setText(total == 0 ? "—" : online + "/" + total + " 在线");
            tvPortSummary.setTextColor(Ui.color(c,
                    online > 0 ? R.color.primary : R.color.text_secondary));
        }
        if (list.isEmpty()) {
            TextView empty = Ui.text(c, "没有检测到物理网口", 12.5f, R.color.text_secondary);
            empty.setGravity(Gravity.CENTER);
            empty.setPadding(0, Ui.dp(c, 10), 0, Ui.dp(c, 6));
            portBox.addView(empty);
        }
    }

    private java.util.List<String> lastPortNames = new java.util.ArrayList<>();

    /** 两列网格。列数写死为 2：手机宽度下三列每个口只剩 90dp，图标和速率会挤在一起。 */
    private void rebuildPortGrid(Context c, java.util.List<String> names) {
        portBox.removeAllViews();
        if (names.isEmpty()) {
            return;
        }
        int gap = Ui.dp(c, 9);
        for (int i = 0; i < names.size(); i += 2) {
            LinearLayout row = Ui.row(c);
            row.setBaselineAligned(false);
            LinearLayout.LayoutParams rlp = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            if (i > 0) {
                rlp.topMargin = gap;
            }
            row.setLayoutParams(rlp);

            PortTile left = tileFor(c, names.get(i));
            LinearLayout.LayoutParams llp = new LinearLayout.LayoutParams(
                    0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
            row.addView(left, llp);

            if (i + 1 < names.size()) {
                PortTile right = tileFor(c, names.get(i + 1));
                LinearLayout.LayoutParams xlp = new LinearLayout.LayoutParams(
                        0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
                xlp.leftMargin = gap;
                row.addView(right, xlp);
            } else {
                // 单数个口时补一个透明占位，否则最后一张卡会横跨两列
                row.addView(new View(c), new LinearLayout.LayoutParams(
                        0, 1, 1f));
            }
            portBox.addView(row);
        }
    }

    private PortTile tileFor(Context c, String name) {
        PortTile tile = portTiles.get(name);
        if (tile == null) {
            tile = new PortTile(c);
            final PortTile target = tile;
            tile.setOnClickListener(v -> {
                Sheet.message(c, "网口 " + target.portName(), target.detailText());
            });
            portTiles.put(name, tile);
        }
        return tile;
    }

    @Override
    public void onResume() {
        super.onResume();
        // 从宽带配置页回来时 WAN 可能已经变了，重置标志让 hero 重新判定
        wanKnown = false;
    }

    /**
     * 台式机的 DMI 型号很多是 BIOS 占位符（「Default string」「To Be Filled By O.E.M.」等），
     * 直接显示等于什么都没说，这里当作空值处理。
     */
    private static String cleanModel(String model) {
        if (model == null) {
            return "";
        }
        String t = model.trim();
        if (t.isEmpty()) {
            return "";
        }
        String lower = t.toLowerCase(java.util.Locale.US);
        if (lower.matches("^(default string|system product name|system version|"
                + "to be filled by o\\.e\\.m\\.?|not specified|not applicable|unknown|oem|"
                + "default|empty|none)(\\s+.*)?$")) {
            return "";
        }
        return t;
    }

    private static String join(String a, String b) {
        if (a == null || a.isEmpty()) {
            return b == null ? "" : b;
        }
        if (b == null || b.isEmpty()) {
            return a;
        }
        return a + " · " + b;
    }

    private static JSONObject biggest(JSONArray arr) {
        if (arr == null || arr.length() == 0) {
            return null;
        }
        JSONObject best = null;
        long bestTotal = -1;
        for (int i = 0; i < arr.length(); i++) {
            JSONObject o = arr.optJSONObject(i);
            if (o == null) {
                continue;
            }
            long total = o.optLong("total", 0);
            if (total > bestTotal) {
                bestTotal = total;
                best = o;
            }
        }
        return best;
    }

    private static double maxTemp(JSONArray arr) {
        if (arr == null) {
            return 0;
        }
        double m = 0;
        for (int i = 0; i < arr.length(); i++) {
            JSONObject o = arr.optJSONObject(i);
            if (o != null) {
                m = Math.max(m, o.optDouble("celsius", 0));
            }
        }
        return m;
    }
}
