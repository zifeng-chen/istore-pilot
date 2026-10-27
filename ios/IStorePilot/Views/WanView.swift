import SwiftUI
import UIKit

/// 网络设置。对应安卓端的 `WanActivity` —— 原来那个独立的「网络」页签整个并到这里。
///
/// 顺序按「手会去点的地方」排：
///   1. 结论（Hero）：通不通、什么接入方式、拿到什么地址
///   2. 连接操作：重拨 / 断开（不动配置，失败也不会丢账号）
///   3. 接入配置：改完保存并重新拨号
///   4. 只读：局域网现状 + 防火墙摘要
///   5. 出口：改网段、静态路由、DDNS 去网页端
struct WanView: View {
    @State private var j: J = Api.cached("/api/v1/network/wan") ?? [:]
    @State private var fw: J = Api.cached("/api/v1/network/firewall") ?? [:]
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

    /// 重拨/断开后的提示行
    @State private var actNote = "重拨只重建链路，不改配置；断开后点「连接」即可恢复。"
    @State private var acting = false
    @State private var waiting = false
    @State private var waitSince = Date()

    private var cfg: J { j.obj("config") ?? [:] }
    private var st: J { j.obj("status") ?? [:] }
    private var lan: J { j.obj("lan") ?? [:] }
    private var protos: [J] { cfg.objs("protos") }
    private var up: Bool { st.bool("up") }

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
                    DuoColumns {
                        statusHero
                        actionCard
                        configCard
                    } right: {
                        lanCard
                        fwCard
                        webCard
                    }
                }
                Color.clear.frame(height: 18)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .scrollIndicators(.hidden)
        .background(C.appBg)
        .navigationTitle("网络")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .alert(item: $popup) { p in
            Alert(title: Text(p.title), message: Text(p.body),
                  dismissButton: .default(Text("好")))
        }
        .alert(confirmTitle, isPresented: $showConfirm) {
            Button("取消", role: .cancel) { pendingConfirm = nil }
            Button("确定") {
                let run = pendingConfirm
                pendingConfirm = nil
                run?()
            }
        } message: {
            Text(confirmBody)
        }
    }

    // MARK: - 结论

    private var statusHero: some View {
        let v6 = st.objs("ipv6").first { !$0.str("address").lowercased().hasPrefix("fe80") }
        let state: String = {
            if waiting { return "正在重拨…" }
            if up { return "已拨通" }
            return st.bool("pending") ? "正在拨号" : (st.str("note").isEmpty ? "未连接" : st.str("note"))
        }()

        return Hero {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Circle().fill(up ? Color(hex: 0x5FE7C4) : Color(hex: 0xFF7A6B))
                        .frame(width: 7, height: 7)
                    Text(state)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(C.heroFg)
                        .lineLimit(1)
                    Spacer()
                    Text(cfg.str("proto_label", "—"))
                        .font(F.tiny)
                        .foregroundStyle(C.heroFgSoft)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Color.white.opacity(0.16))
                        .clipShape(Capsule())
                }

                Text(st.str("ipv4", "—"))
                    .font(F.num(27, .semibold))
                    .foregroundStyle(C.heroFg)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.top, 10)

                Text("网关 \(st.str("gateway", "—"))")
                    .font(.system(size: 12))
                    .foregroundStyle(C.heroFgSoft)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let v6, !v6.str("address").isEmpty {
                    Text("IPv6 \(v6.str("address"))")
                        .font(F.num(10.5, .regular))
                        .foregroundStyle(C.heroFgSoft)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Rectangle().fill(Color.white.opacity(0.18)).frame(height: 0.7)
                    .padding(.top, 6)

                HStack(spacing: 0) {
                    heroCol("拨号时长", st.dbl("uptime") > 0 ? F.dur(st.dbl("uptime")) : "—")
                    heroCol("子网掩码", st.int("mask") > 0 ? "/\(st.int("mask"))" : "—")
                    heroCol("DNS", st.list("dns").count == 0
                            ? "自动" : "\(st.list("dns").count) 个")
                }
                .padding(.top, 8)
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

    // MARK: - 连接操作

    /// 重拨 / 断开：**不动配置**，所以不需要那套回滚吓唬话，点错了再点回来就行。
    private var actionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "连接操作", trailing: "只动链路，不改配置")

                HStack(spacing: 10) {
                    Button {
                        askAction("reconnect")
                    } label: {
                        Text(acting ? "执行中…" : "重拨")
                            .font(.system(size: 14.5, weight: .medium))
                            .foregroundStyle(C.onPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(C.primary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(acting || waiting)

                    Button {
                        askAction(up ? "down" : "up")
                    } label: {
                        Text(up ? "断开" : "连接")
                            .font(.system(size: 14.5, weight: .medium))
                            .foregroundStyle(C.textPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(C.surfaceSunken)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(acting || waiting)
                }

                Text(actNote)
                    .font(.system(size: 11.5))
                    .foregroundStyle(C.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func askAction(_ action: String) {
        let title: String
        let body: String
        switch action {
        case "down":
            title = "断开 WAN？"
            body = "断开后全家立刻上不了网，点「连接」可恢复。这个操作不改配置。"
        case "up":
            title = "重新连接？"
            body = "会向上级设备请求地址，通常 5-10 秒恢复。"
        default:
            title = "重拨？"
            body = "PPPoE 会重新协商，全家断网 10-30 秒。这个操作不改配置，失败也不会丢宽带账号。"
        }
        confirm(title: title, body: body) { doAction(action) }
    }

    /// SwiftUI 没有「确认弹窗」这种轻量件，这里用一个带两个按钮的 alert 包一层
    @State private var pendingConfirm: (() -> Void)?
    @State private var confirmTitle = ""
    @State private var confirmBody = ""

    private func confirm(title: String, body: String, run: @escaping () -> Void) {
        confirmTitle = title
        confirmBody = body
        pendingConfirm = run
        showConfirm = true
    }

    @State private var showConfirm = false

    private func doAction(_ action: String) {
        acting = true
        actNote = action == "down" ? "正在断开…" : "正在重拨…"
        Task {
            let res = try? await Api.post("/api/v1/net/wan/action", ["action": action])
            await MainActor.run {
                acting = false
                if let res, res.bool("ok") {
                    actNote = res.str("detail", "已发出指令")
                    if action == "down" {
                        waiting = false
                        actNote = "WAN 已断开。点「连接」恢复。"
                    } else {
                        waiting = true
                        waitSince = Date()
                    }
                } else {
                    actNote = "操作失败：" + (res?.str("error") ?? "路由器没有回应")
                }
            }
            if action != "down" { await waitForUp() }
        }
    }

    /// 重拨期间每 2.5 秒看一次，通了就停；95 秒还没通就如实说超时
    private func waitForUp() async {
        while waiting {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await load()
            let elapsed = Date().timeIntervalSince(waitSince)
            await MainActor.run {
                if st.bool("up") {
                    waiting = false
                    actNote = "已拨通，网络已恢复。"
                } else if elapsed > 95 {
                    waiting = false
                    actNote = "重拨超时，可能已自动回滚，请检查账号或线路。"
                } else {
                    actNote = "正在重拨… 已等待 \(Int(elapsed)) 秒"
                }
            }
        }
    }

    // MARK: - 接入配置

    private var configCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(text: "接入配置", trailing: "保存后立即重新拨号")

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
                            Text(shortProto(key, p.str("label", key)))
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

                Text("改接入方式会让 WAN 断开十几秒；90 秒内上不了网，路由器会自动回滚。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(C.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        }
    }

    /// 分段控件只有 1/3 屏宽，「自动获取（DHCP）」这种标签必被截断
    private func shortProto(_ key: String, _ fallback: String) -> String {
        switch key {
        case "pppoe": return "PPPoE"
        case "dhcp": return "DHCP"
        case "static": return "静态 IP"
        default: return fallback
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

    // MARK: - 局域网（只读）

    private var lanCard: some View {
        let limit = Double(lan.str("dhcp_limit")) ?? 0
        let leases = Double(lan.int("dhcp_leases"))

        return Card {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(text: "局域网", trailing: lan.bool("dhcp_enabled") ? "DHCP 已开启" : "DHCP 已关闭")

                KV("管理地址", lan.str("cidr"), mono: true)
                if lan.int("hosts") > 0 {
                    KV("可用地址", "\(F.count(lan.int("hosts"))) 个")
                }
                if lan.bool("dhcp_enabled"), !lan.str("dhcp_pool").isEmpty {
                    KV("地址池", lan.str("dhcp_pool"), mono: true)
                    if limit > 0 {
                        Bar(ratio: min(1, leases / limit))
                            .padding(.top, 8)
                        Text("\(Int(leases)) / \(Int(limit)) 已分配"
                             + (lan.str("dhcp_lease").isEmpty ? "" : "　·　租期 \(lan.str("dhcp_lease"))"))
                            .font(.system(size: 11))
                            .foregroundStyle(C.textSecondary)
                            .padding(.top, 6)
                    }
                }
                if !lan.str("ipv6_prefix").isEmpty {
                    KV("IPv6 前缀", lan.str("ipv6_prefix"), mono: true)
                }
            }
        }
    }

    // MARK: - 防火墙（只读）

    private var fwCard: some View {
        let risks = fw.list("risks").compactMap { $0 as? String }

        return Card {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(text: "防火墙", trailing: "只读")

                KV("默认入站", label(fw.obj("defaults")?.str("input") ?? ""))
                // 固定顺序：WAN 放行是唯一真风险，不能等接口返回顺序
                if let wanIn = zoneInput("wan") {
                    KV("WAN 入站", label(wanIn),
                       color: wanIn == "ACCEPT" ? C.danger : nil)
                }
                if let lanIn = zoneInput("lan") {
                    KV("LAN 入站", label(lanIn))
                }
                KV("转发规则", "\(fw.int("rules")) 条")
                if fw.int("redirects") > 0 {
                    KV("端口转发", "\(fw.int("redirects")) 条")
                }
                if fw.int("blocked_rules") > 0 {
                    KV("禁网规则", "\(fw.int("blocked_rules")) 条（本 App 创建）")
                }

                if !risks.isEmpty {
                    Text("需要注意 · \(risks.count) 条")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(C.warn)
                        .padding(.top, 12)

                    ForEach(risks, id: \.self) { r in
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(C.warn).frame(width: 5, height: 5)
                                .padding(.top, 5)
                            Text(r)
                                .font(.system(size: 12))
                                .foregroundStyle(C.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.top, 7)
                    }
                }
            }
        }
    }

    private func zoneInput(_ name: String) -> String? {
        for z in fw.objs("zones") where z.str("name") == name {
            return z.str("input")
        }
        return nil
    }

    private func label(_ v: String) -> String {
        switch v {
        case "ACCEPT": return "允许全部"
        case "REJECT": return "拒绝并回包"
        case "DROP": return "静默丢弃"
        default: return v.isEmpty ? "—" : v
        }
    }

    // MARK: - 出口

    private var webCard: some View {
        Card(padding: 0) {
            Button {
                openLuci()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "globe")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(C.primary)
                        .frame(width: 30, height: 30)
                        .background(C.accentSoft)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("路由器网页端").font(F.body).foregroundStyle(C.textPrimary)
                        Text("改网段、地址池、端口转发、DDNS")
                            .font(.system(size: 11.5))
                            .foregroundStyle(C.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(C.textTertiary)
                }
                .padding(.horizontal, 16).padding(.vertical, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// LuCI 在 80，Agent 在 8443 —— 直接拿 Session.base 会打开 API 端口，浏览器里是一坨 JSON
    private func openLuci() {
        var host = Session.base.replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
        if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
        if let colon = host.lastIndex(of: ":") { host = String(host[..<colon]) }
        if let url = URL(string: "http://\(host)/") {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - 动作

    private func load() async {
        do {
            let res = try await Api.get("/api/v1/network/wan")
            let f = try? await Api.get("/api/v1/network/firewall")
            await MainActor.run {
                j = res
                if let f { fw = f }
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
                        waiting = true
                        waitSince = Date()
                    } else {
                        popup = Popup(title: "保存失败",
                                      body: res.str("error", "路由器拒绝了这次配置"))
                    }
                }
                await load()
                if waiting { await waitForUp() }
            } catch {
                await MainActor.run {
                    busy = false
                    popup = Popup(title: "保存失败", body: error.localizedDescription)
                }
            }
        }
    }
}
