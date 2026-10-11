# Adding an implementation

Read `docs/HARNESS.md` first; it is the contract. Then follow these rules.

## Directory

`<language>/<name>/` with `meta.json`, `build.sh`, `run.sh` plus whatever the build needs.
Everything generated or downloaded goes under `build/` or `gen/` inside that directory (both are
git-ignored). Never write outside your directory.

## Toolchains

The Docker image (and a developer machine) provides only base toolchains on `PATH`:

| what | where |
|---|---|
| `protoc` 36.2 | `$PROTOC` (also on PATH); well-known-type includes at `$(dirname $PROTOC)/../include` |
| C / C++ | gcc, g++, cmake, ninja, pkg-config; libprotobuf 36.2 + abseil installed under `/usr/local` (Docker) |
| protobuf-c | distro `protoc-gen-c` + `libprotobuf-c-dev` (pkg-config `libprotobuf-c`) |
| Rust | rustup stable: `cargo`, `rustc` |
| Go | `go` (1.26) |
| Java | JDK 21, `mvn` (Maven ignores `HTTPS_PROXY`; `tools/maven_settings.sh` turns it into a settings.xml) |
| Python | `python3` (3.12+) with `venv` |
| C# | `dotnet` SDK 8 |
| JavaScript | `node` 22, `npm` |
| Swift | `swift` 6.2 |
| Zig | `zig` 0.16.0; optional `PROTOC_ARCHIVE_DIR` holding the protoc release zip that zig-protobuf declares as a package dependency (the Docker image sets it; otherwise `zig/zig-protobuf/build.sh` downloads the zip from GitHub) |

Anything else (protoc plugins such as `protoc-gen-go`, `protoc-gen-es`, `protoc-gen-swift`,
`pbjs`, `protogen`, nanopb generator and runtime sources, Maven/npm/NuGet/crates packages) must be
installed **by `build.sh` into the implementation's own `build/` directory**, with pinned versions.
Network access is available while `build.sh` runs (the Docker image runs all `build.sh` scripts at
image build time); the benchmark itself runs offline.

## Build flags

Release/optimised builds only: `-O3 -DNDEBUG`, `cargo build --release`, `-Doptimize=ReleaseFast
-Dcpu=baseline`, `dotnet -c Release`, `swift build -c release`, Go default (no `-race`, no `-N -l`),
Java default JIT (no `-Xint`, no `-Xcomp`), Node default flags. Do not enable LTO/PGO/`-march=native`
for some implementations and not others: the rule is "what the library's documented release build
gives you" on the generic x86-64 target. gcc, rustc, Go and Swift default to that target; Zig
defaults to the *host* CPU, hence the explicit `-Dcpu=baseline`.

## Version reporting

`meta.json` `version` is either a literal string or `"auto"`. With `"auto"`, `build.sh` must write
the resolved library version into `build/version.txt` (e.g. from the lock file).

## Checklist

- [ ] All four operations implemented, or `"supported": false` with a precise `reason`.
- [ ] The measurement loop matches `docs/HARNESS.md` exactly, including `--warmup-max-seconds` and
      the steady-state probes; every cell reports `warmup_ns` and `steady`.
- [ ] Validation keys filled; `wire_size_match` must be true for every dataset.
- [ ] `--dump` implemented.
- [ ] `./build.sh && ./run.sh --fixtures $BENCH_ROOT/fixtures --out /tmp/x.json --warmup-seconds 0.2 --warmup-max-seconds 0.2 --round-seconds 0.2 --rounds 2` works.
- [ ] `python3 report/aggregate.py --validate-only /tmp/x.json` passes.
- [ ] `meta.json` `notes` documents every deviation from the idiomatic path and every caveat.
