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

    /// 图表 Y 轴刻度用的极短写法：0 / 128K / 4.2M。
    /// 与安卓 `Fmt.bpsAxis` 逐档对齐，两端刻度文字必须一模一样，
    /// 否则同一张图在手机上看到的量程读法会不同。
    static func bpsAxis(_ v: Double) -> String {
        guard v.isFinite, v > 0 else { return "0" }
        if v < 1024 { return String(format: "%.0fB", v) }
        if v < 1024 * 1024 { return String(format: "%.0fK", v / 1024) }
        if v < 1024 * 1024 * 1024 {
            let m = v / (1024 * 1024)
            return String(format: m >= 10 ? "%.0fM" : "%.1fM", m)
        }
        return String(format: "%.1fG", v / (1024 * 1024 * 1024))
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

    /// 秒 → "3 天 04:12:33" / "04:12:33"。
    /// 运行时长是拿来「看它还在跑」的，`dur()` 只到分钟，放在界面上像定住了
    static func uptime(_ sec: Double) -> String {
        let s = max(0, Int(sec.isFinite ? sec : 0))
        let hms = String(format: "%02d:%02d:%02d",
                         (s % 86400) / 3600, (s % 3600) / 60, s % 60)
        let d = s / 86400
        return d > 0 ? "\(d) 天 \(hms)" : hms
    }

    /// 接入方式标签。source == "ap" 是中兴 AP 报表里的**事实**，不写「推测」；
    /// source == "guess" 是推断的，必须标出来
    static func accessLabel(_ a: J) -> String {
        let band = a.str("band")
        // 只有「AP 报的 + 高置信」才是事实；从节点读不到时退回类型推断，
        // 那种同样带 source=ap，但必须标「推测」
        let real = a.str("source") == "ap" && a.str("conf") == "high"
        switch a.str("type") {
        case "wifi":
            let text = band.isEmpty ? "无线" : "无线 \(band)"
            return real ? text : text + "(推测)"
        case "wired":
            return real ? "有线" : "有线(推测)"
        default:
            return ""
        }
    }

    /// 列表徽标文字：能缩写就缩写（5G / 2.4G / WiFi / LAN），与安卓 `Access.shortLabel` 同一套规则。
    /// 频段不明就只说类型，类型也不明给破折号 —— 问号满屏比留白更像故障
    static func accessShort(_ a: J) -> String {
        let band = a.str("band")
        switch a.str("type") {
        case "wifi":
            if band.hasPrefix("5") { return "5G" }
            if band.hasPrefix("2") { return "2.4G" }
            return "WiFi"
        case "wired":
            return "LAN"
        default:
            return "—"
        }
    }

    /// 「AP 报表 + 高置信」才算事实，其余都是推断
    static func isAccessReal(_ a: J) -> Bool {
        a.str("source") == "ap" && a.str("conf") == "high"
    }

    /// 设备详情用的长文案：事实写来源，推测写依据
    static func accessDetail(_ a: J) -> String {
        let short = accessLabel(a)
        if short.isEmpty { return "" }
        if a.str("source") == "ap" && a.str("conf") == "high" {
            let ap = a.str("ap")
            return ap.isEmpty ? short : "\(short)（\(ap)）"
        }
        let why = a.str("reason")
        return why.isEmpty ? short : "\(short)（\(why)）"
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
