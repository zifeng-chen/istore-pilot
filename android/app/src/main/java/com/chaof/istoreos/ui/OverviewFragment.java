package com.chaof.istoreos.ui;

import com.chaof.istoreos.widget.MeterBar;

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

    /** 走秒的运行时长：hero 副标题拆成「型号 · 内核」前缀 + 每秒自增的秒数 */
    private String heroSysPrefix = "";
    private long upBase = 0;
    private long upAt = 0;
    private final android.os.Handler upHandler =
            new android.os.Handler(android.os.Looper.getMainLooper());
    private final Runnable upTick = new Runnable() {
        @Override
        public void run() {
            paintHeroSys();
            upHandler.postDelayed(this, 1000);
        }
    };
    private TextView tvHeroBadge;
    private TextView tvHeroDown;
    private TextView tvHeroUp;
    private TextView tvHeroDevices;

    // 趋势
    private TrendChart chart;
    private TextView tvPeak;

    // 健康
    private MeterBar meterCpu;
    private MeterBar meterMem;
    private MeterBar meterDisk;
    private TextView tvFacts;

    // WAN
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

        // 趋势图直接长在 hero 里。原来它在下面另一张卡上，同一件事
        // （网快不快）被拆成两块看，往下滚还得来回对照
        // 不再套一层半透明面板：多一层底色会把图压成「卡片里的小卡片」，
        // 而且左右各 12dp 的内边距让折线缩在中间。现在图和上面的
        // 三个数字左对齐、贴着卡片内容区，视觉上就是一体的
        LinearLayout trendBox = Ui.column(c);
        trendBox.setBackground(null);
        trendBox.setPadding(0, 0, 0, 0);
        LinearLayout.LayoutParams tbLp = new LinearLayout.LayoutParams(match, wrap);
        tbLp.topMargin = Ui.dp(c, 18);
        trendBox.setLayoutParams(tbLp);

        LinearLayout tHead = Ui.row(c);
        TextView tTitle = Ui.heroNote(c, "流量趋势 · 最近 2 分钟", 0.86f);
        tTitle.setTextSize(11.5f);
        tHead.addView(tTitle, new LinearLayout.LayoutParams(0, wrap, 1f));
        tvPeak = Ui.heroNote(c, "", 0.9f);
        tvPeak.setTextSize(11.5f);
        tHead.addView(tvPeak);
        trendBox.addView(tHead);

        chart = new TrendChart(c);
        chart.useOnHero();
        LinearLayout.LayoutParams clp = new LinearLayout.LayoutParams(match, Ui.dp(c, 104));
        clp.topMargin = Ui.dp(c, 8);
        trendBox.addView(chart, clp);

        LinearLayout legend = Ui.row(c);
        LinearLayout.LayoutParams llp = new LinearLayout.LayoutParams(match, wrap);
        llp.topMargin = Ui.dp(c, 8);
        legend.setLayoutParams(llp);
        legend.addView(heroLegend(c, "下载", R.color.primary));
        legend.addView(heroLegend(c, "上传", R.color.warn));
        legend.addView(new View(c), new LinearLayout.LayoutParams(0, 1, 1f));
        TextView hint = Ui.heroNote(c, "按住图表看数值", 0.62f);
        hint.setTextSize(10.5f);
        legend.addView(hint);
        trendBox.addView(legend);

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

        hero.addView(trendBox);
        root.addView(hero);

        // ---------------------------------------------------------- 3. 健康
        Ui.Card rings = Ui.card(c);
        // 与「设备」「拦截」卡同一套标题行：28dp 图标块 + 16.5sp 标题 + 12sp 副标题。
        // 卡片自己左右归零，内边距交给标题行和每根进度条，四张卡的行首才对得齐
        Ui.cardPadding(rings, 0);
        Ui.CardHead healthHead = Ui.cardTitleLive(c, rings,
                com.chaof.istoreos.widget.Glyph.CHIP, "系统负载", "CPU · 内存 · 磁盘");
        tvFacts = Ui.text(c, "", 12f, R.color.text_secondary);
        tvFacts.setGravity(Gravity.END);
        healthHead.right.addView(tvFacts);

        // 横向进度条替掉三个环：环并排要吃掉半屏，却只表达三个百分比。
        // 横条能一行一个，还能把「4 核 1.2 GHz」「3.2 / 8 GB」写在名字后面
        meterCpu = new MeterBar(c, "CPU");
        meterMem = new MeterBar(c, "内存");
        meterDisk = new MeterBar(c, "磁盘");
        LinearLayout.LayoutParams mlp = new LinearLayout.LayoutParams(match, wrap);
        mlp.topMargin = Ui.dp(c, 14);
        mlp.leftMargin = Ui.dp(c, 16);
        mlp.rightMargin = Ui.dp(c, 16);
        rings.addView(meterCpu, mlp);
        LinearLayout.LayoutParams mlp2 = new LinearLayout.LayoutParams(match, wrap);
        mlp2.topMargin = Ui.dp(c, 14);
        mlp2.leftMargin = Ui.dp(c, 16);
        mlp2.rightMargin = Ui.dp(c, 16);
        rings.addView(meterMem, mlp2);
        LinearLayout.LayoutParams mlp3 = new LinearLayout.LayoutParams(match, wrap);
        mlp3.topMargin = Ui.dp(c, 14);
        mlp3.leftMargin = Ui.dp(c, 16);
        mlp3.rightMargin = Ui.dp(c, 16);
        rings.addView(meterDisk, mlp3);
        root.addView(rings);

        // ---------------------------------------------------------- 4. 宽带
        Ui.Card wanCard = Ui.card(c);
        Ui.cardPadding(wanCard, 11);   // 最后一行是设置行，自带 11
        Ui.CardHead wanHead = Ui.cardTitleLive(c, wanCard,
                com.chaof.istoreos.widget.Glyph.GLOBE, "宽带连接", "读取中…");
        // 副标题是活的：连上/断开、失败原因都写这儿，拿 CardHead 的引用直接改
        tvWanState = wanHead.sub;

        tvWanBadge = Ui.pill(c, "—", R.color.text_secondary);
        tvWanBadge.setClickable(true);
        tvWanBadge.setOnClickListener(v -> openWan());
        wanHead.right.addView(tvWanBadge);

        // kv 行没有自己的左右内边距（靠卡片内边距撑开），卡片归零后要包一层
        LinearLayout wanInfo = Ui.column(c);
        wanInfo.setPadding(Ui.dp(c, 16), 0, Ui.dp(c, 16), 0);
        wanCard.addView(wanInfo);

        tvWanIp = Ui.kv(wanInfo, "WAN 地址", "—");
        tvWanGw = Ui.kv(wanInfo, "网关", "—");
        tvWanDns = Ui.kv(wanInfo, "DNS", "—");
        tvWanUp = Ui.kv(wanInfo, "拨号时长", "—");

        // 最后一行和分割线之间留 12：原来紧贴着，看起来像粘在一起
        Ui.space(c, wanCard, 12);
        wanCard.addView(Ui.hairline(c));

        // 原来是一个横贯整卡的主色胶囊按钮，跟别处「一行带图标的入口」不是一套。
        // 换成设置页那种行：图标块 + 标题 + 副标题 + 箭头
        Ui.settingRow(c, wanCard, com.chaof.istoreos.widget.Glyph.LINK,
                "网络设置", "WAN / LAN / 无线 / 端口转发", "", true, false,
                () -> openWan());
        root.addView(wanCard);

        // ---------------------------------------------------------- 6. 网口
        // 六行文字谁也记不住自己在看第几个口，所以改成网格：
        // 每口一张小卡，带 RJ45 图标、速率徽标、迷你趋势线。
        // WAN 口靠主色描边一眼挑出来，不用逐个读标签。
        Ui.Card ports = Ui.card(c);
        Ui.cardPadding(ports, 0);
        Ui.CardHead portHead = Ui.cardTitleLive(c, ports,
                com.chaof.istoreos.widget.Glyph.BOX, "网口", "点开看累计收发");
        tvPortSummary = Ui.pill(c, "—", R.color.text_secondary);
        portHead.right.addView(tvPortSummary);

        portBox = Ui.column(c);
        LinearLayout.LayoutParams plp = new LinearLayout.LayoutParams(match, wrap);
        plp.topMargin = Ui.dp(c, 14);
        plp.leftMargin = Ui.dp(c, 16);
        plp.rightMargin = Ui.dp(c, 16);
        portBox.setLayoutParams(plp);
        ports.addView(portBox);
        root.addView(ports);

    }

    /** hero 卡上的一个指标：小标签 + 大数字 */
    private TextView heroStat(Context c, LinearLayout parent, String label) {
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

    /** hero 卡里的小图例：一个色点 + 文字，文字用 on-primary 的透明版 */
    private LinearLayout heroLegend(Context c, String text, int colorRes) {
        LinearLayout row = Ui.row(c);
        row.setGravity(Gravity.CENTER_VERTICAL);
        View dot = new View(c);
        GradientDrawable d = new GradientDrawable();
        d.setShape(GradientDrawable.OVAL);
        d.setColor(Ui.color(c, colorRes));
        dot.setBackground(d);
        LinearLayout.LayoutParams dlp = new LinearLayout.LayoutParams(Ui.dp(c, 7), Ui.dp(c, 7));
        dlp.rightMargin = Ui.dp(c, 5);
        row.addView(dot, dlp);
        TextView label = Ui.heroNote(c, text, 0.78f);
        label.setTextSize(10.5f);
        row.addView(label);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.rightMargin = Ui.dp(c, 14);
        row.setLayoutParams(lp);
        return row;
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

        // 状态点没了：标题行统一成图标块，连没连上由副标题文字和颜色表达
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
                heroSysPrefix = line.length() > 0 ? line.toString() : distro;
                upBase = Math.max(0, (long) b.optDouble("uptime", 0));
                upAt = android.os.SystemClock.elapsedRealtime();
                paintHeroSys();
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
        double temp = maxTemp(b.optJSONArray("temperature"));

        JSONObject load = b.optJSONObject("load");
        String threads = load == null ? "" : load.optString("threads", "");
        int slash = threads.indexOf('/');
        if (slash >= 0) {
            threads = threads.substring(slash + 1);
        }
        if (meterCpu != null) {
            meterCpu.setRatio((float) (cpuPct / 100.0));
            meterCpu.setValue(Math.round(cpuPct) + "%");
            StringBuilder detail = new StringBuilder();
            if (!threads.isEmpty()) {
                detail.append(threads).append(" 线程");
            }
            if (temp > 0) {
                detail.append(detail.length() > 0 ? "　" : "").append(Fmt.temp(temp));
            }
            meterCpu.setDetail(detail.toString());
        }

        JSONObject mem = b.optJSONObject("memory");
        if (mem != null && meterMem != null) {
            double memPct = mem.optDouble("percent", 0);
            meterMem.setRatio((float) (memPct / 100.0));
            meterMem.setValue(Math.round(memPct) + "%");
            // 百分比旁边给绝对值：只写「62%」永远有人问「那还剩多少」
            meterMem.setDetail(Fmt.bytes(mem.optLong("used")) + " / "
                    + Fmt.bytes(mem.optLong("total")));
        }

        JSONArray storage = b.optJSONArray("storage");
        JSONObject disk = biggest(storage);
        if (meterDisk != null) {
            if (disk != null) {
                double dp = disk.optDouble("percent", 0);
                meterDisk.setRatio((float) (dp / 100.0));
                meterDisk.setValue(Math.round(dp) + "%");
                meterDisk.setDetail(Fmt.bytes(disk.optLong("free")) + " 可用");
            } else {
                meterDisk.setRatio(0f);
                meterDisk.setValue("—");
                meterDisk.setDetail("");
            }
        }

        if (tvFacts != null) {
            double load1 = load == null ? 0 : load.optDouble("load1", 0);
            tvFacts.setText(load1 > 0
                    ? String.format(java.util.Locale.US, "负载 %.2f", load1) : "");
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
        // 运行时长按秒走：3 秒轮询只管校准基准值，中间这两秒本地往前推
        upHandler.removeCallbacks(upTick);
        upHandler.postDelayed(upTick, 1000);
    }

    @Override
    public void onPause() {
        super.onPause();
        upHandler.removeCallbacks(upTick);
    }

    /** hero 副标题里的运行时长，每秒重画一次 */
    private void paintHeroSys() {
        if (tvHeroSys == null) {
            return;
        }
        StringBuilder line = new StringBuilder(heroSysPrefix == null ? "" : heroSysPrefix);
        if (upBase > 0) {
            long sec = upBase + (android.os.SystemClock.elapsedRealtime() - upAt) / 1000;
            if (line.length() > 0) {
                line.append("　·　");
            }
            line.append("在线 ").append(Fmt.uptime(sec));
        }
        tvHeroSys.setText(line.length() == 0 ? "iStoreOS" : line.toString());
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
