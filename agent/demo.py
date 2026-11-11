#!/usr/bin/env python3
"""演示实例：录制真实响应 + 只读回放（应用商店审核用）。

审核员没有你的路由器，打开 App 只能看到登录页。方案 A 是云上跑一个只读实例：
先在这台真路由器上把接口返回录一遍，再把录下来的 JSON 拿去回放。

为什么不是手写假数据：二十多个接口，字段少一个界面上就是空列表 / undefined /
1970 年，审核员一眼看出是假的。录制回放拿到的是真机真实返回，结构天然对得上。

用法：

    # 录制（真路由器上，装完正常用一遍 App，五个页签都点）
    python3 run.py --record --demo-dir /tmp/demo
    # 产物：/tmp/demo/<path>.json，一个接口一个文件

    # 回放（云主机上）
    python3 run.py --demo --demo-dir /usr/share/istore-demo --host 0.0.0.0

两条硬规矩：

1. **写操作一律拒绝**。审核员点「禁止设备上网」不能真的改动任何东西，
   server 层统一回 501，不进业务代码。
2. **录制前脱敏**。MAC、内网地址、主机名、订阅链接都换成本地映射生成的示例值，
   同一台设备在不同接口里保持同一个假 MAC（映射表存在 _map.json）。
"""

from __future__ import annotations

import json
import os
import re
import time

# 字符串里出现的地址也一并换掉：有些接口把 IP 拼在说明文字里
_MAC_RE = re.compile(r"\b(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b")
_V4_RE = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")
_V6_RE = re.compile(r"\b(?:[0-9a-fA-F]{1,4}:){2,7}[0-9a-fA-F]{1,4}\b")

# 这些键在任何层级都按地址处理
_IP_KEYS = {"ip", "ipv4", "ipv6", "gateway", "dns", "peer", "addr", "nexthop"}
_URL_KEYS = {"url", "address", "link", "masked"}
# 时间戳字段：回放时按「录制到现在过了多久」整体平移，界面不会停在过去
_TS_KEYS = {"ts", "now", "time", "last_seen", "since", "boot_ts", "started"}
_UP_KEYS = {"uptime"}


def key_of(path: str, query: dict) -> str:
    """接口路径 + 查询串 → 文件名。

    带查询串的单独存一份（如 groups?backend=passwall），否则两个后端会互相覆盖。
    """
    name = path.strip("/").replace("/", "__")
    if query:
        parts: list[str] = []
        for k in sorted(query):
            for v in query[k]:
                parts.append("%s=%s" % (k, v))
        q = "&".join(parts)
        name += "@" + re.sub(r"[^A-Za-z0-9_.=-]+", "_", q)[:80]
    return name + ".json"


class Store:
    """一个目录就是一整套演示数据，录制和回放都走它。"""

    def __init__(self, root: str):
        self.root = root
        self.map_path = os.path.join(root, "_map.json")
        self.macs: dict[str, str] = {}
        self.ips: dict[str, str] = {}
        self.v6s: dict[str, str] = {}
        self.names: dict[str, str] = {}
        self._load_map()

    # ---------------------------------------------------------------- 映射表

    def _load_map(self) -> None:
        try:
            with open(self.map_path, encoding="utf-8") as fh:
                data = json.load(fh)
        except (OSError, ValueError):
            return
        self.macs = dict(data.get("macs") or {})
        self.ips = dict(data.get("ips") or {})
        self.v6s = dict(data.get("v6s") or {})
        self.names = dict(data.get("names") or {})

    def _save_map(self) -> None:
        try:
            os.makedirs(self.root, exist_ok=True)
            tmp = self.map_path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump({"macs": self.macs, "ips": self.ips, "v6s": self.v6s,
                           "names": self.names},
                          fh, ensure_ascii=False, indent=1)
            os.replace(tmp, self.map_path)
        except OSError:
            pass  # 映射表丢了只会换一批假值，不影响回放

    def _seq(self, table: dict[str, str], raw: str, fmt) -> str:
        if raw not in table:
            table[raw] = fmt(len(table) + 1)
            self._save_map()
        return table[raw]

    def _fake_mac(self, raw: str) -> str:
        return self._seq(self.macs, raw.lower(),
                         lambda i: "02:00:00:00:%02x:%02x" % (i // 256, i % 256))

    def _fake_ip(self, raw: str) -> str:
        # 带掩码的地址（192.168.1.1/24）把掩码原样留着
        addr, sep, tail = raw.partition("/")
        prefix = "192.168.1." if _is_private(addr) else "203.0.113."
        fake = self._seq(self.ips, addr,
                         lambda i: prefix + str(min(i + 9, 250)))
        return fake + sep + tail if sep else fake

    def _fake_v6(self, raw: str) -> str:
        return self._seq(self.v6s, raw.lower(),
                         lambda i: "2001:db8::%x" % i)

    def _fake_name(self, raw: str) -> str:
        return self._seq(self.names, raw, lambda i: "演示设备 %02d" % i)

    # ------------------------------------------------------------------ 脱敏

    def scrub(self, value, key: str = "", in_device: bool = False):
        """递归替换敏感值。in_device 表示当前对象带 mac，是「一台设备」。"""
        if isinstance(value, dict):
            dev = in_device or "mac" in value or "bssid" in value
            return {k: self.scrub(v, k, dev) for k, v in value.items()}
        if isinstance(value, list):
            return [self.scrub(x, key, in_device) for x in value]
        if not isinstance(value, str):
            return value

        if key in ("mac", "bssid"):
            return self._fake_mac(value)
        if key == "ssid":
            return "DemoWiFi"
        if key in ("hostname", "name") and in_device:
            return self._fake_name(value)
        if key in _IP_KEYS:
            # v6 不能走 v4 的映射：_is_private 对冒号地址一律当内网，
            # 会把 240e:... 写成 192.168.1.x，一眼看出是假数据
            return self._fake_v6(value) if ":" in value else self._fake_ip(value)
        if key in _URL_KEYS and value.startswith(("http://", "https://")):
            return "https://example.com/sub/demo"
        return self._scrub_text(value)

    def _scrub_text(self, text: str) -> str:
        """兜底：值里夹带的 MAC / 地址也换掉（说明文字、命令行回显里常见）。"""
        text = _MAC_RE.sub(lambda m: self._fake_mac(m.group(0)), text)
        text = _V6_RE.sub(lambda m: self._fake_v6(m.group(0)), text)
        text = _V4_RE.sub(lambda m: self._fake_ip(m.group(0)), text)
        return text

    # ------------------------------------------------------------------ 录制

    def save(self, path: str, query: dict, data) -> None:
        os.makedirs(self.root, exist_ok=True)
        doc = {"recorded_at": time.time(), "data": self.scrub(data)}
        target = os.path.join(self.root, key_of(path, query))
        tmp = target + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(doc, fh, ensure_ascii=False, indent=1)
        os.replace(tmp, target)

    # ------------------------------------------------------------------ 回放

    def load(self, path: str, query: dict):
        """命中返回数据；没录到返回 None（调用方回 503，别静默给空数组）。"""
        for key in (key_of(path, query), key_of(path, {})):
            fp = os.path.join(self.root, key)
            if not os.path.exists(fp):
                continue
            try:
                with open(fp, encoding="utf-8") as fh:
                    doc = json.load(fh)
            except (OSError, ValueError):
                continue
            delta = time.time() - float(doc.get("recorded_at") or time.time())
            return self.shift_doc(doc.get("data"), delta)
        return None

    def shift_doc(self, data, delta: float, key: str = ""):
        """时间戳/运行时长整体前移，界面不会显示「已运行 3 天」永远不变。"""
        if isinstance(data, dict):
            return {k: self.shift_doc(v, delta, k) for k, v in data.items()}
        if isinstance(data, list):
            return [self.shift_doc(x, delta, key) for x in data]
        if isinstance(data, (int, float)) and not isinstance(data, bool):
            if key in (_TS_KEYS | _UP_KEYS) and (key not in _TS_KEYS or data > 1_000_000_000):
                shifted = data + delta
                # 整数型字段保持整数：回一个 86400.019 会让「已运行 X 天」多出小数
                return int(round(shifted)) if isinstance(data, int) else shifted
        return data


def _is_private(addr: str) -> bool:
    parts = addr.split(".")
    if len(parts) != 4 or not all(p.isdigit() for p in parts):
        return True  # 认不出来就按内网处理，宁可比实际更保守
    a, b = int(parts[0]), int(parts[1])
    return (a == 10 or (a == 172 and 16 <= b <= 31) or (a == 192 and b == 168)
            or a == 127 or a == 169)
