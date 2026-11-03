# 代码规范审查报告

审查日期：2026-11-03　　范围：全仓库　　规范依据：[`CODE_STYLE.md`](CODE_STYLE.md)

## 一、怎么审的

| 手段 | 覆盖 | 说明 |
|---|---|---|
| `ruff`（Python） | `agent/` `scripts/` `deploy/`，67 个文件 / 18 610 行 | 规则集含 pycodestyle、pyflakes、bugbear 常用子集 |
| `scripts/lint_style.py`（本次新增） | 全仓库 208 个文件 | 跨语言机械规则：换行符、缩进、行宽、尾随空格、死代码标记、语言特有低级错误 |
| 编译验证 | Android / 鸿蒙 / iOS | 改完必须编过，见第四节 |
| 人工复核 | 上述工具报出的每一条 | 剔除误报，判断"是 bug 还是风格" |

工具本身也做了降噪：初版报 501 个 error，其中 461 条是
`deploy/build_run.py` 里那段 shell 安装器模板（raw string 里的 tab 不是缩进），
34 条是 ArkTS 里必须用双引号的 `fontFeature("\"tnum\" on")`。
降噪后 **0 error / 0 warning**。

## 二、修掉的真问题

### 1. 会导致运行期出错的（3 处）

| 位置 | 问题 | 修法 |
|---|---|---|
| `agent/devices.py:280` | 端口字典里 `3478` 写了两次（`STUN` 与 `PSN`），后者静默覆盖前者 | 合并为 `3478: "STUN / PSN"`，删掉重复项 |
| `scripts/make_icons.py:186` | 引用了不存在的 `MOBILE` 常量，跑到 iOS 图标那段必然 `NameError` | 改为 `ROOT`，并同时写 `ios/Assets` 与 `Assets.xcassets` 两份 |
| `agent/zte.py:207` | `kicked` 变量声明了、`_refresh` 也在读 `extra["kicked"]`，但抢占会话后**从没赋值** —— "抢了谁的登录"这个提示永远不会出现 | 抢占前记下 `holder["ip"]`，随返回值带回 |

### 2. 白跑开销 / 死代码（4 处）

| 位置 | 问题 |
|---|---|
| `agent/adblock.py:1272` | `_dns_chain()` 的结果没人用，但每次 preflight 会多跑 `uci show dhcp` + `nft list table inet fw4` 两条命令（超时 6s / 8s） |
| `agent/netcfg.py:92` | 调了一次 `ubus call network.interface`（timeout 5s）然后完全没用，紧接着又自己拼 `raw = {}` |
| `agent/devices.py:569` | `reason = ""` 初始化后从未使用（末尾 return 用的是字面量） |
| `agent/zte.py` | 同上（`kicked` 已按第 1 节改为真正使用） |

### 3. 异常被吞（3 处）

`AdblockFragment:1003`、`OverviewFragment:324`、`Hz.java:65` 有空 `catch` 块。
这些异常确实可以忽略（`JSONObject.put` 的非空 key/value、老系统没有
`setFontFeatureSettings`、系统拒绝改窗口属性），但**空块本身是危险的**——
下次有人往里加代码时不会意识到异常被吃了。按项目已有惯例补上说明注释：

```java
} catch (Throwable ignored) {
    // 老系统没有这个 API，退回默认字距，数字宽度不齐但不影响读数
}
```

### 4. 可读性（6 处）

- `DeviceDetailActivity:320`、`DevicesFragment:450`：一行四层嵌套三元
  （`!a.isEmpty() ? a : (!b.isEmpty() ? b : ...)`）→ 抽成 `pickName(String...)`，
  循环取第一个非空值。
- `clash.py:133/156`：两处相同的一长串 `(x.get("history") or [{}])[-1].get("delay")`
  → 抽成 `_last_delay()`，并补上"空数组返回 None 而不是 0"的语义说明
  （0 在 Clash 里表示"测过但超时"，两者不能混）。
- `BaseFragment:110`：两条语句挤在一行 + 一个奇怪的行首强转 → 拆行。

## 三、规范化的批量改动

### 换行符：34 个文件、15 094 行 CRLF → LF

仓库 `.gitattributes` 写的是 `* text=auto eol=lf`，但工作区里有 34 个文件是 CRLF。
**根因**：改动这些文件的脚本用 `Path.write_text()`，而它在 Windows 上会把 `\n`
写成 `\r\n`。本次已全部转回 LF，并给 `scripts/lint_style.py` 加了 `EOL` 规则防复发
（所有脚本内部写文件一律 `write_bytes` + 显式 `newline="\n"`）。

影响面：`.ets` / `.swift` / `.java` 在 mac 上构建时对 CRLF 容忍度不一，
`docs/*.md` 的 diff 也会一直显示全文件变更。这次一次性清掉。

### 行宽

Python / Java / Swift 由 100 调到 **110**，Shell 由 100 调到 **120**。
理由写进了规范：中文注释按字符数算，100 列只剩 50 个汉字；shell 里
`uci get xxx && curl ...` 这种一行一条命令断成多行反而更难读。

调完仍有 32 条超限，逐条处理：

- 能断的断（Java 的 `Ui.text(...)` 参数、Swift 的 `observe(...)` 闭包、ArkTS 的 `StatCell({...})`）
- 断开会改变内容的加 `style-ok` 豁免（SVG path、长字符串插值、`export PATH=...`）
- 新增"数据行"判定：行内最长字符串字面量 > 120 字符时不做行宽检查
  （`Icons.ets` 里 583 字符的 SVG path 属于数据，不是风格问题）

## 四、编译验证

改完三端都重新编译过，不是只看语法：

| 端 | 命令 | 结果 |
|---|---|---|
| Android | `gradle :app:assembleDebug` | **BUILD SUCCESSFUL** |
| 鸿蒙 | `hvigorw assembleHap`（Mac） | **BUILD SUCCESSFUL** |
| iOS | `xcodebuild -sdk iphonesimulator`（Mac） | **BUILD SUCCEEDED** |

### 中途踩到的一个坑

`BaseFragment` 里那个 `(NestedScrollView.OnScrollChangeListener)` 强转，
我一度以为是代码异味想删掉，结果编译失败：`NestedScrollView` 和它父类 `View`
各有一个 `setOnScrollChangeListener` 重载，lambda 推断不出该匹配哪个。
**强转是必需的**，已恢复并补注释说明原因——这类"看起来多余、实际不能删"的代码
应该在注释里写清楚，否则下一个人还会去删。

## 五、决定不改的

| 位置 | 现象 | 理由 |
|---|---|---|
| `agent/*.py` 多处 | `except Exception` 宽泛捕获（57 处） | HTTP 入口兜底：宁可返回 `{"ok": false}` 也不能让服务崩，但都会记日志 |
| `agent/*.py` 大量 | `%` 字符串格式化（87 处） | 历史代码，全量改 f-string 改动面过大、收益低；新代码用 f-string |
| `agent/devices.py` | 单文件 1 600+ 行 | 设备/流量/厂商/接入方式强耦合，拆分风险高于收益 |
| `scripts/*.py` | 无类型注解 | 一次性运维脚本 |
| `harmony/**/*.ets` | `@Builder` 参数较多 | ArkUI 的限制（按值传参不刷新），不是风格问题 |
| `docs/*.md` | 部分文档无代码块语言标注 | 纯说明性文档，不影响渲染 |

## 六、怎么复查

```bash
# 风格（本次新增，0 error / 0 warn 才算过）
python scripts/lint_style.py

# Python 语义类
python -m ruff check agent deploy scripts --select F,E722

# 只想看 Python
python scripts/lint_style.py --lang py

# CI 用：warning 也算失败
python scripts/lint_style.py --strict
```
