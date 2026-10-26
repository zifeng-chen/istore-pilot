#!/bin/sh
# 下载 AdGuard Home 本体（x86_64），放到插件约定的路径
set -e

URL="https://static.adtidy.org/adguardhome/release/AdGuardHome_linux_amd64.tar.gz"
TMP=/tmp/agh/dl
mkdir -p "$TMP"

echo "=== 下载本体 ==="
if [ ! -s "$TMP/AdGuardHome_linux_amd64.tar.gz" ]; then
    curl -fL --retry 2 -m 300 -o "$TMP/AdGuardHome_linux_amd64.tar.gz" "$URL"
fi
ls -lh "$TMP/AdGuardHome_linux_amd64.tar.gz"

echo "=== 解包 ==="
cd "$TMP"
tar xzf AdGuardHome_linux_amd64.tar.gz
ls -l AdGuardHome/AdGuardHome

echo "=== 安装到 /usr/bin/AdGuardHome ==="
mkdir -p /usr/bin/AdGuardHome
cp -f AdGuardHome/AdGuardHome /usr/bin/AdGuardHome/AdGuardHome
chmod 755 /usr/bin/AdGuardHome/AdGuardHome
/usr/bin/AdGuardHome/AdGuardHome --version
