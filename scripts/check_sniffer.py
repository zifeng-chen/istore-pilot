#!/usr/bin/env python3
"""检查 Mihomo sniffer 效果：还有多少外网连接拿不到域名。"""
import json
import subprocess
import sys
from collections import Counter

SECRET = "5PLiToz9"


def conns():
    out = subprocess.check_output(
        ["curl", "-s", "--max-time", "10", "-H", "Authorization: Bearer " + SECRET,
         "http://127.0.0.1:9090/connections"]
    )
    return json.loads(out).get("connections") or []


def main():
    cs = conns()
    has, no = 0, 0
    iponly = []
    hosts = Counter()
    for c in cs:
        m = c.get("metadata") or {}
        h = (m.get("host") or "").strip()
        dip = m.get("destinationIP") or ""
        dport = m.get("destinationPort")
        if h:
            has += 1
            hosts[h] += 1
            continue
        no += 1
        # 只看真正的外网目标
        if not dip or dip.startswith("192.168.") or dip.startswith("127.") \
                or dip.startswith("10.") or dip.startswith("198.18."):
            continue
        iponly.append((dip, dport, c.get("rule"), m.get("network"),
                       c.get("chains") or []))

    print(f"连接总数 {len(cs)}   有域名 {has}   无域名 {no}")
    rate = has * 100.0 / max(len(cs), 1)
    print(f"域名还原率 {rate:.1f}%")

    print(f"\n=== 仍无域名的外网目标（{len(iponly)} 条，最多显示 25）===")
    for ip, port, rule, net, chains in iponly[:25]:
        print(f"  {ip:<40} :{port:<6} {net or 'tcp':<4} rule={rule}")

    print("\n=== 有域名的 Top 15 ===")
    for h, n in hosts.most_common(15):
        print(f"  {h:<44} {n}")


if __name__ == "__main__":
    main()
