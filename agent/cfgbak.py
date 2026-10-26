"""配置备份与恢复。

备份什么：整个 `/etc/config`（58 个文件，344 KB，压完约 60 KB）。
不备份 `/etc/istore-agent/config.json`——那是 Agent 自己的口令文件，
跟着备份走会让「恢复旧配置」变成「把口令泄露到旧备份里」。

为什么要自己写而不是用 `sysupgrade -b`：`sysupgrade -b` 打的是
整套 /etc（包含密码、host key、证书），而且恢复必须重启才生效。
这里要的是「改坏了能马上退回去」，所以只收配置、恢复后立刻 reload。

恢复是危险动作，走的是 `netapply` 的事务：先快照当前的，再铺备份的，
客户端 60 秒内不确认就自动退回恢复之前的状态。
"""
from __future__ import annotations

import json
import os
import re
import shutil
import tarfile
import time

from . import netapply, sysinfo

DATA_DIR = "/etc/istore-agent/data"
BAK_DIR = os.path.join(DATA_DIR, "configs")
CONF_DIR = "/etc/config"
MAX_AUTO = 10          # 自动备份（恢复前那一份）最多留这么多份
MAX_TOTAL_BYTES = 48 << 20   # 备份目录整体上限

# 恢复配置会波及的服务。缺哪个就跳过，netapply 里已经做了容错
RESTORE_SERVICES = ("network", "firewall", "dnsmasq", "adguardhome", "openclash")


def _ts() -> int:
    return int(time.time())


def _stamp() -> str:
    return time.strftime("%Y%m%d-%H%M%S")


def _slug(text: str, fallback: str = "backup") -> str:
    s = re.sub(r"[^0-9A-Za-z\u4e00-\u9fa5_-]+", "", text or "")[:24]
    return s or fallback


def _meta_path(bid: str) -> str:
    return os.path.join(BAK_DIR, bid + ".json")


def _archive_path(bid: str) -> str:
    return os.path.join(BAK_DIR, bid + ".tar.gz")


def _firmware() -> str:
    """固件标识。变量名是 DISTRIB_DESCRIPTION，不是 DIST_DESCRIPTION —— 少个 RIB 就永远读不到。"""
    try:
        with open("/etc/openwrt_release", "r", encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                if line.startswith("DISTRIB_DESCRIPTION"):
                    return line.split("=", 1)[1].strip().strip("'\"")
    except OSError:
        pass
    return ""


# ---------------------------------------------------------------- 读

def list_backups() -> dict:
    os.makedirs(BAK_DIR, exist_ok=True)
    items: list[dict] = []
    try:
        names = os.listdir(BAK_DIR)
    except OSError:
        names = []
    for name in names:
        if not name.endswith(".tar.gz"):
            continue
        bid = name[: -len(".tar.gz")]
        arc = _archive_path(bid)
        if not os.path.isfile(arc):
            continue
        meta = {}
        try:
            with open(_meta_path(bid), "r", encoding="utf-8") as fh:
                meta = json.load(fh)
        except (OSError, ValueError):
            meta = {}
        try:
            size = os.path.getsize(arc)
        except OSError:
            continue
        items.append({
            "id": bid,
            "name": meta.get("name") or bid,
            "note": meta.get("note", ""),
            "ts": meta.get("ts") or int(os.path.getmtime(arc)),
            "size": size,
            "files": meta.get("files", 0),
            "source": meta.get("source", "manual"),
            "firmware": meta.get("firmware", ""),
            "auto": meta.get("source") == "auto",
        })
    items.sort(key=lambda x: x["ts"], reverse=True)
    total = sum(i["size"] for i in items)
    return {
        "ok": True,
        "items": items,
        "count": len(items),
        "bytes": total,
        "dir": BAK_DIR,
        "max_auto": MAX_AUTO,
        "note": "备份只含 /etc/config，不含 Agent 口令与证书；恢复后立即生效，不用重启",
    }


# ---------------------------------------------------------------- 写

def create(name: str = "", note: str = "", source: str = "manual") -> dict:
    os.makedirs(BAK_DIR, exist_ok=True)
    if not os.path.isdir(CONF_DIR):
        return {"ok": False, "error": "找不到 /etc/config"}

    bid = f"{_stamp()}-{_slug(name, source)}"
    arc = _archive_path(bid)
    files = 0
    try:
        with tarfile.open(arc, "w:gz") as tf:
            for entry in sorted(os.listdir(CONF_DIR)):
                full = os.path.join(CONF_DIR, entry)
                if os.path.isfile(full):
                    tf.add(full, arcname="config/" + entry)
                    files += 1
    except (OSError, tarfile.TarError) as exc:
        try:
            os.remove(arc)
        except OSError:
            pass
        return {"ok": False, "error": f"打包失败：{exc}"}

    if files == 0:
        try:
            os.remove(arc)
        except OSError:
            pass
        return {"ok": False, "error": "配置目录是空的，没有可备份的内容"}

    meta = {
        "id": bid, "name": name or f"备份 {time.strftime('%m-%d %H:%M')}",
        "note": note, "ts": _ts(), "files": files,
        "source": source, "firmware": _firmware(),
    }
    try:
        with open(_meta_path(bid), "w", encoding="utf-8") as fh:
            json.dump(meta, fh, ensure_ascii=False, indent=1)
    except OSError:
        pass

    _apply_quota()
    size = os.path.getsize(arc)
    return {"ok": True, "id": bid, "name": meta["name"], "files": files, "size": size,
            "message": f"已备份 {files} 个配置文件"}


def delete(bid: str) -> dict:
    if not re.fullmatch(r"[0-9A-Za-z\u4e00-\u9fa5_-]+", bid or ""):
        return {"ok": False, "error": "备份编号不合法"}
    arc = _archive_path(bid)
    if not os.path.isfile(arc):
        return {"ok": False, "error": "备份不存在"}
    try:
        os.remove(arc)
    except OSError as exc:
        return {"ok": False, "error": f"删除失败：{exc}"}
    try:
        os.remove(_meta_path(bid))
    except OSError:
        pass
    return {"ok": True, "message": "已删除"}


def restore(bid: str, allow_lan_change: bool = False, client_ip: str = "") -> dict:
    """把备份铺回去。全程在事务里，客户端不确认就自动退回。"""
    if not re.fullmatch(r"[0-9A-Za-z\u4e00-\u9fa5_-]+", bid or ""):
        return {"ok": False, "error": "备份编号不合法"}
    arc = _archive_path(bid)
    if not os.path.isfile(arc):
        return {"ok": False, "error": "备份不存在"}

    cur_lan = _uci_get("network.lan.ipaddr")
    bak_lan = _lan_in_archive(arc)
    if bak_lan and cur_lan and bak_lan != cur_lan and not allow_lan_change:
        # 这条不是洁癖：恢复会改掉 LAN 地址，手机拿的还是旧地址，连不回来就是死局
        return {"ok": False, "lan_change": True, "from": cur_lan, "to": bak_lan,
                "error": f"这份备份里的管理地址是 {bak_lan}，和现在的 {cur_lan} 不同。"
                         "恢复后 App 会立刻失联，需要手动把 App 的服务器地址改成新地址。"}

    # 恢复前另存一份，防止「恢复错了备份」变成双向丢失
    saved = create(name="恢复前自动备份", note=f"恢复到 {bid} 之前", source="auto")

    txn = netapply.begin("config-restore", services=RESTORE_SERVICES,
                         note=f"恢复配置 {bid}")
    if not txn.get("ok"):
        return txn
    token = txn["token"]

    try:
        with tarfile.open(arc, "r:gz") as tf:
            members = [m for m in tf.getmembers()
                       if m.isfile() and m.name.startswith("config/")
                       and "/" not in m.name[len("config/"):]]
            if not members:
                raise RuntimeError("备份包里没有配置文件")
            for m in members:
                m.name = m.name[len("config/"):]
                tf.extract(m, path=CONF_DIR, set_attrs=True)
    except Exception as exc:
        netapply.rollback(token, quiet=True)
        return {"ok": False, "error": f"解包失败（{exc}），已还原到恢复前的状态"}

    for svc in ("network", "firewall"):
        sysinfo._run(["/etc/init.d/" + svc, "reload"], timeout=20)
    sysinfo._run(["/etc/init.d/dnsmasq", "restart"], timeout=20)

    return {
        "ok": True,
        "token": token,
        "wait": txn["wait"],
        "deadline": txn["deadline"],
        "files": len(members),
        "safety_backup": saved.get("id", ""),
        "message": f"已恢复 {len(members)} 个配置文件",
        "detail": f"如果 {txn['wait']} 秒内没有回到 App 点确认，会自动退回恢复前的状态。",
    }


def _uci_get(key: str) -> str:
    out = sysinfo._run(["uci", "-q", "get", key], timeout=4).strip()
    return "" if out.startswith("uci:") else out


def _lan_in_archive(arc: str) -> str:
    """从备份包里读出当时的 LAN 地址，用来判断恢复后会不会失联。"""
    try:
        with tarfile.open(arc, "r:gz") as tf:
            try:
                fh = tf.extractfile("config/network")
            except KeyError:
                fh = None
            if fh is None:
                return ""
            text = fh.read().decode("utf-8", "replace")
    except (OSError, tarfile.TarError):
        return ""
    inside = False
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("config interface"):
            inside = "'lan'" in s or '"lan"' in s or s.endswith("lan")
            continue
        if inside and s.startswith("option ipaddr"):
            return s.split()[-1].strip("'\"")
    return ""


def _apply_quota() -> None:
    """自动备份按份数裁，整体按体积裁——/overlay 只有 100 MB 出头。"""
    data = list_backups()
    items = data["items"]
    autos = [i for i in items if i["auto"]]
    for old in autos[MAX_AUTO:]:
        _remove_files(old["id"])

    total = sum(i["size"] for i in list_backups()["items"])
    if total <= MAX_TOTAL_BYTES:
        return
    # 超体积：从最老的自动备份开始删，手工备份最后才动
    for i in sorted(list_backups()["items"], key=lambda x: (not x["auto"], x["ts"])):
        if total <= MAX_TOTAL_BYTES:
            break
        _remove_files(i["id"])
        total -= i["size"]


def _remove_files(bid: str) -> None:
    for p in (_archive_path(bid), _meta_path(bid)):
        try:
            os.remove(p)
        except OSError:
            pass
