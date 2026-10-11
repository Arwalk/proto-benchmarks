// proto-benchmarks harness: apple/swift-protobuf.
// Measurement loop mirrors tools/pyharness.py 1:1 (see docs/HARNESS.md).
import Foundation
#if canImport(Glibc)
import Glibc
#endif
import SwiftProtobuf

/// Black hole: every iteration folds one scalar of its result into it.
var sink: UInt64 = 0

let datasetsAll = ["small", "medium", "large"]
let opsAll = ["wire_encode", "wire_decode", "json_encode", "json_decode"]

@inline(__always) func nowNs() -> UInt64 {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
}

func stderr(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

func fail(_ msg: String) -> Never {
    stderr("error: " + msg)
    exit(2)
}

struct Args {
    var fixtures = ""
    var out = ""
    var warmupSeconds = 3.0
    var warmupMaxSeconds = 15.0
    var roundSeconds = 1.0
    var rounds = 10
    var datasets = datasetsAll
    var ops = opsAll
    var dump: String? = nil
}

func parseList(_ s: String, allowed: [String], what: String) -> [String] {
    let items = s.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    for it in items where !allowed.contains(it) { fail("unknown \(what) \(it)") }
    return items
}

/// UInt64(Double) traps on negative / non-finite values, so every duration flag is validated.
func checkDuration(_ s: Double, _ flag: String) {
    if !s.isFinite || s < 0 { fail("\(flag) must be a finite number >= 0 (got \(s))") }
}

func parseArgs() -> Args {
    var a = Args()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        guard let value = it.next() else { fail("missing value for \(arg)") }
        switch arg {
        case "--fixtures": a.fixtures = value
        case "--out": a.out = value
        case "--warmup-seconds": a.warmupSeconds = Double(value) ?? { fail("bad --warmup-seconds \(value)") }()
        case "--warmup-max-seconds": a.warmupMaxSeconds = Double(value) ?? { fail("bad --warmup-max-seconds \(value)") }()
        case "--round-seconds": a.roundSeconds = Double(value) ?? { fail("bad --round-seconds \(value)") }()
        case "--rounds": a.rounds = Int(value) ?? { fail("bad --rounds \(value)") }()
        case "--datasets": a.datasets = parseList(value, allowed: datasetsAll, what: "dataset")
        case "--ops": a.ops = parseList(value, allowed: opsAll, what: "op")
        case "--dump": a.dump = value
        default: fail("unknown argument \(arg)")
        }
    }
    if a.fixtures.isEmpty { fail("--fixtures is required") }
    if a.out.isEmpty { fail("--out is required") }
    checkDuration(a.warmupSeconds, "--warmup-seconds")
    checkDuration(a.warmupMaxSeconds, "--warmup-max-seconds")
    checkDuration(a.roundSeconds, "--round-seconds")
    return a
}

struct Round { let iterations: UInt64; let elapsedNs: UInt64 }

/// Steady-state warm-up parameters (identical in every harness of the suite).
let WARMUP_PROBE_NS: UInt64 = 500_000_000 // length of one warm-up probe
let STEADY_WINDOW = 3 // consecutive probes that must agree
let STEADY_TOL = 0.05 // max spread (hi <= lo * (1 + tol)) within the window

/// Calibration / warm-up / timed rounds exactly as in docs/HARNESS.md.
/// Also returns the actual warm-up duration in ns and whether the warm-up reached a
/// steady state before hitting warmupMaxNs.
func measure(warmupMinNs: UInt64, warmupMaxNs: UInt64, roundNs: UInt64, rounds: Int, _ op: () throws -> Void) throws -> (batch: UInt64, rounds: [Round], warmupNs: UInt64, steady: Bool) {
    var batch: UInt64 = 1
    while true {
        let t0 = nowNs()
        for _ in 0..<batch { try op() }
        if nowNs() &- t0 >= 10_000_000 { break }
        batch *= 2
    }
    let minNs = warmupMinNs // warm-up: probes until steady (after >= minNs) or capped at maxNs
    let maxNs = warmupMaxNs < minNs ? minNs : warmupMaxNs
    var rates = [Double](repeating: 0, count: STEADY_WINDOW)
    var n = 0
    var steady = false
    let w0 = nowNs()
    while true {
        let elapsed = nowNs() &- w0
        if elapsed >= maxNs { break }
        let probeNs = min(WARMUP_PROBE_NS, maxNs - elapsed) // elapsed < maxNs here, no underflow
        let p0 = nowNs()
        var iters: UInt64 = 0
        while nowNs() &- p0 < probeNs {
            for _ in 0..<batch { try op() }
            iters += batch
        }
        rates[n % STEADY_WINDOW] = Double(iters) * 1e9 / Double(nowNs() &- p0)
        n += 1
        if nowNs() &- w0 >= minNs && n >= STEADY_WINDOW {
            let lo = rates.min()!
            let hi = rates.max()!
            if hi <= lo * (1.0 + STEADY_TOL) { steady = true; break }
        }
    }
    let warmupNs = nowNs() &- w0
    var out: [Round] = []
    out.reserveCapacity(rounds)
    for _ in 0..<rounds {
        var iters: UInt64 = 0
        let start = nowNs()
        while nowNs() &- start < roundNs {
            for _ in 0..<batch { try op() }
            iters += batch
        }
        out.append(Round(iterations: iters, elapsedNs: nowNs() &- start))
    }
    return (batch, out, warmupNs, steady)
}

struct Validation {
    let wireBytesMatch: Bool
    let wireSizeMatch: Bool
    let jsonRoundtripOk: Bool
    let jsonBytes: Int
}

func jsonString(_ s: String) -> String {
    var r = "\""
    for u in s.unicodeScalars {
        switch u {
        case "\"": r += "\\\""
        case "\\": r += "\\\\"
        case "\n": r += "\\n"
        case "\r": r += "\\r"
        case "\t": r += "\\t"
        default:
            if u.value < 0x20 { r += String(format: "\\u%04x", u.value) } else { r.unicodeScalars.append(u) }
        }
    }
    return r + "\""
}

func resultEntry(dataset: String, op: String, payload: Int, v: Validation, warmupNs: UInt64, steady: Bool, batch: UInt64, rounds: [Round]) -> String {
    var s = "  {\"dataset\": \(jsonString(dataset)), \"operation\": \(jsonString(op)), \"supported\": true, \"payload_bytes\": \(payload),\n"
    s += "   \"validation\": {\"wire_bytes_match\": \(v.wireBytesMatch), \"wire_size_match\": \(v.wireSizeMatch), \"json_roundtrip_ok\": \(v.jsonRoundtripOk), \"json_bytes\": \(v.jsonBytes)},\n"
    s += "   \"warmup_ns\": \(warmupNs), \"steady\": \(steady), \"batch\": \(batch), \"rounds\": ["
    s += rounds.map { "{\"iterations\": \($0.iterations), \"elapsed_ns\": \($0.elapsedNs)}" }.joined(separator: ", ")
    s += "]}"
    return s
}

/// Runs validation and the requested operations for one message type.
/// Each iteration creates a new message / byte array / String and drops it.
func runDataset<M: SwiftProtobuf.Message>(_: M.Type, name: String, args: Args, scalar: (M) -> UInt64, results: inout [String]) throws {
    let wire = [UInt8](try Data(contentsOf: URL(fileURLWithPath: "\(args.fixtures)/\(name).bin")))
    let text = try String(contentsOf: URL(fileURLWithPath: "\(args.fixtures)/\(name).json"), encoding: .utf8)
    let msg = try M(serializedBytes: wire)

    // ---- validation (once per dataset, before timing) ----
    let reenc: [UInt8] = try msg.serializedBytes()
    let js = try msg.jsonString()
    let back: [UInt8] = try M(jsonString: js).serializedBytes()
    let bytesMatch = reenc == wire
    let v = Validation(
        wireBytesMatch: bytesMatch,
        wireSizeMatch: reenc.count == wire.count,
        jsonRoundtripOk: bytesMatch ? back == wire : back.count == wire.count,
        jsonBytes: js.utf8.count)
    if let dump = args.dump {
        try FileManager.default.createDirectory(atPath: dump, withIntermediateDirectories: true)
        try Data(reenc).write(to: URL(fileURLWithPath: "\(dump)/\(name).wire.bin"))
        try js.write(toFile: "\(dump)/\(name).json", atomically: false, encoding: .utf8)
    }

    // ---- timing ----
    let warmupMinNs = UInt64(args.warmupSeconds * 1e9)
    let warmupMaxNs = UInt64(args.warmupMaxSeconds * 1e9)
    let roundNs = UInt64(args.roundSeconds * 1e9)
    for op in args.ops {
        let payload: Int
        let m: (batch: UInt64, rounds: [Round], warmupNs: UInt64, steady: Bool)
        switch op {
        case "wire_decode":
            payload = wire.count
            m = try measure(warmupMinNs: warmupMinNs, warmupMaxNs: warmupMaxNs, roundNs: roundNs, rounds: args.rounds) {
                let d = try M(serializedBytes: wire)
                sink ^= scalar(d)
            }
        case "wire_encode":
            payload = wire.count
            m = try measure(warmupMinNs: warmupMinNs, warmupMaxNs: warmupMaxNs, roundNs: roundNs, rounds: args.rounds) {
                let b: [UInt8] = try msg.serializedBytes()
                sink ^= UInt64(b.count)
            }
        case "json_decode":
            payload = text.utf8.count
            m = try measure(warmupMinNs: warmupMinNs, warmupMaxNs: warmupMaxNs, roundNs: roundNs, rounds: args.rounds) {
                let d = try M(jsonString: text)
                sink ^= scalar(d)
            }
        default: // json_encode
            payload = text.utf8.count
            m = try measure(warmupMinNs: warmupMinNs, warmupMaxNs: warmupMaxNs, roundNs: roundNs, rounds: args.rounds) {
                let s = try msg.jsonString()
                sink ^= UInt64(s.utf8.count)
            }
        }
        results.append(resultEntry(dataset: name, op: op, payload: payload, v: v, warmupNs: m.warmupNs, steady: m.steady, batch: m.batch, rounds: m.rounds))
        let best = m.rounds.map { Double($0.iterations) / Double($0.elapsedNs) * 1e9 }.max() ?? 0
        let steadyStr = m.steady ? "steady" : "NOT steady"
        stderr(String(format: "swift/swift-protobuf %-6@ %-12@ %14.1f ops/s warmup %.1fs %@", name as NSString, op as NSString, best, Double(m.warmupNs) / 1e9, steadyStr as NSString))
    }
}

let args = parseArgs()
var results: [String] = []
for ds in args.datasets {
    switch ds {
    case "small":
        try runDataset(Bench_SmallMessage.self, name: ds, args: args, scalar: { UInt64(bitPattern: Int64($0.id)) }, results: &results)
    case "medium":
        try runDataset(Bench_MediumMessage.self, name: ds, args: args, scalar: { UInt64(bitPattern: $0.createdAt) }, results: &results)
    default:
        try runDataset(Bench_LargeMessage.self, name: ds, args: args, scalar: { UInt64($0.source.utf8.count) }, results: &results)
    }
}
let runtime = ProcessInfo.processInfo.environment["BENCH_RUNTIME"] ?? "Swift"
let libraryVersion = ProcessInfo.processInfo.environment["BENCH_LIBRARY_VERSION"] ?? "unknown"
var doc = "{\n \"schema_version\": 1,\n \"harness\": {\"language\": \"swift\", \"name\": \"swift-protobuf\", \"runtime\": \(jsonString(runtime)), \"library_version\": \(jsonString(libraryVersion))},\n \"results\": [\n"
doc += results.joined(separator: ",\n")
doc += "\n ]\n}\n"
try doc.write(toFile: args.out, atomically: false, encoding: .utf8)
stderr("sink=\(sink)")
