"""代理后端抽象层。

路由器上可能同时装着 OpenClash 和 Passwall，两者互斥运行：
  - OpenClash 有 external-controller，可以实时查询与热切换
  - Passwall 没有运行时 API，只能读 uci 配置 + 重启服务生效

本模块把两者的差异吃掉，对外只给一套模型：
  backend  = openclash | passwall
  group    = 策略组（clash 的 selector / passwall 的节点分组）
  select   = 切换当前节点
"""

from __future__ import annotations

import json
import os
import subprocess
import time

from . import clash

INIT = {
    "openclash": "/etc/init.d/openclash",
    "passwall": "/etc/init.d/passwall",
}

LABEL = {"openclash": "OpenClash", "passwall": "Passwall"}

_socks_port = {"openclash": 7891, "passwall": 1070}


# --------------------------------------------------------------- 基础工具


def _run(args: list[str], timeout: float = 8.0) -> tuple[int, str]:
    try:
        p = subprocess.run(args, capture_output=True, timeout=timeout, check=False)
        return p.returncode, (p.stdout + p.stderr).decode("utf-8", "replace")
    except (OSError, subprocess.SubprocessError) as exc:
        return 1, str(exc)


def _uci_get(key: str) -> str:
    code, out = _run(["uci", "get", key], timeout=4)
    return out.strip() if code == 0 else ""


def _uci_show(pkg: str) -> dict[str, str]:
    """展开 `uci show` 为 {section.option: value} 扁平表。"""
    code, out = _run(["uci", "show", pkg], timeout=6)
    if code != 0:
        return {}
    flat: dict[str, str] = {}
    for line in out.splitlines():
        if "=" not in line:
            continue
        key, _, raw = line.partition("=")
        flat[key.strip()] = raw.strip().strip("'")
    return flat


def _installed(backend: str) -> bool:
    import os

    return os.path.exists(INIT[backend])


def _service_running(backend: str) -> bool:
    code, out = _run(
        ["ubus", "call", "service", "list", json.dumps({"name": backend})], timeout=5
    )
    if code == 0:
        try:
            data = json.loads(out or "{}")
            instances = data.get(backend, {}).get("instances") or {}
            for item in instances.values():
                if item.get("running"):
                    return True
            if instances:
                return False
        except json.JSONDecodeError:
            pass
    # Passwall 是 legacy init，未必有 procd 实例，用它的运行目录兜底。
    # 不能用 "xray|passwall" 这类宽泛匹配，会把本进程自己的命令行也命中。
    if backend == "passwall":
        code, out = _run(["pgrep", "-f", "/tmp/etc/passwall"], timeout=4)
        return code == 0 and bool(out.strip())
    return False


# --------------------------------------------------------------- Passwall 适配


def _pw_is_info(node: dict) -> bool:
    """订阅导入时会混进「组名:订阅地址」这类信息条目，不是真节点。"""
    name = node.get("name", "")
    return "://" in name or (
        ":" in name and name.split(":", 1)[1].startswith(("http", "//"))
    )


def _passwall_nodes(flat: dict[str, str]) -> list[dict]:
    """把 uci 里 type=nodes 的 section 还原成节点对象。

    uci 展平后形如 ``passwall.J8phxtIP.flow = 'xtls-rprx-vision'``，
    必须按前两个点切成 pkg / section / option，不能只切一次。
    """
    nodes: dict[str, dict] = {}
    for key, value in flat.items():
        parts = key.split(".", 2)
        if len(parts) < 2 or parts[0] != "passwall":
            continue
        section = parts[1]
        if flat.get(f"passwall.{section}") != "nodes":
            continue
        node = nodes.setdefault(section, {"id": section})
        if len(parts) > 2:
            node[parts[2]] = value

    out = []
    for node in nodes.values():
        # 只保留展示与测速需要的字段，uuid / publicKey 等敏感项不外泄
        out.append(
            {
                "id": node.get("id", ""),
                "name": node.get("remarks") or node.get("id", ""),
                "type": node.get("type", ""),
                "protocol": node.get("protocol", ""),
                "group": node.get("group") or "未分组",
                "address": node.get("address", ""),
                "port": node.get("port", ""),
            }
        )
    return [n for n in out if not _pw_is_info(n)]


def _passwall_state(flat: dict[str, str]) -> dict:
    global_sec = ""
    for key, value in flat.items():
        if value == "global" and key.startswith("passwall."):
            global_sec = key.split(".", 1)[1]
            break
    enabled = flat.get(f"passwall.{global_sec}.enabled", "0") == "1"
    current = flat.get(f"passwall.{global_sec}.tcp_node", "")
    nodes = _passwall_nodes(flat)
    current_name = next((n["name"] for n in nodes if n["id"] == current), current)
    return {
        "enabled": enabled,
        "current_id": current,
        "current": current_name,
        "nodes": nodes,
    }


def _passwall_groups(nodes: list[dict], current_id: str) -> dict:
    """Passwall 没有 selector 概念，按节点的 group 字段聚成「分组」，
    当前选中的节点所在的组，其 now 就是当前节点。"""
    buckets: dict[str, list[dict]] = {}
    for node in nodes:
        buckets.setdefault(node["group"], []).append(node)

    groups = []
    for name, members in sorted(buckets.items(), key=lambda kv: (-len(kv[1]), kv[0])):
        now = next((m["name"] for m in members if m["id"] == current_id), "")
        groups.append(
            {
                "name": name,
                "type": "group",
                "now": now,
                "members": [
                    {"name": m["name"], "type": m["protocol"] or m["type"], "is_group": False,
                     "delay": None, "udp": None, "id": m["id"]}
                    for m in members
                ],
            }
        )
    return {"groups": groups, "node_count": len(nodes), "error": None}


# --------------------------------------------------------------- 统一模型


def backends() -> list[dict]:
    """列出两端后端的安装 / 启用 / 运行状态。"""
    oc_flat = _uci_show("openclash")
    pw_flat = _uci_show("passwall")
    oc_running = _service_running("openclash")
    pw_state = _passwall_state(pw_flat) if pw_flat else {"enabled": False, "nodes": []}

    oc_nodes = 0
    if oc_running:
        data = clash.proxies()
        oc_nodes = int(data.get("node_count") or 0)

    pw_running = _service_running("passwall") and pw_state["enabled"]

    return [
        {
            "id": "openclash",
            "label": LABEL["openclash"],
            "installed": _installed("openclash"),
            "enabled": oc_flat.get("openclash.config.enable", "0") == "1",
            "running": bool(oc_running),
            "node_count": oc_nodes,
            "engine": oc_flat.get("openclash.config.core_type", ""),
            "mode": oc_flat.get("openclash.config.en_mode", ""),
        },
        {
            "id": "passwall",
            "label": LABEL["passwall"],
            "installed": _installed("passwall"),
            "enabled": pw_state["enabled"],
            "running": bool(pw_running),
            "node_count": len(pw_state["nodes"]),
            "engine": "Xray",
            "mode": _uci_get("passwall.@global[0].dns_shunt") or "chinadns-ng",
        },
    ]


_ACTIVE_TTL = 3.0
_active_cache = {"ts": 0.0, "id": "none"}


def forget_active() -> None:
    """切换后端之后立刻失效，否则接下来的 3 秒还会读到旧的"""
    _active_cache["ts"] = 0.0


def active() -> str:
    """当前生效的后端。两个都在跑时以 OpenClash 为准（它抢占了 53/7892）。

    `backends()` 要 pgrep + uci，一次 20–30ms；这个函数被 mode/connections/
    groups/select 每次请求都调一遍，实测占掉这些接口的一半时间。
    后端状态不会 3 秒内反复变，缓存 3 秒；写操作（切后端）会主动失效。
    """
    now = time.time()
    if now - _active_cache["ts"] < _ACTIVE_TTL:
        return _active_cache["id"]
    for item in backends():
        if item["running"]:
            _active_cache.update(ts=now, id=item["id"])
            return item["id"]
    _active_cache.update(ts=now, id="none")
    return "none"


def overview() -> dict:
    items = backends()
    current = next((i for i in items if i["running"]), None)
    return {
        "active": current["id"] if current else "none",
        "backends": items,
        "mutual_exclusive": True,
    }


def groups(backend: str = "") -> dict:
    target = backend or active()
    if target == "openclash":
        data = clash.proxies()
        data["backend"] = "openclash"
        return data
    if target == "passwall":
        flat = _uci_show("passwall")
        state = _passwall_state(flat)
        result = _passwall_groups(state["nodes"], state["current_id"])
        result["backend"] = "passwall"
        result["current"] = state["current"]
        return result
    return {"groups": [], "node_count": 0, "error": "没有正在运行的代理后端", "backend": target}


def select(name: str, group: str = "", backend: str = "") -> dict:
    target = backend or active()
    if target == "openclash":
        return {**clash.select(group, name), "backend": "openclash"}

    if target == "passwall":
        flat = _uci_show("passwall")
        state = _passwall_state(flat)
        node = next((n for n in state["nodes"] if n["name"] == name or n["id"] == name), None)
        if not node:
            return {"ok": False, "error": f"节点不存在: {name}", "backend": "passwall"}
        global_sec = next(
            (k.split(".", 1)[1] for k, v in flat.items() if v == "global"), ""
        )
        if not global_sec:
            return {"ok": False, "error": "找不到 passwall global 配置", "backend": "passwall"}
        code, out = _run(["uci", "set", f"passwall.{global_sec}.tcp_node={node['id']}"], timeout=5)
        if code != 0:
            return {"ok": False, "error": out.strip(), "backend": "passwall"}
        _run(["uci", "commit", "passwall"], timeout=5)
        changed = node["id"] != state["current_id"]
        # 节点变更需要重启内核才生效；Passwall 没有热切换能力
        restarted = None
        if changed and state["enabled"]:
            restarted = service("restart", "passwall")
        return {
            "ok": True,
            "backend": "passwall",
            "name": node["name"],
            "group": node["group"],
            "restarted": restarted,
            "note": "Passwall 无热切换，已重启内核生效" if changed else "已是当前节点",
        }
    return {"ok": False, "error": "没有正在运行的代理后端", "backend": target}


def service(action: str, backend: str = "") -> dict:
    if action not in {"start", "stop", "restart"}:
        return {"ok": False, "error": "invalid action"}
    target = backend or active()
    if target not in INIT:
        return {"ok": False, "error": "未知后端"}

    # 两者互斥：启动一方前必须停掉另一方，否则抢 53 端口和转发链
    stopped = None
    if action in ("start", "restart"):
        other = "passwall" if target == "openclash" else "openclash"
        if _installed(other) and _service_running(other):
            _run([INIT[other], "stop"], timeout=90)
            stopped = other

    # 启用状态与开机自启一起改，避免重启后又跑回另一个
    if action == "start":
        if target == "openclash":
            _run(["uci", "set", "openclash.config.enable=1"], timeout=5)
        else:
            _run(["uci", "set", "passwall.@global[0].enabled=1"], timeout=5)
        _run(["uci", "commit", target if target == "openclash" else "passwall"], timeout=5)
    elif action == "stop":
        if target == "openclash":
            _run(["uci", "set", "openclash.config.enable=0"], timeout=5)
        else:
            _run(["uci", "set", "passwall.@global[0].enabled=0"], timeout=5)
        _run(["uci", "commit", target if target == "openclash" else "passwall"], timeout=5)

    code, out = _run([INIT[target], action], timeout=120)
    # 刚切过后端，缓存里的 active 立刻作废
    forget_active()
    return {
        "ok": code == 0,
        "backend": target,
        "action": action,
        "code": code,
        "stopped_other": stopped,
        "output": out[-800:],
    }


CONFIG_DIR = "/etc/openclash/config"


def configs() -> dict:
    """OpenClash 的配置文件清单。

    OpenClash 同一时刻只跑一个 yaml（openclash.config.config_path），其余文件
    只是躺在目录里。想在手机上换订阅，得先能看见这份清单。
    """
    flat = _uci_show("openclash")
    current = flat.get("openclash.config.config_path", "")
    try:
        names = sorted(os.listdir(CONFIG_DIR))
    except OSError:
        names = []

    items: list[dict] = []
    for name in names:
        if not name.endswith((".yaml", ".yml")):
            continue
        path = os.path.join(CONFIG_DIR, name)
        try:
            st = os.stat(path)
        except OSError:
            continue
        items.append(
            {
                "name": name.rsplit(".", 1)[0],
                "file": name,
                "path": path,
                "size": st.st_size,
                "mtime": int(st.st_mtime),
                "current": path == current,
            }
        )
    return {"ok": True, "backend": "openclash", "dir": CONFIG_DIR,
            "current": current, "configs": items}


def switch_config(path: str) -> dict:
    """切换 OpenClash 配置文件。

    只改 uci 不够：内核进程早把旧 yaml 读进内存了，必须重启才生效。
    重启会断网十几秒，调用方要用长超时。
    """
    if not path:
        return {"ok": False, "error": "缺少配置文件路径"}
    real = os.path.realpath(path)
    base = os.path.realpath(CONFIG_DIR) + os.sep
    # 路径来自客户端，必须锁死在配置目录里，否则等于给了一个任意文件写入点
    if not real.startswith(base):
        return {"ok": False, "error": "配置文件不在开放目录内"}
    if not real.endswith((".yaml", ".yml")) or not os.path.isfile(real):
        return {"ok": False, "error": "配置文件不存在"}

    code, out = _run(["uci", "set", f"openclash.config.config_path={real}"], timeout=5)
    if code != 0:
        return {"ok": False, "error": f"写入配置失败: {out[-200:]}"}
    _run(["uci", "commit", "openclash"], timeout=5)

    if not _service_running("openclash"):
        # 没在跑就不用重启，下次启动自然会用新文件
        return {"ok": True, "path": real, "restarted": False}

    code, out = _run([INIT["openclash"], "restart"], timeout=180)
    return {
        "ok": code == 0,
        "path": real,
        "restarted": True,
        "output": out[-600:],
        "error": "" if code == 0 else "重启 OpenClash 失败，看日志确认新配置是否有效",
    }


def mode(value: str = "", backend: str = "") -> dict:
    """读取 / 切换代理模式。"""
    target = backend or active()
    if target == "openclash":
        if not value:
            data = clash._req("/configs")
            return {"ok": True, "backend": target, "mode": data.get("mode")}
        return {**clash.set_mode(value), "backend": target}

    if target == "passwall":
        flat = _uci_show("passwall")
        global_sec = next((k.split(".", 1)[1] for k, v in flat.items() if v == "global"), "")
        if not value:
            return {
                "ok": True,
                "backend": target,
                "mode": flat.get(f"passwall.{global_sec}.tcp_proxy_mode", ""),
            }
        if value not in {"proxy", "disable"}:
            return {"ok": False, "error": "invalid mode"}
        _run(["uci", "set", f"passwall.{global_sec}.tcp_proxy_mode={value}"], timeout=5)
        _run(["uci", "commit", "passwall"], timeout=5)
        return {"ok": True, "backend": target, "mode": value}
    return {"ok": False, "error": "没有正在运行的代理后端"}


def connections(backend: str = "") -> dict:
    """连接明细。必须跟随「正在查看的后端」而不是 active，
    否则看 Passwall 页面会串成 OpenClash 的连接数。"""
    target = backend or active()
    if target == "openclash" and active() == "openclash":
        data = clash.connections()
        data["backend"] = "openclash"
        return data
    if target == "passwall":
        return {
            "backend": target,
            "connections": [],
            "download_total": 0,
            "upload_total": 0,
            "error": "Passwall 不提供连接明细接口",
        }
    return {
        "backend": target,
        "connections": [],
        "download_total": 0,
        "upload_total": 0,
        "error": "该后端未在运行",
    }


def delay(name: str, timeout_ms: int = 5000) -> dict:
    target = active()
    if target == "openclash":
        return {**clash.delay(name, timeout_ms=timeout_ms), "backend": target}
    # Passwall 的 Xray 节点没有测速 HTTP 接口，用 TCP 连通性代替
    flat = _uci_show("passwall")
    state = _passwall_state(flat)
    node = next((n for n in state["nodes"] if n["name"] == name), None)
    if not node or not node.get("address"):
        return {"ok": False, "error": "节点不存在", "backend": target}
    host, port = node["address"], node.get("port") or "443"
    import socket
    import time as _t

    start = _t.monotonic()
    try:
        with socket.create_connection((host, int(port)), timeout=timeout_ms / 1000):
            ms = int((_t.monotonic() - start) * 1000)
        return {"ok": True, "delay": ms, "backend": target, "kind": "tcp"}
    except (OSError, ValueError) as exc:
        return {"ok": False, "error": str(exc), "backend": target}


def delays(group: str = "", backend: str = "", timeout_ms: int = 3000) -> dict:
    """整组测速，一次返回 {节点名: 毫秒}。

    OpenClash 走 Mihomo 的 /group/{name}/delay（内核并发打完一组）；
    Passwall 没有这个接口，只能对节点做并发 TCP 连接探测，
    所以那边的数字是「TCP 握手耗时」，不是 HTTP 往返，界面上会标注。
    """
    target = backend or active()
    if target == "openclash":
        if not group:
            return {"ok": False, "error": "缺少分组名", "backend": target, "delays": {}}
        result = clash.group_delay(group, timeout_ms=timeout_ms)
        return {**result, "backend": target, "kind": "http"}

    if target == "passwall":
        flat = _uci_show("passwall")
        state = _passwall_state(flat)
        nodes = state["nodes"]
        if group:
            nodes = [n for n in nodes if n["group"] == group]
        if not nodes:
            return {"ok": False, "error": "该分组没有节点", "backend": target, "delays": {}}

        import socket
        import time as _t
        from concurrent.futures import ThreadPoolExecutor

        def probe(node: dict) -> tuple[str, int]:
            host = node.get("address") or ""
            port = node.get("port") or "443"
            if not host:
                return node["name"], 0
            start = _t.monotonic()
            try:
                with socket.create_connection((host, int(port)), timeout=timeout_ms / 1000):
                    return node["name"], max(1, int((_t.monotonic() - start) * 1000))
            except (OSError, ValueError):
                return node["name"], 0

        with ThreadPoolExecutor(max_workers=16) as pool:
            pairs = list(pool.map(probe, nodes[:200]))
        delays = {name: ms for name, ms in pairs}
        return {
            "ok": any(delays.values()),
            "backend": target,
            "kind": "tcp",
            "delays": delays,
            "error": None if any(delays.values()) else "全部节点不可达",
        }

    return {"ok": False, "error": "没有正在运行的代理后端", "backend": target, "delays": {}}
