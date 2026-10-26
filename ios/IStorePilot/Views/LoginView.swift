import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var app: AppState

    @State private var addr: String = Session.base
    @State private var pwd: String = ""
    @State private var busy = false
    @State private var err = ""
    @State private var okTip = ""
    @State private var showPwd = false

    @FocusState private var focus: Int?

    var body: some View {
        ZStack {
            C.appBg.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 22) {
                    header

                    Card(padding: 20) {
                        VStack(spacing: 0) {
                            fieldRow(
                                icon: "wifi.router",
                                title: "路由器地址",
                                placeholder: "192.168.100.1:8443",
                                text: $addr,
                                tag: 1,
                                secure: false
                            )
                            Hairline(inset: 0)
                            fieldRow(
                                icon: "lock",
                                title: "管理口令",
                                placeholder: "输入口令",
                                text: $pwd,
                                tag: 2,
                                secure: !showPwd
                            )
                        }
                    }

                    if !err.isEmpty {
                        tip(err, color: C.danger, icon: "exclamationmark.triangle.fill")
                    } else if !okTip.isEmpty {
                        tip(okTip, color: C.ok, icon: "checkmark.circle.fill")
                    }

                    Button(action: submit) {
                        HStack(spacing: 8) {
                            if busy { ProgressView().tint(C.onPrimary) }
                            Text(busy ? "连接中…" : "连接")
                                .font(.system(size: 16.5, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .foregroundStyle(C.onPrimary)
                        .background(
                            LinearGradient(colors: [C.heroFrom, C.heroTo],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .disabled(busy || pwd.isEmpty)
                    .opacity(busy || pwd.isEmpty ? 0.6 : 1)

                    Button(action: probe) {
                        Text("先测一下地址通不通")
                            .font(F.caption)
                            .foregroundStyle(C.primary)
                    }
                    .disabled(busy)

                    Text("地址留空就用出厂默认 \(Session.defaultBase)。\n口令与路由器后台、SSH 是同一个。")
                        .font(F.tiny)
                        .foregroundStyle(C.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.top, 40)
                .padding(.bottom, 30)
                // 登录表单不跟着画布一起变宽：输入框拉成 900pt 一条很怪，
                // 收成手机上那个比例、横向居中
                .contentColumn(480)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear { focus = nil }
    }

    // MARK: - 组件

    private var header: some View {
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

    private func fieldRow(icon: String, title: String, placeholder: String,
                          text: Binding<String>, tag: Int, secure: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(C.primary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(F.tiny)
                    .foregroundStyle(C.textSecondary)

                Group {
                    if secure {
                        SecureField(placeholder, text: text)
                    } else {
                        TextField(placeholder, text: text)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                }
                .font(F.value)
                .foregroundStyle(C.textPrimary)
                .focused($focus, equals: tag)
            }

            if secure {
                Button {
                    showPwd.toggle()
                } label: {
                    Image(systemName: showPwd ? "eye.slash" : "eye")
                        .foregroundStyle(C.textSecondary)
                }
            }
        }
        .padding(.vertical, 13)
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
        Task {
            do {
                let j = try await Api.ping(base: addr)
                await MainActor.run {
                    busy = false
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

    private func submit() {
        focus = nil
        busy = true
        err = ""; okTip = ""
        let target = addr
        let password = pwd

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
                    pwd = ""
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
