"""代理后端抽象层。

路由器上可能同时装着 OpenClash 和 Passwall，两者互斥运行：
  - OpenClash 有 external-controller，可以实时查询与热切换
  - Passwall 没有运行时 API，只能读 uci 配置 + 重启服务生效

本模块把两者的差异吃掉，对外只给一套模型：
  backend  = openclash | passwall
  group    = 策略组（clash 的 selector / passwall 的节点分组）
  select   = 切换当前节点
"""

from __future__ import annotations

import gzip
import json
import os
import platform
import re
import shutil
import socket
import threading
import time
import urllib.error
import urllib.request
from urllib.parse import urlsplit

from . import clash, config, pkgfeed, sysinfo

INIT = {
    "openclash": "/etc/init.d/openclash",
    "passwall": "/etc/init.d/passwall",
}

LABEL = {"openclash": "OpenClash", "passwall": "Passwall"}

_socks_port = {"openclash": 7891, "passwall": 1070}


def _sync_dns() -> None:
    """代理起停后，AGH 的上游要跟着变。

    否则关掉 OpenClash 时，AGH 还指着没人监听的 7874，整个网络 DNS 全挂
    （只有不查 DNS 的 IoT 看起来正常）。延迟 import 避免和 adblock 循环依赖。
    """
    try:
        from . import adblock
        adblock.sync_upstream()
    except Exception:  # noqa: BLE001 —— 同步失败不能影响代理操作本身
        pass


# --------------------------------------------------------------- 基础工具


def _run(args: list[str], timeout: float = 8.0) -> tuple[int, str]:
    # 实现只有一份（sysinfo.run_code），超时默认值各模块自己定
    return sysinfo.run_code(args, timeout=timeout)


def _uci_get(key: str) -> str:
    code, out = _run(["uci", "get", key], timeout=4)
    return out.strip() if code == 0 else ""


def _uci_show(pkg: str) -> dict[str, str]:
    """展开 `uci show` 为 {section.option: value} 扁平表。"""
    code, out = _run(["uci", "show", pkg], timeout=6)
    if code != 0:
        return {}
    flat: dict[str, str] = {}
    for line in out.splitlines():
        if "=" not in line:
            continue
        key, _, raw = line.partition("=")
        flat[key.strip()] = raw.strip().strip("'")
    return flat


def _installed(backend: str) -> bool:
    return os.path.exists(INIT[backend])


def _preview_hidden() -> set[str]:
    """界面预览用：/tmp/istore-agent-preview 里写后端名，就当成「没装」显示。

    为什么需要它：这两个包不在任何软件源里，卸了就装不回来（实测
    `opkg download` 直接报 not available），没法用真卸载来验空态。
    只影响返回给客户端的 installed 字段，**不影响安装/卸载判断**，
    也不动系统；/tmp 重启即清空，不会留在生产环境。
    """
    try:
        with open("/tmp/istore-agent-preview", "r", encoding="utf-8") as fh:
            return {x.strip() for x in fh if x.strip()}
    except OSError:
        return set()


def _shown_installed(backend: str) -> bool:
    """给客户端看的 installed：叠一层预览开关。"""
    return backend not in _preview_hidden() and _installed(backend)


# ------------------------------------------------- 安装：系统、软件源、内核
#
# 界面要区分「没装 / 装了没内核 / 源里没有」三种情况，光一个 installed 不够。
# 这三个探测每次 overview 都要跑，所以只读文件与 statvfs；唯一重的
# `opkg list` 单独加了 2 分钟缓存。

PKG = {"openclash": "luci-app-openclash", "passwall": "luci-app-passwall"}

# 装完 luci-app-* 只是拿到界面和脚本，真正的内核要另外下（OpenClash 20~30 MB，
# 从 GitHub 拉，国内经常失败）。这是「装了却启不来」最常见的原因，单独探一次。
CORE = {
    "openclash": ("/etc/openclash/core/clash_meta", "/etc/openclash/core/clash",
                  "/etc/openclash/core/clash_tun"),
    "passwall": ("/usr/bin/xray", "/usr/bin/v2ray", "/usr/bin/sing-box"),
}


def _which(name: str) -> str:
    dirs = (os.environ.get("PATH") or "/usr/sbin:/usr/bin:/sbin:/bin").split(":")
    for d in dirs:
        p = os.path.join(d, name)
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return ""


def pkg_manager() -> str:
    """24.10 及更早是 opkg，25.12 起换成 apk。

    不按版本号猜 —— 混装过源、刷过固件的机器版本号和实际工具未必对得上，
    直接看哪个命令在。
    """
    if _which("apk"):
        return "apk"
    return "opkg" if _which("opkg") else ""


def _release() -> dict:
    """发行版名与版本，读不到就返回空（界面那行直接不显示）。"""
    out: dict[str, str] = {}
    try:
        with open("/etc/openwrt_release", "r", encoding="utf-8") as fh:
            for line in fh:
                if "=" not in line:
                    continue
                key, _, val = line.partition("=")
                out[key.strip()] = val.strip().strip("'\"")
    except OSError:
        return {}
    return {"distro": out.get("DISTRIB_ID", ""), "release": out.get("DISTRIB_RELEASE", "")}


def _free_mb() -> int:
    """overlay 剩余空间。两个插件加内核要 100 MB 上下，16 MB NAND 的机器
    到这一步就该劝退，而不是等 opkg 报 no space。"""
    try:
        st = os.statvfs("/")
        return int(st.f_bavail * st.f_frsize / 1048576)
    except OSError:
        return -1


def core_ready(backend: str) -> bool:
    return any(os.path.exists(p) for p in CORE.get(backend, ()))


_REPO_TTL = 120.0
_repo_cache: dict = {"ts": 0.0, "data": {}}


def _opkg_cache_ready() -> bool:
    for d in ("/var/opkg-lists", "/tmp/opkg-lists"):
        try:
            if os.path.isdir(d) and os.listdir(d):
                return True
        except OSError:
            continue
    return False


def repo_state() -> dict:
    """每个后端在软件源里有没有。

    `opkg list <pkg>` 靠 Packages 索引：从没 `opkg update` 过的机器返回空。
    这时不能断言「源里没有」，标 unknown 让界面提示「先更新源」。
    """
    now = time.time()
    if _repo_cache["data"] and now - _repo_cache["ts"] < _REPO_TTL:
        return dict(_repo_cache["data"])

    mgr = pkg_manager()
    data: dict[str, str] = {}
    for backend, pkg in PKG.items():
        if mgr == "apk":
            code, out = _run(["apk", "search", "-e", pkg], timeout=8)
            data[backend] = "yes" if code == 0 and pkg in out else "no"
        elif mgr == "opkg":
            feeds = [name for name, _ in _feed_entries()]
            if any(_in_feed_index(pkg, f) for f in feeds):
                data[backend] = "yes"
            elif not feeds or not _opkg_cache_ready():
                data[backend] = "unknown"   # 索引还没建，别断言「源里没有」
            else:
                data[backend] = "no"
        else:
            data[backend] = "unknown"
    _repo_cache.update(ts=now, data=data)
    return dict(data)


def _feed_entries() -> list[tuple[str, str]]:
    """当前配置的所有软件源 [(feed 名, URL)]。

    扫 /etc/opkg/*.conf 而不是写死 distfeeds.conf —— iStoreOS 把自家源放在
    单独的文件里（istore.conf），只读 distfeeds 会漏掉它。
    """
    entries: list[tuple[str, str]] = []
    try:
        names = sorted(f for f in os.listdir("/etc/opkg") if f.endswith(".conf"))
    except OSError:
        return entries
    for name in names:
        try:
            with open(os.path.join("/etc/opkg", name), "r", encoding="utf-8") as fh:
                for line in fh:
                    parts = line.split()
                    # src/gz <feed> <url>
                    if len(parts) >= 3 and parts[0].startswith("src"):
                        entries.append((parts[1], parts[2]))
        except OSError:
            continue
    return entries


def _in_feed_index(pkg: str, feed: str) -> bool:
    """包是否出现在某个 feed 的 Packages 索引里。

    不能用 `opkg list <pkg>`：它会把**已安装**的包也列出来，于是「装过的」
    被当成「源里有」，真去装才发现拿不到（实测 luci-app-passwall 就是：
    opkg list 有、opkg download 报 not available from any configured src）。
    """
    want = "Package: " + pkg
    for d in ("/var/opkg-lists", "/tmp/opkg-lists"):
        path = os.path.join(d, feed)
        if not os.path.isfile(path):
            continue
        try:
            # 索引可能是 gzip（iStoreOS 的 istore_compat 就是），按魔数判断，
            # 别假设都是纯文本 —— 当成文本读会一行都匹配不到，于是「源里有」
            # 被误判成「源里没有」。
            with open(path, "rb") as fh:
                packed = fh.read(2) == b"\x1f\x8b"
            opener = gzip.open if packed else open
            with opener(path, "rt", encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    if line.strip() == want:
                        return True
        except (OSError, EOFError):
            continue
    return False


def _probe(host: str, port: int) -> str:
    """探一个主机，通返回空串，否则返回归因码。"""
    if not host:
        return "repo_missing"
    try:
        socket.create_connection((host, port), timeout=3).close()
        return ""
    except socket.gaierror:
        return "dns_failed"
    except OSError:
        return "net_unreachable"


def precheck(backends: list[str]) -> dict:
    """装之前探一次本次会用到的通道。

    两条通道：系统软件源（repo=yes 的包走这条）、GitHub（repo≠yes 的走这条）。
    只探真正会用到的那个 —— 源里没有的包去测 opkg 源毫无意义。
    全部不通才拦下来；通一条就放行，让 worker 在真正失败的那个包上报具体原因。
    """
    repo = repo_state()
    need_source = any(repo.get(b) == "yes" for b in backends)
    need_gh = any(repo.get(b) != "yes" for b in backends)

    probes: list[tuple[str, str, str]] = []      # (通道名, host, 归因码)
    if need_source:
        entries = _feed_entries()
        if not entries:
            probes.append(("软件源", "", "repo_missing"))
        else:
            url = entries[0][1]
            host = urlsplit(url).hostname or ""
            probes.append(("软件源", host, _probe(host, 443 if url.startswith("https") else 80)))
    if need_gh:
        probes.append(("GitHub", "api.github.com", _probe("api.github.com", 443)))

    bad = [p for p in probes if p[2]]
    if probes and len(bad) == len(probes):
        name, host, code = bad[0]
        detail = ("连不上 %s（%s）" % (host, name)) if host else "没有可用的软件源"
        return _err(code, detail=detail, host=host, precheck=True)
    return {"ok": True, "code": "", "detail": "", "host": ""}


def _classify_fetch(exc: BaseException) -> str:
    """下载通道的异常归因。"""
    if isinstance(exc, urllib.error.HTTPError):
        if exc.code == 404:
            return "repo_missing"
        if exc.code in (403, 429):
            return "gh_limited"
        return "net_unreachable"
    if isinstance(exc, urllib.error.URLError):
        if isinstance(getattr(exc, "reason", None), socket.gaierror):
            return "dns_failed"
        return "net_unreachable"
    if isinstance(exc, ValueError):
        return "bad_payload"
    if isinstance(exc, LookupError):
        return "repo_missing"
    return "unknown"


# 归因表：code -> (标题, 建议动作)。动作由客户端渲染成按钮，
# 顺序即优先级；三端不各自猜，照这个顺序摆就行。
ERRORS: dict[str, tuple[str, list[str]]] = {
    "net_unreachable": ("连不上软件源", ["retry", "diagnose", "force"]),
    "dns_failed": ("域名解析失败", ["retry", "diagnose", "force"]),
    "tls_failed": ("源的证书有问题", ["retry", "diagnose", "force"]),
    "repo_missing": ("源里找不到这个包", ["retry", "change_feed"]),
    "no_space": ("存储空间不足", ["retry"]),
    "dep_failed": ("依赖装不上", ["retry", "change_feed"]),
    "locked": ("另一个安装任务正在进行", ["retry"]),
    "gh_limited": ("GitHub 限流了，过一会儿再试", ["retry"]),
    "bad_payload": ("下载到的文件不对", ["retry"]),
    "no_apk_pkg": ("官方只提供 ipk，你的系统是 apk", ["retry", "change_feed"]),
    "no_file": ("上传的安装包不见了", ["retry"]),
    "no_pkg": ("仓库里没有这个插件", ["retry"]),
    "too_slow": ("网速太慢，装不了", ["local", "retry"]),
    "unknown": ("安装失败", ["retry"]),
}


def _classify(raw: str) -> str:
    """把 opkg/apk 的报错归成上面那几类。

    这里的顺序有意义：先认 DNS 再认超时 —— `wget returned 4` 既可能是解析
    失败也可能是连不上，但只有带 "could not resolve" 才是 DNS。
    """
    low = (raw or "").lower()
    if ("could not resolve" in low or "bad address" in low
            or "name or service not known" in low):
        return "dns_failed"
    if "wget returned 5" in low or "ssl" in low or "certificate" in low:
        return "tls_failed"
    if ("wget returned 4" in low or "timed out" in low or "connection refused" in low
            or "network is unreachable" in low):
        return "net_unreachable"
    if "wget returned 8" in low or " 404" in low:
        return "repo_missing"
    if "no space left" in low:
        return "no_space"
    if "cannot install package" in low or "dependenc" in low:
        return "dep_failed"
    if "lock" in low or "resource temporarily unavailable" in low:
        return "locked"
    return "unknown"


def _err(code: str, detail: str = "", raw: str = "", **extra) -> dict:
    title, suggest = ERRORS.get(code, ERRORS["unknown"])
    return {"ok": False, "error_code": code, "error_title": title,
            "detail": detail, "suggest": list(suggest), "raw": raw[-600:], **extra}


def system_info() -> dict:
    rel = _release()
    return {
        "pkg_manager": pkg_manager(),
        "distro": rel.get("distro", ""),
        "release": rel.get("release", ""),
        "arch": platform.machine() or "",
        "free_mb": _free_mb(),
        "repo": repo_state(),
    }


# ------------------------------------------------------- 官方发布页下载
#
# 这两个包**不在 OpenWrt 官方源里**（实测：8 个索引 1 万多个包，一个都没有），
# 用户机器上能装着，多半是当初手动装的。所以「一键安装」只靠 opkg 源没有意义，
# 必须有第二条通道：从各自官方 GitHub release 下 ipk，再本地装。

GH_REPO = {
    "openclash": ("vernesong/OpenClash", r"^luci-app-openclash_.*\.ipk$"),
    "passwall": ("xiaorouji/openwrt-passwall", r"^luci-app-passwall_.*\.ipk$"),
}
GH_API = "https://api.github.com/repos/%s/releases/latest"
GH_UA = "istore-agent (OpenWrt router client)"
_GH_TTL = 3600.0
_gh_cache: dict = {"ts": 0.0, "data": {}}


def _gh_cfg() -> dict:
    return config.get("proxy") or {}


def _gh_asset(backend: str) -> tuple[str, str]:
    """从官方 release 找 ipk 的下载地址，返回 (url, 文件名)。

    来源可在 config.json 的 proxy.gh_repos 里覆盖：写 "owner/repo" 就按那个
    仓库查最新 release，写完整 http 直链就当作固定地址（自建镜像/钉版本）。
    结果缓存一小时：GitHub 未认证 API 限 60 次/小时。
    """
    now = time.time()
    hit = _gh_cache["data"].get(backend)
    if hit and now - _gh_cache["ts"] < _GH_TTL:
        return hit

    override = str((_gh_cfg().get("gh_repos") or {}).get(backend, "") or "")
    if override.startswith("http"):
        return override, (override.rsplit("/", 1)[-1] or PKG[backend] + ".ipk")

    repo, pattern = GH_REPO[backend]
    if override:
        repo = override
    req = urllib.request.Request(
        GH_API % repo,
        headers={"User-Agent": GH_UA, "Accept": "application/vnd.github+json"},
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        data = json.loads(resp.read().decode("utf-8", "replace"))

    for asset in data.get("assets") or []:
        name = asset.get("name") or ""
        url = asset.get("browser_download_url") or ""
        if url and re.match(pattern, name):
            _gh_cache.update(ts=now)
            _gh_cache["data"][backend] = (url, name)
            return url, name
    raise LookupError("发布页里没有 ipk 附件")


def _looks_like_ipk(path: str) -> bool:
    """挡掉「下回来一个 HTML 错误页」这种：opkg 会报一堆看不懂的错。

    ipk 是 gzip / ar / zip 包，但绝不会以 `<` 开头。
    """
    try:
        if os.path.getsize(path) < 8192:
            return False
        with open(path, "rb") as fh:
            return not fh.read(8).lstrip().startswith(b"<")
    except OSError:
        return False


def _fetch(backend: str) -> tuple[str, str]:
    """下载 ipk 到 /tmp，返回 (本地路径, 文件名)。失败抛异常，由调用方归因。"""
    url, name = _gh_asset(backend)
    mirror = str(_gh_cfg().get("gh_mirror", "") or "")
    if mirror:
        url = mirror + url
    dest = os.path.join("/tmp", name)
    req = urllib.request.Request(url, headers={"User-Agent": GH_UA})
    with urllib.request.urlopen(req, timeout=120) as resp, open(dest, "wb") as fh:
        shutil.copyfileobj(resp, fh)
    if not _looks_like_ipk(dest):
        try:
            os.remove(dest)
        except OSError:
            pass
        raise ValueError("下载到的不是 ipk，可能被限流或劫持")
    return dest, name


# ------------------------------------------------------------- 安装任务
#
# 异步跑：`opkg install` 动辄 30~60 秒，同步等会撞客户端超时。
# 状态放模块级，进程内唯一 —— 顺带解决「两个手机同时点」的并发
# （第二个会拿到 already=true，不会真的并发调 opkg）。

_INST: dict = {
    "running": False, "done": False, "ok": False, "pct": 0, "step": "",
    "queue": [], "index": 0, "total": 0, "current": "",
    "installed": [], "failed": [], "partial": False,
    "error": {}, "started": 0.0, "finished": 0.0, "log": [],
}
_INST_LOCK = threading.Lock()


def _istep(pct: int, text: str) -> None:
    with _INST_LOCK:
        _INST["pct"] = max(0, min(100, pct))
        _INST["step"] = text
        _INST["log"] = (_INST["log"] + [time.strftime("%H:%M:%S ") + text])[-12:]


def install_status() -> dict:
    with _INST_LOCK:
        snap = dict(_INST)
        snap["queue"] = list(_INST["queue"])
        snap["installed"] = list(_INST["installed"])
        snap["failed"] = list(_INST["failed"])
        snap["log"] = list(_INST["log"])
    # 顺带把当前状态回给界面，省得装完还要再问一次有没有装好
    snap["backends"] = {b: {"installed": _shown_installed(b), "core_ready": core_ready(b)}
                        for b in PKG}
    # 整包安装（远端下载 / 本地上传）是另一条任务线，合并在这里返回，
    # 客户端轮询一个接口就能同时盯两件事
    snap["pkg"] = pkg_status()
    return snap


def _install_worker(queue: list[str]) -> None:
    mgr = pkg_manager()
    repo = repo_state()
    total = max(1, len(queue))
    network_kinds = ("net_unreachable", "dns_failed", "tls_failed", "gh_limited")

    def fail(backend: str, kind: str, detail: str, raw: str, base: int) -> bool:
        """记一次失败；返回 True 表示后面不必再试（网络类，试也是同样的结果）。"""
        title = ERRORS.get(kind, ERRORS["unknown"])[0]
        with _INST_LOCK:
            _INST["failed"].append(backend)
            _INST["error"] = _err(kind, detail=detail, raw=raw,
                                  backend=backend, pkg=PKG[backend])
        _istep(base + 50, "%s：%s" % (LABEL[backend], title))
        return kind in network_kinds

    for i, backend in enumerate(queue):
        pkg = PKG[backend]
        base = int(i * 100 / total)
        with _INST_LOCK:
            _INST["index"] = i + 1
            _INST["current"] = backend

        in_repo = repo.get(backend) == "yes"
        if in_repo:
            _istep(base + 8, "从软件源安装 %s" % pkg)
            cmd = ["apk", "add", pkg] if mgr == "apk" else ["opkg", "install", pkg]
            code, out = _run(cmd, timeout=600)
        elif mgr == "apk":
            # 上游只发 ipk，apk 系统装不了 —— 与其下回来再报格式错，不如直接说清
            stop = fail(backend, "no_apk_pkg", "OpenClash / Passwall 官方只发布 ipk",
                        "", base)
            break
        else:
            _istep(base + 5, "软件源里没有，改从官方发布页下载")
            try:
                path, fname = _fetch(backend)
            except (urllib.error.URLError, OSError, ValueError, LookupError) as exc:
                kind = _classify_fetch(exc)
                stop = fail(backend, kind, str(exc), "", base)
                if stop:
                    with _INST_LOCK:
                        _INST["failed"].extend([q for q in queue[i + 1:]])
                    break
                continue
            _istep(base + 35, "正在安装 %s" % fname)
            code, out = _run(["opkg", "install", path], timeout=600)

        ok = code == 0 and _installed(backend)
        # 装过时 opkg 会返回非零（"already installed"），但结果是好的
        if not ok and "already installed" in (out or "").lower() and _installed(backend):
            ok = True

        if ok:
            with _INST_LOCK:
                _INST["installed"].append(backend)
            _istep(base + int(80 / total),
                   "%s 安装完成" % LABEL[backend] + ("" if in_repo else "（来自官方发布页）"))
            continue

        last = ""
        for line in reversed((out or "").strip().splitlines()):
            if line.strip():
                last = line.strip()
                break
        stop = fail(backend, _classify(out), last, out or "", base)
        if stop:
            with _INST_LOCK:
                _INST["failed"].extend([q for q in queue[i + 1:]])
            break

    forget_active()
    _repo_cache["ts"] = 0.0          # 装完让源缓存失效，下次重新探
    _gh_cache["ts"] = 0.0
    with _INST_LOCK:
        failed = bool(_INST["failed"])
        _INST.update(running=False, done=True, finished=time.time(), pct=100,
                     ok=not failed, partial=bool(_INST["installed"]) and failed,
                     step="完成" if not failed else "安装失败")


def _preview_worker(queue: list[str]) -> None:
    """预览模式下的假任务：只走一遍进度与失败，不碰系统。

    没有它就没法验界面 —— 真实环境里这两个包源里没有、卸了装不回来，
    但预览时服务端又认为「已经装好」，install() 会直接回 already，
    客户端连进度条都看不到。
    """
    for i, backend in enumerate(queue):
        with _INST_LOCK:
            _INST["index"] = i + 1
            _INST["current"] = backend
        _istep(int(10 + i * 45), "正在安装 %s（预览）" % PKG[backend])
        time.sleep(1.2)

    _istep(92, "预览：模拟一次网络失败")
    time.sleep(0.6)
    with _INST_LOCK:
        _INST["failed"] = list(queue)
        _INST["error"] = _err("net_unreachable",
                              detail="预览模式：不执行真实安装",
                              raw="preview", backend=queue[0], pkg=PKG[queue[0]])
        _INST.update(running=False, done=True, finished=time.time(), pct=100,
                     ok=False, partial=False, step="安装失败")


def install_just_finished() -> bool:
    """装完（无论成败）的 15 秒内返回 True。

    给外面判断要不要打掉 overview 缓存用 —— 否则会出现「刚装完，卡片上
    还写着未安装」的几秒窗口，用户会以为没装上又点一遍。
    """
    with _INST_LOCK:
        done, finished = _INST["done"], _INST["finished"]
    if done and finished and time.time() - finished < 15:
        return True
    # 整包安装同理：装完 15 秒内也要把 overview 的缓存打掉
    with _PKG_LOCK:
        done, finished = _PKG["done"], _PKG["finished"]
    return bool(done and finished and time.time() - finished < 15)


def install(target: str = "all", confirm: str = "", force: bool = False) -> dict:
    """启动安装任务，立刻返回；进度用 install_status() 轮询。

    `target` 只认三个固定值 —— 这个接口最终以 root 跑 opkg，
    绝不能让客户端把包名传进来，否则等于「用 root 装任意包」。
    """
    if target not in ("all", "openclash", "passwall"):
        return {"ok": False, "error": "target 只能是 all / openclash / passwall"}
    if confirm != "install":
        return {"ok": False, "error": "安装需要二次确认：confirm=install"}
    if not pkg_manager():
        return {"ok": False, "error": "这台设备上没有 opkg / apk，无法安装",
                "error_code": "no_pkg_manager", "error_title": "没有包管理器",
                "suggest": []}

    # 预览模式（见 _preview_hidden）：跑假任务，不执行任何安装。
    # 必须放在「都已装好」判断之前 —— 预览时真实系统里两个包都装着，
    # queue 会是空的，先返回 already 就永远走不到这里。
    wanted = [target] if target != "all" else list(PKG)
    preview = sorted(_preview_hidden() & set(wanted))
    if preview:
        with _INST_LOCK:
            _INST.update(running=True, done=False, ok=False, pct=0, step="准备中（预览）",
                         queue=list(preview), index=0, total=len(preview), current="",
                         installed=[], failed=[], partial=False, error={},
                         started=time.time(), finished=0.0, log=[])
        threading.Thread(target=_preview_worker, args=(list(preview),),
                         name="proxy-preview", daemon=True).start()
        return {"ok": True, "accepted": True, "preview": True, "state": install_status()}

    queue = [b for b in PKG if not _installed(b)] if target == "all" else [target]
    queue = [b for b in queue if not _installed(b)]
    if not queue:
        return {"ok": True, "already": True, "installed": True,
                "message": "要装的都已经装好了"}

    if not force:
        check = precheck(queue)
        if not check.get("ok"):
            return _err(check["code"], detail=check["detail"],
                        host=check["host"], precheck=True)

    with _INST_LOCK:
        if _INST["running"]:
            return {"ok": True, "accepted": True, "already": True,
                    "state": install_status()}
        _INST.update(running=True, done=False, ok=False, pct=0, step="准备中",
                     queue=list(queue), index=0, total=len(queue), current="",
                     installed=[], failed=[], partial=False, error={},
                     started=time.time(), finished=0.0, log=[])
    threading.Thread(target=_install_worker, args=(list(queue),),
                     name="proxy-install", daemon=True).start()
    return {"ok": True, "accepted": True, "queue": queue, "state": install_status()}


CONF_PATHS = {
    "openclash": ["/etc/config/openclash", "/etc/openclash"],
    "passwall": ["/etc/config/passwall"],
}


def uninstall(target: str, confirm: str = "") -> dict:
    """卸载插件。

    `opkg remove` 默认保留 `/etc/config/<pkg>`，但 **OpenClash 的 apk 包不这样**：
    实测 25.12 上 `apk del luci-app-openclash` 会连 `/etc/openclash` 和
    `/etc/config/openclash` 一起删掉（订阅 yaml、订阅条目全没）。所以
    `config_kept` 必须按实际残留判断，硬写 true 会让界面告诉用户
    「配置还在」，重装后才发现订阅要重填。
    """
    if target not in ("openclash", "passwall"):
        return {"ok": False, "error": "target 只能是 openclash / passwall"}
    if confirm != "remove":
        return {"ok": False, "error": "卸载需要二次确认：confirm=remove"}
    if not _installed(target):
        return {"ok": True, "already": True, "removed": True, "backend": target}

    mgr = pkg_manager()
    pkg = PKG[target]
    if mgr == "apk":
        code, out = _run(["apk", "del", pkg], timeout=180)
    else:
        code, out = _run(["opkg", "remove", pkg], timeout=180)

    forget_active()
    _repo_cache["ts"] = 0.0
    pkgfeed.forget_cache()
    kept = any(os.path.exists(p) for p in CONF_PATHS.get(target, []))
    return {
        "ok": code == 0 and not _installed(target),
        "backend": target,
        "removed": not _installed(target),
        "config_kept": kept,
        "output": (out or "").strip()[-600:],
    }


# ------------------------------------------------------ 插件包安装（整包）
#
# 跟上面 install() 的分工：
#   install()  走「官方 GitHub release 里的单个 ipk」，小、快，但要求有内核配套
#   pkg_install() 走「一个完整的 .run 安装包」—— 要么从 Are-u-ok 仓库下，
#                 要么用户自己从手机传上来。包里自带内核，装完就能跑。
#
# 为什么必须异步：PassWall 的 .run 有 85 MB，下加装能到几分钟，HTTP 早超时了。
# 状态单独放一份（_PKG），不复用 _INST —— 两者的字段语义差太多，
# 混在一起会让老客户端的进度条跳来跳去。

PKG_DIR = "/tmp/istore-upload"
PKG_TARGETS = ("openclash", "passwall")   # passwall2 与 passwall 冲突，不进白名单
_PKG_RUN_EXT = (".run", ".ipk", ".apk")

_PKG: dict = {
    "running": False, "done": False, "ok": False, "pct": 0, "step": "",
    "target": "", "source": "", "name": "", "channel": "",
    "got": 0, "total": 0, "log": [], "error": {}, "started": 0.0, "finished": 0.0,
}
_PKG_LOCK = threading.Lock()


def _pstep(pct: int, text: str) -> None:
    with _PKG_LOCK:
        _PKG["pct"] = max(0, min(100, pct))
        _PKG["step"] = text
        _PKG["log"] = (_PKG["log"] + [time.strftime("%H:%M:%S ") + text])[-12:]


def _hsize(got: int, total: int) -> str:
    if total > 0:
        return "%d%%（%.1f/%.1f MB）" % (got * 100 // total, got / 1048576, total / 1048576)
    return "%.1f MB" % (got / 1048576)


def _pfail(kind: str, detail: str, raw: str = "", target: str = "") -> None:
    err = _err(kind, detail=detail, raw=raw, backend=target, pkg=PKG.get(target, ""))
    with _PKG_LOCK:
        _PKG.update(running=False, done=True, ok=False, pct=100,
                    finished=time.time(), step="安装失败", error=err)


def _pkg_worker(target: str, source: str, name: str) -> None:
    path = ""
    channel = ""
    got = total = 0

    if source == "github":
        _pstep(3, "正在读取插件清单")
        try:
            cat = pkgfeed.catalog()
        except (urllib.error.URLError, OSError, LookupError) as exc:
            _pfail("net_unreachable", "拿不到插件清单：%s" % exc, "", target)
            return
        item = next((x for x in cat.get("items") or [] if x["backend"] == target), None)
        if not item:
            _pfail("no_pkg", "仓库里没有 %s 的安装包" % LABEL[target], "", target)
            return
        name = item["file"]
        with _PKG_LOCK:
            _PKG["name"] = name

        _pstep(6, "正在探测下载通道")
        dest = os.path.join("/tmp", os.path.basename(name))
        try:
            # 传完整地址而不是文件名：24.10/25.12 的包在 release 资产里，
            # 22.03 的在 raw 目录里，两者的 URL 形状完全不同
            channel, got = pkgfeed.download_any(
                item["url"], dest,
                on_tick=lambda g, t: _pstep(
                    8 + int(g * 55 / max(1, t or g)), "正在下载 " + _hsize(g, t)),
            )
        except LookupError as exc:
            # 「太慢」和「连不上」是两种病：前者换本地传包就行，后者要查网络。
            # 混报成 net_unreachable 会让人以为是 DNS 挂了
            kind = "too_slow" if getattr(exc, "slow", False) else "net_unreachable"
            _pfail(kind, str(exc), "", target)
            return
        total = got
        with _PKG_LOCK:
            _PKG.update(channel=channel, got=got, total=total)
        path = dest
        if not pkgfeed.looks_like_run(path):
            try:
                os.remove(path)
            except OSError:
                pass
            _pfail("bad_payload", "下回来的不是安装包，多半被网关拦了", "", target)
            return
    else:
        path = os.path.join(PKG_DIR, os.path.basename(name or ""))
        if not os.path.isfile(path):
            _pfail("no_file", "上传的文件不见了，请重新上传", "", target)
            return
        with _PKG_LOCK:
            _PKG.update(name=os.path.basename(path), total=os.path.getsize(path))

    base = os.path.basename(path)
    if not base.lower().endswith(_PKG_RUN_EXT):
        _pfail("bad_payload", "只支持 .run / .ipk / .apk 安装包", "", target)
        return

    _pstep(68, "正在安装 %s" % base)
    if base.lower().endswith(".run"):
        # .run 是 Makeself 自解压脚本，内部 install.sh 会自己调 opkg。
        # 用 sh 执行：很多包没带可执行位，直接 exec 会 EACCES。
        code, out = _run(["/bin/sh", path], timeout=900)
    elif base.lower().endswith(".apk"):
        code, out = _run(["apk", "add", "--allow-untrusted", path], timeout=900)
    else:
        code, out = _run(["opkg", "install", "--force-reinstall", path], timeout=900)

    if _installed(target):
        _pstep(100, "安装完成")
        with _PKG_LOCK:
            _PKG.update(running=False, done=True, ok=True, pct=100,
                        finished=time.time(), step="安装完成")
        forget_active()
        _repo_cache["ts"] = 0.0
        pkgfeed.forget_cache()
        return

    last = ""
    for line in reversed((out or "").strip().splitlines()):
        if line.strip():
            last = line.strip()
            break
    _pfail(_classify(out), last or ("脚本退出码 %d" % code), out or "", target)


def pkg_status() -> dict:
    with _PKG_LOCK:
        snap = dict(_PKG)
        snap["log"] = list(_PKG["log"])
    return snap


def pkg_catalog(force: bool = False) -> dict:
    """远端清单。跑在请求线程里，所以把网络异常收成 ok=False，别抛 500。"""
    try:
        return pkgfeed.catalog(force=force)
    except (urllib.error.URLError, OSError, LookupError) as exc:
        return {"ok": False, "items": [], "channel": "", "repo": pkgfeed.REPO,
                "error": str(exc)}


def pkg_probe() -> dict:
    try:
        return {"ok": True, "channels": pkgfeed.probe_channels()}
    except (urllib.error.URLError, OSError) as exc:
        return {"ok": False, "channels": [], "error": str(exc)}


def pkg_install(target: str = "", source: str = "github", name: str = "",
                confirm: str = "") -> dict:
    """起一个整包安装任务，立刻返回；进度看 install_status()["pkg"]。

    跟 install() 一样，target 只认固定值 —— 这个接口最终以 root 跑
    ``sh <文件>``，绝不能让客户端把路径传进来。
    """
    if target not in PKG_TARGETS:
        return {"ok": False, "error": "target 只能是 openclash / passwall"}
    if source not in ("github", "local"):
        return {"ok": False, "error": "source 只能是 github / local"}
    if confirm != "install":
        return {"ok": False, "error": "安装需要二次确认：confirm=install"}
    if source == "local" and not name:
        return {"ok": False, "error": "本地上传要先给出文件名"}
    if not pkg_manager():
        return _err("unknown", detail="这台设备上没有 opkg / apk，装不了插件包")

    with _PKG_LOCK:
        if _PKG["running"]:
            return {"ok": True, "accepted": True, "already": True, "state": pkg_status()}
        _PKG.update(running=True, done=False, ok=False, pct=0, step="准备中",
                    target=target, source=source, name=os.path.basename(name or ""),
                    channel="", got=0, total=0, error={}, started=time.time(),
                    finished=0.0, log=[])
    threading.Thread(target=_pkg_worker, args=(target, source, name),
                     name="proxy-pkg", daemon=True).start()
    return {"ok": True, "accepted": True, "state": pkg_status()}


def _service_running(backend: str) -> bool:
    code, out = _run(
        ["ubus", "call", "service", "list", json.dumps({"name": backend})], timeout=5
    )
    if code == 0:
        try:
            data = json.loads(out or "{}")
            instances = data.get(backend, {}).get("instances") or {}
            for item in instances.values():
                if item.get("running"):
                    return True
            if instances:
                return False
        except json.JSONDecodeError:
            pass
    # Passwall 是 legacy init，未必有 procd 实例，用它的运行目录兜底。
    # 不能用 "xray|passwall" 这类宽泛匹配，会把本进程自己的命令行也命中。
    if backend == "passwall":
        code, out = _run(["pgrep", "-f", "/tmp/etc/passwall"], timeout=4)
        return code == 0 and bool(out.strip())
    return False


# --------------------------------------------------------------- Passwall 适配


def _pw_is_info(node: dict) -> bool:
    """订阅导入时会混进「组名:订阅地址」这类信息条目，不是真节点。"""
    name = node.get("name", "")
    return "://" in name or (
        ":" in name and name.split(":", 1)[1].startswith(("http", "//"))
    )


def _passwall_nodes(flat: dict[str, str]) -> list[dict]:
    """把 uci 里 type=nodes 的 section 还原成节点对象。

    uci 展平后形如 ``passwall.J8phxtIP.flow = 'xtls-rprx-vision'``，
    必须按前两个点切成 pkg / section / option，不能只切一次。
    """
    nodes: dict[str, dict] = {}
    for key, value in flat.items():
        parts = key.split(".", 2)
        if len(parts) < 2 or parts[0] != "passwall":
            continue
        section = parts[1]
        if flat.get(f"passwall.{section}") != "nodes":
            continue
        node = nodes.setdefault(section, {"id": section})
        if len(parts) > 2:
            node[parts[2]] = value

    out = []
    for node in nodes.values():
        # 只保留展示与测速需要的字段，uuid / publicKey 等敏感项不外泄
        out.append(
            {
                "id": node.get("id", ""),
                "name": node.get("remarks") or node.get("id", ""),
                "type": node.get("type", ""),
                "protocol": node.get("protocol", ""),
                "group": node.get("group") or "未分组",
                "address": node.get("address", ""),
                "port": node.get("port", ""),
            }
        )
    return [n for n in out if not _pw_is_info(n)]


def _passwall_state(flat: dict[str, str]) -> dict:
    global_sec = ""
    for key, value in flat.items():
        if value == "global" and key.startswith("passwall."):
            global_sec = key.split(".", 1)[1]
            break
    enabled = flat.get(f"passwall.{global_sec}.enabled", "0") == "1"
    current = flat.get(f"passwall.{global_sec}.tcp_node", "")
    nodes = _passwall_nodes(flat)
    current_name = next((n["name"] for n in nodes if n["id"] == current), current)
    return {
        "enabled": enabled,
        "current_id": current,
        "current": current_name,
        "nodes": nodes,
    }


def _passwall_groups(nodes: list[dict], current_id: str) -> dict:
    """Passwall 没有 selector 概念，按节点的 group 字段聚成「分组」，
    当前选中的节点所在的组，其 now 就是当前节点。"""
    buckets: dict[str, list[dict]] = {}
    for node in nodes:
        buckets.setdefault(node["group"], []).append(node)

    groups = []
    for name, members in sorted(buckets.items(), key=lambda kv: (-len(kv[1]), kv[0])):
        now = next((m["name"] for m in members if m["id"] == current_id), "")
        groups.append(
            {
                "name": name,
                "type": "group",
                "now": now,
                "members": [
                    {"name": m["name"], "type": m["protocol"] or m["type"], "is_group": False,
                     "delay": None, "udp": None, "id": m["id"]}
                    for m in members
                ],
            }
        )
    return {"groups": groups, "node_count": len(nodes), "error": None}


# --------------------------------------------------------------- 统一模型


def backends() -> list[dict]:
    """列出两端后端的安装 / 启用 / 运行状态。"""
    oc_flat = _uci_show("openclash")
    pw_flat = _uci_show("passwall")
    oc_running = _service_running("openclash")
    pw_state = _passwall_state(pw_flat) if pw_flat else {"enabled": False, "nodes": []}

    oc_nodes = 0
    if oc_running:
        data = clash.proxies()
        oc_nodes = int(data.get("node_count") or 0)

    pw_running = _service_running("passwall") and pw_state["enabled"]

    return [
        {
            "id": "openclash",
            "label": LABEL["openclash"],
            "installed": _shown_installed("openclash"),
            "pkg": PKG["openclash"],
            "core_ready": core_ready("openclash"),
            "enabled": oc_flat.get("openclash.config.enable", "0") == "1",
            "running": bool(oc_running),
            "node_count": oc_nodes,
            "engine": oc_flat.get("openclash.config.core_type", ""),
            "mode": oc_flat.get("openclash.config.en_mode", ""),
        },
        {
            "id": "passwall",
            "label": LABEL["passwall"],
            "installed": _shown_installed("passwall"),
            "pkg": PKG["passwall"],
            "core_ready": core_ready("passwall"),
            "enabled": pw_state["enabled"],
            "running": bool(pw_running),
            "node_count": len(pw_state["nodes"]),
            "engine": "Xray",
            "mode": _uci_get("passwall.@global[0].dns_shunt") or "chinadns-ng",
        },
    ]


_ACTIVE_TTL = 3.0
_active_cache = {"ts": 0.0, "id": "none"}

# 最近一次整组测速的结果：{backend: {节点名: 毫秒}}，0 表示超时。
# 只放内存，不落盘 —— 重启后节点会重新测，旧数据反而误导。
# 用途：Passwall 的节点表里没有延迟字段，分组接口靠它补上，
# 「隐藏超时节点」才能在那儿也生效。
_delay_cache: dict[str, dict[str, int]] = {}


def forget_active() -> None:
    """切换后端之后立刻失效，否则接下来的 3 秒还会读到旧的"""
    _active_cache["ts"] = 0.0


def active() -> str:
    """当前生效的后端。两个都在跑时以 OpenClash 为准（它抢占了 53/7892）。

    `backends()` 要 pgrep + uci，一次 20–30ms；这个函数被 mode/connections/
    groups/select 每次请求都调一遍，实测占掉这些接口的一半时间。
    后端状态不会 3 秒内反复变，缓存 3 秒；写操作（切后端）会主动失效。
    """
    now = time.time()
    if now - _active_cache["ts"] < _ACTIVE_TTL:
        return _active_cache["id"]
    for item in backends():
        if item["running"]:
            _active_cache.update(ts=now, id=item["id"])
            return item["id"]
    _active_cache.update(ts=now, id="none")
    return "none"


def overview() -> dict:
    items = backends()
    current = next((i for i in items if i["running"]), None)
    return {
        "active": current["id"] if current else "none",
        "backends": items,
        "mutual_exclusive": True,
        # 安装环境：界面靠它决定「一键安装」按钮显不显示、提示什么系统
        "system": system_info(),
    }


def groups(backend: str = "") -> dict:
    target = backend or active()
    if target == "openclash":
        data = clash.proxies()
        data["backend"] = "openclash"
        return _shape(data)
    if target == "passwall":
        flat = _uci_show("passwall")
        state = _passwall_state(flat)
        result = _passwall_groups(state["nodes"], state["current_id"])
        # Passwall 的节点里本来没有延迟，把上一次整组测速的结果补上，
        # 否则「隐藏超时节点」在 Passwall 上永远筛不出东西
        cache = _delay_cache.get("passwall", {})
        for g in result.get("groups") or []:
            for m in g.get("members") or []:
                if m.get("delay") is None:
                    m["delay"] = cache.get(m.get("name"))
        result["backend"] = "passwall"
        result["current"] = state["current"]
        return _shape(result)
    return {"groups": [], "node_count": 0, "error": "没有正在运行的代理后端",
            "backend": target, "hide_timeout": prefs()["hide_timeout"], "hidden": 0}


# ------------------------------------------------------- 显示偏好（隐藏超时节点）


def prefs() -> dict:
    """代理页的显示偏好，存在 /etc/istore-agent/config.json。"""
    sec = config.get("proxy", {}) or {}
    return {"hide_timeout": bool(sec.get("hide_timeout", False))}


def set_prefs(hide_timeout=None) -> dict:
    data = config.load()
    sec = dict(data.get("proxy") or {})
    if hide_timeout is not None:
        sec["hide_timeout"] = bool(hide_timeout)
    data["proxy"] = sec
    if not config.save(data):
        return {"ok": False, "error": "写配置失败（/etc/istore-agent/config.json）",
                **prefs()}
    return {"ok": True, **prefs()}


def _shape(data: dict) -> dict:
    """按偏好裁掉超时节点，并告诉客户端裁掉了几个。

    两个细节：
      - 只有 delay == 0 才算「测过且超时」。None 是「还没测」——
        刚开机时几乎全是 None，按 None 藏就会得到一个空列表。
      - 当前选中的节点、策略组本身永远保留：藏了它们，界面上就
        看不出「现在用的是哪条线」，而这条信息比列表整齐重要。
    """
    on = prefs()["hide_timeout"]
    data["hide_timeout"] = on
    if not on:
        data["hidden"] = 0
        return data

    hidden = 0
    for g in data.get("groups") or []:
        keep = []
        for m in g.get("members") or []:
            if m.get("is_group") or m.get("info") or m.get("name") == g.get("now"):
                keep.append(m)
                continue
            if m.get("delay") == 0:
                hidden += 1
                continue
            keep.append(m)
        g["members"] = keep
    data["hidden"] = hidden
    return data


def select(name: str, group: str = "", backend: str = "") -> dict:
    target = backend or active()
    if target == "openclash":
        return {**clash.select(group, name), "backend": "openclash"}

    if target == "passwall":
        flat = _uci_show("passwall")
        state = _passwall_state(flat)
        node = next((n for n in state["nodes"] if n["name"] == name or n["id"] == name), None)
        if not node:
            return {"ok": False, "error": f"节点不存在: {name}", "backend": "passwall"}
        global_sec = next(
            (k.split(".", 1)[1] for k, v in flat.items() if v == "global"), ""
        )
        if not global_sec:
            return {"ok": False, "error": "找不到 passwall global 配置", "backend": "passwall"}
        code, out = _run(["uci", "set", f"passwall.{global_sec}.tcp_node={node['id']}"], timeout=5)
        if code != 0:
            return {"ok": False, "error": out.strip(), "backend": "passwall"}
        _run(["uci", "commit", "passwall"], timeout=5)
        changed = node["id"] != state["current_id"]
        # 节点变更需要重启内核才生效；Passwall 没有热切换能力
        restarted = None
        if changed and state["enabled"]:
            restarted = service("restart", "passwall")
        return {
            "ok": True,
            "backend": "passwall",
            "name": node["name"],
            "group": node["group"],
            "restarted": restarted,
            "note": "Passwall 无热切换，已重启内核生效" if changed else "已是当前节点",
        }
    return {"ok": False, "error": "没有正在运行的代理后端", "backend": target}


def service(action: str, backend: str = "") -> dict:
    if action not in {"start", "stop", "restart"}:
        return {"ok": False, "error": "invalid action"}
    target = backend or active()
    if target not in INIT:
        return {"ok": False, "error": "未知后端"}

    # 两者互斥：启动一方前必须停掉另一方，否则抢 53 端口和转发链
    stopped = None
    if action in ("start", "restart"):
        other = "passwall" if target == "openclash" else "openclash"
        if _installed(other) and _service_running(other):
            _run([INIT[other], "stop"], timeout=90)
            stopped = other

    # 启用状态与开机自启一起改，避免重启后又跑回另一个
    if action == "start":
        if target == "openclash":
            _run(["uci", "set", "openclash.config.enable=1"], timeout=5)
        else:
            _run(["uci", "set", "passwall.@global[0].enabled=1"], timeout=5)
        _run(["uci", "commit", target if target == "openclash" else "passwall"], timeout=5)
    elif action == "stop":
        if target == "openclash":
            _run(["uci", "set", "openclash.config.enable=0"], timeout=5)
        else:
            _run(["uci", "set", "passwall.@global[0].enabled=0"], timeout=5)
        _run(["uci", "commit", target if target == "openclash" else "passwall"], timeout=5)

    code, out = _run([INIT[target], action], timeout=120)
    # 刚切过后端，缓存里的 active 立刻作废
    forget_active()
    # 起停会增减代理的 DNS 端口（OpenClash 7874），AGH 上游要立刻对齐
    _sync_dns()
    return {
        "ok": code == 0,
        "backend": target,
        "action": action,
        "code": code,
        "stopped_other": stopped,
        "output": out[-800:],
    }


CONFIG_DIR = "/etc/openclash/config"


def configs() -> dict:
    """OpenClash 的配置文件清单。

    OpenClash 同一时刻只跑一个 yaml（openclash.config.config_path），其余文件
    只是躺在目录里。想在手机上换订阅，得先能看见这份清单。
    """
    flat = _uci_show("openclash")
    current = flat.get("openclash.config.config_path", "")
    try:
        names = sorted(os.listdir(CONFIG_DIR))
    except OSError:
        names = []

    items: list[dict] = []
    for name in names:
        if not name.endswith((".yaml", ".yml")):
            continue
        path = os.path.join(CONFIG_DIR, name)
        try:
            st = os.stat(path)
        except OSError:
            continue
        items.append(
            {
                "name": name.rsplit(".", 1)[0],
                "file": name,
                "path": path,
                "size": st.st_size,
                "mtime": int(st.st_mtime),
                "current": path == current,
            }
        )
    return {"ok": True, "backend": "openclash", "dir": CONFIG_DIR,
            "current": current, "configs": items}


def switch_config(path: str) -> dict:
    """切换 OpenClash 配置文件。

    只改 uci 不够：内核进程早把旧 yaml 读进内存了，必须重启才生效。
    重启会断网十几秒，调用方要用长超时。
    """
    if not path:
        return {"ok": False, "error": "缺少配置文件路径"}
    real = os.path.realpath(path)
    base = os.path.realpath(CONFIG_DIR) + os.sep
    # 路径来自客户端，必须锁死在配置目录里，否则等于给了一个任意文件写入点
    if not real.startswith(base):
        return {"ok": False, "error": "配置文件不在开放目录内"}
    if not real.endswith((".yaml", ".yml")) or not os.path.isfile(real):
        return {"ok": False, "error": "配置文件不存在"}

    code, out = _run(["uci", "set", f"openclash.config.config_path={real}"], timeout=5)
    if code != 0:
        return {"ok": False, "error": f"写入配置失败: {out[-200:]}"}
    _run(["uci", "commit", "openclash"], timeout=5)

    if not _service_running("openclash"):
        # 没在跑就不用重启，下次启动自然会用新文件
        return {"ok": True, "path": real, "restarted": False}

    code, out = _run([INIT["openclash"], "restart"], timeout=180)
    _sync_dns()
    return {
        "ok": code == 0,
        "path": real,
        "restarted": True,
        "output": out[-600:],
        "error": "" if code == 0 else "重启 OpenClash 失败，看日志确认新配置是否有效",
    }


def mode(value: str = "", backend: str = "") -> dict:
    """读取 / 切换代理模式。"""
    target = backend or active()
    if target == "openclash":
        if not value:
            data = clash._req("/configs")
            return {"ok": True, "backend": target, "mode": data.get("mode")}
        return {**clash.set_mode(value), "backend": target}

    if target == "passwall":
        flat = _uci_show("passwall")
        global_sec = next((k.split(".", 1)[1] for k, v in flat.items() if v == "global"), "")
        if not value:
            return {
                "ok": True,
                "backend": target,
                "mode": flat.get(f"passwall.{global_sec}.tcp_proxy_mode", ""),
            }
        if value not in {"proxy", "disable"}:
            return {"ok": False, "error": "invalid mode"}
        _run(["uci", "set", f"passwall.{global_sec}.tcp_proxy_mode={value}"], timeout=5)
        _run(["uci", "commit", "passwall"], timeout=5)
        return {"ok": True, "backend": target, "mode": value}
    return {"ok": False, "error": "没有正在运行的代理后端"}


def connections(backend: str = "") -> dict:
    """连接明细。必须跟随「正在查看的后端」而不是 active，
    否则看 Passwall 页面会串成 OpenClash 的连接数。"""
    target = backend or active()
    if target == "openclash" and active() == "openclash":
        data = clash.connections()
        data["backend"] = "openclash"
        return data
    if target == "passwall":
        return {
            "backend": target,
            "connections": [],
            "download_total": 0,
            "upload_total": 0,
            "error": "Passwall 不提供连接明细接口",
        }
    return {
        "backend": target,
        "connections": [],
        "download_total": 0,
        "upload_total": 0,
        "error": "该后端未在运行",
    }


def delay(name: str, timeout_ms: int = 5000) -> dict:
    target = active()
    if target == "openclash":
        return {**clash.delay(name, timeout_ms=timeout_ms), "backend": target}
    # Passwall 的 Xray 节点没有测速 HTTP 接口，用 TCP 连通性代替
    flat = _uci_show("passwall")
    state = _passwall_state(flat)
    node = next((n for n in state["nodes"] if n["name"] == name), None)
    if not node or not node.get("address"):
        return {"ok": False, "error": "节点不存在", "backend": target}
    host, port = node["address"], node.get("port") or "443"
    import socket
    import time as _t

    start = _t.monotonic()
    try:
        with socket.create_connection((host, int(port)), timeout=timeout_ms / 1000):
            ms = int((_t.monotonic() - start) * 1000)
        return {"ok": True, "delay": ms, "backend": target, "kind": "tcp"}
    except (OSError, ValueError) as exc:
        return {"ok": False, "error": str(exc), "backend": target}


def delays(group: str = "", backend: str = "", timeout_ms: int = 3000) -> dict:
    """整组测速，一次返回 {节点名: 毫秒}。

    OpenClash 走 Mihomo 的 /group/{name}/delay（内核并发打完一组）；
    Passwall 没有这个接口，只能对节点做并发 TCP 连接探测，
    所以那边的数字是「TCP 握手耗时」，不是 HTTP 往返，界面上会标注。
    """
    target = backend or active()
    if target == "openclash":
        if not group:
            return {"ok": False, "error": "缺少分组名", "backend": target, "delays": {}}
        result = clash.group_delay(group, timeout_ms=timeout_ms)
        found = result.get("delays") or {}
        if found:
            _delay_cache.setdefault(target, {}).update(found)
        return {**result, "backend": target, "kind": "http"}

    if target == "passwall":
        flat = _uci_show("passwall")
        state = _passwall_state(flat)
        nodes = state["nodes"]
        if group:
            nodes = [n for n in nodes if n["group"] == group]
        if not nodes:
            return {"ok": False, "error": "该分组没有节点", "backend": target, "delays": {}}

        import socket
        import time as _t
        from concurrent.futures import ThreadPoolExecutor

        def probe(node: dict) -> tuple[str, int]:
            host = node.get("address") or ""
            port = node.get("port") or "443"
            if not host:
                return node["name"], 0
            start = _t.monotonic()
            try:
                with socket.create_connection((host, int(port)), timeout=timeout_ms / 1000):
                    return node["name"], max(1, int((_t.monotonic() - start) * 1000))
            except (OSError, ValueError):
                return node["name"], 0

        with ThreadPoolExecutor(max_workers=16) as pool:
            pairs = list(pool.map(probe, nodes[:200]))
        delays = {name: ms for name, ms in pairs}
        _delay_cache.setdefault(target, {}).update(delays)
        return {
            "ok": any(delays.values()),
            "backend": target,
            "kind": "tcp",
            "delays": delays,
            "error": None if any(delays.values()) else "全部节点不可达",
        }

    return {"ok": False, "error": "没有正在运行的代理后端", "backend": target, "delays": {}}
