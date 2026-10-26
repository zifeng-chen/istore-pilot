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
import com.chaof.istoreos.util.AppIcon;
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
    private LinearLayout segBox;
    private LinearLayout deviceArea;
    private LinearLayout appArea;
    private LinearLayout appListBox;
    private TextView tvAppHead;
    private TextView tvAppBig;
    private TextView tvAppSub;
    private TextView tvAppSummary;
    private TextView tvAppEmpty;
    private View emptyView;

    private JSONArray devices = new JSONArray();
    private JSONArray appRows = new JSONArray();
    private String keyword = "";

    /** 0 = 设备，1 = 应用流量 */
    private int viewMode = 0;

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
    private String appStructure = "";
    private final Map<String, TextView> rateViews = new HashMap<>();
    private final Map<String, TextView> statusViews = new HashMap<>();
    private final Map<String, TextView> sumViews = new HashMap<>();
    private final Map<String, TextView> appAmountViews = new HashMap<>();
    private final Map<String, TextView> appRateViews = new HashMap<>();
    private final Map<String, TextView> appMetaViews = new HashMap<>();

    @Override
    protected String title() {
        if (mode == 1) {
            return "在线设备";
        }
        if (mode == 2) {
            return "离线设备";
        }
        return "设备";
    }

    @Override
    public void onCreate(@androidx.annotation.Nullable android.os.Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        if (getArguments() != null) {
            mode = getArguments().getInt("mode", 0);
        }
    }

    @Override
    protected void build(LinearLayout root) {
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

        root.addView(head);

        // ---- 分段：设备 / 应用流量
        segBox = Ui.column(c);
        LinearLayout.LayoutParams segLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        segLp.bottomMargin = Ui.dp(c, 12);
        segBox.setLayoutParams(segLp);
        root.addView(segBox);
        renderSeg();

        // ---- 设备区
        deviceArea = Ui.column(c);

        // 在线 / 离线筛选：从一级页带着 mode 进来时，这里是「确认入口」；
        // 也可以就地切换，不用退回一级页再点一次
        modeSeg = Ui.column(c);
        LinearLayout.LayoutParams mslp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        mslp.bottomMargin = Ui.dp(c, 10);
        modeSeg.setLayoutParams(mslp);
        deviceArea.addView(modeSeg);
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
        deviceArea.addView(search);

        listBox = Ui.column(c);
        deviceArea.addView(listBox);

        emptyView = Ui.text(c, "没有匹配的设备", 14f, R.color.text_secondary);
        ((TextView) emptyView).setGravity(Gravity.CENTER);
        emptyView.setPadding(0, Ui.dp(c, 32), 0, 0);
        emptyView.setVisibility(View.GONE);
        deviceArea.addView(emptyView);
        root.addView(deviceArea);

        // ---- 应用流量区
        appArea = Ui.column(c);
        appArea.setVisibility(View.GONE);

        Ui.Card sum = Ui.card(c);
        tvAppHead = Ui.text(c, "累计用量", 12.5f, R.color.text_secondary);
        sum.addView(tvAppHead);
        tvAppBig = Ui.text(c, "—", 30f, R.color.text_primary);
        tvAppBig.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        tvAppBig.setPadding(0, Ui.dp(c, 2), 0, 0);
        sum.addView(tvAppBig);
        tvAppSub = Ui.text(c, "↓ —　↑ —", 13f, R.color.text_secondary);
        tvAppSub.setPadding(0, Ui.dp(c, 4), 0, 0);
        sum.addView(tvAppSub);
        sum.addView(Ui.divider(c));
        tvAppSummary = Ui.text(c, "正在统计…", 12.5f, R.color.text_secondary);
        tvAppSummary.setLineSpacing(Ui.dp(c, 3), 1f);
        sum.addView(tvAppSummary);
        appArea.addView(sum);

        appListBox = Ui.column(c);
        LinearLayout.LayoutParams albs = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        albs.topMargin = Ui.dp(c, 10);
        appListBox.setLayoutParams(albs);
        appArea.addView(appListBox);

        tvAppEmpty = Ui.text(c, "还没有捕获到应用流量", 14f, R.color.text_secondary);
        tvAppEmpty.setGravity(Gravity.CENTER);
        tvAppEmpty.setPadding(0, Ui.dp(c, 24), 0, 0);
        tvAppEmpty.setVisibility(View.GONE);
        appArea.addView(tvAppEmpty);
        root.addView(appArea);
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

    private void renderSeg() {        if (segBox == null) {
            return;
        }
        segBox.removeAllViews();
        segBox.addView(Ui.segmented(ctx(), new String[]{"设备", "应用流量"}, viewMode, index -> {
            if (index == viewMode) {
                return;
            }
            viewMode = index;
            deviceArea.setVisibility(viewMode == 0 ? View.VISIBLE : View.GONE);
            appArea.setVisibility(viewMode == 1 ? View.VISIBLE : View.GONE);
            renderSeg();
            if (viewMode == 1) {
                loadApps();
            }
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

        if (viewMode == 1) {
            loadApps();
        }
    }

    // ---------------------------------------------------------------- 应用流量

    private void loadApps() {
        // 只要累计口径：今日/累计两套数字摆在一起，用户总会怀疑哪个才是"真的"
        Api.get(ctx(), "/api/v1/apps", new Cb() {
            @Override
            public void onData(JSONObject body, boolean fromCache) {
                if (!isAdded() || getContext() == null) {
                    return;
                }
                JSONArray arr = body.optJSONArray("apps");
                appRows = arr == null ? new JSONArray() : arr;
                renderApps(body);
            }

            @Override
            public void onError(String message) {
                if (isAdded() && getContext() != null) {
                    tvAppSummary.setText("读取失败：" + message);
                }
            }
        });
    }

    private void renderApps(JSONObject body) {
        if (appListBox == null) {
            return;
        }
        Context c = appListBox.getContext();

        JSONObject session = body.optJSONObject("session");
        JSONObject clashTotals = body.optJSONObject("clash");
        JSONObject overall = body.optJSONObject("all");
        int conns = clashTotals == null ? 0 : clashTotals.optInt("connections", 0);

        long aUp = overall == null ? 0 : overall.optLong("up", 0);
        long aDown = overall == null ? 0 : overall.optLong("down", 0);
        long sUp = session == null ? 0 : session.optLong("up", 0);
        long sDown = session == null ? 0 : session.optLong("down", 0);
        int days = body.optInt("days", 1);

        tvAppHead.setText(days > 1 ? "累计用量　·　已统计 " + days + " 天" : "累计用量");
        tvAppBig.setText(Fmt.bytes(aUp + aDown));
        tvAppSub.setText("↓ " + Fmt.bytes(aDown) + "　↑ " + Fmt.bytes(aUp));
        tvAppSummary.setText("本次运行 " + Fmt.bytes(sUp + sDown)
                + "　·　当前 " + conns + " 条连接"
                + "\n每条记录上的大数字就是该应用的总用量，重启不清零");

        boolean empty = appRows.length() == 0;
        tvAppEmpty.setVisibility(empty ? View.VISIBLE : View.GONE);

        // 结构没变就只刷新用量文字，避免每 3 秒重建整张列表
        StringBuilder sig = new StringBuilder();
        for (int i = 0; i < appRows.length(); i++) {
            JSONObject a = appRows.optJSONObject(i);
            if (a != null) {
                sig.append(a.optString("name")).append(';');
            }
        }
        boolean rebuild = !sig.toString().equals(appStructure);
        appStructure = sig.toString();

        if (rebuild) {
            appListBox.removeAllViews();
            appAmountViews.clear();
            appRateViews.clear();
            appMetaViews.clear();
            long maxTotal = 1;
            for (int i = 0; i < appRows.length(); i++) {
                JSONObject a = appRows.optJSONObject(i);
                if (a != null) {
                    maxTotal = Math.max(maxTotal, a.optLong("all_total", 0));
                }
            }
            for (int i = 0; i < appRows.length(); i++) {
                JSONObject a = appRows.optJSONObject(i);
                if (a == null) {
                    continue;
                }
                appListBox.addView(appCard(c, a, maxTotal));
            }
        } else {
            refreshAppLive();
        }
    }

    private void refreshAppLive() {
        for (int i = 0; i < appRows.length(); i++) {
            JSONObject a = appRows.optJSONObject(i);
            if (a == null) {
                continue;
            }
            String name = a.optString("name");
            long total = a.optLong("all_total", 0);
            long down = a.optLong("all_down", 0);
            long up = a.optLong("all_up", 0);
            int conns = a.optInt("conns", 0);
            double bps = a.optDouble("down_bps", 0) + a.optDouble("up_bps", 0);

            TextView av = appAmountViews.get(name);
            if (av != null) {
                av.setText(Fmt.bytes(total));
            }
            TextView rv = appRateViews.get(name);
            if (rv != null) {
                rv.setText(bps < 1024 ? "" : Fmt.bps(bps));
            }
            TextView mv = appMetaViews.get(name);
            if (mv != null) {
                mv.setText("↓ " + Fmt.bytes(down) + "　↑ " + Fmt.bytes(up)
                        + (conns > 0 ? "　·　" + conns + " 连接" : ""));
            }
        }
    }

    private View appCard(Context c, JSONObject a, long maxTotal) {
        String name = a.optString("name");
        String category = a.optString("category");
        int conns = a.optInt("conns", 0);
        long total = a.optLong("all_total", 0);
        long down = a.optLong("all_down", 0);
        long up = a.optLong("all_up", 0);
        double bps = a.optDouble("down_bps", 0) + a.optDouble("up_bps", 0);

        Ui.Card card = Ui.card(c);
        LinearLayout line = Ui.row(c);

        // 图标：路由器拿不到真实应用图标，用品牌色 + 首字自绘一个（见 AppIcon）
        line.addView(AppIcon.make(c, name, category, 44));

        LinearLayout mid = Ui.column(c);
        mid.setPadding(Ui.dp(c, 12), 0, Ui.dp(c, 6), 0);

        LinearLayout nameRow = Ui.row(c);
        TextView title = Ui.text(c, name, 15f, R.color.text_primary);
        title.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        title.setSingleLine(true);
        title.setEllipsize(android.text.TextUtils.TruncateAt.END);
        nameRow.addView(title, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        // 实时速率只在真的有流量时露头，平时留空，眼睛不会被跳动的数字勾走
        TextView rate = Ui.text(c, bps < 1024 ? "" : Fmt.bps(bps), 11.5f, R.color.primary);
        rate.setSingleLine(true);
        rate.setPadding(Ui.dp(c, 6), 0, 0, 0);
        nameRow.addView(rate);
        mid.addView(nameRow);

        TextView meta = Ui.text(c, "↓ " + Fmt.bytes(down) + "　↑ " + Fmt.bytes(up)
                + (conns > 0 ? "　·　" + conns + " 连接" : ""), 11.5f, R.color.text_secondary);
        meta.setSingleLine(true);
        meta.setEllipsize(android.text.TextUtils.TruncateAt.END);
        meta.setPadding(0, Ui.dp(c, 3), 0, 0);
        mid.addView(meta);

        line.addView(mid, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        LinearLayout tail = Ui.column(c);
        tail.setGravity(Gravity.END);
        TextView amount = Ui.text(c, Fmt.bytes(total), 18f, R.color.text_primary);
        amount.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        amount.setSingleLine(true);
        tail.addView(amount);
        TextView tag = Ui.text(c, "总计", 11f, R.color.text_secondary);
        tag.setGravity(Gravity.END);
        tail.addView(tag);
        line.addView(tail);

        card.addView(line);

        appAmountViews.put(name, amount);
        appRateViews.put(name, rate);
        appMetaViews.put(name, meta);

        // 占比条：相对榜首，一眼看出谁是大头
        LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        blp.topMargin = Ui.dp(c, 12);
        card.addView(Ui.bar(c, total / (float) maxTotal, R.color.primary), blp);

        return card;
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

        // 状态点
        TextView dot = Ui.text(c, "●", 11f, blocked ? R.color.danger : (online ? R.color.primary : R.color.text_secondary));
        dot.setPadding(0, Ui.dp(c, 1), Ui.dp(c, 8), 0);
        line.addView(dot);

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
        if (!vendor.isEmpty() && !vendor.equals(name) && !"随机 MAC".equals(vendor)) {
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
