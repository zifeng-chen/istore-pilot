"""本地绘制品牌图标：华为 / 荣耀 / 绿联 / 群晖 / 中兴 / 微软 / Gemini / Plex / Jellyfin。

为什么不用 `fetch_app_icons.py` 那一套去 App Store 抓？
  - 华为、荣耀根本没有「品牌 App」的官方图标（商城、运动健康是子品牌），
    抓回来的是别人的脸，比首字色块更离谱；
  - 绿联 NAS、群晖 NAS 是**设备**，App Store 里只有配套 App，图标也不是品牌标；
  - 抓图依赖外网，离线环境跑不了。

所以这几张用品牌自己的视觉语言在本地画：品牌色底 + 白色标识 / 单词标，
尺寸、抗锯齿和抓回来那批保持一致（128px，超采样 4 倍后降采样）。
同一份脚本可重跑，改完直接 `python scripts/sync_app_icons.py` 同步三端。

用法：
    python scripts/make_brand_icons.py           # 生成/覆盖
    python scripts/make_brand_icons.py --check   # 只检查是否缺失
"""

from __future__ import annotations

import math
import os
import sys

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "android", "app", "src", "main", "res", "drawable-nodpi")

SIZE = 128          # 最终边长，和 fetch_app_icons 那批一致
SS = 4              # 超采样倍数
S = SIZE * SS

FONT_BOLD = "C:/Windows/Fonts/arialbd.ttf"
FONT_REG = "C:/Windows/Fonts/arial.ttf"


# ----------------------------------------------------------------- 基础工具

def tile(color: str) -> Image.Image:
    """纯色底。图标圆角由客户端裁（AppIcon 里 borderRadius = 24%）。"""
    return Image.new("RGB", (S, S), color)


def font(size: int, bold: bool = True) -> ImageFont.FreeTypeFont:
    path = FONT_BOLD if bold else FONT_REG
    try:
        return ImageFont.truetype(path, size)
    except OSError:
        return ImageFont.load_default()


def fit_text(draw: ImageDraw.ImageDraw, text: str, max_w: int, max_h: int,
             bold: bool = True, tracking: float = 0.0) -> tuple[ImageFont.FreeTypeFont, list[int]]:
    """把文字压进 max_w × max_h：从大往小试，返回字号和逐字宽度。"""
    size = max_h
    while size > 8:
        f = font(size, bold)
        widths = [draw.textlength(ch, font=f) for ch in text]
        total = sum(widths) + tracking * (len(text) - 1)
        if total <= max_w and size <= max_h:
            return f, widths
        size -= 2
    f = font(8, bold)
    return f, [draw.textlength(ch, font=f) for ch in text]


def wordmark(img: Image.Image, text: str, color: str = "#FFFFFF",
             width_ratio: float = 0.74, tracking_ratio: float = 0.02) -> None:
    """居中画一行字（带字距）。宽度按 width_ratio 收进画布。"""
    d = ImageDraw.Draw(img)
    max_w = int(S * width_ratio)
    max_h = int(S * 0.30)
    tracking = tracking_ratio * S
    f, widths = fit_text(d, text, max_w, max_h, tracking=tracking)
    total = sum(widths) + tracking * (len(text) - 1)
    x = (S - total) / 2
    # 用 bbox 校正垂直位置：Arial 的 ascent 偏上，直接锚 mm 会浮
    bbox = d.textbbox((0, 0), text, font=f)
    h = bbox[3] - bbox[1]
    y = (S - h) / 2 - bbox[1]
    for ch, w in zip(text, widths):
        d.text((x, y), ch, font=f, fill=color)
        x += w + tracking


def finish(img: Image.Image, name: str) -> None:
    out = os.path.join(RES, name)
    img.resize((SIZE, SIZE), Image.LANCZOS).save(out, "PNG", optimize=True)
    print(f"  ok  {name:<28} {os.path.getsize(out) // 1024} KB")


# ----------------------------------------------------------------- 各个品牌

def huawei() -> None:
    """华为：红色底 + 白色八瓣花。

    华为的标是八片「水滴形」花瓣绕中心放射：花心那端收成尖，
    外端是圆的，相邻花瓣之间留一条细缝，中间一个小孔。
    椭圆拼不出这个形状（叠起来会糊成一整块白圆盘），所以按半径参数化：
    宽度随半径长起来，外端再补一个半圆把尖角磨圆。
    """
    red = "#C8102E"
    img = tile(red)
    d = ImageDraw.Draw(img)
    cx = cy = S / 2

    r0 = S * 0.072       # 花瓣内端半径
    R = S * 0.312        # 花瓣外端半径
    W = S * 0.088        # 花瓣最宽处的半宽
    steps = 40

    for k in range(8):
        base = math.radians(-90 + 45 * k)
        left, right = [], []
        for i in range(steps + 1):
            t = i / steps
            r = r0 + (R - r0) * t
            w = W * (t ** 0.55) * (1 - 0.16 * t)
            left.append((w, -r))
            right.append((-w, -r))
        # 外端半圆：把水滴的尖磨圆
        tip_w = W * (1 - 0.16)
        arc = []
        for i in range(13):
            a = math.pi * i / 12
            arc.append((tip_w * math.cos(a), -R - tip_w * math.sin(a) * 0.55))

        local = left + arc + right[::-1]
        pts = [(cx + x * math.cos(base) - y * math.sin(base),
                cy + x * math.sin(base) + y * math.cos(base)) for x, y in local]
        d.polygon(pts, fill="#FFFFFF")

    finish(img, "ic_app_huawei.png")


def honor() -> None:
    """荣耀：深空蓝底 + 白色 HONOR 单词标（品牌本身就是纯文字标）。"""
    img = tile("#0E1B33")
    wordmark(img, "HONOR", width_ratio=0.76, tracking_ratio=0.035)
    finish(img, "ic_app_honor.png")


def ugreen() -> None:
    """绿联：品牌绿 + 白色 UGREEN。"""
    img = tile("#00A650")
    wordmark(img, "UGREEN", width_ratio=0.78, tracking_ratio=0.02)
    finish(img, "ic_app_ugreen.png")


def synology() -> None:
    """群晖：品牌蓝 + 白色 S。

    NAS 品牌，App Store 里只有配套 App（DS finder 之类），图标不是品牌标。
    两段圆弧拼出来的 S 中间有个难看的接缝，直接用粗体字母更干净。
    """
    img = tile("#0B72B9")
    d = ImageDraw.Draw(img)
    f = font(int(S * 0.62))
    bbox = d.textbbox((0, 0), "S", font=f)
    x = (S - (bbox[2] - bbox[0])) / 2 - bbox[0]
    y = (S - (bbox[3] - bbox[1])) / 2 - bbox[1]
    d.text((x, y), "S", font=f, fill="#FFFFFF")
    finish(img, "ic_app_synology.png")


def zte() -> None:
    """中兴：品牌蓝 + 白色 ZTE。"""
    img = tile("#0068B7")
    wordmark(img, "ZTE", width_ratio=0.70, tracking_ratio=0.06)
    finish(img, "ic_app_zte.png")


def microsoft() -> None:
    """微软：四个彩色方块（官方标就是这个，之前那张是 Microsoft 365 的蓝色方块）。"""
    img = tile("#FFFFFF")
    d = ImageDraw.Draw(img)
    gap = S * 0.045
    side = (S * 0.62 - gap) / 2
    x0 = (S - (side * 2 + gap)) / 2
    y0 = x0
    colors = [("#F25022", 0, 0), ("#7FBA00", 1, 0),
              ("#00A4EF", 0, 1), ("#FFB900", 1, 1)]
    for color, cx, cy in colors:
        x = x0 + cx * (side + gap)
        y = y0 + cy * (side + gap)
        d.rectangle((x, y, x + side, y + side), fill=color)
    finish(img, "ic_app_microsoft.png")


def gemini() -> None:
    """Gemini：蓝紫渐变底 + 白色四角星（品牌标就是这颗星）。"""
    img = Image.new("RGB", (S, S), "#4B7BF5")
    d = ImageDraw.Draw(img)
    # 垂直渐变：上蓝下紫
    for y in range(S):
        t = y / S
        r = int(75 + (150 - 75) * t)
        g = int(123 + (90 - 123) * t)
        b = int(245 + (245 - 245) * t)
        d.line((0, y, S, y), fill=(r, g, b))

    cx = cy = S / 2
    R = S * 0.31
    pinch = 0.36          # 收腰：0 = 菱形（细尖），越大越饱满
    pts = []
    for i in range(4):
        ang = math.radians(-90 + i * 90)
        pts.append((cx + R * math.cos(ang), cy + R * math.sin(ang)))
    # 四个角之间用向内收的控制点连成四角星
    poly = []
    for i in range(4):
        ax, ay = pts[i]
        bx, by = pts[(i + 1) % 4]
        poly.append((ax, ay))
        mx, my = (ax + bx) / 2, (ay + by) / 2
        poly.append((cx + (mx - cx) * pinch, cy + (my - cy) * pinch))
    d.polygon(poly, fill="#FFFFFF")
    finish(img, "ic_app_gemini.png")


def plex() -> None:
    """Plex：深底 + 琥珀色三角（品牌色 #E5A00D）。"""
    img = tile("#1F1F1F")
    d = ImageDraw.Draw(img)
    h = S * 0.34
    d.polygon([(S * 0.36, S / 2 - h / 2), (S * 0.36, S / 2 + h / 2), (S * 0.68, S / 2)],
              fill="#E5A00D")
    finish(img, "ic_app_plex.png")


def jellyfin() -> None:
    """Emby / Jellyfin：紫底 + 白色播放三角。"""
    img = tile("#7B4DFF")
    d = ImageDraw.Draw(img)
    h = S * 0.34
    d.polygon([(S * 0.36, S / 2 - h / 2), (S * 0.36, S / 2 + h / 2), (S * 0.70, S / 2)],
              fill="#FFFFFF")
    finish(img, "ic_app_jellyfin.png")


JOBS = [
    ("ic_app_huawei.png", huawei),
    ("ic_app_honor.png", honor),
    ("ic_app_ugreen.png", ugreen),
    ("ic_app_synology.png", synology),
    ("ic_app_zte.png", zte),
    ("ic_app_microsoft.png", microsoft),
    ("ic_app_gemini.png", gemini),
    ("ic_app_plex.png", plex),
    ("ic_app_jellyfin.png", jellyfin),
]


def main() -> int:
    check = "--check" in sys.argv
    os.makedirs(RES, exist_ok=True)
    missing = [n for n, _ in JOBS if not os.path.exists(os.path.join(RES, n))]

    if check:
        print("缺图：" + ("、".join(missing) if missing else "无"))
        return 1 if missing else 0

    print("绘制品牌图标 →", RES)
    for name, fn in JOBS:
        fn()
    print("完成 %d 张。接着跑 python scripts/sync_app_icons.py 同步 iOS / 鸿蒙。" % len(JOBS))
    return 0


if __name__ == "__main__":
    sys.exit(main())
