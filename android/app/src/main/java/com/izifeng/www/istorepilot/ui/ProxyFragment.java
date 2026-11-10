package com.izifeng.www.istorepilot.ui;

import android.app.Dialog;
import android.content.Context;
import android.content.Intent;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import com.izifeng.www.istorepilot.R;
import com.izifeng.www.istorepilot.SubscriptionActivity;
import com.izifeng.www.istorepilot.api.Api;
import com.izifeng.www.istorepilot.api.Cb;
import com.izifeng.www.istorepilot.util.Fmt;
import com.izifeng.www.istorepilot.util.Ui;
import com.izifeng.www.istorepilot.widget.Glyph;
import com.izifeng.www.istorepilot.widget.Hero;
import com.izifeng.www.istorepilot.widget.Radio;
import com.izifeng.www.istorepilot.widget.Sheet;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.HashMap;
import java.util.Locale;
import java.util.Map;

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
    /** 启停请求在途。这期间不跑后台轮询，也别把行上的「启动中」冲掉 */
    private boolean switching;
    /** 正在启停的后端 id，用来在行上标「启动中 / 停止中」 */
    private String startingBackend = "";
    private String pendingText = "启动中";
    /** 最近一次 /proxy 的响应，启停开始时用它原地重绘 */
    private JSONObject lastBackends;
    /** 运行中后端的当前出口节点名（PassWall 用它当主卡片标题） */
    private String activeNode = "";
    /** 装了但没在跑的后端。订阅、配置这类操作认它，不认 running */
    private String installedBackend = "";
    /** 有没有任何一个插件是装着的。安装任务是 Agent 进程内存里的状态，重启就没了 */
    private boolean anyInstalled;
    /** 已安装的后端：id → 显示名。「安装包」弹窗靠它决定要不要给卸载入口 */
    private final java.util.Map<String, String> installedMap = new java.util.LinkedHashMap<>();
    /** 已经提示过的那次安装失败（按 finished 时间戳去重） */
    private double pkgFailShown = 0;
    /** 这次安装任务里「改 hosts」确认框是否已经弹过（waiting 状态去重） */
    private boolean pkgConfirmShown = false;
    private String backendLabel = "";
    private String signature = "";
    private android.app.Dialog nodeSheet;
    /** 弹窗里正在展示的分组：测速完成后要就地刷新延迟，这些是重建素材 */
    private String sheetGroup = "";
    private JSONArray sheetMembers;
    private String sheetNow = "";
    /** 弹窗里的节点表容器 + 测速按钮（测速期间要改文案） */
    private LinearLayout sheetList;
    private TextView sheetTestBtn;
    /** 弹窗副标题。测速失败时得写在这里 —— 页面顶部那条 banner 被弹窗盖住，用户看不到 */
    private TextView sheetSubTitle;
    private String modeValue = "";
    /** GLOBAL 组当前指向谁，切全局模式前用来判断会不会一把拒掉所有流量 */
    private String globalNow = "";
    /** 分组默认只展开一次，之后完全听用户的 */
    private JSONObject lastGroups;
    /** 刚测出来的延迟，优先级高于接口里带的历史值 */
    private final Map<String, Integer> tested = new HashMap<>();
    private String testingGroup = "";
    /** 「隐藏超时节点」：值来自服务端（存路由器），切换后整页节点要重拉 */
    private Ui.Toggle hideToggle;
    private TextView tvHideNote;
    private boolean hideTimeout;

    // ---- 安装包：本地传包 / 从仓库下
    /** 「安装包」那行的状态文字，安装中要实时改 */
    /** 「卸载插件」那行右侧：装了几个 */
    private TextView tvPkgCount;
    /** 安装进度轮询。任务在 Agent 侧跑，页面销毁不会影响安装本身 */
    private final android.os.Handler pkgHandler =
            new android.os.Handler(android.os.Looper.getMainLooper());
    private Runnable pkgPoll;
    /** 等二次确认时暂存的来源与文件名（本地包必须带名字，后端才知道装哪个） */
    private String pkgSource = "github";
    private String pkgName = "";

    // ---- 一个插件都没装时的引导卡
    // 这时运行模式 / 配置 / 节点全是空转控件，整页换成一张卡：选插件 → 安装。
    // 装了任意一个就整页恢复原样（那张卡隐藏，其余照旧），装完的界面不做任何改动。
    private Ui.Card emptyCard;
    private View modeCard;
    private View comboCard;
    private View pkgCard;
    /** 引导卡里选中的插件，默认 OpenClash */
    private String pickTarget = "openclash";
    private final java.util.Map<String, LinearLayout> pickRows = new java.util.HashMap<>();
    private final java.util.Map<String, Radio> pickRadios = new java.util.HashMap<>();
    /** 「全部安装」的排队：Agent 同时只跑一个安装任务，得一个装完再起下一个 */
    private final java.util.ArrayDeque<String> installQueue = new java.util.ArrayDeque<>();
    /** 仓库清单里的包名，只用来写确认框那句话；取不到就留空，后端自己会查 */
    private final java.util.Map<String, String> catalogFiles = new java.util.HashMap<>();
    /** 清单只拉一次，失败也不重试 —— 它只影响确认框里那半句文案 */
    private boolean catalogTried;
    /** 页面打开时是否已经问过「有没有在跑的任务」 */
    private boolean pkgResumeTried;

    /** 「当前配置」整行 + 它下面那条分隔线。PassWall 用不到，要一起藏 */
    private View cfgRow;
    private View cfgHair;
    private TextView comboSub;

    /** 右上角「安装状态」胶囊：安装中才出现，装完或失败就消失。
     *  进度原来只写在「插件安装」那一行小字里，滑走就看不见了。 */
    private TextView pkgChip;
    private Dialog pkgDialog;
    private TextView pkgDlgStep;
    private TextView pkgDlgPct;
    private TextView pkgDlgSize;
    private android.widget.ProgressBar pkgDlgBar;
    /** 上传进度弹窗，和安装那条是两段，分开显示 */
    private Dialog upDialog;
    private TextView upPct;
    private TextView upStep;
    private android.widget.ProgressBar upBar;

    /**
     * 选安装包。必须在字段初始化时注册 —— 放进 build() 会抛
     * "attempting to register while current state is RESUMED"。
     */
    private final androidx.activity.result.ActivityResultLauncher<String[]> pkgPicker =
            registerForActivityResult(
                    new androidx.activity.result.contract.ActivityResultContracts.OpenDocument(),
                    uri -> {
                        if (uri != null) {
                            uploadPkgFile(uri);
                        }
                    });

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
        modeCard = mode;

        // ---------------------------------------------------------- 配置与节点
        Ui.Card combo = Ui.card(c);
        Ui.cardPadding(combo, 3);  // 最后一行是分组标题，底部留 3
        comboSub = Ui.cardTitleLive(c, combo, Glyph.LIST, "配置与节点",
                "换配置会重启内核，断网十几秒").sub;

        // 当前配置：整行可点，右侧「切换」胶囊给出明确的可操作性。
        // 这一行只对 OpenClash 有意义 —— PassWall 没有「配置文件」，
        // 它的节点直接来自订阅，所以下面会按后端把这一行藏掉
        LinearLayout cfgSlot = Ui.infoRow(c, combo, Glyph.BOX, "当前配置", true);
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
        cfgRow = (View) cfgSlot.getParent();

        // 订阅：增删改在独立页面，这里只给入口和条数
        LinearLayout subSlot = Ui.infoRow(c, combo, Glyph.LINK, "订阅管理", false);
        tvSubCount = Ui.num(c, "", 13.5f, R.color.text_secondary);
        subSlot.addView(tvSubCount);
        subSlot.addView(Ui.chevron(c));
        tapRow(subSlot, this::openSubscriptions);

        // infoRow(first=false) 会在行前插一条分隔线，藏「当前配置」时得连它一起藏，
        // 否则标题下面会留一条悬空的横线
        int cfgIdx = combo.indexOfChild(cfgRow);
        if (cfgIdx >= 0 && cfgIdx + 1 < combo.getChildCount()) {
            cfgHair = combo.getChildAt(cfgIdx + 1);
        }

        // 隐藏超时节点：显示偏好存在路由器上（不是这台手机的设置），
        // 几台设备看到的是同一份列表；Web 端读的也是这个值
        combo.addView(Ui.hairline(c, 16));
        LinearLayout hideRow = Ui.row(c);
        hideRow.setGravity(Gravity.CENTER_VERTICAL);
        hideRow.setPadding(Ui.dp(c, 16), Ui.dp(c, 10), Ui.dp(c, 16), Ui.dp(c, 10));

        LinearLayout hideCol = Ui.column(c);
        TextView hideTitle = Ui.text(c, "隐藏超时节点", 14.5f, R.color.text_primary);
        hideCol.addView(hideTitle);
        tvHideNote = Ui.text(c, "只列测速通过的节点", 11.5f, R.color.text_secondary);
        tvHideNote.setPadding(0, Ui.dp(c, 2), 0, 0);
        hideCol.addView(tvHideNote);
        hideRow.addView(hideCol, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        hideToggle = new Ui.Toggle(c, false);
        hideToggle.setOnToggle(this::setHideTimeout);
        hideRow.addView(hideToggle);
        combo.addView(hideRow);

        combo.addView(Ui.hairline(c, 16));
        Ui.cardSubTitle(c, combo, "节点");
        nodesBox = Ui.column(c);
        combo.addView(nodesBox);

        root.addView(combo);
        comboCard = combo;

        // ---------------------------------------------------------- 插件管理
        // 原来叫「安装包」，只有一行「插件安装」通向一个弹窗。现在拆成两件正事：
        // 传包装、卸插件。仓库下载那条路放到 hero 里未安装的行上（点一下就装），
        // 这里就不再重复列一遍清单了。
        Ui.Card pkg = Ui.card(c);
        Ui.cardTitle(c, pkg, Glyph.UPLOAD, "插件管理", "上传安装包 / 卸载插件");

        LinearLayout upSlot = Ui.infoRow(c, pkg, Glyph.UPLOAD, "上传安装包", true);
        TextView upNote = Ui.num(c, "选 .run / .ipk", 12f, R.color.text_secondary);
        upSlot.addView(upNote);
        upSlot.addView(Ui.chevron(c));
        tapRow(upSlot, this::pickPkgFile);

        LinearLayout unSlot = Ui.infoRow(c, pkg, Glyph.LIST, "卸载插件", false);
        tvPkgCount = Ui.num(c, "", 13f, R.color.text_secondary);
        unSlot.addView(tvPkgCount);
        unSlot.addView(Ui.chevron(c));
        tapRow(unSlot, () -> askUninstall(installedAsItems()));

        root.addView(pkg);
        pkgCard = pkg;

        buildEmptyCard(c, root);
        buildPkgChip(c);
        resumePkgIfRunning();
    }

    /**
     * 页面刚打开时接上还在跑的任务。
     *
     * 安装任务跑在路由器上，App 重启不会中断 —— 但进度也不会自己回来，
     * 不接的话用户会以为装丢了。
     */
    private void resumePkgIfRunning() {
        if (pkgResumeTried) {
            return;
        }
        pkgResumeTried = true;
        Api.get(ctx(), "/api/v1/proxy/install", new Cb() {
            @Override
            public void onData(JSONObject data, boolean fromCache) {
                if (!isAdded() || fromCache) {
                    return;
                }
                JSONObject p = data.optJSONObject("pkg");
                if (p != null && p.optBoolean("running", false)) {
                    applyPkgState(p);
                    startPkgPoll();
                }
            }

            @Override
            public void onError(String message) {
                // 接不上就算了，下次刷新再说
            }
        });
    }

    /** 右上角那颗「安装状态」胶囊，安装中才出现 */
    private void buildPkgChip(Context c) {
        pkgChip = Ui.text(c, "", 12f, R.color.on_primary);
        pkgChip.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        pkgChip.setPadding(Ui.dp(c, 12), Ui.dp(c, 7), Ui.dp(c, 12), Ui.dp(c, 7));
        GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(Ui.dp(c, 100));
        bg.setColor(Ui.color(c, R.color.primary));
        pkgChip.setBackground(bg);
        pkgChip.setVisibility(View.GONE);
        pkgChip.setOnClickListener(v -> showPkgDialog());

        FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.gravity = Gravity.TOP | Gravity.END;
        lp.topMargin = Ui.dp(c, 14);
        lp.rightMargin = Ui.dp(c, 18);
        if (overlay != null) {
            overlay.addView(pkgChip, lp);
        }
    }

    /** 打开（或重新打开）安装进度弹窗。弹窗只是「看」，关掉不影响后台任务 */
    private void showPkgDialog() {
        if (pkgDialog != null && pkgDialog.isShowing()) {
            return;
        }
        Context c = ctx();
        LinearLayout box = Ui.column(c);
        box.setPadding(Ui.dp(c, 2), Ui.dp(c, 2), Ui.dp(c, 2), Ui.dp(c, 2));

        pkgDlgPct = Ui.num(c, "0%", 28f, R.color.primary);
        box.addView(pkgDlgPct);

        pkgDlgStep = Ui.text(c, "准备中", 13.5f, R.color.text_primary);
        pkgDlgStep.setPadding(0, Ui.dp(c, 2), 0, Ui.dp(c, 12));
        box.addView(pkgDlgStep);

        pkgDlgBar = new android.widget.ProgressBar(c, null,
                android.R.attr.progressBarStyleHorizontal);
        pkgDlgBar.setMax(100);
        pkgDlgBar.setProgress(0);
        if (pkgDlgBar.getProgressDrawable() != null) {
            pkgDlgBar.getProgressDrawable().setColorFilter(
                    Ui.color(c, R.color.primary), android.graphics.PorterDuff.Mode.SRC_IN);
        }
        box.addView(pkgDlgBar, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, Ui.dp(c, 6)));

        pkgDlgSize = Ui.text(c, "", 11.5f, R.color.text_secondary);
        pkgDlgSize.setPadding(0, Ui.dp(c, 8), 0, 0);
        box.addView(pkgDlgSize);

        pkgDialog = Sheet.custom(c, "安装状态").content(box).cancel("关闭").show();
        pkgDialog.setOnDismissListener(d -> pkgDialog = null);
    }

    /** 关掉安装进度弹窗，但不动后台任务 —— 任务在路由器上跑，关窗只是不看 */
    private void closePkgDialog() {
        if (pkgDialog != null && pkgDialog.isShowing()) {
            pkgDialog.dismiss();
        }
        pkgDialog = null;
        pkgDlgStep = null;
        pkgDlgPct = null;
        pkgDlgSize = null;
        pkgDlgBar = null;
    }

    /**
     * 一个插件都没装时唯一的界面：一张卡选插件、装插件。
     *
     * 为什么要单做一屏：这时候「运行模式 / 配置与节点 / 节点」全是空转控件，
     * 点下去不是报错就是空白，摆在那儿只会让人以为坏了。
     */
    private void buildEmptyCard(Context c, LinearLayout root) {
        emptyCard = Ui.card(c);
        Ui.cardPadding(emptyCard, 0);
        Ui.cardTitle(c, emptyCard, Glyph.UPLOAD,
                "还没安装代理插件", "装一个才能管节点和订阅");

        TextView tip = Ui.text(c,
                "两个后端可以同时装，但同一时间只能跑一个。"
                        + "不确定就先装 OpenClash，规则分流用得最多。",
                11.5f, R.color.text_secondary);
        tip.setLineSpacing(Ui.dp(c, 2), 1f);
        tip.setPadding(Ui.dp(c, 16), 0, Ui.dp(c, 16), Ui.dp(c, 6));
        emptyCard.addView(tip);

        emptyCard.addView(pickRow(c, "openclash", "OpenClash",
                "规则分流，支持订阅与测速"));
        emptyCard.addView(pickRow(c, "passwall", "PassWall",
                "轻量，协议支持面广"));

        TextView go = Ui.filled(c, "安装所选", R.color.primary, R.color.on_primary);
        LinearLayout.LayoutParams glp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        glp.leftMargin = Ui.dp(c, 16);
        glp.rightMargin = Ui.dp(c, 16);
        glp.topMargin = Ui.dp(c, 14);
        go.setOnClickListener(v -> installSelected());
        emptyCard.addView(go, glp);

        // 次按钮用描边：实底浅绿太淡，看着像禁用
        TextView all = Ui.text(c, "全部安装", 15f, R.color.primary);
        all.setTypeface(android.graphics.Typeface.create(
                "sans-serif-medium", android.graphics.Typeface.NORMAL));
        all.setGravity(Gravity.CENTER);
        all.setPadding(Ui.dp(c, 16), Ui.dp(c, 11), Ui.dp(c, 16), Ui.dp(c, 11));
        GradientDrawable allBg = new GradientDrawable();
        allBg.setCornerRadius(Ui.dp(c, 100));
        allBg.setColor(0x00000000);
        allBg.setStroke(Ui.dp(c, 1.5f), Ui.color(c, R.color.primary));
        all.setBackground(allBg);
        LinearLayout.LayoutParams alp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        alp.leftMargin = Ui.dp(c, 16);
        alp.rightMargin = Ui.dp(c, 16);
        alp.topMargin = Ui.dp(c, 8);
        all.setOnClickListener(v -> installAll());
        emptyCard.addView(all, alp);

        TextView allNote = Ui.text(c, "OpenClash + PassWall 依次装，约 5–10 分钟",
                11f, R.color.text_secondary);
        allNote.setGravity(Gravity.CENTER);
        allNote.setPadding(0, Ui.dp(c, 6), 0, Ui.dp(c, 14));
        emptyCard.addView(allNote);

        // 仓库下载经常只有几 KB/s，本地传包是不依赖外网的那条路
        emptyCard.addView(Ui.hairline(c, 16));
        LinearLayout local = Ui.row(c);
        local.setGravity(Gravity.CENTER_VERTICAL);
        local.setPadding(Ui.dp(c, 16), Ui.dp(c, 12), Ui.dp(c, 16), Ui.dp(c, 12));
        LinearLayout localCol = Ui.column(c);
        localCol.addView(Ui.text(c, "从手机里选安装包", 14f, R.color.primary));
        TextView localSub = Ui.text(c, "自己下载好的 .run / .ipk，不用路由器联网",
                11f, R.color.text_secondary);
        localSub.setPadding(0, Ui.dp(c, 2), 0, 0);
        localCol.addView(localSub);
        local.addView(localCol, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        local.addView(Ui.chevron(c));
        local.setClickable(true);
        local.setOnClickListener(v -> pickPkgFile());
        emptyCard.addView(local);

        root.addView(emptyCard);
        emptyCard.setVisibility(View.GONE);
        paintPick();
    }

    /** 引导卡里的一行：名称 + 一句说明 + 右侧单选点 */
    private LinearLayout pickRow(Context c, String id, String label, String desc) {
        LinearLayout row = Ui.row(c);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(Ui.dp(c, 14), Ui.dp(c, 11), Ui.dp(c, 14), Ui.dp(c, 11));

        LinearLayout col = Ui.column(c);
        TextView name = Ui.text(c, label, 14.5f, R.color.text_primary);
        col.addView(name);
        TextView sub = Ui.text(c, desc, 11.5f, R.color.text_secondary);
        sub.setPadding(0, Ui.dp(c, 3), 0, 0);
        col.addView(sub);
        row.addView(col, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        // 单选点用现成的 Radio：外环 + 内点都是自绘的，不随字号抖
        Radio radio = new Radio(c, R.color.primary);
        radio.setOn(id.equals(pickTarget));
        pickRadios.put(id, radio);
        row.addView(radio);

        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.leftMargin = Ui.dp(c, 16);
        lp.rightMargin = Ui.dp(c, 16);
        lp.topMargin = Ui.dp(c, 8);
        row.setLayoutParams(lp);

        row.setClickable(true);
        row.setFocusable(true);
        row.setOnClickListener(v -> {
            pickTarget = id;
            paintPick();
        });
        pickRows.put(id, row);
        return row;
    }

    /** 选中态：选中的那行加绿色描边和淡绿底，其余是浅灰描边 */
    private void paintPick() {
        Context c = ctx();
        for (java.util.Map.Entry<String, LinearLayout> e : pickRows.entrySet()) {
            boolean on = e.getKey().equals(pickTarget);
            GradientDrawable bg = new GradientDrawable();
            bg.setCornerRadius(Ui.dp(c, 12));
            if (on) {
                bg.setColor(Ui.alpha(Ui.color(c, R.color.primary), 0.07f));
                bg.setStroke(Ui.dp(c, 1.5f), Ui.color(c, R.color.primary));
            } else {
                bg.setColor(Ui.color(c, R.color.app_bg));
                bg.setStroke(Ui.dp(c, 1), Ui.alpha(Ui.color(c, R.color.text_secondary), 0.22f));
            }
            e.getValue().setBackground(bg);
            Radio radio = pickRadios.get(e.getKey());
            if (radio != null) {
                radio.setOn(on);
            }
        }
    }

    private static String pluginLabel(String id) {
        return "passwall".equals(id) ? "PassWall" : "OpenClash";
    }

    private void installSelected() {
        String file = catalogFiles.getOrDefault(pickTarget, "");
        askPkg(pickTarget, "github", file);
    }

    /** 队列里的下一个：已经确认过一次了，不再弹确认框 */
    private void startQueued(String target) {
        pkgSource = "github";
        pkgName = catalogFiles.getOrDefault(target, "");
        doPkgInstall(target);
    }

    /**
     * 全部安装 = OpenClash + PassWall。
     *
     * PassWall2 不在 Agent 的白名单里（它和 PassWall 装的时候就冲突），
     * 所以「全部」只能是这两个，别在这里凑三个。
     */
    private void installAll() {
        Sheet.confirm(ctx(), "全部安装",
                "会依次装 OpenClash 和 PassWall，两个都装完后自己挑一个启动。"
                        + "PassWall2 与 PassWall 冲突，不会装。"
                        + "单个包 20–85 MB，网络不好时可能中途失败。",
                "开始", false, () -> {
                    installQueue.clear();
                    installQueue.add("passwall");
                    askPkg("openclash", "github", catalogFiles.getOrDefault("openclash", ""));
                });
    }

    // ------------------------------------------------------------ 安装包
    //
    // Agent 侧有两条安装线：
    //   /api/v1/proxy/install   —— 走软件源 / GitHub release 的单个 ipk（旧的）
    //   /api/v1/proxy/pkg/install —— 走一个完整 .run（带内核），本地传或仓库下
    // 这里用的是后者，因为前者在「源里没有 + GitHub 打不开」时就彻底没辙了。

    /** 把「已安装」的后端拼成 catalog item 的形状，卸载流程两边共用 */
    private JSONArray installedAsItems() {
        JSONArray arr = new JSONArray();
        for (java.util.Map.Entry<String, String> e : installedMap.entrySet()) {
            JSONObject o = new JSONObject();
            try {
                o.put("backend", e.getKey());
                o.put("label", e.getValue());
                o.put("local", "-");
            } catch (Exception ignored) {
                continue;
            }
            arr.put(o);
        }
        return arr;
    }

    /** 列出已装的插件让用户选一个卸。卸载是不可逆的（配置会留着），所以走红色确认 */
    private void askUninstall(JSONArray items) {
        java.util.List<String> ids = new java.util.ArrayList<>();
        java.util.List<String> names = new java.util.ArrayList<>();
        for (int i = 0; i < items.length(); i++) {
            JSONObject it = items.optJSONObject(i);
            if (it == null || it.optString("local", "").isEmpty()) {
                continue;
            }
            ids.add(it.optString("backend", ""));
            names.add(it.optString("label", it.optString("backend", "")));
        }
        if (ids.isEmpty()) {
            notice("没有已安装的插件");
            return;
        }
        Sheet.choose(ctx(), "卸载哪个插件？", names.toArray(new String[0]), -1, idx -> {
            String id = ids.get(idx);
            String label = names.get(idx);
            Sheet.confirm(ctx(), "卸载 " + label + "？",
                    "会删掉插件本体。实测 OpenClash 的包会连配置和订阅一起清掉，"
                            + "重装后要重新粘一次订阅地址。",
                    "卸载", true, () -> doUninstall(id, label));
        });
    }

    private void doUninstall(String id, String label) {
        notice("正在卸载 " + label + "…");
        JSONObject body = new JSONObject();
        try {
            body.put("target", id);
            body.put("confirm", "remove");
        } catch (Exception ignored) {
            return;
        }
        Api.postSlow(ctx(), "/api/v1/proxy/uninstall", body, new Cb() {
            @Override
            public void onData(JSONObject data, boolean fromCache) {
                if (!isAdded()) {
                    return;
                }
                boolean ok = data.optBoolean("ok", false);
                notice(ok ? label + " 已卸载" : "卸载失败：" + data.optString("error", "看日志"),
                        ok);
                load(true);
            }

            @Override
            public void onError(String message) {
                if (isAdded()) {
                    fail("卸载失败：" + message);
                }
            }
        });
    }


    private void pickPkgFile() {
        try {
            // */* 而不是限 MIME：.run / .ipk 没有标准 MIME，限死会让文件管理器把目标灰掉
            pkgPicker.launch(new String[]{"*/*"});
        } catch (Exception e) {
            Toast.makeText(ctx(), "打不开文件选择器：" + e.getMessage(),
                    Toast.LENGTH_LONG).show();
        }
    }

    /** 文件名推后端：AUK9527 的包名里一定带 OpenClash / PassWall */
    private static String targetOfName(String name) {
        String low = name == null ? "" : name.toLowerCase();
        if (low.contains("openclash")) {
            return "openclash";
        }
        if (low.contains("passwall")) {
            return "passwall";
        }
        return "";
    }

    private void uploadPkgFile(android.net.Uri uri) {
        showUploadDialog();
        Api.upload(ctx(), uri, new Cb() {
            @Override
            public void onData(JSONObject data, boolean fromCache) {
                dismissUploadDialog();
                if (!isAdded()) {
                    return;
                }
                String saved = data.optString("name", "");
                if (!data.optBoolean("ok", false) || saved.isEmpty()) {
                    fail(data.optString("error", "上传失败"));
                    return;
                }
                String target = targetOfName(saved);
                if (target.isEmpty()) {
                    fail("文件名里要带 OpenClash 或 PassWall，否则分不清装哪个");
                    return;
                }
                // 已经装过就明说会覆盖，别让用户以为是在装第二个
                String have = installedMap.get(target);
                if (have != null) {
                    Sheet.confirm(ctx(), "覆盖安装 " + have + "？",
                            "本机已经装着 " + have + "，这次会用刚上传的 " + saved
                                    + " 覆盖它（先卸旧版本再装新的），配置和订阅会被清掉。",
                            "覆盖安装", true,
                            () -> askPkg(target, "local", saved));
                } else {
                    askPkg(target, "local", saved);
                }
            }

            @Override
            public void onError(String message) {
                dismissUploadDialog();
                if (isAdded()) {
                    notice("");
                    fail("上传失败：" + message);
                }
            }
        }, (sent, total) -> {
            int pct = (int) (sent * 100 / Math.max(1L, total));
            if (upPct != null) {
                upPct.setText(pct + "%");
            }
            if (upBar != null) {
                upBar.setProgress(pct);
            }
            if (upStep != null) {
                upStep.setText("正在上传 " + Fmt.bytes(sent) + " / " + Fmt.bytes(total));
            }
        });
    }

    /** 上传进度弹窗。跟安装那条分开：传完才轮到装 */
    private void showUploadDialog() {
        if (upDialog != null && upDialog.isShowing()) {
            return;
        }
        Context c = ctx();
        LinearLayout box = Ui.column(c);
        box.setPadding(Ui.dp(c, 2), Ui.dp(c, 2), Ui.dp(c, 2), Ui.dp(c, 2));

        upPct = Ui.num(c, "0%", 28f, R.color.primary);
        box.addView(upPct);
        upStep = Ui.text(c, "正在上传…", 12.5f, R.color.text_secondary);
        upStep.setPadding(0, Ui.dp(c, 2), 0, Ui.dp(c, 12));
        box.addView(upStep);

        upBar = new android.widget.ProgressBar(c, null,
                android.R.attr.progressBarStyleHorizontal);
        upBar.setMax(100);
        if (upBar.getProgressDrawable() != null) {
            upBar.getProgressDrawable().setColorFilter(
                    Ui.color(c, R.color.primary), android.graphics.PorterDuff.Mode.SRC_IN);
        }
        box.addView(upBar, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, Ui.dp(c, 6)));

        upDialog = Sheet.custom(c, "上传安装包").content(box).cancel("后台进行").show();
        upDialog.setOnDismissListener(d -> upDialog = null);
    }

    private void dismissUploadDialog() {
        if (upDialog != null && upDialog.isShowing()) {
            upDialog.dismiss();
        }
        upDialog = null;
        upPct = null;
        upStep = null;
        upBar = null;
    }

    /** 装包 = 用 root 执行对方的脚本，先问一句再动手 */
    private void askPkg(String target, String source, String name) {
        pkgSource = source;
        pkgName = name;
        String label = "openclash".equals(target) ? "OpenClash" : "PassWall";
        String size = "openclash".equals(target) ? "约 20 MB" : "约 80 MB";
        String body;
        if ("local".equals(source)) {
            body = "会把刚上传的 " + name + " 装到路由器上，"
                    + "过程中会以管理员权限执行包里的安装脚本。";
        } else if (name.isEmpty()) {
            // 引导卡里还没拿到清单时点安装，服务端会自己查包名，这里就不报文件名
            body = "会从仓库下载对应的安装包再安装（" + size + "），"
                    + "可能要几分钟到十几分钟，中途别退出。";
        } else {
            body = "会从仓库下载 " + name + " 再安装（" + size + "），"
                    + "可能要几分钟到十几分钟，中途别退出。";
        }
        Sheet.confirm(ctx(), "安装 " + label, body, "开始安装", false,
                () -> doPkgInstall(target));
    }

    private void doPkgInstall(String target) {
        JSONObject body = new JSONObject();
        try {
            body.put("target", target);
            body.put("source", pkgSource);
            body.put("name", pkgName);
            body.put("confirm", "install");
        } catch (Exception ignored) {
            return;
        }
        notice("正在启动安装…");
        Api.post(ctx(), "/api/v1/proxy/pkg/install", body, new Cb() {
            @Override
            public void onData(JSONObject data, boolean fromCache) {
                if (!isAdded()) {
                    return;
                }
                notice("");
                if (!data.optBoolean("ok", false)) {
                    fail(data.optString("error", "启动安装失败"));
                    return;
                }
                pkgConfirmShown = false;
                startPkgPoll();
                // 确认完立刻把进度弹出来；关掉也不影响任务，右上角胶囊还在
                showPkgDialog();
            }

            @Override
            public void onError(String message) {
                if (isAdded()) {
                    notice("");
                    fail("连不上路由器：" + message);
                }
            }
        });
    }

    private void stopPkgPoll() {
        if (pkgPoll != null) {
            pkgHandler.removeCallbacks(pkgPoll);
            pkgPoll = null;
        }
    }

    private void startPkgPoll() {
        stopPkgPoll();
        pkgPoll = new Runnable() {
            @Override
            public void run() {
                Api.get(ctx(), "/api/v1/proxy/install", new Cb() {
                    @Override
                    public void onData(JSONObject data, boolean fromCache) {
                        if (!isAdded()) {
                            return;
                        }
                        // 缓存里存的可能是上一次安装的结果。拿它判断「这一次」结束，
                        // 会在点下开始的瞬间弹「安装失败」，而服务端其实还在下载。
                        // 轮询只认实时结果，缓存直接跳过、下一轮再来。
                        if (fromCache) {
                            pkgHandler.postDelayed(pkgPoll, 1000);
                            return;
                        }
                        JSONObject p = data.optJSONObject("pkg");
                        if (p == null) {
                            return;
                        }
                        applyPkgState(p);
                        maybeAskHostsConfirm(p.optString("waiting", ""));
                        if (p.optBoolean("running", false)) {
                            pkgHandler.postDelayed(pkgPoll, 1000);
                            return;
                        }
                        stopPkgPoll();
                        load(true);
                        if (p.optBoolean("ok", false)) {
                            closePkgDialog();
                            // 「全部安装」是排队跑的：前一个装完再起下一个，
                            // 因为 Agent 同时只能跑一个安装任务
                            if (!installQueue.isEmpty()) {
                                String next = installQueue.poll();
                                Toast.makeText(ctx(), "继续安装 " + pluginLabel(next) + "…",
                                        Toast.LENGTH_SHORT).show();
                                startQueued(next);
                                return;
                            }
                            Toast.makeText(ctx(), "装好了 · 导入订阅后再启动",
                                    Toast.LENGTH_LONG).show();
                            return;
                        }
                        closePkgDialog();
                        if (!installQueue.isEmpty()) {
                            installQueue.clear();
                            Toast.makeText(ctx(), "全部安装已中断",
                                    Toast.LENGTH_LONG).show();
                        }
                        // 同一个失败只提示一次。轮询可能被重复挂上（连点、切页签回来），
                        // 每次都弹的话，用户关掉一个又冒一个
                        double finished = p.optDouble("finished", 0);
                        if (finished > 0 && Math.abs(finished - pkgFailShown) < 0.5) {
                            return;
                        }
                        pkgFailShown = finished;
                        JSONObject e = p.optJSONObject("error");
                        String detail = e == null ? "" : e.optString("detail", "");
                        String code = e == null ? "" : e.optString("error_code", "");
                        if ("cancelled".equals(code)) {
                            // 用户主动取消，别用红色「安装失败」吓人
                            Toast.makeText(ctx(), "已取消安装", Toast.LENGTH_SHORT).show();
                            return;
                        }
                        Sheet.message(ctx(), "安装失败", detail);
                    }

                    @Override
                    public void onError(String message) {
                        // 轮询失败不打断安装，两秒后再试
                        if (isAdded()) {
                            pkgHandler.postDelayed(pkgPoll, 2000);
                        }
                    }
                });
            }
        };
        pkgHandler.post(pkgPoll);
    }

    private void applyPkgState(JSONObject p) {
        boolean running = p.optBoolean("running", false);
        int pct = p.optInt("pct", 0);
        String step = p.optString("step", "");
        long total = p.optLong("total", 0);
        long got = p.optLong("got", 0);

        // 悬浮胶囊只在「正在装」时出现；装完或失败就收起来
        if (pkgChip != null) {
            if (running) {
                pkgChip.setText("安装 " + pct + "%");
                pkgChip.setVisibility(View.VISIBLE);
            } else {
                pkgChip.setVisibility(View.GONE);
            }
        }
        // 弹窗可能被用户关掉了，关掉就只更新胶囊
        if (pkgDlgPct != null) {
            pkgDlgPct.setText(pct + "%");
        }
        if (pkgDlgStep != null && !step.isEmpty()) {
            pkgDlgStep.setText(step);
        }
        if (pkgDlgBar != null) {
            pkgDlgBar.setProgress(pct);
        }
        if (pkgDlgSize != null) {
            pkgDlgSize.setText(total > 0
                    ? Fmt.bytes(got) + " / " + Fmt.bytes(total)
                    : "");
        }
    }

    /** 安装线程停下来等「改 hosts」确认时，弹一次确认框（waiting 状态去重） */
    private void maybeAskHostsConfirm(String waiting) {
        if (!"hosts_fix".equals(waiting) || pkgConfirmShown) {
            return;
        }
        pkgConfirmShown = true;
        Sheet.confirm(ctx(), "GitHub 下载失败",
                "所有加速通道都连不上。是否修改 hosts 后重试？",
                "修改并重试", false,
                () -> postPkgConfirm("yes"),
                () -> postPkgConfirm("no"));
    }

    /** 回应当前安装任务的「改 hosts」确认：yes 继续、no 中止 */
    private void postPkgConfirm(String choice) {
        JSONObject body = new JSONObject();
        try {
            body.put("choice", choice);
        } catch (Exception ignored) {
            return;
        }
        Api.post(ctx(), "/api/v1/proxy/pkg/confirm", body, new Cb() {
            @Override
            public void onData(JSONObject data, boolean fromCache) {
                if (!isAdded()) {
                    return;
                }
                if (!data.optBoolean("ok", false)) {
                    fail(data.optString("error", "回应失败"));
                }
            }

            @Override
            public void onError(String message) {
                if (isAdded()) {
                    fail("连不上路由器：" + message);
                }
            }
        });
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
        // 启停还没回来就跳过这一轮：3 秒一次的轮询会在内核还没起来的空窗里
        // 把「未运行」画上去，用户看到的就是状态来回跳。请求回来后会主动刷一次
        if (switching) {
            return;
        }
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
        // 安装任务在 Agent 侧跑：切页签回来要能接上进度，而不是看着像没装
        Api.get(ctx(), "/api/v1/proxy/install", new Cb() {
            @Override
            public void onData(JSONObject data, boolean fromCache) {
                if (!isAdded()) {
                    return;
                }
                JSONObject p = data.optJSONObject("pkg");
                if (p == null) {
                    return;
                }
                applyPkgState(p);
                if (p.optBoolean("running", false)) {
                    startPkgPoll();
                }
            }

            @Override
            public void onError(String message) {
                // 拿不到就当没有任务，不打扰用户
            }
        });
    }

    @Override
    public void onDestroyView() {
        stopPkgPoll();
        super.onDestroyView();
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
        if (body == null) {
            return;
        }
        lastBackends = body;
        Context c = backendBox.getContext();
        backendBox.removeAllViews();
        backendLabel = "";
        installedBackend = "";
        anyInstalled = false;
        activeNode = "";
        installedMap.clear();

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
                if (installed && installedBackend.isEmpty()) {
                    installedBackend = id;
                }
                if (installed) {
                    anyInstalled = true;
                    installedMap.put(id, label);
                }

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
                    boolean pendingNow = switching && id.equals(startingBackend);
                    line.addView(heroPill(c, pendingNow ? pendingText : "运行中", true));
                    backendLabel = label;
                    activeCount = count;
                    activeEngine = engine;
                    activeNode = b.optString("node", "");
                    if (pendingNow) {
                        // 停止在途，别再让用户重复点
                        line.setClickable(false);
                    } else {
                        // 运行中的行也得能点 —— 否则这个 App 只能启动、不能停止，
                        // 想关掉得回 LuCI，「点一行切换」这句话就只对了一半
                        final String fid = id;
                        final String flabel = label;
                        line.setClickable(true);
                        line.setFocusable(true);
                        GradientDrawable mask = new GradientDrawable();
                        mask.setColor(0xFFFFFFFF);
                        line.setBackground(new android.graphics.drawable.RippleDrawable(
                                android.content.res.ColorStateList.valueOf(
                                        Ui.color(c, R.color.ripple)), null, mask));
                        line.setOnClickListener(v -> askStopBackend(fid, flabel));
                    }
                } else {
                    // 启停在途：行上直接写「启动中」，别再显示「未运行」——
                    // 那两个状态来回闪就是用户看到的「跳动」
                    boolean pending = switching && id.equals(startingBackend);
                    line.addView(heroPill(c, pending ? pendingText
                                    : (installed ? "未运行" : "未安装"),
                            pending));
                    // 装好了但没跑，点一下就能切过去 —— 比让用户去后台点强
                    if (installed && !pending) {
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
                    } else {
                        // 没装就点了直接装：确认框 → 进度弹窗。
                        // 让用户跑去下面的「插件管理」再传包，等于把最简单的路藏起来
                        final String fid = id;
                        line.setClickable(true);
                        line.setFocusable(true);
                        GradientDrawable mask = new GradientDrawable();
                        mask.setColor(0xFFFFFFFF);
                        line.setBackground(new android.graphics.drawable.RippleDrawable(
                                android.content.res.ColorStateList.valueOf(
                                        Ui.color(c, R.color.ripple)), null, mask));
                        line.setOnClickListener(v -> askPkg(fid, "github",
                                catalogFiles.getOrDefault(fid, "")));
                    }
                }

                backendBox.addView(line);
            }
        }

        boolean none = "none".equals(active);
        if (hero != null) {
            hero.dot(R.color.hero_fg, none);
            hero.state.setText(none ? "都没在运行" : "运行中");
            // 没运行时不能写「直连」：「直连」是「后端在跑、模式选了直连」的状态，
            // 和「装了但没启用」是两回事。写成直连会让人以为自己在用直连模式，
            // 实际是没启用任何代理
            hero.badge.setText(none
                    ? (installedMap.isEmpty() ? "未安装" : installedMap.size() + " 个已安装")
                    : backendLabel);
            hero.title.setText(none ? "未启用"
                    : (activeNode.isEmpty() ? "—" : pretty(activeNode)));
            hero.note.setText(none
                    ? "点上面任意一行启用；启用后这里显示当前出口"
                    : join(activeEngine, activeCount + " 个节点可用", modeLabel(modeValue)));
        }

        // 安装任务状态可能比后端列表先到，也可能后到
        if (tvPkgCount != null) {
            tvPkgCount.setText(installedMap.isEmpty()
                    ? "未安装"
                    : installedMap.size() + " 个");
        }

        // PassWall 没有「配置文件」这个概念：它的节点直接来自订阅。
        // 所以「当前配置 + 切换」这一行对它没意义（点了也没反应），整行藏掉，
        // 节点列表照常显示 —— 这就是两个后端在界面上的差异
        boolean pw = "passwall".equals(uiBackend());
        if (cfgRow != null) {
            cfgRow.setVisibility(pw ? View.GONE : View.VISIBLE);
        }
        if (cfgHair != null) {
            cfgHair.setVisibility(pw ? View.GONE : View.VISIBLE);
        }
        if (comboSub != null) {
            comboSub.setText(pw
                    ? "PassWall 的节点来自订阅，没有配置文件"
                    : "换配置会重启内核，断网十几秒");
        }

        // 一个插件都没装时，整页只剩那张引导卡：运行模式、配置与节点、节点、安装包
        // 这时候全是空转控件（点下去不是空白就是报错），摆着只会让人以为坏了。
        // 装了任意一个就原样恢复 —— 装完之后的界面不做任何改动。
        boolean blank = !anyInstalled;
        // 装了但都没运行：模式切的是「正在跑的那个后端」的流量走向，没跑就没得切。
        // 这时把它藏掉，否则用户会以为自己在挑模式，其实全是空转。
        boolean idle = blank || none;
        if (emptyCard != null) {
            emptyCard.setVisibility(blank ? View.VISIBLE : View.GONE);
        }
        if (hero != null) {
            hero.setVisibility(blank ? View.GONE : View.VISIBLE);
        }
        if (modeCard != null) {
            modeCard.setVisibility(idle ? View.GONE : View.VISIBLE);
        }
        // 「配置与节点」保留：订阅管理还得用（先导订阅、再启用是正常顺序），
        // 节点列表也可以先看看有哪些出口
        if (comboCard != null) {
            comboCard.setVisibility(blank ? View.GONE : View.VISIBLE);
        }
        if (pkgCard != null) {
            pkgCard.setVisibility(blank ? View.GONE : View.VISIBLE);
        }
        // 清单里只有包名，但确认框会用到 —— 点未安装的行也要能说出装的是哪个包
        loadCatalogFiles();

        renderMode();
        if (!pw) {
            loadConfigs();
        }
        loadSubCount();
    }

    /** 这一页现在在管哪个后端：正在跑的那个，没跑就是装着的那个 */
    /**
     * 界面当前该以哪个后端为主。
     *
     * 正在跑的那个优先。都停着时不能随手拿「先装的那个」—— OpenClash 的节点
     * 要靠内核 API 才拿得到，停着就只剩一句连接失败；PassWall 的节点存在 uci
     * 里，停着也能看、也能先把节点选好再启动。所以都停着时优先 PassWall。
     */
    private String uiBackend() {
        if (!backendId.isEmpty()) {
            return backendId;
        }
        if (installedMap.containsKey("passwall")) {
            return "passwall";
        }
        return installedBackend;
    }

    /**
     * 取一份仓库清单，只为把包名写进安装确认框。
     *
     * 拿不到不影响安装 —— Agent 收到 source=github 会自己查清单取包，
     * 这里传空名字就行，确认框里换成一句不带文件名的话。
     */
    private void loadCatalogFiles() {
        if (catalogTried) {
            return;
        }
        catalogTried = true;
        Api.get(ctx(), "/api/v1/proxy/pkg/catalog", new Cb() {
            @Override
            public void onData(JSONObject data, boolean fromCache) {
                if (!isAdded() || data == null) {
                    return;
                }
                org.json.JSONArray items = data.optJSONArray("items");
                if (items == null) {
                    return;
                }
                for (int i = 0; i < items.length(); i++) {
                    JSONObject it = items.optJSONObject(i);
                    if (it == null) {
                        continue;
                    }
                    String backend = it.optString("backend", "");
                    String file = it.optString("file", "");
                    if (!backend.isEmpty() && !file.isEmpty()) {
                        catalogFiles.put(backend, file);
                    }
                }
            }

            @Override
            public void onError(String message) {
                // 清单只是用来写文案的，拿不到就算了
            }
        });
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
                    // 启动通常 5～10 秒。这期间不做后台轮询、行上直接标「启动中」，
                    // 否则 3 秒一次的那次刷新会在内核还没起来时把「未运行」画上去，
                    // 看起来就像状态在「未运行 / 运行中」之间来回跳
                    switching = true;
                    startingBackend = id;
                    pendingText = "启动中";
                    renderBackends(lastBackends);
                    Toast.makeText(ctx(), "正在启动 " + label + "…", Toast.LENGTH_SHORT).show();
                    JSONObject body = new JSONObject();
                    try {
                        body.put("action", "start");
                        body.put("backend", id);
                    } catch (Exception ignored) {
                        switching = false;
                        return;
                    }
                    Api.postSlow(ctx(), "/api/v1/proxy/service", body, new Cb() {
                        @Override
                        public void onData(JSONObject data, boolean fromCache) {
                            if (!isAdded()) {
                                return;
                            }
                            finishSwitch();
                            boolean ok = data.optBoolean("ok", false);
                            // 提示只走 Toast：顶部那条 banner 会一直挂着，
                            // 「已启动」这种一次性消息没必要占着版面
                            Toast.makeText(ctx(), ok
                                            ? label + " 已启动"
                                            : data.optString("reason", "启动失败，看日志确认"),
                                    ok ? Toast.LENGTH_SHORT : Toast.LENGTH_LONG).show();
                            load(true);
                        }

                        @Override
                        public void onError(String message) {
                            finishSwitch();
                            if (isAdded()) {
                                fail("启动失败：" + message);
                                load(true);
                            }
                        }
                    });
                });
    }

    /** 停掉正在跑的后端。停止比启动更容易出事（当前连接全断），所以走红色确认。 */
    private void askStopBackend(String id, String label) {
        Sheet.confirm(ctx(), "停止 " + label + "？",
                "停掉后所有流量走直连，已建立的连接会断一下。配置和订阅都留着，随时能再启动。",
                "停止", true, () -> {
                    switching = true;
                    startingBackend = id;
                    pendingText = "停止中";
                    renderBackends(lastBackends);
                    Toast.makeText(ctx(), "正在停止 " + label + "…", Toast.LENGTH_SHORT).show();
                    JSONObject body = new JSONObject();
                    try {
                        body.put("action", "stop");
                        body.put("backend", id);
                    } catch (Exception ignored) {
                        switching = false;
                        return;
                    }
                    Api.postSlow(ctx(), "/api/v1/proxy/service", body, new Cb() {
                        @Override
                        public void onData(JSONObject data, boolean fromCache) {
                            if (!isAdded()) {
                                return;
                            }
                            finishSwitch();
                            boolean ok = data.optBoolean("ok", false);
                            Toast.makeText(ctx(), ok ? label + " 已停止" : "停止失败，看日志确认",
                                    ok ? Toast.LENGTH_SHORT : Toast.LENGTH_LONG).show();
                            load(true);
                        }

                        @Override
                        public void onError(String message) {
                            finishSwitch();
                            if (isAdded()) {
                                fail("停止失败：" + message);
                                load(true);
                            }
                        }
                    });
                });
    }

    private void finishSwitch() {
        switching = false;
        startingBackend = "";
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
                // 只有 OpenClash 的标题是「配置文件名」；PassWall 用节点名，别覆盖
                if (hero != null && "openclash".equals(uiBackend())) {
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
        // 订阅存在 uci 里，跟内核跑不跑没关系 —— 「先配好订阅、再启动」是正常顺序。
        // 原来只有 running 才放行，直连状态下点这一行毫无反应，只在顶部闪一句
        // 「订阅不可用」，看着像坏了
        String be = subsBackend();
        if (be.isEmpty()) {
            notice("两个代理后端都没装，先装一个");
            return;
        }
        Intent it = new Intent(ctx(), SubscriptionActivity.class);
        it.putExtra("backend", be);
        startActivity(it);
    }

    /** 订阅、配置这类操作面向「当前这个后端」，与内核在不在跑无关 */
    private String subsBackend() {
        return uiBackend();
    }

    /** 订阅本身在独立页面维护，这张卡只要一个条数 */
    private void loadSubCount() {
        if (tvSubCount == null) {
            return;
        }
        String be = subsBackend();
        if (be.isEmpty()) {
            tvSubCount.setText("");
            return;
        }
        Api.get(ctx(), "/api/v1/proxy/subscriptions?backend=" + be, new Cb() {
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

    /**
     * 切换「隐藏超时节点」。
     *
     * 写的是路由器上的偏好（/api/v1/proxy/prefs），不是本机设置 ——
     * 所以同一张网里的每台手机、以及 Web 端读到的是同一个值。
     * 写完把缓存签名清掉再拉一次：服务端会按新偏好重新裁节点。
     */
    private void setHideTimeout(boolean on) {
        JSONObject body = new JSONObject();
        try {
            body.put("hide_timeout", on);
        } catch (org.json.JSONException ignored) {
            // 只放了一个 boolean，不会抛
        }
        Api.post(ctx(), "/api/v1/proxy/prefs", body, new Cb() {
            @Override
            public void onData(JSONObject data, boolean fromCache) {
                if (!isAdded()) {
                    return;
                }
                hideTimeout = data.optBoolean("hide_timeout", on);
                signature = "";
                loadGroups();
            }

            @Override
            public void onError(String message) {
                if (!isAdded()) {
                    return;
                }
                // 写失败就把开关拨回去，别让界面显示一个没生效的状态
                if (hideToggle != null) {
                    hideToggle.setOn(hideTimeout, true);
                }
                if (tvHideNote != null) {
                    tvHideNote.setText("设置没保存：" + message);
                }
            }
        });
    }

    /**
     * 节点相关接口都带上 backend。
     *
     * 服务端不传 backend 时按「正在跑的那个」猜；两个后端都停着时就是 none，
     * 整块节点区只会显示「没有正在运行的代理后端」—— 可 Passwall 装了就能看
     * 节点、也能先把节点选好再启动。所以这里优先正在跑的，其次已装的。
     */
    private String nodeBackend() {
        return uiBackend();
    }

    private String nodeBackendQuery() {
        String id = nodeBackend();
        return id.isEmpty() ? "" : "?backend=" + id;
    }

    private void loadGroups() {
        Api.get(ctx(), "/api/v1/proxy/groups" + nodeBackendQuery(), new Cb() {
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
        // 用 uiBackend 而不是 backendId：都停着时 backendId 是空的，但界面
        // 已经按 PassWall 展示了（见 uiBackend 的注释），两档标签得跟着走
        boolean oc = "openclash".equals(uiBackend());
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
    private String modeHint(String backend, String mode) {
        if (backend == null || backend.isEmpty()) {
            // 两个后端都停着时，上面那两档其实是「要不要启动代理」，
            // 没有模式可读 —— 别把兜底文案「还没读到当前模式」甩给用户。
            // 说哪个后端要跟界面走（uiBackend 在都停着时优先 PassWall）
            String bid = uiBackend();
            if (bid.isEmpty()) {
                return "还没装代理插件。装好之后这里才会出现模式选择。";
            }
            return "点「代理」会启动 "
                    + ("openclash".equals(bid) ? "OpenClash" : "Passwall")
                    + "，沿用上次的配置和节点。";
        }
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

        // 开关状态跟服务端对齐：可能在另一台手机上改过，也可能是 Web 端改的
        hideTimeout = body.optBoolean("hide_timeout", hideTimeout);
        int hidden = body.optInt("hidden", 0);
        if (hideToggle != null) {
            hideToggle.setOn(hideTimeout, false);
        }
        if (tvHideNote != null) {
            tvHideNote.setText(!hideTimeout
                    ? "只列测速通过的节点"
                    : (hidden > 0 ? "已隐藏 " + hidden + " 个超时节点" : "当前没有测速超时的节点"));
        }

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
            boolean testing = gname.equals(testingGroup);

            groupRow(c, g, gname, now, members, testing, i == 0);
        }

        setRefreshing(false);
    }

    /**
     * 分组入口：一行列表（类型图标 + 组名 + 当前节点 + 节点数 + 箭头）。
     *
     * 原来是一张「凹槽大卡」（类型胶囊 + 组名 + 当前节点 + 节点数四层），
     * 四组叠在「配置与节点」白卡里又厚又碎。改回和设置页同一条 settingRow：
     * 信息一条不少，但一眼扫完、点开才看节点。
     */
    private void groupRow(Context c, JSONObject g, String gname, String now,
                          JSONArray members, boolean testing, boolean first) {
        String cur = pretty(now);
        int total = members == null ? 0 : members.length();
        Ui.settingRow(c, nodesBox, groupGlyph(g.optString("type", "")),
                pretty(gname),
                cur.isEmpty() ? "未选择" : cur,
                total + " 个",
                first, false,
                () -> openGroupSheet(c, g, gname, now, members, testing));
    }

    /** 分组类型 → 图标 */
    private int groupGlyph(String raw) {
        switch (raw == null ? "" : raw.toLowerCase(Locale.ROOT)) {
            case "urltest": return com.izifeng.www.istorepilot.widget.Glyph.BOLT;
            case "fallback": return com.izifeng.www.istorepilot.widget.Glyph.SHIELD;
            case "relay": return com.izifeng.www.istorepilot.widget.Glyph.LINK;
            default: return com.izifeng.www.istorepilot.widget.Glyph.LIST;
        }
    }

    /** 关闭图标按钮：30dp 圆角方块里的 ×，和测速胶囊并排放在弹窗右上角 */
    private View closeIconBtn(Context c) {
        LinearLayout box = Ui.row(c);
        box.setGravity(Gravity.CENTER);
        GradientDrawable bg = new GradientDrawable();
        bg.setCornerRadius(Ui.dp(c, 9));
        bg.setColor(Ui.color(c, R.color.surface_hi));
        box.setBackground(bg);
        com.izifeng.www.istorepilot.widget.Glyph g = new com.izifeng.www.istorepilot.widget.Glyph(c);
        g.setKind(com.izifeng.www.istorepilot.widget.Glyph.CLOSE);
        g.setColor(Ui.color(c, R.color.text_secondary));
        int s = Ui.dp(c, 16);
        box.addView(g, new LinearLayout.LayoutParams(s, s));
        return box;
    }

    /** 分组类型 → 中文（和 iOS / 鸿蒙同一套映射） */
    private String groupType(String raw) {
        switch (raw == null ? "" : raw.toLowerCase(Locale.ROOT)) {
            case "selector": return "手动";
            case "urltest": return "自动测速";
            case "fallback": return "故障转移";
            case "loadbalance": return "负载均衡";
            case "relay": return "链式";
            // Passwall 没有 selector 概念，服务端按订阅分组返回 type=group
            case "group": return "分组";
            default: return (raw == null || raw.isEmpty()) ? "分组" : raw;
        }
    }

    /**
     * 分组弹窗：固定头（组名 + 副标题在左，测速胶囊 + 关闭在右）+ 一组圆角节点表。
     * 测速不再是占一整条的实心主按钮 —— 它是次要操作，收成胶囊和「关闭」并排。
     */
    private void openGroupSheet(Context c, JSONObject g, String gname, String now,
                                JSONArray members, boolean testing) {
        if (members == null || members.length() == 0) {
            Toast.makeText(c, "这一组没有可选节点", Toast.LENGTH_SHORT).show();
            return;
        }
        sheetGroup = gname;
        sheetMembers = members;
        sheetNow = now;

        LinearLayout head = Ui.row(c);
        head.setGravity(Gravity.CENTER_VERTICAL);
        // 左右 16：Sheet 外框只有 4dp，这里补到 20dp，才和下面列表行的左边距对齐。
        // 之前是 0，标题直接贴屏幕边，看着像没做完
        head.setPadding(Ui.dp(c, 16), Ui.dp(c, 8), Ui.dp(c, 16), Ui.dp(c, 12));

        // 左上：组名 + 副标题
        LinearLayout titleCol = Ui.column(c);
        TextView title = Ui.text(c, pretty(gname), 18f, R.color.text_primary);
        title.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        title.setSingleLine(true);
        title.setEllipsize(android.text.TextUtils.TruncateAt.END);
        titleCol.addView(title);
        TextView sub = Ui.text(c, groupType(g.optString("type", ""))
                + " · " + members.length() + " 个节点", 11.5f, R.color.text_secondary);
        sub.setPadding(0, Ui.dp(c, 4), 0, 0);
        titleCol.addView(sub);
        sheetSubTitle = sub;
        head.addView(titleCol, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        // 右上：测速胶囊 + 关闭图标按钮 —— 一个是「操作」、一个是「退出」，
        // 用不同形式区分开，不再两坨文字并排挤在一起
        sheetTestBtn = testPill(c, testing);
        sheetTestBtn.setOnClickListener(v -> testGroup(gname));
        head.addView(sheetTestBtn);

        View closeBtn = closeIconBtn(c);
        LinearLayout.LayoutParams cbLp = new LinearLayout.LayoutParams(
                Ui.dp(c, 30), Ui.dp(c, 30));
        cbLp.leftMargin = Ui.dp(c, 8);
        closeBtn.setClickable(true);
        closeBtn.setFocusable(true);
        closeBtn.setOnClickListener(v -> {
            if (nodeSheet != null) {
                nodeSheet.dismiss();
            }
        });
        head.addView(closeBtn, cbLp);

        // 节点表：整组共用一个圆角容器，行间细线，跟设备列表同一套骨架
        sheetList = Ui.group(c);
        fillSheetList(c);

        nodeSheet = Sheet.custom(c, "")
                .header(head)
                .content(sheetList)
                .show();
    }

    /** 往弹窗节点容器里填行（打开时 + 测速完成后各填一次，延迟原地刷新） */
    private void fillSheetList(Context c) {
        if (sheetList == null) {
            return;
        }
        sheetList.removeAllViews();
        if (sheetMembers == null) {
            return;
        }
        int added = 0;
        for (int k = 0; k < sheetMembers.length(); k++) {
            JSONObject m = sheetMembers.optJSONObject(k);
            if (m == null || isInfoNode(m.optString("name", ""))) {
                continue;
            }
            if (added > 0) {
                // 46 = 行边距 16 + 单选点 18 + 间距 12，正好对齐名字的起笔
                sheetList.addView(Ui.hairline(c, 46));
            }
            if (addNodeRow(c, sheetList, m, sheetGroup, sheetNow)) {
                added++;
            }
        }
    }

    /** 测速胶囊：主色淡底 + 主色字 */
    private TextView testPill(Context c, boolean testing) {
        TextView v = Ui.text(c, testing ? "测速中…" : "测速", 12.5f, R.color.primary);
        v.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        v.setGravity(Gravity.CENTER);
        v.setPadding(Ui.dp(c, 14), 0, Ui.dp(c, 14), 0);
        GradientDrawable bg = new GradientDrawable();
        // 和右上角「关闭」同一套规格：30dp 高、9dp 圆角。
        // 之前测速是全圆胶囊、关闭是方角方块，并排像两个人画的
        bg.setCornerRadius(Ui.dp(c, 9));
        bg.setColor(Ui.color(c, R.color.accent_soft));
        v.setBackground(bg);
        v.setLayoutParams(new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, Ui.dp(c, 30)));
        return v;
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

    /** 节点行：左侧单选点，中间名字，右侧延迟胶囊。缩进对齐设备列表那套 */
    private boolean addNodeRow(Context c, LinearLayout host, JSONObject m,
                               String group, String current) {
        String name = m.optString("name", "");
        if (isInfoNode(name)) {
            return false;
        }
        boolean isGroup = m.optBoolean("is_group", false);
        boolean selected = name.equals(current);
        // REJECT / DIRECT / PASS 是策略动作，选中它们等于「不代理」或「全拒绝」，
        // 用灰色而不是主题绿，避免看起来像选了个正常节点
        boolean policy = isPolicyName(name);

        int onColor = isRejectPolicy(name) ? R.color.danger
                : (policy ? R.color.text_secondary : R.color.primary);

        LinearLayout line = Ui.row(c);
        line.setGravity(Gravity.CENTER_VERTICAL);
        // 13dp 上下：原先 11 太挤，一列节点看起来像贴在一起
        line.setPadding(Ui.dp(c, 16), Ui.dp(c, 13), Ui.dp(c, 16), Ui.dp(c, 13));
        line.setClickable(true);
        line.setFocusable(true);

        Radio radio = new Radio(c, selected ? onColor : R.color.text_tertiary);
        radio.setOn(selected);
        LinearLayout.LayoutParams rlp = new LinearLayout.LayoutParams(
                Ui.dp(c, 18), Ui.dp(c, 18));
        rlp.rightMargin = Ui.dp(c, 12);
        line.addView(radio, rlp);

        TextView label = Ui.text(c, pretty(name), 15f,
                selected ? onColor : (policy ? R.color.text_secondary : R.color.text_primary));
        label.setMaxLines(1);
        label.setEllipsize(android.text.TextUtils.TruncateAt.END);
        line.addView(label, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        // 延迟有三种态，不能混为一谈：
        //   本次手动测速的结果    → 0 就是真的连不上，显示「超时」
        //   接口带回来的历史值    → 0 只代表「还没测过」，显示「—」
        //   两者都没有（组节点）  → 显示「组」；选中的直接标「使用中」
        Integer fresh = tested.get(name);
        if (fresh != null) {
            line.addView(delayChip(c, fresh, fresh > 0 ? delayColor(fresh) : R.color.danger));
        } else {
            Object delay = m.opt("delay");
            int ms = delay instanceof Number ? ((Number) delay).intValue() : -1;
            if (ms > 0) {
                line.addView(delayChip(c, ms, delayColor(ms)));
            } else if (isGroup) {
                line.addView(Ui.text(c, "组", 11f, R.color.text_secondary));
            } else if (selected) {
                TextView use = Ui.text(c, "使用中", 11f, R.color.primary);
                use.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
                line.addView(use);
            } else {
                line.addView(Ui.text(c, "—", 11f, R.color.text_tertiary));
            }
        }

        // 选中行铺一层极淡的同色底 + 圆角：一列扫下来先认出「当前用的是哪个」，
        // 而不是只能靠左边那个小圆点
        GradientDrawable rowBg = new GradientDrawable();
        rowBg.setCornerRadius(Ui.dp(c, 12));
        rowBg.setColor(selected
                ? Ui.alpha(Ui.color(c, onColor), 0.07f)
                : android.graphics.Color.TRANSPARENT);
        GradientDrawable mask = new GradientDrawable();
        mask.setCornerRadius(Ui.dp(c, 12));
        mask.setColor(0xFFFFFFFF);
        line.setBackground(new android.graphics.drawable.RippleDrawable(
                android.content.res.ColorStateList.valueOf(Ui.color(c, R.color.ripple)),
                rowBg, mask));
        line.setOnClickListener(v -> selectNode(group, name, true));
        host.addView(line);
        return true;
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
        if (sheetTestBtn != null) {
            sheetTestBtn.setText("测速中…");
            // 保持主色：之前测速中把字变灰、底还是绿淡底，绿底灰字看着像按钮失效了
            sheetTestBtn.setTextColor(Ui.color(sheetTestBtn.getContext(), R.color.primary));
        }
        if (lastGroups != null) {
            renderNodes(lastGroups);
        }
        notice("正在测速「" + pretty(group) + "」…");

        JSONObject body = new JSONObject();
        try {
            body.put("group", group);
            body.put("timeout", 3000);
            if (!nodeBackend().isEmpty()) {
                body.put("backend", nodeBackend());
            }
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
                    setSheetSub("测速完成 · " + ok + " 个可达", R.color.text_secondary);
                } else if (data.optBoolean("ok", false)) {
                    // 全组一个都没通：Mihomo 要么回 504，要么把所有成员都标 0。
                    // 列表会整排变红「超时」，副标题再点明一句，省得用户以为没测
                    int n = delays == null ? 0 : delays.length();
                    notice("测速完成：全部 " + n + " 个节点超时", true);
                    setSheetSub("全部 " + n + " 个节点超时", R.color.warn);
                } else {
                    String why = data.optString("error", "无结果");
                    notice("测速失败：" + why);
                    setSheetSub("测速失败：" + why, R.color.warn);
                }
                resetTestBtn();
                if (lastGroups != null) {
                    renderNodes(lastGroups);
                }
                refreshSheet();
            }

            @Override
            public void onError(String message) {
                testingGroup = "";
                if (isAdded()) {
                    fail(message);
                    setSheetSub("测速失败：" + message, R.color.warn);
                    resetTestBtn();
                    if (lastGroups != null) {
                        renderNodes(lastGroups);
                    }
                    refreshSheet();
                }
            }
        });
    }

    /** 测速按钮复位成「测速」 */
    private void resetTestBtn() {
        if (sheetTestBtn != null) {
            sheetTestBtn.setText("测速");
            sheetTestBtn.setTextColor(Ui.color(sheetTestBtn.getContext(), R.color.primary));
        }
    }

    /** 弹窗还开着时，测速完成后把延迟原地刷进节点表 */
    private void refreshSheet() {
        if (sheetList != null && nodeSheet != null && nodeSheet.isShowing()) {
            fillSheetList(sheetList.getContext());
        }
    }

    /** 改弹窗副标题。测速的结果得写在这儿，页面顶部那条 banner 被弹窗挡着 */
    private void setSheetSub(String text, int colorRes) {
        if (sheetSubTitle == null) {
            return;
        }
        sheetSubTitle.setText(text);
        sheetSubTitle.setTextColor(Ui.color(sheetSubTitle.getContext(), colorRes));
    }

    private void selectNode(String group, String name, boolean topLevel) {
        JSONObject body = new JSONObject();
        try {
            body.put("name", name);
            body.put("group", group);
            if (!nodeBackend().isEmpty()) {
                body.put("backend", nodeBackend());
            }
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
                    if (nodeSheet != null) {
                        nodeSheet.dismiss();
                        nodeSheet = null;
                    }
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
        boolean oc = "openclash".equals(uiBackend());
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
        String be = uiBackend();
        // 后端没在跑时，这两三档其实是「把代理开起来」。
        // 只写 tcp_proxy_mode / clash mode 不会拉起内核，界面还会报「切换失败」
        if (backendId.isEmpty()) {
            askSwitchBackend(be, pluginLabel(be));
            return;
        }
        JSONObject body = new JSONObject();
        try {
            body.put("mode", mode);
            if (!be.isEmpty()) {
                body.put("backend", be);
            }
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
