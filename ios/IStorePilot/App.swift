import SwiftUI

@main
struct IStorePilotApp: App {
    @StateObject private var app = AppState()

    init() {
        // 启动画面还在的时候就把「本地网络」授权问出来。
        // 拖到登录时再问的话，那几个请求会一直挂着等用户点允许，
        // 表现就是按了「连接」没反应、画面像卡住
        LocalNetwork.prime()
    }

    var body: some Scene {
        WindowGroup {
            RootContainer()
                .environmentObject(app)
                .tint(C.primary)
                // 启动页是深绿底，状态栏图标必须是白的 —— 这时候按"暗色"报，
                // 结束后再切回用户选的模式。主题模式交给用户选：nil = 跟随系统
                .preferredColorScheme(app.booting ? .dark : Appearance.scheme(app.theme))
        }
    }
}

#if DEBUG
/// 仅调试：用启动参数直接落到某个页面，方便逐页截图核对版式。
///   xcrun simctl launch <dev> com.izfeng.www.istoreos -tab 1 -sub apps
/// Release 构建里整块不编译，不会影响线上行为。
enum DebugRoute {
    private static func value(_ key: String) -> String? {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-" + key), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    static func int(_ key: String, _ fallback: Int) -> Int {
        Int(value(key) ?? "") ?? fallback
    }

    static var tab: Int { int("tab", 0) }
    static var sub: String { value("sub") ?? "" }
    /// 截图时自动用这个口令登录，走的是和用户完全一样的登录链路
    static var pass: String { value("pass") ?? "" }
    /// 截图用：强制把一级页的标题条显示出来（滚动才出现，模拟器里没法滑）
    static var titlebar: Bool { value("titlebar") == "1" }
}
#endif

/// 全局登录态。令牌失效时 Api 会回调 onAuthFail，这里统一踢回登录页。
final class AppState: ObservableObject {
    @Published var loggedIn: Bool = Session.isLoggedIn
    /// 启动页还盖在上面。安卓那边是独立的 SplashActivity，这边用一个覆盖层，
    /// 好处是启动期的网络探测能直接预热首页缓存
    @Published var booting: Bool = true
    /// 外观模式，改了立刻生效（preferredColorScheme 是环境级的，不用重启）
    @Published var theme: Int = Appearance.get()

    init() {
        Api.onAuthFail = { [weak self] in
            DispatchQueue.main.async { self?.loggedIn = false }
        }
    }

    func setTheme(_ mode: Int) {
        Appearance.apply(mode)
        theme = mode
    }

    func signIn() {
        SnapCache.shared.clear()
        loggedIn = true
    }

    func signOut() {
        Session.logout()
        SnapCache.shared.clear()
        loggedIn = false
    }
}

struct RootContainer: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        ZStack {
            Group {
                if app.loggedIn {
                    RootView()
                        .transition(.opacity)
                } else {
                    LoginView()
                        .transition(.opacity)
                }
            }

            if app.booting {
                SplashView {
                    withAnimation(.easeOut(duration: 0.28)) { app.booting = false }
                }
                .transition(.opacity)
                .zIndex(1)
            }
        }
    }
}

// MARK: - 启动页

/// 三端同一套启动页（对齐安卓 `SplashActivity`）：
/// 深绿渐变底 + 88pt 图标 + 名称 + 一句话 + 一条**真的会走**的进度条。
///
/// 进度分三段，每段都有触发条件，不是定时器凑数：
///   0 → 30%   起来了（固定 380ms）
///   30 → 82%  正在连路由器（拉一次 overview，慢速逼近表示在等）
///   82 → 100% 请求回来（成功/失败）后收尾
///
/// 三条约束和安卓一致：最短停 1.4s、等网络最多 2.6s、探的是首页首屏那个接口
/// （等于顺手预热缓存，进主页不用再转圈）。
struct SplashView: View {
    /// 动画结束后通知外面把覆盖层撤掉
    let onDone: () -> Void

    @State private var progress: CGFloat = 0
    @State private var tip = "正在启动…"
    @State private var logoIn = false
    @State private var nameIn = false
    @State private var tagIn = false

    private static let minStay: Double = 1.4
    private static let netTimeout: Double = 2.6
    private static let finish: Double = 0.24

    var body: some View {
        ZStack {
            LinearGradient(colors: [C.heroFrom, C.heroTo],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Image("AppIconLarge")
                    .resizable()
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .opacity(logoIn ? 1 : 0)
                    .scaleEffect(logoIn ? 1 : 0.86)

                Text("iStore Pilot")
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(C.heroFg)
                    .padding(.top, 18)
                    .opacity(nameIn ? 1 : 0)

                Text("家庭网络，一屏看完")
                    .font(.system(size: 13))
                    .foregroundStyle(C.heroFg.opacity(0.72))
                    .padding(.top, 8)
                    .opacity(tagIn ? 1 : 0)

                VStack(spacing: 10) {
                    // 轨道 96×3，填充块铺满轨道再用 scaleX 表示进度
                    // （不变宽度就没有 layout，120Hz 上也不会掉帧）
                    ZStack(alignment: .leading) {
                        Capsule().fill(C.heroFg.opacity(0.22))
                        Capsule().fill(C.heroFg)
                            .scaleEffect(x: max(0.001, progress), y: 1, anchor: .leading)
                    }
                    .frame(width: 96, height: 3)

                    Text(tip)
                        .font(.system(size: 11.5))
                        .foregroundStyle(C.heroFg.opacity(0.6))
                }
                .padding(.top, 46)
            }
        }
        .task { await run() }
    }

    // MARK: - 流程

    @MainActor
    private func run() async {
        let started = Date()

        // 入场：图标先放大淡入，名字晚 120ms、标语晚 220ms —— 比整块一起出现有节奏
        withAnimation(.easeOut(duration: 0.42)) { logoIn = true }
        try? await Task.sleep(nanoseconds: 120_000_000)
        withAnimation(.easeOut(duration: 0.38)) { nameIn = true }
        try? await Task.sleep(nanoseconds: 100_000_000)
        withAnimation(.easeOut(duration: 0.38)) { tagIn = true }

        await step(0.30, 0.38, "正在启动…")

        if !Session.isLoggedIn {
            // 没登录：不等人，直接走完，交给登录页
            await step(1, 0.52, "准备就绪")
        } else {
            tip = "正在连接路由器…"
            await step(0.82, 0.9, nil)

            let ok = await probe()
            if !ok { tip = "路由器暂时没响应，先进入界面" }
            if ok { tip = "准备就绪" }
            // 先快速走满，再让"满格 + 准备就绪"停到最短时长，
            // 比"到 100% 还写着正在连接"清楚
            await step(1, Self.finish, nil)
        }

        let spent = Date().timeIntervalSince(started)
        if spent < Self.minStay {
            try? await Task.sleep(nanoseconds: UInt64((Self.minStay - spent) * 1e9))
        }
        onDone()
    }

    /// 推进到某个比例。`text` 为 nil 表示保留当前文案。
    @MainActor
    private func step(_ target: CGFloat, _ duration: Double, _ text: String?) async {
        if let text { tip = text }
        withAnimation(.easeOut(duration: duration)) { progress = target }
        try? await Task.sleep(nanoseconds: UInt64(duration * 1e9))
    }

    /// 拉一次首页接口，最多等 2.6 秒。成功失败都不挡住进入界面
    private func probe() async -> Bool {
        await withTaskGroup(of: Bool?.self) { group in
            group.addTask {
                do { _ = try await Api.get("/api/v1/overview"); return true }
                catch { return false }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(Self.netTimeout * 1e9))
                return nil            // 超时：当作没响应
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? false
        }
    }
}
