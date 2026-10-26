# 更新日志

本项目从 2026-10-24 开始，到当前版本为止共经历两套版本号：

- **1.0.0 – 2.13.x**：早期快速迭代期，版本号随功能叠加递增
- **0.1.0 起**：重新编号。规则是 `0.1.0 → 0.1.9 → 0.2.0`，
  **第三位满 10 进位**，不存在 `0.1.10` 这种写法

两套号之间不是降级 —— `2.13.x` 的一部分改动已并入 `0.1.0` 的五页签体系，
`versionCode` 始终单调递增（Android 不允许回退），所以覆盖安装不会出问题。

构建产物不入库（`dist/` 已 gitignore），下表版本号对应本仓库的 tag 与 Release。

---

## 0.1.2 — 2026-10-26

### 安全

- **防火墙写入入口全部下线**。`POST /net/firewall/harden` 与 `/unrestrict` 移除
  （现在返回 404），`GET /api/v1/network/firewall` 改为只读并去掉 `harden` 字段。
  三端界面同步删掉「一键收紧」「取消限制」的卡片与确认弹窗。
  原因很实际：这类一键改防火墙的操作，收益不确定而断网风险确定。
- 仓库内**所有硬编码口令清除**，改为环境变量注入，签名密钥与 keystore 不入库。

### 新增

- **配置事务层** `agent/netapply.py`：改配置前先把 `/etc/config` 快照下来，
  客户端在 60 秒内回来确认；没回来就由独立的 shell 守护把快照写回去。
  判据是「客户端有没有回来确认」，不是 ping 通不通 —— 客户端所在的网段可能已经变了。
- 接口 `GET/POST /api/v1/net/lan`、`/net/pending`、`/net/confirm`、`/net/rollback`
- **配置备份** `agent/cfgbak.py`：`/config/backups`、`/config/backups/restore`、`/delete`
- **LAN / DHCP 编辑** `agent/lanedit.py`：改 LAN 地址时按主机号迁移静态绑定，
  地址池偏移相对网络地址而不是路由器 IP

### 修复

- Agent 监听地址从固定 IP 改为 `0.0.0.0`，改 LAN 地址不再把自己踢下线
- 事务状态过期后返回 `{left: 0, expired: true}`，
  之前返回 `null` 会让界面显示「没有待确认」，但配置几秒后自己变了
- 回滚后 `fw_saved.json` 残留，导致 `wan→lan` 转发规则重复生效；
  旁路状态文件已纳入事务快照
- 防火墙卡片改完仍显示旧策略，补 `cache_drop()`

### 变更

- **全链路命名统一为 iStore Pilot**：LuCI 菜单、状态页、前端、ipk `Description`、
  Web 端 title、鸿蒙登录页、Agent 自升级文案、全部文档
- 刻意**不改** ipk 包名（`luci-app-istore-agent`）、服务名、配置路径与 LuCI 路由 URL ——
  改包名会让 opkg 认为新旧两个包并存，卸旧包时会把共用的
  `/usr/lib/istore-agent/*` 一起删掉

### 已知问题

- 从 `2.13.x` 装 `0.1.x` 的包时，opkg 会拒绝降级，需要
  `opkg install --force-downgrade` 一次，之后即可正常升级
- 包内默认 `bind=0.0.0.0` 会覆盖现有 uci 配置，装完需按需改回 LAN 地址

---

## 0.1.0 — 2026-10-26

- **版本体系重置**：从 2.x 换成 0.1.0 重新计数，配套 `scripts/bump_version.py`
  统一管理三端 + Agent 四处版本号
- **五页签结构定稿**：概览 / 设备 / 代理 / 拦截 / 设置。
  网络、系统维护等低频入口收进设置页，主界面只留「天天要看」的东西
- **宣传图重做**：4K 原生渲染，不靠放大，主视觉从概览换成信息密度最高的网络页。
  修掉高斯模糊大半径在贴图边界留下贯穿接缝的问题（改成解析径向衰减）

---

## 2.14.0 — 2026-10-26

- **Android 设置页整页重写**：hero（响应 / 凭证 / Agent）+ 连接 / 网络 / 外观 /
  系统维护 / 安全 / 关于，全部改成带图标的 `settingRow`，无退出登录
- **拦截页新增「规则更新」卡**：AdGuard Home 出厂是每 24 小时自动更新，
  原界面只有「刷新」一个按钮，看不出到底谁在更新。
  现在把「自动 / 手动」亮出来，可改 关闭 / 6h / 12h / 每天 / 2天 / 3天，并列出单表开关
- 新增 `widget/Glyph`（14 种线性图标）、`widget/Toggle`、`Ui.settingRow` / `cardTitle`
- **iOS 补齐四页**：`PortGrid` / `RulesCard` / `HardwareView` / `WanView`，
  设置页重写为七块
- **鸿蒙双端适配**：`ui/Breakpoint.ets`（600 / 840 断点）、`ui/comp/SideNav.ets`，
  四个主页面改成 rail 双列布局
- 三端一致修正：hero 里「有效，剩余 6 天 5 小时」在三列布局必被截断 → 统一短写；
  IPv6 行副标题「外网访问走这条」被挤成「外网访…」→ 统一改「外网入口」

---

## 2.13.1 / 2.13.2 — 2026-10-26

### 图标被裁切事故（真机发现）

成品图标是 1129×1129 的蓝色圆角方块（四角透明），被塞进 Android adaptive icon
的前景层 —— 系统只露出中间 **66% 安全区**，图标外圈的浅蓝弧线被整圈裁掉。

- **Android 弃用 adaptive icon**：删掉 `mipmap-anydpi-v26/*.xml` 与前景 png，
  只保留各密度的 `mipmap-*/ic_launcher.png`
- **鸿蒙 / iOS 需要不透明方图**：按行补四角，取色条件必须 `b - r > 180`。
  取最外像素会拿到圆角弧的浅蓝，四角会发灰
- 母版最外圈有半透明黑边，`im` 与 `orig` 必须一起填，否则边缘留一圈暗影

---

## 2.13.0 — 2026-10-25

- **图标只缩放不重绘**（用户明确要求）：删掉 `knockout_foreground`
- **固件 OTA 走 `/bin/ota`**：返回 0 有新固件 / 1 已最新 / 2 下载中 / 255 失败，
  结果读 `/var/run/ota/ota.latest` 与 `ota.log`。
  iStoreOS 24.10 **没有** owut / attendedsysupgrade，别去找在线升级接口
- **代理页拆分**：配置文件切换改成 `Sheet.choose` 弹窗（带修改时间 + 勾选当前）；
  订阅增删改搬到独立的 `SubscriptionActivity`，代理页只留一行入口
- 节点分组把「自动选择」稳定置顶（匹配 自动 / auto / urltest / fallback）
- 设置页精简：去掉固件 / 内核两行冗余，「上传安装包」不再贴 opkg 原始输出
- **应用名改为 iStore Pilot**：`strings.xml`、登录页、鸿蒙两份 `string.json`

---

## 2.12.0 — 2026-10-25

- **网口角色识别**：从 uci 推 —— `network.wan.device` 是 WAN，
  `network.@device[N].ports` 里 `name` 含 lan 的桥成员是 LAN。
  uci 多口值写成 `'eth1' 'eth2'`，**引号在中间**，必须 `replace("'", " ")` 再 split
- **代理配置文件切换**：`GET /proxy/configs` 列 `/etc/openclash/config/*.yaml` +
  当前启用；`POST /proxy/config {path}` 改 uci + commit + 重启内核（断网十几秒）。
  路径必须 `realpath` 后校验在 `CONFIG_DIR` 内，否则等于开了任意文件写入口
- **检查更新报错的真因**：`refresh=true` 会先跑 `opkg update`，慢源上要 2~3 分钟，
  超过前端超时 → 弹「检查失败」。改成只读现有索引，秒回
- 图标生成脚本重写：从一张带白边的母版切全套（Android 各密度 + round +
  鸿蒙 1024 + iOS 1024）

---

## 2.11.1 — 2026-10-25

### 修：ipk 自安装会把自己弄坏

从 App 里安装 `luci-app-istore-agent` 自己的 ipk 时，opkg 会**先删旧文件再展开**，
而执行 opkg 的正是那些被删掉的 py 文件跑起来的进程 —— 进程把自己弄死，
opkg 被回收，包停在半删半装状态：LuCI 页面 404、服务起不来、
`opkg remove` 还会说 "No packages removed"。

## 2.11.0 — 2026-10-25

- **LuCI 状态页运行时长永远是 `—`**：`luci.sys.exec()` 返回的 PID **带尾部换行**，
  拼成 `/proc/10758\n/stat` 后 `io.open` 必然返回 nil
- 解析 `/proc/<pid>/stat` 要从**最后一个 `)`** 往右切（`comm` 带括号且可能含空格）
- Lua 的 `trim()` 必须写成 `return (s:gsub(...))` —— `gsub` 返回两个值，
  直接 return 会让上层 `tonumber(x, count)` 报 base out of range
- `nixio.fs.chmod` 只吃八进制字符串（`"0600"`），传十进制 384 直接报错
- 改密码走 CBI：`o.write = function() end` 接管，在 `on_after_save` 里自己写 JSON

---

## 2.10.0 — 2026-10-25

真机实测驱动的对比度修正。手机没锁屏密码，可以 adb 切深色、逐页截图、量像素算对比度。

| 位置 | 改前 | 改后 |
|---|---|---|
| 导航栏未选中图标（浅色） | 3.22:1 | 6.16:1 |
| 导航栏未选中图标（深色） | 6.22:1，选中才 6.46 | 5.33:1，选中 9.0 |
| 浅色 hero 白字 | **3.04:1** | 5.0:1+ |
| 深色 hero 说明字 | 3.36~4.02:1 | 8.9:1 |

三个根因都不是「换个颜色」能解决的：

1. **导航图标复用了正文次要色** `text_secondary`。图标是实心小块 + 尺寸小，
   比正文更需要对比补偿，必须独立语义色 `icon_off`
2. **hero 卡直接拿 `primary` 当渐变起点**。浅色 `#00A87E` 太浅压不住白字；
   新增 `hero_from / hero_to / hero_fg / hero_stroke` 四色，两套主题都是「深底浅字」
3. **`Ui.kv` 的值用 WRAP_CONTENT**：LinearLayout 先按内容测值宽度再让标签分剩余，
   IPv6（39 字符）直接顶穿卡片右边距 → 改值 `weight=1` + 关 hyphenation

---

## 2.9.0 — 2026-10-25

- 底部导航图标、趋势图升级、骨架屏、概览页重做
- **`View.setAlpha(0)` 会连整棵子树一起透明** —— 未选中的导航图标完全不显示，
  因为图标被放进了要淡出的胶囊背景里。修法：胶囊和图标必须是兄弟层
- **Shimmer 不适合做骨架屏**：它给整个子树套一层 `SRC_IN` 着色遮罩，
  「白卡片 + 灰文字条」被染成同一个颜色，只剩一块均匀浅灰矩形。
  改成自绘脉冲（保留真实颜色层次，只让整体 alpha 在 0.42↔1 呼吸），依赖已移除

## 2.8.0 — 2026-10-25

纯自绘视觉升级，零新依赖：

- **配色分层**：浅色 `app_bg` `#F2F2F7 → #EDF3F0`（掺冷绿调，纯中性灰像后台管理面板）；
  深色 `#000000 → #0A100E`，卡片 `#1C1C1E → #1A2421`（纯黑背景上卡片浮不起来）
- 卡片加 1.2dp elevation —— **不能给大**，深色下会变成一圈脏边
- 新增 `Ui.group()` / `listRow()` / `hairline()`：设备页 55 台设备从 55 张独立卡
  （55 层圆角 + 55 层投影）改成一组一个容器 + 细分隔线
- 新增 `Ui.num()`：medium 字重 + `'tnum'`（tabular），否则列表里数字不等宽，
  小数点左右跳
- 拦截排行次数从大红字改成黑色 —— 拦截是好事，红色该留给危险操作

## 2.7.1 — 2026-10-25

修「DNS 链路」卡文字被切。根因两层：

1. 横向 `LinearLayout` 里放了个 `MATCH_PARENT` 高的装饰 View 当轨道，
   它要等父高度确定后二次测量，和右侧 `weight=1` 的文字列互相挤压 → 文字被压扁
2. 改成自绘后又踩第二个：容器加 `paddingLeft` 留轨道，同时用 `leftMargin` 定位圆点 ——
   FrameLayout 子 View 的定位是 **padding + margin**，两边都算一遍，圆点压到第一个字上

最终实现：轨道靠 body 的 `leftMargin` 让出来，竖线在 `onDraw` 里画（不参与测量），
`ViewGroup` 无背景时必须 `setWillNotDraw(false)`。

## 2.7.0 — 2026-10-25

- **自绘底部导航** `widget/NavBar.java`，弃用 `BottomNavigationView`
- **`widget/Sheet.java` 成为全站唯一弹窗入口**，替换所有 `MaterialAlertDialogBuilder`
- 新增「宽带连接」「机器信息」两个二级页；概览页不塞这两个接口，避免拖慢首屏
- 后端 `agent/hardware.py`：DMI + 手写 SMBIOS Type 17 解内存条、PCI_ID 查网卡、
  hwmon 找 NVMe 温度
- 后端 `agent/netcfg.py`：WAN 改密码只回掩码 `9****2`，保存前三重保险
  （备份 → 独立进程 90 秒后验收 `up:true` + ping 通 → 不通自动回滚）
- **Agent 打成 iStoreOS 插件**（ipk），LuCI 里可看状态、改端口、下载 App

## 2.6.0 — 2026-10-25

### 修：iPhone 连着 WiFi 却显示离线

在线判定原来只看邻居表 `state ∈ {REACHABLE, DELAY, PROBE}`。
**iPhone 锁屏不回 ARP**，条目一直挂在 STALE，但 WiFi 没断、APNs 长连接还在跑。
实测那台机器在 conntrack 里有 79 条 ESTABLISHED，邻居表却是 STALE。

改成四路交叉，任一命中即在线：邻居表状态 / 150 秒内出现过流量 / `used ≤ 150s` /
主动 ping 通。在线数 32 → 47。

### 新：离线域名库

路由器装了 `v2ray-geosite`（1436 个分类）。手写 protobuf 解码，
挑 150 个常用分类 → **18.2 万条域名**，8.37 MB 压到 1.48 MB，加载 0.34 秒。

## 2.5.0 — 2026-10-25

- **设备识别重做**：之前直接显示 IEEE 原始名（`Zhen Shi`、`Imilab Technology Co.L`）。
  优先级改成 主机名特征 > OUI 中英翻译 > 主机名前缀 > 原始 OUI，
  返回 `{brand, type, model}`
- 新增 `label` 显示名：备注名 > 人话主机名 > 型号（仅手机/电脑/电视/NAS）> 品牌+类型
  —— `gree-c5-65-28`、`HN55DNTA-b997fe...` 这类机器名不再当标题
- 坑：备注名要参与识别。用户把 NAS 备注成「绿联nas」而 DHCP 主机名是空的，
  只看主机名会按 OUI 认成格力
- 排序改为**实时流量从高到低**，用 0.6/0.4 滑动平均（3 秒瞬时值会让列表每刷新一次换顺序）；
  2 KB/s 以下当空闲
- 累计用量落盘，跨重启保留

## 2.4.0 — 2026-10-25

- **全站口令统一为单一口令**（Agent / AGH / SSH / 后台 / keystore）。
  配置已存在也强制同步 —— 原来的「存在就跳过」会让密码永远改不掉
- **拦截排行**：首屏 5 条 + 二级页完整日志。次数取 AGH `stats.top_blocked_domains`
  （跨整天稳定），最后时间 / 规则从最近拦截日志反查
- 坑：1000 条拦截日志只覆盖 8.5 分钟（拦截约 2 条/秒），榜单靠前的域名可能不在
  最近日志里 → 对缺失的域名单独 `search=<domain>` 补查
- 二级页：只看拦截 / 全部查询分段 + 域名搜索（400ms 防抖）+ 100 条/页

## 2.3.0 — 2026-10-25

- **AdGuard Home 接管全网**。接管前定的四条，每条都是踩过或差点踩的坑：
  1. 上游从 `uci show dhcp` 现读，不写死。AGH 用公共 DNS 当上游 = 域名绕开
     OpenClash = 国外解析不到、国内没 fake-ip，分流整条废
  2. dnsmasq 挪到 5354，**不能设 `port=0`** —— 家里 25 条静态绑定和 `.lan` 域名
     全靠它，关掉后 NAS / 打印机只能靠 IP 访问
  3. **AAAA 不动**。`filter_aaaa_dns=1` 是刻意开的（防 IPv6 泄漏），
     不要「帮」用户打开 AAAA，那会让域名优先走 IPv6 直连绕过代理
  4. 接管后实测三类域名（国内 / 国外 / 本地），任一失败自动回滚
- **应用用量账本**：按域名特征累计，`/api/v1/apps`
- YAML 里 `[/lan/]127.0.0.1:5354` **必须加引号**，开头的 `[` 会被当成 flow sequence，
  AGH 直接启动失败

## 2.2.0 — 2026-10-25

- **应用识别**：路由器在转发路径上，Mihomo 对 redir 流的 `process/processPath`
  恒为空（uid 都是 0），所以「应用」只能靠**域名特征**反推
- 拦截日志接口、组测速接口（Mihomo `/group/{name}/delay` 一次打完一组，
  65 节点 2 秒返回；Passwall 无此接口则 16 线程并发 TCP 握手）
- 修「GLOBAL 组怎么点都收不起来」：原逻辑「展开集合为空就自动展开第一组」，
  收起唯一展开的组后集合归空，下次渲染又自动展开

## 2.1.x — 2026-10-24

- **设备管理**：列表 + 详情页 + 改名 / 禁网 / 固定 IP / 网络唤醒
- 原「网络」页并入设置
- 真机验证后修四处：主板占位型号过滤、节点名国旗 emoji 显示成方块、
  未测速显示 `0ms`、版本号改从包信息读取

## 2.0.0 — 2026-10-24

**从 WebView 套壳重写为纯原生。** 1.0.0 是薄壳加载路由器网页，实测三个硬伤：
冷启动要等网页和接口三跳、滚动点击没有原生手感、离开路由器就只剩错误页。

## 1.0.0 — 2026-10-24

首个可用版本，WebView 套壳。功能可用，体验不合格。
