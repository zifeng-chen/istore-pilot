#!/usr/bin/env python3
"""把 Agent 与 LuCI 界面打成一个**自解压 .run 安装包**。

产出：
    dist/istore-pilot_<版本>-<修订>.run

装法（路由器上，一行搞定）：
    sh istore-pilot_0.1.2-10.run

为什么要 .run 而不是只用 ipk：
    ipk 必须经过 opkg，遇到「没有网络装不上依赖」「opkg 版本不一致」
    「软件包页面传不上去」就卡住了。.run 是纯 shell + tar.gz 自解压，
    路由器上只要有 sh / gzip / tar 就能装，不碰包管理器数据库，
    也就不会出现「包管理器认为已装、文件却被覆盖」的错位状态。

    这一条在 iStoreOS 25.12 之后更重要：那版把 opkg 换成了 apk，旧的 ipk
    在 25.12 上根本装不上，而 .run 不受影响。所以安装器里所有装包动作都
    按当前系统的包管理器走（opkg / apk 双分支），缺依赖时还会自动补装。

包体结构：
    [sh 安装器头部][tar.gz 载荷]        偏移量写在头部，安装器自己 tail 出来解压
    载荷 = 与 ipk 完全相同的文件树（直接复用 build_ipk.stage_data）

安全边界（写死在安装器里）：
    - 只写 程序目录 / init.d / LuCI / www，**绝不改 network、firewall、dhcp、dnsmasq**
    - /etc/config/istore-agent 已存在就保留原样（bind 与端口是用户资产，
      覆盖成默认 0.0.0.0 会把 8443 暴露到公网）
    - 与 opkg 安装互斥：检测到已由 opkg 管理时拒绝执行，除非显式 --force

用法：
    python deploy/build_run.py               # 一次出四份：x86_64 / arm64 / armv7 / all
    python deploy/build_run.py --arch=arm64  # 只出指定架构
    python deploy/build_run.py --no-apk      # 不含 APK，包体小 2.6 MB

四份共享同一个 tar.gz 载荷（内容跟架构无关），只有头部里的 PKG_ARCH 不同。
"""

from __future__ import annotations

import importlib.util
import os
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "dist")


def load_build_ipk():
    """复用 build_ipk 的暂存与权限推断，避免两个包内容不一致。"""
    path = os.path.join(ROOT, "deploy", "build_ipk.py")
    spec = importlib.util.spec_from_file_location("build_ipk", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# ---------------------------------------------------------------- 安装器头部

# 占位符用 @VER@ / @REV@ / __OFFSET__ / __LEN__，避免与 shell 的 $ {} 冲突。
# 注意：下面这段是**逐字节写进 .run** 的，换行必须是 LF，否则路由器上
# 会报 "not found" 之类莫名其妙的错（ash 不认 CRLF 的 shebang 与行尾）。
HEADER = r'''#!/bin/sh
# ============================================================================
#  iStore Pilot  ·  自解压安装包
#  iStoreOS / OpenWrt 路由器端 Agent + LuCI 界面
#
#  这个文件既是安装脚本也是压缩包：前面的 shell 会把自己尾部的 tar.gz
#  tail 出来直接解压，不需要联网，不需要 opkg。
#
#  sh 本文件                 安装或升级（保留现有配置）
#  sh 本文件 --check         只检查环境与依赖，不改任何文件
#  sh 本文件 --no-deps       不自动装依赖（离线/已手工备齐时用）
#  sh 本文件 --force         已用 opkg/apk 装过时，强制改由本包接管
#  sh 本文件 --uninstall     卸载程序，保留 /etc/istore-agent 里的密码
#  sh 本文件 --purge         卸载并清除全部配置与密码
#
#  **不修改任何网络 / 防火墙 / DHCP / DNS 配置**，装完当前网络不受影响。
# ============================================================================

APP_NAME="iStore Pilot"
PKG_VERSION="@VER@"
PKG_REVISION="@REV@"
PKG_ARCH="@ARCH@"
PAYLOAD_OFFSET=__OFFSET__
PAYLOAD_LEN=__LEN__

SELF="$0"

ACTION=install
ASSUME_YES=0
NO_START=0
NO_DEPS=0
FORCE=0
ROOT_DIR=""
CFG_BAK=""
PM=""
PY=""

# ---------------------------------------------------------------- 输出小工具

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
info() { printf '  · %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\n  \033[31m✗ %s\033[0m\n\n' "$*" >&2; exit 1; }

cleanup() { [ -n "$CFG_BAK" ] && rm -f "$CFG_BAK"; }

# ---------------------------------------------------------------- 参数

usage() {
	cat <<EOF

  $APP_NAME $PKG_VERSION-$PKG_REVISION  自解压安装包（$PKG_ARCH）

  用法：sh $SELF [选项]

    (无参数)        安装或升级，保留现有配置
    --check         只检查运行环境与依赖，不做任何改动
    --no-deps       不自动安装缺失的依赖（离线或已手工装好时用）
    --force         已由 opkg / apk 装过时，强制移除包记录并由本包接管
    --uninstall     卸载程序文件，保留密码与配置
    --purge         卸载并删除 /etc/istore-agent 与 /etc/config/istore-agent
    --no-start      装完不启动服务
    -y, --yes       不询问，直接执行
    --root=目录     仅用于测试：把文件装到该目录而不是 /
    -V, --version   显示版本
    -h, --help      显示本帮助

EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--uninstall|uninstall) ACTION=uninstall ;;
		--purge|purge)         ACTION=purge ;;
		--check|check)         ACTION=check ;;
		-V|--version)          ACTION=version ;;
		--force|-f)            FORCE=1 ;;
		--yes|-y)              ASSUME_YES=1 ;;
		--no-start)            NO_START=1 ;;
		--no-deps|--offline)   NO_DEPS=1 ;;
		--root=*)              ROOT_DIR="${1#--root=}" ;;
		-h|--help)             ACTION=help ;;
		*)                     printf '未知参数：%s\n' "$1" >&2; ACTION=help ;;
	esac
	shift
done

# 去掉结尾斜杠；"/" 等价于空（真实根目录）
case "$ROOT_DIR" in
	""|"/") ROOT_DIR="" ;;
	*) ROOT_DIR="${ROOT_DIR%/}" ;;
esac

trap cleanup 0

# ---------------------------------------------------------------- 环境检查

need_root() {
	# --root 指向别处时是测试模式，不需要真 root
	[ -n "$ROOT_DIR" ] && return 0
	[ "$(id -u)" = "0" ] || die "需要 root 权限。请用 root 登录，或前面加 sudo。"
}

find_python() {
	PY=""
	for p in /usr/bin/python3 /usr/local/bin/python3 /opt/bin/python3; do
		[ -x "$p" ] && { PY="$p"; return 0; }
	done
	PY="$(command -v python3 2>/dev/null)"
	[ -n "$PY" ]
}

check_env() {
	local miss=""
	for c in gzip tar; do
		command -v "$c" >/dev/null 2>&1 || miss="$miss $c"
	done
	[ -n "$miss" ] && die "缺少命令：$miss —— 这台设备可能不是 OpenWrt/iStoreOS"

	# python3 不在这里判死：缺了交给依赖检查去装（25.12 起是 apk，
	# 不能再写死 opkg install）。check_env 只保证解包能用。
	find_python || PY=""

	# 包体完整性：文件总长必须等于「偏移 + 载荷长」
	local size expect
	size=$(wc -c < "$SELF" 2>/dev/null | tr -d ' ')
	expect=$((PAYLOAD_OFFSET + PAYLOAD_LEN))
	if [ -n "$size" ] && [ "$size" != "$expect" ]; then
		die "安装包不完整（应为 $expect 字节，实际 $size）。
     多半是下载中断，请重新下载后再试。"
	fi
}

m_arch() {
	uname -m 2>/dev/null | tr 'A-Z' 'a-z'
}

# 载荷是纯 Python，跨架构本来就能跑；这里只做「对号」提示，
# 免得把 x86_64 版发给 ARM 路由器的人时以为装错了
arch_match() {
	[ "$PKG_ARCH" = "all" ] && return 0
	case "$PKG_ARCH:$(m_arch)" in
		x86_64:x86_64|x86_64:amd64|arm64:aarch64|arm64:arm64|armv7:armv7l|armv7:armv7)
			return 0 ;;
	esac
	return 1
}

arch_note() {
	if arch_match; then
		ok "架构匹配：$(m_arch)（本包 $PKG_ARCH 版）"
	else
		warn "本包是 $PKG_ARCH 版，当前设备是 $(m_arch)"
		info "载荷是纯 Python，仍可正常安装；只是包名与设备不符，建议换对应架构的包"
	fi
}

lan_ip() {
	local ip
	# uci 里的 ipaddr 可能带掩码（182.168.101.1/24）。直接拼进 URL 会变成
	# http://182.168.101.1/24:8443 —— 看着像个路径，点进去 404。
	ip=$(uci -q get network.lan.ipaddr 2>/dev/null)
	ip=${ip%%/*}
	[ -n "$ip" ] || ip=$(ip -4 addr show br-lan 2>/dev/null \
		| sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)
	[ -n "$ip" ] || ip="路由器地址"
	printf '%s' "$ip"
}

agent_port() {
	local p
	p=$(uci -q get istore-agent.main.port 2>/dev/null)
	[ -n "$p" ] || p=8443
	printf '%s' "$p"
}

pkg_has_self() {
	# 24.10 及更早：opkg；25.12 起：apk。两个都没有就当作没装过。
	if command -v opkg >/dev/null 2>&1; then
		opkg list-installed 2>/dev/null | grep -q '^luci-app-istore-agent '
		return $?
	fi
	if command -v apk >/dev/null 2>&1; then
		apk info -e luci-app-istore-agent >/dev/null 2>&1
		return $?
	fi
	return 1
}

# ---------------------------------------------------------------- 依赖

# 包管理器：24.10 及更早用 opkg，25.12 起 OpenWrt 换成 apk（Alpine 那套），
# 两者的命令完全不同。所以下面所有装包动作都先看 PM，绝不硬写 opkg。
detect_pm() {
	if command -v apk >/dev/null 2>&1; then
		PM="apk"
	elif command -v opkg >/dev/null 2>&1; then
		PM="opkg"
	else
		PM=""
	fi
}

# 架构归一化。装依赖时包名跨架构一致（包管理器会自己去正确的源取），
# 这个值主要给「按架构下载二进制」的功能用（AdGuardHome 之类），
# 也用来在输出里告诉用户当前到底是什么机器。
norm_arch() {
	case "$(uname -m 2>/dev/null)" in
		x86_64|amd64)   printf 'x86_64' ;;
		aarch64|arm64)  printf 'aarch64' ;;
		armv7l|armv7)   printf 'armv7' ;;
		armv6l|armv6)   printf 'armv6' ;;
		mips64*)        printf 'mips64' ;;
		mips*)          printf 'mips' ;;
		riscv64)        printf 'riscv64' ;;
		*)              uname -m 2>/dev/null ;;
	esac
}

distro_line() {
	if [ -f /etc/openwrt_release ]; then
		( . /etc/openwrt_release 2>/dev/null
		  printf '%s %s' "${DISTRIB_ID:-OpenWrt}" "${DISTRIB_RELEASE:-}" )
	else
		uname -s 2>/dev/null
	fi
}

# 依赖清单：名称|opkg 包|apk 包|级别|探测方式
#
#   级别  req = 缺了后端起不来
#         luc = LuCI 网页界面要用；App 走 API，不受影响
#         opt = 缺了只少一块功能（这里是硬件页的 PCI 列表）
#   探测  py      = Python 3.9 以上
#         ipjson  = 支持 -j 的完整 iproute2（busybox 自带的 ip 没有 -j，
#                   而流量与接口列表都靠 ip -j）
#         cmd:X   = 命令 X 存在
#         dir:P   = 目录 P 存在
#
# 两个包名列大部分时候一样，但分开写：opkg 和 apk 的包名库不是同一份，
# 以后哪个改名只改一列就行。
DEPS='
Python 3|python3|python3|req|py
UCI|uci|uci|req|cmd:uci
ubus|ubus|ubus|req|cmd:ubus
iproute2|ip-full|ip-full|req|ipjson
LuCI 框架|luci-base|luci-base|luc|dir:/usr/lib/lua/luci/controller
LuCI Lua 兼容层|luci-compat|luci-compat|luc|dir:/usr/lib/lua/luci/model/cbi
LuCI Lua 运行时|luci-lua-runtime|luci-lua-runtime|luc|cmd:lua
PCI 工具|pciutils|pciutils|opt|cmd:lspci
'

dep_have() {
	case "$1" in
		py)
			find_python || return 1
			"$PY" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)' \
				>/dev/null 2>&1
			;;
		ipjson)
			ip -j addr >/dev/null 2>&1
			;;
		cmd:*)
			command -v "${1#cmd:}" >/dev/null 2>&1
			;;
		dir:*)
			[ -d "$ROOT_DIR${1#dir:}" ]
			;;
		*)
			return 1
			;;
	esac
}

# 扫一遍依赖。缺的按级别存进全局变量（ash 没有数组，只能这样传）。
# 返回 0 = 全齐，1 = 有缺。
scan_deps() {
	MISS_REQ=""; MISS_LUC=""; MISS_OPT=""
	MISS_OPKG=""; MISS_APK=""; MISS_OPT_OPKG=""
	local name op ap lvl probe miss=0
	while IFS='|' read -r name op ap lvl probe; do
		[ -n "$name" ] || continue
		dep_have "$probe" && continue
		miss=1
		case "$lvl" in
			req)
				MISS_REQ="$MISS_REQ $name"
				MISS_OPKG="$MISS_OPKG $op"; MISS_APK="$MISS_APK $ap" ;;
			luc)
				MISS_LUC="$MISS_LUC $name"
				MISS_OPKG="$MISS_OPKG $op"; MISS_APK="$MISS_APK $ap" ;;
			*)
				MISS_OPT="$MISS_OPT $name"; MISS_OPT_OPKG="$MISS_OPT_OPKG $op" ;;
		esac
	done <<DEPS_EOF
$DEPS
DEPS_EOF
	return $miss
}

pm_update() {
	[ -n "$PM" ] || return 1
	if [ "$PM" = "apk" ]; then
		apk update >/dev/null 2>&1
	else
		opkg update >/dev/null 2>&1
	fi
}

pm_add() {
	[ -n "$PM" ] || return 1
	if [ "$PM" = "apk" ]; then
		apk add "$1" >/dev/null 2>&1
	else
		opkg install "$1" >/dev/null 2>&1
	fi
}

# 真正装包。缺的包名按当前包管理器挑（opkg 名 / apk 名可能不同）。
install_deps() {
	local pkgs p failed=""
	if [ "$PM" = "apk" ]; then
		pkgs="$MISS_APK"
	else
		pkgs="$MISS_OPKG"
	fi
	[ -n "$pkgs" ] || return 0

	info "更新软件包索引（$PM update）…"
	pm_update || warn "索引更新失败，直接尝试安装（离线或软件源没配时会这样）"

	for p in $pkgs; do
		printf '    · 安装 %-22s ' "$p"
		if pm_add "$p"; then
			printf '完成\n'
		else
			printf '失败\n'
			failed="$failed $p"
		fi
	done
	FAILED_PKGS="$failed"
	[ -z "$failed" ]
}

# 依赖总闸：缺了就装，装不上按级别决定「继续」还是「中止」
ensure_deps() {
	if scan_deps; then
		ok "依赖齐全"
		return 0
	fi

	[ -n "$MISS_LUC" ] && info "LuCI 界面依赖缺失：$(echo $MISS_LUC)（App 走 API，不受影响）"
	[ -n "$MISS_OPT" ] && info "可选依赖缺失：$(echo $MISS_OPT)（跳过，只影响对应的一小块功能）"

	if [ -z "$MISS_OPKG" ]; then
		return 0
	fi

	info "缺少依赖：$(echo $MISS_OPKG)"

	if [ "$NO_DEPS" = "1" ]; then
		warn "按 --no-deps 跳过自动安装"
		[ -n "$MISS_REQ" ] && die "必需依赖没装：$(echo $MISS_REQ)
     去掉 --no-deps 重跑，或手动装。
     手动命令：$(pkg_hint $MISS_OPKG)"
		return 0
	fi

	if [ -z "$PM" ]; then
		die "缺少依赖，而这台机器既没有 opkg 也没有 apk，没法自动装：
       $(echo $MISS_OPKG)
     请手动准备好后重跑本安装包。"
	fi

	if install_deps; then
		ok "依赖已安装"
	else
		warn "以下包没装上：$(echo $FAILED_PKGS)"
		if [ -n "$MISS_REQ" ]; then
			die "必需依赖没装齐，装上也跑不起来。
     手动重试：$(pkg_hint $FAILED_PKGS)
     离线环境：在一台能上网的机器上下载对应的 $(pkg_ext) 包，
     传到路由器后 $(pkg_hint_local) 安装，再重跑本安装器。"
		fi
	fi

	# 重新确认一次：装失败但漏报的情况（比如包名对不上）在这里拦住
	if scan_deps; then
		ok "依赖齐全"
	elif [ -n "$MISS_REQ" ]; then
		die "必需依赖仍然缺失：$(echo $MISS_REQ)
     手动装：$(pkg_hint $MISS_OPKG)"
	else
		warn "仍有界面/可选依赖缺失：$(echo $MISS_LUC $MISS_OPT)"
	fi

	if [ -z "$PY" ]; then
		find_python || die "找不到 python3，本插件的后端跑不起来。
     手动装：$(pkg_hint python3)"
	fi
	return 0
}

# 给用户的手动命令提示（按当前包管理器）
pkg_hint() {
	if [ "$PM" = "apk" ]; then
		printf 'apk add%s' "$*"
	else
		printf 'opkg install%s' "$*"
	fi
}

pkg_hint_local() {
	if [ "$PM" = "apk" ]; then
		printf 'apk add --allow-untrusted'
	else
		printf 'opkg install'
	fi
}

pkg_ext() {
	[ "$PM" = "apk" ] && printf 'apk' || printf 'ipk'
}

# 移除包管理器里那份同名记录（.run 与 opkg/apk 安装互斥）
pkg_remove_self() {
	if command -v opkg >/dev/null 2>&1; then
		opkg remove luci-app-istore-agent >/dev/null 2>&1
	elif command -v apk >/dev/null 2>&1; then
		apk del luci-app-istore-agent >/dev/null 2>&1
	fi
}

# 当前包管理器的名字，只用于文案。顺序与 detect_pm 一致：apk 优先
pkg_mgr_name() {
	if command -v apk >/dev/null 2>&1; then
		printf 'apk'
	elif command -v opkg >/dev/null 2>&1; then
		printf 'opkg'
	else
		printf '无'
	fi
}

# ---------------------------------------------------------------- 解包

extract_payload() {
	# -C 一定要拿到**非空**的目录：空字符串会让 busybox tar 直接失败，
	# 而在真正的根目录安装时 ROOT_DIR 恰好就是空 —— 这个坑让首次安装
	# 在删掉旧文件之后才失败，服务停在半死状态。默认值必须写 "/"。
	local dest="${1:-/}"
	# tail -c +N 是「从第 N 字节开始」，偏移量是 0 基，所以 +1
	tail -c +$((PAYLOAD_OFFSET + 1)) "$SELF" | gzip -dc | tar -xf - -C "$dest" 2>/dev/null
	# 管道里任何一段失败都不好判断，直接用关键文件是否存在来验收
	[ -f "$dest/usr/lib/istore-agent/run.py" ]
}

# 先把载荷解到 /tmp 验一遍，通过了才准动系统文件。
# 顺序很关键：包被截断时必须**在删任何东西之前**失败。
verify_payload() {
	local st="${TMPDIR:-/tmp}/.pilot-stage.$$"
	rm -rf "$st"
	mkdir -p "$st" 2>/dev/null || return 1
	if ! extract_payload "$st"; then
		rm -rf "$st"
		return 1
	fi
	rm -rf "$st"
	return 0
}

# ---------------------------------------------------------------- 安装

do_check() {
	printf '\n  %s %s-%s 环境检查\n\n' "$APP_NAME" "$PKG_VERSION" "$PKG_REVISION"
	detect_pm
	check_env
	ok "sh / gzip / tar 可用"
	ok "$(distro_line) · $(pkg_mgr_name) · $(norm_arch)"
	if [ -n "$PY" ]; then
		ok "python3 在 $PY（$("$PY" -V 2>&1)）"
	else
		warn "没有 python3 —— 安装时会尝试自动装"
	fi
	arch_note

	local size expect
	size=$(wc -c < "$SELF" 2>/dev/null | tr -d ' ')
	expect=$((PAYLOAD_OFFSET + PAYLOAD_LEN))
	ok "安装包完整（$size 字节）"

	# 依赖矩阵：缺什么、装什么、会不会自动装，一次说清
	printf '\n'
	if scan_deps; then
		ok "依赖齐全"
	else
		[ -n "$MISS_REQ" ] && warn "必需缺失：$(echo $MISS_REQ)" || ok "必需依赖齐全"
		[ -n "$MISS_LUC" ] && warn "界面缺失：$(echo $MISS_LUC)（只影响 LuCI 网页版，App 不受影响）"
		[ -n "$MISS_OPT" ] && info "可选缺失：$(echo $MISS_OPT)（对应功能降级，不装也能用）"
		if [ -n "$MISS_OPKG" ]; then
			if [ "$NO_DEPS" = "1" ]; then
				info "本次带 --no-deps，安装时不会自动装"
			elif [ -z "$PM" ]; then
				warn "没有 opkg / apk，无法自动安装，需要手动准备"
			else
				info "安装时会自动装：$(echo $MISS_OPKG)"
			fi
		fi
	fi
	printf '\n'

	if pkg_has_self; then
		warn "$(pkg_mgr_name) 里有同名包（luci-app-istore-agent）"
		info "安装时需加 --force 改由本包接管，或先 $(pkg_mgr_name) 卸掉它"
	else
		ok "包管理器里没有同名包，互不冲突"
	fi

	if [ -f "$ROOT_DIR/etc/config/istore-agent" ]; then
		info "已存在配置 /etc/config/istore-agent，安装时会保留（不会覆盖 bind 与端口）"
	else
		info "尚无配置，安装时写入默认配置"
	fi

	if [ -x "$ROOT_DIR/etc/init.d/istore-agent" ]; then
		info "服务已存在，安装时会先停再起（约 2 秒，不影响网络转发）"
	fi

	local avail
	avail=$(df -Pk "${ROOT_DIR:-/}" 2>/dev/null | awk 'NR==2{print $4}')
	if [ -n "$avail" ]; then
		info "可用空间 ${avail} KB，本包解压需要约 $((PAYLOAD_LEN / 1024)) KB"
	fi
	printf '\n  检查完毕，未改动任何文件。执行安装：sh %s\n\n' "$SELF"
}

do_install() {
	need_root
	detect_pm
	check_env

	printf '\n  %s %s-%s 安装（%s）\n\n' "$APP_NAME" "$PKG_VERSION" "$PKG_REVISION" "$PKG_ARCH"
	ok "$(distro_line) · $(pkg_mgr_name) · $(norm_arch)"
	arch_note

	# 0) 先只往 /tmp 解一遍验货。损坏的包必须在这一步就被拦住，
	#    绝不能等到「删完旧文件」才失败——那会把服务留在半死状态。
	verify_payload || die "解包失败：安装包已损坏或被截断。
     没有改动任何系统文件，当前服务保持原样，请重新下载后再试。"
	ok "载荷校验通过"

	# 0.5) 依赖：缺了先装（这一步会动软件包，所以放在验包之后）
	ensure_deps

	local cfg="$ROOT_DIR/etc/config/istore-agent"
	local svc="$ROOT_DIR/etc/init.d/istore-agent"

	# 1) 先把现有 uci 配置备份到 /tmp。
	#    顺序很重要：卸载时有可能把 conffile 一起删掉，先备份才安全。
	if [ -f "$cfg" ]; then
		CFG_BAK="${TMPDIR:-/tmp}/.istore-agent.cfg.$$"
		cp -p "$cfg" "$CFG_BAK" 2>/dev/null || CFG_BAK=""
	fi

	# 2) 与 opkg / apk 安装互斥。两者并存会导致卸载时把程序文件删掉，
	#    而包记录里还写着「已安装」，后续升级彻底错乱。
	if [ -z "$ROOT_DIR" ] && pkg_has_self; then
		warn "检测到已用 $(pkg_mgr_name) 安装过 luci-app-istore-agent"
		info "两者不能并存——否则卸载会删掉本包的文件。"
		if [ "$FORCE" = "1" ]; then
			info "按 --force 处理，移除包记录…"
			pkg_remove_self || warn "移除返回非零，继续安装"
			ok "包记录已清除"
		elif [ -t 0 ]; then
			printf '    改为由本安装包接管？[y/N] '
			read -r ans
			case "$ans" in
				y|Y|yes|YES)
					pkg_remove_self
					ok "包记录已清除" ;;
				*) die "已取消，未改动任何文件。" ;;
			esac
		else
			die "检测到 $(pkg_mgr_name) 安装的 luci-app-istore-agent。
     加 --force 让本包接管，或先卸掉它。"
		fi
	fi

	# 3) 停服务
	if [ -z "$ROOT_DIR" ] && [ -x "$svc" ]; then
		"$svc" stop >/dev/null 2>&1
		info "已停止旧服务"
	fi

	# 4) 解包（直接解到目标根，不落临时目录，避免 /tmp 空间不足）
	mkdir -p "$ROOT_DIR/usr/lib/istore-agent" "$ROOT_DIR/etc/init.d" \
		"$ROOT_DIR/etc/config" "$ROOT_DIR/usr/lib/lua/luci" \
		"$ROOT_DIR/www" 2>/dev/null

	# 解包只会覆盖同名文件，上一版的 istoreos-x.y.z.apk 会一直留在 www 里。
	# 既白占空间，又会让下面「Android 安装」按文件名取到最旧的那个
	# （0.1.2 < 0.1.3 < 0.1.4，ls 默认就是按名字排）。所以先清掉。
	rm -f "$ROOT_DIR/www/istore-agent/"*.apk 2>/dev/null

	extract_payload "${ROOT_DIR:-/}" \
		|| die "解包失败（写入目标目录时出错）。设备空间可能不足。
     可以先腾点空间（rm -rf /tmp/*），或改用同版本的 ipk 装。"
	ok "文件已解包到 /usr/lib/istore-agent"

	# 5) 配置：已有就保留，备份还在就恢复，都没有才用默认
	local example="$ROOT_DIR/etc/config/istore-agent.example"
	if [ -f "$cfg" ]; then
		ok "保留现有配置 /etc/config/istore-agent（bind 与端口不变）"
		rm -f "$example"
	elif [ -n "$CFG_BAK" ] && [ -f "$CFG_BAK" ]; then
		cp -p "$CFG_BAK" "$cfg"
		ok "已从备份恢复原配置 /etc/config/istore-agent"
		rm -f "$example"
	else
		mv "$example" "$cfg" && chmod 600 "$cfg"
		ok "已写入默认配置 /etc/config/istore-agent"
	fi

	# 6) 权限兜底：某些挂载方式会丢执行位，显式补一次
	chmod 755 "$ROOT_DIR/usr/lib/istore-agent/run.py" 2>/dev/null
	chmod 755 "$ROOT_DIR/usr/lib/istore-agent/setup.py" 2>/dev/null
	[ -f "$svc" ] && chmod 755 "$svc"

	# 7) 清 LuCI 缓存，否则「服务」菜单里看不到新页面
	rm -rf "$ROOT_DIR/tmp/luci-indexcache" "$ROOT_DIR/tmp/luci-indexcache."* \
		"$ROOT_DIR/tmp/luci-modulecache" 2>/dev/null

	# 8) 补全配置 + 起服务
	if [ -z "$ROOT_DIR" ]; then
		if [ -x "$PY" ] && [ -f /usr/lib/istore-agent/setup.py ]; then
			"$PY" /usr/lib/istore-agent/setup.py 2>&1 | while IFS= read -r line; do
				printf '    %s\n' "$line"
			done
		fi

		if [ "$NO_START" = "0" ]; then
			"$svc" enable >/dev/null 2>&1
			"$svc" restart >/dev/null 2>&1
			sleep 1
			if ps w 2>/dev/null | grep -q '[i]store-agent/run.py'; then
				ok "服务已启动（开机自启已开启）"
			else
				warn "服务似乎没起来，查看日志：logread -e istore-agent"
			fi
		else
			info "按 --no-start 处理，未启动服务"
		fi
	fi

	# 9) 收尾提示
	local ip port apk
	ip=$(lan_ip)
	port=$(agent_port)
	printf '\n  ────────────────────────────────────────────────────────\n'
	printf '   安装完成  %s %s-%s\n\n' "$APP_NAME" "$PKG_VERSION" "$PKG_REVISION"
	printf '   网页控制台   http://%s:%s\n' "$ip" "$port"
	printf '   LuCI 管理    http://%s/cgi-bin/luci/admin/services/istore_agent\n' "$ip"
	# 按时间取，不按文件名取：目录里理论上只剩一个，但万一有残留也别提示错版本
	apk=$(ls -t "$ROOT_DIR/www/istore-agent/"*.apk 2>/dev/null | head -1)
	[ -n "$apk" ] && printf '   Android 安装 http://%s/istore-agent/%s\n' "$ip" "$(basename "$apk")"
	printf '   卸载         sh %s --uninstall\n' "$(basename "$SELF")"
	printf '  ────────────────────────────────────────────────────────\n\n'
	printf '   本包未改动任何网络配置，当前网络不受影响。\n\n'
}

# ---------------------------------------------------------------- 卸载

do_uninstall() {
	need_root
	printf '\n  %s 卸载\n\n' "$APP_NAME"

	local svc="$ROOT_DIR/etc/init.d/istore-agent"
	if [ -z "$ROOT_DIR" ] && [ -x "$svc" ]; then
		"$svc" stop >/dev/null 2>&1
		"$svc" disable >/dev/null 2>&1
		ok "服务已停止并取消自启"
	fi

	if [ -z "$ROOT_DIR" ] && pkg_has_self; then
		warn "包管理器里仍有同名包，建议改用 $(pkg_mgr_name) 卸载"
	fi

	local man="$ROOT_DIR/usr/lib/istore-agent/MANIFEST"
	if [ -f "$man" ]; then
		while IFS= read -r f; do
			[ -n "$f" ] && rm -f "$ROOT_DIR/$f"
		done < "$man"
		ok "已按清单删除程序文件"
	else
		rm -rf "$ROOT_DIR/usr/lib/istore-agent"
		rm -f "$svc"
		rm -f "$ROOT_DIR/usr/lib/lua/luci/controller/istore_agent.lua"
		rm -rf "$ROOT_DIR/usr/lib/lua/luci/model/cbi/istore_agent"
		rm -rf "$ROOT_DIR/usr/lib/lua/luci/view/istore_agent"
		rm -rf "$ROOT_DIR/www/istore-agent"
		ok "已删除程序文件（无清单，按默认路径清理）"
	fi

	# 清掉可能残留的空目录
	for d in \
		"$ROOT_DIR/usr/lib/istore-agent" \
		"$ROOT_DIR/usr/lib/lua/luci/model/cbi/istore_agent" \
		"$ROOT_DIR/usr/lib/lua/luci/view/istore_agent" \
		"$ROOT_DIR/www/istore-agent"
	do
		rmdir "$d" 2>/dev/null
	done

	rm -rf "$ROOT_DIR/tmp/luci-indexcache" "$ROOT_DIR/tmp/luci-indexcache."* 2>/dev/null

	if [ "$ACTION" = "purge" ]; then
		rm -rf "$ROOT_DIR/etc/istore-agent"
		rm -f "$ROOT_DIR/etc/config/istore-agent"
		ok "已删除 /etc/istore-agent 与 /etc/config/istore-agent"
	else
		info "已保留 /etc/istore-agent（登录密码）与 /etc/config/istore-agent（端口/bind）"
		info "要彻底清干净：sh $(basename "$SELF") --purge"
	fi
	printf '\n  卸载完成。\n\n'
}

# ---------------------------------------------------------------- 入口

case "$ACTION" in
	help)      usage ;;
	version)   printf '%s %s-%s\n' "$APP_NAME" "$PKG_VERSION" "$PKG_REVISION" ;;
	check)     do_check ;;
	install)   do_install ;;
	uninstall|purge) do_uninstall ;;
esac

exit 0
'''


# ---------------------------------------------------------------- 构建

def manifest_of(stage: str) -> list[str]:
    """装到设备上的文件相对路径清单，卸载时按它逐个删。"""
    out: list[str] = []
    for dirpath, dirnames, filenames in os.walk(stage):
        dirnames[:] = [d for d in dirnames if d != "__pycache__"]
        for name in filenames:
            rel = os.path.relpath(os.path.join(dirpath, name), stage)
            out.append(rel.replace(os.sep, "/"))
    return sorted(out)


#: 支持的目标架构。载荷是纯 Python，写成哪个都能装，这里只影响包名与自检提示
ARCHS = ("x86_64", "arm64", "armv7", "all")


def render_header(version: str, revision: int, arch: str, payload_len: int) -> bytes:
    """把 @VER@/@REV@/@ARCH@/__OFFSET__/__LEN__ 填好，返回头部字节。

    偏移量要写进头部，而头部长度又取决于偏移量的位数 —— 迭代到稳定。
    用纯数字（不加前导零）：shell 里 0 开头会被当成八进制，含 8/9 还会直接报错。
    """
    off = 0
    for _ in range(8):
        text = (HEADER
                .replace("@VER@", version)
                .replace("@REV@", str(revision))
                .replace("@ARCH@", arch)
                .replace("__OFFSET__", str(off))
                .replace("__LEN__", str(payload_len)))
        new = len(text.encode("utf-8"))
        if new == off:
            break
        off = new
    else:
        raise RuntimeError("头部偏移量迭代未收敛")

    blob = text.encode("utf-8")
    if len(blob) != off:
        raise RuntimeError("头部长度与记录的偏移量不一致")
    return blob


def build(archs: tuple[str, ...], with_apk: bool) -> int:
    bipk = load_build_ipk()
    ver = f"{bipk.version()}-{bipk.revision()}"

    work = tempfile.mkdtemp(prefix="run-")
    try:
        stage = os.path.join(work, "rootfs")
        os.makedirs(stage)
        apk = bipk.stage_data(stage, with_apk)
        if with_apk and not apk:
            print("\n  ! dist 里没有 istoreos-%s.apk，拒绝出包。" % bipk.version())
            print("    包里的 App 版本必须和包本身的版本号一致，"
                  "不然用户装完下载到的还是旧 App。")
            print("    先编译：gradle :app:assembleRelease，"
                  "再跑 scripts/release.py（它会同步 APK），")
            print("    或显式加 --no-apk 打一个不带 App 的包。")
            return 3

        # ipk 里配置直接落 /etc/config/istore-agent；.run 里必须改成 .example，
        # 否则解压就会覆盖用户当前的 bind/端口（曾把 8443 暴露到公网）。
        cfg = os.path.join(stage, "etc", "config", "istore-agent")
        if os.path.exists(cfg):
            os.replace(cfg, cfg + ".example")

        files = manifest_of(stage)
        man = os.path.join(stage, "usr", "lib", "istore-agent", "MANIFEST")
        with open(man, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("\n".join(files + ["usr/lib/istore-agent/MANIFEST"]) + "\n")

        # 载荷只打一次，四个架构共用；不同的只有头部里的架构字串
        payload = bipk.tar_gz(stage)
        os.makedirs(OUT_DIR, exist_ok=True)

        print(f"\n  {ver}  载荷 {len(payload) / 1048576:.2f} MB"
              f"{'（含 APK）' if with_apk else '（不含 APK）'}")
        for arch in archs:
            head = render_header(bipk.version(), bipk.revision(), arch, len(payload))
            suffix = "" if arch == "all" else "_" + arch
            out = os.path.join(OUT_DIR, f"istore-pilot_{ver}{suffix}.run")
            with open(out, "wb") as fh:
                fh.write(head + payload)
            if os.name == "posix":
                os.chmod(out, 0o755)
            print(f"    {os.path.basename(out):<40} "
                  f"{os.path.getsize(out) / 1048576:5.2f} MB  头部 {len(head)} B")

        print("\n  装法：把对应架构的包传到路由器，执行")
        print("        sh <包名> --check    # 先看环境与架构")
        print("        sh <包名>            # 再装")
        return 0
    finally:
        import shutil
        shutil.rmtree(work, ignore_errors=True)


def main() -> int:
    args = sys.argv[1:]
    with_apk = "--no-apk" not in args

    pick = [a for a in args if a.startswith("--arch=")]
    if pick:
        want = pick[0].split("=", 1)[1]
        if want not in ARCHS:
            print(f"未知架构 {want}，可选：{', '.join(ARCHS)}")
            return 2
        archs: tuple[str, ...] = (want,)
    else:
        archs = ARCHS
    return build(archs, with_apk)


if __name__ == "__main__":
    sys.exit(main())
