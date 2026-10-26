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

import os
import re
import subprocess

PKG = {"openclash": "openclash", "passwall": "passwall"}
STYPE = {"openclash": "config_subscribe", "passwall": "subscribe_list"}
LABEL = {"openclash": "OpenClash", "passwall": "Passwall"}

# 主键只允许这两种形态：@type[3] 或 cfg0a1b2c，避免拼接进 shell
_SEC_RE = re.compile(r"^(?:@[A-Za-z0-9_]+\[\d+\]|[A-Za-z0-9_\-]{1,64})$")
_URL_RE = re.compile(r"^https?://[^\s]+$", re.I)


def _run(args: list[str], timeout: float = 10.0) -> tuple[int, str]:
    try:
        p = subprocess.run(args, capture_output=True, timeout=timeout, check=False)
        return p.returncode, (p.stdout + p.stderr).decode("utf-8", "replace")
    except (OSError, subprocess.SubprocessError) as exc:
        return 1, str(exc)


def _spawn(cmd: str, log: str) -> None:
    """后台拉起更新任务：必须脱离当前进程组，否则 Agent 重启会把任务带走。"""
    try:
        with open(log, "wb") as fh:
            subprocess.Popen(["/bin/sh", "-c", cmd], stdout=fh, stderr=fh,
                             stdin=subprocess.DEVNULL, start_new_session=True,
                             close_fds=True)
    except OSError:
        pass


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


def list_subs(backend: str = "") -> dict:
    targets = [backend] if backend in PKG else ["openclash", "passwall"]
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
            items.append({
                "backend": b,
                "backend_label": LABEL[b],
                "id": sec,
                "name": name or "未命名订阅",
                "url": url,
                "enabled": (o.get("enabled", "1") != "0"),
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


def add(backend: str, name: str, url: str, enabled: bool = True) -> dict:
    if backend not in PKG:
        return _bad(backend, "未知后端")
    if not _installed(backend):
        return _bad(backend, f"{LABEL[backend]} 没有安装")
    url = (url or "").strip()
    if not _URL_RE.match(url):
        return _bad(backend, "订阅地址必须以 http:// 或 https:// 开头")
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
        if not _URL_RE.match(url):
            return _bad(backend, "订阅地址必须以 http:// 或 https:// 开头")
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

    if backend == "openclash":
        script = "/usr/share/openclash/openclash.sh"
        if not os.path.exists(script):
            return _bad(backend, "找不到 " + script)
        _spawn(f"{script} >/tmp/istore-sub-update.log 2>&1",
               "/dev/null")
        return {
            "ok": True, "backend": backend, "async": True,
            "note": "已开始更新，OpenClash 会在后台重新拉取订阅并重建配置，"
                    "通常需要 20～60 秒，代理会短暂中断。",
        }

    script = "/usr/share/passwall/subscribe.lua"
    if not os.path.exists(script):
        return _bad(backend, "找不到 " + script)
    # Passwall 的订阅段是匿名的，脚本只认段名，所以只能整批更新
    _spawn(f"lua {script} start all manual >/tmp/istore-sub-update.log 2>&1",
           "/dev/null")
    return {
        "ok": True, "backend": backend, "async": True,
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
    return {"ok": False, "error": f"未知操作: {action}"}
