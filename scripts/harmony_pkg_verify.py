#!/usr/bin/env python3
"""校验鸿蒙产物（.hap / .app）：版本、包名、编译模式、签名类型。

为什么需要这个脚本：`entry-default-signed.hap` 这个名字**不代表**包真的签过名，
也不代表签名类型是发布证书。上架前必须自己验，否则会出现「打了 debug 签名的包
还自称 release」——AGC 会直接拒，或者更糟：审核通过了但用户装不上。

    python scripts/harmony_pkg_verify.py dist/istoreos-0.1.7.hap
    python scripts/harmony_pkg_verify.py dist/xxx.hap --expect-type release
    python scripts/harmony_pkg_verify.py dist/xxx.app --expect-type release

三档检查：

1. **包内元数据**（任何平台都能跑）：解 zip 读 `module.json`，比对
   `harmony/AppScope/app.json5` 的 bundleName / versionName / versionCode，
   检查 `app.buildMode` 与 `app.debug` 是否自洽。
2. **签名验证**（需要 java + hap-sign-tool.jar，通常在装了 DevEco 的机器上）：
   调 `hap-sign-tool verify-app` 出证书链和 profile。
3. **签名类型**（需要上一步）：解析 profile 的 `type` 字段 ——
   `debug` 只能真机调试装，`release` 才能上架/测试分发。

`--expect-type` 用来把这个期望钉死：传 `release` 而上架包实际是 debug 签名，
退出码 1。

不传 `--java` / `--sign-tool` 时自动找 DevEco 默认位置（macOS 与 Windows 各一处），
找不到就跳过第 2、3 档并明确提示「未验签」，**不假装通过**。
"""
from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
import sys
import tempfile
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP_JSON5 = ROOT / "harmony" / "AppScope" / "app.json5"

CANDIDATES = {
    "java": [
        "/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home/bin/java",
        r"C:\Program Files\Huawei\DevEco Studio\jbr\bin\java.exe",
    ],
    "sign_tool": [
        "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar",
        r"C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\lib\hap-sign-tool.jar",
    ],
}

OK, BAD, SKIP = "OK  ", "FAIL", "SKIP"


def first_existing(paths: list[str]) -> str:
    for p in paths:
        if pathlib.Path(p).exists():
            return p
    return ""


def repo_version() -> dict:
    """从 app.json5 读仓库声明的版本（json5 里只有这几个键是纯 JSON 的）。"""
    if not APP_JSON5.exists():
        return {}
    text = APP_JSON5.read_text(encoding="utf-8")
    text = re.sub(r"^\s*//.*$", "", text, flags=re.M)
    try:
        return json.loads(text).get("app", {})
    except json.JSONDecodeError:
        # 有行尾注释时退化成逐键抓取
        out = {}
        for key in ("bundleName", "versionName"):
            m = re.search(rf'"{key}"\s*:\s*"([^"]+)"', text)
            if m:
                out[key] = m.group(1)
        m = re.search(r'"versionCode"\s*:\s*(\d+)', text)
        if m:
            out["versionCode"] = int(m.group(1))
        return out


def read_module_json(pkg: pathlib.Path) -> tuple[dict, str]:
    """返回 (module.json 的 app 段, 说明)。.app 是装了多个 .hap 的 zip。"""
    with zipfile.ZipFile(pkg) as z:
        names = z.namelist()
        if "module.json" in names:
            return json.loads(z.read("module.json")).get("app", {}), "hap"
        inner = [n for n in names if n.endswith(".hap")]
        if not inner:
            raise SystemExit(f"{pkg} 里既没有 module.json 也没有内层 .hap，不是鸿蒙产物")
        # 多个 hap 时取 entry 那个
        pick = next((n for n in inner if "entry" in n), inner[0])
        with tempfile.TemporaryDirectory() as td:
            z.extract(pick, td)
            with zipfile.ZipFile(pathlib.Path(td) / pick) as z2:
                return json.loads(z2.read("module.json")).get("app", {}), f"app({pick})"


def verify_signature(pkg: pathlib.Path, java: str, tool: str) -> tuple[bool, str, dict]:
    """调 hap-sign-tool 验签，并解出 profile 的 type 等字段。"""
    with tempfile.TemporaryDirectory() as td:
        cer, p7b = pathlib.Path(td) / "chain.cer", pathlib.Path(td) / "profile.p7b"
        proc = subprocess.run(
            [java, "-jar", tool, "verify-app", "-inFile", str(pkg),
             "-outCertChain", str(cer), "-outProfile", str(p7b)],
            capture_output=True, text=True, timeout=180,
        )
        out = (proc.stdout or "") + (proc.stderr or "")
        if proc.returncode != 0 or "verify-app success" not in out:
            head = next((ln for ln in out.splitlines() if "ERROR" in ln or "error" in ln), "")
            return False, head.strip() or "verify-app 失败", {}

        info = {}
        if p7b.exists():
            raw = p7b.read_bytes()
            m = re.search(rb"\{.*\}", raw, re.S)
            if m:
                try:
                    prof, _ = json.JSONDecoder().raw_decode(m.group(0).decode("utf-8", "ignore"))
                    info = {
                        "type": prof.get("type", ""),
                        "bundle-name": (prof.get("bundle-info") or {}).get("bundle-name", ""),
                        "not-after": (prof.get("validity") or {}).get("not-after"),
                        "devices": len((prof.get("debug-info") or {}).get("device-ids") or []),
                    }
                except json.JSONDecodeError:
                    info = {"type": "(profile 解析失败)"}
        return True, "", info


def main() -> int:
    ap = argparse.ArgumentParser(description="校验鸿蒙 .hap / .app")
    ap.add_argument("pkg", type=pathlib.Path)
    ap.add_argument("--expect-type", choices=["debug", "release"],
                    help="期望的签名类型；不符则退出码 1")
    ap.add_argument("--java", default="", help="java 可执行文件（默认找 DevEco 自带 JBR）")
    ap.add_argument("--sign-tool", default="", help="hap-sign-tool.jar 路径")
    args = ap.parse_args()

    pkg = args.pkg
    if not pkg.exists():
        print(f"找不到 {pkg}")
        return 2

    fails = 0
    print(f"=== {pkg.name}  ({pkg.stat().st_size / 1048576:.2f} MB) ===")

    # 1. 包内元数据
    app, kind = read_module_json(pkg)
    print(f"\n[产物类型] {kind}")
    print(f"[包名]     {app.get('bundleName')}")
    print(f"[版本]     {app.get('versionName')} ({app.get('versionCode')})")
    print(f"[编译模式] buildMode={app.get('buildMode')}  debug={app.get('debug')}")
    print(f"[API]      min={app.get('minAPIVersion')} target={app.get('targetAPIVersion')}  "
          f"releaseType={app.get('apiReleaseType')}")

    want = repo_version()
    if want:
        for key, label in (("bundleName", "包名"), ("versionName", "版本名"),
                           ("versionCode", "版本号")):
            if want.get(key) in (None, ""):
                continue
            same = app.get(key) == want[key]
            print(f"[对齐{label}] {'一致' if same else '不一致'}  "
                  f"包={app.get(key)} 仓库={want[key]}")
            if not same:
                fails += 1

    # 编译模式与 debug 位必须自洽：release 包若 debug=true，装上就是调试包
    if app.get("buildMode") == "release" and app.get("debug") is True:
        print("[自洽]     buildMode=release 但 debug=true —— 这是调试构建，不能上架")
        fails += 1

    # 2/3. 签名
    java = args.java or first_existing(CANDIDATES["java"])
    tool = args.sign_tool or first_existing(CANDIDATES["sign_tool"])
    print()
    if not (java and tool):
        print(f"[{SKIP}] 未找到 DevEco 的 java / hap-sign-tool.jar，跳过验签")
        print("        在装了 DevEco 的机器上跑，或传 --java / --sign-tool")
        if args.expect_type:
            print(f"[{BAD}] 指定了 --expect-type {args.expect_type} 却没验签，不能算通过")
            fails += 1
        return 1 if fails else 0

    ok, err, info = verify_signature(pkg, java, tool)
    if not ok:
        print(f"[{BAD}] 验签失败：{err}")
        return 1
    stype = info.get("type", "")
    print(f"[{OK}] 签名有效   type={stype}  设备数={info.get('devices', '-')}")
    if info.get("bundle-name") and info["bundle-name"] != app.get("bundleName"):
        print(f"[{BAD}] profile 里的 bundle-name={info['bundle-name']} 与包内不一致")
        fails += 1

    if args.expect_type:
        if stype == args.expect_type:
            print(f"[{OK}] 签名类型符合期望：{stype}")
        else:
            print(f"[{BAD}] 签名类型是 {stype}，期望 {args.expect_type}"
                  + ("（debug 证书只能真机调试，上架必须是 release）"
                     if args.expect_type == "release" else ""))
            fails += 1

    print("\n" + ("全部通过" if not fails else f"{fails} 项不通过"))
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
