# 移动端安装包

## 2.x 是纯原生，不再套壳

1.0.0 是 WebView 薄壳，加载路由器上的网页。实测三个硬伤：冷启动要等网页和接口三跳、滚动和点击没有原生手感、离开路由器就只剩错误页。

2.x 的 Android 端是**纯原生界面**：Java + AndroidX/Material，自绘环形进度和速率曲线，底部五个页签，所有数据走 `HttpURLConnection` 直连接口。路由器上的 Agent 一行没改。

| 平台 | 产物 | 状态 |
|---|---|---|
| Android | `dist/istoreos-2.1.2.apk` | ✅ 已在 OPPO / Android 16 真机跑通 |
| iOS | `ios/` | ⏳ 仍是 WKWebView 套壳，原生 SwiftUI 版待做 |
| HarmonyOS NEXT | 未开始 | ⏳ 需先装 DevEco Studio |

真机截图见 `screenshots/`（六个页面都是实机抓的，不是效果图）。

---

## Android 2.1.2

### 版本变化

| 版本 | 变化 |
|---|---|
| 2.0.0 | 从 WebView 壳改成原生界面 |
| 2.1.0 | 新增设备管理（列表 + 详情 + 改名/禁网/固定 IP/唤醒）；原「网络」页并入设置 |
| 2.1.2 | 真机验证后修的四处：主板占位型号过滤、节点名国旗 emoji 显示成方块、未测速显示 `0ms`、版本号改从包信息读取 |

### 安装

**方式一：ADB 直推（已配好）**

```bash
ADB="/c/Users/chaof/AppData/Local/Android/Sdk/platform-tools/adb.exe"
"$ADB" connect 192.168.1.131:5555
"$ADB" install -r dist/istoreos-2.1.2.apk
```

手机端要开着「无线调试」。首次连接需要配对：

```bash
# 手机上：开发者选项 → 无线调试 → 使用配对码配对设备
"$ADB" pair 192.168.1.131:<配对端口> <6位配对码>
"$ADB" connect 192.168.1.131:<连接端口>   # 配对完显示的那个端口
```

配好之后执行一次 `adb tcpip 5555`，以后固定连 5555，不用再配对（重启手机后要重做一次）。

**方式二：手机浏览器下载**

```
http://<电脑IP>:8899/istoreos-2.1.2.apk
```

电脑上先 `cd dist && python -m http.server 8899 --bind <电脑IP>`。

**方式三：拷文件**——微信传给自己、数据线拖进去都行。

三种方式装出来的包完全一样，与旧版同签名，可以直接覆盖升级。

### 首次登录

| 项 | 值 |
|---|---|
| 地址 | `192.168.1.1:8443`（外网填 DDNS 域名，后面同样加 `:8443`） |
| 密码 | 路由器后台控制密码（不在此文档记录） |
| 令牌 | 7 天有效，之后打开免登录 |

### 四个页签

| 页签 | 内容 |
|---|---|
| 概览 | 主机名/系统/内核/在线时长、CPU·内存·磁盘三个环、负载温度进程数、WAN 实时上下行（含曲线）、网口状态；底部「网络设置」进二级页 |
| 设备 | 总数/在线/已禁网、实时总流量、搜索框、在线离线分组；点进去是独立详情页；拦截（AdGuard Home）也在这页 |
| 代理 | OpenClash 与 Passwall 谁在跑、引擎与节点数、运行模式切换、节点按分组折叠、点击即切换 |
| 设置 | 连接信息、WAN/LAN 明细（IPv4、IPv6 全局地址、网关）、改密码、清缓存、关于 |

### 网络设置（二级页）

原来的「网络」页签已经撤掉，内容并进概览 →「网络设置」：

| 区块 | 内容 |
|---|---|
| 结论 | 是否拨通、接入方式、WAN 地址（脱敏）、网关、在线时长 |
| 连接操作 | 重拨 / 断开 / 连接。不动配置，所以点错了再点回来就行 |
| 接入方式 | PPPoE / DHCP / 静态 IP，切换后参数表单跟着变 |
| 参数 | 宽带账号口令、DNS、MTU；口令留空表示不修改 |
| 局域网 | 管理地址、可用地址、DHCP 状态、地址池占用条、租期、IPv6 前缀（只读） |
| 防火墙 | 默认 / WAN / LAN 入站、转发与端口转发条数（只读，WAN 放行标红） |
| 风险 | 配置层面的暴露点，例如 `wan` 区 input=ACCEPT |
| 出口 | 打开路由器网页端（LuCI），改网段、静态路由、DDNS。**在 App 内置浏览器里打开，且已登录** |

> 所有响应里的公网地址都已脱敏（`100.*.*.34`、`240e:3a0:…`），
> 局域网地址保持原样。截图可以直接发。

### 内置浏览器（路由器网页端）

点「路由器网页端」不再甩给系统浏览器，而是 App 内的 WebView：

- 打开前先向 Agent 要一张通行证（`GET /luci/session`），把 `sysauth_http`
  cookie 塞进 WebView 的 cookie 罐，再加载 `/cgi-bin/luci/` —— 落地就是后台首页，
  不用再输一遍口令。口令不出路由器，客户端拿到的只是一个会话 id
- 拿不到通行证（root 口令和 App 登录口令不一致）时照样打开，退回手动登录
- LuCI 的 argon 主题给主容器写了 `min-width:600px`，iStoreOS 首页的卡片又是固定两列，
  在手机上右侧必然溢出。页面加载完后客户端会量一次真实内容宽度，把 viewport
  改成那个宽度再等比缩小，整页完整显示；`user-scalable` 同时放开，双指还能放大
- 顶部有返回（页面还有历史时先回退历史）和刷新

### 设备详情页（2.1 的核心）

从设备列表点任意一台进去，看的是这五块：

| 区块 | 内容 |
|---|---|
| 基本信息 | 名称、IP、在线状态、MAC、厂商（4 万条 OUI 库识别）、IP 绑定方式 |
| 实时流量 | 当前上下行速率、累计收发、活跃连接数 |
| 管理 | 改备注、禁止上网、固定 IP、网络唤醒 |
| 正在访问 | 这台设备正在访问的域名，按流量排序，带代理链和命中规则 |
| 连接明细 | 对端 IP + 端口 + 服务猜测 + 收发字节 |

「正在访问」这一块是难点：开了 OpenClash 后 conntrack 里全是 `198.18.x.x` 的 fake-ip，光看 IP 什么都看不出。做法是从 Clash 的 `/connections` 按 `metadata.sourceIP` 过滤，取 `host` 字段还原真实域名，同时剔掉订阅里的「剩余流量：xxx GB」这类伪节点。

### 三个体验点的实现方式

**秒开**：每个接口响应都写一份本地快照。进页面先同步渲染快照，同时后台请求真实数据回来原地替换，不出现转圈白屏。

**离线可看**：请求失败时不清空界面，只挂一条橙色提示条「⚠ 连不上路由器（下拉可重试）」，数字仍是上次的。

**不像网页**：底部页签用 add/hide 而非 replace，切回来滚动位置和数据都在；控制项全部是 Material 原生控件，下拉刷新是 SwipeRefreshLayout；深色/浅色跟随系统。

### 技术参数

| 项 | 值 |
|---|---|
| 包名 | `com.chaof.istoreos` |
| 应用名 | iStore Pilot |
| 版本 | 2.1.2（versionCode 5） |
| 支持系统 | Android 7.0+（minSdk 24） |
| 目标系统 | Android 14（targetSdk 34） |
| 实机验证 | OPPO PFEM10，Android 16 / SDK 36 / arm64-v8a |
| 体积 | 4.1 MB |
| 依赖 | AndroidX appcompat / material / recyclerview / swiperefreshlayout / constraintlayout |
| 权限 | 仅 INTERNET + ACCESS_NETWORK_STATE |
| 签名 | `istoreos.keystore`，10000 天 |

体积从 57 KB 涨到 4.1 MB 是原生控件的固有代价（Material 库几百个资源）。换来的是一整套真实的原生交互。

### 重新打包

```bash
export JAVA_HOME="C:/Users/chaof/.workbuddy/binaries/jdk/jdk-17.0.20.1+1"
export ANDROID_HOME="C:/Users/chaof/AppData/Local/Android/Sdk"
export JAVA_TOOL_OPTIONS="-Dfile.encoding=UTF-8"      # 中文文案编译不乱码
cd android
"C:/Users/chaof/.workbuddy/binaries/gradle/gradle-8.7/bin/gradle.bat" assembleRelease
```

产物：`app/build/outputs/apk/release/app-release.apk`

改版本号：`app/build.gradle` 的 `versionCode` / `versionName`（设置页的版本是从包信息读的，不用改文案）。

> 环境坑（都已在工程里解决，重装环境时会再遇到）：
> - `services.gradle.org` 与 `repo.maven.apache.org` 本机不通 → Gradle 用华为云分发包，依赖仓库走 Google Maven + 阿里云镜像
> - 引入 AndroidX 后必须在 `gradle.properties` 里开 `android.useAndroidX=true`，否则 `mergeReleaseNativeLibs` 直接失败
> - 界面文案写在 Java 里，必须锁 UTF-8 编码，否则中文 Windows 上按 GBK 编译，装到手机全是乱码
> - `values-night` 里同名 style 是**整体替换不是合并**，基础主题要拆成 `Theme.IStore.Base`，各限定符只覆盖个别 item

### 代码结构

```
app/src/main/java/com/chaof/istoreos/
├── MainActivity.java          底部导航 + 3 秒刷新节拍
├── DeviceDetailActivity.java  设备详情（独立页，不是弹窗）
├── api/Api.java               HTTP 客户端（缓存优先 + 后台刷新）
├── api/Cb.java                回调
├── core/Session.java          地址 + 令牌
├── core/Snap.java             接口快照缓存
├── util/Ui.java               卡片/键值行/标签等构建器
├── util/Fmt.java              字节、速率、时长格式化
├── widget/RingView.java       自绘环形进度
├── widget/GraphView.java      自绘速率曲线
└── ui/                        5 个页签 + 登录页 + 基类
```

界面不写一堆 XML：卡片、键值行、标签全部由 `Ui.java` 在代码里构建，改一个颜色全局生效。只有登录页和设备详情外的两个布局用了 XML。

### 签名凭据

签名用的 `istoreos.keystore` 与 `keystore.properties` **不入库**（`.gitignore` 已排除），
需要自行生成一份放在 `android/` 下：

```properties
storeFile=istoreos.keystore
storePassword=<你的口令>
keyAlias=istoreos
keyPassword=<你的口令>
```

**这个 keystore 丢了就再也无法给已装的 App 发更新**（签名不同系统会拒绝覆盖安装），务必离线备份。

---

## iOS

见 `ios/README.md`。当前仍是 WKWebView 套壳，和 Android 1.0.0 一个问题。要做原生得重写成 SwiftUI，需要 Mac + Xcode，免费签名 7 天到期。

## HarmonyOS NEXT

需要先在这台 Windows 上装 DevEco Studio（约 15 GB）。原生版走 ArkTS + ArkUI，接口和设计规范与 Android 版一致，可以逐页对照移植。
