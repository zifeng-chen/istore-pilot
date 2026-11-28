# Agent 加固说明

## 1. 链路加密（可选，默认关闭）

Agent 默认走 HTTP:8443。令牌与登录口令在链路上是明文，**同网段抓包即可复用令牌**
（有效期 7 天）。内网自用可以接受；一旦通过公网/反代暴露，必须加密。

### 开启方式

1. 准备证书（自签也行，路由器上生成）：

```sh
mkdir -p /etc/istore-agent/tls
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout /etc/istore-agent/tls/key.pem \
  -out    /etc/istore-agent/tls/cert.pem \
  -subj "/CN=istore-agent"
```

2. 写进配置 `/etc/istore-agent/config.json`：

```json
{ "tls": { "enabled": true,
           "cert": "/etc/istore-agent/tls/cert.pem",
           "key":  "/etc/istore-agent/tls/key.pem" } }
```

3. 重启：`/etc/init.d/istore-agent restart`

### 开启后客户端要跟着改

- 手机端 base URL 改成 `https://…:8443`
- 自签证书：Android 需要在 `network_security_config` 里加 trust-anchor；
  iOS 需要 ATS 例外，否则请求直接失败

**所以默认不开** —— 开了而客户端没改，表现是「全部接口连不上」，很容易误判成故障。

### 判断当前状态

```sh
curl -s http://<路由器>:8443/api/v1/ping
# {"ok":true, ..., "tls": false}
```

`tls:false` 表示当前链路是明文。

## 2. 面向公网时的最小要求

- 只通过反向代理暴露，且反代必须是 **HTTPS**
- Agent 绑定 LAN 地址（`bind` 不要是 `0.0.0.0`）
- 口令用强口令；`auth.token_ttl` 建议从 7 天改成 1 天
- 改口令后调用一次 `rotate_key()`（Agent 内部已自动做），旧令牌立刻失效

## 3. 日志

| 文件 | 上限 | 轮转 |
|---|---|---|
| `/etc/istore-agent/data/access.log` | 512 KB | 超限滚成 `.1`，只留一代 |
| AGH `querylog.json` | 无 | 由 AdGuard Home 自己按天数清理（默认 90 天） |

AGH 若长期不清，`querylog.json` 会到 GB 级（实测见过 2.6 GB）。不影响解析速度，
但持续写闪存。清理：AdGuard Home → 设置 → 常规 → 查询日志保留时间调成 7 天。
