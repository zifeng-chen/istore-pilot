# 文章解读报告：鸿蒙开发的 AI Skill 全景

> 来源：《鸿蒙开发的 AI Skill 全景：让 Claude Code 和 Codex 真正会写 ArkTS》
> 公众号「坚强粑粑」，原创，2026-10-24 07:19，山东。
> 原文：https://mp.weixin.qq.com/s/YP089aVyxhmdRny0-F95YQ
> 解读时间：2026-11-06

---

## 一、一句话结论

**文章的核心命题**：大模型训练数据里几乎没有 ArkTS / Stage 模型 / HarmonyOS Kit，
所以 AI 写鸿蒙代码"看着眼熟、编译跑不通"——把 ArkTS 当 TypeScript（用 `any`、
解构、`for..in`），状态管理退回 ArkUI V1 的 `@State`，路由用已淘汰的 `@ohos.router`，
改 `module.json5` 当成 `package.json`。**解法是给 agent 挂鸿蒙专属 Skill**（SKILL.md
是开放标准，Claude Code / Codex / Cursor / Gemini CLI 都认），让 AI 按约束生成可编译的 ArkTS。

## 二、可用 Skill 全景（文章盘点）

### 1. 官方：格物平台 39 个 `hmos-*` skill

华为 Matrix 格物平台（matrix.openharmony.cn，带安全扫描 + 预审核）分六组：

| 组 | 代表 skill | 用途 |
|---|---|---|
| ArkTS/ArkUI 开发 | `hmos-arkui-develop-skill`、`hmos-arkts-syntax-checker`、`hmos-arkts-deprecated-interface-checker` | 生成可编译 .ets、语法检查+自动修复、废弃接口扫描 |
| 状态管理 | `hmos-arkui-statemgt-migration`、`hmos-arkui-mvvm-pattern` | V1→V2 迁移、MVVM |
| 元服务/ASCF | `hmos-atomicservice-assistant`、`hmos-ascf-assistant` 等 | 免安装元服务构建 |
| 多设备适配 | `hmos-multidevice-*` | 折叠屏、窗口尺寸、避让区、横竖屏 |
| Kit 集成 | `hmos-push-kit-*`、`hmos-live-view-kit-*`、Scan/Account Kit | 推送、实况窗等 |
| DFX 运维 | `hmos-jsleak-analysis`、`hmos-apifault-analysis` | 泄漏/崩溃/卡顿排查 |

安装：`npx skills add https://matrix.openharmony.cn/api/registry/skills/<name>`。

### 2. 官方工具链：DevEcoCli

把 DevEco Studio 的工具链（ohpm / hvigor / hdc / emulator / hilog）封成 CLI，让 agent
能自己 create/build/run/log——这是纯知识型 skill 做不到的。内置 4 个 skill + ArkTS 语法
检查 MCP。安装：`npm i -g @deveco/deveco-cli`，然后 `devecocli init --agent claude-code,codex`。

### 3. 社区精品（GitHub）

| 仓库 | star | 定位 |
|---|---|---|
| linhay/harmony-next.skills | ★366 | 离线 API 12–26 完整声明文件，查签名不联网 |
| majiayu000/spellbook | ★288 | 109 个 skill 的跨 runtime 库，harmonyos-app 用"Hard Rules"写法 |
| DengShiyingA/harmonyos-ai-skill | ★284 | 4461 行知识包，一份源文件产出 11+ 工具配置 |
| JohnnnyTang/harmonyos-dev-skills | 新 | 官方文档 21322 页快照提炼，覆盖构建/CI/测试/签名上架/运维，带出处 |
| everything-claude-code (ECC) | ★286k | 鸿蒙专属 agent + 5 份规则 + CLAUDE.md 模板（华为开发者贡献） |
| baidu-maps/harmony-sdk-skills | — | 百度地图 SDK 集成专用 |

安装位置：Claude Code 放 `~/.claude/skills/`；Codex 放 `~/.agents/skills/`；通用 `npx skills add <repo> --skill <name> -a claude-code|codex`。

### 4. 推荐组合（原文三套）

- **元服务**：官方 `hmos-atomicservice` + `hmos-ascf` 打底 + `hmos-arkts-syntax-checker` 兜语法 + 社区知识包补 API。
- **原生应用**：`linhay/harmony-next.skills` 打底 → 语法/废弃接口双检查 → 测试/签名/上架阶段挂 `JohnnnyTang`。
- **Claude Code 重度用户**：ECC 鸿蒙套件 + DengShiyingA 知识包 + deveco-mcp 语法检查。

### 5. 注意事项（原文）

- 官方 skill 认 API 版本，老项目（API 12）用 linhay 离线声明做版本锚定。
- 知识包有体积（4461 行），全量注入挤上下文，优先 skill 格式按需加载。
- 构建验证依赖本地 DevEco + DEVECO_SDK_HOME。
- **别混装同职责 skill**，两套 ArkTS 语法规则会打架，留一套最强的。

---

## 三、和我们项目的对照（关键）

我们就是文章说的"原生鸿蒙应用"那一类，而且**文章列的错误我们几乎全踩过**：

| 文章说的坑 | 我们项目里的真实对应 |
|---|---|
| AI 把 ArkTS 当 TypeScript，用 `any`/解构/`for..in` | 我们靠 `scripts/dead_code.py` + 手写约束在防，但没有成体系的语法规则 |
| 状态管理退回 V1 `@State` | 现网就是 V1（`@State`/`@Prop`/`@Watch`），V2 迁移是以后的事 |
| 路由用已淘汰的 `@ohos.router` | 我们用的是 `router.pushUrl`（在 `main_pages.json` 登记的页面），好在不是 `@ohos.router` 那种 |
| `@Watch('名字')` 字符串引用、`@Builder` 按值传参、`Toggle` 程序化回调 | 这些**没一个在通用模型知识里**，是我们这两天一个个踩出来、写进 `docs/UI_REVIEW.md` 的 |

结论：**文章的方向和我们这几天做的事完全同频**——我们已经在自己沉淀"项目级 skill"（`CODE_STYLE.md` + `UI_REVIEW.md` + 一堆检查脚本），文章补上的是"别人已经做好的通用鸿蒙知识层"。

## 四、我的判断与建议

**值得借鉴，但不要急着全装。** 分三层：

1. **直接对当前开发最有用的一个**：`hmos-arkts-syntax-checker`（官方，语法检查 + 自动修复）。
   我们在 Mac 上要 `hvigorw` 编一次才知道语法对不对，周期太长；挂上它，agent 写完
   立刻自检，能少很多"编译失败→重来"的往返。
2. **值得纳入我们文档的两个知识包**（取其"坑清单"，不整仓装）：`linhay/harmony-next.skills`
   的离线 API 声明（避免 agent 凭空编 API 名）、`JohnnnyTang/harmonyos-dev-skills` 的
   `arkts-no-*` 报错规则（带错误码 + 惯用改写，正好补我们 `UI_REVIEW.md` 没覆盖的编译期坑）。
3. **暂不碰**：ECC 整套、spellbook、DevEcoCli——它们面向"从零生成项目/CI 全托管"，
   我们这个成型项目用不上，还容易和现有脚本打架（违背原文"别混装同职责 skill"）。

**下一步可选动作**（等你定）：
- 我去核实 `hmos-arkts-syntax-checker` 和 `linhay/harmony-next.skills` 的实际内容，
  把对得上我们 API 版本（现网 API 12 兼容 SDK 20）的部分翻译进 `docs/`；
- 或者先把文章里"AI 易犯的 ArkTS 语法错误清单"整理进 `docs/UI_REVIEW.md` 的鸿蒙专项，
  作为我们自己 skill 的一部分——这最贴合你之前定的"只借鉴、不安装"路线。

---

## 附：原文来源链接（备查）

- 格物平台 Skill 广场：https://matrix.openharmony.cn/#/skillSquare
- linhay/harmony-next.skills：https://github.com/linhay/harmony-next.skills
- DengShiyingA/harmonyos-ai-skill：https://github.com/DengShiyingA/harmonyos-ai-skill
- JohnnnyTang/harmonyos-dev-skills：https://github.com/JohnnnyTang/harmonyos-dev-skills
- majiayu000/spellbook：https://github.com/majiayu000/spellbook
- everything-claude-code：https://github.com/affaan-m/everything-claude-code
- baidu-maps/harmony-sdk-skills：https://github.com/baidu-maps/harmony-sdk-skills
- 官方 hmos-* 全量名录（DSH 移植）：https://github.com/weikangzeng07-ops/dsh-hmos-skills
