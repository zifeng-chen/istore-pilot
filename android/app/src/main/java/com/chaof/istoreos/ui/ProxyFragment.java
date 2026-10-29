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
import com.chaof.istoreos.SubscriptionActivity;
import com.chaof.istoreos.api.Api;
import com.chaof.istoreos.api.Cb;
import com.chaof.istoreos.util.Ui;
import com.chaof.istoreos.widget.Glyph;
import com.chaof.istoreos.widget.Hero;
import com.chaof.istoreos.widget.Radio;
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
 * 这一版重构的几处：
 *   1. 顶部换成和概览/网络/设备同一个 {@link Hero}，四段文字：状态、后端、配置名、摘要。
 *      以前这页的最高优先级信息（谁在跑）是第二张卡的第一行。
 *   2. 后端不再是「两行光秃秃的文字」，改成图标块 + 名称 + 引擎节点数 + 状态胶囊，
 *      和设置页的入口行同一套骨架。
 *   3. 节点行的选中态从 "●/○" 字符换成自绘 {@link Radio} —— 字符会跟着字号
 *      基线漂移，跟在 14sp 名字旁边一高一低，而且不同 ROM 的字形胖瘦不一。
 *   4. 延迟从「裸文字 23ms」换成胶囊：绿/琥珀/红三档底色自带语义，
 *      一列扫下来不用逐个读数字。
 *
 * 折叠状态必须自己记住：以前用「集合为空就展开第一组」做初始化，
 * 结果把唯一展开的那个组收起来后集合归空，下一次渲染又自动展开 ——
 * 表现就是「GLOBAL 怎么点都收不起来」。现在**全部默认折叠**、状态只由点击改，
 * 不再替用户做初始展开（自动展开「自动选择」会让一进来就是几十行节点）。
 */
public class ProxyFragment extends BaseFragment {

    private Hero hero;

    private LinearLayout backendBox;
    private LinearLayout modeBox;
    private TextView tvMode;
    private TextView tvModeHint;
    private LinearLayout nodesBox;
    private TextView tvSubCount;
    /** 「当前配置文件」那一行的值，切换后原地改文案 */
    private TextView tvCurConfig;

    /** 配置文件清单，弹窗切换时直接用，不再请求一次 */
    private JSONArray configs;
    private String currentConfigPath = "";

    private String backendId = "";
    private String backendLabel = "";
    private String signature = "";
    private final Set<String> expanded = new LinkedHashSet<>();
    private String modeValue = "";
    /** GLOBAL 组当前指向谁，切全局模式前用来判断会不会一把拒掉所有流量 */
    private String globalNow = "";
    /** 分组默认只展开一次，之后完全听用户的 */
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

        // ---------------------------------------------------------- 结论
        hero = new Hero(c);
        root.addView(hero);

        // ---------------------------------------------------------- 代理后端
        // 并进 hero：后端是「这一页在管谁」的身份信息，本来就该跟状态放一起。
        // 原来它单独占一张白卡，hero 里又重复写一遍后端名，等于说两遍
        TextView backCap = Ui.heroNote(c, "代理后端 · 点一行切换", 0.62f);
        backCap.setTextSize(11f);
        LinearLayout.LayoutParams bclp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        bclp.topMargin = Ui.dp(c, 16);
        hero.addView(backCap, bclp);

        backendBox = Ui.column(c);
        LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        blp.topMargin = Ui.dp(c, 6);
        hero.addView(backendBox, blp);

        // ---------------------------------------------------------- 运行模式
        Ui.Card mode = Ui.card(c);
        Ui.cardPadding(mode, 0);   // 最后一行是说明文字，自身无内边距
        LinearLayout modeHead = Ui.cardTitle(c, mode, Glyph.BOLT, "运行模式", "改完立即生效");
        tvMode = Ui.num(c, "—", 13.5f, R.color.primary);
        tvMode.setGravity(Gravity.END);
        modeHead.addView(tvMode);

        modeBox = Ui.column(c);
        modeBox.setPadding(Ui.dp(c, 16), 0, Ui.dp(c, 16), 0);
        LinearLayout.LayoutParams mlp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        mlp.topMargin = Ui.dp(c, 12);
        mode.addView(modeBox, mlp);

        tvModeHint = Ui.text(c, "", 11.5f, R.color.text_secondary);
        tvModeHint.setPadding(Ui.dp(c, 16), Ui.dp(c, 9), Ui.dp(c, 16), 0);
        tvModeHint.setLineSpacing(Ui.dp(c, 2), 1f);
        mode.addView(tvModeHint);
        root.addView(mode);

        // ---------------------------------------------------------- 配置与节点
        Ui.Card combo = Ui.card(c);
        Ui.cardPadding(combo, 3);  // 最后一行是分组标题，底部留 3
        Ui.cardTitle(c, combo, Glyph.LIST, "配置与节点", "换配置会重启内核，断网十几秒");

        // 当前配置：整行可点，右侧「切换」胶囊给出明确的可操作性
        LinearLayout cfgSlot = Ui.infoRow(c, combo, Glyph.KEY, "当前配置", true);
        tvCurConfig = Ui.num(c, "读取中…", 13.5f, R.color.text_primary);
        tvCurConfig.setGravity(Gravity.END);
        tvCurConfig.setSingleLine(true);
        tvCurConfig.setEllipsize(android.text.TextUtils.TruncateAt.MIDDLE);
        LinearLayout.LayoutParams clp = new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
        cfgSlot.addView(tvCurConfig, clp);
        TextView switchPill = Ui.pill(c, "切换", R.color.primary);
        LinearLayout.LayoutParams splp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        splp.leftMargin = Ui.dp(c, 8);
        cfgSlot.addView(switchPill, splp);
        tapRow(cfgSlot, this::showConfigPicker);

        // 订阅：增删改在独立页面，这里只给入口和条数
        LinearLayout subSlot = Ui.infoRow(c, combo, Glyph.UPLOAD, "订阅管理", false);
        tvSubCount = Ui.num(c, "", 13.5f, R.color.text_secondary);
        subSlot.addView(tvSubCount);
        subSlot.addView(Ui.chevron(c));
        tapRow(subSlot, this::openSubscriptions);

        combo.addView(Ui.hairline(c, 16));
        Ui.cardSubTitle(c, combo, "节点");
        nodesBox = Ui.column(c);
        combo.addView(nodesBox);

        root.addView(combo);
    }

    /** 让 infoRow 的整行可点（插槽本身只有文字宽，点空白区域也该响应） */
    private void tapRow(LinearLayout slot, Runnable action) {
        View row = (View) slot.getParent();
        if (row == null) {
            return;
        }
        row.setClickable(true);
        row.setFocusable(true);
        GradientDrawable mask = new GradientDrawable();
        mask.setColor(0xFFFFFFFF);
        row.setBackground(new android.graphics.drawable.RippleDrawable(
                android.content.res.ColorStateList.valueOf(
                        Ui.color(row.getContext(), R.color.ripple)), null, mask));
        row.setOnClickListener(v -> action.run());
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


    /** hero 深色底上的小胶囊：白字 + on-primary 淡底 */
    private TextView heroPill(Context c, String text, boolean on) {
        TextView v = Ui.text(c, text, 11f, R.color.hero_fg);
        v.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        v.setPadding(Ui.dp(c, 9), Ui.dp(c, 3), Ui.dp(c, 9), Ui.dp(c, 3));
        GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(Ui.dp(c, 100));
        bg.setColor(Ui.alpha(Ui.color(c, R.color.hero_fg), on ? 0.22f : 0.10f));
        v.setBackground(bg);
        return v;
    }

    private void renderBackends(JSONObject body) {
        Context c = backendBox.getContext();
        backendBox.removeAllViews();
        backendLabel = "";

        String active = body.optString("active", "none");
        JSONArray arr = body.optJSONArray("backends");
        backendId = "none".equals(active) ? "" : active;
        int activeCount = 0;
        String activeEngine = "";

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
                String engine = b.optString("engine", "");
                int count = b.optInt("node_count", 0);

                if (i > 0) {
                    // hero 是深绿底，卡片那套 divider 色在上面看不见
                    View hair = new View(c);
                    hair.setBackgroundColor(Ui.alpha(Ui.color(c, R.color.hero_fg), 0.16f));
                    LinearLayout.LayoutParams hlp = new LinearLayout.LayoutParams(
                            ViewGroup.LayoutParams.MATCH_PARENT, Math.max(1, Ui.dp(c, 0.7f)));
                    hlp.topMargin = Ui.dp(c, 2);
                    backendBox.addView(hair, hlp);
                }

                LinearLayout line = Ui.row(c);
                // hero 自己已经有 20dp 内边距，这里不再加左右
                line.setPadding(0, Ui.dp(c, 10), 0, Ui.dp(c, 10));

                LinearLayout tile = Ui.glyphTile(c, Glyph.POWER, 30, R.color.hero_fg);
                LinearLayout.LayoutParams tlp = new LinearLayout.LayoutParams(
                        Ui.dp(c, 30), Ui.dp(c, 30));
                tlp.rightMargin = Ui.dp(c, 12);
                line.addView(tile, tlp);

                LinearLayout col = Ui.column(c);
                TextView name = Ui.text(c, label, 15f, R.color.hero_fg);
                name.setTextColor(Ui.alpha(Ui.color(c, R.color.hero_fg), running ? 1f : 0.62f));
                name.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
                name.setSingleLine(true);
                col.addView(name);

                String sub = installed
                        ? (engine.isEmpty() ? "" : engine + " · ") + count + " 个节点"
                        : "未安装";
                TextView subText = Ui.text(c, sub, 11.5f, R.color.hero_fg);
                subText.setTextColor(Ui.alpha(Ui.color(c, R.color.hero_fg), 0.62f));
                subText.setPadding(0, Ui.dp(c, 3), 0, 0);
                subText.setSingleLine(true);
                col.addView(subText);

                line.addView(col, new LinearLayout.LayoutParams(0,
                        ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

                if (running) {
                    line.addView(heroPill(c, "运行中", true));
                    backendLabel = label;
                    activeCount = count;
                    activeEngine = engine;
                } else {
                    // 用 text_on_track 而不是 text_secondary：
                    // 灰字配 19% 灰底，在深色下「未运行」几乎读不出来
                    line.addView(heroPill(c, installed ? "未运行" : "未安装", false));
                    // 装好了但没跑，点一下就能切过去 —— 比让用户去后台点强
                    if (installed) {
                        final String fid = id;
                        final String flabel = label;
                        line.setClickable(true);
                        line.setFocusable(true);
                        GradientDrawable mask = new GradientDrawable();
                        mask.setColor(0xFFFFFFFF);
                        line.setBackground(new android.graphics.drawable.RippleDrawable(
                                android.content.res.ColorStateList.valueOf(
                                        Ui.color(c, R.color.ripple)), null, mask));
                        line.setOnClickListener(v -> askSwitchBackend(fid, flabel));
                    }
                }

                backendBox.addView(line);
            }
        }

        boolean none = "none".equals(active);
        if (hero != null) {
            hero.dot(R.color.hero_fg, none);
            hero.state.setText(none ? "都没在运行" : "运行中");
            hero.badge.setText(none ? "未启用" : backendLabel);
            hero.title.setText(none ? "直连" : "—");
            hero.note.setText(none
                    ? "两个代理后端都停着，所有流量走直连"
                    : join(activeEngine, activeCount + " 个节点可用", modeLabel(modeValue)));
        }
        renderMode();
        loadConfigs();
        loadSubCount();
    }

    private static String join(String... parts) {
        StringBuilder sb = new StringBuilder();
        for (String p : parts) {
            if (p == null || p.isEmpty()) {
                continue;
            }
            if (sb.length() > 0) {
                sb.append("　·　");
            }
            sb.append(p);
        }
        return sb.toString();
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
                            notice(ok ? label + " 已启动" : "启动失败，看日志确认", ok);
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

    /** 当前启用的 OpenClash 配置文件。切换走弹窗，这里只负责显示。 */
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
                if (hero != null && !backendId.isEmpty()) {
                    hero.title.setText(name);
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

    private void openSubscriptions() {
        if (backendId.isEmpty()) {
            notice("两个代理后端都没在运行，订阅不可用");
            return;
        }
        Intent it = new Intent(ctx(), SubscriptionActivity.class);
        it.putExtra("backend", backendId);
        startActivity(it);
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

        if (tvModeHint != null) {
            tvModeHint.setText(modeHint(backendId, modeValue));
        }
    }

    /** 模式的后果，一句话说清。光有「规则/全局/直连」三个字，多数人不知道差在哪 */
    private static String modeHint(String backend, String mode) {
        boolean oc = "openclash".equals(backend);
        if (oc) {
            switch (mode == null ? "" : mode) {
                case "rule":
                    return "按规则分流：命中的走节点，其余直连。日常用这个。";
                case "global":
                    return "全部流量走当前节点，不看规则。节点选错会全家上不了网。";
                case "direct":
                    return "不走代理，所有流量直连。";
                default:
                    return "还没读到当前模式。";
            }
        }
        switch (mode == null ? "" : mode) {
            case "proxy":
                return "按 Passwall 规则分流：命中的走节点，其余直连。";
            case "disable":
                return "不走代理，所有流量直连。";
            default:
                return "还没读到当前模式。";
        }
    }

    private void renderNodes(JSONObject body) {
        Context c = nodesBox.getContext();
        nodesBox.removeAllViews();

        JSONArray groups = body.optJSONArray("groups");
        if (groups == null || groups.length() == 0) {
            String err = body.optString("error", "没有可用的节点");
            TextView t = Ui.text(c, err, 13f, R.color.text_tertiary);
            t.setPadding(Ui.dp(c, 16), Ui.dp(c, 10), Ui.dp(c, 16), Ui.dp(c, 10));
            nodesBox.addView(t);
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

        // 分组一律默认折叠：一屏先看到所有「组名 + 当前节点 + 节点数」，
        // 想换哪个再展开哪个。以前会自动展开第一个（排序后就是「自动选择」），
        // 进来先被几十个节点铺满屏，反而不容易找到别的组

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
                nodesBox.addView(Ui.hairline(c, 16));
            }
            nodesBox.addView(groupHead(c, g, gname, now, members, open, testing));
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
     * 分组标题，两行：
     *
     *   ▾ 自动选择                                    [测速]
     *     当前 日本高速06|BGP|CTCU              57 个
     *
     * 原来把「分组名 + 当前节点 + 节点数 + 测速」全塞一行，中文节点名动辄十几字，
     * 结果当前节点被压成「日本高速06|BGP|CT…」，而孤零零一个「57」也不知道是什么。
     * 拆成两行后：名字能全显示，数字带上量词，测速还在原位。
     *
     * 第二行即使折叠也保留 —— 收起分组时「这组现在用哪个节点」正是最想知道的。
     */
    private View groupHead(Context c, JSONObject g, String gname, String now,
                           JSONArray members, boolean open, boolean testing) {
        LinearLayout block = Ui.column(c);

        LinearLayout head = Ui.row(c);
        head.setPadding(Ui.dp(c, 10), Ui.dp(c, 9), Ui.dp(c, 10), Ui.dp(c, 3));
        block.addView(head);

        TextView caret = Ui.text(c, open ? "\u25BE" : "\u25B8", 11f, R.color.text_secondary);
        caret.setPadding(Ui.dp(c, 2), 0, Ui.dp(c, 6), 0);
        head.addView(caret);

        TextView name = Ui.text(c, pretty(gname), 15f, R.color.text_primary);
        name.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        name.setSingleLine(true);
        name.setEllipsize(android.text.TextUtils.TruncateAt.END);
        head.addView(name, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        TextView btn = Ui.text(c, testing ? "测速中" : "测速", 11.5f,
                testing ? R.color.text_secondary : R.color.primary);
        btn.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        btn.setPadding(Ui.dp(c, 9), Ui.dp(c, 4), Ui.dp(c, 9), Ui.dp(c, 4));
        GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(Ui.dp(c, 100));
        bg.setColor(Ui.color(c, testing ? R.color.surface_sunken : R.color.accent_soft));
        btn.setBackground(bg);
        // 测速按钮要在外层之前消费点击，否则会被折叠动作吃掉
        btn.setClickable(true);
        btn.setFocusable(true);
        btn.setOnClickListener(v -> testGroup(gname));
        head.addView(btn);

        // ---- 第二行：当前节点 + 节点数
        LinearLayout sub = Ui.row(c);
        sub.setPadding(Ui.dp(c, 30), 0, Ui.dp(c, 10), Ui.dp(c, 9));
        block.addView(sub);

        String cur = pretty(now);
        // 订阅常把「剩余流量：xxx」塞进节点列表还设成当前项，
        // 照实显示会让人以为流量走了个叫「剩余流量」的节点，说清楚更好
        boolean info = now.isEmpty()
                && (g.optBoolean("now_info", false) || isInfoNode(g.optString("now", "")));
        TextView nowText;
        if (!cur.isEmpty()) {
            nowText = Ui.text(c, "当前 " + cur, 11.5f,
                    isPolicyName(cur) ? R.color.text_secondary : R.color.primary);
        } else if (info) {
            nowText = Ui.text(c, "未选中可用节点", 11.5f, R.color.text_secondary);
        } else {
            nowText = Ui.text(c, "未选择", 11.5f, R.color.text_tertiary);
        }
        nowText.setSingleLine(true);
        nowText.setEllipsize(android.text.TextUtils.TruncateAt.END);
        sub.addView(nowText, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        int total = members == null ? 0 : members.length();
        TextView count = Ui.num(c, total + " 个", 11.5f, R.color.text_tertiary);
        count.setPadding(Ui.dp(c, 8), 0, 0, 0);
        sub.addView(count);

        block.setClickable(true);
        block.setFocusable(true);
        GradientDrawable mask = new GradientDrawable();
        mask.setColor(0xFFFFFFFF);
        block.setBackground(new android.graphics.drawable.RippleDrawable(
                android.content.res.ColorStateList.valueOf(Ui.color(c, R.color.ripple)),
                null, mask));
        block.setOnClickListener(v -> {
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
        return block;
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

    /** 节点行：缩进一级（34dp 对齐分组名的文字起点），左侧单选点，右侧延迟胶囊 */
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

        int onColor = isRejectPolicy(name) ? R.color.danger
                : (policy ? R.color.text_secondary : R.color.primary);

        LinearLayout line = Ui.row(c);
        line.setPadding(Ui.dp(c, 34), Ui.dp(c, 8), Ui.dp(c, 16), Ui.dp(c, 8));
        line.setClickable(true);
        line.setFocusable(true);

        Radio radio = new Radio(c, selected ? onColor : R.color.text_tertiary);
        radio.setOn(selected);
        LinearLayout.LayoutParams rlp = new LinearLayout.LayoutParams(
                Ui.dp(c, 15), Ui.dp(c, 15));
        rlp.rightMargin = Ui.dp(c, 10);
        line.addView(radio, rlp);

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
            line.addView(delayChip(c, fresh, fresh > 0 ? delayColor(fresh) : R.color.danger));
        } else {
            Object delay = m.opt("delay");
            int ms = delay instanceof Number ? ((Number) delay).intValue() : -1;
            if (ms > 0) {
                line.addView(delayChip(c, ms, delayColor(ms)));
            } else if (isGroup) {
                TextView d = Ui.text(c, "组", 11f, R.color.text_secondary);
                line.addView(d);
            } else {
                TextView d = Ui.text(c, "—", 11f, R.color.text_tertiary);
                line.addView(d);
            }
        }

        GradientDrawable mask = new GradientDrawable();
        mask.setColor(0xFFFFFFFF);
        line.setBackground(new android.graphics.drawable.RippleDrawable(
                android.content.res.ColorStateList.valueOf(Ui.color(c, R.color.ripple)),
                null, mask));
        line.setOnClickListener(v -> selectNode(group, name, true));
        nodesBox.addView(line);
    }

    /** 延迟胶囊：绿 / 琥珀 / 红三档，一列扫下来不用逐个读数字 */
    private TextView delayChip(Context c, int ms, int colorRes) {
        String text = ms > 0 ? ms + "ms" : "超时";
        TextView t = Ui.pill(c, text, colorRes);
        return t;
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
