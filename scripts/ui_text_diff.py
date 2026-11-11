#!/usr/bin/env python3
"""提取三端源码里的中文字符串，用于人工比对界面文案差异。

用法：
    python scripts/ui_text_diff.py            # 全部页面
    python scripts/ui_text_diff.py overview   # 只看名字里含 overview 的页面

只做「有哪些中文文案」的罗列，不做自动判定 —— 三端措辞本来就会有差异，
这个脚本的作用是把差异摆到眼前，由人判断是「措辞不同」还是「功能缺失」。
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 页面映射：逻辑页名 -> 三端文件（相对仓库根）
PAGES = {
    "overview": {
        "android": ["android/app/src/main/java/com/izifeng/www/istorepilot/ui/OverviewFragment.java"],
        "ios": ["ios/IStorePilot/Views/OverviewView.swift"],
        "harmony": ["harmony/entry/src/main/ets/ui/tabs/OverviewPage.ets"],
    },
    "devices": {  # 设备一级页（设备 + 拦截）
        "android": ["android/app/src/main/java/com/izifeng/www/istorepilot/ui/SecurityFragment.java"],
        "ios": ["ios/IStorePilot/Views/SecurityView.swift"],
        "harmony": ["harmony/entry/src/main/ets/ui/tabs/SecurityPage.ets"],
    },
    "device_list": {
        "android": ["android/app/src/main/java/com/izifeng/www/istorepilot/ui/DevicesFragment.java"],
        "ios": ["ios/IStorePilot/Views/DevicesView.swift"],
        "harmony": ["harmony/entry/src/main/ets/ui/tabs/DevicesPage.ets"],
    },
    "device_detail": {
        "android": ["android/app/src/main/java/com/izifeng/www/istorepilot/DeviceDetailActivity.java"],
        "ios": ["ios/IStorePilot/Views/DeviceDetailView.swift"],
        "harmony": ["harmony/entry/src/main/ets/pages/DeviceDetailPage.ets"],
    },
    "adblock": {
        "android": ["android/app/src/main/java/com/izifeng/www/istorepilot/ui/AdblockFragment.java"],
        "ios": ["ios/IStorePilot/Views/ShieldView.swift"],
        "harmony": ["harmony/entry/src/main/ets/ui/tabs/ShieldPage.ets"],
    },
    "apps": {
        "android": ["android/app/src/main/java/com/izifeng/www/istorepilot/AppsActivity.java"],
        "ios": ["ios/IStorePilot/Views/AppsView.swift"],
        "harmony": [],  # 待确认
    },
    "proxy": {
        "android": ["android/app/src/main/java/com/izifeng/www/istorepilot/ui/ProxyFragment.java"],
        "ios": ["ios/IStorePilot/Views/ProxyView.swift"],
        "harmony": ["harmony/entry/src/main/ets/ui/tabs/ProxyPage.ets"],
    },
    "subscription": {
        "android": ["android/app/src/main/java/com/izifeng/www/istorepilot/SubscriptionActivity.java"],
        "ios": ["ios/IStorePilot/Views/SubscriptionView.swift"],
        "harmony": ["harmony/entry/src/main/ets/pages/SubscriptionPage.ets"],
    },
    "settings": {
        "android": ["android/app/src/main/java/com/izifeng/www/istorepilot/ui/SettingsFragment.java"],
        "ios": ["ios/IStorePilot/Views/SettingsView.swift"],
        "harmony": ["harmony/entry/src/main/ets/ui/tabs/SettingsPage.ets"],
    },
    "wan": {
        "android": ["android/app/src/main/java/com/izifeng/www/istorepilot/WanActivity.java"],
        "ios": ["ios/IStorePilot/Views/WanView.swift"],
        "harmony": ["harmony/entry/src/main/ets/ui/tabs/NetworkPage.ets"],
    },
    "hardware": {
        "android": ["android/app/src/main/java/com/izifeng/www/istorepilot/HardwareActivity.java"],
        "ios": ["ios/IStorePilot/Views/HardwareView.swift"],
        "harmony": ["harmony/entry/src/main/ets/ui/tabs/SettingsPage.ets"],  # 鸿蒙内嵌在设置
    },
    "backup": {
        "android": ["android/app/src/main/java/com/izifeng/www/istorepilot/BackupActivity.java"],
        "ios": ["ios/IStorePilot/Views/BackupsView.swift"],
        "harmony": ["harmony/entry/src/main/ets/ui/tabs/BackupsPage.ets"],
    },
    "login": {
        "android": ["android/app/src/main/java/com/izifeng/www/istorepilot/ui/LoginActivity.java"],
        "ios": ["ios/IStorePilot/Views/LoginView.swift"],
        "harmony": ["harmony/entry/src/main/ets/pages/LoginPage.ets"],
    },
    "web": {
        "android": ["android/app/src/main/java/com/izifeng/www/istorepilot/WebActivity.java"],
        "ios": ["ios/IStorePilot/Views/WebScreen.swift"],
        "harmony": ["harmony/entry/src/main/ets/pages/WebPage.ets"],
    },
}

# 中文串：允许穿插变量占位，只取长度 >= 2 的
CJK = re.compile(r"[\u4e00-\u9fff]")
STR_D = re.compile(r'"([^"\n]{2,120})"')
STR_S = re.compile(r"'([^'\n]{2,120})'")


def _strings_in(line):
    for rx in (STR_D, STR_S):
        for m in rx.finditer(line):
            yield m.group(1)


def texts_of(path):
    full = os.path.join(ROOT, path)
    if not os.path.exists(full):
        return None
    out = []
    with open(full, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            s = line.strip()
            if s.startswith("//") or s.startswith("*") or s.startswith("/*"):
                continue  # 跳过注释：注释里的中文不是界面文案
            for m in _strings_in(line):
                t = (m or "").strip()
                if t and CJK.search(t):
                    out.append(t)
    # 去重保序
    seen = set()
    uniq = []
    for t in out:
        if t not in seen:
            seen.add(t)
            uniq.append(t)
    return uniq


def main():
    want = sys.argv[1].lower() if len(sys.argv) > 1 else None
    for page, ends in PAGES.items():
        if want and want not in page:
            continue
        print("=" * 72)
        print("页面:", page)
        data = {}
        for end, files in ends.items():
            got = []
            for f in files:
                r = texts_of(f)
                if r is None:
                    got = None
                    break
                got.extend(r)
            data[end] = got
        for end in ("android", "ios", "harmony"):
            v = data[end]
            if v is None:
                print("  %-8s [文件不存在]" % end)
            elif not v:
                print("  %-8s [无独立文件/内嵌在别处]" % end)
            else:
                print("  %-8s %d 条" % (end, len(v)))
        # 只在三端都有内容时给差集（判断「某端缺了什么功能文案」）
        if all(data[e] for e in ("android", "ios", "harmony")):
            sa, si, sh = (set(data[e]) for e in ("android", "ios", "harmony"))
            only_android = sorted(sa - si - sh)
            if only_android:
                print("  -- 只有 Android 有（可能另两端缺）:")
                for t in only_android[:14]:
                    print("     ", t[:60])
        print()


if __name__ == "__main__":
    main()
