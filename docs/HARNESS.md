# Harness contract

Every implementation directory (`<language>/<name>/`) contains:

| File | Purpose |
|---|---|
| `meta.json` | `{"language", "name", "variant", "url", "version", "notes": [...]}`. `version` may be `"auto"`: then `build.sh` must write the resolved version into `build/version.txt`. |
| `build.sh` | Code generation + release build. Must be idempotent and leave an executable entry point behind. Runs with cwd = the implementation directory. |
| `run.sh` | Executes the benchmark binary, forwarding all CLI arguments verbatim. Runs with cwd = the implementation directory. |

`build.sh`/`run.sh` can rely on `$PROTO_DIR` (absolute path of `proto/`), `$PROTOC` (protoc binary),
and `$BENCH_ROOT` (repository root) being exported by the root `run.sh`.

## Command line (identical for all harnesses)

```
--fixtures DIR        directory containing small|medium|large.{bin,json}     (required)
--out FILE            where to write the result JSON                          (required)
--warmup-seconds F    minimum warm-up per dataset x operation   (default 3)
--warmup-max-seconds F
                      warm-up cap for the steady-state detection (default 15; clamped up to
                      --warmup-seconds when smaller)
--round-seconds F     duration of one timed round                (default 1)
--rounds N            number of timed rounds                     (default 10)
--datasets a,b        subset of small,medium,large               (default all)
--ops a,b             subset of wire_encode,wire_decode,json_encode,json_decode (default all)
--dump DIR            if given, write <dataset>.wire.bin and <dataset>.json produced by this
                      implementation into DIR (used by tools/validate_outputs.py)
```

Unknown arguments are an error. Values of `F` are decimal seconds; negative values are an error.

## Operations (what exactly is timed)

The fixture message is decoded once up-front (`fixture_msg`) and the fixture JSON text is read once.

| op | one iteration is | result consumed by the black hole |
|---|---|---|
| `wire_decode` | `fixture.bin` bytes -> fully materialised message object, which is then released/dropped | one scalar of the message (e.g. `id`, `created_at`, length of `source`) |
| `wire_encode` | `fixture_msg` -> newly produced byte buffer | length of the buffer |
| `json_decode` | `fixture.json` text (UTF-8 bytes or string, whatever is idiomatic) -> message object, released afterwards | one scalar of the message |
| `json_encode` | `fixture_msg` -> JSON text | length of the text |

Rules:

* Use the idiomatic *fast path* of the library (static generated code, no reflection, no
  dynamic messages) exactly as a performance-conscious user would in production code.
* Allocate a **new** output buffer/object per iteration. Do not reuse message objects or output
  buffers across iterations, unless the library offers *no* allocating API (then say so in
  `meta.json` `notes`).
* Any per-iteration cleanup required by the library (free/deinit/release/pool-return) is part of
  the timed iteration, because a real user pays for it too.
* Garbage-collected languages: do not call the GC manually inside the loop.
* No validation, no `verify` passes, no extra copies that a user wouldn't make.
* JSON must be the canonical ProtoJSON mapping (lowerCamelCase names, 64-bit ints as strings,
  enums as names, bytes as base64, defaults omitted). If the library cannot produce it, the op is
  reported as `"supported": false` with a `reason`; do not substitute a non-canonical format.
* The black hole: keep a global/volatile accumulator and fold the "result consumed" column into
  it every iteration; print it once at the end so the optimiser cannot remove the work.

## Measurement algorithm (identical for all harnesses)

```
for dataset in datasets:
    wire = read(fixtures/<dataset>.bin); json = read(fixtures/<dataset>.json)
    fixture_msg = decode(wire)
    validation (see below)
    for op in ops:
        if not supported: record {supported:false, reason}; continue
        batch = 1
        loop:                                   # calibration
            t = time(run op `batch` times)
            if t >= 10 ms: break
            batch = batch * 2
        # warm-up (JIT, caches, allocator): at least warmup_seconds, then keep going in
        # probes of PROBE_NS until STEADY_WINDOW consecutive probes agree within STEADY_TOL,
        # or until warmup_max_seconds is used up. Constants, identical everywhere:
        #   PROBE_NS = 500_000_000   STEADY_WINDOW = 3   STEADY_TOL = 0.05
        min_ns = int(warmup_seconds * 1e9); max_ns = max(int(warmup_max_seconds * 1e9), min_ns)
        rates = ring buffer of STEADY_WINDOW floats; n = 0; steady = false; w0 = now
        loop:
            elapsed = now - w0
            if elapsed >= max_ns: break                        # cap (also handles max_ns == 0)
            probe_ns = min(PROBE_NS, max_ns - elapsed)
            p0 = now; iters = 0
            while now - p0 < probe_ns: run op `batch` times; iters += batch
            rates[n % STEADY_WINDOW] = iters * 1e9 / (now - p0); n += 1
            if now - w0 >= min_ns and n >= STEADY_WINDOW and max(rates) <= min(rates) * (1 + STEADY_TOL):
                steady = true; break
        warmup_ns = now - w0                     # recorded per cell with `steady`
        for r in 1..rounds:                     # timed rounds
            iters = 0; start = now
            while now - start < round_seconds:
                run op `batch` times; iters += batch
            elapsed_ns = now - start            # measured *after* the last batch
            record {iterations: iters, elapsed_ns}
```

All time arithmetic is done in integer nanoseconds; only the probe rates are floating point. The
minimum phase is itself made of probes, so a runtime that is already steady pays no extra time
(3 s = 6 probes, the last 3 are compared). With `--quick` the cap equals the minimum, so no probe
beyond it runs and `steady` is false by construction.

Use the highest-resolution monotonic clock available (`clock_gettime(CLOCK_MONOTONIC)`,
`std::chrono::steady_clock`, `System.nanoTime`, `Stopwatch`, `process.hrtime.bigint`,
`time.perf_counter_ns`, `std.time.Timer`, `DispatchTime`/`clock_gettime`, `Instant`).

## Validation (performed once per dataset, before timing)

| key | meaning |
|---|---|
| `wire_bytes_match` | `encode(fixture_msg)` is byte-identical to `fixture.bin` |
| `wire_size_match` | same length (map iteration order may legitimately differ) |
| `json_roundtrip_ok` | `encode(json_decode(json_encode(fixture_msg)))` has the same length as `fixture.bin` (byte-identical when `wire_bytes_match`) |
| `json_bytes` | length in bytes of `json_encode(fixture_msg)` |

With `--dump DIR` the harness also writes its own `encode(fixture_msg)` and `json_encode(fixture_msg)`
outputs so `tools/validate_outputs.py` can cross-check them with the reference implementation.

## Output file

The harness writes the fields below. The root runner later adds `implementation`, `environment` and
`run` (from `meta.json`, `tools/env_info.sh`, and its own arguments), so harnesses must not fail when
they are absent and must not invent them. See `schema/benchmark-result.schema.json`.

```json
{
  "schema_version": 1,
  "harness": { "language": "python", "name": "protobuf", "runtime": "CPython 3.12.3", "library_version": "7.36.2" },
  "results": [
    {
      "dataset": "small",
      "operation": "wire_decode",
      "supported": true,
      "payload_bytes": 39,
      "validation": { "wire_bytes_match": true, "wire_size_match": true, "json_roundtrip_ok": true, "json_bytes": 126 },
      "warmup_ns": 3512345678,
      "steady": true,
      "batch": 1024,
      "rounds": [ { "iterations": 1048576, "elapsed_ns": 1000312345 } ]
    },
    { "dataset": "small", "operation": "json_encode", "supported": false,
      "reason": "protobuf-c has no JSON support" }
  ]
}
```

`payload_bytes` is the size of the *input* of the operation (wire bytes for `wire_decode`/`wire_encode`,
JSON bytes for the JSON ops); the aggregator derives MB/s from it. `warmup_ns` is the warm-up actually
spent on the cell and `steady` whether the steady-state criterion was met before the cap; the report
flags cells with `steady: false`.

Progress line: after each cell the harness prints one line to stderr containing `ops/s` (the runner
echoes those), ending with ` warmup <seconds>s steady` or ` ... NOT steady`.
