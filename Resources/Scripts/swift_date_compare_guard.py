#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Date 比较符防复发检查（v0.3.747 线上事故的机械化守法）.

背景（实测，不是推断）：iOS 27.2 beta（24B5089g）上，Swift 把 Date 的「>=」「<=」
编成 weak import（_$s10Foundation4DateV2geoiySbAC_ACtFZ /
_$s10Foundation4DateV2leoiySbAC_ACtFZ），调用点包在
___isPlatformVersionAtLeast(2, 27, 2, 0) 的可用性门里。beta 系统的 Foundation 还没导出
这两个符号 ⇒ GOT 为空，快路径 br x16 直呼 0x0，进程被系统以 CODESIGNING「Invalid Page」
击杀。两次复现（21:57 / 22:39）崩溃链逐字一致，都落在账户请求门轮询的
「Date() >= deadline」（llvm-objdump 全量反汇编 + 符号 bisect 定位）。

「<」「>」「==」此刻仍是 strong（对应符号存在且解析成功），但本脚本把四个比较符一起拦：
「只有两个会炸」是当前 SDK 的事实，Apple 哪天把「<」「>」也搬进新 ABI，
同一颗雷换个地方响。

写法口径：
  错：Date() >= deadline / until > Date() / a <= b（a、b 为 Date）
  对：Date().timeIntervalSinceReferenceDate >= deadline.timeIntervalSinceReferenceDate
      （比较 Double，编译成 fcmp，不产生任何符号门）；或 .compare(_:) == .orderedAscending
      这类返回 ComparisonResult 的老写法。

判据（只认代码：注释与字符串字面量先屏蔽为空白，注释里写 Date() 不算数）：
  1) 按文件收集「Date 型名字」：
     · 显式标注 : Date / : Date?（属性、let/var、函数参数）
     · 右端含 Date( 或 Date.now 的 let/var 初始化
     · 传递推断：let y = <已知 Date 名>.addingTimeInterval(...) / .advanced(by:)，迭代到不动点
  2) 扫 A (<=|>=|<|>) B，要求**两侧都是** Date 表达式（Date( / Date.now /
     首标识符在集合内，且表达式不含 .timeIntervalSince* / .compare / .description
     这些返回非 Date 的链）⇒ ERROR。两侧都要命中，是为了不碰泛型尖括号与移位：
     Array<Date>、1 << 3 天然不匹配。

扫描范围：TequilaDash/ 与 TequilaDashTunnel/（会进包的应用源码）。
不含 vendor/（上游 ApplePackage）、Zsign/、livecontainer/、tools/、scratch/。

已知豁免（WAIVERS）：无。749 起全仓比较符已清零，新命中一律致命。

用法：python3 swift_date_compare_guard.py [仓库根，默认 .]
退出码：0 = 通过；1 = 有违规；2 = 路径错。
"""
import os
import re
import sys

APP_DIRS = ("TequilaDash", "TequilaDashTunnel")

# 这些链返回 Double / String，不是 Date，比较它们没问题
NON_DATE_CHAIN = re.compile(r"\.\s*(timeIntervalSince\w*|compare|description|hashValue|debugDescription)")

IDENT = r"[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*(?:\([^()\n]*\))?"
OP = re.compile("(" + IDENT + r")\s*(<=|>=|<|>)\s*(" + IDENT + ")")

PARAM = re.compile(r"\b([A-Za-z_]\w*)\s*:\s*Date\s*\??")
INIT_FROM_DATE = re.compile(r"\b(?:let|var)\s+([A-Za-z_]\w*)\s*[:=][^=\n]*\bDate\s*\(")
INIT_NOW = re.compile(r"\b(?:let|var)\s+([A-Za-z_]\w*)\s*[:=][^=\n]*\bDate\.now\b")
PROPAGATE = re.compile(r"\b(?:let|var)\s+([A-Za-z_]\w*)\s*=[^=\n]*\b([A-Za-z_]\w*)\.(addingTimeInterval|advanced)\b")
KEYWORDS = {"in", "let", "var", "func", "if", "guard", "return", "else", "case"}


def blank_noise(text):
    """把注释与字符串字面量的内容换成空格，保留行号与列宽."""
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                out[i] = " "
                i += 1
        elif c == "/" and i + 1 < n and text[i + 1] == "*":
            while i < n and not (text[i] == "*" and i + 1 < n and text[i + 1] == "/"):
                if text[i] != "\n":
                    out[i] = " "
                i += 1
            out[i] = out[i + 1] = " "
            i += 2
        elif c == '"':
            trip = text[i:i + 3] == '"""'
            step = 3 if trip else 1
            for k in range(i, i + step):
                out[k] = " "
            j = i + step
            while j < n:
                if text[j] == "\\":
                    out[j] = " "
                    if j + 1 < n:
                        out[j + 1] = " "
                    j += 2
                    continue
                if trip and text[j:j + 3] == '"""':
                    for k in range(j, j + 3):
                        out[k] = " "
                    j += 3
                    break
                if not trip and text[j] == '"':
                    out[j] = " "
                    j += 1
                    break
                if text[j] == "\n" and not trip:
                    break
                if text[j] != "\n":
                    out[j] = " "
                j += 1
            i = j
        else:
            i += 1
    return "".join(out)


def collect_date_names(code):
    names = set()
    for m in re.finditer(r"\b(?:let|var)\s+([A-Za-z_]\w*)\s*:\s*Date\s*\??", code):
        names.add(m.group(1))
    for m in PARAM.finditer(code):
        if m.group(1) not in KEYWORDS:
            names.add(m.group(1))
    for rx in (INIT_FROM_DATE, INIT_NOW):
        for m in rx.finditer(code):
            names.add(m.group(1))
    for _ in range(6):
        grew = False
        for m in PROPAGATE.finditer(code):
            tgt, base = m.group(1), m.group(2)
            if base in names and tgt not in names:
                names.add(tgt)
                grew = True
        if not grew:
            break
    return names


def is_date_expr(side, names):
    if side == "Date()" or side.startswith("Date(") or side.startswith("Date.now"):
        return True
    if NON_DATE_CHAIN.search(side):
        return False
    head = re.match(r"([A-Za-z_]\w*)", side)
    return bool(head) and head.group(1) in names


def scan(path, rel):
    raw = open(path, "r", encoding="utf-8", errors="replace").read()
    code = blank_noise(raw)
    names = collect_date_names(code)
    hits = []
    lines = code.splitlines()
    raw_lines = raw.splitlines()
    for ln, line in enumerate(lines, 1):
        for m in OP.finditer(line):
            a, op, b = m.group(1), m.group(2), m.group(3)
            if is_date_expr(a, names) and is_date_expr(b, names):
                txt = raw_lines[ln - 1].strip() if ln - 1 < len(raw_lines) else ""
                hits.append((rel, ln, op, txt[:120]))
    return hits


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    if not os.path.isdir(root):
        print("找不到仓库根：%s" % os.path.abspath(root))
        return 2
    all_hits = []
    files = 0
    for d in APP_DIRS:
        base = os.path.join(root, d)
        if not os.path.isdir(base):
            continue
        for dirpath, _dirs, fnames in os.walk(base):
            for fn in sorted(fnames):
                if not fn.endswith(".swift"):
                    continue
                p = os.path.join(dirpath, fn)
                files += 1
                all_hits += scan(p, os.path.relpath(p, root).replace(os.sep, "/"))
    print("扫描 .swift 文件：%d" % files)
    for rel, ln, op, txt in all_hits:
        print("ERROR %s:%d  Date 直接比较（%s）⇒ 改 timeIntervalSinceReferenceDate：%s"
              % (rel, ln, op, txt))
    print("-" * 56)
    print("命中：%d" % len(all_hits))
    if all_hits:
        print("✗ 存在 Date 比较符：iOS 27.2 beta 上 >=/<= 是 weak import，GOT 空则 PC=0 直接被杀")
        return 1
    print("✓ 无 Date 直接比较 —— 合规")
    return 0


if __name__ == "__main__":
    sys.exit(main())
