"""OpenClash / Mihomo 控制。通过本地 Clash external-controller 与 ubus 交互。"""

from __future__ import annotations

import json
import subprocess
import urllib.error
import urllib.parse
import urllib.request

from .config import get as cfg


def _last_delay(node: dict) -> int | None:
    """取节点最近一次测速的延迟。

    Clash 的 history 是一个数组，每项形如 {"time": ..., "delay": 120}；
    空数组或没有 delay 字段都返回 None（= 没测过），不要当成 0（= 超时）。
    """
    hist = node.get("history") or []
    if not hist:
        return None
    return hist[-1].get("delay")


def _base() -> str:
    c = cfg("clash", {})
    host = c.get("controller_host", "127.0.0.1")
    port = int(c.get("controller_port", 9090))
    return f"http://{host}:{port}"


def _secret() -> str:
    return cfg("clash", {}).get("secret", "")


def _req(path: str, method: str = "GET", body: dict | None = None, timeout: float = 6.0):
    url = _base() + path
    data = None
    headers = {"Content-Type": "application/json"}
    if _secret():
        headers["Authorization"] = f"Bearer {_secret()}"
    if body is not None:
        data = json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            if not raw:
                return {}
            return json.loads(raw.decode("utf-8", "replace"))
    except urllib.error.HTTPError as exc:
        return {"__error": f"HTTP {exc.code}", "__status": exc.code}
    except (urllib.error.URLError, OSError, json.JSONDecodeError) as exc:
        return {"__error": str(exc), "__status": 0}


def _uci(section: str) -> str:
    try:
        out = subprocess.run(["uci", "get", f"openclash.{section}"],
                             capture_output=True, timeout=4, check=False)
        return out.stdout.decode("utf-8", "replace").strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def service_running() -> tuple[bool, int]:
    try:
        out = subprocess.run(
            ["ubus", "call", "service", "list", '{"name":"openclash"}'],
            capture_output=True, timeout=5, check=False,
        )
        data = json.loads(out.stdout.decode("utf-8", "replace") or "{}")
        inst = data.get("openclash", {}).get("instances", {})
        for item in inst.values():
            if item.get("running"):
                return True, int(item.get("pid", 0))
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
        pass
    return False, 0


def status() -> dict:
    running, pid = service_running()
    version = _req("/version")
    configs = _req("/configs")
    return {
        "enabled": _uci("config.enable") == "1",
        "running": running,
        "pid": pid,
        "core": _uci("config.core_type"),
        "mode_engine": _uci("config.en_mode"),
        "controller_port": _uci("config.cn_port"),
        "version": version.get("version") if isinstance(version, dict) else None,
        "meta": version.get("meta") if isinstance(version, dict) else None,
        "mode": configs.get("mode") if isinstance(configs, dict) else None,
        "log_level": configs.get("log-level") if isinstance(configs, dict) else None,
        "mixed_port": configs.get("mixed-port") if isinstance(configs, dict) else None,
        "tun": (configs.get("tun") or {}).get("enable") if isinstance(configs, dict) else None,
        "allow_lan": configs.get("allow-lan") if isinstance(configs, dict) else None,
        "reachable": not (isinstance(configs, dict) and configs.get("__error")),
    }


_INFO_PREFIXES = ("剩余流量", "距离下次", "套餐到期", "到期时间", "官网", "订阅", "重置")


def _is_info(name: str) -> bool:
    """订阅里混进来的信息条目（流量余量、到期日）不是真节点，界面上要过滤掉。"""
    return any(name.startswith(p) for p in _INFO_PREFIXES)


def proxies() -> dict:
    data = _req("/proxies")
    if not isinstance(data, dict) or "proxies" not in data:
        return {"groups": [], "error": (data or {}).get("__error", "unavailable")}

    raw = data["proxies"]

    def is_group(p: dict) -> bool:
        return p.get("type", "").lower() in {
            "selector", "urltest", "fallback", "loadbalance", "relay", "smart",
        }

    groups = []
    for name, p in raw.items():
        if not is_group(p):
            continue
        now = p.get("now", "")
        # 订阅常塞一些「剩余流量：xxx GB」「距离下次重置：x 天」的伪节点，
        # 它们既不是节点也不能连。被选成当前节点时如果照实显示，
        # 界面会以为流量走了个叫「剩余流量」的东西，这里直接算作未选。
        now_info = bool(now) and _is_info(now)
        if now_info:
            now = ""
        members = []
        for m in p.get("all", []) or []:
            if _is_info(m):
                continue
            child = raw.get(m, {})
            members.append(
                {
                    "name": m,
                    "type": child.get("type", ""),
                    "is_group": is_group(child),
                    "delay": _last_delay(child),
                    "udp": child.get("udp"),
                }
            )
        # 当前选中项若被当作信息条目过滤掉了，仍要放回列表，否则界面看不出选中了谁
        if now and now in raw and not any(m["name"] == now for m in members):
            child = raw[now]
            members.insert(0, {
                "name": now,
                "type": child.get("type", ""),
                "is_group": is_group(child),
                "delay": (child.get("history") or [{}])[-1].get("delay") if child.get("history") else None,
                "udp": child.get("udp"),
                "info": True,
            })

        groups.append(
            {
                "name": name,
                "type": p.get("type", ""),
                "now": now,
                "now_valid": bool(now),
                "now_info": now_info,
                "now_delay": _last_delay(raw.get(now, {})),
                "members": members,
            }
        )
    node_count = sum(1 for n, p in raw.items() if not is_group(p) and not _is_info(n))
    return {"groups": groups, "node_count": node_count, "error": None}


def select(group: str, name: str) -> dict:
    path = "/proxies/" + urllib.parse.quote(group, safe="")
    res = _req(path, method="PUT", body={"name": name})
    if isinstance(res, dict) and res.get("__error"):
        return {"ok": False, "error": res["__error"]}
    return {"ok": True, "group": group, "name": name}


def _delay_reason(raw: str) -> str:
    """把 Mihomo 的报错翻成人话。

    节点不通时它回 503，原来的实现直接把 "HTTP 503" 甩到界面上 ——
    用户既不知道这是什么意思，也不知道该做什么。这里换成可操作的说明，
    原始串留在 raw 里给排查用。
    """
    low = (raw or "").lower()
    if "503" in low or "timeout" in low or "timed out" in low:
        return "节点连不上（超时）"
    if "404" in low:
        return "内核里没有这个节点，配置可能刚换过"
    if "401" in low or "403" in low:
        return "内核拒绝了请求（API 密钥不对）"
    if "connect" in low or "refused" in low:
        return "连不上内核，OpenClash 可能没在跑"
    return raw or "测速失败"


def delay(name: str, url: str = "", timeout_ms: int = 5000) -> dict:
    """单节点测速。一个地址全失败时换一个再试。

    gstatic 是国内最常见的默认值，但实测在部分机场/线路上完全不可达 ——
    节点其实是好的，只是这个 204 拿不到，界面就会把整排节点判成「超时」。
    """
    target = url or delay_url()
    res = _one_delay(name, target, timeout_ms)
    if not res.get("ok") and not url:
        alt = delay_url(alt=True)
        if alt != target:
            res2 = _one_delay(name, alt, timeout_ms)
            if res2.get("ok"):
                return res2
    return res


def _one_delay(name: str, url: str, timeout_ms: int) -> dict:
    q = urllib.parse.urlencode({"url": url, "timeout": timeout_ms})
    path = "/proxies/" + urllib.parse.quote(name, safe="") + "/delay?" + q
    res = _req(path, timeout=timeout_ms / 1000 + 2)
    if isinstance(res, dict) and "delay" in res:
        return {"ok": True, "delay": res["delay"], "url": url}
    raw = (res or {}).get("__error", "timeout")
    return {"ok": False, "error": _delay_reason(raw), "raw": raw, "url": url}


def delay_url(alt: bool = False) -> str:
    """测速用的探测地址。配置可覆盖；alt=True 时给备份地址。"""
    if not alt:
        return cfg("clash", {}).get("delay_url", "http://www.gstatic.com/generate_204")
    return cfg("clash", {}).get("delay_url_alt", "https://cp.cloudflare.com/generate_204")


def group_delay(group: str, url: str = "", timeout_ms: int = 3000) -> dict:
    """整组测速：Mihomo 的 /group/{name}/delay 一次把所有成员打完，返回 {节点名: 毫秒}。

    比逐个 /proxies/{name}/delay 快一个数量级，65 个节点一次两三秒就够。
    """
    target = url or delay_url()
    res = _one_group_delay(group, target, timeout_ms)
    alive = [v for v in (res.get("delays") or {}).values() if v > 0]
    if not alive and not url:
        # 一个都不通时换备份地址再打一次。全 0 有两种可能：节点真的挂了，
        # 或者这个 204 地址在这条线路上不可达 —— 后者换一个就能区分开
        alt = delay_url(alt=True)
        if alt != target:
            res2 = _one_group_delay(group, alt, timeout_ms)
            if any(v > 0 for v in (res2.get("delays") or {}).values()):
                res2["retried"] = True
                return res2
    return res


def _one_group_delay(group: str, target: str, timeout_ms: int) -> dict:
    q = urllib.parse.urlencode({"url": target, "timeout": timeout_ms})
    path = "/group/" + urllib.parse.quote(group, safe="") + "/delay?" + q
    res = _req(path, timeout=timeout_ms / 1000 + 18)
    if isinstance(res, dict) and res.get("__error"):
        raw = res["__error"]
        # 504 是 Mihomo 把整组成员都等完、一个都没通之后才回的。这跟「请求根本
        # 发不出去」不是一回事：节点确实全不通，得照样把成员补成 0，界面才能标
        # 「超时」。否则点完测速列表一动不动，只剩一句转眼就没的 toast。
        if (res.get("__status") or 0) == 504:
            dead = {name: 0 for name in _group_members(group)}
            if dead:
                return {"ok": True, "delays": dead, "all_dead": True}
        return {"ok": False, "error": _delay_reason(raw), "raw": raw, "delays": {}}
    delays = {}
    for name, ms in (res or {}).items():
        if isinstance(ms, (int, float)):
            delays[name] = int(ms)
    if not delays:
        return {"ok": False, "error": "测速无结果", "delays": {}}
    # Mihomo 对测不通的成员直接不返回，界面于是分不清「这次测了但不通」和
    # 「从来没测过」——点完测速那一行什么都不变，看着像没反应。
    # 按成员表补成 0，客户端就能标「超时」。
    for name in _group_members(group):
        delays.setdefault(name, 0)
    return {"ok": True, "delays": delays}


def _group_members(group: str) -> list[str]:
    """组的成员名单。取不到就返回空表，不影响测速结果本身。"""
    data = _req("/proxies/" + urllib.parse.quote(group, safe=""))
    if isinstance(data, dict):
        return [str(x) for x in (data.get("all") or [])]
    return []


def connections() -> dict:
    data = _req("/connections")
    if not isinstance(data, dict) or "connections" not in data:
        return {"connections": [], "download_total": 0, "upload_total": 0,
                "error": (data or {}).get("__error", "unavailable")}
    items = []
    for c in data.get("connections") or []:
        meta = c.get("metadata") or {}
        items.append(
            {
                "id": c.get("id"),
                "host": meta.get("host") or meta.get("destinationIP", ""),
                "destination": f"{meta.get('destinationIP', '')}:{meta.get('destinationPort', '')}",
                "network": meta.get("network"),
                "source": meta.get("sourceIP", ""),
                "source_port": meta.get("sourcePort", 0),
                "destination_ip": meta.get("destinationIP", ""),
                "destination_port": meta.get("destinationPort", 0),
                "process": meta.get("processPath") or meta.get("process") or "",
                "rule": c.get("rule"),
                "rule_payload": c.get("rulePayload"),
                "chains": c.get("chains") or [],
                "upload": c.get("upload", 0),
                "download": c.get("download", 0),
                "start": c.get("start"),
            }
        )
    return {
        "connections": items,
        "download_total": data.get("downloadTotal", 0),
        "upload_total": data.get("uploadTotal", 0),
        "error": None,
    }


def set_mode(mode: str) -> dict:
    if mode not in {"rule", "global", "direct"}:
        return {"ok": False, "error": "invalid mode"}
    res = _req("/configs", method="PATCH", body={"mode": mode})
    if isinstance(res, dict) and res.get("__error"):
        return {"ok": False, "error": res["__error"]}
    return {"ok": True, "mode": mode}


ALLOWED_ACTIONS = {"start", "stop", "restart"}


def service(action: str) -> dict:
    if action not in ALLOWED_ACTIONS:
        return {"ok": False, "error": "invalid action"}
    try:
        proc = subprocess.run(
            ["/etc/init.d/openclash", action],
            capture_output=True, timeout=90, check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return {"ok": False, "error": str(exc)}
    return {
        "ok": proc.returncode == 0,
        "action": action,
        "code": proc.returncode,
        "output": (proc.stdout + proc.stderr).decode("utf-8", "replace")[-800:],
    }
