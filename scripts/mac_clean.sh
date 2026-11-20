#!/bin/bash
# Mac 构建机清理：删掉可再生的构建产物与临时文件，腾磁盘。
#
# 用法：
#   bash mac_clean.sh              # 默认：项目构建产物 + /tmp 生成物
#   bash mac_clean.sh --deep       # 再加 gradle / Xcode / oh_modules 全局缓存
#   bash mac_clean.sh --dry        # 只列出会删什么、各占多少
#
# 永远不碰：签名材料（.certs / build-profile.json5 / ~/.ohos/config）、
#          模拟器镜像（~/.Huawei）、源码、.env
set -o pipefail
DEEP=0
DRY=0
for a in "$@"; do
  case "$a" in
    --deep) DEEP=1 ;;
    --dry) DRY=1 ;;
  esac
done

PROJ=${PROJ:-$HOME/istore-build/harmony}
ANDROID=${ANDROID:-$HOME/istore-build/android}
IOS=${IOS:-$HOME/istore-build/ios}

remove() {
  for p in "$@"; do
    [ -e "$p" ] || continue
    sz=$(du -sh "$p" 2>/dev/null | cut -f1)
    if [ "$DRY" = "1" ]; then
      echo "  [dry] $sz  $p"
    else
      rm -rf "$p" && echo "  - $sz  $p"
    fi
  done
}

echo "清理前：$(df -h / | awk 'NR==2{print $4" 可用 / "$3" 已用"}')"

echo "项目构建产物"
remove "$PROJ/entry/build" "$PROJ/build" "$PROJ/.hvigor" \
       "$ANDROID/.gradle" "$ANDROID/app/build" "$IOS/build" \
       "$PROJ/oh_modules" "$ANDROID/.idea" 2>/dev/null

echo "临时文件（录屏帧、打包中间件、历史产物）"
remove /tmp/vid.tar /tmp/vid2.tar /tmp/vid3.tar /tmp/vid4.tar \
       /tmp/vid5.tar /tmp/vid6.tar /tmp/vid7.tar /tmp/vid8.tar \
       /tmp/vidframes /tmp/vf /tmp/vf2 /tmp/vf3 /tmp/vf4 /tmp/vf5 /tmp/vf6 /tmp/vf7 /tmp/vf8 \
       /tmp/appkit /tmp/l.json /tmp/l2.json /tmp/*.app /tmp/demo*.mp4 /tmp/tiny.mp4 \
       /tmp/selftest 2>/dev/null
# 设备端留的帧
for d in /data/local/tmp; do :; done

if [ "$DEEP" = "1" ]; then
  echo "全局缓存（--deep）"
  remove "$HOME/.gradle/caches" "$HOME/Library/Developer/Xcode/DerivedData" \
         "$HOME/Library/Caches/Huawei" 2>/dev/null
fi

# 设备端（模拟器/真机）的临时帧也顺手清掉
if command -v hdc >/dev/null 2>&1; then
  for t in $(hdc list targets 2>/dev/null | tr -d '\r' | grep -v -E '^\[Empty\]|^$'); do
    hdc -t "$t" shell 'rm -rf /data/local/tmp/vid /data/local/tmp/*.tar' >/dev/null 2>&1 \
      && echo "  - 设备 $t 的 /data/local/tmp"
  done
fi

echo "清理后：$(df -h / | awk 'NR==2{print $4" 可用 / "$3" 已用"}')"
echo
echo "保留：.certs / build-profile.json5 / ~/.ohos/config / ~/.Huawei（模拟器镜像）/ .env"
