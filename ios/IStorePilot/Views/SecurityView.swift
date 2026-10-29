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

    /// 0 = 一级页，1 = 设备清单，2 = 拦截配置
    @State private var sub = 0
    @State private var subFilter = 0

    @State private var appsData: J = Api.cached("/api/v1/apps") ?? [:]
    @State private var goApps = false
    @Environment(\.barAxis) private var axis

    @State private var askTakeover: Bool? = nil
    @State private var busy = false

    private let tick = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    private var sum: J { d.obj("summary") ?? [:] }
    private var devs: [J] { d.objs("devices") }
    private var takeover: Bool { ad.str("mode") == "takeover" }

    var body: some View {
        Group {
            if sub == 1 {
                DevicesView(onBack: { sub = 0 }, initialFilter: subFilter)
            } else if sub == 2 {
                ShieldView(onBack: { sub = 0 })
            } else {
                level1
            }
        }
    }

    // MARK: - 一级页

    private var level1: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
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
                .padding(.top, 8)
            }
            .scrollIndicators(.hidden)
            .background(C.appBg)
            .navigationTitle("设备")
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $goApps) {
                NavigationStack { AppsView() }
            }
            .task { await load() }
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

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(online)")
                        .font(F.num(34, .bold))
                        .foregroundStyle(C.heroFg)
                    Text("台设备在线")
                        .font(.system(size: 13))
                        .foregroundStyle(C.heroFgSoft)
                }
                .padding(.top, 10)

                Text(blocked > 0 ? "共 \(total) 台　·　\(blocked) 台已禁网" : "共 \(total) 台")
                    .font(.system(size: 12))
                    .foregroundStyle(C.heroFgSoft)
                    .padding(.top, 4)
            }
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
                .padding(.bottom, 4)

                HStack(spacing: 0) {
                    statCell("在线", sum.int("online"), C.primary) { open(.online) }
                    statCell("离线", offline, C.textPrimary) { open(.offline) }
                    statCell("已禁网", sum.int("blocked"), C.danger) { open(.all) }
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
        return HStack(spacing: 10) {
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
        .onTapGesture {
            subFilter = 0
            sub = 1
        }
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
                    .padding(.bottom, 8)

                    Hairline(inset: 0)

                    if top.isEmpty {
                        Text("正在统计…")
                            .font(F.tiny)
                            .foregroundStyle(C.textSecondary)
                            .padding(.top, 10)
                    } else {
                        ForEach(Array(top.enumerated()), id: \.offset) { i, a in
                            if i > 0 { Hairline(inset: 0) }
                            HStack(spacing: 9) {
                                AppIconView(name: a.str("name"), size: 28)
                                Text(a.str("name"))
                                    .font(F.caption)
                                    .foregroundStyle(C.textPrimary)
                                    .lineLimit(1)
                                if a.dbl("down_bps") + a.dbl("up_bps") >= 1024 {
                                    Text(F.rate(a.dbl("down_bps") + a.dbl("up_bps")))
                                        .font(F.num(10.5, .medium))
                                        .foregroundStyle(C.primary)
                                }
                                Spacer(minLength: 6)
                                Text(F.bytes(a.dbl("all_total")))
                                    .font(F.num(12.5, .medium))
                                    .foregroundStyle(C.textPrimary)
                                Text(String(format: "%.0f%%", a.dbl("share")))
                                    .font(F.num(10.5, .regular))
                                    .foregroundStyle(C.textTertiary)
                                    .frame(width: 32, alignment: .trailing)
                            }
                            .padding(.vertical, 9)
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
                         "自动更新频率、规则表开关") { sub = 2 }
                Hairline(inset: 46)
                entryRow("list.bullet.rectangle", "拦截日志",
                         "最近被挡掉的域名查询") { sub = 2 }
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
        switch mode {
        case .all: subFilter = 0
        case .online: subFilter = 1
        case .offline: subFilter = 2
        }
        sub = 1
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
