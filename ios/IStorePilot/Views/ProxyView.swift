import SwiftUI

/// 代理：同时管 OpenClash 与 Passwall。
///
/// 结构照安卓 `ui/ProxyFragment` 复刻，一共 **hero + 两张卡**：
///   1. Hero：谁在跑 / 跑哪份配置 / 多少节点，**代理后端也在这里**（点一行切换）
///   2. 运行模式：分段直接切，下面一句讲清后果
///   3. 配置与节点：当前配置、订阅入口、节点按分组展开（单选点 + 延迟胶囊 + 整组测速）
///
/// 之前是四张卡：hero + 独立的「代理后端」卡 + 运行模式 + 「配置与订阅」+ 独立的「节点」卡。
/// 后端名在 hero 里写一遍、又在下面那张卡里写一遍，等于同一件事说两遍；
/// 配置和节点本来是一条链（换配置 → 重启内核 → 节点重读），拆成两张卡反而要来回看。
struct ProxyView: View {
    @State private var d: J = Api.cached("/api/v1/proxy") ?? [:]
    @State private var groups: [J] = Api.cached("/api/v1/proxy/groups").map { $0.objs("groups") } ?? []
    /// 节点区为什么空着（如「OpenClash 没在运行，启动后才看得到节点」）
    @State private var groupsErr = ""
    /// 「隐藏超时节点」：偏好存在路由器上（不是本机设置），几台设备 + Web 端读的是同一个值
    @State private var hideTimeout: Bool = false
    /// 服务端按偏好裁掉了几个
    @State private var hiddenCount: Int = 0
    @State private var cfg: J = Api.cached("/api/v1/proxy/configs") ?? [:]
    @State private var mode: String = ""
    @State private var loading = true
    @State private var err = ""
    @State private var showCfg = false
    @State private var goSubs = false
    @State private var busy = false
    /// 正在弹窗查看的分组。分组改成卡片之后不再就地展开：
    /// 一屏只有四张卡，点开哪个弹哪个，节点列表在自己的弹窗里滚
    @State private var openGroup: J? = nil
    @State private var testingGroup = ""
    /// 刚测出来的延迟，优先级高于接口里带的历史值
    @State private var tested: [String: Int] = [:]

    // ---- 安装包：本地传包 / 从仓库下
    // 这两个插件不在任何软件源里，GitHub 又常常打不开，所以必须有一条
    // 完全不依赖网络的路径：手机里传包上去。
    @State private var showPkg = false
    @State private var pkgItems: [J] = []
    @State private var pkgChan = ""
    /// 当前系统画像（如「24.10 · x86_64」）：仓库按版本+架构分开发，装错要先看见
    @State private var pkgSys = ""
    @State private var pkgTask: J = [:]
    @State private var pkgBusy = false
    @State private var pkgMsg = ""
    @State private var showImporter = false
    @State private var askTarget = ""
    @State private var askName = ""
    @State private var askSource = "github"
    @State private var showAsk = false
    /// 安装线程停在「改 hosts 等确认」时弹一次。Agent 侧最多等 5 分钟，
    /// 不弹框用户只会看到进度条不动，最后报超时
    /// 「改 hosts」确认框是否已弹过（Agent 侧最多等 5 分钟）
    @State private var askHosts = false
    @State private var hostsAsked = false
    /// 待卸载的后端。只能装不能卸的界面是残的
    @State private var uninstallTarget = ""
    /// 待停止的后端。运行中的行点一下就能停 —— 只能启动不能停止的界面是残的
    @State private var stopTarget = ""
    /// 「配置与节点」卡点名的后端。
    ///
    /// 订阅和节点**每个后端各一套**（OpenClash 的在 uci + 内核里，PassWall 的在
    /// uci 里），这张卡不可能同时管两个。有后端在跑时默认跟它，但允许切到另一个
    /// 去整理订阅 —— 切走后副标题会写明「只改配置」，别让人以为把代理切走了。
    @State private var comboPick = ""

    @Environment(\.tabIndex) private var tabIndex
    @Environment(\.barAxis) private var axis
    @EnvironmentObject private var chrome: TabChrome

    private let tick = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    private var backends: [J] { d.objs("backends") }
    private var active: String { d.str("active", "none") }
    private var backend: J {
        backends.first { $0.str("id") == active } ?? [:]
    }
    private var running: Bool { backend.bool("running") }

    /// 已安装的后端 id
    private var installedIDs: [String] {
        backends.filter { $0.bool("installed") }.map { $0.str("id") }
    }

    /// 「配置与节点」这张卡在管哪个后端：用户点名 > 正在运行 > 已装的（PassWall 优先）。
    ///
    /// 点名优先于「正在运行」是故意的：运行中的那个要跟（改配置立刻生效），
    /// 但另一个的订阅也得能整理，不能因为它在跑就把这张卡焊死。
    private var comboBackend: String {
        if !comboPick.isEmpty, installedIDs.contains(comboPick) { return comboPick }
        if active != "none" { return active }
        if installedIDs.contains("passwall") { return "passwall" }
        return installedIDs.first ?? ""
    }

    /// 这张卡管的后端是不是「正在跑的那个」：不是的话副标题要提醒只改配置
    private var comboIsActive: Bool { !active.isEmpty && active != "none" && comboBackend == active }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    scrollTopProbe()
                    hero
                    // 「运行模式」切的是「正在跑的那个后端」的流量走向，没跑就没得切。
                    // 这时整块不出现，否则用户以为自己在挑模式，其实点下去空转
                    if anyRunning() {
                        DuoColumns(rightFirstInNarrow: true) {
                            comboRegion
                        } right: {
                            modeCard
                        }
                    } else {
                        comboRegion
                    }
                    if !err.isEmpty {
                        Text(err).font(F.tiny).foregroundStyle(C.danger)
                    }
                    pkgCard
                    Color.clear.barBottomGap()
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }
            .scrollIndicators(.hidden)
            .background(C.appBg)
            .navigationTitle("代理")
            .pageTitle("代理")
            .navigationDestination(isPresented: $goSubs) {
                // 带上这张卡点名的后端：订阅各一套，进去必须看到对应的那份
                SubscriptionView(initialBackend: comboBackend)
            }
            .onAppear { chrome.set(tabIndex, goSubs) }
            .onChange(of: goSubs) { chrome.set(tabIndex, $0) }
            .task { await load() }
            .refreshable { await load() }
            .onReceive(tick) { _ in Task { await load() } }
            #if DEBUG
            // 截图用：-sub group 直接弹开第一个分组，省得手动点
            .onAppear {
                guard DebugRoute.sub == "group" else { return }
                Task {
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    openGroup = groups.first { !isAuto($0.str("name")) } ?? groups.first
                }
            }
            #endif
            .adaptiveSheet(isPresented: $showCfg) {
                ConfigPicker(current: cfg.str("current"),
                             items: cfg.objs("configs")) { path in
                    await switchConfig(path)
                }
            }
            .adaptiveSheet(isPresented: Binding(
                get: { openGroup != nil },
                set: { if !$0 { openGroup = nil } }
            )) {
                groupSheet
            }
            .adaptiveSheet(isPresented: $showPkg) { pkgSheet }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.data],
                          allowsMultipleSelection: false) { result in
                if case let .success(urls) = result, let url = urls.first {
                    uploadPkg(url)
                }
            }
            .alert("安装 \(askTarget == "openclash" ? "OpenClash" : "PassWall")",
                   isPresented: $showAsk) {
                Button("取消", role: .cancel) {}
                Button("开始安装") { Task { await doPkgInstall() } }
            } message: {
                Text(askSource == "local"
                     ? "会把 \(askName) 装到路由器上，过程中会以管理员权限执行包里的安装脚本。"
                     : "会从仓库下载 \(askName) 再安装。包大时（PassWall 约 85 MB）"
                     + "可能要十几分钟，中途别退出。")
            }
            .alert("停止 \(stopTarget == "openclash" ? "OpenClash" : "PassWall")？",
                   isPresented: Binding(
                    get: { !stopTarget.isEmpty },
                    set: { if !$0 { stopTarget = "" } }
                   )) {
                Button("取消", role: .cancel) { stopTarget = "" }
                Button("停止", role: .destructive) {
                    let id = stopTarget
                    stopTarget = ""
                    Task { await switchBackend(id, start: false) }
                }
            } message: {
                Text("停掉后所有流量走直连，已建立的连接会断一下。"
                     + "配置和订阅都留着，随时能再启动。")
            }
            .alert("GitHub 下载失败", isPresented: $askHosts) {
                Button("取消", role: .cancel) { postPkgConfirm("no") }
                Button("修改并重试") { postPkgConfirm("yes") }
            } message: {
                Text("所有加速通道都连不上。是否修改 hosts 后重试？")
            }
            .alert("卸载 \(labelOf(uninstallTarget))？",
                   isPresented: Binding(
                    get: { !uninstallTarget.isEmpty },
                    set: { if !$0 { uninstallTarget = "" } }
                   )) {
                Button("取消", role: .cancel) { uninstallTarget = "" }
                Button("卸载", role: .destructive) {
                    let id = uninstallTarget
                    uninstallTarget = ""
                    Task { await doUninstall(id) }
                }
            } message: {
                Text("会删掉插件本体。实测 OpenClash 的包会连配置和订阅一起清掉，"
                     + "重装后要重新粘一次订阅地址。")
            }
        }
    }

    // MARK: - 安装包

    private var pkgCard: some View {
        Card {
            Button {
                showPkg = true
                pkgMsg = ""
                Task { await loadPkg() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(C.primary)
                        .frame(width: 30, height: 30)
                        .background {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(C.accentSoft)
                        }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("安装包")
                            .font(.system(size: 14.5, weight: .medium))
                            .foregroundStyle(C.textPrimary)
                        Text(pkgSub)
                            .font(.system(size: 11.5))
                            .foregroundStyle(C.textSecondary)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(C.textTertiary)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var pkgSub: String {
        if pkgTask.bool("running") {
            return pkgTask.str("step", "正在安装")
        }
        if pkgBusy {
            return "正在上传…"
        }
        return "本地传包，不用路由器联网"
    }

    private var pkgSheet: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showImporter = true
                    } label: {
                        Label("从本地文件安装", systemImage: "folder")
                            .font(.system(size: 14.5))
                    }
                    if !pkgMsg.isEmpty {
                        Text(pkgMsg)
                            .font(F.tiny)
                            .foregroundStyle(C.danger)
                    }
                } header: {
                    Text("手机里的安装包")
                } footer: {
                    Text("选 .run / .ipk。这条路完全不依赖路由器能不能上外网。")
                }

                if !installedIDs.isEmpty {
                    Section {
                        ForEach(installedIDs, id: \.self) { id in
                            Button(role: .destructive) {
                                uninstallTarget = id
                            } label: {
                                Text("卸载 " + labelOf(id))
                                    .font(.system(size: 14.5))
                            }
                            .disabled(pkgBusy)
                        }
                    } header: {
                        Text("已安装")
                    } footer: {
                        Text("会删掉插件本体。OpenClash 的包会连配置和订阅一起清掉，"
                             + "重装后要重新粘一次订阅地址。")
                    }
                }

                Section {
                    if pkgItems.isEmpty {
                        Text("仓库清单读不到，只能用本地文件")
                            .font(F.tiny)
                            .foregroundStyle(C.textTertiary)
                    } else {
                        ForEach(Array(pkgItems.enumerated()), id: \.offset) { _, it in
                            Button {
                                ask(it.str("backend"), "github", it.str("file"))
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(it.str("label") + " " + it.str("version"))
                                        .font(.system(size: 14.5, weight: .medium))
                                        .foregroundStyle(C.textPrimary)
                                    Text(pkgNote(it))
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(C.textSecondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("从仓库下载")
                } footer: {
                    Text((pkgSys.isEmpty ? "" : "已按当前系统匹配：\(pkgSys)。\n")
                         + (pkgChan.isEmpty ? "" : "下载通道 \(pkgChan)。\n")
                         + "PassWall 约 80 MB，可能要十几分钟。")
                }
            }
            .navigationTitle("安装包")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showPkg = false }
                }
            }
        }
    }

    private func pkgNote(_ it: J) -> String {
        let local = it.str("local")
        var s: String
        if local.isEmpty {
            s = "未安装"
        } else if it.bool("newer") {
            s = "本机 \(local)，可升级"
        } else {
            s = "本机 \(local)，仓库里的更旧"
        }
        let conflict = it.str("conflict")
        if !conflict.isEmpty {
            s += " · 与 " + (conflict == "passwall" ? "PassWall" : "PassWall2") + " 冲突"
        }
        return s
    }

    // MARK: - Hero

    private var hero: some View {
        // 没后端在跑时不能写「直连」：「直连」是「后端在跑、模式选了直连」，
        // 和「装了但没启用」是两回事，写成直连会让人以为自己在用直连模式
        let title: String = running
            ? (cfg.str("current") as NSString).lastPathComponent
                .replacingOccurrences(of: ".yaml", with: "")
            : "未启用"
        let nodes = backend.int("node_count")
        let engine = backend.str("engine", "")
        var bits: [String] = []
        if !engine.isEmpty { bits.append(engine) }
        if nodes > 0 { bits.append("\(nodes) 个节点可用") }
        if !mode.isEmpty { bits.append(modeLabel(mode)) }
        if !running { bits = ["点上面任意一行启用；启用后这里显示当前出口"] }

        return Hero {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Circle().fill(running ? C.heroOn : C.heroOff)
                        .frame(width: 7, height: 7)
                    Text(running ? "运行中" : "都没在运行")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(C.heroFg)
                    Spacer()
                    // 没在跑时这里给「装了 N 个」，比一个「未启用」更有用：
                    // 它回答了「我到底装了几个、为什么还不能用」
                    Text(running ? backend.str("label", active)
                                 : "\(installedIDs.count) 个已安装")
                        .font(F.tiny)
                        .foregroundStyle(C.heroFgSoft)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Color.white.opacity(0.16))
                        .clipShape(Capsule())
                }
                Text(title)
                    .font(F.num(26, .semibold))
                    .foregroundStyle(C.heroFg)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, 10)
                Text(bits.joined(separator: "　·　"))
                    .font(.system(size: 12))
                    .foregroundStyle(C.heroFgSoft)
                    .lineLimit(1)
                    .padding(.top, 4)

                // 后端并进 hero：它是「这一页在管谁」的身份信息，本来就该跟状态放一起
                Text("代理后端 · 点一行切换")
                    .font(.system(size: 11))
                    .foregroundStyle(C.heroFgSoft)
                    .padding(.top, 16)

                VStack(spacing: 0) {
                    ForEach(Array(backends.enumerated()), id: \.offset) { i, b in
                        if i > 0 {
                            // hero 是深绿底，卡片那套 divider 色在上面看不见
                            Rectangle().fill(C.heroFg.opacity(0.16))
                                .frame(height: 0.7)
                                .padding(.top, 2)
                        }
                        backendRow(b)
                    }
                }
                .padding(.top, 4)
                .padding(.horizontal, -8)
            }
        }
    }

    /// hero 深色底上的小胶囊。
    ///
    /// 「运行中」用实心薄荷色 + 深色字，未运行只是描边 —— 原来两者都是
    /// 一层半透明白，两个后端的名字又都压到 62% 灰，扫一眼分不出谁在跑。
    private func heroPill(_ text: String, on: Bool) -> some View {
        Text(text)
            .font(.system(size: 11, weight: on ? .semibold : .medium))
            .foregroundStyle(on ? C.heroInk : C.heroFg.opacity(0.72))
            .padding(.horizontal, 10).padding(.vertical, 3.5)
            .background {
                if on {
                    Capsule().fill(C.heroOn)
                } else {
                    Capsule().strokeBorder(C.heroFg.opacity(0.28), lineWidth: 0.9)
                }
            }
    }

    private func backendRow(_ b: J) -> some View {
        let on = b.bool("running")
        let installed = b.bool("installed")
        let name = b.str("label", b.str("id"))
        let sub = installed
            ? (b.str("engine").isEmpty ? "" : b.str("engine") + " · ") + "\(b.int("node_count")) 个节点"
            : "未安装"

        return Button {
            guard installed, !busy else { return }
            if on {
                stopTarget = b.str("id")
            } else {
                Task { await switchBackend(b.str("id")) }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "power")
                    .font(.system(size: 13, weight: on ? .semibold : .medium))
                    .foregroundStyle(on ? C.heroInk : C.heroFg.opacity(0.55))
                    .frame(width: 30, height: 30)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(C.heroOn)
                        } else {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(C.heroFg.opacity(0.09))
                        }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    // 运行中的那个要一眼认出来：加粗 + 放大半档 + 满白。
                    // 只靠右侧胶囊不够，两个名字并排时视线先落在字上
                    Text(name)
                        .font(.system(size: on ? 16 : 15, weight: on ? .bold : .medium))
                        .foregroundStyle(on ? C.heroFg : C.heroFg.opacity(0.55))
                    if !sub.isEmpty {
                        Text(sub)
                            .font(.system(size: 11.5))
                            .foregroundStyle(C.heroFg.opacity(on ? 0.72 : 0.45))
                    }
                }
                Spacer(minLength: 6)
                heroPill(on ? "运行中" : (installed ? "未运行" : "未安装"), on: on)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            // 正在跑的那个垫一层浅底：光靠文字深浅在深绿渐变上不够看
            .background {
                if on {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(C.heroFg.opacity(0.10))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!installed || on || busy)
    }

    // MARK: - 运行模式

    private var modeCard: some View {
        let oc = active == "openclash"
        let labels = oc ? ["规则", "全局", "直连"] : ["代理", "直连"]
        let values = oc ? ["rule", "global", "direct"] : ["proxy", "disable"]
        let selected = values.firstIndex(of: mode) ?? 0

        return Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHead(icon: "bolt", title: "运行模式", sub: "改完立即生效") {
                    Text(modeLabel(mode))
                        .font(F.num(13.5, .medium))
                        .foregroundStyle(C.primary)
                }

                // 尺寸照安卓 Ui.segmented：外槽 34 高、圆角 10、内块圆角 8、字号 13.5
                HStack(spacing: 0) {
                    ForEach(Array(labels.enumerated()), id: \.offset) { i, t in
                        let on = i == selected
                        Button {
                            guard !busy, values[i] != mode else { return }
                            Task { await setMode(values[i]) }
                        } label: {
                            Text(t)
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundStyle(on ? C.textPrimary : C.textSecondary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 28)
                                .background {
                                    if on {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(C.segmentThumb)
                                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .strokeBorder(C.glassStroke, lineWidth: 0.7))
                                    }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(C.segmentTrack)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Text(modeHint(mode))
                    .font(.system(size: 11.5))
                    .foregroundStyle(C.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func modeLabel(_ m: String) -> String {
        switch m {
        case "rule": return "规则模式"
        case "global": return "全局模式"
        case "direct", "disable": return "直连模式"
        case "proxy": return "代理模式"
        default: return m.isEmpty ? "—" : m
        }
    }

    private func modeHint(_ m: String) -> String {
        if active == "openclash" {
            switch m {
            case "rule": return "按规则分流：命中的走节点，其余直连。日常用这个。"
            case "global": return "全部流量走当前节点，不看规则。节点选错会全家上不了网。"
            case "direct": return "不走代理，所有流量直连。"
            default: return "还没读到当前模式。"
            }
        }
        switch m {
        case "proxy": return "按 Passwall 规则分流：命中的走节点，其余直连。"
        case "disable": return "不走代理，所有流量直连。"
        default: return "还没读到当前模式。"
        }
    }

    // MARK: - 配置与节点

    /// 骨架 / 真卡片：拆出来是为了「没后端在跑时」能让它独占一行（不跟模式并排）
    @ViewBuilder
    private var comboRegion: some View {
        if loading {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Bone(w: 90, h: 15); Bone(h: 10); Bone(h: 10)
                }
            }
        } else {
            comboCard
        }
    }

    /// 这张卡管的后端。订阅、节点、配置文件全是各一套，必须先点名
    private var comboSub: String {
        // 切到「没在跑的那个」时必须说清楚：这里改的是它的配置，
        // 正在跑的后端不受影响 —— 否则用户以为刚把代理切走了
        if active != "none" && !comboIsActive {
            return "只改配置，不影响正在运行的 " + labelOf(active)
        }
        if comboBackend == "passwall" {
            return "PassWall 的节点来自订阅，没有配置文件"
        }
        if !comboIsActive {
            return "OpenClash 没在运行，启动后才看得到节点"
        }
        return "换配置会重启内核，断网十几秒"
    }

    private func labelOf(_ id: String) -> String {
        backends.first { $0.str("id") == id }.map { $0.str("label", id) } ?? id
    }

    /// 后端切换器：两个都装着才出现（只有一个时点不点都一样）
    private var comboPicker: some View {
        let labels = ["OpenClash", "PassWall"]
        let sel = comboBackend == "passwall" ? 1 : 0
        return HStack(spacing: 0) {
            ForEach(Array(labels.enumerated()), id: \.offset) { i, t in
                let on = i == sel
                Button {
                    let pick = i == 0 ? "openclash" : "passwall"
                    guard pick != comboBackend else { return }
                    comboPick = pick
                    Task { await load() }
                } label: {
                    Text(t)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(on ? C.textPrimary : C.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(C.segmentThumb)
                                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(C.glassStroke, lineWidth: 0.7))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(C.segmentTrack)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    private var comboCard: some View {
        let cur = cfg.str("current")
        let curName = (cur as NSString).lastPathComponent.replacingOccurrences(of: ".yaml", with: "")
        let sorted = groups.sorted { a, b in
            let aa = isAuto(a.str("name")), bb = isAuto(b.str("name"))
            if aa != bb { return aa }
            return false
        }

        return Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                CardHead(icon: "list.bullet", title: "配置与节点",
                         sub: comboSub)
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 10)

                if installedIDs.count >= 2 { comboPicker }

                // 当前配置：整行可点，右侧「切换」胶囊给出明确的可操作性。
                // PassWall 没有「配置文件」这个概念（节点直接来自订阅），整行藏掉
                if comboBackend == "openclash" {
                    HStack(spacing: 10) {
                        // 配置文件用文档图标：钥匙是「密码」的语义，安卓那边同款改过
                        Image(systemName: "doc.text")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(C.primary)
                            .frame(width: 30, height: 30)
                            .background(C.accentSoft)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("当前配置").font(F.body).foregroundStyle(C.textPrimary)
                            Text(curName.isEmpty ? "未选择" : curName)
                                .font(F.num(12, .regular))
                                .foregroundStyle(C.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 6)
                        Button {
                            showCfg = true
                        } label: {
                            Text("切换")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(C.primary)
                                .padding(.horizontal, 11).padding(.vertical, 5)
                                .background(C.accentSoft)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)

                    Hairline(inset: 18)
                }

                Button {
                    goSubs = true
                } label: {
                    HStack(spacing: 10) {
                        // 订阅是「链接」（订阅地址），不是上传 —— 跟安卓一致
                        Image(systemName: "link")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(C.primary)
                            .frame(width: 30, height: 30)
                            .background(C.accentSoft)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        Text("订阅管理").font(F.body).foregroundStyle(C.textPrimary)
                        Spacer(minLength: 6)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(C.textTertiary)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Hairline(inset: 18)

                // 节点分组：四个组各一张卡。原来是一行组名 + 就地展开几十个节点，
                // 展到第二个组就把配置那半屏顶走了；改成卡片点开弹窗，
                // 一屏永远只占四张卡的高度
                HStack(alignment: .center, spacing: 6) {
                    Text("节点分组")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(C.textSecondary)
                    Spacer(minLength: 6)
                    Text(hideTimeout
                         ? (hiddenCount > 0 ? "已隐藏 \(hiddenCount) 个" : "无超时节点")
                         : "隐藏超时")
                        .font(.system(size: 10.5))
                        .foregroundStyle(C.textTertiary)
                    Toggle("", isOn: Binding(
                        get: { hideTimeout },
                        set: { v in Task { await setHideTimeout(v) } }
                    ))
                    .labelsHidden()
                    .tint(C.primary)
                    .scaleEffect(0.78)
                    .frame(width: 40, height: 24)
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 8)

                if loading {
                    Text("读取中…").font(F.tiny).foregroundStyle(C.textSecondary)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                } else if sorted.isEmpty {
                    // 服务端会说明为什么空着（OpenClash 停着时就是「启动后才看得到」），
                    // 直接用它，别在这儿另编一句
                    Text(groupsErr.isEmpty
                         ? (anyRunning() ? "节点分组还没读取到，这块会自动重试" : "没有可用的节点")
                         : groupsErr)
                        .font(F.tiny)
                        .foregroundStyle(C.textSecondary)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10),
                                             count: groupCols),
                              spacing: 10) {
                        ForEach(Array(sorted.enumerated()), id: \.offset) { _, g in
                            groupCard(g)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 4)
                }
                Color.clear.frame(height: 6)
            }
        }
    }

    /// 有没有任意一个后端处于运行中：用来区分「没装/没启动」和「启动了但没读到分组」
    private func anyRunning() -> Bool {
        for i in 0..<backends.count where backends[i].bool("running") { return true }
        return false
    }

    /// 宽屏两列、窄屏一列：四张卡在手机上竖着排刚好一屏，平板上排两行也不浪费。
    private var groupCols: Int { axis == .rail ? 2 : 1 }

    private func groupType(_ g: J) -> String {
        switch g.str("type").lowercased() {
        case "selector": return "手动"
        case "urltest": return "自动测速"
        case "fallback": return "故障转移"
        case "loadbalance": return "负载均衡"
        case "relay": return "链式"
        default: return g.str("type").isEmpty ? "分组" : g.str("type")
        }
    }

    /// 一张分组卡：类型、组名、当前节点、节点数与它的延迟。
    /// 信息刚好够判断「要不要点进去换」，换节点的动作交给弹窗。
    private func groupCard(_ g: J) -> some View {
        let name = g.str("name")
        let now = infoNode(g.str("now")) ? "" : g.str("now")
        let members = g.objs("members").filter { !infoNode($0.str("name")) }
        let delay = tested[now] ?? (members.first { $0.str("name") == now }?.int("delay") ?? 0)

        return Button {
            openGroup = g
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(groupType(g))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(C.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(C.surfaceHi)
                        .clipShape(Capsule())
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(C.textTertiary)
                        .frame(width: 16, height: 16)
                        .background(C.surfaceHi)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }

                Text(name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(C.textPrimary)
                    .lineLimit(1)
                    .padding(.top, 7)

                Spacer(minLength: 8)

                Text(now.isEmpty ? "未选择" : now)
                    .font(.system(size: 12))
                    .foregroundStyle(now.isEmpty ? C.textTertiary : C.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                HStack(spacing: 6) {
                    Text("\(members.count) 个节点")
                        .font(F.num(10, .regular))
                        .foregroundStyle(C.textTertiary)
                    Spacer(minLength: 2)
                    if delay > 0 {
                        Text("\(delay)ms")
                            .font(F.num(10, .medium))
                            .foregroundStyle(delayColor(delay))
                            .padding(.horizontal, 6).padding(.vertical, 1.5)
                            .background(delayColor(delay).opacity(0.14))
                            .clipShape(Capsule())
                    }
                }
                .padding(.top, 4)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .background(C.surfaceSunken)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(C.glassStroke, lineWidth: 0.7)
            )
        }
        .buttonStyle(.plain)
    }

    private func memberRow(_ m: J, group: String, current: String) -> AnyView {
        let name = m.str("name")
        if infoNode(name) { return AnyView(EmptyView()) }
        let on = name == current
        let policy = isPolicy(name)
        let tint: Color = on
            ? (isReject(name) ? C.danger : (policy ? C.textSecondary : C.primary))
            : (policy ? C.textSecondary : C.textPrimary)
        let delay = tested[name] ?? m.int("delay")

        return AnyView(Button {
            guard !busy else { return }
            Task {
                await selectNode(group: group, node: name)
                openGroup = nil
            }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .strokeBorder(on ? tint : C.textTertiary, lineWidth: 1.4)
                        .frame(width: 15, height: 15)
                    if on {
                        Circle().fill(tint).frame(width: 7, height: 7)
                    }
                }
                Text(name)
                    .font(.system(size: 14))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                Spacer()
                if delay > 0 {
                    Text("\(delay)ms")
                        .font(F.num(11, .medium))
                        .foregroundStyle(delayColor(delay))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(delayColor(delay).opacity(0.16))
                        .clipShape(Capsule())
                } else if m.bool("is_group") {
                    Text("组").font(.system(size: 11)).foregroundStyle(C.textSecondary)
                } else {
                    Text("—").font(.system(size: 11)).foregroundStyle(C.textTertiary)
                }
            }
            .padding(.horizontal, 15).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain))
    }

    // MARK: - 分组弹窗

    /// 点开的分组：整屏一列节点，带测速。宽度跟着窗口走，
    /// 不再受系统 sheet 那套尺寸推导影响（见 `adaptiveSheet`）。
    private var groupSheet: some View {
        let g = openGroup ?? [:]
        let name = g.str("name")
        let now = infoNode(g.str("now")) ? "" : g.str("now")
        let members = g.objs("members")

        return NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(now.isEmpty ? "当前未选择" : "当前 " + now)
                            .font(.system(size: 12))
                            .foregroundStyle(now.isEmpty ? C.textTertiary : C.primary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text("\(members.count) 个节点")
                            .font(F.num(11.5, .regular))
                            .foregroundStyle(C.textTertiary)
                    }
                    .padding(.horizontal, 4)

                    ListGroup {
                        ForEach(Array(members.enumerated()), id: \.offset) { i, m in
                            memberRow(m, group: name, current: now)
                            if i < members.count - 1 { Hairline(inset: 15) }
                        }
                    }

                    Color.clear.frame(height: 18)
                }
                .padding(16)
            }
            .scrollIndicators(.hidden)
            .background(C.appBg)
            .navigationTitle(name.isEmpty ? "节点" : name)
            .navigationBarTitleDisplayMode(.inline)
            .navBarChrome()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { openGroup = nil }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(testingGroup.isEmpty ? "测速" : "测速中…") { testGroup(name) }
                        .disabled(!testingGroup.isEmpty || name.isEmpty)
                }
            }
        }
    }

    private func isAuto(_ s: String) -> Bool {
        let k = s.lowercased()
        return k.contains("自动") || k.contains("auto") || k.contains("urltest")
            || k.contains("fallback") || k == "global"
    }

    private func infoNode(_ s: String) -> Bool {
        ["剩余流量", "距离下次", "套餐到期", "到期时间", "官网", "订阅", "重置"]
            .contains { s.hasPrefix($0) }
    }

    private func isReject(_ s: String) -> Bool {
        let u = s.uppercased()
        return u.hasPrefix("REJECT") || u.hasPrefix("DROP") || u == "PASS"
    }

    private func isPolicy(_ s: String) -> Bool {
        isReject(s) || s.uppercased() == "DIRECT"
    }

    private func delayColor(_ ms: Int) -> Color {
        if ms <= 0 { return C.textTertiary }
        if ms < 150 { return C.ok }
        if ms < 350 { return C.warn }
        return C.danger
    }

    // MARK: - 动作

    // MARK: - 安装包（逻辑）

    private func loadPkg() async {
        do {
            let j = try await Api.get("/api/v1/proxy/pkg/catalog", cache: false)
            await MainActor.run {
                pkgItems = j.objs("items")
                pkgChan = j.str("channel")
                let fam = j.str("family")
                let arch = j.str("arch")
                pkgSys = fam.isEmpty ? "" : (arch.isEmpty ? fam : fam + " · " + arch)
                if !j.bool("ok") {
                    pkgMsg = "仓库里没找到安装包，可以改用本地文件"
                }
            }
        } catch {
            await MainActor.run {
                pkgMsg = "拿不到清单：\(error.localizedDescription)"
            }
        }
    }

    /// 文件名推后端：AUK9527 的包名里一定带 OpenClash / PassWall
    private static func targetOf(_ name: String) -> String {
        let low = name.lowercased()
        if low.contains("openclash") {
            return "openclash"
        }
        if low.contains("passwall") {
            return "passwall"
        }
        return ""
    }

    private func uploadPkg(_ url: URL) {
        pkgBusy = true
        pkgMsg = ""
        Task {
            let got = url.startAccessingSecurityScopedResource()
            defer { if got { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let j = try await Api.upload(data: data, filename: url.lastPathComponent)
                await MainActor.run {
                    pkgBusy = false
                    let saved = j.str("name", url.lastPathComponent)
                    let t = Self.targetOf(saved)
                    if t.isEmpty {
                        pkgMsg = "文件名里要带 OpenClash 或 PassWall，否则分不清装哪个"
                        return
                    }
                    ask(t, "local", saved)
                }
            } catch {
                await MainActor.run {
                    pkgBusy = false
                    pkgMsg = "上传失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func ask(_ target: String, _ source: String, _ name: String) {
        askTarget = target
        askSource = source
        askName = name
        showAsk = true
    }

    private func doPkgInstall() async {
        // 每次新装都允许再问一次「要不要改 hosts」
        await MainActor.run { hostsAsked = false }
        let body: J = [
            "target": askTarget, "source": askSource,
            "name": askName, "confirm": "install",
        ]
        do {
            let r = try await Api.post("/api/v1/proxy/pkg/install", body)
            if !r.bool("ok") {
                await MainActor.run { pkgMsg = r.str("error", "启动安装失败") }
                return
            }
            await MainActor.run { showPkg = false }
            await pollPkg()
        } catch {
            await MainActor.run { pkgMsg = "启动失败：\(error.localizedDescription)" }
        }
    }

    /// 轮询整包安装进度。任务在 Agent 侧跑，App 退后台也不会中断安装。
    private func pollPkg() async {
        for _ in 0..<900 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let j = try? await Api.get("/api/v1/proxy/install", cache: false),
                  let p = j.obj("pkg") else {
                continue
            }
            await MainActor.run { pkgTask = p }
            // 所有下载通道都失败时，Agent 会停下来等用户决定要不要改 hosts。
            // 不接这一步，进度条会一直停着直到 5 分钟超时
            if p.str("waiting") == "hosts_fix", !hostsAsked {
                await MainActor.run {
                    hostsAsked = true
                    askHosts = true
                }
                continue
            }
            if p.bool("running") {
                continue
            }
            await MainActor.run {
                if p.bool("ok") {
                    pkgMsg = ""
                } else if let e = p.obj("error") {
                    pkgMsg = e.str("detail", "安装失败")
                } else {
                    pkgMsg = "安装失败"
                }
            }
            await load()
            return
        }
    }

    /// 回应 Agent 的「改 hosts 等确认」：yes 继续改 hosts 后重试，no 中止安装
    private func postPkgConfirm(_ choice: String) {
        Task {
            _ = try? await Api.post("/api/v1/proxy/pkg/confirm", ["choice": choice])
        }
    }

    /// 卸载代理插件。走慢接口：要在路由器上跑包管理器，几十秒是正常的
    private func doUninstall(_ id: String) async {
        await MainActor.run { pkgBusy = true }
        _ = try? await Api.post("/api/v1/proxy/uninstall",
                                ["target": id, "confirm": "remove"], slow: true)
        await MainActor.run { pkgBusy = false }
        await load()
    }

    private func load() async {
        do {
            let p = try await Api.get("/api/v1/proxy")
            // 这张卡管哪个后端：点名 > 正在运行 > 已装的（PassWall 优先）。
            // 必须先用刚拿到的列表算出来再取节点 —— 读 @State 会晚一拍，
            // 换后端后第一轮就会拿错数据
            let list = p.objs("backends")
            let installed = list.filter { $0.bool("installed") }.map { $0.str("id") }
            let act = p.str("active", "none")
            var target = comboPick
            if target.isEmpty || !installed.contains(target) {
                target = act != "none" ? act
                    : (installed.contains("passwall") ? "passwall" : (installed.first ?? ""))
            }
            var gPath = "/api/v1/proxy/groups"
            if !target.isEmpty { gPath += "?backend=" + target }
            let g = try await Api.get(gPath)
            let m = try? await Api.get("/api/v1/proxy/mode")
            let c = try? await Api.get("/api/v1/proxy/configs")
            await MainActor.run {
                d = p
                groups = (g["groups"] as? [Any])?.compactMap { $0 as? J } ?? []
                groupsErr = g.str("error")
                hideTimeout = g.bool("hide_timeout")
                hiddenCount = g.int("hidden")
                // 分组一律默认折叠（与安卓一致）：一屏先看到所有组的当前节点和节点数，
                // 想换哪个再展开哪个。以前会自动展开第一个，进来就是几十行节点
                if let m { mode = m.str("mode") }
                if let c { cfg = c }
                loading = false
                err = ""
            }
        } catch {
            await MainActor.run {
                loading = false
                if groups.isEmpty { err = error.localizedDescription }
            }
        }
    }

    /// 切换「隐藏超时节点」：写路由器上的偏好，再重拉分组（过滤在服务端做）
    private func setHideTimeout(_ on: Bool) async {
        if on == hideTimeout { return }
        let prev = hideTimeout
        hideTimeout = on
        guard let r = try? await Api.post("/api/v1/proxy/prefs", ["hide_timeout": on]) else {
            hideTimeout = prev
            return
        }
        hideTimeout = r.bool("hide_timeout")
        await load()
    }

    private func switchBackend(_ id: String, start: Bool = true) async {
        busy = true
        defer { busy = false }
        let r = try? await Api.post("/api/v1/proxy/service",
                                    ["action": start ? "start" : "stop", "backend": id],
                                    slow: true)
        await MainActor.run {
            // 刚启停的这个就是接下来要跟的对象：清掉旧的点名，
            // 否则卡片会停在「只改配置」的旁观态
            if r?.bool("ok") ?? false { comboPick = "" }
        }
        await load()
    }

    private func setMode(_ v: String) async {
        busy = true
        defer { busy = false }
        _ = try? await Api.post("/api/v1/proxy/mode", ["mode": v])
        await MainActor.run { mode = v }
        await load()
    }

    private func selectNode(group: String, node: String) async {
        busy = true
        defer { busy = false }
        // 必须带 backend：这张卡可能正管着没在跑的那个后端，
        // 不带就会落到「正在运行的那个」身上，等于改了另一套节点
        _ = try? await Api.post("/api/v1/proxy/select",
                                ["group": group, "name": node, "backend": comboBackend])
        await MainActor.run { tested = [:] }
        await load()
    }

    private func testGroup(_ name: String) {
        guard testingGroup.isEmpty else { return }
        testingGroup = name
        Task {
            let r = try? await Api.post("/api/v1/proxy/delays",
                                        ["group": name, "timeout": 3000,
                                         "backend": comboBackend], slow: true)
            var got: [String: Int] = [:]
            if let list = r?.objs("delays") {
                for x in list {
                    got[x.str("name")] = x.int("delay")
                }
            }
            // delays 是字典形态时也接一下，两种后端返回结构不一样
            if let obj = r?["delays"] as? [String: Any] {
                for (k, v) in obj {
                    if let n = v as? Int { got[k] = n }
                    if let n = v as? Double { got[k] = Int(n) }
                }
            }
            await MainActor.run {
                tested = got
                testingGroup = ""
            }
        }
    }

    private func switchConfig(_ path: String) async {
        busy = true
        defer { busy = false }
        // 切配置文件 = uci set + commit + 重启内核，会断网十几秒
        _ = try? await Api.post("/api/v1/proxy/config", ["path": path], slow: true)
        await load()
    }
}

// MARK: - 配置切换

struct ConfigPicker: View {
    let current: String
    let items: [J]
    let onPick: (String) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var working = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Text("OpenClash 同时只会启用一个配置文件，切换会重启内核，断网十几秒。")
                        .font(F.tiny)
                        .foregroundStyle(C.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)

                    ListGroup {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, c in
                            let on = c.str("path") == current
                            Button {
                                working = true
                                Task {
                                    await onPick(c.str("path"))
                                    working = false
                                    dismiss()
                                }
                            } label: {
                                HStack(spacing: 11) {
                                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 16))
                                        .foregroundStyle(on ? C.primary : C.textTertiary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(c.str("name"))
                                            .font(.system(size: 14.5, weight: on ? .semibold : .regular))
                                            .foregroundStyle(C.textPrimary)
                                        Text(F.bytes(c.dbl("size")) + " · " + F.clock(c.dbl("mtime")))
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(C.textSecondary)
                                    }
                                    Spacer()
                                    if on { Pill(text: "使用中", color: C.primary) }
                                }
                                .padding(.horizontal, 15).padding(.vertical, 11)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(working)
                            if i < items.count - 1 { Hairline(inset: 42) }
                        }
                    }
                }
                .padding(16)
            }
            .background(C.appBg)
            .navigationTitle("选择配置")
            .navigationBarTitleDisplayMode(.inline)
            .navBarChrome()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            .overlay {
                if working {
                    ZStack {
                        Color.black.opacity(0.16).ignoresSafeArea()
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("正在重启内核…").font(F.caption)
                        }
                        .padding(22)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
            }
        }
    }
}
