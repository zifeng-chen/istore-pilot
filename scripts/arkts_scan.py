#!/usr/bin/env python3
"""扫 ArkTS 编译期坑（配合 docs/ARKTS_PITFALLS.md 用）。

    python scripts/arkts_scan.py            # 扫 harmony/，有问题退出码 1

项目已经能在标准模式编译通过，所以这里基本扫不出「错误级」违规；
它的价值在两点：
  1. 抓「警告级」和代码坏味道（ESObject、.bind、@ts-ignore、受限 stdlib…），
     这些现在能编过、将来可能报错或不好维护；
  2. 以后让 AI 代写 .ets 时，写进提交前自查。

匹配是词法层的，会有少量误报（注释/字符串里出现关键字），人工瞄一眼即可。
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
HARMONY = ROOT / "harmony" / "entry" / "src" / "main" / "ets"

RULES: list[tuple[str, str]] = [
    ("any/unknown 类型",
     r"\b(let|const|var)\s+\w+\s*:\s*(any|unknown)\b"   # 变量声明类型
     r"|\)\s*:\s*(any|unknown)\b"                      # 返回类型
     r"|\(\s*\w+\s*:\s*(any|unknown)\b"                # 参数类型
     r"|\bas\s+(any|unknown)\b|<(any|unknown)>|\b(any|unknown)\[\]"),
    ("@ts-ignore/nocheck", r"@ts-(ignore|nocheck)"),
    ("解构声明", r"\b(const|let)\s*[{[]"),
    ("for..in", r"for\s*\(\s*\w+\s+in\s+"),
    ("in 运算符", r"['\"][\w.-]+['\"]\s+in\s+"),
    ("delete", r"\bdelete\s+"),
    ("对象展开", r"\{\s*\.\.\."),
    ("函数表达式", r"=\s*function\s*\(|\bfunction\s*\("),
    ("catch 带类型", r"catch\s*\(\s*\w+\s*:"),
    ("throw 非 Error", r"throw\s+['\"0-9]"),
    ("受限 stdlib",
     r"\b(eval|Object\.(assign|create|freeze|fromEntries|getPrototypeOf|seal|setPrototypeOf)"
     r"|Reflect\.)\s*\("),
    ("Symbol()", r"\bSymbol\s*\("),
    ("globalThis", r"\bglobalThis\."),
    ("new Function", r"new\s+Function\s*\("),
    ("import=require/export=", r"import\s+\w+\s*=\s*require|export\s*="),
    # 真私有字段是 `#name`；`'#RRGGBB'` 颜色字面量是 `#` + 6~8 位十六进制，排除掉
    ("# 私有字段", r"#(?![\dA-Fa-f]{3,8}\b)\w+"),
    ("var 声明", r"\bvar\s+\w"),
    ("as const", r"\bas\s+const\b"),
    ("with 语句", r"\bwith\s*\("),
    ("ESObject", r"\bESObject\b"),
    ("fn.bind(this)", r"\.bind\s*\(\s*this"),
]


def strip_noise(line: str) -> str:
    # 去掉行注释和字符串字面量，避免注释/文案里出现关键字造成误报
    line = re.sub(r"//.*$", "", line)
    line = re.sub(r"'(?:[^'\\]|\\.)*'", "''", line)
    line = re.sub(r'"(?:[^"\\]|\\.)*"', '""', line)
    return line


def main() -> int:
    hits: list[tuple[str, int, str, str]] = []
    for p in sorted(HARMONY.rglob("*.ets")):
        for lineno, raw in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
            line = strip_noise(raw)
            for label, pat in RULES:
                if re.search(pat, line):
                    hits.append((str(p.relative_to(ROOT)), lineno, label, raw.strip()))
                    break  # 一行只报第一条
    for f, n, label, text in hits:
        print(f"{f}:{n}  [{label}]  {text[:90]}")
    print(f"\n共 {len(hits)} 处（多为警告级/坏味道，人工确认）")
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
