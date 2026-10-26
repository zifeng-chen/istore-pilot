#!/usr/bin/env python3
"""从 Windows 远程操作 Mac（192.168.100.229）。

    python scripts/mac.py run "命令"                 # 执行 shell 命令
    python scripts/mac.py put  本地文件 远端路径      # 上传单文件
    python scripts/mac.py get  远端文件 本地路径      # 下载单文件
    python scripts/mac.py sync 本地目录 远端目录      # 递归上传（自动跳过构建产物）
    python scripts/mac.py ping                       # 连通性 + 环境自检

认证优先级：SSH 密钥（~/.ssh/id_ed25519_mac）> 环境变量 MAC_PW。
凭据不落盘。
"""

from __future__ import annotations

import os
import posixpath
import stat
import sys

import paramiko

HOST = os.environ.get("MAC_HOST", "192.168.100.229")
PORT = int(os.environ.get("MAC_PORT", "22"))
USER = os.environ.get("MAC_USER", "chen")
PW = os.environ.get("MAC_PW", "")
KEY = os.path.expanduser(os.environ.get("MAC_KEY", "~/.ssh/id_ed25519_mac"))

# 同步目录时跳过的产物
SKIP_DIRS = {
    ".git", "node_modules", "oh_modules", ".hvigor", "build", ".gradle",
    "DerivedData", ".idea", ".dart_tool", "Pods", "__pycache__", ".vs",
}
SKIP_FILES = {".DS_Store", "Thumbs.db"}

BASE_PATH = (
    "export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:"
    "/usr/sbin:/sbin:$PATH; "
)


def connect() -> paramiko.SSHClient:
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    kw = dict(
        hostname=HOST, port=PORT, username=USER,
        timeout=12, banner_timeout=12, auth_timeout=12,
        allow_agent=False,
    )
    if os.path.exists(KEY):
        kw["key_filename"] = KEY
        kw["look_for_keys"] = False
        if PW:
            kw["passphrase"] = PW
    else:
        kw["password"] = PW
        kw["look_for_keys"] = False
    c.connect(**kw)
    return c


def _exec(c: paramiko.SSHClient, cmd: str, timeout: int = 3600):
    _, out, err = c.exec_command(BASE_PATH + cmd, timeout=timeout, get_pty=False)
    return out, err


def run(cmd: str) -> int:
    c = connect()
    try:
        out, err = _exec(c, cmd)
        for line in iter(out.readline, ""):
            sys.stdout.write(line)
            sys.stdout.flush()
        e = err.read().decode("utf-8", "replace")
        if e:
            sys.stderr.write(e)
        return out.channel.recv_exit_status()
    finally:
        c.close()


def _norm_remote(p: str) -> str:
    """挡住 Git Bash 把 /Users/... 翻译成 C:/Program Files/... 的坑。"""
    if len(p) > 2 and p[1] == ":" and p[0].isalpha():
        raise SystemExit(
            f"远端路径被 MSYS 翻译成了 {p!r}。请在这条命令前加 MSYS_NO_PATHCONV=1"
        )
    return p


def _mkdirs(sftp, remote: str) -> None:
    parts = [p for p in remote.split("/") if p]
    cur = "/" if remote.startswith("/") else ""
    for p in parts:
        cur = posixpath.join(cur, p) if cur else p
        try:
            sftp.stat(cur)
        except IOError:
            sftp.mkdir(cur)


def put(local: str, remote: str) -> int:
    c = connect()
    try:
        remote = _norm_remote(remote)
        sftp = c.open_sftp()
        _mkdirs(sftp, posixpath.dirname(remote))
        sftp.put(local, remote)
        print(f"{local} -> {remote}")
        return 0
    finally:
        c.close()


def get(remote: str, local: str) -> int:
    c = connect()
    try:
        remote = _norm_remote(remote)
        sftp = c.open_sftp()
        os.makedirs(os.path.dirname(os.path.abspath(local)), exist_ok=True)
        sftp.get(remote, local)
        print(f"{remote} -> {local}")
        return 0
    finally:
        c.close()


def sync(local_root: str, remote_root: str) -> int:
    """递归上传，只覆盖内容有变化的文件。"""
    local_root = os.path.abspath(local_root)
    remote_root = _norm_remote(remote_root)
    c = connect()
    n_new = n_skip = 0
    try:
        sftp = c.open_sftp()
        _mkdirs(sftp, remote_root)
        for dirpath, dirnames, filenames in os.walk(local_root):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            rel = os.path.relpath(dirpath, local_root).replace("\\", "/")
            rdir = remote_root if rel == "." else posixpath.join(remote_root, rel)
            _mkdirs(sftp, rdir)
            for f in filenames:
                if f in SKIP_FILES or f.endswith((".pyc", ".log")):
                    continue
                lp = os.path.join(dirpath, f)
                rp = posixpath.join(rdir, f)
                try:
                    if sftp.stat(rp).st_size == os.path.getsize(lp):
                        age_l = os.path.getmtime(lp)
                        age_r = sftp.stat(rp).st_mtime
                        if abs(age_l - age_r) < 2:
                            n_skip += 1
                            continue
                except IOError:
                    pass
                sftp.put(lp, rp)
                # 让远端 mtime 跟本地一致，下次可跳过
                try:
                    sftp.utime(rp, (os.path.getmtime(lp), os.path.getmtime(lp)))
                except Exception:
                    pass
                n_new += 1
                if n_new % 40 == 0:
                    print(f"  ... 已传 {n_new} 个")
        print(f"同步完成：上传 {n_new}，跳过 {n_skip}  ->  {USER}@{HOST}:{remote_root}")
        return 0
    finally:
        c.close()


def ping() -> int:
    probe = (
        'echo "user=$(whoami) host=$(hostname)";'
        ' sw_vers -productVersion; uname -m;'
        ' echo "--- xcode ---"; xcodebuild -version 2>&1 | head -3;'
        ' xcode-select -p 2>&1;'
        ' echo "--- DevEco / 鸿蒙 ---";'
        ' ls -d /Applications/DevEco-Studio*.app 2>/dev/null;'
        ' ls ~/Library/Huawei/Sdk 2>/dev/null;'
        ' which node java hvigorw ohpm hdc 2>/dev/null;'
        ' echo "--- 签名 ---"; security find-identity -v -p codesigning 2>&1 | tail -5'
    )
    return run(probe)


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    mode = sys.argv[1]
    if mode == "run":
        return run(" ".join(sys.argv[2:]))
    if mode == "put" and len(sys.argv) == 4:
        return put(sys.argv[2], sys.argv[3])
    if mode == "get" and len(sys.argv) == 4:
        return get(sys.argv[2], sys.argv[3])
    if mode == "sync" and len(sys.argv) == 4:
        return sync(sys.argv[2], sys.argv[3])
    if mode == "ping":
        return ping()
    print(__doc__)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
