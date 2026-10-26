"""HTTP 服务：对外只暴露一套自定义 REST 接口，内部再调用 ubus / Clash / procfs。"""

from __future__ import annotations

import json
import mimetypes
import os
import posixpath
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import (adblock, apps, auth, cfgbak, clash, devices, hardware, lanedit, mask,
               netapply, netcfg, power, proxy, subscriptions, sysinfo, system)
from .config import get as cfg, load as load_cfg, save as save_cfg

WEB_ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "web")
START_TS = time.time()

# Agent 自身版本：随 ipk 一起发版，硬件详情页与「关于」都会显示
VERSION = "0.1.2"

_cache_lock = threading.Lock()
_cache: dict[str, tuple[float, object]] = {}


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


class Handler(BaseHTTPRequestHandler):
    server_version = "istore-agent/0.1"
    protocol_version = "HTTP/1.1"

    # ------------------------------------------------------------ 基础工具

    def log_message(self, fmt, *args):  # 静音，避免刷屏 procd 日志
        return

    def _send(self, code: int, body: bytes, ctype: str = "application/json; charset=utf-8", extra: dict | None = None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, OPTIONS")
        self.send_header("X-Content-Type-Options", "nosniff")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

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
        header = self.headers.get("Authorization", "")
        token = header[7:] if header.lower().startswith("bearer ") else ""
        if not token:
            token = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query).get("token", [""])[0]
        return auth.verify_token(token)

    def _client_ip(self) -> str:
        return self.client_address[0] if self.client_address else "?"

    # ------------------------------------------------------------ 路由分发

    def do_OPTIONS(self):
        self._send(204, b"")

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        query = urllib.parse.parse_qs(parsed.query)

        if path == "/api/v1/ping":
            # 这里的 version 一定要用 VERSION 常量。
            # 之前写死了一个 "0.1"，App 设置页就一直显示「Agent 版本 v0.1」，
            # 而 /health 报的是真版本，两个接口自相矛盾
            self._json({"ok": True, "service": "istore-agent", "version": VERSION,
                        "host": cfg("listen", {}).get("host"), "ts": int(time.time())})
            return

        if path.startswith("/api/"):
            if not self._authed():
                self._error(401, "unauthorized")
                return
            self._api_get(path, query)
            return

        self._static(parsed.path)

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

            # ---- 订阅地址管理（新增 / 改名改址 / 删除 / 拉取更新）
            elif path == "/api/v1/proxy/subscriptions":
                self._json(subscriptions.dispatch(body))

            # ---- 切换 OpenClash 配置文件：改 uci + 重启内核，会断网十几秒
            elif path == "/api/v1/proxy/config":
                self._json(proxy.switch_config(str(body.get("path", ""))))

            # ---- 系统维护：安装包、路由器密码、软件包更新
            elif path == "/api/v1/system/install":
                self._json(system.install(str(body.get("name", ""))))
            elif path == "/api/v1/system/uploads/delete":
                self._json(system.remove_upload(str(body.get("name", ""))))
            elif path == "/api/v1/system/root_password":
                self._json(system.root_password(
                    str(body.get("current", "")), str(body.get("new", ""))))
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
                self._json({"ok": True})
            else:
                self._error(404, "not found")

        except Exception as exc:  # 兜底：宁可回一个 JSON 500，也别把连接直接掐了
            self._json({"ok": False, "error": f"处理请求失败：{exc}"}, 500)

    def do_PUT(self):
        self.do_POST()

    def do_PATCH(self):
        self.do_POST()

    # ------------------------------------------------------------ GET 接口

    def _api_get(self, path: str, query: dict):
        try:
            if path == "/api/v1/overview":
                self._json(cached("overview", 1.0, sysinfo.overview))
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
                # 只给累计口径，period 参数保留但忽略（老客户端还在传）
                self._json(apps.snapshot(query.get("period", ["all"])[0]))
            elif path == "/api/v1/network":
                self._json(cached("network", 1.0, sysinfo.interfaces))
            elif path == "/api/v1/network/wan":
                # 配置与运行态要一起给：界面上「当前是 PPPoE，已拨上，IP 100.70.72.34」
                # 三块信息必须同时到位，分两个请求会出现「配置是新的、状态是旧的」的错觉
                self._json(netcfg.overview())
            elif path == "/api/v1/network/lan":
                self._json(netcfg.lan())
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
            elif path == "/api/v1/adblock/preflight":
                self._json(adblock.preflight())
            elif path == "/api/v1/adblock/verify":
                # 独立校验：现在这条 DNS 链路到底通不通（国内 / 国外 / IPv6 各查一次）
                self._json(adblock.verify())
            elif path == "/api/v1/adblock/log":
                self._json(adblock.log(
                    limit=int(query.get("limit", ["120"])[0] or 120),
                    only_blocked=query.get("only_blocked", ["0"])[0] in ("1", "true", "yes"),
                    search=query.get("search", [""])[0],
                ))
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
            self._json({"ok": False, "error": f"读取数据失败：{exc}"}, 500)

    # ------------------------------------------------------------ 静态资源

    def _static(self, raw_path: str):
        rel = posixpath.normpath(urllib.parse.unquote(raw_path)).lstrip("/")
        if rel in ("", "."):
            rel = "index.html"
        if rel.startswith(".."):
            self._error(403, "forbidden")
            return
        full = os.path.join(WEB_ROOT, *rel.split("/"))
        if not os.path.isfile(full):
            if "." not in posixpath.basename(rel):
                full = os.path.join(WEB_ROOT, "index.html")
                rel = "index.html"
            if not os.path.isfile(full):
                self._error(404, "not found")
                return
        ctype = mimetypes.guess_type(full)[0] or "application/octet-stream"
        if full.endswith(".webmanifest"):
            ctype = "application/manifest+json"
        try:
            with open(full, "rb") as fh:
                body = fh.read()
        except OSError:
            self._error(500, "read error")
            return
        # 代码类资源必须每次回源，否则改完前端客户端还在用旧版本
        volatile = full.endswith((".html", ".js", ".css", ".webmanifest", ".json"))
        cache = "no-cache, must-revalidate" if volatile else "public, max-age=3600"
        self._send(200, body, ctype, {"Cache-Control": cache})


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


def _bind_host(want: str) -> str:
    """绑定地址已经不在本机时，退到通配地址。

    LAN 管理地址可以从 App 里改，改完那个 IP 就不存在了。agent 如果还死绑
    在上面，socket 就成了孤儿：客户端连不上，也就永远回不来点「确认」，
    结果每次改地址都超时回滚，看起来像功能坏了。
    """
    want = (want or "").strip()
    if want in ("", "0.0.0.0", "*"):
        return "0.0.0.0"
    if want in ("localhost", "127.0.0.1"):
        return "127.0.0.1"
    return want if want in _local_v4() else "0.0.0.0"


def _watch_bind(httpd, host: str) -> None:
    """盯住绑定地址：它是具体 IP 且消失时，让主循环重新绑一次。"""
    if host in ("0.0.0.0", "127.0.0.1", ""):
        return
    while True:
        time.sleep(2)
        if host not in _local_v4():
            print(f"[istore-agent] {host} 已不在本机，改绑 0.0.0.0", flush=True)
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

    # 主循环：正常只跑一圈；只有当绑定地址失效（改了 LAN）时才会重绑
    while True:
        host = _bind_host(want)
        httpd = ThreadingHTTPServer((host, port), Handler)
        httpd.daemon_threads = True
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

