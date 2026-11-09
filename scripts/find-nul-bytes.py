#!/usr/bin/env python3
"""Prints each file, from a NUL-separated list on standard input, that holds a NUL byte.

Usage: git ls-files -z | python3 -I scripts/find-nul-bytes.py

Exits 1 when a file holds a NUL byte. A file that cannot be read stops the
check with an error.
"""

import sys


def main() -> int:
    names = [name for name in sys.stdin.buffer.read().split(b"\0") if name]
    found = False
    for name in names:
        with open(name, "rb") as data:
            if b"\0" in data.read():
                print(name.decode("utf-8", "replace"))
                found = True
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
