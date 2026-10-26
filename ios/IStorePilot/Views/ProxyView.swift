import SwiftUI

struct ProxyView: View {
    @State private var d: J = Api.cached("/api/v1/proxy") ?? [:]
    @State private var groups: [J] = Api.cached("/api/v1/proxy/groups").map { $0.objs("groups") } ?? []
    @State private var cfg: J = Api.cached("/api/v1/proxy/configs") ?? [:]
    @State private var loading = true
    @State private var err = ""
    @State private var pickGroup: J?
    @State private var showCfg = false
    @State private var goSubs = false
    @State private var busy = false

    private let tick = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    private var backend: J { d.objs("backends").first ?? [:] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    hero
                    // 宽屏：节点在左（要点要展开，给足宽度），配置与订阅在右。
                    // 窄屏时右栏排回前面 —— 改配置是件必须做在前面的事
                    DuoColumns(rightFirstInNarrow: true) {
                        if loading {
                            Card { VStack(alignment: .leading, spacing: 10) {
                                Bone(w: 90, h: 15); Bone(h: 10); Bone(h: 10)
                            } }
                        } else if groups.isEmpty {
                            Card { EmptyHint(icon: "network.slash", text: "代理没有在运行，或者没有读到节点") }
                        } else {
                            groupList
                        }
                    } right: {
                        cfgCard
                    }
                    if !err.isEmpty {
                        Text(err).font(F.tiny).foregroundStyle(C.danger)
                    }
                    Color.clear.barBottomGap()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .scrollIndicators(.hidden)
            .background(C.appBg)
            .navigationTitle("代理")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(isPresented: $goSubs) { SubscriptionView() }
            .task { await load() }
            .onReceive(tick) { _ in Task { await load() } }
            .sheet(item: Binding(
                get: { pickGroup.map { GBox(j: $0) } },
                set: { pickGroup = $0?.j }
            )) { box in
                NodePicker(group: box.j) { name in
                    await selectNode(group: box.j.str("name"), node: name)
                }
            }
            .sheet(isPresented: $showCfg) {
                ConfigPicker(current: cfg.str("current"),
                             items: cfg.objs("configs")) { path in
                    await switchConfig(path)
                }
            }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        let b = backend
        let running = b.bool("running")
        let active = d.str("active", "—")

        return Hero {
            VStack(alignment: .leading, spacing: 11) {
                HStack(spacing: 8) {
                    Text(b.str("label", active))
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(C.heroFg)
                    Circle().fill(running ? Color(hex: 0x5FE7C4) : Color(hex: 0xFF7A6B))
                        .frame(width: 7, height: 7)
                    Spacer()
                    Text(running ? "运行中" : "已停止")
                        .font(F.tiny)
                        .foregroundStyle(C.heroFgSoft)
                }
                Text("\(b.int("node_count")) 个节点 · 内核 \(b.str("engine", "—")) · \(b.str("mode", "—"))")
                    .font(F.tiny)
                    .foregroundStyle(C.heroFgSoft)

                if d.bool("mutual_exclusive") {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                        Text("OpenClash 与 PassWall 同时只能跑一个")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(C.heroFgSoft)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Color.white.opacity(0.13))
                    .clipShape(Capsule())
                }
            }
        }
    }

    // MARK: - 配置与节点

    private var cfgCard: some View {
        let cur = cfg.str("current")
        let curName = (cur as NSString).lastPathComponent.replacingOccurrences(of: ".yaml", with: "")

        return Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "配置与节点")

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("当前配置")
                            .font(.system(size: 10.5))
                            .foregroundStyle(C.textSecondary)
                        Text(curName.isEmpty ? "未选择" : curName)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(C.textPrimary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        showCfg = true
                    } label: {
                        Text("切换")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(C.primary)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(C.accentSoft)
                            .clipShape(Capsule())
                    }
                    .disabled(busy)
                }
                .padding(.vertical, 10).padding(.horizontal, 13)
                .background(C.surfaceSunken)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                Button {
                    goSubs = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "link")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(C.primary)
                            .frame(width: 26, height: 26)
                            .background(C.accentSoft)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Text("订阅管理")
                            .font(F.body)
                            .foregroundStyle(C.textPrimary)
                        Spacer()
                        Text("更新 / 添加 / 删除")
                            .font(F.tiny)
                            .foregroundStyle(C.textSecondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(C.textTertiary)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 分组

    private var groupList: some View {
        // 「自动选择」必须永远排最上面：它是日常最常点的那个
        let sorted = groups.sorted { a, b in
            let aa = isAuto(a.str("name")), bb = isAuto(b.str("name"))
            if aa != bb { return aa }
            return false
        }

        return ForEach(Array(sorted.enumerated()), id: \.offset) { _, g in
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(g.str("name"))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(C.textPrimary)
                        Pill(text: g.str("type"), color: C.textSecondary)
                        Spacer()
                        if g.int("now_delay") > 0 {
                            Text("\(g.int("now_delay"))ms")
                                .font(F.num(12, .medium))
                                .foregroundStyle(delayColor(g.int("now_delay")))
                        }
                    }

                    Button {
                        pickGroup = g
                    } label: {
                        HStack(spacing: 8) {
                            Text(g.str("now", "—"))
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(C.primary)
                                .lineLimit(1)
                            Spacer()
                            Text("\(g.objs("members").count) 个节点")
                                .font(F.tiny)
                                .foregroundStyle(C.textSecondary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(C.textTertiary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(C.surfaceSunken)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func isAuto(_ s: String) -> Bool {
        let k = s.lowercased()
        return k.contains("自动") || k.contains("auto") || k.contains("urltest")
            || k.contains("fallback") || k == "global"
    }

    private func delayColor(_ ms: Int) -> Color {
        if ms <= 0 { return C.textTertiary }
        if ms < 200 { return C.ok }
        if ms < 500 { return C.warn }
        return C.danger
    }

    // MARK: - 动作

    private func load() async {
        do {
            let p = try await Api.get("/api/v1/proxy")
            let g = try await Api.get("/api/v1/proxy/groups")
            d = p
            groups = (g["groups"] as? [Any])?.compactMap { $0 as? J } ?? []
            if let c = try? await Api.get("/api/v1/proxy/configs") { cfg = c }
            loading = false
            err = ""
        } catch {
            loading = false
            if groups.isEmpty { err = error.localizedDescription }
        }
    }

    private func selectNode(group: String, node: String) async {
        busy = true
        defer { busy = false }
        _ = try? await Api.post("/api/v1/proxy/select", ["group": group, "name": node])
        await load()
    }

    private func switchConfig(_ path: String) async {
        busy = true
        defer { busy = false }
        // 切配置文件 = uci set + commit + 重启内核，会断网十几秒
        _ = try? await Api.post("/api/v1/proxy/config", ["path": path], slow: true)
        await load()
    }
}

/// Sheet(item:) 需要 Identifiable，字典本身不满足，包一层
private struct GBox: Identifiable {
    let j: J
    var id: String { j.str("name") }
}

// MARK: - 节点选择

struct NodePicker: View {
    let group: J
    let onPick: (String) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var testing = false
    @State private var members: [J]

    init(group: J, onPick: @escaping (String) async -> Void) {
        self.group = group
        self.onPick = onPick
        _members = State(initialValue: group.objs("members"))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                ListGroup {
                    ForEach(Array(members.enumerated()), id: \.offset) { i, m in
                        let on = m.str("name") == group.str("now")
                        Button {
                            Task {
                                await onPick(m.str("name"))
                                dismiss()
                            }
                        } label: {
                            HStack(spacing: 11) {
                                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 16))
                                    .foregroundStyle(on ? C.primary : C.textTertiary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.str("name"))
                                        .font(.system(size: 14.5, weight: on ? .semibold : .regular))
                                        .foregroundStyle(C.textPrimary)
                                        .lineLimit(1)
                                    Text(m.str("type"))
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(C.textSecondary)
                                }
                                Spacer()
                                if m.int("delay") > 0 {
                                    Text("\(m.int("delay"))ms")
                                        .font(F.num(11.5, .medium))
                                        .foregroundStyle(m.int("delay") < 300 ? C.ok : C.warn)
                                }
                            }
                            .padding(.horizontal, 15).padding(.vertical, 11)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if i < members.count - 1 { Hairline(inset: 42) }
                    }
                }
                .padding(16)
            }
            .background(C.appBg)
            .navigationTitle(group.str("name"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        testAll()
                    } label: {
                        if testing { ProgressView() } else { Text("测速") }
                    }
                    .disabled(testing)
                }
            }
        }
    }

    private func testAll() {
        testing = true
        Task {
            // 组测速：Mihomo 的 /group/{name}/delay 一次打完整组
            if let r = try? await Api.post("/api/v1/proxy/delays",
                                           ["group": group.str("name")], slow: true) {
                let map = r.objs("delays")
                if !map.isEmpty {
                    await MainActor.run {
                        members = members.map { m in
                            var x = m
                            if let d = map.first(where: { $0.str("name") == m.str("name") }) {
                                x["delay"] = d.int("delay")
                            }
                            return x
                        }
                    }
                }
            }
            await MainActor.run { testing = false }
        }
    }
}

// MARK: - 配置切换

struct ConfigPicker: View {
    let current: String
    let items: [J]
    let onPick: (String) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var working = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Text("OpenClash 同时只会启用一个配置文件，切换会重启内核，断网十几秒。")
                        .font(F.tiny)
                        .foregroundStyle(C.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)

                    ListGroup {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, c in
                            let on = c.str("path") == current
                            Button {
                                working = true
                                Task {
                                    await onPick(c.str("path"))
                                    working = false
                                    dismiss()
                                }
                            } label: {
                                HStack(spacing: 11) {
                                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 16))
                                        .foregroundStyle(on ? C.primary : C.textTertiary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(c.str("name"))
                                            .font(.system(size: 14.5, weight: on ? .semibold : .regular))
                                            .foregroundStyle(C.textPrimary)
                                        Text(F.bytes(c.dbl("size")) + " · " + F.clock(c.dbl("mtime")))
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(C.textSecondary)
                                    }
                                    Spacer()
                                    if on { Pill(text: "使用中", color: C.primary) }
                                }
                                .padding(.horizontal, 15).padding(.vertical, 11)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(working)
                            if i < items.count - 1 { Hairline(inset: 42) }
                        }
                    }
                }
                .padding(16)
            }
            .background(C.appBg)
            .navigationTitle("选择配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            .overlay {
                if working {
                    ZStack {
                        Color.black.opacity(0.16).ignoresSafeArea()
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("正在重启内核…").font(F.caption)
                        }
                        .padding(22)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
            }
        }
    }
}
