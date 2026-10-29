#!/usr/bin/env python3
"""只看 sniffer 生效之后新建的连接，判断真实还原率。"""
import json
import subprocess
import sys
from collections import Counter

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
    since = sys.argv[1] if len(sys.argv) > 1 else ""
    cs = conns()

    new, old = [], []
    for c in cs:
        st = (c.get("start") or "")[:19]
        (new if st >= since else old).append(c)

    def stat(group, label):
        has = no = 0
        miss = Counter()
        for c in group:
            m = c.get("metadata") or {}
            h = (m.get("host") or "").strip()
            if h:
                has += 1
                continue
            no += 1
            dip = m.get("destinationIP") or ""
            port = m.get("destinationPort")
            net = m.get("network") or "tcp"
            if dip and not (dip.startswith(("192.168.", "127.", "10.", "198.18."))):
                miss[f"{net}:{port}"] += 1
        tot = max(has + no, 1)
        print(f"{label}: 共 {len(group)}  有域名 {has} ({has*100/tot:.0f}%)  无域名 {no}")
        if miss:
            print("   无域名的端口分布: " + ", ".join(f"{k}×{v}" for k, v in miss.most_common(10)))

    print(f"当前时间 {subprocess.check_output(['date','+%H:%M:%S']).decode().strip()}")
    if since:
        print(f"分界线 {since}（之前=重启前的旧连接）\n")
        stat(new, "重启后新建")
        stat(old, "重启前遗留")


if __name__ == "__main__":
    main()
