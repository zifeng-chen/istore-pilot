#!/bin/bash
# 在模拟器上录「从启动到走完四个页签」的演示片。
# 设备没有 screenrecord、SSH 又拿不到屏幕录制权限 → 用 snapshot_display 连拍
# JPEG（约 4-5 fps），ffmpeg 合成 mp4。
#
# 所有点击坐标都从 uitest dumpLayout 里现算，不写死 —— 换机型/换分辨率也能跑。
# 用法：bash record_demo_mac.sh /tmp/demo.mp4
set -o pipefail
H=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
# 有多台设备/残留 target 时必须 -t，否则 hdc 报 "need connect-key"
T=$($H list targets 2>/dev/null | tr -d '\r' | grep -v -E '^\[Empty\]|^$' | tail -1)
[ -n "$T" ] && H="$H -t $T"
echo "target: $T"
B=com.izifeng.www.istorepilot
OUT=${1:-/tmp/demo.mp4}
DIR=/data/local/tmp/vid
LOCAL=/tmp/vidframes
FRAMES=${FRAMES:-170}

# 从最新 dump 里找节点中心点：$1=文本（@toggle 表示勾选框）
tap() {
  $H shell uitest dumpLayout -p /data/local/tmp/l.json >/dev/null 2>&1
  $H file recv /data/local/tmp/l.json /tmp/l.json >/dev/null 2>&1
  XY=$(python3 - /tmp/l.json "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
want = sys.argv[2]
hit = []
def walk(n):
    a = n.get('attributes', {})
    ok = (a.get('type') == 'Toggle') if want == '@toggle' else (a.get('text') == want)
    if ok and a.get('bounds') and not hit:
        b = a['bounds'].replace('[', ' ').replace(']', ' ').replace(',', ' ').split()
        hit.append("%d %d" % ((float(b[0]) + float(b[2])) / 2, (float(b[1]) + float(b[3])) / 2))
        return
    for c in n.get('children', []):
        walk(c)
walk(d)
print(hit[0] if hit else "")
PY
)
  if [ -z "$XY" ]; then echo "  !! 找不到「$1」，跳过"; return 1; fi
  echo "  tap $1 -> $XY"
  $H shell uitest uiInput click $XY >/dev/null 2>&1
  return 0
}

$H shell "rm -rf $DIR; mkdir -p $DIR" >/dev/null 2>&1
$H shell bm clean -n $B -d >/dev/null 2>&1
$H shell aa force-stop $B >/dev/null 2>&1
sleep 1

echo "=== 开拍（$FRAMES 帧）==="
$H shell "for i in \$(seq 1 $FRAMES); do snapshot_display -f $DIR/f\$i.jpeg >/dev/null 2>&1; done" &
CAP=$!

sleep 1
$H shell aa start -a EntryAbility -b $B >/dev/null 2>&1
sleep 6
tap '@toggle'
sleep 1
tap '没有路由器？先看看演示 →'
sleep 6
for T in '概览' '设备' '代理' '设置'; do
  tap "$T"; sleep 4
done
tap '内网网关'; sleep 4
tap '关闭'; sleep 1
tap '设备'; sleep 4
wait $CAP

echo "=== 取帧 ==="
$H shell "cd $DIR && tar cf /data/local/tmp/vid.tar f*.jpeg" >/dev/null 2>&1
rm -rf "$LOCAL"; mkdir -p "$LOCAL"
$H file recv /data/local/tmp/vid.tar /tmp/vid.tar >/dev/null 2>&1
tar xf /tmp/vid.tar -C "$LOCAL"
N=$(ls "$LOCAL"/f*.jpeg 2>/dev/null | wc -l | tr -d ' ')
echo "拿到 $N 帧"

echo "=== 合成 ==="
FPS=$(python3 -c "print(max(3, round($N/42, 1)))")
ffmpeg -y -framerate "$FPS" -pattern_type glob -i "$LOCAL/f*.jpeg" \
  -vf "scale=720:-2" -c:v libx264 -pix_fmt yuv420p -crf 23 "$OUT" 2>&1 | tail -2
ls -lh "$OUT"
python3 -c "import subprocess;print('时长',subprocess.run(['ffprobe','-v','error','-show_entries','format=duration','-of','csv=p=0','$OUT'],capture_output=True,text=True).stdout.strip(),'秒')"

# 帧和 tar 都是中间产物，合成完就删，别堆在 /tmp
rm -rf "$LOCAL" /tmp/vid.tar 2>/dev/null
$H shell "rm -rf $DIR /data/local/tmp/vid.tar" >/dev/null 2>&1
echo "已清：$LOCAL 与设备端 $DIR"
