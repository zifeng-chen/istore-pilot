package com.chaof.istoreos;

import android.annotation.SuppressLint;
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

    /**
     * 拿不到票据时的兜底地址。
     *
     * 现在网页端走 Agent 的同源代理（/cgi-bin/luci 转发到路由器 80 口），
     * 所以地址就是「App 连的那个 origin + 路径」—— 局域网、域名、
     * https 反代都用同一个 origin，不用再猜 LuCI 在哪个端口。
     */
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

        fallbackUrl = origin() + "/cgi-bin/luci/";

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
                    showError("打不开 " + hostOf(url) + "，检查网络是否可达这个地址。");
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
                // 地址一律由客户端自己拼：origin 是我们配的那个服务器，
                // 路径是 Agent 给的相对路径（/cgi-bin/luci/）。
                // 不再用服务端返回的绝对 url —— 它只可能是局域网地址，
                // 走域名进来时对不上（而且会把 root cookie 种到别的域上）。
                String path = body.optString("path", "/cgi-bin/luci/");
                final String url = origin() + (path.startsWith("/") ? path : "/" + path);
                String name = body.optString("cookie_name", "");
                String value = body.optString("cookie_value", "");

                // 网页端通行证：Agent 的代理只放行带这张 cookie 的请求，
                // 所以「能不能开网页端」= App 有没有换过票，浏览器直接访问进不来
                JSONObject pass = body.optJSONObject("web_cookie");
                final String passName = pass == null ? "" : pass.optString("name", "");
                final String passValue = pass == null ? "" : pass.optString("value", "");

                if (body.optBoolean("ok", false) && !name.isEmpty() && !value.isEmpty()) {
                    CookieManager cm = CookieManager.getInstance();
                    // 先清空 WebView 的 cookie 罐：LuCI 自己下发的 cookie 路径是
                    // /cgi-bin/luci/，我们这张是 /，两个同名 cookie 同时存在时
                    // 服务端取哪一条是没保证的 —— 上一轮残留的旧会话因此让人
                    // 反复掉回登录页。罐子是空的才开始，就只有一个 sysauth_http
                    cm.removeAllCookies(cleared -> runOnUiThread(() -> {
                        if (!passName.isEmpty() && !passValue.isEmpty()) {
                            cm.setCookie(url, passName + "=" + passValue + "; path=/", null);
                        }
                        cm.setCookie(url, name + "=" + value + "; path=/", ok -> runOnUiThread(() -> {
                            if (!isFinishing() && web != null) {
                                web.loadUrl(withPath(url));
                            }
                        }));
                    }));
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

    /**
     * App 当前连的 origin：协议 + 主机 + 端口，原样保留。
     *
     * 网页端和 API 必须同源 —— 同源才能共用 cookie、也才能走 Agent 的
     * 代理路径。以前这里把端口和协议都剥掉了，域名访问时打开的是
     * `http://域名/`（80 口），必然白屏。
     */
    private String origin() {
        String b = Session.base(this);
        int sep = b.indexOf("://");
        String scheme = sep > 0 ? b.substring(0, sep) : "http";
        String rest = sep > 0 ? b.substring(sep + 3) : b;
        int slash = rest.indexOf('/');
        if (slash >= 0) {
            rest = rest.substring(0, slash);
        }
        return scheme + "://" + rest;
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
