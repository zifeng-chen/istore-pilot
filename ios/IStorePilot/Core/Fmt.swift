import Foundation

/// 数字格式化。全部走固定的中文单位，避免 Locale 差异。
/// 挂在 F 上（F 同时是字号命名空间），调用统一写 F.bytes / F.rate。
extension F {

    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    /// 字节 → "1.2 GB"
    static func bytes(_ v: Double) -> String {
        guard v.isFinite, v > 0 else { return "0 B" }
        var x = v
        var i = 0
        while x >= 1024 && i < units.count - 1 { x /= 1024; i += 1 }
        return String(format: i == 0 ? "%.0f %@" : "%.1f %@", x, units[i])
    }

    /// 速率 → "1.2 MB/s"
    static func rate(_ bps: Double) -> String {
        guard bps.isFinite, bps > 0.5 else { return "0 B/s" }
        return bytes(bps) + "/s"
    }

    /// hero 三列并排时的极短时长：6 天 / 23 小时 / 45 分。
    /// 每列只有屏宽 1/3，「6 天 5 小时」在那里必被截断。
    static func shortDur(_ sec: Double) -> String {
        guard sec.isFinite, sec > 0 else { return "—" }
        if sec >= 86400 { return "\(Int((sec / 86400).rounded())) 天" }
        if sec >= 3600 { return "\(Int((sec / 3600).rounded())) 小时" }
        return "\(max(1, Int((sec / 60).rounded()))) 分"
    }

    /// 秒 → "3 天 2 小时"
    static func dur(_ sec: Double) -> String {
        guard sec.isFinite, sec > 0 else { return "—" }
        let s = Int(sec)
        let d = s / 86400
        let h = (s % 86400) / 3600
        let m = (s % 3600) / 60
        if d > 0 { return "\(d) 天 \(h) 小时" }
        if h > 0 { return "\(h) 小时 \(m) 分" }
        if m > 0 { return "\(m) 分" }
        return "\(s) 秒"
    }

    static func pct(_ v: Double) -> String { String(format: "%.0f%%", v) }

    static func temp(_ c: Double) -> String { String(format: "%.1f°C", c) }

    /// 时间戳（秒）→ "10-25 23:41"
    static func clock(_ ts: Double) -> String {
        guard ts > 0 else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }

    /// 链路速率：2500 → "2.5G"，100 → "100M"
    static func speed(_ mbps: Int) -> String {
        guard mbps > 0 else { return "—" }
        if mbps >= 1000 {
            return String(format: "%.1fG", Double(mbps) / 1000)
        }
        return "\(mbps)M"
    }

    /// 千分位：103886 → "103,886"
    static func count(_ v: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    /// "2026-10-25T17:02:07+08:00" → "今天 17:02" / "昨天 17:02" / "10-25 17:02"
    static func friendlyISO(_ iso: String) -> String {
        guard iso.count >= 16 else { return "" }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        f.locale = Locale(identifier: "en_US_POSIX")
        let day = String(iso.dropFirst(5).prefix(5))       // MM-dd
        let clock = String(iso.dropFirst(11).prefix(5))    // HH:mm
        let today = DateFormatter()
        today.dateFormat = "MM-dd"
        if day == today.string(from: Date()) { return clock }
        if day == today.string(from: Date().addingTimeInterval(-86400)) {
            return "昨天 " + clock
        }
        return day + " " + clock
    }

    /// 网口卡片里的极短速率：12.3M / 380K，不带 /s ——
    /// 一张 150pt 宽的卡要同时放下 ↓ 和 ↑，加单位就挤不出去了
    static func short(_ bps: Double) -> String {
        guard bps.isFinite, bps > 0 else { return "0" }
        if bps < 1024 { return String(format: "%.0fB", bps) }
        if bps < 1024 * 1024 { return String(format: "%.0fK", bps / 1024) }
        if bps < 1024 * 1024 * 1024 {
            let m = bps / (1024 * 1024)
            return String(format: m >= 10 ? "%.0fM" : "%.1fM", m)
        }
        return String(format: "%.1fG", bps / (1024 * 1024 * 1024))
    }

    /// 相对时间 → "3 分钟前"
    static func ago(_ ts: Double) -> String {
        guard ts > 0 else { return "—" }
        let d = Date().timeIntervalSince1970 - ts
        if d < 60 { return "刚刚" }
        if d < 3600 { return "\(Int(d / 60)) 分钟前" }
        if d < 86400 { return "\(Int(d / 3600)) 小时前" }
        return "\(Int(d / 86400)) 天前"
    }
}
