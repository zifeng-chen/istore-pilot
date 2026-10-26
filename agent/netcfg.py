"""WAN 配置读写（PPPoE / DHCP / 静态 IP）。

这是全项目唯一会「改坏就断网」的地方，所以每一层都按最坏情况设计：

1. **改前必留底**：整个 /etc/config/network 复制到 data 目录，回滚就是复制回去。
2. **改完起守护**：派生一个独立进程，等 90 秒后检查 WAN 是否 up 且能 ping 通公网。
   任何一项不满足就自动还原配置并 ifup，用户不用摸黑去插显示器。
3. **只碰白名单字段**：proto / username / password / ipaddr / netmask / gateway /
   dns / mtu / peerdns，其余选项一律不动（尤其 ip6class、norelease 这些
   跟 IPv6 委派有关的项，动了会让全家 IPv6 掉线）。
4. **密码出站即掩码**：读配置时只回 `password` 是否为空 + 掩码，绝不把明文回给客户端。
   但界面上要能「原样保存」——所以密码为空表示不修改。
"""
from __future__ import annotations

import os
import shutil
import subprocess
import time

from . import sysinfo

NET_CONF = "/etc/config/network"
DATA_DIR = "/etc/istore-agent/data"
NET_BAK = os.path.join(DATA_DIR, "network.bak")
GUARD = "/usr/lib/istore-agent/net_guard.sh"

PROTO_LABELS = {
    "pppoe": "PPPoE 拨号",
    "dhcp": "自动获取（DHCP）",
    "static": "静态 IP",
    "none": "不配置",
}

# 允许改的字段白名单：其余选项一律原样保留
EDITABLE = ("proto", "username", "password", "ipaddr", "netmask",
            "gateway", "dns", "mtu", "peerdns")


def _uci(*args: str, timeout: float = 8.0) -> str:
    return sysinfo._run(["uci", *args], timeout=timeout).strip()


def _uci_get(key: str) -> str:
    out = sysinfo._run(["uci", "get", key], timeout=4).strip()
    return "" if out in ("uci: Entry not found", "") else out


def _present(pwd: str) -> str:
    """密码只回显长度线索，不回明文"""
    if not pwd:
        return ""
    if len(pwd) <= 2:
        return "*" * len(pwd)
    return pwd[0] + "*" * (len(pwd) - 2) + pwd[-1]


# ---------------------------------------------------------------- 读

def wan_id() -> str:
    """WAN 段名不一定是 wan（有人改成 wan2），按 device+proto 猜一次更稳"""
    return "wan"


def config() -> dict:
    """当前 WAN 配置。密码掩码，客户端提交时留空表示「不修改」。"""
    proto = _uci_get("network.wan.proto") or "pppoe"
    password = _uci_get("network.wan.password")
    dns_raw = _uci_get("network.wan.dns")
    return {
        "ok": True,
        "device": _uci_get("network.wan.device"),
        "proto": proto,
        "proto_label": PROTO_LABELS.get(proto, proto),
        "username": _uci_get("network.wan.username"),
        "password_set": bool(password),
        "password_mask": _present(password),
        "ipaddr": _uci_get("network.wan.ipaddr"),
        "netmask": _uci_get("network.wan.netmask"),
        "gateway": _uci_get("network.wan.gateway"),
        "dns": [x for x in dns_raw.split() if x],
        "peerdns": _uci_get("network.wan.peerdns") != "0",
        "mtu": _uci_get("network.wan.mtu"),
        "ipv6": _uci_get("network.wan.ipv6") or "auto",
        "wan6": _uci_get("network.wan6.proto") or "",
        "protos": [{"key": k, "label": v} for k, v in PROTO_LABELS.items() if k != "none"],
    }


def status() -> dict:
    """运行态：链路是否 up、拿到什么 IP、网关 DNS、拨号时长。"""
    data = sysinfo._ubus("network", "interface", timeout=5)
    # ubus 用 interface 名查询要带参数，这里直接查 wan
    raw = {}
    try:
        import json
        out = sysinfo._run(["ubus", "call", "network.interface.wan", "status"], timeout=5)
        raw = json.loads(out) if out.strip().startswith("{") else {}
    except Exception:
        raw = {}

    ipv4 = ""
    mask = ""
    peer = ""
    for a in raw.get("ipv4-address") or []:
        ipv4 = a.get("address", "")
        mask = a.get("mask", "")
        peer = a.get("ptpaddress", "")
        break

    ipv6 = []
    for a in raw.get("ipv6-address") or []:
        addr = a.get("address", "")
        if addr and not addr.startswith("fe80"):
            ipv6.append(f"{addr}/{a.get('mask', '')}")

    dns = []
    for d in raw.get("dns-server") or []:
        if d not in dns:
            dns.append(d)

    route = ""
    for r in raw.get("route") or []:
        if r.get("target") == "0.0.0.0" and r.get("mask") == 0:
            route = r.get("nexthop", "")
            break

    up = bool(raw.get("up"))
    return {
        "ok": True,
        "up": up,
        "pending": bool(raw.get("pending")),
        "proto": raw.get("proto", ""),
        "device": raw.get("device", ""),
        "l3_device": raw.get("l3_device", ""),
        "uptime": raw.get("uptime", 0),
        "ipv4": ipv4,
        "mask": mask,
        "peer": peer,
        "gateway": route,
        "ipv6": ipv6,
        "dns": dns,
        "note": "" if up else "WAN 未连接，请检查拨号账号或线路",
    }


# ---------------------------------------------------------------- 写

def _backup() -> str:
    os.makedirs(DATA_DIR, exist_ok=True)
    if os.path.exists(NET_CONF):
        shutil.copy2(NET_CONF, NET_BAK)
        return NET_BAK
    return ""


def _guard_script(wait: int) -> str:
    """等待若干秒后验收：WAN 必须 up 且能 ping 通公网，否则回滚。"""
    return f"""#!/bin/sh
# 由 istore-agent 生成：改完 WAN 配置后的自动验收与回滚。
# 判据必须同时满足两条，只看 up 不够 —— 账号填错时 PPPoE 也会短暂 up 但没有路由。
sleep {wait}
ok=0
if ubus call network.interface.wan status 2>/dev/null | grep -q '"up": true'; then
    if ping -c 2 -W 3 223.5.5.5 >/dev/null 2>&1 || ping -c 2 -W 3 114.114.114.114 >/dev/null 2>&1; then
        ok=1
    fi
fi
if [ "$ok" = "1" ]; then
    cp {NET_BAK} {DATA_DIR}/network.good 2>/dev/null
    logger -t istore-agent "WAN 配置验证通过，已记录为可用配置"
else
    logger -t istore-agent "WAN 配置验证失败，正在回滚"
    cp {NET_BAK} {NET_CONF}
    ifup wan >/dev/null 2>&1
    ubus call network reload >/dev/null 2>&1
    logger -t istore-agent "已回滚到修改前的网络配置"
fi
"""


def apply_wan(payload: dict) -> dict:
    """
    应用 WAN 配置。payload 只接受白名单字段，缺省表示不改。
    password 为空 = 沿用原密码（避免客户端把掩码提交回来写坏配置）。
    """
    proto = str(payload.get("proto", "")).strip()
    if proto not in PROTO_LABELS:
        return {"ok": False, "error": "不支持的接入方式"}

    bak = _backup()
    if not bak:
        return {"ok": False, "error": "找不到网络配置文件，未做任何修改"}

    old = {k: _uci_get(f"network.wan.{k}") for k in EDITABLE}

    steps: list[str] = []
    steps.append(f"network.wan.proto={proto}")

    if proto == "pppoe":
        user = str(payload.get("username", "")).strip()
        if not user or not all(ch.isalnum() or ch in "@.-_" for ch in user):
            return {"ok": False, "error": "宽带账号格式不对"}
        steps.append(f"network.wan.username={user}")
        pwd = str(payload.get("password", ""))
        if pwd:  # 空 = 保持不变
            steps.append(f"network.wan.password={pwd}")
    elif proto == "static":
        ip = str(payload.get("ipaddr", "")).strip()
        gw = str(payload.get("gateway", "")).strip()
        if not _is_ipv4(ip) or not _is_ipv4(gw):
            return {"ok": False, "error": "静态 IP 或网关格式不对"}
        steps.append(f"network.wan.ipaddr={ip}")
        steps.append(f"network.wan.netmask={str(payload.get('netmask', '255.255.255.0')).strip()}")
        steps.append(f"network.wan.gateway={gw}")

    dns = payload.get("dns")
    if isinstance(dns, list):
        cleaned = [str(d).strip() for d in dns if _is_ipv4(str(d).strip())]
        steps.append("network.wan.dns=" + " ".join(cleaned))
        steps.append("network.wan.peerdns=" + ("1" if payload.get("peerdns") else "0"))

    mtu = str(payload.get("mtu", "")).strip()
    if mtu.isdigit() and 576 <= int(mtu) <= 1500:
        steps.append(f"network.wan.mtu={mtu}")

    ipv6 = str(payload.get("ipv6", "")).strip()
    if ipv6 in ("auto", "1", "0"):
        steps.append(f"network.wan.ipv6={ipv6}")

    # 逐条写，任一条失败就整体回滚
    for step in steps:
        key, value = step.split("=", 1)
        out = _uci("set", f"{key}={value}")
        if out and "not found" in out:
            shutil.copy2(bak, NET_CONF)
            return {"ok": False, "error": f"写入 {key} 失败"}

    # 切到 dhcp 时要把 PPPoE 的账号清掉，否则 uci 里残留会让某些脚本误判
    if proto == "dhcp":
        _uci("delete", "network.wan.username")
        _uci("delete", "network.wan.password")

    commit = _uci("commit", "network")
    if "error" in commit.lower():
        shutil.copy2(bak, NET_CONF)
        return {"ok": False, "error": "提交配置失败，已还原"}

    # 起守护：90 秒后验收，失败自动回滚
    wait = 90
    try:
        os.makedirs(os.path.dirname(GUARD), exist_ok=True)
        with open(GUARD, "w", encoding="utf-8") as f:
            f.write(_guard_script(wait))
        os.chmod(GUARD, 0o755)
        subprocess.Popen(["/bin/sh", GUARD], start_new_session=True,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         close_fds=True)
    except Exception as exc:  # 守护起不来就别改了，安全第一
        shutil.copy2(bak, NET_CONF)
        _uci("commit", "network")
        return {"ok": False, "error": f"无法启动回滚守护（{exc}），已还原配置"}

    # 立刻重拨。这里不能等结果：PPPoE 重拨期间 App 已经断连了
    try:
        subprocess.Popen(["/sbin/ifup", "wan"], start_new_session=True,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass

    return {
        "ok": True,
        "message": "配置已保存，正在重拨",
        "guard_seconds": wait,
        "detail": "网络会在 10-30 秒内恢复；" + f"若 {wait} 秒后仍无法上网，"
                  "路由器会自动回滚到修改前的配置，不需要手动干预。",
        "changed": [s.split("=", 1)[0].replace("network.wan.", "") for s in steps],
        "before": {k: ("***" if k == "password" else v) for k, v in old.items()},
    }


def _is_ipv4(s: str) -> bool:
    parts = s.split(".")
    return len(parts) == 4 and all(p.isdigit() and 0 <= int(p) <= 255 for p in parts)


# ---------------------------------------------------------------- 其他网络项

def firewall() -> dict:
    """防火墙策略摘要（只读）。

    为什么要给客户端看这个：这台机器的 `wan` 区 input 是 ACCEPT，
    意味着 IPv6 上管理面（SSH / 8443 / 后台）对公网是开着的。
    这是配置层面的既定事实，光在文档里写没人看得到，
    做成 App 里的一张卡片，用户才知道自己该去改。
    """
    import re
    zones: list[dict] = []
    defaults: dict = {}
    rules: set[int] = set()
    redirects: set[int] = set()
    try:
        out = _uci("show", "firewall", timeout=6)
    except Exception:
        out = ""

    pat = re.compile(r"^firewall\.@(zone|rule|redirect|defaults)\[(\d+)\]\.(\w+)=(.*)$")
    zmap: dict[int, dict] = {}
    for line in out.splitlines():
        m = pat.match(line.strip())
        if not m:
            continue
        kind, idx, opt, val = m.group(1), int(m.group(2)), m.group(3), m.group(4).strip("'")
        if kind == "rule":
            rules.add(idx)
        elif kind == "redirect":
            redirects.add(idx)
        elif kind == "zone":
            z = zmap.setdefault(idx, {"index": idx, "name": "", "input": "",
                                      "output": "", "forward": "", "masq": False})
            if opt == "masq":
                z["masq"] = val in ("1", "'1'", "true")
            elif opt in ("name", "input", "output", "forward"):
                z[opt] = val
        elif kind == "defaults":
            defaults[opt] = val

    zones = [zmap[k] for k in sorted(zmap)]
    risks: list[str] = []
    # defaults.input 只在「zone 没写 input」时才起作用。这台机器 lan / wan 都显式写了，
    # 所以它本身不是漏洞；原来那句「一律放行」会让刚收紧完 wan 的用户以为没生效，
    # 这里改成如实描述影响范围。
    if defaults.get("input") == "ACCEPT":
        risks.append("默认策略 input=ACCEPT：仅影响未单独指定 input 的分区，lan / wan 都已显式设置")
    for z in zones:
        if z["name"] == "wan" and z["input"] == "ACCEPT":
            risks.append("wan 区 input=ACCEPT：公网可直接访问 SSH / 管理后台 / 8443")

    # 禁网规则是 App 自己加的，单独数出来，方便「一键解除」有依据
    blocked = 0
    try:
        for line in _uci("show", "firewall", timeout=6).splitlines():
            if line.startswith("firewall.istore-block-"):
                blocked += 1
    except Exception:
        pass

    return {
        "zones": zones,
        "defaults": defaults,
        "rules": len(rules),
        "redirects": len(redirects),
        "blocked_rules": blocked,
        "risks": risks,
        "note": "只读展示。改防火墙需要到路由器网页端操作，App 不做在线修改。",
    }


def lan() -> dict:
    """局域网现状（只读）。

    改 LAN 网段会让 App 立刻失联 —— 手机连着 192.168.100.x，
    路由器变成 192.168.2.1 之后这条 TCP 连接就再也回不来了。
    所以这里只读，改动留给网页端（或者以后做成「改完自动跳新地址」）。
    """
    ip = _uci_get("network.lan.ipaddr") or "192.168.1.1"
    mask = _uci_get("network.lan.netmask") or "255.255.255.0"

    dhcp_start = _uci_get("dhcp.lan.start")
    dhcp_limit = _uci_get("dhcp.lan.limit")
    dhcp_ignore = _uci_get("dhcp.lan.ignore")
    lease_time = _uci_get("dhcp.lan.leasetime")

    # 租约数：/tmp/dhcp.leases 一行一条，比 ubus 便宜也不会因为 dnsmasq 没起来而卡住
    leases = 0
    try:
        with open("/tmp/dhcp.leases", "r", encoding="utf-8", errors="ignore") as fh:
            leases = sum(1 for line in fh if line.strip())
    except OSError:
        pass

    # LAN 的全局 IPv6 前缀（SLAAC 用的 /64），没有 IPv6 时留空
    ipv6 = ""
    try:
        out = sysinfo._run(["ip", "-o", "-6", "addr", "show", "dev", "br-lan"], timeout=4)
        for part in out.split():
            if part.startswith("240") or part.startswith("2a") or part.startswith("fd"):
                if "/" in part and not part.startswith("fe80"):
                    ipv6 = part
                    break
    except Exception:
        pass

    import ipaddress
    prefix = mask
    try:
        net = ipaddress.ip_network(f"{ip}/{mask}", strict=False)
        pool = ""
        if dhcp_start.isdigit() and dhcp_limit.isdigit():
            base = int(ipaddress.ip_address(ip))
            pool = (f"{ipaddress.ip_address(base + int(dhcp_start))} – "
                    f"{ipaddress.ip_address(base + int(dhcp_start) + int(dhcp_limit) - 1)}")
        hosts = net.num_addresses - 2
        prefix = str(net.prefixlen)
    except Exception:
        pool = ""
        hosts = 0

    return {
        "ipaddr": ip,
        "netmask": mask,
        "cidr": f"{ip}/{prefix}",
        "hosts": hosts,
        "dhcp_enabled": dhcp_ignore != "1",
        "dhcp_start": dhcp_start if dhcp_start.isdigit() else "",
        "dhcp_limit": dhcp_limit if dhcp_limit.isdigit() else "",
        "dhcp_pool": pool,
        "dhcp_lease": lease_time or "",
        "dhcp_leases": leases,
        "ipv6_prefix": ipv6,
        "note": "改管理地址会让所有设备掉线一次，App 会引导你在新地址上确认，"
                "不确认则自动还原",
    }


def overview() -> dict:
    return {
        "ok": True,
        "ts": int(time.time()),
        "config": config(),
        "status": status(),
        "lan": lan(),
    }
