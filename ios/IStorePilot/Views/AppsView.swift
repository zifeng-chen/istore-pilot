import SwiftUI

/// 应用流量排行（二级页）。对应安卓的 `AppsActivity`。
///
/// 版式与安卓逐项对齐：**一个应用一张小卡**，图标 44、名字 15、
/// 第二行「占 x% · 分类 · N 连接」，右侧总量 17 + 一行上下行。
///
/// 原来这里是「一整个 ListGroup + 36 图标 + 占比放最后」：
/// 行比安卓矮一截、信息也少一截（没有连接数、上下行被挤在中间行），
/// 于是同一份数据在两端读起来完全不是一件事。
struct AppsView: View {
    /// 从设备页用 sheet 打开时为 true —— 那时要自己给一个关闭按钮，
    /// 否则用户只能下拉关（导航栏上光秃秃的，看着像没做返回）
    var asSheet: Bool = false

    @State private var d: J = Api.cached("/api/v1/apps") ?? [:]
    @State private var q = ""
    @Environment(\.dismiss) private var dismiss

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
                LazyVStack(spacing: 10) {
                    if apps.isEmpty {
                        EmptyHint(icon: "chart.bar", text: "还没有捕获到应用流量")
                    } else {
                        ForEach(Array(apps.enumerated()), id: \.offset) { _, a in
                            row(a)
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
        .navBarChrome()
        .toolbar {
            if asSheet {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .font(.system(size: 15, weight: .semibold))
                }
            }
        }
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

        return Card(padding: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(days > 1 ? "累计用量 · 已统计 \(days) 天" : "累计用量")
                    .font(.system(size: 11.5))
                    .foregroundStyle(C.textSecondary)
                Text(F.bytes(up + down))
                    .font(F.num(28, .semibold))
                    .foregroundStyle(C.textPrimary)
                Text("↓ \(F.bytes(down))　↑ \(F.bytes(up))")
                    .font(F.num(12, .regular))
                    .foregroundStyle(C.textSecondary)
                Hairline(inset: 0).padding(.vertical, 6)
                Text("本次运行 \(F.bytes(session.dbl("up") + session.dbl("down")))"
                     + "　·　当前 \(Int(clash.dbl("connections"))) 条连接")
                    .font(.system(size: 11))
                    .foregroundStyle(C.textSecondary)
                Text("「IP 直连」是认不出域名的连接，排在最后")
                    .font(.system(size: 10.5))
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
            if !q.isEmpty {
                Button { q = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(C.textTertiary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(C.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(C.glassStroke, lineWidth: 0.7)
        )
    }

    // MARK: - 行

    private func row(_ a: J) -> some View {
        let name = a.str("name")
        let category = a.str("category")
        let total = a.dbl("all_total")
        let share = a.dbl("share")
        let conns = a.int("conns")
        let bps = a.dbl("down_bps") + a.dbl("up_bps")

        // 第二行：占比 · 分类 · 连接数。占比排在最前是因为它比「多少 GB」
        // 更能说明「谁在吃带宽」；上下行挪到右边金额下面，窄屏上才不会被省略号吃掉
        var meta: [String] = []
        if share > 0 { meta.append(String(format: "占 %.1f%%", share)) }
        if !category.isEmpty, category != "其他" { meta.append(category) }
        if conns > 0 { meta.append("\(conns) 连接") }

        return Card(padding: 13) {
            HStack(spacing: 0) {
                AppIconView(name: name, size: 44)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(name)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(C.textPrimary)
                            .lineLimit(1)
                        if bps >= 1024 {
                            Text(F.rate(bps))
                                .font(F.num(11.5, .medium))
                                .foregroundStyle(C.primary)
                                .lineLimit(1)
                        }
                    }
                    Text(meta.isEmpty ? "—" : meta.joined(separator: "　·　"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(C.textSecondary)
                        .lineLimit(1)
                }
                .padding(.leading, 12)
                .padding(.trailing, 6)

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(F.bytes(total))
                        .font(F.num(17, .medium))
                        .foregroundStyle(C.textPrimary)
                        .lineLimit(1)
                    Text("↓ \(F.bytes(a.dbl("all_down")))　↑ \(F.bytes(a.dbl("all_up")))")
                        .font(F.num(10, .regular))
                        .foregroundStyle(C.textSecondary)
                        .lineLimit(1)
                }
                .padding(.leading, 10)
                // 右侧两个数字是固定信息，不能被中间那行挤掉一半；
                // 真放不下时让「占 x% · 分类」先截断
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
            }
        }
    }

    private func load() async {
        if let j = try? await Api.get("/api/v1/apps") { d = j }
    }
}
