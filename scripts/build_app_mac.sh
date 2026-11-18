#!/bin/bash
# 在 Mac 上出 AGC 能收的 .app：
#   assembleApp（会失败，但失败前已经产出 hap 与 pac.json/pack.info）
#   → 自己 zip → hap-sign-tool 用发布证书签名 → 验签
#
# 为什么不用 hvigor 自己的 PackageApp：app_packing_tool 写死往 /private/tempHapDir
# 解压，普通用户建不了这个目录，SSH 下必然 "Compress failed"。
# 为什么 assembleApp 允许失败：它在 PackageApp 之前就把元数据和 hap 都写好了，
# 失败的那一步正好是我们绕开的。
#
# 用法：KEYSTORE_PWD=xxx bash build_app_mac.sh /tmp/out.app [CLEAN=1]
set -o pipefail
D=/Applications/DevEco-Studio.app/Contents
export DEVECO_SDK_HOME=$D/sdk
export PATH=$D/tools/node/bin:$D/tools/ohpm/bin:$D/tools/hvigor/bin:/opt/homebrew/bin:/usr/bin:/bin  # style-ok
PROJ=/Users/chen/istore-build/harmony
OUT=${1:-/tmp/istoreos-release.app}
CERTS=$(ls -d "$PROJ"/.certs/* 2>/dev/null | head -1)
PWD_KS="${KEYSTORE_PWD:?需要 KEYSTORE_PWD}"

cd "$PROJ" || exit 1

if [ "${CLEAN:-0}" = "1" ]; then
  echo "=== 清理 ==="
  hvigorw clean --no-daemon >/dev/null 2>&1
fi

echo "=== 构建（PackageApp 那步会失败，忽略）==="
hvigorw -p product=default -p buildMode=release assembleApp --no-daemon 2>&1 | grep -E "ERROR|BUILD" | head -4

HAP=entry/build/default/outputs/default/app/entry-default.hap
META=build/outputs/default
for f in "$HAP" "$META/pac.json" "$META/pack.info"; do
  [ -f "$f" ] || { echo "!! 缺 $f —— 构建没产出，停下来"; exit 1; }
done
echo "hap: $(du -h "$HAP" | cut -f1)   元数据: pac.json + pack.info"

echo "=== 打包 .app ==="
rm -rf /tmp/appkit && mkdir -p /tmp/appkit
cp "$META/pac.json" "$META/pack.info" /tmp/appkit/
cp "$HAP" /tmp/appkit/entry-default.hap
( cd /tmp/appkit && rm -f "$OUT" && zip -q -X -r "$OUT" pac.json pack.info entry-default.hap )

echo "=== 签名 ==="
java -jar "$DEVECO_SDK_HOME/default/openharmony/toolchains/lib/hap-sign-tool.jar" sign-app \
  -mode localSign -signAlg SHA256withECDSA \
  -keystoreFile "$CERTS"/key_*.p12 -keystorePwd "$PWD_KS" \
  -keyAlias istore -keyPwd "$PWD_KS" \
  -appCertFile "$CERTS"/cert_*.cer -profileFile "$CERTS"/profile_*.p7b \
  -inFile "$OUT" -outFile "${OUT%.app}-signed.app" 2>&1 | tail -2

echo "=== 验签 ==="
python3 /Users/chen/istore-build/harmony_pkg_verify.py "${OUT%.app}-signed.app" --expect-type release 2>&1 | tail -10
