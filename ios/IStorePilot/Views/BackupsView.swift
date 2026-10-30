import SwiftUI

/// 配置备份。
///
/// 备份的是整个 `/etc/config`，不含 Agent 自己的口令文件 —— 把口令打进备份，
/// 「恢复旧配置」就会变成「把口令泄露到旧备份里」。
///
/// 恢复走的是与服务端同一条事务：铺完 60 秒内不确认就自动退回。
/// 之所以必须这样，是因为备份里的 network 会把 LAN 地址一起改掉，
/// 手机拿的还是旧地址，连不回来就是个死局。
struct BackupsView: View {
    @State private var d: J = Api.cached("/api/v1/config/backups") ?? [:]
    @State private var loading = (Api.cached("/api/v1/config/backups") == nil)
    @State private var popup: Popup?
    @State private var askName = false
    @State private var newName = ""
    /// 当前被点开的那一份备份。用一个 confirmationDialog 同时给出「恢复 / 删除」，
    /// 不在行内塞两个按钮 —— 行太窄，两个按钮会互相挤到看不见
    @State private var pick: J?
    @State private var busy = ""

    private var items: [J] { d.objs("items") }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                heroCard
                noteCard
                listCard

                Button {
                    newName = ""
                    askName = true
                } label: {
                    Text("新建备份")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(C.onPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(C.primary)
                        .clipShape(Capsule())
                }
                .padding(.top, 2)

                Text("恢复前会先自动存一份「恢复前自动备份」，所以恢复错了也还能退回来。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(C.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)

                Color.clear.barBottomGap()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .scrollIndicators(.hidden)
        .background(C.appBg)
        .navigationTitle("配置备份")
        .navigationBarTitleDisplayMode(.inline)
        .navBarChrome()
        .task { await load() }
        .alert(item: $popup) { p in
            Alert(title: Text(p.title), message: Text(p.body),
                  dismissButton: .default(Text("好")))
        }
        .alert("新建备份", isPresented: $askName) {
            TextField("例如：改防火墙前", text: $newName)
            Button("备份") { create() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("给这份备份起个名字，方便以后认出来。")
        }
        .confirmationDialog(pick?.str("name") ?? "", isPresented: pickBinding,
                            titleVisibility: .visible) {
            Button("恢复这份配置") { restore() }
            Button("删除", role: .destructive) { remove() }
            Button("取消", role: .cancel) { pick = nil }
        } message: {
            if let it = pick {
                Text("\(it.int("files")) 个文件 · \(F.bytes(Double(it.int("size"))))\n\n"
                     + "恢复会把配置整份覆盖回去（宽带、局域网、防火墙、代理），"
                     + "60 秒内不确认就自动退回。删除则不可找回。")
            }
        }
    }

    private var pickBinding: Binding<Bool> {
        Binding(get: { pick != nil }, set: { if !$0 { pick = nil } })
    }

    // MARK: - 卡片

    private var heroCard: some View {
        // 拆成局部常量：三元 + 字符串插值写在 Text 里会让类型检查爆时间
        let count = d.int("count")
        let countText = loading ? "—" : "\(count) 份"
        let sizeText = count == 0 ? "还没有备份" : "共占用 " + F.bytes(Double(d.int("bytes")))
        return Card {
            VStack(alignment: .leading, spacing: 0) {
                Text("本机备份")
                    .font(.system(size: 12))
                    .foregroundStyle(C.textSecondary)
                Text(countText)
                    .font(.system(size: 27, weight: .medium).monospacedDigit())
                    .foregroundStyle(C.textPrimary)
                    .padding(.top, 6)
                Text(sizeText)
                    .font(.system(size: 12))
                    .foregroundStyle(C.textSecondary)
                    .padding(.top, 4)
            }
        }
    }

    private var noteCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle(text: "备份的是什么")
                Text("整个 /etc/config（58 个文件），存在路由器本地，恢复后立刻生效，不用重启。")
                    .font(.system(size: 12))
                    .foregroundStyle(C.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("不含 Agent 口令与证书 —— 备份文件里不该出现登录凭据。")
                    .font(.system(size: 12))
                    .foregroundStyle(C.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var listCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(text: "备份列表",
                             trailing: items.isEmpty ? "" : "\(items.count) 份")

                if items.isEmpty {
                    Text(loading ? "正在读取…" : "还没有备份。建议在动网络配置之前先建一份。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(C.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 6)
                }

                ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                    if i > 0 { Hairline(inset: 16) }
                    row(it)
                }
            }
        }
    }

    private func row(_ it: J) -> some View {
        Button {
            pick = it
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(it.str("name"))
                        .font(.system(size: 14.5))
                        .foregroundStyle(C.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(F.clock(it.dbl("ts")))
                        Text("·")
                        Text("\(it.int("files")) 个文件")
                        if it.bool("auto") {
                            Text("·")
                            Text("自动")
                        }
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(C.textSecondary)
                }
                Spacer(minLength: 6)
                if busy == it.str("id") {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Text(F.bytes(Double(it.int("size"))))
                        .font(.system(size: 12.5))
                        .foregroundStyle(C.textSecondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(C.textTertiary)
                }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 动作

    private func load() async {
        do {
            let r = try await Api.get("/api/v1/config/backups", cache: false)
            await MainActor.run {
                d = r
                loading = false
            }
        } catch {
            await MainActor.run { loading = false }
        }
    }

    private func create() {
        Task {
            do {
                let r = try await Api.post("/api/v1/config/backups",
                                           ["name": newName.trimmingCharacters(in: .whitespaces)])
                await MainActor.run {
                    if !r.bool("ok") {
                        popup = Popup(title: "没有备份成功", body: r.str("error"))
                        return
                    }
                    popup = Popup(title: "已备份", body: r.str("message"))
                }
                await load()
            } catch {
                await MainActor.run {
                    popup = Popup(title: "没有备份成功", body: errorText(error))
                }
            }
        }
    }

    private func restore() {
        guard let id = pick?.str("id"), !id.isEmpty else { return }
        pick = nil
        busy = id
        Task {
            do {
                let r = try await Api.post("/api/v1/config/backups/restore", ["id": id])
                await MainActor.run {
                    busy = ""
                    if !r.bool("ok") {
                        popup = Popup(title: "没有恢复", body: r.str("error"))
                        return
                    }
                    popup = Popup(title: "已恢复",
                                  body: r.str("message") + "\n\n" + r.str("detail")
                                        + "\n\n请到网络页确认这次改动。")
                }
                await load()
            } catch {
                await MainActor.run {
                    busy = ""
                    popup = Popup(title: "没有恢复", body: errorText(error))
                }
            }
        }
    }

    private func remove() {
        guard let id = pick?.str("id"), !id.isEmpty else { return }
        pick = nil
        Task {
            do {
                let r = try await Api.post("/api/v1/config/backups/delete", ["id": id])
                await MainActor.run {
                    if !r.bool("ok") {
                        popup = Popup(title: "没有删除", body: r.str("error"))
                    }
                }
                await load()
            } catch {
                await MainActor.run {
                    popup = Popup(title: "没有删除", body: errorText(error))
                }
            }
        }
    }

    private func errorText(_ e: Error) -> String {
        (e as? ApiError)?.message ?? e.localizedDescription
    }
}
