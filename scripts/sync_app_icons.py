#!/usr/bin/env python3
"""把 Android 的应用图标同步到 iOS / 鸿蒙，并生成两端的名称映射。

图标源只有一处：`android/app/src/main/res/drawable-nodpi/ic_app_*.png`
（`scripts/fetch_app_icons.py` 从 App Store 抓的那批），映射表是同目录下
生成的 `AppIcons.java`。iOS 的 Assets 和鸿蒙的 media 都由这里派生 ——
三端用同一张图、同一套名字，改完图标只要重跑这一个脚本。

用法：
    python scripts/sync_app_icons.py            # 同步资源 + 生成映射
    python scripts/sync_app_icons.py --check    # 只检查两端是否落后
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

JAVA_MAP = os.path.join(
    ROOT, "android/app/src/main/java/com/chaof/istoreos/util/AppIcons.java")
ANDROID_ICONS = os.path.join(ROOT, "android/app/src/main/res/drawable-nodpi")

IOS_ASSETS = os.path.join(ROOT, "ios/IStorePilot/Assets.xcassets")
IOS_SWIFT = os.path.join(ROOT, "ios/IStorePilot/Core/AppIcons.swift")

HARMONY_MEDIA = os.path.join(ROOT, "harmony/entry/src/main/resources/base/media")
HARMONY_ETS = os.path.join(ROOT, "harmony/entry/src/main/ets/core/AppIcons.ets")

PAIR = re.compile(r'MAP\.put\("([^"]+)",\s*R\.drawable\.(ic_app_\w+)\)')


def load() -> list[tuple[str, str]]:
    """读出 (应用名, 资源名) 列表，顺序保持 AppIcons.java 里的顺序。"""
    with open(JAVA_MAP, encoding="utf-8") as fh:
        src = fh.read()
    return PAIR.findall(src)


def sync_ios(pairs: list[tuple[str, str]]) -> int:
    os.makedirs(IOS_ASSETS, exist_ok=True)
    for name, res in pairs:
        key = res[len("ic_app_"):]
        src = os.path.join(ANDROID_ICONS, res + ".png")
        if not os.path.isfile(src):
            print("  跳过（缺图）:", res)
            continue
        folder = os.path.join(IOS_ASSETS, "app_" + key + ".imageset")
        os.makedirs(folder, exist_ok=True)
        shutil.copyfile(src, os.path.join(folder, "icon.png"))
        with open(os.path.join(folder, "Contents.json"), "w", encoding="utf-8",
                  newline="\n") as fh:
            json.dump({
                "images": [{"filename": "icon.png", "idiom": "universal"}],
                "info": {"author": "xcode", "version": 1},
            }, fh, indent=2, ensure_ascii=False)
            fh.write("\n")

    lines = [
        "// 自动生成：scripts/sync_app_icons.py。不要手改。",
        "// 图标本体在 Assets.xcassets/app_*.imageset，与安卓 drawable-nodpi 是同一批图。",
        "import Foundation",
        "",
        "enum AppIcons {",
        "    /// 应用名 → Asset 名",
        "    static let map: [String: String] = [",
    ]
    for name, res in pairs:
        key = res[len("ic_app_"):]
        lines.append('        "%s": "app_%s",' % (name.replace('"', '\\"'), key))
    lines += [
        "    ]",
        "",
        "    static func asset(_ name: String) -> String? {",
        "        map[name]",
        "    }",
        "}",
        "",
    ]
    with open(IOS_SWIFT, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines))
    return len(pairs)


def sync_harmony(pairs: list[tuple[str, str]]) -> int:
    os.makedirs(HARMONY_MEDIA, exist_ok=True)
    for _, res in pairs:
        src = os.path.join(ANDROID_ICONS, res + ".png")
        if os.path.isfile(src):
            shutil.copyfile(src, os.path.join(HARMONY_MEDIA, res + ".png"))

    lines = [
        "// 自动生成：scripts/sync_app_icons.py。不要手改。",
        "// 图标本体在 resources/base/media/ic_app_*.png，与安卓是同一批图。",
        "",
        "/** 应用名 → 图标资源。没收录的名字返回 undefined，调用方退回首字色块。 */",
        "const APP_ICONS: Map<string, Resource> = new Map<string, Resource>([",
    ]
    for name, res in pairs:
        lines.append("  ['%s', $r('app.media.%s')]," % (name.replace("'", "\\'"), res))
    lines += [
        "]);",
        "",
        "export function appIconOf(name: string): Resource | undefined {",
        "  return APP_ICONS.get(name);",
        "}",
        "",
    ]
    with open(HARMONY_ETS, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines))
    return len(pairs)


def check(pairs: list[tuple[str, str]]) -> int:
    missing_ios, missing_harmony = [], []
    for _, res in pairs:
        key = res[len("ic_app_"):]
        if not os.path.isfile(os.path.join(
                IOS_ASSETS, "app_" + key + ".imageset", "icon.png")):
            missing_ios.append(key)
        if not os.path.isfile(os.path.join(HARMONY_MEDIA, res + ".png")):
            missing_harmony.append(key)
    print("图标总数:", len(pairs))
    print("iOS 缺:", missing_ios or "无")
    print("鸿蒙缺:", missing_harmony or "无")
    return 1 if (missing_ios or missing_harmony) else 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="只检查，不写文件")
    args = ap.parse_args()

    pairs = load()
    if not pairs:
        print("没读到任何映射，检查 AppIcons.java 是否已生成")
        return 1
    if args.check:
        return check(pairs)

    n_ios = sync_ios(pairs)
    n_harmony = sync_harmony(pairs)
    print("已同步 %d 个图标 → iOS(%d) / 鸿蒙(%d)" % (len(pairs), n_ios, n_harmony))
    print("iOS 映射:", os.path.relpath(IOS_SWIFT, ROOT))
    print("鸿蒙映射:", os.path.relpath(HARMONY_ETS, ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
