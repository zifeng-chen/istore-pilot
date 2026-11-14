#!/bin/bash
# 鸿蒙本地自检（替代「云测试」的最小闭环）：
#   冷启动耗时 / 四页签遍历 / 弹层 / JS 异常与崩溃扫描 / 内存 / 点击热区
# 用法：bash harmony_selftest.sh <hap 路径>
H=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
HAP="${1:-/Users/chen/istore-build/harmony/entry/build/default/outputs/default/entry-default-signed.hap}"
B=com.izifeng.www.istorepilot
T=/tmp/selftest
rm -rf "$T"; mkdir -p "$T"

ms() { python3 -c 'import time;print(int(time.time()*1000))'; }

echo "### 1. 安装"
$H install -r "$HAP" 2>&1 | tail -1

echo "### 2. 冷启动"
$H shell aa force-stop $B >/dev/null 2>&1
$H shell hilog -r >/dev/null 2>&1
T0=$(ms)
$H shell aa start -a EntryAbility -b $B >/dev/null 2>&1
READY=0
for i in $(seq 1 40); do
  $H shell uitest dumpLayout -p /data/local/tmp/st.json >/dev/null 2>&1
  $H file recv /data/local/tmp/st.json "$T/l.json" >/dev/null 2>&1
  if grep -q "连接你的 iStoreOS 路由器\|演示" "$T/l.json" 2>/dev/null; then READY=$(ms); break; fi
  sleep 0.25
done
echo "cold_start_ms=$(( ${READY:-0} - T0 ))"

echo "### 3. 进演示模式"
# 勾协议 + 点「没有路由器？先看看演示」
$H shell uitest uiInput click 160 1598 >/dev/null 2>&1; sleep 1
$H shell uitest uiInput click 1105 2046 >/dev/null 2>&1; sleep 4
$H shell snapshot_display -f /data/local/tmp/st_home.jpeg >/dev/null 2>&1
$H file recv /data/local/tmp/st_home.jpeg "$T/home.jpeg" >/dev/null 2>&1

echo "### 4. 遍历四个页签"
i=0
for X in 175 800 1410 2030; do
  $H shell uitest uiInput click $X 2185 >/dev/null 2>&1
  sleep 2
  $H shell snapshot_display -f /data/local/tmp/st_t$i.jpeg >/dev/null 2>&1
  $H file recv /data/local/tmp/st_t$i.jpeg "$T/tab$i.jpeg" >/dev/null 2>&1
  $H shell uitest dumpLayout -p /data/local/tmp/st_t$i.json >/dev/null 2>&1
  $H file recv /data/local/tmp/st_t$i.json "$T/tab$i.json" >/dev/null 2>&1
  i=$((i+1))
done
echo "tabs=4"

echo "### 5. 二级页（设置 → 内网网关弹层 / 代理 → 订阅）"
$H shell uitest uiInput click 2030 2185 >/dev/null 2>&1; sleep 2
$H shell uitest uiInput click 700 1611 >/dev/null 2>&1; sleep 2
$H shell snapshot_display -f /data/local/tmp/st_dlg.jpeg >/dev/null 2>&1
$H file recv /data/local/tmp/st_dlg.jpeg "$T/dialog.jpeg" >/dev/null 2>&1
$H shell uitest uiInput click 1950 300 >/dev/null 2>&1; sleep 1   # 关掉弹层
$H shell uitest uiInput click 1410 2185 >/dev/null 2>&1; sleep 2
$H shell uitest uiInput click 1990 738 >/dev/null 2>&1; sleep 3    # 订阅入口
$H shell snapshot_display -f /data/local/tmp/st_sub.jpeg >/dev/null 2>&1
$H file recv /data/local/tmp/st_sub.jpeg "$T/sub.jpeg" >/dev/null 2>&1

echo "### 6. 日志扫描（异常 / 崩溃）"
$H shell hilog -d > "$T/hilog.txt" 2>/dev/null
echo "log_lines=$(wc -l < "$T/hilog.txt")"
echo "js_error=$(grep -c -E 'JsError|TypeError|ReferenceError|SyntaxError|Uncaught' "$T/hilog.txt")"
echo "exception=$(grep -c -E 'Fault|Crash|SIGSEGV|AppFreeze|ANR' "$T/hilog.txt")"
grep -E 'JsError|TypeError|ReferenceError|SyntaxError|Uncaught|AppFreeze|SIGSEGV' "$T/hilog.txt" | head -8

echo "### 7. 内存"
PID=$($H shell pidof $B 2>/dev/null | tr -d '\r\n ')
echo "pid=$PID"
$H shell "hidumper --mem $PID" 2>/dev/null | grep -E "Pss|Total" | head -3

echo "### 8. 点击热区（<44vp 的可点节点）"
python3 - "$T" <<'PY'
import json, os, sys
t = sys.argv[1]
DP = 3.125   # 2210 / 706vp ≈ 3.13，按 3.125 折算
small = []
for n in range(4):
    p = os.path.join(t, "tab%d.json" % n)
    if not os.path.exists(p):
        continue
    def walk(node):
        a = node.get("attributes", {})
        if a.get("clickable") == "true" and a.get("bounds"):
            b = a["bounds"].replace("[", " ").replace("]", " ").replace(",", " ").split()
            if len(b) == 4:
                h = (float(b[3]) - float(b[1])) / DP
                w = (float(b[2]) - float(b[0])) / DP
                if h < 44 or w < 44:
                    small.append((round(w), round(h), (a.get("text") or a.get("type"))[:18]))
        for c in node.get("children", []):
            walk(c)
    walk(json.load(open(p, encoding="utf-8")))
print("small_targets=%d" % len(small))
for s in small[:10]:
    print("  %svp x %svp  %s" % (s[0], s[1], s[2]))
PY

echo "### 9. 产物"
ls -1 "$T" | tr '\n' ' '
echo
