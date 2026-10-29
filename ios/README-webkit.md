# iOS 打包指南（Mac + 免费 Apple ID）

你有 Mac、没有开发者账号，所以走**个人免费签名**：Xcode 用你的 Apple ID 直接签，装到自己手机上。

代价只有两条：

- 签名 **7 天过期**，到期在 Xcode 里再 Run 一次即可（覆盖安装，数据不丢）
- 同时最多 3 个自签名 App

下面全程约 10 分钟。

---

## 一、准备

| 项 | 要求 |
|---|---|
| Xcode | App Store 搜 Xcode 装好，首次打开要点「Install additional components」 |
| iPhone | iOS 15 以上，用数据线连 Mac |
| Apple ID | 免费的就行，不用买开发者账号 |

---

## 二、新建工程

1. Xcode → **File → New → Project**
2. 选 **iOS → App** → Next
3. 填：
   - Product Name：`iStoreOS`
   - Team：先选 **None**，一会儿再配
   - Organization Identifier：`com.chaof`
   - Interface：**Storyboard** ← 必须是这个，不要选 SwiftUI
   - Language：**Swift**
   - 三个勾（Core Data / Tests）全部取消
4. 选个保存位置，Create

---

## 三、换掉界面代码

1. 左侧点开 `iStoreOS/ViewController.swift`
2. **全选删除**，把本目录 `ViewController.swift` 的全部内容粘进去
3. 左侧点开 `Main.storyboard`，确认里面那个 ViewController 的 Class 是 `ViewController`（默认就是，不用改）
4. 把本目录的 `error.html` 拖进 Xcode 左侧工程树（放在 `iStoreOS` 组下）
   - 弹窗里勾 **Copy items if needed**
   - **Add to targets** 勾上 `iStoreOS`

> error.html 是「连不上路由器」时显示的内置页面，不拖进去会退回成系统弹窗，功能不受影响但体验差。

---

## 四、允许 http 明文访问

路由器页面是 `http://`，iOS 默认会拦掉。

1. 左侧点 `Info.plist`（或点工程 → Targets → Info → 右键 Add Row）
2. 添加键 **App Transport Security Settings**（`NSAppTransportSecurity`），类型 Dictionary
3. 在它下面加一行 **Allow Arbitrary Loads**（`NSAllowsArbitraryLoads`），类型 Boolean，值 **YES**

> 如果你以后给路由器上了 HTTPS 证书，可以把这一项删掉，更安全。

---

## 五、配签名（免费 Apple ID）

1. 左侧点蓝色工程图标 → **TARGETS → iStoreOS** → **Signing & Capabilities**
2. 勾 **Automatically manage signing**
3. **Team** → 选 `Add an Account...` → 用你的 Apple ID 登录 → 回来后选这个 Personal Team
4. **Bundle Identifier** 改成唯一的，例如 `com.chaof.istoreos`
   - 如果报「identifier is not available」，后面加几个字，如 `com.chaof.istoreos1`

---

## 六、装到手机

1. iPhone 连上 Mac，解锁，点「信任此电脑」
2. Xcode 顶部设备选择器选中你的 iPhone → 点 ▶（Run）
3. 手机第一次会提示「不受信任的开发者」：
   **设置 → 通用 → VPN 与设备管理 → 开发者 App → 你的 Apple ID → 信任**
4. 回到桌面，图标出现，打开即可

---

## 七、日常使用

| 操作 | 说明 |
|---|---|
| **摇一摇手机** | 弹出「路由器地址」，可切内网 IP / 外网域名 |
| 下拉 | 刷新页面 |
| 连不上时 | 显示内置错误页，页面里可直接改地址 |
| 7 天后打不开 | 用数据线连 Mac，Xcode 里再点一次 ▶，覆盖安装 |

地址默认 `http://192.168.1.1:8443`，首次打开会自动尝试。

---

## 八、以后想升级

买 99 美元/年开发者账号后，同一份工程可以：

- 有效期从 7 天变成 1 年
- 用 **TestFlight** 分发，不用连电脑，家人手机也能装
- 有效期 90 天一轮，可续

代码不用改，只要在 Signing 里换成付费 Team。

---

## 附：如果改用 SwiftUI 模板

用 SwiftUI 模板的话，把 `iStoreOSApp.swift` 里的 `ContentView()` 换成：

```swift
WindowGroup {
    WebViewScreen()
}
```

再新建一个文件，把 `ViewController` 包成 `UIViewControllerRepresentable`：

```swift
import SwiftUI

struct WebViewScreen: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> ViewController { ViewController() }
    func updateUIViewController(_ uiViewController: ViewController, context: Context) {}
}
```

其余（Info.plist、签名、error.html）完全一样。
