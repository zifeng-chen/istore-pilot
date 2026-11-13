#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 design/icons 里的 SVG 图标库转成三端代码。

为什么要归一化：库里的 SVG 用了 `H/V/S/Q/T/A` 和相对指令，而
Android（PathParser）能全吃、鸿蒙（Canvas 回放）和 iOS（自写解析）只吃
`M/L/C/Z`。所以在生成阶段统一转成**绝对坐标的 M/L/C/Z**，三端各自只留一个
极简解析器 —— 少两套解析器，也少两处会画歪的地方。

产出：

1. Android `widget/IconData.java`：每个图标一组 path 字符串，`Glyph` 用
   `PathParser` 解析一次并缓存；页签/返回键另外生成 VectorDrawable。
2. 鸿蒙 `ui/comp/IconData.ets`：`IconData.stroke(kind)` / `fill(kind)`，
   键就是 SVG 文件名（kebab-case），由 `GlyphIcon` 用 Canvas 回放。
3. iOS `UI/IconData.swift`：`IconData.paths[name]`，由 `LineIcon` 转成 `Path`。

用法：
    python scripts/gen_icons.py            # 生成三端
    python scripts/gen_icons.py --check    # 只校验产物是否与 SVG 同步
"""
import argparse
import math
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "design", "icons", "icons")

OUT_ANDROID = os.path.join(
    ROOT, "android/app/src/main/java/com/izifeng/www/istorepilot/widget/IconData.java")
OUT_HARMONY = os.path.join(
    ROOT, "harmony/entry/src/main/ets/ui/comp/IconData.ets")
OUT_IOS = os.path.join(ROOT, "ios/IStorePilot/UI/IconData.swift")
OUT_RES = os.path.join(ROOT, "android/app/src/main/res/drawable")

# 页签与返回键：drawable 名 → 图标名（图标库里的相对路径）
NAV_MAP = {
    "ic_nav_overview": "monitoring/system-load",
    "ic_nav_devices": "monitoring/devices",
    "ic_nav_proxy": "monitoring/proxy",
    "ic_nav_settings": "actions/system-settings",
    "ic_back": "common/back",
}

# 图标库里没有、但界面确实在用的：本地补 path，生成时一起并进去。
# 这类图标会写进文档的「待补」清单，等设计补图后替换。
EXTRA = {
    "close": ["M6.6 6.6 17.4 17.4", "M17.4 6.6 6.6 17.4"],
    "check": ["M4.5 11.5 L9 16 L17.5 6.5"],
}

# ---------------------------------------------------------------- SVG 解析

NUM = r"[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?"
TOKEN = re.compile(r"[MmLlHhVvCcSsQqTtAaZz]|" + NUM)


def attrs(s):
    return {k: v for k, v in re.findall(r'([\w:-]+)="([^"]*)"', s)}


def f(v, default=0.0):
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def num(v):
    s = ("%.2f" % v).rstrip("0").rstrip(".")
    return "0" if s in ("", "-0") else s


def circle_path(a):
    cx, cy, r = f(a.get("cx")), f(a.get("cy")), f(a.get("r"))
    return ("M %s %s a %s %s 0 1 0 %s 0 a %s %s 0 1 0 -%s 0"
            % (num(cx - r), num(cy), num(r), num(r), num(2 * r),
               num(r), num(r), num(2 * r)))


def ellipse_path(a):
    cx, cy = f(a.get("cx")), f(a.get("cy"))
    rx, ry = f(a.get("rx")), f(a.get("ry"))
    return ("M %s %s a %s %s 0 1 0 %s 0 a %s %s 0 1 0 -%s 0"
            % (num(cx - rx), num(cy), num(rx), num(ry), num(2 * rx),
               num(rx), num(ry), num(2 * rx)))


def rect_path(a):
    x, y = f(a.get("x")), f(a.get("y"))
    w, h = f(a.get("width")), f(a.get("height"))
    rx = f(a.get("rx"), f(a.get("ry")))
    ry = f(a.get("ry"), rx)
    if rx <= 0 or ry <= 0:
        return "M %s %s H %s V %s H %s Z" % (
            num(x), num(y), num(x + w), num(y + h), num(x))
    rx = min(rx, w / 2)
    ry = min(ry, h / 2)
    return ("M %s %s H %s A %s %s 0 0 1 %s %s V %s "
            "A %s %s 0 0 1 %s %s H %s A %s %s 0 0 1 %s %s V %s "
            "A %s %s 0 0 1 %s %s Z" % (
                num(x + rx), num(y), num(x + w - rx),
                num(rx), num(ry), num(x + w), num(y + ry),
                num(y + h - ry),
                num(rx), num(ry), num(x + w - rx), num(y + h),
                num(x + rx),
                num(rx), num(ry), num(x), num(y + h - ry),
                num(y + ry),
                num(rx), num(ry), num(x + rx), num(y)))


def line_path(a):
    return "M %s %s L %s %s" % (num(f(a.get("x1"))), num(f(a.get("y1"))),
                                num(f(a.get("x2"))), num(f(a.get("y2"))))


def poly_path(a, closed):
    pts = [p for p in re.split(r"[\s,]+", a.get("points", "").strip()) if p]
    if len(pts) < 4:
        return ""
    d = "M %s %s" % (pts[0], pts[1])
    for i in range(2, len(pts) - 1, 2):
        d += " L %s %s" % (pts[i], pts[i + 1])
    return d + (" Z" if closed else "")


# ---------------------------------------------------------------- 路径归一化

def arc_cubics(x1, y1, rx, ry, phi, large, sweep, x2, y2):
    """SVG 端点式圆弧 → 若干三次贝塞尔（每段 ≤ 90°）。"""
    if rx == 0 or ry == 0 or (x1 == x2 and y1 == y2):
        return [("L", x2, y2)]
    rx, ry = abs(rx), abs(ry)
    ph = math.radians(phi % 360.0)
    cos_ph, sin_ph = math.cos(ph), math.sin(ph)

    dx2, dy2 = (x1 - x2) / 2.0, (y1 - y2) / 2.0
    x1p = cos_ph * dx2 + sin_ph * dy2
    y1p = -sin_ph * dx2 + cos_ph * dy2

    lam = x1p * x1p / (rx * rx) + y1p * y1p / (ry * ry)
    if lam > 1:
        s = math.sqrt(lam)
        rx *= s
        ry *= s

    nume = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
    deno = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    co = 0.0 if deno == 0 else math.sqrt(max(0.0, nume / deno))
    if large == sweep:
        co = -co
    cxp = co * rx * y1p / ry
    cyp = -co * ry * x1p / rx
    cx = cos_ph * cxp - sin_ph * cyp + (x1 + x2) / 2.0
    cy = sin_ph * cxp + cos_ph * cyp + (y1 + y2) / 2.0

    def angle(ux, uy, vx, vy):
        dot = ux * vx + uy * vy
        ln = math.hypot(ux, uy) * math.hypot(vx, vy)
        if ln == 0:
            return 0.0
        a = math.acos(max(-1.0, min(1.0, dot / ln)))
        return a if ux * vy - uy * vx >= 0 else -a

    ux, uy = (x1p - cxp) / rx, (y1p - cyp) / ry
    vx, vy = (-x1p - cxp) / rx, (-y1p - cyp) / ry
    theta = angle(1, 0, ux, uy)
    delta = angle(ux, uy, vx, vy)
    if not sweep and delta > 0:
        delta -= 2 * math.pi
    elif sweep and delta < 0:
        delta += 2 * math.pi

    n = max(1, int(math.ceil(abs(delta) / (math.pi / 2))))
    step = delta / n
    k = 4.0 / 3.0 * math.tan(step / 4.0)
    out = []
    th = theta
    for _ in range(n):
        a, b = th, th + step
        ca, sa = math.cos(a), math.sin(a)
        cb, sb = math.cos(b), math.sin(b)
        p1 = (ca - k * sa, sa + k * ca)
        p2 = (cb + k * sb, sb - k * cb)
        pe = (cb, sb)

        def tf(p):
            return (cx + cos_ph * rx * p[0] - sin_ph * ry * p[1],
                    cy + sin_ph * rx * p[0] + cos_ph * ry * p[1])

        c1, c2, e = tf(p1), tf(p2), tf(pe)
        out.append(("C", c1[0], c1[1], c2[0], c2[1], e[0], e[1]))
        th = b
    return out


def normalize(d):
    """任意 SVG path → 绝对坐标的 M/L/C/Z 序列（字符串）。"""
    toks = TOKEN.findall(d or "")
    out = []
    x = y = 0.0            # 当前点
    sx = sy = 0.0          # 子路径起点
    ctrl_x = ctrl_y = 0.0  # 上一个控制点（S/T 反射用）
    prev = ""
    i = 0
    cmd = ""

    def take(n):
        nonlocal i
        vals = []
        for _ in range(n):
            if i < len(toks) and not toks[i].isalpha():
                vals.append(float(toks[i]))
                i += 1
            else:
                return None
        return vals

    while i < len(toks):
        t = toks[i]
        if t.isalpha():
            cmd = t
            i += 1
            if cmd in "Zz":
                out.append("Z")
                x, y = sx, sy
                prev = "Z"
                continue
        elif cmd == "":
            i += 1
            continue
        else:
            # 隐式重复：M 之后的坐标按 L 处理
            if cmd == "M":
                cmd = "L"
            elif cmd == "m":
                cmd = "l"

        rel = cmd.islower()
        c = cmd.upper()

        if c in ("M", "L"):
            v = take(2)
            if v is None:
                break
            nx = v[0] + (x if rel else 0)
            ny = v[1] + (y if rel else 0)
            if c == "M":
                out.append("M %s %s" % (num(nx), num(ny)))
                sx, sy = nx, ny
            else:
                out.append("L %s %s" % (num(nx), num(ny)))
            x, y = nx, ny
            prev = c
        elif c == "H":
            v = take(1)
            if v is None:
                break
            nx = v[0] + (x if rel else 0)
            out.append("L %s %s" % (num(nx), num(y)))
            x = nx
            prev = "L"
        elif c == "V":
            v = take(1)
            if v is None:
                break
            ny = v[0] + (y if rel else 0)
            out.append("L %s %s" % (num(x), num(ny)))
            y = ny
            prev = "L"
        elif c in ("C", "S"):
            need = 6 if c == "C" else 4
            v = take(need)
            if v is None:
                break
            if c == "C":
                c1x, c1y = v[0] + (x if rel else 0), v[1] + (y if rel else 0)
                rest = v[2:]
            else:
                if prev in ("C", "S"):
                    c1x, c1y = 2 * x - ctrl_x, 2 * y - ctrl_y
                else:
                    c1x, c1y = x, y
                rest = v
            c2x, c2y = rest[0] + (x if rel else 0), rest[1] + (y if rel else 0)
            ex, ey = rest[2] + (x if rel else 0), rest[3] + (y if rel else 0)
            out.append("C %s %s %s %s %s %s" % (
                num(c1x), num(c1y), num(c2x), num(c2y), num(ex), num(ey)))
            ctrl_x, ctrl_y = c2x, c2y
            x, y = ex, ey
            prev = "C"
        elif c in ("Q", "T"):
            need = 4 if c == "Q" else 2
            v = take(need)
            if v is None:
                break
            if c == "Q":
                qx, qy = v[0] + (x if rel else 0), v[1] + (y if rel else 0)
                ex, ey = v[2] + (x if rel else 0), v[3] + (y if rel else 0)
            else:
                if prev in ("Q", "T"):
                    qx, qy = 2 * x - ctrl_x, 2 * y - ctrl_y
                else:
                    qx, qy = x, y
                ex, ey = v[0] + (x if rel else 0), v[1] + (y if rel else 0)
            c1x, c1y = x + 2.0 / 3.0 * (qx - x), y + 2.0 / 3.0 * (qy - y)
            c2x = ex + 2.0 / 3.0 * (qx - ex)
            c2y = ey + 2.0 / 3.0 * (qy - ey)
            out.append("C %s %s %s %s %s %s" % (
                num(c1x), num(c1y), num(c2x), num(c2y), num(ex), num(ey)))
            ctrl_x, ctrl_y = qx, qy
            x, y = ex, ey
            prev = "Q"
        elif c == "A":
            v = take(7)
            if v is None:
                break
            ex, ey = v[5] + (x if rel else 0), v[6] + (y if rel else 0)
            for seg in arc_cubics(x, y, v[0], v[1], v[2],
                                  bool(v[3]), bool(v[4]), ex, ey):
                if seg[0] == "L":
                    out.append("L %s %s" % (num(seg[1]), num(seg[2])))
                else:
                    out.append("C %s %s %s %s %s %s" % tuple(
                        num(q) for q in seg[1:]))
            x, y = ex, ey
            prev = "C"
        else:
            i += 1

    return " ".join(out)


# ---------------------------------------------------------------- 采集图标

def parse_svg(path):
    src = open(path, encoding="utf-8").read()
    body = src[src.index(">") + 1:] if "<svg" in src else src
    stroke, fill = [], []
    for m in re.finditer(r"<([a-zA-Z]+)\b([^>]*?)/?>", body):
        tag, raw = m.group(1), m.group(2)
        if tag in ("title", "desc", "g", "defs", "style"):
            continue
        a = attrs(raw)
        if tag == "circle":
            d = circle_path(a)
        elif tag == "ellipse":
            d = ellipse_path(a)
        elif tag == "rect":
            d = rect_path(a)
        elif tag == "line":
            d = line_path(a)
        elif tag == "polyline":
            d = poly_path(a, False)
        elif tag == "polygon":
            d = poly_path(a, True)
        elif tag == "path":
            d = a.get("d", "")
        else:
            continue
        if not d:
            continue
        (fill if a.get("fill") == "currentColor" else stroke).append(normalize(d))
    return [s for s in stroke if s], [s for s in fill if s]


def load_icons():
    icons = []
    for group in sorted(os.listdir(LIB)):
        gdir = os.path.join(LIB, group)
        if not os.path.isdir(gdir):
            continue
        for name in sorted(os.listdir(gdir)):
            if not name.endswith(".svg"):
                continue
            stroke, fill = parse_svg(os.path.join(gdir, name))
            icons.append((name[:-4], group, stroke, fill))
    for name, stroke in EXTRA.items():
        icons.append((name, "local", [normalize(d) for d in stroke], []))
    return icons


def const_name(name):
    return name.upper().replace("-", "_")


# ---------------------------------------------------------------- 各端产物

def java_of(icons):
    lines = [
        "package com.izifeng.www.istorepilot.widget;",
        "",
        "// @generated by scripts/gen_icons.py —— 改图标请改 design/icons 后重跑脚本",
        "",
        "/**",
        " * 图标路径数据（绝对坐标 M/L/C/Z，由生成脚本归一化）。",
        " *",
        " * 与设计稿同一份 24×24 path：描边宽度、圆头端点由 Glyph 统一设置，",
        " * 颜色仍然逐处传（主题色 / 危险色 / hero 上的白色）。",
        " */",
        "public final class IconData {",
        "",
        "    private IconData() {",
        "    }",
        "",
    ]
    for i, (name, group, _, _) in enumerate(icons):
        lines.append("    /** %s */" % group)
        lines.append("    static final int %s = %d;" % (const_name(name), i))
    lines += [
        "",
        "    static final int COUNT = %d;" % len(icons),
        "",
        "    /** 描边路径（fill=none，stroke=currentColor） */",
        "    static final String[][] STROKE = {",
    ]
    for name, _, stroke, _ in icons:
        lines.append('        { %s }, // %s' % (
            ", ".join('"%s"' % d for d in stroke) if stroke else "", name))
    lines += [
        "    };",
        "",
        "    /** 实心路径（少量图标里的小圆点） */",
        "    static final String[][] FILL = {",
    ]
    for name, _, _, fill in icons:
        lines.append('        { %s }, // %s' % (
            ", ".join('"%s"' % d for d in fill) if fill else "", name))
    lines += ["    };", "}", ""]
    return "\n".join(lines)


def harmony_of(icons):
    def cases(field):
        out = []
        for name, _, stroke, fill in icons:
            d = stroke if field == "stroke" else fill
            body = " ".join(d)
            out.append("      case '%s':\n        return '%s';" % (name, body))
        return "\n".join(out)

    names = ",\n".join("    '%s'" % i[0] for i in icons)
    return """// @generated by scripts/gen_icons.py —— 改图标请改 design/icons 后重跑脚本

/**
 * 图标路径（绝对坐标 M/L/C/Z，24×24 设计稿坐标）。
 *
 * 生成脚本已经把圆弧、二次曲线、相对指令都转成三次贝塞尔，
 * 所以 IconPath.replay 只需要认 M/L/C/Z 四个指令。
 */
export class IconData {
  static readonly NAMES: string[] = [
%s
  ];

  static stroke(kind: string): string {
    switch (kind) {
%s
      default:
        return '';
    }
  }

  static fill(kind: string): string {
    switch (kind) {
%s
      default:
        return '';
    }
  }
}
""" % (names, cases("stroke"), cases("fill"))


def ios_of(icons):
    def block(field):
        out = []
        for name, _, stroke, fill in icons:
            d = stroke if field == "stroke" else fill
            out.append('        "%s": "%s",' % (name, " ".join(d)))
        return "\n".join(out)

    return """// @generated by scripts/gen_icons.py —— 改图标请改 design/icons 后重跑脚本
import Foundation

/// 图标路径（绝对坐标 M/L/C/Z，24×24 设计稿坐标）。
///
/// 生成脚本已把圆弧与二次曲线转成三次贝塞尔，`LineIcon` 只需要认四个指令。
enum IconData {
    static let stroke: [String: String] = [
%s
    ]

    static let fill: [String: String] = [
%s
    ]
}
""" % (block("stroke"), block("fill"))


def vector_xml(name, stroke, fill):
    def esc(d):
        return d.replace("&", "&amp;").replace("<", "&lt;").replace('"', "&quot;")

    out = [
        '<?xml version="1.0" encoding="utf-8"?>',
        "<!-- @generated by scripts/gen_icons.py —— 改图标请改 design/icons 后重跑脚本 -->",
        '<vector xmlns:android="http://schemas.android.com/apk/res/android"',
        '    android:width="24dp"',
        '    android:height="24dp"',
        '    android:viewportWidth="24"',
        '    android:viewportHeight="24">',
    ]
    if stroke:
        out += [
            "    <path",
            '        android:pathData="%s"' % esc(" ".join(stroke)),
            '        android:fillColor="#00000000"',
            '        android:strokeColor="#FFFFFFFF"',
            '        android:strokeWidth="2"',
            '        android:strokeLineCap="round"',
            '        android:strokeLineJoin="round" />',
        ]
    for d in fill:
        out += [
            "    <path",
            '        android:pathData="%s"' % esc(d),
            '        android:fillColor="#FFFFFFFF" />',
        ]
    out.append("</vector>")
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="只比对，不写入")
    a = ap.parse_args()

    if not os.path.isdir(LIB):
        sys.exit("找不到图标库：%s" % LIB)

    icons = load_icons()
    by_name = {"%s/%s" % (i[1], i[0]): i for i in icons}
    stale = []

    outputs = [(OUT_ANDROID, java_of(icons)),
               (OUT_HARMONY, harmony_of(icons)),
               (OUT_IOS, ios_of(icons))]

    for path, content in outputs:
        prev = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
        if content != prev:
            stale.append(os.path.relpath(path, ROOT))
            if not a.check:
                open(path, "w", encoding="utf-8", newline="\n").write(content)

    for res, icon in NAV_MAP.items():
        if icon not in by_name:
            sys.exit("页签图标缺失：%s" % icon)
        _, _, stroke, fill = by_name[icon]
        xml = vector_xml(res, stroke, fill)
        p = os.path.join(OUT_RES, res + ".xml")
        prev = open(p, encoding="utf-8").read() if os.path.exists(p) else ""
        if xml != prev:
            stale.append(os.path.relpath(p, ROOT))
            if not a.check:
                open(p, "w", encoding="utf-8", newline="\n").write(xml)

    if a.check:
        if stale:
            print("产物与图标库不同步：")
            for s in stale:
                print("  " + s)
            sys.exit(1)
        print("图标产物已同步（%d 个图标）" % len(icons))
        return

    print("✓ 生成 %d 个图标（已归一化为 M/L/C/Z）" % len(icons))
    for path, _ in outputs:
        print("  " + os.path.relpath(path, ROOT))
    print("  %s 下 %d 个页签 vector" % (os.path.relpath(OUT_RES, ROOT), len(NAV_MAP)))


if __name__ == "__main__":
    main()
