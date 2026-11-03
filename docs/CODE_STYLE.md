# 代码规范基线

本文件只做一件事：**说清每种语言按哪份规范检查，以及本项目对它的取舍**。
评审时以这里的条目为准，不再凭个人习惯争论。

> 规范不是装饰。下面每一条"例外"都写了原因，改之前先看原因还成不成立。

## 一、各语言采用的规范

| 语言 | 目录 | 采用的规范 | 版本/来源 |
|---|---|---|---|
| Python | `agent/` `scripts/` `deploy/` | [PEP 8](https://peps.python.org/pep-0008/) + [Google Python Style Guide](https://google.github.io/styleguide/pyguide.html) | PEP 8 现行版 |
| Java | `android/` | [Google Java Style Guide](https://google.github.io/styleguide/javaguide.html) + Android 官方 lint | — |
| Swift | `ios/` | [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/) + [Google Swift Style Guide](https://google.github.io/swift/) | — |
| ArkTS | `harmony/` | [ArkTS 编程规范（华为官方）](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/arkts-coding-style-guide) | HarmonyOS NEXT |
| Shell | `scripts/*.sh`、`.run` 安装器 | [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html) + [ShellCheck](https://www.shellcheck.net/) | — |
| Markdown | `docs/` `*.md` | 一二级标题用 `##`、代码块标语言、表格对齐 | — |

## 二、共通硬规则（所有语言）

这几条不分语言，违反即改：

1. **源文件必须是 UTF-8 + LF**。仓库有 `.gitattributes`，但新增文件仍要自己确认——
   CRLF 进到 `.run` 的 shell 头里会让 busybox 报 `not found`。
2. **文件末尾留一个空行**，不留多余空行。
3. **行尾不留空格**；缩进不许混用 tab 与空格。
4. **不提交注释掉的死代码**。要留历史用 git，不要留在文件里。
5. **不提交密钥、口令、真实 IP、订阅地址**。这类值一律走环境变量或 `config.json`；
   文档里写占位符（`<路由器IP>`）。
6. **函数只做一件事**。超过 80 行的函数要么拆，要么在注释里说明为什么必须一起。
7. **错误必须带上下文**。抛错/返回 error 时说清"哪一步、什么值、期望什么"，
   不允许只写 `"失败"`。

## 三、各行语言细则

### Python（`agent/` `scripts/` `deploy/`）

- 4 空格缩进，行宽 **100**（PEP 8 的 79 对现代屏幕太窄，Google 用 80，本项目取 100）。
- 命名：模块 `snake_case`、函数/变量 `snake_case`、类 `UpperCamelCase`、
  常量 `UPPER_SNAKE_CASE`。
- 导入：标准库 → 第三方（本项目为零）→ 本包，组间空一行；禁止 `import *`。
- 类型注解：**公开函数必须有**；内部小工具可省。
- 异常：捕获后必须处理或记录，不允许 `except: pass`。
  **例外**：Agent 的每个 HTTP 处理入口允许 `except Exception` 兜底——
  这是有意为之，宁可返回 `{"ok": false, "error": ...}` 也不能让服务 500/崩，
  但必须把异常写进日志。
- 字符串格式化：本项目统一 `%` 与 f-string 混用是历史包袱，
  **新代码用 f-string**，老代码不强制重写（改动面太大，收益低）。

### Java（`android/`）

- 4 空格缩进，行宽 **100**。
- 命名：包 `com.chaof.istoreos.*` 全小写、类 `UpperCamelCase`、方法/字段 `lowerCamelCase`、
  常量 `UPPER_SNAKE_CASE`。
- 一个文件一个 public 类；文件名与类名一致。
- 成员变量 `private`，需要暴露用方法。
- `catch` 不允许空块；至少 `Log.w`。
- **本项目特有的 UI 约定**：没有 Layout XML，界面全部代码构建，
  所以 `Ui.java` / `Glyph.java` 这类工具类里的"魔法数字"（dp、字号）集中定义，
  散落在各 Fragment 里的 dp 值必须有语义（间距、圆角、图标尺寸）。
- **看起来多余、实际不能删的强转必须在注释里说明**。例：
  `setOnScrollChangeListener((NestedScrollView.OnScrollChangeListener) (v, ...) -> ...)`
  —— `NestedScrollView` 与父类 `View` 各有一个同名重载，没有强转时 lambda
  推断不出目标类型，编译直接失败。删之前先编译。

### Swift（`ios/`）

- 2 空格缩进，行宽 **100**（Google Swift Style）。
- 命名：类型 `UpperCamelCase`、方法/属性 `lowerCamelCase`、常量同 lowerCamelCase。
- 能用 `let` 不用 `var`；能省 `self` 就省（闭包里必须时除外）。
- 强制解包 `!` 只允许用在"初始化时已确保非空"的 IBOutlet 类场景；
  本项目无 storyboard，**基本应为零**，用 `guard let` / `??`。
- 闭包参数超过 3 个或逻辑超过 10 行，抽成命名函数。
- SwiftUI：`body` 里不做网络/磁盘 IO，副作用走 `.task` / `.onAppear`。

### ArkTS（`harmony/`）

严格按华为官方《ArkTS 编程规范》，逐条对照：

| 规则 | 级别 | 检查方式 |
|---|---|---|
| 类/枚举/命名空间 UpperCamelCase | 推荐 | 正则 |
| 变量/方法/参数 lowerCamelCase | 推荐 | 正则 |
| 常量/枚举值 UPPER_SNAKE_CASE | 推荐 | 正则 |
| 空格缩进，禁 tab | **规则** | 扫描 |
| 行宽 ≤ 120 | 推荐 | 扫描 |
| 条件/循环必须带大括号 | 推荐 | 扫描 |
| `switch` 的 case 缩进一层 | 推荐 | 扫描 |
| 字符串用单引号 | 推荐 | 扫描 |
| 对象字面量 > 4 属性换行 | 推荐 | 人工 |
| `else`/`catch` 与 `}` 同行 | 推荐 | 扫描 |
| `{` 与语句同行 | 推荐 | 扫描 |
| 类属性加可访问修饰符 | 推荐 | 人工 |
| 浮点数不省略 0（写 `0.5` 不是 `.5`） | 推荐 | 正则 |
| 用 `Number.isNaN()` 判 NaN | 推荐 | 正则 |
| 不在条件表达式里赋值 | **规则** | 人工复核 |
| `finally` 里不 `return`/`break`/`continue`/`throw` | **规则** | 人工复核 |
| 不用 `ESObject` | **规则** | 正则 |
| 用 `T[]` 而非 `Array<T>` | 推荐 | 正则 |

**本项目补充**（踩过坑，写进规范）：

- `@Builder` 按值传参不会刷新 UI——需要响应状态变化时必须用 `@Component + @Prop`。
- `ForEach` 的自定义 key 必须包含会变化的字段，否则节点复用、内容不更新。
- 自定义组件后面不能直接链 `.margin()` 等属性方法，要套一层容器。
- 图标一律走 `LineIcon` / `GlyphIcon`（Canvas 重放路径），
  **不要用 `Path` 组件**（实测只画出第一个 `M` 点）。
- `J.bool` 必须带默认值；页面必须登记到 `main_pages.json`；
  `if` 块不能插在组件闭括号与它的 `.width()` 之间。

### Shell（`scripts/*.sh`、`.run` 安装器）

- `#!/bin/sh` 只在确认真的是 POSIX sh 时用；需要 bash 特性就写 `#!/bin/bash`。
- 变量引用一律加引号：`"$var"`；不引用的地方要写明为什么（如 `for x in $list`）。
- `[ ]` 用于 POSIX，`[[ ]]` 只在 bash 脚本里用。
- 命令失败要处理：`|| die "..."` 或 `set -e`，不允许静默继续。
- 临时文件用 `$$` 或 `mktemp`，并在 `trap ... EXIT` 里清理。
- **`.run` 安装器额外要求**：不能假设 `opkg` 存在（25.12 起是 apk）、
  不能假设 `python3` 已装、所有写系统的操作必须先 `verify_payload`。

## 四、评审怎么跑

```bash
# Python：静态检查（配置见 ruff.toml）
python -m ruff check agent deploy scripts

# 全语言：行宽 / 缩进 / 尾随空格 / 死代码标记 / 敏感信息
python scripts/lint_style.py

# 全语言：声明了但没人调的函数/方法（候选清单，需人工确认）
python scripts/dead_code.py

# 重复代码率（jscpd，阈值 8 行 / 60 token）
npx --yes jscpd@4 . --format python,java,swift --min-lines 8 --min-tokens 60 \
  --ignore "**/build/**,**/dist/**,**/.git/**,**/node_modules/**,**/.workbuddy/**"

# 鸿蒙的 .ets 要单独跑一次：--formats-exts 会顶掉 --format 列表
npx --yes jscpd@4 . --format typescript --formats-exts typescript:ets \
  --min-lines 8 --min-tokens 60 --ignore "**/build/**,**/.git/**"

# Android 编译期 lint
cd android && ./gradlew :app:lintDebug
```

重复率基线（2026-11-03）：总体 **1.21%**，Python 0.12% / Java 2.30% /
Swift 0.71% / ArkTS 2.45% / Shell 0%。剩下的是页面骨架（工具栏 + 滚动容器 +
`setContentView`、ArkUI 的分组卡片），**故意不合并**：每个屏的头部、内边距、
空态都不同，抽成一个六参数 helper 比重复本身更难读。逻辑重复（uci 读写、
命令执行、HTTP 错误归一）已经收干净了。

前三条必须零 error 才算过；warning 分类见报告。

### 死代码怎么判

`dead_code.py` 输出的是**候选**，不是判决书。三类合法的"看起来没人调"已经
在脚本里排除，改规则时别删：

| 形态 | 例子 | 为什么算活的 |
|---|---|---|
| 字符串引用 | ArkTS `@Watch('onSubChanged')` | 回调名是字符串，运行时才绑 |
| 框架回调 | `@Override`/`override`、`onCreate`、`makeUIView` | 调用点在系统里 |
| init 钩子 | `start_service`、`service_triggers` | 由 `/etc/rc.common` 调 |

Python 侧交给 `vulture`（`pip install vulture`，未装则跳过）；协议钩子
（`do_GET`、`log_message`、`server_version`）用行尾 `# noqa: 原因` 标注。

**设计令牌是例外**：`res/values/colors.xml`、`harmony/.../color.json` 这类
颜色/尺寸表即使暂时没人用也保留 —— 它们是配色方案的唯一真源，删了以后
下一屏要用就得凭记忆重编一个色值。函数和样式（`styles.xml` 的 `<style>`）
不留，没人用就删。

## 五、已知的、决定不改的地方

规范的价值在于"知道为什么例外"，不是"全部整齐"。下面这些评审会报但**不改**：

| 位置 | 现象 | 为什么不改 |
|---|---|---|
| `agent/*.py` 多处 | `except Exception` 宽泛捕获 | HTTP 入口兜底，宁可返回错误 JSON 也不能崩服务 |
| `agent/*.py` 大量 | `%` 字符串格式化 | 历史代码，全量改 f-string 收益低于风险 |
| `agent/devices.py` | 单文件 1600+ 行 | 设备/流量/厂商/接入方式强耦合，拆分成本高于收益，按函数边界阅读 |
| `scripts/*.py` | 无类型注解 | 一次性运维脚本，跑完即弃 |
| `harmony/**/*.ets` | `@Builder` 参数较多 | ArkUI 的限制，不是风格问题 |
