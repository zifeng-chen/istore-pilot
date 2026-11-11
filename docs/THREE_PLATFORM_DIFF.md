# 三端差异清单（以 Android 为基准）

> 审查日期：2026-11-11（同日修复完毕，见第三节）
> 方法：先对齐三端文件与接口清单，再用「接口调用对比 + 功能词存在性检查」定位差异，
> 对每个疑点回读源码确认。
> 覆盖：14 个界面 + 接口差异。**未做**逐行通读（三端合计约 3.9 万行），
> 布局细节、动画、无障碍等未覆盖。

## 一、页面映射（三端结构基本一致）

| 逻辑页 | Android | iOS | 鸿蒙 | 形态差异 |
|---|---|---|---|---|
| 页签容器 | `MainActivity` + `NavBar` | `RootView` | `pages/Index` + `NavBar`/`SideNav` | 均为 4 页签：概览/设备/代理/设置 |
| 概览 | `OverviewFragment` (838) | `OverviewView` (562) | `OverviewPage` (845) | — |
| 设备（含拦截） | `SecurityFragment` (688) | `SecurityView` (560) | `SecurityPage` (1235) | 三端都把「设备」和「拦截」合成一个一级页 |
| 设备清单 | `DevicesFragment` (544) | `DevicesView` (483) | `DevicesPage` (696) | 二级页（鸿蒙走页内 subTitle，无路由栈） |
| 设备详情 | `DeviceDetailActivity` (821) | `DeviceDetailView` (373) | `DeviceDetailPage` (466) | — |
| 拦截详情 | `AdblockFragment` (1270) | `ShieldView` (596) | `ShieldPage` (1004) | — |
| 应用流量 | `AppsActivity` (324) | `AppsView` (202) | 内嵌在 `SecurityPage` | 鸿蒙没有独立页 |
| 代理 | `ProxyFragment` (2599) | `ProxyView` (1293) | `ProxyPage` (2319) | — |
| 订阅 | `SubscriptionActivity` (383) | `SubscriptionView` (303) | `pages/SubscriptionPage` (350) | — |
| 设置 | `SettingsFragment` (1093) | `SettingsView` (923) | `SettingsPage` (1289) | — |
| 网络/宽带 | `WanActivity` (860) | `WanView` (628) | `NetworkPage` (933) | 鸿蒙是独立 tab 文件但不在页签里 |
| 硬件 | `HardwareActivity` (614) | `HardwareView` (420) | `HardwarePage` (设置内子页) | 见 D6（已统一） |
| 备份 | `BackupActivity` (340) | `BackupsView` (280) | `BackupsPage` (295) | — |
| 登录 | `LoginActivity` | `LoginView` (290) | `LoginPage` (225) | — |
| 内置网页 | `WebActivity` (356) | `WebScreen` (328) | `pages/WebPage` (307) | — |

## 二、接口一致性

修复前：Android 51 / iOS 50 / 鸿蒙 52 条，共同 47 条，差异 8 条。
**修复后：Android 53 / iOS 54 / 鸿蒙 54 条，共同 51 条，只剩 4 条差异**
（`python scripts/api_parity_check.py`，2026-11-11 实测）：

| 接口 | Android | iOS | 鸿蒙 | 结论 |
|---|---|---|---|---|
| `/system/uploads` | ❌ | ✅ | ❌ | D8，用户决定不做 |
| `/net/pending` | ❌ | ❌ | ✅ | 鸿蒙的网络页有常驻「待确认」卡片；另两端走 D1 的即时弹窗，不需要 |
| `/proxy/pkg/probe` | ❌ | ❌ | ✅ | 鸿蒙装插件前多探一次下载通道，无功能影响 |
| `/traffic` | ❌ | ❌ | ✅ | 鸿蒙单独拉流量；另两端从 `/overview` 取 |

`/proxy/pkg/confirm`、`/proxy/uninstall`、`/net/confirm`、`/net/rollback`
四条在 D1–D3 修完后三端都已调用。

## 三、差异清单

### 修复记录（2026-11-11）

| # | 状态 | 做法 |
|---|---|---|
| D1 | ✅ 已修 | 三端都在「恢复备份」成功后就地弹确认框（确认保留 / 撤销改动），把 agent 返回的 `token` 带回去调 `/net/confirm` 或 `/net/rollback`。Android `BackupActivity.postNetTxn`、iOS `BackupsView.postTxn`、鸿蒙 `BackupsPage.postTxn` |
| D2 | ✅ 已修 | iOS `ProxyView` 与鸿蒙 `ProxyPage` 补上 `pkg.waiting == "hosts_fix"` 的检测与确认框，接 `/proxy/pkg/confirm`（yes/no），每次新装重置一次 |
| D3 | ✅ 已修 | iOS 插件管理 Sheet 加「已安装」段（点击确认后卸载）；鸿蒙同位置加「已安装」+ 卸载按钮，接 `/proxy/uninstall` |
| D4 | ✅ 已修 | 鸿蒙 `DevicesPage` 加搜索框（名称/IP/MAC/厂商，不区分大小写），列表走 `hit()` 过滤 |
| D5 | ❌ 撤销 | **原判断有误**：iOS 与鸿蒙并不缺这个标记。agent 把随机地址的 `vendor` 直接填成 `"随机 MAC"`，两端都是原样展示 vendor，效果与 Android 一致。之前用关键词统计得到「缺失」是假阳性 |
| D6 | ✅ 已修 | 三端统一成「设置 → 设备信息（处理器/内存/系统盘）→ 查看全部硬件 → 独立页」。鸿蒙新增 `ui/tabs/HardwarePage.ets`（hero + CPU + 内存条 + 磁盘 + 网卡 + 温度 + PCI），设置页原来那六行内联字段收成三行概览 + 一个入口 |
| D7 | ✅ 已修 | iOS 四个页签加 `.refreshable`（概览/设备/代理/设置），鸿蒙四个页签最外层 `Scroll` 包 `Refresh`（`$$this.pulling` + `onRefreshing`）；两侧都是等接口回来才收转圈 |
| D8 | ⛔ 不做 | 用户 2026-11-11 决定：`/system/uploads`（列出路由器上已有的升级包）不补，Android/鸿蒙保持现传 |
| D9 | ⛔ 不做 | 用户 2026-11-11 决定：改 LAN 网段（`/net/lan`）不加入口，改错会断网，不值得 |
| D10 | ✅ 已修 | **新发现（审查漏掉的）**：鸿蒙页签序号写错。设备页/设备清单/拦截页判 `tab === 2`（那是代理页）、设置页判 `tab === 4`（只有四个页签）。结果这三页切过去时走 else 分支把轮询停掉，进页面后数字再也不动，设置页的 WAN 地址也不跟着刷新。改为 1 / 1 / 1 / 3 |

### D1【严重】恢复配置备份后，Android / iOS 无法确认，90 秒后被自动回滚

**证据**
- `agent/cfgbak.py:201` 恢复备份时 `netapply.begin("config-restore", ...)`，返回 `token`/`wait`/`deadline`，
  并明确说明「如果 N 秒内没有回到 App 点确认，会自动退回恢复前的状态」
- Android `BackupActivity.java:266` 提示：「已恢复…请到网络页确认这次改动。」
- iOS `BackupsView.swift:243` 提示：「已恢复…请到网络页确认这次改动。」
- 但 **Android `WanActivity` 和 iOS `WanView` 都没有 `/net/pending`、`/net/confirm`、`/net/rollback`**
  → 用户按提示过去，找不到任何确认入口
- 只有鸿蒙 `NetworkPage.ets:747/762` 实现了确认与回滚

**后果**：用户在 Android/iOS 恢复备份 → 提示去确认 → 没有入口 → 超时自动回滚 →
「恢复成功」的配置自己变回去了，且没有任何二次提示。

**修法（二选一）**
1. 两端补上「待确认」卡片（对齐鸿蒙 `NetworkPage` 的 `pendOn/pendToken/doConfirm/doRollback`）
2. 或在恢复成功后直接弹一个「立即确认 / 撤销」的对话框，把 token 带过去

### D2【中】改 hosts 加速确认框，只有 Android 有

`/proxy/pkg/confirm` 只在 `ProxyFragment.java:1023`。
iOS/鸿蒙安装代理插件时，如果所有下载通道都失败，agent 会进入 `waiting="hosts_fix"` 等确认，
但两端没有弹框逻辑 → 用户只能看着安装卡住，直到 5 分钟超时。

（agent 侧 `_await_hosts_confirm` 等待 5 分钟。iOS/鸿蒙的轮询里没有读 `pkg.waiting`。）

### D3【中】卸载代理插件，只有 Android 有

`/proxy/uninstall` 只在 `ProxyFragment.java`。iOS/鸿蒙的代理页只能安装和启停，**不能卸载**。
换插件只能去 LuCI 或命令行。

### D4【中】设备清单搜索，鸿蒙缺

- Android `DevicesFragment.java:186`：`"搜索名称、IP、MAC 或厂商"` 输入框
- iOS `DevicesView.swift`：有搜索
- 鸿蒙 `DevicesPage.ets`：**没有搜索框**（全仓只有 `SecurityPage.ets:40` 一句注释提到「搜索框」）

设备多的时候鸿蒙只能靠滚动找。

### D5【低】「随机 MAC」标记，只有 Android 有

Android `DevicesFragment`/`DeviceDetailActivity` 识别并标注随机 MAC（`"随机"` 出现 4 次）。
iOS 与鸿蒙全仓 **零处**，同一台设备在两端看不出是随机地址。

### D6【低】硬件页形态不同 —— ✅ 已修（2026-11-11）

| 端 | 修前 | 修后 |
|---|---|---|
| Android | 独立页 `HardwareActivity`，从设置进入 | 不动 |
| iOS | 独立页 `HardwareView`，概览和设置都能进 | 不动（超集，概览那个入口留着，删掉是减功能） |
| 鸿蒙 | 设置页内 `hardwareCard()`，只有 6 行字 | 新增独立页 `ui/tabs/HardwarePage.ets` |

鸿蒙这一页按另两端的顺序铺：hero（主机名 / 发行版 / 架构 + CPU 核数、内存、运行时长）→
处理器（含 VT / AES 标记）→ 内存（占比条 + 内存条明细）→ 存储 → 网卡 → 温度 → PCI。

入口也换成和 Android 一样的形状：设置页「设备信息」卡只留处理器 / 内存 / 系统盘三行，
第四行「查看全部硬件」进子页。原来的六行内联字段（型号、核心、主频、缓存、机型、BIOS）
往后加一项就要往下挪一屏，而真正值钱的明细（内存条、磁盘、温度）一处也没露。

子页走的是设置页自己的 `sub` 状态（`'backup' | 'hardware'`），并接上 `Shell.enter/leave`：
底部导航收起、系统返回手势退回设置页，和「设备 → 设备清单」那套一致。
顺带修掉了「配置备份」子页此前不通知壳层、底部导航压在内容上的问题。

### D7【低】下拉刷新，只有 Android 有 —— ✅ 已修（2026-11-11）

- iOS：四个页签的 `ScrollView` 加 `.refreshable { await load() }`
  （`OverviewView` / `SecurityView` / `ProxyView` / `SettingsView`）。
  部署目标是 iOS 16.0，ScrollView 支持 `.refreshable` 正好从 16 开始。
- 鸿蒙：四个页签最外层包 `Refresh({ refreshing: $$this.pulling })`，
  `onRefreshing` 里 `await` 真正的取数、回来再收起转圈 —— 提前松手会看着像没刷新。
  代理页下拉会把插件状态一起重读（`loadPkg(true)`），装完插件下拉一下就能看到「已安装」。

### D8【低】系统上传，只有 iOS 有 —— ⛔ 不做（2026-11-11 用户决定）

`/system/uploads`（列出路由器上已有的升级包）属新增功能，Android / 鸿蒙保持
「现从手机里选文件上传」这一条路，不再加选择列表。

### D9【提示】鸿蒙的「待确认」UI 在正常路径下不会触发 —— ⛔ 不做（2026-11-11 用户决定）

改 LAN 网段（`/net/lan`）三端都不加入口。改错会直接断网，收益不抵风险。
`/net/pending` 那套卡片保留，只服务「恢复配置备份」这一个场景（D1）。

### D10【中】鸿蒙页签序号写错，三页从不轮询 —— ✅ 已修（2026-11-11）

**证据**（`UI.tab` 就是页签下标：0 概览 / 1 设备 / 2 代理 / 3 设置）

| 文件 | 修前 | 修后 |
|---|---|---|
| `SecurityPage.ets` | `this.tab === 2` | `=== 1` |
| `DevicesPage.ets` | `this.tab === 2` | `=== 1` |
| `ShieldPage.ets` | `this.tab === 2` | `=== 1` |
| `SettingsPage.ets` | `this.tab === 4` | `=== 3` |

**后果**：切到「设备」页（`tab=1`）时 `onTab` 走 else 分支把定时器停掉，
`aboutToAppear` 里也因为同一个条件不启动 —— 设备页、设备清单、拦截页只有首次
进入时取过一次数，之后在线数、流量、拦截条数全是死的；设置页的 WAN 地址同理，
从网络页回来不会重取。Android 的 `BaseFragment` 是按 `position` 传的，没有这个问题。

## 四、已核实「不是差异」的项

| 疑点 | 结论 |
|---|---|
| 鸿蒙页签第二个是 `SecurityPage` | 它就是「设备」页（设备+拦截合并），与 Android `SecurityFragment`、iOS `SecurityView` 对应 |
| 鸿蒙没有「当前配置」字样 | 有配置文件切换，用的是「配置文件」，接口 `/proxy/configs` 同样调用 |
| iOS/鸿蒙没有「拦截规则」字样 | 都有（iOS「规则条数」、鸿蒙「规则更新」），措辞不同 |
| 鸿蒙叫「查询日志」 | 与另两端的「拦截日志」是同一功能 |
| iOS 没有「可达」字样 | 用的是「N 个节点可用」 |
| `/traffic` 只在鸿蒙 | 另两端从 `/overview` 取流量，需确认字段一致（未验证数值等价） |

## 五、处置结果

| # | 结论 | 落地 |
|---|---|---|
| D1 | 已修 | 三端恢复备份后当场确认 / 撤销 |
| D2 | 已修 | iOS / 鸿蒙补 `waiting="hosts_fix"` 确认框 |
| D3 | 已修 | iOS / 鸿蒙补插件卸载 |
| D4 | 已修 | 鸿蒙补设备搜索 |
| D5 | 撤销 | 原判断是假阳性（agent 直接把 vendor 填成「随机 MAC」） |
| D6 | 已修 | 鸿蒙新增硬件详情页 + 「查看全部硬件」入口 |
| D7 | 已修 | iOS `.refreshable` ×4，鸿蒙 `Refresh` ×4 |
| D8 | 不做 | 用户决定 |
| D9 | 不做 | 用户决定 |
| D10 | 已修 | 鸿蒙页签序号 2→1 / 4→3 |

到此三端界面与功能对齐，没有待办项。后续新增界面时：
**先在三端各过一遍，别让某一端单独长出一个形态。**

## 六、复跑命令

```bash
python scripts/api_parity_check.py     # 接口一致性（新增/删除接口后跑）
python scripts/ui_text_diff.py         # 单页文案对照（按页名过滤：ui_text_diff.py proxy）
```
