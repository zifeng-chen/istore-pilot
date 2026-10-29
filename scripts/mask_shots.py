#!/usr/bin/env python3
"""把真机截图里的本机信息替换掉，用于 README / 发布页。

为什么不用「打码块」：README 里的截图是门面，一块块灰方块很难看。
这里做的是「原位重绘」——
  1. 用逐行水平插值把原文字抹掉（左右各取一条干净像素做线性过渡），
     这样绿色渐变卡片上不会出现明显的矩形补丁；
  2. 用接近系统字体的字形、按原文字的实际墨迹高度重新渲染替换文字。

区域是按 1080x2412 的真机截图量的绝对值 —— 截图一旦改版（行高、字号、
增删卡片）就要重新量。脚本会检查每个区域里是否真的有墨迹，
没有就报警，避免「什么都没改还以为改好了」。

用法:
    python scripts/mask_shots.py            # 处理并写到 docs/screenshots/app/
    python scripts/mask_shots.py --check     # 只检查区域里有没有墨迹
"""

from __future__ import annotations

import os
import sys

from PIL import Image, ImageDraw, ImageFont

SRC = os.path.join("C:/tmp/shots2")
OUT = os.path.join("docs", "screenshots", "app")

#: 中文字体。Android 上是 Roboto + Noto Sans CJK，Windows 上最接近的是雅黑
FONT = "C:/Windows/Fonts/msyh.ttc"

#: (源文件, 列表[(box, 新文字, 对齐, 字号或 None)])
#: box = (x1, y1, x2, y2)，只覆盖原文字，别盖到相邻内容
JOBS = {
    "r-devices.png": [
        # 「最近活跃」三行的设备名与 IP。盒子右边界必须停在 845 之前 ——
        # 860 往右是绿色的实时速率，盖掉就"削掉一个数字"
        ((70, 1196, 845, 1234), "笔记本电脑", "left", 44),
        ((70, 1252, 600, 1286), "192.168.1.27", "left", None),
        ((70, 1344, 845, 1390), "家庭存储", "left", None),
        ((70, 1405, 600, 1436), "192.168.1.110", "left", None),
        ((70, 1495, 845, 1540), "手机", "left", None),
        ((70, 1556, 600, 1588), "192.168.1.159", "left", None),
    ],
    "r-proxy.png": [
        # 订阅名（牌卡大标题）与「当前配置」的值；后者要避开左侧「当前配置」标签
        ((92, 512, 500, 596), "我的订阅", "left", None),
        ((700, 1743, 872, 1786), "我的订阅", "right", None),
        # 节点行末尾的「当前 xxx」带机场命名
        ((115, 2128, 510, 2168), "当前 节点 A", "left", None),
    ],
    "r-settings.png": [
        # 连接卡大标题与「服务器地址」行
        ((92, 508, 700, 592), "192.168.1.1:8443", "left", None),
        ((655, 1088, 962, 1124), "192.168.1.1:8443", "right", None),
    ],
}


def bg_scan(im: Image.Image, box, probe: int = 14):
    """取盒子左右两侧的干净像素，逐行做线性插值填回去。

    渐变卡片（绿色 hero）横向有亮暗变化，单色填充会留下一条明显的竖带，
    逐行按左右两端插值能贴合原来的渐变。
    """
    x1, y1, x2, y2 = box
    px = im.load()
    lx = max(0, x1 - probe)
    rx = min(im.width - 1, x2 + probe)
    for y in range(y1, y2 + 1):
        cl = px[lx, y]
        cr = px[rx, y]
        for x in range(x1, x2 + 1):
            t = (x - x1) / max(1, (x2 - x1))
            px[x, y] = (
                round(cl[0] + (cr[0] - cl[0]) * t),
                round(cl[1] + (cr[1] - cl[1]) * t),
                round(cl[2] + (cr[2] - cl[2]) * t),
            )


def ink_stats(im: Image.Image, box):
    """返回 (墨迹框, 文字色)。文字色取「离背景最远」的那个像素。

    背景按盒子外圈的中位数估，所以浅灰字、白字都能量到。
    """
    x1, y1, x2, y2 = box
    px = im.load()
    ring = []
    for x in range(max(0, x1 - 10), min(im.width, x2 + 11), 4):
        ring.append(px[x, max(0, y1 - 6)])
        ring.append(px[x, min(im.height - 1, y2 + 6)])
    ring.sort(key=lambda c: c[0] + c[1] + c[2])
    bg = ring[len(ring) // 2]

    xs, ys, best, bestd = [], [], bg, -1
    for y in range(y1, min(y2 + 1, im.height)):
        for x in range(x1, min(x2 + 1, im.width)):
            c = px[x, y]
            d = abs(c[0] - bg[0]) + abs(c[1] - bg[1]) + abs(c[2] - bg[2])
            if d > 90:
                xs.append(x)
                ys.append(y)
                if d > bestd:
                    bestd, best = d, c
    if not xs:
        return None, bg
    return (min(xs), min(ys), max(xs), max(ys)), best


def fit_font(text: str, want_h: int) -> ImageFont.FreeTypeFont:
    """按「墨迹高度」反查字号：先粗调到接近，再微调到最接近的一档。"""
    best, bestdiff = None, 10 ** 9
    for size in range(max(12, want_h - 18), want_h + 24):
        f = ImageFont.truetype(FONT, size)
        box = f.getbbox(text, anchor="ls")
        h = box[3] - box[1]
        diff = abs(h - want_h)
        if diff < bestdiff:
            bestdiff, best = diff, f
        if h > want_h + 6:
            break
    return best


def redact(im: Image.Image, box, text: str, align: str, size: int | None):
    ink, color = ink_stats(im, box)
    if ink is None:
        return False
    ix1, iy1, ix2, iy2 = ink
    want_h = iy2 - iy1 + 1

    bg_scan(im, box)

    font = fit_font(text, want_h) if size is None else ImageFont.truetype(FONT, size)
    d = ImageDraw.Draw(im)
    bbox = d.textbbox((0, 0), text, font=font, anchor="ls")
    tw = bbox[2] - bbox[0]

    # 左对齐贴原文左沿；右对齐贴原文右沿
    x = ix1 if align == "left" else ix2 - tw
    # 基线：让新字的墨迹中心落在原墨迹中心
    baseline = iy1 + (want_h - (bbox[3] - bbox[1])) // 2 - bbox[1]
    d.text((x, baseline), text, font=font, fill=color, anchor="ls")
    return True


def main() -> int:
    check = "--check" in sys.argv
    os.makedirs(OUT, exist_ok=True)
    missing = 0
    for name, jobs in JOBS.items():
        src = os.path.join(SRC, name)
        if not os.path.exists(src):
            print("  缺少 %s" % src)
            missing += 1
            continue
        im = Image.open(src).convert("RGB")
        for box, text, align, size in jobs:
            if check:
                ink, color = ink_stats(im, box)
                state = "有墨迹" if ink else "!! 空（坐标可能过期）"
                print("  %-18s %-24s %s %s" % (name, text, state, ink))
                if not ink:
                    missing += 1
            else:
                if not redact(im, box, text, align, size):
                    print("  !! %s 的 %s 区域没找到文字，跳过" % (name, text))
                    missing += 1
        if not check:
            dst = os.path.join(OUT, name.replace("r-", ""))
            im.save(dst)
            print("  %-22s %dx%d" % (dst, *im.size))
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
