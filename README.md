# proto-benchmarks

A fair, reproducible benchmark of Protocol Buffers implementations across ten languages, built to
compare [zig-protobuf](https://github.com/Arwalk/zig-protobuf) with the popular implementations in
Rust, C, C++, Java, Python, C#, JavaScript, Go and Swift. It measures wire encoding/decoding and
canonical JSON (ProtoJSON) encoding/decoding on three shared datasets and renders everything into
one self-contained HTML report.

* `docs/METHODOLOGY.md` — what is measured, how, and why it is fair.
* `docs/HARNESS.md` — the contract every harness implements (CLI, loop, output format).
* `docs/implementations.md` — which libraries were picked and why.
* `docs/IMPLEMENTING.md` — how to add another implementation.

Besides the default `zig/zig-protobuf` column (general purpose allocator, individual frees), two
allocation-strategy variants of the same build are measured: `zig/zig-protobuf-arena` (arena reset
per iteration) and `zig/zig-protobuf-fba` (fixed buffer reset per iteration). They are labelled as
not like-for-like in the report; see `docs/METHODOLOGY.md`.

## Run it with Docker (recommended)

```bash
docker build -t proto-benchmarks .            # ~20-40 min: builds every toolchain and harness
mkdir -p results
docker run --rm --cpuset-cpus=0-2 -v "$PWD/results:/bench/results" proto-benchmarks
# -> results/report.html, results/summary.json, results/summary.csv, raw per-run JSON, logs
```

Or with compose: `docker compose run --rm bench` (options pass through, e.g.
`docker compose run --rm bench --quick`).

The image is large (about 10 GB: ten toolchains plus prebuilt harnesses). The container's entry point
is `./run.sh --skip-build`, so it starts benchmarking immediately; any `run.sh` option can be appended.

`--cpuset-cpus` gives the container a few cores; the runner pins every benchmark process to that
whole set, so each runtime keeps its usual GC/JIT helper threads (add `--core N` to force a single
core instead). Pass `--repeat 3` for publication-quality numbers (the suite is rerun in rotated order
to cancel thermal drift). See `docs/METHODOLOGY.md` for host settings (governor, SMT, turbo) that
Docker cannot change.

zig-protobuf is pinned to the commit under test (see `zig/zig-protobuf/build.zig.zon`). Benchmark
another revision: `docker build --build-arg ZIG_PROTOBUF_REF=<branch-or-sha> ...`.

## Run it natively

Install the toolchains listed in `docs/IMPLEMENTING.md` (protoc 36.2, gcc/cmake, libprotobuf 36.2,
protobuf-c, rustup, Go, JDK 21 + Maven, Python 3, .NET SDK 8, Node 22, Swift 6.2, Zig 0.16), then:

```bash
./run.sh                          # build all, run all, cross-validate, aggregate
./run.sh --quick                  # smoke test (0.2 s warm-up without steady-state probes, 2 x 0.2 s rounds)
./run.sh --only zig/zig-protobuf,rust/prost --repeat 3 --core 5
./run.sh --skip-build --no-report # rerun only
python3 report/aggregate.py results/ --baseline cpp/protobuf   # re-render with another baseline
```

`./run.sh --help` lists all options. A failing implementation never aborts the suite: failures are
collected in `results/failures.txt` with a pointer to the log, and the report is still generated.

## Known limitations

* Results come from a single host; absolute numbers are not transferable, only the ratios measured on
  the same machine in the same run.
* Runs under WSL2, a VM or Docker Desktop are indicative only: no governor control, host scheduler
  noise, virtualised timers. The committed methodology assumes a native Linux host.
* One process at a time, pinned to the allowed CPU set; multi-threaded throughput is not measured.
* Warm-up is adaptive (minimum 3 s, then until the throughput is steady, capped at 15 s); cells that
  never stabilised are marked in the report and should be read with care.

## Layout

```
proto/bench.proto      shared schema            fixtures/   committed datasets (bin + json)
<lang>/<impl>/         one harness per library  report/     aggregator + HTML template (stdlib Python)
tools/                 fixture generator, environment capture, cross-validation, result finalizer
schema/                JSON schema of the result files
run.sh                 build + run + validate + report      Dockerfile / docker-compose.yml
```

Every harness directory contains `meta.json` (identity, version, caveats), `build.sh` and `run.sh`;
the root runner discovers them automatically.

## Output format

One JSON file per implementation per repeat (`results/<language>-<name>.<repeat>.json`) validated
against `schema/benchmark-result.schema.json`; `summary.json`/`summary.csv` hold the aggregated
statistics (median, mean, stddev, min, max ops/s; ns/op; MB/s) and `report.html` is the page.
