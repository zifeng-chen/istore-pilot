package com.chaof.istoreos.ui;

import android.app.Dialog;
import android.content.Context;
import android.content.Intent;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.InputType;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import com.chaof.istoreos.R;
import com.chaof.istoreos.api.Api;
import com.chaof.istoreos.api.Cb;
import com.chaof.istoreos.core.Session;
import com.chaof.istoreos.core.Snap;
import com.chaof.istoreos.util.Fmt;
import com.chaof.istoreos.util.Hz;
import com.chaof.istoreos.util.Theme;
import com.chaof.istoreos.util.Ui;
import com.chaof.istoreos.widget.Sheet;

import org.json.JSONObject;

/** 设置：连接信息、网络地址、改密码、清缓存、关于。 */
public class SettingsFragment extends BaseFragment {

    private TextView tvBase;
    /** hero 卡：连接状态 / Agent 版本 / 延迟 */
    private TextView tvHeroState;
    private TextView tvHeroBadge;
    /** hero 那行读数用的缓存：地址走后，响应和凭证跟着变 */
    private String heroLatency = "—";
    private String heroToken = "—";
    /** hero 大标题：在线时是主机名，拿不到才退回服务器地址 */
    private TextView tvHeroHost;

    private TextView tvWanState;
    private TextView tvWanV4;
    private TextView tvWanV6;
    private TextView tvWanUp;
    private TextView tvLanV4;

    // 设备信息（原概览页的「机器信息」）
    private TextView tvDevModel;
    private TextView tvDevCpu;
    private TextView tvDevMem;
    private TextView tvDevDisk;
    private TextView tvDevSys;
    private TextView tvTheme;
    /** hero 右上角的主题按钮：点开和「外观」卡里的选择器是同一个 */
    private TextView tvHeroTheme;

    /**
     * 选安装包。必须用字段初始化注册 —— 放到 build() 里会抛
     * "attempting to register while current state is RESUMED"。
     */
    private final androidx.activity.result.ActivityResultLauncher<String[]> filePicker =
            registerForActivityResult(
                    new androidx.activity.result.contract.ActivityResultContracts.OpenDocument(),
                    uri -> {
                        if (uri != null) {
                            uploadInstaller(uri);
                        }
                    });

    @Override
    protected String title() {
        return "设置";
    }

    @Override
    protected void build(LinearLayout root) {
        Context c = ctx();
        int wrap = ViewGroup.LayoutParams.WRAP_CONTENT;

        // ---------------------------------------------------------------- hero
        // 这一版把「响应 / 凭证 / Agent」三件事直接画进 hero，
        // 原来它们是三行 kv，既占了半张卡的篇幅，又把「连的是哪台」这件事压住了。
        Ui.Card hero = Ui.gradient(c, R.color.hero_from, R.color.hero_to);
        hero.setPadding(Ui.dp(c, 20), Ui.dp(c, 18), Ui.dp(c, 20), Ui.dp(c, 16));

        // 三行信息 + 一行动作，只有一条阅读顺序：通不通 → 是哪台 → 现在什么状态 → 能做什么。
        // 上一版左右分栏，在平板上两块被顶到两边，中间空出一大片绿，像没排完。
        LinearLayout stateRow = Ui.row(c);
        stateRow.setGravity(Gravity.CENTER_VERTICAL);
        View dot = new View(c);
        GradientDrawable hd = new GradientDrawable();
        hd.setShape(GradientDrawable.OVAL);
        hd.setColor(Ui.alpha(Ui.color(c, R.color.hero_fg), 0.45f));
        dot.setBackground(hd);
        LinearLayout.LayoutParams hdlp = new LinearLayout.LayoutParams(
                Ui.dp(c, 7), Ui.dp(c, 7));
        hdlp.rightMargin = Ui.dp(c, 7);
        stateRow.addView(dot, hdlp);

        tvHeroState = Ui.heroNote(c, "检测中…", 1.0f);
        tvHeroState.setTextSize(12.5f);
        tvHeroState.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        stateRow.addView(tvHeroState);

        // 版本跟着状态走，不再单独做一枚胶囊
        tvHeroBadge = Ui.heroNote(c, "", 0.86f);
        tvHeroBadge.setTextSize(11.5f);
        LinearLayout.LayoutParams bglp = new LinearLayout.LayoutParams(wrap, wrap);
        bglp.leftMargin = Ui.dp(c, 6);
        stateRow.addView(tvHeroBadge, bglp);
        hero.addView(stateRow);

        tvHeroHost = Ui.text(c,
                Session.base(c).replaceFirst("^https?://", ""), 24f, R.color.hero_fg);
        tvHeroHost.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        tvHeroHost.setIncludeFontPadding(false);
        tvHeroHost.setLetterSpacing(-0.02f);
        tvHeroHost.setSingleLine(true);
        tvHeroHost.setEllipsize(android.text.TextUtils.TruncateAt.END);
        LinearLayout.LayoutParams hlp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, wrap);
        hlp.topMargin = Ui.dp(c, 6);
        hero.addView(tvHeroHost, hlp);

        // 地址 + 响应 + 凭证压成一行：竖着排三行会把卡片撑高一倍
        tvBase = Ui.heroNote(c, "", 0.86f);
        tvBase.setTextSize(11.5f);
        tvBase.setSingleLine(true);
        tvBase.setEllipsize(android.text.TextUtils.TruncateAt.END);
        LinearLayout.LayoutParams blp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, wrap);
        blp.topMargin = Ui.dp(c, 4);
        hero.addView(tvBase, blp);
        renderHeroMeta();

        View heroLine = new View(c);
        heroLine.setBackgroundColor(Ui.alpha(Ui.color(c, R.color.hero_fg), 0.18f));
        LinearLayout.LayoutParams hllp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, Math.max(1, Ui.dp(c, 0.7f)));
        hllp.topMargin = Ui.dp(c, 12);
        hllp.bottomMargin = Ui.dp(c, 9);
        hero.addView(heroLine, hllp);

        LinearLayout acts = Ui.row(c);
        acts.setGravity(Gravity.CENTER_VERTICAL);
        acts.addView(heroLink(c, "重新登录", this::relogin));
        LinearLayout.LayoutParams gap1 = new LinearLayout.LayoutParams(wrap, wrap);
        gap1.leftMargin = Ui.dp(c, 16);
        acts.addView(heroLink(c, "清缓存", this::clearCache), gap1);
        acts.addView(new View(c), new LinearLayout.LayoutParams(0, 1, 1f));
        tvHeroTheme = heroLink(c, "主题 · " + Theme.name(c), this::pickTheme);
        acts.addView(tvHeroTheme);
        hero.addView(acts);
        root.addView(hero);

        // 原来「网络」页的内容挪到这里：设备列表占了那个页签，
        // 而 WAN 地址属于偶尔看一眼的信息，放设置里更合适
        Ui.Card net = Ui.card(c);
        Ui.cardPadding(net, 11);
        Ui.cardTitle(c, net, com.chaof.istoreos.widget.Glyph.GLOBE,
                "网络", "外网与内网网关");

        tvWanState = Ui.settingRow(c, net, com.chaof.istoreos.widget.Glyph.LINK,
                "外网状态", "拨号与链路", "—", true, false, null);
        tvWanV4 = Ui.settingRow(c, net, com.chaof.istoreos.widget.Glyph.GLOBE,
                "IPv4", "运营商分配的地址", "—", false, false, null);
        tvWanV6 = Ui.settingRow(c, net, com.chaof.istoreos.widget.Glyph.GLOBE,
                "IPv6", "外网入口", "—", false, false, null);
        // 完整 IPv6 是 39 个字符，13.5sp 刚好一行放下
        tvWanV6.setTextSize(12.5f);
        tvWanUp = Ui.settingRow(c, net, com.chaof.istoreos.widget.Glyph.CLOCK,
                "连接时长", "本次拨号已持续", "—", false, false, null);
        tvLanV4 = Ui.settingRow(c, net, com.chaof.istoreos.widget.Glyph.CHIP,
                "内网网关", "设备默认走这个地址", "—", false, false, null);
        TextView netNote = Ui.text(c,
                "外网访问走 IPv6，DNS 里配好 AAAA 记录就能用域名连回来。",
                11.5f, R.color.text_secondary);
        netNote.setLineSpacing(Ui.dp(c, 2), 1f);
        netNote.setPadding(Ui.dp(c, 16), Ui.dp(c, 10), Ui.dp(c, 16), Ui.dp(c, 10));
        net.addView(netNote);
        root.addView(net);

        // ---------------------------------------------------------------- 设备信息
        // 原来在概览页叫「机器信息」。它是「查资料」型内容：一个月看一次，
        // 放在打开就要看的概览里，每次都占掉一屏的三分之一。
        Ui.Card dev = Ui.card(c);
        Ui.cardPadding(dev, 11);
        Ui.cardTitle(c, dev, com.chaof.istoreos.widget.Glyph.CHIP,
                "设备信息", "这台路由器的硬件与固件");

        // 「主机名」这一行删掉了：它已经是 hero 的大标题，卡片里再说一遍是重复
        tvDevModel = Ui.settingRow(c, dev, com.chaof.istoreos.widget.Glyph.BOX,
                "型号", "主板与平台", "—", false, false, null);
        tvDevCpu = Ui.settingRow(c, dev, com.chaof.istoreos.widget.Glyph.CHIP,
                "处理器", "核心与最高频率", "—", false, false, null);
        tvDevMem = Ui.settingRow(c, dev, com.chaof.istoreos.widget.Glyph.CHIP,
                "内存", "容量与规格", "—", false, false, null);
        tvDevDisk = Ui.settingRow(c, dev, com.chaof.istoreos.widget.Glyph.BOX,
                "系统盘", "容量与总线", "—", false, false, null);
        tvDevSys = Ui.settingRow(c, dev, com.chaof.istoreos.widget.Glyph.INFO,
                "系统版本", "固件与内核", "—", false, false, null);
        Ui.settingRow(c, dev, com.chaof.istoreos.widget.Glyph.LIST,
                "查看全部硬件", "内存条、网卡、温度、PCI 设备", "", false, false,
                () -> startActivity(new Intent(ctx(),
                        com.chaof.istoreos.HardwareActivity.class)));
        root.addView(dev);

        // ---------------------------------------------------------------- 外观
        Ui.Card look = Ui.card(c);
        Ui.cardPadding(look, 11);
        Ui.cardTitle(c, look, com.chaof.istoreos.widget.Glyph.PALETTE,
                "显示", "刷新率与主题");
        // 主题挪到 hero 右上角了，这里只留一句指路，免得用户翻遍整页找
        tvTheme = Ui.text(c, "深浅色主题在上方卡片的右上角切换。",
                11.5f, R.color.text_secondary);
        tvTheme.setPadding(Ui.dp(c, 16), Ui.dp(c, 2), Ui.dp(c, 16), Ui.dp(c, 2));
        look.addView(tvTheme);
        // 高刷是这一版新加的：窗口不主动申请，120Hz 屏也只有 60 帧，
        // 把结果显示出来，用户能自己确认是不是真的跑在高刷上
        Ui.settingRow(c, look, com.chaof.istoreos.widget.Glyph.BOLT,
                "画面刷新率", "已按本机最高刷新率申请", Hz.label(getActivity()),
                false, false, null);
        root.addView(look);

        // ---------------------------------------------------------------- 系统维护
        Ui.Card system = Ui.card(c);
        Ui.cardPadding(system, 11);
        Ui.cardTitle(c, system, com.chaof.istoreos.widget.Glyph.BOX,
                "系统维护", "备份、固件与软件包");
        // 备份排在第一行：它是后面所有危险操作的前提，
        // 放在最下面，用户往往是「改坏了」才想起来找它
        Ui.settingRow(c, system, com.chaof.istoreos.widget.Glyph.BOX,
                "配置备份", "动网络之前先存一份，随时能退回来", "", true, false,
                () -> startActivity(new Intent(ctx(),
                        com.chaof.istoreos.BackupActivity.class)));
        Ui.settingRow(c, system, com.chaof.istoreos.widget.Glyph.UPLOAD,
                "上传安装包", "从手机里选 .ipk / .run", "", false, false, this::pickInstaller);
        Ui.settingRow(c, system, com.chaof.istoreos.widget.Glyph.BOLT,
                "检查系统更新", "查的是 iStoreOS 固件镜像", "", false, false,
                this::checkFirmware);
        Ui.settingRow(c, system, com.chaof.istoreos.widget.Glyph.BOX,
                "检查软件包更新", "查的是 opkg 软件包", "", false, false, this::checkUpdates);
        Ui.settingRow(c, system, com.chaof.istoreos.widget.Glyph.CLOCK,
                "查看升级进度", "升级过程中的实时日志", "", false, false,
                this::showUpgradeProgress);
        TextView sysNote = Ui.text(c,
                "「系统更新」和「软件包更新」是两条互不相干的链路，"
                        + "固件不动软件包，软件包也不动固件。",
                11.5f, R.color.text_secondary);
        sysNote.setLineSpacing(Ui.dp(c, 2), 1f);
        sysNote.setPadding(Ui.dp(c, 16), Ui.dp(c, 10), Ui.dp(c, 16), Ui.dp(c, 10));
        system.addView(sysNote);
        root.addView(system);

        // ---------------------------------------------------------------- 电源
        // 从概览页搬过来，并换成设置页的图标行样式：
        // 重启/关机是低频且不可撤销的动作，混在概览的指标里容易被误触。
        Ui.Card power = Ui.card(c);
        Ui.cardPadding(power, 11);
        Ui.cardTitle(c, power, com.chaof.istoreos.widget.Glyph.POWER,
                "电源控制", "重启与关机都会短暂断网");
        Ui.settingRow(c, power, com.chaof.istoreos.widget.Glyph.REFRESH,
                "重启网络服务", "只重拨 WAN，通常 10 秒内恢复", "", true, false,
                () -> askPower("重启网络服务？",
                        "只会重启 network 服务：WAN 重新拨号，局域网内的设备不会掉线，"
                                + "但所有正在进行的下载和视频会断一下。\n\n"
                                + "如果你只是外网连不上，先试这个；不要直接重启路由器。",
                        "重启网络", "restart_network", false, false));
        Ui.settingRow(c, power, com.chaof.istoreos.widget.Glyph.REFRESH,
                "重启路由器", "所有设备断网约 1 分钟", "", false, false,
                () -> askPower("重启路由器？",
                        "整机重启：所有有线、无线设备都会断开约 1 分钟，"
                                + "代理、拦截、拨号要等开机后重新起来。\n\n"
                                + "重启期间 App 会显示「连不上」，这是正常的。",
                        "确定重启", "reboot", true, false));
        Ui.settingRow(c, power, com.chaof.istoreos.widget.Glyph.POWER,
                "关闭路由器", "关机后只能到设备跟前手动开机", "", false, true,
                () -> askPower("关闭路由器？",
                        "关机后：\n"
                                + "• 全网立即断网\n"
                                + "• 无法远程唤醒（这台机器没有 WoL 支持）\n"
                                + "• 必须到设备跟前按电源键才能恢复\n\n"
                                + "如果只是想省电，建议用「重启」而不是关机。",
                        "确定关机", "poweroff", true, true));
        root.addView(power);

        // ---------------------------------------------------------------- 安全
        Ui.Card security = Ui.card(c);
        Ui.cardPadding(security, 11);
        Ui.cardTitle(c, security, com.chaof.istoreos.widget.Glyph.SHIELD,
                "安全", "两个密码，别记混");
        Ui.settingRow(c, security, com.chaof.istoreos.widget.Glyph.KEY,
                "修改 App 登录密码", "只管这个 App", "", true, false, this::changePassword);
        Ui.settingRow(c, security, com.chaof.istoreos.widget.Glyph.POWER,
                "修改路由器密码", "root 账号，影响后台与 SSH", "", false, true,
                this::changeRootPassword);
        TextView note = Ui.text(c,
                "App 登录密码是给这个客户端用的；路由器密码是 root 账号，"
                        + "同时影响 iStoreOS 后台和 SSH 登录。",
                11.5f, R.color.text_secondary);
        note.setLineSpacing(Ui.dp(c, 2), 1f);
        note.setPadding(Ui.dp(c, 16), Ui.dp(c, 10), Ui.dp(c, 16), Ui.dp(c, 10));
        security.addView(note);
        root.addView(security);

        // ---------------------------------------------------------------- 关于
        // 只放四样：图标、名称、版本、一句话介绍。剩下的（界面实现、数据来源）
        // 属于开发细节，用户不需要在「关于」里读文档
        Ui.Card about = Ui.card(c);
        LinearLayout aboutHead = Ui.row(c);
        aboutHead.setGravity(Gravity.CENTER_VERTICAL);

        android.widget.ImageView icon = new android.widget.ImageView(c);
        icon.setScaleType(android.widget.ImageView.ScaleType.FIT_CENTER);
        icon.setImageResource(R.mipmap.ic_launcher);
        LinearLayout.LayoutParams ilp = new LinearLayout.LayoutParams(
                Ui.dp(c, 56), Ui.dp(c, 56));
        ilp.rightMargin = Ui.dp(c, 14);
        aboutHead.addView(icon, ilp);

        LinearLayout aboutCol = Ui.column(c);
        TextView aboutName = Ui.text(c, "iStore Pilot", 19f, R.color.text_primary);
        aboutName.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        aboutName.setIncludeFontPadding(false);
        aboutCol.addView(aboutName);
        TextView aboutVer = Ui.text(c, "版本 " + appVersion(c), 12.5f, R.color.text_secondary);
        aboutVer.setPadding(0, Ui.dp(c, 4), 0, 0);
        aboutCol.addView(aboutVer);
        aboutHead.addView(aboutCol, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        about.addView(aboutHead);

        TextView tip = Ui.text(c,
                "iStoreOS 路由器的随身管理台：状态、设备、代理、拦截、硬件，"
                        + "一处看完，不用再开浏览器后台。",
                12.5f, R.color.text_secondary);
        tip.setLineSpacing(Ui.dp(c, 3), 1f);
        tip.setPadding(0, Ui.dp(c, 14), 0, 0);
        about.addView(tip);
        root.addView(about);
    }

    /** hero 里的一个小统计块：上面小字，下面数值 */
    /** hero 底部的一行文字动作：不做胶囊，避免一张卡上三四个抢眼的块 */
    private TextView heroLink(Context c, String text, Runnable onClick) {
        TextView t = Ui.heroNote(c, text, 0.86f);
        t.setTextSize(12f);
        t.setPadding(Ui.dp(c, 2), Ui.dp(c, 3), Ui.dp(c, 2), Ui.dp(c, 3));
        t.setOnClickListener(v -> onClick.run());
        return t;
    }

    /** hero 那行读数：地址 · 响应 · 凭证 */
    private void renderHeroMeta() {
        if (tvBase == null) {
            return;
        }
        String base = Session.base(ctx()).replaceFirst("^https?://", "");
        tvBase.setText(base + "　·　响应 " + heroLatency + "　·　凭证 " + heroToken);
    }

    private void pickTheme() {
        Context c = ctx();
        Sheet.choose(c, "外观", Theme.NAMES, Theme.index(Theme.get(c)), which -> {
            int mode = Theme.MODES[which];
            Theme.applyMode(c, mode);
            // 重建是异步的，先把这一行文案改掉，
            // 否则在「系统本来就是这个颜色」的情况下不重建，会一直显示旧值
            if (tvHeroTheme != null) {
                tvHeroTheme.setText(Theme.name(mode));
            }
        });
    }

    private void action(LinearLayout card, String text, int colorRes, Runnable onClick) {
        Context c = card.getContext();
        card.addView(Ui.divider(c));
        TextView t = Ui.text(c, text, 14.5f, colorRes);
        t.setPadding(0, Ui.dp(c, 12), 0, Ui.dp(c, 12));
        t.setGravity(Gravity.CENTER_VERTICAL);
        t.setOnClickListener(v -> onClick.run());
        card.addView(t);
    }

    /** 设置页是本地表单，没有要等的数据，骨架反而像卡住了 */
    @Override
    protected boolean skeletonEnabled() {
        return false;
    }

    @Override
    protected void load(boolean quiet) {
        long exp = Session.expiresAt(ctx());
        long left = exp - System.currentTimeMillis() / 1000L;
        // 整行宽度有限，这里用短写（Fmt.shortDur 会给「6 天 5 小时」）
        heroToken = left > 0 ? Fmt.shortDur(left) : "已过期";
        renderHeroMeta();

        final long started = System.currentTimeMillis();
        Api.ping(Session.base(ctx()), new Cb() {
            @Override
            public void onData(JSONObject body, boolean fromCache) {
                if (!isAdded()) {
                    return;
                }
                setRefreshing(false);
                String ver = "v" + body.optString("version", "?");
                long ms = System.currentTimeMillis() - started;
                heroLatency = ms + " ms";
                if (tvHeroState != null) {
                    tvHeroState.setText("已连接");
                    tvHeroBadge.setText(ver);
                    renderHeroMeta();
                }
            }

            @Override
            public void onError(String message) {
                if (!isAdded()) {
                    return;
                }
                setRefreshing(false);
                heroLatency = "—";
                if (tvHeroState != null) {
                    tvHeroState.setText("连不上");
                    tvHeroBadge.setText("离线");
                    renderHeroMeta();
                }
            }
        });

        Api.get(ctx(), "/api/v1/network", new Cb() {
            @Override
            public void onData(JSONObject body, boolean fromCache) {
                if (!isAdded()) {
                    return;
                }
                JSONObject wan = body.optJSONObject("wan");
                if (wan != null) {
                    boolean up = wan.optBoolean("up", false);
                    tvWanState.setText(up ? "已连接" : "未连接");
                    tvWanState.setTextColor(Ui.color(ctx(), up ? R.color.text_primary : R.color.danger));
                    tvWanV4.setText(firstAddr(wan.optJSONArray("ipv4")));
                    tvWanV6.setText(ipv6Summary(wan.optJSONArray("ipv6")));
                    long upSec = wan.optLong("uptime", 0);
                    tvWanUp.setText(upSec > 0 ? Fmt.dur(upSec) : "—");
                }
                JSONObject lan = body.optJSONObject("lan");
                if (lan != null) {
                    tvLanV4.setText(firstAddr(lan.optJSONArray("ipv4")));
                }
            }

            @Override
            public void onError(String message) {
                // 网络信息拿不到不影响设置页其它功能，保持静默
            }
        });

        // 设备信息：30 秒后端缓存，不用 quiet 区分 —— 这些值本来就几乎不变
        Api.get(ctx(), "/api/v1/system/hardware", new Cb() {
            @Override
            public void onData(JSONObject body, boolean fromCache) {
                if (isAdded()) {
                    renderDeviceInfo(body);
                }
            }

            @Override
            public void onError(String message) {
                // 硬件读不到不影响设置页其它功能
            }
        });
    }

    /** 设备信息卡：每行只放「最能区分这一项」的信息，不堆参数 */
    private void renderDeviceInfo(JSONObject b) {
        JSONObject cpu = b.optJSONObject("cpu");
        JSONObject mem = b.optJSONObject("memory");
        JSONObject sys = b.optJSONObject("system");

        // 主机名已经摆在 hero 大标题上了，「设备信息」卡不再重复这一行
        if (sys != null && tvHeroHost != null) {
            String host = sys.optString("hostname", "");
            if (!host.isEmpty()) {
                tvHeroHost.setText(host);
            }
        }
        if (tvDevModel != null) {
            String model = sys == null ? "" : sys.optString("model", "");
            tvDevModel.setText(model.isEmpty() ? "—" : model);
        }
        if (cpu != null && tvDevCpu != null) {
            StringBuilder sb = new StringBuilder();
            sb.append(cpu.optInt("cores", 0)).append(" 核");
            if (cpu.optInt("threads", 0) > cpu.optInt("cores", 0)) {
                sb.append(" ").append(cpu.optInt("threads", 0)).append(" 线程");
            }
            if (cpu.optInt("max_mhz", 0) > 0) {
                sb.append(" · ").append(cpu.optInt("max_mhz", 0)).append(" MHz");
            }
            String name = cpu.optString("model", "")
                    .replace("(R)", "").replace("(TM)", "");
            tvDevCpu.setText(name.isEmpty() ? sb.toString() : sb.toString());
        }
        if (mem != null && tvDevMem != null) {
            String total = Fmt.bytes(mem.optLong("total", 0));
            org.json.JSONArray mods = mem.optJSONArray("modules");
            if (mods != null && mods.length() > 0) {
                JSONObject m = mods.optJSONObject(0);
                if (m != null) {
                    StringBuilder sb = new StringBuilder(total);
                    if (!m.optString("type", "").isEmpty()) {
                        sb.append(" ").append(m.optString("type"));
                    }
                    if (m.optInt("speed", 0) > 0) {
                        sb.append("-").append(m.optInt("speed"));
                    }
                    tvDevMem.setText(sb.toString());
                }
            } else {
                tvDevMem.setText(total);
            }
        }
        if (tvDevDisk != null) {
            org.json.JSONArray disks = b.optJSONArray("disks");
            JSONObject d = disks == null ? null : disks.optJSONObject(0);
            if (d != null) {
                String transport = d.optString("transport", "");
                tvDevDisk.setText(d.optString("size_text", "—")
                        + (transport.isEmpty() ? "" : " " + transport));
            }
        }
        if (sys != null && tvDevSys != null) {
            String distro = sys.optString("description", "");
            String kernel = sys.optString("kernel", "");
            StringBuilder sb = new StringBuilder(distro);
            if (!kernel.isEmpty()) {
                if (sb.length() > 0) {
                    sb.append(" · ");
                }
                sb.append("内核 ").append(kernel);
            }
            tvDevSys.setText(sb.length() == 0 ? "—" : sb.toString());
        }
    }

    /**
     * 电源动作的两步确认。
     *
     * 第一步说清楚「会发生什么、多久恢复」；关机这种不可远程恢复的，
     * 还要再确认一次 —— 用户在通勤路上误点一下，代价是回家按电源键。
     */
    private void askPower(String title, String body, String okText,
                          String action, boolean danger, boolean twice) {
        Sheet.confirm(ctx(), title, body, twice ? "继续" : okText, danger, () -> {
            if (!twice) {
                runPower(action, okText);
                return;
            }
            Sheet.confirm(ctx(), "最后确认一次", "关机后无法远程开机，确定要继续吗？",
                    okText, true, () -> runPower(action, okText));
        });
    }

    private void runPower(String action, String label) {
        JSONObject body = new JSONObject();
        try {
            body.put("action", action);
            body.put("confirm", action);
        } catch (Exception e) {
            return;
        }
        Api.post(ctx(), "/api/v1/power", body, new Cb() {
            @Override
            public void onData(JSONObject data, boolean fromCache) {
                if (!isAdded()) {
                    return;
                }
                if (data.optBoolean("ok", false)) {
                    Toast.makeText(ctx(), label + "已下发", Toast.LENGTH_SHORT).show();
                } else {
                    Sheet.message(ctx(), "操作被拒绝",
                            data.optString("error", "AGENT_NOT_ALLOWED"));
                }
            }

            @Override
            public void onError(String message) {
                if (isAdded()) {
                    Sheet.message(ctx(), "下发失败", message);
                }
            }
        });
    }

    private static String firstAddr(org.json.JSONArray arr) {
        if (arr == null || arr.length() == 0) {
            return "—";
        }
        JSONObject o = arr.optJSONObject(0);
        if (o == null) {
            return "—";
        }
        String a = o.optString("address", "");
        int prefix = o.optInt("prefixlen", -1);
        if (a.isEmpty()) {
            return "—";
        }
        return prefix >= 0 ? a + "/" + prefix : a;
    }

    /** ubus 返回的第一条常是 fe80 链路本地地址，优先显示能用的全局地址 */
    private static String ipv6Summary(org.json.JSONArray arr) {
        if (arr == null || arr.length() == 0) {
            return "—";
        }
        String global = "";
        String any = "";
        for (int i = 0; i < arr.length(); i++) {
            JSONObject o = arr.optJSONObject(i);
            if (o == null) {
                continue;
            }
            String a = o.optString("address", "");
            if (a.isEmpty()) {
                continue;
            }
            if (any.isEmpty()) {
                any = a;
            }
            if (!a.toLowerCase(java.util.Locale.US).startsWith("fe80")) {
                global = a;
                break;
            }
        }
        String pick = global.isEmpty() ? any : global;
        return pick.isEmpty() ? "—" : pick;
    }

    // ---------------------------------------------------------------- 地址

    private void editBase() {
        Context c = ctx();
        Sheet.input(c, "服务器地址", "内网填路由器 IP，外网填 DDNS 域名。端口默认 8443。",
                new String[]{"地址:192.168.100.1:8443:" + Session.base(c)},
                "保存", values -> {
                    if (values[0].isEmpty()) {
                        return false;
                    }
                    Session.setBase(ctx(), values[0]);
                    renderHeroMeta();
                    Toast.makeText(ctx(), "地址已更新", Toast.LENGTH_SHORT).show();
                    requireActivity().recreate();
                    return true;
                });
    }

    private void relogin() {
        Session.logout(ctx());
        startActivity(new Intent(ctx(), LoginActivity.class));
        requireActivity().finish();
    }

    private void clearCache() {
        Snap.clear(ctx());
        Toast.makeText(ctx(), "本地缓存已清除", Toast.LENGTH_SHORT).show();
    }

    // ---------------------------------------------------------------- 改密码

    private void changePassword() {
        Sheet.input(ctx(), "修改控制密码", "新密码至少 8 位。修改后所有设备都需要重新登录。",
                new String[]{"当前密码:请输入当前密码:", "新密码:至少 8 位:"},
                "确认修改", values -> {
                    if (values[1].length() < 8) {
                        Toast.makeText(ctx(), "新密码至少 8 位", Toast.LENGTH_SHORT).show();
                        return false;
                    }
                    submitPassword(values[0], values[1]);
                    return true;
                });
    }

    private void submitPassword(String current, String next) {
        JSONObject body = new JSONObject();
        try {
            body.put("current", current);
            body.put("new", next);
        } catch (Exception ignored) {
            return;
        }
        Api.post(ctx(), "/api/v1/password", body, new Cb() {
            @Override
            public void onData(JSONObject data, boolean fromCache) {
                if (!isAdded()) {
                    return;
                }
                if (data.optBoolean("ok", false)) {
                    Session.logout(ctx());
                    Toast.makeText(ctx(), "密码已修改，请重新登录", Toast.LENGTH_LONG).show();
                    startActivity(new Intent(ctx(), LoginActivity.class));
                    requireActivity().finish();
                } else {
                    Toast.makeText(ctx(), data.optString("error", "修改失败"),
                            Toast.LENGTH_SHORT).show();
                }
            }

            @Override
            public void onError(String message) {
                if (isAdded()) {
                    Toast.makeText(ctx(), message, Toast.LENGTH_SHORT).show();
                }
            }
        });
    }

    // ---------------------------------------------------------------- 系统维护

    private void pickInstaller() {
        try {
            // 用 */* 而不是限定 MIME：.ipk / .run 没有标准 MIME，
            // 限死会让不少文件管理器把目标文件灰掉，根本选不到
            filePicker.launch(new String[]{"*/*"});
        } catch (Exception e) {
            Toast.makeText(ctx(), "打不开文件选择器：" + e.getMessage(),
                    Toast.LENGTH_LONG).show();
        }
    }

    private void uploadInstaller(android.net.Uri uri) {
        notice("正在上传安装包…");
        Api.upload(ctx(), uri, new Cb() {
            @Override
            public void onData(JSONObject data, boolean fromCache) {
                if (!isAdded()) {
                    return;
                }
                String name = data.optString("name", "");
                if (!data.optBoolean("ok", false) || name.isEmpty()) {
                    fail(data.optString("error", "上传失败"));
                    return;
                }
                notice("");
                askInstall(name);
            }

            @Override
            public void onError(String message) {
                if (isAdded()) {
                    fail("上传失败：" + message);
                }
            }
        });
    }

    /** 装包 = 用 root 安装或执行对方的文件，先问一句再动手 */
    private void askInstall(String name) {
        Sheet.Builder box = Sheet.custom(ctx(), "安装 " + name);
        box.bodyLeft("这个文件会以管理员权限在路由器上安装或执行。"
                + "只装你自己上传的包，来源不明的一律不要装。");
        box.primary("安装", true, (d, w) -> installPackage(name));
        box.cancel("取消");
        box.show();
    }

    /** .run / .ipk / .apk → 后端要求的确认串（后端会按真实类型再核一遍） */
    private static String confirmKind(String name) {
        String low = name == null ? "" : name.toLowerCase();
        if (low.endsWith(".run")) {
            return "run";
        }
        if (low.endsWith(".ipk")) {
            return "ipk";
        }
        if (low.endsWith(".apk")) {
            return "apk";
        }
        return "";
    }

    private void installPackage(String name) {
        JSONObject body = new JSONObject();
        try {
            body.put("name", name);
            body.put("confirm", confirmKind(name));
        } catch (Exception ignored) {
            return;
        }
        Api.postSlow(ctx(), "/api/v1/system/install", body, new Cb() {
            @Override
            public void onData(JSONObject data, boolean fromCache) {
                if (!isAdded()) {
                    return;
                }
                // 后端认为还需要确认（类型没对上）：不装，提示一下就退回
                if (!data.optString("need_confirm", "").isEmpty()) {
                    Toast.makeText(ctx(), data.optString("error", "需要确认后才能安装"),
                            Toast.LENGTH_LONG).show();
                    return;
                }

                String output = data.optString("output", "");
                String note = data.optString("note", "");
                String detail = data.optString("error", "");

                if (data.optBoolean("restarting", false)) {
                    // 装的是 iStore Pilot 自己的包：服务会重启一次，期间接口全断，
                    // 所以这里只说清楚「等一会儿」，不要报成失败
                    notice("服务正在重启，约 10 秒后自动恢复…");
                    Sheet.Builder box = Sheet.custom(ctx(), "已开始安装");
                    box.bodyLeft(note.isEmpty()
                            ? "安装包已交给后台执行，服务会重启一次。"
                            : note);
                    box.primary("知道了", false, null);
                    box.show();
                    setRefreshing(true);
                    new android.os.Handler(android.os.Looper.getMainLooper())
                            .postDelayed(new Runnable() {
                                @Override
                                public void run() {
                                    if (isAdded()) {
                                        // 清掉「正在重启」的提示条；万一还没起来，
                                        // 「Agent 版本」那行会显示「连不上」，下拉可重试
                                        notice("");
                                        load(true);
                                    }
                                }
                            }, 12000);
                    return;
                }

                boolean ok = data.optBoolean("ok", false);

                StringBuilder sb = new StringBuilder();
                if (!note.isEmpty()) {
                    sb.append(note);
                } else if (ok) {
                    sb.append("安装完成。");
                } else {
                    sb.append("安装失败：").append(detail.isEmpty() ? "未知原因" : detail);
                }
                // 成功时不再贴 opkg 的原始输出：版号 / 依赖一大堆，对用户没意义；
                // 失败时才留着，那份输出才是排查依据
                if (!ok && !output.isEmpty()) {
                    sb.append("\n\n").append(output);
                }
                notice(ok ? "安装完成" : "安装失败", ok);
                Sheet.Builder box = Sheet.custom(ctx(), ok ? "安装结果" : "安装失败");
                box.bodyLeft(sb.toString());
                box.primary("知道了", false, null);
                box.show();
            }

            @Override
            public void onError(String message) {
                if (isAdded()) {
                    fail("安装失败：" + message);
                }
            }
        });
    }

    private void changeRootPassword() {
        Sheet.input(ctx(), "修改路由器密码",
                "这是 root 账号的密码，改完 iStoreOS 后台和 SSH 都用新密码登录。",
                new String[]{"当前路由器密码:请输入当前密码:", "新密码:至少 8 位:"},
                "确认修改", values -> {
                    if (values[1].length() < 8) {
                        Toast.makeText(ctx(), "新密码至少 8 位", Toast.LENGTH_SHORT).show();
                        return false;
                    }
                    submitRootPassword(values[0], values[1]);
                    return true;
                });
    }

    private void submitRootPassword(String current, String next) {
        JSONObject body = new JSONObject();
        try {
            body.put("current", current);
            body.put("new", next);
        } catch (Exception ignored) {
            return;
        }
        Api.post(ctx(), "/api/v1/system/root_password", body, new Cb() {
            @Override
            public void onData(JSONObject data, boolean fromCache) {
                if (!isAdded()) {
                    return;
                }
                if (data.optBoolean("ok", false)) {
                    Sheet.message(ctx(), "已修改",
                            data.optString("note", "路由器密码已更新。"));
                } else {
                    Toast.makeText(ctx(), data.optString("error", "修改失败"),
                            Toast.LENGTH_LONG).show();
                }
            }

            @Override
            public void onError(String message) {
                if (isAdded()) {
                    Toast.makeText(ctx(), message, Toast.LENGTH_LONG).show();
                }
            }
        });
    }

    /**
     * 检查固件更新。走 iStoreOS 后台「系统 → OTA」同一条链路（/bin/ota check），
     * 查的是固件镜像，和下面的 opkg 软件包检查完全是两件事。
     */
    private void checkFirmware() {
        Dialog wait = Sheet.custom(ctx(), "正在检查固件")
                .bodyLeft("正在向 iStoreOS 更新服务器查询最新固件…")
                .show();
        wait.setCancelable(false);

        Api.getFresh(ctx(), "/api/v1/system/firmware", new Cb() {
            @Override
            public void onData(JSONObject data, boolean fromCache) {
                wait.dismiss();
                if (!isAdded()) {
                    return;
                }
                if (!data.optBoolean("ok", false)) {
                    Sheet.message(ctx(), "检查失败",
                            data.optString("error", "读取更新服务器失败") + "\n\n"
                                    + "这一步要路由器能访问 fw.koolcenter.com，"
                                    + "和 opkg 软件源无关。");
                    return;
                }
                String state = data.optString("state", "");
                String cur = data.optString("current", "—");
                String latest = data.optString("latest", "—");

                if ("busy".equals(state)) {
                    Sheet.message(ctx(), "有固件任务在跑",
                            "路由器上已经有固件下载任务，等它结束再检查。\n\n当前 " + cur);
                    return;
                }
                if (!data.optBoolean("has_update", false)) {
                    Sheet.message(ctx(), "固件已是最新",
                            "当前版本 " + cur + "\n\n没有可升级的固件。");
                    return;
                }

                StringBuilder sb = new StringBuilder();
                sb.append("当前  ").append(cur).append("\n");
                sb.append("最新  ").append(latest).append("\n");
                String image = data.optString("image", "");
                if (!image.isEmpty()) {
                    sb.append("\n镜像  ").append(image).append("\n");
                }
                sb.append("\n升级入口：iStoreOS 后台 → 系统 → OTA，点「下载并升级」。");
                sb.append("\n刷固件会重启路由器，中途断电有变砖风险，所以不在 App 里代跑。");

                String log = data.optString("changelog", "");
                if (!log.isEmpty()) {
                    String brief = log.length() > 700 ? log.substring(0, 700) + "…" : log;
                    sb.append("\n\n————\n").append(brief);
                }

                Sheet.Builder box = Sheet.custom(ctx(), "发现新固件");
                box.bodyLeft(sb.toString());
                box.primary("知道了", false, null);
                box.show();
            }

            @Override
            public void onError(String message) {
                wait.dismiss();
                if (isAdded()) {
                    Sheet.message(ctx(), "检查失败", message);
                }
            }
        });
    }

    /** 检查更新：全过程用弹窗交代，别让用户盯着没反应的界面猜 */
    private void checkUpdates() {
        // 原来只丢一条 banner 就发请求，而 refresh=true 会先 opkg update，
        // 慢源上两三分钟才回来，接口超时后弹「检查失败」—— 报错就是这么来的。
        // 现在只读现有索引（秒回），刷新索引单独留给升级动作去做。
        Dialog wait = Sheet.custom(ctx(), "正在检查更新")
                .bodyLeft("正在读取已安装软件包与本地索引…")
                .show();
        wait.setCancelable(false);

        JSONObject body = new JSONObject();
        try {
            body.put("action", "check");
            body.put("refresh", false);
        } catch (Exception ignored) {
            wait.dismiss();
            return;
        }
        Api.postSlow(ctx(), "/api/v1/system/update", body, new Cb() {
            @Override
            public void onData(JSONObject data, boolean fromCache) {
                wait.dismiss();
                if (!isAdded()) {
                    return;
                }
                if (!data.optBoolean("ok", false)) {
                    Sheet.message(ctx(), "检查失败",
                            data.optString("error", "读取软件源失败，稍后再试。"));
                    return;
                }
                JSONObject fw = data.optJSONObject("firmware");
                String ver = fw == null ? "" : fw.optString("version", "");
                org.json.JSONArray pkgs = data.optJSONArray("packages");
                int n = pkgs == null ? 0 : pkgs.length();

                if (n == 0) {
                    Sheet.message(ctx(), "软件包已是最新",
                            "系统 iStoreOS " + ver + " 上装的 " + "软件包全部是最新版。\n\n"
                                    + "想要固件本体升级，用上面的「检查系统更新」。");
                    return;
                }

                StringBuilder sb = new StringBuilder();
                sb.append("共 ").append(n).append(" 个软件包可以升级：\n\n");
                int show = Math.min(n, 12);
                for (int i = 0; i < show; i++) {
                    JSONObject p = pkgs.optJSONObject(i);
                    if (p == null) {
                        continue;
                    }
                    sb.append("· ").append(p.optString("name", ""))
                            .append("\n  ").append(p.optString("current", ""))
                            .append(" → ").append(p.optString("latest", "")).append("\n");
                }
                if (n > show) {
                    sb.append("… 还有 ").append(n - show).append(" 个\n");
                }
                sb.append("\n升级在后台跑，中途不要断电，会断网一两分钟。");

                // 列表要左对齐 + 等宽字体，居中排每行行首参差不齐，根本没法看
                Sheet.Builder box = Sheet.custom(ctx(), "发现 " + n + " 个可升级");
                box.bodyLeft(sb.toString());
                box.cancel("稍后");
                box.primary("全部升级", false, (d, w) -> {
                    d.dismiss();
                    runUpgrade();
                });
                box.show();
            }

            @Override
            public void onError(String message) {
                wait.dismiss();
                if (isAdded()) {
                    Sheet.message(ctx(), "检查失败",
                            "没能拿到更新信息：\n" + message
                                    + "\n\n先确认手机和路由器都连着网，再试一次。");
                }
            }
        });
    }

    private void runUpgrade() {
        JSONObject body = new JSONObject();
        try {
            body.put("action", "upgrade");
        } catch (Exception ignored) {
            return;
        }
        Api.post(ctx(), "/api/v1/system/update", body, new Cb() {
            @Override
            public void onData(JSONObject data, boolean fromCache) {
                if (!isAdded()) {
                    return;
                }
                if (data.optBoolean("ok", false)) {
                    notice("升级已在后台开始，界面可能短暂卡顿", true);
                    Sheet.message(ctx(), "已开始升级",
                            data.optString("note", "") + "\n\n"
                                    + "升级过程会持续几分钟。完成后到「查看升级进度」看结果，"
                                    + "期间不要断电、不要手动重启路由器。");
                } else {
                    fail(data.optString("error", "启动升级失败"));
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

    private void showUpgradeProgress() {
        Api.getFresh(ctx(), "/api/v1/system/update", new Cb() {
            @Override
            public void onData(JSONObject data, boolean fromCache) {
                if (!isAdded()) {
                    return;
                }
                boolean running = data.optBoolean("running", false);
                String log = data.optString("log", "");
                if (log.isEmpty()) {
                    log = "还没有升级记录。";
                }
                Sheet.Builder box = Sheet.custom(ctx(), running ? "正在升级" : "升级日志");
                box.bodyLeft((running ? "后台任务还在跑…\n\n" : "") + log);
                box.primary("关闭", false, null);
                box.show();
            }

            @Override
            public void onError(String message) {
                if (isAdded()) {
                    Toast.makeText(ctx(), message, Toast.LENGTH_SHORT).show();
                }
            }
        });
    }

    private static String appVersion(Context c) {
        try {
            return c.getPackageManager().getPackageInfo(c.getPackageName(), 0).versionName;
        } catch (Exception e) {
            return "—";
        }
    }
}
