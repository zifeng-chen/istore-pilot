"""中兴 AP 的接入设备表 —— 「这台设备是插网线还是连 WiFi」的唯一真值来源。

为什么必须问 AP
---------------
软路由**看不到**这件事。AP 是桥接的，无线和有线都桥到同一根网线，
`brctl showmacs br-lan` 里所有 MAC 都落在同一个 port，上游只看到
「一个以太网帧从 port 1 进来」。关联信息只存在 AP 的 802.11 表里。

接口（实测机型 ZXSLC SR7410 / V1.0.0.7B4.8000，Mesh 主节点）
------------------------------------------------------------
1. ``GET  /?_type=loginsceneData&_tag=login_token_json``  → ``{logintoken, _sessionToken}``
2. ``POST /?_type=loginData&_tag=login_entry``
   ``Username/Password/action=login/Frm_Logintoken/captchaCode`` + ``_sessionTOKEN``,
   其中 ``Password = sha256(口令 + logintoken)`` 的十六进制小写
3. ``GET  /?_type=hiddenData&_tag=accessdev_data`` → XML，``OBJ_LAN_ACCESS_ID`` 里一串
   ``<Instance>``，每条是一个接入设备
4. ``POST /?_type=loginData&_tag=logout_entry`` ``{IF_LogOff:1}`` —— 读完就退

一个 AP 只允许一个管理会话：读之前登录，读完立刻退出（``logout_entry``），
所以正常情况下不会留下任何会话。

如果别人正占着（``e_exceed_max_user_preempt``，多半是用户开着网页后台）：
先让着他，每 30 秒看一眼；**被占超过 90 秒、且 15 分钟内没抢过**，才抢占一次
（``login_preempt``）。抢占会把对方踢回登录页，所以这个策略是克制而不是激进：
临时进后台改个设置不会被踢，只有卡死的残留会话才会被清掉。

字段含义
--------
``ConnectType``    0 有线 / 1 无线
``InterfaceType``  1 以太 / 3 无线
``Band``           2.4G / 5G（有线为空）
``Interface``      eth1 / wlan0 / wlan4

为什么要多台 AP
---------------
Mesh 里从节点的无线客户端，在**主节点**的表里会以 ``eth1``（有线）出现 ——
它们是通过回程网线过来的。所以每台节点的表都要读，合并规则是：
**任何一台说无线就是无线**（带频段），全部说有线的才算有线。
"""

from __future__ import annotations

import hashlib
import http.cookiejar
import json
import re
import threading
import time
import urllib.parse
import urllib.request

from . import config

#: 一轮刷新间隔。AP 管理会话有「同时只能一个人」的限制，太勤没意义；
#: 接入方式也不会几分钟就变，5 分钟足够
REFRESH_SEC = 300.0
#: 失败（多半是 AP 后台正被别人占着）时的重试间隔：等一会儿就能挤进去
RETRY_SEC = 30.0
#: 被占多久才考虑抢占。刚被占多半是用户正在改设置，先让给他
PREEMPT_AFTER = 90.0
#: 两次抢占至少隔这么久，别把用户反复踢回登录页
PREEMPT_COOLDOWN = 900.0
#: 连续多少轮「硬失败」之后拉长间隔。口令错、设备不是中兴、地址填错这类
#: 问题重试再快也没用，别把别人的路由器当靶子打
FATAL_AFTER = 3
FATAL_SEC = 1800.0
#: 单次请求超时。AP 的 web 服务是单线程 CGI，卡住时宁可放弃
TIMEOUT = 6.0

_CT_RE = re.compile(r"<Instance>(.*?)</Instance>", re.S)
_PAIR_RE = re.compile(r"<ParaName>([^<]*)</ParaName><ParaValue>([^<]*)</ParaValue>")
_BLOCK_RE = re.compile(r"<OBJ_LAN_ACCESS_ID>(.*?)</OBJ_LAN_ACCESS_ID>", re.S)

_lock = threading.Lock()
#: 每台 AP 从什么时候开始被占着 / 上次抢占是什么时候
_blocked_since: dict[str, float] = {}
_last_preempt: dict[str, float] = {}
_map: dict[str, dict] = {}
_state: dict = {"ts": 0.0, "errors": {}, "hosts": {}, "ok": False}
_thread: threading.Thread | None = None


def settings() -> dict:
    conf = (config.load().get("ap") or {})
    hosts = [str(h).strip() for h in (conf.get("hosts") or []) if str(h).strip()]
    return {
        "enabled": bool(conf.get("enabled", False)) and bool(hosts),
        "hosts": hosts,
        "user": str(conf.get("user") or "admin"),
        "password": str(conf.get("password") or ""),
    }


# ---------------------------------------------------------------- HTTP


def _post(opener, base: str, path: str, fields: dict) -> str:
    body = "&".join(
        k + "=" + urllib.parse.quote(str(v), safe="") for k, v in fields.items()
    ).encode()
    req = urllib.request.Request(base + path, data=body, method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    req.add_header("Referer", base + "/")
    with opener.open(req, timeout=TIMEOUT) as r:
        return r.read().decode("utf-8", "replace")


def _get(opener, base: str, path: str) -> str:
    req = urllib.request.Request(base + path)
    req.add_header("Referer", base + "/")
    with opener.open(req, timeout=TIMEOUT) as r:
        return r.read().decode("utf-8", "replace")


def _preempt_info(opener, base: str, sess: str) -> dict:
    """被占用时，问一下占着的人是谁：{sid, ip, mac}。

    ZTE 的返回里有个 LOGIN_PREEMPT_ID 块，`preempt_sessid` 用来抢，
    `preempt_ip` 用来在日志里说清楚抢的是谁。
    """
    if not sess:
        return {}
    try:
        xml = _get(opener, base,
                   "/?_type=hiddenData&_tag=vue_userif_data&_sessionTOKEN=" + sess)
    except Exception:
        return {}
    m = re.search(r"<LOGIN_PREEMPT_ID>(.*?)</LOGIN_PREEMPT_ID>", xml, re.S)
    if not m:
        return {}
    rec = {k: v for k, v in _PAIR_RE.findall(m.group(1))}
    return {"sid": rec.get("preempt_sessid", ""), "ip": rec.get("preempt_ip", ""),
            "mac": rec.get("preempt_mac", "")}


def _login(base: str, user: str, password: str, opener=None):
    """返回 (opener, sess_token, error, holder)。error 非空就别往下走。

    ``opener`` 传进来就沿用同一个 cookie 罐 —— 抢占之后必须这样：AP 会把
    新会话绑在原来那条 SID 上，换一个罐子再登录会被当成「页面过期」。
    """
    if opener is None:
        jar = http.cookiejar.CookieJar()
        opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    tok = json.loads(_get(opener, base, "/?_type=loginsceneData&_tag=login_token_json"))
    if "logintoken" not in tok:
        return opener, "", "拿不到 logintoken", {}
    digest = hashlib.sha256((password + tok["logintoken"]).encode()).hexdigest()
    resp = json.loads(_post(opener, base, "/?_type=loginData&_tag=login_entry", {
        "Username": user,
        "Password": digest,
        "action": "login",
        "Frm_Logintoken": "",
        "captchaCode": "",
        "_sessionTOKEN": tok.get("_sessionToken", ""),
    }))
    kind = str(resp.get("loginErrType") or "")
    if kind == "e_exceed_max_user_preempt":
        # 已经有人在管（可能是用户的浏览器，也可能是上一次没退干净的会话）。
        # 先记下对方是谁，抢不抢由 _refresh 决定
        holder = _preempt_info(opener, base, str(resp.get("sess_token") or ""))
        who = holder.get("ip") or ""
        return opener, "", ("有人正在管理 AP" + ("（" + who + "）" if who else "")), holder
    msg = str(resp.get("loginErrMsg") or "")
    if msg:
        return opener, "", msg, {}
    sess = str(resp.get("sess_token") or tok.get("_sessionToken") or "")
    return opener, sess, "", {}


def _logout(opener, base: str, sess: str) -> None:
    try:
        _post(opener, base, "/?_type=loginData&_tag=logout_entry",
              {"IF_LogOff": "1", "_sessionTOKEN": sess})
    except Exception:
        pass


def _parse(xml: str) -> dict[str, dict]:
    """XML → {mac: {type, band, iface, ip, host, node}}。"""
    out: dict[str, dict] = {}
    for block in _BLOCK_RE.findall(xml):
        for inst in _CT_RE.findall(block):
            rec = {k.replace("_LuQUID_", ""): v for k, v in _PAIR_RE.findall(inst)}
            mac = (rec.get("MACAddress") or "").lower()
            if not mac:
                continue
            wireless = str(rec.get("ConnectType") or "0") == "1"
            iface = rec.get("Interface") or ""
            out[mac] = {
                "type": "wifi" if wireless else "wired",
                # Band 只有无线的才有值，2.4G / 5G
                "band": (rec.get("Band") or "") if wireless else "",
                "iface": iface,
                "ip": rec.get("IPAddress") or "",
                "host": rec.get("HostName") or "",
            }
    return out


def _fetch_one(host: str, user: str, password: str,
               allow_preempt: bool = False) -> tuple[dict, str, dict]:
    """读一台 AP 的接入设备表 → (行, 错误, 占位者信息)。"""
    base = host if host.startswith("http") else "http://" + host
    opener, sess, err, holder = _login(base, user, password)

    kicked = ""
    if err:
        # 被占着：只有「已经占了好一会儿」才抢。抢的是别人正在用的会话，
        # 会把对方踢回登录页，所以调用方要克制（见 _refresh）
        if not (allow_preempt and holder.get("sid")):
            return {}, err, holder
        kicked = holder.get("ip", "")
        fields = {"preempt_sessid": holder["sid"], "action": "preempt",
                  "_sessionTOKEN": sess}
        try:
            # 先打一下首页：ZTE 自己的前端也是这么干的。少了这一步
            # login_preempt 会静默失败 —— 返回体看着正常，会话却没换过来
            _post(opener, base, "/", fields)
            _post(opener, base, "/?_type=loginData&_tag=login_preempt", fields)
        except Exception:
            pass
        _last_preempt[host] = time.time()
        opener, sess, err, holder = _login(base, user, password, opener)
        if err:
            return {}, err, holder

    try:
        xml = _get(opener, base, "/?_type=hiddenData&_tag=accessdev_data")
    finally:
        _logout(opener, base, sess)

    if "OBJ_LAN_ACCESS_ID" not in xml:
        # 「登录返回成功、数据接口却说会话过期」是这台 AP 的常见半吊子状态
        # （多半是上一次进程被杀，会话还挂在那儿）。退掉重登一次基本都能拿到。
        opener, sess, err, holder = _login(base, user, password)
        if err:
            return {}, err, holder
        try:
            xml = _get(opener, base, "/?_type=hiddenData&_tag=accessdev_data")
        finally:
            _logout(opener, base, sess)
        if "OBJ_LAN_ACCESS_ID" not in xml:
            return {}, "接入设备表读不到（会话失效？）", {}
    rows = _parse(xml)
    for rec in rows.values():
        rec["ap"] = host
    return rows, "", {}


# ---------------------------------------------------------------- 轮询


#: 这些错误下一轮大概率就好了，不该退避
_TRANSIENT = ("有人正在管理", "读不到", "页面过期", "SessionTimeout")


def _transient(msg: str) -> bool:
    return any(key in msg for key in _TRANSIENT)


def _refresh() -> None:
    conf = settings()
    if not conf["enabled"]:
        with _lock:
            _map.clear()
            _state.update({"ts": time.time(), "ok": False, "errors": {},
                           "hosts": {}, "disabled": True, "preempted": {}})
        return

    merged: dict[str, dict] = {}
    errors: dict[str, str] = {}
    counts: dict[str, int] = {}
    preempted: dict[str, str] = {}
    now = time.time()

    for host in conf["hosts"]:
        since = _blocked_since.get(host, 0.0)
        # 被占超过 90 秒、且 15 分钟内没抢过，才动手 —— 一次抢占会把对方
        # 从网页后台踢回登录页，能不做就不做
        allow = (bool(since) and now - since >= PREEMPT_AFTER
                 and now - _last_preempt.get(host, 0.0) >= PREEMPT_COOLDOWN)
        try:
            rows, err, extra = _fetch_one(host, conf["user"], conf["password"], allow)
        except Exception as exc:      # 网络抖动 / AP 重启
            rows, err, extra = {}, str(exc)[:80], {}
        if err:
            errors[host] = err
            if extra.get("sid") and not since:
                _blocked_since[host] = now
            continue
        _blocked_since.pop(host, None)
        if extra.get("kicked"):
            preempted[host] = extra["kicked"]
        counts[host] = len(rows)
        for mac, rec in rows.items():
            old = merged.get(mac)
            # 任何一台说无线就是无线：从节点的无线客户端在主节点表里
            # 会以 eth1 出现，先写进去的「有线」不能把它盖掉
            if old is None or (rec["type"] == "wifi" and old["type"] != "wifi"):
                merged[mac] = rec

    # 有些失败是自己会好的（会话过期、被占一下），值得 30 秒后再试；
    # 其余（口令错、不是中兴、地址不通）重试再快也没用，连撞三次就退到半小时
    fatal = any(not _transient(msg) for msg in errors.values())

    with _lock:
        _map.clear()
        _map.update(merged)
        _state.update({"ts": time.time(), "ok": bool(merged), "errors": errors,
                       "hosts": counts, "disabled": False, "preempted": preempted,
                       "fatal": fatal})


def _loop() -> None:
    streak = 0
    while True:
        ok = False
        fatal = False
        try:
            _refresh()
            with _lock:
                # 「全部 AP 都读到了」才算成功：只有主节点成功、从节点还被占着
                # 的时候，那批设备会被误判成有线，得按失败节奏快点重试
                ok = bool(_state.get("ok")) and not _state.get("errors")
                fatal = bool(_state.get("fatal"))
        except Exception:
            fatal = True

        if ok:
            streak = 0
            delay = REFRESH_SEC
        else:
            streak += 1
            # 硬失败连撞三次墙就退到半小时一轮：换别的牌子 AP、口令填错的时候，
            # 不该每 30 秒去敲人家一次
            delay = FATAL_SEC if (fatal and streak >= FATAL_AFTER) else RETRY_SEC
        time.sleep(delay)


def ensure() -> None:
    """起后台线程。第一次调用不会阻塞 —— 设备列表先按推测值出，下一轮才准。"""
    global _thread
    if _thread is not None and _thread.is_alive():
        return
    _thread = threading.Thread(target=_loop, name="istore-ap-zte", daemon=True)
    _thread.start()


def access_map() -> dict[str, dict]:
    """MAC → 接入方式。没数据就返回空，调用方回退到推测。"""
    with _lock:
        return dict(_map)


def status() -> dict:
    with _lock:
        return dict(_state)
