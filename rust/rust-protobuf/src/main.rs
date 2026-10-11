//! proto-benchmarks harness: rust-protobuf (wire) + protobuf-json-mapping (ProtoJSON).
//!
//! Implements the CLI, measurement loop, validation and output format of
//! docs/HARNESS.md; the logic mirrors tools/pyharness.py one to one.
use std::fs;
use std::path::PathBuf;
use std::process;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use protobuf::Message;
use serde_json::{json, Value};

// protobuf-codegen writes OUT_DIR/protos/mod.rs (`pub mod bench;`) and bench.rs.
include!(concat!(env!("OUT_DIR"), "/protos/mod.rs"));

const LANGUAGE: &str = "rust";
const NAME: &str = "rust-protobuf";
const DATASETS: [&str; 3] = ["small", "medium", "large"];
const OPS: [&str; 4] = ["wire_encode", "wire_decode", "json_encode", "json_decode"];

/// Black hole: every iteration folds its result into this global so the
/// optimiser cannot remove the work. Printed once at the end.
static SINK: AtomicU64 = AtomicU64::new(0);

#[inline(always)]
fn consume(v: u64) {
    SINK.store(SINK.load(Ordering::Relaxed) ^ v, Ordering::Relaxed);
}

// ---------------------------------------------------------------------------
// The four operations, per dataset type
// ---------------------------------------------------------------------------

trait Dataset {
    type Msg;
    fn wire_decode(bytes: &[u8]) -> Self::Msg;
    fn wire_encode(msg: &Self::Msg) -> Vec<u8>;
    fn json_encode(msg: &Self::Msg) -> String;
    fn json_decode(text: &str) -> Self::Msg;
    fn scalar(msg: &Self::Msg) -> u64;
}

macro_rules! dataset {
    ($name:ident, $msg:ty, |$m:ident| $scalar:expr) => {
        struct $name;
        impl Dataset for $name {
            type Msg = $msg;
            #[inline]
            fn wire_decode(bytes: &[u8]) -> $msg {
                <$msg>::parse_from_bytes(bytes).expect("wire decode failed")
            }
            #[inline]
            fn wire_encode(msg: &$msg) -> Vec<u8> {
                msg.write_to_bytes().expect("wire encode failed")
            }
            #[inline]
            fn json_encode(msg: &$msg) -> String {
                protobuf_json_mapping::print_to_string(msg).expect("json encode failed")
            }
            #[inline]
            fn json_decode(text: &str) -> $msg {
                protobuf_json_mapping::parse_from_str::<$msg>(text).expect("json decode failed")
            }
            #[inline]
            fn scalar($m: &$msg) -> u64 {
                $scalar
            }
        }
    };
}

dataset!(Small, bench::SmallMessage, |m| m.id as u64);
dataset!(Medium, bench::MediumMessage, |m| m.created_at as u64);
dataset!(Large, bench::LargeMessage, |m| m.source.len() as u64);

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

struct Args {
    fixtures: PathBuf,
    out: PathBuf,
    warmup: Duration,
    warmup_max: Duration,
    round: Duration,
    rounds: usize,
    datasets: Vec<String>,
    ops: Vec<String>,
    dump: Option<PathBuf>,
}

fn usage_error(msg: &str) -> ! {
    eprintln!("error: {msg}");
    eprintln!(
        "usage: bench-rust-protobuf --fixtures DIR --out FILE [--warmup-seconds F] [--warmup-max-seconds F] \
         [--round-seconds F] [--rounds N] [--datasets a,b] [--ops a,b] [--dump DIR]"
    );
    process::exit(2);
}

/// Parses a `--xxx-seconds` value. Rejects negative/NaN/infinite values:
/// `Duration::from_secs_f64` panics on those.
fn parse_seconds(flag: &str, value: &str) -> Duration {
    let v: f64 = value
        .parse()
        .unwrap_or_else(|_| usage_error(&format!("{flag} expects a decimal number")));
    if !v.is_finite() || v < 0.0 {
        usage_error(&format!("{flag} must be a finite number of seconds >= 0, got {value}"));
    }
    Duration::from_secs_f64(v)
}

fn parse_args() -> Args {
    let mut fixtures = None;
    let mut out = None;
    let mut warmup = Duration::from_secs_f64(3.0);
    let mut warmup_max = Duration::from_secs_f64(15.0);
    let mut round = Duration::from_secs_f64(1.0);
    let mut rounds = 10usize;
    let mut datasets = DATASETS.join(",");
    let mut ops = OPS.join(",");
    let mut dump = None;

    let argv: Vec<String> = std::env::args().skip(1).collect();
    let mut i = 0;
    while i < argv.len() {
        let arg = &argv[i];
        let (key, inline_val) = match arg.split_once('=') {
            Some((k, v)) if k.starts_with("--") => (k.to_string(), Some(v.to_string())),
            _ => (arg.clone(), None),
        };
        let mut value = || -> String {
            if let Some(v) = &inline_val {
                return v.clone();
            }
            i += 1;
            argv.get(i)
                .cloned()
                .unwrap_or_else(|| usage_error(&format!("{key} requires a value")))
        };
        match key.as_str() {
            "--fixtures" => fixtures = Some(PathBuf::from(value())),
            "--out" => out = Some(PathBuf::from(value())),
            "--warmup-seconds" => warmup = parse_seconds(&key, &value()),
            "--warmup-max-seconds" => warmup_max = parse_seconds(&key, &value()),
            "--round-seconds" => round = parse_seconds(&key, &value()),
            "--rounds" => {
                rounds = value()
                    .parse()
                    .unwrap_or_else(|_| usage_error("--rounds expects an integer"));
                if rounds < 1 {
                    usage_error("--rounds must be >= 1");
                }
            }
            "--datasets" => datasets = value(),
            "--ops" => ops = value(),
            "--dump" => dump = Some(PathBuf::from(value())),
            other => usage_error(&format!("unknown argument {other}")),
        }
        i += 1;
    }

    let datasets: Vec<String> = datasets.split(',').filter(|s| !s.is_empty()).map(String::from).collect();
    let ops: Vec<String> = ops.split(',').filter(|s| !s.is_empty()).map(String::from).collect();
    for d in &datasets {
        if !DATASETS.contains(&d.as_str()) {
            usage_error(&format!("unknown dataset {d}"));
        }
    }
    for o in &ops {
        if !OPS.contains(&o.as_str()) {
            usage_error(&format!("unknown op {o}"));
        }
    }
    Args {
        fixtures: fixtures.unwrap_or_else(|| usage_error("--fixtures is required")),
        out: out.unwrap_or_else(|| usage_error("--out is required")),
        warmup,
        warmup_max,
        round,
        rounds,
        datasets,
        ops,
        dump,
    }
}

// ---------------------------------------------------------------------------
// Measurement loop (docs/HARNESS.md)
// ---------------------------------------------------------------------------

/// Steady-state warm-up (docs/HARNESS.md): the warm-up is cut into probes of
/// WARMUP_PROBE_NS; it ends once the last STEADY_WINDOW probe rates agree within
/// STEADY_TOL (never before `--warmup-seconds`, never after `--warmup-max-seconds`).
const WARMUP_PROBE_NS: u64 = 500_000_000;
const STEADY_WINDOW: usize = 3;
const STEADY_TOL: f64 = 0.05;

struct Round {
    iterations: u64,
    elapsed_ns: u64,
}

struct Measured {
    batch: u64,
    rounds: Vec<Round>,
    warmup_ns: u64,
    steady: bool,
}

fn measure<F: FnMut()>(mut op: F, warmup_min: Duration, warmup_max: Duration, round: Duration, rounds: usize) -> Measured {
    // calibration: find a batch size that takes >= 10 ms
    let mut batch: u64 = 1;
    loop {
        let t0 = Instant::now();
        for _ in 0..batch {
            op();
        }
        if t0.elapsed() >= Duration::from_millis(10) {
            break;
        }
        batch *= 2;
    }
    // warm-up: probes of WARMUP_PROBE_NS until the rate is steady (see the constants above)
    let min = warmup_min;
    let max = warmup_max.max(min);
    let mut rates = [0.0f64; STEADY_WINDOW];
    let mut n = 0usize;
    let mut steady = false;
    let w0 = Instant::now();
    loop {
        let elapsed = w0.elapsed();
        if elapsed >= max {
            break; // cap; also handles max == 0
        }
        let probe = Duration::from_nanos(WARMUP_PROBE_NS).min(max - elapsed);
        let p0 = Instant::now();
        let mut iters: u64 = 0;
        while p0.elapsed() < probe {
            for _ in 0..batch {
                op();
            }
            iters += batch;
        }
        rates[n % STEADY_WINDOW] = iters as f64 * 1e9 / p0.elapsed().as_nanos() as f64;
        n += 1;
        if w0.elapsed() >= min && n >= STEADY_WINDOW {
            let lo = rates.iter().copied().fold(f64::INFINITY, f64::min);
            let hi = rates.iter().copied().fold(f64::NEG_INFINITY, f64::max);
            if hi <= lo * (1.0 + STEADY_TOL) {
                steady = true;
                break;
            }
        }
    }
    let warmup_ns = w0.elapsed().as_nanos() as u64;
    // timed rounds
    let mut out = Vec::with_capacity(rounds);
    for _ in 0..rounds {
        let mut iters: u64 = 0;
        let start = Instant::now();
        while start.elapsed() < round {
            for _ in 0..batch {
                op();
            }
            iters += batch;
        }
        let elapsed_ns = start.elapsed().as_nanos() as u64;
        out.push(Round { iterations: iters, elapsed_ns });
    }
    Measured { batch, rounds: out, warmup_ns, steady }
}

fn run_dataset<D: Dataset>(ds: &str, args: &Args, results: &mut Vec<Value>) {
    let wire = fs::read(args.fixtures.join(format!("{ds}.bin")))
        .unwrap_or_else(|e| fatal(&format!("cannot read {ds}.bin: {e}")));
    let text = fs::read_to_string(args.fixtures.join(format!("{ds}.json")))
        .unwrap_or_else(|e| fatal(&format!("cannot read {ds}.json: {e}")));
    let fixture_msg = D::wire_decode(&wire);

    // validation
    let reenc = D::wire_encode(&fixture_msg);
    let wire_bytes_match = reenc == wire;
    let wire_size_match = reenc.len() == wire.len();
    let js = D::json_encode(&fixture_msg);
    let json_bytes = js.len();
    let back = D::wire_encode(&D::json_decode(&js));
    let json_roundtrip_ok = if wire_bytes_match { back == wire } else { back.len() == wire.len() };
    if let Some(dir) = &args.dump {
        fs::create_dir_all(dir).unwrap_or_else(|e| fatal(&format!("cannot create dump dir: {e}")));
        fs::write(dir.join(format!("{ds}.json")), js.as_bytes())
            .unwrap_or_else(|e| fatal(&format!("cannot write dump: {e}")));
        fs::write(dir.join(format!("{ds}.wire.bin")), &reenc)
            .unwrap_or_else(|e| fatal(&format!("cannot write dump: {e}")));
    }
    let validation = json!({
        "wire_bytes_match": wire_bytes_match,
        "wire_size_match": wire_size_match,
        "json_roundtrip_ok": json_roundtrip_ok,
        "json_bytes": json_bytes,
    });

    for op in &args.ops {
        let (payload, m) = match op.as_str() {
            "wire_decode" => (
                wire.len(),
                measure(|| consume(D::scalar(&D::wire_decode(&wire))), args.warmup, args.warmup_max, args.round, args.rounds),
            ),
            "wire_encode" => (
                wire.len(),
                measure(|| consume(D::wire_encode(&fixture_msg).len() as u64), args.warmup, args.warmup_max, args.round, args.rounds),
            ),
            "json_decode" => (
                text.len(),
                measure(|| consume(D::scalar(&D::json_decode(&text))), args.warmup, args.warmup_max, args.round, args.rounds),
            ),
            "json_encode" => (
                text.len(),
                measure(|| consume(D::json_encode(&fixture_msg).len() as u64), args.warmup, args.warmup_max, args.round, args.rounds),
            ),
            _ => unreachable!(),
        };
        let rounds_json: Vec<Value> = m
            .rounds
            .iter()
            .map(|r| json!({ "iterations": r.iterations, "elapsed_ns": r.elapsed_ns }))
            .collect();
        results.push(json!({
            "dataset": ds,
            "operation": op,
            "supported": true,
            "payload_bytes": payload,
            "validation": validation,
            "warmup_ns": m.warmup_ns,
            "steady": m.steady,
            "batch": m.batch,
            "rounds": rounds_json,
        }));
        let best = m
            .rounds
            .iter()
            .map(|r| r.iterations as f64 / r.elapsed_ns as f64 * 1e9)
            .fold(0.0f64, f64::max);
        eprintln!(
            "{LANGUAGE}/{NAME} {ds:<6} {op:<12} {best:>14.1} ops/s warmup {:.1}s {}",
            m.warmup_ns as f64 / 1e9,
            if m.steady { "steady" } else { "NOT steady" }
        );
    }
}

fn fatal(msg: &str) -> ! {
    eprintln!("error: {msg}");
    process::exit(1);
}

fn main() {
    let args = parse_args();
    let mut results: Vec<Value> = Vec::new();
    for ds in &args.datasets {
        match ds.as_str() {
            "small" => run_dataset::<Small>(ds, &args, &mut results),
            "medium" => run_dataset::<Medium>(ds, &args, &mut results),
            "large" => run_dataset::<Large>(ds, &args, &mut results),
            _ => unreachable!(),
        }
    }
    let doc = json!({
        "schema_version": 1,
        "harness": {
            "language": LANGUAGE,
            "name": NAME,
            "runtime": env!("RUSTC_VERSION"),
            "library_version": env!("PROTOBUF_VERSION"),
        },
        "results": results,
    });
    let mut text = serde_json::to_string_pretty(&doc).expect("serialise result");
    text.push('\n');
    fs::write(&args.out, text).unwrap_or_else(|e| fatal(&format!("cannot write {}: {e}", args.out.display())));
    eprintln!("sink={}", SINK.load(Ordering::Relaxed));
}
