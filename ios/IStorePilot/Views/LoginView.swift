import SwiftUI

/// 登录表单的值。
///
/// 单独放一个 `ObservableObject`、并且**让 LoginView 的 body 不读它的字段**：
/// 输入框每敲一个字都会改动 `addr` / `pwd`，如果这两个值挂在 LoginView 的
/// `@State` 上，整页（渐变按钮、带阴影的图标、卡片）都会跟着重算一遍 ——
/// 在折叠屏 120Hz 上就是肉眼可见的输入卡顿。现在只有下面那两个小字段视图
/// 和按钮会刷新。
final class LoginForm: ObservableObject {
    @Published var addr: String = Session.base
    @Published var pwd: String = ""
}

struct LoginView: View {
    @EnvironmentObject private var app: AppState

    @StateObject private var form = LoginForm()
    @State private var busy = false
    @State private var err = ""
    @State private var okTip = ""

    var body: some View {
        ZStack {
            C.appBg.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 22) {
                    LoginHeader()

                    Card(padding: 20) {
                        VStack(spacing: 0) {
                            AddrField(form: form)
                            Hairline(inset: 0)
                            PwdField(form: form)
                        }
                    }

                    if !err.isEmpty {
                        tip(err, color: C.danger, icon: "exclamationmark.triangle.fill")
                    } else if !okTip.isEmpty {
                        tip(okTip, color: C.ok, icon: "checkmark.circle.fill")
                    }

                    SubmitButton(form: form, busy: busy, action: { submit() })

                    Button(action: probe) {
                        Text("先测一下地址通不通")
                            .font(F.caption)
                            .foregroundStyle(C.primary)
                    }
                    .disabled(busy)

                    Text("地址只写 \(Session.defaultHost) 也行，http:// 会自己补。\n口令与路由器后台、SSH 是同一个。")
                        .font(F.tiny)
                        .foregroundStyle(C.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.top, 26)
                .padding(.bottom, 30)
                // 登录表单不跟着画布一起变宽：输入框拉成 900pt 一条很怪，
                // 收成手机上那个比例、横向居中
                .contentColumn(480)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear {
            #if DEBUG
            // 截图用：带着口令启动就直接登录，走的是和用户一样的登录链路
            let p = DebugRoute.pass
            if !p.isEmpty && !busy { submit(p) }
            #endif
        }
    }

    private func tip(_ text: String, color: Color, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
            Text(text)
                .font(F.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - 动作

    private func probe() {
        busy = true
        err = ""; okTip = ""
        let target = Session.normalize(form.addr)
        Task {
            do {
                let j = try await Api.ping(base: target)
                await MainActor.run {
                    busy = false
                    form.addr = target
                    okTip = "通了：\(j.str("hostname", "路由器"))· v\(j.str("version", "?"))"
                }
            } catch {
                await MainActor.run {
                    busy = false
                    err = error.localizedDescription
                }
            }
        }
    }

    private func submit(_ forced: String? = nil) {
        busy = true
        err = ""; okTip = ""
        let target = Session.normalize(form.addr)
        let password = forced ?? form.pwd

        Task {
            do {
                let j = try await Api.login(base: target, password: password)
                let token = j.str("token")
                guard !token.isEmpty else {
                    throw ApiError(code: 0, message: "路由器没有返回令牌")
                }
                await MainActor.run {
                    Session.base = target
                    Session.save(token: token,
                                 expires: j.dbl("expires_at"),
                                 user: "admin")
                    form.pwd = ""
                    busy = false
                    app.signIn()
                }
            } catch {
                await MainActor.run {
                    busy = false
                    err = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - 拆出来的小视图
//
// 拆开的唯一目的是缩小「一次输入要重算多少东西」的范围：
// 拆之前每敲一个字，整页（含 86pt 图标 + 阴影 + 渐变按钮）都重建一次。

private struct LoginHeader: View {
    var body: some View {
        VStack(spacing: 14) {
            Image("AppIconLarge")
                .resizable()
                .frame(width: 86, height: 86)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: Color.black.opacity(0.16), radius: 12, y: 6)

            Text("iStore Pilot")
                .font(.system(size: 27, weight: .bold))
                .foregroundStyle(C.textPrimary)

            Text("把软路由装进口袋")
                .font(F.caption)
                .foregroundStyle(C.textSecondary)
        }
        .padding(.bottom, 6)
    }
}

private struct AddrField: View {
    @ObservedObject var form: LoginForm

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.router")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(C.primary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text("路由器地址")
                    .font(F.tiny)
                    .foregroundStyle(C.textSecondary)

                // 不用 `keyboardType(.URL)`：它会常驻一个 ".com" 键，
                // 而这里要输的是 IP，用默认键盘更快
                TextField(Session.defaultHost, text: $form.addr)
                    .font(F.value)
                    .foregroundStyle(C.textPrimary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.next)
            }
        }
        .padding(.vertical, 13)
    }
}

private struct PwdField: View {
    @ObservedObject var form: LoginForm
    @State private var show = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(C.primary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text("管理口令")
                    .font(F.tiny)
                    .foregroundStyle(C.textSecondary)

                Group {
                    if show {
                        TextField("输入口令", text: $form.pwd)
                    } else {
                        SecureField("输入口令", text: $form.pwd)
                    }
                }
                .font(F.value)
                .foregroundStyle(C.textPrimary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }

            Button {
                show.toggle()
            } label: {
                Image(systemName: show ? "eye.slash" : "eye")
                    .foregroundStyle(C.textSecondary)
            }
        }
        .padding(.vertical, 13)
    }
}

private struct SubmitButton: View {
    @ObservedObject var form: LoginForm
    let busy: Bool
    let action: () -> Void

    /// 只差口令没填：这时候按钮该是「还不能按」的样子
    private var waiting: Bool { form.pwd.isEmpty && !busy }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy { ProgressView().tint(C.heroFg) }
                Text(busy ? "连接中…" : "连接")
                    .font(.system(size: 16.5, weight: .semibold))
                    // 深绿渐变上永远是白字；只有「还没填口令」那种灰底才换深色字。
                    // 原来是整颗按钮 opacity 0.6 —— 浅色模式下白字被冲成近白底，
                    // 等于看不见
                    .foregroundStyle(waiting ? C.textSecondary : C.heroFg)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background {
                if waiting {
                    C.surfaceHi
                } else {
                    LinearGradient(colors: [C.heroFrom, C.heroTo],
                                   startPoint: .leading, endPoint: .trailing)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .disabled(busy || form.pwd.isEmpty)
    }
}
