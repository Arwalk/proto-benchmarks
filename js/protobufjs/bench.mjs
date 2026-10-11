// proto-benchmarks harness: protobuf.js (static-module codegen for the wire format,
// the official ext/protojson extension for canonical ProtoJSON).
// See docs/HARNESS.md; the measurement loop mirrors tools/pyharness.py 1:1.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import protobuf from "protobufjs/light.js";
import protojson from "protobufjs/ext/protojson.js";
import { bench } from "./gen/bench.js";

const here = path.dirname(fileURLToPath(import.meta.url));

const LANGUAGE = "javascript";
const NAME = "protobufjs";
const DATASETS = ["small", "medium", "large"];
const OPS = ["wire_encode", "wire_decode", "json_encode", "json_decode"];

// Black hole: every iteration xors one Number into it; printed once at the end.
let sink = 0;

// Reflection root (JSON descriptor produced by `pbjs -t json` at build time) is
// needed only by the ProtoJSON extension, which has no static-module codegen.
const root = protobuf.Root.fromJSON(JSON.parse(fs.readFileSync(path.join(here, "gen", "bench.json"), "utf8")));

const STATIC = { small: bench.SmallMessage, medium: bench.MediumMessage, large: bench.LargeMessage };
const REFLECTED = {
  small: root.lookupType("bench.SmallMessage"),
  medium: root.lookupType("bench.MediumMessage"),
  large: root.lookupType("bench.LargeMessage"),
};
// 64-bit fields are Long objects; fold the low 32 bits.
const SCALAR = {
  small: (m) => m.id,
  medium: (m) => (typeof m.createdAt === "number" ? m.createdAt : m.createdAt.low),
  large: (m) => m.source.length,
};

function parseArgs(argv) {
  const args = {
    fixtures: null, out: null, warmupSeconds: 3, warmupMaxSeconds: 15, roundSeconds: 1, rounds: 10,
    datasets: DATASETS.join(","), ops: OPS.join(","), dump: null,
  };
  const spec = {
    "--fixtures": ["fixtures", String],
    "--out": ["out", String],
    "--warmup-seconds": ["warmupSeconds", Number],
    "--warmup-max-seconds": ["warmupMaxSeconds", Number],
    "--round-seconds": ["roundSeconds", Number],
    "--rounds": ["rounds", (v) => parseInt(v, 10)],
    "--datasets": ["datasets", String],
    "--ops": ["ops", String],
    "--dump": ["dump", String],
  };
  for (let i = 0; i < argv.length; i++) {
    let key = argv[i];
    let value;
    const eq = key.indexOf("=");
    if (key.startsWith("--") && eq !== -1) {
      value = key.slice(eq + 1);
      key = key.slice(0, eq);
    }
    const entry = spec[key];
    if (!entry) {
      console.error(`unknown argument ${key}`);
      process.exit(2);
    }
    if (value === undefined) {
      if (i + 1 >= argv.length) {
        console.error(`missing value for ${key}`);
        process.exit(2);
      }
      value = argv[++i];
    }
    args[entry[0]] = entry[1](value);
    if (typeof args[entry[0]] === "number" && !Number.isFinite(args[entry[0]])) {
      console.error(`invalid number for ${key}: ${value}`);
      process.exit(2);
    }
  }
  if (!args.fixtures || !args.out) {
    console.error("--fixtures and --out are required");
    process.exit(2);
  }
  for (const [flag, key] of [["--warmup-seconds", "warmupSeconds"], ["--warmup-max-seconds", "warmupMaxSeconds"], ["--round-seconds", "roundSeconds"]]) {
    if (args[key] < 0) {
      console.error(`${flag} must be >= 0 (got ${args[key]})`);
      process.exit(2);
    }
  }
  return args;
}

// Steady-state warm-up parameters (identical in every harness of the suite).
const WARMUP_PROBE_NS = 500_000_000n; // length of one warm-up probe
const STEADY_WINDOW = 3; // consecutive probes that must agree
const STEADY_TOL = 0.05; // max spread (hi <= lo * (1 + tol)) within the window

// Returns [batch, rounds, warmupNs, steady]: the actual warm-up duration in ns and
// whether the warm-up reached a steady state before hitting warmupMaxS.
function measure(fn, warmupS, warmupMaxS, roundS, rounds) {
  const now = process.hrtime.bigint;
  let batch = 1;
  for (;;) { // calibration
    const t0 = now();
    for (let i = 0; i < batch; i++) fn();
    if (now() - t0 >= 10_000_000n) break;
    batch *= 2;
  }
  const minNs = BigInt(Math.round(warmupS * 1e9)); // warm-up: probes until steady (after >= minNs) or capped at maxNs
  let maxNs = BigInt(Math.round(warmupMaxS * 1e9));
  if (maxNs < minNs) maxNs = minNs;
  const rates = new Array(STEADY_WINDOW).fill(0);
  let n = 0;
  let steady = false;
  const w0 = now();
  for (;;) {
    const elapsed = now() - w0;
    if (elapsed >= maxNs) break;
    let probeNs = maxNs - elapsed;
    if (probeNs > WARMUP_PROBE_NS) probeNs = WARMUP_PROBE_NS;
    const p0 = now();
    let iters = 0;
    while (now() - p0 < probeNs) {
      for (let i = 0; i < batch; i++) fn();
      iters += batch;
    }
    rates[n % STEADY_WINDOW] = (iters * 1e9) / Number(now() - p0);
    n++;
    if (now() - w0 >= minNs && n >= STEADY_WINDOW) {
      const lo = Math.min(...rates);
      const hi = Math.max(...rates);
      if (hi <= lo * (1.0 + STEADY_TOL)) { steady = true; break; }
    }
  }
  const warmupNs = Number(now() - w0);
  const out = [];
  const roundNs = BigInt(Math.round(roundS * 1e9));
  for (let r = 0; r < rounds; r++) { // timed rounds
    let iters = 0;
    const start = now();
    while (now() - start < roundNs) {
      for (let i = 0; i < batch; i++) fn();
      iters += batch;
    }
    out.push({ iterations: iters, elapsed_ns: Number(now() - start) });
  }
  return [batch, out, warmupNs, steady];
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const datasets = args.datasets.split(",").filter(Boolean);
  const ops = args.ops.split(",").filter(Boolean);
  for (const d of datasets) if (!DATASETS.includes(d)) { console.error(`unknown dataset ${d}`); process.exit(2); }
  for (const o of ops) if (!OPS.includes(o)) { console.error(`unknown op ${o}`); process.exit(2); }

  const results = [];
  for (const ds of datasets) {
    const wire = fs.readFileSync(path.join(args.fixtures, `${ds}.bin`)); // Buffer
    const text = fs.readFileSync(path.join(args.fixtures, `${ds}.json`), "utf8");
    const Static = STATIC[ds];
    const Type = REFLECTED[ds];
    const scalar = SCALAR[ds];
    const fixtureMsg = Static.decode(wire);

    // validation
    const reenc = Static.encode(fixtureMsg).finish();
    const validation = {
      wire_bytes_match: Buffer.compare(reenc, wire) === 0,
      wire_size_match: reenc.length === wire.length,
      json_roundtrip_ok: null,
      json_bytes: null,
    };
    const js = protojson.toJsonString(Type, fixtureMsg);
    validation.json_bytes = Buffer.byteLength(js, "utf8");
    const back = Static.encode(protojson.fromJsonString(Type, js)).finish();
    validation.json_roundtrip_ok = validation.wire_bytes_match
      ? Buffer.compare(back, wire) === 0
      : back.length === wire.length;
    if (args.dump) {
      fs.mkdirSync(args.dump, { recursive: true });
      fs.writeFileSync(path.join(args.dump, `${ds}.json`), js, "utf8");
      fs.writeFileSync(path.join(args.dump, `${ds}.wire.bin`), reenc);
    }

    for (const op of ops) {
      let fn;
      let payload;
      if (op === "wire_decode") {
        payload = wire.length;
        fn = () => { sink ^= scalar(Static.decode(wire)); };
      } else if (op === "wire_encode") {
        payload = wire.length;
        fn = () => { sink ^= Static.encode(fixtureMsg).finish().length; };
      } else if (op === "json_decode") {
        payload = Buffer.byteLength(text, "utf8");
        fn = () => { sink ^= scalar(protojson.fromJsonString(Type, text)); };
      } else {
        payload = Buffer.byteLength(text, "utf8");
        fn = () => { sink ^= protojson.toJsonString(Type, fixtureMsg).length; };
      }
      const [batch, rounds, warmupNs, steady] = measure(fn, args.warmupSeconds, args.warmupMaxSeconds, args.roundSeconds, args.rounds);
      results.push({
        dataset: ds, operation: op, supported: true, payload_bytes: payload,
        validation, warmup_ns: warmupNs, steady, batch, rounds,
      });
      const best = Math.max(...rounds.map((r) => (r.iterations / r.elapsed_ns) * 1e9));
      console.error(`${LANGUAGE}/${NAME} ${ds.padEnd(6)} ${op.padEnd(12)} ${best.toFixed(1).padStart(14)} ops/s warmup ${(warmupNs / 1e9).toFixed(1)}s ${steady ? "steady" : "NOT steady"}`);
    }
  }

  const doc = {
    schema_version: 1,
    harness: {
      language: LANGUAGE,
      name: NAME,
      runtime: `node ${process.version} (V8 ${process.versions.v8})`,
      library_version: JSON.parse(fs.readFileSync(path.join(here, "node_modules", "protobufjs", "package.json"), "utf8")).version,
    },
    results,
  };
  fs.writeFileSync(args.out, JSON.stringify(doc, null, 1) + "\n", "utf8");
  console.error(`sink=${sink}`);
}

main();
