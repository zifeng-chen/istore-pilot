#!/bin/sh
# 把工作目录从 tmpfs 迁到 /etc（overlay 持久化），并用 procd 托管
set -e

echo "=== 停止所有实例 ==="
pkill -f "/usr/bin/AdGuardHome/AdGuardHome" 2>/dev/null || true
sleep 3
ps w | grep -c "[A]dGuardHome" || true

echo "=== 迁移数据到持久目录 ==="
mkdir -p /etc/AdGuardHome
if [ -d /tmp/AdGuardHome/data ] && [ ! -d /etc/AdGuardHome/data ]; then
    cp -a /tmp/AdGuardHome/data /etc/AdGuardHome/data
    echo "已复制规则缓存 $(du -sh /etc/AdGuardHome/data | cut -f1)"
else
    echo "无需迁移"
fi

echo "=== 改 workdir ==="
uci set AdGuardHome.AdGuardHome.workdir=/etc/AdGuardHome
uci commit AdGuardHome
uci get AdGuardHome.AdGuardHome.workdir

echo "=== 启动服务 ==="
/etc/init.d/AdGuardHome start 2>&1 | tail -3
sleep 5

echo "=== 服务状态 ==="
/etc/init.d/AdGuardHome status 2>&1 | head -3
echo

echo "=== 进程 ==="
ps w | grep "[A]dGuardHome" | head -3

echo "=== 监听 ==="
netstat -lntp 2>/dev/null | grep -E ":5353 " || echo "5353 未监听！"

echo "=== 解析自检 ==="
for d in doubleclick.net baidu.com; do
    r=$(nslookup -port=5353 "$d" 127.0.0.1 2>/dev/null | grep "Address:" | tail -1 | awk "{print \$NF}")
    echo "$d -> $r"
done

echo "=== 开机自启 ==="
ls -l /etc/rc.d/ | grep -i adguard || echo "未设置自启"
