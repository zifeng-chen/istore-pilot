"""配置事务：快照 → 应用 → 待确认 → 超时自动回滚。

为什么需要这一层
----------------
`netcfg.apply_wan()` 里已经有一套「留底 + 派生守护 + 验收回滚」，但它只服务 WAN
一个场景，而且判据是「能不能 ping 通公网」——这个判据对 LAN / DHCP / 防火墙
完全不适用：改 LAN 网段时后台还在拨号，公网一直是通的，可手机已经连不上了。

所以这里换一个判据：**改完之后，客户端有没有回来确认**。
手机能重新连上 8443 并点下确认，就证明管理面是通的，这是所有网络改动共同
需要的唯一验收条件，与改的是哪一项无关。

三条硬约束
----------
1. 快照必须在「改之前」落盘，且放在持久分区（`/etc/istore-agent/data`）。
   `/tmp` 一重启就没了，而这恰恰是最需要回滚的时候。
2. 回滚由**独立进程**执行，不能挂在 agent 自己的线程上——改 LAN 地址会让
   agent 监听的地址消失，线程可能先于守护挂掉。
3. 状态文件用纯文本而不是 JSON：守护是 `sh`，要在没有任何依赖的情况下
   一行 `head -n1` 读出 token。
"""
from __future__ import annotations

import os
import shutil
import subprocess
import time
import uuid

DATA_DIR = "/etc/istore-agent/data"
TXN_DIR = os.path.join(DATA_DIR, "txn")
STATE = os.path.join(DATA_DIR, "txn.state")
GUARD = "/usr/lib/istore-agent/txn_guard.sh"
CONF_DIR = "/etc/config"

# 默认等待客户端确认的秒数。太短来不及重连，太长用户已经走了还在「待确认」
DEFAULT_WAIT = 60

# 服务名 → 重载命令。reload 不存在时守护会退化成 restart
SERVICE_NAMES = ("network", "firewall", "dnsmasq")

# 事务期间可能被改动的「旁路状态」文件。它们不在 /etc/config 里，
# 但同样是配置的一部分 —— 回滚时必须一起还原，否则会留下脏标记。
# 真实踩过：harden 删掉 wan→lan 转发时把这条记在 fw_saved.json 里，
# 事务超时回滚把 config 铺回去了，标记却留着，用户点「放宽」时
# 又照着标记补了一条，于是同一份配置里出现两条 wan→lan 转发。
SIDE_FILES = ("fw_saved.json",)


def _side_snapshot(snap: str) -> list[str]:
    """记下哪些旁路文件在事务开始前就存在，回滚时据此决定还原还是删除。"""
    side = os.path.join(snap, "side")
    os.makedirs(side, exist_ok=True)
    present: list[str] = []
    for name in SIDE_FILES:
        src = os.path.join(DATA_DIR, name)
        if os.path.isfile(src):
            try:
                shutil.copy2(src, os.path.join(side, name))
                present.append(name)
            except OSError:
                pass
    with open(os.path.join(side, "present"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(present))
    return present


def _side_restore(snap: str) -> None:
    side = os.path.join(snap, "side")
    try:
        with open(os.path.join(side, "present"), "r", encoding="utf-8") as fh:
            present = [x for x in fh.read().splitlines() if x]
    except OSError:
        present = []
    for name in SIDE_FILES:
        dst = os.path.join(DATA_DIR, name)
        src = os.path.join(side, name)
        try:
            if name in present and os.path.isfile(src):
                shutil.copy2(src, dst)
            elif os.path.exists(dst):
                os.remove(dst)
        except OSError:
            pass


def _guard_script() -> str:
    return f"""#!/bin/sh
# 由 istore-agent 自动生成：配置事务的超时守护，不要手工修改。
# 参数：$1 token  $2 快照目录  $3 等待秒数  $4 需要重载的服务  $5 旁路状态文件
TOKEN="$1"; SNAP="$2"; WAIT="$3"; SVCS="$4"; SIDE_LIST="$5"
sleep "$WAIT"
CUR=$(head -n1 {STATE} 2>/dev/null)
[ "$CUR" = "$TOKEN" ] || exit 0
# 仍然是本次事务 → 客户端没回来确认，回滚
cp -a "$SNAP/config/." {CONF_DIR}/ 2>/dev/null
for f in $SIDE_LIST; do
    if [ -f "$SNAP/side/$f" ]; then
        cp -f "$SNAP/side/$f" {DATA_DIR}/$f 2>/dev/null
    else
        rm -f {DATA_DIR}/$f
    fi
done
rm -f {STATE}
for s in $SVCS; do
    /etc/init.d/$s reload >/dev/null 2>&1 || /etc/init.d/$s restart >/dev/null 2>&1
done
logger -t istore-agent "配置事务 $TOKEN 超时未确认，已自动回滚"
"""


def _write_state(token: str, tag: str, snap: str, deadline: float,
                 services: tuple[str, ...], note: str) -> None:
    os.makedirs(DATA_DIR, exist_ok=True)
    tmp = STATE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("\n".join([
            token, str(int(deadline)), tag, snap,
            " ".join(services), note.replace("\n", " "),
        ]) + "\n")
    os.replace(tmp, STATE)


def read_state() -> dict | None:
    """读待确认事务。返回 None 表示没有进行中的事务。"""
    try:
        with open(STATE, "r", encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return None
    if len(lines) < 5:
        return None
    try:
        deadline = float(lines[1])
    except ValueError:
        return None
    left = int(deadline - time.time())
    # 过期的照样返回，只是把 left 压到 0 并打上 expired。
    # 以前这里直接返回 None，结果最后一秒里客户端会显示「没有待确认」，
    # 而守护其实正准备回滚 —— 用户看着「一切正常」，几秒后配置自己变了。
    return {
        "token": lines[0],
        "deadline": int(deadline),
        "tag": lines[2],
        "snap": lines[3],
        "services": lines[4].split(),
        "note": lines[5] if len(lines) > 5 else "",
        "left": max(0, left),
        "expired": left <= 0,
    }


def begin(tag: str, services: tuple[str, ...] = ("network", "firewall", "dnsmasq"),
          wait: int = DEFAULT_WAIT, note: str = "") -> dict:
    """开一个事务：先快照 /etc/config，再写状态、拉守护。

    调用方拿到 token 后自行改 uci、commit、reload；改完把 token 回给客户端。
    任何一步异常都必须调 rollback(token)，否则用户会被留在半改状态。
    """
    token = uuid.uuid4().hex[:12]
    snap = os.path.join(TXN_DIR, token)
    dst = os.path.join(snap, "config")
    try:
        os.makedirs(dst, exist_ok=True)
        for name in os.listdir(CONF_DIR):
            src = os.path.join(CONF_DIR, name)
            if os.path.isfile(src):
                shutil.copy2(src, os.path.join(dst, name))
    except OSError as exc:
        return {"ok": False, "error": f"无法创建配置快照（{exc}），未做任何修改"}

    if not os.listdir(dst):
        return {"ok": False, "error": "配置快照为空，未做任何修改"}

    _side_snapshot(snap)

    deadline = time.time() + wait
    _write_state(token, tag, snap, deadline, services, note)

    try:
        os.makedirs(os.path.dirname(GUARD), exist_ok=True)
        with open(GUARD, "w", encoding="utf-8") as fh:
            fh.write(_guard_script())
        os.chmod(GUARD, 0o755)
        subprocess.Popen(["/bin/sh", GUARD, token, snap, str(wait),
                          " ".join(services), " ".join(SIDE_FILES)],
                         start_new_session=True,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         close_fds=True)
    except Exception as exc:  # 守护起不来就别改了
        rollback(token, quiet=True)
        return {"ok": False, "error": f"无法启动回滚守护（{exc}），已还原配置"}

    return {"ok": True, "token": token, "wait": wait,
            "deadline": int(deadline), "services": list(services)}


def confirm(token: str) -> dict:
    """客户端确认：证明改完之后管理面仍然可达。"""
    st = read_state()
    if not st:
        return {"ok": False, "error": "没有进行中的配置事务"}
    if token and st["token"] != token:
        return {"ok": False, "error": "事务编号不匹配，可能已经被回滚"}
    try:
        os.remove(STATE)
    except OSError:
        pass
    # 确认后把快照删掉；只留最近一个「上一次可用配置」供手工恢复
    _prune(keep=st["snap"])
    return {"ok": True, "confirmed": True, "tag": st["tag"]}


def rollback(token: str = "", quiet: bool = False) -> dict:
    """立刻回滚。token 为空表示强制回滚当前事务。"""
    st = read_state()
    if not st:
        # 过期但文件还在的情况：read_state 已过滤，这里补一刀
        if quiet:
            return {"ok": False}
        return {"ok": False, "error": "没有可回滚的配置事务"}
    if token and token != st["token"] and not quiet:
        return {"ok": False, "error": "事务编号不匹配"}

    src = os.path.join(st["snap"], "config")
    ok = True
    try:
        for name in os.listdir(src):
            shutil.copy2(os.path.join(src, name), os.path.join(CONF_DIR, name))
    except OSError:
        ok = False
    _side_restore(st["snap"])
    try:
        os.remove(STATE)
    except OSError:
        pass

    for svc in st["services"]:
        _reload(svc)

    if quiet:
        return {"ok": ok}
    return {"ok": ok, "rolled_back": True, "tag": st["tag"],
            "message": "已还原到修改前的配置" if ok else "还原时有文件写入失败"}


def _reload(svc: str) -> None:
    for action in ("reload", "restart"):
        try:
            subprocess.run([f"/etc/init.d/{svc}", action],
                           timeout=25, check=False,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return
        except Exception:
            continue


def _prune(keep: str = "", keep_n: int = 6) -> None:
    """只留最近若干个快照，防止 /overlay 被几十个 344KB 的目录塞满。"""
    try:
        items = [os.path.join(TXN_DIR, d) for d in os.listdir(TXN_DIR)]
    except OSError:
        return
    items = [p for p in items if os.path.isdir(p) and p != keep]
    items.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    for p in items[keep_n:]:
        shutil.rmtree(p, ignore_errors=True)


def status() -> dict:
    """给客户端看的「有没有一个改动在等我确认」。"""
    st = read_state()
    if not st:
        return {"ok": True, "pending": False}
    # 过期但守护还没执行完的那几秒，要明确告诉客户端「正在还原」，
    # 而不是假装什么都没有
    if st["expired"]:
        return {"ok": True, "pending": True, "expired": True, "left": 0,
                "token": st["token"], "tag": st["tag"], "note": st["note"]}
    return {"ok": True, "pending": True, "expired": False, "token": st["token"],
            "tag": st["tag"], "note": st["note"], "left": st["left"],
            "deadline": st["deadline"]}


def boot_check() -> None:
    """agent 启动时清掉过期事务残留。

    场景：改完 LAN 地址手机没确认，用户直接拔电重启。守护进程随着重启一起没了，
    配置文件却是改过的状态——这种时候不自动回滚（重启本身是用户的决定，
    可能他正想保留这个配置），但状态文件要清掉，
    否则界面会永远停在一个点不动的「等待确认」上。
    """
    st = read_state()
    if st and not st["expired"]:
        return
    try:
        if os.path.exists(STATE):
            os.remove(STATE)
    except OSError:
        pass
