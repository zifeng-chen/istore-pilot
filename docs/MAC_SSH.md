# 连那台 Mac（构建机）

> 一句话：**SSH，用户 `chen`，密钥 `~/.ssh/id_ed25519_mac`，IP 会变，用 `mac.py find` 现查。**

## 当前是什么

| 项 | 值 |
|---|---|
| 主机名 | `chendeMacBook-Pro.local`（mDNS 名，比 IP 稳） |
| 局域网地址 | `192.168.100.191`（**DHCP，会变**；11-14 还是 .236，再往前 .227） |
| 系统 | macOS 27.2.1 / arm64 / Xcode 27.2 / DevEco Studio（鸿蒙 SDK 6.0.31） |
| 端口 | 22 |
| 账号 | `chen` |
| 认证 | 密钥 `~/.ssh/id_ed25519_mac`（openssh 私钥，**无口令**）；没有密钥时用环境变量 `MAC_PW` |

## 怎么找到它（IP 变了先跑这个）

```bash
python scripts/mac.py find          # 扫 192.168.100.1-254 的 22 端口，再用 SSH 认机器
python scripts/mac.py find 192.168.1   # 换网段就跑这个
```

输出长这样，认 `chendeMacBook-Pro.local` 那行：

```
发现 4 台：
  192.168.100.1   （登不上：AuthenticationException）
  192.168.100.191 chendeMacBook-Pro.local / 27.2.1
```

其它办法：

- Mac 上自己看：`ipconfig getifaddr en0`（Wi-Fi）或 `ipconfig getifaddr en1`
- 路由器设备表里找主机名（这台机器有时不报 hostname，就只能扫端口）
- `ping chendeMacBook-Pro.local` —— Windows 要装了 Bonjour 才解析 mDNS

## 四条命令

`scripts/mac.py` 只有这一个依赖：`paramiko`。全部用法：

```bash
python scripts/mac.py ping                        # 连通性 + 环境自检（版本/Xcode/DevEco/签名）
python scripts/mac.py run  "cd ~/x && make"       # 远端执行，实时回显
python scripts/mac.py put  local.txt /Users/chen/x/local.txt
python scripts/mac.py get  /Users/chen/x/out.bin ./out.bin
python scripts/mac.py sync ./harmony /Users/chen/istore-build/harmony
```

`susy` 时可以用环境变量覆盖，不用改代码：

```bash
MAC_HOST=192.168.100.191 MAC_USER=chen MAC_KEY=~/.ssh/id_ed25519_mac \
  python scripts/mac.py ping
```

| 变量 | 默认 | 说明 |
|---|---|---|
| `MAC_HOST` | `192.168.100.227`（旧值，多半不通） | 现查现填 |
| `MAC_PORT` | `22` | |
| `MAC_USER` | `chen` | |
| `MAC_KEY` | `~/.ssh/id_ed25519_mac` | 存在就优先用密钥 |
| `MAC_PW` | 空 | 只在没密钥时用；也可当密钥口令 |

## 搬到别的项目

**方式 A（推荐）**：把 `scripts/mac.py` 整个复制过去。单文件、无项目耦合，改一下默认 `HOST` 或一律用 `MAC_HOST=`。

**方式 B**：直接用系统 ssh，不写代码：

```bash
ssh -i ~/.ssh/id_ed25519_mac chen@192.168.100.191 'uname -a'
scp -i ~/.ssh/id_ed25519_mac -r ./dist chen@192.168.100.191:/Users/chen/x/
```

**方式 C**：自己写 10 行 paramiko：

```python
import paramiko
c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect("192.168.100.191", 22, "chen", key_filename=str(Path.home()/".ssh/id_ed25519_mac"),
          allow_agent=False, look_for_keys=False)
_, out, _ = c.exec_command("hostname && sw_vers -productVersion")
print(out.read().decode())
```

## 两个会踩的坑

1. **Git Bash 会改写以 `/` 开头的参数**（把 `/Users/chen` 变成 `C:/Program Files/...`）。
   远程绝对路径前加 `MSYS_NO_PATHCONV=1`：
   ```bash
   MSYS_NO_PATHCONV=1 python scripts/mac.py sync ./harmony /Users/chen/x/harmony
   ```
   `mac.py` 的 `_norm_remote()` 也会挡一层（检测到盘符就报错退出，不会静默传错地方）。
2. **`sync` 会跳过 `build-profile.json5`**：那是 Mac 上的签名配置（含 keystore 密文），
   传过去会把签名冲掉，下次出包就成了 unsigned。要改构建配置去 Mac 上改。

## 顺带记着

- 这台 Mac 上跑着 **鸿蒙模拟器**（`Emulator -start 'Mate X7'`，hdc 起来后是 `127.0.0.1:5555`），
  可以装 HAP 截图自测，用完 `Emulator -stop 'Mate X7'`。
- 出鸿蒙发布包的脚本：`scripts/build_app_mac.sh`（`KEYSTORE_PWD=xxx` 传口令），
  编译 → 打 `.app` → 发布证书签名 → 验签一条龙。
