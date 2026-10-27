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

    /// 竖条要同时满足三件事：**够宽、够高、确实是横向**。
    ///
    /// 只看比例会在两种真实场景上翻车：
    ///   1. 画布接近正方（分屏、悬浮窗、合上后的外屏）—— 比例过线，但根本放不下两栏，
    ///      硬排出来就是两根挤成一条的窄柱；
    ///   2. 手机横过来 —— 852x393 比例过线，高度却只有 393，竖条把内容压成一条。
    /// 所以除了 1.06 的宽高比容差，再加一道绝对尺寸门槛。
    static let minRailWidth: CGFloat = 700
    static let minRailHeight: CGFloat = 500

    /// 宽高比超过 1.06 才算横向：给键盘弹出、动态岛这类把高度挤掉一点的情况留余量，
    /// 否则差 1~2pt 就来回跳形态。
    init(size: CGSize) {
        guard size.width > 0, size.height > 0 else { self = .bottom; return }
        let wide = size.width >= Self.minRailWidth
        let tall = size.height >= Self.minRailHeight
        let landscape = size.width > size.height * 1.06
        self = (wide && tall && landscape) ? .rail : .bottom
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
    /// 页面内容末尾的一点呼吸感。
    ///
    /// 以前这个值要 78pt：底部横条是浮在内容上方的，不手动让位就会压住最后一张卡。
    /// 现在横条参与布局（VStack 的第二个孩子），高度系统已经扣掉了，
    /// 这里只剩「最后一张卡别贴着栏」这点作用，所以统一成 18pt。
    func barBottomGap(_ height: CGFloat = 18) -> some View {
        modifier(BarGap(height: height))
    }

    /// 宽画布上把内容收成一列并居中。
    /// 951pt 的内屏如果让卡片铺满，一张卡就横跨半个屏幕，行读起来会散。
    func contentColumn(_ maxWidth: CGFloat = 820) -> some View {
        frame(maxWidth: maxWidth).frame(maxWidth: .infinity)
    }
}

private struct BarGap: ViewModifier {
    let height: CGFloat

    func body(content: Content) -> some View {
        Color.clear.frame(height: height)
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

/// 量窗口尺寸和安全区。
///
/// 不用 `GeometryReader` 包在外层：那会把窗口安全区吃成 0，
/// 背景就没法 `ignoresSafeArea` 铺到屏幕边缘了。这里塞进 **background**，
/// 既不参与外层布局，又能读到容器的安全区。
///
/// 为什么要 insets：竖条形态下（折叠屏横过来）系统经常给 0 的上边距，
/// 因为状态栏挪到了右侧那一列。导航栏和二级页的返回箭头就会被压到屏幕最上沿。
/// 拿到 insets 才能判断「该不该自己补一条呼吸位」。
struct MetricsReader: ViewModifier {
    @Binding var size: CGSize
    @Binding var insets: EdgeInsets

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { g in
                // 注意：**不要**给这个 GeometryReader 加 ignoresSafeArea。
                // 加了之后它自己就成了「忽略安全区的视图」，proxy 报出来的
                // safeAreaInsets 全是 0 —— 拿 0 去判断「系统给没给上边距」永远为真。
                // 不忽略时 proxy 拿到的是容器的安全区（真值），size 是安全区内尺寸，
                // 整块画布 = 两者相加。
                Color.clear
                    .onAppear { read(g) }
                    .onChange(of: g.size) { _ in read(g) }
            }
        }
    }

    private func read(_ g: GeometryProxy) {
        let i = g.safeAreaInsets
        if insets != i {
            insets = i
        }
        let full = CGSize(width: g.size.width + i.leading + i.trailing,
                          height: g.size.height + i.top + i.bottom)
        if size != full {
            size = full
        }
    }
}
