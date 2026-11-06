// proto-benchmarks harness: goose-protobuf (https://github.com/Arwalk/goose-protobuf).
// Measurement loop mirrors tools/pyharness.py 1:1 (see docs/HARNESS.md).
import os;
import pb_wire;
import bench;
import buildinfo;

let IMPL_ID = "goose/goose-protobuf";
let NO_JSON = "goose-protobuf has no JSON (ProtoJSON) support";

// Steady-state warm-up constants (docs/HARNESS.md).
let PROBE_NS: i64 = 500000000;
let STEADY_WINDOW: i64 = 3;
let STEADY_TOL: f64 = 0.05;

// Black hole: every iteration folds one scalar of its result into it.
var sink: u64 = 0;

var warmup_min_ns: i64 = 3000000000;
var warmup_max_ns: i64 = 15000000000;
var round_ns: i64 = 1000000000;
var rounds: i64 = 10;
var fixtures: const u8[:] = "";
var dump: const u8[:] = "";
var ops: const u8[:][>..] = [];

// The result document under construction, and the validation of the current dataset.
var doc: u8[>..] = [];
var first_cell = true;
var wire_bytes_match = false;
var wire_size_match = false;

fn die(msg: const u8[:]) {
    write_stderr(str("error: ", msg, "\n"));
    exit(2);
}

fn check(err: i32) {
    if err != PB_OK { die(str("decode failed: ", pb_error_text(err))); }
}

// Parses a --xxx-seconds value into nanoseconds; rejects negative, NaN and absurdly large values.
fn parse_seconds(flag: const u8[:], value: const u8[:]) -> i64 {
    let v, ok = parse_flt(value);
    if !ok || !(v >= 0.0) || v > 1e9 { die(str(flag, " must be a number of seconds >= 0, got ", value)); }
    return (v * 1e9) as! i64;
}

fn parse_list(list: const u8[:], allowed: const u8[:][:], what: const u8[:]) -> const u8[:][>..] {
    var out: const u8[:][>..] = [];
    for item in split(list, ',') {
        if item.len == 0 { continue; }
        var known = false;
        for a in allowed { if a == item { known = true; } }
        if !known { die(str("unknown ", what, " ", item)); }
        out.push(item);
    }
    return out;
}

fn make_dirs(path: const u8[:]) {
    for i in 1..path.len {
        if path[i] == '/' { make_dir(path[..i]); }
    }
    if !make_dir(path) { die(str("cannot create ", path)); }
}

fn read_or_die(path: const u8[:], out: u8[>..]&) {
    if !read_file(path, out) { die(str("cannot read ", path)); }
}

fn write_or_die(path: const u8[:], data: const u8[:]) {
    if !write_file(path, data) { die(str("cannot write ", path)); }
}

fn begin_cell() {
    if !first_cell { doc.append(",\n"); }
    first_cell = false;
}

fn unsupported(ds: const u8[:], op: const u8[:], reason: const u8[:]) {
    begin_cell();
    doc.append(str("  {\"dataset\": \"", ds, "\", \"operation\": \"", op,
                   "\", \"supported\": false, \"reason\": \"", reason, "\"}"));
}

// Calibration / warm-up / timed rounds exactly as in docs/HARNESS.md. F is one iteration.
fn measure<F>(ds: const u8[:], op: const u8[:], payload: i64) {
    var batch: i64 = 1;
    while true {
        let t0 = clock_ns();
        for _ in batch { F(); }
        if clock_ns() - t0 >= 10000000 { break; }
        batch *= 2;
    }

    // warm-up: probes of PROBE_NS until the rate is steady
    let min_ns = warmup_min_ns;
    let max_ns = if warmup_max_ns > min_ns { warmup_max_ns } else { min_ns };
    var rates: f64[>..] = [0.0, 0.0, 0.0];
    var n: i64 = 0;
    var steady = false;
    let w0 = clock_ns();
    while true {
        let elapsed = clock_ns() - w0;
        if elapsed >= max_ns { break; } // cap; also handles max_ns == 0
        let probe_ns = if max_ns - elapsed < PROBE_NS { max_ns - elapsed } else { PROBE_NS };
        let p0 = clock_ns();
        var iters: i64 = 0;
        while clock_ns() - p0 < probe_ns {
            for _ in batch { F(); }
            iters += batch;
        }
        rates[n % STEADY_WINDOW] = (iters as f64) * 1e9 / ((clock_ns() - p0) as f64);
        n++;
        if clock_ns() - w0 >= min_ns && n >= STEADY_WINDOW {
            var lo = rates[0];
            var hi = rates[0];
            for r in rates {
                if r < lo { lo = r; }
                if r > hi { hi = r; }
            }
            if hi <= lo * (1.0 + STEADY_TOL) {
                steady = true;
                break;
            }
        }
    }
    let warmup_ns = clock_ns() - w0;

    var cells: u8[>..] = [];
    var best: f64 = 0.0;
    for r in rounds {
        var iters: i64 = 0;
        let start = clock_ns();
        while clock_ns() - start < round_ns {
            for _ in batch { F(); }
            iters += batch;
        }
        let elapsed_ns = clock_ns() - start;
        if r != 0 { cells.append(", "); }
        cells.append(str("{\"iterations\": ", iters, ", \"elapsed_ns\": ", elapsed_ns, "}"));
        let rate = (iters as f64) / (elapsed_ns as f64) * 1e9;
        if rate > best { best = rate; }
    }

    begin_cell();
    doc.append(str("  {\"dataset\": \"", ds, "\", \"operation\": \"", op,
                   "\", \"supported\": true, \"payload_bytes\": ", payload, ",\n"));
    doc.append(str("   \"validation\": {\"wire_bytes_match\": ", wire_bytes_match,
                   ", \"wire_size_match\": ", wire_size_match,
                   ", \"json_roundtrip_ok\": null, \"json_bytes\": null},\n"));
    doc.append(str("   \"warmup_ns\": ", warmup_ns, ", \"steady\": ", steady,
                   ", \"batch\": ", batch, ", \"rounds\": [", cells, "]}"));

    var line: u8[>..] = [];
    line.append(str(IMPL_ID, " ", ds, " ", op, " "));
    format_flt(line, best, 1);
    line.append(" ops/s warmup ");
    format_flt(line, (warmup_ns as f64) / 1e9, 1);
    line.append(if steady { "s steady\n" } else { "s NOT steady\n" });
    write_stderr(line);
}

// Validation (once per dataset, before timing) and --dump. The JSON keys stay null.
fn validate(ds: const u8[:], wire: const u8[:], reenc: const u8[:]) {
    wire_size_match = reenc.len == wire.len;
    wire_bytes_match = reenc == wire;
    if dump.len > 0 {
        make_dirs(dump);
        write_or_die(str(dump, "/", ds, ".wire.bin"), reenc);
    }
}

// The three functions below differ only in the message type: generated functions are named per
// message, not generic. Every wire_decode iteration decodes into a new message and M_clear frees
// what it owns; every wire_encode iteration appends to a new buffer, dropped at the closing brace.
fn run_small(ds: const u8[:], wire: const u8[:]) {
    var fixture = bench::SmallMessage { .. };
    check(bench::SmallMessage_decode(wire, fixture));
    var reenc: u8[>..] = [];
    bench::SmallMessage_encode(fixture, reenc);
    validate(ds, wire, reenc);
    for op in ops {
        if op == "wire_decode" {
            measure(ds, op, wire.len) {
                var m = bench::SmallMessage { .. };
                check(bench::SmallMessage_decode(wire, m));
                sink ^= m.id as! u64;
                bench::SmallMessage_clear(m);
            };
        } else if op == "wire_encode" {
            measure(ds, op, wire.len) {
                var out: u8[>..] = [];
                bench::SmallMessage_encode(fixture, out);
                sink ^= out.len as! u64;
            };
        } else {
            unsupported(ds, op, NO_JSON);
        }
    }
    bench::SmallMessage_clear(fixture);
}

fn run_medium(ds: const u8[:], wire: const u8[:]) {
    var fixture = bench::MediumMessage { .. };
    check(bench::MediumMessage_decode(wire, fixture));
    var reenc: u8[>..] = [];
    bench::MediumMessage_encode(fixture, reenc);
    validate(ds, wire, reenc);
    for op in ops {
        if op == "wire_decode" {
            measure(ds, op, wire.len) {
                var m = bench::MediumMessage { .. };
                check(bench::MediumMessage_decode(wire, m));
                sink ^= m.created_at as! u64;
                bench::MediumMessage_clear(m);
            };
        } else if op == "wire_encode" {
            measure(ds, op, wire.len) {
                var out: u8[>..] = [];
                bench::MediumMessage_encode(fixture, out);
                sink ^= out.len as! u64;
            };
        } else {
            unsupported(ds, op, NO_JSON);
        }
    }
    bench::MediumMessage_clear(fixture);
}

fn run_large(ds: const u8[:], wire: const u8[:]) {
    var fixture = bench::LargeMessage { .. };
    check(bench::LargeMessage_decode(wire, fixture));
    var reenc: u8[>..] = [];
    bench::LargeMessage_encode(fixture, reenc);
    validate(ds, wire, reenc);
    for op in ops {
        if op == "wire_decode" {
            measure(ds, op, wire.len) {
                var m = bench::LargeMessage { .. };
                check(bench::LargeMessage_decode(wire, m));
                sink ^= bench::LargeMessage_source(m).len as! u64;
                bench::LargeMessage_clear(m);
            };
        } else if op == "wire_encode" {
            measure(ds, op, wire.len) {
                var out: u8[>..] = [];
                bench::LargeMessage_encode(fixture, out);
                sink ^= out.len as! u64;
            };
        } else {
            unsupported(ds, op, NO_JSON);
        }
    }
    bench::LargeMessage_clear(fixture);
}

fn main() {
    let argv = args();
    var out_path: const u8[:] = "";
    var datasets_arg: const u8[:] = "small,medium,large";
    var ops_arg: const u8[:] = "wire_encode,wire_decode,json_encode,json_decode";
    var i: i64 = 1;
    while i < argv.len {
        let flag = argv[i];
        if i + 1 >= argv.len { die(str("missing value for ", flag)); }
        let value = argv[i + 1];
        i += 2;
        if flag == "--fixtures" { fixtures = value; }
        else if flag == "--out" { out_path = value; }
        else if flag == "--warmup-seconds" { warmup_min_ns = parse_seconds(flag, value); }
        else if flag == "--warmup-max-seconds" { warmup_max_ns = parse_seconds(flag, value); }
        else if flag == "--round-seconds" { round_ns = parse_seconds(flag, value); }
        else if flag == "--rounds" {
            let r, ok = parse_int(value);
            if !ok || r < 1 { die(str("bad --rounds ", value)); }
            rounds = r;
        }
        else if flag == "--datasets" { datasets_arg = value; }
        else if flag == "--ops" { ops_arg = value; }
        else if flag == "--dump" { dump = value; }
        else { die(str("unknown argument ", flag)); }
    }
    if fixtures.len == 0 { die("--fixtures is required"); }
    if out_path.len == 0 { die("--out is required"); }
    let datasets = parse_list(datasets_arg, ["small", "medium", "large"], "dataset");
    ops = parse_list(ops_arg, ["wire_encode", "wire_decode", "json_encode", "json_decode"], "op");

    doc.append(str("{\n \"schema_version\": 1,\n \"harness\": {\"language\": \"goose\", \"name\": \"goose-protobuf\", \"runtime\": \"",
                   RUNTIME_STRING, "\", \"library_version\": \"", LIBRARY_VERSION, "\"},\n \"results\": [\n"));
    for ds in datasets {
        var wire: u8[>..] = [];
        read_or_die(str(fixtures, "/", ds, ".bin"), wire);
        if ds == "small" { run_small(ds, wire); }
        else if ds == "medium" { run_medium(ds, wire); }
        else { run_large(ds, wire); }
    }
    doc.append("\n ]\n}\n");
    write_or_die(out_path, doc);
    write_stderr(str("sink=", sink, "\n"));
}
