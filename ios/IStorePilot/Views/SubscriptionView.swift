import SwiftUI

struct SubscriptionView: View {
    @State private var items: [J] = []
    @State private var backend = ""
    @State private var loading = true
    @State private var err = ""
    @State private var editing: J?            // 非 nil 时弹编辑框
    @State private var adding = false
    @State private var menuFor: J?            // 长按/点击行尾的操作菜单
    @State private var working = ""

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if loading {
                    ListGroup {
                        ForEach(0..<3, id: \.self) { _ in
                            VStack(alignment: .leading, spacing: 6) {
                                Bone(w: 110, h: 12); Bone(w: 200, h: 9)
                            }
                            .padding(16)
                        }
                    }
                } else if items.isEmpty {
                    Card { EmptyHint(icon: "link.badge.plus", text: "还没有订阅，点右上角加一个") }
                } else {
                    ListGroup {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                            subRow(it)
                            if i < items.count - 1 { Hairline(inset: 16) }
                        }
                    }
                }

                if !err.isEmpty {
                    Text(err).font(F.tiny).foregroundStyle(C.danger)
                }

                Text("订阅地址来自路由器上的 uci 配置，「更新节点」会让后端重新拉一遍订阅，需要几十秒。")
                    .font(F.tiny)
                    .foregroundStyle(C.textSecondary)
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
        .background(C.appBg)
        .navigationTitle("订阅管理")
        .navigationBarTitleDisplayMode(.inline)
        .navBarChrome()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editing = nil
                    adding = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $adding) {
            SubEditor(backend: backend, item: nil) { await load() }
        }
        .sheet(item: Binding(
            get: { editing.map { SBox(j: $0) } },
            set: { editing = $0?.j }
        )) { box in
            SubEditor(backend: backend, item: box.j) { await load() }
        }
        .confirmationDialog("订阅操作", isPresented: Binding(
            get: { menuFor != nil },
            set: { if !$0 { menuFor = nil } }
        ), presenting: menuFor) { it in
            Button("更新节点") { act("refresh", it) }
            Button("修改名称 / 地址") { editing = it; menuFor = nil }
            Button("删除订阅", role: .destructive) { act("delete", it) }
            Button("取消", role: .cancel) { menuFor = nil }
        } message: { it in
            Text(it.str("name"))
        }
    }

    // MARK: - 行

    private func subRow(_ it: J) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "link")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(it.bool("enabled") ? C.primary : C.textTertiary)
                .frame(width: 30, height: 30)
                .background((it.bool("enabled") ? C.primary : C.textTertiary).opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(it.str("name", "未命名"))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(C.textPrimary)
                        .lineLimit(1)
                    if !it.bool("enabled") { Pill(text: "已停用", color: C.textSecondary) }
                    if working == it.str("id") { ProgressView().scaleEffect(0.6) }
                }
                Text(it.str("url_masked", it.str("url")))
                    .font(F.num(11, .regular))
                    .foregroundStyle(C.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            Button {
                menuFor = it
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(C.textSecondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    // MARK: - 动作

    private func load() async {
        do {
            var j = try await Api.get("/api/v1/proxy/subscriptions")
            var list = j.objs("items")
            // 后端会同时返回 OpenClash 和 Passwall 两套；只显示当前在跑的那个
            if let cur = try? await Api.get("/api/v1/proxy") {
                let active = cur.str("active")
                if !active.isEmpty {
                    backend = active
                    let only = list.filter { $0.str("backend") == active }
                    if !only.isEmpty { list = only }
                }
            }
            items = list
            loading = false
            err = ""
        } catch {
            loading = false
            err = error.localizedDescription
        }
    }

    private func act(_ action: String, _ it: J) {
        menuFor = nil
        working = it.str("id")
        Task {
            var body: J = ["action": action, "backend": it.str("backend"), "id": it.str("id")]
            if action == "delete" || action == "refresh" { body["sec"] = it.str("id") }
            _ = try? await Api.post("/api/v1/proxy/subscriptions", body, slow: true)
            await load()
            await MainActor.run { working = "" }
        }
    }
}

private struct SBox: Identifiable {
    let j: J
    var id: String { j.str("id") }
}

// MARK: - 新增 / 编辑

struct SubEditor: View {
    let backend: String
    let item: J?
    let onDone: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var enabled = true
    @State private var busy = false
    @State private var err = ""

    private var isEdit: Bool { item != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Card {
                        VStack(spacing: 0) {
                            field("名称", "给订阅起个名字", $name, url: false)
                            Hairline(inset: 0)
                            field("订阅地址", "https://…", $url, url: true)
                            Hairline(inset: 0)
                            Toggle(isOn: $enabled) {
                                Text("启用").font(F.body).foregroundStyle(C.textPrimary)
                            }
                            .tint(C.primary)
                            .padding(.vertical, 10)
                        }
                    }

                    if !err.isEmpty {
                        Text(err).font(F.tiny).foregroundStyle(C.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button(action: save) {
                        HStack {
                            if busy { ProgressView().tint(C.onPrimary) }
                            Text(isEdit ? "保存" : "添加").font(.system(size: 16, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(C.onPrimary)
                        .background(LinearGradient(colors: [C.heroFrom, C.heroTo],
                                                   startPoint: .leading, endPoint: .trailing))
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                    }
                    .disabled(busy || url.isEmpty)

                    Text("地址必须以 http:// 或 https:// 开头。添加后还要点一次「更新节点」才会拉到内容。")
                        .font(F.tiny).foregroundStyle(C.textSecondary)
                }
                .padding(16)
            }
            .background(C.appBg)
            .navigationTitle(isEdit ? "修改订阅" : "添加订阅")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear {
                if let item {
                    name = item.str("name")
                    url = item.str("url")
                    enabled = item.bool("enabled")
                }
            }
        }
    }

    private func field(_ title: String, _ ph: String,
                       _ text: Binding<String>, url: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(F.tiny).foregroundStyle(C.textSecondary)
            TextField(ph, text: text)
                .font(F.value)
                .keyboardType(url ? .URL : .default)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        .padding(.vertical, 10)
    }

    private func save() {
        busy = true
        err = ""
        Task {
            var body: J = [
                "action": isEdit ? "update" : "add",
                "backend": item?.str("backend", backend) ?? backend,
                "name": name.isEmpty ? "未命名订阅" : name,
                "url": url,
                "enabled": enabled,
            ]
            if isEdit { body["id"] = item?.str("id") ?? ""; body["sec"] = item?.str("id") ?? "" }

            do {
                let r = try await Api.post("/api/v1/proxy/subscriptions", body, slow: true)
                if r.bool("ok") || r["ok"] == nil {
                    await onDone()
                    await MainActor.run { dismiss() }
                } else {
                    throw ApiError(code: 0, message: r.str("error", "保存失败"))
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
