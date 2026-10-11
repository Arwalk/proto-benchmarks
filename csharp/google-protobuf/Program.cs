// proto-benchmarks harness: official Google.Protobuf C# runtime.
// Measurement loop mirrors tools/pyharness.py exactly (see docs/HARNESS.md).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Google.Protobuf;
using ProtoBench.Bench;

namespace ProtoBench
{
    /// <summary>Per-dataset operations; each closure is the exact code timed per iteration.</summary>
    abstract class DatasetOps
    {
        public abstract object WireDecode(byte[] data);
        public abstract byte[] WireEncode(object msg);
        public abstract string JsonEncode(object msg);
        public abstract object JsonDecode(string text);
        public abstract long Scalar(object msg);
        public abstract Action WireDecodeLoop(byte[] data);
        public abstract Action WireEncodeLoop(object msg);
        public abstract Action JsonEncodeLoop(object msg);
        public abstract Action JsonDecodeLoop(string text);
    }

    sealed class Ops<T> : DatasetOps where T : class, IMessage<T>, new()
    {
        readonly MessageParser<T> parser;
        readonly Func<T, long> scalar;
        public Ops(MessageParser<T> parser, Func<T, long> scalar) { this.parser = parser; this.scalar = scalar; }

        public override object WireDecode(byte[] data) => parser.ParseFrom(data);
        public override byte[] WireEncode(object msg) => ((T)msg).ToByteArray();
        public override string JsonEncode(object msg) => JsonFormatter.Default.Format((T)msg);
        public override object JsonDecode(string text) => JsonParser.Default.Parse<T>(text);
        public override long Scalar(object msg) => scalar((T)msg);

        public override Action WireDecodeLoop(byte[] data)
        {
            var p = parser; var s = scalar;
            return () => Harness.Sink ^= s(p.ParseFrom(data));
        }
        public override Action WireEncodeLoop(object msg)
        {
            var m = (T)msg;
            return () => Harness.Sink ^= m.ToByteArray().Length;
        }
        public override Action JsonEncodeLoop(object msg)
        {
            var m = (T)msg; var f = JsonFormatter.Default;
            return () => Harness.Sink ^= f.Format(m).Length;
        }
        public override Action JsonDecodeLoop(string text)
        {
            var jp = JsonParser.Default; var s = scalar;
            return () => Harness.Sink ^= s(jp.Parse<T>(text));
        }
    }

    sealed class Args
    {
        public string Fixtures = "";
        public string Out = "";
        public double WarmupSeconds = 3.0;
        public double WarmupMaxSeconds = 15.0;
        public double RoundSeconds = 1.0;
        public int Rounds = 10;
        public string Datasets = string.Join(",", Harness.DATASETS);
        public string Ops = string.Join(",", Harness.OPS);
        public string? Dump = null;
    }

    static class Harness
    {
        public static readonly string[] DATASETS = { "small", "medium", "large" };
        public static readonly string[] OPS = { "wire_encode", "wire_decode", "json_encode", "json_decode" };

        public const string Language = "csharp";
        public const string Name = "google-protobuf";

        /// <summary>Black hole: every iteration folds its result in here; printed once at the end.</summary>
        public static long Sink;

        static readonly Dictionary<string, DatasetOps> Impl = new Dictionary<string, DatasetOps>
        {
            ["small"] = new Ops<SmallMessage>(SmallMessage.Parser, m => m.Id),
            ["medium"] = new Ops<MediumMessage>(MediumMessage.Parser, m => m.CreatedAt),
            ["large"] = new Ops<LargeMessage>(LargeMessage.Parser, m => m.Source.Length),
        };

        static string? Unsupported(string op) => null;

        static string Runtime() =>
            $"{RuntimeInformation.FrameworkDescription} ({RuntimeInformation.ProcessArchitecture}, {(System.Runtime.GCSettings.IsServerGC ? "server" : "workstation")} GC, {Environment.ProcessorCount} cpus)";

        static string LibraryVersion()
        {
            var asm = typeof(IMessage).Assembly;
            var info = (System.Reflection.AssemblyInformationalVersionAttribute?)Attribute.GetCustomAttribute(
                asm, typeof(System.Reflection.AssemblyInformationalVersionAttribute));
            var v = info?.InformationalVersion ?? asm.GetName().Version?.ToString() ?? "?";
            int plus = v.IndexOf('+');
            return plus >= 0 ? v.Substring(0, plus) : v;
        }

        // ---- clock -------------------------------------------------------------------------
        static readonly long Freq = Stopwatch.Frequency;
        static long NowNs()
        {
            long ts = Stopwatch.GetTimestamp();
            if (Freq == 1_000_000_000L) return ts;
            return (ts / Freq) * 1_000_000_000L + (ts % Freq) * 1_000_000_000L / Freq;
        }

        // ---- CLI ---------------------------------------------------------------------------
        static Args ParseArgs(string[] argv)
        {
            var a = new Args();
            bool haveFixtures = false, haveOut = false;
            for (int i = 0; i < argv.Length; i++)
            {
                string key = argv[i];
                string? val = null;
                int eq = key.IndexOf('=');
                if (key.StartsWith("--") && eq > 0) { val = key.Substring(eq + 1); key = key.Substring(0, eq); }
                string Need()
                {
                    if (val != null) return val;
                    if (i + 1 >= argv.Length) Die($"argument {key}: expected one argument");
                    return argv[++i];
                }
                switch (key)
                {
                    case "--fixtures": a.Fixtures = Need(); haveFixtures = true; break;
                    case "--out": a.Out = Need(); haveOut = true; break;
                    case "--warmup-seconds": a.WarmupSeconds = ParseDuration(key, Need()); break;
                    case "--warmup-max-seconds": a.WarmupMaxSeconds = ParseDuration(key, Need()); break;
                    case "--round-seconds": a.RoundSeconds = ParseDuration(key, Need()); break;
                    case "--rounds": a.Rounds = ParseInt(key, Need()); break;
                    case "--datasets": a.Datasets = Need(); break;
                    case "--ops": a.Ops = Need(); break;
                    case "--dump": a.Dump = Need(); break;
                    default: Die($"unrecognized argument: {argv[i]}"); break;
                }
            }
            if (!haveFixtures) Die("the following argument is required: --fixtures");
            if (!haveOut) Die("the following argument is required: --out");
            return a;
        }

        static double ParseDouble(string key, string s)
        {
            if (!double.TryParse(s, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var d))
                Die($"argument {key}: invalid float value: '{s}'");
            return d;
        }
        static double ParseDuration(string key, string s)
        {
            double d = ParseDouble(key, s);
            if (!(d >= 0.0)) Die($"argument {key}: invalid duration '{s}' (must be >= 0 seconds)");
            return d;
        }
        static int ParseInt(string key, string s)
        {
            if (!int.TryParse(s, System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out var n))
                Die($"argument {key}: invalid int value: '{s}'");
            return n;
        }
        static void Die(string msg)
        {
            Console.Error.WriteLine($"error: {msg}");
            Console.Error.WriteLine("usage: --fixtures DIR --out FILE [--warmup-seconds F] [--warmup-max-seconds F]"
                + " [--round-seconds F] [--rounds N] [--datasets a,b] [--ops a,b] [--dump DIR]");
            Environment.Exit(2);
        }

        // ---- measurement -------------------------------------------------------------------
        /// <summary>Length of one warm-up probe (throughput sample).</summary>
        const long WARMUP_PROBE_NS = 500_000_000L;
        /// <summary>Number of consecutive probes that must agree for the warm-up to count as steady.</summary>
        const int STEADY_WINDOW = 3;
        /// <summary>Relative spread (max/min - 1) tolerated across the window.</summary>
        const double STEADY_TOL = 0.05;

        static (int batch, List<(long iters, long ns)> rounds, long warmupNs, bool steady) Measure(
            Action fn, double warmupS, double warmupMaxS, double roundS, int rounds)
        {
            int batch = 1;
            while (true)  // calibration
            {
                long t0 = NowNs();
                for (int i = 0; i < batch; i++) fn();
                if (NowNs() - t0 >= 10_000_000L) break;
                batch *= 2;
            }
            // warm-up (JIT, caches, allocator): at least warmupS, at most warmupMaxS; stop early once
            // STEADY_WINDOW consecutive probe throughputs are within STEADY_TOL of each other.
            long minNs = (long)(warmupS * 1e9);
            long maxNs = (long)(warmupMaxS * 1e9);
            if (maxNs < minNs) maxNs = minNs;
            var rates = new double[STEADY_WINDOW];
            int n = 0;
            bool steady = false;
            long w0 = NowNs();
            while (true)
            {
                long elapsed = NowNs() - w0;
                if (elapsed >= maxNs) break;  // cap; also handles maxNs == 0
                long probeNs = Math.Min(WARMUP_PROBE_NS, maxNs - elapsed);
                long p0 = NowNs();
                long iters = 0;
                while (NowNs() - p0 < probeNs)
                {
                    for (int i = 0; i < batch; i++) fn();
                    iters += batch;
                }
                rates[n % STEADY_WINDOW] = iters * 1e9 / (NowNs() - p0);
                n++;
                if (NowNs() - w0 >= minNs && n >= STEADY_WINDOW)
                {
                    double lo = rates[0], hi = rates[0];
                    foreach (var r in rates) { lo = Math.Min(lo, r); hi = Math.Max(hi, r); }
                    if (hi <= lo * (1.0 + STEADY_TOL)) { steady = true; break; }
                }
            }
            long warmupNs = NowNs() - w0;
            var outRounds = new List<(long, long)>(rounds);
            long roundNs = (long)(roundS * 1e9);
            for (int r = 0; r < rounds; r++)
            {
                long iters = 0;
                long start = NowNs();
                while (NowNs() - start < roundNs)
                {
                    for (int i = 0; i < batch; i++) fn();
                    iters += batch;
                }
                outRounds.Add((iters, NowNs() - start));
            }
            return (batch, outRounds, warmupNs, steady);
        }

        sealed class Result
        {
            public string Dataset = ""; public string Operation = ""; public bool Supported;
            public string? Reason; public long PayloadBytes; public Validation? Validation;
            public long WarmupNs; public bool Steady;
            public int Batch; public List<(long iters, long ns)>? Rounds;
        }
        sealed class Validation
        {
            public bool WireBytesMatch; public bool WireSizeMatch; public bool? JsonRoundtripOk; public long? JsonBytes;
        }

        static readonly UTF8Encoding Utf8NoBom = new UTF8Encoding(false);

        static int Main(string[] argv)
        {
            var args = ParseArgs(argv);
            var datasets = new List<string>();
            foreach (var d in args.Datasets.Split(',')) if (d.Length > 0) datasets.Add(d);
            var ops = new List<string>();
            foreach (var o in args.Ops.Split(',')) if (o.Length > 0) ops.Add(o);
            foreach (var d in datasets) if (Array.IndexOf(DATASETS, d) < 0) Die($"unknown dataset {d}");
            foreach (var o in ops) if (Array.IndexOf(OPS, o) < 0) Die($"unknown op {o}");

            var results = new List<Result>();
            foreach (var ds in datasets)
            {
                var impl = Impl[ds];
                byte[] wire = File.ReadAllBytes(Path.Combine(args.Fixtures, ds + ".bin"));
                byte[] textBytes = File.ReadAllBytes(Path.Combine(args.Fixtures, ds + ".json"));
                string text = Utf8NoBom.GetString(textBytes);
                object fixtureMsg = impl.WireDecode(wire);

                // validation
                byte[] reenc = impl.WireEncode(fixtureMsg);
                var validation = new Validation
                {
                    WireBytesMatch = reenc.AsSpan().SequenceEqual(wire),
                    WireSizeMatch = reenc.Length == wire.Length,
                    JsonRoundtripOk = null,
                    JsonBytes = null,
                };
                bool jsonOk = Unsupported("json_encode") == null && Unsupported("json_decode") == null;
                if (jsonOk)
                {
                    string js = impl.JsonEncode(fixtureMsg);
                    validation.JsonBytes = Utf8NoBom.GetByteCount(js);
                    byte[] back = impl.WireEncode(impl.JsonDecode(js));
                    validation.JsonRoundtripOk = validation.WireBytesMatch ? back.AsSpan().SequenceEqual(wire) : back.Length == wire.Length;
                    if (args.Dump != null)
                    {
                        Directory.CreateDirectory(args.Dump);
                        File.WriteAllText(Path.Combine(args.Dump, ds + ".json"), js, Utf8NoBom);
                    }
                }
                if (args.Dump != null)
                {
                    Directory.CreateDirectory(args.Dump);
                    File.WriteAllBytes(Path.Combine(args.Dump, ds + ".wire.bin"), reenc);
                }

                foreach (var op in ops)
                {
                    string? reason = Unsupported(op);
                    if (reason != null)
                    {
                        results.Add(new Result { Dataset = ds, Operation = op, Supported = false, Reason = reason });
                        continue;
                    }
                    long payload;
                    Action fn;
                    switch (op)
                    {
                        case "wire_decode": payload = wire.Length; fn = impl.WireDecodeLoop(wire); break;
                        case "wire_encode": payload = wire.Length; fn = impl.WireEncodeLoop(fixtureMsg); break;
                        case "json_decode": payload = textBytes.Length; fn = impl.JsonDecodeLoop(text); break;
                        default: payload = textBytes.Length; fn = impl.JsonEncodeLoop(fixtureMsg); break;
                    }
                    var (batch, rounds, warmupNs, steady) = Measure(fn, args.WarmupSeconds, args.WarmupMaxSeconds, args.RoundSeconds, args.Rounds);
                    results.Add(new Result
                    {
                        Dataset = ds, Operation = op, Supported = true, PayloadBytes = payload,
                        Validation = validation, WarmupNs = warmupNs, Steady = steady, Batch = batch, Rounds = rounds,
                    });
                    double best = 0;
                    foreach (var (iters, ns) in rounds) best = Math.Max(best, iters / (double)ns * 1e9);
                    Console.Error.WriteLine(string.Format(System.Globalization.CultureInfo.InvariantCulture,
                        "{0}/{1} {2,-6} {3,-12} {4,14:F1} ops/s warmup {5:F1}s {6}", Language, Name, ds, op, best,
                        warmupNs / 1e9, steady ? "steady" : "NOT steady"));
                }
            }

            WriteOutput(args.Out, results);
            Console.Error.WriteLine($"sink={Sink}");
            return 0;
        }

        // ---- output (System.Text.Json is used ONLY for the result document, never for the benchmark) ----
        static void WriteOutput(string path, List<Result> results)
        {
            using var fs = File.Create(path);
            using var w = new Utf8JsonWriter(fs, new JsonWriterOptions { Indented = true });
            w.WriteStartObject();
            w.WriteNumber("schema_version", 1);
            w.WriteStartObject("harness");
            w.WriteString("language", Language);
            w.WriteString("name", Name);
            w.WriteString("runtime", Runtime());
            w.WriteString("library_version", LibraryVersion());
            w.WriteEndObject();
            w.WriteStartArray("results");
            foreach (var r in results)
            {
                w.WriteStartObject();
                w.WriteString("dataset", r.Dataset);
                w.WriteString("operation", r.Operation);
                w.WriteBoolean("supported", r.Supported);
                if (!r.Supported)
                {
                    w.WriteString("reason", r.Reason);
                    w.WriteEndObject();
                    continue;
                }
                w.WriteNumber("payload_bytes", r.PayloadBytes);
                var v = r.Validation!;
                w.WriteStartObject("validation");
                w.WriteBoolean("wire_bytes_match", v.WireBytesMatch);
                w.WriteBoolean("wire_size_match", v.WireSizeMatch);
                if (v.JsonRoundtripOk.HasValue) w.WriteBoolean("json_roundtrip_ok", v.JsonRoundtripOk.Value); else w.WriteNull("json_roundtrip_ok");
                if (v.JsonBytes.HasValue) w.WriteNumber("json_bytes", v.JsonBytes.Value); else w.WriteNull("json_bytes");
                w.WriteEndObject();
                w.WriteNumber("warmup_ns", r.WarmupNs);
                w.WriteBoolean("steady", r.Steady);
                w.WriteNumber("batch", r.Batch);
                w.WriteStartArray("rounds");
                foreach (var (iters, ns) in r.Rounds!)
                {
                    w.WriteStartObject();
                    w.WriteNumber("iterations", iters);
                    w.WriteNumber("elapsed_ns", ns);
                    w.WriteEndObject();
                }
                w.WriteEndArray();
                w.WriteEndObject();
            }
            w.WriteEndArray();
            w.WriteEndObject();
        }
    }
}
