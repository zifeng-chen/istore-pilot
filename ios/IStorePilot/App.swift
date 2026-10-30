import SwiftUI

@main
struct IStorePilotApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RootContainer()
                .environmentObject(app)
                .tint(C.primary)
                // 主题模式交给用户选：nil = 跟随系统，1/2 = 强制浅色/深色
                .preferredColorScheme(Appearance.scheme(app.theme))
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
}
#endif

/// 全局登录态。令牌失效时 Api 会回调 onAuthFail，这里统一踢回登录页。
final class AppState: ObservableObject {
    @Published var loggedIn: Bool = Session.isLoggedIn
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
        Group {
            if app.loggedIn {
                RootView()
                    .transition(.opacity)
            } else {
                LoginView()
                    .transition(.opacity)
            }
        }
    }
}
