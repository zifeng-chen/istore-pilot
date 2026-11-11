# 三端差异清单（以 Android 为基准）

> 审查日期：2026-11-11
> 方法：先对齐三端文件与接口清单，再用「接口调用对比 + 功能词存在性检查」定位差异，
> 对每个疑点回读源码确认。
> 覆盖：14 个界面 + 8 处接口差异。**未做**逐行通读（三端合计约 3.9 万行），
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
| 硬件 | `HardwareActivity` (614) | `HardwareView` (420) | 内嵌在 `SettingsPage` | **形态不同，见 D6** |
| 备份 | `BackupActivity` (340) | `BackupsView` (280) | `BackupsPage` (295) | — |
| 登录 | `LoginActivity` | `LoginView` (290) | `LoginPage` (225) | — |
| 内置网页 | `WebActivity` (356) | `WebScreen` (328) | `pages/WebPage` (307) | — |

## 二、接口一致性

三端去重后：Android 51 / iOS 50 / 鸿蒙 52 条，**共同 47 条**。差异 8 条：

| 接口 | Android | iOS | 鸿蒙 | 说明 |
|---|---|---|---|---|
| `/proxy/pkg/confirm` | ✅ | ❌ | ❌ | 见 D2 |
| `/proxy/uninstall` | ✅ | ❌ | ❌ | 见 D3 |
| `/system/uploads` | ❌ | ✅ | ❌ | 见 D8 |
| `/net/pending` | ❌ | ❌ | ✅ | 见 D1 |
| `/net/confirm` | ❌ | ❌ | ✅ | 见 D1 |
| `/net/rollback` | ❌ | ❌ | ✅ | 见 D1 |
| `/proxy/pkg/probe` | ❌ | ❌ | ✅ | 鸿蒙多一次通道探测，无功能影响 |
| `/traffic` | ❌ | ❌ | ✅ | 鸿蒙单独拉流量；另两端从 `/overview` 取，需确认字段等价 |

## 三、差异清单

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

### D6【低】硬件页形态不同

| 端 | 形态 |
|---|---|
| Android | 独立页 `HardwareActivity`，从设置进入 |
| iOS | 独立页 `HardwareView`，**概览和设置都能进** |
| 鸿蒙 | 设置页内的 `hardwareCard()`，没有独立页 |

功能（`/system/hardware`）三端都有，只是入口与承载方式不同。
附带发现：iOS 比 Android 多一个概览页入口。

### D7【低】下拉刷新，只有 Android 有

Android `BaseFragment` 用 `SwipeRefreshLayout`（所有页签都有）。
iOS 全仓无 `.refreshable`，鸿蒙全仓无 `Refresh` 组件 —— 两端靠 3 秒定时轮询。

不算功能缺失，但用户想「立刻刷一次」时没有手势。

### D8【低】系统上传，只有 iOS 有

`/system/uploads`（上传安装包/升级包）只在 `SettingsView.swift`。
Android 与鸿蒙不能上传，只能在线检查更新。

### D9【提示】鸿蒙的「待确认」UI 在正常路径下不会触发

`NetworkPage` 的 pending 卡片依赖 `/net/pending`。而创建事务的只有两处：
`cfgbak.restore`（配置恢复）和 `lanedit.apply`（改 LAN 网段）。
三端**都没有** `/net/lan` 调用 → 除了「恢复备份」这个场景，这套 UI 平时不会出现。
如果本意是要支持改 LAN 网段，那三端都还差一个入口。

## 四、已核实「不是差异」的项

| 疑点 | 结论 |
|---|---|
| 鸿蒙页签第二个是 `SecurityPage` | 它就是「设备」页（设备+拦截合并），与 Android `SecurityFragment`、iOS `SecurityView` 对应 |
| 鸿蒙没有「当前配置」字样 | 有配置文件切换，用的是「配置文件」，接口 `/proxy/configs` 同样调用 |
| iOS/鸿蒙没有「拦截规则」字样 | 都有（iOS「规则条数」、鸿蒙「规则更新」），措辞不同 |
| 鸿蒙叫「查询日志」 | 与另两端的「拦截日志」是同一功能 |
| iOS 没有「可达」字样 | 用的是「N 个节点可用」 |
| `/traffic` 只在鸿蒙 | 另两端从 `/overview` 取流量，需确认字段一致（未验证数值等价） |

## 五、建议修复顺序

1. **D1**（严重，用户数据会"莫名回滚"）—— 两端补确认入口
2. **D2**（安装会卡死无提示）—— 两端补 `waiting` 轮询与确认框
3. **D3**（缺功能）
4. **D4**（鸿蒙搜索）
5. D5–D8 按排期

## 六、复跑命令

```bash
python scripts/api_parity_check.py     # 接口一致性（新增/删除接口后跑）
python scripts/ui_text_diff.py         # 单页文案对照（按页名过滤：ui_text_diff.py proxy）
```
