#!/usr/bin/env python3
"""把用户提供的图标母版缩放到 Android / HarmonyOS / iOS 各平台规格。

**只缩放，不裁切、不重绘。** 母版本身就是一张成品 app 图标
（蓝色圆角方块 + 内部图形，1129×1129，四角透明），所以：

1. 不裁任何边距，整图 1:1 缩放
2. 只有需要不透明方图的平台（鸿蒙 / iOS / Android 传统图标）才把四角
   透明区补成相邻的蓝，纯粹是填 alpha，图形一个像素都不动
3. Android **不再使用 adaptive icon** —— 成品图标塞进 adaptive 前景会被
   系统按 66% 安全区裁掉外圈（浅蓝弧线整条消失），只能走传统 mipmap

用法:
    python scripts/make_icons.py                    # 用默认母版
    python scripts/make_icons.py --src 图.png
"""

from __future__ import annotations

import argparse
import os
import re
import sys

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ANDROID_RES = os.path.join(ROOT, "android", "app", "src", "main", "res")
HARMONY = os.path.join(ROOT, "harmony")

# 用户提供的母版：完整的蓝色圆角方块图标，四角透明
MASTER_CANDIDATES = [
    os.path.expanduser(r"~\Desktop\蓝色路由系统管理图标.png"),
    r"C:\Users\chaof\Desktop\蓝色路由系统管理图标.png",
]

# Android 传统图标各密度边长
DENSITIES = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}

# 圆角半径比例（相对边长）。母版自己的圆角约 22.5%
RADIUS_RATIO = 0.225


def load_master(path: str) -> Image.Image:
    """读母版。只做方图化（非正方形时取中心正方），绝不裁边距。"""
    im = Image.open(path).convert("RGBA")
    side = min(im.size)
    left = (im.width - side) // 2
    top = (im.height - side) // 2
    return im.crop((left, top, left + side, top + side))


def _bg_blue(px, w: int, y: int, start: int, step: int) -> tuple[int, int, int] | None:
    """从 start 往内扫，返回第一个"像背景蓝"的像素颜色。"""
    limit = int(w * 0.42)
    for i, x in enumerate(range(start, w if step > 0 else -1, step)):
        if i > limit:
            break
        c = px[x, y]
        if c[3] >= 200 and (c[2] - c[0]) > 180 and c[1] < 205:
            return c[:3]
    return None


def fill_outside(im: Image.Image, alpha_thr: int = 240) -> Image.Image:
    """把透明区补成相邻的蓝，返回完全不透明的 RGB 图。

    逐行找左右两侧的本体边界（alpha >= 阈值），用靠内 8px 的颜色向外填充，
    渐变能顺着延续。四角因此变成与弧线同色的蓝，不会留白三角。
    边缘那圈半透明羽化像素会按 alpha 混合到填充色上，不会变成白边。
    """
    im = im.convert("RGBA")
    orig = im.copy()
    opx = orig.load()
    w, h = im.size
    px = im.load()

    row_info: dict[int, tuple[int, int, tuple[int, int, int]]] = {}
    for y in range(h):
        left = next((x for x in range(w) if px[x, y][3] >= alpha_thr), None)
        if left is None:
            continue
        right = next((x for x in range(w - 1, -1, -1) if px[x, y][3] >= alpha_thr), None)
        assert right is not None
        # 填充色必须取"真正的背景蓝"，不能取最外侧那几个像素 ——
        # 圆角那一行最外面正好是浅蓝弧线 + 羽化边，拿它填会让四个角发灰。
        # 背景蓝的判据：b-r > 180（深蓝底 b-r≈230，浅蓝弧 b-r≈143，白 b-r≈0）
        cl = _bg_blue(px, w, y, left, 1) or px[min(left + 8, w - 1), y][:3]
        cr = _bg_blue(px, w, y, right, -1) or px[max(right - 8, 0), y][:3]
        row_info[y] = (left - 1, right + 1, cl)
        # 原图最外圈有一层"半透明黑"（RGB≈0，alpha 很低），只填 im 不填 orig
        # 的话 composite 时它会被混进来，在四角留下一道暗边，所以两处一起填
        for x in range(0, left):
            px[x, y] = opx[x, y] = (*cl, 255)
        for x in range(right + 1, w):
            px[x, y] = opx[x, y] = (*cr, 255)

    # 整行都没有本体像素时（最顶/最底那几行还在羽化），整行复制最近的已填行。
    # 用 while 往外扩而不是只看 ±2 —— 顶部连续 4~5 行都处于羽化区，
    # 只看邻近两行会漏掉最外圈，留下一条黑/白细边。
    processed = sorted(row_info)
    for y in range(h):
        if y in row_info or not processed:
            continue
        k = min(processed, key=lambda v: abs(v - y))
        for x in range(w):
            px[x, y] = opx[x, y] = px[x, k]

    bg = im.copy()
    bg.putalpha(255)
    # 原图（带 alpha）叠在填充层上：四角保留填充色，半透明边缘按 alpha 正常混合
    return Image.alpha_composite(bg, orig).convert("RGB")


def squircle(size: int) -> Image.Image:
    big = 4
    px = size * big
    mask = Image.new("L", (px, px), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, px - 1, px - 1), radius=int(px * RADIUS_RATIO), fill=255
    )
    return mask.resize((size, size), Image.LANCZOS)


def circle(size: int) -> Image.Image:
    big = 4
    px = size * big
    mask = Image.new("L", (px, px), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, px - 1, px - 1), fill=255)
    return mask.resize((size, size), Image.LANCZOS)


def save(im: Image.Image, path: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    im.save(path, "PNG", optimize=True)
    print(f"  {os.path.relpath(path, ROOT):58} {im.size[0]}×{im.size[1]}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=None)
    args = ap.parse_args()

    src = args.src or next((p for p in MASTER_CANDIDATES if os.path.exists(p)), "")
    if not src or not os.path.exists(src):
        print("找不到母版图，用 --src 指定", file=sys.stderr)
        return 2

    base = load_master(src)
    print(f"母版: {src}")
    print(f"尺寸: {base.shape if hasattr(base, 'shape') else base.size}  （不裁切，整图缩放到各规格）")

    flat = fill_outside(base)  # 不透明方图，四角补蓝
    print(f"补角后: {flat.size[0]}×{flat.size[1]}  模式 {flat.mode}")

    # ---- Android 传统图标：整图缩放，保留原圆角（四角透明，启动器自己裁）
    print("\nAndroid mipmap（传统图标，无 adaptive 裁切）:")
    for name, size in DENSITIES.items():
        d = os.path.join(ANDROID_RES, f"mipmap-{name}")
        sq = base.resize((size, size), Image.LANCZOS)
        save(sq, os.path.join(d, "ic_launcher.png"))
        # round 变体：只换遮罩，图形不变
        rnd = base.resize((size, size), Image.LANCZOS)
        rnd.putalpha(circle(size))
        save(rnd, os.path.join(d, "ic_launcher_round.png"))

    # ---- 干掉 adaptive icon 声明，否则系统优先用它并裁掉外圈图形
    for rel in ("mipmap-anydpi-v26/ic_launcher.xml",
                "mipmap-anydpi-v26/ic_launcher_round.xml",
                "drawable-nodpi/ic_launcher_foreground.png",
                "drawable/ic_launcher_foreground.xml"):
        p = os.path.join(ANDROID_RES, rel)
        if os.path.exists(p):
            os.remove(p)
            print(f"  已移除 {os.path.relpath(p, ROOT)}")

    # ---- 鸿蒙 / iOS：不透明方图（系统自己套圆角）
    opaque = flat.resize((1024, 1024), Image.LANCZOS)
    print("\nHarmonyOS:")
    for rel in ("AppScope/resources/base/media/app_icon.png",
                "entry/src/main/resources/base/media/app_icon.png",
                "entry/src/main/resources/base/media/start_icon.png"):
        save(opaque, os.path.join(HARMONY, rel))

    print("\niOS:")
    save(opaque, os.path.join(MOBILE, "ios", "Assets", "AppIcon-1024.png"))

    # ---- adaptive 背景色保留（万一以后回退）
    colors = os.path.join(ANDROID_RES, "values", "colors.xml")
    if os.path.exists(colors):
        with open(colors, "r", encoding="utf-8") as fh:
            text = fh.read()
        bg = flat.getpixel((4, 4))
        new = f'<color name="ic_launcher_background">#{bg[0]:02X}{bg[1]:02X}{bg[2]:02X}</color>'
        text2 = re.sub(r'<color name="ic_launcher_background">#[0-9A-Fa-f]{6}</color>', new, text)
        if text2 != text:
            with open(colors, "w", encoding="utf-8") as fh:
                fh.write(text2)
            print(f"\n已更新 ic_launcher_background → #{bg[0]:02X}{bg[1]:02X}{bg[2]:02X}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
