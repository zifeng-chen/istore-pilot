"""网络测速（FastNet）。

路由器上的 FastNet 提供了一套 SSE 接口：`/api/speedtest/stream`，事件是
`stage`（延迟/下载/上传三段，每段 starting → ok）与 `log`。没有鉴权，只监听
在 3200。所以这里不自己实现测速，只做「探测 → 安装 → 转发 → 落盘」四件事：

- 客户端不直连 3200：agent 走 127.0.0.1，不依赖 LAN 是否放行
- 测速是长任务（20 秒起），沿用订阅更新那套「后台线程 + 状态落盘 + 客户端轮询」
- FastNet 可能没装，所以有三态：absent（未安装）/ stopped（装了没起）/ ready
"""

import json
import os
import re
import socket
import subprocess
import threading
import time
import urllib.parse
import urllib.request

DATA_DIR = "/etc/istore-agent/data"
STATE_PATH = os.path.join(DATA_DIR, "speedtest.json")
INSTALL_PATH = os.path.join(DATA_DIR, "fastnet_install.json")
HISTORY_PATH = os.path.join(DATA_DIR, "speedtest_history.json")

BASE = "http://127.0.0.1:3200"
PORT = 3200
HISTORY_MAX = 20

_lock = threading.Lock()
_thread = None
#: 采样线程写到这儿，SSE 线程写状态文件时一起带上（各自写各自的会把对方覆盖掉）
_LIVE = {"liveDown": 0.0, "liveUp": 0.0}
#: 各阶段的采样峰值，用于最终结果（FastNet 自报值不可靠）
_PEAK = {"down": 0.0, "up": 0.0}


def _read(path: str, default):
    try:
        with open(path, "r", encoding="utf-8") as fp:
            return json.load(fp)
    except (OSError, ValueError):
        return default


def _write(path: str, data) -> None:
    try:
        os.makedirs(DATA_DIR, exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fp:
            json.dump(data, fp, ensure_ascii=False)
        os.replace(tmp, path)
    except OSError:
        pass


def _port_open(port: int = PORT, timeout: float = 0.6) -> bool:
    """FastNet 监听的是 :::3200（IPv6 通配），某些内核上 127.0.0.1 连不进去，
    所以 IPv4 失败后再试一次 ::1，否则状态会在 ready / stopped 之间乱跳。"""
    for host in ("127.0.0.1", "::1"):
        try:
            with socket.create_connection((host, port), timeout=timeout):
                return True
        except OSError:
            continue
    return False


def _installed() -> bool:
    """opkg 数据库里有没有 fastnet 包。只在端口不通时才调用，避免拖慢每次请求。"""
    try:
        out = subprocess.run(["opkg", "list-installed", "fastnet"],
                             capture_output=True, text=True, timeout=6).stdout
        return "fastnet" in out
    except (OSError, subprocess.SubprocessError):
        return False


def _run(argv: list, timeout: int = 90) -> tuple:
    """跑一条命令（列表参数，不走 shell），返回 (退出码, 输出尾部)。

    不用 shell=True：这里只有常量命令，但列表形式能从根上杜绝将来拼接注入。
    """
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        text = (p.stdout or "") + (p.stderr or "")
        return p.returncode, text.strip()[-1200:]
    except subprocess.TimeoutExpired:
        return 124, "超时：%s" % " ".join(argv)
    except OSError as e:
        return 1, str(e)


def _wan_dev() -> str:
    """WAN 的逻辑设备。PPPoE 拨号时是 pppoe-wan，DHCP 时是 eth0。"""
    for dev in ("pppoe-wan", "eth0", "wan"):
        if os.path.exists("/sys/class/net/%s/statistics/rx_bytes" % dev):
            return dev
    return ""


def _wan_bytes() -> tuple:
    dev = _wan_dev()
    if not dev:
        return 0, 0
    try:
        with open("/sys/class/net/%s/statistics/rx_bytes" % dev) as f:
            rx = int(f.read().strip())
        with open("/sys/class/net/%s/statistics/tx_bytes" % dev) as f:
            tx = int(f.read().strip())
        return rx, tx
    except (OSError, ValueError):
        return 0, 0


class _Sampler(threading.Thread):
    """测速期间每秒采样一次，把瞬时速率写进状态文件。

    FastNet 的 SSE 只在每一段结束时给一个最终值，中间过程什么都没有 ——
    界面要显示「正在跑」，只能自己从网口字节数算。
    """

    def __init__(self):
        super().__init__(daemon=True)
        self.stop_flag = False

    def run(self) -> None:
        last_rx, last_tx = _wan_bytes()
        last_t = time.time()
        while not self.stop_flag:
            time.sleep(1.0)
            rx, tx = _wan_bytes()
            now = time.time()
            span = max(0.2, now - last_t)
            live_in = (rx - last_rx) * 8.0 / span / 1e6
            live_out = (tx - last_tx) * 8.0 / span / 1e6
            last_rx, last_tx, last_t = rx, tx, now

            cur = _read(STATE_PATH, {})
            if cur.get("state") != "running":
                break
            stage = cur.get("stage", "")
            # 只记当前这一段的方向：测下行时上行数字不该跟着跳
            if stage == "download":
                _LIVE["liveDown"] = round(max(0.0, live_in), 1)
                _LIVE["liveUp"] = 0.0
                _PEAK["down"] = max(_PEAK["down"], _LIVE["liveDown"])
            elif stage == "upload":
                _LIVE["liveUp"] = round(max(0.0, live_out), 1)
                _LIVE["liveDown"] = 0.0
                _PEAK["up"] = max(_PEAK["up"], _LIVE["liveUp"])
            else:
                _LIVE["liveDown"] = 0.0
                _LIVE["liveUp"] = 0.0
            cur.update(_LIVE)
            _write(STATE_PATH, cur)


def state() -> str:
    if _port_open():
        return "ready"
    return "stopped" if _installed() else "absent"


# ---------------- 测速 ----------------

def _bench_worker(server_id: str) -> None:
    global _thread
    url = BASE + "/api/speedtest/stream"
    if server_id:
        url += "?serverId=" + urllib.parse.quote(server_id)
    result = {"state": "running", "stage": "speedtest", "msg": "准备测速",
              "ping": 0.0, "down": 0.0, "up": 0.0, "serverId": server_id,
              "server": "", "started": int(time.time()), "error": ""}
    _PEAK["down"] = 0.0
    _PEAK["up"] = 0.0
    _write(STATE_PATH, result)
    sampler = _Sampler()
    sampler.start()
    try:
        with urllib.request.urlopen(url, timeout=180) as resp:
            event = ""
            while True:
                raw = resp.readline()
                if not raw:
                    break
                line = raw.decode("utf-8", "replace").rstrip("\r\n")
                if line.startswith("event:"):
                    event = line[6:].strip()
                    continue
                if not line.startswith("data:"):
                    continue
                payload = line[5:].strip()
                if event == "stage":
                    try:
                        item = json.loads(payload)
                    except ValueError:
                        continue
                    stage = item.get("stage", "")
                    status = item.get("status", "")
                    msg = item.get("msg", "")
                    if stage in ("speedtest", "download", "upload"):
                        result["stage"] = stage
                    result["msg"] = msg
                    num = re.search(r"([\d.]+)", msg)
                    if status == "ok" and num:
                        value = float(num.group(1))
                        if stage == "speedtest" and "ms" in msg:
                            result["ping"] = value
                        elif stage == "download":
                            result["down"] = value
                        elif stage == "upload":
                            result["up"] = value
                    if stage == "speedtest" and ("服务器" in msg or "server " in msg):
                        result["server"] = msg.replace("服务器", "").replace("server ", "").strip()
                    result.update(_LIVE)
                    _write(STATE_PATH, result)
                elif event == "log":
                    if not result.get("log"):
                        result["log"] = []
                    result["log"] = (result.get("log") or [])[-8:] + [payload[:200]]
                    _write(STATE_PATH, result)
        # FastNet 自报的下行偶尔会出现远超链路能力的数字（实测报过 7148 Mbps），
        # 它自己的字节统计有问题；用我们采到的网口峰值更可信
        if _PEAK["down"] > 0:
            result["down"] = round(_PEAK["down"], 2)
        if _PEAK["up"] > 0:
            result["up"] = round(_PEAK["up"], 2)
        result["state"] = "done"
        result["msg"] = "完成"
        result["finished"] = int(time.time())
        _write(STATE_PATH, result)
        if result["down"] > 0 or result["up"] > 0:
            rows = _read(HISTORY_PATH, [])
            rows.insert(0, {"time": result["finished"], "ping": result["ping"],
                            "down": result["down"], "up": result["up"],
                            "server": result.get("server", "")})
            _write(HISTORY_PATH, rows[:HISTORY_MAX])
    except Exception as e:                      # noqa: BLE001 - 网络异常一律转成状态
        result["state"] = "failed"
        result["error"] = str(e)[:200]
        _write(STATE_PATH, result)
    finally:
        sampler.stop_flag = True
        _LIVE["liveDown"] = 0.0
        _LIVE["liveUp"] = 0.0
        result.pop("liveDown", None)
        result.pop("liveUp", None)
        with _lock:
            _thread = None


def start(server_id: str = "") -> dict:
    global _thread
    with _lock:
        if _thread is not None and _thread.is_alive():
            return {"ok": False, "error": "测速进行中", "status": status()}
        if state() == "stopped":
            # 装好了但服务没跑：直接拉起来，别让用户去点「启动」
            start_service()
        if state() != "ready":
            return {"ok": False, "error": "FastNet 未就绪", "status": status()}
        _thread = threading.Thread(target=_bench_worker, args=(server_id,), daemon=True)
        _thread.start()
    return {"ok": True}


_PROBE = {"rx": 0, "tx": 0, "t": 0.0}


def _probe_live() -> None:
    """status 被调用时顺手补一次采样。

    采样线程万一没起来（旧进程、线程异常），这里也能让数字动起来，
    不至于整轮都是 0.0。同样只算当前阶段的方向。
    """
    cur = _read(STATE_PATH, {})
    stage = cur.get("stage", "")
    if stage not in ("download", "upload"):
        _LIVE["liveDown"] = 0.0
        _LIVE["liveUp"] = 0.0
        return
    rx, tx = _wan_bytes()
    now = time.time()
    if _PROBE["t"] > 0:
        span = now - _PROBE["t"]
        if span >= 0.6:
            if stage == "download":
                _LIVE["liveDown"] = round(max(0.0, (rx - _PROBE["rx"]) * 8.0 / span / 1e6), 1)
                _LIVE["liveUp"] = 0.0
            else:
                _LIVE["liveUp"] = round(max(0.0, (tx - _PROBE["tx"]) * 8.0 / span / 1e6), 1)
                _LIVE["liveDown"] = 0.0
    _PROBE["rx"], _PROBE["tx"], _PROBE["t"] = rx, tx, now


def status() -> dict:
    st = state()
    cur = _read(STATE_PATH, {})
    if cur.get("state") == "running":
        _probe_live()
    out = {"ok": True, "state": st, "running": False, "ts": int(time.time())}
    if cur.get("state") == "running":
        # 先把实时值并进去，再读出来，否则读到的是上一拍（甚至 0）
        cur.update(_LIVE)
        _write(STATE_PATH, cur)
        out["running"] = True
        out["state"] = "ready" if st == "ready" else "running"
        for key in ("stage", "msg", "ping", "down", "up", "server", "liveDown", "liveUp"):
            out[key] = cur.get(key)
        out["elapsed"] = int(time.time()) - int(cur.get("started", 0))
    elif cur:
        if st != "ready" and cur.get("state") == "done":
            # 端口探测偶尔抖动，但上一轮结果是真的，不能因此把界面清空
            out["state"] = "done"
        for key in ("state", "stage", "msg", "started", "finished", "error"):
            if key in cur:
                out[key] = cur.get(key)
        # 数值以历史为准，且必须放在 cur 之后 ——
        # 之前写在前面，被 cur 里的 0 覆盖掉，界面就永远是「—」
        rows = _sane(_read(HISTORY_PATH, []))
        if rows:
            out["ping"] = rows[0].get("ping", 0)
            out["down"] = rows[0].get("down", 0)
            out["up"] = rows[0].get("up", 0)
            out["server"] = rows[0].get("server", "")
            out["finished"] = rows[0].get("time", 0)
        else:
            for key in ("ping", "down", "up", "server"):
                if key in cur:
                    out[key] = cur.get(key)
        if cur.get("state") == "running" and st != "ready":
            out["state"] = st
    inst = _read(INSTALL_PATH, {})
    if inst.get("state") in ("installing", "starting", "failed"):
        out["install"] = inst
    return out


def servers() -> dict:
    try:
        with urllib.request.urlopen(BASE + "/api/speedtest/servers", timeout=8) as resp:
            return json.loads(resp.read().decode("utf-8", "replace"))
    except Exception as e:                      # noqa: BLE001
        return {"servers": [], "error": str(e)[:120]}


def _sane(rows: list) -> list:
    """剔除明显不靠谱的记录：单播 5 Gbps 以上在普通宽带上不可能出现。"""
    return [r for r in rows if (r.get("down") or 0) <= 5000 and (r.get("up") or 0) <= 5000]


def history() -> dict:
    return {"rows": _sane(_read(HISTORY_PATH, []))}


# ---------------- 安装 ----------------

def _install_worker() -> None:
    global _thread
    steps = [
        ("update", "更新软件源", ["opkg", "update"], 120),
        ("install", "下载并安装 FastNet", ["opkg", "install", "fastnet", "luci-app-fastnet"], 180),
        ("enable", "设置开机自启", ["/etc/init.d/fastnet", "enable"], 20),
        ("start", "启动服务", ["/etc/init.d/fastnet", "start"], 40),
    ]
    st = {"state": "installing", "step": "", "msg": "", "log": [], "started": int(time.time())}
    _write(INSTALL_PATH, st)
    try:
        for key, label, cmd, timeout in steps:
            st["step"] = key
            st["msg"] = label
            _write(INSTALL_PATH, st)
            code, out = _run(cmd, timeout)
            st["log"] = (st["log"] + [out[-600:]])[-6:]
            _write(INSTALL_PATH, st)
            if code != 0 and key != "start":
                st["state"] = "failed"
                st["msg"] = "%s失败（退出码 %d）" % (label, code)
                _write(INSTALL_PATH, st)
                return
        st["state"] = "starting"
        st["msg"] = "等待测速服务就绪"
        _write(INSTALL_PATH, st)
        for _ in range(30):
            if _port_open():
                st["state"] = "done"
                st["msg"] = "安装完成"
                _write(INSTALL_PATH, st)
                return
            time.sleep(1)
        st["state"] = "failed"
        st["msg"] = "装好了但端口 %d 没起来" % PORT
        _write(INSTALL_PATH, st)
    except Exception as e:                      # noqa: BLE001
        st["state"] = "failed"
        st["msg"] = str(e)[:200]
        _write(INSTALL_PATH, st)
    finally:
        with _lock:
            _thread = None


def install() -> dict:
    global _thread
    with _lock:
        if _thread is not None and _thread.is_alive():
            return {"ok": False, "error": "有任务在跑", "status": status()}
        if state() == "ready":
            return {"ok": False, "error": "已经装好并运行中", "status": status()}
        _thread = threading.Thread(target=_install_worker, daemon=True)
        _thread.start()
    return {"ok": True}


def start_service() -> dict:
    """已安装但没运行：只起服务，不重新装包。"""
    if state() == "ready":
        return {"ok": True, "msg": "已在运行"}
    (_run(["/etc/init.d/fastnet", "enable"], 20),
     _run(["/etc/init.d/fastnet", "start"], 40))
    for _ in range(15):
        if _port_open():
            return {"ok": True, "msg": "已启动"}
        time.sleep(1)
    return {"ok": False, "msg": "启动后端口仍不通"}
