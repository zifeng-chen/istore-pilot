import SwiftUI

/// 代理：同时管 OpenClash 与 Passwall。
///
/// 结构照安卓 `ui/ProxyFragment` 复刻，一共 **hero + 两张卡**：
///   1. Hero：谁在跑 / 跑哪份配置 / 多少节点，**代理后端也在这里**（点一行切换）
///   2. 运行模式：分段直接切，下面一句讲清后果
///   3. 配置与节点：当前配置、订阅入口、节点按分组展开（单选点 + 延迟胶囊 + 整组测速）
///
/// 之前是四张卡：hero + 独立的「代理后端」卡 + 运行模式 + 「配置与订阅」+ 独立的「节点」卡。
/// 后端名在 hero 里写一遍、又在下面那张卡里写一遍，等于同一件事说两遍；
/// 配置和节点本来是一条链（换配置 → 重启内核 → 节点重读），拆成两张卡反而要来回看。
struct ProxyView: View {
    @State private var d: J = Api.cached("/api/v1/proxy") ?? [:]
    @State private var groups: [J] = Api.cached("/api/v1/proxy/groups").map { $0.objs("groups") } ?? []
    @State private var cfg: J = Api.cached("/api/v1/proxy/configs") ?? [:]
    @State private var mode: String = ""
    @State private var loading = true
    @State private var err = ""
    @State private var showCfg = false
    @State private var goSubs = false
    @State private var busy = false
    /// 展开了哪些分组。和 Android 一样「只自动展开一次」，之后完全听用户的
    @State private var expanded: Set<String> = []
    @State private var testingGroup = ""
    /// 刚测出来的延迟，优先级高于接口里带的历史值
    @State private var tested: [String: Int] = [:]

    private let tick = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    private var backends: [J] { d.objs("backends") }
    private var active: String { d.str("active", "none") }
    private var backend: J {
        backends.first { $0.str("id") == active } ?? [:]
    }
    private var running: Bool { backend.bool("running") }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    hero
                    // 窄屏顺序 = 安卓：先模式、后配置与节点。
                    // 宽屏把节点摊到左边，配置/模式挤右栏，省一次长滚动
                    DuoColumns(rightFirstInNarrow: true) {
                        if loading {
                            Card {
                                VStack(alignment: .leading, spacing: 10) {
                                    Bone(w: 90, h: 15); Bone(h: 10); Bone(h: 10)
                                }
                            }
                        } else {
                            comboCard
                        }
                    } right: {
                        modeCard
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
            .navBarChrome()
            .navigationDestination(isPresented: $goSubs) { SubscriptionView() }
            .task { await load() }
            .onReceive(tick) { _ in Task { await load() } }
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
        let title: String = running
            ? (cfg.str("current") as NSString).lastPathComponent
                .replacingOccurrences(of: ".yaml", with: "")
            : "直连"
        let nodes = backend.int("node_count")
        let engine = backend.str("engine", "")
        var bits: [String] = []
        if !engine.isEmpty { bits.append(engine) }
        if nodes > 0 { bits.append("\(nodes) 个节点可用") }
        if !mode.isEmpty { bits.append(modeLabel(mode)) }
        if bits.isEmpty { bits.append("两个代理后端都停着，所有流量走直连") }

        return Hero {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Circle().fill(running ? Color(hex: 0x5FE7C4) : Color(hex: 0xFF7A6B))
                        .frame(width: 7, height: 7)
                    Text(running ? "运行中" : "都没在运行")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(C.heroFg)
                    Spacer()
                    Text(backend.str("label", running ? active : "未启用"))
                        .font(F.tiny)
                        .foregroundStyle(C.heroFgSoft)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Color.white.opacity(0.16))
                        .clipShape(Capsule())
                }
                Text(title)
                    .font(F.num(26, .semibold))
                    .foregroundStyle(C.heroFg)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, 10)
                Text(bits.joined(separator: "　·　"))
                    .font(.system(size: 12))
                    .foregroundStyle(C.heroFgSoft)
                    .lineLimit(1)
                    .padding(.top, 4)

                // 后端并进 hero：它是「这一页在管谁」的身份信息，本来就该跟状态放一起
                Text("代理后端 · 点一行切换")
                    .font(.system(size: 11))
                    .foregroundStyle(C.heroFgSoft)
                    .padding(.top, 16)

                VStack(spacing: 0) {
                    ForEach(Array(backends.enumerated()), id: \.offset) { i, b in
                        if i > 0 {
                            // hero 是深绿底，卡片那套 divider 色在上面看不见
                            Rectangle().fill(C.heroFg.opacity(0.16))
                                .frame(height: 0.7)
                                .padding(.top, 2)
                        }
                        backendRow(b)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    /// hero 深色底上的小胶囊：白字 + 半透明底
    private func heroPill(_ text: String, on: Bool) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(C.heroFg.opacity(on ? 1 : 0.78))
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(C.heroFg.opacity(on ? 0.22 : 0.10))
            .clipShape(Capsule())
    }

    private func backendRow(_ b: J) -> some View {
        let on = b.bool("running")
        let installed = b.bool("installed")
        let name = b.str("label", b.str("id"))
        let sub = installed
            ? (b.str("engine").isEmpty ? "" : b.str("engine") + " · ") + "\(b.int("node_count")) 个节点"
            : "未安装"

        return Button {
            guard installed, !on, !busy else { return }
            Task { await switchBackend(b.str("id")) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "power")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(C.heroFg.opacity(on ? 1 : 0.62))
                    .frame(width: 30, height: 30)
                    .background(C.heroFg.opacity(on ? 0.22 : 0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(C.heroFg.opacity(on ? 1 : 0.62))
                    if !sub.isEmpty {
                        Text(sub)
                            .font(.system(size: 11.5))
                            .foregroundStyle(C.heroFg.opacity(0.62))
                    }
                }
                Spacer(minLength: 6)
                heroPill(on ? "运行中" : (installed ? "未运行" : "未安装"), on: on)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!installed || on || busy)
    }

    // MARK: - 运行模式

    private var modeCard: some View {
        let oc = active == "openclash"
        let labels = oc ? ["规则", "全局", "直连"] : ["代理", "直连"]
        let values = oc ? ["rule", "global", "direct"] : ["proxy", "disable"]
        let selected = values.firstIndex(of: mode) ?? 0

        return Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHead(icon: "bolt", title: "运行模式", sub: "改完立即生效") {
                    Text(modeLabel(mode))
                        .font(F.num(13.5, .medium))
                        .foregroundStyle(C.primary)
                }

                // 尺寸照安卓 Ui.segmented：外槽 34 高、圆角 10、内块圆角 8、字号 13.5
                HStack(spacing: 0) {
                    ForEach(Array(labels.enumerated()), id: \.offset) { i, t in
                        let on = i == selected
                        Button {
                            guard !busy, values[i] != mode else { return }
                            Task { await setMode(values[i]) }
                        } label: {
                            Text(t)
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundStyle(on ? C.textPrimary : C.textSecondary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 28)
                                .background {
                                    if on {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(C.segmentThumb)
                                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .strokeBorder(C.glassStroke, lineWidth: 0.7))
                                    }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(C.segmentTrack)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Text(modeHint(mode))
                    .font(.system(size: 11.5))
                    .foregroundStyle(C.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func modeLabel(_ m: String) -> String {
        switch m {
        case "rule": return "规则模式"
        case "global": return "全局模式"
        case "direct", "disable": return "直连模式"
        case "proxy": return "代理模式"
        default: return m.isEmpty ? "—" : m
        }
    }

    private func modeHint(_ m: String) -> String {
        if active == "openclash" {
            switch m {
            case "rule": return "按规则分流：命中的走节点，其余直连。日常用这个。"
            case "global": return "全部流量走当前节点，不看规则。节点选错会全家上不了网。"
            case "direct": return "不走代理，所有流量直连。"
            default: return "还没读到当前模式。"
            }
        }
        switch m {
        case "proxy": return "按 Passwall 规则分流：命中的走节点，其余直连。"
        case "disable": return "不走代理，所有流量直连。"
        default: return "还没读到当前模式。"
        }
    }

    // MARK: - 配置与节点

    private var comboCard: some View {
        let cur = cfg.str("current")
        let curName = (cur as NSString).lastPathComponent.replacingOccurrences(of: ".yaml", with: "")
        let sorted = groups.sorted { a, b in
            let aa = isAuto(a.str("name")), bb = isAuto(b.str("name"))
            if aa != bb { return aa }
            return false
        }

        return Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                CardHead(icon: "list.bullet", title: "配置与节点",
                         sub: "换配置会重启内核，断网十几秒")
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 10)

                // 当前配置：整行可点，右侧「切换」胶囊给出明确的可操作性
                HStack(spacing: 10) {
                    Image(systemName: "key")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(C.primary)
                        .frame(width: 30, height: 30)
                        .background(C.accentSoft)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("当前配置").font(F.body).foregroundStyle(C.textPrimary)
                        Text(curName.isEmpty ? "未选择" : curName)
                            .font(F.num(12, .regular))
                            .foregroundStyle(C.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 6)
                    Button {
                        showCfg = true
                    } label: {
                        Text("切换")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(C.primary)
                            .padding(.horizontal, 11).padding(.vertical, 5)
                            .background(C.accentSoft)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 9)

                Hairline(inset: 18)

                Button {
                    goSubs = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.up.doc")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(C.primary)
                            .frame(width: 30, height: 30)
                            .background(C.accentSoft)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        Text("订阅管理").font(F.body).foregroundStyle(C.textPrimary)
                        Spacer(minLength: 6)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(C.textTertiary)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Hairline(inset: 18)

                // 节点：不是一个独立卡片，而是这张卡的最后一段
                Text("节点")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(C.textSecondary)
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 2)

                if loading {
                    Text("读取中…").font(F.tiny).foregroundStyle(C.textSecondary)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                } else if sorted.isEmpty {
                    Text(anyRunning() ? "节点分组还没读取到，这块会自动重试"
                                      : "代理没在运行，所以没有节点")
                        .font(F.tiny)
                        .foregroundStyle(C.textSecondary)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                } else {
                    ForEach(Array(sorted.enumerated()), id: \.offset) { i, g in
                        if i > 0 { Hairline(inset: 18) }
                        groupBlock(g)
                    }
                }
                Color.clear.frame(height: 6)
            }
        }
    }

    /// 有没有任意一个后端处于运行中：用来区分「没装/没启动」和「启动了但没读到分组」
    private func anyRunning() -> Bool {
        for i in 0..<backends.count where backends[i].bool("running") { return true }
        return false
    }

    private func groupBlock(_ g: J) -> some View {
        let name = g.str("name")
        let open = expanded.contains(name)
        let now = infoNode(g.str("now")) ? "" : g.str("now")
        let members = g.objs("members")

        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(C.textSecondary)
                    Text(name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(C.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        testGroup(name)
                    } label: {
                        Text(testingGroup == name ? "测速中" : "测速")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(testingGroup == name ? C.textSecondary : C.primary)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(testingGroup == name ? C.surfaceSunken : C.accentSoft)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 6) {
                    Text(now.isEmpty ? "未选择" : "当前 \(now)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(now.isEmpty ? C.textTertiary : C.primary)
                        .lineLimit(1)
                    Spacer()
                    Text("\(members.count) 个")
                        .font(F.num(11.5, .regular))
                        .foregroundStyle(C.textTertiary)
                }
                .padding(.leading, 16)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                if open { expanded.remove(name) } else { expanded.insert(name) }
            }

            if open {
                ForEach(Array(members.enumerated()), id: \.offset) { _, m in
                    memberRow(m, group: name, current: now)
                }
            }
        }
    }

    private func memberRow(_ m: J, group: String, current: String) -> AnyView {
        let name = m.str("name")
        if infoNode(name) { return AnyView(EmptyView()) }
        let on = name == current
        let policy = isPolicy(name)
        let tint: Color = on
            ? (isReject(name) ? C.danger : (policy ? C.textSecondary : C.primary))
            : (policy ? C.textSecondary : C.textPrimary)
        let delay = tested[name] ?? m.int("delay")

        return AnyView(Button {
            guard !busy else { return }
            Task { await selectNode(group: group, node: name) }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .strokeBorder(on ? tint : C.textTertiary, lineWidth: 1.4)
                        .frame(width: 15, height: 15)
                    if on {
                        Circle().fill(tint).frame(width: 7, height: 7)
                    }
                }
                Text(name)
                    .font(.system(size: 14))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                Spacer()
                if delay > 0 {
                    Text("\(delay)ms")
                        .font(F.num(11, .medium))
                        .foregroundStyle(delayColor(delay))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(delayColor(delay).opacity(0.16))
                        .clipShape(Capsule())
                } else if m.bool("is_group") {
                    Text("组").font(.system(size: 11)).foregroundStyle(C.textSecondary)
                } else {
                    Text("—").font(.system(size: 11)).foregroundStyle(C.textTertiary)
                }
            }
            .padding(.leading, 34).padding(.trailing, 18).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain))
    }

    private func isAuto(_ s: String) -> Bool {
        let k = s.lowercased()
        return k.contains("自动") || k.contains("auto") || k.contains("urltest")
            || k.contains("fallback") || k == "global"
    }

    private func infoNode(_ s: String) -> Bool {
        ["剩余流量", "距离下次", "套餐到期", "到期时间", "官网", "订阅", "重置"]
            .contains { s.hasPrefix($0) }
    }

    private func isReject(_ s: String) -> Bool {
        let u = s.uppercased()
        return u.hasPrefix("REJECT") || u.hasPrefix("DROP") || u == "PASS"
    }

    private func isPolicy(_ s: String) -> Bool {
        isReject(s) || s.uppercased() == "DIRECT"
    }

    private func delayColor(_ ms: Int) -> Color {
        if ms <= 0 { return C.textTertiary }
        if ms < 150 { return C.ok }
        if ms < 350 { return C.warn }
        return C.danger
    }

    // MARK: - 动作

    private func load() async {
        do {
            let p = try await Api.get("/api/v1/proxy")
            let g = try await Api.get("/api/v1/proxy/groups")
            let m = try? await Api.get("/api/v1/proxy/mode")
            let c = try? await Api.get("/api/v1/proxy/configs")
            await MainActor.run {
                d = p
                groups = (g["groups"] as? [Any])?.compactMap { $0 as? J } ?? []
                // 分组一律默认折叠（与安卓一致）：一屏先看到所有组的当前节点和节点数，
                // 想换哪个再展开哪个。以前会自动展开第一个，进来就是几十行节点
                if let m { mode = m.str("mode") }
                if let c { cfg = c }
                loading = false
                err = ""
            }
        } catch {
            await MainActor.run {
                loading = false
                if groups.isEmpty { err = error.localizedDescription }
            }
        }
    }

    private func switchBackend(_ id: String) async {
        busy = true
        defer { busy = false }
        _ = try? await Api.post("/api/v1/proxy/service",
                                ["action": "start", "backend": id], slow: true)
        await load()
    }

    private func setMode(_ v: String) async {
        busy = true
        defer { busy = false }
        _ = try? await Api.post("/api/v1/proxy/mode", ["mode": v])
        await MainActor.run { mode = v }
        await load()
    }

    private func selectNode(group: String, node: String) async {
        busy = true
        defer { busy = false }
        _ = try? await Api.post("/api/v1/proxy/select", ["group": group, "name": node])
        await MainActor.run { tested = [:] }
        await load()
    }

    private func testGroup(_ name: String) {
        guard testingGroup.isEmpty else { return }
        testingGroup = name
        Task {
            let r = try? await Api.post("/api/v1/proxy/delays",
                                        ["group": name, "timeout": 3000], slow: true)
            var got: [String: Int] = [:]
            if let list = r?.objs("delays") {
                for x in list {
                    got[x.str("name")] = x.int("delay")
                }
            }
            // delays 是字典形态时也接一下，两种后端返回结构不一样
            if let obj = r?["delays"] as? [String: Any] {
                for (k, v) in obj {
                    if let n = v as? Int { got[k] = n }
                    if let n = v as? Double { got[k] = Int(n) }
                }
            }
            await MainActor.run {
                tested = got
                testingGroup = ""
            }
        }
    }

    private func switchConfig(_ path: String) async {
        busy = true
        defer { busy = false }
        // 切配置文件 = uci set + commit + 重启内核，会断网十几秒
        _ = try? await Api.post("/api/v1/proxy/config", ["path": path], slow: true)
        await load()
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
            .navBarChrome()
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
