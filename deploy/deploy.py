#!/usr/bin/env python3
"""把 Agent 部署到 iStoreOS。

用法:
    ROUTER_PW=xxx AGENT_PASSWORD=xxx python deploy/deploy.py
可选环境变量:
    ROUTER_HOST / ROUTER_PORT / ROUTER_USER
    AGENT_PORT (默认 8443)
    AGENT_BIND (默认 0.0.0.0；填具体 LAN 地址则只监听内网，
                但 LAN 地址改动后会自动退到 0.0.0.0 重绑)
"""

from __future__ import annotations

import io
import json
import os
import posixpath
import sys
import tarfile
import time

import paramiko

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REMOTE_DIR = "/usr/lib/istore-agent"
CONF_DIR = "/etc/istore-agent"
CONF_PATH = f"{CONF_DIR}/config.json"
INITD = "/etc/init.d/istore-agent"

INCLUDE = ["agent", "web", "run.py"]


def agent_version() -> str:
    import re
    with open(os.path.join(ROOT, "agent", "server.py"), "r", encoding="utf-8") as fh:
        m = re.search(r'^VERSION\s*=\s*"([^"]+)"', fh.read(), re.M)
    return m.group(1) if m else "0.0.0"


def build_tarball() -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for item in INCLUDE:
            tar.add(os.path.join(ROOT, item), arcname=item)
    return buf.getvalue()


def connect() -> paramiko.SSHClient:
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(
        hostname=os.environ.get("ROUTER_HOST", "192.168.100.1"),
        port=int(os.environ.get("ROUTER_PORT", "22")),
        username=os.environ.get("ROUTER_USER", "root"),
        password=os.environ["ROUTER_PW"],
        timeout=12,
        allow_agent=False,
        look_for_keys=False,
    )
    return client


def run(client: paramiko.SSHClient, cmd: str, timeout: float = 60) -> tuple[int, str]:
    _, stdout, stderr = client.exec_command(cmd, timeout=timeout)
    out = stdout.read().decode("utf-8", "replace") + stderr.read().decode("utf-8", "replace")
    return stdout.channel.recv_exit_status(), out


def main() -> int:
    # 不内置口令：AGENT_PASSWORD 是装好后 Agent 的登录口令，
    # 没单独给就沿用 SSH 口令（用户习惯全站一个密码）。
    password = os.environ.get("AGENT_PASSWORD") or os.environ.get("ROUTER_PW")
    if not password:
        print("!! 缺少口令。请先设置环境变量再运行，例如：")
        print("   ROUTER_PW='你的SSH口令' AGENT_PASSWORD='你的SSH口令' python deploy/deploy.py")
        return 2
    port = os.environ.get("AGENT_PORT", "8443")
    bind = os.environ.get("AGENT_BIND", "0.0.0.0")

    client = connect()
    sftp = client.open_sftp()

    blob = build_tarball()
    with sftp.open("/tmp/istore-agent.tar.gz", "wb") as fh:
        fh.write(blob)
    print(f"上传完成 {len(blob)/1024:.0f} KB")

    with sftp.open("/tmp/istore-agent.init", "w") as fh:
        with open(os.path.join(ROOT, "deploy", "istore-agent.init"), "r", encoding="utf-8") as src:
            fh.write(src.read())

    steps = [
        f"mkdir -p {REMOTE_DIR} {CONF_DIR}",
        f"tar xzf /tmp/istore-agent.tar.gz -C {REMOTE_DIR}",
        f"cp /tmp/istore-agent.init {INITD} && chmod 755 {INITD}",
        f"chmod 700 {CONF_DIR}",
        # LuCI 状态页读这个文件显示版本号；不打 ipk 直接 deploy 时没人写它，
        # 页面就会一直显示装机时的旧版本
        f"echo '{agent_version()}' > {REMOTE_DIR}/VERSION",
    ]
    for step in steps:
        code, out = run(client, step)
        if code != 0:
            print(f"失败: {step}\n{out}")
            return 1

    # 配置：先读回现有内容再合并，只强制覆盖「管理密码」，
    # 其余字段（监听地址、clash secret、adguard 账号）保持用户改过的值。
    # 全站统一口令是明确需求，所以每次部署都同步，不再"存在就跳过"。
    code, raw = run(client, f"cat {CONF_PATH} 2>/dev/null")
    conf = None
    try:
        conf = json.loads(raw)
    except (ValueError, TypeError):
        conf = None

    if not isinstance(conf, dict):
        conf = {
            "listen": {"host": bind, "port": int(port)},
            "auth": {"password": password, "token_ttl": 604800, "rate_limit_per_min": 30},
            "clash": {
                "controller_host": "127.0.0.1",
                "controller_port": 9090,
                "secret": "",
                "delay_url": "http://www.gstatic.com/generate_204",
            },
            "sample": {"interval": 60, "retain_days": 7},
        }
        print("写入初始配置")
    else:
        conf.setdefault("listen", {"host": bind, "port": int(port)})
        print("配置已存在，仅同步管理密码")

    auth = conf.setdefault("auth", {})
    auth["password"] = password
    auth.setdefault("token_ttl", 604800)
    auth.setdefault("rate_limit_per_min", 30)

    # 从 OpenClash 读 secret 并**在本地**写进 JSON。
    # 原来是写完文件再 `sed -i`：secret 里只要有一个 `'` 或 `/`，
    # 这条命令就断了（甚至能把后面的 shell 一起改写）。
    code, secret = run(client, "uci get openclash.config.dashboard_password 2>/dev/null")
    secret = secret.strip()
    if secret and code == 0:
        conf.setdefault("clash", {})["secret"] = secret
        print("已同步 OpenClash secret")

    with sftp.open(CONF_PATH, "w") as fh:
        fh.write(json.dumps(conf, ensure_ascii=False, indent=2))
    run(client, f"chmod 600 {CONF_PATH}")

    run(client, f"{INITD} enable")
    run(client, f"{INITD} restart")
    time.sleep(2)

    code, out = run(client, f"{INITD} status; netstat -lnt | grep {port}")
    print(out.strip() or "(无监听输出)")

    code, log = run(client, "logread | grep istore-agent | tail -5")
    if log.strip():
        print("--- log ---")
        print(log.strip())

    sftp.close()
    client.close()
    # 不打印口令：CI 日志、终端回滚区、共享屏幕都会把它带走
    print(f"\n访问地址: http://{bind}:{port}  (管理密码与 SSH / 后台 / AdGuard 一致)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
