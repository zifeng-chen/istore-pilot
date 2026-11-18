#!/bin/bash
# 只跑「打包 .app 需要的元数据」两个任务，不跑 PackageApp（它会往 /private/tempHapDir 解压，必然失败）
set -o pipefail
D=/Applications/DevEco-Studio.app/Contents
export DEVECO_SDK_HOME=$D/sdk
export PATH=$D/tools/node/bin:$D/tools/ohpm/bin:$D/tools/hvigor/bin:/opt/homebrew/bin:/usr/bin:/bin  # style-ok
cd /Users/chen/istore-build/harmony || exit 1

hvigorw --mode module -p product=default -p buildMode=release assembleHap --no-daemon 2>&1 \
  | grep -E "ERROR|BUILD" | head -5
echo "--- hap 里的版本 ---"
python3 - <<'PY'
import zipfile, json
z = zipfile.ZipFile("entry/build/default/outputs/default/app/entry-default.hap")
m = json.loads(z.read("module.json"))
app = m.get("app", {})
print("versionName=%s versionCode=%s" % (app.get("versionName"), app.get("versionCode")))
PY

echo "--- 生成 pack 元数据 ---"
hvigorw :MakeProjectPackInfo :GeneratePackRes --no-daemon 2>&1 | grep -E "ERROR|BUILD|error" | head -5
ls -l build/outputs/default/ 2>/dev/null | tail -4
