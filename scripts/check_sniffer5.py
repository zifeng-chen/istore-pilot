#!/usr/bin/env python3
"""90 秒连续采样，抓齐「无域名 tcp:443」的突发连接，按 源→目标 累计。"""
import json
import subprocess
import sys
import time
from collections import Counter

SECRET = "5PLiToz9"
DURATION = int(sys.argv[1]) if len(sys.argv) > 1 else 90


def conns():
    try:
        out = subprocess.check_output(
            ["curl", "-s", "--max-time", "5", "-H", "Authorization: Bearer " + SECRET,
             "http://127.0.0.1:9090/connections"], stderr=subprocess.DEVNULL)
        return json.loads(out).get("connections") or []
    except Exception:
        return []


def main():
    pairs = Counter()
    peaks = []
    samples = 0
    end = time.time() + DURATION
    while time.time() < end:
        cs = conns()
        hit = 0
        for c in cs:
            m = c.get("metadata") or {}
            if (m.get("host") or "").strip():
                continue
            if (m.get("network") or "tcp") != "tcp":
                continue
            if m.get("destinationPort") != 443:
                continue
            dip = m.get("destinationIP") or ""
            pairs[(m.get("sourceIP"), dip)] += 1
            hit += 1
        peaks.append((round(time.time()) % 10000, len(cs), hit))
        samples += 1
        time.sleep(2)

    print(f"采样 {samples} 轮 / {DURATION} 秒")
    print("轮次抽样 (总连接, tcp443无域名):", [(p[1], p[2]) for p in peaks if p[2] > 0][:12] or "全程为 0")
    print(f"\n=== 源 → 目标 组合，共 {len(pairs)} 组 ===")
    for (src, dip), n in pairs.most_common(25):
        print(f"  {str(src):<18} -> {dip:<42} {n} 轮")


if __name__ == "__main__":
    main()
