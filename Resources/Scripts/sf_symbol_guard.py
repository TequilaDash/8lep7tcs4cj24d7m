#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SF Symbol whitelist guard (effective since v0.3.753).

Background: device blanks from invalid symbol names (bolt.badge.plus,
gearshape.arrow.circlepath, app). Every systemName/systemImage/icon
literal and var-icon switch return literal in the repo must be listed
in Resources/Scripts/sf_symbols.txt first; add a name only after
verifying it exists in the SF Symbols app / Apple catalog.

Usage: python Resources/Scripts/sf_symbol_guard.py [repo-root]
exit 0 = all registered; exit 1 = unregistered symbols found.
"""
import os
import re
import sys

LIT_PARAM = re.compile(r'(?:systemName|systemImage|icon)\s*:\s*"([^"]+)"')
LIT_RET = re.compile(r'return\s+"([^"]+)"')
SHAPE = re.compile(r'^[a-z][a-z0-9.\-]*$')


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(here))
    src = os.path.join(root, "TequilaDash")
    whitelist_path = os.path.join(here, "sf_symbols.txt")
    with open(whitelist_path, "r", encoding="utf-8") as fh:
        known = {ln.strip() for ln in fh
                 if ln.strip() and not ln.strip().startswith("#")}
    found = {}
    for dirpath, _dirnames, filenames in os.walk(src):
        for name in filenames:
            if not name.endswith(".swift"):
                continue
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            with open(full, "r", encoding="utf-8", errors="replace") as fh:
                for no, line in enumerate(fh, 1):
                    for mt in LIT_PARAM.finditer(line):
                        v = mt.group(1)
                        if SHAPE.match(v):
                            found.setdefault(v, []).append(rel + ":" + str(no))
                    for mt in LIT_RET.finditer(line):
                        v = mt.group(1)
                        if SHAPE.match(v) and "." in v:
                            found.setdefault(v, []).append(rel + ":" + str(no))
    unknown = sorted(set(found) - known)
    stale = sorted(known - set(found))
    for v in unknown:
        where = ", ".join(found.get(v, [])[:3])
        sys.stdout.write("[sf-symbol] unregistered: %s  (%s)\n" % (v, where))
    if stale:
        sys.stdout.write("[sf-symbol] unused whitelist entries: %s\n" % ", ".join(stale))
    sys.stdout.write("[sf-symbol] literals=%d whitelist=%d unknown=%d\n"
                     % (len(found), len(known), len(unknown)))
    return 1 if unknown else 0


if __name__ == "__main__":
    sys.exit(main())
