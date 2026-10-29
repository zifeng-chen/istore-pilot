"""从 App Store 抓官方应用图标，打包进 APK。

路由器只知道「哪个域名在跑」，拿不到手机里的安装包，所以图标只能离线带进 App。
这里按应用名去 iTunes 搜索接口取官方图标（中国区优先，境外应用走美区），
缩到 128px 存进 res/drawable-nodpi，再生成 util/AppIcons.java 里的名称映射。

用法（需要能出网，本机走 Clash 代理）：
    python scripts/fetch_app_icons.py [--proxy http://127.0.0.1:56977]
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.parse

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "android", "app", "src", "main", "res",
                   "drawable-nodpi")
JAVA_OUT = os.path.join(ROOT, "android", "app", "src", "main", "java",
                        "com", "chaof", "istoreos", "util", "AppIcons.java")

# (后端应用名, 搜索词, 区份, 资源名, 结果名必须包含的关键词)
ICONS = [
    # 品牌方/系统类：原来是拿「智慧生活」「腾讯视频」凑的，图标不对。
    # 华为 / 荣耀没有品牌 logo 的官方 App（App Store 上只有商城、运动健康
    # 这些子品牌），抓回来反而更不像，所以不做图标 —— 交给 AppIcon 用
    # 品牌色块 + 首字，比挂个「华为运动健康」的橙色心形强
    ("腾讯", "腾讯会议", "cn", "tencent", "腾讯"),
    ("X", "X", "us", "x", "X"),
    ("支付宝", "支付宝", "cn", "alipay", "支付宝"),
    ("番茄小说", "番茄小说", "cn", "fanqie", "番茄"),
    ("腾讯视频", "腾讯视频", "cn", "tencent_video", "腾讯视频"),
    ("爱奇艺", "爱奇艺", "cn", "iqiyi", "爱奇艺"),
    ("哔哩哔哩", "哔哩哔哩", "cn", "bilibili", "哔哩"),
    ("抖音", "抖音", "cn", "douyin", "抖音"),
    ("快手", "快手", "cn", "kuaishou", "快手"),
    ("优酷", "优酷视频", "cn", "youku", "优酷"),
    ("芒果 TV", "芒果TV", "cn", "mgtv", "芒果"),
    ("西瓜视频", "西瓜视频", "cn", "xigua", "西瓜"),
    ("搜狐视频", "搜狐视频", "cn", "sohu", "搜狐"),
    ("电视 / 直播", "央视频", "cn", "cctv", "央视"),
    ("YouTube", "YouTube", "us", "youtube", "YouTube"),
    ("Netflix", "Netflix", "us", "netflix", "Netflix"),
    ("Disney+", "Disney+", "us", "disney", "Disney"),
    ("Prime Video", "Prime Video", "us", "prime_video", "Prime"),
    ("微信", "微信", "cn", "wechat", "微信"),
    ("QQ / 邮箱", "QQ", "cn", "qq", "QQ"),
    ("微博", "微博", "cn", "weibo", "微博"),
    ("知乎", "知乎", "cn", "zhihu", "知乎"),
    ("小红书", "小红书", "cn", "xiaohongshu", "小红书"),
    ("豆瓣", "豆瓣", "cn", "douban", "豆瓣"),
    ("Telegram", "Telegram", "us", "telegram", "Telegram"),
    ("WhatsApp", "WhatsApp", "us", "whatsapp", "WhatsApp"),
    ("Discord", "Discord", "us", "discord", "Discord"),
    ("喜马拉雅", "喜马拉雅", "cn", "ximalaya", "喜马拉雅"),
    ("网易云音乐", "网易云音乐", "cn", "netease_music", "网易云"),
    ("QQ 音乐", "QQ音乐", "cn", "qqmusic", "QQ音乐"),
    ("酷狗 / 酷我", "酷狗音乐", "cn", "kugou", "酷狗"),
    ("咪咕", "咪咕视频", "cn", "migu", "咪咕"),
    ("Spotify", "Spotify", "us", "spotify", "Spotify"),
    ("起点 / 七猫", "七猫免费小说", "cn", "qimao", "七猫"),
    ("Steam", "Steam", "us", "steam", "Steam"),
    ("Epic", "Epic Games", "us", "epic", "Epic"),
    ("米哈游", "米游社", "cn", "mihoyo", "米游社"),
    ("ChatGPT", "ChatGPT", "us", "chatgpt", "ChatGPT"),
    ("Claude", "Claude", "us", "claude", "Claude"),
    ("DeepSeek", "DeepSeek", "cn", "deepseek", "DeepSeek"),
    ("GitHub", "GitHub", "us", "github", "GitHub"),
    ("淘宝 / 支付宝", "淘宝", "cn", "taobao", "淘宝"),
    ("京东", "京东", "cn", "jd", "京东"),
    ("拼多多", "拼多多", "cn", "pinduoduo", "拼多多"),
    ("美团", "美团", "cn", "meituan", "美团"),
    ("饿了么", "饿了么外卖", "cn", "eleme", "饿了么"),
    ("苏宁 / 唯品会", "唯品会", "cn", "vip", "唯品会"),
    ("携程", "携程旅行", "cn", "ctrip", "携程"),
    ("高德地图", "高德地图", "cn", "amap", "高德"),
    ("百度地图", "百度地图", "cn", "baidumap", "百度地图"),
    ("12306", "铁路12306", "cn", "rail12306", "12306"),
    ("滴滴", "滴滴出行", "cn", "didi", "滴滴"),
    ("小米 / 米家", "米家", "cn", "mijia", "米家"),
    ("华为 / 荣耀", "华为智慧生活", "cn", "hilink", "华为"),
    ("OPPO / 欢太", "OPPO商城", "cn", "oppo", "OPPO"),
    ("vivo 手机服务", "vivo", "cn", "vivo", "vivo"),
    ("美的", "美的美居", "cn", "midea", "美的"),
    ("海尔", "海尔智家", "cn", "haier", "海尔"),
    ("摄像头 / 涂鸦", "涂鸦智能", "cn", "tuya", "涂鸦"),
    ("扫地机", "石头扫地机器人", "cn", "roborock", "石头"),
    ("Apple 服务", "Apple Store", "us", "apple", "Apple"),
    ("微软服务", "Microsoft Outlook", "us", "microsoft", "Microsoft"),
    ("Google 服务", "Google", "us", "google", "Google"),
    ("百度", "百度", "cn", "baidu", "百度"),
    ("夸克 / UC", "夸克", "cn", "quark", "夸克"),
    ("网易", "网易新闻", "cn", "netease", "网易"),
    ("腾讯服务", "腾讯", "cn", "tencent", "腾讯"),
    ("开发仓库", "Docker", "us", "docker", "Docker"),
    ("远程控制", "向日葵远程控制", "cn", "oray", "向日葵"),
    ("主机 / 平台", "Xbox", "us", "xbox", "Xbox"),
    # ---- 裸 IP 反查出来的归属：运营商 / 云厂商 / 大厂
    ("阿里云", "阿里云", "cn", "aliyun", "阿里云"),
    ("腾讯云", "腾讯云", "cn", "tencent_cloud", "腾讯云"),
    ("华为云", "华为云", "cn", "huaweicloud", "华为云"),
    ("中国联通", "中国联通", "cn", "unicom", "联通"),
    ("中国电信", "中国电信", "cn", "ct", "电信"),
    ("中国移动", "中国移动", "cn", "cmcc", "移动"),
    ("字节跳动", "今日头条", "cn", "bytedance", "头条"),
]


def curl(url: str, proxy: str, binary: bool = False, tries: int = 3):
    args = ["curl", "-sL", "--max-time", "25", "--retry", "2"]
    if proxy:
        args += ["-x", proxy]
    args.append(url)
    for _ in range(tries):
        p = subprocess.run(args, capture_output=True)
        if p.returncode == 0 and p.stdout:
            return p.stdout if binary else p.stdout.decode("utf-8", "replace")
        time.sleep(1.2)
    return b"" if binary else ""


def lookup(term: str, country: str, want: str, proxy: str) -> str:
    url = ("https://itunes.apple.com/search?term=" + urllib.parse.quote(term)
           + f"&country={country}&entity=software&limit=8")
    raw = curl(url, proxy)
    if not raw:
        return ""
    try:
        data = json.loads(raw)
    except ValueError:
        return ""
    best = ""
    for item in data.get("results") or []:
        name = str(item.get("trackName") or "")
        art = str(item.get("artworkUrl100") or "")
        if not art:
            continue
        if want and want.lower() not in name.lower():
            continue
        return art
        # 第一个匹配上的就是最相关的（App Store 已按相关度排序）
    return best


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--proxy", default=os.environ.get("ICON_PROXY", "http://127.0.0.1:56977"))
    args = ap.parse_args()

    os.makedirs(RES, exist_ok=True)
    mapping: dict[str, str] = {}
    missing: list[str] = []

    for name, term, country, slug, want in ICONS:
        out = os.path.join(RES, f"ic_app_{slug}.png")
        if os.path.exists(out):
            # 断点续跑：已经下好的不重复请求，接口对同一批高频请求会限速
            mapping[name] = f"ic_app_{slug}"
            continue
        art = lookup(term, country, want, args.proxy)
        if not art:
            missing.append(f"{name}（搜索不到：{term}）")
            continue
        big = art.replace("100x100bb.jpg", "256x256bb.png")
        blob = curl(big, args.proxy, binary=True)
        if not blob:
            blob = curl(art, args.proxy, binary=True)
        if not blob:
            missing.append(f"{name}（图标下载失败）")
            continue
        tmp = os.path.join(RES, f".{slug}.raw")
        with open(tmp, "wb") as fh:
            fh.write(blob)
        try:
            img = Image.open(tmp).convert("RGBA")
        except Exception as exc:
            os.remove(tmp)
            missing.append(f"{name}（{exc}）")
            continue
        img = img.resize((144, 144), Image.LANCZOS)
        out = os.path.join(RES, f"ic_app_{slug}.png")
        img.save(out, "PNG", optimize=True)
        os.remove(tmp)
        mapping[name] = f"ic_app_{slug}"
        print(f"  ok  {name:<14} -> {slug:<14} {len(blob)//1024} KB")

    lines = ["package com.chaof.istoreos.util;", "",
             "import com.chaof.istoreos.R;", "",
             "import java.util.HashMap;", "import java.util.Map;", "",
             "/** 自动生成：scripts/fetch_app_icons.py。应用名 → 官方图标资源。 */",
             "public final class AppIcons {", "",
             "    private static final Map<String, Integer> MAP = new HashMap<>();", "",
             "    static {"]
    for name, slug in mapping.items():
        lines.append(f'        MAP.put("{name}", R.drawable.{slug});')
    lines += ["    }", "", "    private AppIcons() {", "    }", "",
              "    public static int res(String name) {",
              "        Integer id = name == null ? null : MAP.get(name);",
              "        return id == null ? 0 : id;", "    }", "}", ""]
    with open(JAVA_OUT, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines))

    print(f"\n成功 {len(mapping)} 个，映射写入 {JAVA_OUT}")
    if missing:
        print("未取到：")
        for m in missing:
            print("  -", m)
    return 0


if __name__ == "__main__":
    sys.exit(main())
