"""系统维护：上传安装包、改路由器密码、软件包更新。

三条约束决定了这里怎么写：

1. **上传要用裸流**。路由器内存小，multipart 解析器要么吃内存要么依赖
   python-multipart，所以走「X-Filename 头 + 原始字节流」，边收边写盘。
2. **安装必须按类型分流**。.ipk 走 opkg；Alpine 的 .apk 这台机器上没有 apk
   命令，只能放进下载目录；Android 的 .apk（其实是个 zip）也放进下载目录，
   正好可以让「下载 App」弹窗直接用。
3. **升级不能同步等**。opkg upgrade 动辄几分钟，HTTP 早就超时了，
   所以改成后台任务 + 日志文件，客户端轮询状态。
"""

from __future__ import annotations

import html
import os
import re
import shlex
import shutil
import subprocess
import tarfile
import time
import zipfile

UPLOAD_DIR = "/tmp/istore-upload"
PUBLISH_DIR = "/www/istore-agent"
OPKG_LOG = "/tmp/istore-opkg.log"
SELF_PKG = "luci-app-istore-agent"
# 64MB：本项目的安装包最大的 .run 也只有 20MB 上下，固件不走这里。
# 原来是 256MB，而 /tmp 是 tmpfs —— 连续上传就能把路由器内存吃满。
MAX_BYTES = 64 * 1024 * 1024
_NAME_RE = re.compile(r"[^A-Za-z0-9._\-+]")

_SAFE_EXT = (".ipk", ".apk", ".run", ".img", ".bin", ".sh", ".tar", ".gz", ".zip")


def _run(args: list[str], timeout: float = 60.0, stdin: bytes | None = None) -> tuple[int, str]:
    try:
        p = subprocess.run(args, input=stdin, capture_output=True, timeout=timeout, check=False)
        return p.returncode, (p.stdout + p.stderr).decode("utf-8", "replace")
    except (OSError, subprocess.SubprocessError) as exc:
        return 1, str(exc)


def _safe_name(raw: str) -> str:
    base = os.path.basename((raw or "").replace("\\", "/")).strip()
    base = _NAME_RE.sub("_", base)
    # 去掉开头的点，避免写出隐藏文件或 . / ..
    base = base.lstrip(".") or "upload.bin"
    return base[:96]


# ---------------------------------------------------------------- 上传

def receive_upload(rfile, length: int, raw_name: str) -> dict:
    """把请求体直接落到 /tmp，不做任何缓冲拷贝。"""
    name = _safe_name(raw_name)
    if not name.lower().endswith(_SAFE_EXT):
        return {"ok": False, "error": f"不支持的文件类型：{name}"}
    if length <= 0:
        return {"ok": False, "error": "没有收到文件内容"}
    if length > MAX_BYTES:
        return {"ok": False, "error": f"文件太大（上限 {MAX_BYTES // 1048576} MB）"}
    # /tmp 是 tmpfs：写多少就吃多少内存，留出一半余量再收
    try:
        free = shutil.disk_usage(os.path.dirname(UPLOAD_DIR) or "/tmp").free
        if length > free // 2:
            return {"ok": False,
                    "error": "路由器临时空间不够（安装包会占用内存），"
                             "先清理「安装包管理」里的旧文件再试"}
    except OSError:
        pass

    os.makedirs(UPLOAD_DIR, mode=0o700, exist_ok=True)
    path = os.path.join(UPLOAD_DIR, name)
    left = length
    try:
        with open(path, "wb") as fh:
            while left > 0:
                chunk = rfile.read(min(65536, left))
                if not chunk:
                    break
                fh.write(chunk)
                left -= len(chunk)
    except OSError as exc:
        return {"ok": False, "error": str(exc)}

    if left > 0:
        try:
            os.remove(path)
        except OSError:
            pass
        return {"ok": False, "error": "传输中断，文件不完整"}

    size = os.path.getsize(path)
    return {
        "ok": True,
        "name": name,
        "size": size,
        "kind": _kind(path, name),
        "path": path,
    }


def _kind(path: str, name: str) -> str:
    low = name.lower()
    if low.endswith(".ipk"):
        return "ipk"
    if low.endswith(".run"):
        return "run"
    if low.endswith(".apk"):
        with open(path, "rb") as fh:
            head = fh.read(4)
        if head == b"PK\x03\x04":
            return "android-apk"
        return "alpine-apk"
    return "other"


# ---------------------------------------------------------------- 安装

def _ipk_package(path: str) -> str:
    """读 ipk 里的 Package 名。读不出来就返回空串（当成普通包处理）。

    OpenWrt 24.10 起 ipk 是 tar.gz 外壳（不是 ar），里面再套 control.tar.gz，
    control 文件名还可能带 "./" 前缀，所以两头都得松着解析。
    """
    try:
        with tarfile.open(path, "r:*") as outer:
            member = None
            for item in outer.getmembers():
                if item.name.endswith("control.tar.gz"):
                    member = item
                    break
            if member is None:
                return ""
            raw = outer.extractfile(member)
            if raw is None:
                return ""
            with tarfile.open(fileobj=raw, mode="r:*") as ctl:
                target = None
                for item in ctl.getmembers():
                    if item.name.lstrip("./") == "control":
                        target = item
                        break
                if target is None:
                    return ""
                body = ctl.extractfile(target)
                if body is None:
                    return ""
                for line in body.read().decode("utf-8", "replace").splitlines():
                    if line.startswith("Package:"):
                        return line.split(":", 1)[1].strip()
    except (OSError, tarfile.TarError):
        return ""
    return ""


def _install_self(path: str) -> dict:
    """安装 Agent 自己。必须把 opkg 甩到一个脱离本进程会话的 shell 里去跑。

    原因：opkg 装自己时会先删掉 /etc/init.d/istore-agent 与
    /usr/lib/istore-agent/agent/*.py，再展开新文件 —— 而正在执行 opkg 的
    就是这个 py 代码跑起来的进程。进程一死，opkg 跟着被回收，包就停在
    「旧文件已删、新文件没展开」的坏状态：LuCI 页面 404、服务起不来、
    opkg 记录还挂着 prefer not-installed。实测踩过一次。

    所以这里写完脚本立刻返回，前端提示「服务会重启」，几秒后重连即可。
    """
    script = "/tmp/istore-self-install.sh"
    body = (
        "#!/bin/sh\n"
        "sleep 1\n"
        "opkg install --force-reinstall %s >%s 2>&1\n"
        "echo \"rc=$?\" >>%s\n"
        "/etc/init.d/istore-agent enable >/dev/null 2>&1\n"
        "/etc/init.d/istore-agent restart >/dev/null 2>&1\n"
    ) % (shlex.quote(path), OPKG_LOG, OPKG_LOG)
    try:
        with open(script, "w", encoding="utf-8") as fh:
            fh.write(body)
        os.chmod(script, 0o755)
        subprocess.Popen(["/bin/sh", script],
                         stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL,
                         start_new_session=True,
                         close_fds=True)
    except OSError as exc:
        return {"ok": False, "kind": "ipk", "name": os.path.basename(path),
                "error": "启动后台安装失败：%s" % exc}
    return {"ok": True, "kind": "ipk", "name": os.path.basename(path),
            "restarting": True, "output": "",
            "note": "这是 iStore Pilot 自己的安装包，已经在后台安装。"
                    "服务会重启一次，约 10 秒后 App 可能闪断一下，"
                    "重新连上就是新版本（日志见 /tmp/istore-opkg.log）。"}


# 每种类型要求的确认串。装包本质上就是「用 root 执行对方给的东西」，
# 一次误点或者一个被盗的令牌都不该直接变成 root 权限。
_NEED_CONFIRM = {
    "ipk": "ipk",
    "run": "run",
    "alpine-apk": "apk",
    "android-apk": "apk",
}


def install(name: str, confirm: str = "") -> dict:
    name = _safe_name(name)
    path = os.path.join(UPLOAD_DIR, name)
    if not os.path.isfile(path):
        return {"ok": False, "error": "文件不存在，请重新上传"}

    kind = _kind(path, name)
    want = _NEED_CONFIRM.get(kind)
    if want and confirm != want:
        return {
            "ok": False,
            "need_confirm": want,
            "kind": kind,
            "name": name,
            "error": ("这个文件会以管理员权限%s，需要先确认"
                      % ("执行" if kind == "run" else "安装")),
        }

    if kind == "ipk":
        if _ipk_package(path) == SELF_PKG:
            return _install_self(path)
        # --force-reinstall：同一个版本号重装时 opkg 会直接跳过，
        # 用 force 才能让「我自己重新打了一次包」正常覆盖上去
        code, out = _run(["opkg", "install", "--force-reinstall", path], timeout=180)
        return {"ok": code == 0, "kind": "ipk", "name": name,
                "output": _tail(out), "error": None if code == 0 else "opkg 安装失败"}

    if kind == "alpine-apk":
        if shutil.which("apk"):
            code, out = _run(["apk", "add", "--allow-untrusted", path], timeout=180)
            return {"ok": code == 0, "kind": "apk", "name": name,
                    "output": _tail(out), "error": None if code == 0 else "apk 安装失败"}
        return {"ok": False, "kind": "apk", "name": name,
                "error": "这台机器用 opkg 管理软件包，没有 apk 命令，"
                         "Alpine 格式的 .apk 装不了"}

    if kind == "android-apk":
        os.makedirs(PUBLISH_DIR, exist_ok=True)
        dest = os.path.join(PUBLISH_DIR, name)
        try:
            shutil.move(path, dest)
            os.chmod(dest, 0o644)
        except OSError as exc:
            return {"ok": False, "error": str(exc)}
        return {"ok": True, "kind": "android-apk", "name": name,
                "published": True,
                "note": "这是安卓安装包，已放到路由器的 App 下载目录，"
                        "手机浏览器打开 /istore-agent/" + name + " 就能装。"}

    if kind == "run":
        os.chmod(path, 0o755)
        log = "/tmp/istore-run.log"
        try:
            with open(log, "wb") as fh:
                # 用 sh 跑：很多 .run 其实是 sh 脚本，但没带可执行位或 shebang
                p = subprocess.run(["/bin/sh", path], stdout=fh, stderr=fh,
                                   stdin=subprocess.DEVNULL, timeout=600, check=False)
            with open(log, "r", encoding="utf-8", errors="replace") as fh:
                out = fh.read()
        except (OSError, subprocess.SubprocessError) as exc:
            return {"ok": False, "kind": "run", "name": name, "error": str(exc)}
        return {"ok": p.returncode == 0, "kind": "run", "name": name,
                "output": _tail(out),
                "error": None if p.returncode == 0 else f"脚本退出码 {p.returncode}"}

    return {"ok": False, "kind": kind,
            "error": "这个文件类型没有对应的安装方式，只支持 .ipk / .apk / .run"}


def _tail(text: str, limit: int = 4000) -> str:
    text = (text or "").strip()
    return text[-limit:]


def uploads() -> dict:
    items = []
    if os.path.isdir(UPLOAD_DIR):
        for name in sorted(os.listdir(UPLOAD_DIR)):
            path = os.path.join(UPLOAD_DIR, name)
            if not os.path.isfile(path):
                continue
            st = os.stat(path)
            items.append({
                "name": name,
                "size": st.st_size,
                "mtime": int(st.st_mtime),
                "kind": _kind(path, name),
            })
    return {"ok": True, "items": items}


def remove_upload(name: str) -> dict:
    path = os.path.join(UPLOAD_DIR, _safe_name(name))
    try:
        if os.path.isfile(path):
            os.remove(path)
    except OSError as exc:
        return {"ok": False, "error": str(exc)}
    return {"ok": True}


# ---------------------------------------------------------------- 路由器密码

def _root_hash() -> str:
    try:
        with open("/etc/shadow", "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if line.startswith("root:"):
                    return line.split(":", 2)[1]
    except OSError:
        pass
    return ""


def _verify_root(pw: str) -> bool | None:
    """校验 root 密码。返回 None 表示这台机器没法校验（缺 crypt 模块）。"""
    h = _root_hash()
    if not h or h in ("!", "*", "x"):
        return None
    try:
        import crypt  # Python 3.11 还在，3.13 会移除
    except ImportError:
        return None
    try:
        return crypt.crypt(pw, h) == h
    except (OSError, ValueError):
        return None


def root_password(current: str, new: str) -> dict:
    new = (new or "").strip()
    if len(new) < 8:
        return {"ok": False, "error": "新密码至少 8 位"}
    if len(new) > 63:
        return {"ok": False, "error": "新密码最长 63 位"}

    ok = _verify_root(current or "")
    if ok is False:
        return {"ok": False, "error": "当前路由器密码不正确"}
    if ok is None:
        # 校验不了就只能要求调用方明确确认，不能静默放行
        return {"ok": False, "error": "这台路由器无法校验旧密码，"
                                      "请到 iStoreOS 后台 → 系统 → 管理权 里修改"}

    code, out = _run(["chpasswd"], timeout=20, stdin=f"root:{new}\n".encode())
    if code != 0:
        return {"ok": False, "error": "修改失败：" + _tail(out, 300)}
    return {"ok": True, "note": "路由器密码已更新，LuCI 后台登录同步生效。"}


# ---------------------------------------------------------------- 系统更新

def _release() -> dict:
    data = {}
    try:
        with open("/etc/openwrt_release", "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if "=" not in line:
                    continue
                key, _, raw = line.partition("=")
                data[key.strip()] = raw.strip().strip("'")
    except OSError:
        pass
    return {
        "distro": data.get("DISTRIB_ID", ""),
        "version": data.get("DISTRIB_RELEASE", ""),
        "revision": data.get("DISTRIB_REVISION", ""),
        "target": data.get("DISTRIB_TARGET", ""),
        "description": data.get("DISTRIB_DESCRIPTION", ""),
    }


def _kernel() -> str:
    code, out = _run(["uname", "-r"], timeout=5)
    return out.strip() if code == 0 else ""


def _parse_upgradable() -> list[dict]:
    code, out = _run(["opkg", "list-upgradable"], timeout=90)
    items = []
    for line in out.splitlines():
        line = line.strip()
        # 形如 "luci-lib-base - 25.100.35637~6506bd3 - 26.286.75782~0e65379"
        if " - " not in line or line.startswith(("Multiple packages", "Collected")):
            continue
        parts = [p.strip() for p in line.split(" - ")]
        if len(parts) != 3:
            continue
        items.append({"name": parts[0], "current": parts[1], "latest": parts[2]})
    return items


def _running() -> bool:
    code, _ = _run(["pgrep", "-f", "opkg (update|upgrade)"], timeout=5)
    return code == 0


def update_status() -> dict:
    running = _running()
    log = ""
    try:
        with open(OPKG_LOG, "r", encoding="utf-8", errors="replace") as fh:
            log = fh.read()[-4000:]
    except OSError:
        pass
    rel = _release()
    rel["kernel"] = _kernel()
    return {
        "ok": True,
        "firmware": rel,
        "running": running,
        "log": log,
        "installed": _count_installed(),
    }


def _count_installed() -> int:
    try:
        with open("/usr/lib/opkg/status", "r", encoding="utf-8", errors="replace") as fh:
            return sum(1 for line in fh if line.startswith("Package:"))
    except OSError:
        return 0


def check_updates(refresh: bool = False) -> dict:
    """检查可升级的软件包。refresh=True 会先 opkg update 拉一次索引。"""
    log = ""
    if refresh:
        code, out = _run(["opkg", "update"], timeout=180)
        log = _tail(out, 1200)
        if code != 0 and not log:
            return {"ok": False, "error": "opkg update 失败，检查网络或软件源"}

    items = _parse_upgradable()
    rel = _release()
    rel["kernel"] = _kernel()
    return {
        "ok": True,
        "firmware": rel,
        "packages": items,
        "count": len(items),
        "log": log,
        "note": "软件包升级只动 opkg 包，不改固件本体。",
    }


# ---------------------------------------------------------------- 固件 OTA
#
# iStoreOS 自带 /bin/ota，后台「系统 → OTA」调的就是它。之前查 owut /
# attendedsysupgrade 都扑空，是因为入口在这里：
#   ota check     返回码 0=有新固件 1=已最新 2=下载任务在跑 255=失败
# 检查结果落在 /var/run/ota/{ota.latest,ota.log}，脚本自己带 5 分钟缓存
# （check.status 的 mtime），所以这里不必再加一层缓存。

OTA_BIN = "/bin/ota"
OTA_DIR = "/var/run/ota"


def _strip_html(text: str) -> str:
    """ota.log 是给网页用的 HTML 片段，转成纯文本给 App。"""
    t = text or ""
    t = re.sub(r"<br\s*/?>", "\n", t, flags=re.I)
    t = re.sub(r"</(h3|p|li|pre|ul|ol)>", "\n", t, flags=re.I)
    t = re.sub(r"<h3>", "\n# ", t, flags=re.I)
    t = re.sub(r"<[^>]+>", "", t)
    t = html.unescape(t)
    t = re.sub(r"[ \t]+\n", "\n", t)
    t = re.sub(r"\n{3,}", "\n\n", t)
    return t.strip()


def _ota_latest() -> dict:
    """解析 /var/run/ota/ota.latest，拿最新镜像名、版本号与校验值。

    首行形如：[istoreos-24.10.8-2026073111-x86-64-...img.gz](同名)
    之后是 SHA256 / MD5 两行。
    """
    image = ""
    sha = ""
    path = os.path.join(OTA_DIR, "ota.latest")
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not image:
                    m = re.match(r"\[([^\]]*)\]\(([^)]*)\)", line)
                    if m:
                        image = (m.group(2) or m.group(1)).strip()
                        continue
                if line.upper().startswith("SHA256:") and not sha:
                    sha = line.split(":", 1)[1].strip()
    except OSError:
        pass

    version = ""
    m = re.search(r"istoreos-(\d{4}\.\d+(?:\.\d+)?)-(\d{6,})", image, re.I)
    if m:
        version = f"{m.group(1)} {m.group(2)}"
    return {"image": image, "sha256": sha, "version": version}


def _ota_changelog() -> str:
    path = os.path.join(OTA_DIR, "ota.log")
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return _strip_html(fh.read())[:6000]
    except OSError:
        return ""


def firmware_check() -> dict:
    """检查系统固件更新（走 iStoreOS 自带 OTA 通道）。

    注意它查的是**固件镜像**，不是 opkg 软件包 —— 两件事分开，别混在一起。
    """
    rel = _release()
    current = " ".join(x for x in (rel.get("version", ""), rel.get("revision", "")) if x)
    started = time.time()
    code, out = _run([OTA_BIN, "check"], timeout=180)
    elapsed = round(time.time() - started, 1)
    info = _ota_latest()

    known = {0: "update", 1: "latest", 2: "busy"}
    if code not in known:
        detail = _tail(out, 600).strip() or f"ota check 返回 {code}"
        return {
            "ok": False,
            "error": detail,
            "state": "error",
            "current": current,
            "elapsed": elapsed,
        }

    state = known[code]
    latest = info.get("version") or ""
    if not latest:
        # 已最新时 latest 通常和当前版本一致；取不到就用当前版本兜底
        latest = current
    return {
        "ok": True,
        "state": state,
        "has_update": code == 0,
        "current": current,
        "latest": latest,
        "image": info.get("image", ""),
        "sha256": info.get("sha256", ""),
        "changelog": _ota_changelog() if code in (0, 1) else "",
        "elapsed": elapsed,
    }



def upgrade(names: list[str] | None = None) -> dict:
    """后台跑 opkg upgrade，立刻返回。进度看 update_status()。"""
    if _running():
        return {"ok": False, "error": "已经有升级任务在跑"}

    pkgs = ""
    if names:
        safe = [n for n in names if re.fullmatch(r"[A-Za-z0-9._+\-]{1,80}", n or "")]
        if not safe:
            return {"ok": False, "error": "参数不合法"}
        pkgs = " " + " ".join(safe)

    cmd = f"opkg update && opkg upgrade{pkgs}"
    try:
        with open(OPKG_LOG, "wb") as fh:
            subprocess.Popen(["/bin/sh", "-c", cmd], stdout=fh, stderr=fh,
                             stdin=subprocess.DEVNULL, start_new_session=True,
                             close_fds=True)
    except OSError as exc:
        return {"ok": False, "error": str(exc)}

    time.sleep(0.2)
    return {"ok": True, "async": True, "started": int(time.time()),
            "note": "升级已在后台开始，日志会实时回传。"}
