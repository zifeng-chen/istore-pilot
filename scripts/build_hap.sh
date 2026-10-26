#!/bin/bash
# 在 Mac 上编鸿蒙 HAP。用法：bash build_hap.sh [project_dir]
set -o pipefail

PROJ="${1:-/Users/chen/istore-build/harmony}"
DEVECO="/Applications/DevEco-Studio.app/Contents"

export DEVECO_SDK_HOME="$DEVECO/sdk"
export PATH="$DEVECO/tools/node/bin:$DEVECO/tools/ohpm/bin:$DEVECO/tools/hvigor/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export NODE_HOME="$DEVECO/tools/node"

cd "$PROJ" || { echo "!! 工程目录不存在: $PROJ"; exit 1; }

echo "=== 环境 ==="
echo "node    $(node -v)"
echo "hvigor  $(hvigorw --version 2>&1 | tail -1)"
echo "sdk api $(python3 -c "import json;print(json.load(open('$DEVECO_SDK_HOME/default/sdk-pkg.json'))['data']['apiVersion'])" 2>/dev/null)"
echo "工程    $PROJ"

echo ""
echo "=== 清理 ==="
hvigorw clean --no-daemon 2>&1 | tail -4

echo ""
echo "=== 构建 ==="
hvigorw --mode module -p product=default -p buildMode=release assembleHap --no-daemon 2>&1
RC=$?

echo ""
echo "=== 产物 ==="
find entry/build -name "*.hap" -o -name "*.hsp" 2>/dev/null | while read -r f; do
  printf "%s  %s\n" "$(du -h "$f" | cut -f1)" "$f"
done
echo "=== EXIT:$RC ==="
exit $RC
