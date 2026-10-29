import SwiftUI

struct DeviceDetailView: View {
    let mac: String
    @State private var d: J
    @State private var apps: [J] = []
    @State private var busy = false
    @State private var err = ""
    @State private var renaming = false
    @State private var newName = ""

    @Environment(\.dismiss) private var dismiss

    private let tick = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    init(mac: String, seed: J) {
        self.mac = mac
        _d = State(initialValue: seed)
    }

    private var online: Bool { d.bool("online") }
    private var blocked: Bool { d.bool("blocked") }
    private var net: J { d.obj("net") ?? [:] }
    private var dhcp: J { d.obj("dhcp") ?? [:] }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                hero
                infoCard
                trafficCard
                if !apps.isEmpty { appsCard }
                actionCard
                if !err.isEmpty {
                    Text(err).font(F.tiny).foregroundStyle(C.danger)
                }
                Color.clear.frame(height: 20)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .scrollIndicators(.hidden)
        .background(C.appBg)
        .navigationTitle(d.str("label", "设备"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onReceive(tick) { _ in Task { await load() } }
        .alert("重命名设备", isPresented: $renaming) {
            TextField("给设备起个名字", text: $newName)
            Button("保存") { rename() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("名字会写进路由器的 DHCP 静态主机名，所有设备上看到的一致。")
        }
    }

    // MARK: - Hero

    private var hero: some View {
        Hero {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    Circle().fill(online ? Color(hex: 0x5FE7C4) : Color(hex: 0xFF7A6B))
                        .frame(width: 8, height: 8)
                    Text(online ? "在线" : "离线")
                        .font(F.tiny).foregroundStyle(C.heroFgSoft)
                    if blocked {
                        Text("已禁网")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color(hex: 0xFF9F8F))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Color(hex: 0xFF7A6B).opacity(0.22))
                            .clipShape(Capsule())
                    }
                    Spacer()
                }

                Text(d.str("label", d.str("ip")))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(C.heroFg)

                HStack(spacing: 0) {
                    heroStat("下载", F.rate(net.dbl("rx_bps")))
                    Rectangle().fill(Color.white.opacity(0.18)).frame(width: 0.8, height: 30)
                    heroStat("上传", F.rate(net.dbl("tx_bps")))
                    Rectangle().fill(Color.white.opacity(0.18)).frame(width: 0.8, height: 30)
                    heroStat("今日", F.bytes(net.dbl("rx_today") + net.dbl("tx_today")))
                }
            }
        }
    }

    private func heroStat(_ k: String, _ v: String) -> some View {
        VStack(spacing: 2) {
            Text(v).font(F.num(14.5, .semibold)).foregroundStyle(C.heroFg)
            Text(k).font(.system(size: 10)).foregroundStyle(C.heroFgSoft)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 信息

    private var infoCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(text: "设备信息")
                KV("IP 地址", d.str("ip"), mono: true)
                Hairline(inset: 0)
                KV("MAC", d.str("mac"), mono: true)
                Hairline(inset: 0)
                KV("厂商", d.str("vendor", "未知"))
                Hairline(inset: 0)
                KV("类型", d.str("type", "其他"))
                Hairline(inset: 0)
                KV("主机名", d.str("hostname", "—"), mono: true)
                Hairline(inset: 0)
                KV("状态", stateText())
                if !accessText().isEmpty {
                    Hairline(inset: 0)
                    KV("接入方式", accessText())
                }
                if dhcp.bool("reserved") {
                    Hairline(inset: 0)
                    KV("静态绑定", dhcp.str("reserved_ip", "—"), mono: true, color: C.primary)
                }
            }
        }
    }

    /// 接入方式是**推测**（AP 桥接，上游分不出无线/有线），所以把依据一并写出来
    private func accessText() -> String {
        F.accessDetail(d.obj("access") ?? [:])
    }

    private func stateText() -> String {
        let left = dhcp.dbl("lease_left")
        if left > 0 {
            return "\(online ? "在线" : "离线")· 租约剩 \(F.dur(left))"
        }
        return online ? "在线" : "离线"
    }

    // MARK: - 流量

    private var trafficCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "流量")
                HStack(spacing: 10) {
                    flowBlock("累计下载", F.bytes(net.dbl("rx_total")), C.primary)
                    flowBlock("累计上传", F.bytes(net.dbl("tx_total")), C.warn)
                }
                HStack(spacing: 6) {
                    Image(systemName: "info.circle").font(.system(size: 10))
                    Text("流量统计按设备自己发出的字节数累计，不会被断网设备的内核重传污染。")
                        .font(.system(size: 10))
                }
                .foregroundStyle(C.textSecondary)
            }
        }
    }

    private func flowBlock(_ k: String, _ v: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(k).font(.system(size: 10.5)).foregroundStyle(C.textSecondary)
            Text(v).font(F.num(17, .semibold)).foregroundStyle(c)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 11).padding(.horizontal, 13)
        .background(C.surfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    // MARK: - 应用

    private var appsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 9) {
                SectionTitle(text: "这台设备的应用")
                ForEach(Array(apps.prefix(8).enumerated()), id: \.offset) { _, a in
                    let live = a.dbl("down_bps") + a.dbl("up_bps")
                    HStack(spacing: 9) {
                        Text(a.str("name"))
                            .font(F.caption)
                            .foregroundStyle(C.textPrimary)
                            .lineLimit(1)
                        Pill(text: a.str("category", "其他"), color: C.textSecondary)
                        Spacer()
                        // 累计字节几秒才涨一点点，正在跑的时候把实时速率也摆出来，
                        // 否则边看视频边刷这一页会觉得数字是死的
                        if live >= 1024 {
                            Text("↓ " + F.rate(a.dbl("down_bps")))
                                .font(F.num(11, .medium))
                                .foregroundStyle(C.primary)
                        }
                        Text(F.bytes(a.dbl("total")))
                            .font(F.num(11.5, .regular))
                            .foregroundStyle(C.textSecondary)
                    }
                }
            }
        }
    }

    // MARK: - 操作

    private var actionCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                miniAction(icon: "pencil", title: "重命名", color: C.primary) {
                    newName = d.str("alias", d.str("hostname"))
                    renaming = true
                }
                miniAction(icon: dhcp.bool("reserved") ? "pin.slash" : "pin",
                           title: dhcp.bool("reserved") ? "取消绑定" : "静态绑定",
                           color: C.primary) {
                    toggleBind()
                }
                miniAction(icon: "power", title: "唤醒",
                           color: C.textSecondary, disabled: online) {
                    power("wol")
                }
            }

            Button {
                block(!blocked)
            } label: {
                HStack(spacing: 8) {
                    if busy { ProgressView().tint(blocked ? C.primary : .white) }
                    Image(systemName: blocked ? "checkmark.shield" : "nosign")
                        .font(.system(size: 14, weight: .medium))
                    Text(blocked ? "解除禁网" : "禁止上网")
                        .font(.system(size: 15, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundStyle(blocked ? C.primary : .white)
                .background(blocked ? C.accentSoft : C.danger)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(busy)
        }
    }

    private func miniAction(icon: String, title: String, color: Color,
                            disabled: Bool = false,
                            act: @escaping () -> Void) -> some View {
        Button(action: act) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 15, weight: .medium))
                Text(title).font(.system(size: 11.5))
            }
            .foregroundStyle(disabled ? C.textTertiary : color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(C.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(C.glassStroke, lineWidth: 0.7)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled || busy)
    }

    // MARK: - 动作

    private func load() async {
        guard let j = try? await Api.get("/api/v1/devices/detail?mac=\(mac)", cache: false) else {
            return
        }
        if let dev = j.obj("device"), !dev.isEmpty { d = dev }
        apps = j.objs("apps")
        err = ""
    }

    private func rename() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        busy = true
        Task {
            _ = try? await Api.post("/api/v1/devices/rename", ["mac": mac, "alias": name])
            d["alias"] = name
            d["label"] = name
            await load()
            await MainActor.run { busy = false }
        }
    }

    private func block(_ on: Bool) {
        busy = true
        Task {
            do {
                let r = try await Api.post("/api/v1/devices/block",
                                           ["mac": mac, "enabled": on])
                await MainActor.run {
                    busy = false
                    if r.bool("ok") || r["ok"] == nil {
                        d["blocked"] = on
                    } else {
                        err = r.str("error", "操作失败")
                    }
                }
            } catch {
                await MainActor.run {
                    busy = false
                    err = error.localizedDescription
                }
            }
        }
    }

    private func toggleBind() {
        busy = true
        Task {
            if dhcp.bool("reserved") {
                _ = try? await Api.post("/api/v1/devices/unbind", ["mac": mac])
                d["dhcp"] = ["reserved": false]
            } else {
                _ = try? await Api.post("/api/v1/devices/bind",
                                        ["mac": mac, "ip": d.str("ip")])
                d["dhcp"] = ["reserved": true, "reserved_ip": d.str("ip")]
            }
            await load()
            await MainActor.run { busy = false }
        }
    }

    private func power(_ action: String) {
        Task {
            _ = try? await Api.post("/api/v1/devices/wol", ["mac": mac])
        }
    }
}
