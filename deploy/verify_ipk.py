#!/usr/bin/env python3
"""装完 ipk 后的验收：服务、端口、接口、LuCI 菜单、uci 配置。"""
import os
import sys

import paramiko

CMDS = [
    ("包状态", "opkg list-installed | grep istore-agent"),
    ("uci 配置", "uci show istore-agent 2>&1"),
    ("服务状态", "/etc/init.d/istore-agent status 2>&1; echo rc=$?"),
    ("开机自启", "ls -l /etc/rc.d/ | grep istore-agent"),
    ("端口监听", "netstat -lnt 2>/dev/null | grep 8443"),
    ("健康接口", "curl -s -m 5 http://192.168.100.1:8443/api/v1/health"),
    ("LuCI 控制器", "ls -l /usr/lib/lua/luci/controller/istore_agent.lua "
                   "/usr/lib/lua/luci/view/istore_agent/"),
    ("LuCI 菜单索引", "rm -f /tmp/luci-indexcache*; "
                     "lua -e 'require(\"luci.dispatcher\")' 2>&1 | head -3; "
                     "grep -c istore_agent /tmp/luci-indexcache* 2>/dev/null || echo '(无缓存)'"),
    ("日志", "logread | grep istore-agent | tail -6"),
]


def main() -> int:
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect("192.168.100.1", 22, "root", os.environ["ROUTER_PW"],
              timeout=12, allow_agent=False, look_for_keys=False)

    for title, cmd in CMDS:
        _, o, e = c.exec_command(cmd, timeout=90)
        out = (o.read() + e.read()).decode("utf-8", "replace").strip()
        print(f"=== {title} ===")
        print(out or "(空)")

    c.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
