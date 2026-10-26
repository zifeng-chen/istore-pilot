#!/usr/bin/env python3
"""在路由器上跑：看 Clash 连接里的 host 分布，以及 apps._match 的归类结果。"""
import sys
sys.path.insert(0, "/usr/lib/istore-agent")

from agent import clash, apps  # noqa: E402

data = clash.connections()
if data.get("error"):
    print("ERROR:", data["error"])
    raise SystemExit(1)

conns = data.get("connections") or []
print(f"连接数 {len(conns)}")

rows = []
for c in conns:
    host = str(c.get("host") or "")
    fake = apps._is_fake_ip(host)
    name, cat = apps._match("" if fake else host)
    rows.append((-float(c.get("download") or 0), host, name, cat,
                 c.get("source"), c.get("destinationIP"), c.get("network"),
                 float(c.get("download") or 0), float(c.get("upload") or 0)))

rows.sort()
print(f"{'host':<46}{'归类':<14}{'cat':<8}{'source':<16}{'destIP':<18}{'net':<5}{'down':>10}")
for r in rows[:40]:
    print(f"{r[1][:44]:<46}{r[2][:12]:<14}{r[3][:6]:<8}{str(r[4])[:15]:<16}"
          f"{str(r[5])[:17]:<18}{str(r[6]):<5}{r[7] / 1024:>9.0f}K")

print("\n=== 按归类汇总 ===")
agg = {}
for r in rows:
    a = agg.setdefault(r[2], [0.0, 0])
    a[0] += r[7]
    a[1] += 1
for name, (b, n) in sorted(agg.items(), key=lambda kv: -kv[1][0])[:20]:
    print(f"  {name[:18]:<20}{b / 1048576:>9.2f} MB  {n:>4} 条")
