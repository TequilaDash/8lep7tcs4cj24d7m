#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""界面文案硬规则防复发检查（DesignSystem.swift 头注第 4 条）.

背景：用户两次明确要求界面文案纪律，但此前只靠人眼复查，改一次漏一次 ——
2026-10-18 全量扫描发现 **18 处中文句号**散落 6 个文件（Engine 层的 `detail:` /
`NSLocalizedDescriptionKey` 字符串同样直达界面或弹窗）。本脚本把三条不变量机械守住：

  G1  界面文案不得出现**中文句号** `。` —— 一律英文句点 `.`。
      扫描范围 = `TequilaDash/**/*.swift` 的**字符串字面量**（注释先被屏蔽为空白，
      所以注释里写「不要用中文句号。」不会误报）。
  G2  界面文案不得出现**星形装饰符**（U+2605 ★ / U+2728 ✨ / U+2B50 ⭐ / U+1F31F 🌟）
      —— 用户明确要求「不要星形符号」，强调用加粗、分级用 1. 2. 3.。
  G3  不得用**黄色感叹号**做状态标记（`.yellow` 与 `exclamationmark.triangle` 同现）
      —— 用户原话「不要黄色感叹号」。应改 `info.circle` + `AppTheme.pending`。

判据只认**字符与符号**，不绑行号、不绑文案。扫描前先用状态机把注释屏蔽为空白
（字符串保留），故注释里提这些符号不会误报。

用法：python3 swift_ui_copy_guard.py <仓库根>
退出码：0 = 通过；1 = 有违规；2 = 路径错。
"""
import os
import re
import sys

# 中文 Windows 控制台是 GBK，报错样本里可能出现 GBK 编不出的字符（警告三角 / 闪光符号等），
# 直接 print 会抛 UnicodeEncodeError，把「有违规」伪装成「脚本崩了」。
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

BS = chr(92)   # 反斜杠
Q = chr(34)    # 双引号


def _mask_comments(src):
    """把注释（行注释 / 块注释，支持嵌套）替换为等长空白，保留换行与字符串.

    逐字符状态机：code / string / 多行串 / 行注释 / 块注释；字符串里的 `\\(` 插值切回
    code（插值内的注释照样屏蔽）。返回与 `src` **等长**的文本，行号可原样对齐。
    """
    out = []
    n = len(src)
    i = 0
    mode_stack = ["code"]
    interp_depth = []          # 每层插值的括号深度
    block_depth = 0
    while i < n:
        ch = src[i]
        mode = mode_stack[-1]

        if mode in ("lineComment", "blockComment"):
            if mode == "lineComment":
                if ch == "\n":
                    out.append(ch)
                    mode_stack.pop()
                else:
                    out.append(" ")
                i += 1
                continue
            # blockComment
            if ch == "/" and i + 1 < n and src[i + 1] == "*":
                block_depth += 1
                out.append(" ")
                out.append(" ")
                i += 2
                continue
            if ch == "*" and i + 1 < n and src[i + 1] == "/":
                block_depth -= 1
                out.append(" ")
                out.append(" ")
                i += 2
                if block_depth == 0:
                    mode_stack.pop()
                continue
            out.append(ch if ch == "\n" else " ")
            i += 1
            continue

        if mode == "code":
            if ch == "/" and i + 1 < n and src[i + 1] == "/":
                mode_stack.append("lineComment")
                out.append(" ")
                i += 1
                continue
            if ch == "/" and i + 1 < n and src[i + 1] == "*":
                block_depth = 1
                mode_stack.append("blockComment")
                out.append(" ")
                i += 1
                continue
            if ch == Q:
                if src[i:i + 3] == Q * 3:
                    mode_stack.append("multiline")
                    out.append(src[i:i + 3])
                    i += 3
                    continue
                mode_stack.append("string")
                out.append(ch)
                i += 1
                continue
            if ch == "(" and interp_depth:
                interp_depth[-1] += 1
                out.append(ch)
                i += 1
                continue
            if ch == ")" and interp_depth:
                interp_depth[-1] -= 1
                if interp_depth[-1] == 0:
                    interp_depth.pop()
                    mode_stack.pop()
                out.append(ch)
                i += 1
                continue
            out.append(ch)
            i += 1
            continue

        if mode == "string":
            if ch == BS:
                if i + 1 < n and src[i + 1] == "(":
                    interp_depth.append(1)
                    mode_stack.append("code")
                    out.append(src[i:i + 2])
                    i += 2
                    continue
                out.append(src[i:i + 2])
                i += 2
                continue
            if ch == Q:
                mode_stack.pop()
            out.append(ch)
            i += 1
            continue

        if mode == "multiline":
            if ch == BS:
                out.append(src[i:i + 2])
                i += 2
                continue
            if src[i:i + 3] == Q * 3:
                mode_stack.pop()
                out.append(src[i:i + 3])
                i += 3
                continue
            out.append(ch)
            i += 1
            continue

    return "".join(out)

def _iter_swift_files(root):
    """只扫应用源码 `TequilaDash/`。

    不扫仓库根：`scratch/` 下有历史取证样本（airlift_hist 等），那些字符串是**当时的留存**，
    改了就不再是证据。判据要守的是「会进包、会进界面」的代码。
    """
    base = os.path.join(root, "TequilaDash")
    for dirpath, _dirnames, filenames in os.walk(base):
        for fn in filenames:
            if fn.endswith(".swift"):
                yield os.path.join(dirpath, fn)


STRING_LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')

STAR_GLYPHS = {
    "\u2605": "U+2605 黑星",
    "\u2728": "U+2728 闪光",
    "\u2b50": "U+2B50 白星",
    "\U0001f31f": "U+1F31F 发光星",
}


def _line_of(text, offset):
    return text.count("\n", 0, offset) + 1


def check(root):
    errs = []
    scanned = 0
    for path in _iter_swift_files(root):
        rel = os.path.relpath(path, root)
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                src = f.read()
        except OSError:
            continue
        scanned += 1
        masked = _mask_comments(src)
        for m in STRING_LITERAL.finditer(masked):
            body = m.group(1)
            line = _line_of(masked, m.start())
            # G1 中文句号
            if "\u3002" in body:
                errs.append("[G1] %s:%d 字符串字面量含中文句号 —— 一律改英文句点：%s"
                            % (rel, line, body[:70]))
            # G2 星形装饰符
            for glyph, label in STAR_GLYPHS.items():
                if glyph in body:
                    errs.append("[G2] %s:%d 字符串字面量含星形装饰符 %s —— 强调用加粗：%s"
                                % (rel, line, label, body[:70]))
        # G3 黄色感叹号（同一行内 .yellow 与 exclamationmark.triangle 同现）
        for idx, raw in enumerate(masked.split("\n"), start=1):
            if ".yellow" in raw and "exclamationmark.triangle" in raw:
                errs.append("[G3] %s:%d 黄色感叹号状态标记 —— 改 info.circle + AppTheme.pending"
                            % (rel, idx))
    return errs, scanned


def main():
    if len(sys.argv) < 2:
        print("用法：swift_ui_copy_guard.py <仓库根>")
        return 2
    root = sys.argv[1]
    if not os.path.isdir(os.path.join(root, "TequilaDash")):
        print("仓库根下找不到 TequilaDash/ ：%s" % os.path.abspath(root))
        return 2
    errs, scanned = check(root)
    print("-" * 72)
    if errs:
        for e in errs:
            print("ERROR %s" % e)
        print("命中：%d（G1 中文句号 / G2 星形装饰符 / G3 黄色感叹号）" % len(errs))
        return 1
    print("G1 无中文句号：OK")
    print("G2 无星形装饰符：OK")
    print("G3 无黄色感叹号状态标记：OK")
    print("命中：0（扫描 %d 个 .swift）" % scanned)
    return 0


if __name__ == "__main__":
    sys.exit(main())
