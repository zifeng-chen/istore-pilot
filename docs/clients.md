# 三端打包与安装

三端**共用同一个 Agent 接口**（`/api/v1/*`）和同一个版本号，但构建链完全独立：
`android/`、`harmony/`、`ios/` 各自是一个可以单独 clone、单独出包的工程。

本文只讲「怎么出包、怎么签名、怎么装上去」。接口契约见 [`api.md`](api.md)，
设计取舍见 [`architecture.md`](architecture.md)。

| | Android | HarmonyOS | iOS |
|---|---|---|---|
| 语言 / 框架 | Java + AndroidX | ArkTS + ArkUI（Stage） | SwiftUI |
| 构建工具 | Gradle 8.7 + AGP | hvigor | xcodebuild |
| 能在本仓库的 Windows 机上构建 | ✅ | ✅（需 DevEco） | ❌ 必须 macOS |
| 产物 | APK 2.57 MB | HAP 2.50 MB（未签名） | `.xcarchive` / IPA |
| 能不能直接装 | ✅ | ❌ 需自己签名 | ❌ 需描述文件 |
| 页签 | 概览 / 设备 / 代理 / 设置 | 同左 | 同左 |

版本号统一由 `python scripts/bump_version.py --next` 推进，同步 6 处：

| 文件 | 字段 |
|---|---|
| `agent/server.py` | `VERSION` |
| `android/app/build.gradle` | `versionName` + `versionCode` |
| `ios/gen_project.py` | `VERSION`（再跑一次脚本写进 pbxproj） |
| `harmony/AppScope/app.json5` | `versionName` + `versionCode` |
| `harmony/oh-package.json5` | `version` |
| `harmony/entry/oh-package.json5` | `version` |

提交前用 `python scripts/check_version.py` 校验这 6 处是否一致。

---

## Android

### 环境

```bash
export JAVA_HOME="<JDK 17>"                       # AGP 8 要求 17，不要用 21
export ANDROID_HOME="<Android SDK>"
export JAVA_TOOL_OPTIONS="-Dfile.encoding=UTF-8"   # 中文文案按 UTF-8 编译，否则装到手机全是乱码
```

### 构建

```bash
cd android
gradle assembleRelease      # 或 gradlew assembleRelease
```

产物 `app/build/outputs/apk/release/app-release.apk`。

release 已开 R8 与资源收缩：

```gradle
release {
    minifyEnabled true
    shrinkResources true
    proguardFiles getDefaultProguardFile('proguard-android-optimize.txt'), 'proguard-rules.pro'
}
```

体积变化：**5.33 MB → 2.57 MB**，dex 8.83 MB → 1.67 MB。

**开 R8 之前必须确认三件事**，任何一条不成立都会在运行时崩：

| 前提 | 检查方式 | 不满足的后果 |
|---|---|---|
| 没有反射 | `grep -rn "Class.forName\|getDeclaredMethod\|setAccessible" app/src/main/java` | 类被裁掉，`ClassNotFoundException` |
| 布局里没有自定义 View 全限定名 | `grep -rhoE "<com\.chaof\.[a-z.]+" res/layout` | inflate 时找不到类 |
| 图标是静态 `R.drawable.*` 引用 | 看 `util/AppIcons.java` 是不是 `MAP.put(name, R.drawable.x)` | 若是 `getIdentifier("ic_"+name)`，资源收缩会把图标删成占位块 |

`app/proguard-rules.pro` 里只留了两条 keep：`widget.**`（自绘控件）和
MPAndroidChart 整包（库内部有泛型回调，混淆后偶发 `ClassCastException`）。

### 签名

`android/keystore.properties` 与 `android/istoreos.keystore` **都不入库**
（`.gitignore` 已排除）。自己生成一份：

```bash
keytool -genkeypair -v -keystore android/istoreos.keystore \
        -alias istoreos -keyalg RSA -keysize 2048 -validity 10000
```

```properties
# android/keystore.properties
storeFile=istoreos.keystore
storePassword=<口令>
keyAlias=istoreos
keyPassword=<口令>
```

**这个 keystore 丢了就再也无法给已装的 App 发更新** —— 签名不同，系统会拒绝覆盖安装。
务必离线备份。

### 装到手机

```bash
adb install -r dist/istoreos-0.1.3.apk
```

走 Wi-Fi 调试时有个坑：`adb connect` 之后 daemon 可能被回收，下一条命令就变成
`no devices`。所以 **connect 和后续命令必须写在同一次 shell 调用里**：

```bash
adb connect 192.168.1.129:5555 && adb install -r dist/istoreos-0.1.3.apk
```

### 构建缓存

改完 Java 后如果 gradle 报 `UP-TO-DATE` 但行为没变，是增量快照失效了。
先确认 class 真的更新过：

```bash
grep -rl "你的新类名" app/build/intermediates/javac/release/classes/ | head
```

必要时 `gradle clean`。

---

## HarmonyOS

工程是 Stage 模型。构建链在 macOS / Windows / Linux 都能跑，**不需要 Mac**。

### 环境

- DevEco Studio（本项目用 6.x），自带 HarmonyOS SDK、hvigor、ohpm
- SDK 版本由 `harmony/build-profile.json5` 的 `compatibleSdkVersion: "6.0.0(20)"` 决定
- `modelVersion` 在 `harmony/hvigor/hvigor-config.json5`

### 构建

```bash
cd harmony
hvigorw --sync                                              # 首次：补齐 hvigor 插件版本
hvigorw --mode module -p product=default -p buildMode=release assembleHap --no-daemon
```

产物 `entry/build/default/outputs/default/entry-default-unsigned.hap`（2.50 MB）。

`hvigor-config.json5` 里的 `dependencies` 故意留空 —— hvigor 插件版本与 SDK 强绑定，
手写容易对不上，`--sync` 会按本机 SDK 自动补齐。

### 签名（装不上的唯一门槛）

`build-profile.json5` 的 `signingConfigs` 是空数组。要装真机必须：

1. 在 AppGallery Connect 上建应用，`bundleName` 用 `com.chaof.istoreos`
2. 生成 `p12`（密钥库）+ `cer`（证书）+ `p7b`（Profile）
3. 在 `build-profile.json5` 里填 `signingConfigs`，或在 DevEco 的
   File → Project Structure → Signing Configs 勾「Automatically generate signature」

**本仓库现成的 p7b 绑的是别的包名**，所以只能出 `unsigned` 包，
`hdc install` 会以「签名校验失败」拒绝。这不是代码问题。

### 装到设备

```bash
hdc list targets
hdc install -r entry/build/default/outputs/default/entry-default-signed.hap
```

### 四条不能动的配置

| 位置 | 内容 | 去掉会怎样 |
|---|---|---|
| `resources/base/profile/network_config.json` | `cleartextTrafficPermitted: true` | 接口是明文 HTTP `:8443`，直接连不上 |
| `resources/base/profile/main_pages.json` | 页面登记 | 光有 `@Entry` 不够，`router.pushUrl` 找不到页面 |
| `entry/src/main/module.json5` | 权限声明 | 缺 `INTERNET` 时请求静默失败 |
| `AppScope/app.json5` 的 `bundleName` | 与签名证书一致 | 改了包名，已发的证书全部作废 |

### 图标的坑

底部导航和功能图标用 `Path` 指令画。**`Path.commands` 遇到 `A`（圆弧）、`H`、`V`
会截断**，只剩 `M`，画出来就是一个点。用脚本把弧转成三次贝塞尔：

```bash
python scripts/harmony_icon_paths.py --check   # 扫有没有残留的 A/H/V
python scripts/harmony_icon_paths.py           # 转换并写回
python scripts/harmony_icon_paths.py --sheet   # 出一张图标对照图
```

同样的道理，`Text('‹')` 这种符号依赖系统字体，换机型可能变方框 —— 一律换成路径图标
（`Glyph.CHEVRON_LEFT` / `Glyph.SWAP`）。

---

## iOS

纯 SwiftUI，没有 WebView。**必须有 macOS + Xcode**，这一环绕不过去。

### 工程是脚本生成的

`IStorePilot.xcodeproj/project.pbxproj` **不要手改**。它由 `gen_project.py` 扫描
`IStorePilot/` 下所有 `.swift` 生成，UUID 按路径哈希算（稳定、可重复）：

```bash
cd ios
python gen_project.py
```

**增删 `.swift` 之后必须重跑**，否则新文件不参与编译，报 `cannot find X in scope`。

### 构建与归档

```bash
cd ios
xcodebuild -project IStorePilot.xcodeproj -scheme IStorePilot \
           -configuration Release -destination 'generic/platform=iOS' \
           -archivePath build/IStorePilot.xcarchive archive
```

只想验证能不能编译，用模拟器目标更快（不需要签名）：

```bash
xcodebuild -project IStorePilot.xcodeproj -scheme IStorePilot \
           -configuration Debug -destination 'generic/platform=iOS Simulator' build
```

### 导出 IPA

`archive` 只是打包成 `.xcarchive`，要得到能装的 IPA 还得导一次，
而导这一步**必须有描述文件**：

```bash
xcodebuild -exportArchive -archivePath build/IStorePilot.xcarchive \
           -exportPath build/ipa -exportOptionsPlist ExportOptions.plist
```

`ExportOptions.plist` 至少要有：

```xml
<key>method</key><string>development</string>
<key>teamID</key><string>你的 Team ID</string>
<key>provisioningProfiles</key>
<dict><key>com.chaof.istoreos</key><string>描述文件名</string></dict>
<key>signingStyle</key><string>manual</string>
```

**当前仓库的状态是「有证书、没描述文件」**：Apple Development 证书 1 张，
Provisioning Profile 0 个 → 能 archive，导不出 IPA。自己跑的话在 Xcode 的
Signing & Capabilities 里选一次 Team（免费 Apple ID 也行）就会自动生成，
但免费账号的包 **7 天过期**，过期后要重新签。

### Info.plist 里两条必须保留

| 键 | 为什么 |
|---|---|
| `NSAppTransportSecurity → NSAllowsArbitraryLoads = true` | Agent 是明文 HTTP `:8443`，不放开的话请求在到达路由器之前就被系统拦掉 |
| `NSLocalNetworkUsageDescription` | iOS 14+ 首次访问局域网 IP 会弹权限框，用户点拒绝后只能去系统设置里手动开 |

---

## 三端差异（实现层面）

| 项 | Android | HarmonyOS | iOS |
|---|---|---|---|
| 图表 / 环形 | MPAndroidChart + 自绘 | `Canvas` 自绘 | `Path` 自绘 |
| 快照缓存 | `SharedPreferences` | `preferences` | `UserDefaults` |
| 底部导航 | `BottomNavigationView` + Fragment hide/show | `Tabs(barHeight:0)` + 自绘 NavBar | 自绘 |
| 图标 | `R.drawable.*`（mipmap 不用 adaptive，成品会被 66% 安全区裁掉） | `Path` 指令 | `Assets.xcassets` 单尺寸 1024 |
| 明文 HTTP | 默认允许 | 需 `network_config.json` | 需 ATS 放开 |
| 深色模式 | `values-night`（同名 style 是**替换不是合并**，基础主题拆 `Theme.IStore.Base`） | `Pal.of()` 读系统资源 | `C.*` 算过对比度的常量，不用系统语义色 |

三端的配色数值是一一对应的：Android `values/colors.xml` ↔ iOS `UI/Theme.swift` ↔
鸿蒙 `ui/Theme.ets`。改一处要同步另外两处，否则同一张卡片在三个端上颜色不一样。
