#!/bin/sh
# 安装 adguardhome 插件 + 下载本体，装前先备份 DNS 配置
set -e

BK=/root/agh-backup-$(date +%Y%m%d-%H%M%S)
mkdir -p "$BK"
uci show dhcp > "$BK/dhcp.uci"
uci show AdGuardHome > "$BK/adguardhome.uci" 2>/dev/null || true
cp /etc/config/dhcp "$BK/dhcp" 2>/dev/null || true
echo "备份到 $BK"
ls "$BK"

echo "=== 安装插件 ==="
opkg install /tmp/agh/luci-app-adguardhome.ipk /tmp/agh/zh-cn.ipk 2>&1 | tail -15

echo "=== 安装结果 ==="
opkg list-installed 2>/dev/null | grep -i adguard
ls -l /etc/init.d/AdGuardHome 2>/dev/null
ls -l /etc/config/AdGuardHome 2>/dev/null
