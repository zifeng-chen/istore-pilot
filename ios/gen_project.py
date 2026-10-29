#!/usr/bin/env python3
"""生成 IStorePilot.xcodeproj。

手写 pbxproj 容易错一个分号就整份打不开，所以用脚本生成：
UUID 由文件路径算出（稳定、可重复），加了新 .swift 只要重跑一次。

    python gen_project.py

用 objectVersion=56（Xcode 14 ~ 27 都认），不用 Xcode 16 的
文件夹同步格式 —— 那个格式在旧版本上会直接读不出来。
"""

from __future__ import annotations

import hashlib
import os

ROOT = os.path.dirname(os.path.abspath(__file__))
APP = "IStorePilot"
PROJ = "IStorePilot.xcodeproj"
BUNDLE_ID = "com.chaof.istoreos"
NAME = "iStore Pilot"
VERSION = "0.1.3"
BUILD = "26"
DEPLOY = "16.0"


def uid(key: str) -> str:
    """24 位大写 hex，由 key 稳定推导。"""
    return hashlib.md5(key.encode()).hexdigest()[:24].upper()


def scan():
    """收集所有需要编译的 swift 和资源。"""
    base = os.path.join(ROOT, APP)
    swift, groups = [], {}
    for dirpath, _, files in os.walk(base):
        rel = os.path.relpath(dirpath, ROOT).replace("\\", "/")
        for f in sorted(files):
            if f.endswith(".swift"):
                p = f"{rel}/{f}"
                swift.append(p)
                sub = os.path.relpath(dirpath, base).replace("\\", "/")
                groups.setdefault("" if sub == "." else sub, []).append(p)
    return sorted(swift), groups


def main() -> int:
    swift, groups = scan()
    assets = f"{APP}/Assets.xcassets"
    plist = f"{APP}/Info.plist"

    out = []
    a = out.append

    a("// !$*UTF8*$!")
    a("{")
    a("\tarchiveVersion = 1;")
    a("\tclasses = {")
    a("\t};")
    a("\tobjectVersion = 56;")
    a("\tobjects = {")

    # ---------- PBXBuildFile ----------
    a("\n/* Begin PBXBuildFile section */")
    for p in swift:
        a(f"\t\t{uid('bf:' + p)} /* {os.path.basename(p)} in Sources */ = "
          f"{{isa = PBXBuildFile; fileRef = {uid('fr:' + p)} /* {os.path.basename(p)} */; }};")
    a(f"\t\t{uid('bf:' + assets)} /* Assets.xcassets in Resources */ = "
      f"{{isa = PBXBuildFile; fileRef = {uid('fr:' + assets)} /* Assets.xcassets */; }};")
    a("/* End PBXBuildFile section */")

    # ---------- PBXFileReference ----------
    a("\n/* Begin PBXFileReference section */")
    for p in swift:
        a(f"\t\t{uid('fr:' + p)} /* {os.path.basename(p)} */ = "
          f"{{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; "
          f"path = {os.path.basename(p)}; sourceTree = \"<group>\"; }};")
    a(f"\t\t{uid('fr:' + assets)} /* Assets.xcassets */ = "
      f"{{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; "
      f"path = Assets.xcassets; sourceTree = \"<group>\"; }};")
    a(f"\t\t{uid('fr:' + plist)} /* Info.plist */ = "
      f"{{isa = PBXFileReference; lastKnownFileType = text.plist.xml; "
      f"path = Info.plist; sourceTree = \"<group>\"; }};")
    a(f"\t\t{uid('fr:product')} /* {APP}.app */ = "
      f"{{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; "
      f"path = {APP}.app; sourceTree = BUILT_PRODUCTS_DIR; }};")
    a("/* End PBXFileReference section */")

    # ---------- PBXFrameworksBuildPhase ----------
    a("\n/* Begin PBXFrameworksBuildPhase section */")
    a(f"\t\t{uid('frameworks')} /* Frameworks */ = {{")
    a("\t\t\tisa = PBXFrameworksBuildPhase;")
    a("\t\t\tbuildActionMask = 2147483647;")
    a("\t\t\tfiles = (")
    a("\t\t\t);")
    a("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    a("\t\t};")
    a("/* End PBXFrameworksBuildPhase section */")

    # ---------- PBXGroup ----------
    a("\n/* Begin PBXGroup section */")
    # 主组
    a(f"\t\t{uid('group:main')} = {{")
    a("\t\t\tisa = PBXGroup;")
    a("\t\t\tchildren = (")
    a(f"\t\t\t\t{uid('group:' + APP)} /* {APP} */,")
    a(f"\t\t\t\t{uid('group:products')} /* Products */,")
    a("\t\t\t);")
    a("\t\t\tsourceTree = \"<group>\";")
    a("\t\t};")
    # Products
    a(f"\t\t{uid('group:products')} /* Products */ = {{")
    a("\t\t\tisa = PBXGroup;")
    a("\t\t\tchildren = (")
    a(f"\t\t\t\t{uid('fr:product')} /* {APP}.app */,")
    a("\t\t\t);")
    a("\t\t\tname = Products;")
    a("\t\t\tsourceTree = \"<group>\";")
    a("\t\t};")

    # App 组（含子组）
    sub_names = sorted([g for g in groups if g], key=lambda s: s.lower())
    a(f"\t\t{uid('group:' + APP)} /* {APP} */ = {{")
    a("\t\t\tisa = PBXGroup;")
    a("\t\t\tchildren = (")
    for p in groups.get("", []):
        a(f"\t\t\t\t{uid('fr:' + p)} /* {os.path.basename(p)} */,")
    for g in sub_names:
        a(f"\t\t\t\t{uid('group:' + g)} /* {g.split('/')[-1]} */,")
    a(f"\t\t\t\t{uid('fr:' + assets)} /* Assets.xcassets */,")
    a(f"\t\t\t\t{uid('fr:' + plist)} /* Info.plist */,")
    a("\t\t\t);")
    a(f"\t\t\tpath = {APP};")
    a("\t\t\tsourceTree = \"<group>\";")
    a("\t\t};")

    # 子组
    for g in sub_names:
        a(f"\t\t{uid('group:' + g)} /* {g.split('/')[-1]} */ = {{")
        a("\t\t\tisa = PBXGroup;")
        a("\t\t\tchildren = (")
        for p in groups[g]:
            a(f"\t\t\t\t{uid('fr:' + p)} /* {os.path.basename(p)} */,")
        a("\t\t\t);")
        a(f"\t\t\tpath = {g};")
        a("\t\t\tsourceTree = \"<group>\";")
        a("\t\t};")
    a("/* End PBXGroup section */")

    # ---------- PBXNativeTarget ----------
    a("\n/* Begin PBXNativeTarget section */")
    a(f"\t\t{uid('target')} /* {APP} */ = {{")
    a("\t\t\tisa = PBXNativeTarget;")
    a(f"\t\t\tbuildConfigurationList = {uid('cfglist:target')} "
      f"/* Build configuration list for PBXNativeTarget \"{APP}\" */;")
    a("\t\t\tbuildPhases = (")
    a(f"\t\t\t\t{uid('sources')} /* Sources */,")
    a(f"\t\t\t\t{uid('frameworks')} /* Frameworks */,")
    a(f"\t\t\t\t{uid('resources')} /* Resources */,")
    a("\t\t\t);")
    a("\t\t\tbuildRules = (")
    a("\t\t\t);")
    a("\t\t\tdependencies = (")
    a("\t\t\t);")
    a(f"\t\t\tname = {APP};")
    a(f"\t\t\tproductName = {APP};")
    a(f"\t\t\tproductReference = {uid('fr:product')} /* {APP}.app */;")
    a("\t\t\tproductType = \"com.apple.product-type.application\";")
    a("\t\t};")
    a("/* End PBXNativeTarget section */")

    # ---------- PBXProject ----------
    a("\n/* Begin PBXProject section */")
    a(f"\t\t{uid('project')} /* Project object */ = {{")
    a("\t\t\tisa = PBXProject;")
    a("\t\t\tattributes = {")
    a("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
    a("\t\t\t\tLastSwiftUpdateCheck = 1600;")
    a("\t\t\t\tLastUpgradeCheck = 1600;")
    a("\t\t\t\tTargetAttributes = {")
    a(f"\t\t\t\t\t{uid('target')} = {{")
    a("\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;")
    a("\t\t\t\t\t};")
    a("\t\t\t\t};")
    a("\t\t\t};")
    a(f"\t\t\tbuildConfigurationList = {uid('cfglist:project')} "
      f"/* Build configuration list for PBXProject \"{APP}\" */;")
    a("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
    a("\t\t\tdevelopmentRegion = \"zh-Hans\";")
    a("\t\t\thasScannedForEncodings = 0;")
    a("\t\t\tknownRegions = (")
    a("\t\t\t\t\"zh-Hans\",")
    a("\t\t\t\tBase,")
    a("\t\t\t);")
    a(f"\t\t\tmainGroup = {uid('group:main')};")
    a(f"\t\t\tproductRefGroup = {uid('group:products')} /* Products */;")
    a("\t\t\tprojectDirPath = \"\";")
    a("\t\t\tprojectRoot = \"\";")
    a("\t\t\ttargets = (")
    a(f"\t\t\t\t{uid('target')} /* {APP} */,")
    a("\t\t\t);")
    a("\t\t};")
    a("/* End PBXProject section */")

    # ---------- PBXResourcesBuildPhase ----------
    a("\n/* Begin PBXResourcesBuildPhase section */")
    a(f"\t\t{uid('resources')} /* Resources */ = {{")
    a("\t\t\tisa = PBXResourcesBuildPhase;")
    a("\t\t\tbuildActionMask = 2147483647;")
    a("\t\t\tfiles = (")
    a(f"\t\t\t\t{uid('bf:' + assets)} /* Assets.xcassets in Resources */,")
    a("\t\t\t);")
    a("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    a("\t\t};")
    a("/* End PBXResourcesBuildPhase section */")

    # ---------- PBXSourcesBuildPhase ----------
    a("\n/* Begin PBXSourcesBuildPhase section */")
    a(f"\t\t{uid('sources')} /* Sources */ = {{")
    a("\t\t\tisa = PBXSourcesBuildPhase;")
    a("\t\t\tbuildActionMask = 2147483647;")
    a("\t\t\tfiles = (")
    for p in swift:
        a(f"\t\t\t\t{uid('bf:' + p)} /* {os.path.basename(p)} in Sources */,")
    a("\t\t\t);")
    a("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    a("\t\t};")
    a("/* End PBXSourcesBuildPhase section */")

    # ---------- XCBuildConfiguration ----------
    common = [
        "ALWAYS_SEARCH_USER_PATHS = NO;",
        "CLANG_ANALYZER_NONNULL = YES;",
        "CLANG_ENABLE_MODULES = YES;",
        "CLANG_ENABLE_OBJC_ARC = YES;",
        "CLANG_WARN_BOOL_CONVERSION = YES;",
        "CLANG_WARN_DOCUMENTATION_COMMENTS = YES;",
        "CLANG_WARN_EMPTY_BODY = YES;",
        "CLANG_WARN_ENUM_CONVERSION = YES;",
        "CLANG_WARN_INT_CONVERSION = YES;",
        "CLANG_WARN_UNREACHABLE_CODE = YES;",
        "COPY_PHASE_STRIP = NO;",
        f'IPHONEOS_DEPLOYMENT_TARGET = "{DEPLOY}";',
        "SDKROOT = iphoneos;",
        "SWIFT_VERSION = 5.0;",
        "ENABLE_USER_SCRIPT_SANDBOXING = NO;",
    ]
    target_common = [
        "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = \"\";",
        "CODE_SIGN_STYLE = Automatic;",
        "CURRENT_PROJECT_VERSION = " + BUILD + ";",
        "ENABLE_PREVIEWS = YES;",
        "GENERATE_INFOPLIST_FILE = NO;",
        f"INFOPLIST_FILE = {APP}/Info.plist;",
        "LD_RUNPATH_SEARCH_PATHS = (",
        '\t"$(inherited)",',
        '\t"@executable_path/Frameworks",',
        ");",
        f'MARKETING_VERSION = "{VERSION}";',
        "PRODUCT_BUNDLE_IDENTIFIER = " + BUNDLE_ID + ";",
        "PRODUCT_NAME = \"$(TARGET_NAME)\";",
        "SWIFT_EMIT_LOC_STRINGS = YES;",
        "TARGETED_DEVICE_FAMILY = 1;",
    ]

    a("\n/* Begin XCBuildConfiguration section */")

    def cfg(uuid_key, name, settings, extra):
        a(f"\t\t{uuid_key} /* {name} */ = {{")
        a("\t\t\tisa = XCBuildConfiguration;")
        a("\t\t\tbuildSettings = {")
        for s in extra:
            a(f"\t\t\t\t{s}")
        for s in settings:
            a(f"\t\t\t\t{s}")
        a("\t\t\t};")
        a(f"\t\t\tname = {name};")
        a("\t\t};")

    cfg(uid("cfg:project:Debug"), "Debug",
        common + ["SWIFT_OPTIMIZATION_LEVEL = \"-Onone\";",
                  "SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;",
                  "GCC_OPTIMIZATION_LEVEL = 0;",
                  "ONLY_ACTIVE_ARCH = YES;",
                  "DEBUG_INFORMATION_FORMAT = dwarf;"],
        ["PRODUCT_NAME = \"$(TARGET_NAME)\";"])
    cfg(uid("cfg:project:Release"), "Release",
        common + ["SWIFT_OPTIMIZATION_LEVEL = \"-O\";",
                  "SWIFT_COMPILATION_MODE = wholemodule;",
                  "VALIDATE_PRODUCT = YES;",
                  "DEBUG_INFORMATION_FORMAT = \"dwarf-with-dsym\";"],
        ["PRODUCT_NAME = \"$(TARGET_NAME)\";"])
    cfg(uid("cfg:target:Debug"), "Debug", target_common +
        ["SWIFT_OPTIMIZATION_LEVEL = \"-Onone\";"], [])
    cfg(uid("cfg:target:Release"), "Release", target_common +
        ["SWIFT_COMPILATION_MODE = wholemodule;"], [])
    a("/* End XCBuildConfiguration section */")

    # ---------- XCConfigurationList ----------
    a("\n/* Begin XCConfigurationList section */")
    for key, label in (("cfglist:project", f"PBXProject \"{APP}\""),
                       ("cfglist:target", f"PBXNativeTarget \"{APP}\"")):
        a(f"\t\t{uid(key)} /* Build configuration list for {label} */ = {{")
        a("\t\t\tisa = XCConfigurationList;")
        a("\t\t\tbuildConfigurations = (")
        if key == "cfglist:project":
            a(f"\t\t\t\t{uid('cfg:project:Debug')} /* Debug */,")
            a(f"\t\t\t\t{uid('cfg:project:Release')} /* Release */,")
        else:
            a(f"\t\t\t\t{uid('cfg:target:Debug')} /* Debug */,")
            a(f"\t\t\t\t{uid('cfg:target:Release')} /* Release */,")
        a("\t\t\t);")
        a("\t\t\tdefaultConfigurationIsVisible = 0;")
        a("\t\t\tdefaultConfigurationName = Release;")
        a("\t\t};")
    a("/* End XCConfigurationList section */")

    a("\t};")
    a(f"\trootObject = {uid('project')} /* Project object */;")
    a("}")

    text = "\n".join(out) + "\n"

    d = os.path.join(ROOT, PROJ)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "project.pbxproj"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)

    print(f"{os.path.join(PROJ, 'project.pbxproj')}   {len(swift)} 个 swift 文件")
    for p in swift:
        print("  ", p)
    print(f"Bundle: {BUNDLE_ID}   名称: {NAME}   版本: {VERSION} ({BUILD})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
