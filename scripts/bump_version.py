#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""三端 + Agent 版本号统一管理。

规则（用户 2026-10-26 定）：起点 0.1.0，**第三位满 10 进位**——
0.1.0 → 0.1.1 → … → 0.1.9 → 0.2.0 → … → 0.2.9 → 0.3.0。

也就是说版本号里没有 0.1.10 这种东西：patch 只用 0~9。

用法：
    python scripts/bump_version.py            # 看当前版本
    python scripts/bump_version.py --next     # 自增一位并写入四处
    python scripts/bump_version.py --set 0.4.2

versionCode / BUILD 是单调递增整数，跟语义版本解耦：
Android 不允许 versionCode 回退，所以它只加不减（当前 23 起）。
"""
import argparse
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

FILES = {
    "harmony": "harmony/AppScope/app.json5",
    "ohpkg_root": "harmony/oh-package.json5",
    "ohpkg_entry": "harmony/entry/oh-package.json5",
    "android": "android/app/build.gradle",
    "ios_gen": "ios/gen_project.py",
    "agent": "agent/server.py",
}


def path(key):
    return os.path.join(ROOT, FILES[key])


def read_all():
    with open(path("harmony"), encoding="utf-8") as f:
        s = f.read()
    name = re.search(r'"versionName"\s*:\s*"([^"]+)"', s).group(1)
    # versionCode 取三端最大值：任何一端落后都不能让新包「版本更低」，
    # 否则 Android 会直接拒装（INSTALL_FAILED_VERSION_DOWNGRADE）
    codes = [int(re.search(r'"versionCode"\s*:\s*(\d+)', s).group(1))]
    with open(path("android"), encoding="utf-8") as f:
        codes.append(int(re.search(r"versionCode\s+(\d+)", f.read()).group(1)))
    with open(path("ios_gen"), encoding="utf-8") as f:
        m = re.search(r'^BUILD = "?(\d+)"?', f.read(), flags=re.M)
        if m:
            codes.append(int(m.group(1)))
    return name, max(codes)


def next_version(name):
    major, minor, patch = (int(x) for x in name.split("."))
    patch += 1
    if patch >= 10:  # 第三位满 10 进第二位，patch 归零
        patch = 0
        minor += 1
    if minor >= 10:
        minor = 0
        major += 1
    return f"{major}.{minor}.{patch}"


def write_all(name, code):
    edits = [
        ("harmony", r'"versionCode":\s*\d+', f'"versionCode": {code}'),
        ("harmony", r'"versionName":\s*"[^"]+"', f'"versionName": "{name}"'),
        # oh-package.json5 的 version 是 hvigor 打包时写进产物清单的字段，
        # 不跟着改会出现「app.json5 是 0.1.2、HAP 里写 2.13.1」这种自相矛盾
        ("ohpkg_root", r'"version":\s*"[^"]+"', f'"version": "{name}"'),
        ("ohpkg_entry", r'"version":\s*"[^"]+"', f'"version": "{name}"'),
        ("android", r"versionCode\s+\d+", f"versionCode {code}"),
        ("android", r'versionName\s+"[^"]+"', f'versionName "{name}"'),
    ]
    for key, pat, rep in edits:
        p = path(key)
        with open(p, encoding="utf-8") as f:
            s = f.read()
        s2, n = re.subn(pat, rep, s, count=1)
        if n == 0:
            print(f"!! {key}: 没匹配到 {pat}")
            return False
        with open(p, "w", encoding="utf-8", newline="\n") as f:
            f.write(s2)

    # iOS：VERSION 与 BUILD 两个常量
    p = path("ios_gen")
    with open(p, encoding="utf-8") as f:
        s = f.read()
    s = re.sub(r'^VERSION = "[^"]+"', f'VERSION = "{name}"', s, count=1, flags=re.M)
    s = re.sub(r'^BUILD = (?:\d+|"\d+")', f'BUILD = "{code}"', s, count=1, flags=re.M)
    with open(p, "w", encoding="utf-8", newline="\n") as f:
        f.write(s)

    # Agent：路由端服务的自报版本，和客户端保持一致，设置页才不会被用户看成两个东西
    p = path("agent")
    with open(p, encoding="utf-8") as f:
        s = f.read()
    s = re.sub(r'^VERSION = "[^"]+"', f'VERSION = "{name}"', s, count=1, flags=re.M)
    with open(p, "w", encoding="utf-8", newline="\n") as f:
        f.write(s)
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--next", action="store_true", help="自增一位")
    ap.add_argument("--set", metavar="X.Y.Z", help="直接指定版本号")
    a = ap.parse_args()

    name, code = read_all()
    if a.set:
        new_name = a.set
        if not re.fullmatch(r"\d+\.\d+\.\d", new_name):
            sys.exit("版本号必须形如 0.1.0")
        if int(new_name.split(".")[2]) > 9:
            sys.exit("第三位只能是 0~9，满 10 请进位到第二位（规则见文件头）")
        new_code = code + 1
    elif a.next:
        new_name, new_code = next_version(name), code + 1
    else:
        print(f"当前 {name}  (versionCode {code})")
        print(f"下一位 {next_version(name)}  (versionCode {code + 1})")
        return

    if not write_all(new_name, new_code):
        sys.exit("写入失败")
    print(f"✓ {name} → {new_name}   versionCode {code} → {new_code}")
    print("  已同步：harmony/app.json5 + oh-package×2  android/build.gradle  ios/gen_project.py  agent/server.py")


if __name__ == "__main__":
    main()
