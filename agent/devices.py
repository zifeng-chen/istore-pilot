"""局域网设备发现与管理。

只读部分全部来自系统现成文件与命令，不引入任何第三方依赖：

    /tmp/dhcp.leases        DHCP 租约 → IP / MAC / 主机名 / 租期
    /tmp/hosts/dhcp.*       静态绑定与主机名
    ip -s neigh             邻居表 → 在线状态 + 最后活跃秒数
    /proc/net/nf_conntrack  连接跟踪 → 实时速率、累计流量、连接明细
    uci show dhcp           host 段 → 静态 IP 绑定
    uci show firewall       规则 → 上网开关

写入类操作会改动系统配置，因此都要求调用方传入确认串，并且改动前
保留原始状态，失败时回滚：

    改备注      只写 /etc/istore-agent/devices.json，不碰系统
    禁止上网    uci 增加 firewall rule（src_mac + dest wan → REJECT）
    静态绑定    uci 增加 dhcp host（mac + ip + name）
    网络唤醒    etherwake 发魔术包，纯发帧，不改配置

本机没有无线网卡，所以没有信号强度、协商速率这类字段；也没有 tc，
所以不做限速。这两点是设备能力决定的，不是没实现。
"""

from __future__ import annotations

import gzip
import ipaddress
import json
import os
import re
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor

STATE_DIR = os.environ.get("ISTORE_AGENT_STATE", "/etc/istore-agent")
DEVICES_JSON = os.path.join(STATE_DIR, "devices.json")
USAGE_JSON = os.path.join(STATE_DIR, "data", "devices-usage.json")
OUI_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "oui.txt.gz")

BLOCK_PREFIX = "istore-block-"
SAMPLE_SEC = 3.0

_lock = threading.Lock()
_state_cache: dict | None = None
_oui_cache: dict[str, str] | None = None
_sampler: threading.Thread | None = None
_sampler_stop = False

# mac -> {"rx": 累计字节, "tx": 累计字节, "rx_bps": 速率, "tx_bps": 速率, "ts": 采样时刻}
_acc: dict[str, dict] = {}
# 连接流 key -> (正向字节, 反向字节)
_flow_prev: dict[str, tuple[int, int]] = {}
_prev_sample_ts: float = 0.0

# 落盘的累计用量：内存里的 _acc 一重启就归零，用户问「这台设备一共用了多少」
# 必须跨重启算，所以另存一份。{"mac": {"rx":字节, "tx":字节, "day":日期, "drx":今日, "dtx":今日}}
_usage: dict[str, dict] = {}
_usage_dirty = False
_usage_last_save = 0.0
_ip_mac_cache: dict[str, str] = {}
_ip_mac_ts = 0.0

# 内网 MAC -> 最后一次看到它"自己往外发字节"的时刻。
# 邻居表的 STALE 不能当离线：iPhone 睡眠时不回 ARP，条目会一直挂在 STALE，
# 但它 WiFi 没断、APNs 长连接还在走流量。有出向流量就是铁证。
#
# 注意这里只认「内网设备发出去的字节增长」，不能认「连接跟踪里有这条流」：
# 设备断网后内核会把已建立的连接留在 LAST_ACK/ESTABLISHED 里，还会一直重传，
# 反向字节数照样在涨（实测 vivo 熄屏断 WiFi 后 19 条 LAST_ACK 仍在涨）。
# 那类残留条目会让一台已经拔网的设备永远显示在线。
_seen: dict[str, float] = {}
_seen_ts_cache: dict[str, float] = {}
ONLINE_GRACE = 150.0

# MAC -> 最后一次 ping 通的时刻。
# 邻居表 STALE 只说明"这条映射还没被验证过"，不等于离线：插座、灯、空调这类
# 设备可以几个小时不发一个包，光看流量会把它们判成关机的。对这类设备主动
# ping 一下，通了就是硬证据；ping 不通**不做反向结论**（设备可能屏蔽 ICMP，
# 而且 ping 本身也会顺手把邻居表刷回 REACHABLE）。
_alive: dict[str, float] = {}
_prober: threading.Thread | None = None
# 探活周期别调太短：ping 会把电池设备从休眠里推醒，离线设备每 30 秒被拍一下
# 没必要。60 秒一次足够快地把"其实还活着的静默设备"捞回来。
PROBE_SEC = 60.0
ALIVE_GRACE = 180.0



# ---------------------------------------------------------------- 基础工具


def _read(path: str, default: str = "") -> str:
    try:
        with open(path, "r", errors="replace") as fh:
            return fh.read()
    except OSError:
        return default


def _run(cmd: list[str], timeout: float = 6.0) -> tuple[int, str, str]:
    """返回 (退出码, stdout, stderr)。命令不存在时给 (127, "", 原因)。"""
    try:
        out = subprocess.run(cmd, capture_output=True, timeout=timeout, check=False)
        return (
            out.returncode,
            out.stdout.decode("utf-8", "replace"),
            out.stderr.decode("utf-8", "replace").strip(),
        )
    except FileNotFoundError:
        return 127, "", f"命令不存在: {cmd[0]}"
    except subprocess.TimeoutExpired:
        return 124, "", "超时"
    except OSError as exc:
        return 126, "", str(exc)


def _uci_show(config: str) -> dict[str, str]:
    """uci show 展平成 {section.option: value}。"""
    code, out, _ = _run(["uci", "show", config])
    if code != 0:
        return {}
    flat: dict[str, str] = {}
    for line in out.splitlines():
        if "=" not in line:
            continue
        key, _, val = line.partition("=")
        flat[key.strip()] = val.strip().strip("'")
    return flat


def _uci_sections(flat: dict[str, str], config: str) -> dict[str, dict[str, str]]:
    """按 section 归组。只切一次，避免把 section 和 option 揉在一起。"""
    out: dict[str, dict[str, str]] = {}
    prefix = config + "."
    for key, val in flat.items():
        if not key.startswith(prefix):
            continue
        rest = key[len(prefix):]
        if "." not in rest:
            out.setdefault(rest, {})["__type"] = val
            continue
        section, _, option = rest.partition(".")
        out.setdefault(section, {})[option] = val
    return out


# ---------------------------------------------------------------- 本地状态


def _state() -> dict:
    global _state_cache
    with _lock:
        if _state_cache is not None:
            return _state_cache
        data: dict = {}
        try:
            with open(DEVICES_JSON, "r", encoding="utf-8") as fh:
                loaded = json.load(fh)
            if isinstance(loaded, dict):
                data = loaded
        except (OSError, json.JSONDecodeError):
            pass
        _state_cache = data
        return data


def _state_save(data: dict) -> bool:
    global _state_cache
    with _lock:
        try:
            os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
        except OSError:
            pass
        try:
            tmp = DEVICES_JSON + ".tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(data, fh, ensure_ascii=False, indent=2)
            os.replace(tmp, DEVICES_JSON)
            os.chmod(DEVICES_JSON, 0o600)
        except OSError:
            return False
        _state_cache = data
        return True


def _meta(mac: str) -> dict:
    return _state().get(mac, {})


# ------------------------------------------------------- 累计用量（跨重启）

def _today() -> str:
    return time.strftime("%Y-%m-%d", time.localtime())


def _usage_load() -> None:
    global _usage
    try:
        with open(USAGE_JSON, "r", encoding="utf-8") as fh:
            raw = json.load(fh)
    except (OSError, ValueError):
        return
    items = raw.get("devices")
    if not isinstance(items, dict):
        return
    out: dict[str, dict] = {}
    for mac, val in items.items():
        if not isinstance(val, dict):
            continue
        out[str(mac).lower()] = {
            "rx": int(val.get("rx") or 0),
            "tx": int(val.get("tx") or 0),
            "day": str(val.get("day") or ""),
            "drx": int(val.get("drx") or 0),
            "dtx": int(val.get("dtx") or 0),
        }
    _usage = out


def _usage_save(force: bool = False) -> None:
    global _usage_dirty, _usage_last_save
    if not _usage_dirty and not force:
        return
    now = time.monotonic()
    if not force and now - _usage_last_save < 20.0:
        return
    _usage_last_save = now
    _usage_dirty = False
    with _lock:
        payload = {"ts": int(time.time()), "devices": dict(_usage)}
    try:
        os.makedirs(os.path.dirname(USAGE_JSON), exist_ok=True)
        tmp = USAGE_JSON + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False, separators=(",", ":"))
        os.replace(tmp, USAGE_JSON)
    except OSError:
        pass


def ip_mac_map() -> dict[str, str]:
    """地址 → MAC。应用流量要按设备归类，跨模块只暴露这一个查询。"""
    global _ip_mac_cache, _ip_mac_ts
    now = time.monotonic()
    if _ip_mac_cache and now - _ip_mac_ts < 10.0:
        return _ip_mac_cache
    try:
        mapping = _addr_mac_map()
    except Exception:
        mapping = {}
    if mapping:
        _ip_mac_cache = mapping
        _ip_mac_ts = now
    return _ip_mac_cache



# ---------------------------------------------------------------- 厂商识别

# 手工覆盖层：优先于 IEEE 大库，只为把虚拟机这类容易混淆的条目写清楚。
# 完整的 4 万条厂商库在 data/oui.txt.gz，首次用到时才加载。
_OUI = {
    "000C29": "VMware 虚拟机", "005056": "VMware 虚拟机", "001C14": "VMware 虚拟机",
    "080027": "VirtualBox 虚拟机", "525400": "QEMU 虚拟机", "00155D": "Hyper-V 虚拟机",
    "001C42": "Parallels 虚拟机",
}

# 常见服务端口，用于连接明细里给出人话说明
_PORT_HINT = {
    443: "HTTPS", 80: "HTTP", 53: "DNS", 22: "SSH", 23: "Telnet", 25: "SMTP",
    465: "SMTPS", 587: "SMTP", 110: "POP3", 143: "IMAP", 993: "IMAPS", 995: "POP3S",
    123: "NTP", 1900: "SSDP", 5353: "mDNS", 5355: "LLMNR", 137: "NetBIOS",
    139: "NetBIOS", 445: "SMB 文件共享", 548: "AFP 文件共享", 631: "打印",
    3389: "远程桌面", 5900: "VNC", 8080: "HTTP 代理", 8443: "HTTPS 备用",
    3478: "STUN", 3479: "STUN", 5228: "Google 推送", 5223: "Apple 推送",
    5222: "XMPP", 8883: "MQTT TLS", 1883: "MQTT", 5060: "SIP", 554: "RTSP 视频流",
    8009: "Chromecast", 7000: "AirPlay", 5000: "HTTP 备用", 9000: "HTTP 备用",
    32400: "Plex", 8096: "Jellyfin", 9091: "Transmission", 51413: "BT 下载",
    19132: "Minecraft", 27015: "游戏联机", 3074: "Xbox Live", 3478: "PSN",
    6881: "BT 下载", 16881: "BT 下载", 1194: "OpenVPN", 500: "IPSec",
    4500: "IPSec", 51820: "WireGuard", 8554: "RTSP", 1935: "RTMP 推流",
}


def _load_oui() -> dict[str, str]:
    """惰性加载 IEEE 厂商库。首次调用约几十毫秒，之后常驻内存。"""
    global _oui_cache
    if _oui_cache is not None:
        return _oui_cache
    table: dict[str, str] = {}
    try:
        with gzip.open(OUI_PATH, "rt", encoding="utf-8") as fh:
            for line in fh:
                key, sep, name = line.partition("\t")
                if sep and len(key.strip()) == 6:
                    table[key.strip()] = name.strip()
    except (OSError, EOFError):
        pass
    _oui_cache = table
    return table


def _vendor_raw(mac: str) -> str:
    """按 OUI 判断厂商（IEEE 原始名称，未做品牌翻译）。

    MAC 第二字符是 2/6/A/E 时属于本地管理地址，说明设备开了隐私地址
    （iOS/Android 的"随机 MAC"），此时厂商无从判断，直接说明原因。
    """
    clean = mac.replace(":", "").replace("-", "").upper()
    if len(clean) < 6:
        return ""
    if clean[1] in "26AE":
        return "随机 MAC"
    oui = clean[:6]
    if oui in _OUI:
        return _OUI[oui]
    return _load_oui().get(oui, "")


# ------------------------------------------------------- 品牌 / 型号 / 设备类型

# IEEE 厂商库里大量条目是英文公司名，直接显示对用户毫无意义
# （「Zhen Shi」是创米代工厂、「Gubei」其实是格力空调的模组供应商）。
# 这里做两层：先把常见公司名翻成品牌，再按主机名特征盖一层——
# 主机名是设备自己报的，比 OUI 里的公司名贴近真实用途。
_VENDOR_CN = {
    "apple": "苹果", "samsung": "三星", "xiaomi": "小米", "huawei": "华为",
    "zte": "中兴", "htc": "宏达", "sony": "索尼", "lg electronics": "LG",
    "intel": "英特尔", "realtek": "瑞昱", "broadcom": "博通", "qualcomm": "高通",
    "mediatek": "联发科", "espressif": "乐鑫", "murata": "村田", "azurewave": "海华",
    "hon hai": "富士康", "foxconn": "富士康", "liteon": "光宝", "asustek": "华硕",
    "micro-star": "微星", "giga-byte": "技嘉", "dell": "戴尔", "lenovo": "联想",
    "hp inc": "惠普", "hewlett": "惠普", "canon": "佳能", "epson": "爱普生",
    "tp-link": "普联", "tenda": "腾达", "mercury": "水星", "ruijie": "锐捷",
    "quectel": "移远通信", "fibocom": "广和通", "meig": "美格智能",
    "zhen shi": "创米", "imilab": "创米", "shiyuan": "视源",
    "gubei": "古北电子", "hui zhou gaoshengda": "高盛达",
    "sichuan ai-link": "爱联科技", "ztron": "中兴",
    "hisense": "海信", "skyworth": "创维", "changhong": "长虹", "tcl": "TCL",
    "haier": "海尔", "midea": "美的", "gree": "格力", "aux": "奥克斯",
    "panasonic": "松下", "philips": "飞利浦", "sharp": "夏普",
    "tuya": "涂鸦", "ezviz": "萤石", "hikvision": "海康威视", "dahua": "大华",
    "roborock": "石头科技", "ecovacs": "科沃斯", "dreame": "追觅",
    "raspberry pi": "树莓派", "synology": "群晖", "qnap": "威联通",
    "nintendo": "任天堂", "sony interactive": "索尼", "microsoft": "微软",
}

# 主机名特征 → (品牌, 类型, 型号)。**顺序即优先级**，先匹配到的赢。
# 型号留空表示用主机名清洗后的结果。
_HOST_RULES: list[tuple[tuple[str, ...], str, str, str]] = [
    # ---- 苹果：Mac 的主机名是「xxx-MacBook-Pro」这种，型号在后面
    (("macbook", "mac-book", "imac", "macmini", "mac-mini", "macstudio",
      "mac-studio", "macpro", "mac-pro"), "苹果", "电脑", ""),
    (("iphone",), "苹果", "手机", ""),
    (("ipad",), "苹果", "平板", ""),
    # ---- 手机 / 平板 / 电脑：主机名前缀就是型号
    (("pfem10", "find-x", "find x"), "OPPO", "手机", ""),
    (("hege-", "hbn-al", "mao-al", "mro-w", "nova-", "mate-"), "华为", "手机", ""),
    (("hn55dnt",), "海尔", "电视", ""),
    (("redmi",), "红米", "手机", ""),
    (("honor",), "荣耀", "手机", ""),
    (("iphone",), "苹果", "手机", "iPhone"),
    (("ipad",), "苹果", "平板", "iPad"),
    (("macbook", "imac", "mac-mini", "macmini"), "苹果", "电脑", ""),
    (("appletv",), "苹果", "电视盒子", "Apple TV"),
    (("homepod",), "苹果", "音箱", "HomePod"),
    # ---- 小米生态链：主机名里全是产品线缩写
    (("xiaoai", "soundbox", "miai"), "小米", "音箱", "小爱音箱"),
    (("yeelink-light", "yeelink-lamp"), "易来 Yeelight", "灯具", ""),
    (("yeelink-ven", "yeelink-fan"), "易来 Yeelight", "风扇", ""),
    (("chuangmi_camera", "chuangmi-camera", "chuangmi_ipc"), "创米", "摄像头", ""),
    (("chuangmi-plug", "chuangmi_plug"), "创米", "插座", ""),
    (("yunmi-waterpuri",), "云米", "净水器", ""),
    (("chunmi",), "纯米", "厨电", ""),
    (("dmaker-fan",), "德尔玛", "风扇", ""),
    (("dmaker-derh",), "德尔玛", "除湿机", ""),
    (("mmgg-feeder", "petfeeder"), "米家", "宠物用品", ""),
    (("careli-fryer", "fryer"), "米家", "厨电", ""),
    (("loock-cateye", "cateye"), "鹿客", "摄像头", "智能猫眼"),
    (("zimi-powerstrip",), "紫米", "插座", "插排"),
    (("lumi-acpartner", "lumi-ac"), "绿米 Aqara", "空调伴侣", ""),
    (("lumi-",), "绿米 Aqara", "传感器", ""),
    (("aqara",), "绿米 Aqara", "网关", ""),
    (("chazuo",), "米家", "插座", ""),
    (("xiaomi-gateway", "gateway-hub", "mijia-gateway"), "小米", "网关", ""),
    (("mijia", "miio", "miot"), "小米", "智能家居", ""),
    # ---- 家电
    (("gree", "yun-ji", "yunjia"), "格力", "空调", ""),
    (("midea",), "美的", "空调", ""),
    (("hisense",), "海信", "电视", ""),
    (("skyworth",), "创维", "电视", ""),
    (("tcl", "q9l-pro", "q10l"), "TCL", "电视", ""),
    # ---- 通用
    (("homeassistant",), "自建主机", "服务器", "Home Assistant"),
    (("ugreen", "绿联"), "绿联", "NAS", ""),
    (("synology", "群晖"), "群晖", "NAS", ""),
    (("qnap",), "威联通", "NAS", ""),
    (("zidoo", "极空间"), "极空间", "NAS", ""),
    (("router", "openwrt", "istoreos"), "路由器", "网络设备", ""),
    (("nas",), "NAS", "存储", ""),
]

# 主机名前缀 → 品牌（随机 MAC 的手机靠这个把「随机 MAC」写成真品牌）
_BRAND_PREFIX = (
    ("vivo", "vivo"), ("iqoo", "iQOO"), ("oppo", "OPPO"), ("oneplus", "一加"),
    ("realme", "realme"), ("redmi", "红米"), ("xiaomi", "小米"), ("mi-", "小米"),
    ("honor", "荣耀"), ("huawei", "华为"), ("samsung", "三星"), ("meizu", "魅族"),
    ("nokia", "诺基亚"), ("sony", "索尼"), ("pixel", "Google"),
)

_HASH_RE = re.compile(r"^[0-9a-f]{6,}$")


# 品牌 → 主机名里会重复出现的别名，剥型号时要一起丢掉，
# 否则「创米插座」的型号会显示成「chuangmi plug m3」
_BRAND_ALIAS = {
    "创米": ("chuangmi", "imi"), "易来 Yeelight": ("yeelink", "yeelight"),
    "绿米 Aqara": ("lumi", "aqara"), "小米": ("mi", "xiaomi", "mijia", "miot", "miio"),
    "格力": ("gree",), "美的": ("midea",), "华为": ("huawei",), "荣耀": ("honor",),
    "海尔": ("haier",), "TCL": ("tcl",), "海信": ("hisense",), "云米": ("yunmi",),
    "纯米": ("chunmi",), "德尔玛": ("dmaker",), "鹿客": ("loock",), "紫米": ("zimi",),
    "米家": ("mmgg", "mi"), "苹果": ("apple",), "OPPO": ("oppo",), "vivo": ("vivo",),
    "红米": ("redmi",), "视源": ("shiyuan",),
}


def _model(host: str, brand: str) -> str:
    """从主机名里剥出型号：vivo-X300-Ultra → X300 Ultra。"""
    if not host:
        return ""
    parts = [p for p in re.split(r"[-_\s]+", host) if p]
    alias = set(_BRAND_ALIAS.get(brand, ()))
    keep = []
    for p in parts:
        low = p.lower()
        if low.startswith(("mibt", "miap", "miio", "miot")):
            continue
        if _HASH_RE.match(low):          # MAC 尾巴或随机串
            continue
        if low in alias or (brand and low == brand.lower()):
            continue
        if low == "tv":                  # 类型里已经写了电视，型号里不用再带
            continue
        keep.append(p)
    # MAC 尾巴常被拆成 c5 / 72 / f5 这种两位十六进制，从末尾一路啃掉
    while keep and re.fullmatch(r"[0-9a-f]{1,2}", keep[-1].lower()):
        keep.pop()
    out = " ".join(keep)
    # 只剩一个「类型词」的不算型号：类型已经单独显示了
    if out.lower() in _MODEL_NOISE:
        return ""
    return "" if out.lower() == host.strip().lower() else out


# 这些词在主机名里只起描述作用（camera / plug / gateway），当型号显示没有意义
_MODEL_NOISE = {
    "camera", "plug", "light", "lamp", "lamp4", "sensor", "gateway", "hub",
    "hub1", "switch", "acpartner", "powerstrip", "feeder", "router", "tv",
}


def identify(mac: str, hostname: str) -> dict:
    """给出（品牌, 类型, 型号）。

    优先级：主机名特征 > OUI 翻译 > 主机名前缀 > 原始 OUI。
    这样「Zhen Shi」能显示成「创米 摄像头」，
    「随机 MAC」的 vivo 手机也不会只剩一句「随机 MAC」。
    """
    host = (hostname or "").strip()
    low = host.lower()
    raw = _vendor_raw(mac)

    brand = ""
    kind = ""
    model = ""

    for keys, b, k, m in _HOST_RULES:
        if any(key in low for key in keys):
            brand, kind = b, k
            model = m or _model(host, b)
            break

    if not brand:
        # OUI 命中就先用 OUI：这一步不依赖主机名，认得更稳
        translated = ""
        raw_low = raw.lower()
        for key, cn in _VENDOR_CN.items():
            if key in raw_low:
                translated = cn
                break
        if translated:
            brand = translated
        if not brand:
            for key, cn in _BRAND_PREFIX:
                if low.startswith(key) or ("-" + key) in low or ("_" + key) in low:
                    brand = cn
                    break
        if brand:
            model = _model(host, brand)

    # 「随机 MAC / 私有地址」不是品牌，是「查不到厂商」：这种情况下
    # 品牌留空，让上层用「私有地址」做说明，标题退回 IP —— 一排
    # 「随机 MAC」既分不清是谁，也没告诉你任何信息
    private = (raw == "随机 MAC" and not brand)
    if not brand:
        brand = "" if private else (raw or "未知")
    if not kind:
        kind = _guess_type(brand, low)
    return {"brand": brand, "type": kind, "model": model, "private": private}


_TYPE_BY_BRAND = {
    "苹果": "苹果设备", "小米": "智能家居", "华为": "华为设备", "荣耀": "手机",
    "OPPO": "手机", "vivo": "手机", "红米": "手机", "iQOO": "手机",
    "移远通信": "4G 模组", "英特尔": "电脑", "瑞昱": "电脑", "群晖": "存储",
    "威联通": "存储", "树莓派": "单板机", "中兴": "网络设备", "普联": "网络设备",
    "创米": "摄像头", "视源": "摄像头", "萤石": "摄像头", "海康威视": "摄像头",
    "涂鸦": "智能家居", "古北电子": "家电模组", "高盛达": "电视",
    "格力": "空调", "美的": "空调", "海尔": "家电", "TCL": "电视", "海信": "电视",
    "创维": "电视", "长虹": "电视", "易来 Yeelight": "灯具", "绿米 Aqara": "智能家居",
    "米家": "智能家居", "德尔玛": "小家电", "纯米": "厨电", "云米": "净水器",
    "鹿客": "门锁", "紫米": "插座", "奥克斯": "空调", "松下": "家电",
    "石头科技": "扫地机", "科沃斯": "扫地机", "追觅": "扫地机",
}


def _guess_type(brand: str, host: str) -> str:
    for key in ("phone", "iphone", "android", "mobile"):
        if key in host:
            return "手机"
    if "tv" in host:
        return "电视"
    if "camera" in host or "ipc" in host:
        return "摄像头"
    if "pad" in host or "tab" in host:
        return "平板"
    if "pc" in host or "desktop" in host or "laptop" in host:
        return "电脑"
    return _TYPE_BY_BRAND.get(brand, "其他")


_HEX_TAIL = re.compile(r"[0-9a-f]{8,}$|(-[0-9a-f]{2}){2,}$", re.IGNORECASE)

# 这些设备类型用型号当名字才有信息量（X300 Ultra、75Q9L Pro）
_MODEL_TYPES = {"手机", "平板", "电脑", "电视", "电视盒子", "NAS", "存储", "服务器"}


def _guess_access(mac: str, dev_type: str, hostname: str) -> dict:
    """推测「这台设备是插网线还是连 WiFi」。

    为什么只能"推测"
    -----------------
    软路由**看不到**这个事实。AP 是桥接模式，无线和有线都桥到同一根网线：
    `brctl showmacs br-lan` 里 50 多个 MAC 全部落在同一个 port，上游只看到
    "一个以太网帧从 port 1 进来"。真正的关联信息只存在 AP 的 802.11 表里。

    所以这里只给旁证，字段带 `source: "guess"`，界面必须标「推测」：
      1. 私有 MAC（第一字节 bit1）—— 手机/平板的「私有 Wi-Fi 地址」，
         有线几乎不会随机化 MAC，这条最硬
      2. 设备类型 —— 插座、灯具、空调这类根本没有网口，只能是无线
      3. 电脑/NAS/网络设备 —— 两种都可能，给个低置信度的"有线"
    接入方式在 UI 上是个**参考**，不能拿去当计费或限速的依据。
    """
    reason = ""
    try:
        first = int((mac or "00").split(":")[0], 16)
    except (ValueError, IndexError):
        first = 0
    if first & 0x02:
        return {"type": "wifi", "reason": "私有 MAC", "conf": "high", "source": "guess"}

    if dev_type in _WIFI_ONLY:
        # 这些设备压根没做网口，连上就只能是无线
        return {"type": "wifi", "reason": dev_type + "无网口", "conf": "high", "source": "guess"}
    if dev_type in _WIFI_LIKELY:
        return {"type": "wifi", "reason": dev_type + "通常无线", "conf": "medium", "source": "guess"}
    if dev_type in _WIRED_LIKELY:
        return {"type": "wired", "reason": dev_type + "通常有线", "conf": "low", "source": "guess"}
    host = (hostname or "").lower()
    if "tv" in host or "box" in host:
        return {"type": "unknown", "reason": "电视盒两种接法都常见", "conf": "low", "source": "guess"}
    return {"type": "unknown", "reason": "", "conf": "low", "source": "guess"}


#: 没有网口的品类：连上就只能是无线
_WIFI_ONLY = {"插座", "灯具", "空调", "厨电", "扫地机", "门锁", "净水器",
              "传感器", "智能家居", "家电", "小家电", "4G 模组"}
#: 通常无线，但存在有线版本
_WIFI_LIKELY = {"手机", "平板", "摄像头", "音箱", "苹果设备", "华为设备"}
#: 通常是插线的（置信度仍然低 —— 笔记本也是「电脑」）
_WIRED_LIKELY = {"电脑", "NAS", "存储", "服务器", "网络设备", "单板机", "打印机"}


def _display(host: str, who: dict) -> str:
    """给设备起一个能读的显示名。

    主机名五花八门：`gree-c5-65-28`、`HN55DNTA-b997fe5806f6bf39` 这种一看就是
    机器拼出来的，直接当标题没人看得懂；而 `homeassistant`、`我的Mac` 这类
    是用户自己起的名字，反而比"品牌+类型"有用。这里两者都照顾到。
    """
    brand = who.get("brand") or ""
    kind = who.get("type") or ""
    model = who.get("model") or ""
    name = (host or "").strip()
    if not name:
        return f"{brand} {kind}".strip() if kind and kind != "其他" else (brand or "未知设备")

    low = name.lower()
    alias = _BRAND_ALIAS.get(brand, ())
    tokens = [t for t in re.split(r"[-_\s]+", low) if t]
    machine = (any(a and a in low for a in alias)
               or bool(_HEX_TAIL.search(low))
               or any(t in _MODEL_NOISE for t in tokens))
    if not machine:
        return name

    # 只有手机 / 电脑 / 电视这类「型号本身就是卖点」的设备才用型号当标题；
    # 净水器、插座上的 waterpuri lx7 这种字符串对人没有意义，直接显示品牌+类型
    model_tokens = model.lower().split()
    usable = (bool(model)
              and kind in _MODEL_TYPES
              and not any(t in _MODEL_NOISE for t in model_tokens)
              and not any(t.isdigit() for t in model_tokens))
    if usable:
        return model
    return f"{brand} {kind}".strip() if kind and kind != "其他" else (brand or name)



def _vendor(mac: str) -> str:
    """兼容旧调用：只给品牌名。"""
    return identify(mac, "")["brand"]



# ---------------------------------------------------------------- 数据源


_NEIGH_RE = re.compile(
    r"^(?P<ip>\S+)\s+dev\s+(?P<dev>\S+)"
    r"(?:\s+lladdr\s+(?P<mac>[0-9a-fA-F:]{17}))?"
    r"(?:\s+ref\s+\d+)?"
    r"(?:\s+used\s+(?P<u1>\d+)/(?P<u2>\d+)/(?P<u3>\d+)\s*probes\s+(?P<p>\d+))?"
    r"\s+(?P<state>[A-Z]+)\s*$"
)

_ONLINE_STATES = {"REACHABLE", "DELAY", "PROBE"}


def _neigh() -> dict[str, dict]:
    """邻居表 → {mac: {ip, ipv4, ipv6, state, last_used, dev}}。只看 br-lan，跳过 docker 网桥。

    **一块网卡在内核里会有多条邻居记录**：IPv4 一条、全局 IPv6 一条、
    fe80 链路本地一条。早期实现是 `result[mac] = {...}` 直接覆盖，
    最后落进来的 fe80 把 IPv4 顶掉了 —— 后果是没有 DHCP 租约、只有静态 IP
    的设备（比如本机 Windows PC 192.168.100.243）在列表里 ip 为空，
    按 IP 搜不到、看着像"设备丢了"。
    现在按「IPv4 > 全局 IPv6 > fe80」的优先级合并，三条都留。
    """
    code, out, _ = _run(["ip", "-s", "neigh", "show"])
    if code != 0:
        out = _read("/proc/net/arp")

    acc: dict[str, dict] = {}
    for line in out.splitlines():
        m = _NEIGH_RE.match(line.strip())
        if not m:
            continue
        mac = (m.group("mac") or "").lower()
        dev = m.group("dev")
        if not mac or dev != "br-lan":
            continue
        ip = m.group("ip")
        entry = {
            "ip": ip,
            "state": m.group("state"),
            "last_used": int(m.group("u2")) if m.group("u2") else None,
        }
        rec = acc.setdefault(mac, {"v4": None, "v6": None, "v6ll": None, "dev": dev})
        if ":" not in ip:
            if rec["v4"] is None or _better(entry, rec["v4"]):
                rec["v4"] = entry
        elif ip.lower().startswith("fe80"):
            if rec["v6ll"] is None:
                rec["v6ll"] = entry
        else:
            if rec["v6"] is None or _better(entry, rec["v6"]):
                rec["v6"] = entry

    result: dict[str, dict] = {}
    for mac, rec in acc.items():
        main = rec["v4"] or rec["v6"] or rec["v6ll"]
        if main is None:
            continue
        result[mac] = {
            # ip 只用 IPv4/全局地址，fe80 不能当展示地址（ping 不通也没法看）
            "ip": main["ip"],
            "ipv4": rec["v4"]["ip"] if rec["v4"] else "",
            "ipv6": rec["v6"]["ip"] if rec["v6"] else "",
            "state": main["state"],
            "last_used": main["last_used"],
            "dev": rec["dev"],
        }
    return result


def _better(new: dict, old: dict) -> bool:
    """两条同族邻居记录里挑更可信的那条：已验证状态优先，其次最后活跃更近。"""
    n_ok = new["state"] in _ONLINE_STATES
    o_ok = old["state"] in _ONLINE_STATES
    if n_ok != o_ok:
        return n_ok
    nu, ou = new["last_used"], old["last_used"]
    if nu is None:
        return False
    if ou is None:
        return True
    return nu < ou


def _leases() -> dict[str, dict]:
    """DHCP 租约 → {mac: {ip, hostname, expires, lease_left}}。"""
    now = time.time()
    out: dict[str, dict] = {}
    for line in _read("/tmp/dhcp.leases").splitlines():
        parts = line.split()
        if len(parts) < 4:
            continue
        try:
            expires = int(parts[0])
        except ValueError:
            continue
        mac = parts[1].lower()
        host = parts[3] if parts[3] != "*" else ""
        out[mac] = {
            "ip": parts[2],
            "hostname": host,
            "expires": expires,
            "lease_left": max(0, expires - int(now)) if expires else None,
        }
    return out


def _hosts_file() -> dict[str, dict]:
    """dnsmasq 生成的 hosts 文件 → {ip: {hostname, mac}}。

    静态绑定会出现在这里，租约主机名也会，用来补 DNS 缓存之外的名字。
    """
    out: dict[str, dict] = {}
    base = "/tmp/hosts"
    try:
        names = os.listdir(base)
    except OSError:
        return out
    for name in names:
        if not name.startswith("dhcp"):
            continue
        for line in _read(os.path.join(base, name)).splitlines():
            parts = line.split()
            if len(parts) < 2 or parts[0].startswith("#"):
                continue
            ip, hostname = parts[0], parts[1]
            item = {"hostname": "" if hostname == "*" else hostname, "mac": ""}
            for token in parts[2:]:
                if token.startswith("mac="):
                    item["mac"] = token[4:].lower()
            out[ip] = item
    return out


def _dhcp_hosts() -> dict[str, dict]:
    """静态绑定 → {mac: {ip, name, section}}。"""
    flat = _uci_show("dhcp")
    out: dict[str, dict] = {}
    for section, opts in _uci_sections(flat, "dhcp").items():
        if opts.get("__type") != "host":
            continue
        macs = (opts.get("mac") or "").lower().split()
        ip = opts.get("ip", "")
        if not ip:
            continue
        for mac in macs:
            if mac:
                out[mac] = {"ip": ip, "name": opts.get("name", ""), "section": section}
    return out


def _blocked_map() -> dict[str, str]:
    """被禁止上网的设备 → {mac: firewall section}。以防火墙规则为唯一真源。"""
    flat = _uci_show("firewall")
    out: dict[str, str] = {}
    for section, opts in _uci_sections(flat, "firewall").items():
        name = opts.get("name", "")
        if not name.startswith(BLOCK_PREFIX):
            continue
        mac = name[len(BLOCK_PREFIX):].lower()
        if mac:
            out[mac] = section
    return out


_CT_RE = re.compile(
    r"src=(\S+)\s+dst=(\S+)"
    r"(?:\s+sport=(\d+))?"
    r"(?:\s+dport=(\d+))?"
    r"\s+packets=\d+\s+bytes=(\d+)"
)


def _conntrack() -> list[dict]:
    """解析连接跟踪表。每条流都带正向与反向两个方向的字节数。"""
    flows: list[dict] = []
    for line in _read("/proc/net/nf_conntrack").splitlines():
        if not line.strip():
            continue
        parts = line.split()
        if len(parts) < 4:
            continue
        proto = parts[2] if parts[0] in ("ipv4", "ipv6") else "?"
        pairs = _CT_RE.findall(line)
        if not pairs:
            continue
        fwd = pairs[0]
        rev = pairs[1] if len(pairs) > 1 else ("", "", "", "", "0")
        flows.append(
            {
                "proto": proto,
                "sip": fwd[0],
                "dip": fwd[1],
                "sport": int(fwd[2]) if fwd[2] else 0,
                "dport": int(fwd[3]) if fwd[3] else 0,
                "fwd_bytes": int(fwd[4]),
                "rsip": rev[0],
                "rdip": rev[1],
                "rsport": int(rev[2]) if rev[2] else 0,
                "rdport": int(rev[3]) if rev[3] else 0,
                "rev_bytes": int(rev[4]),
            }
        )
    return flows


# ---------------------------------------------------------------- 流量采样


def _is_private(ip: str) -> bool:
    if ip.startswith("10.") or ip.startswith("192.168."):
        return True
    if ip.startswith("172."):
        try:
            second = int(ip.split(".")[1])
        except (IndexError, ValueError):
            return False
        return 16 <= second <= 31
    return False


_LAN_NETS: list = []
_LAN_NETS_TS = 0.0
_LAN_NETS_TTL = 30.0


def _lan_networks() -> list:
    """br-lan 上的网段（IPv4 + IPv6 前缀），缓存 30 秒。

    判断「这个地址是不是内网设备」不能只看 10./172.16./192.168.：
    IPv6 下设备拿到的是运营商下发的全局地址（240e:…），字面上跟公网地址
    一模一样，唯一的依据是它落在 br-lan 的前缀里。
    早期版本只认 IPv4 私网，于是所有 IPv6 连接都被当成「公网↔公网」整段
    丢掉——表现就是设备上下行明显偏小、应用流量长期不动。
    """
    global _LAN_NETS, _LAN_NETS_TS
    now = time.monotonic()
    if _LAN_NETS and now - _LAN_NETS_TS < _LAN_NETS_TTL:
        return _LAN_NETS
    nets: list = []
    code, out, _ = _run(["ip", "-j", "addr", "show", "dev", "br-lan"])
    if code == 0 and out.strip():
        try:
            for item in json.loads(out):
                for info in item.get("addr_info") or []:
                    local = info.get("local") or ""
                    plen = info.get("prefixlen")
                    if not local or plen is None:
                        continue
                    try:
                        nets.append(ipaddress.ip_network(f"{local}/{plen}", strict=False))
                    except ValueError:
                        continue
        except (ValueError, TypeError):
            nets = []
    if nets:
        _LAN_NETS = nets
        _LAN_NETS_TS = now
        return _LAN_NETS
    if _LAN_NETS:
        return _LAN_NETS
    # 取不到接口信息（ip 命令缺 -j、容器里没有 br-lan）时退回经验网段，
    # 至少不会把整台机器算成公网
    return [ipaddress.ip_network("192.168.0.0/16"),
            ipaddress.ip_network("10.0.0.0/8"),
            ipaddress.ip_network("172.16.0.0/12")]


def _is_lan_addr(ip: str) -> bool:
    """地址是否属于内网侧（含 IPv6）。判断方向全靠它。"""
    if not ip:
        return False
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False
    for net in _lan_networks():
        if addr.version == net.version and addr in net:
            return True
    if addr.version == 4:
        return _is_private(ip)
    # 没有前缀信息时的兜底：ULA / 链路本地一定在内网
    return addr.is_private or addr.is_link_local


def _addr_mac_map() -> dict[str, str]:
    """内网地址 → MAC，IPv4 与全局 IPv6 都收。

    只收 IPv4 会让走 IPv6 的连接找不到归属设备，那部分流量在
    「设备详情 → 应用流量」里会彻底消失。
    """
    mapping: dict[str, str] = {}
    for mac, info in _neigh().items():
        for key in ("ipv4", "ipv6"):
            addr = info.get(key) or ""
            if addr:
                mapping[addr] = mac
        if info.get("ip"):
            mapping.setdefault(info["ip"], mac)
    for mac, info in _leases().items():
        if info.get("ip"):
            mapping.setdefault(info["ip"], mac)
    return mapping


def _sample_once() -> None:
    """采一次流量，按设备累加。用字节差值而不是瞬时值，避免连接断开的抖动。"""
    global _prev_sample_ts
    now = time.monotonic()
    first = _prev_sample_ts == 0.0
    dt = now - _prev_sample_ts if not first else 0.0
    _prev_sample_ts = now

    ip_mac = _addr_mac_map()

    flows = _conntrack()
    alive: set[str] = set()
    delta: dict[str, list[int]] = {}  # mac -> [rx_delta, tx_delta]
    seen_now: set[str] = set()  # 本轮真的往外发过字节的 MAC

    for flow in flows:
        key = "{sip}|{sport}|{dip}|{dport}|{proto}".format(**flow)
        alive.add(key)
        pair = (flow["fwd_bytes"], flow["rev_bytes"])
        prev = _flow_prev.get(key)
        if prev is None:
            # 首次见到这条流时字节数是从连接建立起累计的历史值，不能算成新增流量，
            # 否则刚部署完那一下会看到几十 MB/s 的假峰值
            d_fwd, d_rev = (0, 0) if first else (flow["fwd_bytes"], flow["rev_bytes"])
        else:
            d_fwd = max(0, flow["fwd_bytes"] - prev[0])
            d_rev = max(0, flow["rev_bytes"] - prev[1])
        _flow_prev[key] = pair

        sip, dip = flow["sip"], flow["dip"]
        # 分清"内网设备自己发出"和"发往内网设备"两个方向：
        # 只有前者增长才算设备活着。后者在设备离线后仍会被内核重传而持续增长，
        # 拿它当在线证据等于把断网的设备永久钉在在线状态。
        if _is_lan_addr(sip):
            inner, out_bytes, in_bytes = sip, d_fwd, d_rev
        elif _is_lan_addr(dip):
            inner, out_bytes, in_bytes = dip, d_rev, d_fwd
        else:
            continue
        mac = ip_mac.get(inner)
        if not mac:
            continue
        # 没换过 IP 也可能换了设备，所以活跃状态按 MAC 记而不是按 IP 记
        if out_bytes > 0:
            seen_now.add(mac)
        slot = delta.setdefault(mac, [0, 0])
        slot[0] += in_bytes   # 内网收到
        slot[1] += out_bytes  # 内网发出

    # 清掉已经消失的流，避免内存随会话无限增长
    for key in list(_flow_prev.keys()):
        if key not in alive:
            del _flow_prev[key]

    with _lock:
        day = _today()
        stamp = time.time()
        for mac in seen_now:
            _seen[mac] = stamp
        # 长时间不再出现的设备从字典里清掉，别让它无限长大
        if len(_seen) > 512:
            for mac, ts in list(_seen.items()):
                if stamp - ts > 3600:
                    del _seen[mac]
        for mac, (drx, dtx) in delta.items():
            acc = _acc.setdefault(mac, {"rx": 0, "tx": 0, "rx_bps": 0.0, "tx_bps": 0.0,
                                        "avg_bps": 0.0, "ts": 0.0})
            acc["rx"] += drx
            acc["tx"] += dtx
            if dt > 0.2:
                acc["rx_bps"] = drx / dt
                acc["tx_bps"] = dtx / dt
                acc["ts"] = now
                # 排序用滑动平均而不是瞬时值：3 秒一跳的数字会让列表
                # 每刷新一次就换个顺序，看着像在乱跳
                inst = (drx + dtx) / dt
                acc["avg_bps"] = acc["avg_bps"] * 0.6 + inst * 0.4
            # 跨重启的累计用量
            use = _usage.setdefault(mac, {"rx": 0, "tx": 0, "day": day, "drx": 0, "dtx": 0})
            if use.get("day") != day:
                use["day"] = day
                use["drx"] = 0
                use["dtx"] = 0
            use["rx"] += drx
            use["tx"] += dtx
            use["drx"] += drx
            use["dtx"] += dtx
        # 没流量的设备速率归零
        for mac, acc in _acc.items():
            if mac not in delta and now - acc["ts"] > SAMPLE_SEC * 2:
                acc["rx_bps"] = 0.0
                acc["tx_bps"] = 0.0
                acc["avg_bps"] = acc.get("avg_bps", 0.0) * 0.5
    if delta:
        globals()["_usage_dirty"] = True


def _loop() -> None:
    while not _sampler_stop:
        try:
            _sample_once()
            _usage_save()
        except Exception:  # 采样失败不能拖垮服务
            pass
        time.sleep(SAMPLE_SEC)


def _ping(ip: str) -> bool:
    return _run(["ping", "-c", "1", "-W", "1", ip], timeout=4)[0] == 0


def _probe_once() -> None:
    """对邻居表没验证过、也没有出向流量的设备主动 ping 一次。"""
    now = time.time()
    nb = _neigh()
    targets: list[tuple[str, str]] = []
    taken: set[str] = set()

    def offer(mac: str, ip: str) -> None:
        if mac in taken or not ip or ":" in ip:
            return  # 只探 IPv4：IPv6 隐私地址常换，探了也留不住
        if mac.startswith(("33:33", "01:00:5e", "ff:ff")):
            return  # 组播/广播地址不是设备
        if nb.get(mac, {}).get("state") in _ONLINE_STATES:
            return  # 邻居表已经验证过
        if mac in _seen and now - _seen[mac] <= ONLINE_GRACE:
            return  # 刚发过包，本来就判在线
        if mac in _alive and now - _alive[mac] <= PROBE_SEC * 0.5:
            return  # 这一轮刚探过，别连着拍
        taken.add(mac)
        targets.append((mac, ip))

    for mac, info in nb.items():
        offer(mac, info.get("ip") or "")
    for mac, info in _leases().items():
        offer(mac, info.get("ip") or "")
    for mac, info in _dhcp_hosts().items():
        offer(mac, info.get("ip") or "")

    if not targets:
        return
    # 并发探：单台超时 1 秒，串行的话几十台就要几十秒
    with ThreadPoolExecutor(max_workers=16) as pool:
        hits = list(pool.map(lambda t: (t[0], _ping(t[1])), targets))
    stamp = time.time()
    with _lock:
        for mac, ok in hits:
            if ok:
                _alive[mac] = stamp
        if len(_alive) > 256:
            for mac, ts in list(_alive.items()):
                if stamp - ts > ALIVE_GRACE * 8:
                    del _alive[mac]


def _probe_loop() -> None:
    time.sleep(4.0)  # 先让采样线程跑完第一轮，别一启动就一堆 ping
    while not _sampler_stop:
        try:
            _probe_once()
        except Exception:  # 探活失败不能拖垮服务
            pass
        time.sleep(PROBE_SEC)


def _ensure_sampler() -> None:
    global _sampler, _prober
    if _sampler is None:
        _usage_load()
        _sampler = threading.Thread(target=_loop, name="dev-sampler", daemon=True)
        _sampler.start()
    if _prober is None:
        _prober = threading.Thread(target=_probe_loop, name="dev-prober", daemon=True)
        _prober.start()


# ---------------------------------------------------------------- 设备列表


def _sort_key(ip: str) -> list:
    try:
        return [int(x) for x in ip.split(".")]
    except ValueError:
        return [999, 0, 0, 0]


def _build() -> list[dict]:
    """把各数据源合并成设备列表。租约、邻居表、静态绑定任一出现的设备都算。"""
    _ensure_sampler()

    # 接入设备表来自 AP（有线/无线只有它知道），后台线程刷新，这里只读缓存。
    # ap 这层是适配器：换了厂商、没配、口令错，都只会退回空表 → 按类型推断
    from . import ap as ap_mod

    ap_mod.ensure()
    ap_map = ap_mod.access_map()
    # 有节点没读到（比如 Mesh 从节点）时，主节点会把「经从节点接入」的无线
    # 设备也报成 eth1，这时候它说的「有线」不能当真
    ap_complete = not (ap_mod.status().get("errors") or {})

    neigh = _neigh()
    leases = _leases()
    hosts = _hosts_file()
    statics = _dhcp_hosts()
    blocked = _blocked_map()

    macs: set[str] = set(leases) | set(statics)
    for mac in neigh:
        if not mac.startswith(("33:33", "01:00:5e", "ff:ff")):
            macs.add(mac)

    devices: list[dict] = []
    now = time.time()

    for mac in macs:
        lease = leases.get(mac, {})
        static = statics.get(mac, {})
        nb = neigh.get(mac, {})
        meta = _meta(mac)

        # IP 优先取 IPv4：邻居表里给的常常是 fe80 链路本地地址，
        # 拿它当设备地址既不能 ping 也不能显示给人看
        ip = lease.get("ip") or static.get("ip") or ""
        # 没有 DHCP 租约、也没有静态绑定的设备（自己配了固定 IP 的电脑）
        # 只能靠邻居表认，这里必须取到 IPv4，否则整台设备在界面上没有地址
        if not ip:
            ip = nb.get("ipv4") or nb.get("ipv6") or ""
        hostname = lease.get("hostname") or static.get("name") or ""
        if not hostname and ip:
            hostname = hosts.get(ip, {}).get("hostname", "")

        state = nb.get("state", "")
        last_used = nb.get("last_used")
        # 判在线要三条证据里任意一条成立：
        # 1) 邻居表已验证（REACHABLE/DELAY/PROBE）
        # 2) 它自己还在往外发字节 —— iPhone 睡眠时不回 ARP、条目落进 STALE，
        #    但 WiFi 没断、APNs 长连接一直在跑，这是最硬的证据。
        #    只认"它发出去的字节"，不认"连接跟踪里有它的流"（见 _seen 的注释）
        # 3) 邻居表最近确认过 —— STALE 只是"待验证"，不等于不通
        # 邻居表已经明确解析失败（INCOMPLETE/FAILED）就是一票否决：
        # 连 ARP 都问不到，后面几条都只是历史残影
        # 4) 刚 ping 通过 —— 静默设备（插座/灯/空调）不发包也还活着
        seen_age = (now - _seen[mac]) if mac in _seen else 1e9
        probe_age = (now - _alive[mac]) if mac in _alive else 1e9
        dead = state in ("INCOMPLETE", "FAILED")
        online = not dead and (
            state in _ONLINE_STATES
            or seen_age <= ONLINE_GRACE
            or probe_age <= ALIVE_GRACE
            or (last_used is not None and last_used <= ONLINE_GRACE)
        )
        if online and state not in _ONLINE_STATES:
            # 邻居表没验证但确实在传数据，别把 STALE 直接甩给用户看
            state = "ACTIVE"
        if online:
            last_seen = 0
        elif last_used is not None:
            last_seen = last_used
        elif lease.get("expires"):
            last_seen = max(0, int(now - (lease["expires"] - 43200)))
        else:
            last_seen = None

        acc = _acc.get(mac, {})
        use = _usage.get(mac, {})
        alias = meta.get("alias", "")
        # 备注名是用户自己写的，识别品牌时也拿它当线索：
        # 有人把「绿联nas」当备注，而它 DHCP 主机名是空的，只看主机名会认成格力
        who = identify(mac, hostname or alias)
        # 接入方式只能推测（AP 桥接，无线/有线在上游长得一样），见 _guess_access
        access_guess = _guess_access(mac, who.get("type") or "", hostname)
        ap_row = ap_map.get(mac)
        if ap_row:
            kind = ap_row.get("type", "unknown")
            base = {
                "band": ap_row.get("band", ""),
                "reason": "AP 报表" + (" · " + ap_row["iface"] if ap_row.get("iface") else ""),
                "conf": "high",
                "source": "ap",
                "ap": ap_row.get("ap", ""),
            }
            if kind == "wired" and not ap_complete:
                # 主节点把「经从节点接入」的无线客户端也报成 eth1，
                # 从节点又读不到，这时它的「有线」不可信 —— 退回按设备类型推断
                if access_guess["type"] in ("wifi", "wired"):
                    access_guess = dict(base, type=access_guess["type"], band="",
                                        conf="medium", reason="从节点未读到，按设备类型推断")
                else:
                    access_guess = dict(base, type="unknown", conf="low",
                                        reason="从节点未读到，有线/无线无法确认")
            else:
                # AP 的表是事实：source=ap，界面不再写「推测」
                access_guess = dict(base, type=kind)
        devices.append(
            {
                "mac": mac,
                "ip": ip,
                # 同一台设备往往同时有 IPv4 和全局 IPv6：连接明细、域名归属
                # 都要按全部地址去匹配，只认主地址会漏掉走 IPv6 的那一半
                "ips": sorted({a for a in (ip, nb.get("ipv4"), nb.get("ipv6"),
                                           lease.get("ip"), static.get("ip")) if a}),
                "hostname": hostname,
                "alias": alias,
                "label": alias or _display(hostname, who) if (hostname or alias) else "",
                "vendor": who["brand"] or ("私有地址" if who.get("private") else "未知"),
                "model": who["model"],
                "type": who["type"],
                "access": access_guess,
                # OUI 原始名留着备查：品牌判断错了要能追到来源
                "vendor_raw": _vendor_raw(mac),
                "online": online,
                "state": state,
                "last_seen": last_seen,
                "static": bool(static),
                "blocked": mac in blocked,
                "dhcp": {
                    "reserved": bool(static),
                    "reserved_ip": static.get("ip", ""),
                    "lease_left": lease.get("lease_left"),
                },
                "net": {
                    "rx_bps": round(acc.get("rx_bps", 0.0), 1),
                    "tx_bps": round(acc.get("tx_bps", 0.0), 1),
                    "avg_bps": round(acc.get("avg_bps", 0.0), 1),
                    # 累计（跨重启）与今日，两个都给，界面按需显示
                    "rx_total": int(use.get("rx") or acc.get("rx", 0)),
                    "tx_total": int(use.get("tx") or acc.get("tx", 0)),
                    "rx_today": int(use.get("drx") or 0),
                    "tx_today": int(use.get("dtx") or 0),
                },
            }
        )

    def rank(d: dict):
        # 用户要的是「谁现在最占带宽」：按滑动平均速率降序。
        # 2 KB/s 以下当作空闲——否则某个设备几十字节的心跳包就能把它顶到第一位，
        # 看着像排序坏了。空闲设备退到按累计用量排，再按 IP 保证顺序稳定
        net = d["net"]
        busy = net["avg_bps"] if net["avg_bps"] >= 2048 else 0.0
        return (
            0 if d["online"] else 1,
            -busy,
            -(net["rx_total"] + net["tx_total"]),
            _sort_key(d["ip"] or "999.999.999.999"),
            d["mac"],
        )

    devices.sort(key=rank)
    return devices


def list_devices() -> dict:
    from . import ap as ap_mod

    items = _build()
    online = [d for d in items if d["online"]]
    ranked = sorted(online, key=lambda d: -d["net"]["avg_bps"])[:5]
    return {
        "devices": items,
        # 接入方式的数据源状态：没配 AP 时会带 disabled + 原因
        "ap": ap_mod.status(),
        "summary": {
            "total": len(items),
            "online": len(online),
            "blocked": sum(1 for d in items if d["blocked"]),
            "static": sum(1 for d in items if d["static"]),
            "rx_bps": round(sum(d["net"]["rx_bps"] for d in items), 1),
            "tx_bps": round(sum(d["net"]["tx_bps"] for d in items), 1),
            # 当前最活跃的几台，首页可以直接显示「谁在占带宽」
            "busy": [{"mac": d["mac"], "name": d["alias"] or d["hostname"] or d["vendor"],
                      "ip": d["ip"], "bps": d["net"]["avg_bps"]}
                     for d in ranked if d["net"]["avg_bps"] > 1024],
        },
    }


# ---------------------------------------------------------------- 设备详情


def _clean_chain(chains: list) -> str:
    """从代理链里挑出真正的出口节点。

    订阅里常把「剩余流量：xxx GB」「距离下次重置：x 天」这类信息伪装成节点，
    它们会出现在 chains 里，直接显示给用户毫无意义。
    """
    noise = ("剩余流量", "距离下次", "到期", "重置", "套餐", "官网", "客服", "订阅")
    for name in chains:
        if not isinstance(name, str) or not name:
            continue
        if "://" in name or any(word in name for word in noise):
            continue
        if name in ("GLOBAL", "DIRECT", "REJECT", "PASS"):
            continue
        return name
    return ""


def _domains_for(ips: set[str]) -> tuple[list[dict], str]:
    """查这台设备正在访问哪些域名。

    开了 OpenClash 之后 conntrack 里全是 198.18.x.x 这类 fake-ip，光看 IP
    等于什么都没说。Clash 的连接列表里带真实域名，按来源 IP 过滤就能还原。
    Passwall 没有运行时接口，这种情况下只能返回空并说明原因。

    ``ips`` 必须是设备的**全部**地址：只按 IPv4 过滤的话，走 IPv6 的那部分
    连接（国内 App 默认优先 IPv6）在域名列表里一条都不会出现。
    """
    from . import clash as clash_mod

    try:
        data = clash_mod.connections()
    except Exception:
        return [], "unavailable"
    if data.get("error"):
        return [], "unavailable"

    grouped: dict[str, dict] = {}
    for conn in data.get("connections") or []:
        if conn.get("source") not in ips:
            continue
        host = (conn.get("host") or "").strip()
        if not host:
            continue
        item = grouped.get(host)
        if item is None:
            item = {
                "host": host,
                "up": 0,
                "down": 0,
                "conns": 0,
                "rule": conn.get("rule") or "",
                "chain": _clean_chain(conn.get("chains") or []),
            }
            grouped[host] = item
        item["up"] += conn.get("upload", 0) or 0
        item["down"] += conn.get("download", 0) or 0
        item["conns"] += 1

    out = sorted(grouped.values(), key=lambda x: x["up"] + x["down"], reverse=True)
    return out[:15], "clash"


def detail(mac: str) -> dict:
    """单个设备的完整情况。连接明细来自当前连接跟踪。"""
    mac = (mac or "").lower().replace("-", ":")
    _ensure_sampler()

    target = None
    for dev in _build():
        if dev["mac"] == mac:
            target = dev
            break
    if target is None:
        return {"error": "没有这台设备", "mac": mac}

    ip = target["ip"]
    ips = {a for a in (target.get("ips") or []) if a}
    if ip:
        ips.add(ip)
    flows = [f for f in _conntrack() if f["sip"] in ips or f["dip"] in ips]

    peers = []
    for flow in flows:
        outbound = flow["sip"] in ips
        peer_ip = flow["dip"] if outbound else flow["sip"]
        peer_port = flow["dport"] if outbound else flow["sport"]
        hint = _PORT_HINT.get(peer_port, "")
        peers.append(
            {
                "ip": peer_ip,
                "port": peer_port,
                "proto": flow["proto"],
                "service": hint,
                "outbound": outbound,
                "up": flow["fwd_bytes"] if outbound else flow["rev_bytes"],
                "down": flow["rev_bytes"] if outbound else flow["fwd_bytes"],
            }
        )
    peers.sort(key=lambda p: p["up"] + p["down"], reverse=True)

    # 按对端聚合，去掉同一目标的重复行，只留前 12 条
    grouped: dict[tuple, dict] = {}
    for peer in peers:
        key = (peer["ip"], peer["port"], peer["proto"])
        if key in grouped:
            grouped[key]["up"] += peer["up"]
            grouped[key]["down"] += peer["down"]
            grouped[key]["conns"] += 1
        else:
            item = dict(peer)
            item["conns"] = 1
            grouped[key] = item
    top_peers = sorted(grouped.values(), key=lambda p: p["up"] + p["down"], reverse=True)[:12]

    domains, domains_source = _domains_for(ips) if ips else ([], "none")

    # 这台设备到底是谁在吃流量：按来源地址归过类的应用明细（累计）
    from . import apps as apps_mod

    used = apps_mod.by_device(mac)
    used_total = sum(a["total"] for a in used)
    for item in used:
        item["share"] = round(item["total"] / used_total * 100, 1) if used_total else 0.0

    meta = _meta(mac)
    net = target["net"]
    return {
        "device": target,
        "apps": used,
        "apps_note": "按域名特征归类，只统计经过代理的连接；路由器看不到内网设备的进程名",
        "note": meta.get("note", ""),
        "first_seen": meta.get("first_seen"),
        "conns": len(flows),
        "domains": domains,
        "domains_source": domains_source,
        "peers": top_peers,
        "usage": {
            "total": net["rx_total"] + net["tx_total"],
            "rx": net["rx_total"],
            "tx": net["tx_total"],
            "today": net["rx_today"] + net["tx_today"],
        },
        "capabilities": {
            "wol": True,
            "bandwidth_limit": False,
            "wifi_signal": False,
            "kick": False,
        },
        "limits": {
            "bandwidth_limit": "本机没有 tc 命令，限速不可用",
            "wifi_signal": "本机没有无线网卡，设备全为有线接入",
            "kick": "没有 conntrack 工具，无法强制断开已建立的连接；禁网只对新建连接立即生效",
            "domains": "域名来自 Clash 连接表；走直连的流量只能看到 IP",
        },
    }


# ---------------------------------------------------------------- 写入操作


def rename(mac: str, alias: str) -> dict:
    """设备备注名。只写本地状态文件，不动系统配置。"""
    mac = (mac or "").lower().replace("-", ":")
    if not re.fullmatch(r"[0-9a-f]{2}(:[0-9a-f]{2}){5}", mac):
        return {"ok": False, "error": "MAC 格式不对"}
    alias = (alias or "").strip()[:32]
    state = dict(_state())
    entry = dict(state.get(mac, {}))
    if alias:
        entry["alias"] = alias
    else:
        entry.pop("alias", None)
    entry.setdefault("first_seen", int(time.time()))
    state[mac] = entry
    if not _state_save(state):
        return {"ok": False, "error": "写入状态文件失败"}
    return {"ok": True, "mac": mac, "alias": alias}


def block(mac: str, enabled: bool) -> dict:
    """禁止 / 允许上网。

    实现方式是在防火墙里加一条 lan → wan 的 REJECT 规则，带 src_mac 匹配。
    这是 uci 正式配置项，重启后依然有效；缺点是 fw4 reload 要 1 秒左右，
    期间会有一次规则重建。
    """
    mac = (mac or "").lower().replace("-", ":")
    if not re.fullmatch(r"[0-9a-f]{2}(:[0-9a-f]{2}){5}", mac):
        return {"ok": False, "error": "MAC 格式不对"}

    existing = _blocked_map()
    section = existing.get(mac)
    name = BLOCK_PREFIX + mac

    if enabled:
        if section:
            return {"ok": True, "mac": mac, "blocked": True, "changed": False}
        code, out, err = _run(["uci", "add", "firewall", "rule"])
        if code != 0:
            return {"ok": False, "error": f"添加规则失败: {err or out}"}
        section = out.strip()
        steps = [
            ["uci", "set", f"firewall.{section}.name={name}"],
            ["uci", "set", f"firewall.{section}.src=lan"],
            ["uci", "set", f"firewall.{section}.src_mac={mac}"],
            ["uci", "set", f"firewall.{section}.dest=wan"],
            ["uci", "set", f"firewall.{section}.proto=all"],
            ["uci", "set", f"firewall.{section}.target=REJECT"],
            ["uci", "set", f"firewall.{section}.enabled=1"],
        ]
        for step in steps:
            code, _, err = _run(step)
            if code != 0:
                _run(["uci", "delete", f"firewall.{section}"])
                _run(["uci", "commit", "firewall"])
                return {"ok": False, "error": f"设置规则失败: {err}"}
        code, _, err = _run(["uci", "commit", "firewall"])
        if code != 0:
            return {"ok": False, "error": f"保存防火墙配置失败: {err}"}
    else:
        if not section:
            return {"ok": True, "mac": mac, "blocked": False, "changed": False}
        code, _, err = _run(["uci", "delete", f"firewall.{section}"])
        if code != 0:
            return {"ok": False, "error": f"删除规则失败: {err}"}
        code, _, err = _run(["uci", "commit", "firewall"])
        if code != 0:
            return {"ok": False, "error": f"保存防火墙配置失败: {err}"}

    # 让规则真正生效。fw4 reload 失败必须回滚，否则可能出现全家断网。
    code, out, err = _run(["fw4", "reload"], timeout=25)
    if code != 0:
        rollback = _rollback_block(mac, section, enabled)
        return {
            "ok": False,
            "error": f"重载防火墙失败，已回滚（{err or out or '无输出'}）",
            "rollback": rollback,
        }

    return {"ok": True, "mac": mac, "blocked": enabled, "changed": True}


def _rollback_block(mac: str, section: str, was_enabled: bool) -> str:
    """规则应用失败时恢复原状。"""
    if was_enabled:
        _run(["uci", "delete", f"firewall.{section}"])
    else:
        _run(["uci", "set", f"firewall.{section}.name={BLOCK_PREFIX + mac}"])
        _run(["uci", "set", f"firewall.{section}.src=lan"])
        _run(["uci", "set", f"firewall.{section}.src_mac={mac}"])
        _run(["uci", "set", f"firewall.{section}.dest=wan"])
        _run(["uci", "set", f"firewall.{section}.target=REJECT"])
    _run(["uci", "commit", "firewall"])
    code, _, _ = _run(["fw4", "reload"], timeout=25)
    return "已恢复" if code == 0 else "恢复时重载也失败了，需要手动检查 /etc/config/firewall"


def bind_static(mac: str, ip: str) -> dict:
    """把当前 IP 绑定成静态租约，避免重启后地址漂移。"""
    mac = (mac or "").lower().replace("-", ":")
    if not re.fullmatch(r"[0-9a-f]{2}(:[0-9a-f]{2}){5}", mac):
        return {"ok": False, "error": "MAC 格式不对"}

    existing = _dhcp_hosts().get(mac)
    if existing and existing.get("ip") == ip:
        return {"ok": True, "mac": mac, "ip": ip, "changed": False}
    if existing:
        return {"ok": False, "error": f"这台设备已绑定到 {existing['ip']}，请先解绑"}

    if not re.fullmatch(r"\d{1,3}(\.\d{1,3}){3}", ip or ""):
        return {"ok": False, "error": "IP 格式不对"}

    hostname = ""
    for dev in _build():
        if dev["mac"] == mac:
            hostname = dev["hostname"] or dev["alias"] or ""
            break

    code, out, err = _run(["uci", "add", "dhcp", "host"])
    if code != 0:
        return {"ok": False, "error": f"添加绑定失败: {err or out}"}
    section = out.strip()
    safe_name = re.sub(r"[^A-Za-z0-9_-]", "", hostname)[:20] or "device"
    for step in (
        ["uci", "set", f"dhcp.{section}.mac={mac}"],
        ["uci", "set", f"dhcp.{section}.ip={ip}"],
        ["uci", "set", f"dhcp.{section}.name={safe_name}"],
    ):
        code, _, err = _run(step)
        if code != 0:
            _run(["uci", "delete", f"dhcp.{section}"])
            _run(["uci", "commit", "dhcp"])
            return {"ok": False, "error": f"设置绑定失败: {err}"}

    code, _, err = _run(["uci", "commit", "dhcp"])
    if code != 0:
        return {"ok": False, "error": f"保存 DHCP 配置失败: {err}"}

    # 只重载 dnsmasq，不重启整个网络，已连接设备不会掉线
    code, out, err = _run(["/etc/init.d/dnsmasq", "reload"], timeout=20)
    warning = ""
    if code != 0:
        warning = f"配置已保存，但 dnsmasq 重载失败（{err or out}），下次重启后生效"
    return {"ok": True, "mac": mac, "ip": ip, "changed": True, "warning": warning}


def unbind_static(mac: str) -> dict:
    mac = (mac or "").lower().replace("-", ":")
    existing = _dhcp_hosts().get(mac)
    if not existing:
        return {"ok": True, "mac": mac, "changed": False}
    code, _, err = _run(["uci", "delete", f"dhcp.{existing['section']}"])
    if code != 0:
        return {"ok": False, "error": f"删除绑定失败: {err}"}
    code, _, err = _run(["uci", "commit", "dhcp"])
    if code != 0:
        return {"ok": False, "error": f"保存 DHCP 配置失败: {err}"}
    code, out, err = _run(["/etc/init.d/dnsmasq", "reload"], timeout=20)
    warning = "" if code == 0 else f"配置已保存，dnsmasq 重载失败（{err or out}）"
    return {"ok": True, "mac": mac, "changed": True, "warning": warning}


def wol(mac: str) -> dict:
    """发 WOL 魔术包。只发帧，不改任何配置。"""
    mac = (mac or "").lower().replace("-", ":")
    if not re.fullmatch(r"[0-9a-f]{2}(:[0-9a-f]{2}){5}", mac):
        return {"ok": False, "error": "MAC 格式不对"}

    for cmd in (["etherwake", "-i", "br-lan", mac], ["etherwake", mac]):
        code, out, err = _run(cmd, timeout=8)
        if code == 0:
            return {"ok": True, "mac": mac, "message": "魔术包已发出，设备需支持网络唤醒"}
        if code == 127:
            return {"ok": False, "error": "本机没有 etherwake，无法唤醒"}
        last = err or out
    return {"ok": False, "error": f"发送失败: {last}"}
