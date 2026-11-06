#!/usr/bin/env python3
"""找一个函数/方法「声明了但没人调」的情况。

    python scripts/dead_code.py            # 全仓检查，有问题退出码 1
    python scripts/dead_code.py --json     # 给 CI 用

为什么要自己写：这个仓库有五种语言（Python / Java / Swift / ArkTS / Shell），
没有一种通用工具都覆盖。Python 交给 vulture（装了就跑，没装就跳过），
其余四种用「声明 + 调点数」的粗匹配。

三条已知误报，脚本里做了规避，改匹配规则时别把它们弄丢：
  1. **@Watch('名字')** —— ArkTS 的 Watch 回调是字符串引用，`grep 名字(`
     一个都找不到，但运行时会被调用。凡是文件里出现 `'名字'` 就算被用。
  2. **@Override / override** —— 生命周期和协议方法是框架回调（onCreate、
     makeUIView、onPageShow…），调用点在系统里。
  3. **OpenWrt init 钩子** —— start_service / stop_service / reload_service /
     service_triggers 由 /etc/rc.common 调，脚本里看不到调用点。

输出的是「候选」，不是判决书。删之前还是得看一眼：这东西是不是留着给
下一个界面用的。
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 框架回调：声明在业务代码里，调用点在系统框架里
SKIP_NAMES = {
    # Android / Java
    "onCreate", "onStart", "onResume", "onPause", "onStop", "onDestroy",
    "onCreateView", "onViewCreated", "onDestroyView", "onAttach", "onDetach",
    "onSaveInstanceState", "onConfigurationChanged", "onBackPressed",
    "onPageFinished", "onProgressChanged", "onAnimationUpdate", "onAnimationEnd",
    "onAnimationStart", "onValueSelected", "onNothingSelected", "performClick",
    "getFormattedValue", "getOnBackPressedDispatcher", "handleOnBackPressed",
    "setOnChartValueSelectedListener", "onDraw", "onMeasure", "onLayout",
    "do_GET", "do_POST", "do_PUT", "do_PATCH", "do_HEAD", "do_OPTIONS",
    "log_message", "run",
    # Swift
    "makeUIView", "updateUIView", "dismantleUIView", "makeCoordinator",
    "application", "scene", "body", "onAppear", "onDisappear",
    # ArkTS
    "aboutToAppear", "aboutToDisappear", "onPageShow", "onPageHide",
    "onBackPress", "onWindowStageCreate", "onWindowStageDestroy",
    "onForeground", "onBackground", "onConfigurationUpdate", "onDestroy",
    "build", "redraw", "onTab", "onWidth",
    # Shell（/etc/rc.common）
    "start_service", "stop_service", "reload_service", "service_triggers",
    "boot", "shutdown",
    # 语言关键字被正则误当函数名时的兜底
    "if", "for", "while", "switch", "catch", "return", "new", "case",
}

SKIP_DIRS = {".git", "build", "dist", "node_modules", "__pycache__", ".workbuddy"}


def walk(exts: tuple[str, ...]) -> list[str]:
    out: list[str] = []
    for base, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for f in files:
            if f.endswith(exts):
                out.append(os.path.join(base, f))
    return out


def text_of(path: str) -> str:
    try:
        with open(path, encoding="utf-8", errors="ignore") as fh:
            return fh.read()
    except OSError:
        return ""


def used_in(name: str, blob: str, extra: tuple[str, ...] = ()) -> bool:
    """名字在全文里除了声明之外还有没有出现（调用、属性访问、字符串引用）。"""
    if len(re.findall(r"\b" + re.escape(name) + r"\b", blob)) > 1:
        return True
    for pat in extra:
        if re.search(pat.replace("NAME", re.escape(name)), blob):
            return True
    return False


# ---------------------------------------------------------------- Python

def check_py() -> list[dict]:
    try:
        import vulture  # noqa: F401
    except ImportError:
        print("  (未安装 vulture，跳过 Python；pip install vulture 可启用)")
        return []
    r = subprocess.run(
        [sys.executable, "-m", "vulture", ".", "--exclude=.git,dist,build,node_modules",
         "--min-confidence", "60"],
        cwd=ROOT, capture_output=True, text=True, timeout=120,
    )
    out = []
    for line in r.stdout.splitlines():
        m = re.match(r"(.+?):(\d+): (.+)", line.strip())
        if m:
            out.append({"lang": "py", "file": m.group(1), "line": int(m.group(2)),
                        "what": m.group(3)})
    return out


# ---------------------------------------------------------------- 通用「方法声明」

def decl_pattern(ext: str) -> re.Pattern:
    if ext == ".java":
        return re.compile(
            r"^[ \t]*(?:@\w+(?:\([^)]*\))?\s+)*"
            r"(?:public|protected|private|static|final|synchronized|abstract|native|\s)*"
            r"[\w<>\[\],.?\s]+\s+(\w+)\s*\([^;{]*\)\s*(?:throws [\w, .]+)?\{", re.M)
    if ext == ".swift":
        return re.compile(
            r"^[ \t]*(?:@\w+(?:\([^)]*\))?\s+)*(?:public|private|fileprivate|internal|static|"
            r"class|mutating|\s)*func\s+(\w+)\s*[(<]", re.M)
    if ext == ".ets":
        return re.compile(
            r"^[ \t]*(?:@\w+\s+)*(?:private|public|protected|static|async|\s)*"
            r"(?:function\s+)?(\w+)\s*\([^)]*\)\s*(?::\s*[\w<>\[\]|. ]+)?\s*\{", re.M)
    return re.compile(
        r"^\s*(?:export\s+)?(?:async\s+)?function\s+(\w+)\s*\(", re.M)


def check_decls(exts: tuple[str, ...], lang: str) -> list[dict]:
    files = walk(exts)
    blob = "\n".join(text_of(f) for f in files)
    out: list[dict] = []
    for path in files:
        src = text_of(path)
        pat = decl_pattern(os.path.splitext(path)[1])
        for m in pat.finditer(src):
            name = m.group(1)
            if name in SKIP_NAMES or name[:1].isupper():
                continue                      # 跳过框架回调与构造器
            line = src[:m.start()].count("\n") + 1
            head = src[max(0, m.start() - 240):m.start()]
            if re.search(r"@Override\s*$", head) or re.search(r"\boverride\s", src[m.start():m.end()]):
                continue
            # ArkUI V2 的 @Monitor / @Computed 装饰的方法由框架按路径调用，
            # 方法名不会以字符串形式出现，按「名字没被引用」判会全部误报。
            # 只看紧邻的 2 行，避免把上一个方法的装饰器算到当前方法头上。
            near = "\n".join(head.rstrip().split("\n")[-2:])
            if re.search(r"@(Monitor|Computed)\s*\(", near):
                continue
            # ArkTS 的 @Watch('x')、Swift 的 #selector(x)、JS 的 this.x 都算引用
            if used_in(name, blob, (r"['\"]NAME['\"]", r"::NAME\b")):
                continue
            out.append({"lang": lang, "file": os.path.relpath(path, ROOT),
                        "line": line, "what": name})
    return out


def main() -> int:
    as_json = "--json" in sys.argv
    rows: list[dict] = []
    print("== Python（vulture）")
    rows += check_py()
    for ext, lang in (((".java",), "java"), ((".swift",), "swift"),
                      ((".ets",), "ets"), ((".html", ".htm"), "js"), ((".sh",), "sh")):
        print(f"== {lang}")
        rows += check_decls(ext, lang)

    if as_json:
        print(json.dumps(rows, ensure_ascii=False, indent=1))
    else:
        for r in rows:
            print(f"  {r['file']}:{r['line']}  {r['what']}")
        print(f"\n共 {len(rows)} 处候选（人工确认后再删）")
    return 1 if rows else 0


if __name__ == "__main__":
    sys.exit(main())
