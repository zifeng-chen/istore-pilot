import SwiftUI

/// 宽带详情与配置。对应安卓端的 WanActivity。
///
/// 两块内容各自独立：上面是「现在这一条宽带的运行状态」，
/// 下面是「路由器里存着的那份配置」。分开画的原因很实在 ——
/// 状态是实时算出来的，配置是拨号时才生效的，
/// 混在一张卡里最容易出现「我明明改了怎么没变」的误解。
struct WanView: View {
    @State private var j: J = Api.cached("/api/v1/network/wan") ?? [:]
    @State private var loading = true
    @State private var err = ""
    @State private var busy = false
    @State private var popup: Popup?

    // 表单：只在首次载入时从服务端灌一次，之后以用户输入为准
    @State private var proto = ""
    @State private var username = ""
    @State private var password = ""
    @State private var ipaddr = ""
    @State private var netmask = "255.255.255.0"
    @State private var gateway = ""
    @State private var mtu = ""
    @State private var filled = false

    private var cfg: J { j.obj("config") ?? [:] }
    private var st: J { j.obj("status") ?? [:] }
    private var lan: J { j.obj("lan") ?? [:] }
    private var protos: [J] { cfg.objs("protos") }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if loading {
                    Card { VStack(alignment: .leading, spacing: 10) {
                        Bone(w: 120, h: 16); Bone(h: 10); Bone(h: 10)
                    } }
                } else if !err.isEmpty {
                    EmptyHint(icon: "wifi.exclamationmark", text: err)
                } else {
                    statusHero
                    configCard
                    lanCard
                }
                Color.clear.frame(height: 18)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .scrollIndicators(.hidden)
        .background(C.appBg)
        .navigationTitle("宽带")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .alert(item: $popup) { p in
            Alert(title: Text(p.title), message: Text(p.body),
                  dismissButton: .default(Text("好")))
        }
    }

    // MARK: - 状态

    private var statusHero: some View {
        let up = st.bool("up")
        let v6 = st.objs("ipv6").first { !$0.str("address").lowercased().hasPrefix("fe80") }

        return Hero {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Circle().fill(up ? Color(hex: 0x5FE7C4) : Color(hex: 0xFF7A6B))
                        .frame(width: 7, height: 7)
                    Text(up ? "已连接" : (st.bool("pending") ? "正在拨号" : "未连接"))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(C.heroFg)
                    Spacer()
                    Text(cfg.str("proto_label", "—"))
                        .font(F.tiny)
                        .foregroundStyle(C.heroFgSoft)
                }

                Text(st.str("ipv4", "—"))
                    .font(F.num(26, .bold))
                    .foregroundStyle(C.heroFg)

                Text("网关 \(st.str("gateway", "—"))　·　接口 \(st.str("l3_device", st.str("device", "—")))")
                    .font(F.tiny)
                    .foregroundStyle(C.heroFgSoft)

                if let v6, !v6.str("address").isEmpty {
                    Text(v6.str("address"))
                        .font(F.num(10.5, .regular))
                        .foregroundStyle(C.heroFgSoft)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Rectangle().fill(Color.white.opacity(0.18)).frame(height: 0.7)
                    .padding(.vertical, 2)

                HStack(spacing: 0) {
                    heroCol("拨号时长", st.dbl("uptime") > 0 ? F.dur(st.dbl("uptime")) : "—")
                    heroCol("子网掩码", st.int("mask") > 0 ? "/\(st.int("mask"))" : "—")
                    heroCol("DNS", st.list("dns").count == 0
                            ? "自动" : "\(st.list("dns").count) 个")
                }

                if !st.str("note").isEmpty {
                    Text(st.str("note"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(C.heroFgSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func heroCol(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(.system(size: 10)).foregroundStyle(C.heroFgSoft)
            Text(v).font(F.num(13.5, .semibold)).foregroundStyle(C.heroFg)
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 配置

    private var configCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(text: "接入配置",
                             trailing: "保存后立即重新拨号")

                Text("接入方式")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(C.textSecondary)
                    .padding(.top, 12)

                HStack(spacing: 8) {
                    ForEach(Array(protos.enumerated()), id: \.offset) { _, p in
                        let key = p.str("key")
                        let on = key == proto
                        Button {
                            proto = key
                        } label: {
                            Text(p.str("label", key))
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(on ? C.primary : C.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(on ? C.accentSoft2 : C.surfaceHi)
                                .clipShape(Capsule())
                                .overlay(Capsule().strokeBorder(
                                    on ? C.primary.opacity(0.55) : Color.clear, lineWidth: 0.9))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 8)

                VStack(spacing: 0) {
                    if proto == "pppoe" {
                        field("宽带账号", $username, "运营商给的账号", keyboard: .asciiCapable)
                        Hairline(inset: 0)
                        secureField("宽带密码",
                                    password.isEmpty ? "留空则保持不变" : "",
                                    $password)
                        Hairline(inset: 0)
                    } else if proto == "static" {
                        field("IP 地址", $ipaddr, "192.168.1.2", keyboard: .numbersAndPunctuation)
                        Hairline(inset: 0)
                        field("子网掩码", $netmask, "255.255.255.0",
                              keyboard: .numbersAndPunctuation)
                        Hairline(inset: 0)
                        field("默认网关", $gateway, "192.168.1.1", keyboard: .numbersAndPunctuation)
                        Hairline(inset: 0)
                    }
                    field("MTU", $mtu, "留空用默认", keyboard: .numberPad)
                }
                .padding(.top, 4)

                Text("密码留空表示沿用路由器里现在存的那个 —— 界面上只显示掩码，"
                     + "把掩码提交回去会把真密码覆盖成星号。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(C.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)

                Button {
                    save()
                } label: {
                    HStack(spacing: 7) {
                        if busy { ProgressView().tint(C.onPrimary).scaleEffect(0.75) }
                        else { Image(systemName: "checkmark.circle").font(.system(size: 14)) }
                        Text(busy ? "正在应用…" : "保存并重新拨号")
                            .font(.system(size: 14.5, weight: .medium))
                    }
                    .foregroundStyle(C.onPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(C.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .padding(.top, 12)

                Text("改接入方式会让 WAN 断开十几秒。App 走的是内网，不会因此掉线。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(C.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        }
    }

    private func field(_ label: String, _ v: Binding<String>, _ hint: String,
                       keyboard: UIKeyboardType) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(F.body)
                .foregroundStyle(C.textPrimary)
                .frame(width: 84, alignment: .leading)
            TextField(hint, text: v)
                .font(F.num(14, .medium))
                .multilineTextAlignment(.trailing)
                .keyboardType(keyboard)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        .padding(.vertical, 11)
    }

    private func secureField(_ label: String, _ hint: String,
                             _ v: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(F.body)
                .foregroundStyle(C.textPrimary)
                .frame(width: 84, alignment: .leading)
            SecureField(hint, text: v)
                .font(F.num(14, .medium))
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
        }
        .padding(.vertical, 11)
    }

    // MARK: - 内网

    private var lanCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(text: "内网")
                VStack(spacing: 0) {
                    KV("网关地址", lan.str("ipaddr"), mono: true)
                    Hairline(inset: 0)
                    KV("子网掩码", lan.str("netmask"), mono: true)
                    Hairline(inset: 0)
                    KV("DHCP 池", ".\(lan.str("dhcp_start")) 起，共 \(lan.str("dhcp_limit")) 个")
                }
                .padding(.top, 4)

                if !lan.str("note").isEmpty {
                    Text(lan.str("note"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(C.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                }
            }
        }
    }

    // MARK: - 动作

    private func load() async {
        do {
            let res = try await Api.get("/api/v1/network/wan")
            await MainActor.run {
                j = res
                loading = false
                err = res.bool("ok") ? "" : "读不到宽带配置"
                if !filled {
                    proto = res.obj("config")?.str("proto", "pppoe") ?? "pppoe"
                    username = res.obj("config")?.str("username") ?? ""
                    ipaddr = res.obj("config")?.str("ipaddr") ?? ""
                    let mask = res.obj("config")?.str("netmask") ?? ""
                    netmask = mask.isEmpty ? "255.255.255.0" : mask
                    gateway = res.obj("config")?.str("gateway") ?? ""
                    mtu = res.obj("config")?.str("mtu") ?? ""
                    filled = true
                }
            }
        } catch {
            await MainActor.run {
                loading = false
                err = error.localizedDescription
            }
        }
    }

    private func save() {
        var payload: J = ["proto": proto]
        if proto == "pppoe" {
            payload["username"] = username.trimmingCharacters(in: .whitespaces)
            if !password.isEmpty { payload["password"] = password }
        } else if proto == "static" {
            payload["ipaddr"] = ipaddr.trimmingCharacters(in: .whitespaces)
            payload["netmask"] = netmask.trimmingCharacters(in: .whitespaces)
            payload["gateway"] = gateway.trimmingCharacters(in: .whitespaces)
        }
        let m = mtu.trimmingCharacters(in: .whitespaces)
        if !m.isEmpty { payload["mtu"] = m }

        busy = true
        Task {
            do {
                let res = try await Api.post("/api/v1/network/wan", payload, slow: true)
                await MainActor.run {
                    busy = false
                    if res.bool("ok") {
                        password = ""
                        popup = Popup(title: "已保存",
                                      body: res.str("message", "WAN 正在用新配置重新拨号，十几秒后恢复。"))
                    } else {
                        popup = Popup(title: "保存失败",
                                      body: res.str("error", "路由器拒绝了这次配置"))
                    }
                }
                await load()
            } catch {
                await MainActor.run {
                    busy = false
                    popup = Popup(title: "保存失败", body: error.localizedDescription)
                }
            }
        }
    }
}
