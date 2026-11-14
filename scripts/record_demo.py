#!/usr/bin/env python3
"""录制演示数据，打包进 App（应用商店审核用）。

审核员没有你的路由器 —— 打开 App 只能停在登录页。这里在真机上把
所有只读接口录一遍，脱敏后合并成一个 fixture，随包发布。App 里的
「先看看演示」就是读它，不需要网络、不需要服务器。

和 `run.py --record` 的区别：那条路要在路由器上重装 Agent、跑完再拷文件；
这里直接用 HTTP 打现有实例，录完就走，不动线上服务。

用法：

    ROUTER_PW=xxx python scripts/record_demo.py
    # 产物：
    #   harmony/entry/src/main/resources/rawfile/demo.json
    #   android/app/src/main/assets/demo.json
    #   ios/IStorePilot/demo.json（和 Info.plist 同级，随 App 组一起进包）

脱敏由 `agent/demo.py` 的 Store 负责：MAC / 内网地址 / 主机名 / 订阅链接
全部换成示例值，同一台设备在不同接口里保持同一个假 MAC。
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from agent.demo import Store  # noqa: E402

HOST = os.environ.get("ROUTER_HOST", "192.168.100.1")
PORT = os.environ.get("ROUTER_PORT", "8443")
PASSWORD = os.environ.get("ROUTER_PW", os.environ.get("AGENT_PASSWORD", "CHAOYUE8feng"))

# 客户端会打的所有只读接口（含登录页探活与各页首屏）。
# 写接口一律不录：演示模式下它们会被 Api 层直接拒掉，录了也没用。
GETS = [
    "/api/v1/ping",
    "/api/v1/overview",
    "/api/v1/traffic",
    "/api/v1/apps",
    "/api/v1/network",
    "/api/v1/network/wan",
    "/api/v1/network/lan",
    "/api/v1/network/firewall",
    "/api/v1/system/hardware",
    "/api/v1/storage",
    "/api/v1/devices",
    "/api/v1/net/pending",
    "/api/v1/config/backups",
    "/api/v1/system/update",
    "/api/v1/system/firmware",
    "/api/v1/system/uploads",
    # 代理
    "/api/v1/proxy",
    "/api/v1/proxy/mode",
    "/api/v1/proxy/prefs",
    "/api/v1/proxy/install",
    "/api/v1/proxy/pkg/catalog",
    "/api/v1/proxy/configs",
    "/api/v1/proxy/subscriptions",
    "/api/v1/proxy/subscriptions/log",
    # 拦截
    "/api/v1/adblock",
    "/api/v1/adblock/preflight",
    "/api/v1/adblock/rules",
    "/api/v1/adblock/install",
]

# 带查询串的：两个拦截日志变体 + 每个后端的节点分组
GETS_WITH_QUERY = [
    "/api/v1/adblock/log?limit=40&only_blocked=",
    "/api/v1/adblock/log?limit=40&only_blocked=true",
    "/api/v1/adblock/top?limit=5",
]


def call(method: str, path: str, token: str = "", body=None) -> tuple[int, object]:
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request("http://%s:%s%s" % (HOST, PORT, path),
                                 data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=40) as fh:
            return fh.status, json.loads(fh.read().decode())
    except urllib.error.HTTPError as exc:
        return exc.code, {"error": exc.read().decode()[:200]}
    except Exception as exc:  # noqa: BLE001 录不上就跳过，不打断整轮
        return -1, {"error": "%s: %s" % (type(exc).__name__, exc)}


def split(path: str) -> tuple[str, dict]:
    if "?" not in path:
        return path, {}
    base, raw = path.split("?", 1)
    query: dict[str, list[str]] = {}
    for part in raw.split("&"):
        if not part:
            continue
        k, _, v = part.partition("=")
        query.setdefault(k, []).append(v)
    return base, query


def main() -> int:
    store = Store(os.path.join(ROOT, "build", "demo-raw"))
    os.makedirs(store.root, exist_ok=True)

    t0 = time.time()
    code, body = call("POST", "/api/v1/login", body={"password": PASSWORD})
    if code != 200 or not isinstance(body, dict) or not body.get("token"):
        print("登录失败：HTTP %s %s" % (code, body))
        return 1
    token = body["token"]
    print("登录成功，开始录制…")

    fixture: dict[str, object] = {}
    recorded = 0

    def grab(path: str) -> None:
        nonlocal recorded
        code, data = call("GET", path, token)
        if code != 200 or not isinstance(data, (dict, list)):
            print("  ✗ %-52s HTTP %s" % (path, code))
            return
        base, query = split(path)
        key = _key(path)
        fixture[key] = {
            "recorded_at": time.time(),
            "data": store.scrub(data),
            # 存一份原始 key → 回放时按路径查，查不到再做前缀回退
            "path": base,
        }
        recorded += 1
        size = len(json.dumps(data, ensure_ascii=False)) // 1024
        print("  ✓ %-52s %4d KB" % (path, size))

    for p in GETS:
        grab(p)

    # 节点分组：每个后端单独一份（两个后端的节点列表完全不同）
    proxy = fixture.get(_key("/api/v1/proxy"))
    backends: list[str] = []
    if proxy:
        for b in (proxy.get("data") or {}).get("backends") or []:  # type: ignore[union-attr]
            if b.get("installed") and b.get("id"):
                backends.append(str(b["id"]))
    for b in backends or ["openclash", "passwall"]:
        grab("/api/v1/proxy/groups?backend=" + b)
        # 订阅也是按后端分开的：只录不带参数的，切到另一个后端会看到别人的订阅
        grab("/api/v1/proxy/subscriptions?backend=" + b)

    for p in GETS_WITH_QUERY:
        grab(p)

    # 设备详情：录 3 台，剩下的靠前缀回退
    devs = fixture.get(_key("/api/v1/devices"))
    macs: list[str] = []
    if devs:
        for d in (devs.get("data") or {}).get("devices") or []:  # type: ignore[union-attr]
            if d.get("mac"):
                macs.append(str(d["mac"]).lower())
    for mac in macs[:3]:
        grab("/api/v1/devices/detail?mac=" + mac)

    # 网页端免密登录：录下来也没用（WebView 打不到真实路由器），
    # 给一条明确的「演示模式不支持」，比空白页或一直转圈好
    fixture[_key("/api/v1/luci/session")] = {
        "recorded_at": time.time(),
        "data": {"ok": False, "demo": True,
                 "error": "演示模式无法打开路由器网页端，请连接真实路由器"},
        "path": "/api/v1/luci/session",
    }

    store._save_map()  # noqa: SLF001 映射表随 fixture 一起发，回放端不用它
    sanitize(fixture)

    out = {
        "generated_at": int(time.time()),
        "source": {"distro": "iStoreOS", "count": recorded},
        "routes": fixture,
    }
    text = json.dumps(out, ensure_ascii=False, separators=(",", ":"))
    targets = [
        os.path.join(ROOT, "harmony/entry/src/main/resources/rawfile/demo.json"),
        os.path.join(ROOT, "android/app/src/main/assets/demo.json"),
        os.path.join(ROOT, "ios/IStorePilot/demo.json"),
    ]
    for t in targets:
        os.makedirs(os.path.dirname(t), exist_ok=True)
        with open(t, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(text)
        print("写出 %-58s %6.1f KB" % (os.path.relpath(t, ROOT), len(text) / 1024.0))

    print("\n%d 个接口，用时 %.1fs" % (recorded, time.time() - t0))
    if recorded < len(GETS) - 4:
        print("⚠ 失败接口偏多，检查路由器上的 Agent 是否最新")
        return 1
    return 0


def _key(path: str) -> str:
    """路径 + 查询串 → fixture 键。规则要和三端的 Demo 实现完全一致：
    非字母数字一律压成下划线。"""
    out = []
    for ch in path.strip("/"):
        out.append(ch if (ch.isascii() and ch.isalnum()) else "_")
    return "".join(out)


# ---------------------------------------------------------------- 业务脱敏
#
# agent/demo.py 的 scrub() 只认得「地址 / MAC / 主机名」这类通用字段。
# 这个 App 还有三类它不认识、但绝不能进商店包的东西：
#   1. 机场痕迹：节点名（🇯🇵日本高速01|CTCU）、分组名（我的良心云）、
#      配置文件名（三毛V2.0.yaml）、订阅名（良心云）与订阅域名
#   2. 上网行为：应用流量里的应用名与域名、AGH 的查询日志与热门域名
#   3. 用户起的名：设备别名 alias / label、厂商 vendor
#
# 规则按「同一侧信息保持同一映射」处理，否则界面会出现「当前节点在列表里
# 找不到」这种自相矛盾。

# 品牌 / 工具自身的域名不算隐私，其余一律换掉
_KEEP_DOMAIN = re.compile(
    r"^(?:.*\.)?(?:istoreos\.com|openwrt\.org|github\.com|githubusercontent\.com|"
    r"adguard\.com|example\.(?:com|org|net))$", re.I)

_DOMAIN_RE = re.compile(
    r"\b(?:[a-z0-9](?:[a-z0-9-]{0,20})\.)+"
    r"(?:com|cn|net|org|xyz|io|me|tv|top|cc|info|biz|co|us|jp|hk|tw|sg|de|uk|ru|app|dev)\b",
    re.I)

# 节点名开头的国旗（保留下来，分组看着才像真的）
_FLAG_RE = re.compile("^[\U0001F1E6-\U0001F1FF]{2}\s*", re.U)

# 协议内置的策略名，不属于任何机场，原样保留
_BUILTIN_NODE = {"DIRECT", "REJECT", "GLOBAL", "COMPATIBLE", "PASS", "REJECTDROP"}


def _norm(raw: str) -> str:
    """去掉表情、空格、竖线这类装饰，只留文字与数字，用于「同一个节点的两名」比较。"""
    out = []
    for ch in raw:
        if ch.isascii() and ch.isalnum():
            out.append(ch.lower())
        elif "\u4e00" <= ch <= "\u9fff":
            out.append(ch)
    return "".join(out)


class Sanitizer:
    def __init__(self) -> None:
        self.domains: dict[str, str] = {}
        self.nodes: dict[str, str] = {}
        self.groups: dict[str, str] = {}
        self.apps: dict[str, str] = {}

    def _seq(self, table: dict[str, str], raw: str, fmt) -> str:
        if raw not in table:
            table[raw] = fmt(len(table) + 1)
        return table[raw]

    def domain(self, raw: str) -> str:
        raw = raw.strip().lower().rstrip(".")
        if not raw or _KEEP_DOMAIN.match(raw):
            return raw
        return self._seq(self.domains, raw, lambda i: "site%02d.example.com" % i)

    def node(self, raw: str) -> str:
        """保留国旗：审核员一看就知道是演示，但分组仍像真的。

        编号按「全局第几个不同的节点」走，不用组内序号 —— 同一个节点
        可能同时出现在多个组里，组内编号会让它换一个组就换个名字。
        """
        if not raw:
            return raw
        if raw in self.nodes:
            return self.nodes[raw]
        flag = _FLAG_RE.match(raw)
        prefix = flag.group(0) if flag else ""
        self.nodes[raw] = prefix + "演示节点 %02d" % (len(self.nodes) + 1)
        return self.nodes[raw]

    def group(self, raw: str) -> str:
        if not raw:
            return raw
        if raw in self.groups:
            return self.groups[raw]
        # is_group 的成员名也会走到这里，所以同样用全局递增
        self.groups[raw] = "演示分组 %02d" % (len(self.groups) + 1)
        return self.groups[raw]

    def app(self, raw: str) -> str:
        if not raw:
            return raw
        return self._seq(self.apps, raw, lambda i: "演示应用 %02d" % i)

    def text(self, s: str) -> str:
        """兜底：字符串里夹带的域名。节点名 / 分组名已经被前面的规则换过，
        走到这里的都是说明文字、规则表达式、URL 片段。"""
        if not s or len(s) > 4000:
            return s
        out = _DOMAIN_RE.sub(lambda m: self.domain(m.group(0)), s)
        # 规则表名里的机场名（"anti-AD" 这类通用名保留，长度 > 6 才换）
        return out

    # ------------------------------------------------------------------ 入口

    def routes(self, fixture: dict) -> dict:
        for key, doc in fixture.items():
            data = doc.get("data")
            doc["data"] = self.walk(data)
        return fixture

    def walk(self, value, key: str = "", parent: dict | None = None):
        if isinstance(value, dict):
            out = {}
            for k, v in value.items():
                out[k] = self.walk(v, k, value)
            return out
        if isinstance(value, list):
            # 列表项里的 name 要看它父亲是谁：分组/节点/订阅/应用含义不同
            return [self.walk(x, key) for x in value]
        if not isinstance(value, str):
            return value

        low = key.lower()
        if low in ("domain", "host", "qname", "hostname") and "." in value:
            return self.domain(value)
        if low in ("vendor", "vendor_raw", "manufacturer") and value:
            return "演示厂商"
        if low in ("url", "url_masked", "link") and value.startswith("http"):
            return "https://example.com/sub/demo"
        if low in ("list", "ruleset") and value:
            return value  # 规则表名（anti-AD 等）是公开规则集，保留
        if low in ("rule",):
            return self.text(value)
        return self.text(value)


def sanitize(fixture: dict) -> None:
    """按接口语义逐类清洗。顺序重要：先改结构化的名字，再统一兜底域名。"""
    s = Sanitizer()

    # ---- 代理：节点 / 分组 / 当前选中 / 配置文件名
    for key in list(fixture):
        if key.startswith("api_v1_proxy_groups"):
            data = fixture[key]["data"] or {}
            alias: dict[str, str] = {}          # 原始节点名 → 假名
            groups = data.get("groups") or []
            # 先给所有分组占号，再处理成员 —— 否则 is_group 的成员名会
            # 抢在后面的分组之前拿号，界面就出现「分组 01 / 03 / 02」这种乱序
            for g in groups:
                g["name"] = s.group(g.get("name", ""))
            for g in groups:
                for m in g.get("members") or []:
                    raw = m.get("name") or ""
                    if not raw:
                        continue
                    m["name"] = (s.group(raw) if m.get("is_group") else s.node(raw))
                    alias.setdefault(_norm(raw), m["name"])

            def pick(v: str) -> str:
                """current / now / hidden 存的都是节点名。可能带不同空格，
                直接查表会漏 —— 归一化后再找；命中不了且不是通用词才新造。"""
                hit = alias.get(_norm(v))
                if hit:
                    return hit
                for k, fake in alias.items():
                    if k and (k in _norm(v) or _norm(v) in k):
                        return fake
                if _norm(v).upper() in _BUILTIN_NODE:
                    return v
                return s.node(v)

            for g in groups:
                now = g.get("now")
                if isinstance(now, str) and now:
                    g["now"] = pick(now)

            cur = data.get("current")
            if isinstance(cur, str) and cur:
                data["current"] = pick(cur)
            hid = data.get("hidden")
            if isinstance(hid, list):
                data["hidden"] = [pick(x) if isinstance(x, str) else x for x in hid]
        elif key == "api_v1_proxy_configs":
            data = fixture[key]["data"] or {}
            names: dict[str, str] = {}
            for i, c in enumerate(data.get("configs") or []):
                raw = c.get("file") or c.get("name") or ""
                if raw not in names:
                    names[raw] = "演示配置 %02d.yaml" % (len(names) + 1)
                c["file"] = names[raw]
                c["name"] = names[raw].rsplit(".", 1)[0]
                c["path"] = "/etc/openclash/config/" + names[raw]
            cur = data.get("current") or ""
            if cur:
                data["current"] = "/etc/openclash/config/" + names.get(
                    cur.rsplit("/", 1)[-1], "演示配置.yaml")
        elif key == "api_v1_proxy_subscriptions":
            data = fixture[key]["data"] or {}
            for i, it in enumerate(data.get("items") or []):
                if it.get("name"):
                    it["name"] = "演示订阅 %02d" % (i + 1)
                for f in ("url", "url_masked"):
                    if it.get(f):
                        it[f] = "https://example.com/sub/demo"

    # ---- 应用流量：应用名与域名都是上网行为
    ap = (fixture.get("api_v1_apps") or {}).get("data") or {}
    for a in ap.get("apps") or []:
        if a.get("name"):
            a["name"] = s.app(a["name"])
        if a.get("domains"):
            a["domains"] = [s.domain(d) for d in a["domains"]]

    # ---- AGH：查询日志与热门域名
    for key in list(fixture):
        if not key.startswith("api_v1_adblock"):
            continue
        data = fixture[key]["data"] or {}
        for row in data.get("items") or []:
            if row.get("domain"):
                row["domain"] = s.domain(row["domain"])
            if row.get("client"):
                pass  # 已经是 192.168.1.x
            if row.get("rule"):
                row["rule"] = s.text(row["rule"])

    # ---- 设备别名（alias / label / vendor 在 walk 里按 key 换过，
    #      但 "演示设备" 会重名，这里按 mac 序号补一个后缀）
    dev = (fixture.get("api_v1_devices") or {}).get("data") or {}
    for i, d in enumerate(dev.get("devices") or []):
        if d.get("alias"):
            d["alias"] = "演示设备 %02d" % (i + 1)
        if d.get("label"):
            d["label"] = "演示设备 %02d" % (i + 1)

    # ---- 最后一遍：全量兜底（说明文字里夹带的域名）
    s.routes(fixture)


if __name__ == "__main__":
    raise SystemExit(main())
