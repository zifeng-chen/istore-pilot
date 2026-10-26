#!/usr/bin/env python3
"""把打好的 ipk 传到路由器并安装 / 升级。

用法：
    ROUTER_PW=xxx python deploy/install_ipk.py

先试正常 `opkg install`：版本号变大就会走升级路径，conffiles 里用户改过的
配置会被保留。只有装不动时才退回「修权限 + 强删 + 重装」的兜底 —— 那是上次
遇到损坏状态（control 脚本没有执行位，包卡在「已安装但配置失败」）时的治法，
副作用是 opkg 会把冲突的配置另存成 /etc/config/xxx-opkg，事后要手工清。
"""
import os
import sys

import paramiko

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG = "luci-app-istore-agent"
DIST = os.path.join(ROOT, "dist")
REMOTE = "/tmp/ia.ipk"


def newest_ipk() -> str:
    names = [n for n in os.listdir(DIST) if n.startswith(PKG) and n.endswith(".ipk")]
    if not names:
        raise SystemExit("没有找到 ipk，先跑 python deploy/build_ipk.py --with-apk")
    names.sort(key=lambda n: os.path.getmtime(os.path.join(DIST, n)))
    return os.path.join(DIST, names[-1])


def main() -> int:
    local = newest_ipk()
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect("192.168.100.1", 22, "root", os.environ["ROUTER_PW"],
              timeout=12, allow_agent=False, look_for_keys=False)

    def run(cmd, t=240):
        _, o, e = c.exec_command(cmd, timeout=t)
        out = o.read().decode("utf-8", "replace") + e.read().decode("utf-8", "replace")
        return o.channel.recv_exit_status(), out.strip()

    sftp = c.open_sftp()
    sftp.put(local, REMOTE)
    print(f"上传 {os.path.basename(local)} ({os.path.getsize(local)/1048576:.1f} MB)")

    code, out = run(f"opkg install {REMOTE} 2>&1")
    print(f"--- opkg install 退出码 {code} ---")
    print(out)

    if code != 0:
        print("\n--- 兜底：修权限 + 强删 + 重装 ---")
        for cmd in [
            f"chmod 755 /usr/lib/opkg/info/{PKG}.* 2>/dev/null; true",
            f"opkg remove --force-remove {PKG} 2>&1; true",
            f"rm -f /usr/lib/opkg/info/{PKG}.* /etc/config/{PKG}-opkg 2>/dev/null; true",
        ]:
            _, o = run(cmd)
            if o:
                print(f"$ {cmd}\n{o}")
        code, out = run(f"opkg install {REMOTE} 2>&1")
        print(f"--- 重装退出码 {code} ---")
        print(out)

    _, out = run(f"opkg list-installed | grep {PKG}; "
                 f"ls -l /usr/lib/opkg/info/{PKG}.postinst 2>&1")
    print("--- 安装结果 ---")
    print(out)

    sftp.close()
    c.close()
    return code


if __name__ == "__main__":
    sys.exit(main())
