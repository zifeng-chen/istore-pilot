# 路由器端安装

插件本体是「一个 Python 服务 + 一个 LuCI 页面」，两种安装方式装的是**同一份文件**
（`.run` 直接复用 ipk 的暂存逻辑，内容逐字节相同），选一种即可。

| | `.run` 自解压包 | `.ipk` |
|---|---|---|
| 需要 opkg | 不需要 | 需要 |
| 需要联网装依赖 | 不需要（但要有 python3） | 需要 `opkg update` |
| 一个文件搞定 | ✅ | ✅ |
| 出现在「软件包」列表 | ❌ | ✅ |
| 可被 LuCI 软件包页卸载 | ❌（用 `--uninstall`） | ✅ |
| 适合 | 普通用户装插件 | 要做包管理/批量部署 |

**两者不能并存。** 并存时 `opkg remove` 会把 `.run` 装进去的程序文件一起删掉，
而 opkg 记录里还写着「已安装」，之后升级就彻底错乱。

---

## 一、`.run` 安装（推荐）

### 1. 把文件传到路由器

任选一种：

```bash
# 电脑上，用 scp
scp istore-pilot_0.1.2-11.run root@192.168.1.1:/tmp/

# 或者在路由器上直接下载（需要能访问 GitHub）
wget -O /tmp/pilot.run https://github.com/zifeng-chen/istore-pilot/releases/latest/download/istore-pilot_0.1.2-11.run
```

也可以在 LuCI 里操作：**系统 → 文件传输**，把 `.run` 上传到 `/tmp/`。

> 一定要传到 `/tmp/`。`/tmp` 是内存盘，重启自动清空，不会占闪存。

### 2. 先检查，再安装

```sh
sh /tmp/pilot.run --check     # 只检查环境，不改任何文件
sh /tmp/pilot.run             # 安装或升级
```

`--check` 会告诉你：有没有 python3、包是否完整、是否与 opkg 冲突、
现有配置会不会被保留、剩余空间够不够。

### 3. 打开界面

```
网页控制台   http://<路由器IP>:8443
LuCI 管理    http://<路由器IP>/cgi-bin/luci/admin/services/istore_agent
```

首次安装的随机密码可以直接看：

```sh
cat /etc/istore-agent/INITIAL_PASSWORD
```

Android 客户端也可以直接在路由器上下载：
`http://<路由器IP>/istore-agent/istoreos-0.1.2.apk`

### 全部参数

| 参数 | 作用 |
|---|---|
| （无） | 安装或升级，保留现有配置 |
| `--check` | 只检查环境，不改动任何文件 |
| `--force` | 已由 opkg 装过时，移除包记录并由本包接管 |
| `--uninstall` | 删除程序文件，保留密码与配置 |
| `--purge` | 卸载并删除 `/etc/istore-agent` 与 `/etc/config/istore-agent` |
| `--no-start` | 装完不启动服务 |
| `-y` / `--yes` | 不询问，直接执行 |
| `--root=目录` | 仅用于测试，把文件装到别的目录 |
| `-V` / `--version` | 显示版本 |
| `-h` / `--help` | 帮助 |

---

## 二、ipk 安装

```sh
opkg update
opkg install python3
opkg install luci-app-istore-agent_0.1.2-11_all.ipk
```

或者 LuCI：**系统 → 软件包 → 上传软件包** → 选择 ipk → 安装。

装完同样在 **服务 → iStore Pilot** 里管理。

---

## 三、装了什么

`.run` 会写入下面这些路径（卸载时按包内 `MANIFEST` 逐条删除）：

```
/usr/lib/istore-agent/run.py            入口
/usr/lib/istore-agent/setup.py          配置补全（幂等）
/usr/lib/istore-agent/VERSION           版本号，LuCI 页面读它
/usr/lib/istore-agent/MANIFEST          文件清单，卸载用
/usr/lib/istore-agent/agent/            后端，约 20 个 .py
/usr/lib/istore-agent/agent/data/       OUI 厂商库、应用域名特征库
/usr/lib/istore-agent/web/              浏览器控制台（PWA）
/etc/init.d/istore-agent                procd 服务脚本
/etc/config/istore-agent                uci 配置（端口、bind、开关）
/usr/lib/lua/luci/controller/istore_agent.lua
/usr/lib/lua/luci/model/cbi/istore_agent/status.lua
/usr/lib/lua/luci/view/istore_agent/state.htm
/www/istore-agent/*.apk                 Android 安装包（如果打包时带了）
```

运行时数据放在 `/etc/istore-agent/`（**不随卸载删除**，除非 `--purge`）：

```
config.json        登录密码、Clash secret、AGH 口令
INITIAL_PASSWORD   首次安装的随机密码
devices.json       设备改名与绑定关系
data/              应用流量账本等
```

## 四、安全边界

安装器**只写上面那些路径**，不碰 `network`、`firewall`、`dhcp`、`dnsmasq`
任何一个 uci 配置，也不 reload 相关服务。装的过程中现有网络不受影响。

两条硬规则：

1. **`/etc/config/istore-agent` 已存在就原样保留。**
   不会把 `bind` 覆盖成默认值 —— 覆盖成 `0.0.0.0` 会让 `:8443` 暴露到 WAN 和 IPv6 公网侧。
2. **先验货再动手。** 载荷先解到 `/tmp` 验证一遍，通过了才开始改系统文件。
   包被截断时会在「删任何东西之前」失败，服务保持原样。

## 五、升级

直接用新版覆盖安装：

```sh
sh /tmp/istore-pilot_0.1.3-1.run
```

配置文件、密码、设备绑定、流量账本全部保留。

## 六、卸载

```sh
sh /tmp/pilot.run --uninstall   # 删程序，留密码和配置
sh /tmp/pilot.run --purge       # 全删干净
```

`--uninstall` 之后 `/etc/istore-agent` 还在，重装会接着用原来的密码；
`--purge` 会连密码一起清掉，下次安装重新生成。

## 七、从 ipk 迁移到 .run（或反过来）

```sh
# ipk → .run
sh /tmp/pilot.run --force        # 会先 opkg remove，再由本包接管

# .run → ipk
opkg install --force-reinstall luci-app-istore-agent_0.1.2-11_all.ipk
```

迁移时配置文件都会保留，密码不变。

## 八、排错

| 现象 | 原因与处理 |
|---|---|
| `没有找到 python3` | `opkg update && opkg install python3` |
| `安装包不完整（应 X 字节，实际 Y）` | 下载中断，重新下载。**不会改动任何文件** |
| `检测到 opkg 安装…加 --force` | 说清了两者互斥，按提示加 `--force` 或先 `opkg remove` |
| `服务似乎没起来` | `logread -e istore-agent` 看日志；常见是 python3 没装或端口被占 |
| 装完 LuCI 里看不到菜单 | `rm -f /tmp/luci-indexcache*` 后刷新；或退出登录重进 |
| 界面打得开但数据全是 `—` | 多半是 Clash secret / AGH 口令没配上，LuCI 页面里可以手填 |
| 手机连不上 `:8443` | 确认 `bind` 是 LAN 地址且手机在同一网段；公网访问需要放行 IPv6 |

服务日志：

```sh
logread -e istore-agent -f
```

手动重启：

```sh
/etc/init.d/istore-agent restart
```

## 九、给开发者的说明

构建：

```bash
python deploy/build_run.py              # 含 APK
python deploy/build_run.py --no-apk     # 不含 APK
python deploy/build_run.py --rev 12     # 指定修订号
```

包结构是「shell 头部 + tar.gz 载荷」，头部里的 `PAYLOAD_OFFSET` 是载荷起始字节，
安装器用 `tail -c +N` 把自己尾巴切出来。没有第三方依赖，Windows 上也能构建。

两个改动时容易踩的点：

- **头部必须 LF 换行。** CRLF 会让 ash 的 shebang 和行尾解析出错。
- **`tar -C` 不能是空字符串。** 装到真正的根目录时 `ROOT_DIR` 恰好为空，
  必须回落到 `/` —— 这个坑让首次真机安装失败过一次。

测试不碰真机：

```sh
sh pilot.run --root=/tmp/rr --no-start    # 装到 /tmp/rr
find /tmp/rr -type f | wc -l              # 应为 39
sh pilot.run --root=/tmp/rr --uninstall   # 只剩 etc/config/istore-agent
sh pilot.run --root=/tmp/rr --purge       # 一个文件都不剩
```
