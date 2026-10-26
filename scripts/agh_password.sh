#!/bin/sh
# 把 AdGuard Home 的管理密码改成与 iStoreOS 相同
# 用法：AGH_PWHASH='$2b$10$...' AGH_PW='新明文口令' sh scripts/agh_password.sh
# bcrypt 口令哈希与明文都不写进仓库，用环境变量传入。
set -u
NEWHASH="${AGH_PWHASH:?请先设置 AGH_PWHASH（bcrypt 哈希）}"
YAML=/etc/AdGuardHome.yaml

echo "=== 1. 停服务（避免运行时把改动覆盖回去）==="
/etc/init.d/AdGuardHome stop 2>&1 | tail -2
sleep 2
ps w | grep "[A]dGuardHome" | head -2
echo "(以上为空表示已停)"

echo
echo "=== 2. 备份并改写 users 段密码 ==="
[ -f "${YAML}.bak-pw" ] || cp "$YAML" "${YAML}.bak-pw"
python3 - "$YAML" "$NEWHASH" <<'PY'
import re, sys
path, newhash = sys.argv[1], sys.argv[2]
src = open(path, encoding="utf-8").read()
out, in_users, done = [], False, False
for line in src.splitlines():
    if re.match(r"^users:\s*$", line):
        in_users = True
        out.append(line)
        continue
    if in_users:
        if re.match(r"^\S", line):          # 离开 users 段
            in_users = False
        elif not done and re.match(r"^\s+password:\s*", line):
            indent = line[:len(line) - len(line.lstrip())]
            out.append(f"{indent}password: {newhash}")
            done = True
            continue
    out.append(line)
open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
print("replaced:", done)
PY

echo
echo "=== 3. 启动并校验 ==="
/usr/bin/AdGuardHome/AdGuardHome -c "$YAML" --check-config 2>&1 | tail -4
/etc/init.d/AdGuardHome start 2>&1 | tail -2
sleep 8
/etc/init.d/AdGuardHome status 2>&1 | head -2
ss -lntp 2>/dev/null | grep -E ":5353 " | head -2

echo
echo "=== 4. 认证验证 ==="
printf "新密码 -> "; curl -s -o /dev/null -w "%{http_code}\n" -u "admin:${AGH_PW:?请先设置 AGH_PW}" http://127.0.0.1:3000/control/status
printf "旧密码 -> "; curl -s -o /dev/null -w "%{http_code}\n" -u "admin:${AGH_OLD_PW:-unset}" http://127.0.0.1:3000/control/status

echo
echo "=== 5. 拦截仍生效吗 ==="
for d in doubleclick.net baidu.com; do
  r=$(nslookup -port=5353 "$d" 127.0.0.1 2>/dev/null | grep "Address:" | tail -1 | awk '{print $NF}')
  printf "%-20s %s\n" "$d" "$r"
done
