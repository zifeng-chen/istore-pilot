# iStore Pilot · 鸿蒙端

HarmonyOS NEXT 原生应用，ArkTS + ArkUI（Stage 模型）。
功能与 `android/` 一一对应，共用同一个路由器 Agent 的 `/api/v1/*` 接口。

## 为什么不用 Mac

鸿蒙的构建链在 macOS / Windows / Linux 上都能跑：

| 环节 | 工具 | Windows 支持 |
|---|---|---|
| IDE | DevEco Studio 6.1.1 | 有 Windows 版 |
| 构建 | hvigorw（Gradle 的替代品） | 有独立 CLI |
| 包管理 | ohpm | 有 Windows 版 |
| 设备调试 | hdc（adb 的替代品） | 有 Windows 版 |
| 签名 | 由 DevEco 生成 p12 + cer + p7b | 不限平台 |

需要 Mac 的是 **iOS**（Xcode 强制），不是鸿蒙。
所以 `ios/` 那套 WKWebView 套壳才必须借 Mac，鸿蒙这边不必。

## 目录结构

```
entry/src/main/ets/
├─ entryability/EntryAbility.ets   入口 Ability：沉浸式、配置变化清色缓存、401 跳登录
├─ pages/
│  ├─ Index.ets                    五个页签的容器 + 安全区测量 + 页签广播
│  └─ LoginPage.ets                服务器地址 + 密码，可先「测试连接」再登录
├─ api/
│  ├─ Http.ets                     系统网络库封装（不引第三方 HTTP 客户端）
│  └─ Api.ets                      接口门面：peek() 读快照 / get() 拿真实数据
├─ core/
│  ├─ Session.ets                  服务器地址与令牌（preferences）
│  ├─ Snap.ets                     接口快照缓存，秒开用
│  └─ Json.ets                     JSON 安全取值，避免到处 try/catch
├─ ui/
│  ├─ Theme.ets                    设计系统：尺寸 + 自绘取色（Pal）
│  ├─ Comp.ets                     卡片 / 分组容器 / 键值行 / 状态标签
│  ├─ comp/
│  │  ├─ NavBar.ets                底部导航（Path 自绘图标 + 胶囊选中态）
│  │  ├─ Ring.ets                  Canvas 环形进度（仪表盘弧 135°/270°）
│  │  ├─ TrendChart.ets            Canvas 流量折线 + 面积渐变
│  │  └─ Icons.ets                 图标 SVG 指令
│  └─ tabs/                        五个页面
└─ util/Fmt.ets                    字节 / 速率 / 时长 / 千分位格式化
```

## 与 Android 端的差异

**相同**：配色四层、hero 卡深绿渐变、`icon_off` 独立语义色、分组列表、tabular 数字、
快照优先的加载策略、`/api/v1/*` 全部契约。

**不同**：
- 快照存在 `preferences`（鸿蒙没有 SharedPreferences），键名把 `?`/`&` 压成下划线
- 图表与环形用 `Canvas` 自绘，没有 MPAndroidChart 这种库可用，也不需要
- 底部导航用 `Tabs(barHeight: 0)` + 自绘 NavBar，保留滑动切页但视觉完全自控
- 页签轮询靠 `AppStorage('tab')` 广播：切走的页面立刻停定时器，不在后台空跑

## 构建

1. DevEco Studio → Open → 选本目录
2. 首次打开会提示 Sync，让它下载 SDK（`compatibleSdkVersion: 5.0.0(12)`）
3. File → Project Structure → Signing Configs → 勾选 Automatically generate signature
   （需要登录华为开发者账号，仅签名用，编译本身不需要）
4. 手机开「开发者选项 → USB 调试」，`hdc list targets` 能看到设备
5. 直接 Run，或者 `hvigorw assembleHap`

命令行构建（CI 用）：

```bash
hvigorw --mode module -p product=default assembleHap --no-daemon
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
```

## 当前状态

代码已完整实现，但**尚未编译验证** —— 本机没有 DevEco Studio / HarmonyOS SDK。
工程刻意留了三处「由 DevEco 自己补」的缺口，这不是遗漏：

| 位置 | 留空原因 |
|---|---|
| `hvigor/hvigor-config.json5` → `dependencies` | hvigor 插件版本与 SDK 强绑定，手写容易对不上，Sync 时会自动补齐 |
| `build-profile.json5` → `signingConfigs: []` | 签名证书必须登录华为账号生成，无法预置 |
| `entry/build-profile.json5` → 只有 `default` target | 没有 `src/ohosTest` 目录，多写一个 target 会让 Sync 报找不到模块 |

### 首次打开大概率遇到的四个提示

1. **「工程结构及配置需要升级」** —— 正常，点升级，让它写自己的 hvigor 版本
2. **「Cannot find module '@ohos/hvigor-ohos-plugin'」** —— 先点 Sync，不要直接 Build
3. **Run 时提示未配置签名** —— File → Project Structure → Signing Configs，
   勾「Automatically generate signature」，登录华为账号即可
4. **`compatibleSdkVersion: 5.0.0(12)` 报低于设备系统** —— 改成 `6.1.1(24)`，
   或按设备实际版本下调到 `4.0.0(10)`

### 待验证项（写的时候只能靠推理，跑起来才知道）

- `Pal.of()` 依赖 `resourceManager.getColorSync`，深浅色切换后 `Pal.refresh()` 是否及时生效
- TabContent 的子组件是否随页签切换销毁（若不销毁，靠 `AppStorage('tab')` 停轮询兜底）
- Path 图标坐标是按 22×22 手算的，若把 `.width(22)` 改大，图形不会跟着缩放
- `/api/v1/proxy/mode` 的返回结构没有实测过（只确认了路由存在），`loadMode()` 里做了
  「顶层 mode」和「data.mode」两种兜底
