# 三端 UI 一致性审查报告

> 按 `docs/UI_REVIEW.md` 的清单做第一轮**静态扫描**。证据来自源码（文件:行），
> 只下「实现漂移 / 硬编码 / 待真机验证」三类结论；键盘、刘海、底栏遮挡等
> 运行时表现一律标「待真机验证」，不凭静态猜。
>
> 生成时间：2026-11-06。方法：grep 硬编码颜色/尺寸 + 组件契约比对 + 三端同语义对照。

## 结论速览

- 治理得不错的部分：三端都有统一的 gutter(16)、卡片内边距(16)、字号 Token、
  无裸 px 布局；深浅色都走动态 Token。
- 主要问题集中在**一类**：状态色（在线/离线/运行中）三端各自硬编码，且值还不一样。
- 审查过程中发现并**当场修掉** 2 处我自己上一版引入的双重留白（见 §3）。

---

## 1. 硬编码颜色（P2）

### 1.1 iOS「在线绿 / 离线红」散落 6+4 处，无 Token、不随主题变

| 位置 | 证据 | 说明 |
|---|---|---|
| `DeviceDetailView.swift:66/73/75` | `Color(hex: 0x5FE7C4)` / `0xFF7A6B` / `0xFF9F8F` | 在线绿 + 离线红 |
| `OverviewView.swift:104` | `Color(hex: 0x5FE7C4)` / `0xFF7A6B` | WAN 通/断 |
| `ProxyView.swift:128/183/187/209/214` | `0x5FE7C4` / `0x073128` / `0x5FE7C4` | 运行态点、hero 上文字色 |
| `SettingsView.swift:142` | `Color(hex: 0x5FE7C4)` | 状态点 |
| `ShieldView.swift:212/233` | `0xFFB020` / `0x5FE7C4` / `0xFF7A6B` | 警告点、运行态 |
| `WanView.swift:110` | `0x5FE7C4` / `0xFF7A6B` | 通/断 |

**静态证据**：`0x5FE7C4` 出现 8 次、`0xFF7A6B` 出现 5 次、`0xFFB020` 出现 1 次，
都不在 `Theme.swift` 的 `C.*` 里，也不是 `C.ok`(0x34C759) / `C.danger`(0xFF3B30) 的变体。
它们**不随深浅色切换**（固定值），和「在线绿」「离线红」两个语义绑定。

**风险**：改一处漏一处；浅色下 `0x5FE7C4` 对比度待验（压在白卡上偏浅）。
**建议**：在 `Theme.swift` 补 `C.online`（亮绿）/ `C.offline`（暖红）/ `C.warnBright`，
6 个文件收口；或直接复用 `C.ok`/`C.danger` 并删掉这几处语义分叉。

### 1.2 三端「在线」颜色值不一致（同一语义，三个值）

| 端 | 在线指示色 | 出处 |
|---|---|---|
| Android | `R.color.primary`（#00A87E / 深色 #32D7AC） | `SecurityFragment.java:146` |
| 鸿蒙 | `Pal.primary()`（同上） | `SecurityPage.ets:508` StatCell tone |
| iOS | `Color(hex: 0x5FE7C4)` 固定值 | 见上表 |

**结论**：违反 `UI_REVIEW.md` §三「三端同口径」。iOS 应该和其它两端一样用 `primary`
（或三端一起改成同一个「在线」专用 Token），而不是一个既不随主题、也不等于其它两端的硬编码。

### 1.3 鸿蒙 `ProxyPage.statusColor()` 重复实现调色板

`ProxyPage.ets:288-296` 的 `statusColor()` 返回 `'#8E8E93' / '#34C759' / '#FF9500' / '#FF3B30'`，
正好是 `Pal.textSecondary() / Pal.ok() / Pal.warn() / Pal.danger()` 的浅色值。
这是**把调色板抄了一份**——深浅色切换时这四个会固定在浅色值上。收口到 `Pal.*`。

### 1.4 Android 内联 alpha 位运算，重复 `Ui.alpha()`

`Ui.java:426` 已经提供 `alpha(base, v)`，但下面几处还在手写同一套位运算：

| 位置 | 写法 |
|---|---|
| `OverviewFragment.java:452` | `(base & 0x00FFFFFF) | 0x22000000` |
| `SecurityFragment.java:270/632` | `(base & 0x00FFFFFF) | 0x1F000000` |
| `Ui.java:198/882` | 同上（自己文件里没用自己写的 `alpha`） |

**风险**：0x22 / 0x1F 这类魔法 alpha 值分散，改透明度得全仓搜。
**建议**：统一 `Ui.alpha(base, 0.10f)` 之类，透明度写成分数，别写 16 进制位移。

### 1.5 零散硬编码状态色（P3）

- `BaseFragment.java:79/369`：`0x1AFFB454`（warn 10%）、`0x1A34C759`（ok 10%）→ `Ui.alpha(R.color.warn/ok, 0.10f)`
- `GraphView.java:49`：`0x1A2DD4A7` 填充色，未进 `R.color`
- 鸿蒙 `SettingsPage.ets:281` `#CC1F2A26`、`NetworkPage.ets:302` `'#FFFFFF'` 字面量 → 应走 `Pal`/`Comp.alpha` 语义色

---

## 2. 空间与尺寸（P3）

### 2.1 卡片圆角三端差 2

| 端 | 卡片圆角 | 出处 |
|---|---|---|
| Android | 20dp | `styles.xml` `cardCornerRadius` |
| iOS | 22 | `Theme.swift` `R.card = 22` |
| 鸿蒙 | 22 | `Theme.ets` `T.R_CARD = 22` |

**结论**：Android 比另两端少 2。视觉上几乎看不出，但按「同口径」应该统一（建议 22，或三端一起改 20 也行，只要一致）。

### 2.2 空间责任：本轮已核对通过

- 三端 gutter 都由页面根容器给 16（Android `Ui.dp(16)` / iOS `.padding(.horizontal,16)` / 鸿蒙 `.padding({left:16,right:16})`）
- 卡片内边距都由 `Card` 给（16），未发现页面反向补 padding 的漂移
- 底栏：iOS `BottomBar` 参与布局（内容不需让位）、鸿蒙 `SideNav`/底栏同理，Android 底部导航 — 未发现内容被栏遮挡的静态证据

---

## 3. 审查过程中当场修掉的问题

上一版给鸿蒙「卡片头贴边」批量补 `pad:16` 时，正则把 `Card()`（无参，自带 16 内边距）
误判成了 `RowCard()`，导致两处头部**双重留白 32pt**。本次复核发现并已去掉：

| 位置 | 容器 | 修复 |
|---|---|---|
| `ProxyPage.ets:452` | `Card()` | 去掉 `pad:16` |
| `SecurityPage.ets:503` | `Card()` | 去掉 `pad:16` |

复核脚本已确认：剩余 16 处 `CardTitle` 的 `pad` 与容器全部匹配，`hvigor BUILD SUCCESSFUL`。
这条也补进了 `UI_REVIEW.md` 的已知坑表。

---

## 4. 待真机验证（静态扫描无法下结论）

- 键盘弹起：三端输入框是否被顶起、底部固定操作是否仍可达
- 刘海/灵动岛/Home Indicator：iOS 安全区、鸿蒙挖孔/圆角避让
- 折叠态/分屏：鸿蒙 Duo 展开/折叠、Android 分屏，是否按窗口宽度重算
- 深浅色：硬编码状态色（§1.1）在深色下的对比度与观感
- 列表最后一项：是否被底栏/固定按钮遮挡

---

## 5. 建议的收口顺序

1. 先定「在线/离线/警告」三个状态色的三端统一 Token（影响面最大、最容易被下一个人改歪）。
2. 鸿蒙 `statusColor()` 收口到 `Pal.*`，Android 内联 alpha 收口到 `Ui.alpha()`。
3. 卡片圆角统一成 22（或 20，一次性三端改）。
4. 剩余零散硬编码（GraphView、SettingsPage scrim）按需收口，不强求。
