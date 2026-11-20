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
_cache: dict = {"key": None, "pats": [], "cats": {}}

_LINE_RE = re.compile(r"^\d+\s+(.+?):\[(.*)\]\s*$")
_CLASS_RE = re.compile(r"^#class\s+(\S+)\s+(\d+)\s+(.+)$")

# 特征库里只有一小部分应用带分类号，其余按名字兜一层（够做分组即可）
_NAME_CAT: tuple[tuple[tuple[str, ...], str], ...] = (
    (("游戏", "荣耀", "联盟", "吃鸡", "和平精英", "原神", "崩坏", "王者", "斗地主", "棋"), "游戏"),
    (("视频", "影视", "抖音", "快手", "哔哩", "B站", "优酷", "爱奇艺", "腾讯视频",
      "YouTube", "直播", "虎牙", "斗鱼", "Netflix"), "视频"),
    (("音乐", "QQ音乐", "网易云", "酷狗", "酷我", "Spotify", "喜马拉雅", "播客"), "音乐"),
    (("淘宝", "天猫", "京东", "拼多多", "购物", "闲鱼", "唯品会", "苏宁", "亚马逊"), "购物"),
    (("微信", "QQ", "微博", "知乎", "小红书", "陌陌", "Soul", "贴纸", "钉钉", "飞书",
      "WhatsApp", "Telegram", "Discord", "Line", "Messenger", "探探"), "社交"),
    (("学习", "教育", "课堂", "词典", "作业", "有道", "考研", "得到", "知乎盐选"), "教育"),
    (("银行", "支付", "支付宝", "金融", "证券", "基金", "保险", "钱包"), "金融"),
    (("地图", "导航", "高德", "百度地图", "打车", "滴滴", "出行", "12306", "铁路"), "出行"),
    (("新闻", "资讯", "头条", "网易新闻", "澎湃", "浏览器", "搜索"), "资讯"),
)


def _cat_by_name(name: str) -> str:
    for keys, cat in _NAME_CAT:
        for k in keys:
            if k in name:
                return cat
    return ""


def _parse(text: str) -> tuple[list[tuple[str, str, str]], dict[str, str]]:
    """feature.cfg → ([(域名片段, 应用名, 分类)], {应用名: 分类})。"""
    classes: dict[str, str] = {}
    for line in text.splitlines():
        m = _CLASS_RE.match(line.strip())
        if m:
            classes[m.group(2)] = m.group(3).strip()

    pats: list[tuple[str, str, str]] = []
    cats: dict[str, str] = {}
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
        # 规则元组的第 8 个字段是分类号（不是每条都有），映射成中文分类
        for item in m.group(2).split(","):
            f = item.split(";")
            if len(f) >= 8 and f[7].strip().isdigit():
                cat = classes.get(f[7].strip())
                if cat:
                    cats[name] = cat
                    break
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
                key = (one, name)
                if key in seen:
                    continue
                seen.add(key)
                cat = cats.get(name) or _cat_by_name(name) or "应用"
                pats.append((one, name, cat))
    pats.sort(key=lambda x: -len(x[0]))
    return pats, cats


def load() -> list[tuple[str, str, str]]:
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
                pats, cats = _parse(f.read())
        except OSError:
            return []
        _cache["key"] = key
        _cache["pats"] = pats
        _cache["cats"] = cats
        return pats


def identify(host: str) -> tuple[str, str] | None:
    """域名 → (应用名, 分类)。认不出返回 None（漏判交给上层兜底）。"""
    low = (host or "").lower()
    if not low:
        return None
    pats = load()
    if not pats:
        return None
    for pat, name, cat in pats:
        if pat in low:
            return name, cat
    return None


def info() -> dict:
    """给状态接口用：库在不在、能认多少应用。"""
    pats = load()
    apps = {n for _, n, _ in pats}
    cats = {c for _, _, c in pats}
    return {"available": bool(pats), "patterns": len(pats),
            "apps": len(apps), "categories": len(cats)}
