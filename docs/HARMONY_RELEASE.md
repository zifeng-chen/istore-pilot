# 鸿蒙上架：前置条件与流程

> 目标是把鸿蒙版从「能装真机」推进到「能提审」。
> 配套：`docs/harmony-metadata-audit.md`（元数据预审）、`docs/HARMONY_SKILLS_SETUP.md`（编译期坑）。
> 本文不含任何账号口令、开发者 ID、内网地址 —— 那些只留在你本机。

## 0. 现在到哪一步了

| 环节 | 状态 | 缺什么 |
|---|---|---|
| 能编译 | ✅ `hvigorw assembleHap` 出 `.hap`（约 3.1 MB，buildMode=release） | — |
| 能装真机 | ✅ 调试证书签名有效，设备白名单 2 台，有效期到 2027-11-03 | — |
| **能上架** | ✅ 发布证书（type=2）+ `.app` + 邀请测试提审已打通（0.3.0、0.3.2 都提过） | 正式上架还差应用分类/公开测试材料 |

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
`.app` 用 `assembleApp` 出（见 §5），Mac 上的构建脚本已按发布签名配置好。

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

### 6.1 邀请测试（AppTest）发新版本 —— 实测可跑通的全套命令

每个新版本都要**新建一个测试版本**（旧版本提审后不能再换包）。
下面这一串按顺序跑，参数是 0.3.2 那次实测出来的：

```bash
cd harmony                      # CLI 只读当前目录的 .env
CLI="node ~/.workbuddy/skills/hmos-connect-api-cli-skill/scripts/connect-api-cli.js"
APPID=…; GROUP=…                # 测试组 id，`test group-list` 里拿

# ① 传包（-r 6 = 测试分发；bound:false 是正常的，包要另外挂到版本上）
$CLI upload file -a $APPID -f ../dist/istoreos-<版本>.app -r 6
#   → 记下 objectId

# ② 建测试版本
$CLI test version-create -a $APPID --test-type 3 --test-desc "<50 字以内>" -r 6
#   → versionId

# ③ 把包挂到版本上
$CLI test pkg-add -a $APPID --file-name istoreos-<版本>.app \
      --object-id "<objectId>" --distribute-mode 1
#   → pkgVersion（就是后面要的 pkgId）

# ④ 填元数据（body 见下）
$CLI test version-update -a $APPID --body ../build/testver.json

# ⑤ 等包检通过，再提审
$CLI publish compile-status -a $APPID --pkg-ids <pkgId>   # successStatus 变 0 才能提
$CLI test version-submit -a $APPID -v <versionId>
```

`version-update` 的 body（字段被报错逐个逼出来的，照抄即可）：

```json
{
  "versionId": "<版本 id>",
  "pkgId": "<pkgId>",
  "languages": [{
    "language": "zh-CN",
    "appName": "iStore Pilot",
    "appDesc": "≥2 个字，否则报 Description is necessary",
    "newFeatures": "本次更新",
    "deviceMaterials": [
      {"deviceType": 4,  "appIcon": "<图标 objectId>"},
      {"deviceType": 19, "appIcon": "<图标 objectId>"}
    ]
  }],
  "extInfo": {"privacyPolicy": "https://…（必须是能打开的 https）"},
  "openTestInfo": {
    "startTime": <ms>, "endTime": <ms>,
    "testTaskInfo": {
      "displayArea": "1",
      "startTime": <ms>, "endTime": <ms>,
      "groupInfos": [{"groupId": "<GROUP>", "bind": 1}]
    }
  }
}
```

三个只在踩过之后才知道的点：

1. **`startTime` / `endTime` 必须放在 `openTestInfo` 顶层**，只塞进 `testTaskInfo`
   会报 `openTestInfo.startTime: must not be null`（两层都写最稳）。
2. **`compile-status` 的 `successStatus`：`1` = 检查中，`0` = 通过。**
   刚上传就提审会报 `app package check from cfs not approved` —— 不是包坏了，
   等几分钟重查，变成 0 再提即可（实测约 4 分钟）。
3. **`deviceMaterials[].appIcon` 每个设备档都要带**，图标先 `upload file --no-bind`
   拿 objectId；`appDesc` 为空会报 `Description is necessary`。

提审成功后 `publish version-list` 里该版本 `state` 从 7 变 **12**（已提审）。
邀请码与测试组是**组级**的，跨版本复用；分享链接是**版本级**的（换版本要在
AGC 网页复制新链接），`test public-link-*` 这组接口对本应用无权限。

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
| **P0 材料** | `PRIVACY.md` 已写好，只差托管成网址；写商店文案；补平板/折叠屏截图；录演示视频 | 演示环境**已定方案 A**，代码已就绪（§6.5），只差真机录制 + 云端部署 |
| **P1 证书** | AGC 服务账号 → `.env` → 发布证书 + Profile（§4） | 需要你登录 AGC 建服务账号 |
| **P2 构建** | `assembleApp` + `harmony_pkg_verify --expect-type release` 全绿 | 依赖 P1 |
| **P3 提审** | 上传 `.app` → 填元数据 → `publish submit` | 依赖 P0 + P2 |

**建议顺序**：P1 先做（一次性，且能立刻验证 CLI 通路），P0 并行推进，P2/P3 在两者之后。

## 6.5 演示实例（方案 A，已实现）

审核员没有你的路由器，打开 App 是登录页。方案 A 是云上跑一个**只读演示实例**：
在真机上把接口响应录一遍，云端按路径回放。代码已就绪（`agent/demo.py` + `run.py`
的 `--record` / `--demo`），本地端到端验证通过。

### 为什么是录制回放

二十多个接口，手写假数据少一个字段界面上就是空列表 / undefined / 1970 年，
审核员一眼看出是假的。录制拿到的是真机真实返回，结构天然对得上。

### 用法

```bash
# ① 录制（真路由器上，起一个临时端口，不影响现有服务）
python3 run.py --record --demo-dir /tmp/demo --port 18444
#    然后正常用一遍 App（五个页签都点），GET 响应会自动脱敏落盘到 /tmp/demo/

# ② 回放（云主机上，Python 3.11 即可）
ISTORE_DEMO_PASSWORD='<演示口令>' python3 run.py --demo \
    --demo-dir /usr/share/istore-demo --host 0.0.0.0 --port 8443
#    前面挂 Nginx + 域名 + HTTPS
```

### 四条硬行为

| 行为 | 实现 |
|---|---|
| 脱敏 | 录制时把 MAC、内网/公网 IP、IPv6、主机名、订阅链接换成示例值；同一台设备跨接口保持同一个假 MAC（映射表 `_map.json`）；地址字符串里夹带的也会被正则替换 |
| 只读 | `POST/PUT/DELETE` 一律 **501** + `{"demo":true,"error":"演示环境只读…"}`，在进业务代码之前就挡掉，审核员点「禁网/重启」不会作用于任何环境 |
| 未命中 | 没录到的接口回 **503** + 明确文案，不静默返回空数组（那样界面显示「暂无设备」，审核员以为功能坏了） |
| 动态值 | 回放时把 `ts`/`uptime` 按「录制至今」整体平移，界面不会停在过去、`已运行 X 天` 不会永远不变 |

### 登录

演示口令走环境变量 `ISTORE_DEMO_PASSWORD`，不走 `config.json` 的用户口令。
审核材料里写明的「演示地址 + 演示口令」就用这一组。登录接口照常发 token。

### 验收标准

审核员只填一组地址+口令，能走完概览/设备/代理/拦截/设置五个页签，
每个页面有内容、没报错、没空白表格，写操作弹「演示环境只读」。

### 已实测

- 未登录访问 → 401；演示口令登录 → 200 + token
- 已录制接口 → 回放脱敏数据（MAC `02:00:...`、主机名 `演示设备 01`、内网 `192.168.1.x`）
- 未录制接口 → 503 明确文案；写操作 → 501 只读
- 真机 24 个只读 GET 接口全部 200，可完整录制

### 待办（留给你）

真机录制 + 云端部署这两步会碰到「启动临时端口服务」和「公网部署」，按约定
不自行操作，需要你点头或自己跑。录制数据目录 `agent/demo/` 已加入 `.gitignore`。

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
