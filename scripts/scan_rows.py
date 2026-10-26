#!/usr/bin/env python3
"""定位截图里的文字行，输出可用于打码的矩形区域（纯 Pillow，不依赖 numpy）。

用法:
    python scripts/scan_rows.py <图片> <y起> <y止> [--invert]
--invert  深底白字（hero 卡片）时用
"""
import sys

from PIL import Image


def main() -> int:
    argv = sys.argv[1:]
    flags = {a for a in argv if a.startswith("--")}

    def opt(name, default):
        for a in argv:
            if a.startswith(name + "="):
                return int(a.split("=", 1)[1])
        return default

    args = [a for a in argv if not a.startswith("--")]
    path, y0, y1 = args[0], int(args[1]), int(args[2])
    invert = "--invert" in flags
    x0, x1 = opt("--x0", 0), opt("--x1", 10 ** 6)

    im = Image.open(path).convert("L")
    w, h = im.size
    y0, y1 = max(0, y0), min(h, y1)
    x0, x1 = max(0, x0), min(w, x1)
    px = im.load()

    bands, inb, start = [], False, 0
    for y in range(y0, y1):
        c = 0
        for x in range(x0, x1, 2):                  # 隔点采样，够用且快
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

    for s, e in bands:
        if e - s < 6:
            continue
        xmin, xmax = w, -1
        for y in range(s, e):
            for x in range(x0, x1, 2):
                v = px[x, y]
                if (v > 205) if invert else (v < 120):
                    xmin = min(xmin, x)
                    xmax = max(xmax, x)
        if xmax < 0:
            continue
        print(f"y {s:4d}-{e:4d}  h={e - s:3d}  x {xmin:4d}-{xmax:4d}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
