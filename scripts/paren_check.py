#!/usr/bin/env python3
import argparse
import sys

OPEN = {"(": ")", "[": "]", "{": "}"}
CLOSE = {")": "(", "]": "[", "}": "{"}


def scan(text, path):
    stack = []
    i = 0
    line = 1
    col = 1
    in_str = False
    esc = False
    line_comment = False
    block_comment = 0
    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""

        if ch == "\n":
            line += 1
            col = 1
            line_comment = False
            i += 1
            continue

        if line_comment:
            i += 1
            col += 1
            continue

        if block_comment:
            if ch == "#" and nxt == "|":
                block_comment += 1
                i += 2
                col += 2
                continue
            if ch == "|" and nxt == "#":
                block_comment -= 1
                i += 2
                col += 2
                continue
            i += 1
            col += 1
            continue

        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == "\"":
                in_str = False
            i += 1
            col += 1
            continue

        if ch == ";":
            line_comment = True
            i += 1
            col += 1
            continue

        if ch == "#" and nxt == "|":
            block_comment += 1
            i += 2
            col += 2
            continue

        if ch == "\"":
            in_str = True
            i += 1
            col += 1
            continue

        if ch in OPEN:
            stack.append((ch, line, col))
            i += 1
            col += 1
            continue

        if ch in CLOSE:
            if not stack:
                return False, (line, col, f"unexpected '{ch}'", None)
            top, tline, tcol = stack[-1]
            if CLOSE[ch] != top:
                return False, (line, col, f"mismatched '{ch}', expected '{OPEN[top]}'", (tline, tcol, top))
            stack.pop()
            i += 1
            col += 1
            continue

        i += 1
        col += 1

    if in_str:
        return False, (line, col, "unterminated string", None)
    if block_comment:
        return False, (line, col, "unterminated block comment", None)
    if stack:
        top, tline, tcol = stack[-1]
        return False, (tline, tcol, f"unclosed '{top}'", None)
    return True, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+")
    args = ap.parse_args()

    ok = True
    for path in args.paths:
        try:
            with open(path, "r", encoding="utf-8") as f:
                text = f.read()
        except OSError as e:
            print(f"{path}: {e}", file=sys.stderr)
            ok = False
            continue
        good, err = scan(text, path)
        if good:
            print(f"{path}: ok")
        else:
            line, col, msg, extra = err
            if extra:
                tline, tcol, ch = extra
                print(f"{path}:{line}:{col}: {msg} (open {ch} at {tline}:{tcol})")
            else:
                print(f"{path}:{line}:{col}: {msg}")
            ok = False
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
