const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        exe_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
        if (dep.builder.lazyDependency("wuffs", .{
            .target = target,
            .optimize = optimize,
        })) |wuffs_dep| {
            exe_mod.addImport("wuffs", wuffs_dep.module("wuffs"));
        }
    }

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "ghostty_revision", "6ad1fe7d8cbda36c77b337a96c9bea8a77883699");
    build_options.addOption([]const u8, "zig_version", @import("builtin").zig_version_string);
    exe_mod.addOptions("tinymux_build_options", build_options);

    const exe = b.addExecutable(.{
        .name = "tinymux",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);
    const direnv_wrapper = b.addInstallFileWithDir(exe.getEmittedBin(), .bin, "tinymux-direnv-instant");
    b.getInstallStep().dependOn(&direnv_wrapper.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run tinymux");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{ .root_module = exe_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const bench_cmd = b.addSystemCommand(&.{
        "python3",
        "tests/benchmarks/tinymux_bench.py",
        "--tinymux",
    });
    bench_cmd.addFileArg(exe.getEmittedBin());
    bench_cmd.addArgs(&.{ "--profile", "quick" });
    bench_cmd.step.dependOn(&exe.step);
    if (b.args) |args| bench_cmd.addArgs(args);
    const bench_step = b.step("bench", "Run the quick benchmark suite");
    bench_step.dependOn(&bench_cmd.step);

    const bench_full_cmd = b.addSystemCommand(&.{
        "python3",
        "tests/benchmarks/tinymux_bench.py",
        "--tinymux",
    });
    bench_full_cmd.addFileArg(exe.getEmittedBin());
    bench_full_cmd.addArgs(&.{ "--profile", "full" });
    bench_full_cmd.step.dependOn(&exe.step);
    if (b.args) |args| bench_full_cmd.addArgs(args);
    const bench_full_step = b.step("bench-full", "Run the full benchmark suite");
    bench_full_step.dependOn(&bench_full_cmd.step);
}
