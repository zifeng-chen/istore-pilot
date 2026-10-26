#!/bin/sh
# 逐页截图：5 个页签各截一张，用于视觉回归对比。
# 用法：sh scripts/capture.sh <前缀> [浅色|深色]
# 依赖：adb 已连接真机（无线调试每次调用会回收 daemon，脚本内自行 connect）
set -u

ADB="adb"
DEV="192.168.100.131:5555"
OUT="${1:-shot}"
PLAT="${LOCALAPPDATA:-$HOME/AppData/Local}/Android/Sdk/platform-tools"
PATH="$PATH:$PLAT"
export PATH

DIR="docs/screenshots/theme"
mkdir -p "$DIR"

"$ADB" connect "$DEV" >/dev/null 2>&1
# 手机没设锁屏密码，唤醒后上滑即可进桌面。
# 少了这一步，锁屏状态下截图拍到的全是壁纸，而 am start 会静默失败。
"$ADB" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
sleep 1
"$ADB" shell input swipe 540 2000 540 600 250 >/dev/null 2>&1
sleep 1
"$ADB" shell am start -n com.chaof.istoreos/.MainActivity >/dev/null 2>&1
sleep 3

focus=$("$ADB" shell dumpsys window 2>/dev/null | grep -m1 mCurrentFocus)
case "$focus" in
    *istoreos*) ;;
    *) echo "!! 应用不在前台，当前窗口：$focus"; exit 1 ;;
esac

# 导航栏 5 格均分 1080 宽，图标中心 y≈2256
# 页签是 add/hide 保状态的，切过去会停在原来的滚动位置，
# 所以每页先往上滑回顶部，否则截到的可能是半截页面
i=0
for name in overview devices proxy shield settings; do
    x=$((108 + i * 216))
    "$ADB" shell input tap $x 2256
    sleep 1
    for k in 1 2 3; do
        "$ADB" shell input swipe 540 500 540 1900 120 >/dev/null 2>&1
    done
    # 回到顶部那一下可能带出下拉刷新，多等一会儿让数据落定
    sleep 4
    "$ADB" exec-out screencap -p > "$DIR/${OUT}_${name}.png" 2>/dev/null
    echo "  $name -> ${OUT}_${name}.png"
    i=$((i + 1))
done

# 回到概览
"$ADB" shell input tap 108 2256 >/dev/null 2>&1
echo "done"
