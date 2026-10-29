import SwiftUI

/// 应用流量排行（二级页）。对应安卓的 AppsActivity。
///
/// 设备页只放一张前几名的卡片，完整的放这里。数据按累计用量排序，
/// 「IP 直连」由服务端固定在末尾 —— 它不是应用，是认不出域名的那些连接。
struct AppsView: View {
    @State private var d: J = Api.cached("/api/v1/apps") ?? [:]
    @State private var q = ""

    private let tick = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    private var apps: [J] {
        let all = d.objs("apps")
        let k = q.trimmingCharacters(in: .whitespaces).lowercased()
        guard !k.isEmpty else { return all }
        return all.filter {
            $0.str("name").lowercased().contains(k) || $0.str("category").lowercased().contains(k)
        }
    }

    var body: some View {
        // 汇总卡和搜索框钉在顶部：翻到第 40 个应用时还想拿总数对照一下，
        // 只有下面的列表滚（安卓那边是同一个结构）
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                summaryCard
                searchBar
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 12) {
                    if apps.isEmpty {
                        EmptyHint(icon: "chart.bar", text: "还没有捕获到应用流量")
                    } else {
                        ListGroup {
                            ForEach(Array(apps.enumerated()), id: \.offset) { idx, a in
                                row(a)
                                if idx < apps.count - 1 { Hairline(inset: 16) }
                            }
                        }
                    }

                    Color.clear.barBottomGap()
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
        }
        .background(C.appBg)
        .navigationTitle("应用流量")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onReceive(tick) { _ in Task { await load() } }
    }

    // MARK: - 汇总

    private var summaryCard: some View {
        let all = d.obj("all") ?? [:]
        let session = d.obj("session") ?? [:]
        let clash = d.obj("clash") ?? [:]
        let days = Int(d.dbl("days"))
        let up = all.dbl("up")
        let down = all.dbl("down")

        return Card {
            VStack(alignment: .leading, spacing: 6) {
                Text(days > 1 ? "累计用量 · 已统计 \(days) 天" : "累计用量")
                    .font(F.tiny)
                    .foregroundStyle(C.textSecondary)
                Text(F.bytes(up + down))
                    .font(F.num(30, .semibold))
                    .foregroundStyle(C.textPrimary)
                Text("↓ \(F.bytes(down))　↑ \(F.bytes(up))")
                    .font(F.num(12.5, .regular))
                    .foregroundStyle(C.textSecondary)
                Hairline(inset: 0)
                Text("本次运行 \(F.bytes(session.dbl("up") + session.dbl("down")))"
                     + "　·　当前 \(Int(clash.dbl("connections"))) 条连接")
                    .font(F.tiny)
                    .foregroundStyle(C.textSecondary)
                Text("「IP 直连」是认不出域名的连接，排在最后")
                    .font(F.tiny)
                    .foregroundStyle(C.textTertiary)
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(C.textTertiary)
            TextField("搜应用名或分类", text: $q)
                .font(.system(size: 14))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(C.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - 行

    private func row(_ a: J) -> some View {
        let name = a.str("name")
        let category = a.str("category")
        let total = a.dbl("all_total")
        let share = a.dbl("share")
        let bps = a.dbl("down_bps") + a.dbl("up_bps")

        return HStack(spacing: 10) {
            AppIconView(name: name, size: 36)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(C.textPrimary)
                        .lineLimit(1)
                    if bps >= 1024 {
                        Text(F.rate(bps))
                            .font(F.num(10.5, .medium))
                            .foregroundStyle(C.primary)
                    }
                }
                HStack(spacing: 6) {
                    if !category.isEmpty, category != "其他" {
                        Text(category)
                            .font(.system(size: 10.5))
                            .foregroundStyle(C.textSecondary)
                    }
                    Text("↓ \(F.bytes(a.dbl("all_down")))　↑ \(F.bytes(a.dbl("all_up")))")
                        .font(F.num(10.5, .regular))
                        .foregroundStyle(C.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                Text(F.bytes(total))
                    .font(F.num(13, .medium))
                    .foregroundStyle(C.textPrimary)
                Text(String(format: "占 %.0f%%", share))
                    .font(F.num(10.5, .regular))
                    .foregroundStyle(C.textTertiary)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
    }

    private func load() async {
        if let j = try? await Api.get("/api/v1/apps") { d = j }
    }
}
