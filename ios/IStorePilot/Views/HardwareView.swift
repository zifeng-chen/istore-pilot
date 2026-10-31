import SwiftUI

/// 硬件详情。对应安卓端的 HardwareActivity。
///
/// 排布逻辑：先给「这台机器是什么」，再给「里面装了什么」，
/// 最后才是 PCI 设备表这种翻一次就够的清单。
/// 每块都用两列网格装，手机上不会出现一整屏只有三行字的空旷感。
struct HardwareView: View {
    @State private var h: J = Api.cached("/api/v1/system/hardware") ?? [:]
    @State private var loading = true
    @State private var err = ""

    /// 已运行按秒走：这一页只载入一次，不自己走秒的话数字是定住的
    @State private var upBase: Double = 0
    @State private var upAt: Date = .distantPast
    @State private var now: Date = Date()
    private let secTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if loading {
                    ForEach(0..<3, id: \.self) { _ in
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                Bone(w: 100, h: 15); Bone(h: 10); Bone(h: 10)
                            }
                        }
                    }
                } else if !err.isEmpty {
                    EmptyHint(icon: "exclamationmark.triangle", text: err)
                } else {
                    heroCard
                    cpuCard
                    memoryCard
                    diskCard
                    nicCard
                    thermalCard
                    pciCard
                }
                Color.clear.frame(height: 18)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .scrollIndicators(.hidden)
        .background(C.appBg)
        .navigationTitle("硬件")
        .navigationBarTitleDisplayMode(.inline)
        // 一级页把系统导航栏藏了，二级页显式声明「要显示」，免得跟着一起消失
        .toolbar(.visible, for: .navigationBar)
        .navBarChrome()
        .task { await load() }
        .onReceive(secTick) { now = $0 }
    }

    // MARK: - 机器

    private var heroCard: some View {
        let m = h.obj("machine") ?? [:]
        let s = h.obj("system") ?? [:]
        let cpu = h.obj("cpu") ?? [:]
        let mem = h.obj("memory") ?? [:]

        // 台式机主板的 DMI 常常是 BIOS 占位符，这时用 CPU 型号当标题更有信息量
        let title = firstNonEmpty([s.str("hostname"), cpu.str("model")], fallback: "iStoreOS")

        return Hero {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(C.heroFg)
                        .lineLimit(1)
                    Spacer()
                    Text(s.str("distro", "") + " " + s.str("version", ""))
                        .font(F.tiny)
                        .foregroundStyle(C.heroFgSoft)
                        .lineLimit(1)
                }

                Text("\(s.str("target", "—"))　·　内核 \(s.str("kernel", "—"))　·　\(s.str("arch", "—"))")
                    .font(F.tiny)
                    .foregroundStyle(C.heroFgSoft)

                Rectangle().fill(Color.white.opacity(0.18)).frame(height: 0.7)
                    .padding(.vertical, 2)

                HStack(spacing: 0) {
                    heroStat("CPU",
                             "\(cpu.int("cores")) 核 \(cpu.int("threads")) 线程")
                    heroStat("内存", F.bytes(mem.dbl("total")))
                    heroStat("运行", F.uptime(uptimeNow))
                }

                if !m.str("note").isEmpty {
                    Text(m.str("note"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(C.heroFgSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func heroStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10)).foregroundStyle(C.heroFgSoft)
            Text(value).font(F.num(13.5, .semibold)).foregroundStyle(C.heroFg)
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - CPU

    private var cpuCard: some View {
        let cpu = h.obj("cpu") ?? [:]

        return Card {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(text: "处理器", trailing: cpu.str("arch"))
                VStack(spacing: 0) {
                    KV("型号", cpu.str("model"))
                    Hairline(inset: 0)
                    KV("核心 / 线程", "\(cpu.int("cores")) / \(cpu.int("threads"))")
                    Hairline(inset: 0)
                    KV("当前频率", cpu.int("mhz") > 0 ? "\(cpu.int("mhz")) MHz" : "—",
                       mono: true)
                    Hairline(inset: 0)
                    KV("频率范围", "\(cpu.int("min_mhz"))–\(cpu.int("max_mhz")) MHz", mono: true)
                    Hairline(inset: 0)
                    KV("缓存", cpu.str("cache"))
                }
                .padding(.top, 4)

                HStack(spacing: 8) {
                    flag("VT 虚拟化", cpu.bool("vt"))
                    flag("AES 指令集", cpu.bool("aes"))
                }
                .padding(.top, 10)
            }
        }
    }

    private func flag(_ label: String, _ on: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: on ? "checkmark.circle.fill" : "slash.circle")
                .font(.system(size: 11))
                .foregroundStyle(on ? C.ok : C.textTertiary)
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(on ? C.textPrimary : C.textSecondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(C.surfaceSunken)
        .clipShape(Capsule())
    }

    // MARK: - 内存

    private var memoryCard: some View {
        let mem = h.obj("memory") ?? [:]
        let modules = mem.objs("modules")

        return Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "内存", trailing: F.pct(mem.dbl("percent")))
                Bar(ratio: mem.dbl("percent") / 100,
                    color: mem.dbl("percent") > 85 ? C.danger : C.primary)
                Text("\(F.bytes(mem.dbl("used"))) / \(F.bytes(mem.dbl("total")))")
                    .font(F.tiny).foregroundStyle(C.textSecondary)

                if modules.isEmpty {
                    Text("读不到内存条信息（部分主板不提供 SMBIOS Type 17）")
                        .font(F.tiny).foregroundStyle(C.textSecondary)
                        .padding(.top, 2)
                } else {
                    ForEach(Array(modules.enumerated()), id: \.offset) { i, s in
                        Hairline(inset: 0).padding(.top, i == 0 ? 2 : 0)
                        moduleRow(s)
                    }
                }
            }
        }
    }

    private func moduleRow(_ s: J) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "memorychip")
                .font(.system(size: 13))
                .foregroundStyle(C.primary)
                .frame(width: 26, height: 26)
                .background(C.accentSoft)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(s.str("size", "—"))
                        .font(F.num(13.5, .semibold))
                        .foregroundStyle(C.textPrimary)
                    Text("\(s.str("type")) \(s.int("speed") > 0 ? "\(s.int("speed"))" : "")")
                        .font(.system(size: 11))
                        .foregroundStyle(C.textSecondary)
                    Text(s.str("form"))
                        .font(.system(size: 10))
                        .foregroundStyle(C.textSecondary)
                }
                Text(s.str("vendor", "") + " " + s.str("part", ""))
                    .font(.system(size: 11))
                    .foregroundStyle(C.textSecondary)
                    .lineLimit(1)
                Text(s.str("slot"))
                    .font(.system(size: 10))
                    .foregroundStyle(C.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
    }

    // MARK: - 存储

    private var diskCard: some View {
        let disks = h.objs("disks")

        return Card {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(text: "存储", trailing: "\(disks.count) 块")
                if disks.isEmpty {
                    Text("没有检测到磁盘").font(F.tiny).foregroundStyle(C.textSecondary)
                        .padding(.top, 8)
                }
                ForEach(Array(disks.enumerated()), id: \.offset) { i, d in
                    Hairline(inset: 0).padding(.top, i == 0 ? 4 : 0)
                    HStack(spacing: 10) {
                        Image(systemName: "internaldrive")
                            .font(.system(size: 14))
                            .foregroundStyle(C.primary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(d.str("name", "—"))
                                .font(F.num(13.5, .semibold))
                                .foregroundStyle(C.textPrimary)
                            Text("\(d.str("model", "—"))　·　\(d.str("transport", "—"))")
                                .font(.system(size: 11))
                                .foregroundStyle(C.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(d.str("size_text", F.bytes(d.dbl("size"))))
                                .font(F.num(12.5, .medium))
                                .foregroundStyle(C.textPrimary)
                            if d.dbl("temp") > 0 {
                                Text(F.temp(d.dbl("temp")))
                                    .font(F.num(11, .regular))
                                    .foregroundStyle(d.dbl("temp") > 60 ? C.warn : C.textSecondary)
                            }
                        }
                    }
                    .padding(.vertical, 10)
                }
            }
        }
    }

    // MARK: - 网卡

    private var nicCard: some View {
        let nics = h.objs("nics")

        return Card {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(text: "网卡", trailing: "\(nics.filter { $0.bool("up") }.count)/\(nics.count) 已连接")
                if nics.isEmpty {
                    Text("没有检测到物理网卡").font(F.tiny).foregroundStyle(C.textSecondary)
                        .padding(.top, 8)
                }
                ForEach(Array(nics.enumerated()), id: \.offset) { i, n in
                    Hairline(inset: 0).padding(.top, i == 0 ? 4 : 0)
                    nicRow(n)
                }
            }
        }
    }

    private func nicRow(_ n: J) -> some View {
        let up = n.bool("up")
        return HStack(spacing: 10) {
            PortIcon(up: up, wan: false, size: CGSize(width: 24, height: 18))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(n.str("name", "—"))
                        .font(F.num(13.5, .semibold))
                        .foregroundStyle(up ? C.textPrimary : C.textSecondary)
                    if up {
                        Text(F.speed(n.int("speed_mbps")))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(C.primary)
                    }
                }
                Text(n.str("chip", "—"))
                    .font(.system(size: 11))
                    .foregroundStyle(C.textSecondary)
                    .lineLimit(1)
                Text(n.str("mac"))
                    .font(F.num(10.5, .regular))
                    .foregroundStyle(C.textTertiary)
            }
            Spacer(minLength: 4)
            if !n.str("driver").isEmpty {
                Text(n.str("driver"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(C.textSecondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(C.surfaceSunken)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 9)
    }

    // MARK: - 温度

    private var thermalCard: some View {
        let s = h.obj("sensors") ?? [:]
        let zones = s.objs("zones")

        return Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "温度")
                HStack(spacing: 10) {
                    tempBlock("CPU", s.dbl("cpu"))
                    tempBlock("NVMe", s.dbl("nvme"))
                    if let hottest = zones.map({ $0.dbl("celsius") }).max(), hottest > 0 {
                        tempBlock("机箱", hottest)
                    }
                }
                if !zones.isEmpty {
                    Text(zones.map { "\($0.str("label", $0.str("zone"))) \(F.temp($0.dbl("celsius")))" }
                        .joined(separator: "　·　"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(C.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func tempBlock(_ label: String, _ c: Double) -> some View {
        VStack(spacing: 3) {
            Text(c > 0 ? F.temp(c) : "—")
                .font(F.num(17, .semibold))
                .foregroundStyle(c > 75 ? C.warn : C.textPrimary)
            Text(label).font(.system(size: 10.5)).foregroundStyle(C.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(C.surfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    // MARK: - PCI

    private var pciCard: some View {
        let pci = h.objs("pci")
        return Card {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(text: "PCI 设备", trailing: "\(pci.count) 项")
                ForEach(Array(pci.enumerated()), id: \.offset) { i, p in
                    Hairline(inset: 0).padding(.top, i == 0 ? 4 : 0)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.str("name", "—"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(C.textPrimary)
                            .lineLimit(2)
                        Text("\(p.str("slot"))　\(p.str("class"))")
                            .font(F.num(10, .regular))
                            .foregroundStyle(C.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    /// 当前运行秒数：基准值 + 本地走过的秒数
    private var uptimeNow: Double {
        guard upBase > 0 else { return 0 }
        return upBase + now.timeIntervalSince(upAt)
    }

    // MARK: - 工具

    private func firstNonEmpty(_ items: [String], fallback: String) -> String {
        for s in items where !s.isEmpty { return s }
        return fallback
    }

    private func load() async {
        do {
            let j = try await Api.get("/api/v1/system/hardware")
            await MainActor.run {
                h = j
                upBase = (j.obj("system") ?? [:]).dbl("uptime")
                upAt = Date()
                loading = false
                err = j.bool("ok") ? "" : "硬件信息读取失败"
            }
        } catch {
            await MainActor.run {
                loading = false
                err = error.localizedDescription
            }
        }
    }
}
