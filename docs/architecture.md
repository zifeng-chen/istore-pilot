# 架构与设计决策

这份文档记录**为什么这样做**，而不是做了什么。做了什么看
[README](../README.md) 和 [CHANGELOG](../CHANGELOG.md)。

---

## 一、分层

```
客户端（Android / HarmonyOS / iOS / Web）
        │  HTTP + JSON，Bearer Token
        ▼
Agent  /api/v1/*        ← 唯一契约层
        │
        ├── ubus / uci      配置与状态
        ├── nft / iptables  防火墙（只读）
        ├── procfs / sysfs  CPU、内存、温度、邻居表
        ├── /tmp/dhcp.leases 租约
        ├── OpenClash API   127.0.0.1:9090
        └── AdGuard API     127.0.0.1:3000
```

**为什么要有 Agent，而不是客户端直连路由器？**

- 路由器自带的 `ubus` / `uci` 是本地 Unix socket，客户端访问不到
- LuCI 的接口是 HTML 片段，不是 JSON
- 把「读一堆文件、拼一份数据」的逻辑放在路由器上，比在每个客户端各写一遍靠谱
- 换代理后端（OpenClash ↔ Passwall）、改数据源，只动 Agent 一处

Agent 是 **Python 3 标准库，零第三方依赖**。这是刻意的：OpenWrt 上装
`pyOpenSSL` 之类的包会牵扯一堆依赖，而标准库版本开机就有，升级内核也不受影响。

## 二、Agent 的几个关键设计

### 1. 响应体两种形态

- `overview` / `devices` / `adblock` / `proxy` **直接返回数据**（首屏要快，少一层包装）
- `hardware` / `wan` 包 `{ok, ts, data}`（这两个可能耗时，带时间戳便于判断新鲜度）

不统一是不好看，但客户端已经按这个契约写死了，改动成本高于收益。

### 2. 采样线程而不是每次请求现算

CPU 占用率要两次 `/proc/stat` 差分。每次请求现采就要 sleep 再采，接口会慢一拍。
所以后台常驻采样线程，按固定间隔把结果放进缓存，接口只读缓存。

设备流量同理：按连接 id 做字节差分，3 秒一轮。

> **首轮只建基线**。第一批采样一定算不出速率（没有上一次的值），
> 如果直接算会得到巨大的假峰值。这个坑踩过两次。

### 3. token 与限流

`POST /api/v1/login` 校验口令后发 token，默认 7 天有效，客户端落地后免登录。
登录失败按客户端 IP 限流（默认 30 次/分钟），防暴力猜。

## 三、配置事务（`agent/netapply.py`）

改路由器网络配置最怕的事：改完地址变了，客户端连不回来，人也进不去，只能物理重启。

所以任何会断连的写操作都走这套：

1. 把 `/etc/config` 整个快照到临时目录（含 `fw_saved.json` 这类旁路状态文件）
2. 写 uci 新值
3. 客户端收到「待确认」状态，在 **60 秒内**回来 `POST /net/confirm`
4. 没回来 → 独立的 `sh` 守护进程把快照写回去，重启相关服务
5. 回来了 → 丢弃快照

**关键判据是「客户端有没有回来确认」，不是「ping 得通」。**

因为客户端所在网段可能已经变了 —— 改了 LAN 地址后，ping 不通是正常现象，
但客户端换到新地址后完全可以继续工作。用 ping 当判据会让你刚改完就被回滚。

### 回滚必须复位整条链路

事故教训：一次回滚只 `reload` 了 `network / firewall / dnsmasq`，
漏了 `openclash` 与 `AdGuardHome`，结果 LAN 地址回去了但 DNS 链路没复位，
只能重启路由器恢复。

**改网络的事务，服务列表里必须包含：`network`、`firewall`、`dnsmasq`、
`openclash`、`AdGuardHome`**，而且这几个要 `stop` / `start`，不能只 `reload`。

### 监听地址必须通配

Agent 原来绑 `192.168.100.1:8443`。改 LAN 地址时，它自己就是那个 IP 上的服务 ——
地址一变，服务跟着消失，确认请求永远回不来，必然触发回滚，形成死循环。

改成 `0.0.0.0` 才能在改地址后存活。代价是暴露面变大，所以
**部署后应主动改回 LAN 地址**（README 里写明了）。

## 四、几个数据的真实来源与陷阱

### 在线判定

只信邻居表会误判：**iPhone 锁屏不回 ARP**，条目挂在 STALE，但 WiFi 没断、
长连接还在跑。实测那台机器 conntrack 里 79 条 ESTABLISHED，邻居表却是 STALE。

现在的四路交叉，任一命中即在线：

1. 邻居表 `state ∈ {REACHABLE, DELAY, PROBE}`
2. 150 秒内出现过流量（按 MAC 记账）
3. 邻居表 `used ≤ 150s`（`ip -s neigh` 取中间那个数）
4. 主动 ping 通（180 秒有效）

`INCOMPLETE` / `FAILED` 一票否决。

> **不能靠「conntrack 里有流」判在线。** 断网的设备会停在 `LAST_ACK` 持续重传，
> 反向字节照样涨 —— 实测挂过 17 小时，会永久误报。
>
> **也不能靠「ping 不通」反推离线。** 静默设备（智能插座、灯具）本来就不发包，
> 所以必须配 `dev-prober` 主动探测。

### 应用识别

路由器在转发路径上，但 Mihomo 对 redir 流量的 `process` / `processPath` **恒为空**
（uid 都是 0）。拿不到进程，只能靠**域名特征**反推。

18.2 万条域名来自路由器本地的 `GeoSite.dat`（v2ray-geosite，1436 个分类），
手写 protobuf 解码后挑 150 个常用分类，压缩成 1.48 MB。

- 写入顺序 = 优先级：大厂兜底 → 具体 App → 推送统计 → 广告联盟（最后写，覆盖前面）
- 匹配：后缀逐级上剥，第一个命中的最具体；手写规则仍排在前面
  （`v.qq.com` 要算腾讯视频，不是笼统的「腾讯」）
- 纯 IP 连接统一进「IP 直连」桶并排序垫底，否则排行榜被 IPv6 地址刷屏

### 代理后端抽象

OpenClash 有 Mihomo 运行时 API，Passwall **没有**。两者互斥，同时只跑一个。

`agent/proxy.py` 对外是一套接口，内部分派：

| 能力 | OpenClash | Passwall |
|---|---|---|
| 列节点 / 分组 | Mihomo API | 读 uci |
| 切节点 | Mihomo API | 改 `tcp_node` + commit + **重启内核** |
| 测速 | `/group/{name}/delay`（一组一次） | 16 线程并发 TCP 握手，标注 `kind:"tcp"` |

Mihomo 的组测速一次能打完一组（65 节点 2 秒），比逐个测快一个数量级。

### DNS 链路

`启用 AdGuard Home` 有三种工作模式，真正让 AGH 上位的只有 `takeover`：

- 上游地址从 `uci show dhcp` **现读**，不写死
- dnsmasq 挪到 `5354`，**绝对不能设 `port=0`** —— 静态绑定与 `.lan` 域名全靠它
- `filter_aaaa_dns` 保持原样，不要「帮」用户打开 AAAA
- 接管后实测三类域名，任一失败自动回滚

> **OpenClash 的 `enable_redirect_dns` 会把 AGH 旁路。**
> `=1` 时在 dstnat 里生成两条 `OpenClash DNS Hijack`，把 53 端口直接送去 dnsmasq 的
> 5354，AGH 一条查询都收不到；`=2` 送去 Clash 自己的 7874；`=0` 才不劫持。
> 这个值不改，AGH 装了也等于没装。

## 五、三端一致

三端请求同一份 `/api/v1/*`，所以数据必然一致。剩下要守住的是**观感一致**：

- 配色数值照抄 `android/app/src/main/res/values/colors.xml`，
  鸿蒙 `resources/base/element/color.json` 与 iOS `UI/Theme.swift` 是它的翻译
- 文案长度要按最窄的列算：「有效，剩余 6 天 5 小时」在三列布局必被截断 → 统一短写
- 数字统一 tabular（等宽），否则一列数字的小数点会左右跳

## 六、体验上的两个硬要求

### 秒开：快照优先

进页面时同步渲染上一次的接口快照，同时后台请求真实数据回来原地替换。
不出现转圈白屏。

### 离线可看

请求失败时**不清空界面**，只挂一条橙色提示条「连不上路由器（下拉可重试）」，
数字仍是上次的。对家庭网络来说，「上次看到的数据 + 一个警告」比空白页有用得多。

## 七、打包

ipk 是 OpenWrt 的包格式。不依赖 buildroot，直接用 Python 拼 ar 包
（三个成员：`debian-binary`、`control.tar.gz`、`data.tar.gz`），
40 行代码搞定，比装一整套编译工具链划算。

从 OpenWrt 24.10 起，ipk 实际是 **tar.gz 外壳**，成员名带 `./` 前缀。

> **`control` 文件必须用 `newline="\n"` 写。** Windows 文本模式会把 `\n` 转成 `\r\n`，
> 导致 `Architecture` 字段判定失败。
>
> **权限位要按 shebang 判。** NTFS 没有执行位，打成包后 init 脚本 126 无法执行。

## 八、踩坑清单（会重现的）

### Android

- 引入 AndroidX 必须在 `gradle.properties` 开 `android.useAndroidX=true`
- 界面文案写在 Java 里，必须锁 UTF-8（`JAVA_TOOL_OPTIONS` + `compileOptions.encoding`），
  否则中文 Windows 上按 GBK 编译，装到手机全是乱码
- `values-night` 里同名 style 是**整体替换不是合并**，基础主题要拆成 `Theme.IStore.Base`
- `View.setAlpha(0)` 作用于整棵子树，透明背景层与内容层必须是兄弟节点
- 横向 `LinearLayout` 里塞 `MATCH_PARENT` 高的装饰 View 会压扁文字
- 同一个 View 不能 add 进两个父容器
- 成品图标不能塞 adaptive icon 前景（66% 安全区会裁掉外圈）

### HarmonyOS

- `Card()` 之后不能直接链 `.margin()`，要包一层 `Column() { ... }`
- `@Prop size` 会撞 `CustomComponent.size`，`static name()` 会撞 `Function.name`
- 必须配 `network_config.json` 的 `cleartextTrafficPermitted: true`（接口是明文 HTTP）

### iOS

- `Info.plist` 必须放开 `NSAllowsArbitraryLoads` + 本地网络权限
- `.xcodeproj` 由 `gen_project.py` 生成，**增删 `.swift` 后必须重跑**
- 外层千万别套 `GeometryReader`，它把安全区吃成 0，背景铺不满；量尺寸用 `onGeometryChange`
- 三元表达式 + 字符串插值直接写进 `Text()` 会让类型检查超时，拆成局部常量

### Lua / LuCI

- `luci.sys.exec()` 的返回值带尾部换行
- `nixio.fs.chmod` 只吃八进制字符串
- `trim()` 必须 `return (s:gsub(...))`，否则返回值个数不对

## 九、明确不做的事

- **不接管防火墙写入**：一键「收紧」的收益不确定，断网风险确定。防火墙接口只读
- **不做限速**：路由器没装 `tc`
- **不读无线信号强度**：这台 x86 软路由没有无线网卡
- **不强断已建连接**：禁网是加 REJECT 规则，已建立的连接不会立刻断
