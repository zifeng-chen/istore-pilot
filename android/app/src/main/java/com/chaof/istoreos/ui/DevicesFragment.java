package com.chaof.istoreos.ui;

import android.content.Context;
import android.content.Intent;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.Editable;
import android.text.TextWatcher;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;

import com.chaof.istoreos.DeviceDetailActivity;
import com.chaof.istoreos.R;
import com.chaof.istoreos.api.Api;
import com.chaof.istoreos.api.Cb;
import com.chaof.istoreos.util.Fmt;
import com.chaof.istoreos.util.Ui;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * 设备：谁连着、谁在看视频、谁被断了网；外加一页「应用流量」回答「哪些应用在吃带宽」。
 *
 * 列表只负责「一眼看清状态」，所有细节动作都在详情页，
 * 这样列表能保持轻，56 台设备滚起来也不掉帧。
 *
 * 应用流量为什么按域名归类而不是进程：路由器在转发路径上，
 * 内网设备里的进程名拿不到（Mihomo 对 redir 流量的 process 字段恒为空）。
 */
public class DevicesFragment extends BaseFragment {

    private TextView tvTotal;
    private TextView tvOnline;
    private TextView tvRate;
    private TextView tvBlocked;
    private EditText search;
    private LinearLayout listBox;
    private LinearLayout deviceArea;
    private View emptyView;

    private JSONArray devices = new JSONArray();
    private String keyword = "";

    /**
     * 在线 / 离线筛选。
     * 一级页（设备与拦截合并页）点「在线 12」就带着 1 进来，
     * 点「离线 43」带着 2 进来 —— 这样「在线和离线」成了二级页面，
     * 一级页不用再摆一个几十行的大列表。
     */
    private int mode = 0;
    private LinearLayout modeSeg;

    /** 列表结构签名：只有它变了才重建 view，否则只改速率文字，避免每 3 秒闪一下 */
    private String structure = "";
    private final Map<String, TextView> rateViews = new HashMap<>();
    private final Map<String, TextView> statusViews = new HashMap<>();
    private final Map<String, TextView> sumViews = new HashMap<>();

    @Override
    protected String title() {
        // 标题放在二级页的标题栏里（返回箭头旁边），内容区不再重复一个大标题
        return null;
    }

    @Override
    public void onCreate(@androidx.annotation.Nullable android.os.Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        if (getArguments() != null) {
            mode = getArguments().getInt("mode", 0);
        }
    }

    /**
     * 固定区：hero + 筛选 + 搜索框。
     *
     * 设备有 50 多行，原来这些东西跟着一起滚 —— 翻到第 30 台想换个筛选，
     * 得先滚回顶上。现在只有下面的列表滚，顶部一直看得到。
     */
    @Override
    protected void buildPinned(LinearLayout pinned) {
        Context c = ctx();

        // 顶部 hero：和概览、广告拦截用同一套渐变卡。
        // 这里原来是一张普通白卡 + 大黑字「56 台设备」，切到本页时
        // 主色调、圆角、投影都跟另外两页对不上，看着像两个 App 拼起来的。
        Ui.Card head = Ui.gradient(c, R.color.hero_from, R.color.hero_to);
        head.setPadding(Ui.dp(c, 20), Ui.dp(c, 18), Ui.dp(c, 20), Ui.dp(c, 16));

        LinearLayout top = Ui.row(c);
        View heroDot = new View(c);
        GradientDrawable hd = new GradientDrawable();
        hd.setShape(GradientDrawable.OVAL);
        hd.setColor(Ui.alpha(Ui.color(c, R.color.hero_fg), 0.55f));
        heroDot.setBackground(hd);
        LinearLayout.LayoutParams hdlp = new LinearLayout.LayoutParams(
                Ui.dp(c, 8), Ui.dp(c, 8));
        hdlp.rightMargin = Ui.dp(c, 7);
        top.addView(heroDot, hdlp);

        TextView cap = Ui.heroNote(c, "在线设备", 1.0f);
        cap.setTextSize(13f);
        cap.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        top.addView(cap, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        // 「共 N 台」做成右上角小胶囊，跟广告拦截页的「已接管全网」同一个形状
        tvTotal = Ui.heroNote(c, "共 — 台", 0.9f);
        tvTotal.setTextSize(11.5f);
        tvTotal.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        tvTotal.setPadding(Ui.dp(c, 10), Ui.dp(c, 4), Ui.dp(c, 10), Ui.dp(c, 4));
        GradientDrawable chip = new GradientDrawable();
        chip.setCornerRadius(Ui.dp(c, 100));
        chip.setColor(Ui.alpha(Ui.color(c, R.color.hero_fg), 0.16f));
        tvTotal.setBackground(chip);
        top.addView(tvTotal);
        head.addView(top);

        // 在线台数当主数字：这一页最想第一眼看到的就是「几台在线」
        LinearLayout onlineLine = Ui.row(c);
        onlineLine.setGravity(Gravity.BOTTOM);
        LinearLayout.LayoutParams olp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        olp.topMargin = Ui.dp(c, 14);
        onlineLine.setLayoutParams(olp);

        tvOnline = Ui.heroNumber(c, "—");
        onlineLine.addView(tvOnline);

        TextView unit = Ui.heroNote(c, "台在线", 0.86f);
        unit.setTextSize(13f);
        unit.setPadding(Ui.dp(c, 8), 0, 0, Ui.dp(c, 9));
        onlineLine.addView(unit);

        tvRate = Ui.heroNote(c, "总流量 —", 0.86f);
        tvRate.setTextSize(12.5f);
        tvRate.setGravity(Gravity.END);
        tvRate.setPadding(Ui.dp(c, 10), 0, 0, Ui.dp(c, 9));
        onlineLine.addView(tvRate, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        head.addView(onlineLine);

        View hair = new View(c);
        hair.setBackgroundColor(Ui.alpha(Ui.color(c, R.color.hero_fg), 0.18f));
        LinearLayout.LayoutParams hlp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, Math.max(1, Ui.dp(c, 0.7f)));
        hlp.topMargin = Ui.dp(c, 14);
        head.addView(hair, hlp);

        LinearLayout foot = Ui.row(c);
        foot.setPadding(0, Ui.dp(c, 12), 0, 0);
        tvBlocked = Ui.heroNote(c, "已禁网 0 台", 0.86f);
        tvBlocked.setTextSize(12f);
        foot.addView(tvBlocked, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        TextView hint = Ui.heroNote(c, "点一行看详情", 0.7f);
        hint.setTextSize(11.5f);
        hint.setGravity(Gravity.END);
        foot.addView(hint);
        head.addView(foot);

        pinned.addView(head);

        // 在线 / 离线筛选：从一级页带着 mode 进来时，这里是「确认入口」；
        // 也可以就地切换，不用退回一级页再点一次
        modeSeg = Ui.column(c);
        LinearLayout.LayoutParams mslp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        mslp.bottomMargin = Ui.dp(c, 10);
        modeSeg.setLayoutParams(mslp);
        pinned.addView(modeSeg);
        renderModeSeg();

        search = new EditText(c);
        search.setHint("搜索名称、IP、MAC 或厂商");
        search.setTextSize(14f);
        search.setSingleLine(true);
        search.setTextColor(Ui.color(c, R.color.text_primary));
        search.setHintTextColor(Ui.color(c, R.color.text_secondary));
        GradientDrawable sbg = roundRect(c, R.color.surface, 14);
        sbg.setStroke(Math.max(1, Ui.dp(c, 0.7f)), Ui.color(c, R.color.glass_stroke));
        search.setBackground(sbg);
        int ph = Ui.dp(c, 11), pv = Ui.dp(c, 10);
        search.setPadding(ph + Ui.dp(c, 4), pv, ph, pv);
        LinearLayout.LayoutParams slp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        slp.bottomMargin = Ui.dp(c, 12);
        search.setLayoutParams(slp);
        search.addTextChangedListener(new TextWatcher() {
            @Override
            public void beforeTextChanged(CharSequence s, int a, int b, int d) {
            }

            @Override
            public void onTextChanged(CharSequence s, int a, int b, int d) {
                keyword = s.toString().trim().toLowerCase(Locale.ROOT);
                structure = "";
                render();
            }

            @Override
            public void afterTextChanged(Editable s) {
            }
        });
        pinned.addView(search);
    }

    @Override
    protected void build(LinearLayout root) {
        Context c = ctx();
        deviceArea = Ui.column(c);


        listBox = Ui.column(c);
        deviceArea.addView(listBox);

        emptyView = Ui.text(c, "没有匹配的设备", 14f, R.color.text_secondary);
        ((TextView) emptyView).setGravity(Gravity.CENTER);
        emptyView.setPadding(0, Ui.dp(c, 32), 0, 0);
        emptyView.setVisibility(View.GONE);
        deviceArea.addView(emptyView);
        root.addView(deviceArea);

    }

    /** 在线 / 离线筛选条。选中态是「烧」在背景里的，所以切换后整条重建 */
    private void renderModeSeg() {
        if (modeSeg == null) {
            return;
        }
        modeSeg.removeAllViews();
        modeSeg.addView(Ui.segmented(ctx(), new String[]{"全部", "在线", "离线"},
                mode, index -> {
                    if (index == mode) {
                        return;
                    }
                    mode = index;
                    structure = "";
                    renderModeSeg();
                    render();
                }));
    }

    private GradientDrawable roundRect(Context c, int colorRes, int radiusDp) {
        GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(Ui.dp(c, radiusDp));
        bg.setColor(Ui.color(c, colorRes));
        return bg;
    }

    @Override
    protected void load(boolean quiet) {
        Api.get(ctx(), "/api/v1/devices", new Cb() {
            @Override
            public void onData(JSONObject body, boolean fromCache) {
                // 请求回来时页面可能已经切走，这时候碰 view 会崩
                if (!isAdded() || getContext() == null) {
                    return;
                }
                setRefreshing(false);
                JSONArray arr = body.optJSONArray("devices");
                if (arr != null) {
                    devices = arr;
                }
                    JSONObject sum = body.optJSONObject("summary");
                if (sum != null) {
                    int total = sum.optInt("total", devices.length());
                    int online = sum.optInt("online", 0);
                    int blocked = sum.optInt("blocked", 0);
                    tvTotal.setText("共 " + total + " 台");
                    tvOnline.setText(String.valueOf(online));
                    // hero 是深绿底，红色的「已禁网 2 台」在上面根本读不出来；
                    // 文案里已经写了数量，颜色保持统一的白即可
                    tvBlocked.setText("已禁网 " + blocked + " 台");
                    tvRate.setText("总流量 " + Fmt.bps(sum.optDouble("rx_bps", 0)
                            + sum.optDouble("tx_bps", 0)));
                }
                if (!fromCache) {
                    notice("");
                }
                render();
                markLoaded();
            }

            @Override
            public void onError(String message) {
                if (isAdded() && getContext() != null) {
                    fail(message);
                    markLoaded();
                }
            }
        });
    }

    // ---------------------------------------------------------------- 设备列表

    private void render() {
        if (listBox == null) {
            return;
        }
        List<JSONObject> online = new ArrayList<>();
        List<JSONObject> offline = new ArrayList<>();
        StringBuilder sig = new StringBuilder();

        for (int i = 0; i < devices.length(); i++) {
            JSONObject d = devices.optJSONObject(i);
            if (d == null) {
                continue;
            }
            sig.append(d.optString("mac")).append(d.optBoolean("online"))
                    .append(d.optBoolean("blocked")).append(d.optString("alias"))
                    .append(d.optString("hostname")).append(d.optString("vendor"))
                    .append(d.optString("type")).append(d.optString("model")).append(';');
            if (!matches(d)) {
                continue;
            }
            boolean on = d.optBoolean("online");
            if (mode == 1 && !on) {
                continue;
            }
            if (mode == 2 && on) {
                continue;
            }
            if (on) {
                online.add(d);
            } else {
                offline.add(d);
            }
        }

        // 结构没变就只刷速率和状态，不重建 view
        if (sig.toString().equals(structure)) {
            refreshLive();
            emptyView.setVisibility(online.isEmpty() && offline.isEmpty() ? View.VISIBLE : View.GONE);
            return;
        }
        structure = sig.toString();

        rateViews.clear();
        statusViews.clear();
        sumViews.clear();
        listBox.removeAllViews();

        if (!online.isEmpty()) {
            // 排序按滑动平均速率，3 秒一跳的数字会让列表看起来在乱跳
            listBox.addView(Ui.section(ctx(), "在线 " + online.size() + " · 按实时流量排序"));
            addGroup(online);
        }
        if (!offline.isEmpty()) {
            Ui.space(ctx(), listBox, 4);
            listBox.addView(Ui.section(ctx(), "离线 " + offline.size()));
            addGroup(offline);
        }
        emptyView.setVisibility(online.isEmpty() && offline.isEmpty() ? View.VISIBLE : View.GONE);
        refreshLive();
    }

    /** 一组设备塞进一个卡片，行间加细线。分隔线缩进 26dp，让开左侧状态点 */
    private void addGroup(java.util.List<JSONObject> group) {
        Context c = ctx();
        Ui.Card box = Ui.group(c);
        for (int i = 0; i < group.size(); i++) {
            if (i > 0) {
                box.addView(Ui.hairline(c, 26));
            }
            box.addView(deviceRow(group.get(i)));
        }
        listBox.addView(box);
    }

    private boolean matches(JSONObject d) {
        if (keyword.isEmpty()) {
            return true;
        }
        String blob = (d.optString("alias") + " " + d.optString("hostname") + " "
                + d.optString("ip") + " " + d.optString("mac") + " "
                + d.optString("vendor")).toLowerCase(Locale.ROOT);
        return blob.contains(keyword);
    }

    private void refreshLive() {
        for (int i = 0; i < devices.length(); i++) {
            JSONObject d = devices.optJSONObject(i);
            if (d == null) {
                continue;
            }
            String mac = d.optString("mac");
            JSONObject net = d.optJSONObject("net");
            double down = net == null ? 0 : net.optDouble("rx_bps", 0);
            double up = net == null ? 0 : net.optDouble("tx_bps", 0);
            // 排序用的是滑动平均，展示也用同一个口径的较大值：
            // 否则会出现「排第一的设备写着 —」这种自相矛盾的显示
            double avg = net == null ? 0 : net.optDouble("avg_bps", 0);
            double bps = Math.max(down + up, avg);
            TextView rv = rateViews.get(mac);
            if (rv != null) {
                String text = bps < 1024 ? "—" : Fmt.bps(bps);
                rv.setText(text);
                rv.setTextColor(Ui.color(ctx(), bps < 1024 ? R.color.text_secondary : R.color.primary));
            }
            TextView sv = statusViews.get(mac);
            if (sv != null) {
                sv.setText(d.optBoolean("blocked") ? "已禁网" : "");
                sv.setVisibility(d.optBoolean("blocked") ? View.VISIBLE : View.GONE);
            }
            TextView sum = sumViews.get(mac);
            if (sum != null && net != null) {
                long total = net.optLong("rx_total", 0) + net.optLong("tx_total", 0);
                sum.setText(total > 0 ? "共 " + Fmt.bytes(total) : "暂无用量");
            }
        }
    }

    private View deviceRow(JSONObject d) {
        Context c = ctx();
        String mac = d.optString("mac");
        boolean online = d.optBoolean("online");
        boolean blocked = d.optBoolean("blocked");
        String vendor = d.optString("vendor");
        String kind = d.optString("type");
        String model = d.optString("model");
        String alias = d.optString("alias");
        String host = d.optString("hostname");
        String ip = d.optString("ip");

        // 不再自己建 Card —— 整组设备共用一个容器（见 render 里的 Ui.group），
        // 否则 55 台设备就是 55 层圆角 + 55 层投影，滚起来又卡又碎
        LinearLayout card = Ui.listRow(c);
        LinearLayout line = Ui.row(c);
        line.setGravity(Gravity.CENTER_VERTICAL);

        // 接入方式徽标（5G / 2.4G / LAN）替掉原来的状态圆点：
        // 一列绿点看不出任何信息，而「插线还是无线、哪个频段」才是想知道的
        line.addView(com.chaof.istoreos.util.Access.badge(c, d.optJSONObject("access"), online));

        LinearLayout mid = Ui.column(c);
        String name = d.optString("label");
        if (name.isEmpty()) {
            name = !alias.isEmpty() ? alias : (!host.isEmpty() ? host : (!vendor.isEmpty() ? vendor : (ip.isEmpty() ? mac : ip)));
        }
        TextView title = Ui.text(c, name, 15f, online ? R.color.text_primary : R.color.text_secondary);
        title.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        title.setSingleLine(true);
        title.setEllipsize(android.text.TextUtils.TruncateAt.END);
        mid.addView(title);

        // 第二行说清楚「这是什么」：品牌 + 类型 + 型号，比原来只报 IP 有用得多
        List<String> bits = new ArrayList<>();
        if (!ip.isEmpty()) {
            bits.add(ip);
        }
        StringBuilder who = new StringBuilder();
        // 已经手动命名过就别再挂「私有地址」：那是「查不出厂商」的解释，不是厂商
        boolean named = !d.optString("alias").isEmpty();
        if (!vendor.isEmpty() && !vendor.equals(name) && !"随机 MAC".equals(vendor)
                && !("私有地址".equals(vendor) && named)) {
            who.append(vendor);
        }
        if (!kind.isEmpty() && !"其他".equals(kind)) {
            if (who.length() > 0) {
                who.append(' ');
            }
            who.append(kind);
        }
        if (!model.isEmpty() && !model.equalsIgnoreCase(name)
                && !name.toLowerCase(Locale.ROOT).startsWith(model.toLowerCase(Locale.ROOT))) {
            if (who.length() > 0) {
                who.append(' ');
            }
            who.append(model);
        }
        // 标题已经就是这个信息了就别再重复一遍
        if (who.length() > 0 && !who.toString().equals(name)) {
            bits.add(who.toString());
        } else if ("随机 MAC".equals(vendor)) {
            bits.add("随机 MAC");
        }
        String sub = android.text.TextUtils.join(" · ", bits);
        if (sub.isEmpty()) {
            sub = mac;
        }
        TextView subView = Ui.text(c, sub, 12f, R.color.text_secondary);
        subView.setSingleLine(true);
        subView.setEllipsize(android.text.TextUtils.TruncateAt.END);
        subView.setPadding(0, Ui.dp(c, 3), 0, 0);
        mid.addView(subView);
        line.addView(mid, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        LinearLayout tail = Ui.column(c);
        tail.setGravity(Gravity.END);
        TextView pill = Ui.pill(c, "已禁网", R.color.danger);
        pill.setVisibility(blocked ? View.VISIBLE : View.GONE);
        statusViews.put(mac, pill);
        tail.addView(pill);

        TextView rate = Ui.text(c, "—", 13f, R.color.text_secondary);
        rate.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        rate.setGravity(Gravity.END);
        rate.setPadding(Ui.dp(c, 8), Ui.dp(c, 2), 0, 0);
        tail.addView(rate);
        rateViews.put(mac, rate);

        // 累计用量：用户明确要求「显示当前设备一共用了多少流量」
        JSONObject net = d.optJSONObject("net");
        long total = net == null ? 0 : net.optLong("rx_total", 0) + net.optLong("tx_total", 0);
        TextView sum = Ui.text(c, total > 0 ? "共 " + Fmt.bytes(total) : "暂无用量", 11f,
                R.color.text_secondary);
        sum.setGravity(Gravity.END);
        sum.setPadding(Ui.dp(c, 8), Ui.dp(c, 3), 0, 0);
        tail.addView(sum);
        sumViews.put(mac, sum);

        line.addView(tail);
        card.addView(line);

        final String titleText = name;
        // listRow 是普通 LinearLayout（涟漪由背景提供），没有 Card.tap()
        card.setOnClickListener(v -> {
            Intent it = new Intent(c, DeviceDetailActivity.class);
            it.putExtra("mac", mac);
            it.putExtra("name", titleText);
            startActivity(it);
        });
        return card;
    }
}
