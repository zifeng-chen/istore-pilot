# 图标库落地说明（iStore Pilot SVG Icon Library v1.0.1）

> 设计源：`design/icons/`（76 个 SVG + sprite + manifest + 预览页）
> 生成脚本：`scripts/gen_icons.py`

## 一、能不能用：能，而且和现有实现同源

| 规格 | 图标库 | 我们原来的 `Glyph` | 结论 |
|---|---|---|---|
| 画布 | 24×24 | 24×24（`GRID = 24f`） | 一致 |
| 描边 | 2px，圆头 / 圆角连接 | `stroke = 2f`，`ROUND` / `ROUND` | 一致 |
| 填充 | 默认 `none`，个别小圆点 `currentColor` | 描边为主，个别实心（月牙、三点） | 一致 |
| 颜色 | `currentColor`（由宿主决定） | `setColor()` 逐处传 | 一致 |

所以不是「换一套风格」，而是**把同一套语言从手绘换成了设计稿**。视觉差异主要在图形本身（比如「网口」从立方体换成 RJ45、「系统负载」从芯片换成仪表盘），线宽、端点、留白都保持不变。

## 二、Android 怎么接的

1. `scripts/gen_icons.py` 把每个 SVG 的 `path/circle/rect/ellipse/line/polyline`
   统一转成 24×24 的 path data，生成 `widget/IconData.java`（77 条，含本地补的 `close`）。
2. `Glyph` 不再用 `switch` 手绘，改为用 `androidx.core.graphics.PathParser`
   解析一次并静态缓存，再按控件尺寸缩放描边。对外 API 没变：
   `new Glyph(c)` + `setKind()` + `setColor()`。
3. 常量名与文件名一一对应（`system-load` → `Glyph.SYSTEM_LOAD`）。
   旧名（`GLOBE` / `BOX` / `SHIELD` …）保留为 `@Deprecated` 别名，防止漏改的调用点编译不过。
4. 底部页签与返回键是系统 `ImageView`，走真正的 VectorDrawable：
   `res/drawable/ic_nav_*.xml`、`ic_back.xml` 由同一脚本生成（描边版，不再是实心 Material）。

改图流程：换 `design/icons/icons/**/*.svg` → `python scripts/gen_icons.py` → 编译。
`python scripts/gen_icons.py --check` 可在 CI 里校验产物是否与设计源同步。

## 三、调用点映射（Android）

同一张旧图标在不同位置含义不同（`BOX` 同时当过「网口」「当前配置」「系统盘」），
所以这次是**按语义逐个换**，不是机械替换。

### 概览
| 位置 | 旧 | 新 |
|---|---|---|
| 系统负载 | `CHIP` | `SYSTEM_LOAD` |
| 宽带连接 | `GLOBE` | `BROADBAND` |
| 网络设置（行） | `LINK` | `NETWORK_SETTINGS` |
| 网口 | `BOX` | `ETHERNET_PORT` |

### 设备
| 位置 | 旧 | 新 |
|---|---|---|
| 设备卡 | `LINK` | `DEVICES` |
| 拦截卡 | `SHIELD` | `INTERCEPT` |
| 规则与更新 | `REFRESH` | `RULES_REFRESH` |
| 拦截日志 | `LIST` | `INTERCEPT_LOGS` |
| 应用流量卡 | `BOLT` | `APP_TRAFFIC` |

### 代理
| 位置 | 旧 | 新 |
|---|---|---|
| 运行模式 | `BOLT` | `TOGGLE` |
| 配置与节点 / 当前配置 | `LIST` / `BOX` | `CONFIG_FILE` |
| 订阅管理 | `LINK` | `SYNC` |
| 插件管理 / 未安装卡 | `UPLOAD` | `PACKAGE` |
| 上传安装包 | `UPLOAD` | `UPLOAD`（保留） |
| 卸载插件 | `LIST` | `DELETE` |
| hero 后端行 | `POWER` | `PROXY` |
| 分组类型 urltest / fallback / relay / 其它 | `BOLT` / `SHIELD` / `LINK` / `LIST` | `LATENCY` / `SYNC` / `LINK` / `DEVICES` |

### 设置
| 位置 | 旧 | 新 |
|---|---|---|
| 网络卡 | `GLOBE` | `NETWORK` |
| 外网状态 | `LINK` | `INTERNET_STATUS` |
| IPv4 / IPv6 | `GLOBE` | `IPV4` / `IPV6` |
| 内网网关 | `LINK` | `LAN_GATEWAY` |
| 设备信息 | `CHIP` | `DEVICE_INFO` |
| 处理器 / 内存 / 系统盘 | `CHIP` / `CHIP` / `BOX` | `PROCESSOR` / `MEMORY` / `SYSTEM_DISK` |
| 查看全部硬件 | `LIST` | `ALL_HARDWARE` |
| 系统维护 | `BOX` | `PACKAGE` |
| 配置备份 | `BOX` | `BACKUP` |
| 检查系统更新 | `BOLT` | `SYSTEM_UPDATE` |
| 检查软件包更新 | `BOX` | `PACKAGE_UPDATE` |
| 查看升级进度 | `CLOCK` | `UPGRADE_PROGRESS` |
| 电源控制 / 关闭路由器 | `POWER` | `POWER` / `SHUTDOWN` |
| 重启网络 / 重启路由器 | `REFRESH` | `RESTART_NETWORK` / `RESTART_ROUTER` |
| 安全 | `SHIELD` | `SECURITY` |
| 改 App 密码 / 改路由器密码 | `KEY` | `APP_PASSWORD` / `ROUTER_PASSWORD` |
| 主题 / 清缓存 / 退出登录 | `MOON` / `TRASH` / `LOGOUT` | `THEME` / `CLEAR_CACHE` / `LOGOUT` |

### 宽带二级页 / 备份
| 位置 | 旧 | 新 |
|---|---|---|
| 连接操作 | `BOLT` | `RESTART_NETWORK` |
| 接入方式 | `GLOBE` | `NETWORK_SETTINGS` |
| 参数 | `KEY` | `ROUTER_PASSWORD` |
| 局域网 | `LINK` | `LAN_GATEWAY` |
| 防火墙 | `SHIELD` | `SECURITY` |
| 路由器网页端 | `GLOBE` | `SERVER_ADDRESS` |
| 备份列表 | `BOX` | `BACKUP` |

## 四、缺漏清单（图标库里没有、但界面确实用到）

| 需要 | 现状 | 处理 |
|---|---|---|
| `close`（× 关闭弹层） | 库中没有 | **本地补**两条线（`EXTRA`），等设计补图后替换 |
| `bolt`（闪电，原来表示「运行模式 / 连接操作 / 应用流量」） | 库中没有 | 已按语义拆给 `TOGGLE` / `RESTART_NETWORK` / `APP_TRAFFIC`，不再需要 |
| `list`（三横线，原来当「列表 / 配置」） | 库中没有通用三横线 | 已拆给 `CONFIG_FILE` / `INTERCEPT_LOGS` / `ALL_HARDWARE` |
| `info`（ⓘ） | 库里只有 `status-info`（圆形感叹号） | 未使用，需要时用 `STATUS_INFO` |
| `palette`（调色盘） | 库中没有，但有 `theme`（半圆对比） | 用 `THEME` |
| `gear`（齿轮，底部「设置」页签） | 库中没有纯齿轮，`network-settings` 是齿轮+地球 | 页签暂用 `network-settings`；**若设计认为语义偏「网络」，建议补一个 `settings`** |

其余我们没用到、但库里已有的：`signal` `latency` `packet-loss` `download-speed`
`upload-speed` `wifi-offline` `permission` `timeout` `empty` `sync` `eye` `eye-off`
`lock` `unlock` `search` `copy` `edit` `add` `more` `download` `chevron-*`
`status-*`（成功 / 警告 / 错误 / 信息 / 加载 / 在线 / 离线）——
后面做「空状态 / 错误页 / 测速」时可以直接用，不必再画。

## 五、备份与回滚

替换前的文件在 `backup/icons-android-20261113/`：

- `Glyph.java`（19 个手绘图标）
- `drawable/ic_nav_*.xml`、`ic_back.xml`（实心 Material 风格）

回滚：按原路径覆盖回去，删掉 `widget/IconData.java`。

## 六、还没做的

- **iOS / 鸿蒙**：库是 SVG，两端都需要各自的落地方式（iOS 有 `LineIcon`/`GlyphIcon`
  自绘体系，鸿蒙是 Canvas 重放），这次只按要求先换 Android。
- **深色 / 选中态**：图标全部 `currentColor`，颜色仍由各处传，深浅色自动跟随。
- **真机走查**：Android 手机当前没连上，本轮只到「编译通过 + 路径数据自检」，
  装到机器上还要确认 16dp 小尺寸下的辨识度。
