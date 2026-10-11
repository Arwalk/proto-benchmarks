"""Shared measurement loop for the Python harnesses (see docs/HARNESS.md).

Both Python implementations import this module so the timing code is identical;
only the four operations differ.
"""
import argparse
import json
import os
import sys
import time

DATASETS = ["small", "medium", "large"]
OPS = ["wire_encode", "wire_decode", "json_encode", "json_decode"]

WARMUP_PROBE_NS = 500_000_000  # length of one warm-up probe (throughput sample)
STEADY_WINDOW = 3  # consecutive probes that must agree for the warm-up to count as steady
STEADY_TOL = 0.05  # relative spread (max/min - 1) tolerated across the window


class Implementation:
    language = "python"
    name = "?"

    def runtime(self):
        return sys.version.split()[0]

    def library_version(self):
        return "?"

    # Each op takes (dataset, input) and returns the produced object.
    def wire_decode(self, dataset, data): raise NotImplementedError
    def wire_encode(self, dataset, msg): raise NotImplementedError
    def json_decode(self, dataset, text): raise NotImplementedError
    def json_encode(self, dataset, msg): raise NotImplementedError
    def scalar(self, dataset, msg): raise NotImplementedError

    def unsupported(self, op):
        """Return a reason string if `op` is not supported, else None."""
        return None


def _duration(s):
    d = float(s)
    if not d >= 0.0:
        raise argparse.ArgumentTypeError(f"invalid duration {s!r} (must be >= 0 seconds)")
    return d


def parse_args(argv):
    ap = argparse.ArgumentParser(allow_abbrev=False)
    ap.add_argument("--fixtures", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--warmup-seconds", type=_duration, default=3.0, help="minimum warm-up per cell")
    ap.add_argument("--warmup-max-seconds", type=_duration, default=15.0, help="warm-up cap per cell")
    ap.add_argument("--round-seconds", type=_duration, default=1.0)
    ap.add_argument("--rounds", type=int, default=10)
    ap.add_argument("--datasets", default=",".join(DATASETS))
    ap.add_argument("--ops", default=",".join(OPS))
    ap.add_argument("--dump", default=None)
    return ap.parse_args(argv)


def measure(fn, warmup_s, warmup_max_s, round_s, rounds):
    """Calibrate batch, warm up until steady state (or the cap), then run the timed rounds.

    Returns (batch, rounds, warmup_ns, steady).
    """
    now = time.perf_counter_ns
    batch = 1
    while True:  # calibration
        t0 = now()
        for _ in range(batch):
            fn()
        if now() - t0 >= 10_000_000:
            break
        batch *= 2
    # warm-up (JIT, caches, allocator): at least warmup_s, at most warmup_max_s; stop early once
    # STEADY_WINDOW consecutive probe throughputs are within STEADY_TOL of each other.
    min_ns = int(warmup_s * 1e9)
    max_ns = int(warmup_max_s * 1e9)
    if max_ns < min_ns:
        max_ns = min_ns
    rates = [0.0] * STEADY_WINDOW
    n = 0
    steady = False
    w0 = now()
    while True:
        elapsed = now() - w0
        if elapsed >= max_ns:  # cap; also handles max_ns == 0
            break
        probe_ns = min(WARMUP_PROBE_NS, max_ns - elapsed)
        p0 = now()
        iters = 0
        while now() - p0 < probe_ns:
            for _ in range(batch):
                fn()
            iters += batch
        rates[n % STEADY_WINDOW] = iters * 1e9 / (now() - p0)
        n += 1
        if now() - w0 >= min_ns and n >= STEADY_WINDOW:
            lo = min(rates)
            hi = max(rates)
            if hi <= lo * (1.0 + STEADY_TOL):
                steady = True
                break
    warmup_ns = now() - w0
    out = []
    round_ns = int(round_s * 1e9)
    for _ in range(rounds):
        iters = 0
        start = now()
        while now() - start < round_ns:
            for _ in range(batch):
                fn()
            iters += batch
        out.append({"iterations": iters, "elapsed_ns": now() - start})
    return batch, out, warmup_ns, steady


def main(impl: Implementation, argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    datasets = [d for d in args.datasets.split(",") if d]
    ops = [o for o in args.ops.split(",") if o]
    for d in datasets:
        if d not in DATASETS:
            sys.exit(f"unknown dataset {d}")
    for o in ops:
        if o not in OPS:
            sys.exit(f"unknown op {o}")

    sink = 0
    results = []
    for ds in datasets:
        with open(os.path.join(args.fixtures, f"{ds}.bin"), "rb") as f:
            wire = f.read()
        with open(os.path.join(args.fixtures, f"{ds}.json"), "r", encoding="utf-8") as f:
            text = f.read()
        fixture_msg = impl.wire_decode(ds, wire)

        # validation
        reenc = impl.wire_encode(ds, fixture_msg)
        validation = {
            "wire_bytes_match": reenc == wire,
            "wire_size_match": len(reenc) == len(wire),
            "json_roundtrip_ok": None,
            "json_bytes": None,
        }
        json_ok = impl.unsupported("json_encode") is None and impl.unsupported("json_decode") is None
        if json_ok:
            js = impl.json_encode(ds, fixture_msg)
            validation["json_bytes"] = len(js.encode("utf-8")) if isinstance(js, str) else len(js)
            back = impl.wire_encode(ds, impl.json_decode(ds, js))
            validation["json_roundtrip_ok"] = (back == wire) if validation["wire_bytes_match"] else (len(back) == len(wire))
            if args.dump:
                os.makedirs(args.dump, exist_ok=True)
                with open(os.path.join(args.dump, f"{ds}.json"), "w" if isinstance(js, str) else "wb", encoding="utf-8" if isinstance(js, str) else None) as f:
                    f.write(js)
        if args.dump:
            os.makedirs(args.dump, exist_ok=True)
            with open(os.path.join(args.dump, f"{ds}.wire.bin"), "wb") as f:
                f.write(reenc)

        for op in ops:
            reason = impl.unsupported(op)
            if reason:
                results.append({"dataset": ds, "operation": op, "supported": False, "reason": reason})
                continue
            if op == "wire_decode":
                payload = len(wire)
                def fn(ds=ds, wire=wire):
                    nonlocal sink
                    sink ^= impl.scalar(ds, impl.wire_decode(ds, wire))
            elif op == "wire_encode":
                payload = len(wire)
                def fn(ds=ds, m=fixture_msg):
                    nonlocal sink
                    sink ^= len(impl.wire_encode(ds, m))
            elif op == "json_decode":
                payload = len(text.encode("utf-8"))
                def fn(ds=ds, text=text):
                    nonlocal sink
                    sink ^= impl.scalar(ds, impl.json_decode(ds, text))
            else:
                payload = len(text.encode("utf-8"))
                def fn(ds=ds, m=fixture_msg):
                    nonlocal sink
                    sink ^= len(impl.json_encode(ds, m))
            batch, rounds, warmup_ns, steady = measure(
                fn, args.warmup_seconds, args.warmup_max_seconds, args.round_seconds, args.rounds)
            results.append({
                "dataset": ds, "operation": op, "supported": True, "payload_bytes": payload,
                "validation": validation, "warmup_ns": warmup_ns, "steady": steady,
                "batch": batch, "rounds": rounds,
            })
            best = max(r["iterations"] / r["elapsed_ns"] * 1e9 for r in rounds)
            print(f"{impl.language}/{impl.name} {ds:6s} {op:12s} {best:14.1f} ops/s"
                  f" warmup {warmup_ns / 1e9:.1f}s {'steady' if steady else 'NOT steady'}", file=sys.stderr)

    doc = {
        "schema_version": 1,
        "harness": {"language": impl.language, "name": impl.name,
                    "runtime": impl.runtime(), "library_version": impl.library_version()},
        "results": results,
    }
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=1)
    print(f"sink={sink}", file=sys.stderr)
