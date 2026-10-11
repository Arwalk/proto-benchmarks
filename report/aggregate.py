#!/usr/bin/env python3
"""Aggregate proto-benchmarks result files into summary.json, summary.csv and report.html.

Usage:
  aggregate.py RESULTS_DIR [-o report.html] [--baseline zig/zig-protobuf] [--validation results/validation.json]
  aggregate.py --validate-only FILE...      # schema-check harness/runner outputs

Only the Python standard library is used.
"""
import argparse
import csv
import datetime
import glob
import json
import math
import os
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SCHEMA_PATH = os.path.join(ROOT, "schema", "benchmark-result.schema.json")
DATASETS = ["small", "medium", "large"]
OPS = ["wire_encode", "wire_decode", "json_encode", "json_decode"]


# ----------------------------------------------------------------------------- minimal JSON-schema
class SchemaError(Exception):
    pass


def _type_ok(value, t):
    return {
        "object": isinstance(value, dict),
        "array": isinstance(value, list),
        "string": isinstance(value, str),
        "integer": isinstance(value, int) and not isinstance(value, bool),
        "number": isinstance(value, (int, float)) and not isinstance(value, bool),
        "boolean": isinstance(value, bool),
        "null": value is None,
    }[t]


def validate(value, schema, path="$"):
    """Supports the subset of JSON Schema used by schema/benchmark-result.schema.json."""
    if "const" in schema and value != schema["const"]:
        raise SchemaError(f"{path}: expected {schema['const']!r}, got {value!r}")
    if "enum" in schema and value not in schema["enum"]:
        raise SchemaError(f"{path}: {value!r} not in {schema['enum']}")
    if "type" in schema:
        types = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        if not any(_type_ok(value, t) for t in types):
            raise SchemaError(f"{path}: expected type {types}, got {type(value).__name__}")
    if "minimum" in schema and isinstance(value, (int, float)) and value < schema["minimum"]:
        raise SchemaError(f"{path}: {value} < minimum {schema['minimum']}")
    if isinstance(value, dict):
        for req in schema.get("required", []):
            if req not in value:
                raise SchemaError(f"{path}: missing required key {req!r}")
        for key, sub in schema.get("properties", {}).items():
            if key in value:
                validate(value[key], sub, f"{path}.{key}")
    if isinstance(value, list) and "items" in schema:
        for i, item in enumerate(value):
            validate(item, schema["items"], f"{path}[{i}]")
    if "if" in schema:
        try:
            validate(value, schema["if"], path)
            matched = True
        except SchemaError:
            matched = False
        if matched and "then" in schema:
            validate(value, schema["then"], path)


def load_schema():
    with open(SCHEMA_PATH, encoding="utf-8") as f:
        return json.load(f)


# ----------------------------------------------------------------------------- statistics
def stats(values):
    values = sorted(values)
    n = len(values)
    if n == 0:
        return None
    mean = statistics.fmean(values)
    sd = statistics.stdev(values) if n > 1 else 0.0
    return {
        "n": n,
        "median": statistics.median(values),
        "mean": mean,
        "stddev": sd,
        "cv": (sd / mean) if mean else 0.0,
        "min": values[0],
        "max": values[-1],
    }


def impl_id(doc):
    impl = doc.get("implementation") or {}
    if impl.get("id"):
        return impl["id"]
    h = doc.get("harness") or {}
    lang = impl.get("language") or h.get("language") or "?"
    name = impl.get("name") or h.get("name") or "?"
    variant = impl.get("variant")
    return f"{lang}/{name}" + (f"/{variant}" if variant else "")


def aggregate(docs):
    """Group result documents by implementation and merge repeats."""
    impls = {}
    for doc in docs:
        key = impl_id(doc)
        entry = impls.setdefault(key, {
            "id": key,
            "language": (doc.get("implementation") or doc.get("harness") or {}).get("language"),
            "name": (doc.get("implementation") or doc.get("harness") or {}).get("name"),
            "variant": (doc.get("implementation") or {}).get("variant"),
            "version": (doc.get("implementation") or {}).get("version") or (doc.get("harness") or {}).get("library_version") or "?",
            "url": (doc.get("implementation") or {}).get("url", ""),
            "notes": (doc.get("implementation") or {}).get("notes", []),
            "runtime": (doc.get("harness") or {}).get("runtime", ""),
            "repeats": 0,
            "cells": {},
        })
        entry["repeats"] += 1
        run = doc.get("run") or {}
        entry.setdefault("_runs", set()).add((
            (doc.get("environment") or {}).get("hostname"),
            run.get("warmup_seconds"), run.get("warmup_max_seconds"), run.get("round_seconds"), run.get("rounds"),
        ))
        for r in doc.get("results", []):
            ck = f"{r['dataset']}:{r['operation']}"
            cell = entry["cells"].setdefault(ck, {
                "dataset": r["dataset"], "operation": r["operation"], "supported": r["supported"],
                "reason": r.get("reason"), "payload_bytes": r.get("payload_bytes"),
                "validation": r.get("validation"), "rounds_ops": [], "repeat_medians": [],
                "_warmup_ns": [], "_steady": [],
            })
            if not r["supported"]:
                cell["supported"] = False
                cell["reason"] = r.get("reason") or cell["reason"]
                continue
            ops = [rd["iterations"] / rd["elapsed_ns"] * 1e9 for rd in r.get("rounds", []) if rd["elapsed_ns"] > 0]
            cell["rounds_ops"].extend(ops)
            if ops:
                cell["repeat_medians"].append(statistics.median(ops))
            if r.get("validation"):
                cell["validation"] = r["validation"]
            if r.get("warmup_ns") is not None:
                cell["_warmup_ns"].append(r["warmup_ns"])
            if r.get("steady") is not None:
                cell["_steady"].append(bool(r["steady"]))
    for entry in impls.values():
        runs = sorted(entry.pop("_runs", set()), key=str)
        if len(runs) > 1:
            # Repeats are pooled, so files left over from an earlier run with other settings or
            # from another machine would silently skew the statistics: flag it loudly.
            desc = "; ".join(f"host {h}, warmup {w}s (cap {wm}s), {n} x {r}s" for h, w, wm, r, n in runs)
            msg = f"results pooled from runs with different settings or hosts ({desc})"
            print(f"warning: {entry['id']}: {msg}", file=sys.stderr)
            entry["notes"] = [f"WARNING: {msg}. Delete the stale result files and re-aggregate."] + list(entry["notes"])
        for cell in entry["cells"].values():
            warm = cell.pop("_warmup_ns"); steady = cell.pop("_steady")
            # warm-up actually spent (max over repeats) and whether every repeat reached steady
            # state; None for result files written before the steady-state detection existed.
            cell["warmup_ns_max"] = max(warm) if warm else None
            cell["steady"] = all(steady) if steady else None
            s = stats(cell.pop("rounds_ops"))
            if cell["supported"] and s:
                cell["ops_per_sec"] = s
                cell["ns_per_op"] = 1e9 / s["median"] if s["median"] else None
                pb = cell.get("payload_bytes") or 0
                cell["mb_per_sec"] = pb * s["median"] / 1e6
                rm = cell.pop("repeat_medians")
                cell["repeat_spread"] = (max(rm) / min(rm) - 1.0) if len(rm) > 1 and min(rm) > 0 else 0.0
            else:
                cell["supported"] = False
                cell.pop("repeat_medians", None)
    return impls


def write_csv(impls, path):
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["implementation", "language", "name", "version", "dataset", "operation", "supported",
                    "payload_bytes", "ops_per_sec_median", "ops_per_sec_mean", "ops_per_sec_stddev",
                    "ops_per_sec_min", "ops_per_sec_max", "ns_per_op", "mb_per_sec", "rounds",
                    "cv", "warmup_s_max", "steady",
                    "wire_bytes_match", "wire_size_match", "json_roundtrip_ok", "json_bytes", "reason"])
        for key in sorted(impls):
            e = impls[key]
            for ds in DATASETS:
                for op in OPS:
                    c = e["cells"].get(f"{ds}:{op}")
                    if not c:
                        continue
                    v = c.get("validation") or {}
                    s = c.get("ops_per_sec") or {}
                    w.writerow([key, e["language"], e["name"], e["version"], ds, op, c["supported"],
                                c.get("payload_bytes"), s.get("median"), s.get("mean"), s.get("stddev"),
                                s.get("min"), s.get("max"), c.get("ns_per_op"), c.get("mb_per_sec"), s.get("n"),
                                s.get("cv"), (c["warmup_ns_max"] / 1e9) if c.get("warmup_ns_max") is not None else None, c.get("steady"),
                                v.get("wire_bytes_match"), v.get("wire_size_match"), v.get("json_roundtrip_ok"),
                                v.get("json_bytes"), c.get("reason")])


def render_html(summary, out_path):
    with open(os.path.join(HERE, "template.html"), encoding="utf-8") as f:
        template = f.read()
    with open(os.path.join(HERE, "vendor", "chart.umd.js"), encoding="utf-8") as f:
        chartjs = f.read()
    data = json.dumps(summary, separators=(",", ":")).replace("</", "<\\/")
    html = template.replace("/*__CHARTJS__*/", chartjs).replace("/*__DATA__*/", data)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(html)


def console_table(impls, baseline):
    cols = [f"{d}:{o}" for d in DATASETS for o in OPS]
    short = {"wire_encode": "we", "wire_decode": "wd", "json_encode": "je", "json_decode": "jd"}
    print(f"{'implementation':28s} " + " ".join(f"{d[:3]}.{short[o]:2s}" for d in DATASETS for o in OPS) + "   (Mops/s; '-' = n/a)")
    for key in sorted(impls, key=lambda k: (k != baseline, k)):
        row = []
        for ck in cols:
            c = impls[key]["cells"].get(ck)
            if c and c.get("supported"):
                row.append(f"{c['ops_per_sec']['median']/1e6:6.3g}")
            else:
                row.append(f"{'-':>6s}")
        print(f"{key:28s} " + " ".join(row))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("results", nargs="*", help="results directory or result files")
    ap.add_argument("-o", "--out", default=None, help="report.html path (default RESULTS_DIR/report.html)")
    ap.add_argument("--baseline", default="zig/zig-protobuf")
    ap.add_argument("--validation", default=None, help="results/validation.json from tools/validate_outputs.py")
    ap.add_argument("--environment", default=None, help="environment.json (default: taken from results)")
    ap.add_argument("--validate-only", action="store_true")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    schema = load_schema()
    files = []
    for p in args.results or ["results"]:
        if os.path.isdir(p):
            files += sorted(f for f in glob.glob(os.path.join(p, "*.json"))
                            if os.path.basename(f) not in ("summary.json", "environment.json", "validation.json"))
        else:
            files.append(p)
    if not files:
        print("no result files found", file=sys.stderr)
        return 1

    docs = []
    bad = 0
    for path in files:
        try:
            with open(path, encoding="utf-8") as f:
                doc = json.load(f)
            validate(doc, schema)
            docs.append(doc)
            if args.validate_only:
                print(f"ok      {path}")
        except (json.JSONDecodeError, SchemaError) as e:
            bad += 1
            print(f"INVALID {path}: {e}", file=sys.stderr)
    if args.validate_only:
        return 1 if bad else 0
    if not docs:
        return 1

    impls = aggregate(docs)
    results_dir = args.results[0] if args.results and os.path.isdir(args.results[0]) else os.path.dirname(files[0]) or "."
    out_html = args.out or os.path.join(results_dir, "report.html")

    environment = None
    env_path = args.environment or os.path.join(results_dir, "environment.json")
    if os.path.exists(env_path):
        with open(env_path, encoding="utf-8") as f:
            environment = json.load(f)
    if environment is None:
        environment = docs[0].get("environment")

    cross = None
    val_path = args.validation or os.path.join(results_dir, "validation.json")
    if os.path.exists(val_path):
        with open(val_path, encoding="utf-8") as f:
            cross = json.load(f)

    summary = {
        "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "baseline": args.baseline if args.baseline in impls else (sorted(impls)[0] if impls else None),
        "datasets": DATASETS,
        "operations": OPS,
        "environment": environment,
        "run": docs[0].get("run"),
        "cross_validation": cross,
        "implementations": [impls[k] for k in sorted(impls)],
        "source_files": [os.path.basename(f) for f in files],
    }
    with open(os.path.join(results_dir, "summary.json"), "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=1)
    write_csv(impls, os.path.join(results_dir, "summary.csv"))
    render_html(summary, out_html)
    if not args.quiet:
        console_table(impls, summary["baseline"])
        print(f"\nreport: {out_html}\nsummary: {os.path.join(results_dir, 'summary.json')}, {os.path.join(results_dir, 'summary.csv')}")
    if bad:
        print(f"{bad} invalid result file(s) were skipped", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
