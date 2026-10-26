"""核对 App 依赖的接口字段是否真实存在。

原生界面的每个数值都靠字段名对齐，字段名写错不会报错，
只会安静地显示成「—」。这个脚本就是把用到的那几个字段真跑一遍。
"""

import json
import os
import sys
import urllib.request

BASE = "http://192.168.100.1:8443"
PASSWORD = os.environ.get("ROUTER_PW", "")   # 口令从环境变量读，不写进仓库


def req(path, body=None, token=None):
    data = None
    headers = {"Accept": "application/json"}
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = "Bearer " + token
    r = urllib.request.Request(BASE + path, data=data, headers=headers,
                               method="POST" if body is not None else "GET")
    with urllib.request.urlopen(r, timeout=15) as resp:
        return json.loads(resp.read().decode())


def walk(obj, path=""):
    return obj


def main():
    login = req("/api/v1/login", {"password": PASSWORD})
    token = login["token"]
    print("login ok, ttl=", login.get("ttl"), "expires_at=", login.get("expires_at"))

    ov = req("/api/v1/overview", token=token)
    print("\n[overview] top keys:", sorted(ov.keys()))
    print("  board:", sorted((ov.get("board") or {}).keys()))
    print("  cpu:", sorted((ov.get("cpu") or {}).keys()), "percent=", ov["cpu"]["percent"])
    print("  memory:", sorted((ov.get("memory") or {}).keys()), "percent=", ov["memory"]["percent"])
    print("  load:", ov.get("load"))
    print("  uptime:", ov.get("uptime"))
    print("  temperature[0]:", (ov.get("temperature") or [{}])[0])

    net = ov.get("network") or {}
    wan = net.get("wan") or {}
    print("  wan keys:", sorted(wan.keys()))
    print("  wan proto/up/l3/uptime:", wan.get("proto"), wan.get("up"),
          wan.get("l3_device"), wan.get("uptime"))
    print("  wan ipv4[0]:", (wan.get("ipv4") or [{}])[0])
    print("  wan ipv6 count:", len(wan.get("ipv6") or []),
          "first:", (wan.get("ipv6") or [{}])[0])
    print("  wan dns:", wan.get("dns"), "gateway:", wan.get("gateway"))
    ports = net.get("ports") or []
    print("  ports:", len(ports), "first:", ports[0] if ports else None)
    st = ov.get("storage") or []
    print("  storage:", len(st), "first:", st[0] if st else None)

    n = req("/api/v1/network", token=token)
    print("\n[network] keys:", sorted(n.keys()),
          "lan ipv4:", (n.get("lan", {}).get("ipv4") or [{}])[0])

    cl = req("/api/v1/clients", token=token)
    print("\n[clients]", len(cl.get("clients") or []),
          "first:", (cl.get("clients") or [{}])[0])

    px = req("/api/v1/proxy", token=token)
    print("\n[proxy] keys:", sorted(px.keys()), "active:", px.get("active"))
    for b in px.get("backends") or []:
        print("   backend:", b.get("id"), b.get("label"), "running=", b.get("running"),
              "installed=", b.get("installed"), "nodes=", b.get("node_count"),
              "engine=", b.get("engine"))

    g = req("/api/v1/proxy/groups", token=token)
    print("\n[proxy/groups] keys:", sorted(g.keys()), "backend:", g.get("backend"),
          "node_count:", g.get("node_count"), "error:", g.get("error"))
    groups = g.get("groups") or []
    if groups:
        g0 = groups[0]
        print("   group[0] keys:", sorted(g0.keys()), "name=", g0.get("name"),
              "now=", g0.get("now"), "members=", len(g0.get("members") or []))
        m0 = (g0.get("members") or [{}])[0]
        print("   member[0]:", m0)

    mode = req("/api/v1/proxy/mode", token=token)
    print("   mode:", mode)

    ab = req("/api/v1/adblock", token=token)
    print("\n[adblock] keys:", sorted(ab.keys()))
    print("   installed/running/mode:", ab.get("installed"), ab.get("running"),
          ab.get("mode"), ab.get("mode_label"))
    print("   listening:", ab.get("listening"), "dnsmasq_port:", ab.get("dnsmasq_port"))
    print("   filters:", ab.get("filters") if not isinstance(ab.get("filters"), dict)
          else {k: v for k, v in ab["filters"].items() if k != "lists"})
    print("   stats:", ab.get("stats"))

    probe = req("/api/v1/adblock/preflight", token=token)
    print("\n[adblock/preflight] ready:", probe.get("ready"),
          "checks:", [(c.get("id"), c.get("ok")) for c in probe.get("checks") or []])

    pw = req("/api/v1/power", token=token)
    print("\n[power] actions:", [a.get("id") for a in pw.get("actions") or []],
          "last:", pw.get("last_action"))

    print("\nDONE")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # noqa: BLE001
        print("FAILED:", type(exc).__name__, exc)
        sys.exit(1)
