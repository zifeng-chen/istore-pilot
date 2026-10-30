import SwiftUI

struct DevicesView: View {
    /// 一级页点「在线 / 离线」进来时预设的筛选（0 全部 / 1 在线 / 2 离线）
    var initialFilter: Int = 0

    @State private var didInit = false
    @State private var d: J = Api.cached("/api/v1/devices") ?? [:]
    @State private var loading = (Api.cached("/api/v1/devices") == nil)
    @State private var q = ""
    @State private var filter = 0          // 0 全部 / 1 在线 / 2 离线 / 3 已禁网

    private let tick = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    @Environment(\.winWidth) private var winW
    @Environment(\.barAxis) private var axis

    /// 内容实际可用宽度 = min(窗口, 页签容器上限) 减去左右留白。
    /// 页签容器在 RootView 里用 contentColumn 收过口（rail 980 / 其它 820），
    /// 这里必须把那层上限也算进去，否则 1400pt 的外接屏算出来是四列。
    private var contentW: CGFloat {
        min(winW, axis == .rail ? 980 : 820) - 32
    }

    /// 1 列 = 手机竖屏，保持原来的分组列表；2 / 3 列才换卡片。
    private var cols: Int { GridCols.forWidth(contentW) }

    /// 分段控件的宽度：宽屏固定 300，两列时按比例收一点，
    /// 否则 549pt 的画布上搜索框只剩 239pt，占位文字会被截掉
    private var segW: CGFloat { min(300, max(220, contentW * 0.42)) }

    private var all: [J] { d.objs("devices") }

    private var shown: [J] {
        var list = all
        switch filter {
        case 1: list = list.filter { $0.bool("online") }
        case 2: list = list.filter { !$0.bool("online") }
        case 3: list = list.filter { $0.bool("blocked") }
        default: break
        }
        let k = q.trimmingCharacters(in: .whitespaces).lowercased()
        guard !k.isEmpty else { return list }
        return list.filter {
            $0.str("label").lowercased().contains(k)
            || $0.str("ip").contains(k)
            || $0.str("mac").lowercased().contains(k)
            || $0.str("vendor").lowercased().contains(k)
        }
    }

    private var onlineShown: [J] { shown.filter { $0.bool("online") } }
    private var offlineShown: [J] { shown.filter { !$0.bool("online") } }

    var body: some View {
        ScrollView {
                VStack(spacing: 12) {
                    // 宽屏把搜索框和分段并排：省掉一整行高度，
                    // 而且铺满整块画布的搜索框本身也长得不像话
                    if cols > 1 {
                        HStack(spacing: 10) {
                            searchBar
                            Seg(items: ["全部", "在线", "离线", "禁网"], index: $filter)
                                .frame(width: segW)
                        }
                        .padding(.horizontal, 16)
                    } else {
                        searchBar
                            .padding(.horizontal, 16)

                        Seg(items: ["全部", "在线", "离线", "禁网"], index: $filter)
                            .padding(.horizontal, 16)
                    }

                    if loading {
                        if cols > 1 {
                            cardSkeleton
                        } else {
                            listSkeleton.padding(.horizontal, 16)
                        }
                    } else if shown.isEmpty {
                        EmptyHint(icon: "wifi.slash", text: "没有符合条件的设备")
                            .padding(.horizontal, 16)
                    } else if cols > 1 {
                        // 宽画布：一张列表会把一行拉到 900pt，名字和数字之间空出半个屏。
                        // 改成一卡一台、按列铺开，同样的滚动距离能看到三倍的设备。
                        VStack(spacing: 0) {
                            if !onlineShown.isEmpty {
                                sectionHead("在线", onlineShown.count)
                                grid(onlineShown)
                            }
                            if !offlineShown.isEmpty {
                                sectionHead("离线", offlineShown.count)
                                    .padding(.top, onlineShown.isEmpty ? 0 : 18)
                                grid(offlineShown)
                            }
                        }
                        .padding(.horizontal, 16)
                    } else {
                        // 一组一个容器：55 台设备如果每台一张卡，
                        // 就是 55 层圆角和 55 层投影，又卡又碎
                        ListGroup {
                            ForEach(Array(shown.enumerated()), id: \.offset) { idx, dv in
                                NavigationLink(value: SecurityView.Route.device(dv.str("mac"))) {
                                    row(dv)
                                }
                                .buttonStyle(.plain)
                                if idx < shown.count - 1 { Hairline(inset: 62) }
                            }
                        }
                        .padding(.horizontal, 16)
                    }

                    Color.clear.barBottomGap()
                }
                .padding(.top, 6)
            }
            .scrollIndicators(.hidden)
            .background(C.appBg)
        .background(C.appBg)
        // 这一页永远是二级页：导航栈由「设备」页提供，返回箭头和手势返回都交给系统。
        // 以前是原地换视图 + 自己画一个 chevron，iOS 26 把它渲染成浮在右上角的玻璃圆钮
        .navigationTitle("设备清单")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !didInit {
                filter = initialFilter
                didInit = true
            }
        }
        .task { await load() }
        .onReceive(tick) { _ in Task { await load() } }
    }

    // MARK: - 行

    /// 一行设备。信息密度照安卓 `DevicesFragment` 的行来排：
    ///   主行：名字 +（已命名 / 禁网 / 固定）
    ///   副行：IP · 厂商 · 类型 · 型号 —— 认设备靠的往往不是名字，是型号
    ///   右侧三行：实时速率、在线状态、累计用量
    /// 原来只有「IP · 厂商」和实时速率，「这台用了多少」得点进去才看得到，
    /// 而且行高全靠 15pt 字撑，看着又大又空。
    private func row(_ dv: J) -> some View {
        let net = dv.obj("net") ?? [:]
        let online = dv.bool("online")
        let blocked = dv.bool("blocked")
        let total = net.dbl("rx_total") + net.dbl("tx_total")

        return HStack(spacing: 10) {
            // 接入方式徽标（5G / 2.4G / LAN）替掉原来的类型圆图标：
            // 一排圆图标看不出「插线还是无线、连的哪个频段」，而那才是用户想知道的
            AccessBadge(access: dv.obj("access") ?? [:], online: online)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(dv.str("label", dv.str("ip")))
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(C.textPrimary)
                        .lineLimit(1)
                    if !dv.str("alias").isEmpty { Pill(text: "已命名", color: C.primary) }
                    if dv.bool("static") { Pill(text: "固定", color: C.textSecondary) }
                }
                Text(metaLine(dv))
                    .font(.system(size: 11.5))
                    .foregroundStyle(C.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 2) {
                Text(F.rate(net.dbl("avg_bps")))
                    .font(F.num(12.5, .medium))
                    .foregroundStyle(online ? C.textPrimary : C.textTertiary)
                Text(blocked ? "已禁网" : (online ? "在线" : shortAgo(dv.dbl("last_seen"))))
                    .font(.system(size: 10.5))
                    .foregroundStyle(blocked ? C.danger : (online ? C.ok : C.textSecondary))
                Text(total > 0 ? "共 " + F.bytes(total) : "暂无用量")
                    .font(F.num(10.5, .regular))
                    .foregroundStyle(C.textTertiary)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(C.textTertiary)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    // MARK: - 宽屏卡片

    /// 分组标题：左边「在线 / 离线」，右边台数。
    /// 网格里的卡片不再逐条画分隔线，分组靠这两行字来分。
    private func sectionHead(_ title: String, _ n: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(C.textSecondary)
            Spacer(minLength: 6)
            Text("\(n) 台")
                .font(F.num(11, .regular))
                .foregroundStyle(C.textTertiary)
        }
        .padding(.horizontal, 3)
        .padding(.bottom, 7)
        .padding(.top, 2)
    }

    private func grid(_ list: [J]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: cols),
                  spacing: 10) {
            ForEach(Array(list.enumerated()), id: \.offset) { _, dv in
                NavigationLink(value: SecurityView.Route.device(dv.str("mac"))) {
                    card(dv)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 一台设备一张卡。
    ///
    /// 卡面上必须自己说清四件事，否则「点进去才知道是谁」：
    ///   第一行 状态点 + 名字 +（禁网 / 接入徽标）
    ///   第二行 IP · 型号（没有型号退回厂商）
    ///   第三行 实时速率 · 累计用量
    ///
    /// 状态不用文字：在线用主色点、离线整卡压灰且速率显示破折号。
    /// 55 台设备里大半是离线，逐张写「离线」只会让网格变成噪音。
    private func card(_ dv: J) -> some View {
        let net = dv.obj("net") ?? [:]
        let online = dv.bool("online")
        let blocked = dv.bool("blocked")
        let total = net.dbl("rx_total") + net.dbl("tx_total")
        let rate = net.dbl("avg_bps")
        let name = dv.str("label", dv.str("ip"))

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(online ? C.primary : C.textTertiary)
                    .frame(width: 5, height: 5)

                Text(name)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(online ? C.textPrimary : C.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                // 禁网和接入徽标抢同一个位置：禁网是会出事的操作，优先显示它；
                // 接入方式点进去在详情页仍有
                if blocked {
                    Text("禁网")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(C.danger)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2.5)
                        .background(C.danger.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .fixedSize()
                } else {
                    AccessBadge(access: dv.obj("access") ?? [:], online: online)
                }
            }

            Text(cardMeta(dv, name: name))
                .font(.system(size: 11))
                .foregroundStyle(C.textSecondary)
                .lineLimit(1)
                .padding(.top, 3)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(online ? F.rate(rate) : "—")
                    .font(F.num(12.5, .medium))
                    .foregroundStyle(online ? C.primary : C.textTertiary)
                Spacer(minLength: 4)
                Text(total > 0 ? "共 " + F.bytes(total) : "暂无用量")
                    .font(F.num(11, .regular))
                    .foregroundStyle(C.textTertiary)
                    .lineLimit(1)
            }
            .padding(.top, 9)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(online ? C.surface : C.surfaceSunken)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(online ? C.glassStroke : C.divider.opacity(0.6), lineWidth: 0.7)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// 卡片的副标题只放两段：IP 和「型号，没有型号就用厂商」。
    /// 列表行里是 IP · 厂商 · 类型 · 型号四段，塞进 200pt 宽的卡会全被截掉，
    /// 而认设备靠的正是型号那一段。
    /// 没命名的设备名字本身就是 IP，副标题再写一遍就是同一串数字出现两次。
    private func cardMeta(_ dv: J, name: String) -> String {
        let ip = dv.str("ip")
        let model = dv.str("model")
        let vendor = dv.str("vendor")
        var bits: [String] = []
        if !ip.isEmpty, ip != name { bits.append(ip) }
        if !model.isEmpty {
            bits.append(model)
        } else if !vendor.isEmpty, vendor != "私有地址", vendor != name {
            bits.append(vendor)
        }
        return bits.isEmpty ? dv.str("mac") : bits.joined(separator: " · ")
    }

    private var cardSkeleton: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: cols),
                  spacing: 10) {
            ForEach(0..<6, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    Bone(w: 92, h: 12)
                    Bone(w: 124, h: 9)
                    Bone(w: 66, h: 11)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(C.surface)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(.horizontal, 16)
    }

    /// 副标题：IP · 厂商 · 类型 · 型号。
    /// 逐项判空而不是无脑 join —— 中间留一个「· ·」比缺信息更难看
    private func metaLine(_ dv: J) -> String {
        let kind = dv.str("type")
        let model = dv.str("model")
        let name = dv.str("label", dv.str("ip"))
        var bits: [String] = []
        let ip = dv.str("ip")
        // 没命名的设备名字就是 IP，副标题不用再重复一遍
        if !ip.isEmpty, ip != name { bits.append(ip) }
        let vendor = dv.str("vendor")
        if !vendor.isEmpty, vendor != name, vendor != "私有地址" { bits.append(vendor) }
        if !kind.isEmpty, kind != "其他" { bits.append(kind) }
        if !model.isEmpty, !name.lowercased().hasPrefix(model.lowercased()) { bits.append(model) }
        return bits.isEmpty ? dv.str("mac") : bits.joined(separator: " · ")
    }

    private func shortAgo(_ ts: Double) -> String {
        guard ts > 0 else { return "离线" }
        let d = Date().timeIntervalSince1970 - ts
        if d < 3600 { return "\(max(1, Int(d / 60))) 分钟前" }
        if d < 86400 { return "\(Int(d / 3600)) 小时前" }
        return "\(Int(d / 86400)) 天前"
    }

    // MARK: - 搜索

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(C.textSecondary)
            TextField("名称、IP、MAC 或厂商", text: $q)
                .font(F.body)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !q.isEmpty {
                Button { q = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(C.textTertiary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(C.surface)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(C.glassStroke, lineWidth: 0.7)
        )
    }

    private var listSkeleton: some View {
        ListGroup {
            ForEach(0..<8, id: \.self) { _ in
                HStack(spacing: 12) {
                    Circle().fill(C.textTertiary.opacity(0.3)).frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 6) {
                        Bone(w: 120, h: 12)
                        Bone(w: 180, h: 9)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
            }
        }
    }

    private func load() async {
        do {
            d = try await Api.get("/api/v1/devices")
            loading = false
        } catch {
            loading = false
        }
    }
}
