import Foundation

/// 演示模式：把录制好的接口返回打进包里，不连路由器、不需要网络。
///
/// 存在的理由只有一个 —— 应用商店审核。审核员没有你的路由器，打开 App 就
/// 停在登录页；有了这份数据，点「先看看演示」就能把五个页签完整看一遍。
///
/// 两条硬规矩：
///   1. 只读。写操作在 Api 层被拦掉并明确告知，不假装成功 ——
///      假装成功会让审核员以为「禁网」真的生效了，反而更糟。
///   2. 数据已脱敏。MAC / 内网地址 / 机场名 / 订阅链接 / 访问日志全部换过，
///      生成脚本是 scripts/record_demo.py，随时可以重录。
///
/// 数据的形状和真实接口完全一致（就是录下来的真机返回），页面上没有
/// 「演示专用分支」—— 少一套分支就少一处线上线下不一致的 bug。
enum Demo {

    /// 演示模式下所有写操作统一回这句
    static let readOnly = "演示模式只能浏览，这项操作需要连接真实路由器"

    private static let kOn = "istore.demo"

    private static var routes: [String: J]?
    private static var keys: [String] = []

    static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: kOn) }
        set { UserDefaults.standard.set(newValue, forKey: kOn) }
    }

    /// 取接口数据。没录到返回空对象 —— 界面用 J 的默认值兜底，
    /// 不编假数据（字段对不上比空着更容易露馅）。
    static func data(_ path: String) -> J {
        load()
        guard let table = routes else { return J() }
        let k = key(path)
        if let hit = table[k] { return hit }
        // 前缀回退：带查询串的接口（devices/detail?mac=xx）只录了几台设备，
        // 其余设备拿同一条详情顶替
        let base = key(pathOf(path))
        for kk in keys where kk == base || kk.hasPrefix(base + "_") {
            if let v = table[kk] { return v }
        }
        return J()
    }

    /// 路径 + 查询串 → key。规则和 scripts/record_demo.py 的 _key 一致
    static func key(_ path: String) -> String {
        var src = path
        while src.hasPrefix("/") { src.removeFirst() }
        while src.hasSuffix("/") { src.removeLast() }
        var out = ""
        for ch in src.unicodeScalars {
            let alnum = (ch.value >= 48 && ch.value <= 57)
                || (ch.value >= 65 && ch.value <= 90)
                || (ch.value >= 97 && ch.value <= 122)
            out.append(alnum ? Character(ch) : "_")
        }
        return out
    }

    private static func pathOf(_ path: String) -> String {
        guard let q = path.firstIndex(of: "?") else { return path }
        return String(path[path.startIndex..<q])
    }

    private static func load() {
        guard routes == nil else { return }
        var table: [String: J] = [:]
        guard let url = Bundle.main.url(forResource: "demo", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rs = doc["routes"] as? [String: Any] else {
            routes = table
            return
        }
        for (k, v) in rs {
            guard let item = v as? [String: Any],
                  let d = item["data"] as? [String: Any] else { continue }
            table[k] = d
            keys.append(k)
        }
        routes = table
    }
}
