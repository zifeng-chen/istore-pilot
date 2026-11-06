#!/usr/bin/env python3
"""AGH 上游守护：按代理状态自动切换 DNS 上游，保证开关代理不影响正常网络。

背景
----
AGH 占着 :53 做过滤，它的上游原来写死 OpenClash 的 127.0.0.1:7874。
OpenClash 一关，7874 就没人监听，AGH 所有查询 SERVFAIL ——
整个网络（除了不查 DNS 的 IoT）都上不了网。反过来，上游如果写死公共 DNS，
OpenClash 的 fake-ip 分流又不生效（拿不到域名，只能按 IP 分）。

做法
----
按端口监听状态自动切：
  - OpenClash(7874) / Passwall(15353/7913) 在跑 -> 上游指它（fake-ip 生效）
  - 都没跑 -> 上游指公共 DNS（223.5.5.5 / 119.29.29.29）

只在状态真正变化时才改 yaml + 重启 AGH，避免频繁中断。
由 cron 每分钟跑一次（/etc/crontabs/root）。

为什么不用 netstat
------------------
路由器上的 netstat 输出格式随 busybox 版本变，解析容易出错；
直接读 /proc/net/tcp 和 /proc/net/udp 最稳（纯标准库，无外部依赖）。
"""

import fcntl
import subprocess
import sys

YAML = '/etc/AdGuardHome.yaml'
STATE = '/tmp/agh_upstream.mode'
LOCK = '/tmp/agh_upstream.lock'

# 代理的 DNS 监听端口，按优先级；哪个在听就用哪个
PROXY_PORTS = [
    ('openclash', 7874),
    ('passwall-chinadns', 15353),
    ('passwall-dns2socks', 7913),
]

PUBLIC = ['223.5.5.5', '119.29.29.29']


def port_listening(port):
    """端口是否有进程在监听（TCP 或 UDP 任一）。"""
    for path in ('/proc/net/tcp', '/proc/net/udp', '/proc/net/tcp6', '/proc/net/udp6'):
        try:
            with open(path) as fh:
                next(fh, None)  # 跳过表头
                for line in fh:
                    fields = line.split()
                    if len(fields) < 2:
                        continue
                    try:
                        local_port = int(fields[1].split(':')[1], 16)
                    except (IndexError, ValueError):
                        continue
                    if local_port == port:
                        return True
        except OSError:
            continue
    return False


def detect():
    """返回 (mode, upstreams)。"""
    for name, port in PROXY_PORTS:
        if port_listening(port):
            return name, ['127.0.0.1:%d' % port]
    return 'public', PUBLIC


def read_state():
    try:
        with open(STATE) as fh:
            return fh.read().strip()
    except OSError:
        return ''


def set_upstreams(upstreams):
    """只替换 upstream_dns 块里的上游行，[/lan/] 这些本地规则原样保留。"""
    with open(YAML, encoding='utf-8') as fh:
        lines = fh.read().split('\n')

    out = []
    i = 0
    found = False
    while i < len(lines):
        line = lines[i]
        if line.strip() == 'upstream_dns:':
            found = True
            out.append(line)
            i += 1
            local = []
            while i < len(lines) and lines[i].startswith('    - '):
                if lines[i].lstrip().startswith("- '[/"):
                    local.append(lines[i])
                i += 1
            for u in upstreams:
                out.append('    - ' + u)
            out.extend(local)
            continue
        out.append(line)
        i += 1

    if not found:
        raise RuntimeError('upstream_dns block not found in %s' % YAML)

    with open(YAML, 'w', encoding='utf-8') as fh:
        fh.write('\n'.join(out))


def main():
    # 同一时刻只允许一个实例：AGH restart 要几秒，cron 可能撞上
    lock = open(LOCK, 'w')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return 0

    mode, upstreams = detect()
    if read_state() == mode:
        return 0

    set_upstreams(upstreams)
    with open(STATE, 'w') as fh:
        fh.write(mode)
    subprocess.run(['/etc/init.d/AdGuardHome', 'restart'],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return 0


if __name__ == '__main__':
    sys.exit(main())
