# Agent 接口参考

所有接口由 `agent/server.py` 提供，三端客户端与 Web 控制台共用这一份契约。

## 基础约定

| 项 | 值 |
|---|---|
| 基地址 | `http://<路由器地址>:8443/api/v1` |
| 协议 | HTTP/1.1，JSON（`Content-Type: application/json`） |
| 鉴权 | `Authorization: Bearer <token>` |
| 免鉴权 | `GET /ping`、`POST /login` |
| token 有效期 | 默认 7 天（`auth.token_ttl`，可配） |
| 登录限流 | 每 IP 默认 30 次/分钟 |

### 错误格式

```json
{ "ok": false, "error": "错误说明" }
```

| 状态码 | 含义 |
|---|---|
| 400 | 参数不合法 |
| 401 | 未带 token 或 token 无效 |
| 403 | 口令错误 / 当前密码不正确 |
| 404 | 路径不存在（含已下线的写接口） |
| 500 | 服务端处理异常 |

### 响应体两种形态

- **直接返回数据**：`overview`、`devices`、`adblock`、`proxy` 等首屏接口
- **`{ok, ts, data}` 包装**：`system/hardware`、`network/wan`，带时间戳便于判断新鲜度

### 登录

```bash
curl -X POST http://192.168.100.1:8443/api/v1/login \
     -H "Content-Type: application/json" \
     -d '{"password":"<口令>"}'
```

```json
{ "ok": true, "token": "...", "expires": 1793000000 }
```

后续请求带上 `Authorization: Bearer <token>`。

---

## 状态与概览

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/ping` | 无需鉴权。返回服务名、**真实版本号**、监听地址 |
| GET | `/health` | 健康检查 |
| GET | `/overview` | 概览页全部数据：主机、系统、内核、在线时长、CPU/内存/磁盘、负载温度、WAN 实时速率 |
| GET | `/traffic` | 实时总流量与速率 |
| GET | `/storage` | 磁盘挂载与占用 |
| GET | `/system/hardware` | 主板、CPU、内存条（SMBIOS）、网卡、NVMe 温度 |
| GET | `/system/firmware` | 固件更新检查。内部调 `/bin/ota check`，结果读 `/var/run/ota/`，自带 5 分钟缓存 |
| GET | `/system/update` | 软件包更新检查（`opkg`）。`?refresh=1` 会先跑 `opkg update`，慢源上要几分钟 |
| GET | `/system/uploads` | 已上传的安装包列表 |

> `ping` 的 `version` 必须用 `VERSION` 常量。之前写死过一个字符串，
> 导致设置页显示「Agent 版本 v0.1」而 `/health` 报真版本，两个接口自相矛盾。

## 网络

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/network` | 汇总：WAN/LAN、DNS、代理、拦截的整体状态 |
| GET | `/network/wan` | WAN 明细（含 IPv6 全局地址、网关、DNS） |
| GET | `/network/lan` | LAN 明细 |
| GET | `/network/firewall` | **只读**防火墙策略摘要（`readonly: true`） |
| POST | `/network/wan` | 改 WAN（含 PPPoE 账号口令）。口令只回掩码，空串表示不改 |
| POST | `/net/wan/action` | 重拨 / 断开 / 连接。**不动配置**，所以不挂回滚守护 |
| GET | `/luci/session` | 给内置 WebView 的 LuCI 免密通行证（见下） |

`POST /net/wan/action` 请求体 `{"action": "reconnect" | "down" | "up"}`，
立刻返回 `{ok, action, message, detail}`；命令是 detach 跑的，结果靠轮询
`GET /network/wan` 的 `status.up` 判断（PPPoE 重拨 10-30 秒）。

### LuCI 免密通行证

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/luci/session` | Agent 代登录一次 LuCI，返回可直接塞进 WebView 的 cookie |

响应：

```json
{
  "ok": true,
  "url": "http://192.168.100.1/cgi-bin/luci/",
  "host": "192.168.100.1",
  "scheme": "http",
  "cookie_name": "sysauth_http",
  "cookie_value": "96bd513b…",
  "cookie_path": "/",
  "ttl": 1500
}
```

为什么要服务端代登录：LuCI 的登录态是 uhttpd 在 `POST /cgi-bin/luci/` 之后下发的
`sysauth_http` cookie。App 里点「路由器网页端」，WebView 第一次打开必然是登录页，
用户得把同一个 root 口令再敲一遍 —— 而 App 早就用它登录过 Agent 了。
Agent 就跑在这台机器上、还是 root，直接替它登一次，**口令不出路由器**，
客户端只拿到一个会话 id（和浏览器里那个一样，3600 秒过期、可随时被顶掉）。

口令来源按优先级：

1. 用户通过 App 改过 root 口令 —— 新口令只在 Agent 内存里记着（`/system/root_password` 成功后写入）
2. `config.json` 的 `luci.password`
3. `config.json` 的 `auth.password`（本项目默认：全站一个口令，什么都不用配）

拿不到（口令不一致 / uhttpd 关了 http）时返回 `{ok: false, error, url}`，
客户端应当**照样打开 `url`**，退回「用户自己登一次」。

`host` 取自请求的 `Host` 头（去端口），所以换网段或用 IPv6 访问都不会拼错地址。
会话缓存 25 分钟，且**每次发出去之前会探一次活** —— LuCI 的会话会因为超时、
后端重启、或者在网页端点了「退出」而失效，缓存里那张就是作废的通行证。

### 地址脱敏

所有**响应里**的公网 / CGNAT 地址在服务端就打了码（`agent/mask.py`），
客户端不用各自过滤 —— 五处界面各写一遍，迟早漏一处，而漏的那次泄漏的是一张截图。

| 原值 | 返回 |
|---|---|
| `100.70.72.34`（CGNAT） | `100.*.*.34` |
| `218.2.2.2`（运营商 DNS） | `218.*.*.2` |
| `240e:3a0:5656:3039:…:b7c0` | `240e:3a0:…` |
| `240e:3a6:566b:1080::/64` | `240e:3a6:…/64` |
| `192.168.100.243`（LAN） | 原样 |
| `fd00::1` / `fe80::1` / `127.0.0.1` | 原样 |

只对「展示用」字段生效：`POST /network/wan` 的 `ipaddr` / `netmask` / `gateway`
（用户要编辑的静态 IP）以及设备的 `dhcp.reserved_ip`（静态绑定）保持原值，
否则界面会把打码值回写进配置。

### 配置事务（改 LAN / DHCP）

改地址会断连，所以是「先提交、后确认」的两步式：

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/net/pending` | 有未确认事务时返回 `{pending:true, tag, left, expired}` |
| GET | `/net/lan` | 当前 LAN 与 DHCP 配置 |
| POST | `/net/lan` | 提交改动，进入待确认状态 |
| POST | `/net/confirm` | 客户端在新地址上确认，事务提交 |
| POST | `/net/rollback` | 主动撤销 |

`POST /net/lan` 主要参数：

```json
{
  "ip": "192.168.100.1",
  "mask": "255.255.255.0",
  "dhcp_enabled": true,
  "pool_start": 100,
  "pool_limit": 150,
  "lease": "12h",
  "allow_lan_change": true
}
```

- 地址池偏移是**相对网络地址**，不是相对路由器 IP
- 改网段时静态绑定按**主机号**迁移（`.110` 仍在 `.110`）
- 60 秒内不确认，由独立的 shell 守护自动回滚

## 设备

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/devices` | 设备列表。含在线状态、实时速率、累计用量、品牌/类型/型号 |
| GET | `/devices/detail?mac=` | 单台详情：基本信息、实时流量、正在访问的域名、连接明细 |
| POST | `/devices/rename` | `{mac, alias}` 改备注名 |
| POST | `/devices/block` | `{mac, enabled}` 禁网 / 解禁（写 `firewall` 规则 + `fw4 reload`） |
| POST | `/devices/bind` | `{mac, ip}` 固定 IP |
| POST | `/devices/unbind` | `{mac}` 取消固定 |
| POST | `/devices/wol` | `{mac}` 网络唤醒 |
| GET | `/clients` | 当前客户端连接（原始视图） |

数据源：`/tmp/dhcp.leases`、`/tmp/hosts/dhcp.*`、`ip -s neigh`、`/proc/net/nf_conntrack`、
`uci show dhcp|firewall`。

在线判定四路交叉（邻居表 / 流量 / `used` / 主动 ping），详见
[architecture.md](architecture.md#在线判定)。

## 代理

OpenClash 与 Passwall 双后端，`backend` 参数可选，不传则按当前运行的那个。

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/proxy` | 当前后端、引擎、节点数、运行状态 |
| GET | `/proxy/groups` | 节点分组（含每个节点的延迟） |
| GET | `/proxy/connections` | 实时连接 |
| GET | `/proxy/configs` | 列 `/etc/openclash/config/*.yaml` + 当前启用项 |
| GET | `/proxy/subscriptions` | 订阅列表 |
| POST | `/proxy/select` | `{name, group, backend}` 切节点 |
| POST | `/proxy/service` | `{action, backend}` 启停服务 |
| POST | `/proxy/mode` | `{mode, backend}` 运行模式 |
| POST | `/proxy/delay` | `{name, timeout}` 单个测速 |
| POST | `/proxy/delays` | `{group, backend}` **整组测速** |
| POST | `/proxy/config` | `{path}` 切配置文件（改 uci + commit + 重启内核，断网十几秒） |
| POST | `/proxy/subscriptions` | 增删改订阅 |

> `POST /proxy/config` 的 `path` 会 `realpath` 后校验是否在 `CONFIG_DIR` 内 ——
> 不校验就等于开了个任意文件写入口。

### 兼容接口

`/clash/*`（`mode`、`service`、`delay`、`select`、`proxies`、`connections`）是早期
OpenClash 专用接口，保留兼容。新代码请用 `/proxy/*`。

## 广告拦截

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/adblock` | AGH 状态、拦截率、规则数、更新计划 |
| GET | `/adblock/top?limit=5` | 拦截排行（次数取 AGH `stats.top_blocked_domains`） |
| GET | `/adblock/log?limit=&only_blocked=&search=` | 查询日志，`only_blocked` 走服务端 `response_status=blocked` |
| GET | `/adblock/rules` | 规则表列表与开关状态 |
| GET | `/adblock/preflight` | 接管前体检 |
| GET | `/adblock/verify` | 接管后验证（国内 / 国外 / 本地三类域名） |
| POST | `/adblock/takeover` | 接管全网 DNS |
| POST | `/adblock/release` | 退出接管 |
| POST | `/adblock/service` | `{action}` 启停 AGH |
| POST | `/adblock/refresh` | 手动刷新规则（AGH 本身每 24 小时自动一次） |
| POST | `/adblock/rules` | `{enabled, interval, ...}` 改规则表开关与自动更新间隔 |
| POST | `/adblock/probe` | 探测 AGH 可达性 |

## 配置备份

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/config/backups` | 备份列表 |
| POST | `/config/backups` | `{note}` 新建备份（打包 `/etc/config`） |
| POST | `/config/backups/restore` | `{id}` 恢复 |
| POST | `/config/backups/delete` | `{id}` 删除 |

## 系统操作

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/power` | `{action: "reboot" \| "shutdown"}` |
| POST | `/password` | `{current, new}` 改 Agent 登录口令，新口令至少 8 位 |
| POST | `/system/root_password` | 改路由器 root 口令 |
| POST | `/system/upload` | `multipart/form-data` 上传安装包（**必须在 `_body()` 之前处理**，否则请求体被当 JSON 读走） |
| POST | `/system/install` | `{path}` 安装已上传的包 |
| POST | `/system/uploads/delete` | `{path}` 删除上传的文件 |
| POST | `/system/update` | 触发软件包更新，`{packages: [...]}` |

## 已下线的接口

| 路径 | 状态 |
|---|---|
| `POST /net/firewall/harden` | **404** —— 一键收紧防火墙，收益不确定、断网风险确定 |
| `POST /net/firewall/unrestrict` | **404** —— 同上 |

`GET /network/firewall` 保留只读，返回 `readonly: true` 且不再带 `harden` 建议字段。

## 示例

```bash
BASE=http://192.168.100.1:8443/api/v1

TOKEN=$(curl -s -X POST $BASE/login \
  -H 'Content-Type: application/json' \
  -d "{\"password\":\"$AGENT_PASSWORD\"}" | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p')

# 概览
curl -s -H "Authorization: Bearer $TOKEN" $BASE/overview

# 设备列表里第一台的详情
MAC=$(curl -s -H "Authorization: Bearer $TOKEN" $BASE/devices \
      | sed -n 's/.*"mac": *"\([^"]*\)".*/\1/p' | head -1)
curl -s -H "Authorization: Bearer $TOKEN" "$BASE/devices/detail?mac=$MAC"

# 整组测速
curl -s -X POST $BASE/proxy/delays \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"group":"GLOBAL"}'
```

仓库内的 `scripts/check_*.py` 是这些接口的实测校验脚本，
可以直接对照字段名 —— 界面上每个数字都靠字段名对齐，写错不会报错，只会安静地显示成「—」。
