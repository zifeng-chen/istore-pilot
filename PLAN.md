# iStoreOS 移动端管理 App — 方案与实施记录 v0.4

> 目标：把只能在网页端完成的 iStoreOS 管理搬到手机上（Android / iOS / HarmonyOS NEXT），做到「随手看一眼状态、随手切一下节点」。
> 当前状态：**M0 + M1 已完成并在路由器上线运行**，局域网内手机浏览器已可用。

---

## 一、设备实测画像

### 硬件

| 项 | 值 |
|---|---|
| 处理器 | Intel Pentium Gold 8505（6 核，x86_64） |
| 内存 | 7.5 GiB（无 swap） |
| 系统盘 | NVMe 128 GB（`/ext_overlay` 116.9 G，已用 7 G，6%） |
| 网口 | eth0–eth5 共 6 个，**全部 2500 Mbps**；当前 eth0/1/2 已连接 |
| 温度 | `acpitz` 27.8°C / `x86_pkg_temp` 42°C 附近 |
| 负载 | 日常 0.10–0.20（6 核，极度空闲） |

### 系统

| 项 | 值 |
|---|---|
| 固件 | iStoreOS 24.10.8 2026073111（OpenWrt 24.10 branch） |
| 内核 | 6.6.144 |
| 根文件系统 | squashfs `/rom` + overlayfs `/` |
| 已在线 | 49 天 |
| 运行时 | **Python 3.11.14**、Node 20.20.2 均在机内 |
| 容器 | Docker 已启用（`fam-poc-pg` 在跑） |

### 网络

| 项 | 值 |
|---|---|
| WAN 类型 | PPPoE |
| WAN IPv4 | `100.64.0.1`（**CGNAT，不是公网 IPv4**） |
| WAN IPv6 | `240e:xxxx:xxxx:xxxx::/64`（动态） |
| LAN | `br-lan 192.168.1.1/24` |
| LAN IPv6 | `240e:xxxx:xxxx:xxxx::1/64`（PD 独立前缀） |
| DNS | `218.2.2.2 / 218.4.4.4` |
| 在线设备 | N 台（电视盒子、智能家居设备、手机等） |

> 结论：**外网访问只能走 IPv6**，IPv4 在运营商 CGNAT 后面无法映射。这决定了后续所有外网方案必须围绕 IPv6 + DDNS。

### 插件与服务

| 服务 | 端口 | 说明 |
|---|---|---|
| uhttpd（LuCI） | 80 / 443 | 管理页 |
| dropbear | 22 | SSH |
| **OpenClash / Mihomo** | 9090（控制器）、7890/7893（代理） | Meta 内核 `alpha-ge183c58`，fake-ip 模式，TUN 已开 |
| dnsmasq | 53 | DNS/DHCP |
| ttyd | 7681 | **网页终端，监听 0.0.0.0** |
| SMB / NFS | 445 / 2049 | 文件共享 |
| linkease / dnetd / unetd | 8897 | 易有云与异地组网 |

**OpenClash 关键配置**：`enable=1`、`en_mode=fake-ip`、`core_type=Meta`、`cn_port=9090`、`external-controller=0.0.0.0:9090`、订阅一份自建配置、若干策略组 / 数十个节点 / 日常数百条连接。

**Passwall（已装、已配置、未启用）**：`@global[0].enabled=0`，DNS 分流用 `chinadns-ng`，
**一百多个 Xray 节点**，按订阅来源分 3 组，默认指向某个日本节点。与 OpenClash 互斥，启动一个必须停另一个。

---

## 二、必须指出的安全问题

实测防火墙：

```
firewall.@defaults[0].input   = 'ACCEPT'
firewall.@defaults[0].forward = 'ACCEPT'
firewall.@zone[1] (wan).input   = 'ACCEPT'
firewall.@zone[1] (wan).forward = 'ACCEPT'
firewall.@forwarding[4]: wan → lan
```

nftables 的 `input` 钩子 `policy accept`，WAN 区策略也是 ACCEPT，另有一条 `wan → lan` 的 forwarding。

**这意味着：路由器的管理面和整个内网，在 IPv6 上是对全网敞开的。** 任何扫描器都能尝试：

| 暴露的东西 | 风险 |
|---|---|
| LuCI 80/443 | 弱口令爆破的頭号目标 |
| SSH 22 | 明文爆破 |
| ttyd 7681 | **网页终端，等于第二个 shell 入口** |
| Clash 9090 | 拿到 secret 即可随意改代理配置 |
| SMB 445 / NFS 2049 | 局域网文件共享被公网直接访问 |

要特别留意 `external-controller=0.0.0.0:9090`：只要 WAN 区 input 是 ACCEPT，
它就是可达的。而且**从内网往往测不出来** —— IPv6 路由表里运营商前缀指向
`unreachable dev lo`，回环路径被挡住，很容易造成「没对外开放」的错觉。

**建议**：把 WAN 区 input 改回 `REJECT`，只按需放行特定端口。这件事不影响日常使用，但能一次性关掉上述全部缺口。已列入待办，等用户确认后执行。

---

## 三、已交付（v0.2，运行中）

### 部署形态

```
/usr/lib/istore-agent/          # Python 代码（agent 包 + web 静态资源）
/etc/istore-agent/config.json   # 端口、密码、Clash secret
/etc/init.d/istore-agent        # procd 托管，开机自启
```

- 监听 `192.168.1.1:8443`（**仅局域网地址**，未对公网开放）
- 纯 Python 3.11 标准库，**零第三方依赖**，不需要交叉编译
- 不改动 iStoreOS 任何现有配置，不占 80/443，不影响现有网页端

### 已实现的接口

| 方法 | 路径 | 作用 |
|---|---|---|
| GET | `/api/v1/ping` | 免认证探活，用于内外网自动选路 |
| POST | `/api/v1/login` | 密码换令牌（HMAC-SHA256，7 天） |
| GET | `/api/v1/overview` | 系统全量概览 |
| GET | `/api/v1/traffic` | 实时收发速率（2 秒轮询） |
| GET | `/api/v1/network` | WAN/LAN 地址、网口状态 |
| GET | `/api/v1/clients` | DHCP 在线设备 |
| GET | `/api/v1/storage` | 挂载磁盘容量 |
| POST | `/api/v1/password` | 修改管理密码 |

**代理后端（OpenClash / Passwall 通用，推荐用这组）**

| 方法 | 路径 | 作用 |
|---|---|---|
| GET | `/api/v1/proxy` | 两个后端的安装/启用/运行状态、当前生效方 |
| GET | `/api/v1/proxy/groups?backend=` | 策略组与节点（统一结构） |
| GET | `/api/v1/proxy/connections?backend=` | 活跃连接（Passwall 不支持，返回空） |
| GET | `/api/v1/proxy/mode` | 当前代理模式 |
| POST | `/api/v1/proxy/select` | 切换节点 |
| POST | `/api/v1/proxy/mode` | 切换模式 |
| POST | `/api/v1/proxy/service` | 启停/重启（自动停掉另一方） |
| POST | `/api/v1/proxy/delay` | 延迟测试（Passwall 用 TCP 连通） |

**电源与广告拦截**

| 方法 | 路径 | 作用 |
|---|---|---|
| GET | `/api/v1/power` | 可执行的动作、运行时长、上次操作 |
| POST | `/api/v1/power` | 重启/关机/重启网络·DNS·防火墙·网页（需二次确认） |
| GET | `/api/v1/adblock` | AGH 安装/运行/模式、规则数、拦截统计 |
| GET | `/api/v1/adblock/preflight` | 六项上线体检 |
| POST | `/api/v1/adblock/takeover` | 接管全网 DNS（失败自动回滚） |
| POST | `/api/v1/adblock/release` | 退出接管，回到观察模式 |
| POST | `/api/v1/adblock/refresh` | 拉取规则更新 |
| POST | `/api/v1/adblock/service` | 启停 / 重启 AGH |

> 旧的 `/api/v1/clash/*` 全部保留，行为不变，只作兼容层。


### 数据来源

| 指标 | 来源 |
|---|---|
| CPU 占用 | `/proc/stat` 两次差分，含每核 |
| 内存 | `/proc/meminfo` |
| 温度 | `/sys/class/thermal/*/temp` |
| 网口速率 | `/sys/class/net/*/speed` + `carrier` |
| 收发流量 | `/proc/net/dev` 差分 |
| WAN/LAN 状态 | `ubus call network.interface.{wan,lan} status` |
| 全局 IPv6 | `ip -j addr`（ubus 只返回链路本地地址，必须补） |
| 磁盘 | `/proc/mounts` + `statvfs` |
| 在线设备 | `/tmp/dhcp.leases` |
| OpenClash | `ubus call service list` + uci + Clash REST API（`127.0.0.1:9090`） |

---

## 四、自动切换内外网

### 关键前提：统一使用域名

外网只有 IPv6，域名 DDNS 到 IPv6。要做到「同一个 URL 内外网都通、且证书有效」，正确做法是 **split-horizon DNS**：

| 场景 | 域名解析结果 |
|---|---|
| 家里（走路由器 DNS） | `192.168.1.1`（内网地址） |
| 外面（走运营商 DNS） | 公网 IPv6 |

这样一个域名两端都通，Let's Encrypt 证书也天然匹配，App 不需要任何切换逻辑。

### App 侧的兜底：双地址探测

手机可能开了加密 DNS（DoH / 私人 DNS）绕过路由器 DNS，所以 App 必须自己也能选路：

1. 保存两个地址：内网 `http://192.168.1.1:8443`、外网 `https://域名`
2. 启动时并发探测 `/api/v1/ping`（1.5 秒超时），**取响应最快的**
3. 当前地址仍可用时保持不变，避免每次刷新都跳
4. 网络切换（Wi-Fi ↔ 蜂窝）、App 回到前台时重新探测
5. 设置页显示当前是「内网直连」还是「外网」，并允许手动填两个地址

已实现，实测在局域网内正确识别为「内网直连」。

### 还没做的

- **域名与证书尚未接入**。用户使用 DDNS-go 解析 IPv6，但路由器上没找到 ddns-go（`ddns-scripts` 装的是默认模板配置，未启用），推测跑在 NAS 或其他设备上。**需要用户提供实际域名**，才能配 HTTPS 与证书，届时外网才能用。
- HTTPS 证书计划用 Let's Encrypt DNS-01（阿里云 DNS API），无需开放 80 端口。

---

## 五、外网管理 OpenClash 的方案

用户希望「App 做好后再放开 OpenClash 端口」。这里不建议直接放开 9090，而是：

| 方案 | 做法 | 评价 |
|---|---|---|
| **A（推荐）** | 9090 只监听 `127.0.0.1`，由 Agent 代理转发 | 公网永远只有 Agent 一个入口，Clash 控制器不直接暴露 |
| B | 放开 9090 + 强 secret + IP 白名单 | 可行但攻击面大，不推荐 |
| C | WireGuard / Tailscale 组网后再访问 | 最安全，但需要常开 VPN |

**推荐 A**：Agent 已经完整代理了 Clash 的全部操作（切换节点、模式、连接、延迟、启停），外网只需要放行 8443 一个端口。同时把 `external-controller` 从 `0.0.0.0:9090` 改为 `127.0.0.1:9090`，堵掉直连通道。

开启外网的步骤（等用户确认）：
1. 绑定地址从 `192.168.1.1` 改为 `0.0.0.0`
2. 配好域名 + HTTPS 证书
3. 防火墙只放行 8443 的 IPv6 入站，其余 WAN 入站全部 REJECT

---

## 六、双代理后端：OpenClash 与 Passwall

实测发现两个插件**都装了**：OpenClash 在跑（`config.enable=1`），Passwall 配好了一百多个
Xray 节点但 `@global[0].enabled=0` 没启用。所以 App 不能写死 OpenClash。

两者差异极大，不能共用一套调用：

| | OpenClash | Passwall |
|---|---|---|
| 运行时接口 | 有 REST 控制器（9090） | **没有**，只能读 `uci` |
| 切节点 | `PUT /proxies/{组}` 立即生效 | 改 `tcp_node` + `commit` + **重启内核** |
| 策略组 | selector / url-test 等多组并存 | 无此概念，按节点 `group` 字段分组 |
| 连接明细 | 有 | 不提供 |
| 延迟测试 | HTTP 测速 | 只能测 TCP 连通 |

`agent/proxy.py` 把差异吃掉，对外一套模型。三个关键处理：

1. **互斥**：`start`/`restart` 前自动 `stop` 另一方，否则抢 53 端口与 nft 转发链
2. **无热切换**：Passwall 切节点后必须重启内核，前端要提示「重启中，稍等」
3. **连接数不串台**：连接接口按 `backend` 参数区分，看 Passwall 时显示 `—` 而不是 OpenClash 的数字

---

## 七、广告拦截：AdGuard Home，已装好但默认不接管

用户的顾虑是「担心对网络有影响」。这件事不该靠口头保证，而应先把决定影响面的
事实探出来。实测得到的 DNS 链路是：

```
客户端 :53  →  nft redirect to :53  →  dnsmasq:53  →  server=127.0.0.1#7874  →  OpenClash(fake-ip)
```

**关键结论：53 端口只有一个。** AGH 要生效必须占 53，dnsmasq 就得让出 DNS（只留 DHCP）。
「AGH 串在 dnsmasq 后面用 5353」这条路走不通，因为 OpenClash 的 watchdog 会强制把
dnsmasq 上游改回 `127.0.0.1#7874`（已从 `/usr/share/openclash/openclash_watchdog.sh`
第 381–391 行读到实证）。

### 装了什么

| 组件 | 版本 / 位置 | 说明 |
|---|---|---|
| luci-app-adguardhome | 25.110.32977 | 用户提供的第三方 LuCI 界面（**不含本体**） |
| AdGuard Home 本体 | v0.107.79 → `/usr/bin/AdGuardHome/` | 从 `static.adtidy.org` 下载（GitHub 在本机不通） |
| 规则源 | anti-AD `adguard.txt` | **103,887 条**，国内维护，中文广告覆盖好 |

> 注意：用户给的 `.run` 不是官方安装器，是 Makeself 包装的两个 ipk（LuCI 界面 + 中文包），
> `install.sh` 只有一句 `opkg install`。它自带的自动下载走 GitHub，在你这台机器上必然失败，
> 所以本体是单独从 adtidy 官方 CDN 拉的。

### 两种模式（默认停在观察模式）

| 模式 | AGH 监听 | dnsmasq | 对全家网络的影响 |
|---|---|---|---|
| **observe（当前）** | `127.0.0.1:5353` | 正常占 53 | **零影响**，AGH 只服务路由器本机 |
| takeover | `0.0.0.0:53` + `::` | `port=0`，只留 DHCP | 全网 DNS 先过滤再分流 |

App 设置页有「接管全网 / 退出接管」按钮，一键切换。

### 管理界面与凭据

| 项 | 值 | 说明 |
|---|---|---|
| 地址 | `http://192.168.1.1:3000` | **只绑局域网 IPv4**，不监听 IPv6 |
| 账号 | `admin` | |
| 密码 | 与 iStoreOS 相同 | AGH 只存 bcrypt 哈希，改密码要改 yaml 的 `users.password` |
| Agent 侧 | `/etc/istore-agent/config.json` 的 `adguard` 段 | 含 `api_host` / `api_port` / `password` |

> 管理口初始误配为 `0.0.0.0:3000`，AGH 会同时监听 `:::3000`，在当前
> `wan input=ACCEPT` 下等于把拦截器的管理面板挂到公网 IPv6 上。已收敛为
> `192.168.1.1:3000`（纯 IPv4），实测 `netstat` 只剩 5353 与 3000 两个内网监听。
>
> 连带坑：管理口一旦不绑 0.0.0.0，Agent 里写死的 `127.0.0.1:3000` 就连不上，
> 表现为体检「拦截规则已加载」突然变 0 条。已改为读 `adguard.api_host`。

### 实测数据（消除顾虑的依据）

接管后实测：

| 域名 | 接管前 | 接管后 |
|---|---|---|
| `doubleclick.net` | 198.18.249.36 | **0.0.0.0** |
| `googlesyndication.com` | 正常 | **0.0.0.0** |
| `hm.baidu.com`（百度统计） | 正常 | **0.0.0.0** |
| `baidu.com` | 198.18.246.232 | 198.18.246.232 |
| `api.weixin.qq.com` | 正常 | 正常 |
| `mp.weixin.qq.com` | 正常 | 正常 |
| `bilibili.com` / `taobao.com` / `alipay.com` / `i.y.qq.com` / `zhihu.com` | 正常 | 正常 |

**误杀检验：11 个日常服务全部正常。** 广告域名 6/7 被拦。

### 踩过的三个坑

1. **`- ::` 不加引号会炸**：YAML 把 `::` 解析成 map，AGH 报
   `cannot construct !!map into netip.Addr`，直接拒绝启动。必须写成 `- "::"`。
2. **接管失败绝不等于断网**：接管流程里加了验收，53 上不是 AGH 就自动回滚 dnsmasq，
   实测触发过一次，网络自动恢复。
3. **workdir 不能放 /tmp**：AGH 的规则缓存和统计都在 workdir，放 tmpfs 重启即丢。
   已迁到 `/etc/AdGuardHome`（overlay 持久化）。

### 会变和不会变的边界

| 项目 | 是否受影响 |
|---|---|
| 广告域名解析 | 被拦截，返回 0.0.0.0，连接根本不建立 |
| 带宽 / 延迟 | 不变 |
| 游戏、下载速度 | 不变 |
| 路由、NAT、IPv6、防火墙 | 不变 |
| 某些 App 的统计域名 | **可能被误杀**，表现为页面局部加载失败 |

唯一真实风险是误杀，且**完全可逆**：退出接管即恢复，不需要重启路由器。


---

## 八、电源控制

支持重启路由器、关机、重启网络 / DNS / 防火墙 / 管理网页。

关机与重启是不可撤销且会**让所有远程入口失效**的操作（关机后除非主板支持 WOL
且内网有设备代发，否则只能到设备跟前上电）。因此设了三道约束：

1. 后端强制要求 `confirm` 字段等于动作名，防脚本误调
2. 前端危险操作要求手动输入动作名，防手滑
3. 命令延迟 2 秒执行，保证 HTTP 响应先发回，前端能显示「已下发」

---

## 九、鸿蒙端开发规范

已安装 `harmonyos-development` 技能（来源 `github.com/DengShiyingA/harmonyos-ai-skill`，
4461 行，API 24 基线）。**任何涉及 ArkTS / ArkUI / .ets / module.json5 / DevEco / HAP
的开发，必须先加载该技能再动笔**，不能凭 Web 前端经验直接写——两者的状态管理、
路由、网络请求写法完全不同：

| 需求 | 通用 AI 会给 | 鸿蒙实际是 |
|---|---|---|
| UI 框架 | React Native | ArkUI `@Component struct` |
| 状态管理 | useState / Redux | `@State` / `@Local`（V2） |
| 路由 | react-router | `Navigation` + `NavPathStack`（Router 已淘汰） |
| HTTP | axios / fetch | `@kit.NetworkKit` 的 `http.createHttp()` |
| 权限 | AndroidManifest | `module.json5` + `abilityAccessCtrl` 三步 |

---

## 十、移动端安装包

三端都是**薄壳**：页面仍由路由器上的 Agent 提供，壳只负责「没有地址栏的浏览器 +
记住地址 + 连不上时的兜底」。好处是改界面不用重新发版，也不用你去 Mac 上重新签名。

| 平台 | 产物 | 状态 | 硬门槛 |
|---|---|---|---|
| Android | `dist/istoreos-1.0.0.apk` | ✅ 已构建 | 无 |
| iOS | `ios/` 源码 + 指南 | ⏳ 待你签一次名 | Mac + Apple ID |
| HarmonyOS NEXT | 未开始 | ⏳ | DevEco Studio |

### Android（已完成）

| 项 | 值 |
|---|---|
| 包名 / 应用名 | `com.chaof.istoreos` / iStore Pilot |
| 版本 | 1.0.0（versionCode 1） |
| 系统 | minSdk 24（7.0）· targetSdk 34（14） |
| 体积 | 57 KB |
| 依赖 | **零第三方库**，只用系统 WebView |
| 签名 | 自签 `istoreos.keystore`，10000 天 |

交互：长按返回键改地址（内网 IP / 外网域名），连不上自动进内置错误页，
错误页里能直接改地址并重连，不用重装。

**构建环境的三个坑**（这台机器）：

1. `services.gradle.org` 不通 → Gradle 8.7 从华为云镜像下载并解压到
   `~/.workbuddy/binaries/gradle/`，直接调用，不走 wrapper
2. `repo.maven.apache.org` 不通 → 依赖仓库改用 Google Maven（dl.google.com 可达）
   + 阿里云 central 镜像
3. 为彻底避开依赖问题，工程刻意不引 AppCompat 等任何库，用系统 `Activity` +
   `@android:style/Theme.Material.NoActionBar`

### iOS

有 Mac、无开发者账号，所以走个人免费签名：Xcode 用 Apple ID 直接签，装自己手机，
**7 天过期，到期再 Run 一次覆盖安装**（数据不丢）。同时最多 3 个自签名 App。

代码是 `WKWebView` 壳，交互比 Android 少一个返回键，改成**摇一摇改地址** + 下拉刷新。
错误页复用同一份 `error.html`（通过 `istoreos://set?url=` 自定义 scheme 交回原生保存）。

详细步骤见 `ios/README.md`。

### 鸿蒙 NEXT

需先在这台 Windows 上装 DevEco Studio（约 15 GB），华为账号已实名。装好后走
ArkTS 工程 + `Web` 组件加载同一页面，思路与两端一致。动手前必须先加载
`harmonyos-development` 技能。

---

## 十一、待办

| 优先级 | 事项 | 说明 |
|---|---|---|
| P0 | 收紧 WAN 防火墙 | 当前全开，风险最高 |
| P0 | 用户提供域名 | 外网与 HTTPS 的前置条件 |
| P1 | 接入 HTTPS + 证书 | Let's Encrypt DNS-01 |
| P1 | 对外网开放 8443 | 配合防火墙白名单 |
| P1 | Clash 9090 收敛到 127.0.0.1 | 堵掉直连口子 |
| P2 | 历史曲线 | Agent 内嵌 SQLite 采样（1 分钟粒度，留 7 天） |
| P2 | 异常告警 | WAN 掉线、内存/磁盘超阈值、OpenClash 退出 |
| ✅ | Android 安装包 | 已完成，`dist/istoreos-1.0.0.apk` |
| P1 | iOS 包 | 你在 Mac 上按 `ios/README.md` 签一次名（约 10 分钟） |
| P2 | 鸿蒙 NEXT 包 | 先装 DevEco Studio（约 15 GB） |
| P2 | 决定是否接管 DNS | AGH 已装好并实测通过，App 里一键切换，等用户选时机 |
| P3 | 端口转发、DDNS 管理界面 | |
| P3 | App 内自定义端口/证书 | 目前只支持 http，上 HTTPS 后要放开 ATS/明文白名单 |

---

## 十二、部署命令

```bash
# 修改前先把密码换成你自己的
ROUTER_PW='<路由 SSH 密码>' AGENT_PASSWORD='<新的管理密码>' \
  python deploy/deploy.py
```

脚本会：打包 → SFTP 上传 → 解压到 `/usr/lib/istore-agent` → 写初始配置（已存在则跳过）→ 同步 OpenClash secret → 注册自启 → 重启服务。

前端改动后记得把 `web/index.html` 里的 `?v=N` 递增，否则手机会用缓存里的旧版本。
