#!/usr/bin/env python3
"""对比三端调用的后端接口，找出「某端没实现某个功能」。

比文案对比可靠：文案可以换措辞，但功能必然要调接口。

输出：
  1. 三端各自调用的 /api/v1 路径集合与数量
  2. 只有某一端调用的路径（重点：可能是另两端缺功能）
  3. 某个页面维度下的差异
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SRC = {
    "android": "android/app/src/main/java",
    "ios": "ios/IStorePilot",
    "harmony": "harmony/entry/src/main/ets",
}

API = re.compile(r"/api/v1/[A-Za-z0-9_/{}<>$.\-]+")


def collect(base):
    """返回 {接口路径: [出现的文件]}"""
    found = {}
    for dirpath, _dirnames, filenames in os.walk(os.path.join(ROOT, base)):
        for fn in filenames:
            if not fn.endswith((".java", ".swift", ".ets", ".kt")):
                continue
            p = os.path.join(dirpath, fn)
            rel = os.path.relpath(p, ROOT)
            try:
                text = open(p, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            for m in API.finditer(text):
                u = m.group(0).rstrip('.,);"\'')
                found.setdefault(u, set()).add(rel)
    return found


def norm(u):
    """把路径里的变量段归一，便于跨端比较：/devices/{mac} 与 /devices/xxx 视为同一条"""
    u = u.split("?")[0].rstrip("/")
    u = re.sub(r"/\{[^}]*\}", "/_", u)
    u = re.sub(r"/\$\{[^}]*\}", "/_", u)
    u = re.sub(r"/<[^>]*>", "/_", u)
    return u


def main():
    data = {}
    for end, base in SRC.items():
        full = os.path.join(ROOT, base)
        if not os.path.isdir(full):
            print("跳过（目录不存在）:", end)
            continue
        data[end] = collect(base)

    print("=" * 74)
    print("各端接口数量（去重后）")
    normed = {}
    for end, d in data.items():
        s = {norm(u) for u in d}
        normed[end] = s
        print("  %-8s %d 条" % (end, len(s)))

    ends = list(normed)
    print()
    print("=" * 74)
    print("只有某一端调用的接口（越少越一致）")
    for end in ends:
        others = set().union(*[normed[e] for e in ends if e != end])
        only = sorted(normed[end] - others)
        print()
        print("-- 只有 %s 调用: %d 条" % (end, len(only)))
        for u in only:
            where = sorted(data[end].get(u) or [])
            # 归一后的路径可能对不上原始 key，取前缀匹配
            if not where:
                where = sorted({f for k, v in data[end].items() if norm(k) == u for f in v})
            f = os.path.basename(where[0]) if where else "?"
            print("    %-46s %s" % (u[:46], f))

    print()
    print("=" * 74)
    print("三端都有（一致）的接口: %d 条" % len(set.intersection(*[normed[e] for e in ends])))
    for u in sorted(set.intersection(*[normed[e] for e in ends])):
        print("   ", u)


if __name__ == "__main__":
    sys.exit(main())
