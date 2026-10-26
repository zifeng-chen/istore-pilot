#!/usr/bin/env python3
"""探测并接入局域网内的 Mac。

用法:
    python scripts/mac_probe.py                     # 只探测谁在线
    MAC_PW=xxx python scripts/mac_probe.py --ip 192.168.100.x --user chaof
                                                    # 连接并做环境体检

密码只从环境变量 MAC_PW 读，不写入任何文件。
依赖: paramiko (pip install paramiko)
"""
import argparse
import os
import re
import select
import socket
import struct
import sys
import time
from concurrent.futures import ThreadPoolExecutor

MDNS_GROUP = ('224.0.0.251', 5353)

# 苹果设备会应答的服务。_device-info 的 TXT 里有 model=，能直接区分 Mac 和 AppleTV
SERVICES = [
    '_device-info._tcp.local',
    '_ssh._tcp.local',
    '_rfb._tcp.local',
    '_smb._tcp.local',
    '_afpovertcp._tcp.local',
]

# Mac 上这些端口任一开放都说明有戏
PORTS = {22: 'SSH', 5900: '屏幕共享', 3283: '远程管理', 548: 'AFP', 88: 'Kerberos'}

# AppleTV 的 model 前缀，用来从候选里剔除
TV_MODELS = ('AppleTV', 'AudioAccessory', 'J305AP', 'J42dAP')


def scan_ports(subnet='192.168.100.'):
    """扫端口，返回 {ip: [服务名]}"""
    def probe(ip):
        hits = []
        for port, name in PORTS.items():
            s = socket.socket()
            s.settimeout(0.4)
            try:
                if s.connect_ex((ip, port)) == 0:
                    hits.append(name)
            except Exception:
                pass
            finally:
                s.close()
        return ip, hits

    out = {}
    with ThreadPoolExecutor(max_workers=150) as ex:
        for ip, hits in ex.map(probe, [f'{subnet}{i}' for i in range(1, 255)]):
            if hits:
                out[ip] = hits
    return out


def mdns_scan(seconds=4.0):
    """发 mDNS 查询，从应答里抽主机名和 model=，返回 {ip: {'names': [], 'model': str}}"""
    def build(name, qtype=12):
        q = b''
        for part in name.split('.'):
            q += bytes([len(part)]) + part.encode()
        q += b'\x00' + struct.pack('>HH', qtype, 1)
        return struct.pack('>HHHHHH', 0, 0, 1, 0, 0, 0) + q

    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(('', 5353))
    except OSError as e:
        print(f'  [mDNS] 无法绑定 5353: {e}', file=sys.stderr)
        return {}

    try:
        mreq = struct.pack('4s4s', socket.inet_aton(MDNS_GROUP[0]),
                           socket.inet_aton('0.0.0.0'))
        s.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
    except OSError:
        pass

    for svc in SERVICES:
        s.sendto(build(svc), MDNS_GROUP)
        time.sleep(0.10)

    s.setblocking(False)
    found = {}
    t0 = time.time()
    while time.time() - t0 < seconds:
        r, _, _ = select.select([s], [], [], 0.4)
        if not r:
            continue
        try:
            data, addr = s.recvfrom(9000)
        except Exception:
            continue
        entry = found.setdefault(addr[0], {'names': [], 'model': ''})
        for token in re.findall(rb'[ -~]{4,}', data):
            text = token.decode('ascii', 'replace')
            if text.startswith('model='):
                entry['model'] = text[6:]
            elif text.endswith('.local') and '._' not in text:
                name = text[:-6]
                if name and name not in entry['names'] and name != 'local':
                    entry['names'].append(name)
    s.close()
    return found


def looks_like_mac(model):
    """只有真实 Mac 的型号代号才算。

    macOS 广播的是 MacBookPro18,3 / Macmini9,1 / Mac14,2 / iMac21,1 这类
    「名字 + 逗号 + 数字」的代号。Samba 会广播 model=MacSamba 来假装自己是
    macOS（路由器、NAS 上很常见），不含逗号数字，必须按正则排除。
    """
    if not model:
        return None
    if model == 'MacSamba':
        return False
    if any(model.startswith(p) for p in TV_MODELS):
        return False
    if re.match(r'^(MacBook(Pro|Air)?|Macmini|MacPro|MacStudio|iMac|Mac)\d+,\d+$', model):
        return True
    return None


def discover():
    print('=== 1/2 端口扫描 ===')
    ports = scan_ports()
    for ip, hits in sorted(ports.items(), key=lambda x: int(x[0].split('.')[-1])):
        print(f'  {ip:16s} {", ".join(hits)}')

    print('\n=== 2/2 mDNS 广播 ===')
    mdns = mdns_scan()
    for ip in sorted(mdns, key=lambda x: int(x.split('.')[-1])):
        e = mdns[ip]
        names = ', '.join(e['names']) or '-'
        model = e['model'] or '-'
        print(f'  {ip:16s} {names:24s} model={model}')

    # 综合判断
    candidates = []
    for ip in set(list(ports) + list(mdns)):
        e = mdns.get(ip, {'names': [], 'model': ''})
        verdict = looks_like_mac(e['model'])
        if verdict:
            candidates.append((ip, e['model'], e['names'], ports.get(ip, [])))
        elif verdict is None and 'SSH' in ports.get(ip, []) and ip != '192.168.100.1':
            # 端口开 22 但拿不到 model，列为待人工确认
            candidates.append((ip, '未知(无 model 广播)', e['names'], ports.get(ip, [])))

    print('\n=== 判定 ===')
    if not candidates:
        print('  没有发现 Mac。可能原因：关机 / 休眠 / 连的是另一个网络 / 开了 mDNS 抑制。')
        return []
    for ip, model, names, svc in candidates:
        print(f'  {ip}  model={model}  主机名={", ".join(names) or "-"}  端口={", ".join(svc) or "-"}')
    return candidates


def checkup(ip, user, password):
    import paramiko

    print(f'\n=== 连接 {user}@{ip} ===')
    cli = paramiko.SSHClient()
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        cli.connect(ip, 22, user, password, timeout=15, allow_agent=False,
                    look_for_keys=False)
    except Exception as e:
        print(f'  连接失败: {type(e).__name__}: {e}')
        print('  检查：远程登录是否已开、用户名密码是否正确、账号是否在允许列表里')
        return False
    print('  已连上\n')

    cmds = [
        ('系统版本', 'sw_vers'),
        ('架构', 'uname -m'),
        ('CPU', 'sysctl -n machdep.cpu.brand_string 2>/dev/null || sysctl -n hw.model'),
        ('磁盘', 'df -h / | tail -1'),
        ('Xcode 路径', 'xcode-select -p 2>&1'),
        ('Xcode 版本', 'xcodebuild -version 2>&1 | head -2'),
        ('Homebrew', 'which brew 2>&1'),
        ('Node', 'which node && node -v 2>&1'),
        ('Java', 'which java && java -version 2>&1 | head -2'),
        ('鸿蒙工具', 'which hdc hvigorw ohpm 2>&1'),
        ('DevEco', 'ls -d /Applications/DevEco*.app 2>/dev/null'),
    ]
    for label, cmd in cmds:
        _, out, err = cli.exec_command(cmd, timeout=20)
        text = (out.read().decode('utf-8', 'replace') +
                err.read().decode('utf-8', 'replace')).strip()
        text = re.sub(r'\n+', ' | ', text)[:200]
        print(f'  {label:10s} {text or "（无）"}')

    cli.close()
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ip', help='跳过探测直接连这台')
    ap.add_argument('--user', help='Mac 用户名')
    ap.add_argument('--subnet', default='192.168.100.', help='网段前缀')
    args = ap.parse_args()

    if args.ip:
        if not args.user:
            print('需要用 --user 指定 Mac 用户名')
            return 1
        pw = os.environ.get('MAC_PW')
        if not pw:
            print('需要设置环境变量 MAC_PW')
            return 1
        return 0 if checkup(args.ip, args.user, pw) else 1

    found = discover()
    if found:
        print('\n下一步:')
        ip = found[0][0]
        print(f'  MAC_PW=你的密码 python scripts/mac_probe.py --ip {ip} --user 你的用户名')
    return 0


if __name__ == '__main__':
    sys.exit(main())
