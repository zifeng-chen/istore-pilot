import SwiftUI

/// 导航条的形态。
///
/// iPhone Duo 合上时是一块宽大于高的画布，系统在这种形态下把导航放到**侧边**，
/// 并在那一侧的安全区里预留 84pt。我们没有用系统 TabView，所以这条要自己判。
///
/// 判断依据刻意不用 `interfaceOrientation`，也不用机型/idiom：
/// Duo 的内屏**不遵守** App 声明的支持方向，方向在这个设备上不代表任何事。
/// 唯一可靠的问法是「现在这块地方是不是宽大于高」——
/// 这也正是读屏文档给出的替换写法。
enum BarAxis: Equatable {
    case bottom
    case rail

    /// 宽高比超过 1.06 才算横向：给键盘弹出、动态岛这类把高度挤掉一点的情况留余量，
    /// 否则差 1~2pt 就来回跳形态。
    init(size: CGSize) {
        guard size.width > 0, size.height > 0 else { self = .bottom; return }
        self = size.width > size.height * 1.06 ? .rail : .bottom
    }
}

private struct BarAxisKey: EnvironmentKey {
    static let defaultValue: BarAxis = .bottom
}

extension EnvironmentValues {
    var barAxis: BarAxis {
        get { self[BarAxisKey.self] }
        set { self[BarAxisKey.self] = newValue }
    }
}

extension View {
    /// 页面内容底部给导航条让位。
    /// 横条要 78pt；竖条不在底部，留一点点呼吸感就够，否则一屏少两行。
    func barBottomGap(_ height: CGFloat = 78) -> some View {
        modifier(BarGap(height: height))
    }

    /// 宽画布上把内容收成一列并居中。
    /// 951pt 的内屏如果让卡片铺满，一张卡就横跨半个屏幕，行读起来会散。
    func contentColumn(_ maxWidth: CGFloat = 820) -> some View {
        frame(maxWidth: maxWidth).frame(maxWidth: .infinity)
    }
}

private struct BarGap: ViewModifier {
    @Environment(\.barAxis) private var axis
    let height: CGFloat

    func body(content: Content) -> some View {
        Color.clear.frame(height: axis == .rail ? 18 : height)
    }
}

/// 宽画布的两栏容器。
///
/// Duo 展开后可用宽度接近 870pt。原来只是把单列的卡片拉到 `contentColumn(820)`：
/// 结果是一张卡横跨 820pt，一行字从左读到右要转头，卡片高度却没变 —— 看起来
/// 就是「手机界面被拉长了」，不是为这块屏幕设计的版式。
///
/// 现在按屏幕做两件事：
///   1. 窄屏：完全保持原来的单列顺序，一行代码都不用改行为
///   2. 宽屏：左栏放「要读/要点的主内容」，右栏 372pt 放次级卡片；
///      两栏各自滚动？不 —— 仍然整体滚动，否则左右会滚不同步，看着晕
///
/// `rightFirstInNarrow` 是给「配置在左、节点在右」这类页面用的：
/// 宽屏右栏是配置卡，窄屏时它得排回前面，否则用户要滑到底才能改配置。
struct DuoColumns<Left: View, Right: View>: View {
    @Environment(\.barAxis) private var axis

    /// 右栏宽度。372 是「一行放得下 20 个汉字 + 一个数值」的下限，
    /// 再窄就会出现键值行的值被压到第二行
    private let rightWidth: CGFloat
    private let rightFirstInNarrow: Bool
    private let leftContent: Left
    private let rightContent: Right

    /// 显式写 init 而不是靠成员逐个初始化：`@ViewBuilder` 要落在**参数**上才保证
    /// 闭包里的 if / 多视图展开成 TupleView，靠属性上的 builder 推导容易在换工具链时翻车
    init(rightWidth: CGFloat = 372,
         rightFirstInNarrow: Bool = false,
         @ViewBuilder left: () -> Left,
         @ViewBuilder right: () -> Right) {
        self.rightWidth = rightWidth
        self.rightFirstInNarrow = rightFirstInNarrow
        self.leftContent = left()
        self.rightContent = right()
    }

    var body: some View {
        if axis == .rail {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 14) { leftContent }
                    .frame(maxWidth: .infinity, alignment: .top)
                VStack(spacing: 14) { rightContent }
                    .frame(width: rightWidth, alignment: .top)
            }
        } else {
            VStack(spacing: 14) {
                if rightFirstInNarrow {
                    rightContent
                    leftContent
                } else {
                    leftContent
                    rightContent
                }
            }
        }
    }
}

/// 读当前可用尺寸。
///
/// 不用 `GeometryReader` 包在外层：那会把窗口安全区吃成 0，
/// 背景就没法 `ignoresSafeArea` 铺到屏幕边缘了（现在的底色是靠这个铺的）。
/// `onGeometryChange` 不参与布局，只上报，正好。
/// iOS 18 以下没有这个 API，但那类设备没有折叠形态，恒为横条也不需要量。
struct SizeReporter: ViewModifier {
    @Binding var size: CGSize

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        } else {
            content
        }
    }
}
