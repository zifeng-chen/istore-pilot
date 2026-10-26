"""认证与限流。密码比对用常量时间比较，令牌用 HMAC-SHA256 自签。"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import threading
import time

from .config import get as cfg

_attempts: dict[str, list[float]] = {}
_lock = threading.Lock()


def _b64(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def _unb64(text: str) -> bytes:
    pad = "=" * (-len(text) % 4)
    return base64.urlsafe_b64decode(text + pad)


def _sign(payload: str) -> str:
    key = cfg("auth", {}).get("signing_key", "").encode()
    return _b64(hmac.new(key, payload.encode(), hashlib.sha256).digest())


def verify_password(password: str, remote: str) -> bool:
    """带失败次数限制的密码校验。"""
    limit = int(cfg("auth", {}).get("rate_limit_per_min", 30))
    now = time.time()
    with _lock:
        hits = [t for t in _attempts.get(remote, []) if now - t < 60]
        if len(hits) >= limit:
            _attempts[remote] = hits
            return False
    ok = hmac.compare_digest(password, str(cfg("auth", {}).get("password", "")))
    with _lock:
        if not ok:
            hits.append(now)
        _attempts[remote] = hits
    return ok


def issue_token(subject: str = "app") -> dict:
    ttl = int(cfg("auth", {}).get("token_ttl", 7 * 24 * 3600))
    exp = int(time.time()) + ttl
    payload = _b64(json.dumps({"sub": subject, "exp": exp}, separators=(",", ":")).encode())
    return {"token": f"{payload}.{_sign(payload)}", "expires_at": exp, "ttl": ttl}


def verify_token(token: str) -> bool:
    if not token or "." not in token:
        return False
    payload, sig = token.rsplit(".", 1)
    if not hmac.compare_digest(sig, _sign(payload)):
        return False
    try:
        data = json.loads(_unb64(payload))
    except (ValueError, json.JSONDecodeError):
        return False
    return int(data.get("exp", 0)) > time.time()
