import SwiftUI

/// 规则更新配置卡。
///
/// 这一块要回答一个以前界面上找不到答案的问题：规则到底是谁在更新。
/// 「立即更新」不是唯一入口 —— AdGuard Home 自带定时任务，默认每 24 小时拉一次，
/// 所以卡片先把「自动 / 手动」亮出来，再给频率档位和单张列表的开关。
struct RulesCard: View {
    /// 父页面在规则变更后要刷新统计（启用一张大表会让规则条数变）
    var onChanged: () -> Void = {}

    @State private var r: J = Api.cached("/api/v1/adblock/rules") ?? [:]
    @State private var busy = false
    @State private var note = ""
    @State private var fail = false

    private let choices: [(Int, String)] = [
        (0, "关闭"), (6, "6 小时"), (12, "12 小时"), (24, "每天"), (48, "2 天"), (72, "3 天"),
    ]

    private var auto: Bool { r.bool("auto") }
    private var interval: Int { r.int("interval") }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    SectionTitle(text: "规则更新")
                    Spacer(minLength: 8)
                    Pill(text: auto ? "自动" : "手动",
                         color: auto ? C.primary : C.textSecondary)
                }
                Text("自动还是手动，这里说了算")
                    .font(F.tiny)
                    .foregroundStyle(C.textSecondary)
                    .padding(.top, 3)

                Text("自动更新频率")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(C.textSecondary)
                    .padding(.top, 14)

                // 两行三列：六个档位平铺一行会把「12 小时」压成四个字挤在一起
                VStack(spacing: 8) {
                    ForEach(0..<2, id: \.self) { row in
                        HStack(spacing: 8) {
                            ForEach(0..<3, id: \.self) { col in
                                let idx = row * 3 + col
                                if idx < choices.count {
                                    chip(idx)
                                }
                            }
                        }
                    }
                }
                .padding(.top, 9)

                HStack(alignment: .top, spacing: 14) {
                    Text("下次更新")
                        .font(F.body)
                        .foregroundStyle(C.textSecondary)
                        .frame(width: 84, alignment: .leading)
                    Text(nextText)
                        .font(F.num(13, .medium))
                        .foregroundStyle(auto ? C.textPrimary : C.warn)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.top, 12)

                Button {
                    refreshNow()
                } label: {
                    HStack(spacing: 7) {
                        if busy {
                            ProgressView().tint(C.onPrimary).scaleEffect(0.75)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        Text(busy ? "更新中…" : "立即更新规则")
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
                .padding(.top, 14)

                if !note.isEmpty {
                    Text(note)
                        .font(F.tiny)
                        .foregroundStyle(fail ? C.danger : C.textSecondary)
                        .padding(.top, 8)
                }

                ForEach(Array(r.objs("lists").enumerated()), id: \.offset) { i, f in
                    Hairline(inset: 0).padding(.top, i == 0 ? 8 : 0)
                    listRow(f)
                }
            }
        }
        .task { await load() }
    }

    // MARK: - 子视图

    private func chip(_ index: Int) -> some View {
        let hours = choices[index].0
        let on = hours == interval
        return Button {
            setInterval(hours)
        } label: {
            Text(choices[index].1)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(on ? C.primary : C.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(on ? C.accentSoft2 : C.surfaceHi)
                .clipShape(Capsule())
                .overlay(
                    Capsule().strokeBorder(
                        on ? C.primary.opacity(0.55) : Color.clear,
                        lineWidth: 0.9)
                )
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private func listRow(_ f: J) -> some View {
        let on = f.bool("enabled")
        let err = f.str("last_error")

        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(f.str("name", "—"))
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(on ? C.textPrimary : C.textSecondary)
                    .lineLimit(1)
                Text(subText(f))
                    .font(.system(size: 11.5))
                    .foregroundStyle(err.isEmpty ? C.textSecondary : C.danger)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: Binding(
                get: { on },
                set: { toggle(f.int("id"), $0) }
            ))
            .labelsHidden()
            .tint(C.primary)
            .disabled(busy)
        }
        .padding(.vertical, 11)
    }

    private func subText(_ f: J) -> String {
        if !f.bool("enabled") {
            let n = f.int("rules")
            return n > 0 ? "已停用　·　上次下载 \(F.count(n)) 条" : "已停用"
        }
        var s = "\(F.count(f.int("rules"))) 条规则"
        let last = F.friendlyISO(f.str("last_updated"))
        if !last.isEmpty { s += "　·　\(last)更新" }
        if !f.str("last_error").isEmpty { s += "　·　上次失败" }
        return s
    }

    private var nextText: String {
        guard auto else { return "已关闭，只能手动更新" }
        let at = r.str("next_update")
        let left = r.int("minutes_left")
        if left <= 0 { return "随时" }
        let when = left < 60 ? "\(left) 分钟后" : "\(Int((Double(left) / 60).rounded())) 小时后"
        if at.count >= 16 {
            return "\(when)（\(at.prefix(16).suffix(11))）"
        }
        return when
    }

    // MARK: - 动作

    private func load() async {
        if let j = try? await Api.get("/api/v1/adblock/rules"), j.bool("ok") {
            await MainActor.run { r = j }
        }
    }

    private func setInterval(_ hours: Int) {
        run(["action": "set_interval", "interval": hours])
    }

    private func toggle(_ id: Int, _ on: Bool) {
        run(["action": "toggle", "id": id, "enabled": on])
    }

    private func run(_ body: J) {
        busy = true
        note = ""
        Task {
            do {
                let j = try await Api.post("/api/v1/adblock/rules", body)
                await MainActor.run {
                    busy = false
                    if j.bool("ok") {
                        r = j
                        fail = false
                        note = j.str("message")
                    } else {
                        fail = true
                        note = j.str("error", "设置失败")
                    }
                }
                onChanged()
            } catch {
                await MainActor.run {
                    busy = false
                    fail = true
                    note = error.localizedDescription
                }
            }
        }
    }

    private func refreshNow() {
        busy = true
        note = ""
        Task {
            do {
                let j = try await Api.post("/api/v1/adblock/refresh", nil, slow: true)
                await MainActor.run {
                    busy = false
                    fail = !j.bool("ok")
                    note = j.bool("ok")
                        ? "已更新　·　规则 \(F.count(j.int("rules_after"))) 条"
                        : j.str("error", "更新失败")
                }
                await load()
                onChanged()
            } catch {
                await MainActor.run {
                    busy = false
                    fail = true
                    note = error.localizedDescription
                }
            }
        }
    }
}
