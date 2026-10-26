#!/usr/bin/env python3
"""在 iStoreOS 上执行远程命令的小工具。

用法:
    ROUTER_PW=xxx python rssh.py "ubus call system board"
    ROUTER_PW=xxx python rssh.py -f cmds.txt

凭据从环境变量读取，不落盘:
    ROUTER_HOST (默认 192.168.100.1)
    ROUTER_PORT (默认 22)
    ROUTER_USER (默认 root)
    ROUTER_PW
"""
import os
import sys

import paramiko


def main() -> int:
    host = os.environ.get("ROUTER_HOST", "192.168.100.1")
    port = int(os.environ.get("ROUTER_PORT", "22"))
    user = os.environ.get("ROUTER_USER", "root")
    pw = os.environ.get("ROUTER_PW")
    if not pw:
        print("缺少 ROUTER_PW 环境变量", file=sys.stderr)
        return 2

    if len(sys.argv) > 2 and sys.argv[1] == "-f":
        with open(sys.argv[2], "r", encoding="utf-8") as fh:
            cmd = fh.read()
    elif len(sys.argv) > 1:
        cmd = sys.argv[1]
    else:
        cmd = sys.stdin.read()

    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(
        hostname=host,
        port=port,
        username=user,
        password=pw,
        timeout=10,
        allow_agent=False,
        look_for_keys=False,
    )
    stdin, stdout, stderr = client.exec_command(cmd, timeout=60)
    out = stdout.read().decode("utf-8", "replace")
    err = stderr.read().decode("utf-8", "replace")
    if out:
        print(out, end="")
    if err:
        print("--- stderr ---", file=sys.stderr)
        print(err, end="", file=sys.stderr)
    client.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
