"""HTTP 服务：对外只暴露一套自定义 REST 接口，内部再调用 ubus / Clash / procfs。"""

from __future__ import annotations

import http.client
import ipaddress
import json
import os
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import (adblock, apps, auth, cfgbak, clash, devices, hardware, lanedit, luci,
               mask, netapply, netcfg, power, proxy, subscriptions, sysinfo, system)
from .config import get as cfg, load as load_cfg, save as save_cfg

START_TS = time.time()

# Agent 自身版本：随 ipk 一起发版，硬件详情页与「关于」都会显示
VERSION = "0.1.4"

_cache_lock = threading.Lock()
_cache: dict[str, tuple[float, object]] = {}

# 网页端走同源代理：这两个前缀转发给路由器自己的 LuCI（127.0.0.1:80）。
# LuCI 的页面只用这两个绝对路径（静态资源在 /luci-static），够用。
LUCI_PREFIXES = ("/cgi-bin/luci", "/luci-static")


def _is_lan(ip: str) -> bool:
    """来源是不是内网。

    只用来判断「网页端要不要放行」，不参与鉴权 —— 公网来源还能靠
    换票通行证（cookie）进来，前提是你把 proxy_lan_only 关掉。
    """
    try:
        a = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return a.is_loopback or a.is_private or a.is_link_local


def _log(msg: str) -> None:
    """内部错误只写日志（procd 会收 stderr），不回给客户端。

    以前是 `f"处理请求失败：{exc}"` 直接回给客户端 —— 路径、命令输出、
    堆栈里的实现细节都跟着泄露，等于给对方发了张结构图。
    """
    print("[istore-agent] %s %s" % (time.strftime("%Y-%m-%dT%H:%M:%S"), msg),
          file=sys.stderr, flush=True)


def cached(key: str, ttl: float, producer):
    now = time.monotonic()
    with _cache_lock:
        hit = _cache.get(key)
        if hit and now - hit[0] < ttl:
            return hit[1]
    value = producer()
    with _cache_lock:
        _cache[key] = (now, value)
    return value


def cache_drop(*keys: str) -> None:
    """改完配置要立刻把相关缓存打掉。

    不然会出现最难解释的一种界面：刚点了「收紧」并确认成功，
    卡片上的「WAN 入站」还写着「允许全部」——要等 10 秒缓存过期才变。
    用户会以为操作没生效，然后去点第二遍。
    """
    with _cache_lock:
        for k in keys:
            _cache.pop(k, None)


def cache_drop_prefix(prefix: str) -> None:
    """按前缀清缓存。给「一堆按参数分 key 的接口」用，比如 proxy_groups:<后端>。"""
    with _cache_lock:
        for k in [k for k in _cache if k.startswith(prefix)]:
            _cache.pop(k, None)


class Handler(BaseHTTPRequestHandler):
    server_version = "istore-agent/0.1"  # noqa 由 BaseHTTPRequestHandler 读
    protocol_version = "HTTP/1.1"  # noqa 同上
    # 关掉 Nagle：下面 _send 已经把响应头和正文合成一次写，
    # 但 keep-alive 下零散的小包（比如 OPTIONS 预检）还会走 Nagle，
    # 和客户端的延迟 ACK 凑一起就是每请求固定 40ms
    disable_nagle_algorithm = True  # noqa 同上

    # ------------------------------------------------------------ 基础工具

    def log_message(self, fmt, *args):  # noqa 静音，避免刷屏 procd 日志
        return

    def _cors_origin(self) -> str:
        """只有同源才回 CORS 头。

        以前一律 `Access-Control-Allow-Origin: *`，等于允许任意网页读本机
        接口的响应 —— 登录接口因此能在他人的浏览器里当爆破靶子（响应码就是
        「猜对没猜对」）。App 与 WebView 发的是同源请求（不带 Origin），不受影响。
        """
        origin = (self.headers.get("Origin") or "").strip()
        if not origin:
            return ""
        try:
            netloc = urllib.parse.urlparse(origin).netloc
        except ValueError:
            return ""
        host = (self.headers.get("Host") or "").strip()
        return origin if netloc and netloc == host else ""

    def _send(self, code: int, body: bytes,
              ctype: str = "application/json; charset=utf-8",
              extra: dict | None = None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        origin = self._cors_origin()
        if origin:
            self.send_header("Access-Control-Allow-Origin", origin)
        # 无论有没有 Origin 都要带 Vary，否则中间缓存可能把 A 站的结果发给 B 站
        self.send_header("Vary", "Origin")
        if self.command == "OPTIONS":
            self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, OPTIONS")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        # 头 + 正文合成一次 write。
        # 原来是 end_headers() 先发一排小包、再 wfile.write(body) 发正文：
        # 服务端 Nagle 会压住正文等 ACK，客户端的延迟 ACK 又等 40ms ——
        # 局域网里每个请求都白白多出 ~40ms（实测 /health 47ms，回环 0.6ms）。
        self._headers_buffer.append(b"\r\n")
        head = b"".join(self._headers_buffer)
        self._headers_buffer = []
        if self.command == "HEAD":
            self.wfile.write(head)
        else:
            self.wfile.write(head + body)

    def _json(self, data, code: int = 200):
        self._send(code, json.dumps(data, ensure_ascii=False).encode("utf-8"))

    def _error(self, code: int, message: str):
        self._json({"ok": False, "error": message}, code)

    def _body(self) -> dict:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return {}
        if length <= 0 or length > 1 << 20:
            return {}
        raw = self.rfile.read(length)
        try:
            return json.loads(raw.decode("utf-8", "replace"))
        except json.JSONDecodeError:
            return {}

    def _handle_upload(self):
        """接收安装包：原始字节流 + X-Filename 头，边收边写盘。

        不用 multipart 有两个原因：路由器内存小，整包读进内存会 OOM；
        而且手写 multipart 解析容易在边界字符上出错。
        """
        name = urllib.parse.unquote(self.headers.get("X-Filename", ""))
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        result = system.receive_upload(self.rfile, length, name)
        self._json(result, 200 if result.get("ok") else 400)

    def _authed(self) -> bool:
        """只认 Authorization 头。

        以前还允许 `?token=`，但三端客户端没有一个在用（都发头）——
        留着只会把令牌泄进访问日志、Referer 和浏览器历史。
        """
        header = self.headers.get("Authorization", "")
        token = header[7:] if header.lower().startswith("bearer ") else ""
        return auth.verify_token(token)

    def _client_ip(self) -> str:
        return self.client_address[0] if self.client_address else "?"

    def _origin_ip(self) -> str:
        """真实来源 IP。

        前面挂了反向代理（群晖那类）时，TCP 对端是代理自己 —— 它也在局域网里，
        直接看 client_address 会把「从外网进来的」也当成内网。
        代理会带 X-Forwarded-For，取第一段（最靠近用户的那一跳）。
        """
        xff = (self.headers.get("X-Forwarded-For", "") or "").split(",")[0].strip()
        return xff or self._client_ip()

    def _host_only(self) -> str:
        """客户端访问我们时用的主机名/IP（去掉端口），用来拼 LuCI 的地址。

        不能写死 192.168.100.1：换了网段、或者走 IPv6 的时候，那个地址是错的。
        客户端是拿哪个地址连上的我们，就说明它能连通哪个地址。
        """
        raw = (self.headers.get("Host", "") or "").strip()
        if not raw:
            return ""
        if raw.startswith("["):                 # [240e::1]:8443
            end = raw.find("]")
            return raw[1:end] if end > 0 else raw
        return raw.rsplit(":", 1)[0] if raw.count(":") == 1 else raw

    # ------------------------------------------------------------ 网页端代理

    def _cookie(self, name: str) -> str:
        raw = self.headers.get("Cookie", "") or ""
        for part in raw.split(";"):
            k, _, v = part.strip().partition("=")
            if k == name:
                return v
        return ""

    def _raw_body(self, limit: int = 8 << 20) -> bytes:
        """原样读请求体：LuCI 的 ubus 调用是 json/urlencoded，不能按 JSON 解析。"""
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return b""
        if length <= 0:
            return b""
        return self.rfile.read(min(length, limit))

    def _web_block(self, title: str, detail: str) -> None:
        """给浏览器看的一页说明：不转发，也不透任何 LuCI 内容。"""
        html = (
            '<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            "<title>%s</title><style>"
            "body{margin:0;background:#0f1c18;color:#e8f2ee;"
            "font:15px/1.7 -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;"
            "display:flex;min-height:100vh;align-items:center;justify-content:center;padding:24px}"
            ".b{max-width:430px}h1{font-size:17px;margin:0 0 10px}"
            "p{margin:0;color:#9fb3ab;font-size:13.5px}"
            "</style></head><body><div class=\"b\"><h1>%s</h1><p>%s</p></div></body></html>"
            % (title, title, detail)
        )
        self._send(403, html.encode("utf-8"), "text/html; charset=utf-8")

    def _send_pairs(self, code: int, body: bytes, pairs: list[tuple[str, str]]) -> None:
        """带重复头的发送：Set-Cookie 会来好几条，dict 装不下。"""
        self.send_response(code)
        for k, v in pairs:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self._headers_buffer.append(b"\r\n")
        head = b"".join(self._headers_buffer)
        self._headers_buffer = []
        if self.command == "HEAD":
            self.wfile.write(head)
        else:
            self.wfile.write(head + body)

    @staticmethod
    def _relocate(value: str, port: int) -> str:
        """LuCI 有时回绝对跳转（http://127.0.0.1/cgi-bin/luci/...），改回相对路径。"""
        try:
            u = urllib.parse.urlsplit(value)
        except ValueError:
            return value
        if not u.scheme or not u.netloc:
            return value
        if (u.hostname or "") in ("127.0.0.1", "localhost", "::1"):
            return urllib.parse.urlunsplit(("", "", u.path or "/", u.query, u.fragment))
        return value

    def _relay_luci(self) -> None:
        """把 /cgi-bin/luci、/luci-static 透传给路由器自己的 LuCI。

        为什么不让客户端直接连 LuCI 的 80 口：
          - 外面（域名 + 端口）那条反代只到 Agent，80 口根本不可达；
          - 局域网时又会把协议/端口猜错 —— App 连的是 https://域名:18443，
            网页端却被拼成 http://域名/ 。
        统一从这里转发后，App 用哪个 origin 进来，网页端就落在同一个 origin。
        """
        if luci.proxy_lan_only() and not _is_lan(self._origin_ip()):
            self._web_block(
                "网页端只在家里的局域网可用",
                "当前是从外网连进来的。App 的功能不受影响；要用网页端请连回家里的 Wi-Fi。"
                "想在公网也能用，把 /etc/istore-agent/config.json 里的 "
                "luci.proxy_lan_only 改成 false（那样 LuCI 会暴露在这个端口上）。",
            )
            return

        if not luci.web_pass_ok(self._cookie(luci.WEB_COOKIE)):
            self._web_block(
                "请从 App 的「网页端」入口打开",
                "这个地址不对浏览器单独开放。回 App 里点任意一个网页端入口，"
                "会自动带上通行凭证再跳过来。",
            )
            return

        port, secure = luci.upstream()
        body = None
        if self.command in ("POST", "PUT", "PATCH", "DELETE"):
            body = self._raw_body()

        hdrs = {
            "Host": "127.0.0.1:%d" % port,
            "Connection": "close",
            "User-Agent": self.headers.get("User-Agent", "istore-agent"),
            "Accept": self.headers.get("Accept", "*/*"),
            "Accept-Language": self.headers.get("Accept-Language", "zh-CN,zh;q=0.9"),
            "Cookie": self.headers.get("Cookie", ""),
        }
        for name in ("Content-Type", "Referer", "Origin", "X-Requested-With"):
            v = self.headers.get(name)
            if v:
                hdrs[name] = v
        if body is not None:
            hdrs["Content-Length"] = str(len(body))

        cls = http.client.HTTPSConnection if secure else http.client.HTTPConnection
        conn = cls("127.0.0.1", port, timeout=25)
        try:
            conn.request(self.command, self.path, body=body, headers=hdrs)
            resp = conn.getresponse()
            data = resp.read()
            status = resp.status
            pairs: list[tuple[str, str]] = []
            for k, v in resp.getheaders():
                lk = k.lower()
                if lk in ("connection", "keep-alive", "transfer-encoding", "content-length"):
                    continue
                if lk == "location":
                    v = self._relocate(v, port)
                pairs.append((k, v))
        except (OSError, http.client.HTTPException) as exc:
            _log("luci proxy failed: %s" % exc)
            self._web_block("网页端打不开",
                            "Agent 连不上路由器自己的 LuCI（127.0.0.1:%d）。" % port)
            return
        finally:
            conn.close()

        self._send_pairs(status, data, pairs)

    # ------------------------------------------------------------ 路由分发

    def do_OPTIONS(self):  # noqa HTTP 钩子
        self._send(204, b"")

    def do_HEAD(self):  # noqa HTTP 钩子
        self.do_GET()

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        query = urllib.parse.parse_qs(parsed.query)

        if path == "/api/v1/ping":
            # 这里的 version 一定要用 VERSION 常量。
            # 之前写死了一个 "0.1"，App 设置页就一直显示「Agent 版本 v0.1」，
            # 而 /health 报的是真版本，两个接口自相矛盾
            # 不回 listen.host：探活只需要 ok/version，监听地址属于内部信息
            self._json({"ok": True, "service": "istore-agent", "version": VERSION,
                        "ts": int(time.time())})
            return

        if path.startswith("/api/"):
            if not self._authed():
                self._error(401, "unauthorized")
                return
            self._api_get(path, query)
            return

        # 网页端：同源代理到路由器自己的 LuCI
        if path.startswith(LUCI_PREFIXES):
            self._relay_luci()
            return

        # 不再服务内置 Web 面板（已从项目里分离），非 API 的 GET 一律 404
        self._error(404, "not found")

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"

        if path == "/api/v1/login":
            body = self._body()
            pwd = str(body.get("password", ""))
            if not auth.verify_password(pwd, self._client_ip()):
                self._error(403, "密码错误或尝试过于频繁")
                return
            self._json({"ok": True, **auth.issue_token()})
            return

        # 网页端表单/ubus 调用也走同源代理
        if path.startswith(LUCI_PREFIXES):
            self._relay_luci()
            return

        if not path.startswith("/api/"):
            self._error(404, "not found")
            return
        if not self._authed():
            self._error(401, "unauthorized")
            return

        # ---- 上传安装包：必须在 _body() 之前处理，否则请求体被当成 JSON 读走
        if path == "/api/v1/system/upload":
            self._handle_upload()
            return

        body = self._body()

        try:
            if path == "/api/v1/clash/mode":
                self._json(clash.set_mode(str(body.get("mode", ""))))
            elif path == "/api/v1/clash/service":
                self._json(clash.service(str(body.get("action", ""))))
            elif path == "/api/v1/clash/delay":
                self._json(clash.delay(str(body.get("name", "")), timeout_ms=int(body.get("timeout", 5000))))
            elif path == "/api/v1/clash/select":
                self._json(clash.select(str(body.get("group", "")), str(body.get("name", ""))))

            # ---- 代理后端抽象（OpenClash / Passwall 通用）
            elif path == "/api/v1/proxy/select":
                self._json(proxy.select(
                    str(body.get("name", "")),
                    str(body.get("group", "")),
                    str(body.get("backend", "")),
                ))
            elif path == "/api/v1/proxy/service":
                self._json(proxy.service(str(body.get("action", "")), str(body.get("backend", ""))))
            elif path == "/api/v1/proxy/mode":
                self._json(proxy.mode(str(body.get("mode", "")), str(body.get("backend", ""))))
            elif path == "/api/v1/proxy/delay":
                self._json(proxy.delay(str(body.get("name", "")), timeout_ms=int(body.get("timeout", 5000))))
            elif path == "/api/v1/proxy/delays":
                self._json(proxy.delays(
                    str(body.get("group", "")),
                    str(body.get("backend", "")),
                    int(body.get("timeout", 3000)),
                ))
            elif path == "/api/v1/proxy/prefs":
                want = body.get("hide_timeout")
                result = proxy.set_prefs(None if want is None else bool(want))
                # 分组的缓存是按后端分 key 的，改完偏好要把整批打掉，
                # 否则界面会拿着「没过滤」的旧列表再画一遍
                cache_drop_prefix("proxy_groups:")
                self._json(result)

            # ---- 订阅地址管理（新增 / 改名改址 / 删除 / 拉取更新）
            elif path == "/api/v1/proxy/subscriptions":
                self._json(subscriptions.dispatch(body))

            # ---- 切换 OpenClash 配置文件：改 uci + 重启内核，会断网十几秒
            elif path == "/api/v1/proxy/config":
                self._json(proxy.switch_config(str(body.get("path", ""))))

            # ---- 系统维护：安装包、路由器密码、软件包更新
            elif path == "/api/v1/system/install":
                # 装包 = 用 root 跑对方的代码，必须二次确认（按文件类型核对）
                self._json(system.install(str(body.get("name", "")),
                                          str(body.get("confirm", ""))))
            elif path == "/api/v1/system/uploads/delete":
                self._json(system.remove_upload(str(body.get("name", ""))))
            elif path == "/api/v1/system/root_password":
                result = system.root_password(
                    str(body.get("current", "")), str(body.get("new", "")))
                if result.get("ok"):
                    # root 口令变了，LuCI 免密登录要跟着换钥匙，否则下次打开
                    # 网页端会掉回登录页（用户会以为是 App 坏了）
                    luci.remember(str(body.get("new", "")))
                self._json(result)
            elif path == "/api/v1/system/update":
                action = str(body.get("action", "status"))
                if action == "check":
                    self._json(system.check_updates(refresh=bool(body.get("refresh", False))))
                elif action == "upgrade":
                    pkgs = body.get("packages")
                    self._json(system.upgrade(pkgs if isinstance(pkgs, list) else None))
                else:
                    self._json(system.update_status())

            # ---- 设备管理
            elif path == "/api/v1/devices/rename":
                self._json(devices.rename(str(body.get("mac", "")), str(body.get("alias", ""))))
            elif path == "/api/v1/devices/block":
                self._json(devices.block(str(body.get("mac", "")), bool(body.get("enabled", True))))
            elif path == "/api/v1/devices/bind":
                self._json(devices.bind_static(str(body.get("mac", "")), str(body.get("ip", ""))))
            elif path == "/api/v1/devices/unbind":
                self._json(devices.unbind_static(str(body.get("mac", ""))))
            elif path == "/api/v1/devices/wol":
                self._json(devices.wol(str(body.get("mac", ""))))

            # ---- 电源与服务控制
            elif path == "/api/v1/power":
                self._json(power.run(str(body.get("action", "")), str(body.get("confirm", ""))))

            # ---- 广告拦截
            elif path == "/api/v1/adblock/probe":
                self._json(adblock.preflight())
            elif path == "/api/v1/adblock/takeover":
                self._json(adblock.takeover())
            elif path == "/api/v1/adblock/release":
                self._json(adblock.release())
            elif path == "/api/v1/adblock/refresh":
                self._json(adblock.refresh_rules())
            elif path == "/api/v1/adblock/rules":
                # 规则更新配置：自动间隔 / 立即更新 / 单表开关
                action = str(body.get("action", "set_interval"))
                if action == "toggle":
                    self._json(adblock.toggle_list(
                        body.get("id", 0), bool(body.get("enabled", True))))
                elif action == "refresh_now":
                    self._json(adblock.refresh_rules())
                else:
                    self._json(adblock.set_interval(body.get("interval", 24)))
            elif path == "/api/v1/adblock/service":
                self._json(adblock.service(str(body.get("action", ""))))
            elif path == "/api/v1/adblock/install":
                # 一键安装：必须带 confirm=install，跑在后台线程里，
                # 这个接口只负责「受理」，进度靠 GET 同一个路径查
                self._json(adblock.install(str(body.get("confirm", ""))))

            elif path == "/api/v1/network/wan":
                self._json(netcfg.apply_wan(body))

            # 手动重拨 / 断开 / 连接：不动配置，所以不挂回滚守护
            elif path == "/api/v1/net/wan/action":
                self._json(netcfg.wan_action(str(body.get("action", ""))))

            # ---- 网络改动的「待确认」事务
            # 改完配置 → 客户端重连 → 点确认，这是唯一能证明管理面没被锁死的证据。
            # 不确认就由后台守护在超时后自动回滚。
            elif path == "/api/v1/net/confirm":
                self._json(netapply.confirm(str(body.get("token", ""))))
            elif path == "/api/v1/net/rollback":
                self._json(netapply.rollback(str(body.get("token", ""))))

            # 防火墙只做只读展示：App 不再提供任何写入入口，
            # 一切策略调整都回到 LuCI 做，避免误操作把全家的网关掉。

            # ---- LAN 管理地址 / DHCP 地址池
            # 改地址会让客户端当场掉线，所以走和防火墙同一套事务：
            # 客户端换到新地址重连成功后点确认，否则守护自动改回去。
            elif path == "/api/v1/net/lan":
                r = lanedit.apply(body, self._client_ip())
                if r.get("ok"):
                    cache_drop("firewall", "network", "overview")
                self._json(r)

            # ---- 配置备份 / 恢复
            elif path == "/api/v1/config/backups":
                self._json(cfgbak.create(str(body.get("name", "")),
                                         str(body.get("note", "")),
                                         "manual"))
            elif path == "/api/v1/config/backups/restore":
                r = cfgbak.restore(str(body.get("id", "")),
                                   bool(body.get("allow_lan_change", False)),
                                   self._client_ip())
                if r.get("ok"):
                    # 整份配置都换了，所有缓存都不再可信
                    cache_drop("firewall", "network", "overview", "adblock_status")
                self._json(r)
            elif path == "/api/v1/config/backups/delete":
                self._json(cfgbak.delete(str(body.get("id", ""))))

            elif path == "/api/v1/password":
                cur = str(body.get("current", ""))
                new = str(body.get("new", ""))
                if not auth.verify_password(cur, self._client_ip()):
                    self._json({"ok": False, "error": "当前密码不正确"}, 403)
                    return
                if len(new) < 8:
                    self._json({"ok": False, "error": "新密码至少 8 位"}, 400)
                    return
                conf = load_cfg()
                conf["auth"]["password"] = new
                if not save_cfg(conf):
                    self._json({"ok": False, "error": "写入配置失败"}, 500)
                    return
                # 换签名密钥：旧口令签发的令牌立刻作废，否则改完密码
                # 之前泄漏的令牌还能用满 7 天
                auth.rotate_key()
                self._json({"ok": True, "reauth": True})
            else:
                self._error(404, "not found")

        except Exception as exc:  # 兜底：宁可回一个 JSON 500，也别把连接直接掐了
            _log("POST %s 失败: %r" % (path, exc))
            self._json({"ok": False, "error": "操作失败，详情见路由器系统日志"}, 500)

    def do_PUT(self):  # noqa HTTP 钩子
        self.do_POST()

    def do_PATCH(self):  # noqa HTTP 钩子
        self.do_POST()

    # ------------------------------------------------------------ GET 接口

    def _api_get(self, path: str, query: dict):
        try:
            if path == "/api/v1/overview":
                # 这里不再整份缓存：sysinfo.overview() 自己把慢变量缓存 1 秒，
                # 网口那段每次取共享采样。整份缓存会把速率一起冻住，
                # 和 /traffic、/network 对不上（同一秒能差出一个数量级）。
                # 也别试图把缓存提到 3 秒：客户端正好 3 秒轮询一次，
                # 曲线上会冒出平段；冷计算本身只有 1–5ms，不值得。
                self._json(sysinfo.overview())
            elif path == "/api/v1/traffic":
                net = sysinfo.interfaces()
                self._json({
                    "ts": int(time.time()),
                    "wan": {
                        "rx_bps": net["wan"]["rx_bps"], "tx_bps": net["wan"]["tx_bps"],
                        "rx_total": net["wan"]["rx_total"], "tx_total": net["wan"]["tx_total"],
                    },
                    "ports": [{"name": p["name"], "role": p.get("role", ""),
                               "up": p["up"], "speed_mbps": p["speed_mbps"],
                               # mac 给网口详情用，界面上「哪个口接的是哪台设备」全靠它
                               "mac": p.get("mac", ""),
                               "rx_bps": p["rx_bps"], "tx_bps": p["tx_bps"],
                               "rx_total": p["rx_total"], "tx_total": p["tx_total"]}
                              for p in net["ports"]],
                })
            elif path == "/api/v1/apps":
                # 自带 3 秒采样的后台线程，不走 cached()，否则速率会被冻住
                self._json(apps.snapshot())
            elif path == "/api/v1/network":
                self._json(cached("network", 1.0, sysinfo.interfaces))
            elif path == "/api/v1/network/wan":
                # 配置与运行态要一起给：界面上「当前是 PPPoE，已拨上，IP 100.70.72.34」
                # 三块信息必须同时到位，分两个请求会出现「配置是新的、状态是旧的」的错觉
                self._json(netcfg.overview())
            elif path == "/api/v1/network/lan":
                self._json(netcfg.lan())
            elif path == "/api/v1/luci/session":
                # 给内置 WebView 的免密通行证：Agent 代登录一次 LuCI，
                # 把 sysauth_http 这个 cookie 交给客户端（口令不出路由器）
                self._json(luci.ticket(self._host_only()))
            elif path == "/api/v1/network/firewall":
                # cached() 返回的是同一个对象，直接往上写会污染缓存，所以先拷一层
                base = dict(cached("firewall", 10.0, netcfg.firewall))
                base["readonly"] = True
                base["note"] = ("这里只做展示。修改防火墙请到路由器网页端（LuCI → 网络 → 防火墙），"
                                "App 不提供写入入口。")
                self._json(base)

            # ---- 待确认的网络改动
            elif path == "/api/v1/net/pending":
                self._json(netapply.status())

            # ---- LAN 可编辑项（地址 / 掩码 / 地址池 / 租期）
            elif path == "/api/v1/net/lan":
                self._json(lanedit.config(self._client_ip()))

            # ---- 配置备份
            elif path == "/api/v1/config/backups":
                self._json(cfgbak.list_backups())
            elif path == "/api/v1/system/hardware":
                force = query.get("force", ["0"])[0] in ("1", "true", "yes")
                self._json(hardware.hardware(force=force))
            elif path == "/api/v1/clients":
                self._json({"clients": cached("clients", 5.0, sysinfo.clients)})
            elif path == "/api/v1/devices":
                # 不走缓存：速率是实时值，缓存住会看到一动不动
                # 出口统一脱敏：公网 / 全局 IPv6 打码，局域网地址原样
                self._json(mask.devices(devices.list_devices()))
            elif path == "/api/v1/devices/detail":
                self._json(mask.devices(devices.detail(query.get("mac", [""])[0])))
            elif path == "/api/v1/storage":
                self._json({"storage": cached("storage", 10.0, sysinfo.storage)})
            elif path == "/api/v1/clash":
                self._json(cached("clash_status", 3.0, clash.status))
            elif path == "/api/v1/clash/proxies":
                self._json(cached("clash_proxies", 5.0, clash.proxies))
            elif path == "/api/v1/clash/connections":
                self._json(clash.connections())
            elif path == "/api/v1/clash/delay":
                name = query.get("name", [""])[0]
                self._json(clash.delay(name))

            # ---- 代理后端抽象
            elif path == "/api/v1/proxy":
                self._json(cached("proxy_overview", 4.0, proxy.overview))
            elif path == "/api/v1/proxy/groups":
                backend = query.get("backend", [""])[0]
                self._json(cached(f"proxy_groups:{backend}", 5.0, lambda: proxy.groups(backend)))
            elif path == "/api/v1/proxy/prefs":
                self._json(proxy.prefs())
            elif path == "/api/v1/proxy/connections":
                self._json(proxy.connections(query.get("backend", [""])[0]))
            elif path == "/api/v1/proxy/mode":
                self._json(proxy.mode())

            # ---- 订阅地址
            elif path == "/api/v1/proxy/subscriptions":
                self._json(subscriptions.list_subs(query.get("backend", [""])[0]))
            # ---- OpenClash 配置文件（同一时刻只启用一个）
            elif path == "/api/v1/proxy/configs":
                self._json(cached("proxy_configs", 6.0, proxy.configs))

            # ---- 系统维护
            elif path == "/api/v1/system/update":
                self._json(system.update_status())
            elif path == "/api/v1/system/firmware":
                # 固件 OTA 检查和软件包检查是两条链路，接口也分开
                self._json(system.firmware_check())
            elif path == "/api/v1/system/uploads":
                self._json(system.uploads())

            # ---- 电源与服务
            elif path == "/api/v1/power":
                self._json(power.info())

            # ---- 广告拦截
            elif path == "/api/v1/adblock":
                self._json(cached("adblock_status", 2.0, adblock.status))
            elif path == "/api/v1/adblock/install":
                # 安装进度：1 秒一跳，不走缓存（装了才会用到，平时成本为零）
                self._json(adblock.install_status())
            elif path == "/api/v1/adblock/preflight":
                # 体检要读 meminfo、DNS 链路、dnsmasq 上游、AGH 状态，一次 130ms；
                # 结果是「当前状态」，5 秒内重复问没有意义
                self._json(cached("adblock_preflight", 5.0, adblock.preflight))
            elif path == "/api/v1/adblock/verify":
                # 独立校验：现在这条 DNS 链路到底通不通（国内 / 国外 / IPv6 各查一次）
                self._json(adblock.verify())
            elif path == "/api/v1/adblock/log":
                # 拉一次 AGH 查询日志要 200ms（40KB 回包 + 过滤），
                # 而这一页只是「打开看一眼」，2 秒内重复请求直接复用
                log_limit = int(query.get("limit", ["120"])[0] or 120)
                log_only = query.get("only_blocked", ["0"])[0] in ("1", "true", "yes")
                log_search = query.get("search", [""])[0]
                self._json(cached(
                    f"adblock_log:{log_limit}:{int(log_only)}:{log_search}", 2.0,
                    lambda: adblock.log(limit=log_limit, only_blocked=log_only,
                                        search=log_search)))
            elif path == "/api/v1/adblock/top":
                # 首屏只放拦截次数最多的几条，明细在二级页面看。
                # 统计窗口是 AGH 启动以来，变化很慢，缓存 4 秒足够，省得跟着刷新节拍反复查日志
                n = int(query.get("limit", ["5"])[0] or 5)
                self._json(cached(f"adblock_top:{n}", 4.0, lambda: adblock.top(limit=n)))
            elif path == "/api/v1/adblock/rules":
                # 规则清单与自动更新间隔：界面上要回答「现在是自动还是手动」
                self._json(cached("adblock_rules", 4.0, adblock.rules))

            elif path == "/api/v1/health":
                self._json({
                    "ok": True,
                    "version": VERSION,
                    "uptime": round(time.time() - START_TS, 1),
                    "listen": cfg("listen", {}),
                    "password_is_default": cfg("auth", {}).get("password") in ("changeme", ""),
                })
            else:
                self._error(404, "not found")

        except Exception as exc:  # 兜底：宁可回一个 JSON 500，也别把连接直接掐了
            _log("GET %s 失败: %r" % (path, exc))
            self._json({"ok": False, "error": "读取失败，详情见路由器系统日志"}, 500)


def _local_v4() -> set[str]:
    """本机当前的 IPv4 地址集合，用来判断绑定地址还在不在。"""
    out: set[str] = set()
    try:
        for line in sysinfo._run(["ip", "-o", "-4", "addr", "show"], timeout=4).splitlines():
            for part in line.split():
                if "/" in part and part.count(".") == 3:
                    out.add(part.split("/")[0])
    except Exception:
        pass
    return out


def _bind_host(want: str, wait: float = 0.0) -> str:
    """绑定地址已经不在本机时，退到通配地址。

    LAN 管理地址可以从 App 里改，改完那个 IP 就不存在了。agent 如果还死绑
    在上面，socket 就成了孤儿：客户端连不上，也就永远回不来点「确认」，
    结果每次改地址都超时回滚，看起来像功能坏了。

    但**不能一探不到就退**：服务重启经常撞上 network reload，那一瞬间
    `ip addr` 还没配上地址，退到 0.0.0.0 就等于把管理面摊到 WAN 上
    （实测重启后确实出现过）。所以启动时先等 wait 秒，等不到才降级，
    并且把降级这件事明确打出来。
    """
    want = (want or "").strip()
    if want in ("", "0.0.0.0", "*"):
        return "0.0.0.0"
    if want in ("localhost", "127.0.0.1"):
        return "127.0.0.1"

    deadline = time.time() + max(0.0, wait)
    while True:
        if want in _local_v4():
            return want
        if time.time() >= deadline:
            break
        time.sleep(0.5)

    print("!!! [istore-agent] 绑定地址 %s 不在本机，已退到 0.0.0.0"
          " —— 管理面可能暴露到外网，请检查 LAN 地址" % want, flush=True)
    return "0.0.0.0"


def _watch_bind(httpd, host: str) -> None:
    """盯住绑定地址：它是具体 IP 且**连续几次**都消失时，让主循环重绑。

    连续判定是必须的：network reload 期间 `ip addr` 会短暂缺地址，
    单次失败就重绑会把管理面闪到 0.0.0.0 上。
    """
    if host in ("0.0.0.0", "127.0.0.1", ""):
        return
    miss = 0
    while True:
        time.sleep(2)
        if host in _local_v4():
            miss = 0
            continue
        miss += 1
        if miss < 3:
            continue
        print("!!! [istore-agent] %s 连续 %d 次不在本机，改绑 0.0.0.0" % (host, miss),
              flush=True)
        try:
            httpd.shutdown()
        except Exception:
            pass
        return


def serve():
    conf = load_cfg()
    # 环境变量优先：ipk 的 init 脚本从 uci 读端口和绑定地址，
    # 这样在 LuCI 里改完重启服务就能生效，不用去动 config.json
    want = os.environ.get("ISTORE_AGENT_HOST") or conf["listen"]["host"]
    port = int(os.environ.get("ISTORE_AGENT_PORT") or conf["listen"]["port"])

    # 预热应用流量采样：先把基线打上，首个请求就能有速率而不是一堆 0
    try:
        apps.snapshot()
    except Exception:
        pass
    # 上次改完配置没确认就重启了：清掉残留状态，否则界面永远显示「等待确认」
    try:
        netapply.boot_check()
    except Exception:
        pass
    # DNS 兜底巡检：接管后 AGH 起不来时，把 53 还给 dnsmasq。
    # 放在开机这里起，而不是等 App 来读状态 —— 断网时 App 恰恰是最晚知道的
    try:
        adblock.ensure_watchdog()
    except Exception:
        pass

    # 主循环：正常只跑一圈；只有当绑定地址失效（改了 LAN）时才会重绑。
    # 首圈等 10 秒：开机/重启时网卡可能还没配好地址。
    first = True
    while True:
        host = _bind_host(want, wait=10 if first else 0)
        first = False
        httpd = ThreadingHTTPServer((host, port), Handler)
        httpd.daemon_threads = True  # noqa ThreadingHTTPServer 的开关
        print(f"[istore-agent] listening on {host}:{port}", flush=True)
        threading.Thread(target=_watch_bind, args=(httpd, host), daemon=True).start()
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            httpd.server_close()
            return
        finally:
            try:
                httpd.server_close()
            except Exception:
                pass
        time.sleep(1)
