import UIKit
import WebKit

/// 极简 WKWebView 壳：加载路由器上托管的页面。
///
/// 交互约定：
///  - 下拉刷新（和 Safari 一致）
///  - 摇一摇手机：弹出「路由器地址」，用于切内网 / 外网域名
///  - 加载失败：显示 Bundle 里的 error.html，页面里可点按钮改地址
///
/// 页面走 http 明文，需要在 Info.plist 放行 ATS，详见同目录 README。
final class ViewController: UIViewController {

    private enum Const {
        static let defaultAddress = "http://192.168.100.1:8443"
        static let addressKey = "istore.address"
        static let bg = UIColor(red: 0.043, green: 0.059, blue: 0.078, alpha: 1.0) // #0b0f14
        static let blue = UIColor(red: 0.039, green: 0.518, blue: 1.0, alpha: 1.0)  // #0a84ff
    }

    private var webView: WKWebView!
    private var progressBar: UIProgressView!
    private var progressObservation: NSKeyValueObservation?
    private var showingErrorPage = false

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Const.bg
        setupWebView()
        setupProgressBar()
        loadTarget()
    }

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    // MARK: - 搭建

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.backgroundColor = Const.bg
        webView.isOpaque = false
        webView.scrollView.backgroundColor = Const.bg
        webView.customUserAgent = (webView.customUserAgent ?? "") + " iStoreOSApp/1.0.0"
        webView.navigationDelegate = self

        // 下拉刷新
        let refresh = UIRefreshControl()
        refresh.tintColor = Const.blue
        refresh.addTarget(self, action: #selector(refreshPulled), for: .valueChanged)
        webView.scrollView.refreshControl = refresh

        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func setupProgressBar() {
        progressBar = UIProgressView(progressViewStyle: .bar)
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.progressTintColor = Const.blue
        progressBar.trackTintColor = .clear
        view.addSubview(progressBar)
        NSLayoutConstraint.activate([
            progressBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 2),
        ])

        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
            guard let self else { return }
            let p = Float(webView.estimatedProgress)
            self.progressBar.setProgress(p, animated: true)
            self.progressBar.isHidden = p >= 0.999
        }
    }

    // MARK: - 地址与加载

    private var address: String {
        get { UserDefaults.standard.string(forKey: Const.addressKey) ?? Const.defaultAddress }
        set { UserDefaults.standard.set(newValue, forKey: Const.addressKey) }
    }

    private func normalize(_ raw: String) -> String? {
        var v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return nil }
        if !v.lowercased().hasPrefix("http://") && !v.lowercased().hasPrefix("https://") {
            v = "http://" + v
        }
        while v.hasSuffix("/") { v.removeLast() }
        guard let url = URL(string: v), let host = url.host, !host.isEmpty else { return nil }
        return v
    }

    private func loadTarget() {
        guard let url = URL(string: address) else { return }
        showingErrorPage = false
        var request = URLRequest(url: url)
        request.cachePolicy = .useProtocolCachePolicy
        webView.load(request)
    }

    private func showErrorPage() {
        guard !showingErrorPage else { return }
        showingErrorPage = true
        guard let file = Bundle.main.url(forResource: "error", withExtension: "html") else {
            let alert = UIAlertController(title: "连不上路由器",
                                          message: "请检查地址：\(address)",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "改地址", style: .default) { [weak self] _ in
                self?.promptForAddress()
            })
            alert.addAction(UIAlertAction(title: "重试", style: .default) { [weak self] _ in
                self?.loadTarget()
            })
            present(alert, animated: true)
            return
        }
        webView.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
    }

    @objc private func refreshPulled() {
        if showingErrorPage {
            loadTarget()
        } else {
            webView.reload()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.webView.scrollView.refreshControl?.endRefreshing()
        }
    }

    // MARK: - 摇一摇改地址

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            promptForAddress()
        } else {
            super.motionEnded(motion, with: event)
        }
    }

    private func promptForAddress() {
        let alert = UIAlertController(
            title: "路由器地址",
            message: "家里填内网地址，外面填 DDNS 域名",
            preferredStyle: .alert
        )
        alert.addTextField { [weak self] field in
            field.text = self?.address
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "恢复默认", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.address = Const.defaultAddress
            self.loadTarget()
        })
        alert.addAction(UIAlertAction(title: "保存", style: .default) { [weak self, weak alert] _ in
            guard let self, let text = alert?.textFields?.first?.text else { return }
            guard let v = self.normalize(text) else {
                self.promptInvalid()
                return
            }
            self.address = v
            self.loadTarget()
        })
        present(alert, animated: true)
    }

    private func promptInvalid() {
        let alert = UIAlertController(title: "地址格式不正确",
                                      message: "例如 http://192.168.100.1:8443",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - WKNavigationDelegate

extension ViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {

        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let scheme = url.scheme?.lowercased() ?? ""

        // 错误页里的「改地址」按钮走这个自定义 scheme
        if scheme == "istoreos" {
            decisionHandler(.cancel)
            promptForAddress()
            return
        }

        if scheme == "http" || scheme == "https" {
            decisionHandler(.allow)
            return
        }

        // 其它协议交给系统
        decisionHandler(.cancel)
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        progressBar.isHidden = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        progressBar.isHidden = true
        if webView.url?.scheme?.lowercased().hasPrefix("http") == true {
            showingErrorPage = false
        }
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        progressBar.isHidden = true
        let ns = error as NSError
        // 用户主动取消不算失败
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        showErrorPage()
    }

    func webView(_ webView: WKWebView,
                 didFail navigation: WKNavigation!,
                 withError error: Error) {
        progressBar.isHidden = true
        showErrorPage()
    }
}
