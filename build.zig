const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const ghostty_src = b.option([]const u8, "ghostty-src", "Use a local Ghostty source tree for ghostty-vt");

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    if (ghostty_src) |src| {
        if (directGhosttyVt(b, target, optimize, .{ .cwd = src })) |mod| {
            exe_mod.addImport("ghostty-vt", mod);
        }
    } else if (b.lazyDependency("ghostty", .{ .target = target, .optimize = optimize })) |dep| {
        if (directGhosttyVt(b, target, optimize, .{ .dep = dep })) |mod| {
            exe_mod.addImport("ghostty-vt", mod);
        }
    }

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

const GhosttySource = union(enum) {
    cwd: []const u8,
    dep: *std.Build.Dependency,

    fn path(self: GhosttySource, b: *std.Build, sub_path: []const u8) std.Build.LazyPath {
        return switch (self) {
            .cwd => |root| .{ .cwd_relative = cwdPath(b, &.{ root, sub_path }) },
            .dep => |dep| dep.path(sub_path),
        };
    }
};

fn directGhosttyVt(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ghostty_src: GhosttySource,
) ?*std.Build.Module {
    const vt = b.createModule(.{
        .root_source_file = ghostty_src.path(b, "src/lib_vt.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const general_options = b.addOptions();
    general_options.addOption(bool, "flatpak", false);
    general_options.addOption(bool, "snap", false);
    general_options.addOption(bool, "x11", false);
    general_options.addOption(bool, "wayland", false);
    general_options.addOption(bool, "sentry", false);
    general_options.addOption(bool, "simd", false);
    general_options.addOption(bool, "i18n", false);
    vt.addOptions("build_options", general_options);

    const wuffs = wuffsModule(b, target, optimize, ghostty_src);
    const Artifact = enum { ghostty, lib };
    const terminal_options = b.addOptions();
    terminal_options.addOption(Artifact, "artifact", if (wuffs != null) .ghostty else .lib);
    terminal_options.addOption(bool, "c_abi", false);
    terminal_options.addOption(bool, "oniguruma", false);
    terminal_options.addOption(bool, "simd", false);
    terminal_options.addOption(bool, "slow_runtime_safety", optimize == .Debug);
    terminal_options.addOption(bool, "kitty_graphics", true);
    terminal_options.addOption(bool, "tmux_control_mode", false);
    terminal_options.addOption([]const u8, "version_string", versionString());
    terminal_options.addOption(usize, "version_major", 0);
    terminal_options.addOption(usize, "version_minor", 1);
    terminal_options.addOption(usize, "version_patch", 0);
    terminal_options.addOption(?[]const u8, "version_pre", null);
    terminal_options.addOption(?[]const u8, "version_build", null);
    vt.addOptions("terminal_options", terminal_options);

    const uucode = b.lazyDependency("uucode", .{
        .target = target,
        .optimize = optimize,
        .build_config_path = ghostty_src.path(b, "src/build/uucode_config.zig"),
    }) orelse return null;

    const uucode_tables = uucode.namedLazyPath("tables.zig");
    addUnicodeTables(b, ghostty_src, uucode.module("uucode"), uucode_tables, vt);
    vt.addImport("uucode", uucode.module("uucode"));
    if (wuffs) |mod| vt.addImport("wuffs", mod);
    return vt;
}

fn wuffsModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ghostty_src: GhosttySource,
) ?*std.Build.Module {
    const core = b.lazyDependency("wuffs_core", .{}) orelse return null;
    const module = b.createModule(.{
        .root_source_file = ghostty_src.path(b, "pkg/wuffs/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addIncludePath(core.path("release/c"));
    module.addCSourceFile(.{
        .file = core.path("release/c/wuffs-v0.4.c"),
        .flags = wuffsCFlags(),
    });
    return module;
}

fn wuffsCFlags() []const []const u8 {
    return &.{
        "-DWUFFS_IMPLEMENTATION",
        "-DWUFFS_CONFIG__MODULES",
        "-DWUFFS_CONFIG__MODULE__AUX__BASE",
        "-DWUFFS_CONFIG__MODULE__AUX__IMAGE",
        "-DWUFFS_CONFIG__MODULE__BASE",
        "-DWUFFS_CONFIG__MODULE__ADLER32",
        "-DWUFFS_CONFIG__MODULE__CRC32",
        "-DWUFFS_CONFIG__MODULE__DEFLATE",
        "-DWUFFS_CONFIG__MODULE__JPEG",
        "-DWUFFS_CONFIG__MODULE__PNG",
        "-DWUFFS_CONFIG__MODULE__ZLIB",
    };
}

fn addUnicodeTables(
    b: *std.Build,
    ghostty_src: GhosttySource,
    uucode_mod: *std.Build.Module,
    uucode_tables: std.Build.LazyPath,
    vt_mod: *std.Build.Module,
) void {
    const props_exe = b.addExecutable(.{
        .name = "tinymux-props-unigen",
        .root_module = b.createModule(.{
            .root_source_file = ghostty_src.path(b, "src/unicode/props_uucode.zig"),
            .target = b.graph.host,
            .strip = false,
            .omit_frame_pointer = false,
            .unwind_tables = .sync,
        }),
        .use_llvm = true,
    });
    const symbols_exe = b.addExecutable(.{
        .name = "tinymux-symbols-unigen",
        .root_module = b.createModule(.{
            .root_source_file = ghostty_src.path(b, "src/unicode/symbols_uucode.zig"),
            .target = b.graph.host,
            .strip = false,
            .omit_frame_pointer = false,
            .unwind_tables = .sync,
        }),
        .use_llvm = true,
    });

    props_exe.root_module.addImport("uucode", uucode_mod);
    symbols_exe.root_module.addImport("uucode", uucode_mod);
    uucode_tables.addStepDependencies(&props_exe.step);
    uucode_tables.addStepDependencies(&symbols_exe.step);

    const props_run = b.addRunArtifact(props_exe);
    const symbols_run = b.addRunArtifact(symbols_exe);
    const wf = b.addWriteFiles();
    const props_output = wf.addCopyFile(props_run.captureStdOut(), "props.zig");
    const symbols_output = wf.addCopyFile(symbols_run.captureStdOut(), "symbols.zig");

    vt_mod.addAnonymousImport("unicode_tables", .{ .root_source_file = props_output });
    vt_mod.addAnonymousImport("symbols_tables", .{ .root_source_file = symbols_output });
}

fn cwdPath(b: *std.Build, parts: []const []const u8) []const u8 {
    return std.fs.path.join(b.allocator, parts) catch @panic("OOM");
}

fn versionString() []const u8 {
    return "0.1.0";
}
