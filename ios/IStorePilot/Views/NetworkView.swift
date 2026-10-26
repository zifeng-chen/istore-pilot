import SwiftUI

/// 网络：这台路由器的「怎么上网、内网怎么分、谁能进来」。
///
/// 以前这些信息散着：宽带在概览的 WAN 卡里，LAN 哪都没有，防火墙只能去网页端。
/// 而「我家网段是多少、DHCP 发到哪、外面能不能直接连进来」
/// 恰恰是路由器管理 App 最该回答的问题。
///
/// 三块对应三个决策层级：
///   1. 宽带接入（WAN，可改）
///   2. 局域网（LAN / DHCP，只读）
///   3. 防火墙（只读，含现有配置的风险提示）
///
/// 只读不是偷懒：LAN 一改，手机到路由器的连接立刻失效，
/// 用户看到的是「App 崩了」而不是「配置生效了请注意重连」。
struct NetworkView: View {
    @State private var wan: J = Api.cached("/api/v1/network/wan") ?? [:]
    @State private var fw: J = Api.cached("/api/v1/network/firewall") ?? [:]
    /// 待确认事务：改完网络配置后，客户端不回来点确认，服务端 60 秒后自动回滚
    @State private var pending: J = [:]
    @State private var loading = (Api.cached("/api/v1/network/wan") == nil)
    @State private var goWan = false
    @State private var popup: Popup?

    private let tick = Timer.publish(every: 8, on: .main, in: .common).autoconnect()

    private var cfg: J { wan.obj("config") ?? [:] }
    private var st: J { wan.obj("status") ?? [:] }
    private var lan: J { wan.obj("lan") ?? [:] }
    private var hasPending: Bool { pending.bool("pending") }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if hasPending { pendingCard }
                    heroCard

                    if loading {
                        skeleton
                    } else {
                        // 宽屏：宽带在左（可改、字段多），局域网/防火墙/规划在右
                        DuoColumns {
                            wanCard
                        } right: {
                            lanCard
                            fwCard
                            gapCard
                        }
                    }

                    Color.clear.barBottomGap()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .scrollIndicators(.hidden)
            .background(C.appBg)
            .navigationTitle("网络")
            .navigationBarTitleDisplayMode(.large)
            .task { await load() }
            .onReceive(tick) { _ in Task { await load() } }
            .navigationDestination(isPresented: $goWan) { WanView() }
            .alert(item: $popup) { p in
                Alert(title: Text(p.title), message: Text(p.body),
                      dismissButton: .default(Text("好")))
            }
        }
    }

    // MARK: - 待确认横幅

    private var pendingCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(C.warn)
                    Text(pending.bool("expired") ? "正在还原改动…"
                         : (pending.str("note").isEmpty ? "改动等待确认" : pending.str("note")))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(C.textPrimary)
                    Spacer(minLength: 0)
                    Text(pending.bool("expired") ? "请稍候" : "\(pending.int("left")) 秒")
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(C.warn)
                }
                Text("能连上就说明没问题。不点确认的话，时间一到路由器会自己还原。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(C.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 5)

                HStack(spacing: 10) {
                    Button {
                        rollback()
                    } label: {
                        Text("撤销改动")
                            .font(.system(size: 14))
                            .foregroundStyle(C.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(C.surfaceSunken)
                            .clipShape(Capsule())
                    }
                    Button {
                        confirm()
                    } label: {
                        Text("确认，一切正常")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(C.onPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(C.primary)
                            .clipShape(Capsule())
                    }
                }
                .padding(.top, 12)
            }
        }
    }

    // MARK: - Hero

    private var heroCard: some View {
        let up = st.bool("up")
        let ip = st.str("ipv4")
        let gateway = st.str("gateway")
        let uptime = st.dbl("uptime")

        return Hero {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(up ? C.heroFg : Color.clear)
                        .overlay(Circle().strokeBorder(C.heroFg, lineWidth: up ? 0 : 1.6))
                        .frame(width: 7, height: 7)
                    Text(up ? "已拨通" : (st.str("note").isEmpty ? "未连接" : st.str("note")))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(C.heroFg)
                    Spacer(minLength: 6)
                    Text(cfg.str("proto_label").isEmpty ? "未配置" : cfg.str("proto_label"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(C.heroFgSoft)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(C.heroFg.opacity(0.16))
                        .clipShape(Capsule())
                }

                Text(ip.isEmpty ? "—" : ip)
                    .font(F.num(27, .semibold))
                    .foregroundStyle(C.heroFg)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.top, 12)

                Text(subLine(gateway: gateway, uptime: uptime))
                    .font(.system(size: 12))
                    .foregroundStyle(C.heroFgSoft)
                    .padding(.top, 4)
            }
        }
    }

    private func subLine(gateway: String, uptime: Double) -> String {
        var bits: [String] = []
        if !gateway.isEmpty { bits.append("网关 \(gateway)") }
        if uptime > 0 { bits.append("已连接 \(F.dur(uptime))") }
        return bits.isEmpty ? "—" : bits.joined(separator: "　·　")
    }

    // MARK: - 宽带

    private var wanCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(text: "宽带接入")
                Text("对外那一根线")
                    .font(.system(size: 11.5))
                    .foregroundStyle(C.textSecondary)
                    .padding(.bottom, 8)

                KV("接入方式", cfg.str("proto_label"))
                if !cfg.str("username").isEmpty {
                    KV("账号", cfg.str("username"), mono: true)
                }
                KV("地址获取", st.str("ipv4").isEmpty
                   ? "未获取"
                   : (cfg.str("proto") == "static" ? "静态指定" : "自动下发"))
                KV("DNS", dnsText)

                Button {
                    goWan = true
                } label: {
                    HStack {
                        Text("修改宽带设置").font(F.body).foregroundStyle(C.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(C.textTertiary)
                    }
                    .padding(.top, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text("保存后会立即重新拨号，期间全网断约 10 秒。")
                    .font(.system(size: 11))
                    .foregroundStyle(C.textTertiary)
                    .padding(.top, 6)
            }
        }
    }

    private var dnsText: String {
        let list = st.list("dns").compactMap { $0 as? String }.filter { !$0.isEmpty }
        return list.isEmpty ? "" : list.prefix(3).joined(separator: "　")
    }

    // MARK: - 局域网

    private var lanCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(text: "局域网", trailing: lan.bool("dhcp_enabled") ? "DHCP 已开启" : "DHCP 已关闭")

                KV("管理地址", lan.str("cidr"), mono: true)
                if lan.int("hosts") > 0 {
                    KV("可用地址", "\(F.count(lan.int("hosts"))) 个")
                }
                if lan.bool("dhcp_enabled") {
                    KV("地址池", lan.str("dhcp_pool"), mono: true)
                    KV("已分配", "\(lan.int("dhcp_leases")) 个"
                       + (lan.str("dhcp_lease").isEmpty ? "" : "　·　租期 \(lan.str("dhcp_lease"))"))
                }
                if !lan.str("ipv6_prefix").isEmpty {
                    KV("IPv6 前缀", lan.str("ipv6_prefix"), mono: true)
                }

                Text(lan.str("note", "修改 LAN 网段会导致 App 立即失联"))
                    .font(.system(size: 11))
                    .foregroundStyle(C.textTertiary)
                    .padding(.top, 6)
            }
        }
    }

    // MARK: - 防火墙

    private var fwCard: some View {
        let risks = fw.list("risks").compactMap { $0 as? String }
        return Card {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(text: "防火墙")
                Text("谁能从外面进来")
                    .font(.system(size: 11.5))
                    .foregroundStyle(C.textSecondary)
                    .padding(.bottom, 8)

                KV("默认入站", label(fw.obj("defaults")?.str("input") ?? ""))
                ForEach(Array(fw.objs("zones").enumerated()), id: \.offset) { _, z in
                    let name = z.str("name")
                    if name == "wan" || name == "lan" {
                        KV(name == "wan" ? "WAN 入站" : "LAN 入站", label(z.str("input")))
                    }
                }
                KV("转发规则", "\(fw.int("rules")) 条")
                if fw.int("redirects") > 0 {
                    KV("端口转发", "\(fw.int("redirects")) 条")
                }
                if fw.int("blocked_rules") > 0 {
                    KV("禁网规则", "\(fw.int("blocked_rules")) 条（本 App 创建）")
                }

                ForEach(risks, id: \.self) { r in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(C.warn)
                            .padding(.top, 2)
                        Text(r)
                            .font(.system(size: 12))
                            .foregroundStyle(C.warn)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(C.warn.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.top, 6)
                }

            }
        }
    }

    private func label(_ v: String) -> String {
        switch v {
        case "ACCEPT": return "允许全部"
        case "REJECT": return "拒绝并回包"
        case "DROP": return "静默丢弃"
        default: return v.isEmpty ? "—" : v
        }
    }

    // MARK: - 还不能改的

    private var gapCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(text: "还不能在这里改")
                Text("LAN 管理地址、DHCP 范围、端口转发、静态路由、DDNS —— 都会直接改变网络拓扑")
                    .font(.system(size: 12))
                    .foregroundStyle(C.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)

                Button {
                    popup = Popup(title: "网络配置的下一步", body: gapsText)
                } label: {
                    Text("查看规划")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(C.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(C.accentSoft)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
            }
        }
    }

    private let gapsText = """
    已经有的：宽带（PPPoE / DHCP / 静态）、LAN 与 DHCP 现状、防火墙摘要。

    还没做的：
    1. LAN 管理地址 —— 改完手机立刻连不上，需要失败自动回滚 + 提示新地址
    2. DHCP 地址池 / 租约时长 —— 影响新设备能不能拿到 IP
    3. 静态地址绑定 —— 设备列表里已经有 MAC，只差写入
    4. DDNS、静态路由、VLAN、QoS 限速

    防火墙策略不在 App 里改。这里只做展示，所有调整请到路由器网页端
    （LuCI → 网络 → 防火墙），避免一次误操作把全家的网关换掉。
    """

    // MARK: - 骨架

    private var skeleton: some View {
        VStack(spacing: 14) {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Bone(w: 90, h: 13)
                    Bone(w: 220, h: 26)
                    Bone(w: 150, h: 11)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Bone(w: 110, h: 13)
                    ForEach(0..<4, id: \.self) { _ in Bone(w: .infinity, h: 12) }
                }
            }
        }
    }

    // MARK: - 取数

    private func load() async {
        do {
            async let a = Api.get("/api/v1/network/wan")
            async let b = Api.get("/api/v1/network/firewall", cache: false)
            async let c = Api.get("/api/v1/net/pending", cache: false)
            let (w, f) = try await (a, b)
            // 待确认接口在旧版 Agent 上不存在，失败不影响主页面
            let p = (try? await c) ?? [:]
            await MainActor.run {
                wan = w
                fw = f
                pending = p
                loading = false
            }
        } catch {
            await MainActor.run {
                loading = false
            }
        }
    }

    // MARK: - 待确认

    private func confirm() {
        let token = pending.str("token")
        guard !token.isEmpty else { return }
        Task {
            do {
                _ = try await Api.post("/api/v1/net/confirm", ["token": token])
                await MainActor.run {
                    pending = [:]
                    popup = Popup(title: "已确认", body: "配置保留。")
                }
                await load()
            } catch {
                await MainActor.run { popup = Popup(title: "确认失败", body: errorText(error)) }
            }
        }
    }

    private func rollback() {
        let token = pending.str("token")
        guard !token.isEmpty else { return }
        Task {
            do {
                _ = try await Api.post("/api/v1/net/rollback", ["token": token])
                await MainActor.run {
                    pending = [:]
                    popup = Popup(title: "已还原", body: "路由器已回到改动之前的配置。")
                }
                await load()
            } catch {
                await MainActor.run { popup = Popup(title: "还原失败", body: errorText(error)) }
            }
        }
    }

    private func errorText(_ e: Error) -> String {
        (e as? ApiError)?.message ?? e.localizedDescription
    }
}
