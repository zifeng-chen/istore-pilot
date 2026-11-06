# 鸿蒙上架：前置条件与流程

> 目标是把鸿蒙版从「能装真机」推进到「能提审」。
> 配套：`docs/harmony-metadata-audit.md`（元数据预审）、`docs/HARMONY_SKILLS_SETUP.md`（编译期坑）。
> 本文不含任何账号口令、开发者 ID、内网地址 —— 那些只留在你本机。

## 0. 现在到哪一步了

| 环节 | 状态 | 缺什么 |
|---|---|---|
| 能编译 | ✅ `hvigorw assembleHap` 出 `.hap`（2.85 MB，buildMode=release） | — |
| 能装真机 | ✅ 调试证书签名有效，设备白名单 2 台，有效期到 2027-11-03 | — |
| **能上架** | ❌ | 发布证书（type=2）、`.app` 包、AGC 凭证、审核材料 |

一句话：**代码侧没阻碍，差的全是证书 + 材料 + 账号。**

实测证据（`scripts/harmony_pkg_verify.py` 在 Mac 上跑出来的）：

```
[包名]     com.izifeng.www.istorepilot
[版本]     0.1.7 (30)
[编译模式] buildMode=release  debug=False
[OK  ] 签名有效   type=debug  设备数=2
[FAIL] 签名类型是 debug，期望 release
```

编译模式已经是 release，但**签名类型是 debug** —— 这两个是两套东西，见 §1。

## 1. `.hap` vs `.app`：最容易搞错的一处

| | `.hap` | `.app` |
|---|---|---|
| 是什么 | 单个模块的安装包 | 上架包（App Pack），里面装若干 `.hap` |
| 用在哪 | `hdc install` 装真机调试 | AGC 上传、邀请测试、公开测试、正式上架 |
| 怎么出 | `assembleHap` | `assembleApp` |
| 签名要求 | 调试证书（type=1）够用 | **必须发布证书（type=2）** |

**坑**：AGC 只收 `.app`。直接传 `.hap` 会被拒；改后缀更不行。
本项目现在只有 `.hap`，所以「上传」这一步还没开始。

## 2. 两个官方 skill 已经装好

| skill | 位置 | 能干什么 |
|---|---|---|
| `app-metadata-audit-skill` | `~/.workbuddy/skills/app-metadata-audit-skill/` | 提审前对名称/图标/简介/截图/隐私政策做合规预审，输出 🔴/🟡/🟢 分级 |
| `hmos-connect-api-cli-skill` | `~/.workbuddy/skills/hmos-connect-api-cli-skill/` | 内嵌 `connect-api-cli.js`（v1.1.4，本机 Node 22 直接跑）：登录、建应用、证书/Profile、`assembleApp`、上传 `.app`、提审、ACL、域名 |

装的时候发现**上游仓库缺了三个 `references/` 文件**（`workflows.md` / `commands.md` /
`troubleshooting.md`）。已做补偿：

- `references/commands-auto.md` —— 用 `--help` 递归抓了 92 个命令的完整选项（42 KB）
- `scripts/gen_cmd_ref.py` —— CLI 升级后重跑一条命令就能刷新（`--check` 可校验是否同步）
- `references/README.md` —— 写清楚缺了什么、怎么自己拼

也就是说：**参数查询不缺，缺的是"流程 A–G 的逐步命令序列"**，那部分靠本文 §4–§6 补。

## 3. 一次性准备（账号侧，只能你做）

### 3.1 AGC 服务账号

在 AppGallery Connect 控制台 → 用户与访问 → 服务账号，创建后下载 `*_private.json`。
**不要用 OAuth 模式** —— 它需要浏览器人工授权，脚本跑不了。

### 3.2 工程根目录的 `.env`

CLI 只读**当前工作目录**的 `.env`（无 BOM）。`harmony/` 下建一份，加入 `.gitignore`：

```env
# 服务账号模式（推荐）
AGC_AUTH_MODE=service_account
AGC_SA_CREDENTIALS=./<你的>_private.json

# DevEco 安装目录（签名/构建/hdc 都要）
# macOS 示例形态：/Applications/DevEco-Studio.app
DEVECO_HOME=<DevEco 安装目录>
```

`.env`、`.certs/`、`*.p12`、token 缓存**都不入库**。

### 3.3 验证凭证

```bash
cd harmony
node ~/.workbuddy/skills/hmos-connect-api-cli-skill/scripts/connect-api-cli.js auth status
```

期望 `Token cached: yes` 或走一次 `auth login` 成功。当前跑会报
`Missing AGC credentials` —— 属预期。

## 4. 发布证书 + Profile（流程 B，type=2）

在 **Mac** 上跑（`DEVECO_HOME` 在那边，`csr-generate` 要用 SDK 里的工具）。
`CO=/Users/<你>/istore-pilot/harmony`。

```bash
CLI="node $HOME/.workbuddy/skills/hmos-connect-api-cli-skill/scripts/connect-api-cli.js"

# ① 生成本地密钥对 + CSR（密码由你现场输入，不写进脚本、不落盘）
$CLI provision csr-generate --alias istore --pwd '<你定的口令>' --sdk-path "$DEVECO_HOME/Contents/sdk"
#   → .certs/<随机串>/key_*.p12 / *.csr，记住这个目录

# ② 用 CSR 申请发布证书（--cert-type 2 = release）
$CLI provision cert-create --csr .certs/<随机串>/*.csr --cert-name istore-release --cert-type 2
#   → 返回 certId；下载地址立刻落盘到 cert_*.cer

# ③ 申请发布 Profile（--type 2 不需要设备白名单）
APPID=$($CLI publish app-id -p com.izifeng.www.istorepilot | jq -r '.appids[0].value')
$CLI provision profile-create --name istore-release --type 2 --cert <certId> -a "$APPID"
#   → 返回 provisionId；下载地址立刻落盘到 profile_*.p7b
```

一套完整的发布签名材料 = 同目录的 `key_*.p12` + `cert_*.cer` + `profile_*.p7b`。

### 4.1 写进 `build-profile.json5`

`signingConfigs` 目前是空的（本地仓库这份是干净的，签名配置只在你 Mac 上）。
发布套需要 `material` 指向上面三个文件，密码用 CLI 加密后填：

```bash
# 把 P12 密码转成 build-profile.json5 要的密文（必须带 --config-dir，否则在 Windows 上会写到 CWD）
$CLI provision encrypt-pwd --pwd '<P12 口令>' --config-dir ~/.ohos/config
```

产出填到 `app.signingConfigs[0]` 的 `material.storePassword` / `keyPassword`。
**注意**：`mac.py sync` 会跳过 `build-profile.json5`，所以这份配置只存在 Mac 上，不会被仓库覆盖（这是有意为之，见 memory）。

## 5. 构建 `.app`

```bash
cd harmony
export DEVECO_SDK_HOME="$DEVECO_HOME/Contents/sdk"
HV="$DEVECO_HOME/Contents/tools/hvigor/bin/hvigorw"

"$HV" --mode module -p product=default -p buildMode=release assembleApp --no-daemon
```

**四条硬规则**（违反就会打出错的包还声称成功）：

1. `-p` 必须写 **`buildMode`**（驼峰）。写成 `buildmode` 会被**静默忽略**，
   命令照样成功，但产物是 debug。
2. `buildMode=release` 只决定**编译模式**，不决定签名类型。
   发布证书 + `assembleApp` + `.app` 三个条件缺一不可。
3. `DEVECO_SDK_HOME` 必须先 `export`。只校验文件存在不够，hvigor 不会从
   `DEVECO_HOME` 自己推导这个变量。
4. **构建完必须验产物**，见下。

### 5.1 验产物（别跳过）

```bash
# 在 Mac 上
python3 scripts/harmony_pkg_verify.py entry/build/default/outputs/default/entry-default-*.app \
        --expect-type release
```

要同时看到：

- `[编译模式] buildMode=release  debug=False`
- `[OK] 签名有效 type=release`
- `[对齐包名/版本] 一致`

任何一条红，**不要上传**。

## 6. 上传 + 提审（流程 C）

```bash
# 上传 .app（默认会上报到 AGC；-r 6 是测试分发，1 是全量发布）
$CLI upload file -a "$APPID" -f <path>/entry-default-release.app -r 1

# 提交审核
$CLI publish submit -a "$APPID" --remark "0.1.7 首个鸿蒙版本"
```

上传后 AGC 会跑编译/解析（`publish compile-status` 查），通过后才能提审。

## 7. AGC 上架 13 步里，哪些能自动

| 步骤 | 能否自动 | 说明 |
|---|---|---|
| 注册华为开发者账号、实名 | ❌ 人工 | 一次性 |
| 创建项目 / 应用 | ✅ | `publish app-create`；**应用分类必须人工选**（官方刻意不放 API，防批量误设） |
| 创建服务账号、下载私钥 | ❌ 人工 | 一次性，之后全自动 |
| 申请发布证书 | ✅ | §4 |
| 申请发布 Profile | ✅ | §4 |
| 生成 `.app` | ✅ | §5 |
| 上传包 | ✅ | §6 |
| 填写元数据（名称/简介/截图/隐私政策） | 🟡 半自动 | 文案可以脚本灌，但**隐私政策网址、截图、演示视频**要人工准备 |
| 选择应用分类 | ❌ 人工 | 官方无 API |
| 提交审核 | ✅ | §6 |
| 等审核 / 处理驳回 | ❌ 人工 | — |
| 分阶段发布 | ✅ | `publish phased-release` |
| 上架/下架 | ✅ | `publish submit` + 时间参数 |

**能自动 9 步，4 步必须人工**：实名、服务账号、应用分类、审核沟通。

## 8. 分阶段计划

| 阶段 | 做什么 | 阻塞点 |
|---|---|---|
| **P0 材料** | `PRIVACY.md` 已写好，只差托管成网址；写商店文案；补平板/折叠屏截图；录演示视频 | 需要你定演示环境方案（见元数据报告 §4） |
| **P1 证书** | AGC 服务账号 → `.env` → 发布证书 + Profile（§4） | 需要你登录 AGC 建服务账号 |
| **P2 构建** | `assembleApp` + `harmony_pkg_verify --expect-type release` 全绿 | 依赖 P1 |
| **P3 提审** | 上传 `.app` → 填元数据 → `publish submit` | 依赖 P0 + P2 |

**建议顺序**：P1 先做（一次性，且能立刻验证 CLI 通路），P0 并行推进，P2/P3 在两者之后。

## 9. 从 SKILL.md 抄下来的硬红线

1. **不要搜盘找 DevEco**。问到路径就写进 `.env`，不要 `where` / `mdfind` / 遍历 `Program Files`。
2. **删除类操作（证书/Profile/设备）每次都要确认对象名称 + id**。"随便删一个"不算确认。
3. **时间戳一律按毫秒换算北京时间**，不要 `toISOString()` 直接给用户看（那是 UTC，差 8 小时）。
4. **不要打印** `.env`、token、`.pwd`、P12 密码。
5. **域名更新消耗配额**，执行前先 `domain config` 看余量。
6. `encrypt-pwd` 必须带 `--config-dir`，否则在 Windows 上会写到 CWD 的 `.ohos/config`。

## 10. 与本仓库其他文档的关系

| 文档 | 管什么 |
|---|---|
| 本文 | 上架：证书、`.app`、上传、提审 |
| `docs/harmony-metadata-audit.md` | 商店元数据的合规预审（名称/图标/截图/隐私/演示视频） |
| `docs/HARMONY_SKILLS_SETUP.md` | 两个知识包（离线 API 声明、ArkTS 规则）的装法 |
| `docs/ARKTS_PITFALLS.md` | 编译期语法坑 |
| `docs/UI_REVIEW.md` | 界面一致性审查 |
