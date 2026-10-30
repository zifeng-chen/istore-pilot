import Charts
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

// MARK: - 导航栏

extension View {
    /// 导航栏统一底色。
    ///
    /// iOS 16 之后导航栏默认是**透明**的：大标题和返回按钮直接漂在页面底色上，
    /// 内容一滚就从标题底下穿过去。视觉上等于「这个页面没有导航栏」，
    /// 二级页尤其明显（返回箭头孤零零挂在左上角，没有任何栏的轮廓）。
    /// 这里给它一个实底，让「栏」重新变成一个可见的容器。
    func navBarChrome() -> some View { modifier(NavChrome()) }
}

private struct NavChrome: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .toolbarBackground(C.appBg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(scheme, for: .navigationBar)
    }
}

// MARK: - 流量曲线

/// hero 卡里的流量趋势（Swift Charts）。
///
/// 之前是手写的 Path 逐点连折线；换成系统框架后，平滑、坐标轴刻度、
/// 渐变填充都由 Swift Charts 负责，不再自己算切线。
/// 视觉参数与安卓 `widget/TrendChart.java` 对齐：左轴 4 个刻度、虚线网格、
/// 下行线带 28%→2% 的渐变，上行线不填充。
struct Sparkline: View {
    let down: [Double]
    let up: [Double]
    var height: CGFloat = 88

    /// 两条线共用一个 x 轴，长度不一致时以长的为准，缺的补 0
    private var n: Int { max(down.count, up.count) }
    private var peak: Double { max(down.max() ?? 0, up.max() ?? 0, 1) }

    var body: some View {
        Chart {
            // 先铺渐变再画线：顺序反了填充会盖住线
            ForEach(0..<n, id: \.self) { i in
                AreaMark(x: .value("t", i), y: .value("bps", value(down, i)))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(
                        colors: [C.primary.opacity(0.28), C.primary.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom))
            }
            ForEach(0..<n, id: \.self) { i in
                LineMark(x: .value("t", i), y: .value("bps", value(up, i)),
                         series: .value("s", "up"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(C.warn)
                    .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }
            ForEach(0..<n, id: \.self) { i in
                LineMark(x: .value("t", i), y: .value("bps", value(down, i)),
                         series: .value("s", "down"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(C.primary)
                    .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }
        }
        .chartLegend(.hidden)
        .chartXAxis(.hidden)
        .chartYScale(domain: 0...peak)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6, dash: [6, 7]))
                    .foregroundStyle(C.heroFg.opacity(0.16))
                AxisValueLabel {
                    if let bps = v.as(Double.self) {
                        Text(F.bpsAxis(bps))
                            .font(.system(size: 9))
                            .foregroundStyle(C.heroFg.opacity(0.55))
                    }
                }
            }
        }
        // 上下各留 3pt，否则最顶/最底的刻度文字会被画布切掉一半
        .chartPlotStyle { $0.padding(.vertical, 3) }
        .frame(height: height)
        // 刚打开时只有 1 个采样点，Chart 画不出一条线，整块只剩网格 ——
        // 看着像坏了。给一句说明，等两个点到位自然消失
        .overlay {
            if n < 2 {
                Text("正在采样…")
                    .font(.system(size: 11))
                    .foregroundStyle(C.heroFg.opacity(0.55))
            }
        }
    }

    private func value(_ a: [Double], _ i: Int) -> Double {
        i < a.count ? a[i] : 0
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
    /// 标题行与下面内容之间画不画一条分割线。
    ///
    /// 默认画：卡片里「标题 + 图标块」和它下面的图表/列表原来只有 10~14pt 间距、
    /// 字号也接近，扫下去分不清哪是头、哪是内容，手指也容易点在边界上。
    /// 一条 12pt 外的细线把两者切开，和分组列表的观感一致。
    var divider: Bool = true
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(spacing: 0) {
            row
            if divider {
                Hairline(inset: 0).padding(.top, 12)
            }
        }
    }

    private var row: some View {
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

/// 分段选择。原来是自己拼 HStack + 圆角滑块 + onTapGesture，
/// 换成系统的 `Picker(.segmented)` —— 外观本来就是同一套（灰槽 + 白滑块），
/// 换来的是系统的按压反馈、VoiceOver 支持、动态字体和选中动画。
/// 保留 `Seg` 这个外壳是为了两个调用方（设备筛选、AGH 日志筛选）不用改。
struct Seg: View {
    let items: [String]
    @Binding var index: Int
    var onChange: ((Int) -> Void)? = nil

    var body: some View {
        Picker("", selection: Binding(
            get: { index },
            set: { v in
                guard v != index else { return }
                index = v
                onChange?(v)
            }
        )) {
            ForEach(items.indices, id: \.self) { i in
                Text(items[i]).tag(i)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
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
