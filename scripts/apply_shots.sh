#!/bin/bash
# 上传指定目录的截图并按 deviceType 绑定到一个或多个设备档
# 用法: bash apply_shots.sh <deviceType> <dir> [showType]
# 例:   bash apply_shots.sh 4 phone 0
set -u
cd /Users/chen/istore-build/harmony || exit 1

APPID=6917621503870113751
CLI=$HOME/istore-tools/connect-api-cli.js
DT=${1:?need deviceType}
DIR=${2:?need dir name}
SHOW=${3:-0}
SHOTS=/Users/chen/istore-build/shots/$DIR
OUT=/tmp/oids_${DIR}.txt
: > "$OUT"

for f in overview devices proxy adblock dark settings; do
  [ -f "$SHOTS/$f.png" ] || { echo "  skip $f.png (missing)"; continue; }
  resp=$(node "$CLI" upload file -a "$APPID" -f "$SHOTS/$f.png" 2>&1)
  oid=$(printf '%s' "$resp" | python3 -c "
import sys, json
raw = sys.stdin.read(); i = raw.find('{')
if i < 0: print(''); raise SystemExit
try: d = json.loads(raw[i:])
except Exception: print(''); raise SystemExit
print(d.get('objectId') or '')
")
  if [ -z "$oid" ]; then
    echo "  FAIL $f"
  else
    echo "  ok $f -> $oid"
    echo "$oid" >> "$OUT"
  fi
done

echo "=== 绑定 deviceType=$DT showType=$SHOW （$(wc -l < "$OUT" | tr -d ' ') 张）==="
python3 - "$DT" "$SHOW" "$OUT" <<'PY'
import json, os, subprocess, sys

dt = int(sys.argv[1]); show = int(sys.argv[2]); path = sys.argv[3]
oids = [l.strip() for l in open(path) if l.strip()]
if not oids:
    print('没有可绑定的 objectId'); raise SystemExit(1)

body = {'screenShotList': [{'lang': 'zh-CN', 'fileInfoList': [
    {'deviceType': dt, 'showType': show, 'objectIdList': oids}
]}]}
open('/tmp/shots_bind.json', 'w', encoding='utf-8').write(json.dumps(body, ensure_ascii=False))
r = subprocess.run(['node', os.path.expanduser('~/istore-tools/connect-api-cli.js'),
                    'publish', 'file-info-update', '-a', '6917621503870113751',
                    '--body', '/tmp/shots_bind.json'], capture_output=True, text=True)
print((r.stdout + r.stderr)[-700:])
PY
