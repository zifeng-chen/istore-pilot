#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""跨语言代码规范检查。

为什么不用现成工具：Python 有 ruff，但 Java / Swift / ArkTS 在这台 Windows
机器上没有可用的 linter（SwiftLint 是 macOS 的，ArkTS 要靠 DevEco）。
所以这里实现一份"机械规则"的公共子集，五端一把跑完，结果可复现。

它检查的是**不需要理解语义**的部分：缩进、行宽、尾随空格、换行符、
死代码标记、语言特有的低级错误。语义问题（命名是否达意、函数职责）
仍然靠人看，见 docs/CODE_STYLE.md。

用法：
    python scripts/lint_style.py               # 全仓库，文本报告
    python scripts/lint_style.py --lang py     # 只看一种
    python scripts/lint_style.py --json        # 机器可读
    python scripts/lint_style.py --strict      # warning 也算失败（CI 用）

退出码：0 通过 / 1 有 error（--strict 时有 warning 也算）
"""

from __future__ import annotations

import argparse
import io
import json
import os
import re
import sys
import tokenize
from dataclasses import dataclass, asdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

#: 不看的目录（构建产物、依赖、缓存、第三方）
SKIP_DIRS = {
    ".git", ".workbuddy", "__pycache__", "node_modules", "oh_modules",
    "build", "dist", "Pods", "DerivedData", ".gradle", ".ruff_cache",
    "screenshots", "resources",  # 资源目录里没有代码
    "design",                    # 图标设计源（第三方导出，含长行/行尾空格）
}

#: 各语言的行宽上限，与 docs/CODE_STYLE.md 一致
MAX_LINE = {"py": 110, "java": 110, "swift": 110, "ets": 120, "sh": 120, "md": 0}

LANG_OF = {".py": "py", ".java": "java", ".swift": "swift",
           ".ets": "ets", ".sh": "sh", ".md": "md"}

#: 死代码/待办标记。这些不是错，但评审时要能一眼看到有多少。
MARKERS = re.compile(r"\b(TODO|FIXME|XXX|HACK)\b")

#: 行内字符串字面量超过这个长度就当"数据"（SVG path / base64 / 长 URL），
#: 断行会改变内容，所以不做行宽检查。
DATA_LITERAL = 120
_LITERAL = re.compile(r"'([^'\\]|\\.)*'|\"([^\"\\]|\\.)*\"")


def longest_literal(line: str) -> int:
    return max((len(m.group(0)) for m in _LITERAL.finditer(line)), default=0)


@dataclass
class Issue:
    path: str
    line: int
    col: int
    severity: str       # error / warn
    rule: str
    message: str
    snippet: str = ""


def rel(path: str) -> str:
    return os.path.relpath(path, ROOT).replace(os.sep, "/")


def iter_files(only_lang: str) -> list[tuple[str, str]]:
    out = []
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            ext = os.path.splitext(name)[1].lower()
            lang = LANG_OF.get(ext)
            if not lang:
                continue
            if only_lang and lang != only_lang:
                continue
            out.append((os.path.join(dirpath, name), lang))
    return sorted(out)


# ---------------------------------------------------------------- 通用规则

def py_string_lines(text: str) -> set[int]:
    """Python 文件里处于多行字符串内部的行号。

    `deploy/build_run.py` 里整段 shell 安装器就是一个 raw string，里面的 tab
    是脚本内容不是缩进 —— 不排除的话一次报 460 条，把真问题全埋了。
    """
    lines: set[int] = set()
    try:
        for tok in tokenize.generate_tokens(io.StringIO(text).readline):
            if tok.type == tokenize.STRING and tok.start[0] != tok.end[0]:
                lines.update(range(tok.start[0], tok.end[0] + 1))
    except (tokenize.TokenError, IndentationError, SyntaxError):
        pass
    return lines


def check_common(path: str, lang: str, raw: bytes) -> list[Issue]:
    out: list[Issue] = []
    rp = rel(path)

    # 换行符：仓库统一 LF。CRLF 进 shell 头会让 busybox 报 "not found"。
    if b"\r\n" in raw:
        out.append(Issue(rp, 0, 0, "error", "EOL",
                         "文件含 CRLF，仓库要求 LF"))

    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        out.append(Issue(rp, 0, 0, "error", "ENC", "不是合法的 UTF-8"))
        return out

    # 文件末尾：恰好一个换行
    if text and not text.endswith("\n"):
        out.append(Issue(rp, text.count("\n") + 1, 0, "error", "EOF",
                         "文件末尾缺少换行"))
    elif text.endswith("\n\n") and lang != "md":
        out.append(Issue(rp, text.count("\n"), 0, "warn", "EOF",
                         "文件末尾有多余空行"))

    limit = MAX_LINE.get(lang, 0)
    # 生成文件（带 @generated 头）不按行宽要求：里面的长串是路径数据 / 表格，
    # 由生成脚本负责排版，人工改不了也不该改
    if "@generated" in text[:400]:
        limit = 0
    skip = py_string_lines(text) if lang == "py" else set()
    blank_run = 0
    for i, line in enumerate(text.splitlines(), 1):
        # 行尾空格
        if line != line.rstrip():
            out.append(Issue(rp, i, len(line.rstrip()) + 1, "warn", "TRAIL",
                             "行尾有空格", line.strip()[:40]))

        # 禁 tab 缩进：只对「用空格缩进」的语言要求。shell 对缩进不敏感，
        # heredoc 里也常有 tab，不算问题。
        if line.startswith("\t") and lang in ("py", "java", "swift", "ets") and i not in skip:
            out.append(Issue(rp, i, 1, "error", "TAB",
                             "用 tab 缩进（规范要求空格）", line.strip()[:40]))

        # 行宽（模板字符串里的长行不按代码算）。
        # 确实断不开的（长 URL、长提示语）在行尾写 style-ok 豁免。
        if limit and len(line) > limit and i not in skip \
                and "style-ok" not in line and longest_literal(line) <= DATA_LITERAL:
            out.append(Issue(rp, i, limit + 1, "warn", "WIDTH",
                             "行宽 %d 超过 %d" % (len(line), limit),
                             line.strip()[:50]))

        # 连续空行
        if not line.strip():
            blank_run += 1
            if blank_run == 3 and lang != "md":
                out.append(Issue(rp, i, 1, "warn", "BLANK",
                                 "连续 3 行以上空行"))
        else:
            blank_run = 0

        if "MARKERS = re.compile" in line:
            continue
        for m in MARKERS.finditer(line):
            out.append(Issue(rp, i, m.start() + 1, "warn", "MARK",
                             "未处理标记 %s" % m.group(1), line.strip()[:60]))

    return out


# ---------------------------------------------------------------- 语言规则

def check_py(issues: list[Issue], rp: str, text: str) -> None:
    for i, line in enumerate(text.splitlines(), 1):
        s = line.strip()
        # agent 是服务端，print 会进 stdout 而不是 logread，排查时会丢
        if s.startswith("print(") and "/agent/" in "/" + rp \
                and "[istore-agent]" not in s:
            issues.append(Issue(rp, i, 1, "warn", "PY-PRINT",
                                "agent 里用 print，应走日志", s[:50]))
        if re.match(r"except\s*:\s*$", s):
            issues.append(Issue(rp, i, 1, "error", "PY-BARE-EXCEPT",
                                "裸 except 会吞掉 KeyboardInterrupt", s[:50]))


def check_java(issues: list[Issue], rp: str, text: str) -> None:
    for i, line in enumerate(text.splitlines(), 1):
        s = line.strip()
        if "System.out.print" in s or "System.err.print" in s:
            issues.append(Issue(rp, i, 1, "warn", "JAVA-SYSOUT",
                                "用 Log 而不是 System.out", s[:50]))
        if "printStackTrace()" in s:
            issues.append(Issue(rp, i, 1, "warn", "JAVA-STACKTRACE",
                                "printStackTrace 在 release 里看不到，用 Log.e", s[:50]))
    for m in re.finditer(r"catch\s*\([^)]*\)\s*\{\s*\}", text):
        line = text[:m.start()].count("\n") + 1
        issues.append(Issue(rp, line, 1, "error", "JAVA-EMPTY-CATCH",
                            "空的 catch 块，异常被吞"))


def check_swift(issues: list[Issue], rp: str, text: str) -> None:
    for i, line in enumerate(text.splitlines(), 1):
        s = line.strip()
        if s.startswith("print("):
            issues.append(Issue(rp, i, 1, "warn", "SWIFT-PRINT",
                                "调试用的 print 会进控制台，考虑去掉", s[:50]))
        # 强解包：排除 !=、!x（取反）、as!/try!（这两类是有意为之）
        for m in re.finditer(r"(?<![=!<>])\b\w+!(?!=)", line):
            frag = line[max(0, m.start() - 12):m.end() + 6]
            if "try!" in frag or "as!" in frag:
                continue
            # `navigation: WKNavigation!` 是声明类型（协议方法签名 / IBOutlet），
            # 不是解包。判据是 `!` 前面紧挨着类型位置——也就是 `:` 或 `->` 结尾。
            tail = line[:m.start()].rstrip()
            if tail.endswith(":") or tail.endswith("->"):
                continue
            issues.append(Issue(rp, i, m.start() + 1, "warn", "SWIFT-FORCE",
                                "强制解包，可能崩", frag.strip()[:50]))


def check_ets(issues: list[Issue], rp: str, text: str) -> None:
    for i, line in enumerate(text.splitlines(), 1):
        s = line.strip()
        if "ESObject" in s:
            issues.append(Issue(rp, i, 1, "error", "ETS-ESOBJECT",
                                "ArkTS 规则禁止 ESObject", s[:50]))
        if re.search(r"\bArray<", line):
            issues.append(Issue(rp, i, 1, "warn", "ETS-ARRAY",
                                "用 T[] 而不是 Array<T>", s[:50]))
        # 双引号字符串（ArkTS 推荐单引号）；装饰器与 JSON 里的不算
        if re.search(r'(?<![\\])"', line) and not s.startswith("//") \
                and not s.startswith("/*") and not s.startswith("*") \
                and "fontFeature" not in line:
            if re.search(r'"[^"]*"', line) and "'" not in line:
                issues.append(Issue(rp, i, 1, "warn", "ETS-QUOTE",
                                    "字符串建议用单引号", s[:50]))
        # 浮点省略小数点前的 0
        if re.search(r"(?<![\w.)])\.\d+\b", line) and "..." not in line:
            issues.append(Issue(rp, i, 1, "warn", "ETS-FLOAT",
                                "浮点不要省略小数点前的 0", s[:50]))
        # 条件/循环不带大括号。只认「整行以 ) 结尾」的形式：跨行条件
        # （if (a ||\n b) {）和正常带块的都不该报。
        if re.match(r"^\s*(if|for|while)\s*\(", line) and line.rstrip().endswith(")"):
            issues.append(Issue(rp, i, 1, "warn", "ETS-BRACE",
                                "条件/循环建议带大括号", s[:50]))


def check_sh(issues: list[Issue], rp: str, text: str) -> None:
    for i, line in enumerate(text.splitlines(), 1):
        s = line.strip()
        if s.startswith("#") or not s:
            continue
        # 变量引用不加引号（宽松判定：赋值给命令参数时才算）
        if re.search(r"\$[A-Za-z_]\w*", line) and not re.search(r'"?\$\{?[A-Za-z_]', line):
            issues.append(Issue(rp, i, 1, "warn", "SH-QUOTE",
                                "变量引用建议加引号", s[:50]))
        if re.search(r"\brm\s+-rf\s+/\s*$", line):
            issues.append(Issue(rp, i, 1, "error", "SH-RMRF",
                                "rm -rf / 是灾难", s[:50]))


CHECKERS = {"py": check_py, "java": check_java, "swift": check_swift,
            "ets": check_ets, "sh": check_sh}


# ---------------------------------------------------------------- 主流程

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--lang", choices=sorted(set(LANG_OF.values())), default="")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--strict", action="store_true")
    args = ap.parse_args()

    issues: list[Issue] = []
    files = iter_files(args.lang)
    for path, lang in files:
        try:
            with open(path, "rb") as fh:
                raw = fh.read()
        except OSError as exc:
            print("跳过 %s：%s" % (rel(path), exc), file=sys.stderr)
            continue
        found = check_common(path, lang, raw)
        text = raw.decode("utf-8", "replace")
        CHECKERS.get(lang, lambda *a: None)(found, rel(path), text)
        issues.extend(found)

    errors = [i for i in issues if i.severity == "error"]
    warns = [i for i in issues if i.severity == "warn"]

    if args.json:
        print(json.dumps([asdict(i) for i in issues], ensure_ascii=False, indent=1))
    else:
        by_rule: dict[str, int] = {}
        for i in issues:
            by_rule[i.rule] = by_rule.get(i.rule, 0) + 1
        print("\n检查 %d 个文件，%d error / %d warn\n" % (len(files), len(errors), len(warns)))
        if by_rule:
            print("按规则：")
            for rule, n in sorted(by_rule.items(), key=lambda kv: -kv[1]):
                print("  %-18s %4d" % (rule, n))
            print()
        for label, group in (("ERROR", errors), ("WARN", warns)):
            if not group:
                continue
            print("%s（%d）" % (label, len(group)))
            shown = group[:60] if not args.strict else group
            for i in shown:
                print("  %s:%d:%d  %s  %s" % (i.path, i.line, i.col, i.rule, i.message))
                if i.snippet:
                    print("      %s" % i.snippet)
            if len(group) > len(shown):
                print("  …… 还有 %d 条（--strict 看全部）" % (len(group) - len(shown)))
            print()

    if errors:
        return 1
    if args.strict and warns:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
