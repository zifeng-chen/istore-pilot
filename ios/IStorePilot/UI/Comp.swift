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

// MARK: - 文字

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
