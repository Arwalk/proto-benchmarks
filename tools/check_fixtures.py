#!/usr/bin/env python3
"""Regenerate the fixtures into a temp dir and diff against the committed ones."""
import filecmp
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def main():
    gen = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "python", "protobuf", "gen")
    if not os.path.exists(os.path.join(gen, "bench_pb2.py")):
        print(f"missing {gen}/bench_pb2.py - build python/protobuf first", file=sys.stderr)
        return 2
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.check_call([sys.executable, os.path.join(HERE, "gen_fixtures.py"), "--gen", gen, "--out", tmp],
                              stdout=subprocess.DEVNULL)
        ok = True
        for name in ("small", "medium", "large"):
            for ext in ("bin", "json"):
                a = os.path.join(ROOT, "fixtures", f"{name}.{ext}")
                b = os.path.join(tmp, f"{name}.{ext}")
                same = os.path.exists(a) and filecmp.cmp(a, b, shallow=False)
                print(f"{name}.{ext}: {'ok' if same else 'MISMATCH'}")
                ok &= same
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
