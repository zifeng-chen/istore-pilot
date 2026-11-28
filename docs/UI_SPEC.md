# 三端 UI 规格（唯一事实源）

改这三份实现之前先看这里，改完用 `python scripts/ui_spec_check.py` 校验。

| 项 | 值 | 鸿蒙 `ui/Theme.ets` | Android `util/Ui.java` | iOS `UI/Theme.swift` |
|---|---|---|---|---|
| 页面大标题 | 33 | `F_TITLE` | `largeTitle` 33 | —（用 22） |
| hero 大数字 | 28 | `F_HERO` | 26 | `hero` 33 |
| 卡片标题 | 16 | `F_H2` | 16 | `cardTitle` 16 |
| 正文 | 15 | `F_BODY` | 15 | `body` 15 |
| 次要 | 13 | `F_SUB` | 13 | `caption` 12.5 |
| 最小 | 11.5 | `F_TINY` | 11.5 | `tiny` 11.5 |

## 已知差异（有意保留）

- **页面大标题**：iOS 用 22（NavigationBar inline 的观感），鸿蒙/Android 用 33（自绘头部）
- **hero 大数字**：三端各自贴近自己的卡片比例，不强行统一

除上面两项，其余必须一致。`ui_spec_check.py` 只校验「正文 / 卡片标题 / 最小」这三档，
它们最容易在新增页面时被写错。

## 硬规则

1. **字号必须走常量**，不许在页面里写 `fontSize(15)` 这种字面量
2. 鸿蒙一律 `T.fs(T.F_XXX)`（带 1.2 倍封顶），不要直接用 `T.F_XXX`
3. 数值类文字要用等宽数字（鸿蒙 `fontFeature(FontFeature.tnum)`、Android `Ui.num`、iOS `monospacedDigit`）
4. 需要随状态刷新的数值**不要包成带参 `@Builder`**（ArkUI 按值传参不刷新），用内联节点
