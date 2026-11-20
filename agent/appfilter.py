"""应用过滤（OpenAppFilter / OAF）：状态读取、总开关、特征库升级。

为什么要接这个
--------------
「应用流量」现在只能看**经过 Clash** 的连接（见 apps.py 顶部说明），
直连流量、没走代理的设备全是盲区。OAF 是内核态 DPI，站在转发路径上，
跟走不走代理无关 —— 补的正是这块。

为什么只做「上传特征库」而不内置
--------------------------------
OAF 的特征库是会员私有授权：禁止分发、禁止公开、禁止集成到固件售卖。
所以二进制绝对不能进仓库或安装包，只提供用户自己上传的通道。

升级流程照搬插件自己的 LuCI 实现（/usr/lib/lua/luci/model/cbi/appfilter/feature.lua）
-------------------------------------------------------------------------
上传的是 tar.gz，里面是 feature.cfg（可选 app_icons/）：
    解包 → 校验首行 #version、次行 #format → cp 到 /etc/appfilter/feature.cfg
    → 同步图标 → killall -SIGUSR1 oafd（热重载，不用重启守护进程）
这里额外做两件插件没做的事：覆盖前把旧库备份到 feature.cfg.bak.<时间戳>
（只留两份，路由 flash 很小），以及解包时挡掉绝对路径/.. 的成员。
"""

from __future__ import annotations

import io
import os
import re
import shutil
import subprocess
import tarfile
import time

FEATURE = "/etc/appfilter/feature.cfg"
ICON_DIR = "/www/luci-static/resources/app_icons"
OAFD = "/usr/bin/oafd"
INIT = "/etc/init.d/appfilter"
UCI = "/sbin/uci"
MAX_BYTES = 12 * 1024 * 1024        # 特征库实际 2 MB 左右，留足余量
KEEP_BACKUPS = 2


def _sh(cmd: str, timeout: int = 15) -> str:
    """跑一条命令，失败返回空串（调用方用返回值判断，不抛异常）。"""
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, timeout=timeout)
        return (r.stdout or b"").decode("utf-8", "replace").strip()
    except (subprocess.TimeoutExpired, OSError):
        return ""


def _uci_get(key: str) -> str:
    return _sh("%s -q get %s" % (UCI, key))


def _installed() -> bool:
    return os.path.exists(OAFD)


def _running() -> bool:
    return bool(_sh("pidof oafd"))


def _feature_meta(path: str) -> dict:
    """从特征库首两行取版本与格式，再数一遍规则条数。"""
    meta = {"version": "", "format": "", "rules": 0}
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            first = f.readline().strip()
            second = f.readline().strip()
            rules = 0
            for line in f:
                s = line.strip()
                if s and not s.startswith("#"):
                    rules += 1
        meta["rules"] = rules
    except OSError:
        return meta
    m = re.search(r"#version\s+(\S+)", first)
    if m:
        meta["version"] = m.group(1)
    m = re.search(r"#format\s+(\S+)", second)
    if m:
        meta["format"] = m.group(1)
    return meta


def _lib_info() -> dict:
    from . import appnames          # 局部导入：没装插件时也不影响本模块
    try:
        return appnames.info()
    except Exception:
        return {"available": False, "patterns": 0, "apps": 0}


def status() -> dict:
    """给客户端的一份快照。没装也要能正常返回，客户端据此显示「未安装」。"""
    if not _installed():
        return {"ok": True, "installed": False}

    meta = _feature_meta(FEATURE)
    try:
        st = os.stat(FEATURE)
        size, mtime = st.st_size, int(st.st_mtime)
    except OSError:
        size, mtime = 0, 0

    disable_hnat = _uci_get("appfilter.global.disable_hnat") == "1"
    return {
        "ok": True,
        "installed": True,
        "running": _running(),
        "enabled": _uci_get("appfilter.global.enable") == "1",
        "work_mode": int(_uci_get("appfilter.global.work_mode") or 0),
        "record": _uci_get("appfilter.global.record_enable") == "1",
        "disable_hnat": disable_hnat,
        "feature": {
            "version": meta["version"],
            "format": meta["format"],
            "rules": meta["rules"],
            "size": size,
            "updated": mtime,
        },
        # 特征库同时被应用流量用来做识别（appnames.py），这里顺带报一下覆盖量
        "identify": _lib_info(),
        # 开过滤会关硬件加速，千兆可能掉到几百兆 —— 客户端必须把这条提示出去
        "note": "开启后关闭硬件加速（HNAT），大流量场景速率会下降",
    }


def set_enable(on: bool) -> dict:
    if not _installed():
        return {"ok": False, "error": "路由器未安装应用过滤插件"}
    val = "1" if on else "0"
    _sh("%s set appfilter.global.enable=%s" % (UCI, val))
    _sh("%s commit appfilter" % UCI)
    _sh("%s restart" % INIT, timeout=30)
    time.sleep(1)
    st = status()
    if st.get("enabled") != on:
        return {"ok": False, "error": "切换未生效，请检查插件状态"}
    return {"ok": True, "enabled": st["enabled"], "running": st["running"]}


def _rotate_backup() -> str | None:
    """覆盖前备份，只留最近 KEEP_BACKUPS 份。"""
    if not os.path.exists(FEATURE):
        return None
    dst = "%s.bak.%s" % (FEATURE, time.strftime("%Y%m%d-%H%M%S"))
    try:
        shutil.copy2(FEATURE, dst)
    except OSError:
        return None
    olds = sorted(
        [p for p in os.listdir(os.path.dirname(FEATURE)) if p.startswith("feature.cfg.bak.")]
    )
    for name in olds[:-KEEP_BACKUPS]:
        try:
            os.remove(os.path.join(os.path.dirname(FEATURE), name))
        except OSError:
            pass
    return dst


def upgrade(data: bytes, filename: str = "") -> dict:
    """上传特征库（tar.gz）。校验、备份、替换、热重载，最后回读确认版本变化。"""
    if not _installed():
        return {"ok": False, "error": "路由器未安装应用过滤插件"}
    if not data:
        return {"ok": False, "error": "文件为空"}
    if len(data) > MAX_BYTES:
        return {"ok": False, "error": "文件过大（上限 %d MB）" % (MAX_BYTES // 1024 // 1024)}
    if data[:2] != b"\x1f\x8b":
        return {"ok": False, "error": "不是有效的特征库文件（应为 tar.gz）"}

    before = _feature_meta(FEATURE)

    try:
        tf = tarfile.open(fileobj=io.BytesIO(data), mode="r:gz")
    except (tarfile.TarError, OSError):
        return {"ok": False, "error": "压缩包损坏或格式不对"}

    members = []
    with tf:
        for m in tf.getmembers():
            name = m.name.lstrip("./")
            if not m.isfile():
                continue
            if name.startswith("/") or ".." in name.split("/"):
                continue                      # 挡掉越界路径
            if not (name == "feature.cfg" or name.startswith("app_icons/")):
                continue                      # 只认这两个，别的忽略
            members.append((name, m))
        if not any(n == "feature.cfg" for n, _ in members):
            return {"ok": False, "error": "压缩包里没有 feature.cfg"}

        tmpdir = "/tmp/oaf_up_%d" % int(time.time())
        os.makedirs(tmpdir, exist_ok=True)
        try:
            for name, m in members:
                f = tf.extractfile(m)
                if not f:
                    continue
                dst = os.path.join(tmpdir, name)
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                with open(dst, "wb") as out:
                    out.write(f.read())

            cfg = os.path.join(tmpdir, "feature.cfg")
            meta = _feature_meta(cfg)
            if not meta["version"]:
                return {"ok": False, "error": "特征库缺少 #version 行"}
            want = _uci_get("appfilter.feature.format") or "v3.0"
            if meta["format"] and meta["format"] != want:
                return {"ok": False,
                        "error": "格式不匹配：包里是 %s，当前插件是 %s" % (meta["format"], want)}
            if meta["rules"] < 100:
                return {"ok": False, "error": "规则数只有 %d 条，像是残缺文件" % meta["rules"]}

            backup = _rotate_backup()
            shutil.copyfile(cfg, FEATURE)
            try:
                os.chmod(FEATURE, 0o666)
            except OSError:
                pass

            icons = os.path.join(tmpdir, "app_icons")
            icon_count = 0
            if os.path.isdir(icons):
                try:
                    if os.path.isdir(ICON_DIR):
                        shutil.rmtree(ICON_DIR, ignore_errors=True)
                    shutil.copytree(icons, ICON_DIR)
                    icon_count = len(os.listdir(ICON_DIR))
                except OSError:
                    icon_count = 0
            if _running():
                _sh("killall -SIGUSR1 oafd")      # 热重载，等同插件自己的做法
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)

    after = _feature_meta(FEATURE)
    if after["version"] != meta["version"]:
        return {"ok": False, "error": "写入后版本回读不一致，可能权限不足"}

    return {
        "ok": True,
        "before": before["version"],
        "after": after["version"],
        "rules": after["rules"],
        "icons": icon_count,
        "backup": os.path.basename(backup) if backup else "",
        "restarted": _running(),
        "filename": filename,
    }
