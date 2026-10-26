"""LAN 改地址的端到端验证：改 → 不确认 → 自动回滚；再改 → 确认。

我的 PC 同时有 192.168.100.243 和 192.168.2.9，所以路由器在哪个网段都能连回去。
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

OLD = "192.168.100.1"
NEW = "192.168.2.1"
PW = os.environ.get("ROUTER_PW", "")   # 口令从环境变量读，不写进仓库


def req(base, path, body=None, token=None, timeout=12):
    h = {"Accept": "application/json"}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        h["Content-Type"] = "application/json"
    if token:
        h["Authorization"] = "Bearer " + token
    r = urllib.request.Request(base + path, data=data, headers=h,
                               method="POST" if body is not None else "GET")
    try:
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        return {"ok": False, "http": e.code, "body": e.read().decode()[:400]}
    except Exception as e:
        return {"ok": False, "err": f"{type(e).__name__}: {e}"}


def alive(base):
    d = req(base, "/api/v1/net/pending", timeout=4)
    return bool(d.get("ok"))


def wait_for(ip, want=True, limit=60):
    base = f"http://{ip}:8443"
    t0 = time.time()
    while time.time() - t0 < limit:
        if alive(base) == want:
            return time.time() - t0
        time.sleep(2)
    return -1


def main():
    tok = req(f"http://{OLD}:8443", "/api/v1/login", {"password": PW}).get("token")
    if not tok:
        print("登录失败"); return 1
    cur = req(f"http://{OLD}:8443", "/api/v1/net/lan", token=tok)
    print("改前:", cur["cidr"], "绑定", cur["bindings"], "条")

    mode = sys.argv[1] if len(sys.argv) > 1 else "rollback"

    r = req(f"http://{OLD}:8443", "/api/v1/net/lan",
            {"ipaddr": NEW, "netmask": "255.255.255.0",
             "dhcp_enabled": True, "dhcp_start": 100, "dhcp_limit": 150,
             "dhcp_lease": "24h", "static_action": "move"}, tok)
    print("提交:", json.dumps(r, ensure_ascii=False)[:600])
    if not r.get("ok"):
        return 1

    t = wait_for(NEW, True, 40)
    print(f"新地址 {NEW} 可达用时: {t:.0f}s" if t >= 0 else "新地址一直不可达")
    if t < 0:
        return 1

    pend = req(f"http://{NEW}:8443", "/api/v1/net/pending", token=tok)
    print("pending:", json.dumps(pend, ensure_ascii=False)[:300])
    lan = req(f"http://{NEW}:8443", "/api/v1/net/lan", token=tok)
    print("改后:", lan.get("cidr"), "池", lan.get("dhcp", {}).get("pool"),
          "绑定", lan.get("bindings"), "网段外", lan.get("bindings_outside"))

    if mode == "confirm":
        time.sleep(2)
        print("确认:", req(f"http://{NEW}:8443", "/api/v1/net/confirm",
                          {"token": r["token"]}, tok))
        print("确认后 pending:", req(f"http://{NEW}:8443", "/api/v1/net/pending", token=tok))
        print("确认后:", req(f"http://{NEW}:8443", "/api/v1/net/lan", token=tok).get("cidr"))
    else:
        print("不确认，等守护回滚…")
        t2 = wait_for(OLD, True, 150)
        print(f"旧地址 {OLD} 恢复用时: {t2:.0f}s" if t2 >= 0 else "旧地址没回来")
        back = req(f"http://{OLD}:8443", "/api/v1/net/lan", token=tok)
        print("回滚后:", back.get("cidr"), "绑定", back.get("bindings"),
              "网段外", back.get("bindings_outside"))
        print("pending:", req(f"http://{OLD}:8443", "/api/v1/net/pending", token=tok))
    return 0


if __name__ == "__main__":
    sys.exit(main())
