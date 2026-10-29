# iStore Pilot

**iStoreOS / OpenWrt 路由器的原生管理客户端，外加一个跑在路由器上的轻量 Agent。**

手机上装 App，局域网或外网直连路由器，看实时状态、管设备、切代理节点、查拦截日志。
界面是纯原生的（Java / ArkTS / SwiftUI），不是 WebView 套壳。

```
┌──────────────┐        HTTP :8443         ┌─────────────────┐
│  三端客户端   │ ────────────────────────> │  istore-agent   │
│ Android      │      /api/v1/*            │  (Python 3)     │
│ HarmonyOS    │ <──────────────────────── │                 │
│ iOS          │        JSON               └────────┬────────┘
└──────────────┘                                   │ ubus / uci / nft / procfs
                                          ┌────────▼────────┐
                                          │   iStoreOS 本体  │
                                          │ OpenClash / AGH │
                                          └─────────────────┘
```

---

## 快速开始

到 [**Releases**](https://github.com/zifeng-chen/istore-pilot/releases) 下载，按需要选：

| 文件 | 装在哪 | 说明 |
|---|---|---|
| `istore-pilot_x.y.z-N.run` | 路由器 | **推荐**。单文件，`sh` 一下就装完，不用 opkg、不用联网 |
| `luci-app-istore-agent_x.y.z-N_all.ipk` | 路由器 | 传统方式，走 opkg（软件包页面上传安装） |
| `istoreos-x.y.z.apk` | Android 手机 | 连路由器用 |

路由器端，两种方式**选一种**：

```sh
# 方式 A：.run（推荐）—— 把文件传到路由器后执行
sh istore-pilot_0.1.2-11.run --check    # 先只检查环境，不改任何文件
sh istore-pilot_0.1.2-11.run            # 安装或升级，保留现有配置

# 方式 B：ipk
opkg update && opkg install python3
opkg install luci-app-istore-agent_0.1.2-11_all.ipk
```

`.run` 的其它用法：

```sh
sh istore-pilot_0.1.2-11.run --uninstall   # 卸载程序，保留密码与配置
sh istore-pilot_0.1.2-11.run --purge       # 卸载并清除全部配置
sh istore-pilot_0.1.2-11.run --force       # 已用 opkg 装过时，改由本包接管
```

装完打开 `http://<路由器IP>:8443`。首次安装的随机密码在路由器上查看：

```sh
cat /etc/istore-agent/INITIAL_PASSWORD
```

Android：装 APK，或者直接在装好插件的路由器上下载
`http://<路由器IP>/istore-agent/istoreos-0.1.2.apk`（插件自带这个文件）。

> `.run` **不会改动任何网络、防火墙、DHCP、DNS 配置**，装的过程中现有网络不受影响。
> 已有 `/etc/config/istore-agent` 时一律保留，不会把 `bind` 覆盖成 `0.0.0.0`。

详细说明见 [`docs/install.md`](docs/install.md)。

---

## 一、项目主旨

路由器自带的管理后台是给「配置」用的，不是给「查看」用的。

日常最想知道的几件事 —— 现在网速多少、谁在占带宽、这台设备是什么、代理走没走、
今天拦了多少广告 —— 都埋在好几层菜单里，手机上打开还很别扭。第三方 App 要么只支持
OpenWrt 原版，要么读不到 OpenClash 和 AdGuard Home 的内部状态。

iStore Pilot 想做的是**一个合格的手机端仪表盘**：

- **快**：进去就有数，不是先转圈再出数
- **准**：数字来自内核和服务的真实状态，不是估算
- **像原生**：手势、动画、深色模式都跟系统一致，不是网页套壳
- **不越权**：只读为主，改配置一律走「确认 + 超时自动回滚」

一句话：**把路由器的状态，做成手机上能一眼看懂的东西。**

## 二、它解决什么问题

| 痛点 | iStore Pilot 的做法 |
|---|---|
| 后台层层菜单，手机上难用 | 四个页签：概览 / 设备 / 代理 / 设置，一屏看完 |
| 设备列表只有 IP 和 MAC，看不出是谁 | 4 万条 OUI + 主机名规则识别品牌、类型、型号，显示「绿米 · 插座 · Aqara」 |
| 开了 OpenClash 后全是 `198.18.x.x` fake-ip | 从 Clash `/connections` 的 `metadata.sourceIP` 反查 `host`，还原真实域名 |
| 设备关屏后显示离线 | 在线判定四路交叉（邻居表 / 字节增长 / conntrack / 主动 ping），不再误报 |
| 不知道哪个 App 在吃流量 | 18 万条域名特征库反推应用，路由器在转发路径上拿不到进程信息 |
| 改网络配置断网只能靠重启救 | 配置事务：60 秒内不确认自动回滚，客户端永远能回来 |
| 只支持 OpenWrt 原版 | OpenClash 与 Passwall 双后端抽象，同一套接口 |

## 三、系统架构

三端不直接接触路由器，所有能力由 Agent 统一暴露成 `/api/v1/*`：

- **Agent**（`agent/`）跑在路由器上，Python 3 标准库，零第三方依赖。
  它把 `ubus` / `uci` / `nft` / `procfs` / `/tmp/dhcp.leases` 这些底层数据源，
  整理成一份稳定的 JSON 契约。
- **客户端**（`android/` `harmony/` `ios/`）只认这份契约。三端看到的数据必然一致，
  因为它们请求的是同一份。
- **Web 控制台**（`web/`）是同一套接口的浏览器版（PWA），给不想装 App 的场景。

这样设计的好处是：换代理后端、改数据源、加字段，只动 Agent，
三端不需要各改一遍。

详细设计取舍见 [`docs/architecture.md`](docs/architecture.md)。

## 四、功能

| 页签 | 内容 |
|---|---|
| **概览** | 主机名/系统/内核/在线时长；CPU·内存·磁盘三个环；负载、温度、进程数；WAN 实时上下行（含曲线）；网口状态；重启/关机 |
| **设备** | 在线/总数/已禁网统计；实时总流量；搜索；在线离线分组；按实时流量排序 |
| 　└ 详情 | 品牌/类型/型号；实时上下行 + 累计流量；正在访问的域名（带代理链和命中规则）；连接明细；改备注 / 禁网 / 固定 IP / 唤醒 |
| **代理** | OpenClash 与 Passwall 谁在跑；引擎与节点数；运行模式切换；节点分组折叠 + 一键测速；配置文件切换；订阅管理 |
| **拦截** | AdGuard Home 状态与模式；拦截率环形；规则数与更新计划；拦截 Top 5 与完整日志；运行体检；接管全网 / 退出接管 |
| **设置** | 连接信息；WAN/LAN 明细（含 IPv6 全局地址）；改密码；配置备份与恢复；固件与软件包更新；外观 |

## 五、仓库结构

三端源码各自独立成顶层目录，互不嵌套，任何一端都可以单独 clone / 单独构建。

```
istoreOS/
├── android/          Android 客户端      Java + AndroidX/Material
├── harmony/          HarmonyOS NEXT      ArkTS + ArkUI（Stage 模型）
├── ios/              iOS 客户端          SwiftUI，无 WebView
├── agent/            路由器端 Agent      Python 3 标准库，零依赖
├── web/              浏览器控制台        HTML/CSS/JS（PWA）
├── deploy/           ipk 打包与部署      Python + shell
├── scripts/          构建/版本/运维脚本   Python + shell
├── docs/             文档与成品截图
└── dist/             构建产物（不入库，.gitignore 已排除）
```

| 模块 | 文件数 | 行数 |
|---|---:|---:|
| `agent/` | 20 个 .py | 9,001 |
| `android/` | 40 个 .java | 14,123 |
| `harmony/` | 27 个 .ets | 7,806 |
| `ios/` | 25 个 .swift | 6,859 |
| `web/` | 2 个 .js | 815 |
| `deploy/` + `scripts/` | 30 个 .py | 3,723 |

## 六、构建

### Android

```bash
export JAVA_HOME="<JDK 17>"
export ANDROID_HOME="<Android SDK>"
export JAVA_TOOL_OPTIONS="-Dfile.encoding=UTF-8"   # 中文文案必须锁 UTF-8
cd android
gradle assembleRelease
```

产物 `app/build/outputs/apk/release/app-release.apk`。minSdk 24 / targetSdk 34。

签名需要 `android/keystore.properties` 与 `android/istoreos.keystore`，
**两者都不入库**（`.gitignore` 已排除），格式见 [`docs/clients.md`](docs/clients.md)。

### HarmonyOS

DevEco Studio 打开 `harmony/` 直接运行，或命令行：

```bash
cd harmony
hvigorw --mode module -p product=default -p buildMode=release assembleHap
```

`entry/src/main/resources/base/profile/network_config.json` 里的
`cleartextTrafficPermitted: true` **必须保留** —— 接口是明文 HTTP 的 `:8443`，
去掉就连不上。

### iOS

```bash
cd ios
xcodebuild -project IStorePilot.xcodeproj -scheme IStorePilot \
           -configuration Release -destination 'generic/platform=iOS' \
           -archivePath build/IStorePilot.xcarchive archive
```

`Info.plist` 已放开 `NSAllowsArbitraryLoads` 与本地网络权限。
`.xcodeproj` 由 `ios/gen_project.py` 生成 —— **增删 `.swift` 后必须重跑**，
否则报 `cannot find X in scope`。

## 七、部署 Agent

Agent 是一组 Python 文件，只依赖标准库，路由器自带 Python 3.11 就能跑。

```bash
export ROUTER_PW='<路由器 SSH 口令>'
python deploy/deploy.py            # 开发期：直接推文件 + 重启服务
```

正式安装有两条路，**装的是同一份文件**（`.run` 直接复用 `build_ipk.py` 的暂存逻辑）：

```bash
# A. .run 自解压包（推荐，用户装就这一个文件）
python deploy/build_run.py               # 产出 dist/istore-pilot_<版本>-<修订>.run
python deploy/build_run.py --no-apk      # 不含 APK，小 5 MB
python deploy/build_run.py --rev 12      # 指定修订号

# B. ipk（走 opkg，可被「软件包」页面管理）
python deploy/build_ipk.py                 # 产出 dist/luci-app-istore-agent_<版本>_all.ipk
python deploy/build_ipk.py --with-apk      # 顺带把 APK 塞进包内，网页端可直接下载
ROUTER_PW='...' python deploy/install_ipk.py
```

装完在 LuCI「服务 → iStore Pilot」里能看到运行状态、改端口、下载 App。

> ### ⚠️ 三件必须注意的事
>
> **1. 监听地址**：Agent 默认 `0.0.0.0:8443`。如果不打算走公网访问，
> 请把 `/etc/config/istore-agent` 的 `bind` 改成 LAN 地址
> （例如 `192.168.1.1`），避免管理面暴露在 WAN / IPv6 公网侧。
>
> **2. 打包顺序**：`build_ipk.py` 直接从项目根 `web/` 复制前端资源。
> 先打包后改 web，会导致包内永远是旧文件，装完还会把手工上传的新文件覆盖回去。
> **正确顺序：改代码 → build_ipk / build_run → install。**
>
> **3. `.run` 与 ipk 互斥**：两种装法不能并存，否则 `opkg remove` 会把 `.run`
> 装进去的程序文件一起删掉，而 opkg 记录里还写着「已安装」，后续升级彻底错乱。
> `.run` 检测到 opkg 包时会拒绝执行，需要显式 `--force` 才接管。

## 八、配置与口令

仓库里**不含任何真实口令**。所有敏感值都从环境变量注入：

| 变量 | 用途 | 谁用 |
|---|---|---|
| `ROUTER_PW` | 路由器 SSH 口令 | `deploy/deploy.py`、`scripts/rsh.py`、各 `check_*.py` |
| `AGENT_PASSWORD` | Agent 登录口令（留空则沿用 `ROUTER_PW`） | `deploy/deploy.py` |
| `AGENT_ADGUARD_PASSWORD` | AdGuard Home 管理口令 | `agent/config.py` 默认值 |
| `AGH_PW` | AGH 明文口令 | `scripts/agh_*.sh` |
| `AGH_PWHASH` | AGH 的 bcrypt 口令哈希 | `scripts/agh_password.sh` |
| `ROUTER_HOST` / `ROUTER_PORT` / `ROUTER_USER` | SSH 目标 | 部署与运维脚本 |

`deploy/AdGuardHome.yaml` 里的 `password` 是占位符，部署前需换成自己的 bcrypt 哈希：

```bash
htpasswd -bnBC 10 "" '你的口令' | tr -d ':\n' | sed 's/$2y/$2b/'
```

Agent 自己的配置文件在 `/etc/istore-agent/config.json`，可用
`ISTORE_AGENT_CONFIG` 环境变量指向别处（便于本地调试）。

### 接入方式（有线 / 无线）的数据来源

「这台设备是插网线还是连 WiFi」**软路由自己看不到** —— AP 是桥接的，
无线和有线都桥到同一根网线（`brctl showmacs br-lan` 里所有 MAC 都在同一个 port）。
唯一的准确来源是 AP 的接入设备表，所以要配一段：

```json
"ap": {
  "enabled": true,
  "driver": "zte",                  // 目前只有 zte（中兴 ZXSLC 系列）
  "user": "admin",
  "password": "你的 AP 管理口令",
  "hosts": ["192.168.1.165"]      // Mesh 的话把主、从都写进来
}
```

- 配了：设备列表显示 `无线 2.4G` / `无线 5G` / `有线`，是事实
- 没配、换了别的牌子、口令错：自动退回「私有 MAC + 设备类型」推断，
  显示 `无线(推测)`；推断不出来的不显示。**不会误报**，也不会因为 AP 换了就崩
- 硬失败（口令错 / 不是这个牌子 / 地址不通）连撞三次就退到 30 分钟一轮，
  不会拿别人的路由器当靶子打

要接新厂商（TP-Link / 小米 / OpenWrt…）：照 `agent/zte.py` 的样子写一个模块，
暴露 `settings() / ensure() / access_map() / status()` 四个函数，
再到 `agent/ap.py` 的 `DRIVERS` 里登记一行即可，上层和客户端都不用改。
各家差异只有「怎么登录、客户端列表长什么样」这一步。

## 九、版本管理

三端 + Agent 共用一个版本号：

```bash
python scripts/bump_version.py          # 看当前版本与下一位
python scripts/bump_version.py --next   # 自增并同步四处
```

规则：`0.1.0` 起，**第三位满 10 进位到第二位**（没有 `0.1.10`，是 `0.2.0`）。
`versionCode` 单调递增、与语义版本解耦 —— Android 不接受版本号回退。

`bump_version.py` 同步的四个位置：`harmony/AppScope/app.json5`、
`android/app/build.gradle`、`ios/gen_project.py`、`agent/server.py`。

当前版本见 [`CHANGELOG.md`](CHANGELOG.md)。

## 十、截图

真机截图，不是效果图。

| | | |
|---|---|---|
| ![](docs/screenshots/final/01_home.png) | ![](docs/screenshots/final/02_devices.png) | ![](docs/screenshots/final/03_proxy.png) |
| 概览 | 设备 | 代理 |
| ![](docs/screenshots/final/04_adblock.png) | ![](docs/screenshots/final/05_settings_top.png) | ![](docs/screenshots/final/09_home_dark.png) |
| 拦截 | 设置 | 深色模式 |

## 十一、文档

| 文档 | 内容 |
|---|---|
| [`CHANGELOG.md`](CHANGELOG.md) | 更新日志，逐版本记录 |
| [`docs/install.md`](docs/install.md) | 路由器端安装详解：`.run` 与 ipk 两种方式、卸载、排错 |
| [`docs/architecture.md`](docs/architecture.md) | 架构与关键设计决策、踩过的硬坑 |
| [`docs/api.md`](docs/api.md) | Agent 接口参考 |
| [`docs/clients.md`](docs/clients.md) | 三端打包、安装、签名、真机调试细节 |
| [`PLAN.md`](PLAN.md) | 功能规划与早期设计取舍 |
| `harmony/README.md`、`ios/README.md` | 各端工程内说明 |

## 十二、许可

未指定许可证。代码公开可见，但未授予使用、修改、分发许可，如需引用请联系作者。
