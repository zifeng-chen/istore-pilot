"""配置加载。默认路径 /etc/istore-agent/config.json，可用 ISTORE_AGENT_CONFIG 覆盖（便于本地调试）。"""

from __future__ import annotations

import json
import os
import secrets
import threading

_default_path = "/etc/istore-agent/config.json"
_cache: dict | None = None
_lock = threading.Lock()


def path() -> str:
    return os.environ.get("ISTORE_AGENT_CONFIG", _default_path)


def defaults() -> dict:
    return {
        "listen": {"host": "0.0.0.0", "port": 8443},
        "auth": {
            "password": "changeme",
            "token_ttl": 7 * 24 * 3600,
            "rate_limit_per_min": 30,
        },
        "clash": {
            "controller_host": "127.0.0.1",
            "controller_port": 9090,
            "secret": "",
            "delay_url": "http://www.gstatic.com/generate_204",
        },
        "adguard": {
            "user": "admin",
            # 不写死口令：部署时用 AGENT_ADGUARD_PASSWORD 注入，或装好后在
            # /etc/istore-agent/config.json 里填
            "password": os.environ.get("AGENT_ADGUARD_PASSWORD", ""),
            "api_host": "192.168.100.1",
            "api_port": 3000,
        },
        "sample": {"interval": 60, "retain_days": 7},
        "luci": {
            # App 内置浏览器打开网页端时要免密进后台，Agent 会拿这个口令
            # 代登录一次 LuCI（见 luci.py）。
            # 留空 = 用下面 auth.password（全站同一个口令的部署什么都不用填）；
            # 只有「路由器 root 口令 ≠ App 登录口令」时才需要在这里写。
            "password": os.environ.get("AGENT_LUCI_PASSWORD", ""),
        },
        "ap": {
            # 中兴 AP 的接入设备表 —— 「有线还是无线」只有 AP 自己知道，
            # 详情见 zte.py。口令只存在这台路由器的 config.json 里（0600），
            # 不进仓库、不上传。
            "enabled": False,
            # 接入设备表的驱动：目前只有 zte（中兴 ZXSLC 系列）。
            # 换成别家 AP 时，写一个新驱动并在 agent/ap.py 的 DRIVERS 里登记
            "driver": "zte",
            "user": "admin",
            "password": os.environ.get("AGENT_AP_PASSWORD", ""),
            "hosts": [],
        },
    }


def _merge(base: dict, extra: dict) -> dict:
    out = dict(base)
    for key, val in extra.items():
        if isinstance(val, dict) and isinstance(out.get(key), dict):
            out[key] = _merge(out[key], val)
        else:
            out[key] = val
    return out


def _write(data: dict) -> bool:
    try:
        os.makedirs(os.path.dirname(path()), mode=0o700)
    except OSError:
        pass
    try:
        with open(path(), "w", encoding="utf-8") as fh:
            json.dump(data, fh, ensure_ascii=False, indent=2)
        os.chmod(path(), 0o600)
    except OSError:
        return False
    return True


def load() -> dict:
    global _cache
    with _lock:
        if _cache is not None:
            return _cache
        data = defaults()
        try:
            with open(path(), "r", encoding="utf-8") as fh:
                data = _merge(data, json.load(fh))
        except (OSError, json.JSONDecodeError):
            pass
        if not data["auth"].get("signing_key"):
            data["auth"]["signing_key"] = secrets.token_hex(32)
            # 必须落盘，否则服务重启后令牌全部失效
            _write(data)
        _cache = data
        return _cache


def get(section: str, default=None):
    return load().get(section, default)


def reload() -> dict:
    global _cache
    with _lock:
        _cache = None
    return load()


def save(data: dict) -> bool:
    global _cache
    with _lock:
        if not _write(data):
            return False
        _cache = data
    return True
