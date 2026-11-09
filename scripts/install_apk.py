#!/usr/bin/env python3
"""把 0.1.9 的 APK 通过 adb 装到手机上。

为什么要有这个脚本：某些时候 agent 的命令执行环境不可用（沙箱起不来），
但手机上的无线调试已经开着。这时候在资源管理器里双击 install_apk.bat
就能装，不依赖 agent。

用法：
    python scripts/install_apk.py                    # 交互输入 IP:端口
    python scripts/install_apk.py 192.168.100.130:38137
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APK = os.path.join(ROOT, "dist", "istoreos-0.1.9.apk")

ADB_CANDIDATES = [
    os.path.expandvars(r"%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe"),
    r"C:\Android\platform-tools\adb.exe",
    "adb",
]


def find_adb() -> str:
    for p in ADB_CANDIDATES:
        if p == "adb":
            return p
        if os.path.exists(p):
            return p
    return "adb"


def run(adb: str, *args: str, timeout: int = 120) -> tuple[int, str]:
    try:
        got = subprocess.run([adb] + list(args), capture_output=True,
                             timeout=timeout, text=True,
                             encoding="utf-8", errors="replace")
        return got.returncode, (got.stdout or "") + (got.stderr or "")
    except FileNotFoundError:
        return -1, "找不到 adb，请确认 Android SDK 的 platform-tools 在哪"
    except subprocess.TimeoutExpired:
        return -2, "命令超时"


def main() -> int:
    adb = find_adb()
    print("adb    :", adb)
    print("APK    :", APK)
    if not os.path.exists(APK):
        print("! APK 不存在，先跑 python deploy/build_run.py")
        return 1

    target = sys.argv[1].strip() if len(sys.argv) > 1 else ""
    while not target:
        target = input("手机「无线调试」页上的 IP:端口（如 192.168.100.130:38137）：").strip()

    print("\n[1/3] 连接", target)
    print(run(adb, "connect", target)[1].strip())

    print("\n[2/3] 设备状态")
    _, out = run(adb, "devices", "-l")
    print(out.rstrip())

    state = ""
    for line in out.splitlines():
        if target in line:
            parts = line.split()
            if len(parts) >= 2:
                state = parts[1]
    if state != "device":
        print("\n! 状态是 %r，不是 device。" % (state or "没找到"))
        if state == "unauthorized":
            print("  手机上会弹「允许 USB 调试吗」，点允许后重跑本脚本。")
        elif not state:
            print("  没连上，常见原因：")
            print("   - 第一次连：手机上点「使用配对码配对设备」，先跑")
            print("       adb pair %s" % target.replace(re.search(r":\d+$", target).group(0), ":配对端口"))
            print("     把 6 位配对码填进去，配对成功后再跑本脚本")
            print("   - 锁屏了：解锁手机再试")
            print("   - 端口变了：重看「无线调试」页上的端口")
        return 2

    print("\n[3/3] 安装（覆盖旧版，配置保留）")
    code, out = run(adb, "-s", target, "install", "-r", APK, timeout=300)
    print(out.strip())
    if code != 0:
        print("\n! 安装失败，把上面这段发我")
        return 3

    print("\n装好了。打开 App：")
    print("  地址 192.168.100.208:8443")
    print("  口令 CHAOYUE8feng")
    print("  进「代理」页拉到底 →「安装包」→ 从仓库下载")
    return 0


if __name__ == "__main__":
    sys.exit(main())
