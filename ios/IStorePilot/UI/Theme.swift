import SwiftUI

/// 配色四层：appBg（页面底）< surfaceSunken（卡内嵌）< surface（卡片）< surfaceHi（抬升）。
/// 底色带一点绿调 —— 纯中性灰看着像后台管理面板，纯黑上卡片又浮不起来。
/// 数值与安卓端 `values/colors.xml` / `values-night/colors.xml` 一一对应，
/// 两个平台看起来必须是同一个 App。
enum C {

    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }

    static let appBg         = dyn(0xEDF3F0, 0x0A100E)
    static let surface       = dyn(0xFFFFFF, 0x1A2421)
    static let surfaceHi     = dyn(0xF2F2F7, 0x243430)
    static let surfaceSunken = dyn(0xF4F9F6, 0x141C1A)

    static let primary       = dyn(0x00A87E, 0x32D7AC)
    static let primaryDim    = dyn(0x007F5E, 0x17B58C)
    static let onPrimary     = dyn(0xFFFFFF, 0x04241C)

    // hero 渐变卡专用：不能拿 primary 当起点，浅色下白字只有 3:1
    static let heroFrom      = dyn(0x00805E, 0x12463A)
    static let heroTo        = dyn(0x00553E, 0x0A2C25)
    static let heroFg        = dyn(0xFFFFFF, 0xFFFFFF)
    static let heroFgSoft    = dyn(0xD9FFFFFF, 0xD9FFFFFF)

    // 导航未选中图标：不能复用 textSecondary，尺寸小、对比度要更高一档
    static let iconOff       = dyn(0x59635F, 0x87968F)

    static let danger        = dyn(0xFF3B30, 0xFF453A)
    static let warn          = dyn(0xFF9500, 0xFFD60A)
    static let ok            = dyn(0x34C759, 0x30D158)

    static let textPrimary   = dyn(0x000000, 0xFFFFFF)
    static let textSecondary = dyn(0x6F7A74, 0x93A39E)
    static let textTertiary  = dyn(0xC7C7CC, 0x5A6B66)

    static let divider       = dyn(0xDFE5E2, 0x3A4A44)
    static let track         = dyn(0xE1E7E4, 0x33423C)

    // 分段控件：浅色是"浅槽 + 白滑块"，深色反过来"暗槽 + 亮滑块"
    static let segmentTrack  = dyn(0xE4E9E7, 0x101A17)
    static let segmentThumb  = dyn(0xFFFFFF, 0x2E3F3A)

    static let glassStroke   = dyn(0x14000000, 0x1FFFFFFF)
    static let accentSoft    = dyn(0x1700A87E, 0x2432D7AC)
    static let accentSoft2   = dyn(0x2900A87E, 0x3D32D7AC)

    // 状态色（红涨绿跌的国际惯例在这里不适用，全部按语义使用）
    static func state(_ level: String) -> Color {
        switch level {
        case "ok", "online", "up": return ok
        case "warn", "partial": return warn
        case "danger", "down", "error": return danger
        default: return textSecondary
        }
    }
}

extension UIColor {
    /// 0xRRGGBB 用满不透明；0xAARRGGBB 才读最高字节当 alpha。
    /// 早先把 6 位色也按 ARGB 解，0x5FE7C4 的 alpha 会算成 0，颜色直接消失。
    convenience init(hex: UInt32) {
        let a: CGFloat = hex > 0xFF_FFFF ? CGFloat((hex >> 24) & 0xFF) / 255 : 1
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: a
        )
    }
}

extension Color {
    init(hex: UInt32) { self.init(UIColor(hex: hex)) }
}

enum F {
    static let hero      = Font.system(size: 33, weight: .bold)
    static let title     = Font.system(size: 22, weight: .bold)
    static let cardTitle = Font.system(size: 16, weight: .semibold)
    static let body      = Font.system(size: 15)
    static let value     = Font.system(size: 15, weight: .medium)
    static let caption   = Font.system(size: 12.5)
    static let tiny      = Font.system(size: 11.5)

    /// 数字一律用等宽数字，否则一列数字的小数点左右横跳
    static func num(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
}

enum R {
    static let card: CGFloat = 22
    static let row: CGFloat = 14
    static let sheet: CGFloat = 28
}

// MARK: - 外观

/// 主题模式。0 跟随系统，1 强制浅色，2 强制深色。
///
/// 存 UserDefaults 而不是只放内存：用户在设置里选了「深色」，
/// 下次冷启动还得是深色，否则每次打开都要闪一下浅色。
enum Appearance {
    static let names = ["跟随系统", "浅色", "深色"]
    static let modes = [0, 1, 2]

    private static let key = "istore.theme"

    static func get() -> Int {
        let v = UserDefaults.standard.integer(forKey: key)
        return modes.contains(v) ? v : 0
    }

    static func apply(_ mode: Int) {
        UserDefaults.standard.set(mode, forKey: key)
    }

    static func name(_ mode: Int) -> String {
        let i = modes.firstIndex(of: mode) ?? 0
        return names[i]
    }

    static func scheme(_ mode: Int) -> ColorScheme? {
        switch mode {
        case 1: return .light
        case 2: return .dark
        default: return nil
        }
    }
}
