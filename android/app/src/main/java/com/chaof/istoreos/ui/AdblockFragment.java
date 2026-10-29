package com.chaof.istoreos.ui;

import android.content.Context;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import com.chaof.istoreos.AdblockLogActivity;
import com.chaof.istoreos.R;
import com.chaof.istoreos.WebActivity;
import com.chaof.istoreos.api.Api;
import com.chaof.istoreos.api.Cb;
import com.chaof.istoreos.util.Fmt;
import com.chaof.istoreos.util.Ui;
import com.chaof.istoreos.widget.Sheet;
import com.chaof.istoreos.widget.Toggle;

import org.json.JSONArray;
import org.json.JSONObject;

/**
 * 广告拦截：AdGuard Home 的状态、统计、规则、拦截日志，以及「观察 / 接管」的切换。
 *
 * 版式说明（这次重做）：
 *  - 顶部不再是「标题 + 四行键值对」，而是一张主色渐变卡：
 *    一句话状态、拦截率大字、三个关键数字。这一页用户只想知道「在拦吗、拦了多少」，
 *    其余的监听端口、上游地址属于「配置」，往下放。
 *  - 「当前模式 / 监听 / 上游」改成竖向链路图。DNS 是一条链（客户端 → AGH → 上游），
 *    画成链路比列成四行更容易看懂「谁把请求交给谁」。
 *
 * 日志是重点：用户要能看见「刚刚到底拦了谁」。观察模式下 AGH 只服务路由器本机，
 * 日志里几乎只有本机查询，所以那时候界面会明确提示「要接管才能看到全家的记录」，
 * 而不是给一个空列表让人以为是坏了。
 */
public class AdblockFragment extends BaseFragment {

    /** 渐变卡里的一行文字，运行状态变了要改色 */
    private TextView tvHeroStatus;
    private TextView tvHeroMode;
    private TextView tvHeroPct;
    private TextView tvHeroPctUnit;
    private TextView tvHeroQuery;
    private TextView tvHeroBlocked;
    private TextView tvHeroRules;
    private View heroDot;

    /** 链路图的三段详情 */
    private TextView nodeClientDetail;
    private TextView nodeAghDetail;
    private TextView nodeUpDetail;
    private View nodeAghDot;

    private LinearLayout actionBox;
    private LinearLayout rankBox;

    /** 规则更新卡片：自动/手动徽标、下次更新时间、频率选项、规则列表容器 */
    private TextView tvRulesBadge;
    private TextView tvRulesNext;
    private LinearLayout chipBox;
    private LinearLayout listBox;

    private String mode = "";
    /** 未安装时「去安装」要落的 LuCI 页面，由 Agent 下发 */
    private String installPath = "";
    private String installPkg = "";

    /** DNS 兜底巡检的自愈记录，只在触发过时显示一行说明 */
    private int guardCount;
    private String guardReason = "";

    /** 一键安装：Agent 在路由器上跑，这里只显示进度 */
    private TextView tvInstall;
    private boolean installBusy;
    private final Handler ui = new Handler(Looper.getMainLooper());

    @Override
    protected String title() {
        return "广告拦截";
    }

    @Override
    protected void build(LinearLayout root) {
        final Context c = ctx();
        int wrap = ViewGroup.LayoutParams.WRAP_CONTENT;
        int match = ViewGroup.LayoutParams.MATCH_PARENT;

        // ------------------------------------------------------------ 顶部主卡
        Ui.Card hero = Ui.gradient(c, R.color.hero_from, R.color.hero_to);

        LinearLayout topLine = Ui.row(c);
        heroDot = new View(c);
        GradientDrawable dotBg = new GradientDrawable();
        dotBg.setShape(GradientDrawable.OVAL);
        dotBg.setColor(Ui.alpha(Ui.color(c, R.color.hero_fg), 0.55f));
        heroDot.setBackground(dotBg);
        LinearLayout.LayoutParams dlp = new LinearLayout.LayoutParams(
                Ui.dp(c, 8), Ui.dp(c, 8));
        dlp.rightMargin = Ui.dp(c, 7);
        topLine.addView(heroDot, dlp);

        tvHeroStatus = Ui.heroNote(c, "读取中", 1.0f);
        tvHeroStatus.setTextSize(13f);
        tvHeroStatus.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        topLine.addView(tvHeroStatus, new LinearLayout.LayoutParams(0, wrap, 1f));

        tvHeroMode = Ui.heroNote(c, "—", 0.9f);
        tvHeroMode.setTextSize(11.5f);
        tvHeroMode.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        tvHeroMode.setPadding(Ui.dp(c, 10), Ui.dp(c, 4), Ui.dp(c, 10), Ui.dp(c, 4));
        GradientDrawable chip = new GradientDrawable();
        chip.setCornerRadius(Ui.dp(c, 100));
        chip.setColor(Ui.alpha(Ui.color(c, R.color.hero_fg), 0.16f));
        tvHeroMode.setBackground(chip);
        topLine.addView(tvHeroMode);
        hero.addView(topLine);

        // 拦截率大字：这一页最重要的一个数
        LinearLayout pctLine = Ui.row(c);
        LinearLayout.LayoutParams plp = new LinearLayout.LayoutParams(match, wrap);
        plp.topMargin = Ui.dp(c, 16);
        pctLine.setLayoutParams(plp);
        pctLine.setGravity(Gravity.BOTTOM);

        tvHeroPct = Ui.heroNumber(c, "—");
        pctLine.addView(tvHeroPct);

        tvHeroPctUnit = Ui.heroNote(c, "%", 0.86f);
        tvHeroPctUnit.setTextSize(17f);
        tvHeroPctUnit.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        LinearLayout.LayoutParams ulp = new LinearLayout.LayoutParams(wrap, wrap);
        ulp.leftMargin = Ui.dp(c, 3);
        ulp.bottomMargin = Ui.dp(c, 7);
        pctLine.addView(tvHeroPctUnit, ulp);

        TextView pctLabel = Ui.heroNote(c, "DNS 查询被拦截", 0.86f);
        pctLabel.setTextSize(12.5f);
        pctLabel.setPadding(Ui.dp(c, 10), 0, 0, Ui.dp(c, 9));
        pctLine.addView(pctLabel, new LinearLayout.LayoutParams(0, wrap, 1f));
        pctLabel.setGravity(Gravity.END);
        hero.addView(pctLine);

        // 半透明分隔线：白线压在绿底上，比实色分割更轻
        View hair = new View(c);
        hair.setBackgroundColor(Ui.alpha(Ui.color(c, R.color.hero_fg), 0.18f));
        LinearLayout.LayoutParams hlp = new LinearLayout.LayoutParams(match, Math.max(1,
                Ui.dp(c, 0.7f)));
        hlp.topMargin = Ui.dp(c, 14);
        hero.addView(hair, hlp);

        LinearLayout nums = Ui.row(c);
        nums.setPadding(0, Ui.dp(c, 13), 0, 0);
        tvHeroQuery = heroStat(c, nums, "DNS 查询");
        tvHeroBlocked = heroStat(c, nums, "已拦截");
        tvHeroRules = heroStat(c, nums, "拦截规则");
        hero.addView(nums);

        root.addView(hero);

        // ------------------------------------------------------------ DNS 链路
        Ui.Card chain = Ui.card(c);
        Ui.header(chain, "DNS 链路", "请求从设备到上游依次经过");
        LinearLayout chainBox = Ui.column(c);
        LinearLayout.LayoutParams clp = new LinearLayout.LayoutParams(match, wrap);
        clp.topMargin = Ui.dp(c, 14);
        chainBox.setLayoutParams(clp);

        FrameLayout n1 = Ui.node(c, "家庭设备", "手机 / 电脑 / 电视的 DNS 请求", R.color.text_tertiary, false);
        nodeClientDetail = (TextView) n1.getTag();
        chainBox.addView(n1);

        FrameLayout n2 = Ui.node(c, "AdGuard Home", "规则过滤后转发给上游", R.color.primary, false);
        nodeAghDetail = (TextView) n2.getTag();
        nodeAghDot = n2.findViewWithTag("dot");
        chainBox.addView(n2);

        FrameLayout n3 = Ui.node(c, "上游 DNS", "沿用它现在指向的服务，分流规则不变",
                R.color.text_tertiary, true);
        nodeUpDetail = (TextView) n3.getTag();
        chainBox.addView(n3);

        chain.addView(chainBox);
        root.addView(chain);

        // ------------------------------------------------------------ 拦截记录（前 5）
        // 明细不放首屏：拦截量大时一天几千条，主页面只回答「谁被拦得最多」
        Ui.Card logs = Ui.card(c);
        Ui.header(logs, "拦截记录", "拦截次数最多的前 5 条");

        rankBox = Ui.column(c);
        LinearLayout.LayoutParams rlp2 = new LinearLayout.LayoutParams(match, wrap);
        rlp2.topMargin = Ui.dp(c, 12);
        logs.addView(rankBox, rlp2);

        logs.addView(Ui.divider(c));
        TextView more = Ui.text(c, "查看全部拦截日志", 14.5f, R.color.primary);
        more.setGravity(Gravity.CENTER);
        more.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        more.setPadding(0, Ui.dp(c, 6), 0, Ui.dp(c, 2));
        more.setOnClickListener(v -> startActivity(
                new android.content.Intent(ctx(), AdblockLogActivity.class)));
        logs.addView(more);
        root.addView(logs);

        // ------------------------------------------------------------ 规则更新
        // 这一块回答一个此前界面上找不到答案的问题：规则到底是谁在更新。
        // 「立即更新」不是唯一入口 —— AGH 自带定时任务，默认每 24 小时拉一次，
        // 所以卡片顶部先把「自动 / 手动」亮出来，再给频率和单表开关。
        Ui.Card ruleCard = Ui.card(c);
        LinearLayout ruleHead = Ui.header(ruleCard, "规则更新", "自动还是手动，这里说了算");
        tvRulesBadge = Ui.pill(c, "—", R.color.text_secondary);
        ruleHead.addView(tvRulesBadge);

        TextView freqLabel = Ui.text(c, "自动更新频率", 13f, R.color.text_secondary);
        freqLabel.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        LinearLayout.LayoutParams flp = new LinearLayout.LayoutParams(match, wrap);
        flp.topMargin = Ui.dp(c, 14);
        ruleCard.addView(freqLabel, flp);

        chipBox = Ui.column(c);
        LinearLayout.LayoutParams cblp = new LinearLayout.LayoutParams(match, wrap);
        cblp.topMargin = Ui.dp(c, 9);
        ruleCard.addView(chipBox, cblp);

        tvRulesNext = Ui.kv(ruleCard, "下次更新", "—");
        tvRulesNext.setTextSize(13.5f);

        TextView refreshNow = Ui.filled(c, "立即更新规则", R.color.primary, R.color.on_primary);
        refreshNow.setOnClickListener(v -> confirm("立即更新规则？",
                "会重新下载所有已启用的规则列表，期间拦截可能短暂中断约十秒。"
                        + "更新完成后自动更新的计时也会一起重置。",
                "立即更新", false, "/api/v1/adblock/refresh"));
        LinearLayout.LayoutParams rnlp = new LinearLayout.LayoutParams(match, wrap);
        rnlp.topMargin = Ui.dp(c, 14);
        ruleCard.addView(refreshNow, rnlp);

        listBox = Ui.column(c);
        LinearLayout.LayoutParams lblp = new LinearLayout.LayoutParams(match, wrap);
        lblp.topMargin = Ui.dp(c, 6);
        ruleCard.addView(listBox, lblp);
        root.addView(ruleCard);

        // ------------------------------------------------------------ 操作
        Ui.Card ops = Ui.card(c);
        Ui.header(ops, "操作", "");
        actionBox = Ui.column(c);
        LinearLayout.LayoutParams alp = new LinearLayout.LayoutParams(match, wrap);
        alp.topMargin = Ui.dp(c, 12);
        ops.addView(actionBox, alp);
        root.addView(ops);
    }

    // ================================================================ 规则更新

    /** 可选的自动更新间隔，小时数 + 短标签。0 = 关闭自动更新。 */
    private static final int[] INTERVALS = {0, 6, 12, 24, 48, 72};
    private static final String[] INTERVAL_TEXT = {"关闭", "6 小时", "12 小时", "每天", "2 天", "3 天"};

    private void renderRuleChips(int selectedHours) {
        if (chipBox == null) {
            return;
        }
        Context c = chipBox.getContext();
        chipBox.removeAllViews();
        int gap = Ui.dp(c, 8);

        // 两行三列：六个选项平铺一行会把「12 小时」压成两个字，
        // 换行后每格约 100dp，中文标签刚好放得下
        for (int rowIdx = 0; rowIdx < 2; rowIdx++) {
            LinearLayout rowLine = Ui.row(c);
            LinearLayout.LayoutParams rlp = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            if (rowIdx > 0) {
                rlp.topMargin = gap;
            }
            rowLine.setLayoutParams(rlp);
            for (int col = 0; col < 3; col++) {
                int idx = rowIdx * 3 + col;
                if (idx >= INTERVALS.length) {
                    break;
                }
                rowLine.addView(chip(c, idx, INTERVALS[idx] == selectedHours), chipLp(c, col, gap));
            }
            chipBox.addView(rowLine);
        }
    }

    private LinearLayout.LayoutParams chipLp(Context c, int col, int gap) {
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
        if (col > 0) {
            lp.leftMargin = gap;
        }
        return lp;
    }

    private TextView chip(Context c, int index, boolean on) {
        TextView t = Ui.text(c, INTERVAL_TEXT[index], 13.5f,
                on ? R.color.primary : R.color.text_secondary);
        t.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        t.setGravity(Gravity.CENTER);
        t.setPadding(0, Ui.dp(c, 9), 0, Ui.dp(c, 9));

        GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(Ui.dp(c, 100));
        if (on) {
            bg.setColor(Ui.color(c, R.color.accent_soft2));
            bg.setStroke(Math.max(1, Ui.dp(c, 0.9f)),
                    Ui.alpha(Ui.color(c, R.color.primary), 0.55f));
        } else {
            bg.setColor(Ui.color(c, R.color.surface_hi));
        }
        t.setBackground(new android.graphics.drawable.RippleDrawable(
                android.content.res.ColorStateList.valueOf(Ui.color(c, R.color.ripple)), bg, bg));
        t.setOnClickListener(v -> setInterval(INTERVALS[index]));
        return t;
    }

    private void setInterval(int hours) {
        notice("正在应用…");
        JSONObject body = new JSONObject();
        try {
            body.put("action", "set_interval");
            body.put("interval", hours);
        } catch (org.json.JSONException ignored) {
            // 键名都是常量，不会真的抛
        }
        Api.post(ctx(), "/api/v1/adblock/rules", body, new Cb() {
            @Override
            public void onData(JSONObject res, boolean fromCache) {
                if (!isAdded()) {
                    return;
                }
                notice(null);
                if (res.optBoolean("ok", false)) {
                    renderRules(res);
                    Toast.makeText(ctx(), res.optString("message", "已更新"), Toast.LENGTH_SHORT)
                            .show();
                } else {
                    fail(res.optString("error", "设置失败"));
                }
            }

            @Override
            public void onError(String message) {
                if (isAdded()) {
                    notice(null);
                    fail(message);
                }
            }
        });
    }

    private void toggleRuleList(int id, boolean enable, Toggle toggle) {
        JSONObject body = new JSONObject();
        try {
            body.put("action", "toggle");
            body.put("id", id);
            body.put("enabled", enable);
        } catch (org.json.JSONException ignored) {
            // 同上
        }
        Api.post(ctx(), "/api/v1/adblock/rules", body, new Cb() {
            @Override
            public void onData(JSONObject res, boolean fromCache) {
                if (!isAdded()) {
                    return;
                }
                if (res.optBoolean("ok", false)) {
                    // 启用一张大表会真去下载，条数会变，所以整块重画
                    renderRules(res);
                    Toast.makeText(ctx(), res.optString("message", "已更新"), Toast.LENGTH_SHORT)
                            .show();
                } else {
                    toggle.setOn(!enable, true);
                    fail(res.optString("error", "开关失败"));
                }
            }

            @Override
            public void onError(String message) {
                if (!isAdded()) {
                    return;
                }
                toggle.setOn(!enable, true);
                fail(message);
            }
        });
    }

    private void renderRules(JSONObject r) {
        if (r == null || chipBox == null) {
            return;
        }
        Context c = chipBox.getContext();
        boolean auto = r.optBoolean("auto", false);
        int interval = r.optInt("interval", 0);

        String label = r.optString("interval_label", "");
        if (tvRulesBadge != null) {
            tvRulesBadge.setText(auto ? "自动" : "手动");
            int colorRes = auto ? R.color.primary : R.color.text_secondary;
            tvRulesBadge.setTextColor(Ui.color(c, colorRes));
            GradientDrawable bd = new GradientDrawable();
            bd.setCornerRadius(Ui.dp(c, 100));
            bd.setColor(Ui.alpha(Ui.color(c, colorRes), 0.19f));
            tvRulesBadge.setBackground(bd);
        }

        renderRuleChips(interval);

        if (tvRulesNext != null) {
            if (!auto) {
                tvRulesNext.setText("已关闭，只能手动更新");
                tvRulesNext.setTextColor(Ui.color(c, R.color.warn));
            } else {
                String at = r.optString("next_update", "");
                int left = r.optInt("minutes_left", 0);
                String when;
                if (left <= 0) {
                    when = "随时";
                } else if (left < 60) {
                    when = left + " 分钟后";
                } else {
                    when = Math.round(left / 60f) + " 小时后";
                }
                tvRulesNext.setText(at.isEmpty() ? label : when + "（" + at.substring(
                        Math.min(5, at.length())) + "）");
                tvRulesNext.setTextColor(Ui.color(c, R.color.text_primary));
            }
        }

        // ---- 规则列表
        if (listBox == null) {
            return;
        }
        listBox.removeAllViews();
        JSONArray lists = r.optJSONArray("lists");
        if (lists == null) {
            return;
        }
        for (int i = 0; i < lists.length(); i++) {
            JSONObject f = lists.optJSONObject(i);
            if (f == null) {
                continue;
            }
            if (i == 0) {
                listBox.addView(Ui.hairline(c));
            }
            listBox.addView(ruleRow(c, f));
        }
    }

    /** 一张规则列表：名称 + 条数与更新时间 + 右侧开关 */
    private View ruleRow(Context c, JSONObject f) {
        LinearLayout line = Ui.row(c);
        line.setPadding(0, Ui.dp(c, 11), 0, Ui.dp(c, 11));

        LinearLayout col = Ui.column(c);
        TextView name = Ui.text(c, f.optString("name", "—"), 14.5f, R.color.text_primary);
        name.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        name.setIncludeFontPadding(false);
        name.setSingleLine(true);
        name.setEllipsize(android.text.TextUtils.TruncateAt.END);
        col.addView(name, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        boolean on = f.optBoolean("enabled", false);
        long rules = f.optLong("rules", 0);
        String last = f.optString("last_updated", "");
        String err = f.optString("last_error", "");

        StringBuilder sub = new StringBuilder();
        if (!on) {
            sub.append("已停用");
            if (rules > 0) {
                sub.append("　·　上月下载过 ").append(Fmt.count(rules)).append(" 条");
            }
        } else {
            sub.append(Fmt.count(rules)).append(" 条规则");
            if (!last.isEmpty()) {
                sub.append("　·　").append(friendlyTime(last)).append("更新");
            }
        }
        if (!err.isEmpty()) {
            sub.append("　·　上次失败");
        }

        TextView s = Ui.text(c, sub.toString(), 11.5f,
                err.isEmpty() ? R.color.text_secondary : R.color.danger);
        s.setPadding(0, Ui.dp(c, 4), 0, 0);
        s.setSingleLine(true);
        s.setEllipsize(android.text.TextUtils.TruncateAt.END);
        col.addView(s);

        line.addView(col, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        int id = f.optInt("id", 0);
        Toggle toggle = new Toggle(c);
        toggle.setOn(on, false);
        toggle.setEnabledState(true);
        toggle.setOnChange(want -> {
            toggleRuleList(id, want, toggle);
            // 真正的状态等接口回来再定：这里先放行，让滑块立刻跟手
            return true;
        });
        LinearLayout.LayoutParams tlp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        tlp.leftMargin = Ui.dp(c, 10);
        line.addView(toggle, tlp);

        if (f.optBoolean("enabled", false) == false) {
            // 停用的整行压一点，避免和启用中的抢注意力
            name.setTextColor(Ui.color(c, R.color.text_secondary));
        }
        return line;
    }

    /** 2026-10-25T17:02:07+08:00 → 昨天 17:02 / 10-25 17:02 */
    private static String friendlyTime(String iso) {
        if (iso == null || iso.length() < 16) {
            return "";
        }
        try {
            String day = iso.substring(5, 10);
            String clock = iso.substring(11, 16);
            java.util.Calendar now = java.util.Calendar.getInstance();
            String today = String.format(java.util.Locale.US, "%02d-%02d",
                    now.get(java.util.Calendar.MONTH) + 1,
                    now.get(java.util.Calendar.DAY_OF_MONTH));
            if (day.equals(today)) {
                return clock;
            }
            java.util.Calendar c = java.util.Calendar.getInstance();
            c.add(java.util.Calendar.DAY_OF_MONTH, -1);
            String yesterday = String.format(java.util.Locale.US, "%02d-%02d",
                    c.get(java.util.Calendar.MONTH) + 1,
                    c.get(java.util.Calendar.DAY_OF_MONTH));
            return (day.equals(yesterday) ? "昨天 " : day + " ") + clock;
        } catch (RuntimeException e) {
            return iso;
        }
    }

    /** 渐变卡里的一列：上面大数字，下面小标签 */
    private TextView heroStat(Context c, LinearLayout parent, String label) {
        LinearLayout box = Ui.column(c);
        TextView v = Ui.heroNumber(c, "—");
        v.setTextSize(19f);
        v.setLetterSpacing(0f);
        box.addView(v);
        TextView l = Ui.heroNote(c, label, 0.86f);
        l.setPadding(0, Ui.dp(c, 5), 0, 0);
        box.addView(l);
        parent.addView(box, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        return v;
    }

    @Override
    protected void load(boolean quiet) {
        Api.get(ctx(), "/api/v1/adblock", new Cb() {
            @Override
            public void onData(JSONObject body, boolean fromCache) {
                if (!isAdded()) {
                    return;
                }
                render(body);
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

        // 前五名跟着刷新节拍走：统计窗口是 AGH 启动以来，变化很慢，后端也做了缓存
        Api.get(ctx(), "/api/v1/adblock/top?limit=5", new Cb() {
            @Override
            public void onData(JSONObject body, boolean fromCache) {
                if (isAdded()) {
                    renderRank(body);
                }
            }

            @Override
            public void onError(String message) {
                if (isAdded() && rankBox != null) {
                    rankBox.removeAllViews();
                    rankBox.addView(Ui.label(rankBox.getContext(), "拦截排行读取失败：" + message));
                }
            }
        });

        // 规则清单只在首屏和手动刷新时拉：它一天才变一次，
        // 跟着 3 秒节拍走等于每 3 秒打一次 AGH 的 /filtering/status，纯属浪费
        if (!rulesLoaded || !quiet) {
            Api.get(ctx(), "/api/v1/adblock/rules", new Cb() {
                @Override
                public void onData(JSONObject body, boolean fromCache) {
                    if (!isAdded()) {
                        return;
                    }
                    if (body.optBoolean("ok", false)) {
                        rulesLoaded = true;
                        renderRules(body);
                    }
                }

                @Override
                public void onError(String message) {
                    // 规则读不到不影响上面的状态与统计，静默即可
                }
            });
        }
    }

    private boolean rulesLoaded = false;

    /** 前五名：域名 + 次数 + 占比条 + 名单/最后时间，其余明细在二级页面。 */
    private void renderRank(JSONObject body) {
        if (rankBox == null) {
            return;
        }
        Context c = rankBox.getContext();
        rankBox.removeAllViews();

        if (!body.optBoolean("ok", false)) {
            rankBox.addView(Ui.label(c, "拦截排行读取失败：" + body.optString("error", "未知错误")));
            return;
        }

        if ("observe".equals(body.optString("mode", mode))) {
            TextView tip = Ui.text(c,
                    "当前是观察模式，AGH 只处理路由器本机的 DNS，所以这里几乎没有全家的记录。"
                            + "在下面的「操作」里接管全网后，这里显示的就是全家被拦下的域名排行。",
                    12.5f, R.color.warn);
            tip.setLineSpacing(Ui.dp(c, 2), 1f);
            tip.setPadding(0, 0, 0, Ui.dp(c, 8));
            rankBox.addView(tip);
        }

        JSONArray items = body.optJSONArray("items");
        if (items == null || items.length() == 0) {
            TextView empty = Ui.label(c, "还没有拦截记录");
            empty.setPadding(0, Ui.dp(c, 4), 0, Ui.dp(c, 4));
            rankBox.addView(empty);
            return;
        }

        long max = 1;
        for (int i = 0; i < items.length(); i++) {
            JSONObject it = items.optJSONObject(i);
            if (it != null) {
                max = Math.max(max, it.optLong("count", 0));
            }
        }
        for (int i = 0; i < items.length(); i++) {
            JSONObject it = items.optJSONObject(i);
            if (it == null) {
                continue;
            }
            if (i > 0) {
                rankBox.addView(Ui.divider(c));
            }
            addRankRow(c, it, max, i + 1);
        }

        String window = body.optString("window", "");
        if (!window.isEmpty()) {
            TextView note = Ui.text(c, window + "　共拦截 "
                            + Fmt.count(body.optLong("total_blocked", 0)) + " 次",
                    11f, R.color.text_tertiary);
            note.setPadding(0, Ui.dp(c, 10), 0, 0);
            rankBox.addView(note);
        }
    }

    private void addRankRow(Context c, JSONObject it, long max, int rank) {
        String domain = it.optString("domain", "");
        long count = it.optLong("count", 0);
        double share = it.optDouble("share", 0);
        String list = it.optString("list", "");
        String last = hhmmss(it.optString("last", ""));

        LinearLayout line = Ui.row(c);
        line.setGravity(Gravity.CENTER_VERTICAL);

        // 名次做成小圆徽章：前三名给主色淡底，后面只有灰数字。
        // 排行榜的「名次」本身就是信息，一列同样大小的灰字读起来是没有重点的。
        boolean top = rank <= 3;
        FrameLayout badge = new FrameLayout(c);
        int bs = Ui.dp(c, 20);
        GradientDrawable bbg = new GradientDrawable();
        bbg.setShape(GradientDrawable.OVAL);
        bbg.setColor(top ? Ui.color(c, R.color.accent_soft2) : 0x00000000);
        badge.setBackground(bbg);
        TextView idx = Ui.num(c, String.valueOf(rank), 11.5f,
                top ? R.color.primary : R.color.text_tertiary);
        badge.addView(idx, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER));
        line.addView(badge, new LinearLayout.LayoutParams(bs, bs));

        TextView d = Ui.text(c, domain, 14f, R.color.text_primary);
        d.setSingleLine(true);
        d.setEllipsize(android.text.TextUtils.TruncateAt.END);
        LinearLayout.LayoutParams dlp = new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
        dlp.leftMargin = Ui.dp(c, 9);
        line.addView(d, dlp);

        // 「次」不再是大红字 —— 拦截是好事，红色应该留给真正的危险操作。
        // 数字走 tabular，五条读下来小数点不会左右跳
        TextView n = Ui.num(c, Fmt.count(count), 14.5f, R.color.text_primary);
        n.setGravity(Gravity.END);
        line.addView(n);
        TextView unit = Ui.text(c, " 次", 11f, R.color.text_tertiary);
        unit.setIncludeFontPadding(false);
        line.addView(unit);
        rankBox.addView(line);

        LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        blp.topMargin = Ui.dp(c, 9);
        blp.leftMargin = Ui.dp(c, 29);
        rankBox.addView(Ui.barGradient(c, count / (float) max,
                R.color.primary, R.color.primary_dim), blp);

        StringBuilder meta = new StringBuilder();
        if (share > 0) {
            meta.append(String.format(java.util.Locale.US, "%.1f", share)).append("% 的拦截");
        }
        if (!list.isEmpty()) {
            meta.append(meta.length() > 0 ? "　·　" : "").append(list);
        }
        if (!last.isEmpty()) {
            meta.append(meta.length() > 0 ? "　·　" : "").append(last);
        }
        if (meta.length() == 0) {
            meta.append("—");
        }
        TextView m = Ui.text(c, meta.toString(), 11.5f, R.color.text_secondary);
        m.setSingleLine(true);
        m.setEllipsize(android.text.TextUtils.TruncateAt.END);
        m.setPadding(Ui.dp(c, 29), Ui.dp(c, 6), 0, 0);
        rankBox.addView(m);
    }

    /** AGH 返回的是 2026-10-24T17:02:43.118942863+08:00，只取时分秒 */
    private static String hhmmss(String iso) {
        int t = iso.indexOf('T');
        if (t >= 0 && iso.length() >= t + 9) {
            return iso.substring(t + 1, t + 9);
        }
        return iso.length() > 8 ? iso.substring(11) : iso;
    }

    private void render(JSONObject b) {
        Context c = ctx();
        // 缺这个字段（老 Agent）按「装了」处理，别把一台正常的机器显示成未安装
        boolean installed = b.optBoolean("installed", true);
        boolean running = b.optBoolean("running", false);
        mode = b.optString("mode", "");
        String modeLabel = b.optString("mode_label", mode);

        // 没装的时候给一个能直接落地的入口：软路由上装它要去「软件包」，
        // 让用户自己翻菜单等于把人扔回网页端。路径由 Agent 下发，别写死
        JSONObject ins = b.optJSONObject("install");
        installPath = ins == null ? "" : ins.optString("luci_path", "");
        installPkg = ins == null ? "" : ins.optString("package", "");

        JSONObject guard = b.optJSONObject("guard");
        guardCount = guard == null ? 0 : guard.optInt("count", 0);
        guardReason = guard == null ? "" : guard.optString("reason", "");

        // 状态点与文案：跑起来是主色，没跑是灰色
        String stateText = !installed ? "未安装" : (running ? "运行中" : "未运行");
        int dotColor = !installed ? R.color.text_tertiary
                : (running ? R.color.on_primary : R.color.warn);
        setDot(heroDot, Ui.color(c, dotColor));
        tvHeroStatus.setText(stateText);
        tvHeroMode.setText(modeLabel.isEmpty() ? "—" : modeLabel);

        JSONObject listen = b.optJSONObject("listening");
        int dnsPort = listen == null ? 0 : listen.optInt("port", 0);
        int dnsmasqPort = b.optInt("dnsmasq_port", 0);

        // 上游要能一眼看出「域名还是经过 OpenClash 的」，这是分流不被搞坏的关键
        JSONArray ups = b.optJSONArray("upstream");
        StringBuilder upText = new StringBuilder();
        StringBuilder localText = new StringBuilder();
        if (ups != null) {
            for (int i = 0; i < ups.length(); i++) {
                String s = ups.optString(i, "");
                if (s.isEmpty()) {
                    continue;
                }
                if (s.startsWith("[") && s.contains("]")) {
                    // [/lan/]127.0.0.1:5354 —— 本地域名转发规则
                    String zone = s.substring(1, s.indexOf(']'));
                    if (localText.length() > 0) {
                        localText.append(" · ");
                    }
                    localText.append(zone);
                } else {
                    if (upText.length() > 0) {
                        upText.append("\n");
                    }
                    upText.append(s);
                }
            }
        }

        // ------------------------------------------------------------ 链路图
        if (nodeClientDetail != null) {
            nodeClientDetail.setText(dnsmasqPort > 0
                    ? "dnsmasq :" + dnsmasqPort + "　·　局域网 .lan 与固定 IP 由它解析"
                    : "局域网设备发起 DNS 查询");
        }
        if (nodeAghDetail != null) {
            if (!installed) {
                nodeAghDetail.setText("未安装，DNS 不经过这里");
            } else if (dnsPort > 0) {
                nodeAghDetail.setText("监听 :" + dnsPort + "　·　"
                        + ("takeover".equals(mode) ? "接管全网" : "仅路由器本机"));
            } else {
                nodeAghDetail.setText("未在监听");
            }
        }
        if (nodeAghDot != null) {
            setDot(nodeAghDot, Ui.color(c, installed && running
                    ? R.color.primary : R.color.text_tertiary));
        }
        if (nodeUpDetail != null) {
            String up = upText.length() == 0 ? "—" : upText.toString();
            nodeUpDetail.setText(localText.length() == 0
                    ? up : up + "\n本地域名（" + localText + "）→ dnsmasq");
        }

        // ------------------------------------------------------------ 三个数字
        JSONObject stats = b.optJSONObject("stats");
        long queries = stats == null ? 0 : stats.optLong("queries", 0);
        long blocked = stats == null ? 0 : stats.optLong("blocked", 0);
        double pct = stats == null ? 0 : stats.optDouble("percent", 0);

        // 大字只放百分数，小数保留一位；不要「12.34%」那种满屏数字
        if (pct > 0 && pct < 10) {
            tvHeroPct.setText(String.format(java.util.Locale.US, "%.1f", pct));
        } else {
            tvHeroPct.setText(String.valueOf(Math.round(pct)));
        }
        tvHeroPctUnit.setText("%");

        tvHeroQuery.setText(Fmt.count(queries));
        tvHeroBlocked.setText(Fmt.count(blocked));

        JSONObject filters = b.optJSONObject("filters");
        long rules = filters == null ? 0 : filters.optLong("rules", 0);
        tvHeroRules.setText(Fmt.count(rules));

        renderActions(installed, running);
    }

    /** 圆点换色：直接重建 drawable，比改 tint 兼容性稳 */
    private static void setDot(View dot, int color) {
        if (dot == null) {
            return;
        }
        GradientDrawable d = new GradientDrawable();
        d.setShape(GradientDrawable.OVAL);
        d.setColor(color);
        dot.setBackground(d);
    }

    private void renderActions(boolean installed, boolean running) {
        if (actionBox == null) {
            return;
        }
        Context c = actionBox.getContext();
        actionBox.removeAllViews();

        if (!installed) {
            TextView tip = Ui.text(c, "AdGuard Home 未安装，拦截、规则、日志这些都用不了。"
                            + "装好之后这一页会自动变成可用状态，不用重装 App。",
                    13f, R.color.text_secondary);
            tip.setLineSpacing(Ui.dp(c, 3), 1f);
            tip.setPadding(0, 0, 0, Ui.dp(c, 10));
            actionBox.addView(tip);

            // 进度行：装的时候每 1.2 秒刷一次，装完就隐藏
            tvInstall = Ui.text(c, installBusy ? "安装中…" : "", 12f, R.color.text_secondary);
            tvInstall.setLineSpacing(Ui.dp(c, 2), 1f);
            tvInstall.setPadding(0, 0, 0, Ui.dp(c, 8));
            tvInstall.setVisibility(installBusy ? View.VISIBLE : View.GONE);
            actionBox.addView(tvInstall);

            action(actionBox, "一键安装",
                    "Agent 自动装到路由器，约 6.6 MB，不改 DNS",
                    R.color.primary, true, this::askInstall);

            String pkg = installPkg.isEmpty() ? "luci-app-adguardhome" : installPkg;
            action(actionBox, "去路由器网页安装",
                    "在路由器网页端的「软件包」里装 " + pkg,
                    R.color.text_secondary, false, this::openPackageManager);
            return;
        }

        action(actionBox, "运行体检", "逐项检查端口、上游、规则、统计是否正常",
                R.color.primary, false, this::runPreflight);

        if ("takeover".equals(mode)) {
            action(actionBox, "退出接管", "DNS 回到 dnsmasq，拦截失效但网络不受影响",
                    R.color.text_primary, false, () -> confirm("退出接管？",
                            "DNS 会回到 dnsmasq，广告拦截立即失效，但网络不受影响。",
                            "退出接管", false, "/api/v1/adblock/release"));
        } else {
            action(actionBox, "接管全网", "全设备拦截 + 完整日志，失败自动回滚",
                    R.color.primary, true, () -> confirm("接管全网 DNS？",
                            "AGH 会占用 53 端口；dnsmasq 挪到 5354，继续负责 .lan 和固定 IP，"
                                    + "所以 NAS、打印机照样能用主机名访问。\n\n"
                                    + "上游沿用它现在指的 OpenClash，分流规则不变；"
                                    + "接管后会实测国内 / 国外 / 本地三类域名，"
                                    + "任何一项不通都会自动回滚。",
                            "确认接管", false, "/api/v1/adblock/takeover"));
        }

        // 「刷新规则」已经挪到上面的「规则更新」卡里（那里能看频率、能改间隔），
        // 这里不再重复放一个同样的入口，否则同一件事有两个按钮

        // 巡检触发过自愈时留一条痕迹：否则用户只会看到「怎么突然变成观察模式了」
        if (guardCount > 0) {
            TextView note = Ui.text(c, "DNS 巡检触发过 " + guardCount + " 次自愈"
                            + (guardReason.isEmpty() ? "" : " · " + guardReason)
                            + "（53 没人应答时自动把 dnsmasq 放回去）",
                    11.5f, R.color.text_tertiary);
            note.setLineSpacing(Ui.dp(c, 2), 1f);
            note.setPadding(Ui.dp(c, 2), Ui.dp(c, 6), 0, 0);
            actionBox.addView(note);
        }
    }

    /** 打开路由器网页端的软件包页：Agent 已经换好免密票据，落地就能装 */
    private void openPackageManager() {
        Context c = ctx();
        if (c == null) {
            return;
        }
        android.content.Intent it = new android.content.Intent(c, WebActivity.class);
        it.putExtra(WebActivity.EXTRA_TITLE, "安装 AdGuard Home");
        if (!installPath.isEmpty()) {
            it.putExtra(WebActivity.EXTRA_PATH, installPath);
        }
        c.startActivity(it);
    }

    /**
     * 一键安装的第一步：把「会做什么」讲清楚再让用户点。
     *
     * 装包这件事不可逆（卸载要另跑 opkg），而且会联网下载 6 MB，
     * 所以必须二次确认；确认后由 Agent 在路由器上执行，App 只轮询进度。
     */
    private void askInstall() {
        Sheet.confirm(ctx(), "在路由器上安装 AdGuard Home？",
                "Agent 会在路由器上依次执行：\n"
                        + "· 联网下载本体（约 6.6 MB，来自 static.adtidy.org）\n"
                        + "· 解包到 /usr/bin/AdGuardHome\n"
                        + "· 以观察模式启动：只监听 127.0.0.1，53 端口仍归 dnsmasq\n\n"
                        + "全程不改 DNS、不影响家里上网，大约 1–3 分钟，可以切走干别的。",
                "开始安装", false, this::startInstall);
    }

    private void startInstall() {
        final Context c = ctx();
        if (c == null) {
            return;
        }
        installBusy = true;
        if (tvInstall != null) {
            tvInstall.setText("已提交，正在安装…");
            tvInstall.setTextColor(Ui.color(c, R.color.text_secondary));
            tvInstall.setVisibility(View.VISIBLE);
        }

        JSONObject body = new JSONObject();
        try {
            body.put("confirm", "install");
        } catch (Exception ignored) {
        }
        Api.post(c, "/api/v1/adblock/install", body, new Cb() {
            @Override
            public void onData(JSONObject data, boolean fromCache) {
                if (!isAdded()) {
                    return;
                }
                if (!data.optBoolean("ok", false)) {
                    installBusy = false;
                    Toast.makeText(c, data.optString("error", "安装没被受理"),
                            Toast.LENGTH_LONG).show();
                    return;
                }
                tickInstall();
            }

            @Override
            public void onError(String message) {
                installBusy = false;
                if (isAdded()) {
                    Toast.makeText(c, "安装请求失败：" + message, Toast.LENGTH_LONG).show();
                }
            }
        });
    }

    /** 轮询安装进度。1.2 秒一跳，装完自动刷新整页 */
    private void tickInstall() {
        if (!isAdded() || !installBusy) {
            return;
        }
        final Context c = ctx();
        if (c == null) {
            return;
        }
        Api.get(c, "/api/v1/adblock/install", new Cb() {
            @Override
            public void onData(JSONObject s, boolean fromCache) {
                if (!isAdded()) {
                    return;
                }
                boolean done = s.optBoolean("done", false);
                boolean running = s.optBoolean("running", false);
                boolean ok = s.optBoolean("ok", false);
                String err = s.optString("error", "");
                String step = s.optString("step", "");

                if (tvInstall != null) {
                    String text = ok ? "已安装，正在刷新…"
                            : (!err.isEmpty() ? "失败：" + err : step + " · " + s.optInt("pct", 0) + "%");
                    tvInstall.setText(text);
                    tvInstall.setTextColor(Ui.color(c,
                            (done && !ok) ? R.color.danger : R.color.text_secondary));
                }

                if (done && !running) {
                    installBusy = false;
                    Toast.makeText(c, ok ? "装好了，这一页已经可用" : "安装失败：" + err,
                            Toast.LENGTH_LONG).show();
                    // /adblock 有 2 秒缓存，稍等一下再拉，避免又读到 installed=false
                    ui.postDelayed(() -> {
                        if (isAdded()) {
                            load(false);
                        }
                    }, 1600);
                    return;
                }
                ui.postDelayed(AdblockFragment.this::tickInstall, 1200);
            }

            @Override
            public void onError(String message) {
                if (!isAdded() || !installBusy) {
                    return;
                }
                ui.postDelayed(AdblockFragment.this::tickInstall, 2500);
            }
        });
    }

    /**
     * 操作项：左侧标题 + 副标题，右侧箭头。
     * 主操作用主色淡底 + 描边强调，其余用浅灰底 —— 一眼能看出「现在该点哪个」。
     */
    private void action(LinearLayout box, String title, String sub, int colorRes,
                        boolean accent, Runnable onClick) {
        Context c = box.getContext();
        LinearLayout line = Ui.row(c);
        line.setPadding(Ui.dp(c, 14), Ui.dp(c, 13), Ui.dp(c, 14), Ui.dp(c, 13));
        line.setClickable(true);
        line.setFocusable(true);

        GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(Ui.dp(c, 16));
        if (accent) {
            bg.setColor(Ui.alpha(Ui.color(c, R.color.primary), 0.12f));
            bg.setStroke(Math.max(1, Ui.dp(c, 0.7f)),
                    Ui.alpha(Ui.color(c, R.color.primary), 0.35f));
        } else {
            bg.setColor(Ui.color(c, R.color.surface_hi));
        }
        line.setBackground(bg);
        line.setOnClickListener(v -> onClick.run());

        LinearLayout texts = Ui.column(c);
        TextView t = Ui.text(c, title, 15f, colorRes);
        t.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        t.setIncludeFontPadding(false);
        texts.addView(t);
        if (sub != null && !sub.isEmpty()) {
            TextView s = Ui.text(c, sub, 12f, R.color.text_secondary);
            s.setPadding(0, Ui.dp(c, 3), 0, 0);
            texts.addView(s);
        }
        line.addView(texts, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        TextView arrow = Ui.text(c, "\u203A", 18f, R.color.text_tertiary);
        arrow.setPadding(Ui.dp(c, 8), 0, 0, 0);
        line.addView(arrow);

        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.bottomMargin = Ui.dp(c, 8);
        box.addView(line, lp);
    }

    private void confirm(String title, String message, String ok, boolean danger, String path) {
        Sheet.confirm(ctx(), title, message, ok, danger, () -> post(path));
    }

    private void post(String path) {
        Api.post(ctx(), path, new JSONObject(), new Cb() {
            @Override
            public void onData(JSONObject body, boolean fromCache) {
                if (!isAdded()) {
                    return;
                }
                boolean ok = body.optBoolean("ok", false);
                String msg = ok
                        ? body.optString("message", "已完成")
                        : body.optString("error", body.optString("message", "操作失败"));
                JSONObject accept = body.optJSONObject("accept");
                if (ok && accept != null) {
                    // 接管成功要把三项实测结果摆出来，而不是只丢一句「成功」
                    showAccept(msg, accept, body.optString("upstream_note", ""));
                } else {
                    notice(msg, ok);
                    Sheet.message(ctx(), ok ? "已完成" : "操作失败", msg);
                }
                load(true);
            }

            @Override
            public void onError(String message) {
                if (isAdded()) {
                    fail(message);
                }
            }
        });
    }

    /** 接管后的三项实测：逐条打勾，比一整段文字好读 */
    private void showAccept(String title, JSONObject accept, String note) {
        Sheet.Builder b = Sheet.custom(ctx(), title);
        if (!note.isEmpty()) {
            b.body(note);
        }
        JSONArray items = accept.optJSONArray("items");
        if (items != null) {
            for (int i = 0; i < items.length(); i++) {
                JSONObject o = items.optJSONObject(i);
                if (o != null) {
                    b.content(checkRow(ctx(), o.optBoolean("ok", false),
                            o.optString("label"), o.optString("domain"),
                            o.optString("detail")));
                }
            }
        }
        b.primary("好", false, null);
        b.show();
    }

    private void runPreflight() {
        notice("正在体检…");
        // 体检走 GET /adblock/preflight；POST /adblock/probe 是另一条路由
        Api.getFresh(ctx(), "/api/v1/adblock/preflight", new Cb() {
            @Override
            public void onData(JSONObject body, boolean fromCache) {
                if (!isAdded()) {
                    return;
                }
                notice(null);
                JSONArray checks = body.optJSONArray("checks");
                int pass = 0;
                int total = 0;
                Sheet.Builder b = Sheet.custom(ctx(),
                        body.optBoolean("ready", false) ? "体检通过" : "体检发现问题");
                if (checks != null) {
                    for (int i = 0; i < checks.length(); i++) {
                        JSONObject o = checks.optJSONObject(i);
                        if (o == null) {
                            continue;
                        }
                        boolean ok = o.optBoolean("ok", false);
                        total++;
                        if (ok) {
                            pass++;
                        }
                        b.content(checkRow(ctx(), ok, o.optString("label", ""), "",
                                o.optString("detail", "")));
                    }
                }
                b.body("共 " + total + " 项检查，" + pass + " 项通过"
                        + (pass == total ? "，一切正常。" : "，标红的需要处理。"));
                b.primary("知道了", false, null);
                b.show();
            }

            @Override
            public void onError(String message) {
                if (isAdded()) {
                    fail(message);
                }
            }
        });
    }

    /** 一行检查结果：✓/✗ 圆点 + 名称 + 详情 */
    private View checkRow(Context c, boolean ok, String label, String domain, String detail) {
        LinearLayout line = Ui.row(c);
        line.setPadding(0, Ui.dp(c, 9), 0, Ui.dp(c, 9));

        TextView mark = Ui.text(c, ok ? "\u2713" : "\u2715", 13f,
                ok ? R.color.ok : R.color.danger);
        mark.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        mark.setGravity(Gravity.CENTER);
        GradientDrawable mbg = new GradientDrawable();
        mbg.setShape(GradientDrawable.OVAL);
        mbg.setColor(Ui.alpha(Ui.color(c, ok ? R.color.ok : R.color.danger), 0.14f));
        mark.setBackground(mbg);
        line.addView(mark, new LinearLayout.LayoutParams(Ui.dp(c, 22), Ui.dp(c, 22)));

        LinearLayout body = Ui.column(c);
        LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
        blp.leftMargin = Ui.dp(c, 10);
        line.addView(body, blp);

        StringBuilder head = new StringBuilder(label == null ? "" : label);
        if (domain != null && !domain.isEmpty()) {
            head.append("　").append(domain);
        }
        TextView t = Ui.text(c, head.toString(), 14f, R.color.text_primary);
        t.setIncludeFontPadding(false);
        body.addView(t);

        if (detail != null && !detail.isEmpty()) {
            TextView d = Ui.text(c, detail, 12f, R.color.text_secondary);
            d.setPadding(0, Ui.dp(c, 3), 0, 0);
            d.setLineSpacing(Ui.dp(c, 2), 1f);
            body.addView(d);
        }
        return line;
    }
}
