# 图标库落地说明（iStore Pilot SVG Icon Library v1.2.0）

> 设计源：`design/icons/`（77 个 SVG + sprite + manifest + 预览页）
> 生成脚本：`scripts/gen_icons.py`（一条命令产出三端数据）

## 一、结论：能用，而且三端共用同一份 path

| 规格 | 图标库 | 三端原实现 | 结果 |
|---|---|---|---|
| 画布 | 24×24 | Android 24 格 / iOS SF Symbols / 鸿蒙 24 格 | 统一到 24 格 |
| 描边 | 2px，圆头 / 圆角连接 | Android `stroke=2` + ROUND | 一致 |
| 填充 | 默认 none，少量小圆点 | 同 | 一致 |
| 颜色 | `currentColor` | 逐处传主题色 / 危险色 / 白色 | 一致 |

所以是**把手绘和系统符号换成设计稿**，不是换风格：线宽、端点、留白都不变。

## 二、三端怎么接的

**统一前提**：生成阶段把 SVG 的 `H/V/S/Q/T/A`、相对指令、圆弧全部转成
**绝对坐标的 M/L/C/Z**。三端各自只留一个几十行的解析器，不必各写一套 SVG 语法。

| 端 | 数据 | 渲染 | 页签 |
|---|---|---|---|
| Android | `widget/IconData.java` | `Glyph` + `androidx PathParser`，解析一次静态缓存 | `res/drawable/ic_nav_*.xml`（VectorDrawable） |
| 鸿蒙 | `ui/comp/IconData.ets` | `GlyphIcon` + `IconPath.replay`（Canvas） | `NavBar`/`SideNav` 直接用 `IconData.stroke()` |
| iOS | `UI/IconData.swift` | `LineIcon`（`Canvas` + 自写解析器，带缓存） | 底部标签沿用系统 TabView，图标走 `LineIcon` |

改图流程：换 `design/icons/icons/**/*.svg` → `python scripts/gen_icons.py` → 三端重新编译。
`python scripts/gen_icons.py --check` 可在发版前校验产物是否与设计源同步。

> Android 的 `Glyph` 保持 `setKind()/setColor()` 不变；鸿蒙 `Glyph` 的常量名 =
> 文件名（kebab-case → UPPER_SNAKE），旧名保留为别名；iOS 的 `CardHead` /
> `iconTile` / `EmptyHint` 等槽位接受同一套 key。

## 三、v1.2.0 带来的变化

- 新增 `system-settings`（三横线 + 三个旋钮）→ 底部「设置」页签不再借用网络拓扑图
- 重画 12 个：`broadband`（改为地球 + 插头，不再像 Wi-Fi）、`network-settings`
  （改为网络拓扑）、`ipv4`/`ipv6`（数字字形）、`rules-refresh`、`restart-network`、
  `restart-router`、`shutdown`、`system-update`、`package-update`、`status-offline`
- 三端同步升级，调用点按语义重挂（见下）

## 四、调用点映射（三端一致）

| 位置 | 旧图标 | 新图标 |
|---|---|---|
| 系统负载 | CHIP / cpu / cpu | `system-load` |
| 宽带连接 | GLOBE / globe / globe | `broadband` |
| 网络设置 / 接入方式 | LINK / globe | `network-settings` |
| 网口 | BOX / cable.connector / BOX | `ethernet-port` |
| 设备卡 | LINK / link / LINK | `devices` |
| 拦截 | SHIELD / shield / SHIELD | `intercept` |
| 规则与更新 | REFRESH / arrow.triangle | `rules-refresh` |
| 拦截日志 | LIST / list.bullet.rectangle | `intercept-logs` |
| 应用流量 | BOLT / bolt / BOLT | `app-traffic` |
| 运行模式 | BOLT / bolt / BOLT | `toggle` |
| 配置与节点 / 当前配置 | LIST+BOX / list.bullet+doc.text | `config-file` |
| 订阅管理 | LINK / link / LINK | `sync` |
| 插件管理 / 安装包 | UPLOAD / shippingbox | `package` |
| 上传安装包 | UPLOAD / arrow.up.doc | `upload` |
| 卸载插件 | LIST / trash | `delete` |
| 网络 | GLOBE / globe / GLOBE | `network` |
| 外网状态 | LINK / dot.radiowaves | `internet-status` |
| IPv4 / IPv6 | GLOBE / number | `ipv4` / `ipv6` |
| 内网网关 | LINK / house | `lan-gateway` |
| 设备信息 / 处理器 / 内存 / 系统盘 | CHIP·BOX / iphone·cpu·memorychip·internaldrive | `device-info` `processor` `memory` `system-disk` |
| 查看全部硬件 | LIST / list.bullet | `all-hardware` |
| 系统维护 / 配置备份 | BOX / shippingbox·archivebox | `package` / `backup` |
| 检查系统更新 / 软件包更新 / 升级进度 | BOLT·BOX·CLOCK | `system-update` `package-update` `upgrade-progress` |
| 电源控制 / 重启网络 / 重启路由器 / 关机 | POWER·REFRESH | `power` `restart-network` `restart-router` `shutdown` |
| 安全 / 改 App 密码 / 改路由器密码 | SHIELD·KEY | `security` `app-password` `router-password` |
| 主题 / 清缓存 / 退出登录 | MOON·TRASH·LOGOUT | `theme` `clear-cache` `logout` |
| 空状态 / 错误 | — | `empty` `status-warning` `status-error` `status-success` |

## 五、待补图标清单（v1.2.0 后）

### P0 · 仍缺

| 建议命名 | 用途 | 现状 |
|---|---|---|
| `close` | 弹层右上角 × | 仍是**本地补的两条线**（生成脚本 `EXTRA`），能用但不是设计稿 |

### P1 · 建议补（用近义图标顶着）

| 建议命名 | 用途 | 现在用什么 |
|---|---|---|
| `subscription` | 订阅管理 | `sync`（容易被读成刷新） |
| `nodes` / `node-group` | 节点分组、四种分组类型 | `devices` / `latency` / `sync` |
| `bolt` | 运行模式 / 加速 | `toggle` |
| `speed-test` | 测速 | `latency` |

> v1.2.0 已解决：`settings`（新增）、`wan`（`broadband` 重画成地球+插头，不再像 Wi-Fi）。

### P2 · 可选

`qrcode` `share` `history` `spark/pulse` `wifi`（不分频段的通用无线）。

### 库里已有、还没接的

`signal` `latency` `packet-loss` `download-speed` `upload-speed` `wifi-offline`
`permission` `timeout` `empty` `eye` `eye-off` `lock` `unlock` `search` `copy`
`edit` `add` `more` `download` `chevron-*` `status-*` `wired-connection`
`wifi-2-4g` `wifi-5g` `login-user` `link` `server-address` `toggle` `theme`

## 六、备份与回滚

- Android 旧图标：`backup/icons-android-20261113/`（手绘 `Glyph.java` + 7 个 vector）
- 三端现在都编译自生成数据，回滚只需把 `design/icons` 换回旧版并重跑脚本；
  若要退回手绘/系统符号，按备份目录覆盖并删除 `IconData.*` / `LineIcon.swift`

## 七、已知限制

- iOS 的非语义装饰仍是 SF Symbols（`chevron.right`、`magnifyingglass` 等），
  这些属于控件习惯，不跟设计稿走
- 鸿蒙真机当前未连接，本轮只到编译级；Android 已装机核对
- 16dp 小尺寸下的辨识度仍建议真机走查一遍
