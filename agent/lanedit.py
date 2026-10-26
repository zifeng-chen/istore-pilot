"""LAN 管理地址与 DHCP 地址池的读写。

为什么单独一个模块
------------------
`netcfg.lan()` 是只读快照（给概览页看），`netedit` 只管防火墙，两边都不碰
`network.lan`。而 LAN 地址是**唯一一项改完必然失联一次**的配置——手机连着的
那个 IP 会当场消失，所以它的校验必须比防火墙严得多，但又必须和防火墙共用
同一套事务层（`netapply`），否则「改坏了能回来」这件事就有两套实现。

三个容易踩的点
--------------
1. **改地址和改 DHCP 参数危险程度完全不同**。只调地址池根本不需要动
   `br-lan`，reload 一下 dnsmasq 就行，连接一秒都不断；改 IP 则必然断开。
   混在一起处理会让「只想改租期」的用户也掉一次线，所以这里按是否动了
   ipaddr / netmask 走两条路径。
2. **静态绑定会跟着网段一起失效**。`dhcp` 里的 host 段存的是完整 IP，
   网段从 192.168.100.0/24 换成 192.168.2.0/24 之后，那些绑定全部落到网外，
   dnsmasq 会直接忽略它们——用户不会收到任何提示，只会发现「绑定莫名没了」。
   所以这里的做法是：先算出来报给客户端，让用户明确选「按主机号迁移」还是
   「保留原样」，绝不替用户猜。
3. **agent 自己可能正监听在那个旧 IP 上**。见 `server.serve()`：绑定地址是
   一串具体 IP 时，IP 一换 socket 就成了孤儿，客户端永远回不来确认，于是
   每次改地址都必然超时回滚，看起来像「功能没做对」。
"""
from __future__ import annotations

import ipaddress
import os
import re
import subprocess

from . import netapply, netedit, sysinfo

DATA_DIR = "/etc/istore-agent/data"

# 改 LAN 地址要用比防火墙更长的等待：手机要先掉线、切到新网段、重新握手，
# 60 秒对某些省电策略激进的手机会不够
WAIT_ADDR = 100
WAIT_DHCP = 60

# 掩码下拉选项。不给 /31、/32：那两种没有可用主机地址，DHCP 无从谈起
MASK_CHOICES = [
    {"prefix": 16, "mask": "255.255.0.0", "label": "/16", "hosts": 65534},
    {"prefix": 20, "mask": "255.255.240.0", "label": "/20", "hosts": 4094},
    {"prefix": 22, "mask": "255.255.252.0", "label": "/22", "hosts": 1022},
    {"prefix": 23, "mask": "255.255.254.0", "label": "/23", "hosts": 510},
    {"prefix": 24, "mask": "255.255.255.0", "label": "/24", "hosts": 254},
    {"prefix": 25, "mask": "255.255.255.128", "label": "/25", "hosts": 126},
    {"prefix": 26, "mask": "255.255.255.192", "label": "/26", "hosts": 62},
]

LEASE_CHOICES = [
    {"key": "1h", "label": "1 小时"},
    {"key": "12h", "label": "12 小时"},
    {"key": "24h", "label": "1 天"},
    {"key": "72h", "label": "3 天"},
    {"key": "168h", "label": "7 天"},
    {"key": "infinite", "label": "永久"},
]


def _uci(*args: str, timeout: float = 10.0) -> str:
    return sysinfo._run(["uci", *args], timeout=timeout).strip()


def _now(key: str) -> str:
    out = sysinfo._run(["uci", "-q", "get", key], timeout=4).strip()
    return "" if out.startswith("uci:") else out


def _is_ipv4(s: str) -> bool:
    try:
        ipaddress.IPv4Address(str(s or ""))
        return True
    except ValueError:
        return False


def _prefix_of(mask: str) -> int:
    try:
        return ipaddress.IPv4Network(f"0.0.0.0/{mask}").prefixlen
    except ValueError:
        return 0


def _num(ip: str) -> int:
    return int(ipaddress.IPv4Address(ip))


def _ip(n: int) -> str:
    return str(ipaddress.IPv4Address(n))


def lan_id() -> str:
    """LAN 逻辑接口名。OpenWrt 默认叫 lan，被改过名的按 device=br-lan 找一次。"""
    if _now("network.lan.proto") or _now("network.lan.ipaddr"):
        return "lan"
    for sid, typ in netedit.sections("network").items():
        if typ != "interface" or sid in ("loopback", "wan", "wan6"):
            continue
        if _now(f"network.{sid}.device") == "br-lan":
            return sid
    return "lan"


# ---------------------------------------------------------------- 静态绑定

def _hosts() -> list[dict]:
    """所有 DHCP 静态绑定（dhcp 里的 host 段）。"""
    out: list[dict] = []
    for sid, typ in netedit.sections("dhcp").items():
        if typ != "host":
            continue
        out.append({
            "section": sid,
            "mac": _now(f"dhcp.{sid}.mac"),
            "ip": _now(f"dhcp.{sid}.ip"),
            "name": _now(f"dhcp.{sid}.name"),
        })
    return out


def _hosts_on_section(lan: str) -> list[dict]:
    """只取挂在 LAN 网段上的（`dhcp.lan` 以外的 provider 段不算）。"""
    hosts = _hosts()
    for h in hosts:
        h["dhcp"] = _now(f"dhcp.{h['section']}.dhcp") or lan
    return [h for h in hosts if h.get("dhcp") in (lan, "")]


def _move_hosts(hosts: list[dict], old_net: ipaddress.IPv4Network,
                new_net: ipaddress.IPv4Network) -> tuple[list[dict], list[str]]:
    """按「主机号」把绑定迁到新网段。返回 (可迁移的, 错误信息)。

    主机号是相对**网络地址**算的，不是相对路由器 IP —— 实测 dnsmasq 的
    `dhcp-range` 也按网络地址偏移（192.168.100.1/24 + start=100 得到
    192.168.100.100 – 192.168.100.249），两者必须用同一套口径，
    否则「迁移后的绑定」和「地址池」会差一位。
    """
    old_base = int(old_net.network_address)
    new_base = int(new_net.network_address)
    lo = new_base + 1
    hi = int(new_net.broadcast_address) - 1
    moved: list[dict] = []
    errors: list[str] = []
    for h in hosts:
        if not _is_ipv4(h["ip"]):
            continue
        target = new_base + (_num(h["ip"]) - old_base)
        if target < lo or target > hi:
            errors.append(f"{h.get('name') or h['mac']} 迁移后地址越界")
            continue
        moved.append({**h, "new_ip": _ip(target)})
    return moved, errors


# ---------------------------------------------------------------- 读

def config(client_ip: str = "") -> dict:
    lan = lan_id()
    ip = _now(f"network.{lan}.ipaddr") or "192.168.1.1"
    mask = _now(f"network.{lan}.netmask") or "255.255.255.0"
    prefix = _prefix_of(mask)

    warnings: list[str] = []
    pool = ""
    hosts = 0
    net_first = net_last = 0
    try:
        net = ipaddress.ip_network(f"{ip}/{prefix}", strict=False)
        net_first = int(net.network_address) + 1
        net_last = int(net.broadcast_address) - 1
        hosts = max(0, net.num_addresses - 2)
    except ValueError:
        net = None
        warnings.append("当前 LAN 配置无法解析，可能是手工改过 /etc/config/network")

    start = _now(f"dhcp.{lan}.start")
    limit = _now(f"dhcp.{lan}.limit")
    ignore = _now(f"dhcp.{lan}.ignore")
    lease = _now(f"dhcp.{lan}.leasetime") or "12h"

    pool_first = pool_last = 0
    if net and start.isdigit() and limit.isdigit():
        # uci 里的 start 是「相对网络地址的偏移」，不是相对路由器 IP。
        # 实测：192.168.100.1/24 + start=100 → dhcp-range 192.168.100.100-249
        pool_first = int(net.network_address) + int(start)
        pool_last = pool_first + int(limit) - 1
        if pool_first <= pool_last:
            pool = f"{_ip(pool_first)} – {_ip(pool_last)}"
        if pool_last < net_first or pool_first > net_last:
            warnings.append("DHCP 地址池已经不在 LAN 网段内，新设备拿不到地址")
        elif pool_first <= _num(ip) <= pool_last:
            warnings.append("地址池包含了管理地址本身，可能出现地址冲突")

    # 静态绑定落在网段外的：这类绑定 dnsmasq 会静默忽略，必须在界面上说出来
    bindings = _hosts_on_section(lan)
    outside = []
    if net:
        for h in bindings:
            if _is_ipv4(h["ip"]) and ipaddress.IPv4Address(h["ip"]) not in net:
                outside.append({"mac": h["mac"], "ip": h["ip"], "name": h.get("name", "")})
    if outside:
        warnings.append(f"{len(outside)} 条静态绑定的地址不在当前网段内，实际不生效")

    leases = 0
    try:
        with open("/tmp/dhcp.leases", "r", encoding="utf-8", errors="ignore") as fh:
            leases = sum(1 for line in fh if line.strip())
    except OSError:
        pass

    ipv6 = ""
    try:
        out = sysinfo._run(["ip", "-o", "-6", "addr", "show", "dev", "br-lan"], timeout=4)
        for part in out.split():
            if part.startswith("fe80"):
                continue
            if "/" in part and (part.startswith("240") or part.startswith("2a")
                               or part.startswith("fd")):
                ipv6 = part
                break
    except Exception:
        pass

    ra = _now(f"dhcp.{lan}.ra") or "server"
    return {
        "ok": True,
        "lan": lan,
        "ipaddr": ip,
        "netmask": mask,
        "prefix": prefix,
        "cidr": f"{ip}/{prefix}",
        "network": str(net.network_address) if net else "",
        "broadcast": str(net.broadcast_address) if net else "",
        "first_ip": _ip(net_first) if net else "",
        "last_ip": _ip(net_last) if net else "",
        "hosts": hosts,
        "dhcp": {
            "enabled": ignore != "1",
            "start": int(start) if start.isdigit() else 100,
            "limit": int(limit) if limit.isdigit() else 150,
            "start_ip": _ip(pool_first) if pool_first else "",
            "end_ip": _ip(pool_last) if pool_last else "",
            "pool": pool,
            "lease": lease,
            "leases": leases,
            "ra": ra,
            "ipv6_ok": ra not in ("disabled", "relay"),
        },
        "ipv6_prefix": ipv6,
        "bindings": len(bindings),
        "bindings_outside": outside,
        "masks": MASK_CHOICES,
        "leases_choices": LEASE_CHOICES,
        "waits": {"addr": WAIT_ADDR, "dhcp": WAIT_DHCP},
        # 从外网改 LAN 地址最危险：改完既回不到旧地址，也不一定能连上新地址
        "remote": not netedit.client_on_lan(client_ip),
        "warnings": warnings,
        "note": "改管理地址会让所有设备掉线一次，需要在新地址上点确认，"
                "否则会自动还原。",
    }


# ---------------------------------------------------------------- 校验

def _wan_nets() -> list[tuple[str, ipaddress.IPv4Network]]:
    """其它逻辑接口已占用的网段，用来避免 LAN 改成跟 WAN 冲突的地址。"""
    out: list[tuple[str, ipaddress.IPv4Network]] = []
    lan = lan_id()
    for sid, typ in netedit.sections("network").items():
        if typ != "interface" or sid in ("loopback", lan):
            continue
        ip = _now(f"network.{sid}.ipaddr")
        mask = _now(f"network.{sid}.netmask") or "255.255.255.0"
        if not _is_ipv4(ip):
            continue
        try:
            out.append((sid, ipaddress.ip_network(f"{ip}/{mask}", strict=False)))
        except ValueError:
            continue
    return out


def _norm_lease(v: str) -> str:
    v = (v or "").strip()
    if v in ("", "0"):
        return "12h"
    if v == "infinite":
        return v
    if re.fullmatch(r"\d+[smhdw]?", v):
        return v
    return ""


def apply(payload: dict, client_ip: str = "") -> dict:
    """写 LAN 地址 / DHCP 地址池。全程在配置事务里，失败自动回滚。"""
    lan = lan_id()
    cur_ip = _now(f"network.{lan}.ipaddr") or "192.168.1.1"
    cur_mask = _now(f"network.{lan}.netmask") or "255.255.255.0"
    cur_prefix = _prefix_of(cur_mask)

    # ---- 目标地址
    ip = str(payload.get("ipaddr", cur_ip)).strip() or cur_ip
    if not _is_ipv4(ip):
        return {"ok": False, "error": "管理地址格式不对", "field": "ipaddr"}

    mask = str(payload.get("netmask", "")).strip()
    if mask and not _prefix_of(mask):
        return {"ok": False, "error": "子网掩码格式不对", "field": "netmask"}
    prefix = _prefix_of(mask) if mask else int(payload.get("prefix") or cur_prefix)
    if not mask:
        try:
            mask = str(ipaddress.IPv4Network(f"0.0.0.0/{prefix}").netmask)
        except ValueError:
            return {"ok": False, "error": "子网掩码不合法", "field": "netmask"}

    if prefix < 16 or prefix > 30:
        return {"ok": False, "field": "netmask",
                "error": "掩码范围只支持 /16 – /30，再小的话地址池放不下设备"}

    try:
        net = ipaddress.ip_network(f"{ip}/{prefix}", strict=False)
    except ValueError:
        return {"ok": False, "error": "地址与掩码组合不合法", "field": "ipaddr"}

    if _num(ip) == int(net.network_address):
        return {"ok": False, "field": "ipaddr", "error": f"{ip} 是网段地址，不能作为管理地址"}
    if _num(ip) == int(net.broadcast_address):
        return {"ok": False, "field": "ipaddr", "error": f"{ip} 是广播地址，不能作为管理地址"}

    first = int(net.network_address) + 1
    last = int(net.broadcast_address) - 1

    # 跟别的接口撞网段会导致路由表打架，两边都不通
    for sid, other in _wan_nets():
        if net.overlaps(other):
            return {"ok": False, "field": "ipaddr",
                    "error": f"该网段与 {sid} 的 {other} 重叠，会让两条路由互相打架"}

    # ---- DHCP 参数
    dh = payload.get("dhcp") if isinstance(payload.get("dhcp"), dict) else payload
    dhcp_on = dh.get("dhcp_enabled")
    if dhcp_on is None:
        dhcp_on = _now(f"dhcp.{lan}.ignore") != "1"
    dhcp_on = bool(dhcp_on)

    start_raw = dh.get("dhcp_start", _now(f"dhcp.{lan}.start") or 100)
    limit_raw = dh.get("dhcp_limit", _now(f"dhcp.{lan}.limit") or 150)
    start = int(start_raw) if str(start_raw).strip().isdigit() else 100
    limit = int(limit_raw) if str(limit_raw).strip().isdigit() else 150

    # 允许客户端直接给地址而不是偏移量：用户填 192.168.100.100 比填 100 直观
    start_ip_raw = str(dh.get("dhcp_start_ip", "")).strip()
    if _is_ipv4(start_ip_raw):
        # 同 config()：偏移量相对网络地址
        start = _num(start_ip_raw) - int(net.network_address)
        if start < 1:
            return {"ok": False, "field": "dhcp_start_ip",
                    "error": "地址池起始地址必须在网段可用范围内"}

    if dhcp_on:
        if start < 1:
            return {"ok": False, "field": "dhcp_start", "error": "起始偏移必须大于 0"}
        if limit < 4:
            return {"ok": False, "field": "dhcp_limit", "error": "地址池至少要留 4 个地址"}
        pool_first = int(net.network_address) + start
        pool_last = pool_first + limit - 1
        if pool_first > pool_last:
            return {"ok": False, "field": "dhcp_limit", "error": "地址池范围不合法"}
        if pool_first < first or pool_last > last:
            return {"ok": False, "field": "dhcp_start",
                    "error": f"地址池 {_ip(pool_first)} – {_ip(pool_last)} 超出网段可用范围 "
                             f"{_ip(first)} – {_ip(last)}"}
        if pool_first <= _num(ip) <= pool_last:
            return {"ok": False, "field": "dhcp_start",
                    "error": f"地址池包含了管理地址 {ip}，会让路由器自己拿到矛盾地址"}
        if pool_last - pool_first + 1 > net.num_addresses - 3:
            return {"ok": False, "field": "dhcp_limit", "error": "地址池比网段还大"}

    lease = _norm_lease(str(dh.get("dhcp_lease", _now(f"dhcp.{lan}.leasetime") or "12h")))
    if not lease:
        return {"ok": False, "field": "dhcp_lease", "error": "租约时长格式不对"}

    # ---- 静态绑定
    addr_changed = (ip != cur_ip) or (prefix != cur_prefix)
    hosts = _hosts_on_section(lan)
    static_action = str(payload.get("static_action", "")).strip()
    movable: list[dict] = []
    outside: list[dict] = []
    if addr_changed:
        for h in hosts:
            if not _is_ipv4(h["ip"]):
                continue
            if ipaddress.IPv4Address(h["ip"]) not in net:
                outside.append({"mac": h["mac"], "ip": h["ip"],
                                "name": h.get("name", "")})
        if outside:
            try:
                old_net = ipaddress.ip_network(f"{cur_ip}/{cur_prefix}", strict=False)
            except ValueError:
                old_net = net
            movable, errs = _move_hosts(outside, old_net, net)
            if errs:
                return {"ok": False, "needs_choice": True,
                        "field": "static_action",
                        "static_outside": outside,
                        "static_errs": errs,
                        "error": "有静态绑定的地址超出新网段，且无法按主机号迁移"}
            if not static_action:
                return {
                    "ok": False, "needs_choice": True, "field": "static_action",
                    "error": f"{len(outside)} 条静态绑定的地址不在新网段内",
                    "static_outside": outside,
                    "static_move": movable,
                    "hint": "可以按主机号迁移到新网段，也可以保留原样（这些绑定将失效）",
                }
            if static_action not in ("move", "keep"):
                return {"ok": False, "error": "静态绑定处理方式不合法"}

    # 什么都没变就直接返回，不浪费一次事务
    cur_ignore = _now(f"dhcp.{lan}.ignore") != "1"
    cur_start = _now(f"dhcp.{lan}.start") or "100"
    cur_limit = _now(f"dhcp.{lan}.limit") or "150"
    cur_lease = _now(f"dhcp.{lan}.leasetime") or "12h"
    if (not addr_changed and dhcp_on == cur_ignore
            and str(start) == cur_start and str(limit) == cur_limit
            and lease == cur_lease):
        return {"ok": True, "changed": False, "message": "配置没有变化"}

    # ---- 开事务
    note = (f"LAN 地址 {cur_ip}/{cur_prefix} → {ip}/{prefix}" if addr_changed
            else "调整 DHCP 地址池")
    wait = WAIT_ADDR if addr_changed else WAIT_DHCP
    txn = netapply.begin("lan", services=("network", "firewall", "dnsmasq"),
                         wait=wait, note=note)
    if not txn.get("ok"):
        return txn
    token = txn["token"]

    def fail(msg: str, field: str = "") -> dict:
        netapply.rollback(token, quiet=True)
        out = {"ok": False, "error": msg}
        if field:
            out["field"] = field
        return out

    steps: list[str] = []
    try:
        if addr_changed:
            steps.append(f"network.{lan}.ipaddr={ip}")
            steps.append(f"network.{lan}.netmask={mask}")
        if dhcp_on != cur_ignore:
            steps.append(f"dhcp.{lan}.ignore={'0' if dhcp_on else '1'}")
        if str(start) != cur_start:
            steps.append(f"dhcp.{lan}.start={start}")
        if str(limit) != cur_limit:
            steps.append(f"dhcp.{lan}.limit={limit}")
        if lease != cur_lease:
            steps.append(f"dhcp.{lan}.leasetime={lease}")

        for step in steps:
            key, value = step.split("=", 1)
            out = _uci("set", f"{key}={value}")
            if out and ("not found" in out or "invalid" in out):
                return fail(f"写入 {key} 失败：{out}", key.split(".", 2)[-1])
        # 打开 DHCP 时把模式补成 server：有些配置里 dhcpv4 被设成 disabled，
        # 只把 ignore 置 0 是不够的
        if dhcp_on:
            _uci("set", f"dhcp.{lan}.dhcpv4=server")

        # 静态绑定迁移必须在新地址生效前写进去，否则 dnsmasq 会先读到失效的旧表
        moved = 0
        if addr_changed and static_action == "move":
            for h in movable:
                _uci("set", f"dhcp.{h['section']}.ip={h['new_ip']}")
                moved += 1

        for pkg in ("network", "dhcp"):
            commit = _uci("commit", pkg)
            if "error" in commit.lower():
                return fail(f"提交 {pkg} 配置失败，已还原")
    except Exception as exc:
        return fail(f"写入配置时出错（{exc}），已还原")

    # ---- 生效
    if addr_changed:
        # 这里必须异步：一旦 br-lan 换了地址，本次 HTTP 连接就断了，
        # 同步等 reload 会在响应发出之前把自己弄死
        _spawn_reload()
    else:
        _reload_dnsmasq()

    warnings: list[str] = []
    if addr_changed:
        warnings.append(f"所有设备会短时间掉线，请把 App 地址改为 http://{ip}:8443")
        if not dhcp_on:
            warnings.append("DHCP 已关闭，新设备需要手工配置 IP 才能上网")
    if moved:
        warnings.append(f"{moved} 条静态绑定已按主机号迁移到新网段")
    if addr_changed and static_action == "keep" and outside:
        warnings.append(f"{len(outside)} 条静态绑定保留原地址，将不再生效")

    return {
        "ok": True,
        "token": token,
        "wait": wait,
        "deadline": txn.get("deadline", 0),
        "reconnect": addr_changed,
        "changed": [s.split("=", 1)[0].split(".", 1)[1] for s in steps],
        "old_ipaddr": cur_ip,
        "old_cidr": f"{cur_ip}/{cur_prefix}",
        "new_ipaddr": ip,
        "new_netmask": mask,
        "new_cidr": f"{ip}/{prefix}",
        "moved_bindings": moved,
        "warnings": warnings,
        "message": (f"地址已改为 {ip}，正在切换" if addr_changed
                    else "DHCP 设置已保存"),
    }


def _reload_dnsmasq() -> None:
    try:
        subprocess.run(["/etc/init.d/dnsmasq", "reload"], timeout=20,
                       check=False, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
    except Exception:
        pass


def _spawn_reload() -> None:
    """派生一个脱离 agent 进程的 shell 去换地址。

    为什么不能直接 reload：`/etc/init.d/network reload` 会把 br-lan 摘下来
    重新配一遍，本次请求所在连接当场断开；如果同步执行，客户端收到的是
    「连接被重置」而不是一句「已改为 192.168.2.1」——它连新地址是什么都不知道，
    只能靠猜，于是永远回不来确认。
    """
    script = """#!/bin/sh
sleep 1
/etc/init.d/network reload >/dev/null 2>&1
sleep 3
/etc/init.d/dnsmasq reload >/dev/null 2>&1
/etc/init.d/firewall reload >/dev/null 2>&1
logger -t istore-agent "LAN 地址已切换，等待客户端确认"
"""
    try:
        os.makedirs("/usr/lib/istore-agent", exist_ok=True)
        path = "/usr/lib/istore-agent/lan_reload.sh"
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(script)
        os.chmod(path, 0o755)
        subprocess.Popen(["/bin/sh", path], start_new_session=True,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         close_fds=True)
    except Exception:
        # 起不来就退化成直接 reload：连接会断，但至少地址改了
        try:
            subprocess.Popen(["/etc/init.d/network", "reload"], start_new_session=True,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass
