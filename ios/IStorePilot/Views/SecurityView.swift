import SwiftUI

/// 设备（设备 + 拦截的一级页）。
///
/// 原来「设备」和「拦截」是两个并列页签，各自都是一整套管理界面：
/// 设备页有搜索、分段、应用流量；拦截页有链路图、规则表、体检、日志。
/// 但打开 App 的人通常只想知道「几台连着 / 今天挡了多少」，
/// 真正要动手的事一周才发生一次。
///
/// 所以合成一个入口，一级只留三件：
///   1. 在线 / 离线 / 已禁网 各多少台
///   2. 拦截在不在工作、今天挡了多少
///   3. 两个最大开关（接管全网 / 进清单）
/// 搜索、应用流量、规则表、日志全部下沉到二级页。
struct SecurityView: View {
    @State private var d: J = Api.cached("/api/v1/devices") ?? [:]
    @State private var ad: J = Api.cached("/api/v1/adblock") ?? [:]
    @State private var loading = (Api.cached("/api/v1/devices") == nil)
    @State private var err = ""

    /// 二级页路由。空数组 = 停在一级页
    enum Route: Hashable {
        case devices(Int)
        case shield
        /// 三级页：某台设备的详情。放在同一个枚举里 —— `NavigationStack(path:)`
        /// 的 path 是 `[Route]`，只能往里 push `Route`；
        /// 之前清单里用 `NavigationLink(value: mac)`（String）配
        /// `.navigationDestination(for: String.self)`，类型对不上，点了没反应
        case device(String)
    }

    @State private var path: [Route] = {
        #if DEBUG
        switch DebugRoute.sub {
        case "devices": return [.devices(0)]
        case "shield": return [.shield]
        default: return []
        }
        #else
        return []
        #endif
    }()

    @State private var appsData: J = Api.cached("/api/v1/apps") ?? [:]
    @State private var goApps = false
    @Environment(\.barAxis) private var axis
    @Environment(\.tabIndex) private var tabIndex
    @EnvironmentObject private var chrome: TabChrome

    @State private var askTakeover: Bool? = nil
    @State private var busy = false

    private let tick = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    private var sum: J { d.obj("summary") ?? [:] }
    private var devs: [J] { d.objs("devices") }
    private var takeover: Bool { ad.str("mode") == "takeover" }

    /// 二级页走**真正的导航推进**，不再是「原地换一个视图 + 自己画返回箭头」。
    ///
    /// 原地换页时没有导航栈，返回按钮只能自己塞一个 ToolbarItem；
    /// iOS 26 会把它渲染成一颗浮在右上角的玻璃圆钮，跟标题各在各处，
    /// 看起来就不像导航栏。推进之后返回箭头、标题、手势返回全由系统给。
    var body: some View {
        NavigationStack(path: $path) {
            level1
                // onAppear 里也要报一次：onChange 只在变化时触发，
                // 冷启动直接落在二级页（调试参数）时初值就非空
                .onAppear { chrome.set(tabIndex, !path.isEmpty) }
                .onChange(of: path.count) { chrome.set(tabIndex, $0 > 0) }
                .navigationDestination(for: Route.self) { r in
                    switch r {
                    case .devices(let f):
                        DevicesView(initialFilter: f)
                    case .shield:
                        ShieldView()
                    case .device(let mac):
                        DeviceDetailView(mac: mac,
                                         seed: devs.first { $0.str("mac") == mac } ?? [:])
                    }
                }
        }
    }

    // MARK: - 一级页

    private var level1: some View {
            ScrollView {
                VStack(spacing: 14) {
                    scrollTopProbe()
                    heroCard

                    if loading {
                        skeleton
                    } else {
                        // 宽屏：左边设备、右边拦截。两块本来就是「两个系统」，
                        // 竖着排的时候要滑过一整张卡才能看到拦截今天挡了多少
                        if axis == .rail {
                            DuoColumns {
                                deviceCard
                            } right: {
                                adCard
                            }
                            appsCard
                        } else {
                            deviceCard
                            appsCard
                            adCard
                        }
                    }

                    if !err.isEmpty {
                        Text(err).font(F.tiny).foregroundStyle(C.danger)
                    }
                    Color.clear.barBottomGap()
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }
            .scrollIndicators(.hidden)
            .background(C.appBg)
            .navigationTitle("设备")
            .pageTitle("设备")
            .adaptiveSheet(isPresented: $goApps) {
                NavigationStack { AppsView(asSheet: true) }
            }
            .task { await load() }
            #if DEBUG
            // 截图用：-sub apps 时自动把应用流量页弹出来
            .onAppear {
                guard DebugRoute.sub == "apps" else { return }
                Task {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    goApps = true
                }
            }
            #endif
            .onReceive(tick) { _ in Task { await load(quiet: true) } }
            .confirmationDialog(takeover ? "退出 DNS 接管？" : "让所有设备走 AdGuard Home 解析？",
                                isPresented: Binding(
                                    get: { askTakeover != nil },
                                    set: { if !$0 { askTakeover = nil } }
                                ), titleVisibility: .visible) {
                Button(takeover ? "退出接管" : "接管", role: takeover ? .destructive : nil) {
                    let want = askTakeover ?? false
                    askTakeover = nil
                    Task { await setTakeover(want) }
                }
                Button("取消", role: .cancel) { askTakeover = nil }
            } message: {
                Text(takeover
                     ? "退出后所有设备改回运营商 DNS：广告拦截立即失效，已建立的连接不受影响。"
                     : "会把全网的域名查询切到 AdGuard Home。已连设备在租约续期后生效，中途有一两秒解析抖动；如果 AGH 已停用，全网会短时无法解析域名。")
            }
    }

    private var heroCard: some View {
        let online = sum.int("online")
        let total = sum.int("total")
        let blocked = sum.int("blocked")

        return Hero {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    Circle().fill(C.heroFg).frame(width: 7, height: 7)
                    Text("局域网")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(C.heroFg)
                    Spacer(minLength: 6)
                    Text(adBadge)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(C.heroFgSoft)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(C.heroFg.opacity(0.16))
                        .clipShape(Capsule())
                }

                // 大数字右侧留给「全网实时总流量」：和「几台在线」是同一件事的两面，
                // 也把这一行原本空着的右半边填上（安卓 hero 就是这么排的）
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(online)")
                        .font(F.num(34, .bold))
                        .foregroundStyle(C.heroFg)
                    Text("台设备在线")
                        .font(.system(size: 13))
                        .foregroundStyle(C.heroFgSoft)
                    Spacer(minLength: 8)
                    Text(totalRate > 0 ? "总流量 " + F.rate(totalRate) : "总流量 —")
                        .font(F.num(12.5, .medium))
                        .foregroundStyle(C.heroFgSoft)
                        .lineLimit(1)
                }
                .padding(.top, 10)

                Rectangle().fill(C.heroFg.opacity(0.18))
                    .frame(height: 0.7)
                    .padding(.top, 14)

                HStack(spacing: 8) {
                    Text(blocked > 0 ? "共 \(total) 台 · \(blocked) 台已禁网" : "共 \(total) 台")
                        .font(.system(size: 12))
                        .foregroundStyle(C.heroFgSoft)
                    Spacer(minLength: 8)
                    Text("点一行看详情")
                        .font(.system(size: 11.5))
                        .foregroundStyle(C.heroFgSoft.opacity(0.8))
                }
                .padding(.top, 12)
            }
        }
    }

    /// 全网实时总流量：把每台设备的上下行加起来
    private var totalRate: Double {
        devs.reduce(0) { sum, dv in
            let net = dv.obj("net") ?? [:]
            return sum + net.dbl("rx_bps") + net.dbl("tx_bps")
        }
    }

    private var adBadge: String {
        if !ad.bool("installed") { return "拦截未装" }
        return takeover ? "拦截已接管" : "拦截未接管"
    }

    // MARK: - 设备卡

    private var deviceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                CardHead(icon: "link", title: "设备", sub: "点数字进清单，点行看详情") {
                    Button {
                        open(.all)
                    } label: {
                        Text("全部 ›").font(.system(size: 13, weight: .medium))
                            .foregroundStyle(C.primary)
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 0) {
                    statCell("在线", sum.int("online"), C.primary) { open(.online) }
                    statCell("离线", offline, C.textPrimary) { open(.offline) }
                    // 0 台禁网时标红只会让人以为出事了；有数才用危险色
                    statCell("已禁网", sum.int("blocked"),
                             sum.int("blocked") > 0 ? C.danger : C.textTertiary) { open(.all) }
                }
                .padding(.vertical, 10)

                Hairline(inset: 0)

                Text("最近活跃")
                    .font(.system(size: 11.5))
                    .foregroundStyle(C.textSecondary)
                    .padding(.top, 10)
                    .padding(.bottom, 2)

                if active.isEmpty {
                    Text("还没有设备上线")
                        .font(F.body)
                        .foregroundStyle(C.textTertiary)
                        .padding(.vertical, 10)
                } else {
                    ForEach(Array(active.enumerated()), id: \.offset) { idx, dv in
                        if idx > 0 { Hairline(inset: 0) }
                        recentRow(dv)
                    }
                }
            }
        }
    }

    private var offline: Int {
        max(0, sum.int("total") - sum.int("online"))
    }

    /// 在线里按速率取前三
    private var active: [J] {
        devs.filter { $0.bool("online") }
            .sorted { bps($0) > bps($1) }
            .prefix(3)
            .map { $0 }
    }

    private func bps(_ dv: J) -> Double {
        let net = dv.obj("net") ?? [:]
        return max(net.dbl("rx_bps") + net.dbl("tx_bps"), net.dbl("avg_bps"))
    }

    private func statCell(_ label: String, _ value: Int, _ color: Color,
                          tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            VStack(spacing: 3) {
                Text("\(value)")
                    .font(F.num(25, .semibold))
                    .foregroundStyle(color)
                Text(label)
                    .font(.system(size: 11.5))
                    .foregroundStyle(C.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func recentRow(_ dv: J) -> some View {
        let b = bps(dv)
        let name = [dv.str("label"), dv.str("hostname"), dv.str("vendor"), dv.str("ip"), dv.str("mac")]
            .first { !$0.isEmpty } ?? "—"
        return Button {
            path.append(.devices(0))
        } label: {
            HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(F.body)
                    .foregroundStyle(C.textPrimary)
                    .lineLimit(1)
                Text(dv.str("ip").isEmpty ? dv.str("mac") : dv.str("ip"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(C.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                Text(b < 1024 ? "空闲" : F.rate(b))
                    .font(F.num(12, .medium))
                    .foregroundStyle(b < 1024 ? C.textSecondary : C.primary)
                if dv.bool("blocked") {
                    Text("已禁网").font(.system(size: 11)).foregroundStyle(C.danger)
                }
            }
        }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 应用流量卡

    /// 与安卓一级页的 AppsCard 同构：图标标题 + 副标题（时间范围与总量）+ 前 3 名。
    /// 原来这张卡只在「设备清单」二级页里，得先点进去才看得到。
    private var appsCard: some View {
        let arr = appsData.objs("apps")
        let all = appsData.obj("all") ?? [:]
        let days = Int(appsData.dbl("days"))
        let total = all.dbl("up") + all.dbl("down")
        let top = arr.filter { $0.dbl("all_total") > 1024 }.prefix(3)

        return Button {
            goApps = true
        } label: {
            Card {
                VStack(alignment: .leading, spacing: 0) {
                    CardHead(icon: "bolt", title: "应用流量",
                             sub: (days > 1 ? "近 \(days) 天 · " : "") + "共 " + F.bytes(total)) {
                        Text("全部 \(arr.count) 个 ›")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(C.primary)
                    }

                    if top.isEmpty {
                        Text("正在统计…")
                            .font(F.tiny)
                            .foregroundStyle(C.textSecondary)
                            .padding(.top, 10)
                    } else {
                        ForEach(Array(top.enumerated()), id: \.offset) { i, a in
                            if i > 0 { Hairline(inset: 0) }
                            HStack(spacing: 0) {
                                AppIconView(name: a.str("name"), size: 32)
                                Text(a.str("name"))
                                    .font(.system(size: 14.5))
                                    .foregroundStyle(C.textPrimary)
                                    .lineLimit(1)
                                    .padding(.leading, 11)
                                if a.dbl("down_bps") + a.dbl("up_bps") >= 1024 {
                                    Text(F.rate(a.dbl("down_bps") + a.dbl("up_bps")))
                                        .font(F.num(11, .medium))
                                        .foregroundStyle(C.primary)
                                        .padding(.leading, 6)
                                }
                                Spacer(minLength: 6)
                                Text(F.bytes(a.dbl("all_total")))
                                    .font(F.num(13.5, .medium))
                                    .foregroundStyle(C.textPrimary)
                                if a.dbl("share") > 0 {
                                    Text(String(format: "%.0f%%", a.dbl("share")))
                                        .font(F.num(11, .regular))
                                        .foregroundStyle(C.textSecondary)
                                        .frame(width: 34, alignment: .trailing)
                                        .padding(.leading, 6)
                                }
                            }
                            .padding(.vertical, 10)
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 拦截卡

    private var adCard: some View {
        let stats = ad.obj("stats") ?? [:]
        let blocked = stats.int("blocked")
        let queries = stats.int("queries")
        let pct = stats.dbl("percent")

        return Card {
            VStack(alignment: .leading, spacing: 0) {
                CardHead(icon: "shield.lefthalf.filled", title: "拦截", sub: "AdGuard Home") {
                    Pill(text: adStateText,
                         color: ad.bool("running") ? C.primary : C.textSecondary)
                }

                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(F.count(blocked))
                        .font(F.num(30, .semibold))
                        .foregroundStyle(C.textPrimary)
                    Text("次拦截")
                        .font(.system(size: 12.5))
                        .foregroundStyle(C.textSecondary)
                }
                .padding(.top, 12)

                Text("今日共查询 \(F.count(queries)) 次")
                    .font(.system(size: 12))
                    .foregroundStyle(C.textSecondary)
                    .padding(.top, 4)
                Text(pct > 0 ? "拦截率 \(String(format: "%.0f%%", pct))" : "今天还没有拦截记录")
                    .font(.system(size: 12))
                    .foregroundStyle(C.textSecondary)
                    .padding(.top, 2)

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("接管全网 DNS")
                            .font(F.body)
                            .foregroundStyle(C.textPrimary)
                        Text("关闭后所有设备改回运营商 DNS")
                            .font(.system(size: 11.5))
                            .foregroundStyle(C.textSecondary)
                    }
                    Spacer(minLength: 6)
                    Toggle("", isOn: Binding(
                        get: { takeover },
                        set: { askTakeover = $0 }
                    ))
                    .labelsHidden()
                    .tint(C.primary)
                    .disabled(!ad.bool("installed") || busy)
                }
                .padding(.top, 14)

                Hairline(inset: 0).padding(.top, 12)

                entryRow("arrow.triangle.2.circlepath", "规则与更新",
                         "自动更新频率、规则表开关") { path.append(.shield) }
                Hairline(inset: 46)
                entryRow("list.bullet.rectangle", "拦截日志",
                         "最近被挡掉的域名查询") { path.append(.shield) }
            }
        }
    }

    private var adStateText: String {
        if !ad.bool("installed") { return "未安装" }
        if !ad.bool("running") { return "未运行" }
        return takeover ? "运行中 · 接管" : "运行中"
    }

    private func entryRow(_ icon: String, _ title: String, _ note: String,
                          tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(C.primary)
                    .frame(width: 30, height: 30)
                    .background(C.primary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14.5)).foregroundStyle(C.textPrimary)
                    Text(note).font(.system(size: 11.5)).foregroundStyle(C.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(C.textTertiary)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 跳转

    private enum Sub { case all, online, offline }

    private func open(_ mode: Sub) {
        let filter: Int
        switch mode {
        case .all: filter = 0
        case .online: filter = 1
        case .offline: filter = 2
        }
        path.append(.devices(filter))
    }

    private var skeleton: some View {
        VStack(spacing: 14) {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Bone(w: 80, h: 12)
                    Bone(w: 160, h: 30)
                    Bone(w: 110, h: 11)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(0..<4, id: \.self) { _ in Bone(w: .infinity, h: 13) }
                }
            }
        }
    }

    // MARK: - 数据

    private func load(quiet: Bool = false) async {
        do {
            async let a = Api.get("/api/v1/devices", cache: quiet)
            async let b = Api.get("/api/v1/adblock", cache: quiet)
            async let c = Api.get("/api/v1/apps", cache: quiet)
            let (dv, ab, ap) = try await (a, b, c)
            await MainActor.run {
                d = dv
                ad = ab
                appsData = ap
                loading = false
                err = ""
            }
        } catch {
            await MainActor.run {
                loading = false
                err = "读取失败：\(error.localizedDescription)"
            }
        }
    }

    private func setTakeover(_ want: Bool) async {
        await MainActor.run { busy = true }
        _ = try? await Api.post(want ? "/api/v1/adblock/takeover" : "/api/v1/adblock/release")
        await MainActor.run { busy = false }
        await load(quiet: false)
    }
}
