#!/bin/bash
# 在 Mac 上：assembleHap → 自己打 .app → 用发布证书签名 → 验签。
# 为什么不用 hvigorw assembleApp：app_packing_tool 写死往 /private/tempHapDir 解压，
# 普通用户建不了这个目录，SSH 下必然 "Compress failed"。
set -o pipefail
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
D=/Applications/DevEco-Studio.app/Contents
export PATH=$D/tools/node/bin:$D/tools/ohpm/bin:$D/tools/hvigor/bin:/opt/homebrew/bin:/usr/bin:/bin  # style-ok
PROJ=/Users/chen/istore-build/harmony
OUT=${1:-/tmp/istoreos-release.app}
CERTS=$(ls -d "$PROJ"/.certs/* 2>/dev/null | head -1)
PWD_KS="${KEYSTORE_PWD:?需要 KEYSTORE_PWD}"

cd "$PROJ" || exit 1
echo "=== 编译 HAP ==="
hvigorw --mode module -p product=default -p buildMode=release assembleHap --no-daemon 2>&1 \
  | grep -E "ERROR|BUILD" | head -5

echo "=== 打包 .app ==="
rm -rf /tmp/appkit && mkdir -p /tmp/appkit
cp build/outputs/default/pac.json build/outputs/default/pack.info /tmp/appkit/ || exit 1
cp entry/build/default/outputs/default/app/entry-default.hap /tmp/appkit/ || exit 1
( cd /tmp/appkit && rm -f "$OUT" && zip -q -X -r "$OUT" pac.json pack.info entry-default.hap ) || exit 1

echo "=== 签名 ==="
java -jar "$DEVECO_SDK_HOME/default/openharmony/toolchains/lib/hap-sign-tool.jar" sign-app \
  -mode localSign -signAlg SHA256withECDSA \
  -keystoreFile "$CERTS"/key_*.p12 -keystorePwd "$PWD_KS" \
  -keyAlias istore -keyPwd "$PWD_KS" \
  -appCertFile "$CERTS"/cert_*.cer -profileFile "$CERTS"/profile_*.p7b \
  -inFile "$OUT" -outFile "${OUT%.app}-signed.app" 2>&1 | tail -3

echo "=== 验签 ==="
python3 /Users/chen/istore-build/harmony_pkg_verify.py "${OUT%.app}-signed.app" --expect-type release 2>&1 | tail -10
ls -lh "${OUT%.app}-signed.app"
