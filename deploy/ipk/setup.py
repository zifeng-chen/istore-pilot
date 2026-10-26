#!/usr/bin/env python3
"""首次安装 / 重置密码 / 抓取周边服务凭据。

由 ipk 的 postinst 调用，也可以在路由器上手动跑：

    python3 /usr/lib/istore-agent/setup.py              # 补全配置，不动已有密码
    python3 /usr/lib/istore-agent/setup.py --reset      # 重置成随机密码
    python3 /usr/lib/istore-agent/setup.py --password x # 指定密码

设计要点：
  - **幂等**：升级时不能覆盖用户改过的密码和 clash secret，所以只在缺失时补。
  - **尽量自动填**：OpenClash 的 controller secret 能读就直接读，
    省得用户装完 App 发现「代理页全是 —」还要回来手动配。
  - **初始密码可查**：随机密码写到 /etc/istore-agent/INITIAL_PASSWORD（0600），
    LuCI 状态页会读它显示一次，用户装上 App 就能登录。
"""
from __future__ import annotations

import json
import os
import secrets
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

CONF_DIR = "/etc/istore-agent"
CONF_PATH = os.path.join(CONF_DIR, "config.json")
INITIAL = os.path.join(CONF_DIR, "INITIAL_PASSWORD")


def _run(cmd: list[str], timeout: float = 6.0) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True,
                              timeout=timeout).stdout.strip()
    except Exception:
        return ""


def _openclash_secret() -> str:
    """OpenClash 的 controller 密钥。读不到就让用户自己配。"""
    sec = _run(["uci", "get", "openclash.config", "secret"])
    if sec and sec != "uci: Entry not found":
        return sec
    # 有些版本把 secret 写在运行配置里
    import glob
    for path in glob.glob("/etc/openclash/*.yaml"):
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    line = line.strip()
                    if line.startswith("secret:"):
                        return line.split(":", 1)[1].strip().strip("'\"")
        except OSError:
            continue
    return ""


def _openclash_port() -> int:
    raw = _run(["uci", "get", "openclash.config", "cn_port"]) or "9090"
    try:
        return int(raw)
    except ValueError:
        return 9090


def main() -> int:
    reset = "--reset" in sys.argv
    want = ""
    if "--password" in sys.argv:
        idx = sys.argv.index("--password")
        if idx + 1 < len(sys.argv):
            want = sys.argv[idx + 1].strip()

    from agent import config  # noqa: E402  （sys.path 已处理）

    os.makedirs(CONF_DIR, mode=0o700, exist_ok=True)

    existed = os.path.exists(CONF_PATH)
    data = config.load()

    # 密码：只在「首次安装 / 明确要求重置」时改
    first_password = ""
    if reset or want or not existed:
        pwd = want or secrets.token_urlsafe(9)
        data["auth"]["password"] = pwd
        first_password = pwd
    elif data["auth"].get("password") in ("", "changeme"):
        # 之前的版本可能留下默认口令，顺手换掉
        pwd = secrets.token_urlsafe(9)
        data["auth"]["password"] = pwd
        first_password = pwd

    # OpenClash secret：为空才填，不覆盖
    if not data["clash"].get("secret"):
        sec = _openclash_secret()
        if sec:
            data["clash"]["secret"] = sec
            data["clash"]["controller_port"] = _openclash_port()

    if not config.save(data):
        print("!! 写入配置失败", file=sys.stderr)
        return 1

    if first_password:
        try:
            with open(INITIAL, "w", encoding="utf-8") as fh:
                fh.write(first_password + "\n")
            os.chmod(INITIAL, 0o600)
        except OSError:
            pass
        print(f"初始登录密码：{first_password}")
    else:
        print("配置已补全，密码保持不变")

    print(f"配置文件：{CONF_PATH}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
