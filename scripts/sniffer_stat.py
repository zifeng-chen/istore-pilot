#!/usr/bin/env python3
"""路由器上排查 Mihomo sniffer：哪些外网连接没还原出域名。

    python3 sniffer_stat.py                 # 总体还原率 + 无域名目标 + Top 域名
    python3 sniffer_stat.py split 14:32:10  # 按时间分界，对比重启前后
    python3 sniffer_stat.py tcp443          # 明细：tcp/443 还没还原的连接
    python3 sniffer_stat.py device          # 按源设备聚合
    python3 sniffer_stat.py watch 90        # 连续采样 90 秒，抓突发

以前这里是 check_sniffer.py ~ check_sniffer5.py 五个文件，八成代码一模一样、
只有统计口径不同；合成一个带子命令的脚本，改一处就全改。跑在路由器上，
依赖只有 curl 和 python3。
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from collections import Counter, defaultdict

CLASH_SECRET = ""

# 这些地址不算「外网目标」：内网、回环、fake-ip 段
LOCAL_PREFIXES = ("192.168.", "127.", "10.", "172.16.", "198.18.")


def _secret() -> str:
    """口令不写进仓库：优先环境变量，其次路由器上的 Agent 配置。"""
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


def conns(timeout: int = 10) -> list:
    try:
        out = subprocess.check_output(
            ["curl", "-s", "--max-time", str(timeout),
             "-H", "Authorization: Bearer " + SECRET,
             "http://127.0.0.1:9090/connections"],
            stderr=subprocess.DEVNULL)
        return json.loads(out).get("connections") or []
    except Exception:
        return []


def _clock() -> str:
    return subprocess.check_output(["date", "+%H:%M:%S"]).decode().strip()


def _unresolved(c: dict) -> tuple[str, str] | None:
    """没域名、且目标是外网 tcp 连接时，返回 (源 IP, 目标 IP)。"""
    m = c.get("metadata") or {}
    if (m.get("host") or "").strip():
        return None
    if (m.get("network") or "tcp") != "tcp":
        return None
    dip = m.get("destinationIP") or ""
    if not dip or dip.startswith(LOCAL_PREFIXES):
        return None
    return str(m.get("sourceIP") or ""), dip


# ---------------------------------------------------------------- 各口径

def mode_rate() -> None:
    cs = conns()
    has = no = 0
    iponly = []
    hosts = Counter()
    for c in cs:
        m = c.get("metadata") or {}
        h = (m.get("host") or "").strip()
        if h:
            has += 1
            hosts[h] += 1
            continue
        no += 1
        hit = _unresolved(c)
        if hit:
            iponly.append((hit[1], m.get("destinationPort"), c.get("rule"),
                           m.get("network")))

    print(f"连接总数 {len(cs)}   有域名 {has}   无域名 {no}")
    print(f"域名还原率 {has * 100.0 / max(len(cs), 1):.1f}%")

    print(f"\n=== 仍无域名的外网目标（{len(iponly)} 条，最多显示 25）===")
    for ip, port, rule, net in iponly[:25]:
        print(f"  {ip:<40} :{port:<6} {net or 'tcp':<4} rule={rule}")

    print("\n=== 有域名的 Top 15 ===")
    for h, n in hosts.most_common(15):
        print(f"  {h:<44} {n}")


def mode_split(since: str) -> None:
    cs = conns()
    new = [c for c in cs if (c.get("start") or "")[:19] >= since]
    old = [c for c in cs if (c.get("start") or "")[:19] < since]

    def stat(group: list, label: str) -> None:
        has = sum(1 for c in group if ((c.get("metadata") or {}).get("host") or "").strip())
        miss = Counter()
        for c in group:
            hit = _unresolved(c)
            if hit:
                port = (c.get("metadata") or {}).get("destinationPort")
                miss[f"tcp:{port}"] += 1
        tot = max(len(group), 1)
        print(f"{label}: 共 {len(group)}  有域名 {has} ({has * 100 / tot:.0f}%)  "
              f"无域名 {len(group) - has}")
        if miss:
            print("   无域名的端口分布: " + ", ".join(f"{k}×{v}" for k, v in miss.most_common(10)))

    print(f"当前时间 {_clock()}")
    print(f"分界线 {since}（之前=重启前的旧连接）\n")
    stat(new, "重启后新建")
    stat(old, "重启前遗留")


def mode_tcp443() -> None:
    print(f"时间 {_clock()}")
    rows = []
    for c in conns():
        m = c.get("metadata") or {}
        if m.get("destinationPort") != 443:
            continue
        hit = _unresolved(c)
        if not hit:
            continue
        rows.append((
            (c.get("start") or "")[11:19], hit[0], hit[1], c.get("rule"),
            (c.get("chains") or ["-"])[-1],
            round((c.get("download") or 0) / 1024),
        ))
    rows.sort()
    print(f"{'开始':<9}{'源':<16}{'目标IP':<40}{'规则':<8}{'出站':<10}{'下载KB'}")
    for r in rows[:30]:
        print(f"{r[0]:<9}{r[1]:<16}{r[2]:<40}{str(r[3]):<8}{str(r[4]):<10}{r[5]}")
    print(f"\n合计 {len(rows)} 条")


def mode_device() -> None:
    print(f"时间 {_clock()}")
    by_src = defaultdict(list)
    dst = Counter()
    for c in conns():
        hit = _unresolved(c)
        if not hit or (c.get("metadata") or {}).get("destinationPort") != 443:
            continue
        by_src[hit[0]].append((hit[1], round((c.get("download") or 0) / 1024)))
        dst[hit[1]] += 1

    print(f"\n{'源设备':<18}{'条数':>5}   目标 IP（下载 KB）")
    for src, items in sorted(by_src.items(), key=lambda kv: -len(kv[1])):
        uniq = Counter(i[0] for i in items)
        sample = ", ".join(f"{ip}×{n}" for ip, n in uniq.most_common(4))
        tot = sum(i[1] for i in items)
        print(f"{src:<18}{len(items):>5}   共{tot}KB  {sample}")

    print("\n=== 目标 IP 汇总 ===")
    for ip, n in dst.most_common(10):
        print(f"  {ip:<40} {n}")


def mode_watch(duration: int) -> None:
    pairs = Counter()
    samples = 0
    peaks = []
    end = time.time() + duration
    while time.time() < end:
        cs = conns(5)
        hit = 0
        for c in cs:
            found = _unresolved(c)
            if found and (c.get("metadata") or {}).get("destinationPort") == 443:
                pairs[found] += 1
                hit += 1
        peaks.append((len(cs), hit))
        samples += 1
        time.sleep(2)

    print(f"采样 {samples} 轮 / {duration} 秒")
    print("轮次抽样 (总连接, tcp443 无域名):",
          [p for p in peaks if p[1] > 0][:12] or "全程为 0")
    print(f"\n=== 源 → 目标 组合，共 {len(pairs)} 组 ===")
    for (src, dip), n in pairs.most_common(25):
        print(f"  {src:<18} -> {dip:<42} {n} 轮")


def main() -> int:
    cmd = sys.argv[1] if len(sys.argv) > 1 else "rate"
    if cmd == "rate":
        mode_rate()
    elif cmd == "split":
        if len(sys.argv) < 3:
            print("用法: sniffer_stat.py split HH:MM:SS")
            return 2
        mode_split(sys.argv[2])
    elif cmd == "tcp443":
        mode_tcp443()
    elif cmd == "device":
        mode_device()
    elif cmd == "watch":
        mode_watch(int(sys.argv[2]) if len(sys.argv) > 2 else 90)
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
