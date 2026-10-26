package com.chaof.istoreos.ui;

import android.content.Context;
import android.content.Intent;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.view.View;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import com.chaof.istoreos.R;
import com.chaof.istoreos.SubscriptionActivity;
import com.chaof.istoreos.api.Api;
import com.chaof.istoreos.api.Cb;
import com.chaof.istoreos.util.Ui;
import com.chaof.istoreos.widget.Sheet;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.Map;
import java.util.Set;

/**
 * 代理：同时管 OpenClash 与 Passwall。
 *
 * 两者互斥，同一时刻只有一个在跑，所以先展示「谁在跑」，再展示「跑着的这个有哪些节点」。
 * 节点按分组折叠，默认只展开第一个组 —— 157 个节点全铺开是灾难。
 *
 * 折叠状态必须自己记住：以前用「集合为空就展开第一组」做初始化，
 * 结果把唯一展开的那个组收起来后集合归空，下一次渲染又自动展开 ——
 * 表现就是「GLOBAL 怎么点都收不起来」。现在用一个 seeded 标记，只初始化一次。
 */
public class ProxyFragment extends BaseFragment {

    private LinearLayout backendBox;
    private LinearLayout modeBox;
    private TextView tvMode;
    private LinearLayout nodesBox;
    private TextView tvSubCount;
    /** 配置文件清单，弹窗切换时直接用，不再请求一次 */
    private JSONArray configs;
    private String currentConfigPath = "";
    /** hero 卡：谁在跑 / 跑哪份配置 / 什么模式 */
    private View heroDot;
    private TextView tvHeroState;
    private TextView tvHeroBadge;
    private TextView tvHeroTitle;
    private TextView tvHeroMeta;
    /** 「配置与节点」卡顶部那行显示当前启用的 yaml */
    private TextView tvCurConfig;

    private String backendId = "";
    private String backendLabel = "";
    private String signature = "";
    private final Set<String> expanded = new LinkedHashSet<>();
    private String modeValue = "";
    /** GLOBAL 组当前指向谁，切全局模式前用来判断会不会一把拒掉所有流量 */
    private String globalNow = "";
    /** 分组默认只展开一次，之后完全听用户的 */
    private boolean seeded = false;
    private JSONObject lastGroups;
    /** 刚测出来的延迟，优先级高于接口里带的历史值 */
    private final Map<String, Integer> tested = new HashMap<>();
    private String testingGroup = "";

    @Override
    protected String title() {
        return "代理";
    }

    @Override
    protected void build(LinearLayout root) {
        Context c = ctx();

        // ---------------------------------------------------------- hero
        // 另外四页顶部都是一张深底渐变卡给结论，这里原来直接堆卡片，
        // 进来第一眼看不到「谁在跑」，得自己往下找。
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

        tvHeroState = Ui.heroNote(c, "正在读取…", 1.0f);
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

        tvHeroTitle = Ui.text(c, "—", 27f, R.color.hero_fg);
        tvHeroTitle.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        tvHeroTitle.setIncludeFontPadding(false);
        tvHeroTitle.setLetterSpacing(-0.02f);
        tvHeroTitle.setMaxLines(1);
        tvHeroTitle.setEllipsize(android.text.TextUtils.TruncateAt.END);
        LinearLayout.LayoutParams hlp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        hlp.topMargin = Ui.dp(c, 12);
        hero.addView(tvHeroTitle, hlp);

        tvHeroMeta = Ui.heroNote(c, "读取中…", 0.86f);
        tvHeroMeta.setPadding(0, Ui.dp(c, 5), 0, 0);
        tvHeroMeta.setSingleLine(true);
        tvHeroMeta.setEllipsize(android.text.TextUtils.TruncateAt.END);
        hero.addView(tvHeroMeta);
        root.addView(hero);

        // ---------------------------------------------------------- 代理后端
        Ui.Card back = Ui.card(c);
        Ui.header(back, "代理后端", "两个插件互斥，点一行切过去");
        backendBox = Ui.column(c);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.topMargin = Ui.dp(c, 8);
        back.addView(backendBox, lp);
        root.addView(back);

        Ui.Card mode = Ui.card(c);
        // 原来用 Ui.kv 把「运行模式」当键值行，标题就成了灰色小字，
        // 跟上面「代理后端」那种白色粗体标题不一样。改成标准卡片标题，
        // 当前值放到右上角 —— 和「节点」卡的写法统一。
        LinearLayout modeHead = Ui.header(mode, "运行模式", "");
        tvMode = Ui.value(c, "—");
        modeHead.addView(tvMode);
        modeBox = Ui.column(c);
        LinearLayout.LayoutParams mlp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        mlp.topMargin = Ui.dp(c, 12);
        mode.addView(modeBox, mlp);
        root.addView(mode);

        // ---------------------------------------------------------- 配置与节点
        // 订阅和节点原来是两张卡，来回翻着看很割裂：换了订阅要往下滑才知道
        // 节点有没有跟着变。现在合成一张，最上面就是「当前用的是哪份」。
        Ui.Card combo = Ui.card(c);
        // 标题右侧不挂数字：那位置留给订阅行的「N 条」，两边都放会重复
        Ui.header(combo, "配置与节点", "");

        LinearLayout curRow = Ui.row(c);
        curRow.setPadding(0, Ui.dp(c, 10), 0, Ui.dp(c, 10));
        curRow.setClickable(true);
        LinearLayout curCol = Ui.column(c);
        TextView curLabel = Ui.text(c, "当前启用的配置文件", 11.5f, R.color.text_secondary);
        curCol.addView(curLabel);
        tvCurConfig = Ui.text(c, "读取中…", 15f, R.color.text_primary);
        tvCurConfig.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        tvCurConfig.setPadding(0, Ui.dp(c, 3), 0, 0);
        tvCurConfig.setMaxLines(1);
        tvCurConfig.setEllipsize(android.text.TextUtils.TruncateAt.END);
        curCol.addView(tvCurConfig);
        curRow.addView(curCol, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        curRow.addView(Ui.pill(c, "切换", R.color.primary));
        // 换配置从「进二级页」改成「弹窗直接选」：配置文件通常就三五份，
        // 为一次选择跳一页再跳回来太重
        curRow.setOnClickListener(v -> showConfigPicker());
        combo.addView(curRow, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        combo.addView(Ui.divider(c));

        // 订阅只留一行入口：增删改都在独立页面里，这里再列一遍会让这张卡长得没边
        LinearLayout subRow = Ui.row(c);
        subRow.setPadding(0, Ui.dp(c, 12), 0, Ui.dp(c, 12));
        subRow.setClickable(true);
        LinearLayout subCol = Ui.column(c);
        TextView subTitle = Ui.text(c, "订阅管理", 15f, R.color.text_primary);
        subTitle.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        subCol.addView(subTitle);
        TextView subNote = Ui.text(c, "添加、修改、删除订阅地址", 11.5f, R.color.text_secondary);
        subNote.setPadding(0, Ui.dp(c, 3), 0, 0);
        subCol.addView(subNote);
        subRow.addView(subCol, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        tvSubCount = Ui.value(c, "");
        subRow.addView(tvSubCount);
        TextView chevron = Ui.text(c, "›", 18f, R.color.text_tertiary);
        chevron.setPadding(Ui.dp(c, 8), 0, 0, 0);
        subRow.addView(chevron);
        subRow.setOnClickListener(v -> {
            if (backendId.isEmpty()) {
                notice("两个代理后端都没在运行，订阅不可用");
                return;
            }
            Intent it = new Intent(ctx(), SubscriptionActivity.class);
            it.putExtra("backend", backendId);
            startActivity(it);
        });
        combo.addView(subRow);

        combo.addView(Ui.divider(c));
        combo.addView(Ui.section(c, "节点"));
        nodesBox = Ui.column(c);
        combo.addView(nodesBox);

        root.addView(combo);
    }

    @Override
    protected void load(boolean quiet) {
        Api.get(ctx(), "/api/v1/proxy", new Cb() {
            @Override
            public void onData(JSONObject body, boolean fromCache) {
                if (!isAdded()) {
                    return;
                }
                renderBackends(body);
                loadGroups();
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
    }

    private void renderBackends(JSONObject body) {
        Context c = backendBox.getContext();
        backendBox.removeAllViews();
        backendLabel = "";

        String active = body.optString("active", "none");
        JSONArray arr = body.optJSONArray("backends");
        backendId = "none".equals(active) ? "" : active;
        int activeCount = 0;

        if (arr != null) {
            for (int i = 0; i < arr.length(); i++) {
                JSONObject b = arr.optJSONObject(i);
                if (b == null) {
                    continue;
                }
                String id = b.optString("id", "");
                String label = b.optString("label", id);
                boolean running = b.optBoolean("running", false);
                boolean installed = b.optBoolean("installed", false);

                LinearLayout line = Ui.row(c);
                line.setPadding(0, Ui.dp(c, 8), 0, Ui.dp(c, 8));

                LinearLayout col = Ui.column(c);
                TextView name = Ui.text(c, label, 15f, R.color.text_primary);
                name.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
                col.addView(name);

                String engine = b.optString("engine", "");
                int count = b.optInt("node_count", 0);
                TextView sub = Ui.text(c, installed
                                ? (engine.isEmpty() ? "" : engine) + " · " + count + " 个节点"
                                : "未安装",
                        12f, R.color.text_secondary);
                sub.setPadding(0, Ui.dp(c, 3), 0, 0);
                col.addView(sub);

                line.addView(col, new LinearLayout.LayoutParams(0,
                        ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

                if (running) {
                    line.addView(Ui.pill(c, "运行中", R.color.primary));
                    backendLabel = label;
                    activeCount = b.optInt("node_count", 0);
                } else {
                    // 用 text_on_track 而不是 text_secondary：
                    // 灰字配 19% 灰底，在深色下「未运行」几乎读不出来
                    line.addView(Ui.pill(c, installed ? "未运行" : "未安装",
                            R.color.text_on_track));
                    // 装好了但没跑，点一下就能切过去 —— 比让用户去后台点强
                    if (installed) {
                        final String fid = id;
                        final String flabel = label;
                        line.setClickable(true);
                        line.setOnClickListener(v -> askSwitchBackend(fid, flabel));
                    }
                }

                backendBox.addView(line);
                if (i < arr.length() - 1) {
                    backendBox.addView(Ui.divider(c));
                }
            }
        }

        boolean none = "none".equals(active);
        if (tvHeroState != null) {
            tvHeroState.setText(none ? "都没在运行" : "运行中");
            tvHeroBadge.setText(none ? "未启用" : backendLabel);
            tvHeroTitle.setText(none ? "直连" : "—");
            tvHeroMeta.setText(none
                    ? "两个代理后端都停着，所有流量走直连"
                    : activeCount + " 个节点可用");
        }
        if (heroDot != null) {
            GradientDrawable dot = new GradientDrawable();
            dot.setShape(GradientDrawable.OVAL);
            dot.setColor(Ui.alpha(Ui.color(c, R.color.hero_fg), none ? 0.45f : 1f));
            heroDot.setBackground(dot);
        }
        renderMode();
        loadConfigs();
        loadSubCount();
    }

    /** 装了但没跑的后端点一下切过去。互斥关系要提前说清，否则用户以为只是「启动」。 */
    private void askSwitchBackend(String id, String label) {
        Sheet.confirm(ctx(), "切换到 " + label + "？",
                "两个代理后端互斥，启动这个会先停掉另一个，网络会断十几秒。",
                "切换", false, () -> {
                    notice("正在启动 " + label + "…");
                    JSONObject body = new JSONObject();
                    try {
                        body.put("action", "start");
                        body.put("backend", id);
                    } catch (Exception ignored) {
                        return;
                    }
                    Api.postSlow(ctx(), "/api/v1/proxy/service", body, new Cb() {
                        @Override
                        public void onData(JSONObject data, boolean fromCache) {
                            if (!isAdded()) {
                                return;
                            }
                            boolean ok = data.optBoolean("ok", false);
                            notice(ok ? label + " 已启动" : "启动失败，看日志确认",
                                    ok);
                            load(true);
                        }

                        @Override
                        public void onError(String message) {
                            if (isAdded()) {
                                fail("启动失败：" + message);
                            }
                        }
                    });
                });
    }

    /** 当前启用的 OpenClash 配置文件。切换在二级页做，这里只负责显示。 */
    private void loadConfigs() {
        Api.get(ctx(), "/api/v1/proxy/configs", new Cb() {
            @Override
            public void onData(JSONObject body, boolean fromCache) {
                if (!isAdded() || tvCurConfig == null) {
                    return;
                }
                JSONArray arr = body.optJSONArray("configs");
                configs = arr;
                currentConfigPath = body.optString("current", "");

                String name = "";
                if (arr != null) {
                    for (int i = 0; i < arr.length(); i++) {
                        JSONObject it = arr.optJSONObject(i);
                        if (it != null && it.optBoolean("current", false)) {
                            name = it.optString("name", "");
                        }
                    }
                }
                if (name.isEmpty() && !currentConfigPath.isEmpty()) {
                    int slash = currentConfigPath.lastIndexOf('/');
                    name = slash >= 0 ? currentConfigPath.substring(slash + 1)
                            : currentConfigPath;
                }
                if (name.isEmpty()) {
                    name = "未设置";
                }
                tvCurConfig.setText(name);
                if (tvHeroTitle != null && !backendId.isEmpty()) {
                    tvHeroTitle.setText(name);
                }
            }

            @Override
            public void onError(String message) {
                if (isAdded() && tvCurConfig != null) {
                    tvCurConfig.setText("读取失败");
                }
            }
        });
    }

    /**
     * 配置文件切换走弹窗：配置文件一般就三五份，为一次选择跳一整个页面太重。
     * 弹窗里带上修改时间，便于分辨「哪份是刚拉的」。
     */
    private void showConfigPicker() {
        if (configs == null || configs.length() == 0) {
            notice("还没读到配置文件列表，正在重试…");
            loadConfigs();
            return;
        }
        int n = configs.length();
        final String[] labels = new String[n];
        final String[] paths = new String[n];
        int sel = -1;
        for (int i = 0; i < n; i++) {
            JSONObject it = configs.optJSONObject(i);
            if (it == null) {
                labels[i] = "—";
                paths[i] = "";
                continue;
            }
            String nm = it.optString("name", "—");
            long mtime = it.optLong("mtime", 0);
            String when = mtime > 0
                    ? android.text.format.DateFormat
                            .format("MM-dd HH:mm", mtime * 1000L).toString()
                    : "";
            labels[i] = when.isEmpty() ? nm : nm + " · " + when;
            paths[i] = it.optString("path", "");
            if (it.optBoolean("current", false)) {
                sel = i;
            }
        }
        final int selected = sel;
        Sheet.choose(ctx(), "切换配置文件", labels, selected, idx -> {
            if (idx == selected) {
                notice("已经是这份配置");
                return;
            }
            askSwitchConfig(labels[idx], paths[idx]);
        });
    }

    private void askSwitchConfig(String label, String path) {
        if (path.isEmpty()) {
            return;
        }
        int cut = label.indexOf(" · ");
        String name = cut > 0 ? label.substring(0, cut) : label;
        Sheet.confirm(ctx(), "切换到 " + name + "？",
                "OpenClash 会重启内核，期间断网十几秒。\n\n"
                        + "如果新配置有问题，代理可能起不来 —— 到时回到这里换回来就行。",
                "切换", false, () -> doSwitchConfig(path));
    }

    private void doSwitchConfig(String path) {
        JSONObject body = new JSONObject();
        try {
            body.put("path", path);
        } catch (Exception ignored) {
            return;
        }
        notice("正在切换配置，内核会重启，稍等十几秒…");
        Api.postSlow(ctx(), "/api/v1/proxy/config", body, new Cb() {
            @Override
            public void onData(JSONObject data, boolean fromCache) {
                if (!isAdded()) {
                    return;
                }
                boolean ok = data.optBoolean("ok", true);
                if (!ok) {
                    notice("切换失败");
                    Sheet.message(ctx(), "切换失败",
                            data.optString("error", "未知原因") + "\n\n"
                                    + "配置可能有问题，换回原来那份试试。");
                    return;
                }
                notice("已切换", true);
                load(true);
                loadConfigs();
            }

            @Override
            public void onError(String message) {
                if (isAdded()) {
                    fail("切换失败：" + message);
                }
            }
        });
    }

    /** 订阅本身在独立页面维护，这张卡只要一个条数 */
    private void loadSubCount() {
        if (tvSubCount == null) {
            return;
        }
        if (backendId.isEmpty()) {
            tvSubCount.setText("");
            return;
        }
        Api.get(ctx(), "/api/v1/proxy/subscriptions?backend=" + backendId, new Cb() {
            @Override
            public void onData(JSONObject body, boolean fromCache) {
                if (!isAdded() || tvSubCount == null) {
                    return;
                }
                JSONArray items = body.optJSONArray("items");
                int n = items == null ? 0 : items.length();
                tvSubCount.setText(n == 0 ? "" : n + " 条");
            }

            @Override
            public void onError(String message) {
                if (isAdded() && tvSubCount != null) {
                    tvSubCount.setText("");
                }
            }
        });
    }

    private void loadGroups() {
        Api.get(ctx(), "/api/v1/proxy/groups", new Cb() {
            @Override
            public void onData(JSONObject body, boolean fromCache) {
                if (!isAdded()) {
                    return;
                }
                String sig = body.toString();
                if (!sig.equals(signature)) {
                    signature = sig;
                    lastGroups = body;
                    renderNodes(body);
                }
                if (!fromCache) {
                    setRefreshing(false);
                }
            }

            @Override
            public void onError(String message) {
                if (isAdded()) {
                    setRefreshing(false);
                    if (nodesBox.getChildCount() == 0) {
                        nodesBox.addView(Ui.label(nodesBox.getContext(), message));
                    }
                }
            }
        });

        // 模式是单独接口，顺带刷新
        Api.get(ctx(), "/api/v1/proxy/mode", new Cb() {
            @Override
            public void onData(JSONObject body, boolean fromCache) {
                if (!isAdded()) {
                    return;
                }
                modeValue = body.optString("mode", "");
                tvMode.setText(modeLabel(modeValue));
                renderMode();
            }
        });
    }

    /** 分段控件的选中项要跟着实际模式走，所以这块每次拿到数据都重建一遍 */
    private void renderMode() {
        if (modeBox == null) {
            return;
        }
        Context c = modeBox.getContext();
        modeBox.removeAllViews();
        boolean oc = "openclash".equals(backendId);
        String[] labels = oc ? new String[]{"规则", "全局", "直连"} : new String[]{"代理", "直连"};
        int selected = oc
                ? ("rule".equals(modeValue) ? 0 : ("global".equals(modeValue) ? 1 : 2))
                : ("proxy".equals(modeValue) ? 0 : 1);
        modeBox.addView(Ui.segmented(c, labels, selected, this::pickModeAt));
    }

    private void renderNodes(JSONObject body) {
        Context c = nodesBox.getContext();
        nodesBox.removeAllViews();

        JSONArray groups = body.optJSONArray("groups");
        if (groups == null || groups.length() == 0) {
            String err = body.optString("error", "没有可用的节点");
            nodesBox.addView(Ui.label(c, err));
            return;
        }

        // 「自动选择」是日常真正在用的那个分组，但订阅自带的顺序经常把它压在
        // 第三四位，每次都要往下找一眼。这里统一提到最上面（稳定排序，其余不动）
        java.util.List<JSONObject> ordered = new java.util.ArrayList<>();
        for (int i = 0; i < groups.length(); i++) {
            JSONObject g = groups.optJSONObject(i);
            if (g != null) {
                ordered.add(g);
            }
        }
        java.util.Collections.sort(ordered, (a, b) ->
                (isAutoGroup(b.optString("name", "")) ? 1 : 0)
                        - (isAutoGroup(a.optString("name", "")) ? 1 : 0));

        // 只有第一次进来才替用户展开第一个分组，之后一切听用户的
        if (!seeded && !ordered.isEmpty()) {
            expanded.add(ordered.get(0).optString("name", ""));
            seeded = true;
        }

        for (int i = 0; i < ordered.size(); i++) {
            JSONObject g = ordered.get(i);
            if (g == null) {
                continue;
            }
            String gname = g.optString("name", "");
            // 订阅里混进来的「剩余流量：625.19 GB」这类信息条目不是真节点，
            // 有些订阅甚至把它设成默认选项，这里统一挡掉
            String nowRaw = g.optString("now", "");
            String now = isInfoNode(nowRaw) ? "" : nowRaw;
            if ("GLOBAL".equalsIgnoreCase(gname)) {
                // 记下来：GLOBAL 指向 REJECT 时切全局模式会断网，setMode 要用它挡一下
                globalNow = now;
            }
            JSONArray members = g.optJSONArray("members");
            boolean open = expanded.contains(gname);
            boolean testing = gname.equals(testingGroup);

            if (i > 0) {
                nodesBox.addView(Ui.divider(c));
            }

            LinearLayout head = Ui.row(c);
            head.setPadding(0, Ui.dp(c, 8), 0, Ui.dp(c, 8));
            head.setClickable(true);

            TextView name = Ui.text(c, pretty(gname), 15f, R.color.text_primary);
            name.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
            head.addView(name, new LinearLayout.LayoutParams(0,
                    ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

            // 当前选中的节点：只留名字，延迟单独显示
            if (!now.isEmpty()) {
                TextView cur = Ui.text(c, pretty(now), 12f,
                        isPolicyName(now) ? R.color.text_secondary : R.color.primary);
                cur.setMaxLines(1);
                cur.setMaxEms(12);
                cur.setEllipsize(android.text.TextUtils.TruncateAt.END);
                cur.setPadding(Ui.dp(c, 10), 0, 0, 0);
                head.addView(cur);
            } else if (g.optBoolean("now_info", false) || isInfoNode(g.optString("now", ""))) {
                // 订阅把「剩余流量：xxx」这类信息条目塞进了节点列表，还被选成了当前项。
                // 照实显示会让人以为流量走了个叫「剩余流量」的节点，说清楚更好。
                TextView cur = Ui.text(c, "未选中可用节点", 11.5f, R.color.text_secondary);
                cur.setMaxLines(1);
                cur.setPadding(Ui.dp(c, 10), 0, 0, 0);
                head.addView(cur);
            }

            int total = members == null ? 0 : members.length();
            TextView arrow = Ui.text(c, (open ? "▾" : "▸") + " " + total, 12f,
                    R.color.text_secondary);
            arrow.setPadding(Ui.dp(c, 8), 0, 0, 0);
            head.addView(arrow);

            // ★ 测速按钮：必须在 header 之前消费点击，否则会被折叠动作吃掉
            TextView btn = Ui.text(c, testing ? "测速中" : "测速", 12f,
                    testing ? R.color.text_secondary : R.color.primary);
            btn.setPadding(Ui.dp(c, 10), Ui.dp(c, 3), Ui.dp(c, 2), Ui.dp(c, 3));
            btn.setClickable(true);
            btn.setFocusable(true);
            btn.setOnClickListener(v -> testGroup(gname));
            head.addView(btn);

            head.setOnClickListener(v -> {
                if (expanded.contains(gname)) {
                    expanded.remove(gname);
                } else {
                    expanded.add(gname);
                }
                // 折叠是纯本地动作，不用再问服务器
                if (lastGroups != null) {
                    renderNodes(lastGroups);
                }
            });

            nodesBox.addView(head);

            if (open && members != null) {
                for (int k = 0; k < members.length(); k++) {
                    JSONObject m = members.optJSONObject(k);
                    if (m == null) {
                        continue;
                    }
                    addNodeRow(c, m, gname, now);
                }
            }
        }

        setRefreshing(false);
    }

    /**
     * 判断是不是「自动选择」类分组。订阅里这类组的名字五花八门：
     * 自动选择 / 自动切换 / Auto / URLTest / Fallback，统一都归到最前面。
     */
    private static boolean isAutoGroup(String name) {
        if (name == null || name.isEmpty()) {
            return false;
        }
        String n = name.toLowerCase();
        return n.contains("自动") || n.contains("auto")
                || n.contains("urltest") || n.contains("fallback");
    }

    /**
     * 订阅里的节点名常带国旗 emoji（🇯🇵 这种由两个「区域指示符」拼成）。
     * 不少安卓机的中文字体没有对应字形，会渲染成方块，所以显示前把它们剔掉；
     * 中文名里本来就有「日本 / 香港」，信息不丢。
     */
    private static String pretty(String name) {
        if (name == null || name.isEmpty()) {
            return "";
        }
        StringBuilder sb = new StringBuilder(name.length());
        for (int i = 0; i < name.length(); ) {
            int cp = name.codePointAt(i);
            boolean flag = cp >= 0x1F1E6 && cp <= 0x1F1FF;
            boolean variation = cp == 0xFE0F || cp == 0x200D;  // 变体选择符 / 零宽连接符
            if (!flag && !variation) {
                sb.appendCodePoint(cp);
            }
            i += Character.charCount(cp);
        }
        String out = sb.toString().trim();
        return out.isEmpty() ? name : out;
    }

    /** 订阅里混进来的流量余量 / 到期日 / 官网这类信息条目 */
    private static boolean isInfoNode(String name) {
        if (name == null || name.isEmpty()) {
            return false;
        }
        String[] prefixes = {"剩余流量", "距离下次", "套餐到期", "到期时间", "官网", "订阅", "重置"};
        for (String p : prefixes) {
            if (name.startsWith(p)) {
                return true;
            }
        }
        return false;
    }

    private void addNodeRow(Context c, JSONObject m, String group, String current) {
        String name = m.optString("name", "");
        if (isInfoNode(name)) {
            return;
        }
        boolean isGroup = m.optBoolean("is_group", false);
        boolean selected = name.equals(current);
        // REJECT / DIRECT / PASS 是策略动作，选中它们等于「不代理」或「全拒绝」，
        // 用灰色而不是主题绿，避免看起来像选了个正常节点
        boolean policy = isPolicyName(name);

        LinearLayout line = Ui.row(c);
        line.setPadding(Ui.dp(c, 14), Ui.dp(c, 9), Ui.dp(c, 2), Ui.dp(c, 9));
        line.setClickable(true);

        int onColor = isRejectPolicy(name) ? R.color.danger
                : (policy ? R.color.text_secondary : R.color.primary);
        TextView dot = Ui.text(c, selected ? "●" : "○", 10f,
                selected ? onColor : R.color.text_tertiary);
        line.addView(dot, new LinearLayout.LayoutParams(Ui.dp(c, 18),
                ViewGroup.LayoutParams.WRAP_CONTENT));

        TextView label = Ui.text(c, pretty(name), 14f,
                selected ? onColor : (policy ? R.color.text_secondary : R.color.text_primary));
        label.setMaxLines(1);
        label.setEllipsize(android.text.TextUtils.TruncateAt.END);
        line.addView(label, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        // 延迟有三种态，不能混为一谈：
        //   本次手动测速的结果    → 0 就是真的连不上，显示「超时」
        //   接口带回来的历史值    → 0 只代表「还没测过」，显示「—」
        //   两者都没有（组节点）  → 显示「组」
        Integer fresh = tested.get(name);
        if (fresh != null) {
            int ms = fresh;
            TextView d = Ui.text(c, ms > 0 ? ms + "ms" : "超时", 12f, delayColor(ms));
            d.setPadding(Ui.dp(c, 8), 0, 0, 0);
            line.addView(d);
        } else {
            Object delay = m.opt("delay");
            int ms = delay instanceof Number ? ((Number) delay).intValue() : -1;
            if (ms > 0) {
                TextView d = Ui.text(c, ms + "ms", 12f, delayColor(ms));
                d.setPadding(Ui.dp(c, 8), 0, 0, 0);
                line.addView(d);
            } else if (isGroup) {
                TextView d = Ui.text(c, "组", 12f, R.color.text_secondary);
                d.setPadding(Ui.dp(c, 8), 0, 0, 0);
                line.addView(d);
            } else {
                TextView d = Ui.text(c, "—", 12f, R.color.text_tertiary);
                d.setPadding(Ui.dp(c, 8), 0, 0, 0);
                line.addView(d);
            }
        }

        line.setOnClickListener(v -> selectNode(group, name, true));
        nodesBox.addView(line);
    }

    private static int delayColor(int ms) {
        if (ms <= 0) {
            return R.color.text_tertiary;
        }
        return ms < 150 ? R.color.ok : (ms < 350 ? R.color.warn : R.color.danger);
    }

    /** 整组测速：OpenClash 由内核并发打完，Passwall 走并发 TCP 探测 */
    private void testGroup(String group) {
        if (!testingGroup.isEmpty()) {
            Toast.makeText(ctx(), "正在测速，稍等", Toast.LENGTH_SHORT).show();
            return;
        }
        testingGroup = group;
        tested.clear();
        if (lastGroups != null) {
            renderNodes(lastGroups);
        }
        notice("正在测速「" + pretty(group) + "」…");

        JSONObject body = new JSONObject();
        try {
            body.put("group", group);
            body.put("timeout", 3000);
        } catch (Exception ignored) {
            testingGroup = "";
            return;
        }
        Api.post(ctx(), "/api/v1/proxy/delays", body, new Cb() {
            @Override
            public void onData(JSONObject data, boolean fromCache) {
                testingGroup = "";
                if (!isAdded()) {
                    return;
                }
                JSONObject delays = data.optJSONObject("delays");
                int ok = 0;
                if (delays != null) {
                    java.util.Iterator<String> it = delays.keys();
                    while (it.hasNext()) {
                        String key = it.next();
                        int ms = delays.optInt(key, 0);
                        tested.put(key, ms);
                        if (ms > 0) {
                            ok++;
                        }
                    }
                }
                if (data.optBoolean("ok", false) && ok > 0) {
                    notice("测速完成：" + ok + " 个节点可达"
                            + ("tcp".equals(data.optString("kind")) ? "（TCP 握手耗时）" : ""), true);
                } else if (!data.optBoolean("ok", false)) {
                    notice("测速失败：" + data.optString("error", "无结果"));
                }
                if (lastGroups != null) {
                    renderNodes(lastGroups);
                }
            }

            @Override
            public void onError(String message) {
                testingGroup = "";
                if (isAdded()) {
                    fail(message);
                    if (lastGroups != null) {
                        renderNodes(lastGroups);
                    }
                }
            }
        });
    }

    private void selectNode(String group, String name, boolean topLevel) {
        JSONObject body = new JSONObject();
        try {
            body.put("name", name);
            body.put("group", group);
        } catch (Exception ignored) {
            return;
        }
        notice("正在切换到「" + pretty(name) + "」…");

        Api.post(ctx(), "/api/v1/proxy/select", body, new Cb() {
            @Override
            public void onData(JSONObject data, boolean fromCache) {
                if (!isAdded()) {
                    return;
                }
                if (data.optBoolean("ok", false)) {
                    String chosen = data.optString("name", name);
                    Toast.makeText(ctx(), "已切换到 " + pretty(chosen), Toast.LENGTH_SHORT).show();
                    boolean restarted = data.optBoolean("restarted", false);
                    notice(restarted ? "节点已切换，内核已重启（Passwall 无法热切换）" : null);
                    signature = "";
                    load(true);
                } else {
                    fail(data.optString("error", "切换失败"));
                }
            }

            @Override
            public void onError(String message) {
                if (isAdded()) {
                    fail(message);
                }
            }
        });
    }

    /** 点分段控件直接切，省掉一次弹窗 */
    private void pickModeAt(int index) {
        boolean oc = "openclash".equals(backendId);
        final String[] values = oc
                ? new String[]{"rule", "global", "direct"}
                : new String[]{"proxy", "disable"};
        if (index < 0 || index >= values.length) {
            return;
        }
        setMode(values[index]);
    }

    private void setMode(String mode) {
        // GLOBAL 组指向 REJECT 时切全局模式 = 全家断网。这不是理论风险，
        // 很多订阅的 GLOBAL 默认就是 REJECT，必须先挡一道。
        if ("global".equals(mode) && isRejectPolicy(globalNow)) {
            Sheet.confirm(ctx(), "GLOBAL 当前指向 REJECT",
                    "切到全局模式后所有流量都会被拒绝，全家会立刻断网。\n\n"
                            + "建议先在「节点」里给 GLOBAL 选一个实际节点，再切全局模式。",
                    "仍然切换", true, () -> applyMode(mode));
            return;
        }
        applyMode(mode);
    }

    /** REJECT / REJECT-DROP / PASS 这些是策略动作，不是节点，选它们等于自断网络 */
    private static boolean isRejectPolicy(String name) {
        if (name == null || name.isEmpty()) {
            return false;
        }
        String up = name.toUpperCase(java.util.Locale.ROOT);
        return up.startsWith("REJECT") || up.startsWith("DROP") || "PASS".equals(up);
    }

    /** DIRECT 也是策略动作（不走代理但能上网），颜色上跟节点区分开就行，不算危险 */
    private static boolean isPolicyName(String name) {
        return isRejectPolicy(name) || "DIRECT".equalsIgnoreCase(name);
    }

    private void applyMode(String mode) {
        JSONObject body = new JSONObject();
        try {
            body.put("mode", mode);
        } catch (Exception ignored) {
            return;
        }
        Api.post(ctx(), "/api/v1/proxy/mode", body, new Cb() {
            @Override
            public void onData(JSONObject data, boolean fromCache) {
                if (!isAdded()) {
                    return;
                }
                if (data.optBoolean("ok", true)) {
                    modeValue = mode;
                    tvMode.setText(modeLabel(mode));
                    renderMode();
                    Toast.makeText(ctx(), "已切换为" + modeLabel(mode), Toast.LENGTH_SHORT).show();
                } else {
                    fail(data.optString("error", "切换失败"));
                }
            }

            @Override
            public void onError(String message) {
                if (isAdded()) {
                    fail(message);
                }
            }
        });
    }

    private static String modeLabel(String mode) {
        if (mode == null) {
            return "—";
        }
        switch (mode) {
            case "rule":
                return "规则模式";
            case "global":
                return "全局模式";
            case "direct":
            case "disable":
                return "直连模式";
            case "proxy":
                return "代理模式";
            default:
                return mode;
        }
    }
}
