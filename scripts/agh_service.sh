#!/bin/sh
# 把 AGH 配成 procd 服务（DNS 仍只用 5353，不影响主链路）
set -e

echo "=== 停掉手动实例 ==="
pkill -f "AdGuardHome -c /etc/AdGuardHome.yaml" 2>/dev/null || true
sleep 2

echo "=== 记录当前 dnsmasq 端口（切前基线）==="
uci get dhcp.@dnsmasq[0].port 2>/dev/null || echo "(默认 53)"
uci get dhcp.@dnsmasq[0].server 2>/dev/null || echo "(无)"

echo "=== 配置 uci ==="
uci set AdGuardHome.AdGuardHome.enabled=1
uci set AdGuardHome.AdGuardHome.configpath=/etc/AdGuardHome.yaml
uci set AdGuardHome.AdGuardHome.workdir=/tmp/AdGuardHome
uci set AdGuardHome.AdGuardHome.binpath=/usr/bin/AdGuardHome/AdGuardHome
uci set AdGuardHome.AdGuardHome.httpport=3000
uci set AdGuardHome.AdGuardHome.redirect=none
uci commit AdGuardHome
/etc/init.d/AdGuardHome enable

echo "=== 启动 ==="
/etc/init.d/AdGuardHome start 2>&1 | tail -5
sleep 4

echo "=== 校验：dnsmasq 端口没被动 ==="
echo -n "dnsmasq port: "; uci get dhcp.@dnsmasq[0].port 2>/dev/null || echo "53(默认)"
echo -n "dnsmasq server: "; uci get dhcp.@dnsmasq[0].server 2>/dev/null || echo "(无)"

echo "=== 监听状态 ==="
netstat -lntp 2>/dev/null | grep -E ":53 |:5353 |:3000 "

echo "=== 配置有没有被改 ==="
grep -A3 "^dns:" /etc/AdGuardHome.yaml | head -8
echo -n "规则数: "; grep -c "" /tmp/AdGuardHome/data/filters/*.txt 2>/dev/null | awk -F: "{s+=\$2} END{print s+0}"

echo "=== 解析自检 ==="
r=$(nslookup -port=5353 doubleclick.net 127.0.0.1 2>/dev/null | grep "Address:" | tail -1 | awk "{print \$NF}")
echo "doubleclick.net -> $r (期望 0.0.0.0)"
r2=$(nslookup -port=5353 baidu.com 127.0.0.1 2>/dev/null | grep "Address:" | tail -1 | awk "{print \$NF}")
echo "baidu.com -> $r2 (期望 198.18.x.x)"
