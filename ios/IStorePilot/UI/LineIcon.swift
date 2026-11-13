import SwiftUI

/// 设计稿图标（24×24 / 2px 描边）。
///
/// 路径来自 `IconData`（由 `scripts/gen_icons.py` 从 `design/icons` 生成），
/// 生成阶段已经把圆弧、二次曲线、相对指令统一成绝对坐标的 M/L/C/Z，
/// 所以这里只需要一个几十行的解析器，不必带着整套 SVG 语法。
///
/// 颜色仍然由调用方给（主色 / 危险色 / hero 上的白色），
/// 和 Android 的 `Glyph`、鸿蒙的 `GlyphIcon` 是同一份图形数据。
struct LineIcon: View {
    let name: String
    var size: CGFloat = 16
    var color: Color = C.textSecondary
    /// 设计稿线宽（24 格里的 2），会按实际尺寸缩放
    var weight: CGFloat = 2

    var body: some View {
        Canvas { ctx, canvas in
            let s = min(canvas.width, canvas.height) / 24
            let tf = CGAffineTransform(scaleX: s, y: s)

            if let d = IconData.stroke[name], !d.isEmpty {
                ctx.stroke(IconPath.build(d).applying(tf),
                           with: .color(color),
                           style: StrokeStyle(lineWidth: weight * s,
                                              lineCap: .round,
                                              lineJoin: .round))
            }
            if let d = IconData.fill[name], !d.isEmpty {
                ctx.fill(IconPath.build(d).applying(tf), with: .color(color))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// 路径缓存：同一张图标只解析一次，列表滚动时不重复做字符串分词
private enum IconPath {
    private static var cache: [String: Path] = [:]

    static func build(_ d: String) -> Path {
        if let hit = cache[d] {
            return hit
        }
        let p = parse(d)
        cache[d] = p
        return p
    }

    private static func parse(_ d: String) -> Path {
        var path = Path()
        var cmd: Character = "M"
        var args: [CGFloat] = []
        var token = ""

        func flushArg() {
            if !token.isEmpty {
                args.append(CGFloat(Double(token) ?? 0))
                token = ""
            }
        }

        func apply() {
            guard !args.isEmpty else { return }
            switch cmd {
            case "M":
                if args.count >= 2 {
                    path.move(to: CGPoint(x: args[0], y: args[1]))
                }
            case "L":
                if args.count >= 2 {
                    path.addLine(to: CGPoint(x: args[0], y: args[1]))
                }
            case "C":
                if args.count >= 6 {
                    path.addCurve(to: CGPoint(x: args[4], y: args[5]),
                                  control1: CGPoint(x: args[0], y: args[1]),
                                  control2: CGPoint(x: args[2], y: args[3]))
                }
            case "Z":
                path.closeSubpath()
            default:
                break
            }
            args.removeAll(keepingCapacity: true)
        }

        for ch in d {
            if ch.isLetter {
                flushArg()
                apply()
                // Z 不带参数，走不到 apply() 里的 guard，单独处理
                if ch == "Z" || ch == "z" {
                    path.closeSubpath()
                }
                cmd = ch
            } else if ch == " " || ch == "," {
                flushArg()
            } else {
                token.append(ch)
            }
        }
        flushArg()
        apply()
        return path
    }
}
