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
        if app.loggedIn {
            RootView()
                .transition(.opacity)
        } else {
            LoginView()
                .transition(.opacity)
        }
    }
}
