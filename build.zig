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
        if (directGhosttyVt(b, target, optimize, src)) |mod| {
            exe_mod.addImport("ghostty-vt", mod);
        }
    } else if (b.lazyDependency("ghostty", .{ .target = target, .optimize = optimize })) |dep| {
        exe_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }

    const exe = b.addExecutable(.{
        .name = "tinymux",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run tinymux");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{ .root_module = exe_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

fn directGhosttyVt(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ghostty_src: []const u8,
) ?*std.Build.Module {
    const lib_vt_path = cwdPath(b, &.{ ghostty_src, "src/lib_vt.zig" });
    const vt = b.createModule(.{
        .root_source_file = .{ .cwd_relative = lib_vt_path },
        .target = target,
        .optimize = optimize,
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

    const Artifact = enum { ghostty, lib };
    const terminal_options = b.addOptions();
    terminal_options.addOption(Artifact, "artifact", .lib);
    terminal_options.addOption(bool, "c_abi", false);
    terminal_options.addOption(bool, "oniguruma", false);
    terminal_options.addOption(bool, "simd", false);
    terminal_options.addOption(bool, "slow_runtime_safety", optimize == .Debug);
    terminal_options.addOption(bool, "kitty_graphics", false);
    terminal_options.addOption(bool, "tmux_control_mode", false);
    terminal_options.addOption([]const u8, "version_string", versionString());
    terminal_options.addOption(usize, "version_major", 0);
    terminal_options.addOption(usize, "version_minor", 1);
    terminal_options.addOption(usize, "version_patch", 0);
    terminal_options.addOption(?[]const u8, "version_pre", null);
    terminal_options.addOption(?[]const u8, "version_build", null);
    vt.addOptions("terminal_options", terminal_options);

    const uucode_config_path = cwdPath(b, &.{ ghostty_src, "src/build/uucode_config.zig" });
    const uucode = b.lazyDependency("uucode", .{
        .target = target,
        .optimize = optimize,
        .build_config_path = std.Build.LazyPath{ .cwd_relative = uucode_config_path },
    }) orelse return null;

    const uucode_tables = uucode.namedLazyPath("tables.zig");
    addUnicodeTables(b, ghostty_src, uucode.module("uucode"), uucode_tables, vt);
    vt.addImport("uucode", uucode.module("uucode"));
    return vt;
}

fn addUnicodeTables(
    b: *std.Build,
    ghostty_src: []const u8,
    uucode_mod: *std.Build.Module,
    uucode_tables: std.Build.LazyPath,
    vt_mod: *std.Build.Module,
) void {
    const props_exe = b.addExecutable(.{
        .name = "tinymux-props-unigen",
        .root_module = b.createModule(.{
            .root_source_file = .{ .cwd_relative = cwdPath(b, &.{ ghostty_src, "src/unicode/props_uucode.zig" }) },
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
            .root_source_file = .{ .cwd_relative = cwdPath(b, &.{ ghostty_src, "src/unicode/symbols_uucode.zig" }) },
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
