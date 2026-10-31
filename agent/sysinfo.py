"""iStoreOS 状态采集。只读 /proc、/sys 与 ubus，不改动系统任何配置。"""

from __future__ import annotations

import copy
import json
import os
import subprocess
import threading
import time

from . import mask

_lock = threading.Lock()
_prev_cpu: tuple[float, float] | None = None
_cpu_cache: tuple[float, float, list[float]] = (0.0, 0.0, [])
_prev_net: dict[str, tuple[float, float]] = {}
_prev_net_ts: float = 0.0
_net_cache: dict[str, dict[str, float]] = {}
_IFACE_TTL = 0.5
_iface_lock = threading.Lock()
# 可变字典：写成 global 容易漏，直接原地更新
_iface_cache: dict = {"ts": 0.0, "val": {}}
_ROLES_TTL = 15.0
_roles_lock = threading.Lock()
_roles_cache: dict = {"ts": 0.0, "val": {}}
_OV_BASE_TTL = 1.0
_ov_lock = threading.Lock()
_ov_cache: dict = {"ts": 0.0, "val": {}}


def _read(path: str, default: str = "") -> str:
    try:
        with open(path, "r", errors="replace") as fh:
            return fh.read()
    except OSError:
        return default


def _run(cmd: list[str], timeout: float = 5.0) -> str:
    try:
        out = subprocess.run(
            cmd,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
        return out.stdout.decode("utf-8", "replace")
    except (OSError, subprocess.SubprocessError):
        return ""


def _ubus(obj: str, method: str, timeout: float = 5.0) -> dict:
    raw = _run(["ubus", "call", obj, method], timeout=timeout)
    if not raw.strip():
        return {}
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {}


# ---------------------------------------------------------------- CPU / 内存


def cpu() -> dict:
    """返回整体占用率与每核占用率（基于两次采样差分）。"""
    global _prev_cpu, _cpu_cache
    with _lock:
        now = time.monotonic()
        cached_pct, cached_ts, cached_core = _cpu_cache
        raw = _read("/proc/stat")
        rows = [ln.split() for ln in raw.splitlines() if ln.startswith("cpu")]
        if not rows:
            return {"percent": 0.0, "per_core": []}

        def parse(row: list[str]) -> tuple[float, float]:
            vals = [float(v) for v in row[1:9]]
            idle = vals[3] + (vals[4] if len(vals) > 4 else 0.0)
            return sum(vals), idle

        total, idle = parse(rows[0])
        if _prev_cpu is None:
            _prev_cpu = (total, idle)
            _cpu_cache = (0.0, now, [])
            return {"percent": 0.0, "per_core": []}
        if now - cached_ts < 0.2:
            return {"percent": cached_pct, "per_core": cached_core}

        d_total = total - _prev_cpu[0]
        d_idle = idle - _prev_cpu[1]
        pct = 0.0 if d_total <= 0 else max(0.0, min(100.0, (1 - d_idle / d_total) * 100))
        _prev_cpu = (total, idle)

        per_core = []
        for row in rows[1:]:
            t, i = parse(row)
            per_core.append(round(0.0 if t <= 0 else (1 - i / t) * 100, 1))
        _cpu_cache = (round(pct, 1), now, per_core)
        return {"percent": round(pct, 1), "per_core": per_core}


def memory() -> dict:
    info: dict[str, int] = {}
    for line in _read("/proc/meminfo").splitlines():
        parts = line.split(":")
        if len(parts) == 2:
            info[parts[0].strip()] = int(parts[1].split()[0]) * 1024
    total = info.get("MemTotal", 0)
    avail = info.get("MemAvailable", info.get("MemFree", 0))
    used = total - avail
    return {
        "total": total,
        "used": used,
        "available": avail,
        "free": info.get("MemFree", 0),
        "buffers": info.get("Buffers", 0),
        "cached": info.get("Cached", 0),
        "percent": round(used / total * 100, 1) if total else 0.0,
        "swap_total": info.get("SwapTotal", 0),
        "swap_used": info.get("SwapTotal", 0) - info.get("SwapFree", 0),
    }


def load() -> dict:
    parts = _read("/proc/loadavg").split()
    try:
        one, five, fifteen = (float(x) for x in parts[:3])
    except (ValueError, IndexError):
        one = five = fifteen = 0.0
    threads = parts[3] if len(parts) > 3 else ""
    return {"load1": one, "load5": five, "load15": fifteen, "threads": threads}


def uptime() -> float:
    try:
        return float(_read("/proc/uptime").split()[0])
    except (ValueError, IndexError):
        return 0.0


_BOARD_TTL = 60.0
_board_lock = threading.Lock()
_board_cache: dict = {"ts": 0.0, "val": {}}


def board() -> dict:
    """主机名 / 型号 / 固件版本。只有升级固件或改主机名才会变，缓存 60 秒。

    一次 `ubus call system board` 要 3.9ms，它在概览的冷路径上白占四分之一的
    时间；而这个值一分钟内不可能变。
    """
    with _board_lock:
        if _board_cache["val"] and time.monotonic() - _board_cache["ts"] < _BOARD_TTL:
            return _board_cache["val"]
    data = _ubus("system", "board")
    rel = data.get("release", {}) if isinstance(data, dict) else {}
    out = {
        "hostname": data.get("hostname", ""),
        "model": data.get("model", ""),
        "system": data.get("system", ""),
        "kernel": data.get("kernel", ""),
        "distribution": rel.get("distribution", ""),
        "version": rel.get("version", ""),
        "revision": rel.get("revision", ""),
        "target": rel.get("target", ""),
        "description": rel.get("description", ""),
    }
    with _board_lock:
        _board_cache["ts"] = time.monotonic()
        _board_cache["val"] = out
    return out


def cpu_model() -> dict:
    name = "unknown"
    cores = 0
    # 只读一次：原来是两遍 _read("/proc/cpuinfo")
    for line in _read("/proc/cpuinfo").splitlines():
        if line.startswith("processor"):
            cores += 1
        elif name == "unknown" and line.lower().startswith("model name"):
            name = line.split(":", 1)[1].strip()
    return {"model": name, "cores": cores}


def temperature() -> list[dict]:
    out = []
    for entry in sorted(os.listdir("/sys/class/thermal") if os.path.isdir("/sys/class/thermal") else []):
        if not entry.startswith("thermal_zone"):
            continue
        base = f"/sys/class/thermal/{entry}"
        raw = _read(f"{base}/temp").strip()
        if not raw:
            continue
        try:
            milli = int(raw)
        except ValueError:
            continue
        out.append({"zone": entry, "label": _read(f"{base}/type").strip(), "celsius": round(milli / 1000, 1)})
    return out


# ---------------------------------------------------------------- 网口 / 流量


def _net_counters() -> dict[str, tuple[float, float]]:
    counters: dict[str, tuple[float, float]] = {}
    for line in _read("/proc/net/dev").splitlines()[2:]:
        if ":" not in line:
            continue
        name, rest = line.split(":", 1)
        fields = rest.split()
        if len(fields) < 9:
            continue
        counters[name.strip()] = (float(fields[0]), float(fields[8]))
    return {k: v for k, v in counters.items() if not k.startswith(("lo", "docker", "veth", "br-"))}


def net_rates() -> dict[str, dict[str, float]]:
    """返回每个网口当前的收发速率（字节/秒）。"""
    global _prev_net, _prev_net_ts, _net_cache
    with _lock:
        now = time.monotonic()
        cur = _net_counters()
        if _prev_net_ts and now - _prev_net_ts > 0.15:
            dt = now - _prev_net_ts
            fresh: dict[str, dict[str, float]] = {}
            for name, (rx, tx) in cur.items():
                if name in _prev_net:
                    prx, ptx = _prev_net[name]
                    fresh[name] = {
                        "rx_bps": round(max(0.0, (rx - prx) / dt), 1),
                        "tx_bps": round(max(0.0, (tx - ptx) / dt), 1),
                        "rx_total": rx,
                        "tx_total": tx,
                    }
                else:
                    fresh[name] = {"rx_bps": 0.0, "tx_bps": 0.0, "rx_total": rx, "tx_total": tx}
            _net_cache = fresh
            _prev_net = cur
            _prev_net_ts = now
        elif not _prev_net_ts:
            _prev_net = cur
            _prev_net_ts = now
        return _net_cache


def _link_speed(name: str) -> int:
    raw = _read(f"/sys/class/net/{name}/speed").strip()
    try:
        val = int(raw)
        return val if val > 0 else 0
    except ValueError:
        return 0


def _carrier(name: str) -> bool:
    return _read(f"/sys/class/net/{name}/carrier").strip() == "1"


def _mac(name: str) -> str:
    return _read(f"/sys/class/net/{name}/address").strip()


def ip_addrs() -> list[dict]:
    raw = _run(["ip", "-j", "addr"])
    if not raw.strip():
        return []
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return []
    out = []
    for dev in data:
        addrs = []
        for a in dev.get("addr_info", []):
            addrs.append({"family": a.get("family"), "address": a.get("local"), "prefixlen": a.get("prefixlen")})
        out.append(
            {
                "name": dev.get("ifname"),
                "state": dev.get("operstate", "").lower(),
                "mac": dev.get("address", ""),
                "mtu": dev.get("mtu"),
                "addresses": addrs,
            }
        )
    return out


def _port_roles() -> dict[str, str]:
    """物理网口 → "wan" / "lan"。

    软路由上前六个口长得一模一样，界面上只写 eth0~eth5 等于没说。角色只能从
    uci 读：WAN 绑的那个口写在 network.wan.device，LAN 口是 br-lan 这类桥的成员。
    DSA 架构下 wan.device 可能是逻辑名（wan / lan1），那种情况靠桥成员反推，
    剩下没归到任何桥的口留空，不瞎猜。

    结果缓存 15 秒：它只在改网络配置时才变，而 `uci show network` 要 2.7ms。
    """
    now = time.monotonic()
    with _roles_lock:
        if _roles_cache["val"] and now - _roles_cache["ts"] < _ROLES_TTL:
            return _roles_cache["val"]

    flat: dict[str, str] = {}
    for line in _run(["uci", "show", "network"]).splitlines():
        key, sep, val = line.partition("=")
        if not sep:
            continue
        flat[key.strip()] = val.strip().strip("'")

    roles: dict[str, str] = {}
    wan_dev = flat.get("network.wan.device", "")
    if wan_dev:
        roles[wan_dev] = "wan"

    for key, val in flat.items():
        if not key.startswith("network.") or not key.endswith(".ports"):
            continue
        sec = key[len("network."):-len(".ports")]
        sec_name = flat.get(f"network.{sec}.name", sec)
        role = "wan" if "wan" in sec_name.lower() else "lan"
        # uci 把多口写成 'eth1' 'eth2'，引号在中间，去掉引号再切
        for port in val.replace("'", " ").split():
            roles.setdefault(port, role)
    with _roles_lock:
        _roles_cache["ts"] = now
        _roles_cache["val"] = roles
    return roles


def physical_ports(addrs: dict[str, dict] | None = None) -> list[dict]:
    """物理网口列表。`addrs` 可由调用方传进来复用，省一次 `ip -j addr`。"""
    rates = net_rates()
    if addrs is None:
        addrs = {d["name"]: d for d in ip_addrs()}
    roles = _port_roles()
    out = []
    names = sorted(n for n in os.listdir("/sys/class/net") if n.startswith(("eth", "enp", "eno")))
    for name in names:
        state = addrs.get(name, {}).get("state", "down")
        up = state == "up" and _carrier(name)
        rate = rates.get(name, {})
        out.append(
            {
                "name": name,
                "role": roles.get(name, ""),
                "up": up,
                "speed_mbps": _link_speed(name) if up else 0,
                "mac": _mac(name),
                "rx_bps": rate.get("rx_bps", 0.0),
                "tx_bps": rate.get("tx_bps", 0.0),
                "rx_total": rate.get("rx_total", 0.0),
                "tx_total": rate.get("tx_total", 0.0),
            }
        )
    return out


def interfaces() -> dict:
    """网口快照，0.5 秒内复用同一次采样。

    `interfaces()` 要起一个 ubus 进程 + 一次 `ip -j addr`，约 9ms；而
    `/overview`、`/traffic`、`/network` 三个接口都会调它，客户端又是「一次刷新
    连着打一串请求」—— 不共享的话同一个刷新周期要采两三遍，还彼此相差几十毫秒，
    顶栏的速率和曲线会互相打架。

    0.5 秒只够盖住这种突发，不会让速率发木（客户端本身 3 秒才刷一次）。
    返回深拷贝：调用方往下写不会污染缓存。
    """
    now = time.monotonic()
    with _iface_lock:
        if _iface_cache["val"] and now - _iface_cache["ts"] < _IFACE_TTL:
            return copy.deepcopy(_iface_cache["val"])
    val = _interfaces_sample()
    with _iface_lock:
        _iface_cache["ts"] = now
        _iface_cache["val"] = val
    return copy.deepcopy(val)


def _iface_statuses() -> tuple[dict, dict]:
    """一次 `ubus call network.interface dump` 取回 wan / lan 两份状态。

    原来分两次单查（`...wan status` / `...lan status`）：一个 ubus 进程约 4ms，
    两次就 8ms，是网口采样里最大的一笔。dump 返回的字段跟单查完全一致
    （up / proto / device / l3_device / uptime / ipv4-address / ipv6-address /
    dns-server / route），只是多带一个 interface 名字。
    """
    data = _ubus("network.interface", "dump")
    items = data.get("interface") if isinstance(data, dict) else None
    if isinstance(items, list) and items:
        by = {it.get("interface"): it for it in items if isinstance(it, dict)}
        return by.get("wan", {}), by.get("lan", {})
    # 万一这版固件的 dump 行为不同，退回两次单查，宁可慢也不能报错
    return _ubus("network.interface.wan", "status"), _ubus("network.interface.lan", "status")


def _interfaces_sample() -> dict:
    wan, lan = _iface_statuses()
    rates = net_rates()
    all_addrs = ip_addrs()

    def pick(status: dict, key: str) -> list[dict]:
        items = status.get(key) or []
        return [
            {
                # 公网 / CGNAT 地址出站即打码，本地地址原样（见 mask.py）
                "address": mask.ip(str(it.get("address") or "")),
                "prefixlen": it.get("mask"),
                # PPPoE 的对端地址就是运营商网关，和 WAN 地址一样要打码
                "ptp": mask.ip(str(it.get("ptpaddress") or "")),
            }
            for it in items
            if isinstance(it, dict)
        ]

    def shape(status: dict, label: str) -> dict:
        dev = status.get("l3_device") or status.get("device") or ""
        rate = rates.get(dev, {})
        ipv6 = pick(status, "ipv6-address")
        # ubus 只给出链路本地地址，全局地址要从接口表里补
        for entry in all_addrs:
            if entry["name"] != dev:
                continue
            for addr in entry["addresses"]:
                if addr["family"] != "inet6" or not addr["address"]:
                    continue
                if addr["address"].startswith("fe80"):
                    continue
                if not any(x["address"] == addr["address"] for x in ipv6):
                    ipv6.append({"address": mask.ip(addr["address"]),
                                 "prefixlen": addr["prefixlen"], "ptp": None})
        return {
            "label": label,
            "up": bool(status.get("up")),
            "proto": status.get("proto", ""),
            "device": status.get("device", ""),
            "l3_device": dev,
            "uptime": status.get("uptime", 0),
            "ipv4": pick(status, "ipv4-address"),
            "ipv6": ipv6,
            "prefixes": [
                dict(x, address=mask.ip(str(x.get("address") or "")))
                for x in pick(status, "ipv6-prefix")
            ],
            "dns": [mask.ip(str(d)) for d in (status.get("dns-server") or [])],
            "gateway": mask.ip(str(status.get("route", [{}])[0].get("nexthop") or ""))
            if status.get("route") else None,
            "rx_bps": rate.get("rx_bps", 0.0),
            "tx_bps": rate.get("tx_bps", 0.0),
            "rx_total": rate.get("rx_total", 0.0),
            "tx_total": rate.get("tx_total", 0.0),
        }

    return {"wan": shape(wan, "WAN"), "lan": shape(lan, "LAN"),
            "ports": physical_ports({d["name"]: d for d in all_addrs})}


def clients() -> list[dict]:
    out = []
    seen: set[str] = set()
    raw = _read("/tmp/dhcp.leases")
    for line in raw.splitlines():
        parts = line.split()
        if len(parts) < 4:
            continue
        try:
            expires = int(parts[0])
        except ValueError:
            continue
        mac, ip, hostname = parts[1].lower(), parts[2], parts[3]
        if mac in seen:
            continue
        seen.add(mac)
        out.append(
            {
                "mac": mac,
                "ip": ip,
                "hostname": "" if hostname == "*" else hostname,
                "expires": expires,
                "online": expires == 0 or expires > time.time(),
            }
        )
    return sorted(out, key=lambda c: [int(x) for x in c["ip"].split(".")] if c["ip"].count(".") == 3 else [0])


# ---------------------------------------------------------------- 存储


def storage() -> list[dict]:
    skip_fs = {"tmpfs", "devtmpfs", "proc", "sysfs", "cgroup", "cgroup2", "devpts", "debugfs", "tracefs",
               "securityfs", "pstore", "bpf", "configfs", "fusectl", "mqueue", "hugetlbfs", "efivarfs",
               "squashfs", "overlay", "nsfs", "binfmt_misc", "autofs", "ramfs"}
    out = []
    seen: set[str] = set()
    for line in _read("/proc/mounts").splitlines():
        parts = line.split()
        if len(parts) < 3:
            continue
        device, mount, fstype = parts[0], parts[1], parts[2]
        if fstype in skip_fs or "overlay" in fstype:
            continue
        if device in seen or not device.startswith("/dev/"):
            continue
        try:
            st = os.statvfs(mount)
        except OSError:
            continue
        total = st.f_blocks * st.f_frsize
        free = st.f_bavail * st.f_frsize
        if total < 64 * 1024 * 1024:
            continue
        seen.add(device)
        out.append(
            {
                "device": device,
                "mount": mount,
                "fstype": fstype,
                "total": total,
                "free": free,
                "used": total - free,
                "percent": round((total - free) / total * 100, 1),
            }
        )
    return out


def _overview_base() -> dict:
    """概览里变化慢的那几块，1 秒内复用。

    CPU 占用、内存、负载这些本来就没有「毫秒级」的意义，1 秒一采和之前
    服务端那层 1 秒缓存是同一档精度；把它们单独缓存，是为了让 `network`
    每次都能拿最新的一份 —— 见 `overview()`。
    """
    now = time.monotonic()
    with _ov_lock:
        if _ov_cache["val"] and now - _ov_cache["ts"] < _OV_BASE_TTL:
            return _ov_cache["val"]
    cpu_info = cpu()
    info = cpu_model()
    val = {
        "board": board(),
        "cpu": {
            "model": info["model"],
            "cores": info["cores"],
            "percent": cpu_info["percent"],
            "per_core": cpu_info["per_core"],
        },
        "memory": memory(),
        "load": load(),
        "uptime": uptime(),
        "temperature": temperature(),
        "storage": storage(),
    }
    with _ov_lock:
        _ov_cache["ts"] = now
        _ov_cache["val"] = val
    return val


def overview() -> dict:
    """概览。网口那一段每次都走 `interfaces()` 的共享采样。

    之前整份 overview 缓存在服务端 1 秒，而 `/traffic`、`/network` 各走各的采样：
    同一秒内三个接口能给出一大一小两组速率（实测 126KB/s 对 7KB/s），
    顶栏和曲线就会互相打架。拆开之后，慢变量仍缓存 1 秒，
    网口数据固定来自同一份 0.5 秒采样 —— 三个接口天然一致。
    """
    out = dict(_overview_base())
    out["ts"] = int(time.time())
    out["network"] = interfaces()
    return out
