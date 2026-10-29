#!/usr/bin/env python3
"""列出重启后新建、且 tcp:443 仍未还原域名的连接明细。"""
import json
import subprocess

CLASH_SECRET = ""

def _secret() -> str:
    """口令不写进仓库：优先环境变量，其次路由器上的 Agent 配置。"""
    import os
    if CLASH_SECRET:
        return CLASH_SECRET
    env = os.environ.get("CLASH_SECRET")
    if env:
        return env
    try:
        with open("/etc/istore-agent/config.json", encoding="utf-8") as fh:
            return json.load(fh).get("clash", {}).get("secret", "")
    except OSError:
        return ""

SECRET = _secret()


def conns():
    out = subprocess.check_output(
        ["curl", "-s", "--max-time", "10", "-H", "Authorization: Bearer " + SECRET,
         "http://127.0.0.1:9090/connections"]
    )
    return json.loads(out).get("connections") or []


def main():
    print(f"时间 {subprocess.check_output(['date','+%H:%M:%S']).decode().strip()}")
    rows = []
    for c in conns():
        m = c.get("metadata") or {}
        h = (m.get("host") or "").strip()
        if h:
            continue
        if (m.get("network") or "tcp") != "tcp":
            continue
        if m.get("destinationPort") != 443:
            continue
        dip = m.get("destinationIP") or ""
        if dip.startswith(("192.168.", "127.", "10.", "198.18.")):
            continue
        sn = c.get("sniffHost") or ""
        rows.append((
            (c.get("start") or "")[11:19],
            m.get("sourceIP"), dip, c.get("rule"),
            (c.get("chains") or ["-"])[-1],
            round((c.get("download") or 0) / 1024),
            sn,
        ))
    rows.sort()
    print(f"{'开始':<9}{'源':<16}{'目标IP':<40}{'规则':<8}{'出站':<10}{'下载KB'}")
    for r in rows[:30]:
        print(f"{r[0]:<9}{str(r[1]):<16}{r[2]:<40}{str(r[3]):<8}{str(r[4]):<10}{r[5]}")
    print(f"\n合计 {len(rows)} 条")


if __name__ == "__main__":
    main()
