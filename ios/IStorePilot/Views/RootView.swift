import SwiftUI

struct RootView: View {
    @State private var tab = 0
    @State private var size: CGSize = .zero
    @State private var insets: EdgeInsets = EdgeInsets()

    // 和 Android 端一致：四个页签。
    // 「网络」不再是独立页签 —— 它大部分是只读信息，真正要动手的只有宽带配置和重拨，
    // 都收进了概览 →「网络设置」的二级页（WanView）。
    private let items: [(String, String)] = [
        ("概览", "gauge.medium"),
        ("设备", "desktopcomputer"),
        ("代理", "network"),
        ("设置", "gearshape"),
    ]

    private var axis: BarAxis { BarAxis(size: size) }

    /// 竖条形态下系统经常不给上边距（折叠屏横过来时状态栏跑到右侧那一列去了），
    /// 导航栏和二级页的返回箭头会被压到屏幕最上沿、贴着圆角。补一小条呼吸位。
    private var topGuard: CGFloat {
        axis == .rail && insets.top < 8 ? 10 : 0
    }

    var body: some View {
        Group {
            if axis == .rail {
                HStack(spacing: 0) {
                    tabs
                    NavRail(items: items, tab: $tab)
                        .frame(width: NavRail.width)
                }
            } else {
                VStack(spacing: 0) {
                    tabs
                    // 材料要铺到屏幕最底下（Home 指示条那一条），
                    // 图标本身留在安全区里 —— ignoresSafeAreaEdges 只作用于背景
                    BottomBar(items: items, tab: $tab)
                        .background(.regularMaterial, ignoresSafeAreaEdges: .bottom)
                }
            }
        }
        .padding(.top, topGuard)
        .background(C.appBg.ignoresSafeArea())
        .environment(\.barAxis, axis)
        .modifier(MetricsReader(size: $size, insets: $insets))
        .ignoresSafeArea(.keyboard)
        .animation(.easeInOut(duration: 0.22), value: axis)
    }

    /// 四个页面同时存在、靠透明度切换：add/hide 保状态，
    /// 切回来不用重新拉数据、滚动位置也不会跳回顶部
    private var tabs: some View {
        ZStack {
            OverviewView().opacity(tab == 0 ? 1 : 0).allowsHitTesting(tab == 0)
            SecurityView().opacity(tab == 1 ? 1 : 0).allowsHitTesting(tab == 1)
            ProxyView().opacity(tab == 2 ? 1 : 0).allowsHitTesting(tab == 2)
            SettingsView().opacity(tab == 3 ? 1 : 0).allowsHitTesting(tab == 3)
        }
        .contentColumn(axis == .rail ? 980 : 820)
    }
}

/// 自绘底部导航。
/// 不用系统 TabView：系统栏的灰线、字号、内边距都改不动，
/// 而且选中态做不出"胶囊浮起来"的效果。
private struct BottomBar: View {
    let items: [(String, String)]
    @Binding var tab: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                let on = i == tab
                Button {
                    guard i != tab else { return }
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { tab = i }
                } label: {
                    VStack(spacing: 3.5) {
                        Image(systemName: items[i].1)
                            .font(.system(size: 17, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? C.primary : C.iconOff)
                        Text(items[i].0)
                            .font(.system(size: 10.5, weight: on ? .semibold : .regular))
                            .foregroundStyle(on ? C.primary : C.iconOff)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .fill(C.accentSoft)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 7)
        .padding(.bottom, 4)
        .overlay(alignment: .top) {
            Rectangle().fill(C.divider).frame(height: 0.5)
        }
    }
}

/// 竖排导航。宽画布（Duo 内屏展开、分屏）时替代底部横条。
///
/// 宽度 84 跟系统给侧边竖条预留的宽度对齐，手指落点和系统自己的栏一致。
/// 但**不要**把它塞进系统那条安全区里：折叠屏横过来时，系统的状态栏
/// （时间 / 信号 / 电池）正好画在那一列上，塞进去会和导航项叠在一起。
/// 现在它站在安全区之内、紧挨着那条留白，两边互不打扰。
private struct NavRail: View {
    let items: [(String, String)]
    @Binding var tab: Int

    static let width: CGFloat = 84

    var body: some View {
        VStack(spacing: 4) {
            Spacer(minLength: 0)
            ForEach(items.indices, id: \.self) { i in
                let on = i == tab
                Button {
                    guard i != tab else { return }
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { tab = i }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: items[i].1)
                            .font(.system(size: 19, weight: on ? .semibold : .regular))
                        Text(items[i].0)
                            .font(.system(size: 10, weight: on ? .semibold : .regular))
                    }
                    .foregroundStyle(on ? C.primary : C.iconOff)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(C.accentSoft)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(C.surface)
        .overlay(alignment: .leading) {
            Rectangle().fill(C.divider).frame(width: 0.5)
        }
    }
}
