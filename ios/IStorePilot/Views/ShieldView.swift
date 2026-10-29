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
    @State private var goInstall = false

    /// 一键安装：Agent 在路由器上装，这里只管确认和进度
    @State private var askInstall = false
    @State private var installing = false
    @State private var installStep = ""
    @State private var installPct = 0
    @State private var installErr = ""

    private let tick = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    private var stats: J { d.obj("stats") ?? [:] }
    private var running: Bool { d.bool("running") }
    /// 软路由上可能根本没装 AdGuard Home。缺字段（老 Agent）按「装了」处理，
    /// 别把一台正常的机器显示成未安装
    private var installed: Bool {
        guard let v = d["installed"] else { return true }
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        return true
    }
    private var install: J { d.obj("install") ?? [:] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    hero
                    if loading {
                        Card { VStack(alignment: .leading, spacing: 10) {
                            Bone(w: 90, h: 15); Bone(h: 10); Bone(h: 10)
                        } }
                    } else if !installed {
                        // 没装的时候统计、排行、规则、接管全都无从谈起，
                        // 只留一张说明 + 一个能直接落地的安装入口
                        installCard
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
            .sheet(isPresented: $goInstall) {
                WebScreen(title: "安装 AdGuard Home",
                          path: install.str("luci_path"))
            }
            .task { await load() }
            .onReceive(tick) { _ in Task { await load() } }
        }
    }

    // MARK: - 未安装

    private var installCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "装好就能用")
                Text("Agent 可以直接在路由器上装：联网下载本体、解包、以观察模式启动。"
                     + "装完这一页自动变成可用状态，不用重装 App。")
                    .font(F.caption)
                    .foregroundStyle(C.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if installing || !installErr.isEmpty {
                    Text(installErr.isEmpty
                         ? (installStep.isEmpty ? "安装中…" : "\(installStep) · \(installPct)%")
                         : "失败：\(installErr)")
                        .font(F.tiny)
                        .foregroundStyle(installErr.isEmpty ? C.textSecondary : C.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    askInstall = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                        Text(installing ? "安装中…" : "一键安装")
                            .font(F.caption)
                    }
                    .foregroundStyle(C.onPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(C.primary.opacity(installing ? 0.5 : 1),
                                in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(installing)

                Button {
                    goInstall = true
                } label: {
                    Text("去路由器网页安装")
                        .font(F.caption)
                        .foregroundStyle(C.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(C.divider, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Text("一键安装不改 DNS：装完只监听本机，接管全网仍是单独一步。")
                    .font(F.tiny)
                    .foregroundStyle(C.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .alert("在路由器上安装 AdGuard Home？", isPresented: $askInstall) {
            Button("取消", role: .cancel) {}
            Button("开始安装") { Task { await runInstall() } }
        } message: {
            Text("会联网下载本体（约 6.6 MB，来自 static.adtidy.org）并装到 /usr/bin/AdGuardHome，"
                 + "以观察模式启动：只监听 127.0.0.1，53 端口仍归 dnsmasq。"
                 + "全程不改 DNS、不影响上网，大约 1–3 分钟。")
        }
    }

    /// 提交安装 + 轮询进度。装完重新拉一次 /adblock，卡片会自动换成可用状态
    private func runInstall() async {
        await MainActor.run {
            installing = true
            installErr = ""
            installStep = "已提交"
            installPct = 0
        }
        do {
            _ = try await Api.post("/api/v1/adblock/install", ["confirm": "install"])
        } catch {
            await MainActor.run {
                installing = false
                installErr = error.localizedDescription
            }
            return
        }

        while true {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let s = try? await Api.get("/api/v1/adblock/install", cache: false) else {
                continue
            }
            let done = s.bool("done")
            let ok = s.bool("ok")
            let running = s.bool("running")
            await MainActor.run {
                installStep = s.str("step")
                installPct = s.int("pct")
                if done && !running {
                    installing = false
                    if !ok {
                        installErr = s.str("error")
                    }
                }
            }
            if done && !running {
                if ok {
                    await load()
                }
                break
            }
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private var hero: some View {
        if installed { runningHero } else { missingHero }
    }

    /// 没装本体：大字改成「未安装」，不再显示 0% —— 显示 0 会让人以为
    /// 装了只是没生效，反而更迷惑
    private var missingHero: some View {
        Hero {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("AdGuard Home")
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(C.heroFg)
                    Circle().fill(Color(hex: 0xFFB020)).frame(width: 7, height: 7)
                    Spacer()
                    Text("未安装").font(F.tiny).foregroundStyle(C.heroFgSoft)
                }
                Text("这台软路由上没有装 AdGuard Home")
                    .font(F.caption).foregroundStyle(C.heroFg)
                Text("装上之后拦截、规则、日志、接管全网会自动启用，App 不用更新。")
                    .font(F.tiny).foregroundStyle(C.heroFgSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var runningHero: some View {
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

                // 巡检救过场就留个痕：否则用户只会看到「怎么突然变成观察模式了」
                if let g = d.obj("guard"), g.int("count") > 0 {
                    Text("DNS 巡检触发过 \(g.int("count")) 次自愈"
                         + (g.str("reason").isEmpty ? "" : " · \(g.str("reason"))"))
                        .font(F.tiny)
                        .foregroundStyle(C.textTertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
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
