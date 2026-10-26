"""应用流量：把 Clash 的连接明细按「应用」聚合成排行。

为什么不用进程名
----------------
路由器站在转发路径上，流量来自内网设备，Mihomo 的 ``process`` / ``processPath``
对本机 redir 进来的转发流量恒为空（实测 uid 都是 0），拿不到对端机器里是谁在发包。
所以这里改用「域名特征」反推应用：``douyincdn`` 归抖音、``googlevideo`` 归 YouTube、
``mijia.tech`` 归米家……这对家庭场景足够准，也是用户真正想问的
「到底哪些应用在吃带宽」。

流量怎么算
----------
Clash 每条连接的 ``upload`` / ``download`` 是**连接生命周期内的累计值**，不是速率。
直接看它会以为流量一动不动，所以后台线程每 3 秒采一次，按连接 id 做字节差分：
  - 本轮增量 = 本轮累计 - 上轮累计
  - 新出现的连接：只有建立过基线之后才整笔计入
    （首轮必须只建基线，否则会把所有存活连接的历史字节算成一次暴涨）
  - 连接消失后不再出现，其增量自然停止，累计值仍留在 ``_acc`` 里

纯 IP 连接
----------
243 条连接里有 90 条拿不到域名（UDP 直连、IPv6 裸地址）。把它们统一收进
「IP 直连」一个桶，否则排行榜会被一堆 240e:xxxx 地址刷屏。
"""

from __future__ import annotations

import gzip
import json
import os
import re
import threading
import time

from . import asn, clash

POLL_SECONDS = 3.0
MAX_APPS = 60
IP_ONLY = "IP 直连"
LAN_ONLY = "局域网"

# geosite 提取出来的域名库（18 万条）。路由器上本来就有 v2ray-geosite，
# 由 scripts/build_app_domains.py 离线转成 {域名后缀: [应用名, 分类]}。
# 手写规则认不出来的域名在这里兜底，比继续往 _RULES 里堆关键字可靠得多。
GEO_JSON = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "data", "app-domains.json.gz")

# 用量账本：内存里只有「本次」（Agent 启动以来），要回答「今天用了多少」
# 「总共用了多少」必须落盘，否则重启就归零。目录跟 Agent 一起，
# 不能放 /tmp（重启即丢）。
DATA_DIR = "/etc/istore-agent/data"
STORE = os.path.join(DATA_DIR, "apps-usage.json")
KEEP_DAYS = 30
SAVE_EVERY = 15.0
MAX_TRACKED = 200

_IPV4_RE = re.compile(r"^\d{1,3}(\.\d{1,3}){3}$")
_IPV6_RE = re.compile(r"^[0-9a-fA-F:]+$")

# 域名特征 → (应用名, 分类)。**顺序即优先级**，越具体的写在越前面。
# 例：v.qq.com 必须排在 qq.com 之前，否则腾讯视频会被算成 QQ；
#     vivo 必须排在 heytap 之前，否则 vivo 手机会被算成 OPPO。
_RULES: list[tuple[tuple[str, ...], str, str]] = [
    # ------------------------------------------------ 广告 / 推送 / 遥测（必须最先判）
    # 这些域名的字面里常带别家的关键词（pangolin-sdk-toutiao 带 toutiao、
    # galileotelemetry.tencent 带 tencent），排在后面就会被算成抖音、腾讯，
    # 于是「被浪费的流量」永远显示不出来。
    (("ugdtimg", "gdtimg", "gdt.qq.com", "sigmob", "1rtb", "pangolin", "pangle",
      "mintegral", "applovin", "unityads", "inmobi", "adview", "admaster",
      "umtrack", "adservice", "doubleclick", "googlesyndication"), "广告联盟", "统计"),
    (("getui", "ge.push", "jpush", "umeng", "growingio", "sensorsdata", "mobtech",
      "mtalk.google", "fcm.googleapis", "gcm-http", "firebaseinstallations"),
     "应用推送", "推送"),
    (("google-analytics", "adlog", "clickmonitor", "telemetry", "xdcs-collector",
      "apmplus", "gator.volces", "log-api", "rmonitor", "mdt.qq.com", "eve.mdt"),
     "遥测 / 统计", "统计"),
    # ---------------------------------------------------------- 视频
    # 番茄小说：正文只有几十 KB，视频才是大头，域名特征全在 CDN 上
    (("fanqienovel", "fanqie", "fqnovel", "fqimg", "qznovel", "novelvod",
      "reading-video", "novelpic"), "番茄小说", "视频"),
    (("v.qq.com", "vv.video.qq", "video.qq.com", "tc.qq.com"), "腾讯视频", "视频"),
    (("iqiyi", "qiyipic", "71.am", "iqiyiimg"), "爱奇艺", "视频"),
    (("bilivideo", "biliapi", "hdslb", "bilibili"), "哔哩哔哩", "视频"),
    (("douyincdn", "douyin", "amemv", "snssdk", "bytedance", "pstatp", "toutiaoimg",
      "byteimg", "volces.com", "ibytedtos"), "抖音", "视频"),
    (("youku", "ykimg", "tudou"), "优酷", "视频"),
    (("mgtv", "hitv", "hunantv"), "芒果 TV", "视频"),
    (("ixigua", "xigua"), "西瓜视频", "视频"),
    (("kuaishou", "gifshow", "kwai"), "快手", "视频"),
    (("vrs.sohu", "sohu", "itc.cn"), "搜狐视频", "视频"),
    (("wasu", "cntv", "cibntv", "ott.cibntv", "tv.cctv"), "电视 / 直播", "视频"),
    (("googlevideo", "youtube", "ytimg", "ggpht"), "YouTube", "视频"),
    (("nflxvideo", "nflximg", "nflxso", "netflix"), "Netflix", "视频"),
    (("disneyplus", "dssott", "bamgrid"), "Disney+", "视频"),
    (("primevideo", "aiv-cdn"), "Prime Video", "视频"),
    (("plex",), "Plex", "局域网"),
    (("emby", "jellyfin"), "Emby / Jellyfin", "局域网"),
    (("ug.link", "ugreen"), "绿联 NAS", "局域网"),
    (("synology", "quickconnect"), "群晖 NAS", "局域网"),
    # ---------------------------------------------------------- 社交
    (("weixin", "wechat", "wx.qq.com", "mmbiz", "qpic", "qlogo", "wetype"), "微信", "社交"),
    (("telegram", "t.me", "telesco.pe"), "Telegram", "社交"),
    (("whatsapp", "wa.me"), "WhatsApp", "社交"),
    (("xiaohongshu", "xhscdn", "xhs."), "小红书", "社交"),
    (("weibo", "sinaimg", "wbimg"), "微博", "社交"),
    (("zhihu", "zhimg"), "知乎", "社交"),
    (("douban",), "豆瓣", "社交"),
    (("discord", "discordapp"), "Discord", "社交"),
    (("qzone", "qqmail", "exmail", "sginput"), "QQ / 邮箱", "社交"),
    # ---------------------------------------------------------- 音频 / 阅读
    (("ximalaya", "xmcdn", "tingmall"), "喜马拉雅", "音频"),
    (("music.163", "163music"), "网易云音乐", "音频"),
    (("qqmusic", "y.qq.com", "i.y.qq.com"), "QQ 音乐", "音频"),
    (("kugou", "kuwo"), "酷狗 / 酷我", "音频"),
    (("migu",), "咪咕", "音频"),
    (("spotify", "scdn.co"), "Spotify", "音频"),
    (("qidian", "zongheng", "qimao"), "起点 / 七猫", "阅读"),
    (("novelfm",), "阅读 / 小说", "阅读"),
    # ---------------------------------------------------------- 游戏
    (("steamcontent", "steamstatic", "steampowered", "steamcommunity"), "Steam", "游戏"),
    (("epicgames", "unrealengine"), "Epic", "游戏"),
    (("mihoyo", "hoyoverse", "yuanshen", "starrail"), "米哈游", "游戏"),
    (("battle.net", "blizzard", "blzstatic"), "暴雪", "游戏"),
    (("riotgames", "leagueoflegends"), "Riot", "游戏"),
    (("nintendo", "playstation", "xboxlive", "wegame"), "主机 / 平台", "游戏"),
    # ---------------------------------------------------------- AI / 开发
    (("openai", "chatgpt", "oaistatic", "oaiusercontent"), "ChatGPT", "AI"),
    (("anthropic", "claude.ai"), "Claude", "AI"),
    (("deepseek",), "DeepSeek", "AI"),
    (("gemini.google", "bard.google"), "Gemini", "AI"),
    (("codebuddy", "workbuddy"), "AI 编程助手", "AI"),
    (("github", "githubusercontent", "ghcr.io"), "GitHub", "开发"),
    (("npmjs", "pypi", "docker.io", "docker.com"), "开发仓库", "开发"),
    # ---------------------------------------------------------- 购物 / 出行
    (("alicdn", "taobao", "tmall", "alipay", "alibaba"), "淘宝 / 支付宝", "购物"),
    (("360buyimg", "jd.com", "jdpay", "jdcloud", "jdurl"), "京东", "购物"),
    (("pinduoduo", "yangkeduo", "pddpic"), "拼多多", "购物"),
    (("meituan", "dianping", "sankuai"), "美团", "购物"),
    (("ele.me", "elemecdn"), "饿了么", "购物"),
    (("suning", "vip.com"), "苏宁 / 唯品会", "购物"),
    (("ctrip", "trip.com", "qunar"), "携程", "出行"),
    (("amap", "autonavi", "dispatcher.is.autonavi"), "高德地图", "出行"),
    (("baidumap", "map.baidu"), "百度地图", "出行"),
    (("12306",), "12306", "出行"),
    (("didiglobal", "didichuxing"), "滴滴", "出行"),
    (("allawntech", "oray", "teamviewer", "向日葵"), "远程控制", "工具"),
    # ---------------------------------------------------------- 手机厂商 / 智能家居
    (("vivo.com", "iqoo"), "vivo 手机服务", "智能家居"),
    (("oppomobile", "coloros", "heytap"), "OPPO / 欢太", "智能家居"),
    (("mijia", "mi.com", "xiaomi", "miui", "miot"), "小米 / 米家", "智能家居"),
    (("dbankcloud", "dbankcdn", "hicloud", "huawei", "hihonor", "allawn"), "华为 / 荣耀", "智能家居"),
    (("midea",), "美的", "智能家居"),
    (("haier",), "海尔", "智能家居"),
    (("hisense", "tcl", "skyworth", "changhong"), "电视厂商", "智能家居"),
    (("tuya", "ezviz", "hikvision", "dahua", "imou"), "摄像头 / 涂鸦", "智能家居"),
    (("roborock", "dreame", "ecovacs"), "扫地机", "智能家居"),
    (("tplink", "tapo", "mercusys"), "路由器 / 插座", "智能家居"),
    (("ztehome", "zte.com"), "中兴", "智能家居"),
    (("bambulab",), "拓竹 3D 打印", "智能家居"),
    # ---------------------------------------------------------- 系统 / 云
    (("apple-cloudkit", "icloud", "mzstatic", "cdn-apple", "aaplimg", "apple.com",
      "push.apple.com", "courier", "ess.apple", "time.apple"), "Apple 服务", "系统"),
    (("windowsupdate", "msftncsi", "microsoft", "live.com", "office.net",
      "msedge", "wns.windows"), "微软服务", "系统"),
    (("gstatic", "googleapis", "google.com", "gvt1", "1e100.net"), "Google 服务", "系统"),
    (("cloudflare", "akamai", "fastly", "cloudfront", "smtcdns", "wscloudcdn",
      "cdntip", "qiniudns", "qcloudcdn"), "CDN 加速", "网络"),
    (("ntp.org", "time.nist", "pool.ntp"), "时间同步", "系统"),
    (("bdstatic", "baidu.com", "bdurl"), "百度", "搜索"),
    (("quark", "uc.cn", "ucweb"), "夸克 / UC", "搜索"),
    (("tencent.com", "myqcloud", "tencent-cloud", "gtimg"), "腾讯服务", "系统"),
    (("163.com", "126.net", "netease", "youdao"), "网易", "系统"),
]

# 应用名 → 分类。账本里只存流量不存分类，历史条目（尤其被 _canonical 重新
# 归类的）要靠这张表补回分类，否则界面上的图标只能拿到「其他」。
_NAME_CATEGORY = {name: cat for _, name, cat in _RULES}

_lock = threading.Lock()
_geo_cache: dict | None = None
_geo_tried = False
_prev: dict[str, tuple[float, float]] = {}
_acc: dict[str, dict] = {}
_rate: dict[str, tuple[float, float]] = {}
_last_ts = 0.0
_last_error = ""
_totals = {"up": 0.0, "down": 0.0}
_thread: threading.Thread | None = None

# 规则改名后，旧账本里的应用名要能落到新名字上，否则排行榜上会同时出现
# 「抖音 / 字节」和「抖音」两条，看着像重复统计
_LEGACY = {
    "抖音 / 字节": "抖音",
    "爱奇艺 / 腾讯视频": "腾讯视频",
    "地图导航": "高德地图",
    "音乐": "网易云音乐",
    "小米 / 米家": "小米 / 米家",
}

# 落盘的账本：total = 累计，days = 按天（YYYY-MM-DD）
_hist_total: dict[str, list[float]] = {}
_hist_days: dict[str, dict[str, list[float]]] = {}
_dirty = False
_last_save = 0.0



# --------------------------------------------------------------- 用量账本


def _today() -> str:
    return time.strftime("%Y-%m-%d", time.localtime())


def _canonical(name: str) -> str:
    """账本里的 key 可能是旧规则留下的主域名，按当前规则重新归类一次。

    规则改了以后（比如把 allawntech 扩成 allawn），历史数据也能并到新名字上，
    否则排行榜会出现「allawnfs.com」和「华为 / 荣耀」两条，看着像重复统计。
    """
    if name in (IP_ONLY, LAN_ONLY) or any(name == rule_name for _, rule_name, _ in _RULES):
        return name
    if name in _LEGACY:
        return _LEGACY[name]
    mapped, _ = _match(name)
    return mapped


def _merge_keys(mapping: dict[str, list[float]]) -> dict[str, list[float]]:
    out: dict[str, list[float]] = {}
    for key, val in mapping.items():
        name = _canonical(key)
        slot = out.setdefault(name, [0.0, 0.0])
        slot[0] += val[0]
        slot[1] += val[1]
    return out


def _load() -> None:
    """启动时读回账本。文件坏了就当作空账本，绝不因为读盘失败拖垮统计。"""
    global _hist_total, _hist_days
    try:
        with open(STORE, "r", encoding="utf-8") as fh:
            raw = json.load(fh)
    except (OSError, ValueError):
        return
    total = raw.get("total")
    days = raw.get("days")
    if isinstance(total, dict):
        _hist_total = _merge_keys(
            {k: [float(v[0]), float(v[1])] for k, v in total.items()
             if isinstance(v, list) and len(v) == 2})
    if isinstance(days, dict):
        _hist_days = {
            day: _merge_keys({k: [float(v[0]), float(v[1])] for k, v in names.items()
                              if isinstance(v, list) and len(v) == 2})
            for day, names in days.items() if isinstance(names, dict)
        }


def _save(force: bool = False) -> None:
    """原子写：先写 .tmp 再 rename，掉电也不会留下半个 json。"""
    global _dirty, _last_save
    if not _dirty and not force:
        return
    now = time.monotonic()
    if not force and now - _last_save < SAVE_EVERY:
        return
    _last_save = now
    _dirty = False

    with _lock:
        payload = {
            "ts": int(time.time()),
            "total": {k: [round(v[0], 1), round(v[1], 1)] for k, v in _hist_total.items()},
            "days": {
                day: {k: [round(v[0], 1), round(v[1], 1)] for k, v in names.items()}
                for day, names in _hist_days.items()
            },
        }
    try:
        os.makedirs(DATA_DIR, exist_ok=True)
        tmp = STORE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False, separators=(",", ":"))
        os.replace(tmp, STORE)
    except OSError:
        pass


def _trim() -> None:
    """控制文件体积：只留最近 KEEP_DAYS 天，每天只留流量最大的 MAX_TRACKED 个应用。"""
    global _hist_days, _hist_total
    cutoff = time.strftime("%Y-%m-%d", time.localtime(time.time() - KEEP_DAYS * 86400))
    _hist_days = {d: v for d, v in _hist_days.items() if d >= cutoff}
    for day, names in _hist_days.items():
        if len(names) > MAX_TRACKED:
            keep = sorted(names.items(), key=lambda kv: -(kv[1][0] + kv[1][1]))[:MAX_TRACKED]
            _hist_days[day] = dict(keep)
    if len(_hist_total) > MAX_TRACKED * 2:
        keep = sorted(_hist_total.items(), key=lambda kv: -(kv[1][0] + kv[1][1]))[:MAX_TRACKED]
        _hist_total = dict(keep)


def _mark_dirty() -> None:
    global _dirty
    _dirty = True


# ----------------------------------------------------------- 每台设备用了什么

# mac → {应用名: [上行, 下行]}。用户要能「点进设备看是哪个应用在用流量」，
# 全局排行回答不了这个问题，只能按来源地址再记一本。
DEV_STORE = os.path.join(DATA_DIR, "dev-apps.json")
MAX_DEV = 120
MAX_DEV_APPS = 24

_dev: dict[str, dict[str, list[float]]] = {}
_dev_dirty = False
_dev_last_save = 0.0
_ip_mac_cache: dict[str, str] = {}
_ip_mac_ts = 0.0


def _dev_load() -> None:
    global _dev
    try:
        with open(DEV_STORE, "r", encoding="utf-8") as fh:
            raw = json.load(fh)
    except (OSError, ValueError):
        return
    dev = raw.get("dev")
    if not isinstance(dev, dict):
        return
    out: dict[str, dict[str, list[float]]] = {}
    for mac, apps in dev.items():
        if not isinstance(apps, dict):
            continue
        names: dict[str, list[float]] = {}
        for name, val in apps.items():
            if isinstance(val, list) and len(val) == 2:
                names[_canonical(name)] = [float(val[0]), float(val[1])]
        if names:
            out[str(mac).lower()] = names
    _dev = out


def _dev_save(force: bool = False) -> None:
    global _dev_dirty, _dev_last_save
    if not _dev_dirty and not force:
        return
    now = time.monotonic()
    if not force and now - _dev_last_save < SAVE_EVERY:
        return
    _dev_last_save = now
    _dev_dirty = False
    with _lock:
        payload = {
            "ts": int(time.time()),
            "dev": {mac: {k: [round(v[0], 1), round(v[1], 1)] for k, v in apps.items()}
                    for mac, apps in _dev.items()},
        }
    try:
        os.makedirs(DATA_DIR, exist_ok=True)
        tmp = DEV_STORE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False, separators=(",", ":"))
        os.replace(tmp, DEV_STORE)
    except OSError:
        pass


def _ip_mac() -> dict[str, str]:
    """来源地址 → MAC。每 10 秒重建一次，够用且不额外增加采集开销。"""
    global _ip_mac_cache, _ip_mac_ts
    now = time.monotonic()
    if _ip_mac_cache and now - _ip_mac_ts < 10.0:
        return _ip_mac_cache
    try:
        from . import devices as dev_mod

        mapping = dev_mod.ip_mac_map()
    except Exception:
        mapping = {}
    if mapping:
        _ip_mac_cache = mapping
        _ip_mac_ts = now
    return _ip_mac_cache


def by_device(mac: str) -> list[dict]:
    """某台设备用过的应用与流量（累计），按用量降序。"""
    key = (mac or "").lower().replace("-", ":")
    apps = _dev.get(key) or {}
    out = []
    for name, (up, down) in apps.items():
        if up + down < 1024:      # 只有握手包的应用不值得占一行
            continue
        out.append({
            "name": name,
            "category": _NAME_CATEGORY.get(name, "其他"),
            "up": int(up),
            "down": int(down),
            "total": int(up + down),
        })
    out.sort(key=lambda x: -x["total"])
    return out[:MAX_DEV_APPS]



def _is_fake_ip(host: str) -> bool:
    return host.startswith(("198.18.", "198.19."))


def _is_ip(host: str) -> bool:
    if not host:
        return True
    if _IPV4_RE.match(host):
        return True
    return ":" in host and bool(_IPV6_RE.match(host))


def _is_lan(host: str) -> bool:
    """内网地址：DNS 查询、投屏、NAS 传输这些不是"上网"，不该进应用流量榜。

    之前 192.168.100.1:53 的 DNS 往返也被算进「IP 直连」，白占一栏流量。
    """
    if not host:
        return False
    if host.startswith(("192.168.", "10.", "127.", "169.254.")):
        return True
    if host.startswith("172."):
        try:
            return 16 <= int(host.split(".")[1]) <= 31
        except (IndexError, ValueError):
            return False
    if ":" in host:
        return host.startswith(("fe80", "fd", "fc", "::1"))
    return False


def _geo() -> dict:
    """懒加载域名库。第一次用到时才读，不装代理的人不用付这 1 MB 的启动开销。"""
    global _geo_cache, _geo_tried
    if _geo_cache is not None or _geo_tried:
        return _geo_cache or {}
    _geo_tried = True
    try:
        with gzip.open(GEO_JSON, "rt", encoding="utf-8") as fh:
            _geo_cache = json.load(fh)
    except (OSError, ValueError):
        _geo_cache = {}
    return _geo_cache


def _geo_lookup(host: str) -> tuple[str, str] | None:
    """从最具体的后缀往上剥，第一个命中的就是最贴切的那条记录。

    upos-hz-mirrorakam.akamaized.net → 先查全名，再查 akamaized.net，逐级上溯。
    """
    table = _geo()
    if not table:
        return None
    parts = host.split(".")
    for i in range(len(parts) - 1):
        hit = table.get(".".join(parts[i:]))
        if hit:
            return hit[0], hit[1]
    return None


def _match(host: str) -> tuple[str, str]:
    """域名 → (应用名, 分类)。认不出来就退化成主域名，归类「其他」。"""
    if _is_lan(host):
        return LAN_ONLY, "局域网"
    if _is_ip(host):
        # 裸 IP 没有域名可查，但能查出是谁的网段：Telegram 的 91.108.x、
        # 阿里云的 39.101.x 这类一眼就认出来。反查是异步的，第一轮先按
        # 「IP 直连」记，后台查完下一轮自然归到新桶里
        label = asn.peek(host)
        if label:
            return label, "网络"
        asn.enqueue(host)
        return IP_ONLY, "其他"
    low = host.lower()
    # 手写规则优先级最高：v.qq.com 要算腾讯视频而不是笼统的「腾讯」
    for keys, name, category in _RULES:
        for key in keys:
            if key in low:
                return name, category
    hit = _geo_lookup(low)
    if hit:
        # 账本只存流量不存分类，这里顺手把名字→分类补进表，
        # 否则设备详情页里从 geosite 认出来的应用分类全是「其他」
        _NAME_CATEGORY.setdefault(hit[0], hit[1])
        return hit
    # 退化成主域名：api.foo.example.com → example.com
    parts = [p for p in low.split(".") if p]
    if len(parts) >= 2:
        if len(parts) >= 3 and parts[-2] in {"com", "net", "org", "gov", "edu", "co"}:
            return ".".join(parts[-3:]), "其他"
        return ".".join(parts[-2:]), "其他"
    return host, "其他"


def _sample_once() -> None:
    global _prev, _acc, _last_ts, _last_error, _totals, _dev_dirty, _dev
    data = clash.connections()
    if data.get("error"):
        _last_error = str(data["error"])
        return
    _last_error = ""

    conns = data.get("connections") or []
    ip_mac = _ip_mac()
    now = time.monotonic()
    first = _last_ts <= 0.0
    dt = (now - _last_ts) if not first else 0.0

    cur: dict[str, tuple[float, float]] = {}
    step: dict[str, dict] = {}
    dev_step: dict[str, dict[str, list[float]]] = {}

    for c in conns:
        cid = str(c.get("id") or "")
        if not cid:
            continue
        up = float(c.get("upload") or 0)
        down = float(c.get("download") or 0)
        cur[cid] = (up, down)

        host = str(c.get("host") or "")
        if _is_fake_ip(host):
            host = ""
        name, category = _match(host)
        if name == LAN_ONLY:
            continue

        if first:
            d_up = d_down = 0.0
        else:
            prev = _prev.get(cid)
            if prev is None:
                # 基线之后新建立的连接：它的字节全部是这段时间产生的
                d_up, d_down = up, down
            else:
                d_up = max(0.0, up - prev[0])
                d_down = max(0.0, down - prev[1])

        slot = step.setdefault(name, {"up": 0.0, "down": 0.0, "conns": 0, "category": category})
        slot["up"] += d_up
        slot["down"] += d_down
        slot["conns"] += 1

        mac = ip_mac.get(str(c.get("source") or ""))
        if mac:
            bucket = dev_step.setdefault(mac, {}).setdefault(name, [0.0, 0.0])
            bucket[0] += d_up
            bucket[1] += d_down

    _prev = cur
    _last_ts = now

    if first:
        # 首轮只建基线：把所有存活连接的历史字节算成新流量会得到假峰值
        for name, slot in step.items():
            acc = _acc.setdefault(name, {"up": 0.0, "down": 0.0,
                                         "category": slot["category"], "conns": 0})
            acc["conns"] = int(slot["conns"])
        return

    day = _today()
    day_map = _hist_days.setdefault(day, {})
    for name, slot in step.items():
        acc = _acc.setdefault(name, {"up": 0.0, "down": 0.0,
                                     "category": slot["category"], "conns": 0})
        acc["up"] += slot["up"]
        acc["down"] += slot["down"]
        acc["conns"] = int(slot["conns"])
        _totals["up"] += slot["up"]
        _totals["down"] += slot["down"]

        # 账本：今天 + 累计，两条一起累加，口径永远一致
        t = _hist_total.setdefault(name, [0.0, 0.0])
        t[0] += slot["up"]
        t[1] += slot["down"]
        d = day_map.setdefault(name, [0.0, 0.0])
        d[0] += slot["up"]
        d[1] += slot["down"]
    if step:
        _mark_dirty()

    # 本轮没有连接的先归零速率，避免残留数字看起来还在跑
    for name in list(_rate.keys()):
        _rate[name] = (0.0, 0.0)
    if dt > 0.2:
        for name, slot in step.items():
            _rate[name] = (slot["up"] / dt, slot["down"] / dt)

    # 每台设备的应用明细：只增不减，重启后靠文件续上
    for mac, names in dev_step.items():
        entry = _dev.setdefault(mac, {})
        for name, val in names.items():
            slot = entry.setdefault(name, [0.0, 0.0])
            slot[0] += val[0]
            slot[1] += val[1]
        if len(entry) > MAX_DEV_APPS * 2:
            keep = sorted(entry.items(), key=lambda kv: -(kv[1][0] + kv[1][1]))[:MAX_DEV_APPS]
            _dev[mac] = dict(keep)
    if dev_step:
        _dev_dirty = True

    if len(_dev) > MAX_DEV:
        keep = sorted(_dev.items(),
                      key=lambda kv: -sum(v[0] + v[1] for v in kv[1].values()))[:MAX_DEV]
        _dev = dict(keep)

    # 控制内存：应用名会随着访问的域名无限增长
    if len(_acc) > 400:
        keep = sorted(_acc.items(), key=lambda kv: kv[1]["up"] + kv[1]["down"],
                      reverse=True)[:MAX_APPS * 2]
        _acc = dict(keep)


def _loop() -> None:
    global _last_error
    ticks = 0
    while True:
        try:
            with _lock:
                _sample_once()
            # 落盘放在锁外：_save 自己会拿锁，重入会死锁
            _save()
            _dev_save()
            ticks += 1
            if ticks % 600 == 0:      # 约半小时清一次，控制文件体积
                with _lock:
                    _trim()
        except Exception as exc:  # 后台线程不能因为一次异常就死掉
            _last_error = str(exc)
        time.sleep(POLL_SECONDS)


def _ensure() -> None:
    global _thread
    with _lock:
        if _thread is None:
            _load()
            _dev_load()
    if _thread is not None and _thread.is_alive():
        return
    _thread = threading.Thread(target=_loop, name="istore-apps", daemon=True)
    _thread.start()


def _domains_for(conns: list[dict]) -> dict[str, dict[str, int]]:
    """每个应用当前访问最多的域名，用来解释「这流量到底花在哪」。"""
    out: dict[str, dict[str, int]] = {}
    for c in conns:
        host = str(c.get("host") or "")
        if _is_fake_ip(host):
            host = ""
        if _is_ip(host):
            continue
        name, _ = _match(host)
        bucket = out.setdefault(name, {})
        bucket[host] = bucket.get(host, 0) + 1
    return out


def snapshot(period: str = "all") -> dict:
    """对外接口：应用流量排行（只给累计口径）。

    用户只关心「这个应用一共用了多少」，今日口径在界面上只会让人反复
    对比两套数字，所以接口不再返回 today 系列字段；``period`` 参数保留
    但被忽略，仅为兼容老版本客户端。
    """
    _ensure()
    with _lock:
        acc = {k: dict(v) for k, v in _acc.items()}
        rate = dict(_rate)
        error = _last_error
        started = _last_ts > 0
        totals = dict(_totals)
        overall = {k: list(v) for k, v in _hist_total.items()}
        days = len(_hist_days)

    data = clash.connections()
    live = data.get("connections") or []
    domains = _domains_for(live)

    # 以账本为基准并上「本次」：昨天用过、今天没跑的应用也要留在榜上，
    # 否则列表只能看到当下有连接的那几个，问「一共用了多少」答不出来
    names = set(acc) | set(overall)
    all_sum = {"up": int(sum(v[0] for v in overall.values())),
               "down": int(sum(v[1] for v in overall.values()))}
    grand = max(1, all_sum["up"] + all_sum["down"])

    apps = []
    for name in names:
        item = acc.get(name) or {}
        a = overall.get(name) or [0.0, 0.0]
        up_bps, down_bps = rate.get(name, (0.0, 0.0))
        top = sorted(domains.get(name, {}).items(), key=lambda kv: -kv[1])[:3]
        total = int(a[0] + a[1])
        apps.append(
            {
                "name": name,
                "category": item.get("category") or _NAME_CATEGORY.get(name, "其他"),
                "up": int(item.get("up", 0)),
                "down": int(item.get("down", 0)),
                "total": int(item.get("up", 0) + item.get("down", 0)),
                "up_bps": round(up_bps, 1),
                "down_bps": round(down_bps, 1),
                "conns": int(item.get("conns", 0)),
                "all_up": int(a[0]),
                "all_down": int(a[1]),
                "all_total": total,
                # 占全部应用流量的比例，前端直接画占比条，不用自己算
                "share": round(total / grand * 100, 1),
                "domains": [d for d, _ in top],
            }
        )

    # 排序以累计用量为准：用户问的是「用了多少」，不是此刻谁在跑。
    # 速率只在用量打平时做次级排序。「IP 直连」永远垫底
    # （它不是某个应用，只是认不出域名的那些连接，不该抢占榜首）
    apps.sort(key=lambda x: (x["name"] == IP_ONLY, -x["all_total"],
                             -(x["down_bps"] + x["up_bps"])))
    idle = [a for a in apps if a["conns"] == 0]

    return {
        "ts": int(time.time()),
        "ready": started,
        "date": _today(),
        "days": days,
        "period": "all",
        # 不按「有没有在跑」拆表：用过、此刻闲着的应用同样要出现在用量榜上
        "apps": apps[:MAX_APPS],
        "idle": idle[:MAX_APPS],
        "session": {"up": int(totals["up"]), "down": int(totals["down"])},
        "all": all_sum,
        "clash": {
            "up": int(data.get("upload_total") or 0),
            "down": int(data.get("download_total") or 0),
            "connections": len(live),
        },
        "error": error or None,
        "note": "按域名特征归类；未经代理的直连流量不计入；累计用量已落盘，重启不清零",
    }
