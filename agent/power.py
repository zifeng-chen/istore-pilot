"""电源与服务控制。

关机、重启这类操作不可撤销，且关机后路由器脱离网络，
所有远程入口全部失效，无法再远程开机（除非主板支持 WOL 且内网有设备代发）。

因此这里强制两道关：
  1. 必须带 confirm 字段，值等于动作名（防手滑、防脚本误调）
  2. 关机 / 重启 前先写入一条标记，前端下次连上能看到「上次是主动重启」
"""

from __future__ import annotations

import json
import os
import subprocess
import time

STATE_FILE = "/tmp/istore-agent-power.json"

# 允许的动作 -> (命令, 是否需要二次确认)
ACTIONS = {
    "reboot": (["/sbin/reboot"], True),
    "poweroff": (["/sbin/poweroff"], True),
    "restart_network": (["/etc/init.d/network", "restart"], False),
    "restart_dnsmasq": (["/etc/init.d/dnsmasq", "restart"], False),
    "restart_firewall": (["/etc/init.d/firewall", "restart"], False),
    "restart_uhttpd": (["/etc/init.d/uhttpd", "restart"], False),
}

LABELS = {
    "reboot": "重启路由器",
    "poweroff": "关闭路由器",
    "restart_network": "重启网络",
    "restart_dnsmasq": "重启 DNS",
    "restart_firewall": "重启防火墙",
    "restart_uhttpd": "重启管理网页",
}


def _record(action: str):
    try:
        with open(STATE_FILE, "w", encoding="utf-8") as fh:
            json.dump({"action": action, "ts": int(time.time())}, fh)
    except OSError:
        pass


def last_action() -> dict | None:
    try:
        with open(STATE_FILE, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError):
        return None


def uptime() -> int:
    try:
        with open("/proc/uptime", "r", encoding="utf-8") as fh:
            return int(float(fh.read().split()[0]))
    except (OSError, ValueError, IndexError):
        return 0


def info() -> dict:
    return {
        "actions": [
            {"id": k, "label": LABELS[k], "danger": v[1]}
            for k, v in ACTIONS.items()
        ],
        "uptime": uptime(),
        "last_action": last_action(),
        "can_wake": False,
        "warning": "关机后远程入口不可用，只能到设备跟前手动上电",
    }


def run(action: str, confirm: str = "") -> dict:
    if action not in ACTIONS:
        return {"ok": False, "error": "不支持的操作"}

    cmd, need_confirm = ACTIONS[action]
    if need_confirm and confirm != action:
        return {
            "ok": False,
            "error": f"{LABELS[action]} 需要二次确认",
            "need_confirm": action,
        }

    _record(action)
    # 关机/重启必须延迟执行，否则 HTTP 响应还没发出去机器就断了
    if action in ("reboot", "poweroff"):
        try:
            subprocess.Popen(
                ["/bin/sh", "-c", f"sleep 2; exec {' '.join(cmd)}"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
        except OSError as exc:
            return {"ok": False, "error": str(exc)}
        return {
            "ok": True,
            "action": action,
            "label": LABELS[action],
            "message": "已下发，2 秒后执行，连接会中断",
        }

    try:
        proc = subprocess.run(cmd, capture_output=True, timeout=60, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        return {"ok": False, "error": str(exc)}
    return {
        "ok": proc.returncode == 0,
        "action": action,
        "label": LABELS[action],
        "code": proc.returncode,
        "output": (proc.stdout + proc.stderr).decode("utf-8", "replace")[-600:],
    }
