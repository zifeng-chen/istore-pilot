"""网络配置相关的公共助手（**只读**）。

这里只剩两件事：把 `uci show` 的段拍平成 {section_id: type}，以及判断
「这条连接是不是从内网来的」。`lanedit` 改 LAN 配置时用它们做前置判断。

2026-11 起**防火墙写入路径已全部下线**：`harden` / `unrestrict` 两个接口
在 server.py 里没有路由（返回 404），本文里的实现也一并删除。原因是收益
不确定、断网风险确定——`wan` 区 input 改成 REJECT 会连带挡掉外网回连、
IPv6 直连 NAS、以及挂在 zone input 上的 VPN 服务端，而用户日常在用域名 +
端口从外面管理路由器。要收紧防火墙，请到 LuCI → 网络 → 防火墙手动做，
那里改错了还能用 SSH 立刻回滚。

历史背景（留档）：这台机器 `firewall.@zone[1].input = ACCEPT`，而该 zone
覆盖 `wan` 和 `wan6`，WAN 是 PPPoE + CGNAT、IPv4 无公网地址，所以平时
看不出来；IPv6 是全局可达的，SSH / 8443 / LuCI 实际对整个公网敞开。
"""
from __future__ import annotations

import ipaddress
import re

from . import sysinfo


def _uci(*args: str, timeout: float = 8.0) -> str:
    return sysinfo._run(["uci", *args], timeout=timeout).strip()


def _now(key: str) -> str:
    out = sysinfo._run(["uci", "-q", "get", key], timeout=4).strip()
    return "" if out.startswith("uci:") else out


def sections(pkg: str) -> dict[str, str]:
    """把 `uci show` 拍平成 {section_id: type}。

    section_id 可能是 `@zone[1]` 也可能是具名段 `wan`——两种都要认，
    因为 LuCI 新建的段是具名的，而系统自带的匿名段是带下标的。
    """
    out: dict[str, str] = {}
    for line in _uci("show", pkg, timeout=6).splitlines():
        m = re.match(rf"^{pkg}\.(\S+)=(\S+)$", line.strip())
        if m:
            out[m.group(1)] = m.group(2)
    return out


def _is_ipv4(s: str) -> bool:
    try:
        ipaddress.IPv4Address(s)
        return True
    except ValueError:
        return False


def client_on_lan(client_ip: str) -> bool:
    """判断当前连接是不是从内网来的。

    用来在界面上区分「局域网内操作」和「外网远程操作」：改 LAN 网段这类
    动作在外网做等于当场把自己断掉，必须先劝回去。
    """
    if not client_ip or not _is_ipv4(client_ip):
        return False
    ip = _now("network.lan.ipaddr")
    mask = _now("network.lan.netmask") or "255.255.255.0"
    if not _is_ipv4(ip):
        return False
    try:
        net = ipaddress.ip_network(f"{ip}/{mask}", strict=False)
        return ipaddress.ip_address(client_ip) in net
    except ValueError:
        return False
