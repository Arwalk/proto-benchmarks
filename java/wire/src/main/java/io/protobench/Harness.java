package io.protobench;

import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Shared measurement loop for the Java harnesses (see docs/HARNESS.md). This file is
 * byte-identical in java/protobuf-java and java/wire; only {@code Bench} differs.
 * It mirrors tools/pyharness.py 1:1.
 */
public abstract class Harness {
    /** Black hole: every timed iteration folds one scalar into it (xor). Printed once at the end. */
    public static volatile long sink;

    static final List<String> DATASETS = List.of("small", "medium", "large");
    static final List<String> OPS = List.of("wire_encode", "wire_decode", "json_encode", "json_decode");

    /** One fixture type. The *Loop methods are the timed inner loops (n iterations each). */
    public abstract static class Dataset<T> {
        public abstract T wireDecode(byte[] data) throws Exception;
        public abstract byte[] wireEncode(T msg) throws Exception;
        public abstract T jsonDecode(String text) throws Exception;
        public abstract String jsonEncode(T msg) throws Exception;
        public abstract long scalar(T msg);

        public abstract void wireDecodeLoop(byte[] data, int n) throws Exception;
        public abstract void wireEncodeLoop(T msg, int n) throws Exception;
        public abstract void jsonDecodeLoop(String text, int n) throws Exception;
        public abstract void jsonEncodeLoop(T msg, int n) throws Exception;
    }

    protected abstract String language();
    protected abstract String name();
    protected abstract String runtime();
    protected abstract String libraryVersion();
    protected abstract Dataset<?> dataset(String name);
    /** Reason string if {@code op} is not supported, else null. */
    protected String unsupported(String op) { return null; }

    @FunctionalInterface
    interface Loop { void run(int n) throws Exception; }

    static final class Args {
        String fixtures, out, dump;
        double warmupSeconds = 3.0, warmupMaxSeconds = 15.0, roundSeconds = 1.0;
        int rounds = 10;
        List<String> datasets = DATASETS, ops = OPS;
    }

    static Args parseArgs(String[] argv) {
        Args a = new Args();
        for (int i = 0; i < argv.length; i++) {
            String key = argv[i], value;
            int eq = key.indexOf('=');
            if (key.startsWith("--") && eq > 0) {
                value = key.substring(eq + 1);
                key = key.substring(0, eq);
            } else {
                if (i + 1 >= argv.length) usage("missing value for " + key);
                value = argv[++i];
            }
            try {
                switch (key) {
                    case "--fixtures" -> a.fixtures = value;
                    case "--out" -> a.out = value;
                    case "--warmup-seconds" -> a.warmupSeconds = parseDuration(key, value);
                    case "--warmup-max-seconds" -> a.warmupMaxSeconds = parseDuration(key, value);
                    case "--round-seconds" -> a.roundSeconds = parseDuration(key, value);
                    case "--rounds" -> a.rounds = Integer.parseInt(value);
                    case "--datasets" -> a.datasets = splitList(value);
                    case "--ops" -> a.ops = splitList(value);
                    case "--dump" -> a.dump = value;
                    default -> usage("unknown argument " + key);
                }
            } catch (NumberFormatException e) {
                usage("bad value for " + key + ": " + value);
            }
        }
        if (a.fixtures == null) usage("--fixtures is required");
        if (a.out == null) usage("--out is required");
        for (String d : a.datasets) if (!DATASETS.contains(d)) usage("unknown dataset " + d);
        for (String o : a.ops) if (!OPS.contains(o)) usage("unknown op " + o);
        return a;
    }

    private static double parseDuration(String key, String value) {
        double d = Double.parseDouble(value);
        if (!(d >= 0.0)) usage("bad value for " + key + ": " + value + " (duration must be >= 0 seconds)");
        return d;
    }

    private static List<String> splitList(String s) {
        List<String> out = new ArrayList<>();
        for (String p : s.split(",")) if (!p.isEmpty()) out.add(p);
        return out;
    }

    private static void usage(String msg) {
        System.err.println("error: " + msg);
        System.err.println("usage: --fixtures DIR --out FILE [--warmup-seconds F] [--warmup-max-seconds F]"
                + " [--round-seconds F] [--rounds N] [--datasets a,b] [--ops a,b] [--dump DIR]");
        System.exit(2);
    }

    /** Length of one warm-up probe (throughput sample). */
    static final long WARMUP_PROBE_NS = 500_000_000L;
    /** Number of consecutive probes that must agree for the warm-up to count as steady. */
    static final int STEADY_WINDOW = 3;
    /** Relative spread (max/min - 1) tolerated across the window. */
    static final double STEADY_TOL = 0.05;

    /**
     * Calibrate batch, warm up until steady state (or the cap), then run the timed rounds.
     * Returns [batch, rounds, warmup_ns (Long), steady (Boolean)].
     */
    static Object[] measure(Loop fn, double warmupS, double warmupMaxS, double roundS, int rounds) throws Exception {
        int batch = 1;
        while (true) { // calibration: smallest power of two taking >= 10 ms
            long t0 = System.nanoTime();
            fn.run(batch);
            if (System.nanoTime() - t0 >= 10_000_000L) break;
            batch *= 2;
        }
        // warm-up (JIT, caches, allocator): at least warmupS, at most warmupMaxS; stop early once
        // STEADY_WINDOW consecutive probe throughputs are within STEADY_TOL of each other.
        long minNs = (long) (warmupS * 1e9);
        long maxNs = (long) (warmupMaxS * 1e9);
        if (maxNs < minNs) maxNs = minNs;
        double[] rates = new double[STEADY_WINDOW];
        int n = 0;
        boolean steady = false;
        long w0 = System.nanoTime();
        while (true) {
            long elapsed = System.nanoTime() - w0;
            if (elapsed >= maxNs) break; // cap; also handles maxNs == 0
            long probeNs = Math.min(WARMUP_PROBE_NS, maxNs - elapsed);
            long p0 = System.nanoTime();
            long iters = 0;
            while (System.nanoTime() - p0 < probeNs) {
                fn.run(batch);
                iters += batch;
            }
            rates[n % STEADY_WINDOW] = iters * 1e9 / (System.nanoTime() - p0);
            n++;
            if (System.nanoTime() - w0 >= minNs && n >= STEADY_WINDOW) {
                double lo = rates[0], hi = rates[0];
                for (double r : rates) { lo = Math.min(lo, r); hi = Math.max(hi, r); }
                if (hi <= lo * (1.0 + STEADY_TOL)) { steady = true; break; }
            }
        }
        long warmupNs = System.nanoTime() - w0;
        List<Map<String, Object>> out = new ArrayList<>();
        long roundNs = (long) (roundS * 1e9);
        for (int r = 0; r < rounds; r++) {
            long iters = 0;
            long start = System.nanoTime(), now;
            while ((now = System.nanoTime()) - start < roundNs) {
                fn.run(batch);
                iters += batch;
            }
            Map<String, Object> round = new LinkedHashMap<>();
            round.put("iterations", iters);
            round.put("elapsed_ns", now - start); // measured after the last batch
            out.add(round);
        }
        return new Object[] {batch, out, warmupNs, steady};
    }

    public void run(String[] argv) throws Exception {
        Args args = parseArgs(argv);
        PrintStream err = System.err;
        List<Map<String, Object>> results = new ArrayList<>();
        for (String ds : args.datasets) {
            byte[] wire = Files.readAllBytes(Path.of(args.fixtures, ds + ".bin"));
            byte[] jsonBytes = Files.readAllBytes(Path.of(args.fixtures, ds + ".json"));
            String text = new String(jsonBytes, StandardCharsets.UTF_8);
            runDataset(ds, dataset(ds), wire, text, args, results, err);
        }

        Map<String, Object> harness = new LinkedHashMap<>();
        harness.put("language", language());
        harness.put("name", name());
        harness.put("runtime", runtime());
        harness.put("library_version", libraryVersion());
        Map<String, Object> doc = new LinkedHashMap<>();
        doc.put("schema_version", 1);
        doc.put("harness", harness);
        doc.put("results", results);
        StringBuilder sb = new StringBuilder(1 << 16);
        Json.write(sb, doc, 0);
        sb.append('\n');
        Path outPath = Path.of(args.out);
        if (outPath.getParent() != null) Files.createDirectories(outPath.getParent());
        Files.writeString(outPath, sb.toString(), StandardCharsets.UTF_8);
        err.println("sink=" + sink);
    }

    private <T> void runDataset(String ds, Dataset<T> impl, byte[] wire, String text, Args args,
                                List<Map<String, Object>> results, PrintStream err) throws Exception {
        T fixtureMsg = impl.wireDecode(wire);

        // validation
        byte[] reenc = impl.wireEncode(fixtureMsg);
        boolean wireBytesMatch = Arrays.equals(reenc, wire);
        Map<String, Object> validation = new LinkedHashMap<>();
        validation.put("wire_bytes_match", wireBytesMatch);
        validation.put("wire_size_match", reenc.length == wire.length);
        validation.put("json_roundtrip_ok", null);
        validation.put("json_bytes", null);
        boolean jsonOk = unsupported("json_encode") == null && unsupported("json_decode") == null;
        if (jsonOk) {
            String js = impl.jsonEncode(fixtureMsg);
            validation.put("json_bytes", js.getBytes(StandardCharsets.UTF_8).length);
            byte[] back = impl.wireEncode(impl.jsonDecode(js));
            validation.put("json_roundtrip_ok", wireBytesMatch ? Arrays.equals(back, wire) : back.length == wire.length);
            if (args.dump != null) {
                Files.createDirectories(Path.of(args.dump));
                Files.writeString(Path.of(args.dump, ds + ".json"), js, StandardCharsets.UTF_8);
            }
        }
        if (args.dump != null) {
            Files.createDirectories(Path.of(args.dump));
            Files.write(Path.of(args.dump, ds + ".wire.bin"), reenc);
        }

        for (String op : args.ops) {
            String reason = unsupported(op);
            Map<String, Object> entry = new LinkedHashMap<>();
            entry.put("dataset", ds);
            entry.put("operation", op);
            if (reason != null) {
                entry.put("supported", false);
                entry.put("reason", reason);
                results.add(entry);
                continue;
            }
            int payload;
            Loop fn;
            switch (op) {
                case "wire_decode" -> { payload = wire.length; fn = n -> impl.wireDecodeLoop(wire, n); }
                case "wire_encode" -> { payload = wire.length; fn = n -> impl.wireEncodeLoop(fixtureMsg, n); }
                case "json_decode" -> { payload = text.getBytes(StandardCharsets.UTF_8).length; fn = n -> impl.jsonDecodeLoop(text, n); }
                default -> { payload = text.getBytes(StandardCharsets.UTF_8).length; fn = n -> impl.jsonEncodeLoop(fixtureMsg, n); }
            }
            Object[] m = measure(fn, args.warmupSeconds, args.warmupMaxSeconds, args.roundSeconds, args.rounds);
            @SuppressWarnings("unchecked")
            List<Map<String, Object>> rounds = (List<Map<String, Object>>) m[1];
            long warmupNs = (Long) m[2];
            boolean steady = (Boolean) m[3];
            entry.put("supported", true);
            entry.put("payload_bytes", payload);
            entry.put("validation", validation);
            entry.put("warmup_ns", warmupNs);
            entry.put("steady", steady);
            entry.put("batch", m[0]);
            entry.put("rounds", rounds);
            results.add(entry);
            double best = 0;
            for (Map<String, Object> r : rounds) {
                double ops = (Long) r.get("iterations") / (double) (Long) r.get("elapsed_ns") * 1e9;
                if (ops > best) best = ops;
            }
            err.printf("%s/%s %-6s %-12s %14.1f ops/s warmup %.1fs %s%n", language(), name(), ds, op, best,
                    warmupNs / 1e9, steady ? "steady" : "NOT steady");
        }
    }

    /** Minimal JSON writer (Map / List / String / Number / Boolean / null), Python indent=1 style. */
    static final class Json {
        static void write(StringBuilder sb, Object v, int level) {
            if (v == null) {
                sb.append("null");
            } else if (v instanceof String s) {
                string(sb, s);
            } else if (v instanceof Boolean || v instanceof Integer || v instanceof Long) {
                sb.append(v);
            } else if (v instanceof Double d) {
                if (d.isNaN() || d.isInfinite()) throw new IllegalArgumentException("non-finite double");
                sb.append(d.doubleValue());
            } else if (v instanceof Map<?, ?> m) {
                if (m.isEmpty()) { sb.append("{}"); return; }
                sb.append('{');
                boolean first = true;
                for (Map.Entry<?, ?> e : m.entrySet()) {
                    sb.append(first ? "\n" : ",\n");
                    first = false;
                    indent(sb, level + 1);
                    string(sb, (String) e.getKey());
                    sb.append(": ");
                    write(sb, e.getValue(), level + 1);
                }
                sb.append('\n');
                indent(sb, level);
                sb.append('}');
            } else if (v instanceof List<?> l) {
                if (l.isEmpty()) { sb.append("[]"); return; }
                sb.append('[');
                boolean first = true;
                for (Object e : l) {
                    sb.append(first ? "\n" : ",\n");
                    first = false;
                    indent(sb, level + 1);
                    write(sb, e, level + 1);
                }
                sb.append('\n');
                indent(sb, level);
                sb.append(']');
            } else {
                throw new IllegalArgumentException("unsupported JSON value: " + v.getClass());
            }
        }

        private static void indent(StringBuilder sb, int level) {
            for (int i = 0; i < level; i++) sb.append(' ');
        }

        private static void string(StringBuilder sb, String s) {
            sb.append('"');
            for (int i = 0; i < s.length(); i++) {
                char c = s.charAt(i);
                switch (c) {
                    case '"' -> sb.append("\\\"");
                    case '\\' -> sb.append("\\\\");
                    case '\n' -> sb.append("\\n");
                    case '\r' -> sb.append("\\r");
                    case '\t' -> sb.append("\\t");
                    default -> {
                        if (c < 0x20) sb.append(String.format("\\u%04x", (int) c));
                        else sb.append(c);
                    }
                }
            }
            sb.append('"');
        }
    }
}
