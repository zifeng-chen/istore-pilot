"""给 App 内置 WebView 发一张已登录的 LuCI 通行证。

为什么要在服务端代登录：LuCI 的登录态是 uhttpd 在 `POST /cgi-bin/luci/` 之后
下发的 `sysauth_http` cookie。App 里点「路由器网页端」，WebView 第一次打开
必然是那张登录页 —— 用户得在手机上把同一个 root 口令再敲一遍。而 App 早就
用这个口令登录过 Agent 了，再问一次纯属折腾。

Agent 就跑在这台机器上、还是 root，直接替它登一次，把 cookie 交给 WebView：
用户看到的就是后台首页。**口令不出路由器**，客户端只拿到一个会话 id，
而且这个 id 和浏览器里那个一样，会过期、可以随时被 LuCI 顶掉。

口令来源（按优先级）：
1. 用户通过 App 改过 root 口令 —— 新口令只在内存里记着，进程重启就没了
2. `config.json` 的 `luci.password`（口令和 App 登录口令不一样时才需要填）
3. `config.json` 的 `auth.password`（本项目的默认情形：全站一个口令）
"""

from __future__ import annotations

import http.client
import threading
import time
import urllib.parse

from .config import get as cfg

# uhttpd 的默认口；能从 /etc/config/uhttpd 读到时以配置为准
_DEFAULT_HTTP_PORT = 80
_DEFAULT_HTTPS_PORT = 443

# LuCI 的会话默认 3600 秒（/etc/config/luci 的 sauth.sessiontime）。
# 缓存 25 分钟：既避免每开一次 WebView 就在路由器上多留一个会话，也不会
# 拿到一个马上要过期的 id。
_TTL = 25 * 60

_lock = threading.Lock()
_cache: dict = {"at": 0.0, "name": "", "sid": "", "port": 0, "secure": False}
# 用户从 App 里改过 root 口令后，这里记新的（只在内存）
_override: str = ""


def remember(password: str) -> None:
    """App 改完 root 口令后调一次，否则免密登录会在下次打开网页端时失效。"""
    global _override
    pwd = (password or "").strip()
    if not pwd:
        return
    with _lock:
        _override = pwd
        _cache["at"] = 0.0


def forget() -> None:
    global _override
    with _lock:
        _override = ""
        _cache["at"] = 0.0


def _password() -> str:
    if _override:
        return _override
    conf = cfg("luci", {}) or {}
    pwd = str(conf.get("password") or "")
    if pwd:
        return pwd
    # 兜底：很多部署是全站同一个口令，这时候一次都不用配
    return str((cfg("auth", {}) or {}).get("password") or "")


def _uhttpd() -> tuple[int, bool]:
    """从 /etc/config/uhttpd 读出端口和是否强制 https。

    iStoreOS 默认 `listen_http 0.0.0.0:80`、`redirect_https 0`，走明文那条。
    万一有人开了强制 https，就得连 443 并且用 sysauth_https 这个 cookie 名。
    """
    http_port, https_port, redirect = _DEFAULT_HTTP_PORT, _DEFAULT_HTTPS_PORT, False
    try:
        with open("/etc/config/uhttpd", "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                parts = line.strip().split()
                if len(parts) < 3 or parts[0] != "option":
                    continue
                key, val = parts[1], parts[2].strip("'\"")
                if key == "listen_http" and ":" in val:
                    try:
                        http_port = int(val.rsplit(":", 1)[1])
                    except ValueError:
                        pass
                elif key == "listen_https" and ":" in val:
                    try:
                        https_port = int(val.rsplit(":", 1)[1])
                    except ValueError:
                        pass
                elif key == "redirect_https":
                    redirect = val in ("1", "true", "yes", "on")
    except OSError:
        pass
    if redirect:
        return https_port, True
    return http_port, False


def _login(port: int, secure: bool) -> tuple[str, str] | None:
    """替用户登一次 LuCI，返回 (cookie 名, 会话 id)；口令不对返回 None。

    用 http.client 而不是 urllib：需要看 Set-Cookie 的原始头，
    urllib 的 HTTPCookieProcessor 会把路径、SameSite 一起揉平。
    """
    body = urllib.parse.urlencode({
        "luci_username": "root",
        "luci_password": _password(),
    })
    conn = http.client.HTTPSConnection("127.0.0.1", port, timeout=5) if secure \
        else http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        conn.request("POST", "/cgi-bin/luci/", body, {
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": "iStorePilot-agent",
        })
        resp = conn.getresponse()
        resp.read()
        raw = resp.msg.get_all("Set-Cookie") or []
    except (OSError, http.client.HTTPException):
        return None
    finally:
        try:
            conn.close()
        except OSError:
            pass

    for item in raw:
        name, _, rest = item.partition("=")
        name = name.strip()
        if name not in ("sysauth_http", "sysauth_https"):
            continue
        sid = rest.split(";", 1)[0].strip()
        if sid:
            return name, sid
    return None


def _probe(name: str, sid: str, port: int, secure: bool) -> bool:
    """这条会话还活着吗。

    必须验一下再发：LuCI 的会话会在超时、后端重启、或者在网页端点了「退出」
    之后失效，而我们的缓存还在有效期里 —— 那样发出去的是一张作废的通行证，
    客户端打开就是登录页，用户会以为免密坏了。
    """
    conn = http.client.HTTPSConnection("127.0.0.1", port, timeout=3) if secure \
        else http.client.HTTPConnection("127.0.0.1", port, timeout=3)
    try:
        conn.request("GET", "/cgi-bin/luci/", headers={
            "Cookie": "%s=%s" % (name, sid),
            "User-Agent": "iStorePilot-agent",
        })
        resp = conn.getresponse()
        resp.read()
        # 未登录时 LuCI 返回 403 + 登录表单，登录了才是 200
        return resp.status == 200
    except (OSError, http.client.HTTPException):
        return False
    finally:
        try:
            conn.close()
        except OSError:
            pass


def ticket(host: str) -> dict:
    """给客户端一张可以直接塞进 WebView 的 cookie。

    `host` 是客户端访问 Agent 用的地址（去掉端口后的主机名或 IP），
    LuCI 在 80 口，所以最终打开的是 `http://<host>/cgi-bin/luci/`。
    """
    host = (host or "").strip() or "192.168.100.1"
    port, secure = _uhttpd()

    with _lock:
        fresh = (_cache["sid"] and time.time() - _cache["at"] < _TTL
                 and _cache["port"] == port and _cache["secure"] == secure)
        cached = dict(_cache) if fresh else {}

    # 缓存命中也要探一次活：作废的 cookie 发出去只会得到一张登录页
    if cached and not _probe(cached["name"], cached["sid"], port, secure):
        cached = {}
        with _lock:
            _cache["at"] = 0.0

    if not cached:
        got = _login(port, secure)
        if not got:
            return {
                "ok": False,
                "error": "路由器的 root 口令和 App 登录口令不一样，需要在 "
                         "/etc/istore-agent/config.json 里填 luci.password",
                "host": host,
                "url": "http://%s/" % host,
            }
        name, sid = got
        with _lock:
            _cache.update({"at": time.time(), "name": name, "sid": sid,
                           "port": port, "secure": secure})
        cached = {"name": name, "sid": sid}

    scheme = "https" if secure else "http"
    return {
        "ok": True,
        # 直接给 /cgi-bin/luci/：这是后台首页。打开 `http://host/` 也行，
        # 但那多一跳 meta refresh，WebView 会闪一下白屏
        "url": "%s://%s/cgi-bin/luci/" % (scheme, host),
        "host": host,
        "scheme": scheme,
        "cookie_name": cached["name"],
        "cookie_value": cached["sid"],
        "cookie_path": "/",
        # LuCI 的会话是 3600 秒，缓存过 25 分钟，这里给个保守值
        "ttl": _TTL,
    }
