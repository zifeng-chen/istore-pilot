import SwiftUI

struct OverviewView: View {
    @State private var d: J = Api.cached("/api/v1/overview") ?? [:]
    @State private var dev: J = Api.cached("/api/v1/devices") ?? [:]
    @State private var loading = (Api.cached("/api/v1/overview") == nil)
    @State private var err = ""
    @State private var popup: Popup?
    @State private var goHardware = false
    @State private var goWan = false
    @State private var detail: PortDetail?
    @Environment(\.barAxis) private var axis
    @Environment(\.tabIndex) private var tabIndex
    @EnvironmentObject private var chrome: TabChrome

    /// 每个网口最近 32 次采样，约 1 分半。
    /// 放这里而不是 PortTile 内部：tile 是 struct，每帧重建，存不住历史。
    @State private var hist: [String: [Double]] = [:]

    private let tick = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    /// 运行时长按秒走：3 秒轮询只负责校准基准，中间由这个 1 秒节拍往前推
    @State private var upBase: Double = 0
    @State private var upAt: Date = .distantPast
    @State private var now: Date = Date()
    private let secTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// hero 里的流量曲线：每 3 秒一个采样点，留 48 个（约 2 分半）
    @State private var rxHist: [Double] = []
    @State private var txHist: [Double] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    heroCard

                    if loading {
                        skeleton
                    } else if axis == .rail {
                        // 宽屏：上面「系统状态 | 局域网设备」两栏，网口单独占一整行。
                        // 网口挤在左栏里只有 479pt，6 个口得两两排成三行；
                        // 摊成整行后一行能看全，拔插网线时不用来回扫
                        DuoColumns {
                            systemCard
                        } right: {
                            deviceCard
                        }
                        wanCard
                        portCard(tileMin: 120)
                    } else {
                        // 窄屏维持原来的单列顺序。156 是手机上排两张的下限：
                        // 402pt 的机器内容宽 334，再大就只能排一张，六个口要滑六屏
                        systemCard
                        wanCard
                        portCard(tileMin: 156)
                        deviceCard
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
            .navigationTitle("概览")
            .navigationBarTitleDisplayMode(.large)
            .navBarChrome()
            .task { await load() }
            .onReceive(tick) { _ in Task { await load() } }
            .onReceive(secTick) { now = $0 }
            .navigationDestination(isPresented: $goHardware) { HardwareView() }
            .navigationDestination(isPresented: $goWan) { WanView() }
            // 推进到二级页时把底部页签收起来（横条画在导航栈外面，它自己不知道）
            .onAppear { chrome.set(tabIndex, goHardware || goWan) }
            .onChange(of: goHardware) { v in chrome.set(tabIndex, v || goWan) }
            .onChange(of: goWan) { v in chrome.set(tabIndex, v || goHardware) }
            .alert(item: $popup) { p in
                Alert(title: Text(p.title), message: Text(p.body),
                      dismissButton: .default(Text("好")))
            }
            .sheet(item: $detail) { t in
                PortDetailSheet(detail: t)
            }
        }
    }

    // MARK: - Hero

    private var heroCard: some View {
        let wan = d.obj("network")?.obj("wan") ?? [:]
        let up = wan.dbl("rx_bps")       // 路由器收到的 = 用户下载
        let down = wan.dbl("tx_bps")     // 路由器发出的 = 用户上传
        let board = d.obj("board") ?? [:]

        return Hero {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 8) {
                    Text(board.str("hostname", "iStoreOS"))
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(C.heroFg)
                    Circle()
                        .fill(wan.bool("up") ? Color(hex: 0x5FE7C4) : Color(hex: 0xFF7A6B))
                        .frame(width: 7, height: 7)
                    Spacer()
                    Text(F.uptime(uptimeNow))
                        .font(F.num(12, .regular))
                        .foregroundStyle(C.heroFgSoft)
                }

                Text(board.str("description", "—"))
                    .font(F.tiny)
                    .foregroundStyle(C.heroFgSoft)

                // 横线在上、三栏在下 —— 与安卓 hero 一致（`heroLine` 是一条通栏的
                // 0.7dp 白线，不是三栏之间的竖线）。
                //
                // 这两条竖线是 iOS 自己加的，安卓没有。加的时候三栏还是
                // 「图标 | 标签上、数值下」挤在一起的两列，竖线看着像分隔；
                // 改成数值独占一行后，每栏都是一个左对齐的字块，竖线就只是
                // 贴在「当前上传」「在线设备」左边的一根孤线，反而像画错了。
                Rectangle()
                    .fill(C.heroFg.opacity(0.18))
                    .frame(height: 0.7)
                    .padding(.top, 10)
                    .padding(.bottom, 10)

                HStack(spacing: 0) {
                    rateBlock(icon: "arrow.down", label: "当前下载", text: F.rate(up))
                    rateBlock(icon: "arrow.up", label: "当前上传", text: F.rate(down))
                    rateBlock(icon: "wifi", label: "在线设备", text: "\(onlineCount)")
                }

                // 趋势图直接长在 hero 里，与安卓一致：网快不快是同一件事，
                // 拆成下面另一张卡看得来回对照
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("流量趋势 · 最近 2 分钟")
                            .font(.system(size: 11))
                            .foregroundStyle(C.heroFgSoft)
                        Spacer()
                        Text(peakText)
                            .font(.system(size: 11))
                            .foregroundStyle(C.heroFgSoft.opacity(0.85))
                    }
                    .padding(.bottom, 10)
                    Sparkline(down: rxHist, up: txHist, height: 88)
                    // 图例离图远一点：贴着画布时总被当成图的一部分，
                    // 手指也容易点在图例上以为能切换曲线
                    HStack(spacing: 14) {
                        legendDot(color: C.primary, text: "下载")
                        legendDot(color: C.warn, text: "上传")
                        Spacer()
                    }
                    .padding(.top, 12)
                }
                .padding(.top, 16)
            }
        }
    }

    /// 一格指标：圆图标 + 标签在一行，数值单独占下一行。
    ///
    /// 原来是「图标 | 标签/数值」两列并排，370pt 的机器上每栏只剩 60pt 给数字，
    /// 「147.2 KB/s」必然折行或被截成「147.2 K…」。数值独占一行后就够放了。
    private func rateBlock(icon: String, label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(C.heroFg.opacity(0.9))
                    .frame(width: 20, height: 20)
                    .background(Color.white.opacity(0.16))
                    .clipShape(Circle())
                Text(label)
                    .font(.system(size: 10.5))
                    .foregroundStyle(C.heroFgSoft)
                    .lineLimit(1)
            }
            Text(text)
                .font(F.num(17, .semibold))
                .foregroundStyle(C.heroFg)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 2)
    }

    private var onlineCount: Int {
        dev.obj("summary")?.int("online") ?? 0
    }

    private var peakText: String {
        let peak = max(rxHist.max() ?? 0, txHist.max() ?? 0)
        return peak > 0 ? "峰值 " + F.rate(peak) : ""
    }

    private func legendDot(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(C.heroFgSoft.opacity(0.85))
        }
    }

    // MARK: - 系统

    /// 与安卓概览的「系统负载」卡逐项对齐：标题右侧写负载，
    /// 下面 CPU / 内存 / 磁盘 三根横条，每根自带细节。
    ///
    /// 之前这里只有 CPU 和内存，磁盘那条整个缺失 —— 而安卓有。
    /// 另外 CPU 型号原来塞在标题右侧，`Intel(R) Pentium(R) Gold 8505` 一定被截断
    /// （截图里就是 `Intel(R) Pentium(R) Gold…`），信息等于没显示。
    /// 型号改放 CPU 那一行的细节里，右侧让给真正在变的负载值。
    private var systemCard: some View {
        let cpu = d.obj("cpu") ?? [:]
        let mem = d.obj("memory") ?? [:]
        let load = d.obj("load") ?? [:]
        let temps = d.objs("temperature")
        let hot = temps.map { $0.dbl("celsius") }.max() ?? 0
        let (_, tt) = load.pair("threads")
        let disk = biggestDisk()
        let cpuPct = cpu.dbl("percent")

        return Card {
            VStack(alignment: .leading, spacing: 14) {
                CardHead(icon: "cpu", title: "系统负载",
                         sub: "CPU · 内存 · 磁盘") {
                    if load.dbl("load1") > 0 {
                        Text(String(format: "负载 %.2f", load.dbl("load1")))
                            .font(F.num(12, .medium))
                            .foregroundStyle(C.textSecondary)
                    }
                }

                metricRow(title: "CPU",
                          value: F.pct(cpuPct),
                          ratio: cpuPct / 100,
                          color: meterColor(cpuPct),
                          note: "\(tt) 线程" + (hot > 0 ? "　\(F.temp(hot))" : ""))

                metricRow(title: "内存",
                          value: F.pct(mem.dbl("percent")),
                          ratio: mem.dbl("percent") / 100,
                          color: meterColor(mem.dbl("percent")),
                          note: "\(F.bytes(mem.dbl("used"))) / \(F.bytes(mem.dbl("total")))")

                metricRow(title: "磁盘",
                          value: disk.percent > 0 ? F.pct(disk.percent) : "—",
                          ratio: disk.percent / 100,
                          color: meterColor(disk.percent),
                          note: disk.total > 0 ? F.bytes(disk.free) + " 可用" : "")

                Hairline(inset: 0)
                Button {
                    goHardware = true
                } label: {
                    HStack {
                        Text("查看全部硬件").font(F.body).foregroundStyle(C.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(C.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 用量条的配色阶梯：<70% 主色、70–90% 橙、>90% 红。
    /// 与安卓 `MeterBar.setRatio` 完全一致，也和温度那套判断同源
    private func meterColor(_ pct: Double) -> Color {
        pct >= 90 ? C.danger : (pct >= 70 ? C.warn : C.primary)
    }

    /// 最大的一块盘（安卓 `biggest()` 同逻辑）：overlay 只有 2 GB，
    /// 按容量最大那块看才有意义
    private func biggestDisk() -> (total: Double, free: Double, percent: Double) {
        let list = d.objs("storage")
        let best = list.max { $0.dbl("total") < $1.dbl("total") } ?? [:]
        return (best.dbl("total"), best.dbl("free"), best.dbl("percent"))
    }

    /// 名字 · 细节 ─────────────── 百分比
    /// ────────── 进度条 ──────────
    private func metricRow(title: String, value: String, ratio: Double,
                           color: Color, note: String) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(C.textPrimary)
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(C.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(value).font(F.num(13, .medium)).foregroundStyle(color)
            }
            Bar(ratio: ratio, color: color, height: 7)
        }
    }

    // MARK: - 网口

    /// 物理网口网格。
    ///
    /// 原来这张卡只画了 WAN / LAN 两个「逻辑接口」，看不到六个口各自的状态 ——
    /// 插错口、某个口协商成百兆、某个口一直空着，从原来那两行里完全读不出来。
    /// - Parameter tileMin: 单张网口卡的最小宽度。整行铺开时给 120（6 个口一行），
    ///   窄屏给 156（手机上两张并排）
    private func portCard(tileMin: CGFloat) -> some View {
        let ports = (d.obj("network")?.objs("ports") ?? []).sorted { a, b in
            let wa = a.str("role") == "wan"
            let wb = b.str("role") == "wan"
            if wa != wb { return wa }
            return a.str("name") < b.str("name")
        }
        let online = ports.filter { $0.bool("up") }.count

        return Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHead(icon: "cable.connector", title: "网口",
                         sub: "点开看累计收发") {
                    if !ports.isEmpty {
                        Text("\(online)/\(ports.count) 在线")
                            .font(F.caption)
                            .foregroundStyle(C.textSecondary)
                    }
                }

                if ports.isEmpty {
                    Text("没有检测到物理网口")
                        .font(F.caption).foregroundStyle(C.textSecondary)
                } else {
                    LazyVGrid(columns: [
                        GridItem(.adaptive(minimum: tileMin), spacing: 9),
                    ], spacing: 9) {
                        ForEach(Array(ports.enumerated()), id: \.offset) { _, p in
                            let name = p.str("name")
                            PortTile(name: name,
                                     role: p.str("role"),
                                     up: p.bool("up"),
                                     speedMbps: p.int("speed_mbps"),
                                     rx: p.dbl("rx_bps"),
                                     tx: p.dbl("tx_bps"),
                                     rxTotal: p.dbl("rx_total"),
                                     txTotal: p.dbl("tx_total"),
                                     mac: p.str("mac"),
                                     hist: hist[name] ?? []) {
                                detail = PortDetail(name: name,
                                                    text: PortDetailSheet.text(for: p))
                            }
                        }
                    }
                }

            }
        }
    }

    // MARK: - 宽带连接

    /// 与安卓概览的「宽带连接」卡同构：图标标题 + 四项关键信息 + 网络设置入口。
    /// 原来这部分信息只藏在「网口」卡底部的一个文字链接里，得点进去才知道拨没拨通。
    private var wanCard: some View {
        let wan = d.obj("network")?.obj("wan") ?? [:]
        let up = wan.bool("up")
        let proto = wan.str("proto_label", wan.str("proto", ""))
        let dns = wan.list("dns").compactMap { $0 as? String }
        let secs = wan.dbl("uptime")

        return Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHead(icon: "globe", title: "宽带连接",
                         sub: up ? "已拨通" : "未连接") {
                    Text(proto.isEmpty ? "配置" : proto)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(up ? C.ok : C.textSecondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(C.accentSoft)
                        .clipShape(Capsule())
                }

                VStack(spacing: 9) {
                    KV("WAN 地址", wan.str("ipv4"))
                    KV("网关", wan.str("gateway"))
                    KV("DNS", dns.isEmpty ? "自动" : dns.joined(separator: "  "))
                    KV("拨号时长", secs > 0 ? F.uptime(secs) : "—")
                }

                Hairline(inset: 0)

                Button {
                    goWan = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(C.primary)
                            .frame(width: 28, height: 28)
                            .background(C.accentSoft)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("网络设置").font(F.body).foregroundStyle(C.textPrimary)
                            Text("WAN / LAN / 无线 / 端口转发")
                                .font(F.tiny).foregroundStyle(C.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(C.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 设备

    private var deviceCard: some View {
        let list = dev.objs("devices")
        let online = list.filter { $0.bool("online") }
        let blocked = list.filter { $0.bool("blocked") }
        let top = list.sorted { $0.obj("net")?.dbl("avg_bps") ?? 0 > $1.obj("net")?.dbl("avg_bps") ?? 0 }
            .prefix(3)

        return Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHead(icon: "link", title: "局域网设备",
                         sub: "点行看详情") {
                    if !list.isEmpty {
                        Text("\(online.count) / \(list.count) 在线")
                            .font(F.caption)
                            .foregroundStyle(C.textSecondary)
                    }
                }

                HStack(spacing: 10) {
                    statBlock("在线", "\(online.count)", C.primary)
                    statBlock("离线", "\(max(0, list.count - online.count))", C.textSecondary)
                    statBlock("已禁网", "\(blocked.count)", blocked.isEmpty ? C.textSecondary : C.warn)
                }

                if !top.isEmpty {
                    Hairline(inset: 0)
                    ForEach(Array(top.enumerated()), id: \.offset) { _, dv in
                        let net = dv.obj("net") ?? [:]
                        HStack(spacing: 9) {
                            Circle().fill(dv.bool("online") ? C.ok : C.textTertiary)
                                .frame(width: 6, height: 6)
                            Text(dv.str("label", dv.str("ip")))
                                .font(F.caption)
                                .foregroundStyle(C.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Text(F.rate(net.dbl("avg_bps")))
                                .font(F.num(12, .regular))
                                .foregroundStyle(C.textSecondary)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
    }

    private func statBlock(_ k: String, _ v: String, _ c: Color) -> some View {
        VStack(spacing: 3) {
            Text(v).font(F.num(22, .bold)).foregroundStyle(c)
            Text(k).font(.system(size: 10.5)).foregroundStyle(C.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(C.surfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    // MARK: - 电源

    /// 和安卓端概览底部一致：网络服务重启 / 重启 / 关机。
    /// 这三个放在概览而不是设置里 —— 它们是「出问题时最想立刻按到的」，
    /// 藏进设置两级菜单等于找不到。
    // MARK: - 骨架

    private var skeleton: some View {
        VStack(spacing: 14) {
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    Bone(w: 110, h: 16)
                    Bone(h: 10)
                    Bone(w: 220, h: 10)
                    Bone(h: 10)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Bone(w: 90, h: 15)
                    Bone(h: 9)
                    Bone(h: 9)
                }
            }
        }
    }

    /// 当前运行秒数：基准值 + 本地走过的秒数
    private var uptimeNow: Double {
        guard upBase > 0 else { return 0 }
        return upBase + now.timeIntervalSince(upAt)
    }

    // MARK: - 载入

    private func load() async {
        // 不用 async let 并发：async let 的子任务不继承 MainActor 隔离，
        // 在里面改 @State 会变成后台线程写视图状态
        if let o = try? await Api.get("/api/v1/overview") {
            d = o
            upBase = o.dbl("uptime")
            upAt = Date()
            recordHistory(o)
        } else if d.isEmpty {
            err = "连不上路由器"
        }
        if let v = try? await Api.get("/api/v1/devices") { dev = v }
        loading = false
        if !d.isEmpty { err = "" }
    }

    /// 每个网口留 32 个采样点。只记总速率（收 + 发），
    /// 分开记两条线在 26pt 高的小图里只会糊成一团。
    private func recordHistory(_ o: J) {
        let w = o.obj("network")?.obj("wan") ?? [:]
        rxHist.append(w.dbl("rx_bps"))
        txHist.append(w.dbl("tx_bps"))
        if rxHist.count > 48 {
            rxHist.removeFirst(rxHist.count - 48)
            txHist.removeFirst(txHist.count - 48)
        }

        let ports = o.obj("network")?.objs("ports") ?? []
        var next = hist
        for p in ports {
            let name = p.str("name")
            guard !name.isEmpty else { continue }
            var arr = next[name] ?? []
            arr.append(max(0, p.dbl("rx_bps") + p.dbl("tx_bps")))
            if arr.count > 32 { arr.removeFirst(arr.count - 32) }
            next[name] = arr
        }
        // 拔掉的网口顺手清掉，避免字典越攒越大
        let alive = Set(ports.map { $0.str("name") })
        next = next.filter { alive.contains($0.key) }
        hist = next
    }
}

// MARK: - 网口详情

struct PortDetail: Identifiable {
    let id = UUID()
    let name: String
    let text: String
}

struct PortDetailSheet: View {
    let detail: PortDetail
    @Environment(\.dismiss) private var dismiss

    static func text(for p: J) -> String {
        let role = p.str("role")
        let roleText = role == "wan" ? "WAN（外网）" : (role == "lan" ? "LAN（内网）" : "未分配")
        let up = p.bool("up")
        return """
        接口　\(p.str("name", "—"))
        角色　\(roleText)
        状态　\(up ? "已连接 · \(F.speed(p.int("speed_mbps")))" : "未连接")
        MAC　\(p.str("mac").isEmpty ? "—" : p.str("mac"))
        累计接收　\(F.bytes(p.dbl("rx_total")))
        累计发送　\(F.bytes(p.dbl("tx_total")))
        """
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(detail.text)
                        .font(F.num(14, .regular))
                        .foregroundStyle(C.textPrimary)
                        .lineSpacing(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("累计收发从上次路由器开机算起，重启会归零。")
                        .font(F.tiny)
                        .foregroundStyle(C.textSecondary)
                    Color.clear.frame(height: 10)
                }
                .padding(18)
            }
            .background(C.appBg)
            .navigationTitle("网口 \(detail.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("好") { dismiss() }
                }
            }
        }
        .presentationDetents([.height(330), .medium])
        .presentationDragIndicator(.visible)
    }
}
