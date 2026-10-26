#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""三端 + Agent 版本号一致性自检。

同一个版本号在工程里有 6 个落脚点，漏改任何一个都会让产物自相矛盾
（例如工程是 0.1.2、HAP 清单里写 2.13.1）。这里一把梭全读出来比对。

用法：
    python scripts/check_version.py        # 一致则打印 OK，不一致 exit 1
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# (标签, 相对路径, 正则, 提取组)  —— 正则必须只命中版本号本身
SOURCES = [
    ("android  versionName", "android/app/build.gradle", r'versionName\s+"([^"]+)"', 1),
    ("android  versionCode", "android/app/build.gradle", r"versionCode\s+(\d+)", 1),
    ("harmony  app.versionName", "harmony/AppScope/app.json5", r'"versionName"\s*:\s*"([^"]+)"', 1),
    ("harmony  app.versionCode", "harmony/AppScope/app.json5", r'"versionCode"\s*:\s*(\d+)', 1),
    ("harmony  oh-package(根)", "harmony/oh-package.json5", r'^\s*"version"\s*:\s*"([^"]+)"', 1),
    ("harmony  oh-package(entry)", "harmony/entry/oh-package.json5", r'^\s*"version"\s*:\s*"([^"]+)"', 1),
    ("ios      VERSION", "ios/gen_project.py", r'^VERSION\s*=\s*"([^"]+)"', 1),
    ("ios      BUILD", "ios/gen_project.py", r'^BUILD\s*=\s*"?(\d+)"?', 1),
    ("ios      pbxproj MARKETING", "ios/IStorePilot.xcodeproj/project.pbxproj",
     r'MARKETING_VERSION\s*=\s*"?([^";]+)"?;', 1),
    ("ios      pbxproj CURRENT", "ios/IStorePilot.xcodeproj/project.pbxproj",
     r'CURRENT_PROJECT_VERSION\s*=\s*"?(\d+)"?;', 1),
    ("agent    VERSION", "agent/server.py", r'^VERSION\s*=\s*"([^"]+)"', 1),
]
# pbxproj 里每个 target 各写一次，只取第一次即可


def grab(rel, pat):
    path = os.path.join(ROOT, rel)
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as f:
        s = f.read()
    m = re.search(pat, s, flags=re.M)
    return m.group(1) if m else None


def main():
    names, codes, bad = [], [], []

    for label, rel, pat, _ in SOURCES:
        val = grab(rel, pat)
        if val is None:
            bad.append(f"{label:28} ————  读取失败（{rel}）")
            continue
        (codes if ("Code" in label or "BUILD" in label or "CURRENT" in label) else names).append(val)
        print(f"{label:28} {val}")

    problems = []
    if len(set(names)) > 1:
        problems.append(f"语义版本不一致：{sorted(set(names))}")
    if len(set(codes)) > 1:
        problems.append(f"versionCode 不一致：{sorted(set(codes))}")
    problems += bad

    print()
    if problems:
        for p in problems:
            print("!! " + p)
        print("\n修复：python scripts/bump_version.py --set <X.Y.Z>   （会把 6 处一起写）")
        return 1

    print(f"OK  {names[0]}  versionCode {codes[0]}   6 处一致")
    return 0


if __name__ == "__main__":
    sys.exit(main())
