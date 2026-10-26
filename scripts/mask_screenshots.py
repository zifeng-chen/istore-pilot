#!/usr/bin/env python3
"""给截图里的敏感信息打码。

策略：整行实心覆盖 + 打码点标记。
不用马赛克 —— 马赛克在粗体大字上仍能看出字形轮廓，实心覆盖才是不可还原的。
覆盖色从该行自身的主色取样，所以贴合卡片底色，不会突兀。

坐标按图片原始像素（1080x2412）给出，横向统一取卡片内 60~1020，
宁可比实际文字宽一些，也不留露出半个字符的风险。

原始文件备份到 %USERPROFILE%/.workbuddy/mask_backup/，脚本每次都从备份重做，
可以反复运行。
"""
import os
import shutil


from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHOT = os.path.join(ROOT, "docs", "screenshots")
BACKUP = os.path.expanduser("~/.workbuddy/mask_backup")

DOT_R = 4           # 打码点半径
DOT_GAP = 16        # 打码点间距

# 文件 -> [(x0, y0, x1, y1), ...]
SPEC = {
    "promo/network.png": [
        (60, 518, 1020, 596),       # 大号 WAN IPv4
        (60, 604, 1020, 650),       # 网关 · 在线时长
        (60, 992, 1020, 1042),      # PPPoE 账号
        (60, 1143, 1020, 1188),     # DNS
        (60, 1795, 1020, 1845),     # IPv6 前缀
    ],
    "promo/network2.png": [
        (60, 518, 1020, 596),
        (60, 604, 1020, 650),
        (60, 992, 1020, 1042),
        (60, 1143, 1020, 1188),
        (60, 1795, 1020, 1845),
    ],
    "promo/network3.png": [
        (60, 214, 1020, 267),
    ],
    "promo/pending.png": [
        (60, 595, 1020, 692),
    ],
    "promo/pending2.png": [
        (60, 912, 1020, 992),       # 大号 WAN IPv4
        (60, 998, 1020, 1048),      # 网关 · 在线时长
        (60, 1385, 1020, 1440),     # PPPoE 账号
        (60, 1540, 1020, 1582),     # DNS
    ],
    "promo/confirmed.png": [
        (60, 210, 1020, 368),       # 大号 WAN IPv4 + 网关 · 在线时长
        (60, 664, 1020, 708),       # PPPoE 账号
        (60, 814, 1020, 854),       # DNS
        (60, 1466, 1020, 1506),     # IPv6 前缀
    ],
    "promo/dlg1.png": [
        (60, 213, 1020, 269),
    ],
    "promo/settings.png": [
        (60, 1883, 1020, 1988),     # IPv4 行
        (60, 2040, 1020, 2124),     # IPv6 行
    ],
    "06-settings.png": [
        (60, 268, 1020, 318),
    ],
    "final/05_settings_top.png": [
        (60, 1050, 1020, 1102),     # IPv4 行
        (60, 1124, 1020, 1174),     # IPv6 行
    ],
    # 带 token 的订阅链接（比 IP 更敏感）
    "final/03_proxy.png": [
        (60, 1610, 1020, 1660),
        (60, 1818, 1020, 1868),
        (60, 2027, 1020, 2080),
    ],
    "final/08_sub_actions.png": [
        (180, 1572, 900, 1666),     # 完整订阅地址（两行）
    ],
    # 含公网 IP 与私有域名（Plex / ug.link）的访问列表，整块覆盖
    "03-device-detail.png": [
        (60, 1985, 1020, 2412),
    ],
}


def _bg_color(im: Image.Image, box) -> tuple:
    """取该区域的中位色当背景色。

    不能用众数：hero 卡上那行 IP 是白色粗体，占的像素比绿底还多，
    众数会取到白色，糊出一条白条。中位数对「少数派」的文字更稳。
    """
    crop = im.crop(box).convert("RGB")
    px = list(crop.getdata())
    n = len(px)
    if not n:
        return (255, 255, 255)
    return tuple(sorted(p[c] for p in px)[n // 2] for c in range(3))


def _dot_color(bg: tuple) -> tuple:
    lum = 0.299 * bg[0] + 0.587 * bg[1] + 0.114 * bg[2]
    return (255, 255, 255) if lum < 140 else (128, 138, 132)


def redact(im: Image.Image, box) -> None:
    x0, y0, x1, y1 = [int(v) for v in box]
    x0, y0 = max(0, x0), max(0, y0)
    x1, y1 = min(im.width, x1), min(im.height, y1)
    if x1 - x0 < 4 or y1 - y0 < 4:
        return

    bg = _bg_color(im, (x0, y0, x1, y1))
    draw = ImageDraw.Draw(im)
    draw.rectangle([x0, y0, x1 - 1, y1 - 1], fill=bg)

    # 打码点：明确表示「此处被隐去」，避免看起来像渲染缺失
    cy = (y0 + y1) // 2
    n = max(3, (x1 - x0 - 40) // DOT_GAP)
    total = (n - 1) * DOT_GAP
    sx = (x0 + x1) // 2 - total // 2
    for i in range(n):
        cx = sx + i * DOT_GAP
        draw.ellipse([cx - DOT_R, cy - DOT_R, cx + DOT_R, cy + DOT_R], fill=_dot_color(bg))


def main() -> int:
    os.makedirs(BACKUP, exist_ok=True)
    total = 0
    for rel, boxes in SPEC.items():
        path = os.path.join(SHOT, rel.replace("/", os.sep))
        if not os.path.exists(path):
            print(f"!! 缺失 {rel}")
            continue

        bak = os.path.join(BACKUP, rel.replace("/", "__"))
        if not os.path.exists(bak):
            shutil.copy2(path, bak)

        im = Image.open(bak).convert("RGB")     # 永远从原件重做
        for b in boxes:
            redact(im, b)
        im.save(path, optimize=True)
        total += len(boxes)
        print(f"  {rel:32s} {len(boxes)} 处")
    print(f"\n共覆盖 {total} 处，原件备份于 {BACKUP}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
