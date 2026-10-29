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

import com.chaof.istoreos.AdblockLogActivity;
import com.chaof.istoreos.DeviceDetailActivity;
import com.chaof.istoreos.AppsActivity;
import com.chaof.istoreos.R;
import com.chaof.istoreos.SecurityAdblockActivity;
import com.chaof.istoreos.SecurityDevicesActivity;
import com.chaof.istoreos.api.Api;
import com.chaof.istoreos.api.Cb;
import com.chaof.istoreos.util.Fmt;
import com.chaof.istoreos.util.Ui;
import com.chaof.istoreos.widget.Glyph;
import com.chaof.istoreos.widget.Sheet;
import com.chaof.istoreos.widget.Toggle;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.List;

/**
 * 设备与拦截（合并后的一级页）。
 *
 * 原来「设备」和「拦截」是两个并列页签，各自都有一套完整的功能：
 * 设备页有搜索、分段、应用流量；拦截页有链路图、规则表、体检、日志。
 * 五个页签里放两个「管理型」页面，打开 App 的人却只想知道
 * 「几台连着 / 今天挡了多少」——真正要动手的事一周才发生一次。
 *
 * 所以把它们合成一个入口，一级只留三件事：
 *   1. 现在有多少台在线、多少台离线、几台被禁网（一眼看完）
 *   2. 拦截在不在工作、今天挡了多少（一眼看完）
 *   3. 两个最大开关：接管全网 / 进入清单（点一下就走）
 * 其余全部下沉到二级页，一级页不出现搜索框、分段控件、规则表。
 *
 * 这样底部只需要四个业务页签：概览 / 网络 / 设备 / 代理（+ 设置），
 * 才发现「网络配置」一直没有独立入口 —— 它原来藏在概览的宽带卡后面。
 */
public class SecurityFragment extends BaseFragment {

    private TextView tvHeroOnline;
    private TextView tvHeroAd;
    private TextView tvHeroRate;
    private TextView tvHeroNote;
    private TextView tvHeroBadge;

    private TextView tvStatOn;
    private TextView tvStatOff;
    private TextView tvStatBlocked;
    private LinearLayout recentBox;
    private TextView tvRecentEmpty;

    private TextView tvAdState;
    private TextView tvAdBlocked;
    private TextView tvAdSub;
    private TextView tvAdRate;
    private Toggle swTakeover;
    private boolean syncing = false;

    private JSONArray devices = new JSONArray();
    private AppsCard appsCard;
    private String structure = "";
    private boolean adInstalled = false;
    private boolean adTakeover = false;
    private int adPercent = 0;

    @Override
    protected String title() {
        return "设备";
    }

    @Override
    protected void build(LinearLayout root) {
        final Context c = ctx();

        // ---------------------------------------------------------- hero
        Ui.Card hero = Ui.gradient(c, R.color.hero_from, R.color.hero_to);
        hero.setPadding(Ui.dp(c, 20), Ui.dp(c, 18), Ui.dp(c, 20), Ui.dp(c, 18));

        LinearLayout top = Ui.row(c);
        View dot = new View(c);
        GradientDrawable hd = new GradientDrawable();
        hd.setShape(GradientDrawable.OVAL);
        hd.setColor(Ui.color(c, R.color.hero_fg));
        dot.setBackground(hd);
        LinearLayout.LayoutParams dlp = new LinearLayout.LayoutParams(Ui.dp(c, 7), Ui.dp(c, 7));
        dlp.rightMargin = Ui.dp(c, 7);
        top.addView(dot, dlp);

        TextView cap = Ui.heroNote(c, "局域网", 1.0f);
        cap.setTextSize(12.5f);
        cap.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        top.addView(cap, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        tvHeroBadge = Ui.heroNote(c, "拦截 —", 0.86f);
        tvHeroBadge.setTextSize(11f);
        tvHeroBadge.setPadding(Ui.dp(c, 9), Ui.dp(c, 4), Ui.dp(c, 9), Ui.dp(c, 4));
        GradientDrawable bb = new GradientDrawable();
        bb.setCornerRadius(Ui.dp(c, 100));
        bb.setColor(Ui.alpha(Ui.color(c, R.color.hero_fg), 0.16f));
        tvHeroBadge.setBackground(bb);
        top.addView(tvHeroBadge);
        hero.addView(top);

        // 总览三栏：在线设备 / 今日拦截 / 实时流量。
        // 原来这里只有一个「48 台设备在线」的大数字，占了一整块却只说一件事；
        // 一级页最该被一眼看到的是这三项，具体的设备清单、拦截明细都在下面
        LinearLayout statLine = Ui.row(c);
        LinearLayout.LayoutParams slp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        slp.topMargin = Ui.dp(c, 14);
        statLine.setLayoutParams(slp);

        tvHeroOnline = heroStat(c, statLine, "设备在线", c);
        tvHeroAd = heroStat(c, statLine, "今日拦截", c);
        tvHeroRate = heroStat(c, statLine, "实时流量", c);
        hero.addView(statLine);

        tvHeroNote = Ui.heroNote(c, "正在读取…", 0.78f);
        tvHeroNote.setTextSize(12f);
        tvHeroNote.setPadding(0, Ui.dp(c, 4), 0, 0);
        hero.addView(tvHeroNote);
        root.addView(hero);

        // ---------------------------------------------------------- 设备
        Ui.Card dev = Ui.card(c);
        Ui.cardPadding(dev, 9);    // 最后一行是「最近活跃」，行内 9
        LinearLayout devHead = Ui.cardTitle(c, dev, Glyph.LINK, "设备", "点数字进清单，点行看详情");
        TextView allDev = Ui.text(c, "全部 ›", 13f, R.color.primary);
        allDev.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        allDev.setOnClickListener(v -> openDevices(0));
        devHead.addView(allDev);

        LinearLayout statRow = Ui.row(c);
        statRow.setPadding(0, Ui.dp(c, 14), 0, Ui.dp(c, 4));
        tvStatOn = statCell(c, statRow, "在线", R.color.primary, () -> openDevices(1));
        tvStatOff = statCell(c, statRow, "离线", R.color.text_primary, () -> openDevices(2));
        tvStatBlocked = statCell(c, statRow, "已禁网", R.color.danger, () -> openDevices(0));
        dev.addView(statRow);

        dev.addView(Ui.hairline(c, 16));
        TextView recentTitle = Ui.text(c, "最近活跃", 11.5f, R.color.text_secondary);
        recentTitle.setPadding(Ui.dp(c, 16), Ui.dp(c, 10), Ui.dp(c, 16), Ui.dp(c, 2));
        dev.addView(recentTitle);

        recentBox = Ui.column(c);
        dev.addView(recentBox);

        tvRecentEmpty = Ui.text(c, "还没有设备上线", 13f, R.color.text_tertiary);
        tvRecentEmpty.setPadding(Ui.dp(c, 16), Ui.dp(c, 8), Ui.dp(c, 16), Ui.dp(c, 8));
        dev.addView(tvRecentEmpty);
        root.addView(dev);

        // ---------------------------------------------------------- 应用流量
        // 原来这张卡在「设备清单」二级页里，得先点进来才看得到。它回答的是
        // 「谁在吃带宽」，属于一眼就想知道的东西，所以提到一级页
        appsCard = new AppsCard(c, v -> startActivity(new Intent(ctx(), AppsActivity.class)));
        LinearLayout.LayoutParams alp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        alp.topMargin = Ui.dp(c, 12);
        appsCard.view().setLayoutParams(alp);
        root.addView(appsCard.view());

        // ---------------------------------------------------------- 拦截
        Ui.Card ad = Ui.card(c);
        Ui.cardPadding(ad, 10);    // 最后一行是接管开关，行内 10
        LinearLayout adHead = Ui.cardTitle(c, ad, Glyph.SHIELD, "拦截", "AdGuard Home");
        tvAdState = Ui.pill(c, "—", R.color.text_secondary);
        adHead.addView(tvAdState);

        LinearLayout adLine = Ui.row(c);
        adLine.setGravity(Gravity.BOTTOM);
        adLine.setPadding(Ui.dp(c, 16), Ui.dp(c, 16), Ui.dp(c, 16), 0);
        tvAdBlocked = Ui.num(c, "—", 30f, R.color.text_primary);
        adLine.addView(tvAdBlocked);
        TextView adUnit = Ui.text(c, "次拦截", 12.5f, R.color.text_secondary);
        adUnit.setPadding(Ui.dp(c, 7), 0, 0, Ui.dp(c, 6));
        adLine.addView(adUnit);
        ad.addView(adLine);

        tvAdSub = Ui.text(c, "共查询 — 次", 12f, R.color.text_secondary);
        tvAdSub.setPadding(Ui.dp(c, 16), Ui.dp(c, 4), Ui.dp(c, 16), 0);
        ad.addView(tvAdSub);

        tvAdRate = Ui.text(c, "拦截率 —", 12f, R.color.text_secondary);
        tvAdRate.setPadding(Ui.dp(c, 16), Ui.dp(c, 2), Ui.dp(c, 16), 0);
        ad.addView(tvAdRate);

        // 总开关：接管全网是所有拦截功能的前提，所以放在一级页而不是二级页。
        // 它改的是 DNS 走向 —— 全网设备解析都会变，属于「肯定影响网络」的项，
        // 所以点一下不直接生效，先弹确认（见 onTakeover）。
        LinearLayout swRow = Ui.row(c);
        swRow.setGravity(Gravity.CENTER_VERTICAL);
        swRow.setPadding(Ui.dp(c, 16), Ui.dp(c, 14), Ui.dp(c, 16), Ui.dp(c, 10));
        LinearLayout swCol = Ui.column(c);
        TextView swTitle = Ui.text(c, "接管全网 DNS", 15f, R.color.text_primary);
        swTitle.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        swCol.addView(swTitle);
        TextView swSub = Ui.text(c, "关闭后所有设备改回运营商 DNS", 11.5f, R.color.text_secondary);
        swSub.setPadding(0, Ui.dp(c, 4), 0, 0);
        swCol.addView(swSub);
        swRow.addView(swCol, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        swTakeover = new Toggle(c);
        swTakeover.setEnabledState(false);
        swTakeover.setOnChange(on -> {
            if (syncing) {
                return true;
            }
            askTakeover(on);
            return false; // 真正生效要等接口回来，先不让视觉状态自己跑
        });
        swRow.addView(swTakeover, new LinearLayout.LayoutParams(
                Ui.dp(c, 48), Ui.dp(c, 28)));
        ad.addView(swRow);

        ad.addView(entryRow(c, Glyph.REFRESH, "规则与更新", "自动更新频率、规则表开关",
                true, this::openAdblock));
        ad.addView(entryRow(c, Glyph.LIST, "拦截日志", "最近被挡掉的域名查询",
                false, () -> startActivity(new Intent(ctx(), AdblockLogActivity.class))));
        root.addView(ad);

        Ui.space(c, root, 8);
    }


    /** hero 里的一格：上面大数字、下面小标题，返回数字控件 */
    private TextView heroStat(Context c, LinearLayout parent, String label, Context unused) {
        LinearLayout col = Ui.column(c);
        TextView num = Ui.heroNumber(c, "—");
        num.setTextSize(24f);
        col.addView(num);
        TextView cap = Ui.heroNote(c, label, 0.82f);
        cap.setTextSize(11.5f);
        cap.setPadding(0, Ui.dp(c, 3), 0, 0);
        col.addView(cap);
        parent.addView(col, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        return num;
    }

    /** 一行「图标 + 标题 + 副标题 + 箭头」的二级页入口，风格跟设置页一致 */
    private View entryRow(Context c, int glyph, String title, String sub,
                          boolean first, Runnable onClick) {
        LinearLayout box = Ui.column(c);
        if (!first) {
            // 分隔线从图标右侧开始，和设置页的 inset 对齐
            box.addView(Ui.hairline(c, 16));
        }
        LinearLayout row = Ui.row(c);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(Ui.dp(c, 16), Ui.dp(c, 11), Ui.dp(c, 14), Ui.dp(c, 11));

        LinearLayout wrap = Ui.row(c);
        wrap.setGravity(Gravity.CENTER);
        GradientDrawable tile = new GradientDrawable();
        tile.setCornerRadius(Ui.dp(c, 9));
        int base = Ui.color(c, R.color.primary);
        tile.setColor((base & 0x00FFFFFF) | 0x1F000000);
        wrap.setBackground(tile);
        Glyph g = new Glyph(c);
        g.setKind(glyph);
        g.setColor(Ui.color(c, R.color.primary));
        wrap.addView(g, new LinearLayout.LayoutParams(Ui.dp(c, 17), Ui.dp(c, 17)));
        LinearLayout.LayoutParams wlp = new LinearLayout.LayoutParams(Ui.dp(c, 30), Ui.dp(c, 30));
        wlp.rightMargin = Ui.dp(c, 11);
        row.addView(wrap, wlp);

        LinearLayout col = Ui.column(c);
        TextView t = Ui.text(c, title, 14.5f, R.color.text_primary);
        t.setIncludeFontPadding(false);
        col.addView(t);
        TextView s = Ui.text(c, sub, 11.5f, R.color.text_secondary);
        s.setPadding(0, Ui.dp(c, 3), 0, 0);
        col.addView(s);
        row.addView(col, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        TextView arrow = Ui.text(c, "\u203A", 17f, R.color.text_tertiary);
        row.addView(arrow);

        GradientDrawable mask = new GradientDrawable();
        mask.setColor(0xFFFFFFFF);
        row.setBackground(new android.graphics.drawable.RippleDrawable(
                android.content.res.ColorStateList.valueOf(Ui.color(c, R.color.ripple)),
                null, mask));
        row.setClickable(true);
        row.setOnClickListener(v -> onClick.run());
        box.addView(row);
        return box;
    }

    /** 设备卡里的一个数字块，返回数字那个 TextView */
    private TextView statCell(Context c, LinearLayout parent, String label,
                              int colorRes, Runnable onClick) {
        LinearLayout col = Ui.column(c);
        col.setGravity(Gravity.CENTER_HORIZONTAL);
        TextView v = Ui.num(c, "—", 25f, colorRes);
        v.setGravity(Gravity.CENTER);
        col.addView(v);
        TextView l = Ui.text(c, label, 11.5f, R.color.text_secondary);
        l.setGravity(Gravity.CENTER);
        l.setPadding(0, Ui.dp(c, 3), 0, 0);
        col.addView(l);
        if (onClick != null) {
            col.setClickable(true);
            col.setFocusable(true);
            col.setOnClickListener(x -> onClick.run());
        }
        parent.addView(col, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        return v;
    }

    private void openDevices(int mode) {
        Intent i = new Intent(ctx(), SecurityDevicesActivity.class);
        i.putExtra("mode", mode);
        startActivity(i);
    }

    private void openAdblock() {
        startActivity(new Intent(ctx(), SecurityAdblockActivity.class));
    }

    // ---------------------------------------------------------------- 数据

    @Override
    protected void load(boolean quiet) {
        if (appsCard != null) {
            appsCard.refresh();
        }

        Api.get(ctx(), "/api/v1/devices", new Cb() {
            @Override
            public void onData(JSONObject body, boolean fromCache) {
                if (!isAdded()) {
                    return;
                }
                devices = body.optJSONArray("devices");
                if (devices == null) {
                    devices = new JSONArray();
                }
                renderDevices(body.optJSONObject("summary"));
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

        Api.get(ctx(), "/api/v1/adblock", new Cb() {
            @Override
            public void onData(JSONObject body, boolean fromCache) {
                if (isAdded()) {
                    renderAd(body);
                }
            }

            @Override
            public void onError(String message) {
                if (isAdded() && tvAdState != null) {
                    tvAdState.setText("不可用");
                }
            }
        });
    }

    private void renderDevices(JSONObject sum) {
        int online = 0, total = 0, blocked = 0;
        JSONObject s = sum;
        if (s != null) {
            online = s.optInt("online", 0);
            total = s.optInt("total", 0);
            blocked = s.optInt("blocked", 0);
        } else {
            for (int i = 0; i < devices.length(); i++) {
                JSONObject d = devices.optJSONObject(i);
                if (d == null) {
                    continue;
                }
                total++;
                if (d.optBoolean("online")) {
                    online++;
                }
                if (d.optBoolean("blocked")) {
                    blocked++;
                }
            }
        }
        int offline = Math.max(0, total - online);

        tvHeroOnline.setText(online > 0 ? String.valueOf(online) : "0");

        double bps = 0;
        for (int i = 0; i < devices.length(); i++) {
            JSONObject d = devices.optJSONObject(i);
            JSONObject n = d == null ? null : d.optJSONObject("net");
            if (n != null) {
                bps += n.optDouble("rx_bps", 0) + n.optDouble("tx_bps", 0);
            }
        }
        if (tvHeroRate != null) {
            tvHeroRate.setText(bps < 1024 ? "0" : Fmt.bps(bps));
        }
        tvStatOn.setText(String.valueOf(online));
        tvStatOff.setText(String.valueOf(offline));
        tvStatBlocked.setText(String.valueOf(blocked));

        StringBuilder note = new StringBuilder();
        note.append("共 ").append(total).append(" 台");
        if (blocked > 0) {
            note.append("　·　").append(blocked).append(" 台已禁网");
        }
        tvHeroNote.setText(note.toString());

        renderRecent();
    }

    /** 最近活跃：在线里按速率取前三，让一级页也能看到「谁在用网」 */
    private void renderRecent() {
        if (recentBox == null) {
            return;
        }
        JSONArray rows = new JSONArray();
        List<JSONObject> pool = new java.util.ArrayList<>();
        for (int i = 0; i < devices.length(); i++) {
            JSONObject d = devices.optJSONObject(i);
            if (d != null && d.optBoolean("online")) {
                pool.add(d);
            }
        }
        pool.sort((a, b) -> Double.compare(bps(b), bps(a)));
        for (int i = 0; i < pool.size() && i < 3; i++) {
            rows.put(pool.get(i));
        }

        StringBuilder sig = new StringBuilder();
        for (int i = 0; i < rows.length(); i++) {
            JSONObject d = rows.optJSONObject(i);
            sig.append(d.optString("mac")).append(d.optString("label"))
                    .append(d.optString("hostname")).append(d.optString("blocked")).append(';');
        }
        if (sig.toString().equals(structure)) {
            // 结构没变：只改速率文字，避免每 3 秒整块重建闪一下
            for (int i = 0; i < recentBox.getChildCount(); i++) {
                View row = recentBox.getChildAt(i);
                Object tag = row.getTag();
                if (!(tag instanceof String)) {
                    continue;
                }
                TextView rate = row.findViewById(R.id.recent_rate);
                if (rate == null) {
                    continue;
                }
                TextView amount = row.findViewById(R.id.recent_amount);
                for (int k = 0; k < rows.length(); k++) {
                    JSONObject d = rows.optJSONObject(k);
                    if (d != null && tag.equals(d.optString("mac"))) {
                        double b = bps(d);
                        rate.setText(b < 1024 ? "空闲" : Fmt.bps(b));
                        rate.setTextColor(Ui.color(ctx(), b < 1024
                                ? R.color.text_secondary : R.color.primary));
                        if (amount != null) {
                            amount.setText(d.optBoolean("blocked") ? "已禁网" : "");
                            amount.setVisibility(d.optBoolean("blocked")
                                    ? View.VISIBLE : View.GONE);
                        }
                    }
                }
            }
            tvRecentEmpty.setVisibility(rows.length() == 0 ? View.VISIBLE : View.GONE);
            return;
        }
        structure = sig.toString();

        recentBox.removeAllViews();
        tvRecentEmpty.setVisibility(rows.length() == 0 ? View.VISIBLE : View.GONE);
        for (int i = 0; i < rows.length(); i++) {
            JSONObject d = rows.optJSONObject(i);
            if (d == null) {
                continue;
            }
            recentBox.addView(recentRow(d, i == 0));
        }
    }

    private View recentRow(JSONObject d, boolean first) {
        Context c = ctx();
        LinearLayout wrap = Ui.column(c);
        if (!first) {
            wrap.addView(Ui.hairline(c, 16));
        }
        String mac = d.optString("mac");
        LinearLayout row = Ui.row(c);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(Ui.dp(c, 16), Ui.dp(c, 9), Ui.dp(c, 14), Ui.dp(c, 9));
        row.setTag(mac);

        // 标题依次退：名字 → 主机名 → IP → MAC。**跳过厂商**：
        // 「私有地址」既不是名字也不告诉你这是谁，拿它当标题只会把真正的 IP 挤到副标题
        String ip = d.optString("ip");
        String name = d.optString("label");
        if (name.isEmpty()) {
            name = d.optString("hostname");
        }
        if (name.isEmpty()) {
            name = ip;
        }
        if (name.isEmpty()) {
            name = mac;
        }

        LinearLayout col = Ui.column(c);
        TextView t = Ui.text(c, name, 14.5f, R.color.text_primary);
        t.setSingleLine(true);
        t.setEllipsize(android.text.TextUtils.TruncateAt.END);
        col.addView(t);

        // 标题已经是 IP 了就别再写一遍，改写成厂商（「私有地址」/「小米」都比重复的 IP 有用）
        String subText;
        if (name.equals(ip)) {
            String vendor = d.optString("vendor");
            subText = vendor.isEmpty() || "未知".equals(vendor) ? mac : vendor;
        } else {
            subText = ip.isEmpty() ? mac : ip;
        }
        TextView sub = Ui.text(c, subText, 11.5f, R.color.text_secondary);
        sub.setPadding(0, Ui.dp(c, 3), 0, 0);
        col.addView(sub);
        row.addView(col, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        LinearLayout tail = Ui.column(c);
        tail.setGravity(Gravity.END);
        double b = bps(d);
        TextView rate = Ui.text(c, b < 1024 ? "空闲" : Fmt.bps(b), 12f,
                b < 1024 ? R.color.text_secondary : R.color.primary);
        rate.setId(R.id.recent_rate);
        rate.setGravity(Gravity.END);
        tail.addView(rate);
        TextView amount = Ui.text(c, d.optBoolean("blocked") ? "已禁网" : "", 11f, R.color.danger);
        amount.setId(R.id.recent_amount);
        amount.setGravity(Gravity.END);
        amount.setVisibility(d.optBoolean("blocked") ? View.VISIBLE : View.GONE);
        tail.addView(amount);
        row.addView(tail);

        GradientDrawable mask = new GradientDrawable();
        mask.setColor(0xFFFFFFFF);
        row.setBackground(new android.graphics.drawable.RippleDrawable(
                android.content.res.ColorStateList.valueOf(Ui.color(c, R.color.ripple)),
                null, mask));
        row.setClickable(true);
        row.setOnClickListener(v -> {
            Intent i = new Intent(ctx(), DeviceDetailActivity.class);
            i.putExtra("mac", mac);
            startActivity(i);
        });
        wrap.addView(row);
        return wrap;
    }

    private void renderAd(JSONObject b) {
        adInstalled = b.optBoolean("installed", false);
        boolean running = b.optBoolean("running", false);
        String mode = b.optString("mode", "");
        adTakeover = "takeover".equals(mode);

        tvHeroBadge.setText(!adInstalled ? "拦截未装"
                : (adTakeover ? "拦截已接管" : "拦截未接管"));

        JSONObject stats = b.optJSONObject("stats");
        long queries = stats == null ? 0 : stats.optLong("queries", 0);
        long blocked = stats == null ? 0 : stats.optLong("blocked", 0);
        double pct = stats == null ? 0 : stats.optDouble("percent", 0);
        adPercent = (int) Math.round(pct);

        if (tvHeroAd != null) {
            tvHeroAd.setText(Fmt.count(blocked));
        }
        tvAdBlocked.setText(Fmt.count(blocked));
        tvAdSub.setText("今日共查询 " + Fmt.count(queries) + " 次");
        tvAdRate.setText(pct > 0 ? "拦截率 " + (pct < 10
                ? String.format(java.util.Locale.US, "%.1f%%", pct)
                : Math.round(pct) + "%") : "今天还没有拦截记录");

        if (!adInstalled) {
            tvAdState.setText("未安装");
            tvAdState.setTextColor(Ui.color(ctx(), R.color.text_secondary));
        } else if (running) {
            tvAdState.setText(adTakeover ? "运行中 · 接管" : "运行中");
            tvAdState.setTextColor(Ui.color(ctx(), R.color.primary));
        } else {
            tvAdState.setText("未运行");
            tvAdState.setTextColor(Ui.color(ctx(), R.color.warn));
        }
        stylePill(tvAdState);

        syncing = true;
        swTakeover.setEnabledState(adInstalled && running);
        swTakeover.setOn(adTakeover, true);
        syncing = false;

        if (!adInstalled) {
            tvAdSub.setText("AdGuard Home 未安装，拦截不可用");
        }
    }

    private void stylePill(TextView t) {
        GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(Ui.dp(ctx(), 100));
        int base = t.getCurrentTextColor();
        bg.setColor((base & 0x00FFFFFF) | 0x1F000000);
        t.setBackground(bg);
    }

    /** 接管开关：先确认再改。改的是 DNS 走向，属于必然影响网络的配置 */
    private void askTakeover(boolean want) {
        String title = want ? "让所有设备走 AdGuard Home 解析？" : "退出 DNS 接管？";
        String body = want
                ? "路由器的 DNS 接管会把全网的域名查询切到 AdGuard Home。\n"
                + "• 已连设备在租约续期后生效，中途会有一两秒解析抖动\n"
                + "• 如果 AdGuard Home 已停用，全网会短时无法解析域名\n"
                + "• 本地 .lan 域名和静态绑定仍然由 dnsmasq 解析，不受影响"
                : "退出接管后，所有设备改回运营商 DNS。\n"
                + "• 广告拦截会立即失效\n"
                + "• 已经建立的连接不受影响，新查询才会走回原路径";
        Sheet.confirm(ctx(), title, body, want ? "接管" : "退出接管", !want, () -> {
            post(want ? "/api/v1/adblock/takeover" : "/api/v1/adblock/release");
        });
    }

    private void post(String path) {
        Api.post(ctx(), path, new JSONObject(), new Cb() {
            @Override
            public void onData(JSONObject data, boolean fromCache) {
                if (!isAdded()) {
                    return;
                }
                if (data.optBoolean("ok", false)) {
                    notice(data.optString("message",
                            data.optString("mode_label", "已生效")), true);
                } else {
                    fail(data.optString("error", "操作被拒绝"));
                }
                load(true);
            }

            @Override
            public void onError(String message) {
                if (isAdded()) {
                    fail(message);
                    load(true);
                }
            }
        });
    }

    private static double bps(JSONObject d) {
        JSONObject net = d.optJSONObject("net");
        if (net == null) {
            return 0;
        }
        double down = net.optDouble("rx_bps", 0);
        double up = net.optDouble("tx_bps", 0);
        double avg = net.optDouble("avg_bps", 0);
        return Math.max(down + up, avg);
    }
}
