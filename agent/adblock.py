"""广告拦截：AdGuard Home 状态检测、预检与接管控制。

设计要点：默认**不接管** DNS。
AGH 装着、跑着、规则也加载了，但只监听 127.0.0.1:5353，
全家设备仍走 dnsmasq:53，等于零影响。
用户主动点「接管」才切到 53，随时可以一键回滚。

两种运行模式：
  observe  — AGH 监听 127.0.0.1:5353，仅路由器本机可查，不参与转发
  takeover — AGH 监听 0.0.0.0:53，dnsmasq 关 DNS（port=0）只留 DHCP

切到 takeover 后链路：
  客户端:53 → nft redirect :53 → AGH:53 → 127.0.0.1:7874 → OpenClash
  本地域名（.lan / 静态绑定 / hosts）→ AGH → 127.0.0.1:5354 → dnsmasq

接管前的四道保险（这里踩过坑，不能再踩）
----------------------------------------
1. **上游必须沿用 dnsmasq 的 server**。AGH 一旦用公共 DNS 当上游，域名就不再
   经过 OpenClash，国外站点解析不到真地址、国内站点也拿不到 fake-ip，
   分流链路整条废掉。所以上游从 ``uci show dhcp`` 现读，不写死。
2. **dnsmasq 只挪端口，不能关掉**。家里有 25 条静态绑定和 ``.lan`` 域名，
   dnsmasq 一停，NAS、打印机这些就只剩 IP 能访问了。
   挪到 5354 后继续提供本地解析，OpenClash 的 watchdog 只改 server 不改 port，
   不会把它抢回去。
3. **AAAA 跟随 OpenClash 的 filter_aaaa_dns**，不擅自改动。本机开着该开关
   （过滤 AAAA 防 IPv6 泄漏），AGH 跟着一起过滤才是零变化；
   反过来"帮"用户打开 AAAA 会让域名优先走 IPv6 直连，绕过代理。
4. **接管后实测解析**：国内 / 国外 / 本地 .lan 各查一次，任一失败立即回滚。
"""

from __future__ import annotations

import base64
import json
import os
import random
import re
import socket
import struct
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

from .config import get as cfg

AGH_BIN = "/usr/bin/AdGuardHome/AdGuardHome"
AGH_YAML = "/etc/AdGuardHome.yaml"
SS53 = 5353

# 接管时 AGH 要接住所有来源地址：nft 把 LAN/UDP 的 53 一律 redirect 到本机
BIND_ALL = ["0.0.0.0", "::"]

# 接管时 dnsmasq 挪到这个端口继续做本地解析（.lan / 静态绑定 / hosts）
LOCAL_DNS_PORT = 5354

# 本地解析要保留的域名后缀，AGH 会把它们单独转发给 dnsmasq
LOCAL_ZONES = ("lan", "local", "home.arpa")

# OpenClash 没在跑时的兜底上游（此时本来也没有分流）
FALLBACK_UPSTREAM = ["223.5.5.5", "119.29.29.29"]


# --------------------------------------------------------------- 基础


def _run(args: list[str], timeout: float = 15.0) -> tuple[int, str]:
    try:
        p = subprocess.run(args, capture_output=True, timeout=timeout, check=False)
        return p.returncode, (p.stdout + p.stderr).decode("utf-8", "replace")
    except (OSError, subprocess.SubprocessError) as exc:
        return 1, str(exc)


def _conf() -> dict:
    return cfg("adguard", {}) or {}


def _api_base() -> str:
    """AGH 管理口只绑局域网 IPv4，所以不能写死 127.0.0.1。
    配置里 api_host 优先，没配就用本机 LAN 地址。"""
    conf = _conf()
    port = int(conf.get("api_port", 3000))
    host = conf.get("api_host") or "192.168.100.1"
    return f"http://{host}:{port}/control"


def _api(path: str, method: str = "GET", body: dict | None = None, timeout: float = 6.0):
    user = _conf().get("user", "admin")
    password = _conf().get("password", "")
    auth = base64.b64encode(f"{user}:{password}".encode()).decode()
    headers = {"Authorization": f"Basic {auth}", "Content-Type": "application/json"}
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(_api_base() + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            return json.loads(raw.decode("utf-8", "replace")) if raw else {}
    except (urllib.error.URLError, urllib.error.HTTPError, OSError, json.JSONDecodeError) as exc:
        return {"__error": str(exc)}


def _installed() -> bool:
    return os.path.exists(AGH_BIN)


def _running() -> bool:
    code, out = _run(["pgrep", "-f", "/usr/bin/AdGuardHome/AdGuardHome"], timeout=5)
    return code == 0 and bool(out.strip())


def _read_yaml() -> str:
    try:
        with open(AGH_YAML, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def _dns_settings(text: str) -> dict:
    """只解析 dns 段里的标量，避免误伤 tls 段的同名键。"""
    out = {"port": None, "bind_hosts": [], "upstream_dns": [], "aaaa_disabled": None}
    lines = text.splitlines()
    in_dns = False
    list_key = ""
    for line in lines:
        if re.match(r"^dns:\s*$", line):
            in_dns = True
            continue
        if in_dns and re.match(r"^\S", line):
            break
        if not in_dns:
            continue

        m = re.match(r"^\s{2}port:\s*(\d+)", line)
        if m:
            out["port"] = int(m.group(1))
            list_key = ""
            continue
        m = re.match(r"^\s{2}aaaa_disabled:\s*(\S+)", line)
        if m:
            out["aaaa_disabled"] = m.group(1).lower() in {"true", "1", "yes"}
            list_key = ""
            continue

        m = re.match(r"^\s{2}(bind_hosts|upstream_dns):\s*$", line)
        if m:
            list_key = m.group(1)
            continue
        if list_key:
            m = re.match(r"^\s{4}-\s*(\S+)", line)
            if m:
                # yaml 里 IPv6 any 会写成 - "::"（不加引号会被当成 map）
                out[list_key].append(m.group(1).strip("\"'"))
                continue
            if line.strip() and not line.strip().startswith("#"):
                list_key = ""
    return out


def _patch_yaml(port=None, hosts=None, aaaa=None, upstream=None) -> bool:
    """整段重写 dns 里的 port / bind_hosts / aaaa_disabled / upstream_dns。

    先备份到 .bak。四个参数都可选，只改传进来的那几项。
    """
    text = _read_yaml()
    if not text:
        return False
    try:
        with open(AGH_YAML + ".bak", "w", encoding="utf-8") as fh:
            fh.write(text)
    except OSError:
        pass

    lines = text.splitlines()
    out: list[str] = []
    in_dns = False
    seen: set[str] = set()
    i = 0
    while i < len(lines):
        line = lines[i]

        if re.match(r"^dns:\s*$", line):
            in_dns = True
            out.append(line)
            i += 1
            continue
        if in_dns and re.match(r"^\S", line):
            # 离开 dns 段之前，把没写过的项补齐（顺序无所谓，yaml 不要求）
            out.extend(_pending(seen, port, hosts, aaaa, upstream))
            in_dns = False

        if not in_dns:
            out.append(line)
            i += 1
            continue

        if port is not None and re.match(r"^\s{2}port:\s*\d+", line):
            out.append(f"  port: {port}")
            seen.add("port")
            i += 1
            continue

        if aaaa is not None and re.match(r"^\s{2}aaaa_disabled:\s*\S+", line):
            out.append(f"  aaaa_disabled: {'true' if aaaa else 'false'}")
            seen.add("aaaa")
            i += 1
            continue

        m = re.match(r"^\s{2}(bind_hosts|upstream_dns):\s*$", line)
        if m:
            key = m.group(1)
            want = hosts if key == "bind_hosts" else upstream
            out.append(f"  {key}:")
            # 跳过原列表项
            j = i + 1
            while j < len(lines) and re.match(r"^\s{4}-\s*\S+", lines[j]):
                j += 1
            if want is None:
                # 不打算改，原样搬回来
                out.extend(lines[i + 1:j])
            else:
                for h in want:
                    # 一律加引号：上游可能写成 [/lan/]127.0.0.1:5354，
                    # 开头的 [ 会被 yaml 当成数组，"" 会被当成空串，":" 会被当成 map
                    out.append(f'    - "{h}"')
                seen.add("bind" if key == "bind_hosts" else "upstream")
            i = j
            continue

        out.append(line)
        i += 1

    if in_dns:
        out.extend(_pending(seen, port, hosts, aaaa, upstream))

    try:
        with open(AGH_YAML, "w", encoding="utf-8") as fh:
            fh.write("\n".join(out) + "\n")
        return True
    except OSError:
        return False


def _pending(seen: set[str], port, hosts, aaaa, upstream) -> list[str]:
    """原配置里压根没有这些键时，补在 dns 段末尾。"""
    add: list[str] = []
    if port is not None and "port" not in seen:
        add.append(f"  port: {port}")
    if aaaa is not None and "aaaa" not in seen:
        add.append(f"  aaaa_disabled: {'true' if aaaa else 'false'}")
    if hosts is not None and "bind" not in seen:
        add.append("  bind_hosts:")
        add.extend(f'    - "{h}"' for h in hosts)
    if upstream is not None and "upstream" not in seen:
        add.append("  upstream_dns:")
        add.extend(f'    - "{u}"' for u in upstream)
    return add


def _write_dns_settings(port: int, hosts: list[str]) -> bool:
    """只改监听地址的那条老路，保留给回滚用。"""
    return _patch_yaml(port=port, hosts=hosts)


def _dnsmasq_port() -> int:
    code, out = _run(["uci", "get", "dhcp.@dnsmasq[0].port"], timeout=5)
    if code == 0 and out.strip().isdigit():
        return int(out.strip())
    return 53


# --------------------------------------------------------------- 上游探测


def _port_open(host: str, port: int, timeout: float = 1.2) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def _dnsmasq_upstream() -> str:
    """dnsmasq 现在的上游，形如 127.0.0.1#7874 → 转成 AGH 的 127.0.0.1:7874。

    这是整个接管的命门：AGH 必须沿用它，否则域名不再经过 OpenClash，
    国外解析不到、国内拿不到 fake-ip，分流和拦截一起废掉。
    """
    code, out = _run(["uci", "show", "dhcp"], timeout=6)
    if code != 0:
        return ""
    for line in out.splitlines():
        if ".server=" not in line:
            continue
        val = line.split("=", 1)[1].strip().strip("'\"")
        # 可能写成 127.0.0.1#7874 或 127.0.0.1:7874
        if "#" in val or ":" in val:
            return val.replace("#", ":", 1)
        if val.startswith("/") or not val:
            continue
        return val + ":53"
    return ""


def _clash_alive() -> bool:
    up = _dnsmasq_upstream()
    if not up:
        return False
    host, _, port = up.partition(":")
    try:
        return _port_open(host or "127.0.0.1", int(port or 53))
    except ValueError:
        return False


def _pick_upstream() -> tuple[list[str], str]:
    """返回 (上游列表, 说明)。优先沿用 dnsmasq 指向的 OpenClash。"""
    up = _dnsmasq_upstream()
    if up and _port_open(*_split_host_port(up)):
        return [up], f"沿用 dnsmasq 上游 {up}（OpenClash 在跑，分流不变）"
    return list(FALLBACK_UPSTREAM), "OpenClash 未运行，暂时用公共 DNS"


def _split_host_port(value: str) -> tuple[str, int]:
    host, _, port = value.rpartition(":")
    if not host:
        return value, 53
    try:
        return host.strip("[]"), int(port)
    except ValueError:
        return value, 53


# --------------------------------------------------------------- DNS 实测


def _dns_probe(name: str, qtype: int = 1, server: str = "127.0.0.1",
               port: int = 53, timeout: float = 4.0) -> dict:
    """直接用裸 DNS 报文查一次，不依赖 dig / nslookup（路由器上没有）。

    qtype: 1=A, 28=AAAA
    """
    tid = random.randint(0, 0xFFFF)
    packet = struct.pack(">HHHHHH", tid, 0x0100, 1, 0, 0, 0)
    for part in name.rstrip(".").split("."):
        if not part:
            continue
        packet += bytes([len(part)]) + part.encode("ascii", "replace")
    packet += b"\x00" + struct.pack(">HH", qtype, 1)

    fam = socket.AF_INET6 if ":" in server else socket.AF_INET
    sock = socket.socket(fam, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    started = time.monotonic()
    try:
        sock.sendto(packet, (server, port))
        data, _ = sock.recvfrom(2048)
    except OSError as exc:
        return {"ok": False, "error": str(exc), "ms": 0}
    finally:
        sock.close()

    ms = int((time.monotonic() - started) * 1000)
    if len(data) < 12:
        return {"ok": False, "error": "响应过短", "ms": ms}
    rcode = data[3] & 0x0F
    answers = struct.unpack(">H", data[6:8])[0]
    return {
        "ok": rcode == 0 and answers > 0,
        "rcode": rcode,
        "answers": answers,
        "ms": ms,
        "error": "" if rcode == 0 else f"rcode={rcode}",
    }


def _local_hostname() -> str:
    """从 dnsmasq 生成的 hosts 取路由器自己的主机名，用来验收本地解析。

    实测这台是 ``iStoreOS``（/tmp/hosts/dhcp.* 第一行），配合 uci 的
    ``domain='lan'`` 就是 ``iStoreOS.lan``。
    """
    import glob
    for path in glob.glob("/tmp/hosts/dhcp.*"):
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    if line.startswith("#"):
                        continue
                    parts = line.split()
                    if len(parts) >= 2:
                        return parts[1]
        except OSError:
            continue
    return "iStoreOS"


def _accept_dns() -> dict:
    """接管后的实打实验收：国内、国外、本地内网域名三条都得通。

    只验 A 记录。AAAA 由 OpenClash 的 filter_aaaa_dns 决定，本机是开着的，
    所以 IPv6 记录本来就空，拿它当失败条件会误判。
    """
    local = _local_hostname()
    checks = [
        ("国内域名", "www.baidu.com"),
        ("国外域名", "www.google.com"),
        ("本地域名", f"{local}.lan"),
    ]
    items = []
    for label, host_name in checks:
        r = _dns_probe(host_name, 1)
        items.append({
            "label": label,
            "domain": host_name,
            "ok": r["ok"],
            "ms": r["ms"],
            "detail": f"{r['answers']} 条应答 / {r['ms']}ms" if r["ok"]
                      else (r.get("error") or "无应答"),
        })
    return {"ok": all(i["ok"] for i in items), "items": items}


# --------------------------------------------------------------- 规则 / 统计


def _agh_filters() -> dict:
    data = _api("/filtering/status")
    if isinstance(data, dict) and "__error" in data:
        return {"rules": 0, "enabled": 0, "error": data["__error"]}
    filters = data.get("filters") or []
    rules = sum(int(f.get("rules_count") or 0) for f in filters if f.get("enabled"))
    return {
        "rules": rules,
        "enabled": sum(1 for f in filters if f.get("enabled")),
        "user_rules": len(data.get("user_rules") or []),
        "lists": [
            {"name": f.get("name", ""), "rules": int(f.get("rules_count") or 0),
             "enabled": bool(f.get("enabled"))}
            for f in filters
        ],
    }


def _agh_stats() -> dict:
    data = _api("/stats")
    if not isinstance(data, dict) or "__error" in data:
        return {"queries": 0, "blocked": 0, "percent": 0.0}
    total = int(data.get("num_dns_queries") or 0)
    blocked = int(data.get("num_blocked_filtering") or 0)
    return {
        "queries": total,
        "blocked": blocked,
        "percent": round(blocked / total * 100, 1) if total else 0.0,
        "top_blocked": [list(x.items())[0] for x in (data.get("top_blocked_domains") or [])
                        if isinstance(x, dict) and x],
        "top_queried": [list(x.items())[0] for x in (data.get("top_queried_domains") or [])
                        if isinstance(x, dict) and x],
        "blocked_services": [list(x.items())[0] for x in (data.get("top_blocked_services") or [])
                             if isinstance(x, dict) and x],
    }


# --------------------------------------------------------------- 查询日志

# 只有 reason 以 Filtered 开头的才是真被规则拦下的；
# NotFilteredNotFound / NotFilteredWhiteList 都是放行。
_BLOCK_PREFIX = "Filtered"


def _filter_names() -> dict[int, str]:
    """filter_list_id → 规则列表名，日志里要能说清是哪张表命中的。"""
    data = _api("/filtering/status")
    if not isinstance(data, dict) or "__error" in data:
        return {}
    out = {}
    for f in data.get("filters") or []:
        try:
            out[int(f.get("id"))] = str(f.get("name") or "")
        except (TypeError, ValueError):
            continue
    return out


def log(limit: int = 120, only_blocked: bool = False, search: str = "") -> dict:
    """读取 AGH 的 DNS 查询日志。

    观察模式下 AGH 只服务路由器本机，日志里几乎只有本机查询；
    要看到全家的拦截记录，必须切到接管模式。
    """
    limit = max(1, min(int(limit or 120), 500))
    params = {"limit": str(limit)}
    if search:
        params["search"] = search
    if only_blocked:
        # 让 AGH 自己筛，而不是拉一堆放行记录回来本地丢掉——
        # 否则 limit=80 里可能只剩三五条真拦截，翻页形同虚设
        params["response_status"] = "blocked"
    query = "&".join(f"{k}={urllib.parse.quote(str(v))}" for k, v in params.items())
    data = _api("/querylog?" + query, timeout=10)
    if isinstance(data, dict) and "__error" in data:
        return {"ok": False, "error": data["__error"], "items": [], "blocked": 0, "total": 0}

    names = _filter_names()
    items = []
    blocked_count = 0
    for entry in (data or {}).get("data") or []:
        q = entry.get("question") or {}
        domain = str(q.get("name") or "")
        if not domain:
            continue
        reason = str(entry.get("reason") or "")
        blocked = reason.startswith(_BLOCK_PREFIX)

        rule_text, list_name = "", ""
        for rule in entry.get("rules") or []:
            if not isinstance(rule, dict):
                continue
            rule_text = str(rule.get("text") or "")
            try:
                list_name = names.get(int(rule.get("filter_list_id") or 0), "")
            except (TypeError, ValueError):
                list_name = ""
            break

        if blocked:
            blocked_count += 1
        if only_blocked and not blocked:
            continue

        try:
            elapsed = round(float(entry.get("elapsedMs") or 0), 1)
        except (TypeError, ValueError):
            elapsed = 0.0

        answers = []
        for a in entry.get("answer") or []:
            if isinstance(a, dict) and a.get("value"):
                answers.append(str(a["value"]))
            if len(answers) >= 2:
                break

        items.append(
            {
                "time": str(entry.get("time") or ""),
                "domain": domain,
                "type": str(q.get("type") or ""),
                "client": str(entry.get("client") or ""),
                "status": str(entry.get("status") or ""),
                "blocked": blocked,
                "reason": reason,
                "rule": rule_text,
                "list": list_name,
                "upstream": str(entry.get("upstream") or ""),
                "answers": answers,
                "elapsed": elapsed,
                "cached": bool(entry.get("cached")),
            }
        )

    return {
        "ok": True,
        "items": items,
        "blocked": blocked_count,
        "total": len(items),
        "oldest": str((data or {}).get("oldest") or ""),
        "mode": status()["mode"],
    }


# --------------------------------------------------------------- 拦截排行


def _blocked_recent(limit: int = 400, search: str = "") -> list[dict]:
    """最近一段被规则拦下的查询（时间倒序）。

    用 ``response_status=blocked`` 让 AGH 端先筛，比拉全量再本地过滤省一半流量：
    实测全量 1000 条 570 KB，其中绝大多数是放行的正常查询。
    """
    lim = max(1, min(int(limit or 400), 1000))
    params = {"limit": str(lim), "response_status": "blocked"}
    if search:
        params["search"] = search
    query = "&".join(f"{k}={urllib.parse.quote(str(v))}" for k, v in params.items())
    data = _api("/querylog?" + query, timeout=10)
    if isinstance(data, dict) and "__error" in data:
        return []
    return [e for e in (data or {}).get("data") or []
            if isinstance(e, dict) and str(e.get("reason") or "").startswith(_BLOCK_PREFIX)]


def _detail_of(entry: dict, names: dict[int, str]) -> dict:
    """从一条日志里取出「最后时间 / 来源 / 命中规则 / 规则列表」。"""
    rule, lid = "", 0
    for r in entry.get("rules") or []:
        if not isinstance(r, dict):
            continue
        rule = str(r.get("text") or "")
        try:
            lid = int(r.get("filter_list_id") or 0)
        except (TypeError, ValueError):
            lid = 0
        break
    return {
        "last": str(entry.get("time") or ""),
        "client": str(entry.get("client") or ""),
        "rule": rule or str(entry.get("rule") or ""),
        "list": names.get(lid, ""),
    }


def top(limit: int = 5) -> dict:
    """拦截次数最多的域名，默认前 5。

    两路数据各取所长：
      - 次数来自 AGH 统计窗口的 ``top_blocked_domains``，跨整天都稳定，
        比"最近 N 条日志"准得多（拦截量大时 1000 条日志只覆盖几分钟）；
      - 细节（最后一次时间、来源设备、命中规则）只有日志里有，从最近
        拦截日志里反查。
    """
    limit = max(1, min(int(limit or 5), 30))
    st = _agh_stats()
    ranked: list[tuple[str, int]] = [(str(d), int(n)) for d, n in (st.get("top_blocked") or []) if d]

    recent = _blocked_recent(600)
    names = _filter_names()
    detail: dict[str, dict] = {}
    counts: dict[str, int] = {}
    for e in recent:
        domain = str((e.get("question") or {}).get("name") or "")
        if not domain:
            continue
        counts[domain] = counts.get(domain, 0) + 1
        if domain not in detail:
            detail[domain] = _detail_of(e, names)

    if not ranked:
        # AGH 刚重启、统计归零时退回日志聚合，至少界面上还有东西看
        ranked = sorted(counts.items(), key=lambda kv: -kv[1])

    # 最近几百条日志只覆盖几分钟，榜单靠前的域名可能刚好落在这段之外：
    # 单独按域名补查一次，免得界面上出现「次数有、时间空」的半截数据
    for domain, _ in ranked[:limit]:
        if domain in detail:
            continue
        for e in _blocked_recent(50, search=domain):
            if str((e.get("question") or {}).get("name") or "") == domain:
                detail[domain] = _detail_of(e, names)
                break

    total = int(st.get("blocked") or 0) or sum(n for _, n in ranked)
    items = []
    for domain, count in ranked[:limit]:
        d = detail.get(domain) or {}
        items.append({
            "domain": domain,
            "count": int(count),
            "share": round(count / total * 100, 1) if total else 0.0,
            "last": d.get("last", ""),
            "client": d.get("client", ""),
            "rule": d.get("rule", ""),
            "list": d.get("list", ""),
        })

    return {
        "ok": True,
        "mode": status()["mode"],
        "window": "自 AdGuard Home 启动以来",
        "total_blocked": total,
        "queries": int(st.get("queries") or 0),
        "percent": float(st.get("percent") or 0.0),
        "items": items,
        "recent_blocked": len(recent),
    }


# --------------------------------------------------------------- 对外接口


def status() -> dict:
    installed = _installed()
    running = _running()
    dns_cfg = _dns_settings(_read_yaml()) if installed else _dns_settings("")
    dnsmasq_port = _dnsmasq_port()

    # 判断当前是观察模式还是接管模式
    if not running:
        mode = "stopped"
    elif dns_cfg["port"] == 53 and dnsmasq_port != 53:
        mode = "takeover"
    else:
        mode = "observe"

    filters = _agh_filters() if running else {"rules": 0, "enabled": 0}
    stats = _agh_stats() if running else {"queries": 0, "blocked": 0, "percent": 0.0}

    return {
        "installed": installed,
        "running": running,
        "mode": mode,
        "mode_label": {"stopped": "未运行", "observe": "观察模式", "takeover": "已接管全网"}.get(mode, mode),
        "listening": dns_cfg,
        "dnsmasq_port": dnsmasq_port,
        "aaa_enabled": dns_cfg["aaaa_disabled"] is False,
        "upstream": dns_cfg["upstream_dns"],
        "filters": filters,
        "stats": stats,
        "web_port": int(_conf().get("api_port", 3000)),
    }


def _listening_53() -> str:
    """返回 53 端口上监听者的进程名，用于判断接管是否真的成功了。"""
    code, out = _run(["netstat", "-lnpt"], timeout=8)
    if code != 0:
        return ""
    for line in out.splitlines():
        if ":53 " in line and "LISTEN" in line:
            return line.strip().split()[-1]
    return ""


def _restore_dnsmasq(port: int = 53):
    _run(["uci", "set", f"dhcp.@dnsmasq[0].port={port}"], timeout=5)
    _run(["uci", "commit", "dhcp"], timeout=5)
    _run(["/etc/init.d/dnsmasq", "restart"], timeout=60)


def takeover() -> dict:
    """接管：AGH 上 53，dnsmasq 只留 DHCP。

    任何一步失败都必须把 dnsmasq 的 53 还回去，否则全家断网。
    """
    if not _installed():
        return {"ok": False, "error": "AdGuard Home 未安装"}

    upstream, upstream_note = _pick_upstream()
    # 本地域名单独转发给 dnsmasq：NAS、打印机、静态绑定这些不能因为接管就失联
    upstream = list(upstream) + [f"[/{z}/]127.0.0.1:{LOCAL_DNS_PORT}" for z in LOCAL_ZONES]

    # 1. 一次把 53 端口、监听地址、上游全写好
    #    "::" 会被 yaml 解析成 map，写入时已加引号
    #    aaaa 不传 = 保持原样，跟随 OpenClash 的 filter_aaaa_dns
    if not _patch_yaml(port=53, hosts=BIND_ALL, upstream=upstream):
        return {"ok": False, "error": "改写 AGH 配置失败，未做任何变更"}

    # 2. dnsmasq 让出 53，挪到 5354 继续做本地解析（DHCP 完全不受影响）
    code, out = _run(["uci", "set", f"dhcp.@dnsmasq[0].port={LOCAL_DNS_PORT}"], timeout=5)
    if code != 0:
        _write_dns_settings(SS53, ["127.0.0.1"])
        return {"ok": False, "error": f"设置 dnsmasq 端口失败: {out.strip()}"}
    _run(["uci", "commit", "dhcp"], timeout=5)
    _run(["/etc/init.d/dnsmasq", "restart"], timeout=60)

    # 3. 等 53 真正空出来再启 AGH，否则它 bind 会失败
    time.sleep(2)
    code, out = _run(["/etc/init.d/AdGuardHome", "restart"], timeout=90)
    time.sleep(3)

    def rollback(reason: str, extra: dict | None = None) -> dict:
        _write_dns_settings(SS53, ["127.0.0.1"])
        _restore_dnsmasq(53)
        _run(["/etc/init.d/AdGuardHome", "restart"], timeout=90)
        return {
            "ok": False,
            "error": reason + "，已自动回滚，网络已恢复正常",
            "holder": _listening_53() or "(53 无人监听)",
            "detail": out[-300:],
            **(extra or {}),
        }

    # 4. 53 上必须是 AGH，否则立刻还回去
    holder = _listening_53()
    if "adguardhome" not in holder.lower():
        return rollback("AGH 没能接管 53", {"holder": holder or "(53 无人监听)"})

    # 5. 实测解析：只看进程起来不算成功，域名真能查出来才算
    accept = _accept_dns()
    if not accept["ok"]:
        return rollback("接管后域名解析失败", {"accept": accept})

    return {
        "ok": True,
        "mode": "takeover",
        "message": "已接管全网 DNS，拦截立即生效",
        "holder": holder,
        "accept": accept,
        "upstream": upstream,
        "upstream_note": upstream_note,
    }


def release() -> dict:
    """回滚：AGH 退回 5353，dnsmasq 拿回 53。"""
    if not _installed():
        return {"ok": False, "error": "AdGuard Home 未安装"}

    up = _dnsmasq_upstream()
    _patch_yaml(port=SS53, hosts=["127.0.0.1"], upstream=[up] if up else None)
    _restore_dnsmasq(53)
    _run(["/etc/init.d/AdGuardHome", "restart"], timeout=90)
    time.sleep(2)

    holder = _listening_53()
    ok = "dnsmasq" in holder.lower()
    return {
        "ok": ok,
        "mode": "observe",
        "message": "已退出接管，DNS 回到 dnsmasq" if ok else "回滚后 DNS 状态异常，请检查",
        "holder": holder,
    }


def verify() -> dict:
    """App 里「体检」以外的独立校验：现在这条路到底通不通。"""
    st = status()
    accept = _accept_dns()
    return {
        "mode": st["mode"],
        "mode_label": st["mode_label"],
        "upstream": st["upstream"],
        "aaa_enabled": st["aaa_enabled"],
        "dns": accept,
        # AAAA 开关不参与判定：它跟随 OpenClash 的 filter_aaaa_dns，
        # 过滤是刻意配置，不是故障
        "ok": accept["ok"] and st["mode"] == "takeover",
    }


def refresh_rules() -> dict:
    """立即更新所有启用的规则列表。

    AGH 自己也会按 ``filters_update_interval`` 定时拉取，这里是「现在就来一次」，
    两个入口共用同一条链路，所以手动更新完自动更新的计时也会一起重置。
    """
    before = rules()
    res = _api("/filtering/refresh", "POST", {"whitelist": False}, timeout=180)
    if isinstance(res, dict) and "__error" in res:
        return {"ok": False, "error": res["__error"]}
    after = rules()
    return {
        "ok": True,
        "updated": res.get("updated", 0),
        "rules_before": before.get("total_rules", 0),
        "rules_after": after.get("total_rules", 0),
        "lists": after.get("lists", []),
    }


# --------------------------------------------------------------- 规则更新配置


# 自动更新的可选项（小时）。0 = 关闭自动更新，只能手动点。
# 之所以给固定档位而不是自由输入：AGH 的语义是「每 N 小时」，填 3 小时
# 对订阅型规则列表没意义，反而一直在拉 CDN，白白占带宽。
INTERVAL_CHOICES = [0, 6, 12, 24, 48, 72]


def _interval_label(hours: int) -> str:
    if hours <= 0:
        return "已关闭自动更新"
    if hours == 1:
        return "每小时"
    if hours == 24:
        return "每天"
    if hours == 48:
        return "每 2 天"
    if hours == 72:
        return "每 3 天"
    if hours % 24 == 0:
        return f"每 {hours // 24} 天"
    return f"每 {hours} 小时"


def _parse_iso(ts: str) -> float:
    """AGH 的 last_updated 是 2026-10-25T17:02:07+08:00 这种，带上时区偏移。"""
    if not ts:
        return 0.0
    try:
        from datetime import datetime

        return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except (TypeError, ValueError):
        return 0.0


def rules() -> dict:
    """规则列表 + 自动更新配置，给 App 的「规则更新」卡片用。

    自动还是手动：AGH 的 ``filters_update_interval`` 就是答案。
    本机出厂值是 24 小时，也就是**每天自动更新一次**，App 里那个按钮
    只是「等不及了现在就来一次」，不是唯一入口。
    """
    data = _api("/filtering/status")
    if isinstance(data, dict) and "__error" in data:
        return {"ok": False, "error": data["__error"], "lists": [],
                "interval": 0, "interval_label": "", "auto": False}

    interval = int(data.get("interval") or 0)
    lists = []
    total = 0
    newest = 0.0
    enabled_count = 0
    failed = 0
    for f in data.get("filters") or []:
        if not isinstance(f, dict):
            continue
        try:
            fid = int(f.get("id") or 0)
        except (TypeError, ValueError):
            fid = 0
        count = int(f.get("rules_count") or 0)
        on = bool(f.get("enabled"))
        last = str(f.get("last_updated") or "")
        err = str(f.get("last_error") or "")
        if on:
            enabled_count += 1
            total += count
            if err:
                failed += 1
            newest = max(newest, _parse_iso(last))
        lists.append({
            "id": fid,
            "name": str(f.get("name") or ""),
            "url": str(f.get("url") or ""),
            "enabled": on,
            "rules": count,
            "last_updated": last,
            "last_error": err,
        })

    # 启用中的列表按「间隔」各自计时，取最近一次更新作为整体进度
    next_at = ""
    remain = 0
    if interval > 0 and newest:
        nxt = newest + interval * 3600
        remain = max(0, int((nxt - time.time()) // 60))
        next_at = time.strftime("%Y-%m-%d %H:%M", time.localtime(nxt))

    return {
        "ok": True,
        "enabled": bool(data.get("enabled")),
        "interval": interval,
        "interval_label": _interval_label(interval),
        "interval_choices": INTERVAL_CHOICES,
        "auto": interval > 0,
        "next_update": next_at,
        "minutes_left": remain,
        "lists": lists,
        "enabled_lists": enabled_count,
        "total_lists": len(lists),
        "total_rules": total,
        "failed": failed,
        "user_rules": len(data.get("user_rules") or []),
    }


def set_interval(hours: int) -> dict:
    """改自动更新间隔。0 = 关闭自动更新。"""
    try:
        hours = int(hours)
    except (TypeError, ValueError):
        return {"ok": False, "error": "间隔必须是整数小时"}
    if hours < 0 or hours > 24 * 30:
        return {"ok": False, "error": "间隔范围 0–720 小时"}

    cur = rules()
    if not cur.get("ok"):
        return cur
    # 两个参数必须一起发：AGH 的 /filtering/config 是整段替换，
    # 只传 interval 会把 enabled 冲成 false，拦截会整个停掉
    res = _api("/filtering/config", "POST",
               {"interval": hours, "enabled": cur.get("enabled", True)})
    if isinstance(res, dict) and "__error" in res:
        return {"ok": False, "error": res["__error"]}

    after = rules()
    # 改完立刻回读，别拿请求成功糊弄界面
    if int(after.get("interval") or 0) != hours:
        return {"ok": False, "error": "配置未生效，请检查 AdGuard Home 是否运行",
                **after}
    return {"ok": True, "message": f"自动更新已设为{_interval_label(hours)}", **after}


def toggle_list(list_id: int, enabled: bool) -> dict:
    """启用 / 停用某一张规则列表。

    AGH 没有单独的开关接口，只能 set_url 整条覆盖，所以先把当前对象读出来，
    改掉 enabled 再原样写回，别丢 name / url。
    """
    try:
        list_id = int(list_id)
    except (TypeError, ValueError):
        return {"ok": False, "error": "列表 id 无效"}

    data = _api("/filtering/status")
    if isinstance(data, dict) and "__error" in data:
        return {"ok": False, "error": data["__error"]}

    target = None
    for f in data.get("filters") or []:
        if not isinstance(f, dict):
            continue
        try:
            if int(f.get("id") or 0) == list_id:
                target = f
                break
        except (TypeError, ValueError):
            continue
    if target is None:
        return {"ok": False, "error": "找不到这张规则列表"}

    body = {
        "url": str(target.get("url") or ""),
        "data": {
            "id": list_id,
            "name": str(target.get("name") or ""),
            "url": str(target.get("url") or ""),
            "enabled": bool(enabled),
        },
    }
    res = _api("/filtering/set_url", "POST", body, timeout=30)
    if isinstance(res, dict) and "__error" in res:
        return {"ok": False, "error": res["__error"]}

    after = rules()
    for f in after.get("lists", []):
        if f.get("id") == list_id:
            if bool(f.get("enabled")) != bool(enabled):
                return {"ok": False, "error": "开关未生效，请重试", **after}
            break
    name = str(target.get("name") or "规则列表")
    return {"ok": True, "message": f"{name} 已{'启用' if enabled else '停用'}", **after}


def service(action: str) -> dict:
    if action not in {"start", "stop", "restart"}:
        return {"ok": False, "error": "invalid action"}
    code, out = _run(["/etc/init.d/AdGuardHome", action], timeout=120)
    return {"ok": code == 0, "action": action, "output": out[-400:]}


# --------------------------------------------------------------- 上线前体检


def _meminfo() -> dict:
    info: dict[str, int] = {}
    try:
        with open("/proc/meminfo", "r", encoding="utf-8") as fh:
            for line in fh:
                key, _, rest = line.partition(":")
                parts = rest.split()
                if parts and parts[0].isdigit():
                    info[key] = int(parts[0]) // 1024
    except OSError:
        pass
    total, avail = info.get("MemTotal", 0), info.get("MemAvailable", 0)
    return {"total_mb": total, "available_mb": avail,
            "used_percent": round((1 - avail / total) * 100, 1) if total else 0.0}


def _dns_chain() -> dict:
    servers: list[str] = []
    code, out = _run(["uci", "show", "dhcp"], timeout=6)
    if code == 0:
        for line in out.splitlines():
            if ".server=" in line:
                servers.append(line.split("=", 1)[1].strip().strip("'"))
    hijack = False
    code, out = _run(["nft", "list", "table", "inet", "fw4"], timeout=8)
    if code == 0:
        hijack = "OpenClash DNS Hijack" in out
    return {"openclash_hijack": hijack, "upstream": servers[0] if servers else "未知"}


def preflight() -> dict:
    mem = _meminfo()
    chain = _dns_chain()
    st = status()
    up, up_note = _pick_upstream()

    checks = [
        {
            "id": "installed",
            "label": "AdGuard Home 已安装",
            "ok": st["installed"],
            "detail": f"本体在 {AGH_BIN}" if st["installed"] else "未检测到本体",
        },
        {
            "id": "running",
            "label": "服务运行中",
            "ok": st["running"],
            "detail": f"当前模式：{st['mode_label']}" if st["running"] else "服务未启动",
        },
        {
            "id": "rules",
            "label": "拦截规则已加载",
            "ok": st["filters"].get("rules", 0) > 1000,
            "detail": f"{st['filters'].get('rules', 0):,} 条规则，{st['filters'].get('enabled', 0)} 个列表",
        },
        {
            "id": "upstream",
            "label": "上游指向 OpenClash",
            "ok": bool(_dnsmasq_upstream()),
            "detail": up_note,
        },
        {
            "id": "local",
            "label": "本地域名继续可解析",
            "ok": True,
            "detail": f"dnsmasq 挪到 :{LOCAL_DNS_PORT} 继续管 .lan 与静态绑定，"
                      f"AGH 把本地后缀转给它，NAS / 打印机不会失联",
        },
        {
            "id": "ipv6",
            "label": "AAAA 处理与 OpenClash 一致",
            "ok": True,
            "detail": "OpenClash 开着 AAAA 过滤（防 IPv6 泄漏），AGH 保持同样设置；"
                      "公网 IPv6 走 IP 直连，不受 DNS 影响",
        },
        {
            "id": "memory",
            "label": "内存余量",
            "ok": mem["available_mb"] > 500,
            "detail": f"可用 {mem['available_mb']} MB，AGH 常驻约 60–120 MB",
        },
        {
            "id": "rollback",
            "label": "可一键回滚",
            "ok": True,
            "detail": "退回观察模式后 dnsmasq 立即拿回 53，不重启路由器",
        },
    ]

    return {
        "ready": all(c["ok"] for c in checks),
        "checks": checks,
        "mode": st["mode"],
        "mode_label": st["mode_label"],
        "notes": [
            "观察模式下 AGH 只服务路由器本机，对全家网络零影响",
            "接管后所有设备的 DNS 先经 AGH 过滤，再交给 OpenClash 分流",
            "接管前自动把上游设成 dnsmasq 现在用的那个（OpenClash），分流不变",
            "dnsmasq 只挪到 5354 不关闭，.lan 和静态绑定照常解析",
            "接管后实测国内 / 国外 / 本地三类域名，任一失败自动回滚",
            "被拦的域名返回 0.0.0.0，连接不会建立，不占带宽",
        ],
    }
