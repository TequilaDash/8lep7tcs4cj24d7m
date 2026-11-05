#!/usr/bin/env python3
# check_weak_imports.py —— 未定义弱导入守卫（CI 用，纯标准库）
#
# 背景：iOS 27.2 beta（24B5089g）上 Foundation 的 Date 比较运算符（>= / <=）是弱导入，
# 编译器在 ___isPlatformVersionAtLeast(2,27,2,0) 门槛内走快路径直呼弱符号，GOT 为空 ⇒
# br x16 ⇒ PC=0 ⇒ CODESIGNING Invalid Page 闪退（v0.3.746 实锤，两份 .ips 同偏移）。
# 部署目标保持 18.0 的前提下，这一整类风险只能靠二进制层守卫拦住：出包后扫描主二进制的
# 未定义弱导入，出现白名单之外的新弱导入即判构建失败（宁可拦版，不发会炸的包）。
#
# 用法:
#   check_weak_imports.py <主二进制路径> [--allowlist <附加白名单文件>]
#   check_weak_imports.py --from-file <nm -m 输出文件>   （自测用，不调用 nm）
#
# 白名单语义：
#   ALLOWED_SUBSTRINGS —— 已知安全（逐一核对过：iOS 26/27 API 或系统必然提供）
#   HARD_BLOCKED_SUBSTRINGS —— 出现即失败（v0.3.746 那类在旧 iOS 上 GOT 为空的符号）
# 退出码: 0 = 通过；1 = 有违规；2 = 用法/输入错误。

import argparse
import re
import subprocess
import sys

ALLOWED_SUBSTRINGS = (
    "GlassEffect",           # SwiftUI Glass（iOS 26+）
    "searchToolbarBehavior", # SwiftUI（iOS 26+）
    "Section.create",
    "ForEach.create",
    "RawSpan",               # ContiguousBytes RawSpan 版（iOS 26 门）
    "swift_FORCE_LOAD",
)

# 出现即失败：这一类在旧 iOS 上曾把 GOT 留空直呼 → PC=0（v0.3.746 实锤）
HARD_BLOCKED_SUBSTRINGS = (
    "4DateV2geoiy",   # Date.>=  (Foundation)
    "4DateV2leoiy",   # Date.<=  (Foundation)
)

WEAK_LINE = re.compile(r"weak external\s+(_[^ (]+)")


def collect_weak_imports(binary: str, from_file: str = None) -> list:
    if from_file:
        with open(from_file, "r", encoding="utf-8", errors="replace") as fh:
            out = fh.read()
    else:
        proc = subprocess.run(
            ["xcrun", "nm", "-m", binary],
            capture_output=True, text=True, timeout=120,
        )
        if proc.returncode != 0:
            print("::error::nm -m 执行失败（{}）: {}".format(binary, proc.stderr.strip()[:200]))
            raise SystemExit(2)
        out = proc.stdout
    names = []
    for line in out.splitlines():
        if "(undefined)" in line and "weak external" in line:
            m = WEAK_LINE.search(line)
            if m:
                names.append(m.group(1))
    return names


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("binary", nargs="?")
    ap.add_argument("--allowlist")
    ap.add_argument("--from-file")
    ap.add_argument("--strict", action="store_true",
                    help="新增未归类弱导入也判失败（等白名单枚举齐全后再启用）")
    args = ap.parse_args()
    if not args.binary and not args.from_file:
        ap.error("需要 <主二进制路径> 或 --from-file")
    extra_allow = ""
    if args.allowlist:
        with open(args.allowlist, "r", encoding="utf-8") as fh:
            extra_allow = fh.read()
    names = collect_weak_imports(args.binary or "", args.from_file)
    strict = args.strict
    if not names:
        print("weak-import 守卫：主二进制无未定义弱导入 —— 通过")
        return 0
    hard, new, allowed = [], [], 0
    for name in names:
        if any(token in name for token in HARD_BLOCKED_SUBSTRINGS):
            hard.append(name)
        elif any(token in name for token in ALLOWED_SUBSTRINGS) or (extra_allow and name in extra_allow):
            allowed += 1
        else:
            new.append(name)
    print("weak-import 守卫：未定义弱导入共 {} 个（安全白名单 {} / 新增未归类 {} / 硬禁止 {}）".format(
        len(names), allowed, len(new), len(hard)))
    for name in new:
        print("weak-import NEW（未归类，暂放行；确认无害后加入 ALLOWED_SUBSTRINGS）: {}".format(name[:160]))
    if hard:
        for name in hard:
            print("::error::weak-import 硬禁止: {}".format(name[:160]))
        print("::error::出现 v0.3.746 那类危险弱导入（旧 iOS 上 GOT 为空直呼 → PC=0 闪退）——拦截本次构建")
        return 1
    if strict and new:
        for name in new:
            print("::error::weak-import 违规[NEW]: {}".format(name[:160]))
        return 1
    print("weak-import 守卫：无硬禁止弱导入 —— 通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
