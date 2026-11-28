# 代码审查报告 · 2026-11-28

> 范围：agent（Python）· 鸿蒙（ArkTS）· Android（Java）· iOS（Swift）· scripts / deploy
> 方式：自动化体检 + 人工阅读关键路径 + 跨端一致性比对
> 结论：**工程质量高于同类独立项目，没有发现可利用的注入或越权漏洞**；
> 主要问题集中在「安全传输」「资源无界增长」「三端手工同步」三类。

## 0. 规模与体检

| 目录 | 文件 | 行数 |
|---|---|---|
| agent | 29 | 15,180 |
| harmony/ets | 48 | 19,232 |
| android/java | 50 | 19,249 |
| ios/swift | 31 | 11,469 |
| scripts | 68 | 8,877 |
| deploy | 7 | 1,844 |

```
lint_style.py    269 个文件，0 error / 0 warn
dead_code.py     0 处候选
check_version.py 0.4.5 / versionCode 49 · 6 处一致
```

最大的几个文件（维护成本集中点）：

```
2943  harmony/.../ProxyPage.ets
2599  android/.../ProxyFragment.java
1854  agent/adblock.py
1660  harmony/.../SettingsPage.ets
1650  agent/devices.py
1630  agent/proxy.py
```

## 1. 必修（按风险排序）

### 1.1 Agent 走明文 HTTP —— 令牌与口令在链路上裸奔

```
agent/server.py   HTTPServer，:8443，无 TLS
客户端            http://192.168.100.1:8443  /  经反代 https://…
```

令牌本身的实现是**合格的**（HMAC-SHA256、`exp` 到期、`hmac.compare_digest`、
改口令时 `rotate_key()` 让旧令牌立刻失效），问题只在传输层：

- 直连内网时，同网段任何设备抓包即可拿到 Bearer 令牌，再用 7 天
- 走群晖反代时 HTTPS 终结在反代，反代到路由器这一段仍是明文（同一台机器，可接受）

**建议**：二选一 ——
(a) 反代强制 HTTPS 并在 agent 侧拒绝非内网来源（已有 `_origin_ip()`，加白名单即可）；
(b) 给 `HTTPServer` 包一层 `ssl.SSLContext`，客户端三端都改 `https://`（工作量大，可排期）。

### 1.2 `access.log` 没有轮转（本次新引入）

```python
agent/server.py:165   with open("/etc/istore-agent/data/access.log", "a") ...
```

每次 JSON 响应记一行。按 5 秒轮询估算：单设备 ≈ 17k 行/天 ≈ 1.2 MB/天，
三台设备一个月 100 MB 左右，写在 overlay/闪存上。

**建议**：写入前判断大小，超 512 KB 就 `access.log → access.log.1`（只留一份）。
改动约 6 行。

### 1.3 广告拦截查询日志 2.6 GB（运维，非代码）

```
/etc/AdGuardHome/data/querylog.json   2,686,579,527 B
```

不影响解析（实测 0.00s），但持续写盘。属"删数据"操作，需你确认。

### 1.4 Android 6 个页面 `postDelayed` 未 `removeCallbacks`

```
SubscriptionActivity  AdblockFragment  BaseFragment
SecurityFragment      SettingsFragment WebActivity
```

回调内部都有 `if (isAdded())` 守卫，**不会崩**，但页面销毁后消息仍留在队列里
直到触发，属于轻微泄漏。修法：`onDestroyView` 里 `handler.removeCallbacksAndMessages(null)`。

## 2. 建议改

### 2.1 `shell=True` 的通用工具函数太宽

```python
agent/appfilter.py:45   def _sh(cmd): subprocess.run(cmd, shell=True, ...)
agent/speedtest.py:83   def _run(cmd): subprocess.run(cmd, shell=True, ...)
```

当前**所有调用点都是常量字符串**（我逐个核对过：uci key 是内部常量，
`serverId` 只进 URL 且 quote 过），所以现在没有注入。

但这两个函数是全项目唯一的"能执行任意命令"的口子，将来谁拼一个变量进来就是 RCE。
建议改成接受 `list[str]`，或至少加注释禁止拼接。

### 2.2 三端 UI 规格手抄，已经出过两次事故

这次测速功能的两个 bug 都属这一类：

- `@Builder` 按值传参不刷新 → 数值永远是 `—`
- 三端字号 33/33/22 不一致

现在的"三端一致"靠人肉对齐，没有机器保障。建议：

1. 建 `docs/UI_SPEC.md`：色板、字号阶梯、圆角、间距，作为唯一事实源
2. 加一个校验脚本，比对三端 Theme 文件里的常量（鸿蒙 `Theme.ets` / Android `Ui.java` / iOS `Theme.swift`），不一致就报错

### 2.3 轮询没有退避

三端都是固定间隔（概览 5s、测速 1s、设备 3s）。弱网时三端会同时重试，
把一次抖动放大成持续拥塞。建议失败后指数退避（5→10→20s，成功即复位）。

### 2.4 版本号同步没进 CI

6 处 + 网站 + 安装包，全靠人记得跑 `bump_version.py` / `check_version.py`。
建议 `pre-push` hook 里跑一次 `check_version.py`，不一致直接拒绝推送。

### 2.5 鸿蒙 `setFontScale` 的时序

`fs()` 依赖 `EntryAbility.onCreate` 里读到的 `fontSizeScale`。若某个页面在
`onCreate` 完成前就完成首帧布局，会按 1.0 渲染一帧再跳变。实际几乎不可见，
但可以在 `Theme` 里给个惰性兜底（首次调用 `fs()` 时读一次系统配置）。

## 3. 观察项（不改也行）

| 项 | 现状 |
|---|---|
| 快照缓存无全局淘汰 | 键按路径固定，只有 `/speedtest/` 带时间戳且已跳过；`traffic` 等高频接口键稳定，不会堆积 |
| Android 定时器 | 回调有 `isAdded()`，只影响消息队列驻留 |
| iOS 强制解包 | `try!` / `as!` / `.first!` 共 0 处 |
| 裸 `except:` | 0 处 |
| 硬编码口令 | 0 处（`deploy.py` 里那处是提示文案） |
| 鸿蒙定时器 | 10 个文件 `setInterval`，10 个 `clearInterval`，成对 |

## 4. 值得肯定的地方

- **鉴权设计**：只认 Authorization 头（明确拒绝 `?token=` 防止令牌进日志）、
  令牌带 `exp`、`jti` 预留吊销、改口令轮换签名密钥
- **登录防护**：单 IP 失败计数 + 全局失败上限 + 惩罚 TTL（429 而非 403）
- **错误处理纪律**：0 个裸 `except`，失败路径都返回明确文案而不是静默
- **注释质量**：大量"为什么这么写"的历史原因（如 `_origin_ip` 为何要读 XFF、
  `ping` 为何不能用写死版本号），对后来者非常友好
- **体检常态化**：lint / dead code / 版本一致性三个脚本能拦住大部分低级问题

## 5. 建议的处理顺序

```
本次必修    1.2 access.log 轮转（6 行，我自己引入的）
确认后执行  1.3 AGH querylog 清理（删数据，需你点头）
排期        1.1 传输层（要么白名单，要么 TLS）
排期        2.2 UI_SPEC + 校验脚本（防第三次事故）
顺手        1.4 Android removeCallbacks、2.3 退避
```

—— 报告结束。需要我直接动手的那几项，说一声。
