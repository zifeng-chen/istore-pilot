"""把最新的鸿蒙签名包复制成带序号的内测包。

约定：`dist/istorepilot-<版本>-beta<三位序号>.hap`，序号从 001 起递增。
每次编译完跑一次，拿到递增的文件名和 MD5，再交给 DevBridge 推送 ——
文件名里带序号，就不会出现「推了哪一版」说不清的情况。

用法：
    python scripts/hap_beta.py                # 生成下一个序号的 beta 包
    python scripts/hap_beta.py --list         # 只看现有 beta 包
"""

import argparse
import glob
import hashlib
import os
import re
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIST = os.path.join(ROOT, "dist")
#: 本地构建产物目录（Mac 上编译后 sync/put 回来的那份）
BUILD = os.path.join(ROOT, "build")
PATTERN = re.compile(r"istorepilot-(\d+\.\d+\.\d+)-beta(\d{3})\.hap$")


def version() -> str:
    """版本号取自 AppScope/app.json5，和 hap 里的一致。"""
    path = os.path.join(ROOT, "harmony", "AppScope", "app.json5")
    try:
        with open(path, encoding="utf-8") as fp:
            text = fp.read()
        hit = re.search(r'"versionName"\s*:\s*"([^"]+)"', text)
        if hit:
            return hit.group(1)
    except OSError:
        pass
    return "0.0.0"


def betas() -> list:
    rows = []
    for path in glob.glob(os.path.join(DIST, "istorepilot-*-beta*.hap")):
        hit = PATTERN.search(os.path.basename(path))
        if hit:
            rows.append((hit.group(1), int(hit.group(2)), path))
    return sorted(rows, key=lambda r: (r[0], r[1]))


def md5(path: str) -> str:
    h = hashlib.md5()
    with open(path, "rb") as fp:
        for chunk in iter(lambda: fp.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", action="store_true", help="只列出现有的 beta 包")
    ap.add_argument("--src", default="", help="签名包路径，默认取 build/ 下最新的 hap")
    args = ap.parse_args()

    os.makedirs(DIST, exist_ok=True)
    existing = betas()

    if args.list:
        if not existing:
            print("还没有 beta 包")
            return 0
        for ver, num, path in existing:
            print("%s  beta%03d  %.1f MB  %s" % (ver, num, os.path.getsize(path) / 1048576, md5(path)))
        return 0

    ver = version()
    src = args.src
    if not src:
        cands = [os.path.join(BUILD, f) for f in os.listdir(BUILD)
                 if f.endswith(".hap")] if os.path.isdir(BUILD) else []
        cands.sort(key=os.path.getmtime, reverse=True)
        src = cands[0] if cands else ""
    if not src or not os.path.exists(src):
        print("! 没找到签名包，用 --src 指定，或先把 Mac 上编译好的 hap 拉回 build/")
        return 2

    same = [n for v, n, _ in existing if v == ver]
    nxt = (max(same) + 1) if same else 1
    target = os.path.join(DIST, "istorepilot-%s-beta%03d.hap" % (ver, nxt))
    shutil.copyfile(src, target)
    print("来源：%s" % src)
    print("新包：%s" % target)
    print("MD5 ：%s" % md5(target))
    print("大小：%.1f MB" % (os.path.getsize(target) / 1048576))
    return 0


if __name__ == "__main__":
    sys.exit(main())
