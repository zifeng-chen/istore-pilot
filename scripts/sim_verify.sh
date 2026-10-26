#!/bin/bash
# 在模拟器上跑一遍，验证自适应布局没有回归 / 竖条形态正常。
# 用法: TOKEN=xxx bash sim_verify.sh <设备类型> <设备名> [rail]
#   rail = 强制竖条形态（临时改 BarAxis），只用于这次目检，跑完会还原
set -e

DEVTYPE="${1:-com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro}"
NAME="${2:-PilotTest}"
FORCE_RAIL="${3:-}"

PROJ=/Users/chen/istore-build/ios
: "${TOKEN:?需要 TOKEN}"

UDID=$(xcrun simctl list devices 2>/dev/null | grep -F "$NAME (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
if [ -z "$UDID" ]; then
  UDID=$(xcrun simctl create "$NAME" "$DEVTYPE" com.apple.CoreSimulator.SimRuntime.iOS-27-0)
  echo "created $UDID"
else
  echo "reuse $UDID"
fi
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true

DUO="$PROJ/IStorePilot/UI/DuoLayout.swift"
cp "$DUO" /tmp/DuoLayout.bak
if [ "$FORCE_RAIL" = "rail" ]; then
  python3 -c "
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
s = s.replace('self = size.width > size.height * 1.06 ? .rail : .bottom',
              'self = .rail   // 临时')
open(p, 'w', encoding='utf-8').write(s)
" "$DUO"
  echo "强制 .rail"
fi

cd "$PROJ"
xcodebuild -project IStorePilot.xcodeproj -scheme IStorePilot -configuration Debug \
  -sdk iphonesimulator -destination "id=$UDID" -derivedDataPath /tmp/dd_sim \
  CODE_SIGNING_ALLOWED=NO build > /tmp/sim_build.log 2>&1 || {
    grep -E "error:" /tmp/sim_build.log | head -20; cp /tmp/DuoLayout.bak "$DUO"; exit 1; }
APP=/tmp/dd_sim/Build/Products/Debug-iphonesimulator/IStorePilot.app
xcrun simctl install "$UDID" "$APP"

# 还原源码，别把临时的强制形态留在工程里
cp /tmp/DuoLayout.bak "$DUO"

# 预置登录态：plutil -insert 会把 istore.base 的点当 keypath 分隔符，用 plistlib
DATA=$(xcrun simctl get_app_container "$UDID" com.chaof.istoreos data)
PREFS="$DATA/Library/Preferences"
mkdir -p "$PREFS"
PL="$PREFS/com.chaof.istoreos.plist"
TOKEN="$TOKEN" PL="$PL" python3 -c "
import os, plistlib, time
d = {
    'istore.base': 'http://192.168.100.1:8443',
    'istore.token': os.environ['TOKEN'],
    'istore.expires': time.time() + 7 * 86400,
    'istore.user': 'root',
}
plistlib.dump(d, open(os.environ['PL'], 'wb'))
"
echo "预置: $(ls -la "$PL" | awk '{print $5" bytes"}')"

xcrun simctl terminate "$UDID" com.chaof.istoreos 2>/dev/null || true
xcrun simctl launch "$UDID" com.chaof.istoreos >/dev/null
sleep 9
xcrun simctl io "$UDID" screenshot "/tmp/shot_${NAME}.png" 2>/dev/null
echo "SHOT=/tmp/shot_${NAME}.png"
ls -la "/tmp/shot_${NAME}.png"
echo "UDID=$UDID"
