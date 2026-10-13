# Implementation selection

Up to two implementations per language, chosen by popularity (registry downloads, GitHub stars,
maintenance activity as of October 2026) and by whether they can take part in all four operations.
Libraries that cannot do canonical ProtoJSON are still benchmarked on the wire format and show
`n/a` for JSON.

| language | implementation | version | wire | JSON | selection notes |
|---|---|---|---|---|---|
| Zig | [zig-protobuf](https://github.com/Arwalk/zig-protobuf) | 7.0.0 (commit e9e18c7, pinned) | ✓ | ✓ | the implementation under test; general purpose allocator, every object freed individually |
| Zig | zig-protobuf `arena` variant (`zig/zig-protobuf-arena`) | same build | ✓ | ✓ | same binary code, `std.heap.ArenaAllocator` reset per iteration; see "allocation-strategy variants" in `docs/METHODOLOGY.md` |
| Zig | zig-protobuf `fixed-buffer` variant (`zig/zig-protobuf-fba`) | same build | ✓ | ✓ | same binary code, `std.heap.FixedBufferAllocator` reset per iteration; same caveat |
| Zig | zig-protobuf `native-cpu` variants (`zig/zig-protobuf-native`, `-arena-native`, `-fba-native`) | same build | ✓ | ✓ | the three strategies above compiled for the host CPU instead of the x86-64 baseline; not like-for-like, see "CPU-target variants" in `docs/METHODOLOGY.md` |
| Rust | [prost](https://github.com/tokio-rs/prost) + [pbjson](https://github.com/influxdata/pbjson) | 0.14 / 0.9 | ✓ | ✓ | ~145 M recent crates.io downloads; JSON needs the pbjson serde generator |
| Rust | [rust-protobuf](https://github.com/stepancheg/rust-protobuf) | 3.7 | ✓ | ✓ | ~29 M downloads; JSON through `protobuf-json-mapping` (reflection) |
| C | [protobuf-c](https://github.com/protobuf-c/protobuf-c) | 1.4/1.5 (distro) | ✓ | – | 3 k stars; no JSON |
| C | [nanopb](https://github.com/nanopb/nanopb) | 0.4.9 | ✓ | – | 5.6 k stars; embedded-oriented, run here in malloc mode; no JSON |
| C++ | [protobuf](https://github.com/protocolbuffers/protobuf) | 36.2 | ✓ | ✓ | Google's reference runtime (`util/json_util`) |
| Java | [protobuf-java](https://github.com/protocolbuffers/protobuf/tree/main/java) | 4.36 | ✓ | ✓ | official; JSON via `JsonFormat` (protobuf-java-util) |
| Java | [Wire](https://github.com/square/wire) | 5.5 | ✓ | ✓ | 4.4 k stars; JSON via `wire-moshi-adapter` |
| Python | [protobuf](https://github.com/protocolbuffers/protobuf/tree/main/python) | 7.36 | ✓ | ✓ | official, upb backend; JSON via `json_format` |
| C# | [Google.Protobuf](https://github.com/protocolbuffers/protobuf/tree/main/csharp) | 3.36 | ✓ | ✓ | 1.4 B NuGet downloads; `JsonFormatter`/`JsonParser` |
| C# | [protobuf-net](https://github.com/protobuf-net/protobuf-net) | 3.4 | ✓ | – | 274 M downloads; no canonical ProtoJSON |
| JavaScript | [protobuf.js](https://github.com/protobufjs/protobuf.js) | 8.x | ✓ | ✓ | ~408 M npm downloads/month; static codegen (`pbjs`), ProtoJSON extension |
| JavaScript | [protobuf-es](https://github.com/bufbuild/protobuf-es) | 2.x | ✓ | ✓ | ~112 M downloads/month; `toJson`/`fromJson` |
| Go | [protobuf-go](https://github.com/protocolbuffers/protobuf-go) | 1.36 | ✓ | ✓ | official; `protojson` |
| Go | [vtprotobuf](https://github.com/planetscale/vtprotobuf) | 0.6 | ✓ | (✓) | 1.1 k stars; generated `MarshalVT`/`UnmarshalVT`; JSON reuses `protojson` |
| Swift | [swift-protobuf](https://github.com/apple/swift-protobuf) | 1.38 | ✓ | ✓ | the only mature Swift implementation |

## Considered and not included

| library | reason |
|---|---|
| quick-protobuf (Rust) | last release 2022, repository inactive since 2024 |
| google-protobuf (npm) | official but ~13× fewer downloads than protobuf.js, no JSON support |
| upb (C) | fastest C runtime, but no releases and an explicitly unstable C API/ABI; only consumable from the protobuf Bazel tree |
| QuickBuffers (Java) | ~140 stars |
| gogo/protobuf (Go) | deprecated since 2022 |
| ProtobufKit (Swift) | too small to count as a popular implementation |
| C++ arena allocation | same library as `cpp/protobuf`; left out to keep one entry per implementation |

vtprotobuf's `json_encode`/`json_decode` columns measure `protojson` from google.golang.org/protobuf
(vtprotobuf has no JSON code of its own); they are expected to equal protobuf-go's and are shown for
completeness.

Each implementation directory has a `meta.json` whose `notes` list every deviation and caveat; the
report shows them in the "Implementations and caveats" section.
