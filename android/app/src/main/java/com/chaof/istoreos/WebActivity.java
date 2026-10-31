package com.chaof.istoreos;

import android.annotation.SuppressLint;
import android.graphics.Color;
import android.os.Build;
import android.os.Bundle;
import android.view.MenuItem;
import android.view.View;
import android.view.ViewGroup;
import android.webkit.CookieManager;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.Nullable;

import com.chaof.istoreos.api.Api;
import com.chaof.istoreos.api.Cb;
import com.chaof.istoreos.core.BaseActivity;
import com.chaof.istoreos.core.Session;
import com.chaof.istoreos.util.Theme;
import com.chaof.istoreos.util.Ui;
import com.google.android.material.appbar.MaterialToolbar;

import org.json.JSONObject;

/**
 * 内置浏览器：路由器网页端（LuCI）。
 *
 * 为什么不交给系统浏览器：跳出去就是另一个 App，回来还得从最近任务里翻；
 * 更要紧的是 LuCI 会再验一次密码 —— 而 App 刚刚才用同一个口令登录过。
 * 所以进来先向 Agent 要一张「已登录的通行证」：Agent 在这台路由器上、
 * 又是 root，替用户登一次 LuCI，只把会话 id（sysauth_http cookie）交给客户端，
 * **口令不出路由器**。把它塞进 WebView 的 CookieManager 再加载
 * `/cgi-bin/luci/`，用户看到的就是后台首页，不是那张登录页。
 *
 * 拿不到通行证（比如 root 口令和 App 登录口令不一样）也不妨碍使用：
 * 照样打开网页端，让用户自己登一次，行为退回到改版前。
 */
public class WebActivity extends BaseActivity {

    public static final String EXTRA_TITLE = "title";
    /** 落地的 LuCI 路径，比如 /cgi-bin/luci/admin/system/package-manager。
     *  不传就停在后台首页。 */
    public static final String EXTRA_PATH = "path";

    private WebView web;
    private ProgressBar bar;
    private TextView errorBox;
    private String wantPath = "";

    /** 拿不到票据时的兜底地址：Agent 在 8443，LuCI 在 80，端口必须剥掉 */
    private String fallbackUrl = "";

    @SuppressLint("SetJavaScriptEnabled")
    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        Theme.apply(this);
        super.onCreate(savedInstanceState);

        String title = getIntent().getStringExtra(EXTRA_TITLE);
        if (title == null || title.isEmpty()) {
            title = "路由器网页端";
        }
        String p = getIntent().getStringExtra(EXTRA_PATH);
        wantPath = p == null ? "" : p;

        fallbackUrl = guessLuciUrl();

        LinearLayout page = new LinearLayout(this);
        page.setOrientation(LinearLayout.VERTICAL);
        page.setBackgroundColor(Ui.color(this, R.color.app_bg));
        page.setFitsSystemWindows(true);

        MaterialToolbar toolbar = new MaterialToolbar(this);
        toolbar.setTitle(title);
        toolbar.setSubtitle(hostOf(fallbackUrl));
        toolbar.setTitleTextColor(Ui.color(this, R.color.text_primary));
        toolbar.setSubtitleTextColor(Ui.color(this, R.color.text_secondary));
        toolbar.setNavigationIcon(R.drawable.ic_back);
        toolbar.setNavigationIconTint(Ui.color(this, R.color.text_primary));
        toolbar.setBackgroundColor(Ui.color(this, R.color.app_bg));
        toolbar.setNavigationOnClickListener(v -> finish());
        // 没有图标也能用：带 WITH_TEXT 就按文字显示
        MenuItem reload = toolbar.getMenu().add("刷新");
        reload.setShowAsAction(MenuItem.SHOW_AS_ACTION_ALWAYS
                | MenuItem.SHOW_AS_ACTION_WITH_TEXT);
        reload.setOnMenuItemClickListener(item -> {
            if (web != null) {
                errorBox.setVisibility(View.GONE);
                web.setVisibility(View.VISIBLE);
                web.reload();
            }
            return true;
        });
        page.addView(toolbar, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        // 细进度条：LuCI 的页面是服务端渲染的，跳一次要 200-600ms，
        // 没有进度提示会以为点了没反应
        bar = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        bar.setMax(100);
        bar.setProgress(0);
        bar.setVisibility(View.GONE);
        page.addView(bar, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, Ui.dp(this, 2)));

        FrameLayout holder = new FrameLayout(this);
        page.addView(holder, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f));

        web = new WebView(this);
        web.setBackgroundColor(Ui.color(this, R.color.app_bg));
        WebSettings st = web.getSettings();
        st.setJavaScriptEnabled(true);
        st.setDomStorageEnabled(true);
        st.setDatabaseEnabled(true);
        // 认页面自己的 viewport（后面要改它也靠这个开关生效）
        st.setUseWideViewPort(true);
        st.setLoadWithOverviewMode(true);
        st.setSupportZoom(true);
        st.setBuiltInZoomControls(true);
        st.setDisplayZoomControls(false);
        st.setMixedContentMode(WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE);
        // 后台刷不刷无所谓，前台要能正常渲染动画
        st.setCacheMode(WebSettings.LOAD_DEFAULT);
        holder.addView(web, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        errorBox = Ui.text(this, "", 13f, R.color.text_secondary);
        errorBox.setVisibility(View.GONE);
        errorBox.setPadding(Ui.dp(this, 24), Ui.dp(this, 48), Ui.dp(this, 24), 0);
        holder.addView(errorBox, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        CookieManager cm = CookieManager.getInstance();
        cm.setAcceptCookie(true);
        cm.setAcceptThirdPartyCookies(web, true);

        web.setWebViewClient(new WebViewClient() {
            @Override
            public void onPageFinished(WebView view, String url) {
                bar.setVisibility(View.GONE);
                fitToWidth(view);
                // iStoreOS 首页那几张卡是 JS 画出来的，第一帧还没有它们，
                // 等 600ms 再量一次才不会漏判
                view.postDelayed(() -> fitToWidth(view), 600);
            }

            @Override
            public void onReceivedError(WebView view, WebResourceRequest request,
                                        WebResourceError error) {
                // 只处理主文档：LuCI 里某个图标 404 不该整页变成错误提示
                if (Build.VERSION.SDK_INT >= 23 && request.isForMainFrame()) {
                    showError("打不开 " + request.getUrl().getHost()
                            + "，确认手机还连着这个路由器的 Wi-Fi。");
                }
            }

            @SuppressWarnings("deprecation")
            @Override
            public void onReceivedError(WebView view, int code, String desc, String url) {
                if (Build.VERSION.SDK_INT < 23) {
                    showError("打不开 " + hostOf(url) + "，确认手机还连着这个路由器的 Wi-Fi。");
                }
            }
        });

        web.setWebChromeClient(new WebChromeClient() {
            @Override
            public void onProgressChanged(WebView view, int progress) {
                bar.setVisibility(progress >= 100 ? View.GONE : View.VISIBLE);
                bar.setProgress(progress);
            }
        });

        setContentView(page);

        openWithTicket();
    }

    /**
     * 先换票再加载。
     *
     * 顺序不能反：先 loadUrl 再 setCookie，LuCI 已经按未登录渲染过一次，
     * 页面会先闪一下登录页再跳回来。
     */
    private void openWithTicket() {
        bar.setVisibility(View.VISIBLE);
        Api.getFresh(this, "/api/v1/luci/session", new Cb() {
            @Override
            public void onData(JSONObject body, boolean fromCache) {
                if (isFinishing() || web == null) {
                    return;
                }
                String rawUrl = body.optString("url", fallbackUrl);
                // 票据里的地址必须是「我们连的这台路由器」。否则（被篡改、
                // 或被 Host 头带偏）这张 root 会话 cookie 就会被种到别的域上。
                // 用 final 局部变量：下面两层 lambda 要捕获它
                final String url = hostOnly(rawUrl).equals(hostOnly(Session.base(WebActivity.this)))
                        ? rawUrl : fallbackUrl;
                String name = body.optString("cookie_name", "");
                String value = body.optString("cookie_value", "");
                if (body.optBoolean("ok", false) && !name.isEmpty() && !value.isEmpty()) {
                    CookieManager cm = CookieManager.getInstance();
                    // 先清空 WebView 的 cookie 罐：LuCI 自己下发的 cookie 路径是
                    // /cgi-bin/luci/，我们这张是 /，两个同名 cookie 同时存在时
                    // 服务端取哪一条是没保证的 —— 上一轮残留的旧会话因此让人
                    // 反复掉回登录页。罐子是空的才开始，就只有一个 sysauth_http
                    cm.removeAllCookies(cleared -> runOnUiThread(() ->
                            cm.setCookie(url, name + "=" + value + "; path=/", ok -> runOnUiThread(() -> {
                                if (!isFinishing() && web != null) {
                                    web.loadUrl(withPath(url));
                                }
                            }))));
                    return;
                }
                // 票据拿不到：不是错误，退回「打开网页端，自己登」
                String why = body.optString("error", "");
                if (!why.isEmpty()) {
                    Toast.makeText(WebActivity.this, "需要手动登录一次后台", Toast.LENGTH_SHORT).show();
                }
                web.loadUrl(withPath(url));
            }

            @Override
            public void onError(String message) {
                if (isFinishing() || web == null) {
                    return;
                }
                web.loadUrl(fallbackUrl);
            }
        });
    }

    /**
     * 装不下就整体缩小，别让右半页被切掉。
     *
     * LuCI 的 argon 主题给主容器写了 `min-width:600px`，iStoreOS 首页的卡片栅格
     * 又是「固定两列」，两件事叠在一起，在 411dp 的手机上右侧必然溢出 —— 这是
     * 路由器页面自己的设计，桌面浏览器拉窄也一样。改不了路由器，就在客户端补：
     * 量出真实内容宽度，把 viewport 改成那个宽度再等比缩小，整页就完整了。
     * 缩完文字偏小，所以顺手把 user-scalable 放开，双指还能放大。
     */
    private void fitToWidth(WebView view) {
        if (view == null) {
            return;
        }
        view.evaluateJavascript(
                "(function(){"
                + "var d=document,w=window,h=d.documentElement;"
                + "var iw=w.innerWidth||h.clientWidth;"
                + "var sw=Math.max(h.scrollWidth,d.body?d.body.scrollWidth:0);"
                + "if(!iw||!sw||sw<=iw+8)return 'ok';"
                + "var k=iw/sw;"
                + "var m=d.querySelector('meta[name=viewport]');"
                + "if(!m){m=d.createElement('meta');m.name='viewport';d.head.appendChild(m);}"
                + "m.setAttribute('content','width='+sw+',initial-scale='+k.toFixed(4)"
                + "+',maximum-scale=3,user-scalable=yes');"
                + "return 'fit';"
                + "})()", null);
    }

    private void showError(String text) {
        bar.setVisibility(View.GONE);
        web.setVisibility(View.GONE);
        errorBox.setText(text);
        errorBox.setVisibility(View.VISIBLE);
    }

    /** Agent 在 8443、LuCI 在 80：直接拿 Session.base 会把 API 端口当网页打开 */
    private String guessLuciUrl() {
        String host = Session.base(this).replaceFirst("^https?://", "");
        int slash = host.indexOf('/');
        if (slash > 0) {
            host = host.substring(0, slash);
        }
        if (host.startsWith("[")) {
            int end = host.indexOf(']');
            if (end > 0) {
                host = host.substring(0, end + 1);
            }
        } else {
            int colon = host.lastIndexOf(':');
            if (colon > 0) {
                host = host.substring(0, colon);
            }
        }
        return "http://" + host + "/cgi-bin/luci/";
    }

    /** 只取 host（不含端口、统一小写），用来核对票据地址 */
    private static String hostOnly(String url) {
        try {
            String h = android.net.Uri.parse(url == null ? "" : url).getHost();
            return h == null ? "" : h.toLowerCase();
        } catch (Exception e) {
            return "";
        }
    }

    private static String hostOf(String url) {
        String s = url == null ? "" : url.replaceFirst("^https?://", "");
        int slash = s.indexOf('/');
        return slash > 0 ? s.substring(0, slash) : s;
    }

    /**
     * 落地到指定 LuCI 页面。
     *
     * 票据给的 url 是后台首页，深链要自己换上路径；query 必须清掉，
     * 否则首页带过来的参数会跟着跑到别的页面上去。
     */
    private String withPath(String url) {
        if (wantPath == null || wantPath.isEmpty() || url == null || url.isEmpty()) {
            return url;
        }
        try {
            android.net.Uri u = android.net.Uri.parse(url);
            String path = wantPath.startsWith("/") ? wantPath : "/" + wantPath;
            return u.buildUpon().encodedPath(path).clearQuery().fragment(null).build().toString();
        } catch (Exception e) {
            return url;
        }
    }

    @Override
    public void onBackPressed() {
        if (web != null && web.canGoBack()) {
            web.goBack();
            return;
        }
        super.onBackPressed();
    }

    @Override
    protected void onDestroy() {
        if (web != null) {
            web.setVisibility(View.GONE);
            web.destroy();
        }
        super.onDestroy();
    }
}
