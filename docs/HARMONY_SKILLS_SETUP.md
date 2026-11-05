# 鸿蒙开发知识包：核实结果与落地方式

> 针对 2026-11-06 微信文章《鸿蒙开发的 AI Skill 全景》里推荐的两个社区知识包，
> 克隆核实后的落地说明。目标不是整仓搬进本项目，而是"装哪个、怎么用、我们取走了什么"。

## 一、linhay/harmony-next.skills —— 离线 API 检索（★366）

**它是什么**：HarmonyOS NEXT 的离线参考库，`references/` 打包了 **API 12–23** 的
完整声明文件 + 指南（API 26 声明已含，完整指南待补）。作用：AI 查 API 签名不联网、
不被旧文档误导；也覆盖 DevEco 自动化、hdc/uitest/aa/bm/hilog 诊断、ArkUI Inspector 等。

**核实结论**：
- 内容真实、维护活跃（v1.3.37），与我们 API 20 完全对得上。
- 它是**检索型** skill（渐进式披露：先路由 → `rg INDEX.md` → 只打开 1–3 个 .md），
  不是"一次塞进上下文"的知识包，不会撑爆 context。
- 它体积大（4389 个文件），**不适合提交进我们仓库**——属于工具链，装到 agent 环境里。

**装法（Codex 为例，Claude Code 同理换 `-a claude-code`）**：

```bash
npx skills add linhay/harmony-next.skills --skill harmony-next -a codex -g -y --copy
```

**用法（写鸿蒙代码时）**：

```bash
# 定位某个 API/Kit 的文档文件
rg -n "(@ohos\\.app\\.ability\\.|UIAbility|Want)" INDEX.md | rg "JsEtsAPIReference/" | head
```

### Kit 导入键速查（本项目会用到的一部分）

| 场景 | 关键词 | 模块前缀 |
|---|---|---|
| 应用/能力/上下文 | `UIAbility` `AbilityStage` `Context` `Want` | `@ohos.app.ability.` `@ohos.ability.` |
| 声明式 UI | `@Entry` `@Component` `build()` `UIContext` `LazyForEach` | `@ohos.arkui.` |
| 语言/并发/容器 | `TaskPool` `Worker` `sendable` `collections` | `@kit.ArkTS` |
| 数据/偏好 | `rdb` `Preferences` `distributed` | `@ohos.data.` |
| 网络 | `http` `socket` `wifi` | `@ohos.net.` `@ohos.wifi.` |
| 权限/密钥 | `abilityAccessCtrl` `huks` `UserAuthentication` | `@ohos.abilityAccessCtrl` `@ohos.security.` |

（完整 Kit 名单见原仓库 `references/KITS.md`。）

## 二、JohnnnyTang/harmonyos-dev-skills —— 生命周期全链路

**它是什么**：官方文档 21322 页快照蒸馏，每个结论标注出处。覆盖 ArkTS 编译报错
（`arkts-no-*` 规则带错误码 + 惯用改写）、hvigorw 构建/CI、Hypium 测试、AppGallery
签名上架、分阶段发布、APMS/AppFreeze 运维。作者评测：带 skill 26/26 全对，不带只对 20。

**核实结论**：`references/arkts-language.md` 是其中最有价值的一份——**正是"AI 易犯
ArkTS 语法错误"的完整清单**（规则 id + 错误码 + 禁止写法 → 惯用改写 + 并发 + 导入规则）。

**我们取走了什么**：把这份清单按本项目（API 20、Stage 模型、现网 V1 状态管理）改写成了
`docs/ARKTS_PITFALLS.md`，作为写 `.ets` 前自查 + 编译报错时查改写的本地真源。原仓库本身
不装（它是 Claude Code 插件格式，我们走"借鉴、不安装"路线）。

## 三、落地的文档关系

```
docs/ARKTS_PITFALLS.md        编译期坑清单（← JohnnnyTang arkts-language.md 改写）
docs/UI_REVIEW.md §四 鸿蒙专项   UI/交互层坑 + 指向 ARKTS_PITFALLS
docs/wechat-article-...md      文章解读（§四已标注"已核实并落地"）
本文件                          两个知识包的装法/用法/取走了什么
```

## 四、一句话建议

- **日常写 ArkTS**：打开 `docs/ARKTS_PITFALLS.md` 自检，报错按 rule-id 查改写。
- **查 API 签名**：装 `linhay/harmony-next.skills` 用 `rg` 检索（不联网、版本准确）。
- **不要**把两个知识包全量塞进我们仓库，也不要把 linhay 的 4389 个文件提交进来。
