#!/bin/bash
# 在 Mac 上编 iOS。用法：
#   bash build_ios.sh                 # 只验证编译（不签名）
#   bash build_ios.sh sign            # 尝试签名 + 导出 IPA
set -o pipefail

PROJ_DIR="${PROJ_DIR:-/Users/chen/istore-build/ios}"
LOG=/tmp/ios_build.log
MODE="${1:-build}"
TEAM="${DEV_TEAM:-224G8HPA6X}"

cd "$PROJ_DIR" || { echo "!! 目录不存在: $PROJ_DIR"; exit 1; }

echo "=== 环境 ==="
echo "Xcode  $(xcodebuild -version | head -1)"

COMMON=(-project IStorePilot.xcodeproj -scheme IStorePilot -configuration Release)

if [ "$MODE" = "sign" ]; then
  echo ""
  echo "=== 归档（自动签名）==="
  xcodebuild "${COMMON[@]}" \
    -destination 'generic/platform=iOS' \
    -archivePath build/IStorePilot.xcarchive \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic \
    archive > "$LOG" 2>&1
  RC=$?
else
  echo ""
  echo "=== 编译（免签名，只验证代码）==="
  xcodebuild "${COMMON[@]}" \
    -sdk iphoneos -destination 'generic/platform=iOS' \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    build > "$LOG" 2>&1
  RC=$?
fi

echo ""
if [ $RC -eq 0 ]; then
  echo "BUILD SUCCEEDED"
  if [ "$MODE" = "sign" ] && [ -d build/IStorePilot.xcarchive ]; then
    echo ""
    echo "=== 导出 IPA ==="
    cat > /tmp/ExportOptions.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>development</string>
  <key>signingStyle</key><string>automatic</string>
  <key>stripSwiftSymbols</key><true/>
  <key>compileBitcode</key><false/>
</dict>
</plist>
PLIST
    xcodebuild -exportArchive \
      -archivePath build/IStorePilot.xcarchive \
      -exportOptionsPlist /tmp/ExportOptions.plist \
      -exportPath build/ipa \
      -allowProvisioningUpdates >> "$LOG" 2>&1
    echo "导出返回码: $?"
    find build/ipa -name "*.ipa" 2>/dev/null
  fi
else
  echo "BUILD FAILED (rc=$RC)"
  grep -E "error:|BUILD FAILED" "$LOG" | head -40
fi
exit $RC
