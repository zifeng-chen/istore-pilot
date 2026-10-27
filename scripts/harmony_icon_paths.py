"""把 Icons.ets 里的图标路径改写成只含 M / L / C / Z 的形式。

为什么：ArkUI 的 `Path.commands` 虽然写着走 SVG 语法，但实测里带 `A`（圆弧）或
`H` / `V`（水平/垂直直线）的路径在部分版本上会被截断 —— 只剩开头的 `M`，
于是图标变成一个点（strokeLineCap 是圆的，所以就是个小圆点）。
这里在离线阶段把圆弧换成等价的三次贝塞尔、把 H/V 换成 L，
渲染层只留最基础的四种指令。

用法：
    python scripts/harmony_icon_paths.py            # 改写 Icons.ets
    python scripts/harmony_icon_paths.py --check    # 只报告，不写文件
    python scripts/harmony_icon_paths.py --sheet x.png   # 顺带渲染对照图
"""

from __future__ import annotations

import math
import re
import sys

SRC = "harmony/entry/src/main/ets/ui/comp/Icons.ets"

TOKEN_RE = re.compile(
    r"([MmLlHhVvCcSsQqTtAaZz])|(-?\d*\.?\d+(?:[eE][-+]?\d+)?)"
)


def tokenize(path: str):
    out = []
    for m in TOKEN_RE.finditer(path):
        if m.group(1):
            out.append(m.group(1))
        else:
            out.append(float(m.group(2)))
    return out


def arc_to_cubics(x1, y1, rx, ry, phi_deg, large, sweep, x2, y2):
    """SVG 端点参数 → 最多 4 段三次贝塞尔（标准算法）。"""
    if rx == 0 or ry == 0 or (x1 == x2 and y1 == y2):
        return [("L", x2, y2)]
    phi = math.radians(phi_deg)
    cos_phi, sin_phi = math.cos(phi), math.sin(phi)

    dx2, dy2 = (x1 - x2) / 2.0, (y1 - y2) / 2.0
    x1p = cos_phi * dx2 + sin_phi * dy2
    y1p = -sin_phi * dx2 + cos_phi * dy2

    rx, ry = abs(rx), abs(ry)
    lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
    if lam > 1:
        s = math.sqrt(lam)
        rx, ry = rx * s, ry * s

    num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
    den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    coef = math.sqrt(max(0.0, num / den)) if den else 0.0
    if large == sweep:
        coef = -coef
    cxp = coef * rx * y1p / ry
    cyp = -coef * ry * x1p / rx

    cx = cos_phi * cxp - sin_phi * cyp + (x1 + x2) / 2.0
    cy = sin_phi * cxp + cos_phi * cyp + (y1 + y2) / 2.0

    def angle(ux, uy, vx, vy):
        dot = ux * vx + uy * vy
        n = math.hypot(ux, uy) * math.hypot(vx, vy)
        if n == 0:
            return 0.0
        a = math.acos(max(-1.0, min(1.0, dot / n)))
        return -a if (ux * vy - uy * vx) < 0 else a

    theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    dtheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry,
                   (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if not sweep and dtheta > 0:
        dtheta -= 2 * math.pi
    elif sweep and dtheta < 0:
        dtheta += 2 * math.pi

    segs = max(1, int(math.ceil(abs(dtheta) / (math.pi / 2))))
    step = dtheta / segs
    k = 4.0 / 3.0 * math.tan(step / 4.0)

    out = []
    t = theta1
    for _ in range(segs):
        def pt(a):
            ca, sa = math.cos(a), math.sin(a)
            return (cos_phi * rx * ca - sin_phi * ry * sa + cx,
                    sin_phi * rx * ca + cos_phi * ry * sa + cy)

        def deriv(a):
            ca, sa = math.cos(a), math.sin(a)
            return (-cos_phi * rx * sa - sin_phi * ry * ca,
                    -sin_phi * rx * sa + cos_phi * ry * ca)

        p1 = pt(t)
        p2 = pt(t + step)
        d1 = deriv(t)
        d2 = deriv(t + step)
        out.append(("C",
                    p1[0] + k * d1[0], p1[1] + k * d1[1],
                    p2[0] - k * d2[0], p2[1] - k * d2[1],
                    p2[0], p2[1]))
        t += step
    return out


def convert(path: str) -> str:
    toks = tokenize(path)
    out = []          # [(cmd, *nums)]
    i = 0
    cx = cy = 0.0     # 当前点
    sx = sy = 0.0     # 子路径起点

    def num():
        nonlocal i
        v = toks[i]
        i += 1
        return v

    while i < len(toks):
        cmd = toks[i]
        if not isinstance(cmd, str):
            raise ValueError("路径必须以指令开头：" + path)
        i += 1
        rel = cmd.islower()
        c = cmd.upper()

        if c == "M" or c == "L":
            x, y = num(), num()
            if rel:
                x, y = cx + x, cy + y
            out.append(("M" if c == "M" else "L", x, y))
            cx, cy = x, y
            if c == "M":
                sx, sy = x, y
                # M 之后的连续坐标按 L 处理
                while i < len(toks) and not isinstance(toks[i], str):
                    x, y = num(), num()
                    if rel:
                        x, y = cx + x, cy + y
                    out.append(("L", x, y))
                    cx, cy = x, y
        elif c == "H":
            x = num()
            if rel:
                x = cx + x
            out.append(("L", x, cy))
            cx = x
        elif c == "V":
            y = num()
            if rel:
                y = cy + y
            out.append(("L", cx, y))
            cy = y
        elif c == "C":
            v = [num() for _ in range(6)]
            if rel:
                v = [v[0] + cx, v[1] + cy, v[2] + cx, v[3] + cy, v[4] + cx, v[5] + cy]
            out.append(("C", *v))
            cx, cy = v[4], v[5]
        elif c == "Q":
            v = [num() for _ in range(4)]
            if rel:
                v = [v[0] + cx, v[1] + cy, v[2] + cx, v[3] + cy]
            # 二次 → 三次
            qx, qy, ex, ey = v
            out.append(("C",
                        cx + 2.0 / 3.0 * (qx - cx), cy + 2.0 / 3.0 * (qy - cy),
                        ex + 2.0 / 3.0 * (qx - ex), ey + 2.0 / 3.0 * (qy - ey),
                        ex, ey))
            cx, cy = ex, ey
        elif c == "A":
            rx, ry, rot = num(), num(), num()
            large, sweep = num(), num()
            x, y = num(), num()
            if rel:
                x, y = cx + x, cy + y
            out.extend(arc_to_cubics(cx, cy, rx, ry, rot, int(large), int(sweep), x, y))
            cx, cy = x, y
        elif c == "Z":
            out.append(("Z",))
            cx, cy = sx, sy
        else:
            raise ValueError("不支持的指令 " + cmd)

    def f(v: float) -> str:
        s = ("%.2f" % v).rstrip("0").rstrip(".")
        return "0" if s in ("-0", "") else s

    parts = []
    for seg in out:
        if seg[0] == "Z":
            parts.append("Z")
        else:
            parts.append(seg[0] + " ".join(f(v) for v in seg[1:]))
    return " ".join(parts)


LITERAL_RE = re.compile(r"'((?:[^'\\]|\\.)*)'")


def rewrite_source(src: str, dry: bool) -> tuple[str, int]:
    """找出所有「以 M 开头的字符串字面量（含用 + 连接的续行）」，逐个改写。"""
    result = []
    pos = 0
    changed = 0
    while True:
        m = LITERAL_RE.search(src, pos)
        if not m:
            result.append(src[pos:])
            break
        value = m.group(1)
        start, end = m.start(), m.end()
        if not value.startswith("M"):
            result.append(src[pos:end])
            pos = end
            continue
        # 吞掉后续的 + '...' 续行
        combined = value
        cursor = end
        while True:
            nxt = re.match(r"\s*\+\s*'((?:[^'\\]|\\.)*)'", src[cursor:])
            if not nxt:
                break
            combined += nxt.group(1)
            cursor += nxt.end()
        new = convert(combined)
        if new == combined:
            result.append(src[pos:cursor])
        else:
            result.append(src[pos:start])
            result.append("'" + new + "'")
            changed += 1
        pos = cursor
    return "".join(result), changed


def sample(path: str, scale: float = 1.0):
    """把路径采样成折线，用来渲染对照图。"""
    toks = tokenize(path)
    polys, cur = [], []
    i, cx, cy, sx, sy = 0, 0.0, 0.0, 0.0, 0.0

    def num():
        nonlocal i
        v = toks[i]
        i += 1
        return v

    while i < len(toks):
        cmd = toks[i]
        i += 1
        c = cmd.upper()
        rel = cmd.islower()
        if c == "M":
            x, y = num(), num()
            if rel:
                x, y = cx + x, cy + y
            if len(cur) > 1:
                polys.append(cur)
            cur = [(x, y)]
            cx, cy, sx, sy = x, y, x, y
        elif c == "L":
            x, y = num(), num()
            if rel:
                x, y = cx + x, cy + y
            cur.append((x, y))
            cx, cy = x, y
        elif c == "H":
            x = num()
            if rel:
                x = cx + x
            cur.append((x, cy))
            cx = x
        elif c == "V":
            y = num()
            if rel:
                y = cy + y
            cur.append((cx, y))
            cy = y
        elif c == "C":
            v = [num() for _ in range(6)]
            if rel:
                v = [v[0] + cx, v[1] + cy, v[2] + cx, v[3] + cy, v[4] + cx, v[5] + cy]
            for k in range(1, 21):
                t = k / 20.0
                mt = 1 - t
                px = (mt ** 3 * cx + 3 * mt * mt * t * v[0]
                      + 3 * mt * t * t * v[2] + t ** 3 * v[4])
                py = (mt ** 3 * cy + 3 * mt * mt * t * v[1]
                      + 3 * mt * t * t * v[3] + t ** 3 * v[5])
                cur.append((px, py))
            cx, cy = v[4], v[5]
        elif c == "A":
            rx, ry, rot = num(), num(), num()
            large, sweep = int(num()), int(num())
            x, y = num(), num()
            if rel:
                x, y = cx + x, cy + y
            segs = arc_to_cubics(cx, cy, rx, ry, rot, large, sweep, x, y)
            px, py = cx, cy
            for s in segs:
                for k in range(1, 21):
                    t = k / 20.0
                    mt = 1 - t
                    ax = (mt ** 3 * px + 3 * mt * mt * t * s[1]
                          + 3 * mt * t * t * s[3] + t ** 3 * s[5])
                    ay = (mt ** 3 * py + 3 * mt * mt * t * s[2]
                          + 3 * mt * t * t * s[4] + t ** 3 * s[6])
                    cur.append((ax, ay))
                px, py = s[5], s[6]
            cx, cy = x, y
        elif c == "Z":
            if cur:
                cur.append((sx, sy))
            cx, cy = sx, sy
    if len(cur) > 1:
        polys.append(cur)
    return [[(x * scale, y * scale) for x, y in p] for p in polys]


def sheet(pairs, out_path: str) -> None:
    from PIL import Image, ImageDraw

    cell, pad, cols = 96, 10, 6
    rows = (len(pairs) + cols - 1) // cols
    img = Image.new("RGB", (cols * (cell + pad) + pad,
                            rows * (cell + pad) + pad), "#EDF3F0")
    d = ImageDraw.Draw(img)
    for idx, (name, old, new) in enumerate(pairs):
        r, c = divmod(idx, cols)
        x0 = pad + c * (cell + pad)
        y0 = pad + r * (cell + pad)
        for half, path in ((0, old), (1, new)):
            bx = x0 + half * (cell // 2)
            # 22 格（页签图标）和 24 格（Glyph）都按各自画布缩放
            polys = sample(path)
            pts = [c for poly in polys for c in poly]
            span = max((max(x, y) for x, y in pts), default=22.0)
            span = 26.0 if span > 22.5 else 22.0
            s = (cell // 2 - 8) / span
            for poly in polys if abs(s - 1.0) < 1e-9 else sample(path, s):
                d.line([(bx + 4 + px, y0 + 6 + py) for px, py in poly],
                       fill="#00A87E" if half == 1 else "#8B9A95", width=2, joint="curve")
        d.text((x0 + 2, y0 + cell - 12), name[:14], fill="#59635F")
    img.save(out_path)
    print("对照图：", out_path, "（左列=原路径，右列=改写后）")


def main() -> int:
    src = open(SRC, encoding="utf-8").read()
    dry = "--check" in sys.argv
    new, changed = rewrite_source(src, dry)
    print(f"改动 {changed} 处路径")
    if not dry:
        open(SRC, "w", encoding="utf-8", newline="\n").write(new)
        print("已写入", SRC)
    if "--sheet" in sys.argv:
        out = sys.argv[sys.argv.index("--sheet") + 1]
        # 收集原/新路径做对照
        names = re.findall(r"static readonly (\w+): string =\s*('(?:[^'\\]|\\.)*'(?:\s*\+\s*'(?:[^'\\]|\\.)*')*)", src)
        pairs = []
        for name, expr in names:
            old = "".join(re.findall(r"'((?:[^'\\]|\\.)*)'", expr))
            if not old.startswith("M"):
                continue   # Glyph 的常量值是 'link' 这类名字，不是路径
            pairs.append((name, old, convert(old)))
        for m in re.finditer(r"case Glyph\.(\w+):", src):
            tail = src[m.end():]
            nxt = re.search(r"case Glyph\.|default:", tail)
            block = tail[:nxt.start()] if nxt else tail
            full = "".join(re.findall(r"'((?:[^'\\]|\\.)*)'", block))
            if full.startswith("M"):
                pairs.append((m.group(1).lower(), full, convert(full)))
        sheet(pairs, out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
