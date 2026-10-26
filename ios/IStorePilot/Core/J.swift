import Foundation

/// 接口返回的字段非常多，而且大半是可选的。
/// 用 `[String: Any]` 动态取值比定义几十个 Codable 结构体省事得多，
/// 加字段也不用改模型层 —— 这点和安卓端的 JSONObject 用法保持一致。
typealias J = [String: Any]

extension Dictionary where Key == String, Value == Any {

    func obj(_ k: String) -> J? { self[k] as? J }

    func list(_ k: String) -> [Any] { (self[k] as? [Any]) ?? [] }

    /// 对象数组：自动丢掉不是字典的元素
    func objs(_ k: String) -> [J] { list(k).compactMap { $0 as? J } }

    func str(_ k: String) -> String {
        switch self[k] {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case let b as Bool: return b ? "true" : "false"
        default: return ""
        }
    }

    func str(_ k: String, _ fallback: String) -> String {
        let v = str(k)
        return v.isEmpty ? fallback : v
    }

    func int(_ k: String) -> Int {
        switch self[k] {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s) ?? 0
        default: return 0
        }
    }

    func dbl(_ k: String) -> Double {
        switch self[k] {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s) ?? 0
        default: return 0
        }
    }

    func bool(_ k: String) -> Bool {
        switch self[k] {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String: return s == "true" || s == "1"
        default: return false
        }
    }

    /// `overview.load.threads` 这种是字符串 "1/364"，不能当数字取
    func pair(_ k: String) -> (Int, Int) {
        let parts = str(k).split(separator: "/")
        guard parts.count == 2 else { return (0, 0) }
        return (Int(parts[0]) ?? 0, Int(parts[1]) ?? 0)
    }
}
