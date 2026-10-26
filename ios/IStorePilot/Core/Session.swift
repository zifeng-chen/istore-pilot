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

    /// 补协议、去尾斜杠、去多余空白。用户只会输入 `192.168.100.1:8443` 这种。
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return defaultBase }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "http://" + s
        }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
