"""接入设备表的统一入口 —— 换一家 AP 只加一个适配器，不动上层。

为什么要有这层
--------------
「这台设备是插网线还是连 WiFi」只有 AP 自己知道（AP 是桥接的，无线和有线
在上游都桥到同一根网线）。但**每家 AP 的接口完全不一样**，而路由器的品牌
是用户自己的事，不能把 App 写死在中兴上。

所以上层（`devices._build()`）只认四个函数：

    settings()   -> dict        这层要不要工作、连哪台
    ensure()     -> None        起后台线程（第一次调用**不能阻塞**）
    access_map() -> {mac: ...}  当前快照，拿不到就是空表
    status()     -> dict        给接口看的状态（错误、条数、驱动名）

拿不到数据时返回空表，上层自动退回「按 MAC / 设备类型推断」，界面标「推测」。
AP 换了、没装、口令错了，功能都只是降级，不会坏。

已实现
------
    zte      中兴 ZXSLC 系列（实测 SR7410 主 + SR6110 从）

要接新厂商，新建一个模块（比如 `ap_tplink.py`），暴露上面四个函数，
然后在 DRIVERS 里登记一行即可。真正的活是「登录 → 拿客户端列表 →
映射成 ConnectType/频段」这件事，各家的差异全在驱动里。
"""

from __future__ import annotations

import importlib
import time

from . import config

#: 驱动名 → 模块。模块必须提供 settings/ensure/access_map/status
DRIVERS = ("zte",)


def _conf() -> dict:
    return config.load().get("ap") or {}


def driver_name() -> str:
    return str(_conf().get("driver") or "zte").strip().lower()


def _load():
    """按配置加载驱动。没开、名字不认识、模块导入失败都返回 None。"""
    if not _conf().get("enabled"):
        return None
    name = driver_name()
    if name in ("", "none", "off") or name not in DRIVERS:
        return None
    try:
        mod = importlib.import_module("." + name, package=__package__)
    except Exception:
        return None
    # 驱动自己也会判「有没有地址可读」，没地址就当没开，别让上层拿到空状态
    try:
        return mod if mod.settings().get("enabled") else None
    except Exception:
        return None


def _off_reason() -> str:
    conf = _conf()
    if not conf.get("enabled"):
        return "未配置 AP（ap.enabled=false），接入方式只能按类型推断"
    name = driver_name()
    if name not in DRIVERS:
        return f"没有 {name} 的驱动，接入方式只能按类型推断"
    return "ap.hosts 为空，没地方读接入表"


def settings() -> dict:
    mod = _load()
    if mod is None:
        return {"enabled": False, "hosts": [], "user": "", "password": "",
                "driver": driver_name()}
    out = dict(mod.settings())
    out["driver"] = driver_name()
    return out


def ensure() -> None:
    mod = _load()
    if mod is not None:
        mod.ensure()


def access_map() -> dict[str, dict]:
    mod = _load()
    if mod is None:
        return {}
    try:
        return mod.access_map()
    except Exception:
        return {}


def status() -> dict:
    mod = _load()
    if mod is None:
        return {"ts": time.time(), "ok": False, "errors": {}, "hosts": {},
                "disabled": True, "driver": driver_name(), "reason": _off_reason()}
    out = dict(mod.status())
    out["driver"] = driver_name()
    if out.get("disabled") and not out.get("reason"):
        out["reason"] = _off_reason()
    return out
