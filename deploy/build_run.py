#!/usr/bin/env python3
"""把 Agent 与 LuCI 界面打成一个**自解压 .run 安装包**。

产出：
    dist/istore-pilot_<版本>-<修订>.run

装法（路由器上，一行搞定）：
    sh istore-pilot_0.1.2-10.run

为什么要 .run 而不是只用 ipk：
    ipk 必须经过 opkg，遇到「没有网络装不上依赖」「opkg 版本不一致」
    「软件包页面传不上去」就卡住了。.run 是纯 shell + tar.gz 自解压，
    路由器上只要有 sh / gzip / tar / python3 就能装，不碰 opkg 数据库，
    也就不会出现「opkg 认为已装、文件却被覆盖」的错位状态。

包体结构：
    [sh 安装器头部][tar.gz 载荷]        偏移量写在头部，安装器自己 tail 出来解压
    载荷 = 与 ipk 完全相同的文件树（直接复用 build_ipk.stage_data）

安全边界（写死在安装器里）：
    - 只写 程序目录 / init.d / LuCI / www，**绝不改 network、firewall、dhcp、dnsmasq**
    - /etc/config/istore-agent 已存在就保留原样（bind 与端口是用户资产，
      覆盖成默认 0.0.0.0 会把 8443 暴露到公网）
    - 与 opkg 安装互斥：检测到已由 opkg 管理时拒绝执行，除非显式 --force

用法：
    python deploy/build_run.py               # 含最新 APK（可在路由器上下载安装）
    python deploy/build_run.py --no-apk      # 不含 APK，包体小 5 MB
    python deploy/build_run.py --rev 11      # 指定修订号
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
#  sh 本文件 --check         只检查环境，不改任何文件
#  sh 本文件 --force         已用 opkg 装过时，强制改由本包接管
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
FORCE=0
ROOT_DIR=""
CFG_BAK=""

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
    --check         只检查运行环境，不做任何改动
    --force         已由 opkg 装过时，强制移除包记录并由本包接管
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

	find_python || die "没有找到 python3。
     本插件用 Python 3 写后端，请先执行：
         opkg update && opkg install python3
     再回来重跑本安装包。"

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
	ip=$(uci -q get network.lan.ipaddr 2>/dev/null)
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

opkg_has_pkg() {
	command -v opkg >/dev/null 2>&1 || return 1
	opkg list-installed 2>/dev/null | grep -q '^luci-app-istore-agent '
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
	check_env
	ok "sh / gzip / tar 可用"
	ok "python3 在 $PY（$("$PY" -V 2>&1)）"
	arch_note

	local size expect
	size=$(wc -c < "$SELF" 2>/dev/null | tr -d ' ')
	expect=$((PAYLOAD_OFFSET + PAYLOAD_LEN))
	ok "安装包完整（$size 字节）"

	if opkg_has_pkg; then
		warn "opkg 中有同名包：$(opkg list-installed 2>/dev/null | grep '^luci-app-istore-agent ')"
		info "安装时需加 --force 改由本包接管，或先 opkg remove"
	else
		ok "opkg 中没有同名包，互不冲突"
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
	check_env

	printf '\n  %s %s-%s 安装（%s）\n\n' "$APP_NAME" "$PKG_VERSION" "$PKG_REVISION" "$PKG_ARCH"
	arch_note

	# 0) 先只往 /tmp 解一遍验货。损坏的包必须在这一步就被拦住，
	#    绝不能等到「删完旧文件」才失败——那会把服务留在半死状态。
	verify_payload || die "解包失败：安装包已损坏或被截断。
     没有改动任何系统文件，当前服务保持原样，请重新下载后再试。"
	ok "载荷校验通过"

	local cfg="$ROOT_DIR/etc/config/istore-agent"
	local svc="$ROOT_DIR/etc/init.d/istore-agent"

	# 1) 先把现有 uci 配置备份到 /tmp。
	#    顺序很重要：opkg remove 有可能把 conffile 一起删掉，先备份才安全。
	if [ -f "$cfg" ]; then
		CFG_BAK="${TMPDIR:-/tmp}/.istore-agent.cfg.$$"
		cp -p "$cfg" "$CFG_BAK" 2>/dev/null || CFG_BAK=""
	fi

	# 2) 与 opkg 安装互斥。两者并存会导致 opkg 卸载时把程序文件删掉，
	#    而 opkg 记录里还写着「已安装」，后续升级彻底错乱。
	if [ -z "$ROOT_DIR" ] && opkg_has_pkg; then
		warn "检测到已用 opkg 安装：$(opkg list-installed 2>/dev/null | grep '^luci-app-istore-agent ')"
		info "两者不能并存——否则 opkg 卸载会删掉本包的文件。"
		if [ "$FORCE" = "1" ]; then
			info "按 --force 处理，移除 opkg 包记录…"
			opkg remove luci-app-istore-agent >/dev/null 2>&1 \
				|| warn "opkg remove 返回非零，继续安装"
			ok "opkg 包记录已清除"
		elif [ -t 0 ]; then
			printf '    改为由本安装包接管？[y/N] '
			read -r ans
			case "$ans" in
				y|Y|yes|YES)
					opkg remove luci-app-istore-agent >/dev/null 2>&1
					ok "opkg 包记录已清除" ;;
				*) die "已取消，未改动任何文件。" ;;
			esac
		else
			die "检测到 opkg 安装的 luci-app-istore-agent。
     加 --force 让本包接管，或先执行：opkg remove luci-app-istore-agent"
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
	extract_payload "${ROOT_DIR:-/}" \
		|| die "解包失败（写入目标目录时出错）。设备空间可能不足。
     手动救急：opkg install --force-reinstall <同名 ipk>"
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
	apk=$(ls "$ROOT_DIR/www/istore-agent/"*.apk 2>/dev/null | head -1)
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

	if [ -z "$ROOT_DIR" ] && opkg_has_pkg; then
		warn "opkg 中仍有同名包，建议改用：opkg remove luci-app-istore-agent"
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
        bipk.stage_data(stage, with_apk)

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
