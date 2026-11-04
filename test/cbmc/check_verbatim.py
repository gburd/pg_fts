#!/usr/bin/env python3
"""check_verbatim.py -- the transcribed functions in test/cbmc/*.c still match
the shipped source.

A harness that copies a function proves a property of the COPY.  Each copy is
fenced in the harness by

    /* VERBATIM <source-file> <function-name> */
    ...function definition...
    /* END VERBATIM */

and this script extracts the same-named definition from the source file and
compares the two with comments and whitespace removed.  Exit 1 on any drift,
so a change to the shipped function fails the CBMC job until the harness is
updated with it.  No dependencies beyond the standard library.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
HERE = pathlib.Path(__file__).resolve().parent

FENCE = re.compile(r"/\* VERBATIM (\S+) (\w+) \*/\n(.*?)/\* END VERBATIM \*/", re.S)


def norm(code):
    code = re.sub(r"/\*.*?\*/", " ", code, flags=re.S)
    code = re.sub(r"//[^\n]*", " ", code)
    return re.sub(r"\s+", "", code)


def extract(src, name):
    """The definition of `name` in src: the line `name(` starts in column 0
    (PostgreSQL style puts the return type on the line above), back to that
    return-type line, forward to the closing brace in column 0.  A comment
    or call mentioning `name(` mid-line never matches."""
    for m in re.finditer(r"^" + name + r"\(", src, re.M):
        body = src.find("\n}\n", m.start())
        semi = src.find(";", m.start())
        brace = src.find("\n{", m.start())
        if body < 0 or brace < 0 or (0 <= semi < brace):
            continue            # a prototype, not the definition
        start = src.rfind("\n", 0, m.start() - 1) + 1
        return src[start:body + 2]
    return None


def main():
    bad = 0
    n = 0
    for h in sorted(HERE.glob("*.c")):
        text = h.read_text()
        for m in FENCE.finditer(text):
            n += 1
            srcfile, name, copy = m.group(1), m.group(2), m.group(3)
            src = (ROOT / srcfile).read_text()
            orig = extract(src, name)
            if orig is None:
                print(f"DRIFT {h.name}: {name} not found in {srcfile}")
                bad += 1
            elif norm(orig) != norm(copy):
                print(f"DRIFT {h.name}: {name} differs from {srcfile}")
                bad += 1
            else:
                print(f"ok    {h.name}: {name} == {srcfile}")
    if n == 0:
        print("no VERBATIM fences found")
        return 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
