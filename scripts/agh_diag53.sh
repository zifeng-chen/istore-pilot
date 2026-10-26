#!/bin/sh
# 诊断：AGH 能否绑定 53
restore() {
    echo "--- 恢复 ---"
    uci set dhcp.@dnsmasq[0].port=53
    uci commit dhcp
    sed -i 's/^  port: 53$/  port: 5353/' /etc/AdGuardHome.yaml
    /etc/init.d/dnsmasq restart >/dev/null 2>&1
    sleep 2
    echo -n "dnsmasq: "; netstat -lnpt 2>/dev/null | grep ":53 " | awk '{print $NF}' | sort -u | tr '\n' ' '
    echo
}
trap restore EXIT INT TERM

echo "=== 1. 让 dnsmasq 让出 53 ==="
uci set dhcp.@dnsmasq[0].port=0
uci commit dhcp
/etc/init.d/dnsmasq restart 2>&1 | tail -2
sleep 4
echo -n "53 上的进程（应为空）: "; netstat -lnpt 2>/dev/null | grep ":53 " | awk '{print $NF}' | sort -u | tr '\n' ' '
echo

echo "=== 2. 改 AGH 配置到 0.0.0.0:53 ==="
cp /etc/AdGuardHome.yaml /root/agh-yaml.bak
python3 - <<'PY'
import re
p = "/etc/AdGuardHome.yaml"
t = open(p, encoding="utf-8").read()
lines = t.splitlines()
out, in_dns, i = [], False, 0
while i < len(lines):
    ln = lines[i]
    if re.match(r"^dns:\s*$", ln):
        in_dns = True; out.append(ln); i += 1; continue
    if in_dns and re.match(r"^\S", ln):
        in_dns = False
    if in_dns and re.match(r"^\s{2}port:\s*\d+", ln):
        out.append("  port: 53"); i += 1; continue
    if in_dns and re.match(r"^\s{2}bind_hosts:\s*$", ln):
        out.append("  bind_hosts:")
        j = i + 1
        while j < len(lines) and re.match(r"^\s{4}-\s*\S+", lines[j]):
            j += 1
        out.append("    - 0.0.0.0")
        out.append("    - ::")
        i = j; continue
    out.append(ln); i += 1
open(p, "w", encoding="utf-8").write("\n".join(out) + "\n")
print("已改写")
PY
awk "/^dns:/{f=1} f&&c<5{print; c++}" /etc/AdGuardHome.yaml

echo "=== 3. 重启 AGH 并抓日志 ==="
/etc/init.d/AdGuardHome restart 2>&1 | tail -2
sleep 6
echo -n "53 上的进程: "; netstat -lnpt 2>/dev/null | grep ":53 " | awk '{print $NF}' | sort -u | tr '\n' ' '
echo
echo "--- 日志尾部 ---"
tail -12 /etc/AdGuardHome/AdGuardHome.log 2>/dev/null | grep -iE "error|fail|listen|53|bind" | head -10

echo "=== 4. 解析测试 ==="
nslookup doubleclick.net 127.0.0.1 2>&1 | tail -3
