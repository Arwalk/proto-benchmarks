const std = @import("std");
const protobuf = @import("protobuf");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Absolute path of the protoc binary used for code generation ($PROTOC).
    // Without it zig-protobuf downloads its own protoc (the same 36.2 release).
    const protoc_opt = b.option([]const u8, "protoc", "Absolute path of the protoc binary to use");
    // Absolute path of the directory containing bench.proto ($PROTO_DIR).
    const proto_dir_opt = b.option([]const u8, "proto-dir", "Absolute path of the directory containing bench.proto");
    // Resolved library version, reported in the result JSON (written by build.sh).
    const library_version = b.option([]const u8, "library-version", "zig-protobuf version string reported by the harness") orelse "unknown";

    const protobuf_dep = b.dependency("protobuf", .{
        .target = target,
        .optimize = optimize,
    });

    // Second CPU target: the host CPU (what `zig build` does without -Dcpu). The *-native
    // executables are the same code compiled for it; everything else in the suite is built for
    // the generic x86-64 baseline, so these variants are not like-for-like (see docs/METHODOLOGY.md).
    const native_target = b.resolveTargetQuery(.{});
    const protobuf_dep_native = b.dependency("protobuf", .{
        .target = native_target,
        .optimize = optimize,
    });

    const proto_dir: std.Build.LazyPath = if (proto_dir_opt) |p| .{ .cwd_relative = p } else b.path("../../proto");

    // protoc + protoc-gen-zig (built from the dependency) -> gen/bench.pb.zig
    const protoc_step = protobuf.RunProtocStep.create(protobuf_dep.builder, target, .{
        .destination_directory = b.path("gen"),
        .protoc = if (protoc_opt) |p| .{ .cwd_relative = p } else null,
        .source_files = &.{proto_dir.path(b, "bench.proto")},
        .include_directories = &.{proto_dir},
    });
    const gen_step = b.step("gen-proto", "generate Zig sources from bench.proto");
    gen_step.dependOn(protoc_step.step);

    // One executable per allocation strategy (see src/main.zig `Strategy`) and per CPU target:
    // bench, bench-arena, bench-fba (the -Dcpu target, baseline in build.sh) and the same three
    // with a -native suffix (host CPU). The sibling directories zig-protobuf-arena, -fba and the
    // three *-native directories run them from this single build.
    const cpus = [_]struct { suffix: []const u8, native: bool, target: std.Build.ResolvedTarget, dep: *std.Build.Dependency }{
        .{ .suffix = "", .native = false, .target = target, .dep = protobuf_dep },
        .{ .suffix = "-native", .native = true, .target = native_target, .dep = protobuf_dep_native },
    };
    const strategies = [_]struct { exe: []const u8, allocator: []const u8 }{
        .{ .exe = "bench", .allocator = "gpa" },
        .{ .exe = "bench-arena", .allocator = "arena" },
        .{ .exe = "bench-fba", .allocator = "fixed" },
    };
    for (cpus) |c| {
        const protobuf_mod = c.dep.module("protobuf");
        const gen_mod = b.createModule(.{
            .root_source_file = b.path("gen/bench.pb.zig"),
            .target = c.target,
            .optimize = optimize,
            .imports = &.{.{ .name = "protobuf", .module = protobuf_mod }},
        });
        for (strategies) |v| {
            const options = b.addOptions();
            options.addOption([]const u8, "library_version", library_version);
            options.addOption([]const u8, "allocator", v.allocator);
            options.addOption(bool, "native_cpu", c.native);

            const exe = b.addExecutable(.{
                .name = b.fmt("{s}{s}", .{ v.exe, c.suffix }),
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/main.zig"),
                    .target = c.target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "protobuf", .module = protobuf_mod },
                        .{ .name = "bench_pb", .module = gen_mod },
                    },
                }),
            });
            exe.root_module.addOptions("build_options", options);
            exe.step.dependOn(protoc_step.step);
            b.installArtifact(exe);
        }
    }
}
