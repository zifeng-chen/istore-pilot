"""认证、限流与口令强度。

三层防护，各挡各的：

1. **失败计数 + 递增退避**（按来源 IP）—— 挡单机爆破。前 4 次不要钱，
   第 5 次起依次锁 1/2/4/8/16/30/60 秒，成功登录立刻清零。
2. **全局失败上限**（每分钟 300 次）—— 挡「换 IP 继续试」。IPv6 下攻击者
   手里是一整段地址，只按 IP 计数等于没限。
3. **口令强度校验** —— 挡「口令本身就弱」。这是最后一道闸：口令一旦被撞开，
   攻击者能做的事是「以 root 执行任意 .run 安装包」，等于整台路由器。

退避的实现刻意是「返回拒绝」而不是「在请求里 sleep」：服务端是
ThreadingHTTPServer，每个连接一个线程，在请求里睡 60 秒等于白送一个线程
给攻击者打满。

令牌是 HMAC-SHA256 自签，payload 可读但不含敏感信息。改口令时换签名密钥，
旧令牌立刻全部作废。
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import secrets
import threading
import time

from .config import get as cfg, load as load_cfg, save as save_cfg

_WINDOW = 60.0
# 每分钟全局失败上限。定 300 而不是几十，是为了别让攻击者用少量请求就把
# 正常用户一起锁在门外；真要挡分布式爆破，这个值也够用
_GLOBAL_LIMIT = 300
# 第 n 次失败之后锁多少秒。前 4 次不锁（手滑几次很正常），第 5 次起指数退避
_BACKOFF = (0.0, 0.0, 0.0, 0.0, 1.0, 2.0, 4.0, 8.0, 16.0, 30.0, 60.0)
# 解锁后一小时没再失败就把这条记录扔掉，避免 _penalty 被撑大
_PENALTY_TTL = 3600.0

_lock = threading.Lock()
# remote -> (连续失败次数, 解锁时间戳)
_penalty: dict[str, tuple[int, float]] = {}
# 全窗口内的失败时间戳（不分来源）
_all_fails: list[float] = []


def _b64(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def _unb64(text: str) -> bytes:
    pad = "=" * (-len(text) % 4)
    return base64.urlsafe_b64decode(text + pad)


def _sign(payload: str) -> str:
    key = cfg("auth", {}).get("signing_key", "").encode()
    return _b64(hmac.new(key, payload.encode(), hashlib.sha256).digest())


def _prune(now: float) -> None:
    """清掉过期的失败记录。

    不做这一步，`_penalty` 会随着「每个来源 IP 一条」一直长下去 ——
    在 IPv6 网段里这就是一个能被外部撑大的内存结构。
    """
    if _all_fails:
        gone = now - _WINDOW
        _all_fails[:] = [t for t in _all_fails if t > gone]
    for key in list(_penalty):
        _, until = _penalty[key]
        if until and now - until > _PENALTY_TTL:
            del _penalty[key]


def retry_after(remote: str) -> int:
    """还要等几秒才能再试。0 表示没被退避锁住。

    调用方拿到正数应该回 429 + Retry-After，而不是回「密码错误」——
    这两种情况用户能做的事完全不同：一个是改口令，一个是等。
    """
    now = time.time()
    with _lock:
        _prune(now)
        _, until = _penalty.get(remote, (0, 0.0))
    if until <= now:
        return 0
    return max(1, int(until - now + 0.999))


def verify_password(password: str, remote: str) -> bool:
    """校验口令。被退避锁住时直接返回 False，不消耗比对。"""
    now = time.time()
    with _lock:
        _prune(now)
        _, until = _penalty.get(remote, (0, 0.0))
        locked = until > now
        global_locked = len(_all_fails) >= _GLOBAL_LIMIT
    if locked or global_locked:
        return False

    ok = hmac.compare_digest(password, str(cfg("auth", {}).get("password", "")))
    if ok:
        with _lock:
            # 成功就清零：用户改对一次，不该被之前的失败继续压着
            _penalty.pop(remote, None)
        return True

    with _lock:
        count, _ = _penalty.get(remote, (0, 0.0))
        count += 1
        wait = _BACKOFF[min(count, len(_BACKOFF) - 1)]
        _penalty[remote] = (count, now + wait)
        _all_fails.append(now)
    return False


# --------------------------------------------------------------- 口令强度

# 撞库字典里最常见的那批。不追求全，够挡「随手设一个」就行
_WEAK = {
    "password", "passw0rd", "p@ssw0rd", "12345678", "123456789", "1234567890",
    "admin", "admin123", "admin888", "administrator", "changeme", "letmein",
    "qwerty", "qwerty123", "abc123456", "iloveyou", "welcome123",
    "istoreos", "istore", "openwrt", "wifi12345678", "88888888", "66668888",
}


def password_problem(pw: str, user: str = "") -> str:
    """口令强度检查。返回中文理由，空串表示合格。

    卡 12 位 + 两类字符：这个口令护着的是「以 root 执行任意安装包」的权限，
    而当前链路还是明文 HTTP（口令可能被抓包拿走），强度是最后一道闸。
    """
    if len(pw) < 12:
        return "至少 12 位"
    if pw.lower() in _WEAK:
        return "太常见了，换一个"
    if pw.isdigit():
        return "不能全是数字"
    if pw.isalpha():
        return "不能全是字母"
    kinds = 0
    if any(c.islower() for c in pw):
        kinds += 1
    if any(c.isupper() for c in pw):
        kinds += 1
    if any(c.isdigit() for c in pw):
        kinds += 1
    if any(not c.isalnum() for c in pw):
        kinds += 1
    if kinds < 2:
        return "至少包含两类字符（小写 / 大写 / 数字 / 符号）"
    if user and pw.lower() == user.lower():
        return "不能和用户名相同"
    low = pw.lower()
    for seq in ("0123456789", "abcdefghijklmnopqrstuvwxyz"):
        for i in range(len(seq) - 3):
            if seq[i:i + 4] in low:
                return "不要用连续字符（如 abcd、1234）"
    return ""


# ------------------------------------------------------------------ 令牌


def issue_token(subject: str = "app") -> dict:
    ttl = int(cfg("auth", {}).get("token_ttl", 7 * 24 * 3600))
    now = int(time.time())
    exp = now + ttl
    payload = _b64(json.dumps(
        # jti 现在不参与校验，但有了它以后要加「吊销单个令牌」就不用改格式
        {"sub": subject, "iat": now, "exp": exp, "jti": secrets.token_hex(8)},
        separators=(",", ":")).encode())
    return {"token": f"{payload}.{_sign(payload)}", "expires_at": exp, "ttl": ttl}


def verify_token(token: str) -> bool:
    if not token or "." not in token:
        return False
    payload, sig = token.rsplit(".", 1)
    if not hmac.compare_digest(sig, _sign(payload)):
        return False
    try:
        data = json.loads(_unb64(payload))
        exp = data.get("exp", 0)
        if isinstance(exp, bool):          # bool 是 int 的子类，单独挡掉
            return False
        return int(exp) > time.time()
    except (ValueError, TypeError, json.JSONDecodeError):
        return False


def rotate_key() -> bool:
    """换签名密钥：所有已发出的令牌立刻失效。

    改口令时顺手调用。不然改完口令，旧令牌还能用满 7 天 ——
    用户会觉得「密码改了怎么还能进」。
    """
    conf = load_cfg()
    conf.setdefault("auth", {})["signing_key"] = secrets.token_hex(32)
    return save_cfg(conf)
