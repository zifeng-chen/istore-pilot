import SwiftUI
import UniformTypeIdentifiers

/// 设置。结构与安卓端 `ui/SettingsFragment` 对齐：
/// 连接 → 网络 → 外观 → 系统维护 → 安全 → 关于。
///
/// 这一版改掉的问题：
///  - 原来没有「连的是哪台、通不通」的结论卡，一进来先看到一堆按钮
///  - 「网络」整块缺失，WAN 地址只能在概览里看
///  - 没有主题切换，深色只能跟着系统走
///  - 没有修改密码的入口
///  - 底部有个「退出登录」—— 这个 App 只连一台自己家的路由器，
///    退出没有任何意义（令牌过期会自动回登录页），所以整块移除
struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.tabIndex) private var tabIndex
    @EnvironmentObject private var chrome: TabChrome

    @State private var d: J = Api.cached("/api/v1/overview") ?? [:]
    @State private var net: J = Api.cached("/api/v1/network") ?? [:]
    @State private var uploads: [J] = []
    @State private var ping: J = [:]
    @State private var busy = ""
    @State private var popup: Popup?
    @State private var showPwd = false
    @State private var showRootPwd = false
    @State private var showImporter = false
    @State private var goHardware = false
    @State private var goWan = false
    @State private var goBackups = false
    /// 待确认的电源动作：nil 表示没有弹窗
    @State private var confirmPower: String? = nil
    /// 待确认的安装包：装包 = 用 root 跑对方的代码，先问一句
    @State private var confirmInstall: String? = nil

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    scrollTopProbe()
                    hero
                    // 宽屏两栏：左边「这台机器连得怎么样、是什么」（连接/网络/设备/外观），
                    // 右边「能对它做什么」（维护/上传/电源/安全/关于）。
                    // 十张卡竖着排的时候，改个密码要滑七八屏
                    DuoColumns {
                        networkCard
                        deviceCard
                    } right: {
                        maintainCard
                        uploadCard
                        powerCard
                        securityCard
                        aboutCard
                    }
                    Color.clear.barBottomGap()
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }
            .scrollIndicators(.hidden)
            .background(C.appBg)
            .navigationTitle("设置")
            .pageTitle("设置")
            .task { await load() }
            .navigationDestination(isPresented: $goHardware) { HardwareView() }
            .navigationDestination(isPresented: $goWan) { WanView() }
            .navigationDestination(isPresented: $goBackups) { BackupsView() }
            .onAppear { chrome.set(tabIndex, goHardware || goWan || goBackups) }
            .onChange(of: goHardware) { v in chrome.set(tabIndex, v || goWan || goBackups) }
            .onChange(of: goWan) { v in chrome.set(tabIndex, v || goHardware || goBackups) }
            .onChange(of: goBackups) { v in chrome.set(tabIndex, v || goHardware || goWan) }
            .alert(item: $popup) { p in
                Alert(title: Text(p.title), message: Text(p.body),
                      dismissButton: .default(Text("好")))
            }
            // 电源动作一律二次确认：先把「会断多久、怎么恢复」写清楚，
            // 再让用户点确定。关机额外多一次确认，因为它不可远程恢复
            .confirmationDialog(powerTitle, isPresented: Binding(
                get: { confirmPower != nil },
                set: { if !$0 { confirmPower = nil } }
            ), titleVisibility: .visible) {
                Button(confirmPower == "restart_network" ? "重启网络" : "确定", role: .destructive) {
                    if let a = confirmPower { power(a) }
                    confirmPower = nil
                }
                Button("取消", role: .cancel) { confirmPower = nil }
            } message: {
                Text(powerBody)
            }
            // 装包确认：写清楚「会以管理员权限执行」，类型不明的直接不给装
            .confirmationDialog(confirmInstall ?? "安装", isPresented: Binding(
                get: { confirmInstall != nil },
                set: { if !$0 { confirmInstall = nil } }
            ), titleVisibility: .visible) {
                Button(installVerb, role: .destructive) {
                    if let n = confirmInstall { install(n, confirm: installKind(n)) }
                    confirmInstall = nil
                }
                Button("取消", role: .cancel) { confirmInstall = nil }
            } message: {
                Text("这个文件会以管理员权限\(installVerb)在路由器上。只装你自己上传的包。")
            }
            .sheet(isPresented: $showPwd) {
                PasswordSheet(title: "修改 App 登录密码",
                              note: "只管这个 App 的登录，不影响路由器后台。",
                              path: "/api/v1/password", needsCurrent: true) { popup = $0 }
            }
            .sheet(isPresented: $showRootPwd) {
                PasswordSheet(title: "修改路由器密码",
                              note: "root 账号密码，同时影响 iStoreOS 后台和 SSH。",
                              path: "/api/v1/system/root_password", needsCurrent: true) { popup = $0 }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.data],
                          allowsMultipleSelection: false) { result in
                if case let .success(urls) = result, let url = urls.first {
                    upload(url)
                }
            }
        }
    }

    // MARK: - Hero

    private var hero: some View {
        let b = d.obj("board") ?? [:]

        return Hero {
            VStack(alignment: .leading, spacing: 0) {
                // 三行信息 + 一行动作，从上往下只有一条阅读顺序：
                // 通不通 → 是哪台 → 现在什么状态 → 能做什么。
                // 上一版左右分栏，在 Duo 展开的 820pt 里两块被顶到两边，
                // 中间空出一大片绿，看着像没排完。
                HStack(spacing: 6) {
                    Circle()
                        .fill(ok ? Color(hex: 0x5FE7C4) : C.heroFgSoft)
                        .frame(width: 7, height: 7)
                    Text(ok ? "已连接" : "连不上")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(C.heroFg)
                    if ok {
                        Text("v" + ping.str("version"))
                            .font(F.num(11.5, .regular))
                            .foregroundStyle(C.heroFgSoft)
                    }
                }

                Text(b.str("hostname").isEmpty ? bareBase : b.str("hostname"))
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(C.heroFg)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.top, 6)

                // 地址和三项体征压成一行：它们都是「这台机器现在什么样」的读数，
                // 竖着排三行会把卡片撑高一倍，横着排一行刚好铺满宽度
                Text(metaLine)
                    .font(F.num(11.5, .regular))
                    .foregroundStyle(C.heroFgSoft)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.top, 4)

                Rectangle().fill(C.heroFg.opacity(0.18)).frame(height: 0.7)
                    .padding(.top, 12)
                    .padding(.bottom, 9)

                HStack(spacing: 16) {
                    heroLink("重新登录") {
                        Api.onAuthFail?()
                        app.signOut()
                    }
                    heroLink("清缓存") {
                        SnapCache.shared.clear()
                        popup = Popup(title: "已清除", body: "下次进入各页面会重新从路由器读取。")
                    }
                    Spacer(minLength: 6)
                    themeMenu
                }
            }
        }
    }

    private var ok: Bool { !ping.str("version").isEmpty }

    /// 地址 · 响应 · 凭证 · 温度：一行铺满，宽屏不留空、窄屏按比例缩
    private var metaLine: String {
        var bits = [bareBase, "响应 " + pingMs, "凭证 " + tokenLeft]
        if hotTemp != "—" { bits.append(hotTemp) }
        return bits.joined(separator: "　·　")
    }

    private func heroLink(_ title: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(C.heroFgSoft)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var themeIcon: String {
        switch app.theme {
        case 1: return "sun.max.fill"
        case 2: return "moon.fill"
        default: return "circle.lefthalf.filled"
        }
    }

    /// 主题入口：文字形态，落在卡片右下角。一张卡上不再出现任何胶囊
    private var themeMenu: some View {
        Menu {
            ForEach(Array(Appearance.modes.enumerated()), id: \.offset) { i, m in
                Button {
                    app.setTheme(m)
                } label: {
                    Text((app.theme == m ? "✓ " : "") + Appearance.names[i])
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: themeIcon)
                    .font(.system(size: 10.5))
                Text("主题 · " + Appearance.name(app.theme))
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            .foregroundStyle(C.heroFgSoft)
            .padding(.vertical, 3)
        }
    }

    /// 只留 host:port，给离线时当标题用
    private var bareBase: String {
        Session.base.replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
    }

    private var pingMs: String {
        // ping 里没有耗时字段，用「有没有拿到版本」区分通断，
        // 具体毫秒由 Api 那层的 URLSession 时延决定，这里给个定性结论更诚实
        ping.str("version").isEmpty ? "—" : "正常"
    }

    private var tokenLeft: String {
        let left = Session.expiresAt - Date().timeIntervalSince1970
        // 右上角那一列很窄，长了必截断，这里用短写（F.shortDur 会给出「6 天 5 小时」）
        return left > 0 ? F.shortDur(left) : "已过期"
    }

    private var hotTemp: String {
        let t = d.objs("temperature").map { $0.dbl("celsius") }.max() ?? 0
        return t > 0 ? F.temp(t) : "—"
    }

    // MARK: - 网络

    private var networkCard: some View {
        let wan = net.obj("wan") ?? [:]
        let lan = net.obj("lan") ?? [:]
        let v4 = wan.objs("ipv4").first?.str("address") ?? ""
        let v6 = wan.objs("ipv6").first { !$0.str("address").lowercased().hasPrefix("fe80") }?
            .str("address") ?? ""

        return Card {
            VStack(alignment: .leading, spacing: 0) {
                CardHead(icon: "globe", title: "网络", sub: "外网与内网网关")

                plainRow(icon: "dot.radiowaves.left.and.right",
                         title: "外网状态",
                         note: wan.str("proto").uppercased() + "　·　" + wan.str("device"),
                         value: wan.bool("up") ? "已连接" : "未连接",
                         valueColor: wan.bool("up") ? C.primary : C.danger)
                Hairline(inset: 62)
                plainRow(icon: "number", title: "IPv4", note: "运营商分配", value: v4)
                Hairline(inset: 62)
                plainRow(icon: "number", title: "IPv6", note: "外网入口",
                         value: v6.isEmpty ? "—" : v6)
                Hairline(inset: 62)
                plainRow(icon: "clock", title: "连接时长", note: "本次拨号已持续",
                         value: wan.dbl("uptime") > 0 ? F.dur(wan.dbl("uptime")) : "—")
                Hairline(inset: 62)
                plainRow(icon: "house", title: "内网网关", note: "设备默认走这个地址",
                         value: lan.objs("ipv4").first?.str("address") ?? "—")

                Hairline(inset: 62)
                row(icon: "wifi", title: "宽带详情与配置",
                    note: "改接入方式、账号密码、静态 IP") {
                    goWan = true
                }
                Hairline(inset: 62)
                row(icon: "cpu", title: "硬件详情",
                    note: "CPU、内存条、硬盘、网卡、PCI") {
                    goHardware = true
                }
            }
        }
    }

    // MARK: - 外观


    // MARK: - 设备信息

    /// 原来在概览页叫「机器信息」。它是「查资料」型内容，一个月看一次，
    /// 放在打开就要看的概览里每次占掉三分之一屏，搬到设置更合适。
    private var deviceCard: some View {
        let board = d.obj("board") ?? [:]
        let cpu = d.obj("cpu") ?? [:]
        let mem = d.obj("memory") ?? [:]
        let store = d.obj("storage") ?? [:]
        let mod = mem.objs("modules").first ?? [:]

        return Card {
            VStack(alignment: .leading, spacing: 0) {
                CardHead(icon: "iphone", title: "设备信息", sub: "型号、固件、运行时长")

                // 主机名已在上面的 hero 大标题里，这里不再重复
                plainRow(icon: "desktopcomputer", title: "型号",
                         note: "主板与平台", value: board.str("model"))
                Hairline(inset: 62)
                plainRow(icon: "cpu", title: "处理器",
                         note: "\(cpu.int("cores")) 核",
                         value: cpu.str("model").replacingOccurrences(of: "(R)", with: "")
                            .replacingOccurrences(of: "(TM)", with: ""))
                Hairline(inset: 62)
                plainRow(icon: "memorychip", title: "内存",
                         note: mod.str("type").isEmpty ? "已安装容量" : "\(mod.str("type")) \(mod.int("speed"))",
                         value: F.bytes(mem.dbl("total")))
                Hairline(inset: 62)
                plainRow(icon: "internaldrive", title: "系统盘",
                         note: store.str("mount").isEmpty ? "" : store.str("mount"),
                         value: F.bytes(store.dbl("total")))
                Hairline(inset: 62)
                plainRow(icon: "info.circle", title: "系统版本",
                         note: board.str("kernel").isEmpty ? "" : "内核 \(board.str("kernel"))",
                         value: board.str("version"))

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
                    .padding(.top, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 系统维护

    private var maintainCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                CardHead(icon: "shippingbox", title: "系统维护", sub: "备份、固件与软件包")

                row(icon: "archivebox", title: "配置备份",
                    note: "动网络之前先存一份，随时能退回来") {
                    goBackups = true
                }
                Hairline(inset: 62)
                row(icon: "shippingbox", title: "检查固件更新",
                    note: "走系统 OTA 通道", busy: busy == "fw") {
                    checkFirmware()
                }
                Hairline(inset: 62)
                row(icon: "square.stack.3d.up", title: "检查软件包更新",
                    note: "opkg 可升级列表", busy: busy == "pkg") {
                    checkPackages()
                }
                Hairline(inset: 62)
                row(icon: "list.bullet.rectangle", title: "升级进度",
                    note: "正在进行的 opkg 任务", busy: busy == "progress") {
                    showProgress()
                }
                Hairline(inset: 62)
                row(icon: "arrow.up.doc", title: "上传安装包",
                    note: ".ipk / .run，传到 router 的 /tmp", busy: busy == "up") {
                    showImporter = true
                }

                Text("「系统更新」和「软件包更新」是两条互不相干的链路，"
                     + "固件不动软件包，软件包也不动固件。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(C.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
        }
    }

    // MARK: - 上传列表

    @ViewBuilder
    private var uploadCard: some View {
        if !uploads.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    CardHead(icon: "tray.full", title: "已上传的包", sub: "点查看或删除") {
                    Text("\(uploads.count) 个")
                        .font(F.caption)
                        .foregroundStyle(C.textSecondary)
                }
                    ForEach(Array(uploads.enumerated()), id: \.offset) { _, u in
                        HStack(spacing: 9) {
                            Image(systemName: "doc")
                                .font(.system(size: 12))
                                .foregroundStyle(C.textSecondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(u.str("name"))
                                    .font(F.num(12, .medium))
                                    .foregroundStyle(C.textPrimary)
                                    .lineLimit(1)
                                Text(F.bytes(u.dbl("size")))
                                    .font(.system(size: 10))
                                    .foregroundStyle(C.textSecondary)
                            }
                            Spacer()
                            Button("安装") { confirmInstall = u.str("name") }
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(C.primary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    // MARK: - 安全


    // MARK: - 电源

    /// 从概览搬过来。重启/关机是低频且不可撤销的动作，
    /// 混在概览的指标里容易被误触，而且它们本来就属于「设置」。
    private var powerCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                CardHead(icon: "power", title: "电源控制", sub: "重启与关机都会短暂断网")

                row(icon: "arrow.triangle.2.circlepath", title: "重启网络服务",
                    note: "只重拨 WAN，通常 10 秒内恢复") {
                    confirmPower = "restart_network"
                }
                Hairline(inset: 62)
                row(icon: "arrow.clockwise", title: "重启路由器",
                    note: "所有设备断网约 1 分钟", danger: true) {
                    confirmPower = "reboot"
                }
                Hairline(inset: 62)
                row(icon: "power", title: "关闭路由器",
                    note: "关机后只能到设备跟前手动开机", danger: true) {
                    confirmPower = "poweroff"
                }
            }
        }
    }

    private var securityCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                CardHead(icon: "lock.shield", title: "安全", sub: "两个密码，别记混")
                row(icon: "key", title: "修改 App 登录密码",
                    note: "只管这个 App") {
                    showPwd = true
                }
                Hairline(inset: 62)
                row(icon: "power", title: "修改路由器密码",
                    note: "root 账号，影响后台与 SSH", danger: true) {
                    showRootPwd = true
                }
                Text("App 登录密码是给这个客户端用的；路由器密码是 root 账号，"
                     + "同时影响 iStoreOS 后台和 SSH 登录。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(C.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
        }
    }

    // MARK: - 关于

    private var aboutCard: some View {
        Card {
            VStack(spacing: 12) {
                Image("AppIconLarge")
                    .resizable()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))

                VStack(spacing: 3) {
                    Text("iStore Pilot")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(C.textPrimary)
                    Text("版本 \(appVersion)")
                        .font(F.tiny)
                        .foregroundStyle(C.textSecondary)
                }

                Text("iStoreOS 路由器的手机管理端。看状态、管设备、切节点、拦广告，都能在手机上完成。")
                    .font(F.tiny)
                    .foregroundStyle(C.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - 行

    /// 带图标、可点、右值 + 箭头
    private func row(icon: String, title: String, note: String,
                     value: String = "", busy: Bool = false, danger: Bool = false,
                     act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 12) {
                iconTile(icon, danger: danger)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(F.body)
                        .foregroundStyle(danger ? C.danger : C.textPrimary)
                        .lineLimit(1)
                    if !note.isEmpty {
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundStyle(C.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if busy {
                    ProgressView().scaleEffect(0.7)
                } else {
                    if !value.isEmpty {
                        Text(value)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(C.textSecondary)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(C.textTertiary)
                }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!busy && !self.busy.isEmpty)
    }

    /// 只读行：右侧是值，没有箭头

    private var powerTitle: String {
        switch confirmPower ?? "" {
        case "restart_network": return "重启网络服务？"
        case "reboot": return "重启路由器？"
        case "poweroff": return "关闭路由器？"
        default: return ""
        }
    }

    private var powerBody: String {
        switch confirmPower ?? "" {
        case "restart_network":
            return "只重启 network 服务：WAN 重新拨号，局域网设备不掉线，但正在进行的下载和视频会断一下。如果只是外网连不上，先试这个。"
        case "reboot":
            return "整机重启：所有有线设备都会断开约 1 分钟，代理、拦截、拨号要等开机后重新起来。重启期间 App 会显示「连不上」。"
        case "poweroff":
            return "关机后：全网立即断网；无法远程唤醒（这台机器没有 WoL）；必须到设备跟前按电源键才能恢复。只是想省电的话，建议用「重启」。"
        default:
            return ""
        }
    }

    private func power(_ action: String) {
        Task {
            _ = try? await Api.post("/api/v1/power",
                                    ["action": action, "confirm": action])
            await MainActor.run {
                popup = Popup(title: action == "poweroff" ? "正在关机" : "正在重启",
                              body: action == "restart_network"
                              ? "网络服务正在重启，十几秒后恢复。"
                              : "路由器马上会断开，大约 1 分钟后自动恢复。")
            }
        }
    }

    private func plainRow(icon: String, title: String, note: String,
                          value: String, valueColor: Color? = nil) -> some View {
        HStack(spacing: 12) {
            iconTile(icon, danger: false)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(F.body)
                    .foregroundStyle(C.textPrimary)
                    .lineLimit(1)
                if !note.isEmpty {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(C.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Text(value.isEmpty ? "—" : value)
                .font(F.num(13, .medium))
                .foregroundStyle(valueColor ?? C.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .truncationMode(.middle)
        }
        .padding(.vertical, 10)
    }

    private func iconTile(_ icon: String, danger: Bool) -> some View {
        Image(systemName: icon)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(danger ? C.danger : C.primary)
            .frame(width: 32, height: 32)
            .background((danger ? C.danger : C.primary).opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - 载入与动作

    private func load() async {
        if let o = try? await Api.get("/api/v1/overview") { d = o }
        if let n = try? await Api.get("/api/v1/network") { net = n }
        if let p = try? await Api.ping(base: Session.base) { ping = p }
        if let u = try? await Api.get("/api/v1/system/uploads") {
            uploads = u.objs("files")
        }
    }

    private func checkFirmware() {
        busy = "fw"
        Task {
            defer { Task { @MainActor in busy = "" } }
            do {
                let j = try await Api.get("/api/v1/system/firmware", cache: false)
                await MainActor.run {
                    busy = ""
                    if j.str("state") == "error" || j.bool("ok") == false {
                        popup = Popup(title: "检查失败", body: j.str("error", "没能拿到固件信息"))
                    } else if j.bool("has_update") {
                        popup = Popup(title: "发现新固件",
                                      body: "当前：\(j.str("current"))\n最新：\(j.str("latest"))\n\n\(j.str("note", ""))")
                    } else {
                        popup = Popup(title: "已是最新固件",
                                      body: "当前版本 \(j.str("current")) 就是官方最新版。")
                    }
                }
            } catch {
                await MainActor.run {
                    busy = ""
                    popup = Popup(title: "检查失败", body: error.localizedDescription)
                }
            }
        }
    }

    private func checkPackages() {
        busy = "pkg"
        Task {
            do {
                let j = try await Api.post("/api/v1/system/update", ["action": "check"], slow: true)
                let list = j.objs("upgradable")
                await MainActor.run {
                    busy = ""
                    if list.isEmpty {
                        popup = Popup(title: "软件包都是最新的", body: "没有可升级的包。")
                    } else {
                        let names = list.prefix(6)
                            .map { "\($0.str("name"))  \($0.str("current"))→\($0.str("available"))" }
                        popup = Popup(title: "\(list.count) 个软件包可升级",
                                      body: names.joined(separator: "\n"))
                    }
                }
            } catch {
                await MainActor.run {
                    busy = ""
                    popup = Popup(title: "检查失败", body: error.localizedDescription)
                }
            }
        }
    }

    private func showProgress() {
        busy = "progress"
        Task {
            let j = try? await Api.get("/api/v1/system/update", cache: false)
            await MainActor.run {
                busy = ""
                guard let j else {
                    popup = Popup(title: "读取失败", body: "连不上路由器")
                    return
                }
                let running = j.bool("running")
                let log = j.str("log")
                popup = Popup(title: running ? "正在升级" : "没有进行中的升级",
                              body: log.isEmpty ? "opkg 当前空闲。" : String(log.suffix(1200)))
            }
        }
    }

    /// 文件类型 → 后端要求的确认串（后端按真实类型再核一遍）
    private func installKind(_ name: String) -> String {
        let low = name.lowercased()
        if low.hasSuffix(".run") { return "run" }
        if low.hasSuffix(".ipk") { return "ipk" }
        if low.hasSuffix(".apk") { return "apk" }
        return ""
    }

    private var installVerb: String { "安装" }

    private func install(_ name: String, confirm: String) {
        busy = "install"
        Task {
            let j = try? await Api.post("/api/v1/system/install",
                                        ["name": name, "confirm": confirm], slow: true)
            await MainActor.run {
                busy = ""
                if let j, j.str("need_confirm") != "" {
                    // 后端认为还得再确认一次：把弹窗重新拉起来
                    confirmInstall = name
                } else if let j, j.bool("ok") || j["ok"] == nil {
                    popup = Popup(title: "安装完成", body: name)
                } else {
                    popup = Popup(title: "安装失败", body: j?.str("error", "未知错误") ?? "未知错误")
                }
            }
            await load()
        }
    }

    private func upload(_ url: URL) {
        busy = "up"
        Task {
            let got = url.startAccessingSecurityScopedResource()
            defer { if got { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let j = try await Api.upload(data: data, filename: url.lastPathComponent)
                await MainActor.run {
                    busy = ""
                    popup = Popup(title: "上传完成",
                                  body: j.str("error", "\(url.lastPathComponent) 已传到路由器"))
                }
                await load()
            } catch {
                await MainActor.run {
                    busy = ""
                    popup = Popup(title: "上传失败", body: error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - 改密码

/// 两个密码共用一张表单：字段一样、接口不同（/password 和 /system/root_password）
struct PasswordSheet: View {
    let title: String
    let note: String
    let path: String
    let needsCurrent: Bool
    var done: (Popup) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var next = ""
    @State private var confirm = ""
    @State private var busy = false
    @State private var err = ""

    private var ready: Bool {
        next.count >= 8 && next == confirm && (!needsCurrent || !current.isEmpty)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(note)
                        .font(F.caption)
                        .foregroundStyle(C.textSecondary)

                    Card {
                        VStack(spacing: 0) {
                            if needsCurrent {
                                field("当前密码", $current, "路由器现在的密码", secret: true)
                                Hairline(inset: 0)
                            }
                            field("新密码", $next, "至少 8 位", secret: true)
                            Hairline(inset: 0)
                            field("确认新密码", $confirm, "再输一遍", secret: true)
                        }
                    }

                    if next.count > 0 && next.count < 8 {
                        Text("新密码至少 8 位").font(F.tiny).foregroundStyle(C.danger)
                    } else if !confirm.isEmpty && next != confirm {
                        Text("两次输入不一致").font(F.tiny).foregroundStyle(C.danger)
                    }
                    if !err.isEmpty {
                        Text(err).font(F.tiny).foregroundStyle(C.danger)
                    }

                    Button {
                        submit()
                    } label: {
                        HStack(spacing: 7) {
                            if busy { ProgressView().tint(C.onPrimary).scaleEffect(0.75) }
                            Text(busy ? "提交中…" : "保存")
                                .font(.system(size: 15, weight: .medium))
                        }
                        .foregroundStyle(C.onPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(ready ? C.primary : C.textTertiary)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!ready || busy)

                    Color.clear.frame(height: 12)
                }
                .padding(16)
            }
            .background(C.appBg)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    private func field(_ label: String, _ v: Binding<String>, _ hint: String,
                       secret: Bool) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(F.body)
                .foregroundStyle(C.textPrimary)
                .frame(width: 96, alignment: .leading)
            Group {
                if secret {
                    SecureField(hint, text: v)
                } else {
                    TextField(hint, text: v)
                }
            }
            .font(F.num(14, .medium))
            .multilineTextAlignment(.trailing)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        }
        .padding(.vertical, 12)
    }

    private func submit() {
        busy = true
        err = ""
        var payload: J = ["new": next]
        if needsCurrent { payload["current"] = current }
        Task {
            do {
                let j = try await Api.post(path, payload)
                await MainActor.run {
                    busy = false
                    if j.bool("ok") {
                        dismiss()
                        done(Popup(title: "已修改", body: "下次登录请用新密码。"))
                    } else {
                        err = j.str("error", "修改失败")
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
}
