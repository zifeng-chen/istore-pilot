import Foundation

/// 连接会话：路由器地址 + 令牌。
///
/// 令牌是 Agent 用 HMAC 自签的（有效期 7 天），本地只存 token 和过期时间，
/// 不保存密码 —— 和安卓端 `core/Session.java` 完全同一套规则。
enum Session {

    static let defaultBase = "http://192.168.100.1:8443"

    private static let kBase = "istore.base"
    private static let kToken = "istore.token"
    private static let kExpires = "istore.expires"
    private static let kUser = "istore.user"

    private static var d: UserDefaults { .standard }

    static var base: String {
        get {
            let v = d.string(forKey: kBase) ?? ""
            return v.isEmpty ? defaultBase : v
        }
        set { d.set(normalize(newValue), forKey: kBase) }
    }

    static var token: String { d.string(forKey: kToken) ?? "" }

    static var expiresAt: Double { d.double(forKey: kExpires) }

    static var user: String { d.string(forKey: kUser) ?? "" }

    static var isLoggedIn: Bool {
        !token.isEmpty && (expiresAt <= 0 || expiresAt > Date().timeIntervalSince1970)
    }

    static func save(token: String, expires: Double, user: String) {
        d.set(token, forKey: kToken)
        d.set(expires, forKey: kExpires)
        d.set(user, forKey: kUser)
    }

    static func logout() {
        d.removeObject(forKey: kToken)
        d.removeObject(forKey: kExpires)
    }

    /// 不含协议的主机地址，拿来当输入框的占位符。三端展示的是同一个串。
    static var defaultHost: String {
        defaultBase.replacingOccurrences(of: "http://", with: "")
                   .replacingOccurrences(of: "https://", with: "")
    }

    /// 补协议、补默认端口、去尾斜杠、去多余空白。
    ///
    /// 用户输入什么都认：`192.168.100.1` / `192.168.100.1:8443` /
    /// `http://192.168.100.1:8443` / `https://nas.lan`。
    /// 不写协议就补 http://（Agent 本身就是明文），不写端口补 8443 ——
    /// 这一条和安卓 `Session.normalize` 完全一致，鸿蒙也照抄了一份。
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return defaultBase }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "http://" + s
        }
        while s.hasSuffix("/") { s.removeLast() }

        // 没写端口时补 8443：`http://192.168.100.1` 直接连会打到 80 端口上，
        // 那儿是 LuCI，不是 Agent
        if let r = s.range(of: "://") {
            let rest = String(s[r.upperBound...])
            if !rest.contains(":") && !rest.contains("/") {
                s += ":8443"
            }
        }
        return s
    }
}
