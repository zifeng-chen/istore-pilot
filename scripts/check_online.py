#!/usr/bin/env python3
"""交叉核对：把接口给的 online 跟内核邻居表逐台对齐，找漏报/误报。"""

from __future__ import annotations

import json
import os
import re
import urllib.request

import paramiko

BASE = "http://192.168.100.1:8443"
PASSWORD = os.environ.get("ROUTER_PW", "")   # 口令从环境变量读，不写进仓库
NEIGH_RE = re.compile(
    r"^(?P<ip>\S+)\s+(?:lladdr\s+(?P<mac>[0-9a-f:]{17})\s+)?"
    r"(?:ref\s+\d+\s+)?(?:used\s+\d+/\d+/\d+\s*probes\s+\d+\s+)?(?P<state>[A-Z]+)\s*$"
)


def req(path: str, token: str | None = None, body: dict | None = None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(BASE + path, data=data, headers=headers,
                               method="POST" if body is not None else "GET")
    with urllib.request.urlopen(r, timeout=40) as resp:
        return json.loads(resp.read().decode())


def neigh() -> dict[str, str]:
    cli = paramiko.SSHClient()
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    cli.connect("192.168.100.1", 22, "root", PASSWORD, timeout=15)
    _, out, _ = cli.exec_command("ip -s neigh show dev br-lan", timeout=20)
    text = out.read().decode()
    cli.close()
    out_map: dict[str, str] = {}
    for line in text.splitlines():
        m = NEIGH_RE.match(line.strip())
        if not m or not m.group("mac"):
            continue
        out_map[m.group("mac").lower()] = m.group("state")
    return out_map


def main() -> int:
    token = req("/api/v1/login", body={"password": PASSWORD})["token"]
    devs = req("/api/v1/devices", token)["devices"]
    nb = neigh()

    alive = {"REACHABLE", "DELAY", "PROBE"}
    dead = {"INCOMPLETE", "FAILED"}

    miss, false_pos = [], []
    for d in devs:
        st = nb.get(d["mac"])
        if st in alive and not d["online"]:
            miss.append((d, st))
        elif st in dead and d["online"]:
            false_pos.append((d, st))

    print(f"设备 {len(devs)} 台，邻居表 {len(nb)} 条")
    print(f"[漏报] ARP 明确在线但接口说离线: {len(miss)}")
    for d, st in miss:
        print(f"   {d['mac']} {d['ip'] or '-':16} {st:10} {d['state']:10} {d['label']}")
    print(f"[误报] ARP 解析失败但接口说在线: {len(false_pos)}")
    for d, st in false_pos:
        print(f"   {d['mac']} {d['ip'] or '-':16} {st:10} {d['state']:10} {d['label']}")

    # 列出接口说离线、邻居表是 STALE 的（这些是"历史上见过、现在叫不应"）
    stale_off = [(d, nb[d["mac"]]) for d in devs
                 if not d["online"] and nb.get(d["mac"]) == "STALE"]
    print(f"[参考] STALE 且判离线: {len(stale_off)}")
    for d, _ in stale_off:
        print(f"   {d['mac']} {d['ip'] or '-':16} last_seen={d['last_seen']}  {d['label']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
