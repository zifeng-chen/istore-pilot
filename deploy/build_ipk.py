#!/usr/bin/env python3
"""把 Agent 打成 iStoreOS 可安装的 ipk。

产出：
    dist/luci-app-istore-agent_<版本>_all.ipk

装法：路由器网页 → 系统 → 软件包 → 上传软件包 → 安装。
装完在「服务 → iStore Pilot」里能看到运行状态、改端口、下载 App。

为什么自己拼 ar 包：
    OpenWrt 上打 ipk 需要 buildroot 环境，而这里只需要「把一堆文件按 deb 格式塞进
    三个成员里」。ar 格式简单到 40 行代码就能写完，比装一整套编译工具链划算得多。

用法：
    python deploy/build_ipk.py             # 不打包 APK（体积小，约 2 MB）
    python deploy/build_ipk.py --with-apk  # 把最新 APK 也塞进去，网页端可直接下载
"""

from __future__ import annotations

import io
import os
import re
import shutil
import sys
import tarfile
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IPK_SRC = os.path.join(ROOT, "deploy", "ipk")
OUT_DIR = os.path.join(ROOT, "dist")
APK_DIR = os.path.join(ROOT, "dist")

PKG_NAME = "luci-app-istore-agent"


def version() -> str:
    with open(os.path.join(ROOT, "agent", "server.py"), "r", encoding="utf-8") as fh:
        m = re.search(r'^VERSION\s*=\s*"([^"]+)"', fh.read(), re.M)
    return m.group(1) if m else "0.0.0"


def revision() -> int:
    """
    ipk 的修订号（Version 里的 -N）。

    改内容不加修订号，opkg 会认为「已经是最新」而跳过重装 —— 这是升级时
    最容易漏掉的一步。用法：python deploy/build_ipk.py --rev 2
    """
    for i, arg in enumerate(sys.argv):
        if arg == "--rev" and i + 1 < len(sys.argv):
            return int(sys.argv[i + 1])
        if arg.startswith("--rev="):
            return int(arg.split("=", 1)[1])
    return 1


def newest_apk() -> str:
    if not os.path.isdir(APK_DIR):
        return ""
    best = ""
    best_mtime = 0
    for name in os.listdir(APK_DIR):
        if not name.endswith(".apk"):
            continue
        path = os.path.join(APK_DIR, name)
        mt = os.path.getmtime(path)
        if mt > best_mtime:
            best, best_mtime = path, mt
    return best


# ---------------------------------------------------------------- 打包工具

def file_mode(full: str) -> int:
    """
    决定打进包里的权限位。

    Windows 上不能直接用 st_mode：NTFS 没有 POSIX 执行位，os.chmod 只会动
    「只读」属性，os.stat 拿回来的一律是 0666。结果就是 postinst / init.d 脚本
    打进 ipk 后丢了 x，opkg 装的时候报
        /usr/lib/opkg/info/xxx.postinst: Permission denied
        pkg_run_script: postinst script returned status 126
    ——文件都装好了，只是脚本跑不起来，很容易误以为是依赖或环境问题。

    所以非 POSIX 平台按 shebang 推断：首行 #! 的当可执行。
    """
    if os.name == "posix":
        return os.stat(full).st_mode & 0o777
    try:
        with open(full, "rb") as fh:
            head = fh.read(2)
    except OSError:
        head = b""
    return 0o755 if head == b"#!" else 0o644


def tar_gz(base: str) -> bytes:
    """
    把一个目录打成 tar.gz，成员名统一带 "./" 前缀。

    目录条目也要打进去（包括根 "." 本身）——官方 ipk 就是这种结构。
    opkg 用 libarchive 解包，理论上能自己补父目录，但目录权限/属主就只能靠
    条目本身，缺目录条目时 /etc/init.d 下的脚本可能拿到怪权限，别省这一步。
    """
    buf = io.BytesIO()
    now = int(time.time())
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        # 根目录条目，官方包里写作 "."
        root = tarfile.TarInfo(".")
        root.type = tarfile.DIRTYPE
        root.mode = 0o755
        root.mtime = now
        root.uid = root.gid = 0
        root.uname = root.gname = "root"
        tar.addfile(root)

        for dirpath, dirnames, filenames in os.walk(base):
            dirnames.sort()
            for name in sorted(dirnames):
                rel = os.path.relpath(os.path.join(dirpath, name), base).replace(os.sep, "/")
                info = tarfile.TarInfo("./" + rel)
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                info.mtime = now
                info.uid = info.gid = 0
                info.uname = info.gname = "root"
                tar.addfile(info)

            for name in sorted(filenames):
                full = os.path.join(dirpath, name)
                # deb/ipk 的惯例是成员名带 "./" 前缀。
                # 虽然 GNU tar 两种都认，但 libopkg 解 control 时按 "./control" 匹配，
                # 不带前缀会直接报 Malformed package file
                rel = "./" + os.path.relpath(full, base).replace(os.sep, "/")
                info = tar.gettarinfo(full, arcname=rel)
                info.mode = file_mode(full)
                # 统一属主：ipk 里的 uid/gid 没意义，统一 root:root 更规范
                info.uid = info.gid = 0
                info.uname = info.gname = "root"
                info.mtime = now
                with open(full, "rb") as fh:
                    tar.addfile(info, fh)
    return buf.getvalue()


def ipk_pack(members: list[tuple[str, bytes]]) -> bytes:
    """
    打 ipk 外壳。

    **格式随 OpenWrt 版本变过**，这点很容易踩：
      - 23.05 及更早：ipk 是 ar 归档（!<arch> + debian-binary + control.tar.gz + data.tar.gz）
      - 24.10 起：ipk 换成了 **tar.gz**，里面装同样三个文件

    这个路由器是 iStoreOS 24.10.8（opkg 2024-10 版，基于 libarchive），
    用 ar 格式会直接报 "Malformed package file"——踩过这个坑，所以这里出 tar.gz。
    判断依据就是拿官方源下载的 ipk 看首字节：ar 是 `!<arch>`，新版是 gzip 的 1f 8b。
    """
    buf = io.BytesIO()
    now = int(time.time())
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for name, data in members:
            info = tarfile.TarInfo("./" + name)
            info.size = len(data)
            info.mode = 0o644
            info.mtime = now
            info.uid = info.gid = 0
            info.uname = info.gname = "root"
            tar.addfile(info, io.BytesIO(data))
    return buf.getvalue()


def size_of(base: str) -> int:
    total = 0
    for dirpath, _, filenames in os.walk(base):
        for name in filenames:
            try:
                total += os.path.getsize(os.path.join(dirpath, name))
            except OSError:
                pass
    return total


# ---------------------------------------------------------------- 数据目录

def uci_config(src: str) -> bytes:
    """
    把带注释的 uci 源文件规范成 uci 自己的写法。

    为什么值得为这个写个函数：`uci commit` 会丢掉独立注释行，还会在文件头
    和尾部各留一个空行。如果包装的是带注释的版本，opkg 每次升级都会判定
    conffile 冲突 —— 日志里冒出
        resolve_conffiles: Existing conffile /etc/config/istore-agent is
        different from the conffile in the new package
    并且把新文件另存成 /etc/config/istore-agent-opkg，看着像装坏了。
    规范成同一形态之后升级就安静了。

    注释留在仓库里给人看，装到设备上的是等价但无注释的版本。
    """
    lines: list[str] = []
    with open(src, "r", encoding="utf-8") as fh:
        for raw in fh:
            s = raw.strip()
            if not s or s.startswith("#"):
                continue
            lines.append("\t" + s if s.startswith("option ") else s)
    # 头尾各一个空行是 uci commit 的实际产物，照抄才不会触发冲突判定
    return ("\n" + "\n".join(lines) + "\n\n").encode("utf-8")


def stage_data(stage: str, with_apk: bool) -> None:
    def put(rel: str, content: bytes, mode: int = 0o644) -> None:
        dest = os.path.join(stage, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "wb") as fh:
            fh.write(content)
        os.chmod(dest, mode)

    def copy_tree(src: str, rel: str) -> None:
        dest = os.path.join(stage, rel)
        os.makedirs(dest, exist_ok=True)
        for dirpath, dirnames, filenames in os.walk(src):
            dirnames[:] = [d for d in dirnames if d != "__pycache__"]
            rel_dir = os.path.relpath(dirpath, src)
            target = dest if rel_dir == "." else os.path.join(dest, rel_dir)
            os.makedirs(target, exist_ok=True)
            for name in filenames:
                if name.endswith((".pyc", ".pyo")):
                    continue
                shutil.copy2(os.path.join(dirpath, name), os.path.join(target, name))

    # --- Agent 本体
    copy_tree(os.path.join(ROOT, "agent"), "usr/lib/istore-agent/agent")
    copy_tree(os.path.join(ROOT, "web"), "usr/lib/istore-agent/web")
    shutil.copy2(os.path.join(ROOT, "run.py"), os.path.join(stage, "usr/lib/istore-agent/run.py"))
    shutil.copy2(os.path.join(IPK_SRC, "setup.py"),
                 os.path.join(stage, "usr/lib/istore-agent/setup.py"))
    os.chmod(os.path.join(stage, "usr/lib/istore-agent/run.py"), 0o755)
    os.chmod(os.path.join(stage, "usr/lib/istore-agent/setup.py"), 0o755)

    # 版本文件：LuCI 状态页读它，不用去连 API
    with open(os.path.join(stage, "usr/lib/istore-agent/VERSION"), "w",
              encoding="utf-8", newline="\n") as fh:
        fh.write(version() + "\n")

    # --- init 与 uci 配置
    os.makedirs(os.path.join(stage, "etc/init.d"), exist_ok=True)
    os.makedirs(os.path.join(stage, "etc/config"), exist_ok=True)
    shutil.copy2(os.path.join(IPK_SRC, "init.d", "istore-agent"),
                 os.path.join(stage, "etc/init.d/istore-agent"))
    os.chmod(os.path.join(stage, "etc/init.d/istore-agent"), 0o755)
    put("etc/config/istore-agent",
        uci_config(os.path.join(IPK_SRC, "etc", "config", "istore-agent")), 0o600)

    # --- LuCI 三件套
    luci = os.path.join(IPK_SRC, "luci")
    put("usr/lib/lua/luci/controller/istore_agent.lua",
        open(os.path.join(luci, "controller", "istore_agent.lua"), "rb").read())
    put("usr/lib/lua/luci/model/cbi/istore_agent/status.lua",
        open(os.path.join(luci, "model", "cbi", "istore_agent", "status.lua"), "rb").read())
    # 只打包 state.htm：App 下载已并进状态页的弹窗，
    # app.htm / password.htm 都不再有入口（password 现在是 CBI 表单）
    for name in ("state.htm",):
        put(f"usr/lib/lua/luci/view/istore_agent/{name}",
            open(os.path.join(luci, "view", "istore_agent", name), "rb").read())

    # --- APK（可选）
    if with_apk:
        apk = newest_apk()
        if apk:
            put(f"www/istore-agent/{os.path.basename(apk)}", open(apk, "rb").read())
            print(f"  已附带 APK：{os.path.basename(apk)} "
                  f"({os.path.getsize(apk) / 1048576:.1f} MB)")


# ---------------------------------------------------------------- control

def stage_control(stage: str, data_size: int) -> None:
    os.makedirs(stage, exist_ok=True)
    ver = f"{version()}-{revision()}"

    # Description 必须是**单行**：OpenWrt 24.10 的 opkg 对多行续行处理有问题，
    # 会报 "truncating field 4 <垃圾指针>" 然后把包当成未知包。
    # 官方源的 ipk 也全是单行，照抄这个格式最稳。
    control = f"""Package: {PKG_NAME}
Version: {ver}
Depends: libc, python3, luci-base, luci-compat, luci-lua-runtime
Source: istoreos-app
SourceName: {PKG_NAME}
License: MIT
Section: luci
Maintainer: chaof
Architecture: all
Installed-Size: {data_size // 1024}
Description: iStore Pilot — iStoreOS 路由管理 App 的后端服务（设备/流量/代理/广告拦截/硬件/网络）
"""
    # newline="\n" 是**必须**的：Windows 上文本模式默认把 \n 转成 \r\n，
    # 于是 control 里变成 "Architecture: all\r"，opkg 拿 "all\r" 跟 "all" 比对
    # 永远不相等，报 "incompatible with the architectures configured"。
    # 这个报错极具误导性——看着像打包格式问题，其实是换行符。
    with open(os.path.join(stage, "control"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(control)

    # 配置文件在升级时要保留
    with open(os.path.join(stage, "conffiles"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write("/etc/config/istore-agent\n")

    postinst = """#!/bin/sh
# 安装 / 升级后的收尾。
[ -n "${IPKG_INSTROOT}" ] && exit 0

/etc/init.d/istore-agent enable >/dev/null 2>&1

# setup.py 是幂等的：配置文件已存在就只在缺项时补，不会覆盖用户改过的密码
if [ -x /usr/bin/python3 ]; then
	/usr/bin/python3 /usr/lib/istore-agent/setup.py 2>&1 | logger -t istore-agent
else
	logger -t istore-agent "未找到 python3，请先安装 python3 后再启动服务"
fi

/etc/init.d/istore-agent restart >/dev/null 2>&1
exit 0
"""
    with open(os.path.join(stage, "postinst"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(postinst)
    os.chmod(os.path.join(stage, "postinst"), 0o755)

    prerm = """#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/istore-agent stop >/dev/null 2>&1
/etc/init.d/istore-agent disable >/dev/null 2>&1
exit 0
"""
    with open(os.path.join(stage, "prerm"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(prerm)
    os.chmod(os.path.join(stage, "prerm"), 0o755)

    postrm = """#!/bin/sh
# 卸载时保留 /etc/istore-agent（密码、令牌）；真要清干净加 purge 参数
[ -n "${IPKG_INSTROOT}" ] && exit 0
if [ "$1" = "purge" ]; then
	rm -rf /etc/istore-agent
fi
exit 0
"""
    with open(os.path.join(stage, "postrm"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(postrm)
    os.chmod(os.path.join(stage, "postrm"), 0o755)


# ---------------------------------------------------------------- 主流程

def main() -> int:
    with_apk = "--with-apk" in sys.argv
    ver = f"{version()}-{revision()}"

    work = tempfile.mkdtemp(prefix="ipk-")
    try:
        data_dir = os.path.join(work, "data")
        ctrl_dir = os.path.join(work, "control")
        os.makedirs(data_dir)
        os.makedirs(ctrl_dir)

        print(f"打包 {PKG_NAME} {ver}")
        stage_data(data_dir, with_apk)
        data_size = size_of(data_dir)
        stage_control(ctrl_dir, data_size)

        data_tar = tar_gz(data_dir)
        ctrl_tar = tar_gz(ctrl_dir)

        ipk = ipk_pack([
            ("debian-binary", b"2.0\n"),
            ("data.tar.gz", data_tar),
            ("control.tar.gz", ctrl_tar),
        ])

        os.makedirs(OUT_DIR, exist_ok=True)
        out = os.path.join(OUT_DIR, f"{PKG_NAME}_{ver}_all.ipk")
        with open(out, "wb") as fh:
            fh.write(ipk)

        print(f"\n产物：{out}")
        print(f"  解包后 {data_size / 1048576:.1f} MB，ipk 本体 {len(ipk) / 1048576:.1f} MB")
        print("  安装：路由器网页 → 系统 → 软件包 → 上传软件包")
        return 0
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
