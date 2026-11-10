"""iStoreOS 插件包源。

按系统版本分流 —— 这是上游仓库自己的组织方式，不是我们挑的：

===========  =======================================  ==========================
系统版本      来源                                      形态
===========  =======================================  ==========================
22.03        ``AUK9527/Are-u-ok`` 的 ``x86/`` ``apps/``  目录里的 .run，README 列表
24.10        ``bcseputetto/Are-u-ok`` 的 release         资产页，按架构分开发
25.12        ``bcseputetto/Are-u-ok`` 的 release         同上
===========  =======================================  ==========================

24.10 / 25.12 已经整体迁到 ``bcseputetto`` 名下了（原仓库根 README 里就写着
「插件由 bcseputetto 维护」），而且 24.10 的 release 说明里明确讲
「24.10 的 .run 包会自动处理从 22.03 固件升级过来的依赖问题」——
所以版本选错不是「装得慢一点」，是依赖对不上。

架构也要对：同一个 release 里 PassWall 分 ``x86_64`` / ``aarch64_a53`` /
``aarch64_a72`` / ``aarch64_generic`` 四个包，下错了根本跑不起来。
OpenClash 例外，它只发 ``x86_64`` 和 ``aarch64`` 两种。

为什么不用 GitHub API 列资产（三条路都试过，全堵）：

- ``api.github.com`` 直接 403 —— 未认证限流 60 次/小时，国内还常被拦。
- ``data.jsdelivr.com`` 列目录 403：整个仓库超过 50 MB，jsDelivr 不接。
- ``cdn.jsdelivr.net`` 单文件上限 20 MB，而 PassWall 81 MB、OpenClash 20.4 MB。

能用的是 ``github.com/<repo>/releases/expanded_assets/<tag>`` —— 一个 150 KB
的 HTML 片段，里面就是资产文件名列表，不需要认证也不走 API。
"""

from __future__ import annotations

import json
import os
import platform
import re
import shutil
import socket
import ssl
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

UA = "istore-agent"

# 只认这三个：PassWall2 与 PassWall 会互相冲突，装之前要提示。
BACKENDS = {
    "openclash": {"label": "OpenClash", "prefix": "OpenClash_", "pkg": "luci-app-openclash"},
    "passwall": {"label": "PassWall", "prefix": "PassWall_", "pkg": "luci-app-passwall"},
    "passwall2": {"label": "PassWall2", "prefix": "PassWall2_", "pkg": "luci-app-passwall2"},
}

# 内置兜底池：远程清单拉不到时用。(id, 前缀, 说明)，空前缀表示直连。
# 实测（2026-11-10，真实直连环境）：15 个社区常见镜像里只有 gh-proxy / ghfast
# 能用，且速度在 37～2379 KB/s 之间剧烈波动、两者快慢还会反转 —— 所以绝不能
# 死顺序，必须每次下载前实测（见 rank_channels / download_any）。
CHANNELS: list[tuple[str, str, str]] = [
    ("direct", "", "直连"),
    ("ghproxy", "https://gh-proxy.com/", "gh-proxy"),
    ("ghfast", "https://ghfast.top/", "ghfast"),
    ("ghproxy_net", "https://ghproxy.net/", "ghproxy.net"),
]

# 远程候选池：改仓库里的 agent/mirrors.json 即对所有设备生效，不用发版。
# 必须用 jsDelivr 而不是 GitHub raw —— 后者本身就要加速，拉清单成了鸡生蛋。
# jsDelivr 国内实测 0.49~1.99 秒可达。
MIRRORS_URLS = (
    "https://cdn.jsdelivr.net/gh/zifeng-chen/istore-pilot@main/agent/mirrors.json",
    "https://gcore.jsdelivr.net/gh/zifeng-chen/istore-pilot@main/agent/mirrors.json",
)
_MIRRORS_TTL = 24 * 3600.0
_mirrors_cache: dict = {"ts": 0.0, "channels": []}

# 拉资产列表（HTML）时按这个顺序：直连最稳，镜像反代 HTML 会间歇性 TLS 断
TEXT_ORDER = ["direct", "ghproxy", "ghfast", "ghproxy_net"]
# 拉大文件时按这个顺序：反代比直连快一个数量级，实测 97 KB/s vs 16 KB/s
FILE_ORDER = ["ghproxy", "direct", "ghfast", "ghproxy_net"]

TREE_REPO = "AUK9527/Are-u-ok"
TREE_BRANCH = "main"
# 24.10 / 25.12 的 releases 在另一个仓库
REL_REPO = "bcseputetto/Are-u-ok"
REL_TAGS = {"24.10": "iStoreOS_24.10", "25.12": "iStoreOS_25.12"}

_INDEX_TTL = 900.0
_index_cache: dict = {"ts": 0.0, "key": "", "data": {}}
_profile_cache: dict = {"ts": 0.0, "data": {}}

_ASSET_RE = re.compile(r'/releases/download/[^"]+?/([^"/]+\.run)')
_VER_RE = re.compile(r"_(\d+(?:\.\d+)+)")


# --------------------------------------------------------------- 系统画像


def _read_release() -> dict:
    info: dict[str, str] = {}
    try:
        with open("/etc/openwrt_release", "r", encoding="utf-8") as fh:
            for line in fh:
                if "=" not in line:
                    continue
                key, _, val = line.partition("=")
                info[key.strip()] = val.strip().strip("'\"")
    except OSError:
        pass
    return info


def _family(release: str) -> str:
    """24.10 / 25.12 走新仓库；其余（22.03、23.05、自己编的）走老目录树。"""
    if release.startswith("25.12"):
        return "25.12"
    if release.startswith("24.10"):
        return "24.10"
    return "22.03"


def system_profile() -> dict:
    """发行版 + 架构 + 该走哪个源。缓存 60 秒：这几项运行期不会变。"""
    now = time.time()
    if _profile_cache["data"] and now - _profile_cache["ts"] < 60:
        return dict(_profile_cache["data"])

    info = _read_release()
    release = info.get("DISTRIB_RELEASE", "")
    arch = info.get("DISTRIB_ARCH", "") or platform.machine()
    family = _family(release)
    data = {
        "distro": info.get("DISTRIB_ID", ""),
        "release": release,
        "arch": arch,
        "family": family,
        "repo": REL_REPO if family in REL_TAGS else TREE_REPO,
        "tag": REL_TAGS.get(family, ""),
        "kind": "release" if family in REL_TAGS else "tree",
    }
    _profile_cache.update(ts=now, data=data)
    return dict(data)


def _arch_marker(arch: str, backend: str) -> str:
    """DISTRIB_ARCH → 文件名里的架构片段。

    OpenClash 只发两个变体，而且是 ``+x86_64_core`` / ``+aarch64_core`` 这种
    带加号的形式；PassWall 是 ``_x86_64_`` / ``_aarch64_a53_`` 这种。
    直接拿 ``_aarch64_`` 去匹配 PassWall 会把 a53/a72/generic 三个都命中，
    所以两边必须分开写。
    """
    a = (arch or "").lower()
    if backend == "openclash":
        return "+x86_64_core" if a.startswith("x86") else "+aarch64_core"
    if a.startswith("x86"):
        return "_x86_64_"
    if "a53" in a:
        return "_aarch64_a53_"
    if "a72" in a:
        return "_aarch64_a72_"
    return "_aarch64_generic_"


def _tree_dir(arch: str) -> str:
    """22.03 的目录只有两个：x86/ 是 x86_64，apps/ 是 aarch64_cortex-a53。"""
    return "x86" if (arch or "").lower().startswith("x86") else "apps"


# ------------------------------------------------------------------ 取文本


def _open(url: str, timeout: float):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    return urllib.request.urlopen(req, timeout=timeout)


def _remote_channels() -> list[tuple[str, str, str]]:
    """从 jsDelivr 拉远程候选池；缓存 24 小时。拉不到返回空（用内置池）。"""
    now = time.time()
    if _mirrors_cache["channels"] and now - _mirrors_cache["ts"] < _MIRRORS_TTL:
        return list(_mirrors_cache["channels"])
    for url in MIRRORS_URLS:
        try:
            with _open(url, 8) as resp:
                data = json.loads(resp.read().decode("utf-8", "replace"))
            chans = [(str(c["id"]), str(c["prefix"]), str(c.get("label") or c["id"]))
                     for c in data.get("channels") or []
                     if c.get("id") and isinstance(c.get("prefix"), str)]
            if chans:
                _mirrors_cache.update(ts=now, channels=chans)
                return list(chans)
        except (urllib.error.URLError, OSError, ValueError, KeyError, TypeError):
            continue
    return []


def all_channels() -> list[tuple[str, str, str]]:
    """远程池 + 内置池合并（按 id 去重，远程优先）。"""
    remote = _remote_channels()
    seen = {c[0] for c in remote}
    return remote + [c for c in CHANNELS if c[0] not in seen]


_mirror_paths_cache: dict = {"ts": 0.0, "map": {}}


def _mirror_paths() -> dict[str, str]:
    """id → 前缀映射；缓存 5 分钟，避免每次下载都重新合并。"""
    now = time.time()
    if _mirror_paths_cache["map"] and now - _mirror_paths_cache["ts"] < 300:
        return _mirror_paths_cache["map"]
    m = {cid: prefix for cid, prefix, _ in all_channels()}
    _mirror_paths_cache.update(ts=now, map=m)
    return m


def _mirror(channel: str, url: str) -> str:
    return _mirror_paths().get(channel, "") + url


def _get_text(url: str, order: list[str] | None = None,
              limit: int = 400000, timeout: float = 20) -> tuple[str, str]:
    """依次换通道拉一小段文本，返回 (正文, 通道 id)。"""
    last = ""
    for cid in (order or TEXT_ORDER):
        try:
            with _open(_mirror(cid, url), timeout) as resp:
                body = resp.read(limit).decode("utf-8", "replace")
            if body:
                return body, cid
        except (urllib.error.URLError, OSError, ValueError) as exc:
            last = str(exc)
    raise LookupError(last or "拿不到内容")


def probe_channels(timeout: float = 6.0) -> list[dict]:
    """并发探一遍通道，给界面显示「哪条路通、多快」。

    探的是 3.4 KB 的 README 而不是大包 —— 但它只测得出 TLS 握手和首包延迟，
    测不出带宽，所以下载顺序不按这个排（见 FILE_ORDER）。
    """
    import concurrent.futures

    url = "https://raw.githubusercontent.com/%s/%s/x86/README.md" % (TREE_REPO, TREE_BRANCH)

    def one(item: tuple[str, str, str]) -> dict:
        cid, prefix, label = item
        started = time.time()
        try:
            with _open(prefix + url, timeout) as resp:
                ok = bool(resp.read(64))
        except (urllib.error.URLError, OSError, ValueError):
            ok = False
        return {
            "id": cid, "label": label, "ok": ok,
            "ms": int((time.time() - started) * 1000) if ok else -1,
        }

    with concurrent.futures.ThreadPoolExecutor(max_workers=len(CHANNELS)) as pool:
        out = list(pool.map(one, CHANNELS))
    out.sort(key=lambda c: (not c["ok"], c["ms"] if c["ms"] >= 0 else 1 << 30))
    return out


# -------------------------------------------------------------------- 清单


def local_version(backend: str) -> str:
    """本机装着的版本，没装返回空串。

    不直接问 proxy：proxy 会 import 本模块，反过来 import 会绕成环。
    """
    spec = BACKENDS.get(backend)
    if not spec:
        return ""
    pkg = spec["pkg"]
    try:
        if shutil.which("opkg"):
            out = subprocess.run(["opkg", "list-installed", pkg], capture_output=True,
                                 timeout=15, check=False).stdout.decode("utf-8", "replace")
            for line in out.splitlines():
                parts = line.split(" - ")
                if len(parts) >= 2 and parts[0].strip() == pkg:
                    return parts[1].strip()
        elif shutil.which("apk"):
            out = subprocess.run(["apk", "info", "-e", pkg], capture_output=True,
                                 timeout=15, check=False).stdout.decode("utf-8", "replace")
            if out.strip():
                return out.strip().rsplit("-", 1)[0]
    except (OSError, subprocess.SubprocessError):
        return ""
    return ""


def _catalog_release(profile: dict) -> tuple[list[dict], str]:
    """24.10 / 25.12：解析 release 资产页，按架构挑出对应的 .run。"""
    url = "https://github.com/%s/releases/expanded_assets/%s" % (
        profile["repo"], profile["tag"])
    html, channel = _get_text(url)
    names: list[str] = []
    seen: set[str] = set()
    for name in _ASSET_RE.findall(html):
        if name not in seen:
            seen.add(name)
            names.append(name)

    items = []
    for backend, spec in BACKENDS.items():
        marker = _arch_marker(profile["arch"], backend)
        pick = next((n for n in names if n.startswith(spec["prefix"]) and marker in n), "")
        if not pick:
            continue
        items.append(_item(
            backend, spec, pick,
            "https://github.com/%s/releases/download/%s/%s"
            % (profile["repo"], profile["tag"], urllib.parse.quote(pick, safe="+._-"))))
    return items, channel


def _catalog_tree(profile: dict) -> tuple[list[dict], str]:
    """22.03：目录里的 README 是 markdown 表格，版本号和下载链接都写在里面。"""
    folder = _tree_dir(profile["arch"])
    url = "https://raw.githubusercontent.com/%s/%s/%s/README.md" % (
        TREE_REPO, TREE_BRANCH, folder)
    text, channel = _get_text(url)

    # 目录名要跟着走：x86/ 是 x86_64，apps/ 是 aarch64_cortex-a53。
    # 写死 x86/all/ 会让 aarch64 那台机器一个包都列不出来。
    pat = re.compile(re.escape(folder) + r"/all/([A-Za-z0-9._+%-]+\.run)")
    files: dict[str, str] = {}
    for name in pat.findall(text):
        for backend, spec in BACKENDS.items():
            if name.startswith(spec["prefix"]) and backend not in files:
                files[backend] = name

    items = []
    for backend, spec in BACKENDS.items():
        name = files.get(backend, "")
        if not name:
            continue
        # 老目录不分架构（x86/ 就是 x86_64），文件名里也没有架构片段
        items.append(_item(
            backend, spec, name,
            "https://raw.githubusercontent.com/%s/%s/%s/all/%s"
            % (TREE_REPO, TREE_BRANCH, folder, urllib.parse.quote(name, safe="+._-"))))
    return items, channel


def _item(backend: str, spec: dict, filename: str, url: str) -> dict:
    ver = (_VER_RE.search(filename) or [None, ""])[1]
    local = local_version(backend)
    return {
        "backend": backend,
        "label": spec["label"],
        "version": ver or "",
        "file": filename,
        "url": url,
        "local": local,
        "newer": _is_newer(ver, local),
        "conflict": "passwall" if backend == "passwall2" else
                    ("passwall2" if backend == "passwall" else ""),
    }


def _is_newer(remote: str, local: str) -> bool:
    """纯数字版本比较。0.47.156 vs 0.48.002 要按段比，不能按字符串。"""
    if not local:
        return True

    def parts(v: str) -> list[int]:
        return [int(x) for x in re.findall(r"\d+", v)[:4]]

    a, b = parts(remote), parts(local)
    if not a:
        return False
    while len(a) < len(b):
        a.append(0)
    while len(b) < len(a):
        b.append(0)
    return a > b


def catalog(force: bool = False) -> dict:
    """当前系统该装哪几个包。key 变化（换了固件）就重算。"""
    profile = system_profile()
    key = "%s|%s|%s" % (profile["family"], profile["arch"], profile["release"])
    now = time.time()
    cached = _index_cache["data"]
    if not force and cached and _index_cache["key"] == key and now - _index_cache["ts"] < _INDEX_TTL:
        return dict(cached)

    try:
        if profile["kind"] == "release":
            items, channel = _catalog_release(profile)
        else:
            items, channel = _catalog_tree(profile)
    except (urllib.error.URLError, OSError, LookupError) as exc:
        return {"ok": False, "items": [], "channel": "", "error": str(exc), **profile}

    data = {"ok": bool(items), "channel": channel, "fetched": int(now), "items": items, **profile}
    if items:
        _index_cache.update(ts=now, key=key, data=data)
    return data


def forget_cache() -> None:
    """装完或卸载后清单里的「本机版本」就过期了，清掉让下次重算。

    不清的话会出现「刚卸载完，弹窗里还写着本机已装、可升级」—— 那份数据
    是 15 分钟前算的，local 字段压根没变。
    """
    _index_cache.update(ts=0.0, key="", data={})


# -------------------------------------------------------------------- 下载


class SlowChannel(Exception):
    """通道太慢，换一条重来。"""


def download(channel: str, url: str, dest: str, on_tick=None,
             timeout: float = 600.0, floor_bps: float = 20 * 1024) -> int:
    """流式下载，边写边回调 ``on_tick(got, total)``。返回字节数。

    开头的 512 KB 里盯一次速度：低于 ``floor_bps`` 就抛 SlowChannel 换路。
    阈值不能定太高 —— 实测这条宽带只有 16~97 KB/s，卡 40 KB/s 会把本来
    能下的通道全部拒掉。
    """
    started = time.time()
    got = 0
    tmp = dest + ".part"
    try:
        with _open(_mirror(channel, url), timeout) as resp:
            try:
                total = int(resp.headers.get("Content-Length") or 0)
            except (TypeError, ValueError):
                total = 0
            with open(tmp, "wb") as fh:
                while True:
                    chunk = resp.read(65536)
                    if not chunk:
                        break
                    fh.write(chunk)
                    got += len(chunk)
                    if on_tick:
                        on_tick(got, total)
                    if got <= 524288:
                        elapsed = time.time() - started
                        if elapsed > 15 and got < 65536:
                            raise SlowChannel("%s 15 秒只下了 %d KB"
                                              % (channel, got // 1024))
                        if elapsed > 5 and got / elapsed < floor_bps:
                            raise SlowChannel("%s 只有 %d KB/s"
                                              % (channel, int(got / elapsed / 1024)))
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise
    os.replace(tmp, dest)
    return got


class DownloadFailed(LookupError):
    """所有通道都失败。

    ``slow`` 区分两种完全不同的情况：链路是通的但太慢（用户该改用本地传包），
    还是根本连不上（用户该查 DNS / 代理）。混在一起说「连不上」会误导人 ——
    实测四个通道都能握手、只是 4 KB/s 时报的就是这句。
    """

    def __init__(self, msg: str, slow: bool) -> None:
        super().__init__(msg)
        self.slow = slow


PROBE_BYTES = 128 * 1024   # 探针大小：够区分快慢，又不会在慢镜像上等太久
                            # （镜像实测只有 11~112 KB/s，下 256KB 要 2~23 秒）


def _probe_speed(cid: str, url: str, timeout: float = 3.0) -> float | None:
    """下 PROBE_BYTES 测真实带宽（B/s）；失败返回 None。

    用 Range 只取开头一段：要的是「这条路能跑多快」，不是「文件能不能下完」。
    镜像不支持 Range 时会回 200 全量，读够 PROBE_BYTES 就断开，同样能测。
    """
    started = time.time()
    got = 0
    try:
        req = urllib.request.Request(
            _mirror(cid, url),
            headers={"User-Agent": UA, "Range": "bytes=0-%d" % (PROBE_BYTES - 1)})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            while got < PROBE_BYTES:
                chunk = resp.read(65536)
                if not chunk:
                    break
                got += len(chunk)
                if time.time() - started > timeout:
                    break
    except (urllib.error.URLError, OSError, ValueError):
        return None
    elapsed = time.time() - started
    if got <= 0 or elapsed <= 0:
        return None
    return got / elapsed


def rank_channels(url: str, timeout: float = 3.0) -> list[str]:
    """并发实测各反代通道真实带宽，返回按速度降序的可用通道 id。

    不能靠死顺序：实测 gh-proxy 和 ghfast 会在 37～2379 KB/s 之间各自跳动，
    且两者快慢会反转。只有现场测才选得对。

    不探 direct：github 直连基本连不通，探它只会白等一个超时（实测拖慢 6 秒）。
    直连只在 download_any 里当「反代全挂」的最后兜底。
    """
    chans = [c for c in all_channels() if c[0] != "direct"]
    if not chans:
        return []
    with ThreadPoolExecutor(max_workers=len(chans)) as pool:
        results = list(pool.map(lambda c: (c[0], _probe_speed(c[0], url, timeout)), chans))
    ok = [(cid, sp) for cid, sp in results if sp]
    ok.sort(key=lambda x: -x[1])
    return [cid for cid, _ in ok]


def download_any(url: str, dest: str, on_tick=None,
                 order: list[str] | None = None) -> tuple[str, int]:
    """先并发实测带宽、按快慢逐条试；中途掉速自动换下一条。

    ``order`` 覆盖默认：改过 hosts 之后重试时把 direct 提最前，让它优先走
    「已经被 hosts 修正过的直连」，而不是再撞一遍失败的反代。
    """
    if order:
        ranked = list(order)
    else:
        ranked = rank_channels(url)
        if ranked:
            ranked.append("direct")   # 探针只测反代，直连当最后兜底排末尾
        else:
            # 探针全失败（可能镜像不支持 Range / 都慢）：退回内置死顺序再试一次全量，
            # 全量流式下载和 Range 探针是两条不同的路，不能因为探针失败就放弃。
            ranked = ["direct"] + [c[0] for c in CHANNELS if c[0] != "direct"]
    errors: list[str] = []
    slow_hits = 0
    for cid in ranked:
        try:
            return cid, download(cid, url, dest, on_tick)
        except SlowChannel as exc:
            slow_hits += 1
            errors.append("%s: %s" % (cid, exc))
            continue
        except (urllib.error.URLError, OSError, ValueError) as exc:
            errors.append("%s: %s" % (cid, exc))
            continue
    raise DownloadFailed(
        "所有通道都下载失败：" + "；".join(errors[-4:]),
        slow=bool(errors) and slow_hits == len(errors),
    )


def looks_like_run(path: str) -> bool:
    """挡掉「下回来一个 HTML 拦截页」。.run 以 ``#!/bin/sh`` 开头。"""
    try:
        if os.path.getsize(path) < 65536:
            return False
        with open(path, "rb") as fh:
            head = fh.read(64)
        return head.startswith(b"#!") or head.startswith(b"\x1f\x8b")
    except OSError:
        return False


# ------------------------------------------------------------- hosts 兜底


# 下载链路会碰到的 github 域名：release 页面 / expanded_assets 走 github.com，
# 22.03 的 raw 目录走 raw.githubusercontent.com，release 资产 302 到下面两个。
GH_HOSTS = (
    "github.com",
    "raw.githubusercontent.com",
    "objects.githubusercontent.com",
    "release-assets.githubusercontent.com",
    "codeload.github.com",
)

HOSTS_PATH = "/etc/hosts"


def _doh_resolve(domain: str) -> list[str]:
    """腾讯 DoH 查 A 记录，绕过本机被污染的 DNS。返回 IP 列表（去重保序）。"""
    url = "https://doh.pub/dns-query?name=%s&type=A" % urllib.parse.quote(domain)
    req = urllib.request.Request(url, headers={"Accept": "application/dns-json"})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode("utf-8", "replace"))
    except (urllib.error.URLError, OSError, ValueError):
        return []
    ips: list[str] = []
    seen: set[str] = set()
    for a in data.get("Answer") or []:
        ip = a.get("data", "")
        if a.get("type") == 1 and ip and ip not in seen:
            seen.add(ip)
            ips.append(ip)
    return ips


# 内置候选 IP：DoH 返回的第一个往往是被限速/被 RST 的（实测 20.205.243.166
# 直连 6 秒还 RST，而 140.82.112.3 只要 1.66 秒）。github.com 用 140.82 段，
# 其余（raw / objects / release-assets / codeload）都挂在 Fastly 的 185.199 段。
_BUILTIN_IPS: dict[str, tuple[str, ...]] = {
    "github.com": (
        "140.82.112.3", "140.82.113.3", "140.82.114.3",
        "140.82.116.3", "140.82.121.3", "140.82.121.4",
    ),
    "raw.githubusercontent.com": (
        "185.199.108.133", "185.199.109.133", "185.199.110.133", "185.199.111.133",
    ),
    "objects.githubusercontent.com": (
        "185.199.108.133", "185.199.109.133", "185.199.110.133", "185.199.111.133",
    ),
    "release-assets.githubusercontent.com": (
        "185.199.108.133", "185.199.109.133", "185.199.110.133", "185.199.111.133",
    ),
    "codeload.github.com": (
        "140.82.112.9", "140.82.113.9", "140.82.114.9", "140.82.116.9",
    ),
}


def _tls_probe(domain: str, ip: str, timeout: float = 3.0) -> float | None:
    """TLS 握手耗时（毫秒），用真实域名做 SNI；失败/超时返回 None。

    不能只看 TCP：实测 140.82.116.3 TCP 秒连但 TLS 卡 6 秒，140.82.112.3
    TLS 只要 1.66 秒。只有 TLS 层才反映「能不能真把 HTTPS 建起来」。
    """
    try:
        ctx = ssl.create_default_context()
        started = time.time()
        with socket.create_connection((ip, 443), timeout=timeout) as sock:
            with ctx.wrap_socket(sock, server_hostname=domain) as _:
                return (time.time() - started) * 1000
    except (OSError, ssl.SSLError, ValueError):
        return None


def _pick_ip(domain: str) -> str:
    """从内置候选 + DoH 结果里挑 TLS 握手最快能连通的 IP；都不通返回空串。"""
    candidates: list[str] = list(_BUILTIN_IPS.get(domain, ()))
    candidates.extend(_doh_resolve(domain))
    seen: set[str] = set()
    uniq = [ip for ip in candidates if ip and not (ip in seen or seen.add(ip))]
    if not uniq:
        return ""
    # 并发探，总耗时约等于最慢的那个（3 秒），而不是串行累加
    with ThreadPoolExecutor(max_workers=len(uniq)) as pool:
        results = list(pool.map(lambda ip: (ip, _tls_probe(domain, ip)), uniq))
    best_ip, best_ms = "", None
    for ip, ms in results:
        if ms is not None and (best_ms is None or ms < best_ms):
            best_ip, best_ms = ip, ms
    return best_ip


def fix_github_hosts() -> tuple[bool, str]:
    """往 /etc/hosts 写入 github 核心域名的可用 IP，绕过 DNS 污染。

    每个域名从「内置候选 + DoH」里挑 TCP 443 最快能连通的 IP 写进去
    （不是随手写 DoH 第一个 —— 那常常是被 RST 的）。返回 (ok, 说明)。
    写之前先把原文件备份到 /etc/hosts.bak，并清掉旧的 github 行，避免重复。
    """
    try:
        with open(HOSTS_PATH, "r", encoding="utf-8") as fh:
            original = fh.read()
    except OSError as exc:
        return False, "读不到 %s：%s" % (HOSTS_PATH, exc)

    try:
        with open(HOSTS_PATH + ".bak", "w", encoding="utf-8") as fh:
            fh.write(original)
    except OSError:
        pass  # 备份失败不阻断，原内容还在内存里

    keep = [ln for ln in original.splitlines()
            if not any(dom in ln for dom in GH_HOSTS)]
    added: list[str] = []
    for dom in GH_HOSTS:
        ip = _pick_ip(dom)
        if ip:
            keep.append("%s %s" % (ip, dom))
            added.append("%s %s" % (ip, dom))
    if not added:
        return False, "没找到 github 域名能连通的 IP"

    try:
        with open(HOSTS_PATH, "w", encoding="utf-8") as fh:
            fh.write("\n".join(keep) + "\n")
    except OSError as exc:
        return False, "写 %s 失败：%s" % (HOSTS_PATH, exc)
    return True, "已写入 %d 条 hosts（备份在 %s.bak）" % (len(added), HOSTS_PATH)
