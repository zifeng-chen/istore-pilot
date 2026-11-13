import SwiftUI
import WebKit

/// 内置浏览器：路由器网页端（LuCI）。对应安卓端的 `WebActivity`。
///
/// 为什么不交给 Safari：跳出去就是另一个 App，回来还得从最近任务里翻；
/// 更要紧的是 LuCI 会再验一次密码 —— 而 App 刚刚才用同一个口令登录过。
/// 所以进来先向 Agent 要一张「已登录的通行证」：Agent 就在这台路由器上、
/// 又是 root，替用户登一次 LuCI，只把会话 id（sysauth_http cookie）交给客户端，
/// **口令不出路由器**。把它塞进 WKWebView 的 cookie 仓再加载 /cgi-bin/luci/，
/// 用户看到的就是后台首页，不是那张登录页。
///
/// 拿不到通行证（比如 root 口令和 App 登录口令不一样）也不妨碍使用：
/// 照样打开网页端，让用户自己登一次，行为和改版前一样。
struct WebScreen: View {
    var title: String = "路由器网页端"
    /// 落地路径，比如 /cgi-bin/luci/admin/system/package-manager；空就停在后台首页
    var path: String = ""

    @Environment(\.dismiss) private var dismiss
    @StateObject private var ctl: WebController

    init(title: String = "路由器网页端", path: String = "") {
        self.title = title
        self.path = path
        _ctl = StateObject(wrappedValue: WebController(path: path))
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            // 细进度条：LuCI 是服务端渲染，跳一次 200-600ms，没有提示会以为点了没反应
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Color.clear
                    Rectangle()
                        .fill(C.primary)
                        .frame(width: g.size.width * ctl.safeProgress)
                }
            }
            .frame(height: 2)
            .opacity(ctl.progress > 0 && ctl.progress < 1 ? 1 : 0)

            ZStack {
                ctl.view
                if let note = ctl.blocked {
                    VStack(spacing: 8) {
                        LineIcon(name: "status-warning", size: 30, color: C.textTertiary)
                            .font(.system(size: 26))
                            .foregroundStyle(C.textSecondary)
                        Text(note)
                            .font(F.caption)
                            .foregroundStyle(C.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(C.appBg.ignoresSafeArea())
        .task { await ctl.start() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                if ctl.canGoBack {
                    ctl.goBack()
                } else {
                    dismiss()
                }
            } label: {
                LineIcon(name: "back", size: 18, color: C.textPrimary)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(C.textPrimary)
                    .frame(width: 34, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(F.cardTitle).foregroundStyle(C.textPrimary)
                if !ctl.host.isEmpty {
                    Text(ctl.host).font(.system(size: 11)).foregroundStyle(C.textSecondary)
                }
            }

            Spacer()

            Button {
                ctl.reload()
            } label: {
                Text("刷新")
                    .font(F.body)
                    .foregroundStyle(C.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .background(C.appBg)
    }
}

/// WKWebView 的 SwiftUI 外壳 + 免密加载逻辑。
///
/// 单独抽出来是因为「先设 cookie 再 load」这个顺序必须严格：
/// 反过来会先按未登录渲染一次，页面闪一下登录页再跳回来。
final class WebController: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var progress: Double = 0

    /// 进度条宽度直接吃这个值：KVO 首帧、重定向瞬间可能给到 NaN/负数，
    /// 未收敛时会刷 "Invalid frame dimension (negative or non-finite)"
    var safeProgress: CGFloat {
        guard progress.isFinite else { return 0 }
        return CGFloat(min(1, max(0, progress)))
    }
    @Published var host = ""
    @Published var blocked: String?

    let web: WKWebView
    private var loaded = false
    private let wantPath: String

    var view: UIViewRepresentableBox { UIViewRepresentableBox(web: web) }

    var canGoBack: Bool { web.canGoBack }

    init(path: String = "") {
        wantPath = path
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        web = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        web.navigationDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.addObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress),
                        options: .new, context: nil)
    }

    deinit {
        web.removeObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress))
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        if keyPath == #keyPath(WKWebView.estimatedProgress) {
            DispatchQueue.main.async { self.progress = self.web.estimatedProgress }
        }
    }

    func goBack() { web.goBack() }

    func reload() {
        blocked = nil
        web.reload()
    }

    func start() async {
        guard !loaded else { return }
        loaded = true

        let res = try? await Api.get("/api/v1/luci/session")

        // 地址一律由客户端拼：origin 用 App 里配的那个服务器，
        // 路径用 Agent 给的相对路径。这样局域网 / 域名 / https 反代
        // 都落在同一个源上（Agent 在 8443 上把 /cgi-bin/luci 透传给 80 口）。
        let path = res?.str("path") ?? "/cgi-bin/luci/"
        let urlStr = Self.origin() + (path.hasPrefix("/") ? path : "/" + path)
        await MainActor.run { host = URL(string: urlStr)?.host ?? "" }

        var cookies: [(String, String)] = []
        if let res, res.bool("ok") {
            let name = res.str("cookie_name")
            let value = res.str("cookie_value")
            if !name.isEmpty, !value.isEmpty {
                cookies.append((name, value))
            }
            // 网页端通行证：Agent 的代理只放行带这张 cookie 的请求，
            // 没换过票的浏览器直接被挡在门外
            if let pass = res.obj("web_cookie") {
                let pn = pass.str("name")
                let pv = pass.str("value")
                if !pn.isEmpty, !pv.isEmpty {
                    cookies.append((pn, pv))
                }
            }
        }
        // 拿不到票据也不挡：照样打开，让用户自己登一次
        await load(withPath(urlStr), cookies: cookies)
    }

    /// 票据给的 url 是后台首页，深链要自己换上路径；query 必须清掉，
    /// 否则首页带过来的参数会跟着跑到别的页面上
    private func withPath(_ s: String) -> String {
        guard !wantPath.isEmpty, var comp = URLComponents(string: s) else { return s }
        comp.path = wantPath.hasPrefix("/") ? wantPath : "/" + wantPath
        comp.query = nil
        comp.fragment = nil
        return comp.url?.absoluteString ?? s
    }

    private func load(_ urlStr: String, cookies jar: [(String, String)]) async {
        guard let url = URL(string: urlStr) else { return }
        let domain = url.host ?? ""
        let store = WKWebsiteDataStore.default().httpCookieStore

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            // 先清空 cookie：LuCI 自己下发的 cookie 路径是 /cgi-bin/luci/，
            // 我们这张是 /。两个同名 cookie 同时存在时服务端取哪一条没保证，
            // 上一轮的旧会话会让人反复掉回登录页
            store.getAllCookies { cookies in
                let group = DispatchGroup()
                for c in cookies {
                    group.enter()
                    store.delete(c) { group.leave() }
                }
                group.notify(queue: .main) {
                    // 注意别写成 cookies：外层 getAllCookies 的回调参数就叫 cookies（[HTTPCookie]），
                    // 会把它盖掉，编译器会去 HTTPCookie 上找 .0/.1
                    let ready = jar.compactMap { pair -> HTTPCookie? in
                        HTTPCookie(properties: [
                            .name: pair.0, .value: pair.1, .domain: domain,
                            .path: "/", .version: 0,
                        ])
                    }
                    guard !ready.isEmpty else {
                        cont.resume()
                        self.web.load(URLRequest(url: url))
                        return
                    }
                    let put = DispatchGroup()
                    for c in ready {
                        put.enter()
                        store.setCookie(c) { put.leave() }
                    }
                    put.notify(queue: .main) {
                        cont.resume()
                        self.web.load(URLRequest(url: url))
                    }
                }
            }
        }
    }

    /// App 当前连的 origin（协议 + 主机 + 端口），原样保留。
    ///
    /// 网页端必须和 API 同源：同源才能共用 cookie，也才能走 Agent 的代理路径。
    /// 以前这里把协议和端口都剥掉了，域名访问时打开的是 http://域名/，
    /// 打到 80 口上，必然白屏。
    static func origin() -> String {
        if let u = URL(string: Session.base), let scheme = u.scheme, let h = u.host {
            var out = "\(scheme)://\(h)"
            if let port = u.port { out += ":\(port)" }
            return out
        }
        return Session.base.hasSuffix("/") ? String(Session.base.dropLast()) : Session.base
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.async { self.progress = 0 }
        fitToWidth()
        // iStoreOS 首页的卡片是 JS 画的，第一帧还没有它们，等一会儿再量一次
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.fitToWidth()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        fail()
    }

    private func fail() {
        DispatchQueue.main.async {
            self.progress = 0
            self.blocked = "打不开 \(self.host)，确认手机还连着这个路由器的 Wi-Fi。"
        }
    }

    /// 装不下就整体缩小，别让右半页被切掉。
    ///
    /// LuCI 的 argon 主题给主容器写了 `min-width:600px`，iStoreOS 首页的卡片栅格
    /// 又是固定两列 —— 在 393pt 的 iPhone 上右侧必然溢出，桌面浏览器拉窄也一样。
    /// 改不了路由器就在客户端补：量出真实内容宽度，把 viewport 改成那个宽度再
    /// 等比缩小；缩完字偏小，所以顺手放开 user-scalable，双指还能放大。
    private func fitToWidth() {
        let js = """
        (function(){
          var d=document,w=window,h=d.documentElement;
          var iw=w.innerWidth||h.clientWidth;
          var sw=Math.max(h.scrollWidth,d.body?d.body.scrollWidth:0);
          if(!iw||!sw||sw<=iw+8)return 'ok';
          var k=iw/sw;
          var m=d.querySelector('meta[name=viewport]');
          if(!m){m=d.createElement('meta');m.name='viewport';d.head.appendChild(m);}
          m.setAttribute('content','width='+sw+',initial-scale='+k.toFixed(4)
            +',maximum-scale=3,user-scalable=yes');
          return 'fit';
        })()
        """
        web.evaluateJavaScript(js, completionHandler: nil)
    }
}

/// 把 WKWebView 塞进 SwiftUI
struct UIViewRepresentableBox: UIViewRepresentable {
    let web: WKWebView

    func makeUIView(context: Context) -> WKWebView { web }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
