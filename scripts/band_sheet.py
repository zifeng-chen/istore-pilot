#!/usr/bin/env python3
"""把指定纵向范围内的文字行切成条，拼成一张对照图，便于逐行确认。

用法:
    python scripts/band_sheet.py <图片> <y起> <y止> [--invert] [--out=表格.png]

输出：按从上到下的顺序排列的行条，左侧标注该行在原因片里的 y 起点。
同时在终端打印同一顺序的清单，两者一一对应。
"""
import sys

from PIL import Image, ImageDraw

W = 960              # 成品宽度
GAP = 6
PAD = 52             # 左侧留白，放 y 坐标


def find_bands(im, y0, y1, invert):
    px = im.load()
    w = im.width
    bands, inb, start = [], False, 0
    for y in range(y0, y1):
        c = 0
        for x in range(60, min(w, 1020), 2):
            v = px[x, y]
            if (v > 205) if invert else (v < 120):
                c += 1
        if c >= 4 and not inb:
            start, inb = y, True
        elif c < 2 and inb:
            bands.append((start, y))
            inb = False
    if inb:
        bands.append((start, y1))
    return [(s, e) for s, e in bands if e - s >= 6]


def main() -> int:
    argv = sys.argv[1:]
    flags = {a for a in argv if a.startswith("--")}
    args = [a for a in argv if not a.startswith("--")]
    path, y0, y1 = args[0], int(args[1]), int(args[2])
    invert = "--invert" in flags
    out = next((a.split("=", 1)[1] for a in argv if a.startswith("--out=")), "band_sheet.png")

    im = Image.open(path).convert("L")
    y1 = min(y1, im.height)
    bands = find_bands(im, y0, y1, invert)
    if not bands:
        print("没有找到文字行")
        return 1

    heights = [e - s for s, e in bands]
    H = sum(heights) + GAP * (len(bands) - 1) + 20
    sheet = Image.new("RGB", (W + PAD, H), (32, 32, 32))
    draw = ImageDraw.Draw(sheet)
    rgb = Image.open(path).convert("RGB")

    y = 10
    for i, (s, e) in enumerate(bands):
        crop = rgb.crop((60, s, 1020, e)).resize((W, e - s), Image.LANCZOS)
        sheet.paste(crop, (PAD, y))
        draw.text((6, y + (e - s) // 2 - 6), f"{s}", fill=(255, 220, 120))
        y += (e - s) + GAP
        print(f"  #{i:<2} y {s:4d}-{e:4d}  h={e - s:3d}")

    sheet.save(out)
    print(f"\n对照图: {out}   （{len(bands)} 行）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
