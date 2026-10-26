"""IP → 归属（运营商标 / 云厂商 / 服务商）。

为什么需要
----------
Clash 里有一大半连接拿不到域名（客户端自己 DoH 解析后直连 IP、UDP、IPv6 字面量），
这些流量全塞进「IP 直连」一个桶，用户看不出所以然 —— 「这台手机 78 MB 去了哪」

用 Team Cymru 提供的公开 DNS 接口反查，两次 TXT 查询就能拿到 AS 号和注册名：
    41.237.167.119.origin.asn.cymru.com  TXT → "4837 | 119.164.0.0/14 | CN | apnic | ..."
    AS4837.asn.cymru.com                 TXT → "4837 | CN | apnic | ... | CHINA169-BACKBONE | China Unicom"
IPv6 用 nibble 反转形式查 origin6.asn.cymru.com。

为什么手写 DNS
--------------
路由器上只有 Python 标准库，没有 dnspython，也不该为一个 TXT 查询引入依赖。
TXT 报文很短（UDP 一次就够），手工拼包解析不到 80 行。

查询是同步的，所以只能放在后台线程里，绝不能进 3 秒的采样循环。
"""

from __future__ import annotations

import ipaddress
import queue
import random
import socket
import struct
import threading
import time

TIMEOUT = 1.5
CACHE_TTL = 3600.0
EMPTY_TTL = 600.0
MAX_PENDING = 512

# 国内 DNS 优先（Cymru 的域名国内解析没问题，但链路抖动时要能换一个重试）
SERVERS = ("223.5.5.5", "119.29.29.29", "8.8.8.8")

# AS 号 → 服务名。这张表比用 AS 注册名做关键词匹配准：
# 同一个云厂商往往有十几个 AS，注册名写法也不统一。
_ASN = {
    59930: "Telegram", 62041: "Telegram", 62014: "Telegram", 211157: "Telegram",
    45090: "腾讯云", 132203: "腾讯云", 4837: None,  # 4837 是联通骨干，交给名字判定
    45102: "阿里云", 37963: "阿里云", 24429: "阿里云",
    138699: "字节跳动", 396986: "字节跳动", 55990: "字节跳动",
    55967: "百度", 38365: "百度", 65545: "百度",
    45083: "华为云", 55990 + 1: None,
}

# AS 注册名关键词 → 显示名。按顺序匹配，先到先得。
_NAME_RULES: list[tuple[tuple[str, ...], str]] = [
    (("BYTEDANCE", "BYTE DANCE"), "字节跳动"),
    (("TENCENT",), "腾讯云"),
    (("ALIBABA",), "阿里云"),
    (("BAIDU",), "百度"),
    (("HUAWEI",), "华为云"),
    (("KUAISHOU",), "快手"),
    (("MEITUAN",), "美团"),
    (("TELEGRAM",), "Telegram"),
    (("GOOGLE",), "Google"),
    (("CLOUDFLARE",), "Cloudflare"),
    (("AMAZON",), "AWS"),
    (("MICROSOFT",), "Azure"),
    (("MICROSOFT", "AZURE"), "Azure"),
    (("CHINA169", "CNCGROUP", "UNICOM"), "中国联通"),
    (("CHINANET", "CHINA TELECOM", "CTCNET"), "中国电信"),
    (("CMNET", "CHINA MOBILE", "CMCC"), "中国移动"),
    (("CHINA EDU", "CERNET", "EDU.CN"), "教育网"),
    (("ALIBABA-CN", "ALICLOUD"), "阿里云"),
    (("WANGSU",), "网宿科技"),
    (("CHINACACHE",), "蓝汛 CDN"),
]

_cache: dict[str, tuple[str, float]] = {}
_pending: "queue.Queue[str]" = queue.Queue(maxsize=MAX_PENDING)
_inflight: set[str] = set()
_worker: threading.Thread | None = None


def _query_txt(name: str, server: str) -> list[str]:
    """手写 DNS TXT 查询。失败返回空列表，绝不抛异常。"""
    qid = random.randint(0, 0xFFFF)
    header = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0)
    qname = b"".join(bytes([len(p)]) + p.encode("ascii")
                     for p in name.split(".") if p) + b"\x00"
    pkt = header + qname + struct.pack(">HH", 16, 1)  # TXT / IN

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(TIMEOUT)
    try:
        sock.sendto(pkt, (server, 53))
        data, _ = sock.recvfrom(2048)
    except OSError:
        return []
    finally:
        sock.close()

    if len(data) < 12:
        return []
    ancount = struct.unpack(">H", data[6:8])[0]
    pos = 12
    try:
        while data[pos] != 0:          # 跳过 QNAME
            pos += data[pos] + 1
        pos += 5                        # 结尾 0 + qtype + qclass
        out: list[str] = []
        for _ in range(ancount):
            if data[pos] & 0xC0:        # 压缩指针
                pos += 2
            else:
                while data[pos] != 0:
                    pos += data[pos] + 1
                pos += 1
            rtype, _rclass, _ttl, rdlen = struct.unpack(">HHIH", data[pos:pos + 10])
            pos += 10
            rdata = data[pos:pos + rdlen]
            pos += rdlen
            if rtype != 16:
                continue
            i, parts = 0, []
            while i < len(rdata):
                ln = rdata[i]
                parts.append(rdata[i + 1:i + 1 + ln].decode("utf-8", "replace"))
                i += 1 + ln
            out.append("".join(parts))
        return out
    except (IndexError, struct.error):
        return []


def _ptr_name(ip: str) -> str:
    if ":" in ip:
        # IPv6 取完整 32 位半字节再反转
        try:
            packed = ipaddress.IPv6Address(ip).exploded.replace(":", "")
        except ValueError:
            return ""
        return ".".join(reversed(packed)) + ".origin6.asn.cymru.com"
    parts = ip.split(".")
    if len(parts) != 4:
        return ""
    return ".".join(reversed(parts)) + ".origin.asn.cymru.com"


def _first_txt(name: str) -> str:
    """按服务器顺序试，拿第一条 TXT。全失败返回空串。"""
    for server in SERVERS:
        got = _query_txt(name, server)
        if got:
            return got[0]
    return ""


def _name_of(asn: int) -> str:
    """AS 注册名 → 中文服务名。"""
    up = _first_txt(f"AS{asn}.asn.cymru.com").upper()
    if not up:
        return ""
    for keys, label in _NAME_RULES:
        if any(k in up for k in keys):
            return label
    return ""


def peek(ip: str) -> str:
    """只读缓存，绝不阻塞。没结果返回空串，调用方负责排进后台队列。"""
    hit = _cache.get(ip)
    if not hit:
        return ""
    label, ts = hit
    ttl = CACHE_TTL if label else EMPTY_TTL
    return label if time.time() - ts < ttl else ""


def lookup(ip: str) -> str:
    """IP → 归属名。查不到返回空串（调用方继续用「IP 直连」）。"""
    label = ""
    ptr = _ptr_name(ip)
    if ptr:
        head = _first_txt(ptr)
        asn_s = head.split("|")[0].strip() if head else ""
        if asn_s.isdigit():
            asn = int(asn_s)
            label = _ASN.get(asn) or _name_of(asn)

    now = time.time()
    _cache[ip] = (label, now)
    if len(_cache) > 4000:
        for k, v in list(_cache.items()):
            if now - v[1] > CACHE_TTL:
                del _cache[k]
    return label


def _loop() -> None:
    while True:
        ip = _pending.get()
        try:
            lookup(ip)
        except Exception:      # 反查失败不能拖垮线程
            _cache[ip] = ("", time.time())
        finally:
            _inflight.discard(ip)
            _pending.task_done()


def enqueue(ip: str) -> None:
    """把一个还没查过的 IP 丢进后台队列。绝不阻塞采样循环。"""
    global _worker
    if not ip or ip in _inflight:
        return
    if peek(ip):
        return
    hit = _cache.get(ip)
    if hit and time.time() - hit[1] < EMPTY_TTL:
        return
    if _worker is None:
        _worker = threading.Thread(target=_loop, name="asn-resolver", daemon=True)
        _worker.start()
    try:
        _pending.put_nowait(ip)
        _inflight.add(ip)
    except queue.Full:
        pass
