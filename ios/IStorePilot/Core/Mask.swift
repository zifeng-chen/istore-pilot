import Foundation

/// 列表里显示用的脱敏地址：内网原样，公网 / CGNAT 打码。
///
/// 只作用于「一眼扫过」的列表；点开的弹窗用原值 —— 用户要复制完整地址去填
/// DDNS、做端口映射。截图时列表不会把 WAN 地址带出去。
///
/// - IPv4：`100.76.60.71/32` → `100.*.*.71/32`
/// - IPv6：`240e:3a0:5680:…/64` → `240e:3a0:…/64`
enum Mask {

    static func addr(_ v: String) -> String {
        if v.isEmpty || v == "—" { return v }

        let parts = v.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let addr = String(parts[0])
        let suffix = parts.count > 1 ? "/" + parts[1] : ""

        if addr.contains(":") {
            let low = addr.lowercased()
            if low == "::1" || low.hasPrefix("fe80")
                || low.hasPrefix("fc") || low.hasPrefix("fd") {
                return v
            }
            let groups = addr.split(separator: ":").filter { !$0.isEmpty }
            guard let first = groups.first else { return v }
            if groups.count >= 2 {
                return "\(first):\(groups[1]):…" + suffix
            }
            return "\(first):…" + suffix
        }

        let p = addr.split(separator: ".", omittingEmptySubsequences: false)
        guard p.count == 4,
              let a = Int(p[0]), let b = Int(p[1]) else { return v }
        let local = a == 10 || a == 127
            || (a == 192 && b == 168)
            || (a == 172 && b >= 16 && b <= 31)
            || (a == 169 && b == 254)
        return local ? v : "\(p[0]).*.*.\(p[3])" + suffix
    }
}
