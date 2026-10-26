#!/usr/bin/env python3
"""核对设备接口的真实返回，避免界面上的字段名对不上。"""

from __future__ import annotations

import json
import os
import time
import urllib.request

BASE = "http://192.168.100.1:8443"
PASSWORD = os.environ.get("ROUTER_PW", "")   # 口令从环境变量读，不写进仓库


def req(path: str, token: str | None = None, body: dict | None = None):
    url = BASE + path
    data = None
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if body is not None:
        data = json.dumps(body).encode()
    r = urllib.request.Request(url, data=data, headers=headers,
                               method="POST" if body is not None else "GET")
    with urllib.request.urlopen(r, timeout=30) as resp:
        return json.loads(resp.read().decode())


def main() -> int:
    token = req("/api/v1/login", body={"password": PASSWORD})["token"]
    print("登录 OK")

    for i in range(2):
        d = req("/api/v1/devices", token)
        s = d["summary"]
        print(f"\n[devices #{i + 1}] 共 {s['total']} 台，在线 {s['online']}，"
              f"禁网 {s['blocked']}，静态 {s['static']}，"
              f"当前 {s['rx_bps'] / 1024:.1f}/{s['tx_bps'] / 1024:.1f} KB/s")
        if i == 0:
            for dev in d["devices"][:12]:
                net = dev["net"]
                mark = "●" if dev["online"] else "○"
                print(f"  {mark} {dev['ip']:<15} {dev['mac']}  "
                      f"{dev['vendor'] or '—':<12} {(dev['alias'] or dev['hostname'] or '—'):<16} "
                      f"↓{net['rx_bps'] / 1024:6.1f} ↑{net['tx_bps'] / 1024:6.1f} KB/s"
                      f"{'  [禁网]' if dev['blocked'] else ''}{'  [静态]' if dev['static'] else ''}")
        else:
            tot = sum(x["net"]["rx_bps"] + x["net"]["tx_bps"] for x in d["devices"])
            print(f"  所有设备速率合计 {tot / 1024:.1f} KB/s（第二轮，说明采样在动）")
        time.sleep(6)

    # 详情：挑一台在线的
    online = [x for x in d["devices"] if x["online"] and x["ip"]]
    if online:
        pick = max(online, key=lambda x: x["net"]["rx_bps"] + x["net"]["tx_bps"])
        det = req(f"/api/v1/devices/detail?mac={pick['mac']}", token)
        print(f"\n[detail] {det['device']['ip']}  {det['device']['mac']}  "
              f"厂商={det['device']['vendor'] or '—'}")
        print(f"  主机名={det['device']['hostname'] or '—'}  备注={det['device']['alias'] or '—'}")
        print(f"  状态={det['device']['state']}  在线={det['device']['online']}  "
              f"最后活跃={det['device']['last_seen']}")
        print(f"  租约剩余={det['device']['dhcp']['lease_left']}  静态={det['device']['dhcp']['reserved']}")
        print(f"  连接数={det['conns']}  累计 ↓{det['device']['net']['rx_total'] / 1048576:.1f} "
              f"↑{det['device']['net']['tx_total'] / 1048576:.1f} MB")
        print("  对端 Top:")
        for p in det["peers"][:6]:
            arrow = "↑" if p["outbound"] else "↓"
            print(f"    {arrow} {p['ip']:<40} :{p['port']:<6} {p['proto']:<4} "
                  f"{p['service'] or '—':<14} {p['conns']} 条  "
                  f"{(p['up'] + p['down']) / 1024:.1f} KB")
        print(f"  能力={det['capabilities']}")

    # 只读验证：改名（可逆，先改再改回）
    if online:
        mac = online[0]["mac"]
        r1 = req("/api/v1/devices/rename", token, {"mac": mac, "alias": "接口自测"})
        det2 = req(f"/api/v1/devices/detail?mac={mac}", token)
        print(f"\n[rename] 写入={r1}  回读备注={det2['device']['alias']!r}")
        req("/api/v1/devices/rename", token, {"mac": mac, "alias": ""})
        det3 = req(f"/api/v1/devices/detail?mac={mac}", token)
        print(f"[rename] 清空后={det3['device']['alias']!r}")

    # 厂商识别命中率
    hit = sum(1 for x in d["devices"] if x["vendor"])
    print(f"\n[vendor] 识别出 {hit}/{len(d['devices'])} 台")
    miss = [x["mac"] for x in d["devices"] if not x["vendor"]]
    print("  未识别:", " ".join(miss[:20]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
