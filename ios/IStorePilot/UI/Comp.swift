import SwiftUI

// MARK: - 卡片

/// 标准卡片：圆角 22 + 0.7pt 描边 + 1.2pt 投影，和安卓端 util/Ui.java 一致
struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(C.surface)
            .clipShape(RoundedRectangle(cornerRadius: R.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: R.card, style: .continuous)
                    .strokeBorder(C.glassStroke, lineWidth: 0.7)
            )
            .shadow(color: Color.black.opacity(0.055), radius: 3, x: 0, y: 1.2)
    }
}

/// 一组行装进一个容器。
/// 55 台设备如果每台一张卡，就是 55 层圆角和 55 层投影，又卡又碎。
struct ListGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .background(C.surface)
            .clipShape(RoundedRectangle(cornerRadius: R.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: R.card, style: .continuous)
                    .strokeBorder(C.glassStroke, lineWidth: 0.7)
            )
            .shadow(color: Color.black.opacity(0.055), radius: 3, x: 0, y: 1.2)
    }
}

struct Hairline: View {
    var inset: CGFloat = 16
    var body: some View {
        Rectangle()
            .fill(C.divider)
            .frame(height: 0.6)
            .padding(.leading, inset)
    }
}

// MARK: - 流量曲线

/// hero 卡里的流量趋势：两条折线 + 四条横向网格线。
/// 只描线不填充 —— 深色底上填充会盖住另一条线。
struct Sparkline: View {
    let down: [Double]
    let up: [Double]
    var height: CGFloat = 88

    var body: some View {
        GeometryReader { geo in
            let peak = max(down.max() ?? 0, up.max() ?? 0, 1)
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(0..<4, id: \.self) { i in
                        Rectangle()
                            .fill(Color.white.opacity(0.10))
                            .frame(height: 0.5)
                        if i < 3 { Spacer(minLength: 0) }
                    }
                }
                line(up, size: geo.size, peak: peak)
                    .stroke(Color(hex: 0xFFC46B).opacity(0.85),
                            style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                line(down, size: geo.size, peak: peak)
                    .stroke(Color(hex: 0x5FE7C4),
                            style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(height: height)
    }

    private func line(_ data: [Double], size: CGSize, peak: Double) -> Path {
        Path { p in
            guard data.count > 1, size.width > 0 else { return }
            let stepX = size.width / CGFloat(data.count - 1)
            for (i, v) in data.enumerated() {
                let x = CGFloat(i) * stepX
                let ratio = min(1, max(0, v / peak))
                let y = size.height - CGFloat(ratio) * (size.height - 6) - 3
                if i == 0 {
                    p.move(to: CGPoint(x: x, y: y))
                } else {
                    p.addLine(to: CGPoint(x: x, y: y))
                }
            }
        }
    }
}

// MARK: - 应用图标

/// 应用图标：优先用 Assets 里的官方图（与安卓 drawable-nodpi 同一批，
/// 由 scripts/sync_app_icons.py 同步），认不出来的名字退回「首字 + 稳定色块」。
///
/// 圆角 24% 与安卓 `AppIcon.RoundIconView` 一致 —— 抓来的图都是方图，
/// 圆角是 App Store 客户端加上去的，不裁就是方的。
struct AppIconView: View {
    let name: String
    var size: CGFloat = 32

    private var corner: CGFloat { size * 0.24 }

    var body: some View {
        Group {
            if let asset = AppIcons.asset(name) {
                Image(asset)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            } else {
                Text(glyph)
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(tint)
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            }
        }
        .frame(width: size, height: size)
    }

    /// 没有官方图时的首字：中文取第一个字，英文取前两个单词首字母
    private var glyph: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard let first = n.first else { return "?" }
        if first.isNumber { return String(n.prefix(2)) }
        if first.unicodeScalars.first!.value > 0x2E80 { return String(first) }
        let parts = n.split(separator: " ")
        if parts.count >= 2, let a = parts[0].first, let b = parts[1].first {
            return "\(Character(a.uppercased()))\(Character(b.uppercased()))"
        }
        return String(Character(first.uppercased()))
    }

    /// 稳定色：用字符编码求和，不用 hashValue（Swift 的 hash 每次启动都不同，
    /// 同一个应用的颜色会变来变去）
    private var tint: Color {
        let palette: [UInt32] = [
            0xFF5A2D, 0xFF7A00, 0xFB7299, 0x00BE06, 0x1E9FFF, 0xFF6C00,
            0xFF3B30, 0x161823, 0x07C160, 0x12B7F5, 0xFFAA00, 0x2577E3,
            0xCF0A2C, 0x0A59F7, 0x10A37F, 0x7C3AED,
        ]
        let seed = name.unicodeScalars.reduce(0) { ($0 &+ Int($1.value)) % 9973 }
        return Color(hex: palette[seed % palette.count])
    }
}

// MARK: - 文字

/// 卡片标题行：28pt 圆角图标块 + 标题 + 副标题，右侧留给调用方。
///
/// 对应安卓的 `Ui.cardTitle`。原来这里只有 `SectionTitle`（一行字，没有图标块），
/// 结果安卓的卡片都有彩色图标块、iOS 全是一行裸标题 —— 同一个 App 两个长相。
struct CardHead<Trailing: View>: View {
    let icon: String
    let title: String
    var sub: String = ""
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(C.primary)
                .frame(width: 28, height: 28)
                .background(C.accentSoft)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16.5, weight: .medium))
                    .foregroundStyle(C.textPrimary)
                if !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 12))
                        .foregroundStyle(C.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
    }
}

extension CardHead where Trailing == EmptyView {
    init(icon: String, title: String, sub: String = "") {
        self.init(icon: icon, title: title, sub: sub, trailing: { EmptyView() })
    }
}

struct SectionTitle: View {
    let text: String
    var trailing: String = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text)
                .font(F.cardTitle)
                .foregroundStyle(C.textPrimary)
            Spacer(minLength: 8)
            if !trailing.isEmpty {
                Text(trailing)
                    .font(F.caption)
                    .foregroundStyle(C.textSecondary)
            }
        }
    }
}

/// 键值行。值必须占满剩余宽度并右对齐 ——
/// 安卓端踩过：值给 WRAP_CONTENT 时，39 字符的 IPv6 会顶穿卡片右边距
struct KV: View {
    let k: String
    let v: String
    var mono: Bool = false
    var color: Color? = nil

    init(_ k: String, _ v: String, mono: Bool = false, color: Color? = nil) {
        self.k = k
        self.v = v.isEmpty ? "—" : v
        self.mono = mono
        self.color = color
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(k)
                .font(F.body)
                .foregroundStyle(C.textSecondary)
                .frame(width: 84, alignment: .leading)
            Text(v)
                .font(mono ? F.num(15, .medium) : F.value)
                .foregroundStyle(color ?? C.textPrimary)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.vertical, 9)
    }
}

struct Pill: View {
    let text: String
    var color: Color = C.primary

    var body: some View {
        Text(text)
            .font(F.tiny)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(color.opacity(0.13))
            .clipShape(Capsule())
    }
}

/// 接入方式徽标：5G / 2.4G / WiFi / LAN / —。
/// 事实画实心、推测画描边（从节点读不到时，主节点把经它接入的无线报成有线）。
/// 尺寸与配色照搬安卓 `Access.badge`，两端列表放在同一个位置上，看起来才是一套东西
struct AccessBadge: View {
    let access: J
    var online: Bool = true

    var body: some View {
        Text(F.accessShort(access))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(F.isAccessReal(access) ? tint.opacity(0.14) : .clear)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(tint.opacity(F.isAccessReal(access) ? 0 : 0.42),
                                          lineWidth: 1)
                    }
            }
            .fixedSize()
    }

    private var tint: Color {
        guard online else { return C.textTertiary }
        switch F.accessShort(access) {
        case "5G": return C.primary
        case "2.4G": return C.warn
        default: return C.textSecondary
        }
    }
}

// MARK: - 进度条

struct Bar: View {
    let ratio: Double
    var color: Color = C.primary
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(C.track)
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.75), color],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, min(1, ratio)) * geo.size.width)
            }
        }
        .frame(height: height)
    }
}

// MARK: - Hero 头

/// 顶部渐变卡。四个专用色，不拿 primary 当起点 ——
/// 浅色 primary 太浅，白大字压不住；深色下亮绿一整块糊在近黑底上非常刺眼。
struct Hero<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(colors: [C.heroFrom, C.heroTo],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .clipShape(RoundedRectangle(cornerRadius: R.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: R.card, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.8)
            )
            .shadow(color: C.heroTo.opacity(0.28), radius: 10, x: 0, y: 5)
    }
}

// MARK: - 分段控件

struct Seg: View {
    let items: [String]
    @Binding var index: Int
    var onChange: ((Int) -> Void)? = nil

    var body: some View {
        HStack(spacing: 3) {
            ForEach(items.indices, id: \.self) { i in
                let on = i == index
                Text(items[i])
                    .font(.system(size: 13.5, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? C.textPrimary : C.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(on ? C.segmentThumb : Color.clear)
                            .shadow(color: on ? Color.black.opacity(0.07) : .clear,
                                    radius: 1.5, y: 0.6)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard i != index else { return }
                        index = i
                        onChange?(i)
                    }
            }
        }
        .padding(3)
        .background(C.segmentTrack)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - 空状态 / 载入

struct EmptyHint: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(C.textTertiary)
            Text(text)
                .font(F.caption)
                .foregroundStyle(C.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }
}

/// 骨架块。自绘脉冲（透明度呼吸），不用 Shimmer ——
/// Shimmer 会给子树套一层着色遮罩，卡片和文字块被染成同一个颜色，形状全糊在一起。
struct Bone: View {
    var w: CGFloat? = nil
    var h: CGFloat = 13
    @State private var on = false

    var body: some View {
        RoundedRectangle(cornerRadius: h / 2.5, style: .continuous)
            .fill(C.textTertiary.opacity(0.34))
            .frame(width: w, height: h)
            .opacity(on ? 1 : 0.42)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

// MARK: - 弹窗

/// 通用提示弹窗。放这里而不是某个页面里 ——
/// 概览、设置、拦截三个页面都要用，跟着页面走会到处找不到定义。
struct Popup: Identifiable {
    let title: String
    let body: String
    var id: String { title + body }
}

// MARK: - 页脚

struct FootNote: View {
    let text: String
    var body: some View {
        Text(text)
            .font(F.tiny)
            .foregroundStyle(C.textSecondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 2)
    }
}
