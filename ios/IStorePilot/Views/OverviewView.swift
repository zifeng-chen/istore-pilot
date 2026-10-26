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

    /// 每个网口最近 32 次采样，约 1 分半。
    /// 放这里而不是 PortTile 内部：tile 是 struct，每帧重建，存不住历史。
    @State private var hist: [String: [Double]] = [:]

    private let tick = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    heroCard

                    if loading {
                        skeleton
                    } else {
                        systemCard
                        portCard
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
            .task { await load() }
            .onReceive(tick) { _ in Task { await load() } }
            .navigationDestination(isPresented: $goHardware) { HardwareView() }
            .navigationDestination(isPresented: $goWan) { WanView() }
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
                    Text(F.dur(d.dbl("uptime")))
                        .font(F.tiny)
                        .foregroundStyle(C.heroFgSoft)
                }

                Text(board.str("description", "—"))
                    .font(F.tiny)
                    .foregroundStyle(C.heroFgSoft)

                HStack(spacing: 0) {
                    rateBlock(icon: "arrow.down", label: "下载", v: up)
                    Rectangle().fill(Color.white.opacity(0.18)).frame(width: 0.8, height: 34)
                    rateBlock(icon: "arrow.up", label: "上传", v: down)
                }
                .padding(.top, 2)
            }
        }
    }

    private func rateBlock(icon: String, label: String, v: Double) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(C.heroFg.opacity(0.9))
                .frame(width: 26, height: 26)
                .background(Color.white.opacity(0.16))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 10.5))
                    .foregroundStyle(C.heroFgSoft)
                Text(F.rate(v))
                    .font(F.num(16.5, .semibold))
                    .foregroundStyle(C.heroFg)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 系统

    private var systemCard: some View {
        let cpu = d.obj("cpu") ?? [:]
        let mem = d.obj("memory") ?? [:]
        let load = d.obj("load") ?? [:]
        let temps = d.objs("temperature")
        let hot = temps.map { $0.dbl("celsius") }.max() ?? 0
        let (th, tt) = load.pair("threads")

        return Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(text: "系统状态", trailing: cpu.str("model"))

                metricRow(title: "CPU",
                          value: F.pct(cpu.dbl("percent")),
                          ratio: cpu.dbl("percent") / 100,
                          color: cpu.dbl("percent") > 85 ? C.danger : C.primary,
                          note: "\(cpu.int("cores")) 线程")

                metricRow(title: "内存",
                          value: F.pct(mem.dbl("percent")),
                          ratio: mem.dbl("percent") / 100,
                          color: mem.dbl("percent") > 85 ? C.danger : C.primary,
                          note: "\(F.bytes(mem.dbl("used"))) / \(F.bytes(mem.dbl("total")))")

                HStack(spacing: 10) {
                    chip("负载", String(format: "%.2f", load.dbl("load1")))
                    chip("进程", "\(th)/\(tt)")
                    chip("温度", hot > 0 ? F.temp(hot) : "—",
                         color: hot > 75 ? C.warn : C.textPrimary)
                    chip("内核", d.obj("board")?.str("kernel", "—") ?? "—")
                }

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

    private func metricRow(title: String, value: String, ratio: Double,
                           color: Color, note: String) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(title).font(F.body).foregroundStyle(C.textSecondary)
                Spacer()
                Text(note).font(F.tiny).foregroundStyle(C.textSecondary)
                Text(value).font(F.num(15, .semibold)).foregroundStyle(color)
                    .frame(width: 52, alignment: .trailing)
            }
            Bar(ratio: ratio, color: color)
        }
    }

    private func chip(_ k: String, _ v: String, color: Color = C.textPrimary) -> some View {
        VStack(spacing: 3) {
            Text(k).font(.system(size: 10.5)).foregroundStyle(C.textSecondary)
            Text(v).font(F.num(13.5, .medium)).foregroundStyle(color).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(C.surfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    // MARK: - 网口

    /// 物理网口网格。
    ///
    /// 原来这张卡只画了 WAN / LAN 两个「逻辑接口」，看不到六个口各自的状态 ——
    /// 插错口、某个口协商成百兆、某个口一直空着，从原来那两行里完全读不出来。
    private var portCard: some View {
        let ports = (d.obj("network")?.objs("ports") ?? []).sorted { a, b in
            let wa = a.str("role") == "wan"
            let wb = b.str("role") == "wan"
            if wa != wb { return wa }
            return a.str("name") < b.str("name")
        }
        let online = ports.filter { $0.bool("up") }.count

        return Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "网口",
                             trailing: ports.isEmpty ? "" : "\(online)/\(ports.count) 在线")

                if ports.isEmpty {
                    Text("没有检测到物理网口")
                        .font(F.caption).foregroundStyle(C.textSecondary)
                } else {
                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: 9),
                        GridItem(.flexible(), spacing: 9),
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

                Hairline(inset: 0)
                Button {
                    goWan = true
                } label: {
                    HStack {
                        Text("宽带连接与配置").font(F.body).foregroundStyle(C.primary)
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
                SectionTitle(text: "局域网设备",
                             trailing: list.isEmpty ? "" : "\(online.count) / \(list.count) 在线")

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

    // MARK: - 载入

    private func load() async {
        // 不用 async let 并发：async let 的子任务不继承 MainActor 隔离，
        // 在里面改 @State 会变成后台线程写视图状态
        if let o = try? await Api.get("/api/v1/overview") {
            d = o
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
