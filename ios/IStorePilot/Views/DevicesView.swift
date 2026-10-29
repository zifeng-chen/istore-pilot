import SwiftUI

struct DevicesView: View {
    /// 从「设备与拦截」一级页进来时会给一个返回动作；
    /// 作为独立页签使用时是 nil，导航栏保持原样
    var onBack: (() -> Void)? = nil
    /// 一级页点「在线 / 离线」进来时预设的筛选（0 全部 / 1 在线 / 2 离线）
    var initialFilter: Int = 0

    @State private var didInit = false
    @State private var d: J = Api.cached("/api/v1/devices") ?? [:]
    @State private var loading = (Api.cached("/api/v1/devices") == nil)
    @State private var q = ""
    @State private var filter = 0          // 0 全部 / 1 在线 / 2 离线 / 3 已禁网
    @State private var path: [String] = []

    private let tick = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

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

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 12) {
                    searchBar
                        .padding(.horizontal, 16)

                    Seg(items: ["全部", "在线", "离线", "禁网"], index: $filter)
                        .padding(.horizontal, 16)

                    if loading {
                        listSkeleton.padding(.horizontal, 16)
                    } else if shown.isEmpty {
                        EmptyHint(icon: "wifi.slash", text: "没有符合条件的设备")
                            .padding(.horizontal, 16)
                    } else {
                        // 一组一个容器：55 台设备如果每台一张卡，
                        // 就是 55 层圆角和 55 层投影，又卡又碎
                        ListGroup {
                            ForEach(Array(shown.enumerated()), id: \.offset) { idx, dv in
                                Button {
                                    path.append(dv.str("mac"))
                                } label: {
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
            .navigationTitle("设备")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let onBack {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: onBack) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 15, weight: .semibold))
                        }
                    }
                }
            }
            .onAppear {
                if !didInit {
                    filter = initialFilter
                    didInit = true
                }
            }
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: String.self) { mac in
                if mac == "#apps" {
                    AppsView()
                } else {
                    DeviceDetailView(mac: mac,
                                     seed: all.first { $0.str("mac") == mac } ?? [:])
                }
            }
        }
        .task { await load() }
        .onReceive(tick) { _ in Task { await load() } }
    }

    // MARK: - 行

    private func row(_ dv: J) -> some View {
        let net = dv.obj("net") ?? [:]
        let online = dv.bool("online")
        let blocked = dv.bool("blocked")

        return HStack(spacing: 10) {
            // 接入方式徽标（5G / 2.4G / LAN）替掉原来的类型圆图标：
            // 一排圆图标看不出「插线还是无线、连的哪个频段」，而那才是用户想知道的
            AccessBadge(access: dv.obj("access") ?? [:], online: online)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(dv.str("label", dv.str("ip")))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(C.textPrimary)
                        .lineLimit(1)
                    if dv.str("alias").isEmpty == false {
                        Pill(text: "已命名", color: C.primary)
                    }
                    if blocked { Pill(text: "禁网", color: C.danger) }
                    if dv.bool("static") { Pill(text: "固定", color: C.textSecondary) }
                }
                Text("\(dv.str("ip"))· \(dv.str("vendor", "未知厂商"))")
                    .font(F.tiny)
                    .foregroundStyle(C.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 3) {
                Text(F.rate(net.dbl("avg_bps")))
                    .font(F.num(12.5, .medium))
                    .foregroundStyle(online ? C.textPrimary : C.textTertiary)
                Text(online ? "在线" : shortAgo(dv.dbl("last_seen")))
                    .font(.system(size: 10.5))
                    .foregroundStyle(online ? C.ok : C.textSecondary)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(C.textTertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
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
