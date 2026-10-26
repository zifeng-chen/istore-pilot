#!/bin/sh
# 收敛 AGH 管理界面到局域网 IPv4，避免 IPv6 公网可达
set -u
YAML=/etc/AdGuardHome.yaml

[ -f "${YAML}.bak-addr" ] || cp "$YAML" "${YAML}.bak-addr"

python3 - "$YAML" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s2 = re.sub(r"(?m)^(\s+address:)\s*0\.0\.0\.0:3000\s*$", r"\1 192.168.100.1:3000", s)
open(p, "w", encoding="utf-8").write(s2)
print("changed:", s != s2)
PY

grep -n "address:" "$YAML" | head -3

/etc/init.d/AdGuardHome restart >/dev/null 2>&1
sleep 7

echo "=== 监听状态 ==="
netstat -lntp 2>/dev/null | grep 3000
echo "(只有 192.168.100.1:3000 才对，出现 :::3000 就是还在公网)"
echo
echo "=== 局域网 IPv4 可达 ==="
curl -s -o /dev/null -w "http=%{http_code}\n" -m 6 http://192.168.100.1:3000/
echo
echo "=== DNS 仍正常 ==="
nslookup -port=5353 doubleclick.net 127.0.0.1 2>/dev/null | grep "Address:" | tail -1
echo
echo "=== 服务状态 ==="
/etc/init.d/AdGuardHome status 2>&1 | tail -2
