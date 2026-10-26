#!/bin/sh
# 配置 anti-AD 过滤列表并刷新
# 用法：AGH_PW='管理口令' sh scripts/agh_rules.sh
AUTH="-u admin:${AGH_PW:?请先设置 AGH_PW}"
BASE=http://127.0.0.1:3000/control

echo "=== 清空测试规则 ==="
curl -s $AUTH -X POST "$BASE/filtering/set_rules" \
    -H "Content-Type: application/json" -d '{"rules":[]}'
echo " done"

echo "=== 添加 anti-AD ==="
curl -s $AUTH -X POST "$BASE/filtering/add_url" \
    -H "Content-Type: application/json" \
    -d '{"name":"anti-AD 国内广告规则","url":"https://anti-ad.net/adguard.txt","whitelist":false}'
echo " done"

echo "=== 触发更新（2.3MB，稍等）==="
curl -s $AUTH -X POST "$BASE/filtering/refresh" \
    -H "Content-Type: application/json" -d '{"whitelist":false}'
echo " done"

echo "=== 列表状态 ==="
sleep 3
curl -s $AUTH "$BASE/filtering/status" | head -c 1200
echo
