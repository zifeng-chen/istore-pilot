#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""鸿蒙端对比度自查：拿截图 + uitest dumpLayout，逐个文本节点量对比度。

应用市场审核报的是「控件类型 Text，对比度 1.03」这种数，说明他们是按控件矩形
取前景/背景色再算 WCAG 比值。这里复刻同一套算法，好在提交前自己先撞一遍。

用法：
    hdc shell uitest dumpLayout -p /data/local/tmp/p0.json
    hdc shell snapshot_display -f /data/local/tmp/p0.jpeg
    python scripts/harmony_contrast_audit.py build/audit

目录里按同名配对：p0.json + p0.jpeg。
阈值：正文 4.5:1，大字（>=24dp 或 >=19dp 加粗）3.0:1。
"""
from __future__ import annotations

import json
import os
import sys

try:
    from PIL import Image
except ImportError:  # pragma: no cover
    sys.exit("需要 Pillow：pip install pillow")

MIN_NORMAL = 4.5
MIN_LARGE = 3.0
# 节点矩形高度 >= 这个像素数，按「大字」放宽到 3.0
LARGE_PX = 72


def parse_bounds(s: str):
    # "[x1,y1][x2,y2]"
    body = s.replace("[", " ").replace("]", " ").replace(",", " ").split()
    if len(body) != 4:
        return None
    x1, y1, x2, y2 = (int(float(v)) for v in body)
    return (x1, y1, x2, y2)


def lum(rgb):
    def f(c):
        c /= 255.0
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    return 0.2126 * f(rgb[0]) + 0.7152 * f(rgb[1]) + 0.0722 * f(rgb[2])


def ratio(a, b):
    la, lb = lum(a), lum(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def colors_of(img, box):
    """量化后统计主色，返回 (背景色, 前景色)。"""
    x1, y1, x2, y2 = box
    w, h = x2 - x1, y2 - y1
    if w < 4 or h < 4:
        return None
    crop = img.crop((x1 + 1, y1 + 1, x2 - 1, y2 - 1)).convert("RGB")
    counts = {}
    for r, g, b in crop.getdata():
        k = (r >> 3, g >> 3, b >> 3)
        e = counts.get(k)
        if e is None:
            counts[k] = [0, r, g, b]
        else:
            e[0] += 1
            e[1] += r
            e[2] += g
            e[3] += b
    total = sum(v[0] for v in counts.values()) or 1
    ranked = sorted(counts.values(), key=lambda v: -v[0])
    bg = tuple(round(v / ranked[0][0]) for v in ranked[0][1:])
    best, best_ratio = bg, 1.0
    for c, r, g, b, in ((v[0], v[1], v[2], v[3]) for v in ranked[1:]):
        if c < 60 or c / total < 0.001:   # 抗锯齿噪点不要
            continue
        col = (round(r / c), round(g / c), round(b / c))
        rt = ratio(col, bg)
        if rt > best_ratio:
            best, best_ratio = col, rt
    return bg, best, best_ratio


def walk(node, out):
    a = node.get("attributes", {})
    txt = (a.get("text") or "").strip()
    if txt and a.get("type") in ("Text", "Button"):
        box = parse_bounds(a.get("bounds", ""))
        if box:
            out.append((txt, box))
    for c in node.get("children", []):
        walk(c, out)


def main():
    d = sys.argv[1] if len(sys.argv) > 1 else "build/audit"
    bad = 0
    for name in sorted(os.listdir(d)):
        if not name.endswith(".json"):
            continue
        stem = name[:-5]
        img_path = os.path.join(d, stem + ".jpeg")
        if not os.path.exists(img_path):
            img_path = os.path.join(d, stem + ".png")
        if not os.path.exists(img_path):
            continue
        img = Image.open(img_path)
        nodes = []
        walk(json.load(open(os.path.join(d, name), encoding="utf-8")), nodes)
        print("\n== %s  (%d 个文本节点)" % (stem, len(nodes)))
        for txt, box in nodes:
            got = colors_of(img, box)
            if got is None:
                continue
            rt = got[2]
            need = MIN_LARGE if (box[3] - box[1]) >= LARGE_PX else MIN_NORMAL
            if rt < need:
                bad += 1
                print("  !! %.2f:1 (需 %.1f)  %-28s %s" % (rt, need, txt[:26], box))
    print("\n共 %d 处低于阈值" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
