import SwiftUI

// MARK: - RJ45 图标

/// 网口插座：外壳 + 顶部卡扣。全部用 Shape 画，颜色跟着状态变，
/// 用 SF Symbol 没有「网口」这个形状，用图片又要维护两套配色。
struct RJ45Body: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let inset = r.width * 0.07
        let top = r.height * 0.26
        let body = CGRect(x: inset, y: top,
                          width: r.width - inset * 2,
                          height: r.height - top - inset * 0.5)
        let radius = r.width * 0.13
        p.addRoundedRect(in: body, cornerSize: CGSize(width: radius, height: radius))

        // 卡扣：下宽上窄的梯形。这是「网口」区别于「盒子」的唯一特征，
        // 宽度必须够、必须居中 —— 早先画成窄矩形，缩到 20pt 高看着像个提手
        let bw = r.width * 0.42
        let tw = r.width * 0.30
        let tabH = r.height * 0.20
        p.move(to: CGPoint(x: r.midX - bw / 2, y: top + 0.6))
        p.addLine(to: CGPoint(x: r.midX - tw / 2, y: tabH))
        p.addLine(to: CGPoint(x: r.midX + tw / 2, y: tabH))
        p.addLine(to: CGPoint(x: r.midX + bw / 2, y: top + 0.6))
        return p
    }
}

/// 内侧五个触点
struct RJ45Pins: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let inset = r.width * 0.20
        let top = r.height * 0.26 + r.height * 0.11
        let bottom = r.height - r.height * 0.13
        for i in 0..<5 {
            let x = inset + (r.width - inset * 2) * (CGFloat(i) / 4)
            p.move(to: CGPoint(x: x, y: top))
            p.addLine(to: CGPoint(x: x, y: bottom))
        }
        return p
    }
}

struct PortIcon: View {
    let up: Bool
    let wan: Bool
    var size = CGSize(width: 26, height: 20)

    private var tone: Color { up ? C.primary : C.textTertiary }

    var body: some View {
        ZStack {
            // 先填一层淡色再描边：纯描边在 20pt 高时会糊成一条线，
            // 填充能让「插座」这个形状立住（安卓端同样处理）
            RJ45Body()
                .fill(tone.opacity(up ? (wan ? 0.20 : 0.13) : 0.07))
            RJ45Body()
                .stroke(tone, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            RJ45Pins()
                .stroke(tone.opacity(up ? 0.9 : 0.5), lineWidth: 1.05)
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - 迷你趋势线

/// 32 点 ≈ 1 分半。按窗口最大值归一化，再用 log 压缩 ——
/// 网口平时可能只有几十 K，线性画出来就是贴着底边的一条直线。
struct MiniSpark: View {
    let values: [Double]
    let color: Color
    let active: Bool

    var body: some View {
        Canvas { ctx, size in
            let h = size.height
            let pad: CGFloat = 1.2
            guard values.count >= 2 else {
                var line = Path()
                line.move(to: CGPoint(x: pad, y: h - pad))
                line.addLine(to: CGPoint(x: size.width - pad, y: h - pad))
                ctx.stroke(line, with: .color(color.opacity(0.3)),
                           style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                return
            }

            let maxV = max(values.max() ?? 1, 1)
            let stepX = (size.width - pad * 2) / CGFloat(31)
            let offset = 32 - values.count

            var line = Path()
            var firstX = pad
            for (i, v) in values.enumerated() {
                let x = pad + CGFloat(offset + i) * stepX
                let norm = min(1, max(0, v / maxV))
                let shaped = log1p(norm * 24) / log(25.0)
                let y = h - pad - CGFloat(shaped) * (h - pad * 2)
                if i == 0 {
                    firstX = x
                    line.move(to: CGPoint(x: x, y: y))
                } else {
                    line.addLine(to: CGPoint(x: x, y: y))
                }
            }

            var area = line
            area.addLine(to: CGPoint(x: pad + CGFloat(31) * stepX, y: h - pad))
            area.addLine(to: CGPoint(x: firstX, y: h - pad))
            area.closeSubpath()
            ctx.fill(area, with: .linearGradient(
                Gradient(colors: [color.opacity(active ? 0.30 : 0.12), color.opacity(0)]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: h)))
            ctx.stroke(line, with: .color(color.opacity(active ? 1 : 0.55)),
                       style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - 一张网口卡

struct PortTile: View {
    let name: String
    let role: String
    let up: Bool
    let speedMbps: Int
    let rx: Double
    let tx: Double
    let rxTotal: Double
    let txTotal: Double
    let mac: String
    let hist: [Double]
    var onTap: () -> Void = {}

    private var wan: Bool { role == "wan" }

    private var stateText: String {
        if !up { return "未连接" }
        if wan { return "WAN · 已连接" }
        if role == "lan" { return "LAN · 已连接" }
        return "已连接"
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    PortIcon(up: up, wan: wan)
                    Spacer(minLength: 4)
                    speedBadge
                }

                Text(name)
                    .font(.system(size: 15.5, weight: .medium))
                    .foregroundStyle(up ? C.textPrimary : C.textSecondary)
                    .lineLimit(1)
                    .padding(.top, 9)

                Text(stateText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(C.textSecondary)
                    .lineLimit(1)
                    // 摊成整行六个之后每张只有 126pt，
                    // 「WAN · 已连接」正好卡在临界，给一点缩放余量别截断
                    .minimumScaleFactor(0.82)
                    .padding(.top, 3)

                MiniSpark(values: hist, color: up ? C.primary : C.textTertiary, active: up)
                    .frame(height: 26)
                    .padding(.top, 9)

                HStack(spacing: 0) {
                    Text("↓ " + shortRate(rx))
                        .font(F.num(12, .medium))
                        .foregroundStyle(up ? C.primary : C.textTertiary)
                    Spacer(minLength: 4)
                    Text("↑ " + shortRate(tx))
                        .font(F.num(12, .medium))
                        .foregroundStyle(up ? C.warn : C.textTertiary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.top, 7)
            }
            .padding(.horizontal, 13)
            .padding(.top, 11)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(up ? C.surfaceHi : C.surfaceSunken)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(up ? C.primary.opacity(wan ? 0.55 : 0.26) : C.glassStroke,
                                  lineWidth: wan && up ? 1.1 : 0.7)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var speedBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(up ? C.ok : C.textTertiary)
                .frame(width: 5, height: 5)
            Text(up ? F.speed(speedMbps) : "—")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(up ? C.primary : C.textTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(up ? C.accentSoft : C.surfaceSunken)
        .clipShape(Capsule())
    }

    private func shortRate(_ v: Double) -> String {
        guard v.isFinite, v >= 1 else { return "0" }
        return F.short(v)
    }

    /// 点开看累计收发。网口详情只有这几项，弹底部卡片比跳新页面快
    var detailText: String {
        """
        接口　\(name.isEmpty ? "—" : name)
        角色　\(wan ? "WAN（外网）" : (role == "lan" ? "LAN（内网）" : "未分配"))
        状态　\(up ? "已连接 · \(F.speed(speedMbps))" : "未连接")
        MAC　\(mac.isEmpty ? "—" : mac)
        累计接收　\(F.bytes(rxTotal))
        累计发送　\(F.bytes(txTotal))
        """
    }
}
