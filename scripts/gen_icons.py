#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 design/icons 里的 SVG 图标库转成 Android 资源。

产出两样东西：

1. `widget/IconData.java`
   每个图标一条（或几条）24×24 的 path data 字符串，`Glyph` 运行时用
   `androidx.core.graphics.PathParser` 解析一次并缓存。这样：

   - 不用为 76 个图标各写一个 vector xml（资源表会膨胀，还得逐个写 tint）；
   - 颜色仍由 `Glyph.setColor()` 控制，危险态/主题色照旧；
   - 和设计稿是同一份 path，改图只改 SVG 再跑本脚本。

2. `res/drawable/ic_nav_*.xml`、`ic_back.xml`
   底部页签/返回键走系统 ImageView，需要真正的 VectorDrawable。

用法：
    python scripts/gen_icons.py            # 生成
    python scripts/gen_icons.py --check    # 只校验产物是否与 SVG 同步
"""
import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, "design", "icons", "icons")
OUT_JAVA = os.path.join(
    ROOT, "android/app/src/main/java/com/izifeng/www/istorepilot/widget/IconData.java")
OUT_RES = os.path.join(ROOT, "android/app/src/main/res/drawable")

# 页签与返回键：drawable 名 → 图标名（图标库里的相对路径）
NAV_MAP = {
    "ic_nav_overview": "monitoring/system-load",
    "ic_nav_devices": "monitoring/devices",
    "ic_nav_proxy": "monitoring/proxy",
    "ic_nav_settings": "monitoring/network-settings",
    "ic_back": "common/back",
}

# 图标库里没有、但界面确实在用的：本地补 path，生成时一起并进去。
# 这类图标会写进 README 的「缺漏」清单，等设计补图后替换。
EXTRA = {
    "close": ["M6.6 6.6 17.4 17.4", "M17.4 6.6 6.6 17.4"],
}


def attrs(s):
    return {k: v for k, v in re.findall(r'([\w:-]+)="([^"]*)"', s)}


def f(v, default=0.0):
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def num(v):
    """去掉多余的 .0：12.0 → 12，2.50 → 2.5"""
    s = ("%.3f" % v).rstrip("0").rstrip(".")
    return s if s else "0"


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
                num(x + rx), num(y),
                num(x + w - rx),
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


def parse_svg(path):
    """返回 (stroke_paths, fill_paths)，坐标保持 24×24 视图。"""
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
        (fill if a.get("fill") == "currentColor" else stroke).append(d)
    return stroke, fill


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
        icons.append((name, "local", stroke, []))
    return icons


def const_name(name):
    return name.upper().replace("-", "_")


def java_of(icons):
    lines = [
        "package com.izifeng.www.istorepilot.widget;",
        "",
        "// @generated by scripts/gen_icons.py —— 改图标请改 design/icons 后重跑脚本",
        "",
        "/**",
        " * 图标路径数据，由 scripts/gen_icons.py 从 design/icons 生成，不要手改。",
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

    java = java_of(icons)
    old = open(OUT_JAVA, encoding="utf-8").read() if os.path.exists(OUT_JAVA) else ""
    if java != old:
        stale.append(os.path.relpath(OUT_JAVA, ROOT))
        if not a.check:
            open(OUT_JAVA, "w", encoding="utf-8", newline="\n").write(java)

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

    print("✓ 生成 %d 个图标" % len(icons))
    print("  %s" % os.path.relpath(OUT_JAVA, ROOT))
    print("  %s 下 %d 个页签 vector" % (os.path.relpath(OUT_RES, ROOT), len(NAV_MAP)))


if __name__ == "__main__":
    main()
