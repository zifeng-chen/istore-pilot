"""用路由器上的 OAF 特征库做应用识别。

为什么用它
----------
``apps.py`` 里手写的 ``_RULES`` 只有几十条，覆盖的都是常见应用；
OpenAppFilter 的特征库有 **560 个应用、719 条域名特征**，还带分类，
而且用户会持续更新它（在线订阅或上传）。

这里的定位是**纯识别**，不做过滤：只读 ``/etc/appfilter/feature.cfg``，
把里面的 ``host url`` 字段抽出来当域名特征用。库在不在、过滤开不开都无所谓，
没装插件就静静返回 None，让上层退回 geosite / 主域名。

优先级
------
广告联盟和推送域名必须优先判（``apps.py`` 的 ``_RULES`` 排在最前），
否则 ``pangolin-sdk-toutiao`` 这种会被算成抖音。所以调用方要在 ``_RULES``
之后、geosite 之前调用这里。

许可证
------
特征库是 OAF 会员私有授权，禁止分发。这里只**读用户机器上已有的文件**，
不拷贝、不打包、不内置任何特征数据。
"""

from __future__ import annotations

import os
import re
import threading

FEATURE = "/etc/appfilter/feature.cfg"
MIN_LEN = 4          # 太短的片段（如 "qq"）会误伤，宁可漏判

_lock = threading.Lock()
_cache: dict = {"key": None, "pats": []}

_LINE_RE = re.compile(r"^\d+\s+(.+?):\[(.*)\]\s*$")


def _parse(text: str) -> list[tuple[str, str]]:
    """feature.cfg → [(域名片段, 应用名)]，按片段长度降序（长的更具体）。"""
    pats: list[tuple[str, str]] = []
    seen: set[tuple[str, str]] = set()
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = _LINE_RE.match(line)
        if not m:
            continue
        name = m.group(1).strip()
        if not name:
            continue
        for item in m.group(2).split(","):
            f = item.split(";")
            if len(f) < 4:
                continue
            host = f[3].strip().lower()
            if not host:
                continue
            # host 字段偶尔塞多个候选，用 | 或空格分隔
            for one in host.replace("|", " ").split():
                if len(one) < MIN_LEN or " " in one:
                    continue
                if (one, name) in seen:
                    continue
                seen.add((one, name))
                pats.append((one, name))
    pats.sort(key=lambda x: -len(x[0]))
    return pats


def load() -> list[tuple[str, str]]:
    """按 mtime 缓存解析结果；文件不在就返回空表。"""
    try:
        st = os.stat(FEATURE)
        key = (st.st_mtime, st.st_size)
    except OSError:
        return []
    with _lock:
        if _cache["key"] == key:
            return _cache["pats"]
        try:
            with open(FEATURE, "r", encoding="utf-8", errors="replace") as f:
                pats = _parse(f.read())
        except OSError:
            return []
        _cache["key"] = key
        _cache["pats"] = pats
        return pats


def identify(host: str) -> tuple[str, str] | None:
    """域名 → (应用名, 分类)。认不出返回 None（漏判交给上层兜底）。"""
    low = (host or "").lower()
    if not low:
        return None
    pats = load()
    if not pats:
        return None
    for pat, name in pats:
        if pat in low:
            return name, "应用"
    return None


def info() -> dict:
    """给状态接口用：库在不在、能认多少应用。"""
    pats = load()
    apps = {name for _, name in pats}
    return {"available": bool(pats), "patterns": len(pats), "apps": len(apps)}
