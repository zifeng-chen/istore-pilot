#!/usr/bin/env python3
"""把路由器上的 geosite.dat / geoip.dat / appfilter 规则拉到本地，解析成可用的库。

geosite.dat 是 protobuf 格式:
    GeoSiteList { repeated GeoSite entry = 1 }
    GeoSite     { string country_code = 1; repeated Domain domain = 2 }
    Domain      { Type type = 1; string value = 2; repeated string attribute = 3 }

用法:
    ROUTER_PW=xxx python scripts/fetch_geodata.py [--list]
"""
from __future__ import annotations

import io
import json
import os
import struct
import sys

import paramiko

HOST = os.environ.get("ROUTER_HOST", "192.168.100.1")
USER = os.environ.get("ROUTER_USER", "root")
PW = os.environ.get("ROUTER_PW", "")

REMOTE = {
    "geosite": "/etc/openclash/GeoSite.dat",
    "geoip": "/usr/share/v2ray/geoip.dat",
    "feature": "/etc/appfilter/feature.cfg",
    "feature_cn": "/etc/appfilter/feature_cn.cfg",
    "feature_en": "/etc/appfilter/feature_en.cfg",
}
OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "agent", "data")


def fetch(name: str) -> bytes:
    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(HOST, 22, USER, PW, timeout=15, allow_agent=False, look_for_keys=False)
    sftp = client.open_sftp()
    with sftp.open(REMOTE[name], "rb") as fh:
        data = fh.read()
    sftp.close()
    client.close()
    return data


# ---------------------------------------------------------------- protobuf

def _varint(buf: bytes, pos: int) -> tuple[int, int]:
    result = shift = 0
    while True:
        b = buf[pos]
        pos += 1
        result |= (b & 0x7F) << shift
        if not b & 0x80:
            return result, pos
        shift += 7


def _fields(buf: bytes):
    """逐字段产出 (field_no, wire_type, value)。value 为 int 或 bytes。"""
    pos = 0
    n = len(buf)
    while pos < n:
        key, pos = _varint(buf, pos)
        field, wire = key >> 3, key & 7
        if wire == 0:
            val, pos = _varint(buf, pos)
        elif wire == 2:
            ln, pos = _varint(buf, pos)
            val = buf[pos:pos + ln]
            pos += ln
        elif wire == 5:
            val = struct.unpack("<I", buf[pos:pos + 4])[0]
            pos += 4
        elif wire == 1:
            val = struct.unpack("<Q", buf[pos:pos + 8])[0]
            pos += 8
        else:
            return
        yield field, wire, val


def parse_geosite(buf: bytes) -> dict[str, list[tuple[int, str]]]:
    """→ {country_code: [(type, value), ...]}，type: 0 明文 1 正则 2 根域 3 全量"""
    out: dict[str, list[tuple[int, str]]] = {}
    for f, w, val in _fields(buf):
        if f != 1 or w != 2:
            continue
        code = ""
        domains: list[tuple[int, str]] = []
        for f2, w2, v2 in _fields(val):
            if f2 == 1 and w2 == 2:
                code = v2.decode("utf-8", "replace")
            elif f2 == 2 and w2 == 2:
                dtype, value = 0, ""
                for f3, w3, v3 in _fields(v2):
                    if f3 == 1 and w3 == 0:
                        dtype = v3
                    elif f3 == 2 and w3 == 2:
                        value = v3.decode("utf-8", "replace")
                if value:
                    domains.append((dtype, value))
        if code:
            out[code] = domains
    return out


def parse_geoip(buf: bytes) -> dict[str, int]:
    """→ {country_code: cidr 条数}"""
    out: dict[str, int] = {}
    for f, w, val in _fields(buf):
        if f != 1 or w != 2:
            continue
        code, cnt = "", 0
        for f2, w2, v2 in _fields(val):
            if f2 == 1 and w2 == 2:
                code = v2.decode("utf-8", "replace")
            elif f2 == 2 and w2 == 2:
                cnt += 1
        if code:
            out[code] = cnt
    return out


def main() -> int:
    if not PW:
        print("缺少 ROUTER_PW", file=sys.stderr)
        return 2
    os.makedirs(OUT_DIR, exist_ok=True)

    print("拉 GeoSite.dat ...")
    site_raw = fetch("geosite")
    print(f"  {len(site_raw) / 1048576:.1f} MB")
    sites = parse_geosite(site_raw)
    total = sum(len(v) for v in sites.values())
    print(f"  分类 {len(sites)} 个，域名 {total} 条")

    if "--list" in sys.argv:
        print("\n按域名数量排序（前 60）:")
        for code, doms in sorted(sites.items(), key=lambda kv: -len(kv[1]))[:60]:
            print(f"  {code:<28} {len(doms):>6}")

    print("\n拉 geoip.dat ...")
    ip_raw = fetch("geoip")
    print(f"  {len(ip_raw) / 1048576:.1f} MB")
    ips = parse_geoip(ip_raw)
    print(f"  分类 {len(ips)} 个，网段 {sum(ips.values())} 条")
    for code, cnt in sorted(ips.items(), key=lambda kv: -kv[1])[:20]:
        print(f"  {code:<20} {cnt:>6}")

    with open(os.path.join(OUT_DIR, "geosite-summary.json"), "w", encoding="utf-8") as fh:
        json.dump({k: len(v) for k, v in sites.items()}, fh, ensure_ascii=False, indent=1)

    print("\n拉 appfilter 规则 ...")
    for key in ("feature", "feature_cn", "feature_en"):
        data = fetch(key)
        print(f"  {key}: {len(data)} 字节")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
