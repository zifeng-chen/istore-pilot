#!/usr/bin/env python3
"""生成 iStore Pilot 宣传图（高清）。

为什么重写：上一版画布只有 1600x900，中文按 15~26px 渲染，
发到大屏或放大看必然糊。这一版按 4K 原生尺寸绘制 ——
所有字号直接以目标像素渲染，不靠放大，文字边缘是实的。

素材：
  docs/screenshots/promo/{overview,network,devices,proxy,settings}.png（真机 1080x2412）
  ~/Desktop/蓝色路由系统管理图标.png                      （用户给的母版，只缩放不重绘）

用法: python scripts/make_promo.py
输出:
  dist/promo_4k.png                 3840x2160
  dist/promo_1080p.png              1920x1080
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

# ---------- 画布：4K 原生 ----------
W, H = 3840, 2160
S = W / 1600.0          # 坐标按 1600x900 的设计稿写，再乘这个系数

THEMES = {
    'dark': {
        'top': (10, 20, 17), 'bot': (4, 10, 8),
        'fg': (240, 246, 243), 'sub': (156, 174, 167), 'dim': (108, 126, 120),
        'stroke': (56, 78, 70), 'glow': (0, 168, 126),
        'accent': (46, 211, 166),
    },
    'light': {
        # 底色比截图里的卡片更沉一档，否则白卡片和背景糊成一片
        'top': (235, 242, 239), 'bot': (208, 224, 217),
        'fg': (18, 36, 30), 'sub': (74, 96, 89), 'dim': (112, 134, 127),
        'stroke': (176, 198, 190), 'glow': (0, 168, 126),
        'accent': (0, 128, 96),
    },
}

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHOT_DIR = os.path.join(ROOT, 'docs', 'screenshots', 'promo')
ICON_MASTER = os.path.expanduser('~/Desktop/蓝色路由系统管理图标.png')
OUT_DIR = os.path.join(ROOT, 'dist')

GREEN = (0, 168, 126)

BOLD = [r'C:\Windows\Fonts\msyhbd.ttc', r'C:\Windows\Fonts\msyh.ttc']
REG = [r'C:\Windows\Fonts\msyh.ttc', r'C:\Windows\Fonts\msyhbd.ttc']


def font(size_1600, bold=True):
    """size_1600 是设计稿里的字号（1600 宽基准），这里换算到 4K 实际像素。"""
    px = max(1, int(round(size_1600 * S)))
    for p in (BOLD if bold else REG):
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, px)
            except OSError:
                continue
    return ImageFont.load_default()


def P(v):
    """设计稿坐标 → 画布像素。"""
    return int(round(v * S))


def gradient(w, h, top, bottom, gamma=1.15):
    img = Image.new('RGB', (w, h), top)
    d = ImageDraw.Draw(img)
    for y in range(h):
        t = (y / h) ** gamma
        d.line([(0, y), (w, y)],
               fill=tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return img


def glow(base, cx, cy, size, strength, color):
    # 解析径向衰减，不用 GaussianBlur —— 大半径模糊会把能量摊到贴图方框边缘，
    # 在 x=贴图左边 处留下一道贯穿全高的硬接缝（实测差 14 个色阶，肉眼可见）
    n = 192
    spot = Image.new('L', (n, n), 0)
    sp = spot.load()
    c = (n - 1) / 2.0
    for y in range(n):
        for x in range(n):
            d = (((x - c) ** 2 + (y - c) ** 2) ** 0.5) / c
            if d < 1.0:
                sp[x, y] = int(255 * (1.0 - d) ** 2.2)
    spot = spot.resize((size, size), Image.BICUBIC)

    mask = Image.new('L', base.size, 0)
    mask.paste(spot, (int(cx - size // 2), int(cy - size // 2)))
    mask = mask.point(lambda v: int(v * strength))
    return Image.composite(Image.new('RGB', base.size, color), base, mask)


def load_icon(px):
    """用户给的母版：整图缩放，只把它自带的 alpha 当蒙版用，不重绘。"""
    im = Image.open(ICON_MASTER).convert('RGBA')
    return im.resize((px, px), Image.LANCZOS)


def paste_icon(canvas, x, y, w, shadow=True):
    icon = load_icon(P(w))
    if shadow:
        blur = int(24 * S)
        pad = blur * 2
        sh = Image.new('RGBA', (icon.width + pad * 2, icon.height + pad * 2), (0, 0, 0, 0))
        ImageDraw.Draw(sh).rounded_rectangle(
            [pad, pad, pad + icon.width, pad + icon.height],
            int(icon.width * 0.22), fill=(0, 0, 0, 120))
        sh = sh.filter(ImageFilter.GaussianBlur(blur))
        canvas.alpha_composite(sh, (P(x) - pad, P(y) - pad + int(8 * S)))
    canvas.alpha_composite(icon, (P(x), P(y)))


def paste_shot(canvas, name, x, top, width, radius=24, blur=22, alpha=132):
    src = Image.open(os.path.join(SHOT_DIR, name)).convert('RGB')
    sw, sh = src.size
    w, hh = P(width), P(int(width * sh / sw))
    shot = src.resize((w, hh), Image.LANCZOS)

    pad = int(blur * S) * 2
    shadow = Image.new('RGBA', (w + pad * 2, hh + pad * 2), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [pad, pad, pad + w, pad + hh], P(radius), fill=(0, 0, 0, alpha))
    shadow = shadow.filter(ImageFilter.GaussianBlur(int(blur * S)))
    canvas.alpha_composite(shadow, (P(x) - pad, P(top) - pad + int(12 * S)))

    mask = Image.new('L', (w, hh), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, w - 1, hh - 1], P(radius), fill=255)
    canvas.paste(shot, (P(x), P(top)), mask)
    return hh


def build(theme='dark', out_name='promo_4k.png'):
    t = THEMES[theme]
    canvas = gradient(W, H, t['top'], t['bot'])
    canvas = glow(canvas, P(1140), P(300), int(1000 * S), 0.12 if theme == 'dark' else 0.10, t['glow'])
    canvas = glow(canvas, P(320), P(880), int(820 * S), 0.06, t['glow'])
    canvas = canvas.convert('RGBA')
    dr = ImageDraw.Draw(canvas)

    LX = 88

    # ---------- 品牌行：图标 + 名称 ----------
    paste_icon(canvas, LX, 52, 76)
    dr.text((P(LX + 92), P(56)), 'iStore Pilot', font=font(30), fill=t['fg'])
    dr.text((P(LX + 94), P(99)), 'iStoreOS 原生客户端　·　Android / iOS / HarmonyOS',
            font=font(13.5, False), fill=t['sub'])

    # ---------- 主标题 ----------
    # 第二行用品牌绿做层次；字数控制在 5 个以内，否则会压到右边的手机
    dr.text((P(LX - 2), P(160)), '你的路由器', font=font(68), fill=t['fg'])
    dr.text((P(LX - 2), P(240)), '住进手机里', font=font(68), fill=t['accent'])

    dr.text((P(LX), P(348)), '不用开电脑，不用记命令。', font=font(20, False), fill=t['sub'])
    dr.text((P(LX), P(380)), '路由器的每一项状态，都在口袋里。', font=font(20, False), fill=t['sub'])

    dr.line([(P(LX), P(430)), (P(LX + 58), P(430))], fill=(*t['glow'], 215), width=max(2, int(3 * S)))

    # ---------- 四条卖点 ----------
    def feature(y, num, title, desc):
        r = 15
        cx, cy = P(LX + r), P(y + 2 + r)
        dr.ellipse([cx - P(r), cy - P(r), cx + P(r), cy + P(r)],
                   fill=(*t['glow'], 34), outline=(*t['glow'], 150), width=max(1, int(1.2 * S)))
        nf = font(13)
        label = str(num)
        nw = dr.textlength(label, font=nf)
        dr.text((cx - nw / 2, cy - P(10)), label, font=nf, fill=t['accent'])
        tx = LX + r * 2 + 16
        dr.text((P(tx), P(y - 4)), title, font=font(21), fill=t['fg'])
        dr.text((P(tx), P(y + 28)), desc, font=font(14.5, False), fill=t['sub'])

    # 不写具体数值：换到别人的环境就对不上了
    feature(470, 1, '五个页签，一眼看全', '概览 · 网络 · 设备 · 代理 · 设置')
    feature(556, 2, '全屋设备，在线离线分明', '实时速率、累计流量、一键禁网')
    feature(642, 3, '宽带和局域网，总算看懂了', '拨号状态、DHCP 地址池、防火墙风险')
    feature(728, 4, '代理与拦截，点一下就换', '节点延迟实测，拦截率与日志可查')

    # ---------- 底部版本信息 ----------
    dr.line([(P(LX), P(806)), (P(LX + 430), P(806))], fill=(255, 255, 255, 26) if theme == 'dark'
            else (0, 0, 0, 22), width=max(1, int(1 * S)))
    meta = ['v0.1.0', '5.3 MB', '免 Root', 'Android 8.0+']
    x = LX
    mf = font(14)
    for i, item in enumerate(meta):
        dr.text((P(x), P(826)), item, font=mf, fill=t['fg'] if theme == 'dark' else t['sub'])
        x += dr.textlength(item, font=mf) / S
        if i < len(meta) - 1:
            dr.text((P(x + 9), P(826)), '·', font=mf, fill=t['dim'])
            x += 24
    dr.text((P(LX), P(860)), '适配 iStoreOS 24.10 及以上', font=font(13.5, False), fill=t['dim'])

    # ---------- 三台手机：左低、中高（主视觉）、右低 ----------
    # 主视觉换成「网络」页：本轮新增的页签，信息密度最高
    side_w, main_w, gap = 280, 328, 20
    x_main = 628 + side_w + gap
    x_right = x_main + main_w + gap
    k = 1.0 if theme == 'dark' else 1.55      # 浅底上投影要更重，否则浮不起来
    paste_shot(canvas, 'devices.png', 628, 138, side_w, radius=22, blur=20, alpha=int(118 * k))
    paste_shot(canvas, 'network.png', x_main, 62, main_w, radius=26, blur=26, alpha=int(150 * k))
    paste_shot(canvas, 'overview.png', x_right, 138, side_w, radius=22, blur=20, alpha=int(118 * k))

    os.makedirs(OUT_DIR, exist_ok=True)
    out = os.path.join(OUT_DIR, out_name)
    canvas.convert('RGB').save(out, optimize=True)
    print(f'{out}  {canvas.size[0]}x{canvas.size[1]}')

    # 1080p 副本
    small = os.path.join(OUT_DIR, out_name.replace('4k', '1080p'))
    canvas.convert('RGB').resize((1920, 1080), Image.LANCZOS).save(small, optimize=True)
    print(f'{small}  1920x1080')


if __name__ == '__main__':
    if not os.path.exists(ICON_MASTER):
        print('缺少图标母版:', ICON_MASTER)
        sys.exit(1)
    missing = [n for n in ('overview.png', 'network.png', 'devices.png')
               if not os.path.exists(os.path.join(SHOT_DIR, n))]
    if missing:
        print('缺少截图:', missing)
        sys.exit(1)
    build('dark', 'promo_4k.png')
    build('light', 'promo_light_4k.png')
