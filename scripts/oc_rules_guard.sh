#!/bin/sh
# 给 OpenClash 注入两条 DIRECT 规则（走官方 custom_rules 机制），
# 并自带「超时验收 + 自动回滚 + 连 uci 开关一起还原」。
#
# 为什么必须这么做：
#   openclash_custom_rules.list 是给 yml_rules_change.sh 做 YAML 合并的，
#   格式必须是 rules: 列表；而且 openclash.config.enable_custom_clash_rules
#   这个开关默认是 0，不打开文件压根不会被读。之前只追加裸行 = 白改。
#
# 回滚不依赖远程会话：用 setsid 脱离，SSH / App 断了它照样跑。
#
# 用法：sh oc_rules_guard.sh apply
# 日志：/tmp/oc-rules-guard.log
# 原始备份：/etc/openclash/custom/openclash_custom_rules.list.bak（21:00 的模板原样）

FILE=/etc/openclash/custom/openclash_custom_rules.list
LOG=/tmp/oc-rules-guard.log
BAK=$FILE.bak
TMP=/tmp/oc_rules_new.yaml

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

probe() {
    ping -c1 -W3 223.5.5.5 >/dev/null 2>&1 || return 1
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 https://www.baidu.com)
    case "$code" in
        2*|3*) return 0 ;;
        *) return 1 ;;
    esac
}

wait_ok() {
    i=0
    while [ "$i" -lt "$1" ]; do
        probe && return 0
        i=$((i + 1))
        sleep 10
    done
    return 1
}

rollback() {
    log "开始回滚：还原文件 + 关掉开关"
    cp "$BAK" "$FILE"
    uci set openclash.config.enable_custom_clash_rules='0'
    uci commit openclash
    /etc/init.d/openclash restart >/dev/null 2>&1
    sleep 60
    if wait_ok 6; then
        log "回滚完成：网络已恢复，规则与开关都回到改动前"
    else
        log "回滚后仍不通，需要人工介入；文件与开关已还原"
    fi
}

guard() {
    log "守护启动：等 80 秒让内核重启完"
    sleep 80
    if wait_ok 6; then
        log "验收通过：代理链路正常，保留新规则"
        return 0
    fi
    log "验收失败：网络不通"
    rollback
}

apply() {
    [ -f "$BAK" ] || { log "缺少原始备份 $BAK，放弃"; exit 1; }

    cat > "$TMP" <<'YAML'
# OpenClash 自定义规则（由 istore-pilot 写入，插入在订阅规则顶部）
# 目的：ug.link / ugreen.com 在国内，走代理既慢又经常超时，直接放行
rules:
  - DOMAIN-SUFFIX,ug.link,DIRECT
  - DOMAIN-SUFFIX,ugreen.com,DIRECT
YAML

    cp "$TMP" "$FILE" || { log "写规则文件失败"; exit 1; }
    log "已写入 YAML 规则（2 条）"

    uci set openclash.config.enable_custom_clash_rules='1'
    uci commit openclash
    log "已打开 enable_custom_clash_rules"

    setsid /bin/sh "$0" guard >/dev/null 2>&1 &
    log "守护已脱离会话启动"
    /etc/init.d/openclash restart >/dev/null 2>&1
    log "内核重启已发起"
}

case "${1:-}" in
    apply) apply ;;
    guard) guard ;;
    *) echo "usage: $0 apply"; exit 1 ;;
esac
