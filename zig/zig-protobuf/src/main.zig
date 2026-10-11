//! proto-benchmarks harness: zig-protobuf (https://github.com/Arwalk/zig-protobuf).
//! Measurement loop mirrors tools/pyharness.py 1:1 (see docs/HARNESS.md).
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const protobuf = @import("protobuf");
const pb = @import("bench_pb");
const build_options = @import("build_options");

/// General purpose allocator of Zig 0.16 (no libc), what a performance-conscious
/// user picks for release builds. The harness itself (fixtures, output) always uses it,
/// and so does every benchmark iteration of the `gpa` strategy.
const gpa: Allocator = std.heap.smp_allocator;

/// How each timed iteration gets its memory; fixed at build time (build.zig builds one
/// executable per strategy, see `-Dallocator`).
///   gpa:   allocate from the general purpose allocator and free every object individually
///          (msg.deinit, Allocating.deinit, allocator.free) inside the iteration.
///   arena: std.heap.ArenaAllocator (child: page_allocator) that is reset with
///          `.retain_capacity` at the end of every iteration; nothing is freed individually.
///   fixed: std.heap.FixedBufferAllocator over one preallocated slab, `reset()` at the end
///          of every iteration; nothing is freed individually.
const Strategy = enum { gpa, arena, fixed };
const strategy: Strategy = std.meta.stringToEnum(Strategy, build_options.allocator) orelse
    @compileError("unknown allocator strategy " ++ build_options.allocator);
const impl_id = switch (strategy) {
    .gpa => "zig/zig-protobuf",
    .arena => "zig/zig-protobuf-arena",
    .fixed => "zig/zig-protobuf-fba",
};
/// Slab of the fixed-buffer strategy. Pages are only touched as they are used; the peak
/// usage per dataset is printed to stderr.
const fixed_capacity: usize = 128 << 20;

/// Per-iteration memory source of the benchmark operations (see `Strategy`).
const Scratch = struct {
    arena: std.heap.ArenaAllocator = undefined,
    fba: std.heap.FixedBufferAllocator = undefined,
    peak: usize = 0,

    fn init() Scratch {
        var s: Scratch = .{};
        switch (strategy) {
            .gpa => {},
            .arena => s.arena = .init(std.heap.page_allocator),
            .fixed => s.fba = .init(std.heap.page_allocator.alloc(u8, fixed_capacity) catch @panic("OOM")),
        }
        return s;
    }

    fn allocator(s: *Scratch) Allocator {
        return switch (strategy) {
            .gpa => gpa,
            .arena => s.arena.allocator(),
            .fixed => s.fba.allocator(),
        };
    }

    /// End of an iteration: bulk release for the arena / fixed strategies (the gpa
    /// strategy freed everything individually already).
    fn release(s: *Scratch) void {
        switch (strategy) {
            .gpa => {},
            .arena => _ = s.arena.reset(.retain_capacity),
            .fixed => {
                s.peak = @max(s.peak, s.fba.end_index);
                s.fba.reset();
            },
        }
    }
};

/// Black hole: every iteration folds one scalar of its result into it.
var sink: u64 = 0;

const datasets_all = [_][]const u8{ "small", "medium", "large" };
const ops_all = [_][]const u8{ "wire_encode", "wire_decode", "json_encode", "json_decode" };

/// Canonical ProtoJSON: oneof members are flat fields of the parent object
/// (zig-protobuf's default `true` wraps them in an object named after the oneof).
const json_pb_options: protobuf.json.Options = .{ .emit_oneof_field_name = false };
const json_std_options: std.json.Stringify.Options = .{};
const json_parse_options: std.json.ParseOptions = .{};

const runtime_string = std.fmt.comptimePrint("Zig {s} ({s}, {s})", .{
    builtin.zig_version_string,
    @tagName(builtin.mode),
    switch (strategy) {
        .gpa => "std.heap.smp_allocator",
        .arena => "std.heap.ArenaAllocator reset per iteration",
        .fixed => "std.heap.FixedBufferAllocator reset per iteration",
    },
});

const Args = struct {
    fixtures: ?[]const u8 = null,
    out: ?[]const u8 = null,
    warmup_seconds: f64 = 3.0,
    warmup_max_seconds: f64 = 15.0,
    round_seconds: f64 = 1.0,
    rounds: u32 = 10,
    datasets: []const u8 = "small,medium,large",
    ops: []const u8 = "wire_encode,wire_decode,json_encode,json_decode",
    dump: ?[]const u8 = null,
};

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

/// Parses a `--xxx-seconds` value. Rejects negative/NaN/infinite values: `@intFromFloat`
/// of those into a u64 is undefined behaviour in ReleaseFast.
fn parseSeconds(flag: []const u8, value: []const u8) f64 {
    const v = std.fmt.parseFloat(f64, value) catch fail("bad {s} {s}", .{ flag, value });
    if (!std.math.isFinite(v) or v < 0) fail("{s} must be a finite number of seconds >= 0, got {s}", .{ flag, value });
    return v;
}

fn parseArgs(init: std.process.Init) Args {
    var a: Args = .{};
    var it = init.minimal.args.iterate();
    _ = it.skip();
    while (it.next()) |arg| {
        const value = it.next() orelse fail("missing value for {s}", .{arg});
        if (std.mem.eql(u8, arg, "--fixtures")) {
            a.fixtures = value;
        } else if (std.mem.eql(u8, arg, "--out")) {
            a.out = value;
        } else if (std.mem.eql(u8, arg, "--warmup-seconds")) {
            a.warmup_seconds = parseSeconds(arg, value);
        } else if (std.mem.eql(u8, arg, "--warmup-max-seconds")) {
            a.warmup_max_seconds = parseSeconds(arg, value);
        } else if (std.mem.eql(u8, arg, "--round-seconds")) {
            a.round_seconds = parseSeconds(arg, value);
        } else if (std.mem.eql(u8, arg, "--rounds")) {
            a.rounds = std.fmt.parseInt(u32, value, 10) catch fail("bad --rounds {s}", .{value});
            if (a.rounds < 1) fail("--rounds must be >= 1", .{});
        } else if (std.mem.eql(u8, arg, "--datasets")) {
            a.datasets = value;
        } else if (std.mem.eql(u8, arg, "--ops")) {
            a.ops = value;
        } else if (std.mem.eql(u8, arg, "--dump")) {
            a.dump = value;
        } else {
            fail("unknown argument {s}", .{arg});
        }
    }
    if (a.fixtures == null) fail("--fixtures is required", .{});
    if (a.out == null) fail("--out is required", .{});
    return a;
}

/// Splits a comma separated list and checks every item against `allowed`.
fn parseList(list: []const u8, allowed: []const []const u8, what: []const u8) std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |item| {
        if (item.len == 0) continue;
        var ok = false;
        for (allowed) |x| ok = ok or std.mem.eql(u8, x, item);
        if (!ok) fail("unknown {s} {s}", .{ what, item });
        out.append(gpa, item) catch @panic("OOM");
    }
    return out;
}

fn nowNs(io: Io) u64 {
    return @intCast(Io.Clock.awake.now(io).nanoseconds);
}

/// Steady-state warm-up (docs/HARNESS.md): the warm-up is cut into probes of
/// WARMUP_PROBE_NS; it ends once the last STEADY_WINDOW probe rates agree within
/// STEADY_TOL (never before `--warmup-seconds`, never after `--warmup-max-seconds`).
const WARMUP_PROBE_NS: u64 = 500_000_000;
const STEADY_WINDOW: usize = 3;
const STEADY_TOL: f64 = 0.05;

const Round = struct { iterations: u64, elapsed_ns: u64 };
const Measured = struct { batch: u64, rounds: []Round, warmup_ns: u64, steady: bool };

/// Calibration / warm-up / timed rounds exactly as in docs/HARNESS.md.
fn measure(
    io: Io,
    comptime C: type,
    ctx: *C,
    comptime op: fn (*C) anyerror!void,
    warmup_min_ns: u64,
    warmup_max_ns: u64,
    round_ns: u64,
    rounds: u32,
) !Measured {
    var batch: u64 = 1;
    while (true) {
        const t0 = nowNs(io);
        var i: u64 = 0;
        while (i < batch) : (i += 1) try op(ctx);
        if (nowNs(io) - t0 >= 10_000_000) break;
        batch *= 2;
    }
    // warm-up: probes of WARMUP_PROBE_NS until the rate is steady (see the constants above)
    const min_ns = warmup_min_ns;
    const max_ns = @max(warmup_max_ns, min_ns);
    var rates: [STEADY_WINDOW]f64 = undefined;
    var n: usize = 0;
    var steady = false;
    const w0 = nowNs(io);
    while (true) {
        const elapsed = nowNs(io) - w0;
        if (elapsed >= max_ns) break; // cap; also handles max_ns == 0
        const probe_ns = @min(WARMUP_PROBE_NS, max_ns - elapsed);
        const p0 = nowNs(io);
        var iters: u64 = 0;
        while (nowNs(io) - p0 < probe_ns) {
            var i: u64 = 0;
            while (i < batch) : (i += 1) try op(ctx);
            iters += batch;
        }
        rates[n % STEADY_WINDOW] = @as(f64, @floatFromInt(iters)) * 1e9 / @as(f64, @floatFromInt(nowNs(io) - p0));
        n += 1;
        if (nowNs(io) - w0 >= min_ns and n >= STEADY_WINDOW) {
            var lo = rates[0];
            var hi = rates[0];
            for (rates[1..]) |r| {
                lo = @min(lo, r);
                hi = @max(hi, r);
            }
            if (hi <= lo * (1.0 + STEADY_TOL)) {
                steady = true;
                break;
            }
        }
    }
    const warmup_ns = nowNs(io) - w0;
    const out = try gpa.alloc(Round, rounds);
    for (out) |*r| {
        var iters: u64 = 0;
        const start = nowNs(io);
        while (nowNs(io) - start < round_ns) {
            var i: u64 = 0;
            while (i < batch) : (i += 1) try op(ctx);
            iters += batch;
        }
        r.* = .{ .iterations = iters, .elapsed_ns = nowNs(io) - start };
    }
    return .{ .batch = batch, .rounds = out, .warmup_ns = warmup_ns, .steady = steady };
}

/// The four operations for one message type. Each produces a new message / buffer
/// from the iteration's allocator and releases it within the same iteration.
fn Ctx(comptime T: type, comptime scalar: fn (*const T) u64) type {
    return struct {
        wire: []const u8,
        json: []const u8,
        msg: T,
        scratch: Scratch,

        const Self = @This();

        fn wireDecode(self: *Self) anyerror!void {
            const a = self.scratch.allocator();
            defer self.scratch.release();
            var reader: Io.Reader = .fixed(self.wire);
            var m = try T.decode(&reader, a);
            sink ^= scalar(&m);
            if (strategy == .gpa) m.deinit(a);
        }

        fn wireEncode(self: *Self) anyerror!void {
            const a = self.scratch.allocator();
            defer self.scratch.release();
            var w: Io.Writer.Allocating = .init(a);
            defer if (strategy == .gpa) w.deinit();
            try self.msg.encode(&w.writer, a);
            sink ^= w.written().len;
        }

        fn jsonEncode(self: *Self) anyerror!void {
            const a = self.scratch.allocator();
            defer self.scratch.release();
            const text = try self.msg.jsonEncode(json_std_options, json_pb_options, a);
            sink ^= text.len;
            if (strategy == .gpa) a.free(text);
        }

        fn jsonDecode(self: *Self) anyerror!void {
            const a = self.scratch.allocator();
            defer self.scratch.release();
            if (strategy == .gpa) {
                // Msg.jsonDecode = std.json.parseFromSlice: the result lives in its own
                // std.json.Parsed arena, released here.
                const parsed = try T.jsonDecode(self.json, json_parse_options, a);
                sink ^= scalar(&parsed.value);
                parsed.deinit();
            } else {
                // The library has no "leaky" JSON decode entry point; Msg.jsonDecode is a
                // thin wrapper over std.json.parseFromSlice, so the arena/fixed strategies
                // call the equivalent std.json.parseFromSliceLeaky with their own allocator
                // instead of nesting a std.json.Parsed arena inside it.
                const value = try std.json.parseFromSliceLeaky(T, a, self.json, json_parse_options);
                sink ^= scalar(&value);
            }
        }
    };
}

fn smallScalar(m: *const pb.SmallMessage) u64 {
    return @bitCast(@as(i64, m.id));
}
fn mediumScalar(m: *const pb.MediumMessage) u64 {
    return @bitCast(m.created_at);
}
fn largeScalar(m: *const pb.LargeMessage) u64 {
    return m.source.len;
}

fn encodeAlloc(msg: anytype) ![]u8 {
    var w: Io.Writer.Allocating = .init(gpa);
    errdefer w.deinit();
    try msg.encode(&w.writer, gpa);
    return w.toOwnedSlice();
}

const Validation = struct {
    wire_bytes_match: bool,
    wire_size_match: bool,
    json_roundtrip_ok: bool,
    json_bytes: u64,
};

fn writeJsonString(w: *Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c),
    };
    try w.writeByte('"');
}

const Output = struct {
    w: *Io.Writer,
    first: bool = true,

    fn result(
        self: *Output,
        dataset: []const u8,
        op: []const u8,
        payload_bytes: u64,
        v: Validation,
        m: Measured,
    ) !void {
        const w = self.w;
        if (!self.first) try w.writeAll(",\n");
        self.first = false;
        try w.writeAll("  {\"dataset\": ");
        try writeJsonString(w, dataset);
        try w.writeAll(", \"operation\": ");
        try writeJsonString(w, op);
        try w.print(", \"supported\": true, \"payload_bytes\": {d},\n", .{payload_bytes});
        try w.print("   \"validation\": {{\"wire_bytes_match\": {}, \"wire_size_match\": {}, \"json_roundtrip_ok\": {}, \"json_bytes\": {d}}},\n", .{
            v.wire_bytes_match, v.wire_size_match, v.json_roundtrip_ok, v.json_bytes,
        });
        try w.print("   \"warmup_ns\": {d}, \"steady\": {}, \"batch\": {d}, \"rounds\": [", .{ m.warmup_ns, m.steady, m.batch });
        for (m.rounds, 0..) |r, i| {
            if (i != 0) try w.writeAll(", ");
            try w.print("{{\"iterations\": {d}, \"elapsed_ns\": {d}}}", .{ r.iterations, r.elapsed_ns });
        }
        try w.writeAll("]}");
    }
};

fn runDataset(
    comptime T: type,
    comptime scalar: fn (*const T) u64,
    io: Io,
    args: Args,
    name: []const u8,
    ops: []const []const u8,
    out: *Output,
) !void {
    const C = Ctx(T, scalar);
    const cwd = Io.Dir.cwd();

    const bin_path = try std.fmt.allocPrint(gpa, "{s}/{s}.bin", .{ args.fixtures.?, name });
    defer gpa.free(bin_path);
    const json_path = try std.fmt.allocPrint(gpa, "{s}/{s}.json", .{ args.fixtures.?, name });
    defer gpa.free(json_path);
    const wire = try cwd.readFileAlloc(io, bin_path, gpa, .unlimited);
    defer gpa.free(wire);
    const text = try cwd.readFileAlloc(io, json_path, gpa, .unlimited);
    defer gpa.free(text);

    var reader: Io.Reader = .fixed(wire);
    var ctx: C = .{ .wire = wire, .json = text, .msg = try T.decode(&reader, gpa), .scratch = .init() };
    defer ctx.msg.deinit(gpa);

    // ---- validation (once per dataset, before timing) ----
    const reenc = try encodeAlloc(ctx.msg);
    defer gpa.free(reenc);
    const js = try ctx.msg.jsonEncode(json_std_options, json_pb_options, gpa);
    defer gpa.free(js);
    const parsed = try T.jsonDecode(js, json_parse_options, gpa);
    defer parsed.deinit();
    const back = try encodeAlloc(parsed.value);
    defer gpa.free(back);

    const wire_bytes_match = std.mem.eql(u8, reenc, wire);
    const v: Validation = .{
        .wire_bytes_match = wire_bytes_match,
        .wire_size_match = reenc.len == wire.len,
        .json_roundtrip_ok = if (wire_bytes_match) std.mem.eql(u8, back, wire) else back.len == wire.len,
        .json_bytes = js.len,
    };
    if (args.dump) |dump| {
        try cwd.createDirPath(io, dump);
        const p1 = try std.fmt.allocPrint(gpa, "{s}/{s}.json", .{ dump, name });
        defer gpa.free(p1);
        try cwd.writeFile(io, .{ .sub_path = p1, .data = js });
        const p2 = try std.fmt.allocPrint(gpa, "{s}/{s}.wire.bin", .{ dump, name });
        defer gpa.free(p2);
        try cwd.writeFile(io, .{ .sub_path = p2, .data = reenc });
    }

    // ---- timing ----
    const warmup_ns: u64 = @intFromFloat(args.warmup_seconds * 1e9);
    const warmup_max_ns: u64 = @intFromFloat(args.warmup_max_seconds * 1e9);
    const round_ns: u64 = @intFromFloat(args.round_seconds * 1e9);
    for (ops) |op| {
        var payload: u64 = wire.len;
        const m = if (std.mem.eql(u8, op, "wire_decode"))
            try measure(io, C, &ctx, C.wireDecode, warmup_ns, warmup_max_ns, round_ns, args.rounds)
        else if (std.mem.eql(u8, op, "wire_encode"))
            try measure(io, C, &ctx, C.wireEncode, warmup_ns, warmup_max_ns, round_ns, args.rounds)
        else if (std.mem.eql(u8, op, "json_decode")) blk: {
            payload = text.len;
            break :blk try measure(io, C, &ctx, C.jsonDecode, warmup_ns, warmup_max_ns, round_ns, args.rounds);
        } else blk: {
            payload = text.len;
            break :blk try measure(io, C, &ctx, C.jsonEncode, warmup_ns, warmup_max_ns, round_ns, args.rounds);
        };
        defer gpa.free(m.rounds);
        try out.result(name, op, payload, v, m);
        var best: f64 = 0;
        for (m.rounds) |r| {
            const rate = @as(f64, @floatFromInt(r.iterations)) / @as(f64, @floatFromInt(r.elapsed_ns)) * 1e9;
            if (rate > best) best = rate;
        }
        std.debug.print("{s} {s:<6} {s:<12} {d:14.1} ops/s warmup {d:.1}s {s}\n", .{
            impl_id,
            name,
            op,
            best,
            @as(f64, @floatFromInt(m.warmup_ns)) / 1e9,
            if (m.steady) "steady" else "NOT steady",
        });
    }
    if (strategy == .fixed) {
        std.debug.print("{s} {s:<6} fixed buffer peak usage {d} bytes of {d}\n", .{ impl_id, name, ctx.scratch.peak, fixed_capacity });
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = parseArgs(init);
    var datasets = parseList(args.datasets, &datasets_all, "dataset");
    defer datasets.deinit(gpa);
    var ops = parseList(args.ops, &ops_all, "op");
    defer ops.deinit(gpa);

    var buf: Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    const w = &buf.writer;
    try w.writeAll("{\n \"schema_version\": 1,\n \"harness\": {\"language\": \"zig\", \"name\": \"zig-protobuf\", \"runtime\": ");
    try writeJsonString(w, runtime_string);
    try w.writeAll(", \"library_version\": ");
    try writeJsonString(w, build_options.library_version);
    try w.writeAll("},\n \"results\": [\n");
    var out: Output = .{ .w = w };

    for (datasets.items) |ds| {
        if (std.mem.eql(u8, ds, "small")) {
            try runDataset(pb.SmallMessage, smallScalar, io, args, ds, ops.items, &out);
        } else if (std.mem.eql(u8, ds, "medium")) {
            try runDataset(pb.MediumMessage, mediumScalar, io, args, ds, ops.items, &out);
        } else {
            try runDataset(pb.LargeMessage, largeScalar, io, args, ds, ops.items, &out);
        }
    }
    try w.writeAll("\n ]\n}\n");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = args.out.?, .data = buf.written() });
    std.mem.doNotOptimizeAway(sink);
    std.debug.print("sink={d}\n", .{sink});
}
