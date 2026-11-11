#!/bin/bash
# 批量上传截图到 AGC OBS，输出 fileName 与 objectId 的对应关系
# 注意：CLI 只从「当前目录」读 .env，必须 cd 到 harmony 才能拿到凭证
set -u
cd /Users/chen/istore-build/harmony || exit 1

APPID=6917621503870113751
CLI=$HOME/istore-tools/connect-api-cli.js
SHOTS=/Users/chen/istore-build/shots
OUT=$SHOTS/objectids.txt
: > "$OUT"

for f in overview devices proxy adblock dark settings; do
  echo "--- uploading $f.png ---"
  resp=$(node "$CLI" upload file -a "$APPID" -f "$SHOTS/$f.png" 2>&1)
  oid=$(printf '%s' "$resp" | python3 -c "
import sys, json
raw = sys.stdin.read()
start = raw.find('{')
if start < 0:
    print(''); raise SystemExit
try:
    d = json.loads(raw[start:])
except Exception:
    print(''); raise SystemExit
print(d.get('objectId') or '')
")
  if [ -z "$oid" ]; then
    echo "  FAILED"
    printf '%s\n' "$resp" | tail -3
  else
    echo "  ok $oid"
    echo "$f.png|$oid" >> "$OUT"
  fi
done

echo "=== objectids.txt ==="
cat "$OUT"
