"""路由器 SSH 执行小工具：python scripts/rsh.py "cmd" """
import os
import sys

import paramiko

HOST = os.environ.get("ROUTER_HOST", "192.168.100.1")
PW = os.environ.get("ROUTER_PW", "")   # 口令从环境变量读，不写进仓库


def main() -> int:
    cmd = " ".join(sys.argv[1:]) or "echo hi"
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username="root", password=PW, timeout=10)
    _in, out, err = c.exec_command(cmd, timeout=120)
    sys.stdout.write(out.read().decode("utf-8", "replace"))
    errs = err.read().decode("utf-8", "replace")
    if errs.strip():
        sys.stderr.write(errs)
    c.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
