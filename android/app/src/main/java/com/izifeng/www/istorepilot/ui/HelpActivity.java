package com.izifeng.www.istorepilot.ui;

import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.view.View;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import androidx.annotation.Nullable;

import com.google.android.material.appbar.MaterialToolbar;
import com.izifeng.www.istorepilot.R;
import com.izifeng.www.istorepilot.core.BaseActivity;
import com.izifeng.www.istorepilot.util.Theme;
import com.izifeng.www.istorepilot.util.Ui;

/**
 * 使用帮助：从「路由器上还没有 Agent」讲到「四个页签怎么用」。
 *
 * 为什么挂在登录页：第一次用的人手里只有这个 App，地址填什么、口令是哪个、
 * 路由器上要不要先装点东西 —— 没人说就只能靠猜。放进设置里没用，
 * 因为卡住的正是还没登录进来的人。
 *
 * 三端同一份文案与顺序（iOS HelpView、鸿蒙 pages/HelpPage），改这里要同步那两处。
 */
public class HelpActivity extends BaseActivity {

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        Theme.apply(this);
        super.onCreate(savedInstanceState);

        MaterialToolbar toolbar = new MaterialToolbar(this);
        toolbar.setTitle("使用帮助");
        toolbar.setNavigationIcon(R.drawable.ic_back);
        toolbar.setNavigationIconTint(Ui.color(this, R.color.text_primary));
        toolbar.setNavigationOnClickListener(v -> finish());
        toolbar.setBackgroundColor(Ui.color(this, R.color.app_bg));

        ScrollView scroller = new ScrollView(this);
        scroller.setBackgroundColor(Ui.color(this, R.color.app_bg));
        scroller.setClipToPadding(false);
        scroller.setFillViewport(true);

        LinearLayout root = Ui.column(this);
        int pad = Ui.dp(this, 16);
        root.setPadding(pad, Ui.dp(this, 8), pad, Ui.dp(this, 28));
        scroller.addView(root);

        LinearLayout page = Ui.column(this);
        page.setBackgroundColor(Ui.color(this, R.color.app_bg));
        page.addView(toolbar, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        page.addView(scroller, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));
        setContentView(page);

        build(root);
    }

    private void build(LinearLayout root) {
        // ---------------------------------------------------------- 一、装 Agent
        LinearLayout c1 = card(root, "一、先在路由器上装 Agent", "只需一次");

        step(c1, 1, "下载安装包",
                "打开 github.com/zifeng-chen/istore-pilot/releases/latest ，"
                        + "按架构挑一个 .run：Intel / AMD 选 x86_64，ARM 选 arm64。");
        step(c1, 2, "传到路由器",
                "方式一（推荐）：iStoreOS 自带「iStore 商店」，进商店 → 上传插件，"
                        + "把下载好的 .run 传上去，它会在商店里自动安装。\n"
                        + "方式二：scp，或 LuCI 的「系统 → 文件传输」，放到 /tmp/ 下再手动执行。");
        step(c1, 3, "先检查再安装", "SSH 登录路由器，执行下面两行：");
        code(c1, "sh /tmp/istore-pilot_<版本>_x86_64.run --check\n"
                + "sh /tmp/istore-pilot_<版本>_x86_64.run");
        step(c1, 4, "确认装好了",
                "浏览器打开 http://路由器IP:8443 ，能看到登录框就成了 —— "
                        + "这个 8443 就是下面要填的端口。");
        note(c1, "24.10 及更早也可以用 .ipk（系统 → 软件包 → 上传软件包）；"
                + "25.12 起包管理器换成了 apk，只能用 .run。两种不要同时装。");

        // ---------------------------------------------------------- 二、登录
        LinearLayout c2 = card(root, "二、回到这里登录", null);

        bullet(c2, "地址", "局域网填「路由器IP:8443」，例如 192.168.100.1:8443；"
                + "外网填 DDNS 域名加端口。");
        bullet(c2, "密码", "与路由器后台、SSH 是同一个，也就是安装时设的 AGENT_PASSWORD。");
        para(c2, "连不上，按这个顺序查：");
        bullet(c2, "①", "点「连接」，看它报什么错 —— 错误直接写在密码框下面");
        bullet(c2, "②", "Agent 在不在跑：/etc/init.d/istore-agent status");
        bullet(c2, "③", "8443 有没有被防火墙拦住");
        bullet(c2, "④", "外网访问要先在路由器上做端口映射");

        // ---------------------------------------------------------- 三、页签
        LinearLayout c3 = card(root, "三、App 里有什么", null);

        bullet(c3, "概览", "外网状态、实时上下行、网口速率、CPU / 内存 / 运行时长。");
        bullet(c3, "设备", "谁在线、各自跑了多少流量，点进去看连接明细；"
                + "拦截（AdGuard Home）也在这里。");
        bullet(c3, "代理", "装 OpenClash / PassWall、切运行模式、选节点、管订阅。"
                + "两个插件的配置各一套，不通用。");
        bullet(c3, "设置", "改服务器地址、配置备份、固件与软件包更新、重启。");

        // ---------------------------------------------------------- 四、坑
        LinearLayout c4 = card(root, "四、容易踩的几个点", null);

        bullet(c4, "·", "安装包一定放 /tmp —— 它是内存盘，重启自动清空，不占闪存。");
        bullet(c4, "·", "恢复配置备份后会问「保留 / 撤销」，90 秒内不点会自动退回原样。");
        bullet(c4, "·", "装代理插件时如果所有下载通道都不通，会问要不要改 hosts 加速。");
        bullet(c4, "·", "数据 3 秒自动刷新一次；等不及就下拉一下。");
    }

    // ---------------------------------------------------------------- 零件

    /**
     * 一张卡。左右内边距必须自己给：Ui.cardPadding 把左右设成 0，
     * 那是给「行自带 16 缩进」的设置卡用的；这一页的子项是裸文字，
     * 照抄会让标题和代码块直接贴到卡片边缘。
     */
    private LinearLayout card(LinearLayout root, String title, String sub) {
        Ui.Card card = Ui.card(this);
        int p = Ui.dp(this, 16);
        card.setPadding(p, Ui.dp(this, 16), p, Ui.dp(this, 14));
        Ui.header(card, title, sub);
        root.addView(card);
        return card;
    }

    private void step(LinearLayout card, int n, String title, String detail) {
        LinearLayout line = Ui.row(card.getContext());
        line.setGravity(android.view.Gravity.TOP);

        TextView num = Ui.text(this, String.valueOf(n), 11.5f, R.color.primary);
        num.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        num.setGravity(android.view.Gravity.CENTER);
        GradientDrawable dot = new GradientDrawable();
        dot.setShape(GradientDrawable.OVAL);
        dot.setColor(Ui.alpha(Ui.color(this, R.color.primary), 0.16f));
        num.setBackground(dot);
        int dotW = Ui.dp(this, 20);
        LinearLayout.LayoutParams dlp = new LinearLayout.LayoutParams(dotW, dotW);
        dlp.rightMargin = Ui.dp(this, 10);
        line.addView(num, dlp);

        LinearLayout box = Ui.column(this);
        TextView t = Ui.text(this, title, 13.5f, R.color.text_primary);
        t.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        box.addView(t);
        TextView d = Ui.text(this, detail, 12.5f, R.color.text_secondary);
        d.setLineSpacing(Ui.dp(this, 2), 1f);
        LinearLayout.LayoutParams dl = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        dl.topMargin = Ui.dp(this, 3);
        box.addView(d, dl);

        line.addView(box, new LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.topMargin = Ui.dp(this, 12);
        card.addView(line, lp);
    }

    private void bullet(LinearLayout card, String mark, String text) {
        LinearLayout line = Ui.row(card.getContext());
        line.setGravity(android.view.Gravity.TOP);

        TextView m = Ui.text(this, mark, 12.5f, R.color.primary);
        m.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        LinearLayout.LayoutParams mlp = new LinearLayout.LayoutParams(
                Ui.dp(this, 34), ViewGroup.LayoutParams.WRAP_CONTENT);
        line.addView(m, mlp);

        TextView t = Ui.text(this, text, 12.5f, R.color.text_secondary);
        t.setLineSpacing(Ui.dp(this, 2), 1f);
        line.addView(t, new LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.topMargin = Ui.dp(this, 8);
        card.addView(line, lp);
    }

    private void para(LinearLayout card, String text) {
        TextView t = Ui.text(this, text, 13f, R.color.text_primary);
        t.setLineSpacing(Ui.dp(this, 3), 1f);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.topMargin = Ui.dp(this, 12);
        card.addView(t, lp);
    }

    /** 命令行块：等宽 + 可选中的，用户能长按复制 */
    private void code(LinearLayout card, String text) {
        TextView t = new TextView(this);
        t.setText(text);
        t.setTextSize(12f);
        t.setTextColor(Ui.color(this, R.color.text_primary));
        t.setTypeface(Typeface.MONOSPACE);
        t.setTextIsSelectable(true);
        t.setLineSpacing(Ui.dp(this, 3), 1f);
        int p = Ui.dp(this, 11);
        t.setPadding(p, Ui.dp(this, 9), p, Ui.dp(this, 9));
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(Ui.color(this, R.color.surface_sunken));
        bg.setCornerRadius(Ui.dp(this, 10));
        t.setBackground(bg);

        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.topMargin = Ui.dp(this, 8);
        card.addView(t, lp);
    }

    private void note(LinearLayout card, String text) {
        TextView t = Ui.text(this, text, 10.5f, R.color.text_tertiary);
        t.setLineSpacing(Ui.dp(this, 2), 1f);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.topMargin = Ui.dp(this, 10);
        card.addView(t, lp);
    }
}
