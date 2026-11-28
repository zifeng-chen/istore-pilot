#!/usr/bin/env python3
"""校验三端字号常量是否一致（防「改了鸿蒙忘改安卓」）。

做法是「存在性检查」而不是解析 AST：每个平台为每一档给一个可以唯一定位的片段，
找不到就说明有人改了值而没同步。规则写死在 CHECKS 里，和 docs/UI_SPEC.md 对应。

只校验最容易漂移的三档：正文 / 卡片标题 / 最小。
页面大标题与 hero 数字在规格文档里注明「有意不同」，不校验。

用法：python scripts/ui_spec_check.py
"""

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

HARMONY = "harmony/entry/src/main/ets/ui/Theme.ets"
ANDROID = "android/app/src/main/java/com/izifeng/www/istorepilot/util/Ui.java"
IOS = "ios/IStorePilot/UI/Theme.swift"

# (档位, 期望值, {平台: 文件里应当出现的片段})
CHECKS = [
    ("正文", "15",
     {  # noqa: E128
         HARMONY: ["F_BODY: number = 15"],
         ANDROID: ["text(c, s, 15f", "COMPLEX_UNIT_DIP, 15f * capFont"],
         IOS: ["static let body      = Font.system(size: 15)"],
     }),
    ("卡片标题", "16",  # noqa: E128
     {  # noqa: E128
         HARMONY: ["F_H2: number = 16"],
         ANDROID: ["text(c, title, 16f"],
         IOS: ["static let cardTitle = Font.system(size: 16"],
     }),
    ("最小", "11.5",  # noqa: E128
     {  # noqa: E128
         HARMONY: ["F_TINY: number = 11.5"],
         ANDROID: ["text(c, s, 11.5f"],
         IOS: ["static let tiny      = Font.system(size: 11.5"],
     }),
]


def main() -> int:
    cache = {}
    bad = []
    for label, value, spec in CHECKS:
        ok = True
        for path, needles in spec.items():
            if path not in cache:
                try:
                    cache[path] = open(os.path.join(ROOT, path), encoding="utf-8").read()
                except OSError:
                    cache[path] = ""
            text = cache[path]
            miss = [n for n in needles if n not in text]
            if miss:
                ok = False
                short = path.split("/")[-1]
                print("!! %-6s %s 里找不到：%s" % (label, short, " / ".join(miss)))
        if ok:
            print("OK %-6s 三端均为 %s" % (label, value))
        else:
            bad.append(label)
    if bad:
        print("\n不一致：%s —— 对照 docs/UI_SPEC.md 修正后重试。" % "、".join(bad))
        return 1
    print("\n三端一致 ✓")
    return 0


if __name__ == "__main__":
    sys.exit(main())
