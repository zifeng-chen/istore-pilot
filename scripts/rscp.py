#!/usr/bin/env python3
"""上传本地文件到路由器。

用法:
    ROUTER_PW=xxx python rscp.py <本地路径> <远端路径>

凭据从环境变量读取，不落盘。
"""
import os
import sys

import paramiko


def main() -> int:
    if len(sys.argv) != 3:
        print("用法: rscp.py <本地路径> <远端路径>", file=sys.stderr)
        return 2

    host = os.environ.get("ROUTER_HOST", "192.168.100.1")
    port = int(os.environ.get("ROUTER_PORT", "22"))
    user = os.environ.get("ROUTER_USER", "root")
    pw = os.environ.get("ROUTER_PW")
    if not pw:
        print("缺少 ROUTER_PW 环境变量", file=sys.stderr)
        return 2

    local, remote = sys.argv[1], sys.argv[2]
    if not os.path.isfile(local):
        print(f"本地文件不存在: {local}", file=sys.stderr)
        return 2

    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(hostname=host, port=port, username=user, password=pw, timeout=15)
    try:
        # 这台机器的 sftp-server 对 /tmp 写入会报 ENOENT，
        # 改用 exec 通道 + cat 重定向，不依赖 sftp 子系统。
        with open(local, "rb") as fh:
            data = fh.read()
        stdin, stdout, stderr = client.exec_command(
            f"cat > '{remote}' && wc -c < '{remote}'", timeout=120
        )
        stdin.write(data)
        stdin.channel.shutdown_write()
        out = stdout.read().decode("utf-8", "replace").strip()
        err = stderr.read().decode("utf-8", "replace").strip()
        rc = stdout.channel.recv_exit_status()
        if rc != 0:
            print(f"上传失败: {err or 'exit %d' % rc}", file=sys.stderr)
            return 1
        print(f"已上传 {os.path.basename(local)} -> {remote} ({out} 字节)")
    finally:
        client.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
