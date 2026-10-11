# Methodology

The goal is a *fair* comparison of protobuf implementations across languages. "Fair" here means:
every implementation does the same work on the same data, is measured by the same algorithm, is
built the way its own documentation recommends for production, and is run under the same machine
conditions. Where a library cannot do something, that is reported rather than approximated.

## What is measured

Four operations, three datasets, every implementation:

| operation | input | output |
|---|---|---|
| `wire_decode` | fixture bytes (`fixtures/<ds>.bin`) | a fully materialised message object (then released) |
| `wire_encode` | the message decoded from the fixture | a new byte buffer |
| `json_decode` | fixture ProtoJSON text (`fixtures/<ds>.json`) | a message object (then released) |
| `json_encode` | the message decoded from the fixture | ProtoJSON text |

| dataset | shape | wire size | JSON size |
|---|---|---|---|
| `small` | flat scalars, one string ("RPC request") | 39 B | 126 B |
| `medium` | nested messages, 40 repeated submessages, map<string,int64>, oneof, bytes ("business document") | 4.8 KB | 8.3 KB |
| `large` | packed double/int32/sint64 arrays (20k/50k/30k), 5k + 10k submessages, map<int32,string>, 64 KiB blob ("telemetry batch") | 819 KB | 1.75 MB |

The schema (`proto/bench.proto`) is proto3 without well-known types, extensions, groups or
`optional`, because some of the libraries (nanopb, protobuf-c, protobuf-net) do not
support those or treat them differently; keeping them out means every implementation runs the whole
matrix on identical semantics.

The fixtures are generated once by `tools/gen_fixtures.py` from a self-contained splitmix64 PRNG
with fixed seeds, serialised by the official Python runtime, and committed. `run.sh` regenerates
them in a temp dir and refuses to continue if they differ.

## How it is measured

Every harness runs the *same* algorithm (`docs/HARNESS.md`), hand-written in each language, instead
of using the language's benchmark framework. Frameworks (JMH, criterion, BenchmarkDotNet,
google/benchmark, pyperf) each have their own ideas about warm-up, outlier rejection and statistics,
which makes their numbers incomparable; a shared algorithm avoids that:

1. **Calibration**: the batch size is doubled until one batch takes ≥ 10 ms, so clock reads are
   amortised identically everywhere (they matter at 20 M ops/s, not at 5 ops/s).
2. **Warm-up with steady-state detection**: at least 3 s per dataset × operation (default), then
   0.5 s probes until three consecutive probes agree within 5 %, with a cap of 15 s. A fixed 3 s was
   not enough for .NET's tiered PGO on a pinned core (its first timed rounds ran 5× slower), and no
   fixed number is right for every runtime; the criterion is. Cells that hit the cap without
   stabilising are flagged (⏱) in the report, and the warm-up actually spent is recorded per cell.
   For the JIT runtimes this phase is *not* discarded data, it is simply not reported.
3. **Timed rounds**: 10 rounds of 1 s (default). Each round reports raw `(iterations, elapsed_ns)`.
   Rounds give an honest spread: the report shows median, mean ± stddev, min, max, coefficient of
   variation.
4. **Repeats**: `./run.sh --repeat N` runs the whole suite N times, rotating the start of the order
   on every repeat (A B C, B C A, C A B, …) so that thermal throttling or background drift does not
   systematically favour whoever runs first and no implementation runs twice back-to-back. All
   rounds of all repeats are pooled; the spread between repeats is also recorded (`repeat_spread`).

Per-iteration rules that keep implementations comparable:

* A **new** output buffer / message object per iteration; no buffer or object reuse, no
  object pools, no arenas reset per iteration (unless a library has no allocating API at all, in
  which case the note is shown in the report).
* Any mandatory cleanup (free, deinit, release) is inside the timed iteration.
* GC languages do not call the GC manually.
* A black hole consumes one scalar of the decoded message / the length of the produced buffer so
  dead-code elimination cannot remove the work.
* Static generated code only; no reflection-based or dynamic-message paths unless that is the only
  JSON path the library offers (documented per implementation).
* The JSON format must be canonical ProtoJSON. Libraries without it report the JSON operations as
  unsupported instead of benchmarking a different format.

Allocation-strategy variants of the implementation under test: `zig/zig-protobuf-arena` and
`zig/zig-protobuf-fba` run the very same zig-protobuf build and harness code but hand the library an
`std.heap.ArenaAllocator` (reset with `.retain_capacity` after every iteration) or a
`std.heap.FixedBufferAllocator` over a preallocated slab (`reset()` after every iteration), and skip
all individual frees. They intentionally violate the first rule above and are labelled as such in
the report: they show how much of zig-protobuf's cost is allocator work and what a caller who owns an
arena can expect, not a like-for-like comparison with the other libraries' default columns. The
`zig/zig-protobuf` column (general purpose allocator, everything freed individually) remains the
comparable one and the default baseline.

Machine conditions (`run.sh`):

* one benchmark process at a time, pinned with `taskset` to the CPU set allowed to the
  container/shell (recorded as `run.cpuset`). Pinning everyone to the same set keeps the runtimes'
  processor-count ergonomics intact: HotSpot keeps G1 and its compiler threads, Go keeps
  `GOMAXPROCS` = set size, .NET keeps its tiering threads. (`taskset` affinity is inherited by every
  thread, so pinning to *one* core would silently switch the JVM to SerialGC with two compiler
  threads and set `GOMAXPROCS=1`.) `--core C` restricts every implementation to one core instead, for
  a pure single-core CPU-cost comparison; the report shows which mode was used;
* release builds for everyone (`-O3`, `--release`, `ReleaseFast`, `-c Release`); no LTO/PGO/
  `-march=native` for anyone;
* machine, kernel, governor, SMT state and every toolchain version are recorded in
  `results/environment.json` and shown in the report.

What Docker cannot do for you: set the CPU governor to `performance`, disable turbo boost and SMT,
or isolate the core from the host scheduler. For publication-quality numbers do that on the host
(`cpupower frequency-set -g performance`, `echo 0 > /sys/devices/system/cpu/smt/control`,
`isolcpus=`/`nohz_full=` kernel parameters) and pass the isolated cores with `--cpuset-cpus`.

## Validation

Numbers are only meaningful if everyone did the same work. Three layers check that:

1. **Self-validation** (in every harness, before timing): re-encoding the decoded fixture must
   produce the same number of bytes (`wire_size_match`; byte identity, `wire_bytes_match`, may fail
   only because of map iteration order), and a JSON round trip must come back to the same message
   (`json_roundtrip_ok`).
2. **Cross-validation** (`tools/validate_outputs.py`): each harness dumps its own wire and JSON
   output. The reference runtime (official Python protobuf / upb) parses both and compares them to
   the fixture message, and the wire dump must have the fixture's size; this catches lazy or partial
   decoders and dropped fields. Because the reference JSON parser is lenient (it accepts snake_case
   keys, numeric int64 and enum numbers), the dumped JSON is additionally walked against the message
   descriptor and must be canonical ProtoJSON: lowerCamelCase keys, 64-bit integers as strings,
   enums as names, bytes as base64, proto3 defaults omitted (whitespace is ignored). Each problem is
   listed in `results/validation.json` and the report.
3. **Size columns** in the report: `json_bytes` exposes libraries that pretty-print or emit
   defaults; `payload_bytes` is always the fixture size so MB/s stays comparable.

## Reading the report

* Prefer the **medium** dataset for a general impression; `small` is dominated by per-call
  overhead (allocation, FFI, JIT inlining), `large` by raw packed-array throughput and memcpy.
* Compare encode and decode separately; libraries are often asymmetric (zero-copy decoders,
  reflection-based JSON printers).
* Look at the coefficient of variation: a `cv` above 5 % is shown in red and means the machine was
  noisy or the runtime was not steady; rerun with more repeats or on isolated cores. A ⏱ marker
  means the warm-up cap was reached before the throughput stabilised.
* `json_bytes` differs between implementations for legitimate reasons, all disclosed in the notes:
  C#, Python and rust-protobuf emit a space after `:` and `,` (about 10 % more bytes); zig-protobuf
  and both JavaScript libraries print 32-bit `float` fields as the exact double value
  (`575.219970703125` instead of `575.22`), which inflates `large` to 2.07 MB against 1.75 MB;
  protojson adds a per-binary random choice of whitespace. All of them parse back to the identical
  message (cross-validation checks it) and MB/s uses the fixture size, so throughput stays comparable;
  but a library that writes more bytes per `json_encode` really does more work, and that is its cost.
* The ratio column is relative to the selected baseline (default `zig/zig-protobuf`): 2.0× means
  twice the throughput of the baseline.

## Prior art this design borrows from

* the protobuf repository's own `benchmarks/` (shared datasets, parse + serialize per language);
* `rust_serialization_benchmark` (fixed datasets, serialize/deserialize/size per library);
* JMH's throughput mode (time-boxed rounds, warm-up, raw per-round data) and its black-hole;
* the rotated-order interleaving used in multi-runtime benchmark suites to cancel drift.
