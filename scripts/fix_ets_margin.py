#!/usr/bin/env python3
"""把「自定义组件后面链式 .margin()」改写成组件参数。

ArkTS 语法不允许：

    Card() { ... }
      .margin({ top: 12 });      // ← Declaration or statement expected

只能把间距塞进组件自身，由根容器承担：

    Card({ gapTop: 12 }) { ... }

内置容器（Column/Row/Stack/Scroll/List…）后面链式写是合法的，不动。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# 项目里所有 @Component struct —— 这些都不能链式加属性
CUSTOM = {
    "Card", "GroupBox", "Hairline", "Kv", "Pill", "CardHeader", "Ring",
    "TrendChart", "NavBar", "Icon", "Sheet", "Skeleton", "Empty",
}

MARGIN_RE = re.compile(r"^(\s*)\.margin\(\{\s*(top|bottom|left|right)\s*:\s*([^}]+?)\s*\}\);\s*$")
OPENER_RE = re.compile(r"^(\s*)(\w+)\(")

GAP_KEY = {"top": "gapTop", "bottom": "gapBottom"}


def patch(path: Path) -> int:
    lines = path.read_text(encoding="utf-8").splitlines()
    out: list[str] = []
    changed = 0
    i = 0
    while i < len(lines):
        line = lines[i]
        m = MARGIN_RE.match(line)
        if not m:
            out.append(line)
            i += 1
            continue

        indent, side, value = m.group(1), m.group(2), m.group(3).strip()
        # 只有单边、且该边有 gap 参数时才处理
        if side not in GAP_KEY:
            out.append(line)
            i += 1
            continue

        # 上一条非空行必须是 "}"（说明是挂在某个组件上的）
        k = len(out) - 1
        while k >= 0 and not out[k].strip():
            k -= 1
        if k < 0 or out[k].strip() != "}":
            out.append(line)
            i += 1
            continue

        # 往上找同缩进的组件开头
        j = k - 1
        opener = None
        while j >= 0:
            s = out[j]
            if not s.strip():
                j -= 1
                continue
            si = len(s) - len(s.lstrip())
            if si < len(indent):
                break
            if si == len(indent) and s.rstrip().endswith("{"):
                opener = j
                break
            j -= 1

        if opener is None:
            out.append(line)
            i += 1
            continue

        om = OPENER_RE.match(out[opener])
        name = om.group(2) if om else ""
        if name not in CUSTOM:
            out.append(line)
            i += 1
            continue

        # 重写开头：Card() { -> Card({ gapTop: v }) {
        decl = out[opener].rstrip()
        head = decl[: decl.rindex("{")].rstrip()          # "Card()" 或 "Card({ pad: 4 })"
        body_open = decl[decl.rindex("{"):]               # "{"
        pm = re.match(r"^(\s*)(\w+)\((.*)\)$", head)
        if not pm:
            out.append(line)
            i += 1
            continue
        args = pm.group(3).strip()
        key = GAP_KEY[side]
        if args in ("", "{}"):
            args = f"{{ {key}: {value} }}"
        elif args.startswith("{") and args.endswith("}"):
            inner = args[1:-1].strip()
            args = "{}" if not inner else "{ " + inner + f", {key}: {value}" + " }"
        else:
            out.append(line)
            i += 1
            continue
        out[opener] = f"{pm.group(1)}{pm.group(2)}({args}) {body_open}"

        print(f"  {path}:{i+1}  {name} ← {side}:{value}")
        changed += 1
        i += 1  # 丢掉 .margin 这一行

    if changed:
        path.write_text("\n".join(out) + "\n", encoding="utf-8", newline="\n")
    return changed


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    total = 0
    for p in sorted(root.rglob("*.ets")):
        total += patch(p)
    print(f"共改写 {total} 处")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
