"""认证与限流。密码比对用常量时间比较，令牌用 HMAC-SHA256 自签。

限流是两层：**按来源 IP** 挡单机爆破，**全局**挡「换 IP 继续试」——
wan 侧如果放通了 IPv6，攻击者手里是整段地址，只按 IP 计数等于没限。
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
# 全局上限：正常人一分钟登不了这么多次，超了就是有人在撞库
_GLOBAL_LIMIT = 120

_lock = threading.Lock()
_fails: dict[str, list[float]] = {}
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
    """清掉窗口外的记录，顺手扔掉空桶。

    不做这一步的话，`_fails` 会随着「每个来源 IP 一条」一直长下去 ——
    在 IPv6 网段里这就是一个能被外部撑大的内存结构。
    """
    gone = now - _WINDOW
    for key in list(_fails):
        kept = [t for t in _fails[key] if t > gone]
        if kept:
            _fails[key] = kept
        else:
            del _fails[key]
    if _all_fails:
        _all_fails[:] = [t for t in _all_fails if t > gone]


def verify_password(password: str, remote: str) -> bool:
    """带失败次数限制的密码校验（按 IP + 全局双阈值）。"""
    per_ip = int(cfg("auth", {}).get("rate_limit_per_min", 30))
    now = time.time()
    with _lock:
        _prune(now)
        hits = _fails.get(remote, [])
        if len(hits) >= per_ip or len(_all_fails) >= _GLOBAL_LIMIT:
            return False

    ok = hmac.compare_digest(password, str(cfg("auth", {}).get("password", "")))
    if not ok:
        with _lock:
            _fails.setdefault(remote, []).append(now)
            _all_fails.append(now)
    return ok


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
