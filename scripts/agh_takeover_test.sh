#!/bin/sh
# 接管测试：接管 -> 验证 -> 无论成败都回滚 -> 验证恢复
# 通过 IP + Agent 操作，不依赖 DNS，所以即使 DNS 中断也能远程救回

TOK=$(curl -s -X POST http://192.168.100.1:8443/api/v1/login \
    -H "Content-Type: application/json" -d "{\"password\":\"${AGH_PW:?请先设置 AGH_PW}\"}" \
    | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p')
if [ -z "$TOK" ]; then echo "登录失败，中止"; exit 1; fi

api_post() {
    curl -s -m 120 -X POST "http://192.168.100.1:8443/api/v1$1" \
        -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" -d '{}'
}

dnstest() {
    nslookup "$1" 127.0.0.1 2>/dev/null | grep "Address:" | tail -1 | awk '{print $NF}'
}

who53() {
    netstat -lnpt 2>/dev/null | grep ":53 " | awk '{print $NF}' | sort -u | tr '\n' ' '
}

rollback() {
    echo "--- 回滚 ---"
    api_post /adblock/release >/dev/null 2>&1
    sleep 7
    echo -n "dnsmasq 端口: "; uci get dhcp.@dnsmasq[0].port 2>/dev/null || echo "53(默认)"
    echo -n "53 上的进程: "; who53
    echo "doubleclick.net -> $(dnstest doubleclick.net)"
}

echo "=== 接管前 ==="
echo -n "dnsmasq 端口: "; uci get dhcp.@dnsmasq[0].port 2>/dev/null || echo "53(默认)"
echo -n "53 上的进程: "; who53
echo "doubleclick.net -> $(dnstest doubleclick.net)  [接管前应正常解析]"

echo
echo "=== 执行接管 ==="
api_post /adblock/takeover
echo
sleep 9

echo
echo "=== 接管后 ==="
echo -n "dnsmasq 端口: "; uci get dhcp.@dnsmasq[0].port 2>/dev/null || echo "未设置"
echo -n "53 上的进程: "; who53
echo "doubleclick.net -> $(dnstest doubleclick.net)  [期望 0.0.0.0]"
echo "baidu.com      -> $(dnstest baidu.com)  [期望 198.18.x.x]"

echo
echo "=== 判定并回滚 ==="
if who53 | grep -qi adguard; then
    echo "结果：接管成功，53 已由 AGH 承接"
else
    echo "结果：接管失败，53 未由 AGH 承接"
fi

rollback

echo
echo "=== 最终确认（应恢复原状）==="
echo -n "53 上的进程: "; who53
echo "baidu.com -> $(dnstest baidu.com)"
echo -n "AGH 监听: "; netstat -lnt 2>/dev/null | grep ":5353 " | wc -l
echo -n "规则数: "; curl -s -u "admin:${AGH_PW:?请先设置 AGH_PW}" http://127.0.0.1:3000/control/filtering/status \
    | sed -n 's/.*"rules_count":\([0-9]*\).*anti-AD[^}]*/\1/p' | head -1
