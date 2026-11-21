import SwiftUI

/// 网络测速。
///
/// 测速不是 App 自己做的：路由器 FastNet 提供 SSE，agent 转成「后台任务 + 状态落盘」，
/// 这里只轮询。所以本页没有测速逻辑，只有取状态、画进度、选节点。
///
/// 布局与鸿蒙/Android 完全对齐：一张卡里放节点、三段进度条、状态字、三个数值、按钮，
/// 三段等宽且全部居中，数值列对准各自进度条的中心。
struct SpeedView: View {

    private struct SpeedRow: Identifiable {
        let id: Int
        let time: Int
        let ping: Double
        let down: Double
        let up: Double
        let server: String
    }

    private struct Srv: Identifiable {
        let id: String
        let name: String
        let isp: String
    }

    @Environment(\.dismiss) private var dismiss

    @State private var state = "unknown"
    @State private var stage = ""
    @State private var running = false
    @State private var ping: Double = 0
    @State private var down: Double = 0
    @State private var up: Double = 0
    @State private var liveDown: Double = 0
    @State private var liveUp: Double = 0
    @State private var server = ""
    @State private var elapsed = 0
    @State private var rows: [SpeedRow] = []
    @State private var servers: [Srv] = []
    @State private var serverId = ""
    @State private var picking = false
    @State private var err = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if !err.isEmpty {
                        Card {
                            Text(err).font(.footnote).foregroundStyle(C.danger)
                        }
                    }
                    mainCard
                    if !rows.isEmpty { historyCard }
                    Text("测速会占满带宽约 20 秒，期间的下载和视频通话会变慢。")
                        .font(.caption2)
                        .foregroundStyle(C.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(C.appBg)
            .navigationTitle("网络测速")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .confirmationDialog("选择测速节点", isPresented: $picking, titleVisibility: .visible) {
                Button("自动选择") {
                    serverId = ""
                }
                ForEach(servers) { s in
                    Button(s.name) {
                        serverId = s.id
                    }
                }
                Button("取消", role: .cancel) {}
            }
            .task {
                await refresh()
                await loadHistory()
                await loadServers()
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if running {
                        elapsed += 1
                    }
                    if running || elapsed % 3 == 0 {
                        await refresh()
                    }
                }
            }
        }
    }

    // MARK: - 主卡

    private var mainCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("测速节点")
                            .font(.caption)
                            .foregroundStyle(C.textTertiary)
                        Text(nodeLine)
                            .font(.subheadline)
                            .foregroundStyle(C.textPrimary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        picking = true
                    } label: {
                        Text("选择 ›")
                            .font(.caption)
                            .foregroundStyle(C.primary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(C.primary.opacity(0.14))
                            .clipShape(Capsule())
                    }
                }

                Divider().padding(.vertical, 12)

                if running {
                    progressBlock
                } else {
                    resultBlock
                }

                Button {
                    Task { await start() }
                } label: {
                    Text(running ? "测速中… \(elapsed)s" : "开始测速")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(running ? C.surfaceHi : C.primary)
                        .foregroundStyle(running ? C.textTertiary : C.onPrimary)
                        .clipShape(Capsule())
                }
                .disabled(running)
                .padding(.top, 14)
            }
        }
    }

    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                segBar(0)
                segBar(1)
                segBar(2)
            }

            HStack(spacing: 0) {
                segLabel(0).frame(maxWidth: .infinity)
                segLabel(1).frame(maxWidth: .infinity)
                segLabel(2).frame(maxWidth: .infinity)
            }
            .padding(.top, 5)

            HStack(spacing: 0) {
                metric("延迟", text: ping > 0 ? String(format: "%.0f", ping) : "—", unit: "ms", hot: false)
                    .frame(maxWidth: .infinity)
                metric("下行 ↓", text: downLiveText, unit: "Mbps", hot: stage == "download")
                    .frame(maxWidth: .infinity)
                metric("上行 ↑", text: upLiveText, unit: "Mbps", hot: stage == "upload")
                    .frame(maxWidth: .infinity)
            }
            .padding(.top, 10)

            Text(hint)
                .font(.caption2)
                .foregroundStyle(C.textTertiary)
                .padding(.top, 12)
        }
    }

    private var resultBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(rows.isEmpty && down <= 0 ? "还没有测过" : "最近一次结果")
                .font(.caption2)
                .foregroundStyle(C.textSecondary)

            HStack(spacing: 0) {
                metric("延迟", text: lastPing > 0 ? String(format: "%.0f", lastPing) : "—",
                       unit: "ms", hot: false).frame(maxWidth: .infinity)
                metric("下行 ↓", text: lastDown > 0 ? String(format: "%.1f", lastDown) : "—",
                       unit: "Mbps", hot: false).frame(maxWidth: .infinity)
                metric("上行 ↑", text: lastUp > 0 ? String(format: "%.1f", lastUp) : "—",
                       unit: "Mbps", hot: false).frame(maxWidth: .infinity)
            }
            .padding(.top, 8)
        }
    }

    private func segBar(_ i: Int) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(C.surfaceHi)
                Capsule().fill(C.primary)
                    .frame(width: max(0, min(1, segPct(i))) * geo.size.width)
            }
        }
        .frame(height: 6)
    }

    private func segLabel(_ i: Int) -> some View {
        Text(segState(i))
            .font(.caption2)
            .multilineTextAlignment(.center)
            .foregroundStyle(isActive(i) ? C.primary : C.textTertiary)
    }

    private func metric(_ label: String, text: String, unit: String, hot: Bool) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(hot ? C.primary : C.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(text)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(hot ? C.primary : C.textPrimary)
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(C.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var historyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                Text("历史记录")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(C.textPrimary)
                HStack {
                    Text("时间 / 节点").font(.caption2).foregroundStyle(C.textTertiary)
                    Spacer()
                    Text("下行 ↓").font(.caption2).foregroundStyle(C.textTertiary).frame(width: 62, alignment: .trailing)
                    Text("上行 ↑").font(.caption2).foregroundStyle(C.textTertiary).frame(width: 62, alignment: .trailing)
                }
                .padding(.top, 8)

                ForEach(rows) { r in
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(timeText(r.time))
                                .font(.footnote)
                                .foregroundStyle(C.textPrimary)
                            Text("\(r.server.isEmpty ? "自动" : r.server) · \(Int(r.ping)) ms")
                                .font(.caption2)
                                .foregroundStyle(C.textTertiary)
                        }
                        Spacer()
                        Text(String(format: "%.1f", r.down))
                            .font(.footnote)
                            .foregroundStyle(C.textPrimary)
                            .frame(width: 62, alignment: .trailing)
                        Text(String(format: "%.1f", r.up))
                            .font(.footnote)
                            .foregroundStyle(C.textPrimary)
                            .frame(width: 62, alignment: .trailing)
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }

    // MARK: - 派生

    private var nodeLine: String {
        let base = serverLabel
        return server.isEmpty ? base : base + "：上次服务器 " + server
    }

    private var serverLabel: String {
        if serverId.isEmpty { return "自动选择" }
        return servers.first { $0.id == serverId }?.name ?? "自动选择"
    }

    private var lastPing: Double { rows.first?.ping ?? ping }
    private var lastDown: Double { rows.first?.down ?? down }
    private var lastUp: Double { rows.first?.up ?? up }

    private var downLiveText: String {
        if stage == "download" { return String(format: "%.1f", liveDown) }
        return down > 0 ? String(format: "%.1f", down) : "—"
    }

    private var upLiveText: String {
        stage == "upload" ? String(format: "%.1f", liveUp) : "—"
    }

    private var hint: String {
        switch stage {
        case "speedtest": return "正在测延迟 · \(elapsed) 秒"
        case "download": return "正在测下行 · \(elapsed) 秒"
        case "upload": return "正在测上行 · \(elapsed) 秒"
        default: return "准备中 · \(elapsed) 秒"
        }
    }

    private func isActive(_ i: Int) -> Bool {
        (i == 0 && stage == "speedtest") || (i == 1 && stage == "download") || (i == 2 && stage == "upload")
    }

    private func segState(_ i: Int) -> String {
        if i == 0 { return stage == "speedtest" ? "延迟 · 测速中" : "延迟 · 完成" }
        if i == 1 {
            if stage == "download" { return "下行 · 测速中" }
            return stage == "upload" || !running ? "下行 · 完成" : "下行 · 等待"
        }
        if stage == "upload" { return "上行 · 测速中" }
        return running ? "上行 · 等待" : "上行 · 完成"
    }

    private func segPct(_ i: Int) -> Double {
        let t = Double(elapsed)
        if i == 0 {
            if stage != "speedtest" { return 1 }
            return min(0.9, t * 0.18)
        }
        if i == 1 {
            if stage == "upload" || !running { return 1 }
            if stage == "download" { return min(0.95, max(0, (t - 3) * 0.09)) }
            return 0
        }
        if !running { return 1 }
        if stage == "upload" { return min(0.95, max(0, (t - 12) * 0.09)) }
        return 0
    }

    private func timeText(_ ts: Int) -> String {
        guard ts > 0 else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    // MARK: - 数据

    private func refresh() async {
        do {
            let b = try await Api.get("/api/v1/speedtest/status?t=\(Int(Date().timeIntervalSince1970 * 1000))",
                                      cache: false)
            state = b.str("state")
            let wasRunning = running
            running = b.bool("running")
            let st = b.str("stage")
            if !st.isEmpty { stage = st }
            let p = b.dbl("ping"), d = b.dbl("down"), u = b.dbl("up")
            if p > 0 { ping = p }
            if d > 0 { down = d }
            if u > 0 { up = u }
            let sv = b.str("server")
            if !sv.isEmpty { server = sv }
            if running {
                liveDown = b.dbl("liveDown")
                liveUp = b.dbl("liveUp")
            } else {
                liveDown = 0
                liveUp = 0
                if wasRunning { await loadHistory() }
            }
            err = ""
        } catch {
            err = "状态读取失败：\(error.localizedDescription)"
        }
    }

    private func loadHistory() async {
        guard let b = try? await Api.get("/api/v1/speedtest/history?t=\(Int(Date().timeIntervalSince1970 * 1000))",
                                         cache: false) else { return }
        rows = b.objs("rows").map {
            SpeedRow(id: $0.int("time"), time: $0.int("time"), ping: $0.dbl("ping"),
                     down: $0.dbl("down"), up: $0.dbl("up"), server: $0.str("server"))
        }
        if let first = rows.first, down <= 0 {
            _ = first
        }
    }

    private func loadServers() async {
        guard let b = try? await Api.get("/api/v1/speedtest/servers", cache: false) else { return }
        servers = b.objs("servers").compactMap { s in
            let name = s.str("name")
            return name.isEmpty ? nil : Srv(id: s.str("id"), name: name, isp: s.str("isp"))
        }
    }

    private func start() async {
        if running { return }
        elapsed = 0
        do {
            var body: J = [:]
            body["serverId"] = serverId
            let b = try await Api.post("/api/v1/speedtest/start", body)
            if b.bool("ok") {
                running = true
                stage = ""
            } else {
                err = b.str("error", "启动失败")
            }
        } catch {
            err = "启动失败：\(error.localizedDescription)"
        }
    }
}
