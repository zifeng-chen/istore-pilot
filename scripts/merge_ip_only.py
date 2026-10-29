#!/usr/bin/env python3
"""把某台设备账本里的「IP 直连」并到指定应用（一次性修账，不自动执行）。

为什么需要它
------------
应用流量的账本只增不改：在「IP → 应用学习」上线之前记到「IP 直连」的字节，
事后无法反推是哪一次连接、属于哪个应用。这些字节会一直挂在榜上，
看起来就像「下了 74 GB 却只有一半归到百度」。

这个脚本做的是**假设性修账**：把那台设备的「IP 直连」整体并到一个应用名下。
只有在你能确认「那段时间这台设备基本只在跑这一个应用」时才该用。

用法（在路由器上跑）：
    python3 merge_ip_only.py --mac 42:2d:7d:c7:f9:5f --to 百度          # 只看会怎么改
    python3 merge_ip_only.py --mac 42:2d:7d:c7:f9:5f --to 百度 --apply  # 真的改

改之前会自动备份到同目录的 *.bak-<时间戳>，想反悔就 cp 回去再重启 Agent。
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import time

DATA = "/etc/istore-agent/data"
STORE = os.path.join(DATA, "apps-usage.json")
DEV = os.path.join(DATA, "dev-apps.json")
IP_ONLY = "IP 直连"


def load(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def gb(v):
    return v / 2 ** 30


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mac", required=True)
    ap.add_argument("--to", required=True, help="目标应用名，例如 百度")
    ap.add_argument("--apply", action="store_true", help="真的写回；不带就是试算")
    args = ap.parse_args()

    mac = args.mac.lower()
    dev = load(DEV)
    apps = load(STORE)

    table = dev.get("dev") or {}
    entry = table.get(mac)
    if not entry:
        print("账本里没有这台设备：", mac)
        return 1
    moved = entry.get(IP_ONLY)
    if not moved:
        print("这台设备的账本里没有「IP 直连」，不用改")
        return 0

    amount = float(moved[0]) + float(moved[1])
    print("设备 %s 的「IP 直连」：%0.2f GB（上行 %0.2f / 下行 %0.2f）"
          % (mac, gb(amount), gb(float(moved[0])), gb(float(moved[1]))))

    before = entry.get(args.to, [0.0, 0.0])
    print("改后「%s」：%0.2f GB -> %0.2f GB"
          % (args.to, gb(float(before[0]) + float(before[1])),
             gb(float(before[0]) + float(before[1]) + amount)))

    glob = apps.get("total") or {}
    g_ip = glob.get(IP_ONLY, [0.0, 0.0])
    print("全局「IP 直连」：%0.2f GB -> %0.2f GB（同额扣减，不会扣成负数）"
          % (gb(float(g_ip[0]) + float(g_ip[1])),
             gb(max(0.0, float(g_ip[0]) + float(g_ip[1]) - amount))))

    if not args.apply:
        print("\n这是试算。确认无误后加 --apply 才会真的写。")
        return 0

    stamp = time.strftime("%Y%m%d-%H%M%S")
    for path in (STORE, DEV):
        shutil.copy2(path, "%s.bak-%s" % (path, stamp))

    # 1) 设备账本
    slot = entry.setdefault(args.to, [0.0, 0.0])
    slot[0] += float(moved[0])
    slot[1] += float(moved[1])
    entry.pop(IP_ONLY, None)

    # 2) 全局账本：同额扣减，扣到 0 为止（全局还含别的设备）
    if IP_ONLY in glob:
        left_up = max(0.0, float(glob[IP_ONLY][0]) - float(moved[0]))
        left_down = max(0.0, float(glob[IP_ONLY][1]) - float(moved[1]))
        take_up = float(glob[IP_ONLY][0]) - left_up
        take_down = float(glob[IP_ONLY][1]) - left_down
        g_slot = glob.setdefault(args.to, [0.0, 0.0])
        g_slot[0] += take_up
        g_slot[1] += take_down
        if left_up <= 0.0 and left_down <= 0.0:
            glob.pop(IP_ONLY, None)
        else:
            glob[IP_ONLY] = [left_up, left_down]

    for path, payload in ((DEV, dev), (STORE, apps)):
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, ensure_ascii=False, separators=(",", ":"))
        os.replace(tmp, path)

    print("\n已写入。备份带 .bak-%s 后缀。重启 Agent 后生效：" % stamp)
    print("  /etc/init.d/istore-agent restart")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
