# 鸿蒙重构评估：范围 · 影响面 · 回滚方案

> 生成时间：2026-11-06。基于当前代码实测（11924 行 .ets，19 个文件）。
> 这是一份**评估**，不是开工令——每一项都列了收益、风险和回滚，你拍板再动。

## 先厘清：真正的重构目标是什么

实测下来，鸿蒙代码的「大」不在组件库，而在**页面**：

| 文件 | 行数 | 问题 |
|---|---|---|
| SettingsPage.ets | 1287 | 单页塞了 hero + 多个卡片 + 浮层弹窗 |
| SecurityPage.ets | 1230 | 设备 + 拦截两套逻辑挤一页 |
| ShieldPage.ets | 1000 | 规则/日志/排名全在一页 |
| ProxyPage.ets | 965 | 节点分组 + 测速 + 后端切换 |
| NetworkPage / OverviewPage / DevicesPage | 692–930 | 同上，页面越来越胖 |
| **Comp.ets（组件库）** | **617** | **不算大，不是主要矛盾** |

所以「拆 Comp.ets」不是重点；重点是**大页面 + 状态管理 V1**。下面按真实目标列。

---

## 目标 A：V1 → V2 状态管理迁移（影响最大，最不急着做）

**现状**：全用 ArkUI V1 装饰器，实测用量：

| 装饰器 | 用量 |
|---|---|
| `@State` | 234 |
| `@Prop` | 69 |
| `@Watch` | 30 |
| `@StorageProp` | 19 |
| `@Link` | 2 |
| `@BuilderParam` | 4 |
| `@StorageLink` | 1 |

合计约 **360 处、分布在近 20 个文件**。

**要改成**：`@ComponentV2` + `@Local`（替代 @State）/ `@Param`（替代 @Prop，只读）/ `@Event`（子改父）/ `@Monitor`（替代 @Watch）/ `@Computed`。

**影响面**：
- `@Param` 是**只读**的，`@Prop` 改成它之后，子组件所有「直接改 prop」的写法都要改成 `@Event` 回调——这是**语义级**变化，不是机械替换。
- `@Watch` → `@Monitor` 的触发时机/参数不同，30 处要逐个核对（我们 `@Watch` 多是联动刷新，正是最容易踩的）。
- `@StorageProp/@StorageLink`（19+1 处，主题/登录态）在 V2 里的等价物要重新接。
- ArkUI V2 与系统组件/三方库的兼容性，折叠屏 `Bp` 断点逻辑要重测。

**收益**：局部刷新（性能）、单向数据流更清晰、跟上官方方向（V1 已停止演进）。

**风险**：**高**。360 处里任何一处语义改错，表现就是"界面不刷新 / 刷新错位 / 内存泄漏"，而且往往不是编译错，是真机上才看得见。

**回滚**：单开分支，**逐页迁移、逐页真机验**（每页先截图存基线，改后 `mask_shots` 对照）；每页一个 commit，哪个页出问题 `git revert` 那一个 commit，不波及其它页。

**建议**：**暂缓**。等出现真实性能痛点（比如大列表掉帧）或官方 V2 生态更稳再做，别为了"新"去赌一个能跑的版本。

---

## 目标 B：大页面拆分 + 页面骨架去重（低风险、收益实在）

**现状**：7 个 tab 页 692–1287 行，每页各自实现一遍"卡片头 + 键值行 + 空态 + 加载骨架"，jscpd 实测 DevicesPage/ProxyPage 有 31 行级的重复块（这就是当初"卡片头贴边"时三端不一的土壤）。

**要改成**：
- 把重复的**页面骨架**（Hero 顶部卡、CardTitle+SettingRow 组合、空态、加载骨架）抽成公共 `@Component`，落到 `ui/comp/`。
- 大页面按「hero / 操作卡 / 列表卡 / 弹窗」切成子组件或 `@Builder` 分组。

**影响面**：
- 会动到 7 个页面的内部结构，但**不改对外行为**（接口、路由、文案、数据流都不动）。
- 有两个已知 ArkTS 坑必须遵守（已在 `UI_REVIEW.md` 记了）：`@Builder` 按值传参不刷新 → 要状态刷新用 `@Component + @Prop`；`ForEach` 的 key 必须带会变的字段。

**收益**：
- 直接消灭"改一处样式三端/多页不一致"的根源，正好接上刚立的 `UI_REVIEW.md` 空间责任模型。
- 页面行数降下来，以后加功能（比如代理页再加一种节点）不用在 965 行里找位置。

**风险**：**中**。ArkUI 组件化有坑，但都有文档可依，且每页抽完能立刻编译 + 真机截图对照。

**回滚**：逐页抽、逐页 commit、逐页截图对照；出问题 revert 单页 commit。

**建议**：**先做这个**。它是"重构"里唯一投入产出比为正的项，也是把之前 UI 规范落到代码上的自然一步。

---

## 目标 C：状态色 / Token / 语法收口

**已经做完**（本轮）：`delayHex` → `Pal.*`、状态色 Token、`arkts_scan` 0 违规。**无需再动。**

---

## 建议的先后顺序

1. **目标 B**：大页面拆分 + 骨架去重（低风险、高收益、和 UI 规范配套）。
2. **目标 C**：已清零，保持（发版门禁 + CI 会盯）。
3. **目标 A**：V2 迁移，等痛点或生态成熟再做。

## 阶段性结论（2026-11-06 已开工 A）

按「先迁叶子组件」的官方建议，第一批量已落地在 `refactor/arkui-v2` 分支：

**已迁 V2（编译通过，与 V1 页面共存）**：`Comp.ets`（Card/RowCard/GroupBox/
CardTitle/SettingRow/Kv/GlyphIcon/LineIcon/HeroStat/Pill/Note/Chip…15 个共享组件）、
`Ring`、`AppIcon`、`PortTile`、`TrendChart`。

**迁移中确认的两个硬事实**：

1. **V1 父组件可以容纳 V2 子组件**（实测编译通过），所以能自底向上渐进迁，
   不必大爆炸。
2. **`@StorageProp`/`@StorageLink` 是 V1 专属装饰器**，在 `@ComponentV2` 里直接
   编译报错。V2 的等价物是 **`AppStorageV2.connect()` + `@ObservedV2`/`@Trace`**
   —— 要把 `tab`/`winW`/`safeTop`/`forceLogin`/`shellBackTick` 这些跨页 AppStorage
   键值改成 `@ObservedV2` 类。这是**架构级改动**，不是装饰器替换。

**因此**：页面（Index、7 个 tab、Login 等）和 NavBar/SideNav（依赖双向绑定 @Link）
**暂留 V1**，等 AppStorageV2 改造单独立项后再迁。这不是没做完，而是 V1/V2 共存的
官方推荐边界 —— 强行迁页面会把跨页状态机制一起推翻，风险反而变大。

**剩余工作**：把 AppStorage 键值封装成 `@ObservedV2` 状态类 + `AppStorageV2.connect`，
再逐页迁 V2。建议单独一期，配真机全量回归。

## AppStorageV2 改造 + 页面全量迁 V2（2026-11-06 完成）

上一节「剩余工作」已做完，`refactor/arkui-v2` 分支上**页面全部迁到 V2**，编译通过：

**新增 `core/UIState.ets`**：`@ObservedV2 class UIState` 把 `tab`/`winW`/`safeTop`/
`forceLogin`/`subTitle`/`backTick`/`hostname`/`agentVer` 收成 `@Trace` 字段，
`export const UI = AppStorageV2.connect(UIState, 'iStoreUI', ...)!` 拿全局单例。

**写入方**：`Index`（tab/winW/safeTop/hostname/agentVer）、`Shell`（subTitle/backTick）、
`EntryAbility`（forceLogin）—— 全部从 `AppStorage.setOrCreate` 改成 `UI.xxx = ...`。

**读方**（各页面的标准接法，也是官方的 `@StorageProp` 迁移姿势）：
```typescript
@Local ui: UIState = UI;
@Local tab: number = UI.tab;          // @StorageProp('tab') 的替代
@Monitor('ui.tab') onTab() {          // @Watch('onTab') 的替代
  this.tab = this.ui.tab;             // 先同步本地副本，再跑原逻辑
  ...
}
```

**双向绑定**：NavBar/SideNav 的 `@Link current` 改成 `@Param current` + `@Event onChange`，
Index 在 `onChange` 里 `this.current = i; UI.tab = i`（两条路径——点导航、滑 Tabs——都汇
到 `UI.tab`，`@Trace` 严格相等去重，重复写无害）。

**边界（刻意保留 V1）**：`LoginPage`/`WebPage`/`DeviceDetailPage`/`SubscriptionPage`/
`NetSettingsPage` 五个路由页仍是 `@Entry @Component + @State`。它们不参与跨页状态，
`safeTop` 改成一次性读 `UI.safeTop`（静态值），没有迁 V2 的必要——强行迁只会增加回归面。

**尚未做**：真机回归（USB 掉线，编译通过但运行时未验）。重点看：切页签时轮询启停、
二级页返回、折叠屏宽度联动、canvas 组件（Ring/TrendChart）的 `@Monitor` 重绘。

## 回滚总原则（通用）

- 一切重构在**独立分支**上做，主线保持可发版状态。
- **逐页 commit + 逐页真机截图对照**，不做"大爆炸式"一次性替换。
- 每个 commit 过 `lint_style + dead_code + arkts_scan + hvigor` 四道关。
- 任何一页异常，`git revert` 单页 commit，不回滚整体。

---

## 一句话结论

**值得做的重构只有「大页面拆分 + 骨架去重」，V2 状态管理迁移建议暂缓。**
