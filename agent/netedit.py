"""网络配置的写操作（防火墙策略收紧）。

与 `netcfg.py` 的分工：`netcfg` 只读，这里只写。所有写操作都必须在
`netapply.begin()` 开的事务里做，并且把 token 一路回给客户端，
等客户端重连后点确认——这是唯一能证明「没有把管理员关在门外」的证据。

当前这台机器的实际问题
----------------------
`firewall.@zone[1].input = ACCEPT`，而这个 zone 覆盖 `wan` 和 `wan6`。
WAN 是 PPPoE + CGNAT，IPv4 没有公网地址，所以平时看不出来；
但 IPv6 是全局可达的，于是 SSH / 8443 / LuCI 实际上对整个公网敞开，
任何人扫到这个 /64 前缀就能连。这不是理论风险——IPv6 扫描器一直在跑。
"""
from __future__ import annotations

import ipaddress
import json
import os
import re

from . import netapply, sysinfo

PKG = "firewall"
MGMT_DEFAULT = (8443, 22)      # Agent 的 HTTPS 口 + SSH
SAVED = "/etc/istore-agent/data/fw_saved.json"   # 被删掉的 wan→lan 转发，留着好还原


def _uci(*args: str, timeout: float = 8.0) -> str:
    return sysinfo._run(["uci", *args], timeout=timeout).strip()


def _now(key: str) -> str:
    out = sysinfo._run(["uci", "-q", "get", key], timeout=4).strip()
    return "" if out.startswith("uci:") else out


def sections(pkg: str = PKG) -> dict[str, str]:
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


def find_section(pkg: str, kind: str, **match: str) -> str:
    """按类型 + 字段值找段，找不到返回空串。

    不能用固定下标：用户在 LuCI 里加过一个 zone，`@zone[1]` 就可能不是 wan 了，
    那时候按下标改等于把 lan 区锁死。
    """
    for sid, typ in sections(pkg).items():
        if typ != kind:
            continue
        if all(_now(f"{pkg}.{sid}.{k}") == v for k, v in match.items()):
            return sid
    return ""


def _is_ipv4(s: str) -> bool:
    try:
        ipaddress.IPv4Address(s)
        return True
    except ValueError:
        return False


# ---------------------------------------------------------------- 现状

def state() -> dict:
    """防火墙当前的入口状态，供界面判断「要不要提出建议」。"""
    wz = find_section(PKG, "zone", name="wan")
    input_policy = _now(f"{PKG}.{wz}.input") if wz else ""
    networks = _now(f"{PKG}.{wz}.network") if wz else ""

    # wan → lan 的 forwarding：有它，公网可以主动连内网设备
    wan_to_lan = ""
    for sid, typ in sections(PKG).items():
        if typ != "forwarding":
            continue
        if _now(f"{PKG}.{sid}.src") == "wan" and _now(f"{PKG}.{sid}.dest") == "lan":
            wan_to_lan = sid
            break

    mgmt: list[int] = []
    for sid, typ in sections(PKG).items():
        if typ != "rule" or not sid.startswith("istore_mgmt"):
            continue
        port = _now(f"{PKG}.{sid}.dest_port")
        if port.isdigit():
            mgmt.append(int(port))

    # 显式放行到公网的端口规则。
    # 这一项不能省：把 zone input 改成 REJECT 之后，`linkease`(8897)、
    # `fastnet`(3200) 这类自己加过 ACCEPT 的规则仍然有效，
    # 界面上如果只说「已收紧」，用户会以为全关了。
    open_rules: list[dict] = []
    for sid, typ in sections(PKG).items():
        if typ != "rule":
            continue
        if _now(f"{PKG}.{sid}.target") != "ACCEPT":
            continue
        if _now(f"{PKG}.{sid}.src") != "wan":
            continue
        name = _now(f"{PKG}.{sid}.name") or sid
        if name.startswith("Allow-") or sid.startswith("istore_mgmt"):
            continue          # 系统自带的 DHCP/ICMP 与 App 自己加的，不算遗留
        proto = _now(f"{PKG}.{sid}.proto") or "tcp"
        open_rules.append({
            "id": sid, "name": name, "proto": proto,
            "port": _now(f"{PKG}.{sid}.dest_port"),
        })

    return {
        "zone": wz,
        "zone_networks": networks,
        "input": input_policy or "?",
        "wan_to_lan": wan_to_lan,
        "mgmt_rules": sorted(mgmt),
        "open_rules": open_rules,
        "hardened": input_policy == "REJECT",
    }


def client_on_lan(client_ip: str) -> bool:
    """判断当前连接是不是从内网来的。

    这决定「收紧入口」能不能无风险执行：内网连接走 lan zone，改 wan 区完全
    不影响它；外网连接走的就是 wan zone，一改自己先断。
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


# ---------------------------------------------------------------- 收紧

def harden(payload: dict, client_ip: str = "") -> dict:
    """收紧 wan 区入口。

    三件事可以分开做，但一次事务里全部应用：
      1. `wan` zone input: ACCEPT → REJECT  （公网不能再主动连路由器）
      2. 删掉 wan → lan 的 forwarding        （公网不能主动连内网设备）
      3. 可选：为管理端口补 ACCEPT 规则      （远程管理还得能用）
    """
    do_input = bool(payload.get("harden_input", True))
    do_fwd = bool(payload.get("drop_wan_to_lan", True))
    keep_mgmt = bool(payload.get("keep_mgmt", False))

    ports: list[int] = []
    raw = payload.get("mgmt_ports")
    if isinstance(raw, list):
        for p in raw:
            try:
                n = int(p)
            except (TypeError, ValueError):
                continue
            if 1 <= n <= 65535:
                ports.append(n)
    if keep_mgmt and not ports:
        ports = list(MGMT_DEFAULT)

    if not do_input and not do_fwd and not keep_mgmt:
        return {"ok": False, "error": "没有选择任何改动"}

    st = state()
    if not st["zone"]:
        return {"ok": False, "error": "找不到 wan 区，防火墙结构可能被改过，请到网页端操作"}

    # 远程连接 + 不保留管理口 = 必定把自己关在门外，直接拒绝而不是让他等 60 秒
    remote = bool(client_ip) and not client_on_lan(client_ip)
    if remote and do_input and not keep_mgmt:
        return {"ok": False, "need_mgmt": True,
                "error": "你现在是从外网连进来的。收紧 wan 入口会立刻断开这条连接，"
                         "请勾选「保留远程管理端口」，或回到局域网内操作。"}

    todo: list[str] = []
    if do_input and st["input"] != "REJECT":
        todo.append(f"wan 区 input: {st['input'] or '?'} → REJECT")
    if do_fwd and st["wan_to_lan"]:
        todo.append("删除 wan → lan 转发：公网不能再主动连内网设备")
    if keep_mgmt:
        add = [p for p in ports if p not in st["mgmt_rules"]]
        if add:
            todo.append("放行管理端口：" + "、".join(str(p) for p in add))
    if not todo:
        return {"ok": True, "changed": [], "message": "已经是最严策略，无需改动",
                "state": state()}

    txn = netapply.begin("firewall-harden", services=("firewall",), note="收紧 wan 入口")
    if not txn.get("ok"):
        return txn
    token = txn["token"]

    try:
        if do_input:
            _uci("set", f"{PKG}.{st['zone']}.input=REJECT")
        if do_fwd and st["wan_to_lan"]:
            _remember_forwarding(st["wan_to_lan"])
            _uci("delete", f"{PKG}.{st['wan_to_lan']}")
        if keep_mgmt:
            for p in ports:
                _mgmt_rule(p)
        out = _uci("commit", PKG)
        if "error" in out.lower():
            raise RuntimeError(out)
    except Exception as exc:
        netapply.rollback(token, quiet=True)
        return {"ok": False, "error": f"写入防火墙配置失败（{exc}），已还原"}

    # reload 是异步的，这里不等；客户端会在下一次轮询里看到新策略
    sysinfo._run(["/etc/init.d/firewall", "reload"], timeout=20)

    after = state()
    # 显式 ACCEPT 规则不受 zone input 影响，必须单独告诉用户还剩哪些口开着，
    # 否则「已收紧」会给人错误的安全感
    warnings = [f"{r['name']} 仍然对公网放行（{r['proto']}/{r['port'] or '全部端口'}）"
                for r in after["open_rules"]]

    return {
        "ok": True,
        "token": token,
        "wait": txn["wait"],
        "deadline": txn["deadline"],
        "changed": todo,
        "state": after,
        "warnings": warnings,
        "message": "策略已生效",
        "detail": f"如果 {txn['wait']} 秒内没有回到 App 点确认，路由器会自动还原。",
    }


def _mgmt_rule(port: int) -> None:
    """管理端口放行规则。用具名段，重复执行是幂等的。"""
    sid = f"istore_mgmt_{port}"
    _uci("set", f"{PKG}.{sid}=rule")
    _uci("set", f"{PKG}.{sid}.name=istore-mgmt-{port}")
    _uci("set", f"{PKG}.{sid}.src=wan")
    _uci("set", f"{PKG}.{sid}.proto=tcp")
    _uci("set", f"{PKG}.{sid}.dest_port={port}")
    _uci("set", f"{PKG}.{sid}.target=ACCEPT")


def _remember_forwarding(sid: str) -> None:
    """删之前把 wan→lan 转发记下来。

    uci 的匿名段删掉就没了，`撤销收紧`时没法凭空重建。
    存到 Agent 自己的 data 目录而不是 uci 里：uci 里没有「停用的段」
    这种概念，写进去就等于立刻生效，等于没删。
    """
    fields = {}
    for k in ("src", "dest"):
        v = _now(f"{PKG}.{sid}.{k}")
        if v:
            fields[k] = v
    if len(fields) < 2:
        return
    try:
        os.makedirs(os.path.dirname(SAVED), exist_ok=True)
        with open(SAVED, "w", encoding="utf-8") as fh:
            json.dump({"wan_to_lan": fields}, fh, ensure_ascii=False)
    except OSError:
        pass


def _restore_forwarding() -> bool:
    try:
        with open(SAVED, "r", encoding="utf-8") as fh:
            saved = json.load(fh).get("wan_to_lan") or {}
    except (OSError, ValueError):
        return False
    if not saved.get("src") or not saved.get("dest"):
        return False
    sid = _uci("add", PKG, "forwarding").strip()
    if not sid:
        return False
    _uci("set", f"{PKG}.{sid}.src={saved['src']}")
    _uci("set", f"{PKG}.{sid}.dest={saved['dest']}")
    try:
        os.remove(SAVED)
    except OSError:
        pass
    return True


def unrestrict() -> dict:
    """撤销收紧：wan input 回到 ACCEPT，并清掉 App 加的管理口规则。

    这是「我确认自己不需要这么严」的出口，同样要走事务——
    放宽之后如果发现哪里不对，还得能一键回来。
    """
    st = state()
    if not st["zone"]:
        return {"ok": False, "error": "找不到 wan 区"}

    todo: list[str] = []
    if st["input"] != "ACCEPT":
        todo.append(f"wan 区 input: {st['input'] or '?'} → ACCEPT")
    if st["mgmt_rules"]:
        todo.append("移除 App 添加的管理端口放行规则")
    if os.path.exists(SAVED):
        todo.append("恢复 wan → lan 转发")
    if not todo:
        return {"ok": True, "changed": [], "message": "当前已经是放行状态", "state": state()}

    txn = netapply.begin("firewall-open", services=("firewall",), note="放宽 wan 入口")
    if not txn.get("ok"):
        return txn
    token = txn["token"]
    try:
        _uci("set", f"{PKG}.{st['zone']}.input=ACCEPT")
        for p in st["mgmt_rules"]:
            _uci("delete", f"{PKG}.istore_mgmt_{p}")
        _restore_forwarding()
        out = _uci("commit", PKG)
        if "error" in out.lower():
            raise RuntimeError(out)
    except Exception as exc:
        netapply.rollback(token, quiet=True)
        return {"ok": False, "error": f"写入防火墙配置失败（{exc}），已还原"}

    sysinfo._run(["/etc/init.d/firewall", "reload"], timeout=20)
    return {"ok": True, "token": token, "wait": txn["wait"], "deadline": txn["deadline"],
            "changed": todo, "state": state(), "message": "已放宽",
            "detail": f"如果 {txn['wait']} 秒内没有确认，会自动还原。"}
