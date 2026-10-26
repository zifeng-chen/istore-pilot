#!/usr/bin/env python3
"""从路由器上的 GeoSite.dat 提取「域名 → 应用」库，落到 agent/data/app-domains.json.gz。

手写规则只能覆盖几百个域名，而 geosite 里有十几万条，且由社区长期维护。
路由器上本来就装了 v2ray-geosite（OpenClash 也在用），直接拿它当数据源，
不用联网、不用第三方依赖。

用法:
    ROUTER_PW=xxx python scripts/build_app_domains.py
"""
from __future__ import annotations

import gzip
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fetch_geodata as geo  # noqa: E402

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "..", "agent", "data", "app-domains.json.gz")

# geosite 分类 → (应用名, 分类)。后写的覆盖先写的，所以顺序是「粗 → 细」。
APP_MAP: list[tuple[str, str, str]] = [
    # ---- 大厂兜底，先铺最粗的一层
    ("ALIBABA", "阿里巴巴", "购物"),
    ("TENCENT", "腾讯", "综合"),
    ("BYTEDANCE", "字节跳动", "短视频"),
    ("NETEASE", "网易", "综合"),
    ("BAIDU", "百度", "综合"),
    ("HUAWEI", "华为", "综合"),
    ("XIAOMI", "小米", "综合"),
    ("JD", "京东", "购物"),
    ("GOOGLE", "谷歌", "综合"),
    ("MICROSOFT", "微软", "综合"),
    ("AMAZON", "亚马逊", "购物"),
    ("APPLE", "苹果", "系统服务"),
    ("META", "Meta", "社交"),
    ("SINA", "新浪", "资讯"),

    # ---- 细分到具体 App（覆盖上面的兜底）
    ("FQNOVEL", "番茄小说", "阅读视频"),
    ("QIMAO", "七猫小说", "阅读"),
    ("YUEWEN", "起点读书", "阅读"),
    ("CIWEIMAO", "刺猬猫", "阅读"),
    ("WENSHUSHU", "微信读书", "阅读"),
    ("DOUYIN", "抖音", "短视频"),
    ("TIKTOK", "TikTok", "短视频"),
    ("KUAISHOU", "快手", "短视频"),
    ("BYTEDANCE-AI-!CN", "豆包", "AI 对话"),
    ("DOUBAO", "豆包", "AI 对话"),
    ("IQIYI", "爱奇艺", "视频"),
    ("BILIBILI", "哔哩哔哩", "视频"),
    ("BILIBILI-CDN", "哔哩哔哩", "视频"),
    ("BILIBILI2", "哔哩哔哩", "视频"),
    ("BILIBILI-GAME", "哔哩哔哩", "游戏"),
    ("YOUKU", "优酷", "视频"),
    ("PPTV", "PPTV", "视频"),
    ("SOHU", "搜狐视频", "视频"),
    ("KU6", "酷6网", "视频"),
    ("CCTV", "央视影音", "视频"),
    ("HUNANTV", "芒果 TV", "视频"),
    ("WASU", "华数 TV", "视频"),
    ("BESTV", "百视通", "视频"),
    ("GITV", "银河奇异果", "视频"),
    ("KANZHONGGUO", "看看视频", "视频"),
    ("ACFUN", "AcFun", "视频"),
    ("YOUTUBE", "YouTube", "视频"),
    ("NETFLIX", "Netflix", "视频"),
    ("DISNEY", "Disney+", "视频"),
    ("DISNEYPLUS", "Disney+", "视频"),
    ("HBO", "HBO", "视频"),
    ("PRIMEVIDEO", "Prime Video", "视频"),
    ("APPLE-TVPLUS", "Apple TV+", "视频"),
    ("KUGOU", "酷狗音乐", "音乐"),
    ("KUWO", "酷我音乐", "音乐"),
    ("SPOTIFY", "Spotify", "音乐"),
    ("SOUNDCLOUD", "SoundCloud", "音乐"),
    ("DEEZER", "Deezer", "音乐"),
    ("TIDAL", "Tidal", "音乐"),
    ("XIMALAYA", "喜马拉雅", "音频"),
    ("QINGTINGFM", "蜻蜓 FM", "音频"),
    ("LIZHI", "荔枝 FM", "音频"),
    ("ZHIHU", "知乎", "社区"),
    ("DOUBAN", "豆瓣", "社区"),
    ("HUPU", "虎扑", "社区"),
    ("NGA", "NGA", "社区"),
    ("BAHAMUT", "巴哈姆特", "社区"),
    ("BANGUMI", "Bangumi", "社区"),
    ("XIAOHONGSHU", "小红书", "社交"),
    ("DINGTALK", "钉钉", "办公"),
    ("FEISHU", "飞书", "办公"),
    ("LARK", "飞书", "办公"),
    ("LARK-GLOBAL", "飞书", "办公"),
    ("SLACK", "Slack", "办公"),
    ("NOTION", "Notion", "办公"),
    ("TRELLO", "Trello", "办公"),
    ("ATLASSIAN", "Atlassian", "办公"),
    ("WPS", "WPS", "办公"),
    ("KINGSOFT", "金山", "办公"),
    ("MEITUAN", "美团", "生活"),
    ("ELEME", "饿了么", "生活"),
    ("DIDI", "滴滴出行", "出行"),
    ("CTRIP", "携程", "出行"),
    ("PINDUODUO", "拼多多", "购物"),
    ("SUNING", "苏宁", "购物"),
    ("DEWU", "得物", "购物"),
    ("SMZDM", "什么值得买", "购物"),
    ("DOUYU", "斗鱼", "直播"),
    ("HUYA", "虎牙", "直播"),
    ("TWITCH", "Twitch", "直播"),
    ("AMAP", "高德地图", "地图"),
    ("SOGOU", "搜狗", "综合"),
    ("QIHOO360", "360", "综合"),
    ("XUNLEI", "迅雷", "下载"),
    ("ALIYUN", "阿里云", "云服务"),
    ("ALIBABACLOUD", "阿里云", "云服务"),
    ("ALIYUN-DRIVE", "阿里云盘", "网盘"),
    ("QCLOUD", "腾讯云", "云服务"),
    ("TENDCLOUD", "腾讯云", "云服务"),
    ("HUAWEICLOUD", "华为云", "云服务"),
    ("AZURE", "Azure", "云服务"),
    ("AWS", "AWS", "云服务"),
    ("ICLOUD", "iCloud", "云服务"),
    ("ONEDRIVE", "OneDrive", "网盘"),
    ("XIAOMI-IOT", "米家", "智能家居"),
    ("XIAOMI-AI", "小爱同学", "AI 语音"),
    ("OPPO", "OPPO", "综合"),
    ("VIVO", "vivo", "综合"),
    ("HONOR", "荣耀", "综合"),
    ("MEIZU", "魅族", "综合"),
    ("ONEPLUS", "一加", "综合"),
    ("APPLE-CN", "苹果", "系统服务"),
    ("ICLOUDPRIVATERELAY", "iCloud 隐私中继", "系统服务"),
    ("ITUNES", "iTunes", "系统服务"),
    ("APPLE-UPDATE", "苹果系统更新", "系统更新"),
    ("GOOGLE-CN", "谷歌", "综合"),
    ("GOOGLE-PLAY", "Google Play", "应用商店"),
    ("GOOGLE-GEMINI", "Gemini", "AI 对话"),
    ("TELEGRAM", "Telegram", "社交"),
    ("WHATSAPP", "WhatsApp", "社交"),
    ("INSTAGRAM", "Instagram", "社交"),
    ("FACEBOOK", "Facebook", "社交"),
    ("TWITTER", "X", "社交"),
    ("REDDIT", "Reddit", "社区"),
    ("DISCORD", "Discord", "社交"),
    ("GITHUB", "GitHub", "代码托管"),
    ("GITLAB", "GitLab", "代码托管"),
    ("GITEE", "Gitee", "代码托管"),
    ("STEAM", "Steam", "游戏"),
    ("EPICGAMES", "Epic 游戏", "游戏"),
    ("EA", "EA", "游戏"),
    ("UBISOFT", "育碧", "游戏"),
    ("BLIZZARD", "暴雪", "游戏"),
    ("ROCKSTAR", "Rockstar", "游戏"),
    ("MOJANG", "我的世界", "游戏"),
    ("MIHOYO", "米哈游", "游戏"),
    ("MIHOYO-CN", "米哈游", "游戏"),
    ("HOYOVERSE", "米哈游", "游戏"),
    ("CYGAMES", "Cygames", "游戏"),
    ("KUROGAMES", "库洛游戏", "游戏"),
    ("NINTENDO", "任天堂", "游戏"),
    ("PLAYSTATION", "PlayStation", "游戏"),
    ("XBOX", "Xbox", "游戏"),
    ("TENCENT-GAMES", "腾讯游戏", "游戏"),
    ("OPENAI", "ChatGPT", "AI 对话"),
    ("ANTHROPIC", "Claude", "AI 对话"),
    ("PERPLEXITY", "Perplexity", "AI 对话"),
    ("DEEPSEEK", "DeepSeek", "AI 对话"),
    ("HUGGINGFACE", "Hugging Face", "AI 编程"),
    ("CURSOR", "Cursor", "AI 编程"),
    ("TRAE", "Trae", "AI 编程"),
    ("WINDSURF", "Windsurf", "AI 编程"),
    ("GITHUB-COPILOT", "GitHub Copilot", "AI 编程"),
    ("KEEP", "Keep", "运动"),
    ("YUANFUDAO", "猿辅导", "教育"),
    ("ZUOYEBANG", "作业帮", "教育"),
    ("XUEERSI", "学而思", "教育"),
    ("KOOLEARN", "猿题库", "教育"),
    ("CNKI", "知网", "教育"),
    ("XUEQIU", "雪球", "金融"),
    ("EASTMONEY", "东方财富", "金融"),
    ("FUTU", "富途牛牛", "金融"),
    ("51JOB", "前程无忧", "招聘"),
    ("LIEPIN", "猎聘", "招聘"),
    ("36KR", "36氪", "资讯"),
    ("CNBETA", "cnBeta", "资讯"),
    ("IFANR", "爱范儿", "资讯"),
    ("TEAMVIEWER", "TeamViewer", "远程控制"),
    ("ZOOM", "Zoom", "会议"),
    ("WEBEX", "Webex", "会议"),
    ("TAILSCALE", "Tailscale", "内网穿透"),
    ("SAKURAFRP", "SakuraFrp", "内网穿透"),
    ("NGROK", "ngrok", "内网穿透"),
    ("ADGUARD", "AdGuard", "网络工具"),
    ("V2RAY", "V2Ray", "代理工具"),
    ("CLOUDFLARE", "Cloudflare", "网络"),
    ("FASTLY", "Fastly", "CDN"),
    ("AKAMAI", "Akamai", "CDN"),
    ("QINIU", "七牛云", "CDN"),
    ("WANGSU", "网宿科技", "CDN"),
    ("BAISHANCLOUD", "白山云", "CDN"),
    ("SPACEX", "Starlink", "网络"),
    ("TESLA", "特斯拉", "车联网"),
    ("DJI", "大疆", "硬件"),
    ("SYNOLOGY", "群晖", "NAS"),
    ("QNAP", "威联通", "NAS"),
    ("MIKROTIK", "MikroTik", "网络设备"),
    ("UBIQUITI", "Ubiquiti", "网络设备"),
    ("HIKVISION", "海康威视", "安防"),
    ("TPLINK", "TP-LINK", "网络设备"),
    ("OPENWRT", "OpenWrt", "网络设备"),
    ("F-DROID", "F-Droid", "应用商店"),
    ("APKPURE", "APKPure", "应用商店"),

    # ---- 推送 / 统计：比普通应用优先，否则会被归到它所属的大厂
    ("UMENG", "友盟统计", "推送统计"),
    ("JIGUANG", "极光推送", "推送统计"),
    ("GETUI", "个推", "推送统计"),
    ("ADJUST", "Adjust 归因", "推送统计"),
    ("SEGMENT", "Segment 埋点", "推送统计"),
    ("FIREBASE", "Firebase", "推送统计"),
    ("GOOGLEFCM", "Google 推送", "推送统计"),

    # ---- 广告最后写，优先级最高：App 内嵌的广告 SDK 域名都落在这
    ("CATEGORY-ADS", "广告联盟", "广告"),
    ("CATEGORY-ADS-ALL", "广告联盟", "广告"),
]

# 太短或是公共后缀的域名不能进表，否则 example.com 全被误判
SKIP = {
    "com", "net", "org", "cn", "io", "co", "me", "tv", "cc", "xyz",
    "info", "biz", "top", "site", "online", "app", "dev", "cloud",
}
MIN_LEN = 5


def main() -> int:
    if not os.environ.get("ROUTER_PW"):
        print("缺少 ROUTER_PW", file=sys.stderr)
        return 2

    print("读取 GeoSite.dat ...")
    sites = geo.parse_geosite(geo.fetch("geosite"))
    print(f"  分类 {len(sites)} 个")

    table: dict[str, list[str]] = {}
    for code, name, kind in APP_MAP:
        doms = sites.get(code) or []
        added = 0
        for dtype, value in doms:
            # 正则类型没法当后缀匹配，跳过
            if dtype == 1:
                continue
            d = value.strip().lower().lstrip("*.").rstrip(".")
            if not d or d in SKIP or len(d) < MIN_LEN or "/" in d:
                continue
            table[d] = [name, kind]
            added += 1
        print(f"  {code:<22} → {name:<12} {kind:<6} {added:>6} 条")

    print(f"\n合计 {len(table)} 个域名")
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    raw = json.dumps(table, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    with gzip.open(OUT, "wb", compresslevel=9) as fh:
        fh.write(raw)
    size = os.path.getsize(OUT)
    print(f"写出 {OUT}")
    print(f"  {len(raw) / 1048576:.2f} MB → 压缩后 {size / 1048576:.2f} MB")

    # 抽查几个关键域名，确认提取没跑偏
    print("\n抽查:")
    for probe in ("qznovelvod.com", "fqnovel.com", "douyinvod.com", "v.qq.com",
                  "cache.video.iqiyi.com", "upos-sz-mirrorali.bilivideo.com",
                  "api.umeng.com", "v6-web-sdk.umengcloud.com"):
        parts = probe.split(".")
        hit = None
        for i in range(len(parts) - 1):
            hit = table.get(".".join(parts[i:]))
            if hit:
                break
        print(f"  {probe:<36} → {hit}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
