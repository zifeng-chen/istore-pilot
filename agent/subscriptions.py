"""订阅地址管理（OpenClash / Passwall）。

两边的订阅都存成 **匿名 uci 段**：

    config config_subscribe
        option name 'xxx'
        option address 'https://...'

    config subscribe_list
        option remark 'xxx'
        option url 'https://...'

匿名段在 uci 里只能按下标引用（``@config_subscribe[0]``），所以对外用这个
下标当主键，改名、改地址、删除都按它来。新增之后 uci 会生成一个带名字的段，
那时主键就是那个名字 —— 两种形式都要认。

「更新订阅」不是改 url，而是让后端重新拉一遍内容，这一步要几十秒，
所以只起后台任务，不在这里等结果：

    OpenClash  /usr/share/openclash/openclash.sh
    Passwall   lua /usr/share/passwall/subscribe.lua start all manual
"""

from __future__ import annotations

import ipaddress
import json
import os
import re
import subprocess
import time
import urllib.parse

from . import sysinfo

PKG = {"openclash": "openclash", "passwall": "passwall"}
STYPE = {"openclash": "config_subscribe", "passwall": "subscribe_list"}
LABEL = {"openclash": "OpenClash", "passwall": "Passwall"}

# 「更新订阅」是后台任务，用户看不到跑没跑完、成没成功，只知道「点了没反应」。
# 所以两边都写同一份状态到磁盘：开始写 running，脚本跑完由 _finish_log 落结果。
DATA_DIR = "/etc/istore-agent/data"
SUB_LOG = "/tmp/istore-sub-update.log"
STATUS_JSON = os.path.join(DATA_DIR, "sub_update.json")
# 脚本可能写得很啰嗦，只留尾部够定位问题
_TAIL_CHARS = 4000

# 主键只允许这两种形态：@type[3] 或 cfg0a1b2c，避免拼接进 shell
_SEC_RE = re.compile(r"^(?:@[A-Za-z0-9_]+\[\d+\]|[A-Za-z0-9_\-]{1,64})$")
_URL_RE = re.compile(r"^https?://[^\s]+$", re.I)


def _url_ok(url: str) -> bool:
    """订阅地址白名单：http(s) + **不能指向本机/链路本地**。

    这个地址最终是让 OpenClash / Passwall 去 fetch 的，等于路由器替用户
    发请求 —— 填 `http://127.0.0.1:9090/...` 就成了打内网服务的跳板
    （SSRF）。域名放行（可能是自建订阅站），只挡明确的回环/本地地址。
    """
    if not _URL_RE.match(url or ""):
        return False
    try:
        host = (urllib.parse.urlparse(url).hostname or "").strip().lower()
    except ValueError:
        return False
    if not host:
        return False
    if host == "localhost" or host.endswith(".localhost"):
        return False
    try:
        ip = ipaddress.ip_address(host.strip("[]"))
    except ValueError:
        return True                     # 域名：交给后端自己去解析
    return not (ip.is_loopback or ip.is_link_local or ip.is_unspecified
                or ip.is_multicast or ip.is_reserved)


def _run(args: list[str], timeout: float = 10.0) -> tuple[int, str]:
    # 实现只有一份（sysinfo.run_code），超时默认值各模块自己定
    return sysinfo.run_code(args, timeout=timeout)


def _spawn(cmd: str, log: str) -> None:
    """后台拉起更新任务：必须脱离当前进程组，否则 Agent 重启会把任务带走。"""
    try:
        with open(log, "wb") as fh:
            subprocess.Popen(["/bin/sh", "-c", cmd], stdout=fh, stderr=fh,
                             stdin=subprocess.DEVNULL, start_new_session=True,
                             close_fds=True)
    except OSError:
        pass


def _read_status() -> dict:
    try:
        with open(STATUS_JSON, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def _write_status(data: dict) -> None:
    try:
        os.makedirs(DATA_DIR, exist_ok=True)
        tmp = STATUS_JSON + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(data, fh, ensure_ascii=False)
        os.chmod(tmp, 0o600)
        os.replace(tmp, STATUS_JSON)
    except OSError:
        pass


def _log_raw() -> str:
    try:
        with open(SUB_LOG, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read().replace("\r", "")
    except OSError:
        return ""


def _log_tail() -> str:
    """取更新脚本输出的尾部。脚本可能几 MB，只留最后一段。"""
    # 退出码那行是我们自己塞进去的，别让它在界面日志里露出来
    lines = [ln for ln in _log_raw().splitlines()
             if not ln.strip().startswith("__EXIT__")]
    return "\n".join(lines)[-_TAIL_CHARS:]


_FAIL_HINTS = ("error", "fail", "失败", "错误", "timeout", "timed out", "refused")


def _finish_log(started: float, backend: str = "") -> None:  # noqa: vulture 被后台命令调用
    """脚本跑完时由后台命令回调：判定成功/失败并落盘。

    退出码不可全信（OpenClash 的脚本失败也常返回 0），所以再看一眼日志尾部
    有没有 error/fail 这类字样；两者都干净才算成功。
    """
    tail = _log_tail()
    code = -1
    # 退出码要从原始日志里找：_log_tail 会把它过滤掉（不显示给用户）
    for line in _log_raw().splitlines():
        line = line.strip()
        if line.startswith("__EXIT__"):
            try:
                code = int(line[len("__EXIT__"):].strip() or "-1")
            except ValueError:
                code = -1
    low = tail.lower()
    bad = any(h in low for h in _FAIL_HINTS)
    ok = code == 0 and not bad
    if code == 0 and bad:
        note = "脚本退出码 0，但日志里有失败字样"
    elif ok:
        note = "更新成功"
    else:
        note = "更新失败（退出码 %d）" % code if code >= 0 else "更新失败（脚本异常退出）"
    _write_status({
        "backend": backend or _read_status().get("backend", ""),
        "running": False,
        "ok": ok,
        "exit_code": code,
        "started_at": int(started),
        "finished_at": int(time.time()),
        "seconds": max(0, int(time.time() - started)),
        "summary": note,
        "tail": tail,
    })


def _show(pkg: str) -> tuple[dict[str, str], dict[str, dict[str, str]]]:
    """`uci show pkg` → (段名→类型, 段名→{选项: 值})。"""
    code, out = _run(["uci", "show", pkg], timeout=8)
    if code != 0:
        return {}, {}
    types: dict[str, str] = {}
    opts: dict[str, dict[str, str]] = {}
    prefix = pkg + "."
    for line in out.splitlines():
        if "=" not in line or not line.startswith(prefix):
            continue
        key, _, raw = line.partition("=")
        val = raw.strip().strip("'")
        rest = key.strip()[len(prefix):]
        parts = rest.split(".", 1)
        if len(parts) == 1:
            types[parts[0]] = val
        else:
            opts.setdefault(parts[0], {})[parts[1]] = val
    return types, opts


def _installed(backend: str) -> bool:
    return os.path.exists(f"/etc/config/{PKG.get(backend, backend)}")


def _backend_list() -> list[dict]:
    return [
        {"id": b, "label": LABEL[b], "installed": _installed(b)}
        for b in ("openclash", "passwall")
    ]


def _oc_current_file() -> str:
    """OpenClash 当前挂着的配置文件（openclash.config.config_path）。"""
    code, out = _run(["uci", "get", "openclash.config.config_path"], timeout=6)
    return out.strip() if code == 0 else ""


def _pw_current_group() -> str:
    """PassWall 当前节点所属的分组名。

    PassWall 的订阅没有「启用」这个概念 —— 节点属于哪个分组，就是哪条订阅
    在生效（订阅拉下来的节点都带 ``group=<订阅备注>``）。所以「在用哪条订阅」
    等于「当前节点属于哪个组」。
    """
    types, opts = _show("passwall")
    tcp = ""
    for sec, typ in types.items():
        if typ == "global":
            tcp = opts.get(sec, {}).get("tcp_node", "")
            break
    if not tcp:
        return ""
    return opts.get(tcp, {}).get("group", "")


def list_subs(backend: str = "") -> dict:
    targets = [backend] if backend in PKG else ["openclash", "passwall"]
    cur_file = _oc_current_file().rsplit("/", 1)[-1] if "openclash" in targets else ""
    pw_group = _pw_current_group() if "passwall" in targets else ""
    items: list[dict] = []
    for b in targets:
        types, opts = _show(PKG[b])
        want = STYPE[b]
        for sec, typ in types.items():
            if typ != want:
                continue
            o = opts.get(sec, {})
            url = o.get("address") or o.get("url") or ""
            name = o.get("name") or o.get("remark") or ""
            # 界面上只给「正在用的那条」打角标，所以这里算的是 in_use，
            # 不是 uci 里的 enabled（那个是「要不要包含在订阅列表里」，两回事）
            if not name:
                in_use = False
            elif b == "openclash":
                in_use = cur_file in (name + ".yaml", name + ".yml")
            else:
                in_use = name == pw_group
            items.append({
                "backend": b,
                "backend_label": LABEL[b],
                "id": sec,
                "name": name or "未命名订阅",
                "url": url,
                "enabled": (o.get("enabled", "1") != "0"),
                "in_use": in_use,
                "auto_update": (o.get("auto_update", "0") == "1"),
                "expired": o.get("expired_date", ""),
                "traffic": o.get("rem_traffic", ""),
                # 订阅地址里带 token，界面上默认打码，点一下才展开
                "url_masked": _mask(url),
            })
    return {"ok": True, "items": items, "backends": _backend_list()}


def _mask(url: str) -> str:
    if not url:
        return ""
    if len(url) <= 42:
        return url
    return url[:30] + "…" + url[-8:]


def _bad(backend: str, msg: str) -> dict:
    return {"ok": False, "error": msg, "backend": backend}


# Passwall 装完时 /usr/share/passwall/0_default_config 会塞一个「分流总节点」
# 和 6 条分流规则。它们不是订阅节点，却会在节点列表里多出一个「未分组」，
# 让人以为订阅没拉全 —— 拉订阅时清掉。
_PW_FACTORY_SHUNT = "myshunt"
_PW_FACTORY_RULES = ("DirectGame", "ProxyGame", "AIGC", "Streaming", "Proxy", "Direct")


def _pw_drop_factory_shunt() -> bool:
    """删掉 Passwall 出厂自带的「分流总节点」，返回是否真删了。

    只认出厂状态：成员必须全指向 ``_direct`` / ``_default``，且没有
    tcp_node / udp_node 挂在这个节点上。用户配过的分流一律不碰 ——
    删了等于把人家的分流规则一起废掉。
    """
    types, opts = _show("passwall")
    if types.get(_PW_FACTORY_SHUNT) != "nodes":
        return False
    o = opts.get(_PW_FACTORY_SHUNT, {})
    if o.get("protocol") != "_shunt":
        return False
    members = {k: v for k, v in o.items() if k in _PW_FACTORY_RULES}
    if len(members) != len(_PW_FACTORY_RULES):
        return False
    if any(v not in ("_direct", "_default") for v in members.values()):
        return False
    for sec, typ in types.items():
        if typ == "global" and opts.get(sec, {}).get("tcp_node", "") == _PW_FACTORY_SHUNT:
            return False

    code, _ = _run(["uci", "delete", "passwall." + _PW_FACTORY_SHUNT], timeout=8)
    if code != 0:
        return False
    _run(["uci", "commit", "passwall"], timeout=8)
    return True


_PW_SEL_FILE = "/tmp/istore-pw-selection.json"


def _pw_save_selection() -> None:
    """拉订阅前记住当前节点。

    subscribe.lua 会把订阅节点全部删掉重建，section id 每次都变 ——
    只记 id 的话，刷完 tcp_node 就指向一个不存在的段，界面上变成「未选择」。
    所以按 remarks 记名字，拉完再按名字找回来。
    """
    types, opts = _show("passwall")
    global_sec = next((s for s, t in types.items() if t == "global"), "")
    if not global_sec:
        return
    names = {sec: o.get("remarks", "") for sec, o in opts.items()
             if types.get(sec) == "nodes"}
    g = opts.get(global_sec, {})
    try:
        with open(_PW_SEL_FILE, "w", encoding="utf-8") as fh:
            json.dump({"tcp": names.get(g.get("tcp_node", ""), ""),
                       "udp": names.get(g.get("udp_node", ""), "")}, fh,
                      ensure_ascii=False)
    except OSError:
        pass


def _pw_restore_selection() -> bool:  # noqa: vulture 看不到子进程调用
    """订阅拉完后，按名字把节点选回去。返回是否真的改了 uci。"""
    try:
        with open(_PW_SEL_FILE, encoding="utf-8") as fh:
            want = json.load(fh)
    except (OSError, ValueError):
        return False
    try:
        os.remove(_PW_SEL_FILE)
    except OSError:
        pass

    types, opts = _show("passwall")
    global_sec = next((s for s, t in types.items() if t == "global"), "")
    if not global_sec:
        return False
    by_name = {o.get("remarks", ""): sec for sec, o in opts.items()
               if types.get(sec) == "nodes"}
    changed = False
    for key, opt in (("tcp", "tcp_node"), ("udp", "udp_node")):
        name = want.get(key, "")
        sec = by_name.get(name, "")
        if not name or not sec or opts.get(global_sec, {}).get(opt, "") == sec:
            continue
        _run(["uci", "set", f"passwall.{global_sec}.{opt}={sec}"], timeout=6)
        changed = True
    if changed:
        _run(["uci", "commit", "passwall"], timeout=6)
    return changed


def add(backend: str, name: str, url: str, enabled: bool = True) -> dict:
    if backend not in PKG:
        return _bad(backend, "未知后端")
    if not _installed(backend):
        return _bad(backend, f"{LABEL[backend]} 没有安装")
    url = (url or "").strip()
    if not _url_ok(url):
        return _bad(backend, "订阅地址必须是可以公网访问的 http:// 或 https:// 地址"
                             "（不能填本机地址）")
    name = (name or "").strip()[:64] or "新订阅"

    code, out = _run(["uci", "add", PKG[backend], STYPE[backend]])
    sec = out.strip().splitlines()[-1].strip() if out.strip() else ""
    if code != 0 or not _SEC_RE.match(sec):
        return _bad(backend, "写入 uci 失败：" + (out.strip()[:200] or "未知错误"))

    if backend == "openclash":
        pairs = [
            ("name", name), ("address", url),
            ("enabled", "1" if enabled else "0"),
            ("sub_ua", "clash.meta"), ("sub_convert", "0"), ("emoji", "false"),
            ("udp", "true"), ("skip_cert_verify", "false"), ("sort", "false"),
            ("node_type", "false"), ("rule_provider", "false"),
        ]
    else:
        pairs = [
            ("remark", name), ("url", url), ("allowInsecure", "0"),
            ("filter_keyword_mode", "5"), ("user_agent", "passwall"),
            ("boot_update", "0"), ("auto_update", "1"),
            ("ss_type", "global"), ("trojan_type", "global"),
            ("vmess_type", "global"), ("vless_type", "global"),
            ("hysteria2_type", "global"),
        ]
    for key, val in pairs:
        _run(["uci", "set", f"{PKG[backend]}.{sec}.{key}={val}"])
    _run(["uci", "commit", PKG[backend]])

    return {"ok": True, "backend": backend, "id": sec, "name": name,
            "note": "已添加。点「更新」拉一次节点才会生效。"}


def update(backend: str, sec: str, name: str = "", url: str = "",
           enabled: bool | None = None) -> dict:
    if backend not in PKG:
        return _bad(backend, "未知后端")
    if not _SEC_RE.match(sec or ""):
        return _bad(backend, "非法的订阅标识")

    changed = []
    if name is not None and name.strip():
        key = "name" if backend == "openclash" else "remark"
        _run(["uci", "set", f"{PKG[backend]}.{sec}.{key}={name.strip()[:64]}"])
        changed.append("名称")
    if url is not None and url.strip():
        url = url.strip()
        if not _url_ok(url):
            return _bad(backend, "订阅地址必须是可以公网访问的 http:// 或 https:// 地址"
                                 "（不能填本机地址）")
        key = "address" if backend == "openclash" else "url"
        _run(["uci", "set", f"{PKG[backend]}.{sec}.{key}={url}"])
        changed.append("地址")
    if enabled is not None and backend == "openclash":
        _run(["uci", "set", f"{PKG[backend]}.{sec}.enabled={'1' if enabled else '0'}"])
        changed.append("启用状态")

    if not changed:
        return _bad(backend, "没有要修改的内容")
    _run(["uci", "commit", PKG[backend]])
    return {"ok": True, "backend": backend, "id": sec, "changed": changed}


def delete(backend: str, sec: str) -> dict:
    if backend not in PKG:
        return _bad(backend, "未知后端")
    if not _SEC_RE.match(sec or ""):
        return _bad(backend, "非法的订阅标识")
    code, out = _run(["uci", "delete", f"{PKG[backend]}.{sec}"])
    if code != 0:
        return _bad(backend, "删除失败：" + out.strip()[:200])
    _run(["uci", "commit", PKG[backend]])
    return {"ok": True, "backend": backend, "id": sec,
            "note": "已删除。已经导入的节点不会自动清掉，需要的话在代理里手动删。"}


def refresh(backend: str, sec: str = "") -> dict:
    """让后端重新拉订阅内容。异步执行，立刻返回。"""
    if backend not in PKG:
        return _bad(backend, "未知后端")
    if not _installed(backend):
        return _bad(backend, f"{LABEL[backend]} 没有安装")

    _run(["uci", "commit", PKG[backend]])

    # 先落一条 running，界面点完立刻能看到「正在更新」；
    # 真正的结果由脚本退出后回调 _finish_log 写
    started = int(time.time())
    _write_status({
        "backend": backend, "running": True, "ok": None,
        "started_at": started, "finished_at": 0, "seconds": 0,
        "summary": "正在更新…", "tail": "",
    })
    rec = ("cd /usr/lib/istore-agent && python3 -c "
           "\"import sys;sys.path.insert(0,'/usr/lib/istore-agent');"
           f"from agent import subscriptions as s;s._finish_log({started},'{backend}')\"")

    if backend == "openclash":
        script = "/usr/share/openclash/openclash.sh"
        if not os.path.exists(script):
            return _bad(backend, "找不到 " + script)
        _spawn(f"{script} >{SUB_LOG} 2>&1; echo __EXIT__$? >>{SUB_LOG};"
               f" {rec} >>{SUB_LOG} 2>&1",
               "/dev/null")
        return {
            "ok": True, "backend": backend, "async": True,
            "note": "已开始更新，OpenClash 会在后台重新拉取订阅并重建配置，"
                    "通常需要 20～60 秒，代理会短暂中断。",
        }

    script = "/usr/share/passwall/subscribe.lua"
    if not os.path.exists(script):
        return _bad(backend, "找不到 " + script)

    # 出厂那个「分流总节点」在拉订阅之前清掉：它不属于任何订阅，
    # 留着节点列表就会多出一个空分组，把真正的订阅节点挤到下面
    dropped = _pw_drop_factory_shunt()
    # 订阅节点每次都是删掉重建，先按名字记住选的是哪个，拉完再选回去
    _pw_save_selection()
    restore = ("cd /usr/lib/istore-agent && python3 -c "
               "\"import sys;sys.path.insert(0,'/usr/lib/istore-agent');"
               "from agent import subscriptions as s;s._pw_restore_selection()\"")
    # Passwall 的订阅段是匿名的，脚本只认段名，所以只能整批更新。
    # code=$? 必须在 restore 之前取，否则拿到的是恢复选中项的退出码
    _spawn(f"lua {script} start all manual >{SUB_LOG} 2>&1; code=$?;"
           f" {restore} >>{SUB_LOG} 2>&1; echo __EXIT__$code >>{SUB_LOG};"
           f" {rec} >>{SUB_LOG} 2>&1",
           "/dev/null")
    return {
        "ok": True, "backend": backend, "async": True,
        "dropped_default": dropped,
        "note": "已开始更新全部订阅（Passwall 不支持只更新一条），"
                "通常需要 20～60 秒。",
    }


def dispatch(body: dict) -> dict:
    """按 action 分发，给 server.py 用。"""
    action = str(body.get("action", "list")).lower()
    backend = str(body.get("backend", "")).strip()
    sec = str(body.get("id", body.get("sec", ""))).strip()

    if action == "list":
        return list_subs(backend)
    if action == "add":
        return add(backend, str(body.get("name", "")), str(body.get("url", "")),
                   bool(body.get("enabled", True)))
    if action == "update":
        en = body.get("enabled")
        return update(backend, sec, str(body.get("name", "")),
                      str(body.get("url", "")),
                      None if en is None else bool(en))
    if action == "delete":
        return delete(backend, sec)
    if action == "refresh":
        return refresh(backend, sec)
    if action == "log":
        return {"ok": True, "log": _read_status()}
    return {"ok": False, "error": f"未知操作: {action}"}
