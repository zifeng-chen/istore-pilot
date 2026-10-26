#!/bin/sh
# 启动 AdGuard Home 实验实例（5353，不碰主链路）
mkdir -p /tmp/AdGuardHome

# 先确认端口没被占
echo "=== 端口预检 ==="
netstat -lnt 2>/dev/null | grep -E ":3000 |:5353 " && echo "警告：端口已被占用" || echo "3000/5353 空闲"

echo "=== 启动 ==="
pkill -f "AdGuardHome -c /etc/AdGuardHome.yaml" 2>/dev/null
sleep 1
cd /tmp
nohup /usr/bin/AdGuardHome/AdGuardHome -c /etc/AdGuardHome.yaml \
    --work-dir /tmp/AdGuardHome --no-check-update \
    > /tmp/agh-run.log 2>&1 &
sleep 4

echo "=== 进程 ==="
ps w | grep "[A]dGuardHome" | head -3
echo "=== 监听 ==="
netstat -lntp 2>/dev/null | grep -E "AdGuard|:3000|:5353"
echo "=== 启动日志 ==="
tail -12 /tmp/agh-run.log
