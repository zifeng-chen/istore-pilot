import SwiftUI

struct ShieldView: View {
    /// 从「设备与拦截」一级页进来时给返回动作
    var onBack: (() -> Void)? = nil

    @State private var d: J = Api.cached("/api/v1/adblock") ?? [:]
    @State private var top: [J] = []
    @State private var loading = true
    @State private var err = ""
    @State private var busy = false
    @State private var goLog = false

    private let tick = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    private var stats: J { d.obj("stats") ?? [:] }
    private var running: Bool { d.bool("running") }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    hero
                    if loading {
                        Card { VStack(alignment: .leading, spacing: 10) {
                            Bone(w: 90, h: 15); Bone(h: 10); Bone(h: 10)
                        } }
                    } else {
                        statCard
                        topCard
                        dnsCard
                        RulesCard { Task { await load() } }
                        actionCard
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
            .navigationTitle("拦截")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let onBack {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: onBack) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 15, weight: .semibold))
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(isPresented: $goLog) { AdblockLogView() }
            .task { await load() }
            .onReceive(tick) { _ in Task { await load() } }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        let pct = stats.dbl("percent")
        return Hero {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("AdGuard Home")
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(C.heroFg)
                    Circle().fill(running ? Color(hex: 0x5FE7C4) : Color(hex: 0xFF7A6B))
                        .frame(width: 7, height: 7)
                    Spacer()
                    Text(d.str("mode_label", running ? "运行中" : "已停止"))
                        .font(F.tiny).foregroundStyle(C.heroFgSoft)
                }

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(format: "%.1f", pct))
                        .font(F.num(40, .bold))
                        .foregroundStyle(C.heroFg)
                    Text("%")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(C.heroFgSoft)
                    Text("的查询被拦下")
                        .font(F.tiny).foregroundStyle(C.heroFgSoft)
                        .padding(.leading, 4)
                    Spacer()
                }

                HStack(spacing: 0) {
                    tiny(label: "查询", v: num(stats.int("queries")))
                    Rectangle().fill(Color.white.opacity(0.18)).frame(width: 0.8, height: 26)
                    tiny(label: "拦截", v: num(stats.int("blocked")))
                    Rectangle().fill(Color.white.opacity(0.18)).frame(width: 0.8, height: 26)
                    tiny(label: "规则", v: num(d.obj("filters")?.int("rules") ?? 0))
                }
            }
        }
    }

    private func num(_ v: Int) -> String {
        v >= 10000 ? String(format: "%.1f 万", Double(v) / 10000) : "\(v)"
    }

    private func tiny(label: String, v: String) -> some View {
        VStack(spacing: 2) {
            Text(v).font(F.num(15, .semibold)).foregroundStyle(C.heroFg)
            Text(label).font(.system(size: 10)).foregroundStyle(C.heroFgSoft)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 统计

    private var statCard: some View {
        let s = stats
        let f = d.obj("filters") ?? [:]

        return Card {
            VStack(alignment: .leading, spacing: 13) {
                SectionTitle(text: "拦截概况",
                             trailing: d.str("mode") == "takeover" ? "已接管全网" : "")
                Bar(ratio: s.dbl("percent") / 100, color: C.primary, height: 8)

                HStack(spacing: 10) {
                    stat("拦截次数", num(s.int("blocked")), C.primary)
                    stat("规则条数", num(f.int("rules")), C.textPrimary)
                    stat("自定义", "\(f.int("user_rules"))", C.textPrimary)
                }
            }
        }
    }

    private func stat(_ k: String, _ v: String, _ c: Color) -> some View {
        VStack(spacing: 3) {
            Text(v).font(F.num(19, .bold)).foregroundStyle(c)
            Text(k).font(.system(size: 10.5)).foregroundStyle(C.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(C.surfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    // MARK: - 排行

    private var topCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionTitle(text: "拦截排行")
                    Spacer()
                    Button {
                        goLog = true
                    } label: {
                        HStack(spacing: 3) {
                            Text("全部日志").font(.system(size: 12))
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        }
                        .foregroundStyle(C.primary)
                    }
                }

                if top.isEmpty {
                    EmptyHint(icon: "shield.slash", text: "还没有拦截记录")
                } else {
                    ForEach(Array(top.prefix(6).enumerated()), id: \.offset) { i, it in
                        HStack(spacing: 10) {
                            Text("\(i + 1)")
                                .font(F.num(11, .semibold))
                                .foregroundStyle(C.textTertiary)
                                .frame(width: 14, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(it.str("domain"))
                                    .font(F.num(12.5, .medium))
                                    .foregroundStyle(C.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(it.str("list", "—"))
                                    .font(.system(size: 10))
                                    .foregroundStyle(C.textSecondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Text("\(it.int("count"))")
                                .font(F.num(12, .medium))
                                .foregroundStyle(C.textSecondary)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
    }

    // MARK: - DNS 链路

    private var dnsCard: some View {
        let listen = d.obj("listening") ?? [:]
        let host = listen.objs("bind_hosts").first?.str("address", "—") ?? "—"
        let ups = d.list("upstream").compactMap { $0 as? String }

        return Card {
            VStack(alignment: .leading, spacing: 4) {
                SectionTitle(text: "DNS 链路")
                KV("监听", "\(host):\(listen.int("port"))", mono: true)
                Hairline(inset: 0)
                KV("上游", ups.prefix(2).joined(separator: " · "), mono: true)
                Hairline(inset: 0)
                KV("本地端口", "\(d.int("dnsmasq_port"))（dnsmasq）", mono: true)
                Hairline(inset: 0)
                HStack {
                    Text("AAAA 过滤").font(F.body).foregroundStyle(C.textSecondary)
                    Spacer()
                    // 这是 OpenClash filter_aaaa_dns=1 带出来的结果，刻意配置，
                    // 不是故障 —— 打开会让域名走 IPv6 绕过代理
                    Pill(text: d.bool("aaaa_disabled") ? "已跟随代理关闭" : "已启用",
                         color: C.textSecondary)
                }
                .padding(.vertical, 9)
            }
        }
    }

    // MARK: - 操作

    private var actionCard: some View {
        Card {
            VStack(spacing: 10) {
                Button {
                    run(d.str("mode") == "takeover" ? "release" : "takeover")
                } label: {
                    HStack {
                        if busy { ProgressView().tint(C.onPrimary) }
                        Text(d.str("mode") == "takeover" ? "退出接管（还回 dnsmasq）" : "接管全网 DNS")
                            .font(.system(size: 15.5, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(d.str("mode") == "takeover" ? C.textPrimary : C.onPrimary)
                    .background(d.str("mode") == "takeover" ? C.surfaceSunken : C.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(busy)

                // 「刷新规则源」已挪到上面的 RulesCard 里（那里能说明白
                // 自动更新和手动更新的关系），这里再放一个只是重复
                Text(d.str("mode") == "takeover"
                     ? "接管中：所有设备的 DNS 先经 AGH 过滤再交给 OpenClash 分流。"
                     : "观察中：AGH 只服务路由器本机，对全家网络零影响。")
                    .font(F.tiny)
                    .foregroundStyle(C.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - 载入

    private func load() async {
        do {
            d = try await Api.get("/api/v1/adblock")
            if let t = try? await Api.get("/api/v1/adblock/top?limit=8") {
                top = t.objs("items")
            }
            loading = false
            err = ""
        } catch {
            loading = false
            if d.isEmpty { err = error.localizedDescription }
        }
    }

    private func run(_ action: String) {
        busy = true
        Task {
            _ = try? await Api.post("/api/v1/adblock/\(action)", nil, slow: true)
            await load()
            await MainActor.run { busy = false }
        }
    }
}

// MARK: - 拦截日志

struct AdblockLogView: View {
    @State private var items: [J] = []
    @State private var onlyBlocked = true
    @State private var loading = true
    @State private var q = ""

    private var shown: [J] {
        let k = q.trimmingCharacters(in: .whitespaces).lowercased()
        guard !k.isEmpty else { return items }
        return items.filter { $0.str("domain").lowercased().contains(k)
            || $0.str("client").contains(k) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Seg(items: ["仅拦截", "全部查询"], index: Binding(
                    get: { onlyBlocked ? 0 : 1 },
                    set: { onlyBlocked = $0 == 0 }
                ), onChange: { _ in Task { await load() } })

                if loading {
                    ListGroup {
                        ForEach(0..<6, id: \.self) { _ in
                            VStack(alignment: .leading, spacing: 5) {
                                Bone(w: 200, h: 11); Bone(w: 120, h: 9)
                            }.padding(14)
                        }
                    }
                } else if shown.isEmpty {
                    Card { EmptyHint(icon: "doc.text.magnifyingglass", text: "没有记录") }
                } else {
                    ListGroup {
                        ForEach(Array(shown.enumerated()), id: \.offset) { i, it in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 7) {
                                    Text(it.str("domain"))
                                        .font(F.num(13, .medium))
                                        .foregroundStyle(C.textPrimary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 4)
                                    if it.str("status") == "blocked" || onlyBlocked {
                                        Pill(text: "拦截", color: C.warn)
                                    }
                                }
                                HStack(spacing: 8) {
                                    Text(it.str("client", "—"))
                                        .font(F.num(10.5, .regular))
                                        .foregroundStyle(C.textSecondary)
                                    Text(it.str("time", "—"))
                                        .font(.system(size: 10))
                                        .foregroundStyle(C.textTertiary)
                                    Spacer()
                                    Text(it.str("rule"))
                                        .font(F.num(10, .regular))
                                        .foregroundStyle(C.textTertiary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.horizontal, 15).padding(.vertical, 10)
                            if i < shown.count - 1 { Hairline(inset: 15) }
                        }
                    }
                }
                Color.clear.frame(height: 20)
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
        .background(C.appBg)
        .navigationTitle("拦截日志")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        do {
            let j = try await Api.get("/api/v1/adblock/log?only_blocked=\(onlyBlocked ? 1 : 0)&limit=200")
            items = j.objs("items")
            loading = false
        } catch {
            loading = false
        }
    }
}
