#!/usr/bin/env python3
"""验证 LuCI 改配置能生效：临时把端口改成 8444 再改回 8443。

这是「能在网页端管理」的核心承诺，必须实测。脚本用 try/finally 保证
无论中间出什么错都会把端口还原，避免把 App 的连接地址搞丢。
"""
import os
import re
import sys
import time

import paramiko


def main() -> int:
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect("192.168.100.1", 22, "root", os.environ["ROUTER_PW"],
              timeout=12, allow_agent=False, look_for_keys=False)

    def run(cmd, t=90):
        _, o, e = c.exec_command(cmd, timeout=t)
        return (o.read() + e.read()).decode("utf-8", "replace").strip()

    def listening(port):
        out = run(f"netstat -lnt 2>/dev/null | grep ':{port} '")
        return bool(out), out

    def curl_health(port):
        return run(f"curl -s -m 5 http://192.168.100.1:{port}/api/v1/health")

    try:
        print("--- 改端口 8443 → 8444 ---")
        print(run("uci set istore-agent.main.port='8444'; uci commit istore-agent; "
                  "/etc/init.d/istore-agent restart; sleep 3; "
                  "uci get istore-agent.main.port"))
        ok, out = listening(8444)
        print(f"8444 监听: {ok}  {out}")
        print("健康接口:", curl_health(8444))
        ok_old, _ = listening(8443)
        print(f"8443 已释放: {not ok_old}")

        print("\n--- 关闭开关 enabled=0 ---")
        print(run("uci set istore-agent.main.enabled='0'; uci commit istore-agent; "
                  "/etc/init.d/istore-agent restart; sleep 3; "
                  "uci get istore-agent.main.enabled"))
        ok, _ = listening(8444)
        print(f"8444 仍在监听: {ok}  (应为 False)")
        print(run("/etc/init.d/istore-agent status 2>&1; echo rc=$?"))
    finally:
        print("\n--- 还原 8443 并启用 ---")
        print(run("uci set istore-agent.main.port='8443'; "
                  "uci set istore-agent.main.enabled='1'; uci commit istore-agent; "
                  "/etc/init.d/istore-agent restart; sleep 3; "
                  "uci show istore-agent"))
        ok, out = listening(8443)
        print(f"8443 恢复监听: {ok}  {out}")
        print("健康接口:", curl_health(8443))
        c.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
