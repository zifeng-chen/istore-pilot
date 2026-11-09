#!/usr/bin/env python3
"""一条命令走完「APK 更新 → 重打 .run → 提交推送 → 发 Release」。

为什么要有这个脚本：这四步以前是手动的，而 .run 要带**对应版本**的 APK
（`build_ipk.apk_for()` 按版本名取），最容易出的错就是「编译了新 APK 但忘了复制进 dist」，
于是打出来的包里还是旧 App —— 用户从网页端点下载，拿到的是旧版本。

步骤：
  1. 把 android/app/build/outputs/apk/release/app-release.apk 同步到 dist/
  2. 跑 deploy/build_run.py，产出 x86_64 / arm64 / armv7 / all 四份 .run
  3. git add + commit + push（有变更才提交）
  4. 打 tag v<版本> 并推送
  5. 创建 GitHub Release，上传 4 份 .run + APK（+ 可选的 ipk）

用法：
  python scripts/release.py                  # 全自动
  python scripts/release.py --notes 说明.md  # 自定义 Release 正文
  python scripts/release.py --skip-build     # 跳过 APK 同步与 .run 重打
  python scripts/release.py --dry-run        # 只打印将要做什么

凭据：优先环境变量 GITHUB_TOKEN，其次 git credential（Windows 凭据管理器里存的
那个）。都不会写到磁盘上。
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIST = os.path.join(ROOT, "dist")
REPO = "zifeng-chen/istore-pilot"
API = "https://api.github.com"
#: 资产上传走另一个域名，用 api.github.com 会 404
UPLOAD = "https://uploads.github.com"
APK_BUILD = os.path.join(ROOT, "android", "app", "build", "outputs", "apk", "release", "app-release.apk")


# ---------------------------------------------------------------- 小工具

#: 有的机器上系统代理只对 curl 生效，urllib 走同一个代理会 502。
#: 先直连，失败再退回系统代理 —— 两条路都试过才报错。
_DIRECT = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def _open(req: urllib.request.Request, timeout: int):
    try:
        return _DIRECT.open(req, timeout=timeout)
    except urllib.error.URLError as exc:
        if "proxy" not in str(exc).lower() and "tunnel" not in str(exc).lower():
            raise
        return urllib.request.urlopen(req, timeout=timeout)


def sh(args: list[str], check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(args, cwd=ROOT, text=True, capture_output=True, check=check)


def preflight() -> int:
    """发版前体检：任一项不过就不发。--skip-checks 可跳过（救急用）。

    这里只跑「纯 Python / 不需要 SDK」的检查：lint_style、dead_code、
    arkts_scan、ruff(F)、版本一致性。三端编译不在这里跑——需要 Android SDK
    / Mac / DevEco，放到真正出包前各自验证。
    """
    checks = [
        ("lint_style", [sys.executable, "scripts/lint_style.py"]),
        ("dead_code", [sys.executable, "scripts/dead_code.py"]),
        ("arkts_scan", [sys.executable, "scripts/arkts_scan.py"]),
        ("ruff", [sys.executable, "-m", "ruff", "check", "agent", "scripts",
                  "deploy", "--select", "F"]),
        ("version", [sys.executable, "scripts/check_version.py"]),
    ]
    failed: list[str] = []
    for name, cmd in checks:
        r = subprocess.run(cmd, cwd=ROOT, text=True, capture_output=True)
        if r.returncode != 0:
            failed.append(name)
            print("  ✗ %s 未通过：" % name)
            print((r.stdout + r.stderr).strip()[-1200:])
    if failed:
        print("! 体检不过：%s。修复后再发，或用 --skip-checks 强制（不建议）。"
              % ", ".join(failed))
        return 1
    print("  体检通过：%s" % ", ".join(c[0] for c in checks))
    return 0


def version() -> tuple[str, int]:
    """从 agent/server.py 的 VERSION 与 build_ipk.revision() 取，和包名一致。"""
    import importlib.util

    spec = importlib.util.spec_from_file_location(
        "build_ipk", os.path.join(ROOT, "deploy", "build_ipk.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.version(), mod.revision()


def token() -> str:
    env = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if env:
        return env.strip()
    out = subprocess.run(
        ["git", "credential", "fill"],
        input="protocol=https\nhost=github.com\n\n",
        text=True, capture_output=True, cwd=ROOT)
    for line in out.stdout.splitlines():
        if line.startswith("password="):
            return line.split("=", 1)[1].strip()
    return ""


def _send(req, timeout: int) -> tuple[int, dict]:
    """发请求，把 HTTPError 也归一成 (status, dict)。

    api() / upload() 原来各抄了 10 行同样的错误处理：GitHub 的 4xx
    有时返回 JSON，有时返回纯文本，两处都得兜住。
    """
    try:
        with _open(req, timeout) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as exc:
        payload = exc.read()
        try:
            return exc.code, json.loads(payload)
        except ValueError:
            return exc.code, {"message": payload.decode("utf-8", "replace")}


def api(method: str, path: str, tok: str, body: dict | None = None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        API + path, data=data, method=method,
        headers={"Authorization": "token " + tok,
                 "Accept": "application/vnd.github+json",
                 "Content-Type": "application/json",
                 "User-Agent": "istore-pilot-release"})
    return _send(req, 60)


def patch_body(release_id: int, body: str, tok: str) -> int:
    """改已发布 Release 的正文。PATCH 只认数字 id，用 /tags/ 会 404。"""
    status, _ = api("PATCH", "/repos/%s/releases/%d" % (REPO, release_id), tok,
                    {"body": body})
    return status


def upload(release_id: int, path: str, tok: str) -> tuple[int, dict]:
    name = os.path.basename(path)
    size = os.path.getsize(path)
    url = "%s/repos/%s/releases/%d/assets?name=%s" % (
        UPLOAD, REPO, release_id, urllib.parse.quote(name))
    req = urllib.request.Request(url, data=open(path, "rb").read(), method="POST", headers={
        "Authorization": "token " + tok,
        "Content-Type": "application/octet-stream",
        "Content-Length": str(size),
        "User-Agent": "istore-pilot-release"})
    return _send(req, 300)


# ---------------------------------------------------------------- 构建

def sync_apk(ver: str, dry: bool) -> str:
    """把编译出来的 APK 同步进 dist/，并清掉其它版本的旧 APK。

    打包时按「版本名」取 APK（`build_ipk.apk_for`），所以 dist 里留着旧版本
    只会制造混乱：既看不出哪个是真的，又容易在手工操作时被打进包。
    """
    target = os.path.join(DIST, "istoreos-%s.apk" % ver)
    if not os.path.exists(APK_BUILD):
        print("  ! 没找到编译产物 %s" % APK_BUILD)
        print("    先跑：cd android && gradle assembleRelease")
        return target if os.path.exists(target) else ""

    src_mt = os.path.getmtime(APK_BUILD)
    dst_mt = os.path.getmtime(target) if os.path.exists(target) else 0
    if src_mt > dst_mt:
        if dry:
            print("  [dry] APK %s → dist/%s" % (ver, os.path.basename(target)))
        else:
            shutil.copy2(APK_BUILD, target)
            print("  APK 已更新 → dist/%s" % os.path.basename(target))
    else:
        print("  APK 已是最新（dist 不比编译产物旧）")

    # 只留当前版本这一个
    if not dry and os.path.isdir(DIST):
        keep = os.path.basename(target)
        for name in sorted(os.listdir(DIST)):
            if not (name.startswith("istoreos-") and name.endswith(".apk")):
                continue
            if name == keep:
                continue
            try:
                os.remove(os.path.join(DIST, name))
                print("  清理旧 APK：%s" % name)
            except OSError:
                pass
    return target


def build_run(dry: bool) -> int:
    if dry:
        print("  [dry] python deploy/build_run.py")
        return 0
    proc = subprocess.run([sys.executable, os.path.join(ROOT, "deploy", "build_run.py")],
                          cwd=ROOT, text=True, capture_output=True)
    sys.stdout.write(proc.stdout)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
    return proc.returncode


# ---------------------------------------------------------------- 发布

def notes_for(tag: str, ver: str, full: str) -> str:
    """Release 正文：本次提交列表 + 下载表 + 安装说明。"""
    # 上一个 release tag（要把本次的 tag 自己排除，否则区间为空）
    last = ""
    try:
        tags = [t for t in sh(["git", "tag", "--sort=-creatordate"]).stdout.split() if t != tag]
        last = tags[0] if tags else ""
    except subprocess.CalledProcessError:
        pass

    rng = "%s..HEAD" % last if last else "HEAD"
    lines = []
    for ln in sh(["git", "log", "--no-merges", "--pretty=- %s", rng]).stdout.splitlines():
        if not ln.strip():
            continue
        # 发布提交本身不算"更新"
        if ln.startswith("- release:"):
            continue
        lines.append(ln)
    if not lines:
        log = "- 维护性更新"
    elif len(lines) > 12:
        # 只列最近 12 条，其余指向 CHANGELOG，免得正文变成一屏
        log = "\n".join(lines[:12]) + "\n\n……共 %d 条，完整记录见 CHANGELOG.md" % len(lines)
    else:
        log = "\n".join(lines)

    runs = ["istore-pilot_%s_x86_64.run" % full,
            "istore-pilot_%s_arm64.run" % full,
            "istore-pilot_%s_armv7.run" % full,
            "istore-pilot_%s.run" % full]

    return """## 装哪个版本

先确认路由器系统版本 —— iStoreOS 25.12 把包管理器从 `opkg` 换成了 `apk`，
两边的包**格式不同、互不通用**：

```sh
grep DISTRIB_RELEASE /etc/openwrt_release
```

| 你的系统 | 包管理器 | 路由器端可装 | 说明 |
|---|---|---|---|
| **24.10 及更早**（含 22.03） | `opkg` | `.run` 或 `.ipk` | 两种都行，ipk 能被「软件包」页管理 |
| **25.12 及以后** | `apk` | **只有 `.run`** | `.ipk` 在 25.12 上会报 `opkg: not found` |

`.run` 两种系统通吃：它自己判断当前是 `opkg` 还是 `apk`，缺依赖也按对应的包管理器补装。
**拿不准就装 `.run`。**

## 本次更新

%s

## 下载

| 文件 | 装在哪 | 说明 |
|---|---|---|
| `%s` | 路由器（Intel/AMD） | 自解压单文件，含 Android APK |
| `%s` | 路由器（ARM64） | 主流 ARM 软路由 |
| `%s` | 路由器（ARMv7） | 老一点的 ARM |
| `%s` | 路由器（通用） | 不确定架构就选这个 |
| `istoreos-%s.apk` | Android 手机 | 连路由器用 |

> 路由器的四个包**内容完全相同**（载荷是纯 Python），架构只影响文件名与自检提示。
> 任选其一，不要同时装两个。
>
> 如果本页还带了 `luci-app-istore-agent_*.ipk`，它**只能装在 24.10 及更早** ——
> 25.12 没有 `opkg`，装不上。

## 安装

```sh
sh istore-pilot_%s_arm64.run --check   # 先看环境与架构
sh istore-pilot_%s_arm64.run           # 再装
```

装完打开 `http://<路由器IP>:8443` 或手机 App。安装包不会改动任何网络 / 防火墙 / DHCP 配置。
""" % (log, runs[0], runs[1], runs[2], runs[3], ver, full, full)


def shown(text: str) -> bool:
    return bool(text and text.strip())


# ---------------------------------------------------------------- 主流程

def main() -> int:
    args = sys.argv[1:]
    dry = "--dry-run" in args
    skip_build = "--skip-build" in args
    skip_checks = "--skip-checks" in args

    notes_file = ""
    for i, a in enumerate(args):
        if a == "--notes" and i + 1 < len(args):
            notes_file = args[i + 1]
        elif a.startswith("--notes="):
            notes_file = a.split("=", 1)[1]

    ver, rev = version()
    tag = "v" + ver
    full = "%s-%d" % (ver, rev)
    print("\n=== 发布 %s（revision %d）===" % (tag, rev))

    if not skip_checks and preflight() != 0:
        return 2

    tok = token()
    if not tok:
        print("! 没有可用的 GitHub 凭据：设 GITHUB_TOKEN，或先 git 登录一次")
        return 2

    status, me = api("GET", "/user", tok)
    if status != 200:
        print("! 凭据无效：%s" % me.get("message"))
        return 2
    print("  身份：%s" % me.get("login"))

    # 1) APK 同步
    if not skip_build:
        apk = sync_apk(ver, dry)
        if not apk:
            return 3
        if build_run(dry) != 0:
            print("! build_run 失败")
            return 3
    else:
        apk = os.path.join(DIST, "istoreos-%s.apk" % ver)

    # 2) 组装资产清单
    assets = [os.path.join(DIST, "istore-pilot_%s%s.run" % (full, sfx))
              for sfx in ("_x86_64", "_arm64", "_armv7", "")]
    assets.append(apk)
    ipk = os.path.join(DIST, "luci-app-istore-agent_%s_all.ipk" % full)
    if "--ipk" in args and os.path.exists(ipk):
        assets.append(ipk)

    missing = [p for p in assets if not os.path.exists(p)]
    if missing:
        print("! 缺文件：%s" % ", ".join(os.path.basename(p) for p in missing))
        return 3
    print("  资产：%s" % ", ".join(os.path.basename(p) for p in assets))

    # 3) 提交并推送
    if not dry:
        dirty = sh(["git", "status", "--porcelain"]).stdout.strip()
        if dirty:
            sh(["git", "add", "-A"])
            msg = "release: %s\n\n- 同步 APK 与四份 .run\n- 详见 CHANGELOG" % tag
            sh(["git", "commit", "-m", msg])
            print("  已提交 %s" % tag)
        else:
            print("  工作区干净，没有需要提交的改动")
        push = sh(["git", "push", "origin", "HEAD"], check=False)
        if push.returncode != 0:
            print("! push 失败：%s" % (push.stderr.strip()[:300]))
            return 4
        print("  代码已推送")

        # 4) tag
        existing = sh(["git", "tag", "-l", tag]).stdout.strip()
        if not existing:
            sh(["git", "tag", "-a", tag, "-m", "iStore Pilot %s" % full])
        sh(["git", "push", "origin", tag], check=False)
        print("  tag %s 已推送" % tag)

    # 5) Release
    status, rel = api("GET", "/repos/%s/releases/tags/%s" % (REPO, tag), tok)
    if status == 200:
        # 已经建过：只补传缺的资产，不重复创建（重复创建会 422）
        have = {a["name"] for a in rel.get("assets", [])}
        todo = [p for p in assets if os.path.basename(p) not in have]
        if not todo:
            print("  Release %s 已存在且资产齐全：%s" % (tag, rel.get("html_url")))
            if "--update-notes" in args and not dry:
                body = (open(notes_file, encoding="utf-8").read() if notes_file
                        else notes_for(tag, ver, full))
                code = patch_body(rel["id"], body, tok)
                print("  正文已更新：HTTP %s" % code)
            return 0
        print("  Release %s 已存在，补传 %d 个缺失资产" % (tag, len(todo)))
        assets = todo
    else:
        body = (open(notes_file, encoding="utf-8").read() if notes_file
                else notes_for(tag, ver, full))
        payload = {"tag_name": tag, "name": "%s — iStore Pilot" % tag,
                   "body": body, "draft": False, "prerelease": False}
        if dry:
            print("  [dry] 创建 Release %s，上传 %d 个资产" % (tag, len(assets)))
            return 0

        status, rel = api("POST", "/repos/%s/releases" % REPO, tok, payload)
        if status not in (200, 201):
            print("! 创建 Release 失败 %s：%s" % (status, rel.get("message")))
            return 5
        print("  Release 已创建：%s" % rel.get("html_url"))

    ok = 0
    for path in assets:
        code, info = upload(rel["id"], path, tok)
        if code in (200, 201):
            ok += 1
            print("    ✓ %s（%.2f MB）" % (os.path.basename(path),
                                          os.path.getsize(path) / 1048576))
        else:
            print("    ✗ %s：%s" % (os.path.basename(path), info.get("message")))

    print("\n完成：上传 %d/%d，Release %s\n" % (ok, len(assets), rel.get("html_url")))
    return 0 if ok == len(assets) else 6


if __name__ == "__main__":
    sys.exit(main())
