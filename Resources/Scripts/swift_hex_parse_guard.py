#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""hex 解析口径防复发检查（把 BigInt.swift:36-78 的三条防护机械化）.

背景：UInt8(_:radix:16)（以及 Int16/32/64(_:radix:16)）的失败模式不是 nil，而是
**「非 nil 的垃圾」**。同一个 bug 在本仓有 5 个副本，修完只靠人眼复查，所以守成脚本：

  1. 前导正号：UInt8("+1", radix: 16) == Some(1) —— "aa+1bb" 被静默解成 aa 01 bb。
     只有 allSatisfy { $0.isHexDigit }（或等价的字符集校验）能挡住它。
  2. 奇数长度：index(_:offsetBy: 2) 会跨过 endIndex 直接 trap（实测 SIGILL），
     必须先靠 % 2 挡掉。
  3. 空串 / 裸 0x：旧实现返回零值，须显式 !isEmpty 拒绝。

判据（只认代码：注释与字符串字面量先被屏蔽为空白，故注释里写 isHexDigit 不算数）：
  对每个「String -> 整数(radix:16)」解析点，取它**所在的函数 / init** 为作用域，要求：
    C 字符集：作用域内有 isHexDigit，或有已知校验器（见 HEX_VALIDATORS）；
    E 空串  ：作用域内有 !x.isEmpty；
    O 奇数长：作用域内有 % 2 / isMultiple(of: 2)。
  作用域分两族：
    · 整串解析器（有 while 循环 / reserveCapacity / 返回 Data?、[UInt8]?，
      或函数名属 hex 解码家族 / 是 init?(hex:)）—— 三防缺一即 ERROR（致命）。
    · 定长切片（2 字符一解）—— 要 C 且（.count == 2 或 % 2），缺则 WARN 或豁免。

扫描范围：TequilaDash/ 与 TequilaDashTunnel/（会进包的应用源码）。
不含 vendor/（上游 ApplePackage）、scratch/（历史取证留存，改了不再是证据）、
livecontainer/、ZSign/、tools/ —— 第三方或非本仓维护。

已知豁免（WAIVERS）：本仓当前**未修**的未防护点，只报告不改那些文件（不在本守卫写域）。
新出现的未防护点不会被豁免吞掉：ERROR 致命；WARN 默认只报告，--strict 时致命。
参考实现：TequilaDash/Services/AppleAuth/BigInt.swift:52、
TequilaDash/Services/AppleAuth/GSAAuth.swift:192、
TequilaDash/Engine/IPADownloadCenter.swift:1830。

用法：python3 swift_hex_parse_guard.py [仓库根，默认 .] [--strict]
退出码：0 = 通过；1 = 有 ERROR（--strict 时 WARN 也算）；2 = 路径错。
"""
import os
import re
import sys

# 中文 Windows 控制台是 GBK，报告里可能出现编不出的字符，直接 print 会抛
# UnicodeEncodeError，把「有违规」伪装成「脚本崩了」。
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

SCAN_DIRS = ("TequilaDash", "TequilaDashTunnel")

# 「String -> 整数(radix: 16)」的解析点。**不含 String(** —— 那是反向编码（bytes -> hex），
# 本仓有十几处，混进来全是误报。
PARSE_TYPES = ("UInt8", "Int8", "UInt16", "Int16", "UInt32", "Int32",
               "UInt64", "Int64", "UInt", "Int")
CALL_HEAD = re.compile(r"\b(?:" + "|".join(PARSE_TYPES) + r")\s*\(")
RADIX16 = re.compile(r"\bradix\s*:\s*16\b")

# 函数声明扫描（用于把解析点归属到「所在的函数 / init」）。
DECL_SCAN = re.compile(
    r"^\s*(?:(?:@\w+(?:\([^)]*\))?|private|fileprivate|internal|public|open|static"
    r"|class|final|override|mutating|nonisolated|convenience|required)\s+)*"
    r"(?:func\s+([A-Za-z_]\w*)\s*[(<]|init\??\s*\()"
)

# 声明家族：init?(hex: 家族) 与 hex 解码函数名 —— 这类就算没有解析调用点也要查。
HEX_INIT_DECL = re.compile(r"\binit\?\(\s*(?:hex|hexString|hexBytes|hexData)\s*:")
HEX_DECODER_NAME = re.compile(
    r"^(?:hexToBytes|hexToData|hexDecoded|hexDecode|hexBytes|hexToBuffer|bytesFromHex|fromHex)$"
)

# 已知校验器：函数名 -> 它能替调用方证明的不变量。加进来等于承认「这个校验器的语义
# 被本守卫依赖」，所以每条都钉住出处；改了校验器就要回来改这里。
HEX_VALIDATORS = {
    # StoreAuthenticationProtocol.swift:156-159
    #   guard (12 ... 32).contains(value.count), value.count.isMultiple(of: 2)
    #   return value.allSatisfy(\.isHexDigit)
    "isDeviceGUID": ("charset", "even"),
}

# 已知豁免：本仓当前确实未防护、但不在本守卫写域的点。只报告，不改。
# key = (相对仓库根路径, 作用域名)；用「路径 + 函数名」而不是行号，改行不会失效。
WAIVERS = {
    # v0.3.698：HexEditorView.applyEdit 的豁免已撤销 —— 该点已用 hexByteValue()
    # 补齐字符集 / 空串 / 定长三防，守卫实测 OK，豁免条目不再命中（留着每次都会打 NOTE）。
    # 新增豁免必须写「为什么本守卫不该管它」并钉出处，否则就是在掩盖缺陷。
    # v0.3.704：Xrash 解析层逐文件原样搬入（TequilaDash/Engine/CrashReport/），
    # 改动会破坏与上游 github.com/owngoal-dev/Xrash 的可对照性。该处是
    # UInt64(digits, radix: 16) 整串解析、不做切片，无越界风险；仅容忍前导正号，
    # 而调用方传入的是设备回传的地址串，不接受用户输入。
    ("TequilaDash/Engine/CrashReport/LegacyCrashLines.swift", "init"):
        "上游逐文件原样搬入，无切片越界风险；不接受用户输入。",
}
MISSING_LABEL = {
    "charset": "缺字符集校验（UInt8(_:radix:16) 接受前导正号 \"+F\" / 非 hex 字符）-> 补 allSatisfy { $0.isHexDigit }",
    "empty": "缺空串校验（空串 / 裸 0x 会被当成零值）-> 补 guard !x.isEmpty",
    "odd": "缺奇数长度校验（index(_:offsetBy:2) 会越界 trap）-> 补 x.count % 2 == 0",
    "delegate": "无解析调用点、也未委派给已验证解析器（名字像 hex 解析器却没在解？）",
}


def _mask(src):
    """把注释与字符串字面量的**内容**替换为等长空白（保留换行与引号）。

    注释要屏蔽，否则 BigInt.swift / GSAAuth.swift 的说明注释里写的 radix:16、
    isHexDigit 会被当成真实代码。字符串内容也要屏蔽，否则串里的 { } 会破坏作用域
    大括号配平。字符串插值内部的代码本守卫不查（本仓无此形态）。
    """
    out = []
    n = len(src)
    i = 0
    stack = ["code"]
    block_depth = 0
    while i < n:
        ch = src[i]
        mode = stack[-1]

        if mode == "lineComment":
            if ch == "\n":
                out.append(ch)
                stack.pop()
            else:
                out.append(" ")
            i += 1
            continue

        if mode == "blockComment":
            if ch == "/" and i + 1 < n and src[i + 1] == "*":
                block_depth += 1
                out.append("  ")
                i += 2
                continue
            if ch == "*" and i + 1 < n and src[i + 1] == "/":
                block_depth -= 1
                out.append("  ")
                i += 2
                if block_depth == 0:
                    stack.pop()
                continue
            out.append(ch if ch == "\n" else " ")
            i += 1
            continue

        if mode in ("string", "multiline"):
            if ch == "\\":
                out.append(src[i:i + 2] if i + 1 < n and src[i + 1] == "\n" else "  ")
                i += 2
                continue
            if mode == "string" and ch == '"':
                stack.pop()
                out.append(ch)
                i += 1
                continue
            if mode == "multiline" and src[i:i + 3] == '"' * 3:
                stack.pop()
                out.append('"' * 3)
                i += 3
                continue
            out.append(ch if ch == "\n" else " ")
            i += 1
            continue

        # mode == "code"
        if ch == "/" and i + 1 < n and src[i + 1] == "/":
            stack.append("lineComment")
            out.append("  ")
            i += 2
            continue
        if ch == "/" and i + 1 < n and src[i + 1] == "*":
            block_depth = 1
            stack.append("blockComment")
            out.append("  ")
            i += 2
            continue
        if ch == '"':
            if src[i:i + 3] == '"' * 3:
                stack.append("multiline")
                out.append('"' * 3)
                i += 3
                continue
            stack.append("string")
            out.append(ch)
            i += 1
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def _iter_swift_files(root):
    for d in SCAN_DIRS:
        base = os.path.join(root, d)
        if not os.path.isdir(base):
            continue
        for dirpath, _dirnames, filenames in os.walk(base):
            for fn in sorted(filenames):
                if fn.endswith(".swift"):
                    yield os.path.join(dirpath, fn)


def _scope_end(lines, start):
    """从声明行开始的整段作用域（大括号配平；输入已屏蔽注释与字符串）。"""
    depth = 0
    started = False
    for idx in range(start, len(lines)):
        for ch in lines[idx]:
            if ch == "{":
                depth += 1
                started = True
            elif ch == "}":
                depth -= 1
                if started and depth <= 0:
                    return idx
    return len(lines) - 1


def _decls(lines):
    """返回 [(行号0基, 名字, 声明行文本)]，按行序。"""
    found = []
    for idx, raw in enumerate(lines):
        m = DECL_SCAN.match(raw)
        if not m:
            continue
        name = m.group(1) or "init"
        found.append((idx, name, raw.strip()))
    return found


def _call_sites(text):
    """所有 Ty( ... radix: 16 ... ) 解析点的 (行号0基, 列)。括号配平后再看内部。"""
    sites = []
    for m in CALL_HEAD.finditer(text):
        j = m.end()
        depth = 1
        while j < len(text) and depth > 0:
            c = text[j]
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
            j += 1
        if RADIX16.search(text[m.end():j - 1]):
            sites.append((text.count("\n", 0, m.start()), m.start()))
    return sites


def _proofs(scope_text):
    """作用域内能自证的不变量（只认真实代码；注释与字符串已被 _mask 屏蔽）。"""
    charset = "isHexDigit" in scope_text
    even_ok = False
    for fn, proofs in HEX_VALIDATORS.items():
        if re.search(r"\b" + re.escape(fn) + r"\s*\(", scope_text):
            if "charset" in proofs:
                charset = True
            if "even" in proofs:
                even_ok = True
    return {
        "charset": charset,
        "empty": re.search(r"!\s*[\w.\[\]()]+\.isEmpty", scope_text) is not None,
        "odd": (re.search(r"%\s*2\b", scope_text) is not None) or even_ok,
        "width2": re.search(r"\.\w+\s*==\s*2\b", scope_text) is not None,
    }


def _missing(proofs, need_empty=True):
    out = []
    if not proofs["charset"]:
        out.append("charset")
    if need_empty and not proofs["empty"]:
        out.append("empty")
    if not proofs["odd"]:
        out.append("odd")
    return out


def _steps_itself(scope_text):
    """是否自己按 2 字符切步（那就要自证偶数长度，不能只靠委派）。"""
    return re.search(r"offsetBy\s*:\s*2\b", scope_text) is not None


def _verdict(scope_text, decl_line, forced_parser):
    has_loop = re.search(r"\bwhile\b", scope_text) is not None
    has_reserve = "reserveCapacity(" in scope_text
    has_bytes_ret = re.search(r"->\s*(?:Data|\[UInt8\]|Array<UInt8>)\s*\??", decl_line) is not None
    is_parser = bool(forced_parser or has_loop or has_reserve or has_bytes_ret)

    proofs = _proofs(scope_text)
    if proofs["charset"] and proofs["empty"] and proofs["odd"]:
        return "OK", "整串解析器：空串 / 奇数长度 / 字符集三防齐备"
    if proofs["charset"] and (proofs["width2"] or proofs["odd"]):
        return "OK", "定长切片：字符集已校验 + 宽度/长度已定"
    kind = "ERROR" if is_parser else "WARN"
    return kind, _missing(proofs)


def check(root, strict):
    errors = []
    warns = []
    waived = []
    oks = []
    scanned = 0
    used_waivers = set()

    for path in _iter_swift_files(root):
        rel = os.path.relpath(path, root).replace(os.sep, "/")
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                src = f.read()
        except OSError:
            continue
        scanned += 1
        masked = _mask(src)
        lines = masked.split("\n")
        decls = _decls(lines)

        # 作用域收集：解析点归属 + 声明家族（init?(hex:) / hex 解码函数名）
        scopes = {}
        for sline, _col in _call_sites(masked):
            owner = None
            for idx, name, decl_line in reversed(decls):
                if idx <= sline and sline <= _scope_end(lines, idx):
                    owner = (idx, name, decl_line)
                    break
            if owner is None:
                scopes.setdefault(-1, {"name": "<顶层/闭包>", "sites": [],
                                       "parser": True, "line": -1})["sites"].append(sline)
                continue
            idx, name, decl_line = owner
            sc = scopes.setdefault(idx, {"name": name, "sites": [], "parser": False,
                                        "line": idx})
            sc["sites"].append(sline)
            sc["decl_line"] = decl_line

        for idx, name, decl_line in decls:
            forced = bool(HEX_INIT_DECL.search(decl_line) or HEX_DECODER_NAME.match(name))
            if forced or idx in scopes:
                sc = scopes.setdefault(idx, {"name": name, "sites": [], "parser": False,
                                             "line": idx})
                sc["parser"] = sc.get("parser", False) or forced
                sc["decl_line"] = decl_line

        # 第一遍：取作用域文本，并裁定「有解析调用点」的作用域
        for idx in sorted(scopes):
            sc = scopes[idx]
            if idx < 0:
                sc["text"] = masked
                sc["decl_line"] = ""
            else:
                sc["text"] = "\n".join(lines[idx:_scope_end(lines, idx) + 1])
            if sc["sites"]:
                sc["kind"], sc["info"] = _verdict(sc["text"], sc.get("decl_line", ""),
                                                  sc.get("parser", True))

        # 第二遍：没有解析调用点的声明家族作用域。hexDecoded() 把逐字节解析委派给同文件的
        # hexByte()、不另写两份（NBStoreClient.swift:1773-1801）是刻意设计，所以委派目标
        # 判 OK 就放行；但若它自己做 offsetBy: 2 切步，仍须自证空串与偶数长度。
        by_name = {}
        for idx in sorted(scopes):
            if idx >= 0:
                by_name.setdefault(scopes[idx]["name"], []).append(scopes[idx])

        for idx in sorted(scopes):
            sc = scopes[idx]
            if sc["sites"]:
                continue
            callees = sorted(n for n in by_name if n != sc["name"]
                             and re.search(r"\b" + re.escape(n) + r"\s*\(", sc["text"]))
            verified = [n for n in callees
                        if all(s.get("kind") == "OK" for s in by_name[n])]
            if verified:
                proofs = _proofs(sc["text"])
                if _steps_itself(sc["text"]):
                    missing = [k for k in ("empty", "odd") if not proofs[k]]
                    if missing:
                        sc["kind"], sc["info"] = "ERROR", missing
                        continue
                sc["kind"] = "OK"
                sc["info"] = "委派给已验证解析器 %s（不另写一份 hex 解析）" % "、".join(verified)
            elif HEX_INIT_DECL.search(sc.get("decl_line", "")):
                sc["kind"], sc["info"] = "ERROR", ["delegate"]
            else:
                sc["kind"], sc["info"] = "WARN", ["delegate"]

        for idx in sorted(scopes):
            sc = scopes[idx]
            line_no = sc["line"] + 1
            kind, info = sc["kind"], sc["info"]
            site_txt = ",".join(":%d" % (n + 1) for n in sorted(set(sc["sites"]))) or "（无解析调用点）"
            where = "%s:%d %s()  调用点 %s" % (rel, line_no, sc["name"], site_txt)
            if kind == "OK":
                oks.append("%s —— %s" % (where, info))
            elif kind == "ERROR":
                errors.append("%s —— %s" % (where, "；".join(MISSING_LABEL[m] for m in info)))
            else:
                key = (rel, sc["name"])
                reason = WAIVERS.get(key)
                if reason is not None:
                    used_waivers.add(key)
                    waived.append("%s —— 已知豁免（未修，非本守卫写域）：%s" % (where, reason))
                elif strict:
                    errors.append("%s —— %s" % (where, "；".join(MISSING_LABEL[m] for m in info)))
                else:
                    warns.append("%s —— %s" % (where, "；".join(MISSING_LABEL[m] for m in info)))

    for line in oks:
        print("OK     %s" % line)
    for line in waived:
        print("WAIVED %s" % line)
    for line in warns:
        print("WARN   %s" % line)
    for line in errors:
        print("ERROR  %s" % line)
    for k in [k for k in WAIVERS if k not in used_waivers]:
        print("NOTE   豁免条目已不再命中（可能已修好，可删）：%s %s()" % k)

    n_scope = len(oks) + len(warns) + len(waived) + len(errors)
    print("命中：%d（ERROR %d / WARN %d；已防护 %d / 已知豁免 %d；"
          "扫描 %d 个 .swift，解析作用域 %d 个）"
          % (len(errors) + len(warns), len(errors), len(warns),
             len(oks), len(waived), scanned, n_scope))
    if n_scope == 0:
        print("ERROR  一个 hex 解析点都没扫到 —— 守卫自身失效（目录改名 / 判据过时？），当成失败")
        return 1
    return 1 if errors else 0


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    strict = "--strict" in sys.argv[1:]
    root = args[0] if args else "."
    if not os.path.isdir(os.path.join(root, "TequilaDash")):
        print("仓库根下找不到 TequilaDash/ ：%s" % os.path.abspath(root))
        return 2
    print("-" * 72)
    return check(root, strict)


if __name__ == "__main__":
    sys.exit(main())
