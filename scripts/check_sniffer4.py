#!/usr/bin/env python3
"""按源 IP 聚合「无域名的 tcp:443」连接，定位是谁在连。"""
import json
import subprocess
from collections import Counter, defaultdict

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
    by_src = defaultdict(list)
    dst = Counter()
    for c in conns():
        m = c.get("metadata") or {}
        if (m.get("host") or "").strip():
            continue
        if (m.get("network") or "tcp") != "tcp":
            continue
        if m.get("destinationPort") != 443:
            continue
        dip = m.get("destinationIP") or ""
        if dip.startswith(("192.168.", "127.", "10.", "198.18.")):
            continue
        by_src[m.get("sourceIP")].append(
            (dip, round((c.get("download") or 0) / 1024), round((c.get("upload") or 0) / 1024))
        )
        dst[dip] += 1

    print(f"\n{'源设备':<18}{'条数':>5}   目标 IP（下载 KB）")
    for src, items in sorted(by_src.items(), key=lambda kv: -len(kv[1])):
        uniq = Counter(i[0] for i in items)
        tot = sum(i[1] for i in items)
        sample = ", ".join(f"{ip}×{n}" for ip, n in uniq.most_common(4))
        print(f"{str(src):<18}{len(items):>5}   共{tot}KB  {sample}")

    print("\n=== 目标 IP 汇总 ===")
    for ip, n in dst.most_common(10):
        print(f"  {ip:<40} {n}")


if __name__ == "__main__":
    main()
