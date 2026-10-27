import SwiftUI

struct RootView: View {
    @State private var tab = 0
    @State private var size: CGSize = .zero

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

    var body: some View {
        ZStack(alignment: .bottom) {
            C.appBg.ignoresSafeArea()

            // 五个页面同时存在、靠透明度切换：add/hide 保状态，
            // 切回来不用重新拉数据、滚动位置也不会跳回顶部
            ZStack {
                OverviewView().opacity(tab == 0 ? 1 : 0).allowsHitTesting(tab == 0)
                SecurityView().opacity(tab == 1 ? 1 : 0).allowsHitTesting(tab == 1)
                ProxyView().opacity(tab == 2 ? 1 : 0).allowsHitTesting(tab == 2)
                SettingsView().opacity(tab == 3 ? 1 : 0).allowsHitTesting(tab == 3)
            }
            .contentColumn(axis == .rail ? 980 : 820)

            if axis == .rail {
                NavRail(items: items, tab: $tab)
                    .frame(width: NavRail.width)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    // 竖条要落在系统为侧边栏预留的那 84pt 里。那片区域已经在安全区之外，
                    // 所以只放开 trailing 这一个边 —— 上下安全区照旧生效，内容不会被顶到状态栏下面
                    .ignoresSafeArea(edges: .trailing)
            } else {
                BottomBar(items: items, tab: $tab)
            }
        }
        .environment(\.barAxis, axis)
        .modifier(SizeReporter(size: $size))
        .ignoresSafeArea(.keyboard)
        .animation(.easeInOut(duration: 0.22), value: axis)
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
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(C.divider).frame(height: 0.5)
        }
    }
}

/// 竖排导航。宽画布（Duo 内屏展开、分屏）时替代底部横条。
///
/// 为什么宽度写死 84：系统给侧边竖条预留的安全区就是 84pt，
/// 跟它对齐，手指落点和系统自己的栏位置一致。
/// 图标 + 文字都保留 —— 竖向是"定宽不定高"，纯文字会挤，
/// 纯图标又认不出来，两个叠着放才读得懂。
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
        .background(.regularMaterial)
        .overlay(alignment: .leading) {
            Rectangle().fill(C.divider).frame(width: 0.5)
        }
    }
}
