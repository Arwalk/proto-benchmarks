#!/usr/bin/env python3
"""Merge runner metadata into a harness output file (in place).

finalize_result.py RESULT.json --meta IMPL/meta.json --env environment.json
                   --repeat N [--core C] [--cpuset SET] --warmup S --warmup-max S --round S --rounds N
                   [--version-file build/version.txt]
"""
import argparse
import datetime
import json
import os
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("result")
    ap.add_argument("--meta", required=True)
    ap.add_argument("--env", required=True)
    ap.add_argument("--repeat", type=int, default=0)
    ap.add_argument("--core", default=None, help="single pinned core (empty/absent when pinned to a set)")
    ap.add_argument("--cpuset", default=None, help="taskset cpu list the process was pinned to, e.g. 0-2")
    ap.add_argument("--warmup", type=float, required=True)
    ap.add_argument("--warmup-max", type=float, default=None)
    ap.add_argument("--round", type=float, required=True)
    ap.add_argument("--rounds", type=int, required=True)
    ap.add_argument("--version-file", default=None)
    ap.add_argument("--id", default=None, help="implementation id (directory, e.g. rust/prost)")
    args = ap.parse_args()

    with open(args.result, encoding="utf-8") as f:
        doc = json.load(f)
    with open(args.meta, encoding="utf-8") as f:
        meta = json.load(f)
    with open(args.env, encoding="utf-8") as f:
        env = json.load(f)

    version = meta.get("version", "auto")
    if version == "auto":
        version = None
        if args.version_file and os.path.exists(args.version_file):
            with open(args.version_file, encoding="utf-8") as f:
                version = f.read().strip() or None
        if not version:
            version = doc.get("harness", {}).get("library_version") or "unknown"

    doc["implementation"] = {
        "id": args.id or f"{meta['language']}/{meta['name']}",
        "language": meta["language"],
        "name": meta["name"],
        "variant": meta.get("variant"),
        "version": version,
        "url": meta.get("url", ""),
        "notes": meta.get("notes", []),
    }
    doc["environment"] = env
    core = args.core if args.core not in (None, "") else None
    if core is not None:
        try:
            core = int(core)
        except ValueError:
            pass
    doc["run"] = {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "repeat_index": args.repeat,
        "core": core,
        "cpuset": args.cpuset or None,
        "warmup_seconds": args.warmup,
        "warmup_max_seconds": args.warmup_max,
        # constants of the steady-state detection (docs/HARNESS.md), recorded for provenance
        "steady_probe_seconds": 0.5,
        "steady_window": 3,
        "steady_tolerance": 0.05,
        "round_seconds": args.round,
        "rounds": args.rounds,
    }
    with open(args.result, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
