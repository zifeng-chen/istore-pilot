"""验证规则更新配置接口（读 / 改间隔 / 改回来 / 单表开关）。"""
import json
import os
import urllib.request

BASE = "http://192.168.100.1:8443"
PW = os.environ.get("ROUTER_PW", "")   # 口令从环境变量读，不写进仓库


def call(path, body=None, token=None):
    data = json.dumps(body).encode() if body is not None else None
    h = {"Accept": "application/json", "Content-Type": "application/json"}
    if token:
        h["Authorization"] = "Bearer " + token
    r = urllib.request.Request(BASE + path, data=data, headers=h,
                               method="POST" if body is not None else "GET")
    with urllib.request.urlopen(r, timeout=90) as resp:
        return json.loads(resp.read().decode())


tok = call("/api/v1/login", {"password": PW}).get("token")
print("token ok:", bool(tok))

r = call("/api/v1/adblock/rules", token=tok)
print("\n== 读规则配置 ==")
print("ok:", r.get("ok"), "auto:", r.get("auto"), "interval:", r.get("interval"),
      r.get("interval_label"))
print("下一轮:", r.get("next_update"), "剩余分钟:", r.get("minutes_left"))
print("规则总数:", r.get("total_rules"), "启用表:", r.get("enabled_lists"),
      "/", r.get("total_lists"), "失败:", r.get("failed"))
for f in r.get("lists", []):
    print("  -", f["name"], "| enabled =", f["enabled"], "| rules =", f["rules"],
          "|", f["last_updated"])

print("\n== 改成 12 小时 ==")
r2 = call("/api/v1/adblock/rules", {"action": "set_interval", "interval": 12}, tok)
print("ok:", r2.get("ok"), "interval:", r2.get("interval"), r2.get("interval_label"),
      r2.get("message") or r2.get("error"))

print("\n== 改回 24 小时 ==")
r3 = call("/api/v1/adblock/rules", {"action": "set_interval", "interval": 24}, tok)
print("ok:", r3.get("ok"), "interval:", r3.get("interval"), r3.get("message") or r3.get("error"))

# 单表开关：挑一个停用的表打开再关回去，验证 set_url 整条覆盖没丢字段
off = next((f for f in r3.get("lists", []) if not f["enabled"]), None)
if off:
    print("\n== 开关测试：", off["name"], "==")
    a = call("/api/v1/adblock/rules", {"action": "toggle", "id": off["id"], "enabled": True}, tok)
    print("启用 ->", a.get("ok"), a.get("message") or a.get("error"),
          "| rules:", a.get("total_rules"))
    b = call("/api/v1/adblock/rules", {"action": "toggle", "id": off["id"], "enabled": False}, tok)
    print("停用 ->", b.get("ok"), b.get("message") or b.get("error"),
          "| rules:", b.get("total_rules"))

# 网口 mac 字段
net = call("/api/v1/traffic", token=tok)
print("\n== 网口 ==")
for p in net.get("ports", []):
    print(" ", p["name"], p.get("role"), "up" if p["up"] else "down",
          p["speed_mbps"], "Mbps", p.get("mac", "(无 mac)"))
