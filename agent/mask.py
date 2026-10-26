"""把「非本地 IP」脱敏。

为什么放在服务端：地址会出现在五处界面（概览、网络、宽带、设置、设备详情），
每端各写一遍过滤，迟早漏一处 —— 而漏的那一次，泄漏的是一张要发出去的截图。

规则：
- 本地地址保留原样（RFC1918 192.168/10/172.16、IPv6 ULA、回环、链路本地）。
  这些本来就不敏感，而且用户要靠它们认设备（192.168.100.243 是我的电脑）。
- 其余一律打码：公网 IPv4、CGNAT（100.64/10，本机 WAN 就是）、公网 IPv6。

打码只保留「能看出是哪一类地址」的信息：
- IPv4: 100.*.*.34   —— 保留首尾段，看不出完整地址
- IPv6: 240e:3a0:…   —— 保留前两段（运营商前缀），后面全省
- 带前缀长度的（240e:3a6:566b:1080::/64）保留 /64
"""
from __future__ import annotations

import ipaddress


def is_local(a: ipaddress._BaseAddress) -> bool:
    """这条地址是不是「说了也没关系」的本地地址。"""
    if a.is_loopback or a.is_link_local or a.is_unspecified or a.is_multicast:
        return True
    # is_private 在 3.11+ 覆盖 10/8、172.16/12、192.168/16 与 IPv6 ULA。
    # 但 100.64/10（CGNAT）在不同小版本上判定不一致，这里显式按「本地」排除它。
    if a.version == 4 and a in ipaddress.ip_network("100.64.0.0/10"):
        return False
    return a.is_private


def ip(text: str) -> str:
    """单条地址脱敏。认不出来就原样返回（可能是域名、空串、"—"）。"""
    if not text:
        return text
    raw = text.strip()
    addr, sep, plen = raw.partition("/")
    try:
        a = ipaddress.ip_address(addr)
    except ValueError:
        return text
    if is_local(a):
        return text

    suffix = ("/" + plen) if sep else ""
    if a.version == 4:
        p = addr.split(".")
        return f"{p[0]}.*.*.{p[3]}{suffix}"
    groups = [g for g in addr.split(":") if g]
    head = ":".join(groups[:2]) if len(groups) >= 2 else (groups[0] if groups else "")
    return f"{head}:…{suffix}"


def ips(items):
    """列表版本：给 dns 这类多值字段用。"""
    return [ip(x) for x in items] if isinstance(items, list) else items


def device(d: dict) -> dict:
    """设备记录里的 ip / ipv4 / ipv6 三个字段。就地改，返回同一个 dict。"""
    if not isinstance(d, dict):
        return d
    for key in ("ip", "ipv4", "ipv6"):
        if d.get(key):
            d[key] = ip(str(d[key]))
    return d


def devices(payload: dict) -> dict:
    """设备列表 / 详情响应的通用出口。

    只碰展示用的地址字段：`dhcp.reserved_ip` 这类「用户自己填的静态绑定」
    保持原样，否则列表里看到的是打码值，用户改绑定时会照着打码值去填。
    """
    if not isinstance(payload, dict):
        return payload
    for d in payload.get("devices") or []:
        device(d)
    dev = payload.get("device")
    if isinstance(dev, dict):
        device(dev)
    return payload
