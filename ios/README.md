# iStore Pilot — iOS 原生端

纯 SwiftUI，没有 WebView。接口与安卓端、鸿蒙端完全共用 `/api/v1/*`，
所以三端看到的数据一定是一致的。

## 编译

```bash
# 命令行（不需要打开 Xcode）
cd ios
xcodebuild -project IStorePilot.xcodeproj \
           -scheme IStorePilot \
           -configuration Release \
           -destination 'generic/platform=iOS' \
           -archivePath build/IStorePilot.xcarchive \
           archive

# 导出 IPA 需要 ExportOptions.plist
xcodebuild -exportArchive -archivePath build/IStorePilot.xcarchive \
           -exportPath build/ipa -exportOptionsPlist ExportOptions.plist
```

Xcode 里直接打开 `IStorePilot.xcodeproj`，选真机 Run 也可以。
首次打开要在 Signing & Capabilities 里选一次 Team（个人 Apple ID 即可，
免费账号 7 天有效期）。

## 工程是脚本生成的

`project.pbxproj` 不要手改。加删 `.swift` 之后重跑：

```bash
python gen_project.py
```

脚本会扫 `IStorePilot/` 下所有 `.swift`，按目录自动分组，UUID 由路径哈希
得出（稳定、可重复）。

## 目录

```
IStorePilot/
├── App.swift              入口 + 全局登录态
├── Info.plist             ATS 放开（Agent 是明文 HTTP 8443）、本地网络权限
├── Core/
│   ├── J.swift            JSON 便捷取值（对应安卓的 JSONObject）
│   ├── Session.swift      地址 + 令牌（对应 core/Session.java）
│   ├── Api.swift          URLSession 客户端 + 内存快照缓存
│   └── Fmt.swift          字节 / 速率 / 时长格式化
├── UI/
│   ├── Theme.swift        配色四层，数值与 values/colors.xml 一一对应
│   └── Comp.swift         卡片 / 键值行 / 胶囊 / 进度条 / 分段控件
└── Views/
    ├── LoginView.swift
    ├── RootView.swift     四页签 + 自绘底部导航
    ├── OverviewView.swift 概览
    ├── DevicesView.swift  设备列表（搜索 / 筛选）
    ├── DeviceDetailView.swift
    ├── ProxyView.swift    代理（配置切换弹窗 + 节点选择）
    ├── SubscriptionView.swift
    ├── ShieldView.swift   广告拦截 + 拦截日志
    └── SettingsView.swift
```

## 几个必须知道的点

- **ATS 必须放开**：Agent 监听 `http://192.168.1.1:8443`，不放开
  `NSAllowsArbitraryLoads` 的话所有请求在到达路由器之前就被系统拦了。
- **本地网络权限**：iOS 14+ 第一次访问局域网 IP 会弹权限框，文案在
  `NSLocalNetworkUsageDescription`。用户点了拒绝得去系统设置里手动开。
- **不改 token 传法**：走 `Authorization: Bearer <token>`，和安卓端一致。
  401 时 `Api` 自动登出并回到登录页。
- **配色不要用系统语义色**：`C.textSecondary` 是算过对比度的值，
  换成 `.secondary` 会在深色下糊成一片。
- **不需要推送**：这个 App 没接 APNs，别在 Capabilities 里开。

## 和安卓端的差异

| 项 | 安卓 | iOS |
| --- | --- | --- |
| 图标 | 传统 mipmap（**不用 adaptive**，成品图会被 66% 安全区裁掉） | Assets.xcassets 单尺寸 1024 |
| 导航 | 自绘 NavBar | 自绘 BottomBar |
| 弹窗 | 自绘 Sheet | 系统 sheet + confirmationDialog |
| 缓存 | SharedPreferences 快照 | 内存字典（冷启动不缓存） |

## 待办

- [ ] 硬件详情页（`/api/v1/system/hardware`）
- [ ] WAN 详情页（`/api/v1/network/wan`）
- [ ] 应用流量页（`/api/v1/apps`）
- [ ] 趋势图表（安卓用 MPAndroidChart，iOS 需要 Swift Charts 或自绘）

旧的 `ViewController.swift` / `error.html` 是早期 WKWebView 套壳的残留，
原生端跑通后可以删。
