#!/usr/bin/env python3
"""生成 iStore Pilot 宣传图（高清）。

为什么按 4K 原生绘制：1600x900 的设计稿缩放到大屏上中文会糊，
这里所有字号直接以目标像素渲染，不靠放大，文字边缘是实的。

素材：
  docs/screenshots/promo/{overview,devices,apps,proxy,settings}.png（真机 1080x2412）
  ~/Desktop/蓝色路由系统管理图标.png                      （用户给的母版，只缩放不重绘）

用法: python scripts/make_promo.py           # 只出亮色
      python scripts/make_promo.py dark      # 需要时再出深色
输出:
  dist/promo_light_4k.png           3840x2160
  dist/promo_light_1080p.png        1920x1080
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
# 素材用 docs/screenshots/app/ 里那份 —— 它们已经过 mask_shots.py 脱敏，
# 直接拿原始截图会把这户人家的设备名和内网地址画进宣传图
SHOT_DIR = os.path.join(ROOT, 'docs', 'screenshots', 'app')
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
    # 裁掉状态栏：三张截图不是同一秒拍的，时钟会差一两分钟，放大看就是「拼的」；
    # 顺手也去掉电量、网速这些小图标，画面上只剩 App 自己
    sw, sh = src.size
    src = src.crop((0, int(108 * sw / 1080), sw, sh))
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
    feature(470, 1, '四个页签，一眼看全', '概览 · 设备 · 代理 · 设置')
    feature(556, 2, '谁在用网，怎么连的一列看清', '5G / 2.4G / 有线，实时速率与累计流量')
    feature(642, 3, '流量花在哪个 App', '按应用汇总，点进去看连接与设备')
    feature(728, 4, '代理与拦截，点一下就换', '节点延迟实测，拦截率与日志可查')

    # ---------- 底部版本信息 ----------
    dr.line([(P(LX), P(806)), (P(LX + 430), P(806))], fill=(255, 255, 255, 26) if theme == 'dark'
            else (0, 0, 0, 22), width=max(1, int(1 * S)))
    meta = ['v0.1.3', '2.6 MB', '免 Root', 'Android 7.0+']
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
    # 只放四个主界面里的三个（概览 / 设备 / 代理）——
    # 副页面（设备清单、应用流量、设备详情）不上面，那是点进去才看的东西
    side_w, main_w, gap = 280, 328, 20
    x_main = 628 + side_w + gap
    x_right = x_main + main_w + gap
    k = 1.0 if theme == 'dark' else 1.55      # 浅底上投影要更重，否则浮不起来
    paste_shot(canvas, 'devices.png', 628, 138, side_w, radius=22, blur=20, alpha=int(118 * k))
    paste_shot(canvas, 'overview.png', x_main, 62, main_w, radius=26, blur=26, alpha=int(150 * k))
    paste_shot(canvas, 'proxy.png', x_right, 138, side_w, radius=22, blur=20, alpha=int(118 * k))

    os.makedirs(OUT_DIR, exist_ok=True)
    out = os.path.join(OUT_DIR, out_name)
    canvas.convert('RGB').save(out, optimize=True)
    print(f'{out}  {canvas.size[0]}x{canvas.size[1]}')

    # 1080p 副本
    small = os.path.join(OUT_DIR, out_name.replace('4k', '1080p'))
    canvas.convert('RGB').resize((1920, 1080), Image.LANCZOS).save(small, optimize=True)
    print(f'{small}  1920x1080')


# ---------------------------------------------------------------- 竖版单页

#: 四张竖图，一个主界面一张。副页面（设备清单 / 应用流量 / 设备详情）不上，
#: 那是点进去才有内容 —— 宣传图上放主界面，看的人一眼就知道这 App 长什么样
CARDS = [
    ('overview.png', 'promo-card-1-overview.png', '概览',
     '一眼看清家里的网', '实时速率 · 系统负载 · 宽带状态'),
    ('devices.png', 'promo-card-2-devices.png', '设备',
     '谁在用网，怎么连的', '5G / 2.4G / 有线，一列看清'),
    ('proxy.png', 'promo-card-3-proxy.png', '代理',
     '换个节点，不用开电脑', 'OpenClash 与 Passwall 一个界面'),
    ('settings.png', 'promo-card-4-settings.png', '设置',
     '连接、备份、改密码', '内外网自动选路，改完即时生效'),
]

CW, CH = 1080, 1920
CM = 96                                    # 左右留白
INK = (15, 31, 25)
INK_SOFT = (100, 118, 110)
GREEN_DEEP = (0, 108, 80)


def cfont(px: int, bold: bool = True):
    """竖版按目标像素直接取字号，不经过 1600 基准的换算"""
    for p in (BOLD if bold else REG):
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, px)
            except OSError:
                continue
    return ImageFont.load_default()


def card_phone(name, width, radius=46, bezel=8, blur=32, alpha=54):
    """截图 → 带窄边框和圆角的手机，附带柔和投影（含外扩留白）"""
    src = Image.open(os.path.join(SHOT_DIR, name)).convert('RGB')
    sw, sh = src.size
    src = src.crop((0, int(108 * sw / 1080), sw, sh))   # 去状态栏，理由同 paste_shot
    sw, sh = src.size
    h = int(width * sh / sw)
    body = src.resize((width, h), Image.LANCZOS).convert('RGBA')

    mask = Image.new('L', (width, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, width - 1, h - 1], radius, fill=255)
    body.putalpha(mask)

    fw, fh = width + bezel * 2, h + bezel * 2
    frame = Image.new('RGBA', (fw, fh), (0, 0, 0, 0))
    ImageDraw.Draw(frame).rounded_rectangle([0, 0, fw - 1, fh - 1],
                                            radius + bezel, fill=(13, 26, 22, 255))
    frame.paste(body, (bezel, bezel), body)

    pad = blur * 2
    canvas = Image.new('RGBA', (fw + pad * 2, fh + pad * 2), (0, 0, 0, 0))
    shade = Image.new('RGBA', canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(shade).rounded_rectangle(
        [pad, pad + 20, pad + fw, pad + fh + 20], radius + bezel, fill=(10, 40, 30, alpha))
    shade = shade.filter(ImageFilter.GaussianBlur(blur))
    canvas = Image.alpha_composite(canvas, shade)
    canvas.paste(frame, (pad, pad), frame)
    return canvas


def card(shot_name, out_name, tag, headline, sub):
    # glow 只吃同模式的图（内部是 Image.composite），所以先做光斑再转 RGBA
    canvas = gradient(CW, CH, (248, 252, 250), (224, 239, 233))
    canvas = glow(canvas, 130, 250, 900, 0.10, GREEN)
    canvas = glow(canvas, 980, 1560, 1000, 0.07, GREEN)
    canvas = canvas.convert('RGBA')
    d = ImageDraw.Draw(canvas)

    # 品牌行：绿点 + 名字（没有竖排 logo 素材，别硬拼一个假图标）
    d.ellipse([CM, 104, CM + 26, 130], fill=GREEN)
    d.text((CM + 42, 92), 'iStore Pilot', font=cfont(28), fill=INK)

    d.text((CM, 190), tag, font=cfont(30, False), fill=GREEN_DEEP)
    d.text((CM, 232), headline, font=cfont(74), fill=INK)
    d.text((CM, 358), sub, font=cfont(30, False), fill=INK_SOFT)

    ph = card_phone(shot_name, 570)
    canvas.alpha_composite(ph, ((CW - ph.width) // 2, 432))

    d.text((CM, 1852), 'iStoreOS 原生客户端', font=cfont(24, False), fill=INK_SOFT)
    tail = 'Android · iOS · HarmonyOS'
    d.text((CW - CM - d.textlength(tail, font=cfont(24, False)), 1852),
           tail, font=cfont(24, False), fill=INK_SOFT)

    out = os.path.join(OUT_DIR, out_name)
    canvas.convert('RGB').save(out, optimize=True)
    print(f'{out}  {CW}x{CH}')


def build_cards():
    missing = [c[0] for c in CARDS if not os.path.exists(os.path.join(SHOT_DIR, c[0]))]
    if missing:
        print('缺少截图:', missing)
        sys.exit(1)
    for args in CARDS:
        card(*args)


if __name__ == '__main__':
    if not os.path.exists(ICON_MASTER):
        print('缺少图标母版:', ICON_MASTER)
        sys.exit(1)
    need = {'overview.png', 'devices.png', 'proxy.png'} | {c[0] for c in CARDS}
    missing = sorted(n for n in need if not os.path.exists(os.path.join(SHOT_DIR, n)))
    if missing:
        print('缺少截图:', missing)
        sys.exit(1)
    modes = sys.argv[1:] or ['light', 'cards']
    if 'light' in modes:
        build('light', 'promo_light_4k.png')
    if 'dark' in modes:
        build('dark', 'promo_4k.png')
    if 'cards' in modes:
        build_cards()
