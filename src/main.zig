const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const vt = @import("ghostty-vt");
const wuffs = @import("wuffs");
const ptypkg = @import("pty.zig");
const protocol = @import("protocol.zig");
const shell_scripts = @import("shell_scripts.zig");
const diagnostics = @import("diagnostics.zig");
const os = @import("posix_compat.zig");
const vt_trace = @import("vt_trace.zig");
const graphics_protocol = @import("graphics_protocol.zig");
const build_options = @import("tinymux_build_options");
const EnvMap = std.process.Environ.Map;

pub const std_options: std.Options = .{
    .logFn = diagnostics.logFn,
};

pub const version = "0.1.0";

const stdin_fd: posix.fd_t = 0;
const stdout_fd: posix.fd_t = 1;

const OuterTerminal = struct {
    fd: posix.fd_t,

    fn write(self: OuterTerminal, bytes: []const u8) !void {
        try protocol.writeAll(self.fd, bytes);
    }
};

const outer_terminal: OuterTerminal = .{ .fd = stdout_fd };
var runtime_io: ?std.Io = null;
var runtime_environ: ?*const EnvMap = null;

fn getenv(name: [*:0]const u8) ?[:0]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

fn currentIo() std.Io {
    if (comptime builtin.is_test) return std.testing.io;
    return runtime_io.?;
}

fn currentEnvMap(alloc: std.mem.Allocator) !EnvMap {
    if (comptime builtin.is_test) return .init(alloc);
    return runtime_environ.?.clone(alloc);
}

fn initTerminal(alloc: std.mem.Allocator, options: vt.Terminal.Options) !vt.Terminal {
    return vt.Terminal.init(currentIo(), alloc, options);
}

fn decodePng(
    alloc: std.mem.Allocator,
    data: []const u8,
) vt.sys.DecodeError!vt.sys.Image {
    const result = wuffs.png.decode(alloc, data) catch |err| switch (err) {
        error.WuffsError => return error.InvalidData,
        error.OutOfMemory => return error.OutOfMemory,
        error.Overflow => return error.InvalidData,
    };

    return .{
        .width = result.width,
        .height = result.height,
        .data = result.data,
    };
}

fn nanoTimestamp() i128 {
    return @intCast(std.Io.Clock.awake.now(currentIo()).toNanoseconds());
}

fn milliTimestamp() i64 {
    return @intCast(@divTrunc(nanoTimestamp(), std.time.ns_per_ms));
}

fn sleepNanoseconds(duration_ns: u64) void {
    std.Io.sleep(
        currentIo(),
        .fromNanoseconds(@intCast(duration_ns)),
        .awake,
    ) catch {};
}

const default_split_rows: u16 = 9;
const exit_drain_ms: i64 = 50;
const termination_poll_ns: u64 = 1 * std.time.ns_per_ms;
const termination_grace_polls: usize = 100;
const composed_idle_poll_ms: i32 = 50;
const composed_frame_interval_ns: i128 = 4 * std.time.ns_per_ms;
const bulk_frame_interval_ns: i128 = 8 * std.time.ns_per_ms;
const bulk_max_coalesce_ns: i128 = 50 * std.time.ns_per_ms;
const bulk_sticky_window_ns: i128 = 120 * std.time.ns_per_ms;
const resize_quiet_ns: i128 = 80 * std.time.ns_per_ms;
const control_sequence_timeout_ns: i128 = 20 * std.time.ns_per_ms;
const terminal_report_settle_ns: i128 = 1 * std.time.ns_per_ms;
const interactive_input_window_ns: i128 = 50 * std.time.ns_per_ms;
const interactive_pty_drain_budget_ns: i128 = 1 * std.time.ns_per_ms;
const bulk_pty_drain_budget_ns: i128 = 6 * std.time.ns_per_ms;
const pty_drain_max_reads: usize = 128;
const pty_drain_max_bytes: usize = 8 * 1024 * 1024;
const bulk_damage_bytes: usize = 16 * 1024;
const bulk_damage_reads: usize = 2;
const max_pending_scrolls: usize = 8;
const max_handoff_state_bytes: usize = 64 * 1024 * 1024;
const wheel_scroll_rows: isize = 3;
const max_sgr_mouse_sequence: usize = 64;
const scrollback_bytes: usize = 256 * 1024 * 1024;
const deferred_raw_state_limit: usize = 64 * 1024 * 1024;
const deferred_raw_catchup_bytes: usize = 1024 * 1024;
const deferred_raw_catchup_ns: i128 = 1 * std.time.ns_per_ms;
const deferred_raw_catchup_delay_ns: i128 = 25 * std.time.ns_per_ms;
const deferred_raw_catchup_slice: usize = 256 * 1024;
const deferred_raw_bulk_threshold: usize = 16 * 1024 * 1024;
const deferred_raw_bulk_catchup_bytes: usize = 8 * 1024 * 1024;
const deferred_raw_bulk_catchup_ns: i128 = 6 * std.time.ns_per_ms;
const deferred_raw_bulk_prealloc_trigger: usize = 32 * 1024;
const deferred_raw_bulk_prealloc_bytes: usize = 16 * 1024 * 1024;
const kitty_image_storage_limit: usize = 320 * 1024 * 1024;
const kitty_image_loading_limits: @FieldType(vt.Terminal.Options, "kitty_image_loading_limits") = .direct;
const kitty_upload_chunk_bytes: usize = 3000;
const outer_image_id_start: u32 = 0x70000000;
const default_cell_width: u32 = 8;
const default_cell_height: u32 = 16;
const kitty_graphics_enabled = @hasField(vt.Screen, "kitty_images");

const sgr_reset = "\x1b[0m";
const style_dim = "\x1b[2m";
const synchronized_update_begin = "\x1b[?2026h";
const synchronized_update_end = "\x1b[?2026l";
const mux_mouse_enable = "\x1b[?1002h\x1b[?1006h";
const composed_input_reset =
    "\x1b[2l\x1b[12h\x1b[20l" ++
    "\x1b[?1l\x1b[?8h\x1b[?66l\x1b[?67l\x1b[?1035l\x1b[?1036l\x1b[?1039l" ++
    "\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1005l\x1b[?1006l\x1b[?1015l\x1b[?1016l" ++
    "\x1b[?1004l\x1b[?2004l\x1b[?2031l\x1b[?2033l" ++
    "\x1b[>4;0m\x1b[=0;1u";
const composed_input_capture = mux_mouse_enable ++ "\x1b[?1004h\x1b[?2004h\x1b[?2031h\x1b[?2033h";
const scrollbar_track = "│";
const scrollbar_thumb = "█";

extern "c" fn cfmakeraw(termios_p: *posix.termios) void;
extern "c" fn tcgetpgrp(fd: c_int) posix.pid_t;

const RenderScheduler = struct {
    const DirtyKind = enum { normal, urgent, bulk };

    dirty: bool = false,
    urgent: bool = false,
    bulk: bool = false,
    last_render_ns: ?i128 = null,
    last_input_ns: ?i128 = null,
    bulk_until_ns: ?i128 = null,

    fn markDirty(self: *RenderScheduler, kind: DirtyKind) void {
        self.dirty = true;
        switch (kind) {
            .normal => self.bulk = false,
            .urgent => {
                self.bulk = false;
                self.urgent = true;
            },
            .bulk => {
                self.bulk = true;
                self.urgent = false;
            },
        }
    }

    fn noteInput(self: *RenderScheduler, now_ns: i128) void {
        self.last_input_ns = now_ns;
    }

    fn recentlyInput(self: *const RenderScheduler, now_ns: i128) bool {
        const last = self.last_input_ns orelse return false;
        return now_ns >= last and now_ns - last <= interactive_input_window_ns;
    }

    fn ptyDrainBudget(self: *const RenderScheduler, now_ns: i128, first_read: DrainStats) i128 {
        if (first_read.bulkish() or self.bulkActive(now_ns)) return bulk_pty_drain_budget_ns;
        return if (self.recentlyInput(now_ns))
            interactive_pty_drain_budget_ns
        else
            bulk_pty_drain_budget_ns;
    }

    fn noteBulk(self: *RenderScheduler, now_ns: i128) void {
        self.bulk_until_ns = now_ns + bulk_sticky_window_ns;
    }

    fn dirtyKindForDamage(self: *RenderScheduler, now_ns: i128, stats: DrainStats) DirtyKind {
        const recent_input = self.recentlyInput(now_ns);
        const interactive_damage = recent_input and
            !stats.saturated and
            stats.bytes < bulk_damage_bytes;
        if (stats.bulkish() and !interactive_damage) self.noteBulk(now_ns);
        if (interactive_damage) return .urgent;
        if (stats.bulkish() or self.bulkActive(now_ns)) return .bulk;
        if (recent_input) return .urgent;
        return .normal;
    }

    fn bulkActive(self: *const RenderScheduler, now_ns: i128) bool {
        const until = self.bulk_until_ns orelse return false;
        return now_ns < until;
    }

    fn shouldRender(self: *const RenderScheduler, now_ns: i128) bool {
        if (!self.dirty) return false;
        if (self.urgent) return true;
        const last = self.last_render_ns orelse return true;
        return now_ns >= last + self.frameIntervalNs();
    }

    fn pollTimeoutMs(self: *const RenderScheduler, now_ns: i128) i32 {
        if (!self.dirty) return composed_idle_poll_ms;
        if (self.shouldRender(now_ns)) return 0;

        const last = self.last_render_ns orelse return 0;
        const due_ns = last + self.frameIntervalNs();
        if (now_ns >= due_ns) return 0;
        return nsToPollMs(due_ns - now_ns);
    }

    fn rendered(self: *RenderScheduler, now_ns: i128) void {
        self.dirty = false;
        self.urgent = false;
        self.bulk = false;
        self.last_render_ns = now_ns;
    }

    fn frameIntervalNs(self: *const RenderScheduler) i128 {
        return if (self.bulk) bulk_frame_interval_ns else composed_frame_interval_ns;
    }

    fn mustRenderUnderLoad(self: *const RenderScheduler, now_ns: i128) bool {
        const last = self.last_render_ns orelse return true;
        return now_ns >= last + bulk_max_coalesce_ns;
    }

    fn nsToPollMs(ns: i128) i32 {
        if (ns <= 0) return 0;
        const ms = @divFloor(ns + std.time.ns_per_ms - 1, std.time.ns_per_ms);
        return @intCast(@min(ms, @as(i128, std.math.maxInt(i32))));
    }
};

const DrainStats = struct {
    reads: usize = 0,
    bytes: usize = 0,
    saturated: bool = false,

    fn record(self: *DrainStats, n: usize) void {
        if (n == 0) return;
        self.reads += 1;
        self.bytes += n;
    }

    fn merge(self: *DrainStats, other: DrainStats) void {
        self.reads += other.reads;
        self.bytes += other.bytes;
        self.saturated = self.saturated or other.saturated;
    }

    fn bulkish(self: DrainStats) bool {
        return self.saturated or self.bytes >= bulk_damage_bytes or self.reads >= bulk_damage_reads;
    }
};

pub fn main(init: std.process.Init) !void {
    runtime_io = init.io;
    runtime_environ = init.environ_map;
    vt.sys.decode_png = &decodePng;
    diagnostics.initFromEnv() catch |err| {
        var stderr = std.Io.File.stderr().writer(init.io, &.{});
        try stderr.interface.print(
            "tinymux: unable to open TINYMUX_LOG: {s}\n",
            .{@errorName(err)},
        );
        return err;
    };
    defer diagnostics.deinit();
    vt_trace.initFromEnv() catch |err| {
        var stderr = std.Io.File.stderr().writer(init.io, &.{});
        try stderr.interface.print(
            "tinymux: unable to open TINYMUX_VT_TRACE: {s}\n",
            .{@errorName(err)},
        );
        return err;
    };
    defer vt_trace.deinit();

    const alloc = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        var stdout_buffer: [256]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
        try stdout.interface.print(
            "tinymux {s} ghostty-vt={s} zig={s}\n",
            .{ version, build_options.ghostty_revision, build_options.zig_version },
        );
        try stdout.interface.flush();
        return;
    }

    if (args.len > 0 and std.mem.eql(u8, std.fs.path.basename(args[0]), "kitty")) {
        const code = runKittyShim(alloc, args[1..]) catch |err| blk: {
            var stderr = std.Io.File.stderr().writer(init.io, &.{});
            try stderr.interface.print("kitty: tinymux compatibility failed: {s}\n", .{@errorName(err)});
            break :blk 1;
        };
        if (code != 0) std.process.exit(code);
        return;
    }

    if (args.len >= 2 and std.mem.eql(u8, args[1], "pane")) {
        const code = runNativeControlClient(alloc, args[1..]) catch |err| blk: {
            var stderr = std.Io.File.stderr().writer(init.io, &.{});
            try stderr.interface.print("tinymux: control request failed: {s}\n", .{@errorName(err)});
            break :blk 1;
        };
        if (code != 0) std.process.exit(code);
        return;
    }

    if (args.len >= 2 and std.mem.eql(u8, args[1], "init")) {
        try runInit(args[2..]);
        return;
    }
    if (args.len >= 2 and std.mem.eql(u8, args[1], "handoff-capture")) {
        try runHandoffCapture(alloc, args[2..]);
        return;
    }
    if (args.len >= 2 and std.mem.eql(u8, args[1], "handoff-apply")) {
        try runHandoffApply(alloc, args[2..]);
        return;
    }

    const config = parseArgs(args) catch |err| {
        try printUsage(err);
        return err;
    };

    var app = try App.init(alloc, config);
    defer app.deinit();
    try app.run();
}

fn printUsage(err: anyerror) !void {
    var stderr = std.Io.File.stderr().writer(currentIo(), &.{});
    try stderr.interface.print(
        \\tinymux: {s}
        \\
        \\usage:
        \\  tinymux --version
        \\  tinymux session [--no-kitty-compat] -- <main-argv...>
        \\  tinymux pane run [--rows <n>] -- <argv...>
        \\  tinymux pane close <generation>
        \\  tinymux pane status
        \\  tinymux --split <split-cmd> [--split-rows <n>] [--split-term auto|xterm-256color|xterm-direct|xterm-kitty|xterm-ghostty] -- <main-argv...>
        \\  tinymux --seamless [--handoff-state <dir>] -- <main-argv...>
        \\  tinymux -- <main-argv...>
        \\  tinymux init fish|sh|bash|zsh|nu
        \\  tinymux handoff-capture --state <dir> --slot baseline|result
        \\  tinymux handoff-apply --shell fish|sh|nu --state <dir>
        \\
        \\options:
        \\  --no-kitty-compat   do not expose the Kitty compatibility facade to child processes
        \\  session             run one seamless multiplexer for the main process lifetime
        \\  --seamless          avoid raw-mode terminal cleanup/redraw bytes unless a split is opened
        \\
    , .{@errorName(err)});
}

const TermChoice = enum {
    auto,
    xterm_256color,
    xterm_direct,
    xterm_kitty,
    xterm_ghostty,

    fn parse(value: []const u8) !TermChoice {
        if (std.mem.eql(u8, value, "auto")) return .auto;
        if (std.mem.eql(u8, value, "xterm-256color")) return .xterm_256color;
        if (std.mem.eql(u8, value, "xterm-direct")) return .xterm_direct;
        if (std.mem.eql(u8, value, "xterm-kitty")) return .xterm_kitty;
        if (std.mem.eql(u8, value, "xterm-ghostty")) return .xterm_ghostty;
        return error.UnsupportedTerm;
    }
};

fn selectTerm(choice: TermChoice, outer_term: ?[]const u8, colorterm: ?[]const u8) []const u8 {
    return switch (choice) {
        .xterm_256color => "xterm-256color",
        .xterm_direct => "xterm-direct",
        .xterm_kitty => "xterm-kitty",
        .xterm_ghostty => "xterm-ghostty",
        .auto => if (outerSupportsKittyGraphics(outer_term))
            outer_term.?
        else if (outerHasTruecolor(outer_term, colorterm))
            "xterm-direct"
        else
            "xterm-256color",
    };
}

fn outerSupportsKittyGraphics(outer_term: ?[]const u8) bool {
    if (outer_term) |term| {
        return containsIgnoreCase(term, "kitty") or
            containsIgnoreCase(term, "ghostty") or
            containsIgnoreCase(term, "wezterm");
    }
    return false;
}

fn outerHasTruecolor(outer_term: ?[]const u8, colorterm: ?[]const u8) bool {
    if (colorterm) |ct| {
        if (std.ascii.eqlIgnoreCase(ct, "truecolor")) return true;
        if (std.ascii.eqlIgnoreCase(ct, "24bit")) return true;
    }
    if (outer_term) |term| {
        return containsIgnoreCase(term, "direct") or
            containsIgnoreCase(term, "truecolor") or
            containsIgnoreCase(term, "ghostty") or
            containsIgnoreCase(term, "kitty") or
            containsIgnoreCase(term, "wezterm");
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

const Config = struct {
    split_cmd: ?[]const u8 = null,
    split_rows: u16 = default_split_rows,
    split_term: TermChoice = .auto,
    kitty_compat: bool = true,
    seamless: bool = false,
    session: bool = false,
    handoff_state: ?[]const u8 = null,
    main_argv: []const []const u8,
};

fn parseArgs(args: []const []const u8) !Config {
    var config: Config = .{ .main_argv = &.{} };
    var i: usize = 1;
    if (i < args.len and std.mem.eql(u8, args[i], "session")) {
        config.session = true;
        config.seamless = true;
        i += 1;
    }
    var saw_separator = false;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            saw_separator = true;
            i += 1;
            break;
        } else if (std.mem.eql(u8, arg, "--split")) {
            i += 1;
            if (i >= args.len) return error.MissingSplitCommand;
            config.split_cmd = args[i];
        } else if (std.mem.eql(u8, arg, "--split-rows")) {
            i += 1;
            if (i >= args.len) return error.MissingSplitRows;
            const rows = try std.fmt.parseUnsigned(u16, args[i], 10);
            if (rows == 0) return error.InvalidSplitRows;
            config.split_rows = rows;
        } else if (std.mem.eql(u8, arg, "--split-term")) {
            i += 1;
            if (i >= args.len) return error.MissingSplitTerm;
            config.split_term = try TermChoice.parse(args[i]);
        } else if (std.mem.eql(u8, arg, "--no-kitty-compat")) {
            config.kitty_compat = false;
        } else if (std.mem.eql(u8, arg, "--seamless")) {
            config.seamless = true;
        } else if (std.mem.eql(u8, arg, "--handoff-state")) {
            i += 1;
            if (i >= args.len) return error.MissingHandoffState;
            config.handoff_state = args[i];
        } else {
            return error.UnknownArgument;
        }
        i += 1;
    }
    if (!saw_separator) return error.MissingCommandSeparator;
    if (i >= args.len) return error.MissingMainCommand;
    if (config.session and config.handoff_state != null) return error.SessionDoesNotUseHandoff;
    config.main_argv = args[i..];
    return config;
}

fn runInit(args: []const []const u8) !void {
    if (args.len != 1) return error.UnsupportedShell;
    const shell = shell_scripts.parseInitShell(args[0]) orelse return error.UnsupportedShell;

    var stdout = std.Io.File.stdout().writer(currentIo(), &.{});
    try stdout.interface.writeAll(shell_scripts.initScript(shell));
    try stdout.interface.flush();
}

fn runHandoffCapture(alloc: std.mem.Allocator, args: []const []const u8) !void {
    var state: ?[]const u8 = null;
    var slot: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--state")) {
            i += 1;
            if (i >= args.len) return error.MissingHandoffState;
            state = args[i];
        } else if (std.mem.eql(u8, args[i], "--slot")) {
            i += 1;
            if (i >= args.len) return error.MissingHandoffSlot;
            slot = args[i];
        } else {
            return error.UnknownArgument;
        }
    }

    const state_dir = state orelse return error.MissingHandoffState;
    const slot_name = slot orelse return error.MissingHandoffSlot;
    if (!validHandoffSlot(slot_name)) return error.InvalidHandoffSlot;

    try std.Io.Dir.cwd().createDirPath(currentIo(), state_dir);
    const cwd_path = try handoffPath(alloc, state_dir, slot_name, "cwd");
    defer alloc.free(cwd_path);
    const env_path = try handoffPath(alloc, state_dir, slot_name, "env");
    defer alloc.free(env_path);

    const cwd = try std.process.currentPathAlloc(currentIo(), alloc);
    defer alloc.free(cwd);
    try writeFile(cwd_path, cwd);
    try writeEnvSnapshot(alloc, env_path);
}

fn runHandoffApply(alloc: std.mem.Allocator, args: []const []const u8) !void {
    var state: ?[]const u8 = null;
    var shell: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--state")) {
            i += 1;
            if (i >= args.len) return error.MissingHandoffState;
            state = args[i];
        } else if (std.mem.eql(u8, args[i], "--shell")) {
            i += 1;
            if (i >= args.len) return error.UnsupportedShell;
            shell = args[i];
        } else {
            return error.UnknownArgument;
        }
    }

    const state_dir = state orelse return error.MissingHandoffState;
    const shell_name = shell orelse return error.UnsupportedShell;
    const apply_shell = parseApplyShell(shell_name) orelse return error.UnsupportedShell;

    try emitHandoffApply(alloc, state_dir, apply_shell);
}

const ApplyShell = enum { fish, sh, nu };

fn parseApplyShell(shell_name: []const u8) ?ApplyShell {
    if (std.mem.eql(u8, shell_name, "fish")) return .fish;
    if (std.mem.eql(u8, shell_name, "sh") or
        std.mem.eql(u8, shell_name, "bash") or
        std.mem.eql(u8, shell_name, "zsh"))
    {
        return .sh;
    }
    if (std.mem.eql(u8, shell_name, "nu") or std.mem.eql(u8, shell_name, "nushell")) return .nu;
    return null;
}

fn validHandoffSlot(slot: []const u8) bool {
    return std.mem.eql(u8, slot, "baseline") or std.mem.eql(u8, slot, "result");
}

fn handoffPath(alloc: std.mem.Allocator, state_dir: []const u8, slot: []const u8, suffix: []const u8) ![]u8 {
    return try std.fmt.allocPrint(alloc, "{s}/{s}.{s}", .{ state_dir, slot, suffix });
}

fn writeFile(path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(currentIo(), path, .{ .truncate = true });
    defer file.close(currentIo());
    try file.writeStreamingAll(currentIo(), bytes);
}

fn writeEnvSnapshot(alloc: std.mem.Allocator, path: []const u8) !void {
    var env = try currentEnvMap(alloc);
    defer env.deinit();

    var file = try std.Io.Dir.cwd().createFile(currentIo(), path, .{ .truncate = true });
    defer file.close(currentIo());
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(currentIo(), &buffer);
    const out = &writer.interface;

    var it = env.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        try out.print("{d}\n", .{key.len});
        try out.writeAll(key);
        try out.writeByte('\n');
        try out.print("{d}\n", .{value.len});
        try out.writeAll(value);
        try out.writeByte('\n');
    }
    try out.flush();
}

const EnvSnapshot = struct {
    data: []u8,
    map: std.StringHashMap([]const u8),

    fn deinit(self: *EnvSnapshot, alloc: std.mem.Allocator) void {
        self.map.deinit();
        alloc.free(self.data);
        self.* = undefined;
    }
};

fn readEnvSnapshot(alloc: std.mem.Allocator, path: []const u8) !EnvSnapshot {
    const data = try std.Io.Dir.cwd().readFileAlloc(
        currentIo(),
        path,
        alloc,
        .limited(max_handoff_state_bytes),
    );
    errdefer alloc.free(data);
    var map = std.StringHashMap([]const u8).init(alloc);
    errdefer map.deinit();

    var index: usize = 0;
    while (index < data.len) {
        const key_len = try parseSnapshotLen(data, &index);
        const key = try parseSnapshotBytes(data, &index, key_len);
        const value_len = try parseSnapshotLen(data, &index);
        const value = try parseSnapshotBytes(data, &index, value_len);
        try map.put(key, value);
    }

    return .{ .data = data, .map = map };
}

fn parseSnapshotLen(data: []const u8, index: *usize) !usize {
    const start = index.*;
    while (index.* < data.len and data[index.*] != '\n') : (index.* += 1) {}
    if (index.* >= data.len or index.* == start) return error.InvalidHandoffState;
    const len = try std.fmt.parseUnsigned(usize, data[start..index.*], 10);
    index.* += 1;
    return len;
}

fn parseSnapshotBytes(data: []const u8, index: *usize, len: usize) ![]const u8 {
    if (index.* + len > data.len) return error.InvalidHandoffState;
    const bytes = data[index.* .. index.* + len];
    index.* += len;
    if (index.* >= data.len or data[index.*] != '\n') return error.InvalidHandoffState;
    index.* += 1;
    return bytes;
}

fn emitHandoffApply(alloc: std.mem.Allocator, state_dir: []const u8, shell: ApplyShell) !void {
    const baseline_path = try handoffPath(alloc, state_dir, "baseline", "env");
    defer alloc.free(baseline_path);
    const result_path = try handoffPath(alloc, state_dir, "result", "env");
    defer alloc.free(result_path);
    const result_cwd_path = try handoffPath(alloc, state_dir, "result", "cwd");
    defer alloc.free(result_cwd_path);

    var baseline = readEnvSnapshot(alloc, baseline_path) catch |err| switch (err) {
        error.FileNotFound => EnvSnapshot{
            .data = try alloc.dupe(u8, ""),
            .map = std.StringHashMap([]const u8).init(alloc),
        },
        else => return err,
    };
    defer baseline.deinit(alloc);

    var result = readEnvSnapshot(alloc, result_path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer result.deinit(alloc);

    const result_cwd = std.Io.Dir.cwd().readFileAlloc(
        currentIo(),
        result_cwd_path,
        alloc,
        .limited(std.Io.Dir.max_path_bytes),
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (result_cwd) |cwd| alloc.free(cwd);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(currentIo(), &stdout_buffer);
    const out = &stdout.interface;

    if (shell == .nu) {
        try emitNuHandoffApply(out, &baseline, &result, result_cwd);
        try out.flush();
        return;
    }

    if (result_cwd) |cwd| {
        if (cwd.len > 0) {
            if (shell == .fish) {
                try out.writeAll("cd -- ");
                try writeFishQuoted(out, cwd);
                try out.writeByte('\n');
            } else {
                try out.writeAll("cd -- ");
                try writeShQuoted(out, cwd);
                try out.writeByte('\n');
            }
        }
    }

    var it = result.map.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (!handoffVarAllowed(key)) continue;
        if (baseline.map.get(key)) |old| {
            if (std.mem.eql(u8, old, value)) continue;
        }
        if (shell == .fish) {
            try out.writeAll("set -gx ");
            try out.writeAll(key);
            try out.writeByte(' ');
            try writeFishQuoted(out, value);
            try out.writeByte('\n');
        } else {
            try out.writeAll("export ");
            try out.writeAll(key);
            try out.writeByte('=');
            try writeShQuoted(out, value);
            try out.writeByte('\n');
        }
    }
    try out.flush();
}

fn emitNuHandoffApply(
    out: *std.Io.Writer,
    baseline: *const EnvSnapshot,
    result: *const EnvSnapshot,
    result_cwd: ?[]const u8,
) !void {
    try out.writeAll("{\"cwd\":");
    if (result_cwd) |cwd| {
        if (cwd.len == 0) {
            try out.writeAll("null");
        } else {
            try writeJsonString(out, cwd);
        }
    } else {
        try out.writeAll("null");
    }
    try out.writeAll(",\"env\":{");

    var first = true;
    var it = result.map.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (!handoffVarAllowed(key)) continue;
        if (baseline.map.get(key)) |old| {
            if (std.mem.eql(u8, old, value)) continue;
        }
        if (!first) try out.writeByte(',');
        first = false;
        try writeJsonString(out, key);
        try out.writeByte(':');
        try writeJsonString(out, value);
    }
    try out.writeAll("}}\n");
}

fn handoffVarAllowed(key: []const u8) bool {
    if (!isShellIdentifier(key)) return false;
    if (std.mem.eql(u8, key, "_")) return false;
    if (std.mem.eql(u8, key, "PWD")) return false;
    if (std.mem.eql(u8, key, "OLDPWD")) return false;
    if (std.mem.eql(u8, key, "SHLVL")) return false;
    if (std.mem.eql(u8, key, "TERM")) return false;
    if (std.mem.eql(u8, key, "SHELL")) return false;
    if (std.mem.startsWith(u8, key, "TMUX")) return false;
    if (std.mem.startsWith(u8, key, "KITTY_")) return false;
    if (std.mem.eql(u8, key, "TINYMUX")) return false;
    if (std.mem.startsWith(u8, key, "TINYMUX_")) return false;
    return true;
}

fn isShellIdentifier(key: []const u8) bool {
    if (key.len == 0) return false;
    if (!(std.ascii.isAlphabetic(key[0]) or key[0] == '_')) return false;
    for (key[1..]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return false;
    }
    return true;
}

fn writeShQuoted(out: *std.Io.Writer, bytes: []const u8) !void {
    try out.writeByte('\'');
    for (bytes) |byte| {
        if (byte == '\'') {
            try out.writeAll("'\\''");
        } else {
            try out.writeByte(byte);
        }
    }
    try out.writeByte('\'');
}

fn writeFishQuoted(out: *std.Io.Writer, bytes: []const u8) !void {
    try out.writeByte('\'');
    for (bytes) |byte| {
        if (byte == '\'' or byte == '\\') try out.writeByte('\\');
        try out.writeByte(byte);
    }
    try out.writeByte('\'');
}

fn writeJsonString(out: *std.Io.Writer, bytes: []const u8) !void {
    const hex = "0123456789abcdef";
    try out.writeByte('"');
    for (bytes) |byte| {
        switch (byte) {
            '"' => try out.writeAll("\\\""),
            '\\' => try out.writeAll("\\\\"),
            '\n' => try out.writeAll("\\n"),
            '\r' => try out.writeAll("\\r"),
            '\t' => try out.writeAll("\\t"),
            else => if (byte < 0x20) {
                try out.writeAll("\\u00");
                try out.writeByte(hex[@as(usize, byte >> 4)]);
                try out.writeByte(hex[@as(usize, byte & 0x0f)]);
            } else {
                try out.writeByte(byte);
            },
        }
    }
    try out.writeByte('"');
}

const native_control_magic = "TINYMUX_CONTROL_2";
const kitty_split_rows_text = "10";
const max_control_line: usize = 128;
const max_control_frame: usize = 1024 * 1024;
const max_control_items: usize = 4096;
const max_control_request: usize = 16 * 1024 * 1024;
const max_control_connections: usize = 16;
const control_connection_timeout_ns: i128 = 2 * std.time.ns_per_s;

const KittyLaunchCommand = struct {
    address: ?[]const u8,
    argv: []const []const u8,
};

const PaneRunCommand = struct {
    rows: u16,
    argv: []const []const u8,
};

const NativeCommand = union(enum) {
    pane_run: PaneRunCommand,
    pane_close: u64,
    pane_status,
};

fn parseKittyCommand(args: []const []const u8) !KittyLaunchCommand {
    if (args.len == 0 or !std.mem.eql(u8, args[0], "@")) {
        return error.MissingKittyRemoteControlMarker;
    }

    var address: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len and !std.mem.eql(u8, args[i], "launch")) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--to")) {
            i += 1;
            if (i >= args.len) return error.MissingKittyAddress;
            address = args[i];
            i += 1;
        } else if (std.mem.startsWith(u8, arg, "--to=") and arg.len > "--to=".len) {
            address = arg["--to=".len..];
            i += 1;
        } else {
            return error.UnsupportedKittyGlobalOption;
        }
    }
    if (i >= args.len) return error.MissingKittyLaunchCommand;
    i += 1;

    var location_ok = false;
    var keep_focus = false;
    var self = false;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--location")) {
            i += 1;
            if (i >= args.len) return error.MissingKittyLocation;
            if (!std.mem.eql(u8, args[i], "hsplit")) return error.UnsupportedKittyLocation;
            location_ok = true;
            i += 1;
        } else if (std.mem.startsWith(u8, arg, "--location=") and arg.len > "--location=".len) {
            if (!std.mem.eql(u8, arg["--location=".len..], "hsplit")) {
                return error.UnsupportedKittyLocation;
            }
            location_ok = true;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--keep-focus")) {
            keep_focus = true;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--self")) {
            self = true;
            i += 1;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnsupportedKittyLaunchOption;
        } else {
            break;
        }
    }
    if (!location_ok) return error.MissingKittyLocation;
    if (!keep_focus) return error.MissingKittyKeepFocus;
    if (!self) return error.MissingKittySelf;
    if (i >= args.len) return error.MissingSplitCommand;

    return .{ .address = address, .argv = args[i..] };
}

fn parseNativeCommand(args: []const []const u8) !NativeCommand {
    if (args.len < 2 or !std.mem.eql(u8, args[0], "pane")) return error.UnsupportedControlCommand;
    if (std.mem.eql(u8, args[1], "run")) {
        var rows = default_split_rows;
        var i: usize = 2;
        while (i < args.len) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--")) {
                i += 1;
                break;
            } else if (std.mem.eql(u8, arg, "--rows")) {
                i += 1;
                if (i >= args.len) return error.MissingSplitRows;
                rows = try parseRows(args[i]);
                i += 1;
            } else {
                return error.UnsupportedPaneOption;
            }
        }
        if (i >= args.len) return error.MissingSplitCommand;
        return .{ .pane_run = .{
            .rows = rows,
            .argv = args[i..],
        } };
    }
    if (std.mem.eql(u8, args[1], "close")) {
        if (args.len != 3) return error.MissingPaneGeneration;
        return .{ .pane_close = try std.fmt.parseUnsigned(u64, args[2], 10) };
    }
    if (std.mem.eql(u8, args[1], "status")) {
        if (args.len != 2) return error.UnsupportedPaneOption;
        return .pane_status;
    }
    return error.UnsupportedControlCommand;
}

fn parseRows(value: []const u8) !u16 {
    const rows = try std.fmt.parseUnsigned(u16, value, 10);
    if (rows == 0) return error.InvalidSplitRows;
    return rows;
}

const ControlRuntime = struct {
    session_id: []const u8,
    dir_path: []const u8,
    socket_path: []const u8,
    kitty_shim_dir: []const u8,
    server: std.Io.net.Server,

    fn init(alloc: std.mem.Allocator) !ControlRuntime {
        const tmp = getenv("TMPDIR") orelse "/tmp";
        var runtime_root = try alloc.dupe(u8, tmp);
        defer alloc.free(runtime_root);
        if (getenv("XDG_RUNTIME_DIR")) |xdg_runtime| {
            const candidate = try std.fs.path.join(alloc, &.{ xdg_runtime, "tinymux" });
            if (ensurePrivateRuntimeDir(candidate)) {
                alloc.free(runtime_root);
                runtime_root = candidate;
            } else {
                alloc.free(candidate);
            }
        }

        var random_bytes: [@sizeOf(u64)]u8 = undefined;
        currentIo().random(&random_bytes);
        const session_id = try std.fmt.allocPrint(alloc, "{d}-{x}", .{
            std.c.getpid(),
            std.mem.readInt(u64, &random_bytes, .native),
        });
        errdefer alloc.free(session_id);

        const dir_name = try std.fmt.allocPrint(alloc, "tinymux-{s}", .{session_id});
        defer alloc.free(dir_name);
        const dir_path = try std.fs.path.join(alloc, &.{ runtime_root, dir_name });
        errdefer alloc.free(dir_path);

        try std.Io.Dir.createDirAbsolute(currentIo(), dir_path, @enumFromInt(0o700));
        errdefer std.Io.Dir.cwd().deleteTree(currentIo(), dir_path) catch {};

        const socket_path = try std.fs.path.join(alloc, &.{ dir_path, "control.sock" });
        errdefer alloc.free(socket_path);

        const kitty_shim_dir = try kittyShimDirAlloc(alloc);
        errdefer alloc.free(kitty_shim_dir);

        const address = try std.Io.net.UnixAddress.init(socket_path);
        var server = try address.listen(currentIo(), .{ .kernel_backlog = 16 });
        errdefer server.deinit(currentIo());
        try setNonblocking(server.socket.handle);

        return .{
            .session_id = session_id,
            .dir_path = dir_path,
            .socket_path = socket_path,
            .kitty_shim_dir = kitty_shim_dir,
            .server = server,
        };
    }

    fn deinit(self: *ControlRuntime, alloc: std.mem.Allocator) void {
        self.server.deinit(currentIo());
        std.Io.Dir.cwd().deleteTree(currentIo(), self.dir_path) catch {};
        alloc.free(self.kitty_shim_dir);
        alloc.free(self.socket_path);
        alloc.free(self.dir_path);
        alloc.free(self.session_id);
        self.* = undefined;
    }
};

fn kittyShimDirAlloc(alloc: std.mem.Allocator) ![]u8 {
    const self_exe = try std.process.executablePathAlloc(currentIo(), alloc);
    defer alloc.free(self_exe);
    const bin_dir = std.fs.path.dirname(self_exe) orelse return error.InvalidExecutablePath;
    const prefix = std.fs.path.dirname(bin_dir) orelse return error.InvalidExecutablePath;
    return try std.fs.path.join(alloc, &.{ prefix, "libexec", "tinymux" });
}

fn ensurePrivateRuntimeDir(path: []const u8) bool {
    std.Io.Dir.createDirAbsolute(currentIo(), path, @enumFromInt(0o700)) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return false,
    };
    const path_z = posix.toPosixPath(path) catch return false;
    return std.c.chmod(&path_z, 0o700) == 0;
}

fn setNonblocking(fd: posix.fd_t) !void {
    const flags = std.c.fcntl(fd, std.c.F.GETFL);
    if (flags < 0) return error.FcntlFailed;
    const nonblock = @as(usize, 1) << @bitOffsetOf(posix.O, "NONBLOCK");
    if (@as(usize, @intCast(flags)) & nonblock != 0) return;
    const result = std.c.fcntl(
        fd,
        std.c.F.SETFL,
        @as(c_int, @intCast(@as(usize, @intCast(flags)) | nonblock)),
    );
    if (result < 0) return error.FcntlFailed;
}

const TinymuxEnvRole = enum {
    main_session,
    nested_main,
    auxiliary,
};

fn applyTinymuxEnv(
    alloc: std.mem.Allocator,
    env: *EnvMap,
    runtime: ?*const ControlRuntime,
    kitty_compat: bool,
    pane_id: []const u8,
    role: TinymuxEnvRole,
) !void {
    try env.put("TINYMUX", "1");
    _ = env.swapRemove("TINYMUX_SESSION_ID");
    _ = env.swapRemove("TINYMUX_CONTROL");
    _ = env.swapRemove("TINYMUX_TMUX_SOCKET");
    _ = env.swapRemove("TINYMUX_SHIM_DIR");
    _ = env.swapRemove("TMUX_PANE");
    _ = env.swapRemove("TMUX");
    _ = env.swapRemove("KITTY_LISTEN_ON");
    _ = env.swapRemove("KITTY_WINDOW_ID");
    _ = env.swapRemove("KITTY_PID");

    if (role != .main_session) {
        // Host integration belongs only to the persistent main shell. Nested
        // legacy shells and auxiliary panes must not publish host prompt/cwd
        // state through the main terminal.
        _ = env.swapRemove("GHOSTTY_RESOURCES_DIR");
        _ = env.swapRemove("GHOSTTY_SHELL_INTEGRATION_XDG_DIR");
    }

    if (runtime) |rt| {
        try env.put("TINYMUX_SESSION_ID", rt.session_id);
        try env.put("TINYMUX_CONTROL", rt.socket_path);
        if (kitty_compat) {
            const listen_on = try std.fmt.allocPrint(alloc, "unix:{s}", .{rt.socket_path});
            defer alloc.free(listen_on);
            try env.put("KITTY_LISTEN_ON", listen_on);
            try env.put("KITTY_WINDOW_ID", pane_id);
            try prependPath(alloc, env, rt.kitty_shim_dir);
        }
    }
}

fn prependPath(alloc: std.mem.Allocator, env: *EnvMap, dir: []const u8) !void {
    const current = env.get("PATH") orelse "";
    var paths = std.mem.splitScalar(u8, current, ':');
    while (paths.next()) |path| {
        if (std.mem.eql(u8, path, dir)) return;
    }
    const updated = if (current.len == 0)
        try alloc.dupe(u8, dir)
    else
        try std.mem.join(alloc, ":", &.{ dir, current });
    defer alloc.free(updated);
    try env.put("PATH", updated);
}

const SocketReader = struct {
    fd: posix.fd_t,
    buf: [4096]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    fn readByte(self: *SocketReader) !u8 {
        if (self.start >= self.end) {
            const n = try os.read(self.fd, &self.buf);
            if (n == 0) return error.EndOfStream;
            self.start = 0;
            self.end = n;
        }
        const byte = self.buf[self.start];
        self.start += 1;
        return byte;
    }

    fn readExact(self: *SocketReader, out: []u8) !void {
        var offset: usize = 0;
        while (offset < out.len) {
            out[offset] = try self.readByte();
            offset += 1;
        }
    }

    fn readLineAlloc(self: *SocketReader, alloc: std.mem.Allocator, max_len: usize) ![]u8 {
        var line: std.ArrayList(u8) = .empty;
        errdefer line.deinit(alloc);
        while (true) {
            const byte = try self.readByte();
            if (byte == '\n') break;
            if (line.items.len >= max_len) return error.ControlLineTooLong;
            try line.append(alloc, byte);
        }
        return try line.toOwnedSlice(alloc);
    }

    fn readNumber(self: *SocketReader, alloc: std.mem.Allocator) !usize {
        const line = try self.readLineAlloc(alloc, max_control_line);
        defer alloc.free(line);
        return try std.fmt.parseUnsigned(usize, line, 10);
    }

    fn readCount(self: *SocketReader, alloc: std.mem.Allocator) !usize {
        const count = try self.readNumber(alloc);
        if (count > max_control_items) return error.ControlRequestTooLarge;
        return count;
    }

    fn readFrame(self: *SocketReader, alloc: std.mem.Allocator) ![]u8 {
        const len = try self.readNumber(alloc);
        if (len > max_control_frame) return error.ControlFrameTooLarge;
        const data = try alloc.alloc(u8, len);
        errdefer alloc.free(data);
        try self.readExact(data);
        return data;
    }
};

const ControlRequest = struct {
    cwd: ?[]u8,
    argv: [][]u8,
    env: EnvMap,

    fn read(alloc: std.mem.Allocator, fd: posix.fd_t) !ControlRequest {
        var reader: SocketReader = .{ .fd = fd };
        const magic = try reader.readLineAlloc(alloc, max_control_line);
        defer alloc.free(magic);
        if (!std.mem.eql(u8, magic, native_control_magic)) return error.InvalidControlMagic;

        const cwd_frame = try reader.readFrame(alloc);
        const cwd: ?[]u8 = if (cwd_frame.len == 0) cwd: {
            alloc.free(cwd_frame);
            break :cwd null;
        } else cwd_frame;
        errdefer if (cwd) |path| alloc.free(path);

        const argc = try reader.readCount(alloc);
        var argv = try alloc.alloc([]u8, argc);
        errdefer alloc.free(argv);
        var argv_len: usize = 0;
        errdefer {
            for (argv[0..argv_len]) |arg| alloc.free(arg);
        }
        while (argv_len < argc) : (argv_len += 1) {
            argv[argv_len] = try reader.readFrame(alloc);
        }

        const env_count = try reader.readCount(alloc);
        var env = EnvMap.init(alloc);
        errdefer env.deinit();
        for (0..env_count) |_| {
            const key = try reader.readFrame(alloc);
            errdefer alloc.free(key);
            const value = try reader.readFrame(alloc);
            errdefer alloc.free(value);
            try env.putMove(key, value);
        }

        return .{ .cwd = cwd, .argv = argv, .env = env };
    }

    fn readBuffer(alloc: std.mem.Allocator, data: []const u8) !ControlRequest {
        var reader: ControlBufferReader = .{ .data = data };
        const magic = try reader.readLine(max_control_line);
        if (!std.mem.eql(u8, magic, native_control_magic)) return error.InvalidControlMagic;

        const cwd_frame = try reader.readFrame();
        const cwd: ?[]u8 = if (cwd_frame.len == 0)
            null
        else
            try alloc.dupe(u8, cwd_frame);
        errdefer if (cwd) |path| alloc.free(path);

        const argc = try reader.readCount();
        var argv = try alloc.alloc([]u8, argc);
        errdefer alloc.free(argv);
        var argv_len: usize = 0;
        errdefer for (argv[0..argv_len]) |arg| alloc.free(arg);
        while (argv_len < argc) : (argv_len += 1) {
            argv[argv_len] = try alloc.dupe(u8, try reader.readFrame());
        }

        const env_count = try reader.readCount();
        var env = EnvMap.init(alloc);
        errdefer env.deinit();
        for (0..env_count) |_| {
            const key = try alloc.dupe(u8, try reader.readFrame());
            errdefer alloc.free(key);
            const value = try alloc.dupe(u8, try reader.readFrame());
            errdefer alloc.free(value);
            try env.putMove(key, value);
        }
        if (reader.index != data.len) return error.TrailingControlData;

        return .{ .cwd = cwd, .argv = argv, .env = env };
    }

    fn deinit(self: *ControlRequest, alloc: std.mem.Allocator) void {
        if (self.cwd) |cwd| alloc.free(cwd);
        for (self.argv) |arg| alloc.free(arg);
        alloc.free(self.argv);
        self.env.deinit();
        self.* = undefined;
    }
};

const ControlBufferReader = struct {
    data: []const u8,
    index: usize = 0,

    fn readLine(self: *ControlBufferReader, max_len: usize) ![]const u8 {
        const end = std.mem.indexOfScalarPos(u8, self.data, self.index, '\n') orelse
            return error.IncompleteControlRequest;
        if (end - self.index > max_len) return error.ControlLineTooLong;
        const line = self.data[self.index..end];
        self.index = end + 1;
        return line;
    }

    fn readNumber(self: *ControlBufferReader) !usize {
        return try std.fmt.parseUnsigned(usize, try self.readLine(max_control_line), 10);
    }

    fn readCount(self: *ControlBufferReader) !usize {
        const count = try self.readNumber();
        if (count > max_control_items) return error.ControlRequestTooLarge;
        return count;
    }

    fn readFrame(self: *ControlBufferReader) ![]const u8 {
        const len = try self.readNumber();
        if (len > max_control_frame) return error.ControlFrameTooLarge;
        if (len > self.data.len - self.index) return error.IncompleteControlRequest;
        const frame = self.data[self.index .. self.index + len];
        self.index += len;
        return frame;
    }
};

const ControlConnection = struct {
    fd: posix.fd_t,
    input: std.ArrayList(u8) = .empty,
    accepted_ns: i128,

    fn deinit(self: *ControlConnection, alloc: std.mem.Allocator) void {
        os.close(self.fd);
        self.input.deinit(alloc);
        self.* = undefined;
    }
};

const ControlResponse = struct {
    ok: bool,
    message: []u8,

    fn read(alloc: std.mem.Allocator, fd: posix.fd_t) !ControlResponse {
        var reader: SocketReader = .{ .fd = fd };
        const status = try reader.readLineAlloc(alloc, max_control_line);
        defer alloc.free(status);
        const ok = if (std.mem.eql(u8, status, "OK"))
            true
        else if (std.mem.eql(u8, status, "ERR"))
            false
        else
            return error.InvalidControlResponse;
        const message = try reader.readFrame(alloc);
        return .{ .ok = ok, .message = message };
    }

    fn deinit(self: *ControlResponse, alloc: std.mem.Allocator) void {
        alloc.free(self.message);
        self.* = undefined;
    }
};

fn writeFrame(fd: posix.fd_t, bytes: []const u8) !void {
    var len_buf: [64]u8 = undefined;
    const len_line = try std.fmt.bufPrint(&len_buf, "{d}\n", .{bytes.len});
    try protocol.writeAll(fd, len_line);
    try protocol.writeAll(fd, bytes);
}

fn writeControlResponse(fd: posix.fd_t, ok: bool, message: []const u8) void {
    protocol.writeAll(fd, if (ok) "OK\n" else "ERR\n") catch return;
    writeFrame(fd, message) catch return;
}

fn writeControlRequest(
    alloc: std.mem.Allocator,
    fd: posix.fd_t,
    magic: []const u8,
    args: []const []const u8,
) !void {
    try protocol.writeAll(fd, magic);
    try protocol.writeAll(fd, "\n");

    const cwd = std.process.currentPathAlloc(currentIo(), alloc) catch try alloc.dupe(u8, "");
    defer alloc.free(cwd);
    try writeFrame(fd, cwd);

    var count_buf: [64]u8 = undefined;
    const argc_line = try std.fmt.bufPrint(&count_buf, "{d}\n", .{args.len});
    try protocol.writeAll(fd, argc_line);
    for (args) |arg| try writeFrame(fd, arg);

    var env = try currentEnvMap(alloc);
    defer env.deinit();
    const env_count_line = try std.fmt.bufPrint(&count_buf, "{d}\n", .{env.count()});
    try protocol.writeAll(fd, env_count_line);
    var it = env.iterator();
    while (it.next()) |entry| {
        try writeFrame(fd, entry.key_ptr.*);
        try writeFrame(fd, entry.value_ptr.*);
    }
}

fn runKittyShim(alloc: std.mem.Allocator, args: []const []const u8) !u8 {
    const listen_on = getenv("KITTY_LISTEN_ON") orelse {
        var stderr = std.Io.File.stderr().writer(currentIo(), &.{});
        try stderr.interface.writeAll("kitty: not running inside tinymux Kitty compatibility\n");
        return 1;
    };
    const socket_path = getenv("TINYMUX_CONTROL") orelse {
        var stderr = std.Io.File.stderr().writer(currentIo(), &.{});
        try stderr.interface.writeAll("kitty: no tinymux control socket\n");
        return 1;
    };
    const launch = try parseKittyCommand(args);
    if (launch.address) |address| {
        if (!std.mem.eql(u8, address, listen_on)) return error.KittyAddressMismatch;
    }

    var native_args = try alloc.alloc([]const u8, launch.argv.len + 5);
    defer alloc.free(native_args);
    native_args[0] = "pane";
    native_args[1] = "run";
    native_args[2] = "--rows";
    native_args[3] = kitty_split_rows_text;
    native_args[4] = "--";
    std.mem.copyForwards([]const u8, native_args[5..], launch.argv);

    const address = try std.Io.net.UnixAddress.init(socket_path);
    const stream = try address.connect(currentIo());
    defer stream.close(currentIo());

    try writeControlRequest(alloc, stream.socket.handle, native_control_magic, native_args);
    var response = try ControlResponse.read(alloc, stream.socket.handle);
    defer response.deinit(alloc);

    if (!response.ok) {
        var stderr = std.Io.File.stderr().writer(currentIo(), &.{});
        try stderr.interface.print("kitty: {s}\n", .{response.message});
        return 1;
    }
    return 0;
}

fn runNativeControlClient(alloc: std.mem.Allocator, args: []const []const u8) !u8 {
    const socket_path = getenv("TINYMUX_CONTROL") orelse {
        var stderr = std.Io.File.stderr().writer(currentIo(), &.{});
        try stderr.interface.writeAll("tinymux: no persistent session control socket\n");
        return 1;
    };
    const address = try std.Io.net.UnixAddress.init(socket_path);
    const stream = try address.connect(currentIo());
    defer stream.close(currentIo());

    try writeControlRequest(alloc, stream.socket.handle, native_control_magic, args);
    var response = try ControlResponse.read(alloc, stream.socket.handle);
    defer response.deinit(alloc);
    if (!response.ok) {
        var stderr = std.Io.File.stderr().writer(currentIo(), &.{});
        try stderr.interface.print("tinymux: {s}\n", .{response.message});
        return 1;
    }
    if (response.message.len > 0) {
        var stdout = std.Io.File.stdout().writer(currentIo(), &.{});
        try stdout.interface.writeAll(response.message);
        try stdout.interface.writeByte('\n');
        try stdout.interface.flush();
    }
    return 0;
}

const Layout = struct {
    rows: u16,
    cols: u16,
    split_visible: bool,
    main_rows: u16,
    border_row: ?u16,
    split_rows: u16,

    fn compute(rows_raw: u16, cols_raw: u16, split_visible: bool, requested_split_rows: u16) Layout {
        const rows = @max(rows_raw, 1);
        const cols = @max(cols_raw, 1);
        if (!split_visible or rows < 3) {
            return .{
                .rows = rows,
                .cols = cols,
                .split_visible = false,
                .main_rows = rows,
                .border_row = null,
                .split_rows = 0,
            };
        }

        const max_split = rows - 2;
        const split_rows = @min(@max(requested_split_rows, 1), max_split);
        const main_rows = rows - split_rows - 1;
        return .{
            .rows = rows,
            .cols = cols,
            .split_visible = true,
            .main_rows = main_rows,
            .border_row = main_rows,
            .split_rows = split_rows,
        };
    }

    fn splitTop(self: Layout) u16 {
        return if (self.border_row) |row| row + 1 else self.rows;
    }

    fn scrollbarVisible(self: Layout) bool {
        return self.split_visible and self.cols > 1;
    }

    fn paneCols(self: Layout) u16 {
        return if (self.scrollbarVisible()) self.cols - 1 else self.cols;
    }

    fn scrollbarCol(self: Layout) ?u16 {
        return if (self.scrollbarVisible()) self.cols else null;
    }
};

const PendingScrollUp = struct {
    screen: vt.ScreenSet.Key,
    top: u16,
    bottom: u16,
    count: usize,

    fn height(self: PendingScrollUp) u16 {
        return self.bottom - self.top + 1;
    }
};

const PendingScrollBatch = struct {
    items: [max_pending_scrolls]PendingScrollUp = undefined,
    len: usize = 0,
    overflow: bool = false,
};

const ReplyRoute = union(enum) {
    pane: ?posix.pid_t,
    discard,
};

const RawControlScanner = struct {
    const State = enum { ground, escape, csi };

    state: State = .ground,
    bytes: [512]u8 = undefined,
    len: usize = 0,
    due_ns: ?i128 = null,

    fn start(self: *RawControlScanner, now_ns: i128) void {
        self.state = .escape;
        self.bytes[0] = 0x1b;
        self.len = 1;
        self.due_ns = now_ns + control_sequence_timeout_ns;
    }

    fn append(self: *RawControlScanner, byte: u8, now_ns: i128) bool {
        if (self.len >= self.bytes.len) return false;
        self.bytes[self.len] = byte;
        self.len += 1;
        self.due_ns = now_ns + control_sequence_timeout_ns;
        return true;
    }

    fn reset(self: *RawControlScanner) void {
        self.state = .ground;
        self.len = 0;
        self.due_ns = null;
    }

    fn buffered(self: *const RawControlScanner) []const u8 {
        return self.bytes[0..self.len];
    }
};

const OuterInputFilter = struct {
    const State = enum { ground, escape, csi };

    state: State = .ground,
    bytes: [128]u8 = undefined,
    len: usize = 0,
    due_ns: ?i128 = null,
    bracketed_paste: bool = false,
    paste_forward_markers: bool = false,

    fn start(self: *OuterInputFilter, now_ns: i128) void {
        self.state = .escape;
        self.bytes[0] = 0x1b;
        self.len = 1;
        self.due_ns = now_ns + control_sequence_timeout_ns;
    }

    fn append(self: *OuterInputFilter, byte: u8, now_ns: i128) bool {
        if (self.len >= self.bytes.len) return false;
        self.bytes[self.len] = byte;
        self.len += 1;
        self.due_ns = now_ns + control_sequence_timeout_ns;
        return true;
    }

    fn resetSequence(self: *OuterInputFilter) void {
        self.state = .ground;
        self.len = 0;
        self.due_ns = null;
    }

    fn buffered(self: *const OuterInputFilter) []const u8 {
        return self.bytes[0..self.len];
    }
};

const PaneInputEncoding = struct {
    screen: vt.ScreenSet.Key = .primary,
    send_receive_mode: bool = true,
    linefeed: bool = false,
    cursor_keys: bool = false,
    keypad_keys: bool = false,
    backarrow_key_mode: bool = false,
    ignore_keypad_with_numlock: bool = false,
    alt_esc_prefix: bool = false,
    alt_sends_escape: bool = false,
    modify_other_keys_2: bool = false,
    kitty_flags: u8 = 0,

    fn fromPane(pane: *const Pane) PaneInputEncoding {
        const term = &pane.term;
        return .{
            .screen = term.screens.active_key,
            .send_receive_mode = term.modes.get(.send_receive_mode),
            .linefeed = term.modes.get(.linefeed),
            .cursor_keys = term.modes.get(.cursor_keys),
            .keypad_keys = term.modes.get(.keypad_keys),
            .backarrow_key_mode = term.modes.get(.backarrow_key_mode),
            .ignore_keypad_with_numlock = term.modes.get(.ignore_keypad_with_numlock),
            .alt_esc_prefix = term.modes.get(.alt_esc_prefix),
            .alt_sends_escape = term.modes.get(.alt_sends_escape),
            .modify_other_keys_2 = term.flags.modify_other_keys_2,
            .kitty_flags = @intCast(term.screens.active.kitty_keyboard.current().int()),
        };
    }
};

const InputModePolicy = enum {
    display_state,
    mirror_to_outer,
    pin_outer_default,
    virtualize_in_mux,
    synthesize_report,
};

/// Every terminal mode must have an explicit ownership policy. This switch is
/// intentionally exhaustive so updating ghostty-vt cannot silently introduce
/// another mode that changes outer input behind the mux's back.
fn inputModePolicy(mode: vt.Mode) InputModePolicy {
    return switch (mode) {
        .send_receive_mode,
        .linefeed,
        .cursor_keys,
        .keypad_keys,
        .backarrow_key_mode,
        .ignore_keypad_with_numlock,
        .alt_esc_prefix,
        .alt_sends_escape,
        => .mirror_to_outer,

        .autorepeat => .pin_outer_default,

        .disable_keyboard,
        .mouse_event_x10,
        .mouse_event_normal,
        .mouse_event_button,
        .mouse_event_any,
        .focus_event,
        .mouse_format_utf8,
        .mouse_format_sgr,
        .mouse_alternate_scroll,
        .mouse_format_urxvt,
        .mouse_format_sgr_pixels,
        .bracketed_paste,
        => .virtualize_in_mux,

        .report_color_scheme,
        .report_visibility,
        .in_band_size_reports,
        => .synthesize_report,

        .insert,
        .@"132_column",
        .slow_scroll,
        .reverse_colors,
        .origin,
        .wraparound,
        .cursor_blinking,
        .cursor_visible,
        .enable_mode_3,
        .reverse_wrap,
        .alt_screen_legacy,
        .enable_left_and_right_margin,
        .reverse_wrap_extended,
        .alt_screen,
        .save_cursor,
        .alt_screen_save_cursor_clear_enter,
        .synchronized_output,
        .grapheme_cluster,
        => .display_state,
    };
}

const PaneInputState = struct {
    encoding: PaneInputEncoding = .{},
    keyboard_disabled: bool = false,
    focus_event: bool = false,
    bracketed_paste: bool = false,
    report_color_scheme: bool = false,
    report_visibility: bool = false,

    fn fromPane(pane: *const Pane) PaneInputState {
        return .{
            .encoding = .fromPane(pane),
            .keyboard_disabled = pane.term.modes.get(.disable_keyboard),
            .focus_event = pane.term.modes.get(.focus_event),
            .bracketed_paste = pane.term.modes.get(.bracketed_paste),
            .report_color_scheme = pane.term.modes.get(.report_color_scheme),
            .report_visibility = pane.term.modes.get(.report_visibility),
        };
    }
};

const OuterInputProtocol = struct {
    composed: bool = false,
    state: PaneInputState = .{},

    fn appendMode(
        writer: *std.Io.Writer,
        previous: bool,
        desired: bool,
        force: bool,
        set: []const u8,
        reset: []const u8,
    ) !void {
        if (!force and previous == desired) return;
        try writer.writeAll(if (desired) set else reset);
    }

    fn appendEncodingDiff(
        previous: PaneInputEncoding,
        desired: PaneInputEncoding,
        writer: *std.Io.Writer,
        force_all: bool,
    ) !void {
        const force = force_all or previous.screen != desired.screen;
        try appendMode(
            writer,
            previous.send_receive_mode,
            desired.send_receive_mode,
            force,
            "\x1b[12h",
            "\x1b[12l",
        );
        try appendMode(writer, previous.linefeed, desired.linefeed, force, "\x1b[20h", "\x1b[20l");
        try appendMode(writer, previous.cursor_keys, desired.cursor_keys, force, "\x1b[?1h", "\x1b[?1l");
        try appendMode(writer, previous.keypad_keys, desired.keypad_keys, force, "\x1b[?66h", "\x1b[?66l");
        try appendMode(writer, previous.backarrow_key_mode, desired.backarrow_key_mode, force, "\x1b[?67h", "\x1b[?67l");
        try appendMode(
            writer,
            previous.ignore_keypad_with_numlock,
            desired.ignore_keypad_with_numlock,
            force,
            "\x1b[?1035h",
            "\x1b[?1035l",
        );
        try appendMode(writer, previous.alt_esc_prefix, desired.alt_esc_prefix, force, "\x1b[?1036h", "\x1b[?1036l");
        try appendMode(writer, previous.alt_sends_escape, desired.alt_sends_escape, force, "\x1b[?1039h", "\x1b[?1039l");
        try appendMode(
            writer,
            previous.modify_other_keys_2,
            desired.modify_other_keys_2,
            force,
            "\x1b[>4;2m",
            "\x1b[>4;0m",
        );
        if (force or previous.kitty_flags != desired.kitty_flags) {
            try writer.print("\x1b[={d};1u", .{desired.kitty_flags});
        }
    }

    fn enterComposed(
        self: *OuterInputProtocol,
        desired: PaneInputState,
        writer: *std.Io.Writer,
    ) !void {
        try writer.writeAll(composed_input_reset);
        try writer.writeAll(composed_input_capture);
        try appendEncodingDiff(.{}, desired.encoding, writer, true);
        self.composed = true;
        self.state = desired;
    }

    fn sync(
        self: *OuterInputProtocol,
        desired: PaneInputState,
        writer: *std.Io.Writer,
    ) !void {
        if (!self.composed) return;
        try appendEncodingDiff(self.state.encoding, desired.encoding, writer, false);
        self.state = desired;
    }

    fn adoptRaw(self: *OuterInputProtocol, desired: PaneInputState) void {
        self.composed = false;
        self.state = desired;
    }

    fn noteRawControlSequence(self: *OuterInputProtocol, sequence: []const u8) void {
        if (self.composed) return;
        if (std.mem.eql(u8, sequence, "\x1b[?1004h")) self.state.focus_event = true;
        if (std.mem.eql(u8, sequence, "\x1b[?1004l")) self.state.focus_event = false;
        if (std.mem.eql(u8, sequence, "\x1b[?2004h")) self.state.bracketed_paste = true;
        if (std.mem.eql(u8, sequence, "\x1b[?2004l")) self.state.bracketed_paste = false;
        if (std.mem.eql(u8, sequence, "\x1b[?2031h")) self.state.report_color_scheme = true;
        if (std.mem.eql(u8, sequence, "\x1b[?2031l")) self.state.report_color_scheme = false;
        if (std.mem.eql(u8, sequence, "\x1b[?2033h")) self.state.report_visibility = true;
        if (std.mem.eql(u8, sequence, "\x1b[?2033l")) self.state.report_visibility = false;
    }
};

const DeferredOuterReport = enum {
    focus_in,
    focus_out,
    color_scheme_dark,
    color_scheme_light,
    visibility_visible,
    visibility_hidden,

    fn bytes(self: DeferredOuterReport) []const u8 {
        return switch (self) {
            .focus_in => "\x1b[I",
            .focus_out => "\x1b[O",
            .color_scheme_dark => "\x1b[?997;1n",
            .color_scheme_light => "\x1b[?997;2n",
            .visibility_visible => "\x1b[?999;1n",
            .visibility_hidden => "\x1b[?999;2n",
        };
    }
};

const PendingColorQuery = struct {
    pane: PaneId,
    owner: ?posix.pid_t,
};

const DeferredOuterReportDelivery = struct {
    report: DeferredOuterReport,
    query: ?PendingColorQuery = null,
};

const RawTerminal = struct {
    fd: posix.fd_t,
    original: posix.termios,
    active: bool = false,

    fn enable(fd: posix.fd_t) !RawTerminal {
        const raw = RawTerminal{
            .fd = fd,
            .original = try posix.tcgetattr(fd),
            .active = true,
        };
        var mode = raw.original;
        cfmakeraw(&mode);
        try posix.tcsetattr(fd, .NOW, mode);
        return raw;
    }

    fn restore(self: *RawTerminal) void {
        if (!self.active) return;
        posix.tcsetattr(self.fd, .NOW, self.original) catch {};
        self.active = false;
    }
};

const CellSize = struct {
    width: u32 = default_cell_width,
    height: u32 = default_cell_height,

    fn fromWinsize(size: ptypkg.Winsize) CellSize {
        if (size.col == 0 or size.row == 0 or size.xpixel == 0 or size.ypixel == 0) return .{};
        return .{
            .width = @max(@as(u32, size.xpixel) / @as(u32, size.col), 1),
            .height = @max(@as(u32, size.ypixel) / @as(u32, size.row), 1),
        };
    }

    fn makeWinsize(self: CellSize, rows: u16, cols: u16) ptypkg.Winsize {
        return .{
            .row = rows,
            .col = cols,
            .xpixel = saturatingU16(@as(u64, self.width) * cols),
            .ypixel = saturatingU16(@as(u64, self.height) * rows),
        };
    }

    fn applyToTerm(self: CellSize, term: *vt.Terminal) void {
        term.width_px = saturatingU32(@as(u64, self.width) * term.cols);
        term.height_px = saturatingU32(@as(u64, self.height) * term.rows);
    }
};

fn saturatingU16(value: u64) u16 {
    return if (value > std.math.maxInt(u16)) std.math.maxInt(u16) else @intCast(value);
}

fn saturatingU32(value: u64) u32 {
    return if (value > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(value);
}

fn sameGridSize(a: ptypkg.Winsize, b: ptypkg.Winsize) bool {
    return a.row == b.row and a.col == b.col;
}

fn plainAsciiEligible(bytes: []const u8) bool {
    for (bytes) |byte| {
        switch (byte) {
            '\r', '\n', 0x20...0x7e => {},
            else => return false,
        }
    }
    return true;
}

const PlainCursorState = struct {
    col: u16 = 0,
    pending_wrap: bool = false,
};

const ScreenSwitchMirror = struct {
    const State = enum { ground, escape, csi };

    state: State = .ground,
    bytes: [32]u8 = undefined,
    len: usize = 0,

    fn reset(self: *ScreenSwitchMirror) void {
        self.state = .ground;
        self.len = 0;
    }

    fn startEscape(self: *ScreenSwitchMirror) void {
        self.state = .escape;
        self.len = 1;
        self.bytes[0] = 0x1b;
    }

    fn feed(
        self: *ScreenSwitchMirror,
        alloc: std.mem.Allocator,
        input: []const u8,
        out: *std.ArrayList(u8),
        primary_touched: *bool,
        alternate_touched: *bool,
    ) !void {
        for (input) |byte| {
            switch (self.state) {
                .ground => if (byte == 0x1b) self.startEscape(),
                .escape => {
                    if (byte == '[') {
                        self.bytes[1] = byte;
                        self.len = 2;
                        self.state = .csi;
                    } else if (byte == 0x1b) {
                        self.startEscape();
                    } else {
                        self.reset();
                    }
                },
                .csi => {
                    if (self.len >= self.bytes.len) {
                        self.reset();
                        if (byte == 0x1b) self.startEscape();
                        continue;
                    }
                    self.bytes[self.len] = byte;
                    self.len += 1;
                    if (byte < 0x40 or byte > 0x7e) continue;

                    const sequence = self.bytes[0..self.len];
                    const target: ?bool = if (std.mem.eql(u8, sequence, "\x1b[?47h") or
                        std.mem.eql(u8, sequence, "\x1b[?1047h") or
                        std.mem.eql(u8, sequence, "\x1b[?1049h"))
                        true
                    else if (std.mem.eql(u8, sequence, "\x1b[?47l") or
                        std.mem.eql(u8, sequence, "\x1b[?1047l") or
                        std.mem.eql(u8, sequence, "\x1b[?1049l"))
                        false
                    else
                        null;
                    if (target) |alternate| {
                        try out.appendSlice(alloc, sequence);
                        if (alternate) alternate_touched.* = true else primary_touched.* = true;
                    }
                    self.reset();
                },
            }
        }
    }
};

const HostEffectMirror = struct {
    const State = enum { ground, escape, osc, osc_escape, osc_discard, osc_discard_escape };

    state: State = .ground,
    bytes: [4096]u8 = undefined,
    len: usize = 0,

    fn reset(self: *HostEffectMirror) void {
        self.state = .ground;
        self.len = 0;
    }

    fn startEscape(self: *HostEffectMirror) void {
        self.state = .escape;
        self.len = 1;
        self.bytes[0] = 0x1b;
    }

    fn append(self: *HostEffectMirror, byte: u8) bool {
        if (self.len >= self.bytes.len) return false;
        self.bytes[self.len] = byte;
        self.len += 1;
        return true;
    }

    fn forwardOsc(self: *HostEffectMirror, alloc: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        if (self.len < 4) return;
        const body_end = if (self.bytes[self.len - 1] == 0x07) self.len - 1 else self.len - 2;
        const body = self.bytes[2..body_end];
        const separator = std.mem.indexOfScalar(u8, body, ';') orelse return;
        const selector = body[0..separator];
        if (std.mem.eql(u8, selector, "0") or
            std.mem.eql(u8, selector, "2") or
            std.mem.eql(u8, selector, "7") or
            std.mem.eql(u8, selector, "133"))
        {
            try out.appendSlice(alloc, self.bytes[0..self.len]);
        }
    }

    fn feed(self: *HostEffectMirror, alloc: std.mem.Allocator, input: []const u8, out: *std.ArrayList(u8)) !void {
        for (input) |byte| {
            switch (self.state) {
                .ground => if (byte == 0x07) {
                    try out.append(alloc, byte);
                } else if (byte == 0x1b) {
                    self.startEscape();
                },
                .escape => {
                    if (byte == ']') {
                        _ = self.append(byte);
                        self.state = .osc;
                    } else if (byte == 0x1b) {
                        self.startEscape();
                    } else {
                        self.reset();
                    }
                },
                .osc => {
                    if (!self.append(byte)) {
                        self.state = .osc_discard;
                        continue;
                    }
                    if (byte == 0x07) {
                        try self.forwardOsc(alloc, out);
                        self.reset();
                    } else if (byte == 0x1b) {
                        self.state = .osc_escape;
                    }
                },
                .osc_escape => {
                    if (!self.append(byte)) {
                        self.state = .osc_discard;
                        continue;
                    }
                    if (byte == '\\') {
                        try self.forwardOsc(alloc, out);
                        self.reset();
                    } else if (byte != 0x1b) {
                        self.state = .osc;
                    }
                },
                .osc_discard => if (byte == 0x07) {
                    self.reset();
                } else if (byte == 0x1b) {
                    self.state = .osc_discard_escape;
                },
                .osc_discard_escape => if (byte == '\\') {
                    self.reset();
                } else if (byte != 0x1b) {
                    self.state = .osc_discard;
                },
            }
        }
    }
};

fn plainPassthroughEndState(bytes: []const u8, pane_cols: u16, start: PlainCursorState) ?PlainCursorState {
    if (pane_cols == 0) return null;
    var state = start;
    for (bytes) |byte| {
        switch (byte) {
            0x20...0x7e => {
                if (state.pending_wrap) {
                    state.col = 0;
                    state.pending_wrap = false;
                }
                if (state.col >= pane_cols) return null;
                if (state.col == pane_cols - 1) {
                    state.pending_wrap = true;
                } else {
                    state.col += 1;
                }
            },
            '\r' => {
                state.col = 0;
                state.pending_wrap = false;
            },
            '\n' => {
                state.pending_wrap = false;
            },
            else => return null,
        }
    }
    return state;
}

fn terminalCursorWillScrollUp(term: *const vt.Terminal) bool {
    const cursor = term.screens.active.cursor;
    return cursor.y == term.scrolling_region.bottom and
        cursor.x >= term.scrolling_region.left and
        cursor.x <= term.scrolling_region.right;
}

fn cloneEnvMap(alloc: std.mem.Allocator, source: *const EnvMap) !EnvMap {
    var env = EnvMap.init(alloc);
    errdefer env.deinit();
    var it = source.iterator();
    while (it.next()) |entry| {
        try env.put(entry.key_ptr.*, entry.value_ptr.*);
    }
    return env;
}

const Pane = struct {
    alloc: std.mem.Allocator,
    pty_fd: posix.fd_t,
    child_pid: posix.pid_t,
    alive: bool = true,
    reaped: bool = false,
    command_title: []const u8,
    reply_route: ReplyRoute = .discard,
    in_band_size_owner: ?posix.pid_t = null,
    ascii_fast_feed_enabled: bool = true,
    cell_size: CellSize,
    term: vt.Terminal,
    stream: Stream,
    pending_scrolls: [max_pending_scrolls]PendingScrollUp = undefined,
    pending_scroll_count: usize = 0,
    pending_scroll_overflow: bool = false,
    model_epoch: u64 = 0,
    cursor_repair_count: u64 = 0,
    color_scheme: ColorScheme = null,
    color_scheme_queries_to_outer: usize = 0,
    color_scheme_query_owner: ?posix.pid_t = null,
    graphics_normalizer: graphics_protocol.Normalizer = .{},
    graphics_seen: bool = false,
    graphics_dropped: bool = false,

    pub const TerminalHandler = vt.TerminalStream.Handler;
    pub const Stream = vt.Stream(StreamHandler);
    const ColorScheme = EffectReturn("color_scheme");

    const StreamHandler = struct {
        const Action = @import("ghostty-vt").StreamAction;
        const Terminal = @import("ghostty-vt").Terminal;

        terminal_handler: TerminalHandler,
        pane: *Pane,

        fn init(pane: *Pane) StreamHandler {
            var handler: TerminalHandler = .init(&pane.term);
            handler.effects = .{
                .write_pty = effectWritePty,
                .bell = null,
                .desktop_notification = null,
                .color_scheme = effectColorScheme,
                .device_attributes = effectDeviceAttributes,
                .enquiry = null,
                .size = effectSize,
                .title_changed = null,
                .pwd_changed = null,
                .progress_report = null,
                .clipboard_write = null,
                .xtversion = effectXtversion,
            };
            return .{
                .terminal_handler = handler,
                .pane = pane,
            };
        }

        pub fn deinit(self: *StreamHandler) void {
            self.terminal_handler.deinit();
        }

        pub fn vt(
            self: *StreamHandler,
            comptime action: Action.Tag,
            value: Action.Value(action),
        ) void {
            self.pane.ensureCursorCoherent("before", @tagName(action));
            const scroll_up = self.scrollUp(action, value);
            self.terminal_handler.vt(action, value);
            self.pane.model_epoch +%= 1;
            self.pane.ensureCursorCoherent("after", @tagName(action));
            if (comptime action == .set_mode) {
                if (value.mode == .in_band_size_reports) {
                    self.pane.in_band_size_owner = switch (self.pane.reply_route) {
                        .pane => |owner| owner,
                        else => null,
                    };
                    self.pane.sendInBandSizeReport();
                }
            }
            if (comptime action == .reset_mode) {
                if (value.mode == .in_band_size_reports) {
                    self.pane.in_band_size_owner = null;
                }
            }
            if (comptime action == .full_reset) {
                self.pane.in_band_size_owner = null;
            }
            if (scroll_up) |scroll| self.pane.noteScrollUp(scroll);
        }

        fn scrollUp(
            self: *StreamHandler,
            comptime action: Action.Tag,
            value: Action.Value(action),
        ) ?PendingScrollUp {
            const term = self.terminal_handler.terminal;
            const count: usize = switch (action) {
                .linefeed, .index, .next_line => if (cursorWillScrollUp(term)) 1 else return null,
                .scroll_up => @min(value, scrollRegionHeight(term)),
                else => return null,
            };
            if (count == 0) return null;
            return .{
                .screen = term.screens.active_key,
                .top = term.scrolling_region.top,
                .bottom = term.scrolling_region.bottom,
                .count = count,
            };
        }

        fn scrollRegionHeight(term: *const Terminal) u16 {
            if (term.rows == 0 or term.scrolling_region.bottom < term.scrolling_region.top) return 0;
            return term.scrolling_region.bottom - term.scrolling_region.top + 1;
        }

        fn cursorWillScrollUp(term: *const Terminal) bool {
            const cursor = term.screens.active.cursor;
            return cursor.y == term.scrolling_region.bottom and
                cursor.x >= term.scrolling_region.left and
                cursor.x <= term.scrolling_region.right;
        }
    };

    fn create(
        alloc: std.mem.Allocator,
        argv: []const []const u8,
        env: *EnvMap,
        rows: u16,
        cols: u16,
        cell_size: CellSize,
        cwd: ?[]const u8,
    ) !*Pane {
        const self = try alloc.create(Pane);
        errdefer alloc.destroy(self);

        const spawned = try ptypkg.spawnInPty(alloc, .{
            .argv = argv,
            .env = env,
            .size = cell_size.makeWinsize(rows, cols),
            .cwd = cwd,
        });
        errdefer os.close(spawned.master);

        self.* = .{
            .alloc = alloc,
            .pty_fd = spawned.master,
            .child_pid = spawned.pid,
            .command_title = try alloc.dupe(u8, argv[0]),
            .cell_size = cell_size,
            .term = undefined,
            .stream = undefined,
        };
        errdefer alloc.free(self.command_title);

        self.term = if (comptime kitty_graphics_enabled)
            try initTerminal(alloc, .{
                .cols = cols,
                .rows = rows,
                .max_scrollback_bytes = scrollback_bytes,
                .kitty_image_storage_limit = kitty_image_storage_limit,
                .kitty_image_loading_limits = kitty_image_loading_limits,
            })
        else
            try initTerminal(alloc, .{
                .cols = cols,
                .rows = rows,
                .max_scrollback_bytes = scrollback_bytes,
            });
        errdefer self.term.deinit(alloc);
        self.cell_size.applyToTerm(&self.term);

        const handler = StreamHandler.init(self);
        self.stream = .initAlloc(alloc, handler);
        return self;
    }

    fn destroy(self: *Pane) void {
        self.terminate();
        self.graphics_normalizer.deinit(self.alloc);
        self.stream.deinit();
        self.term.deinit(self.alloc);
        self.alloc.free(self.command_title);
        self.alloc.destroy(self);
    }

    fn fromHandler(handler: *TerminalHandler) *Pane {
        const stream_handler: *StreamHandler = @alignCast(@fieldParentPtr("terminal_handler", handler));
        return stream_handler.pane;
    }

    const DeviceAttributes = EffectReturn("device_attributes");

    fn EffectReturn(comptime field_name: []const u8) type {
        const Effects = TerminalHandler.Effects;
        const field = std.meta.fieldInfo(
            Effects,
            @field(std.meta.FieldEnum(Effects), field_name),
        );
        const Fn = @typeInfo(field.type).optional.child;
        return @typeInfo(@typeInfo(Fn).pointer.child).@"fn".return_type.?;
    }

    fn effectWritePty(handler: *TerminalHandler, data: [:0]const u8) void {
        const self = fromHandler(handler);
        switch (self.reply_route) {
            .discard => return,
            .pane => |owner| self.writeTerminalReply(data, owner),
        }
    }

    fn effectDeviceAttributes(handler: *TerminalHandler) DeviceAttributes {
        _ = handler;
        return .{};
    }

    fn effectColorScheme(handler: *TerminalHandler) ColorScheme {
        const self = fromHandler(handler);
        if (self.color_scheme) |scheme| return scheme;
        self.color_scheme_queries_to_outer +|= 1;
        self.color_scheme_query_owner = switch (self.reply_route) {
            .discard => null,
            .pane => |owner| owner,
        };
        return null;
    }

    fn effectSize(handler: *TerminalHandler) ?vt.size_report.Size {
        const self = fromHandler(handler);
        return .{
            .rows = self.term.rows,
            .columns = self.term.cols,
            .cell_width = self.cell_size.width,
            .cell_height = self.cell_size.height,
        };
    }

    fn effectXtversion(handler: *TerminalHandler) []const u8 {
        _ = handler;
        return "tinymux " ++ version;
    }

    fn repairCursorCache(self: *Pane) bool {
        const screen = self.term.screens.active;
        const expected = screen.cursor.page_pin.rowAndCell();
        if (screen.cursor.page_row != expected.row or
            screen.cursor.page_cell != expected.cell)
        {
            screen.cursorReload();
            self.cursor_repair_count +%= 1;
            return true;
        }
        return false;
    }

    fn ensureCursorCoherent(self: *Pane, phase: []const u8, action: []const u8) void {
        if (!self.repairCursorCache()) return;
        std.log.warn(
            "repaired stale cursor cache phase={s} action={s} epoch={d}",
            .{ phase, action, self.model_epoch },
        );
    }

    fn feed(self: *Pane, bytes: []const u8) void {
        vt_trace.feed(self.child_pid, bytes);
        self.ensureCursorCoherent("feed-before", "slice");
        if (self.ascii_fast_feed_enabled) {
            if (plainAsciiEligible(bytes)) {
                if (self.feedPlainAscii(bytes)) {
                    self.ensureCursorCoherent("feed-after", "ascii-slice");
                    return;
                }
                self.ascii_fast_feed_enabled = false;
                return;
            } else {
                self.ascii_fast_feed_enabled = false;
            }
        }
        self.stream.nextSlice(bytes);
        self.ensureCursorCoherent("feed-after", "slice");
    }

    fn feedWithReplies(self: *Pane, bytes: []const u8, owner: ?posix.pid_t) void {
        const previous = self.reply_route;
        self.reply_route = .{ .pane = owner };
        defer self.reply_route = previous;
        self.feed(bytes);
    }

    fn foregroundPgrp(self: *const Pane) ?posix.pid_t {
        if (self.pty_fd < 0) return null;
        const result = tcgetpgrp(self.pty_fd);
        return if (result < 0) null else result;
    }

    fn terminalReplySafe(self: *const Pane, owner: ?posix.pid_t) bool {
        if (self.pty_fd < 0) return false;
        const expected = owner orelse return false;
        const current = self.foregroundPgrp() orelse return false;
        if (current != expected) return false;
        const attrs = posix.tcgetattr(self.pty_fd) catch return false;
        return !attrs.lflag.ECHO;
    }

    fn writeTerminalReply(self: *Pane, bytes: []const u8, owner: ?posix.pid_t) void {
        if (!self.terminalReplySafe(owner)) return;
        protocol.writeAll(self.pty_fd, bytes) catch {};
    }

    fn sendInBandSizeReport(self: *Pane) void {
        const owner = self.in_band_size_owner orelse return;
        if (!self.term.modes.get(.in_band_size_reports)) return;
        var storage: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&storage);
        vt.size_report.encode(&writer, .mode_2048, .{
            .rows = self.term.rows,
            .columns = self.term.cols,
            .cell_width = self.cell_size.width,
            .cell_height = self.cell_size.height,
        }) catch return;
        self.writeTerminalReply(writer.buffered(), owner);
    }

    fn feedPlainAscii(self: *Pane, bytes: []const u8) bool {
        var start: usize = 0;
        for (bytes, 0..) |byte, i| {
            switch (byte) {
                '\r', '\n' => {
                    if (start < i) {
                        self.ensureCursorCoherent("before", "print-string");
                        self.term.printString(bytes[start..i]) catch return false;
                        self.model_epoch +%= 1;
                        self.ensureCursorCoherent("after", "print-string");
                    }
                    if (byte == '\r') {
                        self.ensureCursorCoherent("before", "carriage-return");
                        self.term.carriageReturn();
                        self.model_epoch +%= 1;
                        self.ensureCursorCoherent("after", "carriage-return");
                    } else {
                        if (terminalCursorWillScrollUp(&self.term)) {
                            self.noteScrollUp(.{
                                .screen = self.term.screens.active_key,
                                .top = self.term.scrolling_region.top,
                                .bottom = self.term.scrolling_region.bottom,
                                .count = 1,
                            });
                        }
                        self.ensureCursorCoherent("before", "linefeed");
                        self.term.linefeed() catch return false;
                        self.model_epoch +%= 1;
                        self.ensureCursorCoherent("after", "linefeed");
                    }
                    start = i + 1;
                },
                else => {},
            }
        }
        if (start < bytes.len) {
            self.ensureCursorCoherent("before", "print-string");
            self.term.printString(bytes[start..]) catch return false;
            self.model_epoch +%= 1;
            self.ensureCursorCoherent("after", "print-string");
        }
        return true;
    }

    fn noteScrollUp(self: *Pane, scroll: PendingScrollUp) void {
        if (scroll.count == 0 or scroll.bottom < scroll.top) return;
        if (self.pending_scroll_overflow) return;

        for (self.pending_scrolls[0..self.pending_scroll_count]) |*pending| {
            if (pending.screen == scroll.screen and
                pending.top == scroll.top and
                pending.bottom == scroll.bottom)
            {
                pending.count = std.math.add(usize, pending.count, scroll.count) catch std.math.maxInt(usize);
                return;
            }
        }

        if (self.pending_scroll_count >= max_pending_scrolls) {
            self.pending_scroll_count = 0;
            self.pending_scroll_overflow = true;
            return;
        }

        self.pending_scrolls[self.pending_scroll_count] = scroll;
        self.pending_scroll_count += 1;
    }

    fn takePendingScrolls(self: *Pane) PendingScrollBatch {
        var batch: PendingScrollBatch = .{
            .len = self.pending_scroll_count,
            .overflow = self.pending_scroll_overflow,
        };
        @memcpy(batch.items[0..self.pending_scroll_count], self.pending_scrolls[0..self.pending_scroll_count]);
        self.pending_scroll_count = 0;
        self.pending_scroll_overflow = false;
        return batch;
    }

    fn writeInput(self: *Pane, bytes: []const u8) !void {
        if (!self.alive or self.pty_fd < 0) return;
        try protocol.writeAll(self.pty_fd, bytes);
    }

    fn resize(self: *Pane, rows: u16, cols: u16, cell_size: CellSize) !void {
        self.cell_size = cell_size;
        vt_trace.resize(self.child_pid, rows, cols, cell_size.width, cell_size.height);
        try self.term.resize(self.alloc, .{
            .cols = cols,
            .rows = rows,
            .cell_size_px = .{
                .width = cell_size.width,
                .height = cell_size.height,
            },
        });
        if (self.pty_fd >= 0) {
            try ptypkg.Pty.setSize(self.pty_fd, self.cell_size.makeWinsize(rows, cols));
        }
        self.sendInBandSizeReport();
    }

    fn closePty(self: *Pane) void {
        if (self.pty_fd >= 0) {
            os.close(self.pty_fd);
            self.pty_fd = -1;
        }
    }

    fn markDead(self: *Pane) void {
        self.alive = false;
        self.closePty();
        _ = self.reap(posix.W.NOHANG);
    }

    fn reapIfExited(self: *Pane) void {
        if (self.reaped) return;
        if (self.reap(posix.W.NOHANG)) {
            self.alive = false;
        }
    }

    fn terminate(self: *Pane) void {
        self.closePty();
        self.alive = false;
        if (self.reaped) return;

        posix.kill(self.child_pid, posix.SIG.HUP) catch {};
        if (self.waitForExit(termination_grace_polls, termination_poll_ns)) return;

        posix.kill(self.child_pid, posix.SIG.TERM) catch {};
        if (self.waitForExit(termination_grace_polls, termination_poll_ns)) return;

        posix.kill(self.child_pid, posix.SIG.KILL) catch {};
        _ = self.reap(0);
    }

    fn waitForExit(self: *Pane, polls: usize, sleep_ns: u64) bool {
        for (0..polls) |_| {
            if (self.reap(posix.W.NOHANG)) return true;
            sleepNanoseconds(sleep_ns);
        }
        return false;
    }

    fn reap(self: *Pane, options: u32) bool {
        if (self.reaped) return true;

        var status: c_int = 0;
        while (true) {
            const rc = std.c.waitpid(self.child_pid, &status, @intCast(options));
            switch (posix.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) return false;
                    self.reaped = true;
                    return true;
                },
                .INTR => continue,
                .CHILD => {
                    self.reaped = true;
                    return true;
                },
                else => return false,
            }
        }
    }

    fn repaint(self: *Pane, alloc: std.mem.Allocator) ![]u8 {
        var raw: std.Io.Writer.Allocating = .init(alloc);
        defer raw.deinit();
        var formatter: vt.formatter.TerminalFormatter = .init(&self.term, .{ .emit = .vt });
        formatter.content = .{ .selection = self.screenSelection() };
        formatter.extra = .{
            .palette = false,
            .modes = true,
            .scrolling_region = true,
            .tabstops = true,
            .pwd = false,
            .keyboard = true,
            .screen = .all,
        };
        try raw.writer.print("{f}", .{formatter});

        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try out.writer.writeAll(sanitize_sequence);
        try out.writer.writeAll(raw.writer.buffered());
        try self.writeCursorPos(&out.writer);
        return alloc.dupe(u8, out.writer.buffered());
    }

    fn terminalModes(self: *Pane, alloc: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        var terminal_formatter: vt.formatter.TerminalFormatter = .init(&self.term, .{ .emit = .vt });
        terminal_formatter.content = .none;
        terminal_formatter.extra = .{
            .palette = false,
            .modes = true,
            .scrolling_region = true,
            .tabstops = true,
            .pwd = true,
            .keyboard = true,
            .screen = .none,
        };
        try out.writer.print("{f}", .{terminal_formatter});
        var filtered: std.ArrayList(u8) = .empty;
        defer filtered.deinit(alloc);
        try appendWithoutScreenSwitchModes(alloc, &filtered, out.writer.buffered());
        return alloc.dupe(u8, filtered.items);
    }

    fn screenState(self: *Pane, alloc: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        var screen_formatter: vt.formatter.TerminalFormatter = .init(&self.term, .{ .emit = .vt });
        screen_formatter.content = .none;
        screen_formatter.extra = .none;
        screen_formatter.extra.screen = .all;
        try out.writer.print("{f}", .{screen_formatter});
        return alloc.dupe(u8, out.writer.buffered());
    }

    fn screenSelection(self: *Pane) ?vt.Selection {
        const pages = &self.term.screens.active.pages;
        const tl = pages.pin(.{ .active = .{ .x = 0, .y = 0 } }) orelse return null;
        const br = pages.pin(.{ .active = .{
            .x = self.term.cols - 1,
            .y = self.term.rows - 1,
        } }) orelse return null;
        return vt.Selection.init(tl, br, false);
    }

    fn writeCursorPos(self: *Pane, writer: *std.Io.Writer) !void {
        const cursor = &self.term.screens.active.cursor;
        var row: usize = cursor.y;
        var col: usize = cursor.x;
        if (self.term.modes.get(.origin)) {
            row -|= self.term.scrolling_region.top;
            col -|= self.term.scrolling_region.left;
        }
        try writePaneCursorState(writer, &self.term, row, col);
    }
};

fn appendWithoutScreenSwitchModes(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    input: []const u8,
) !void {
    const sequences = [_][]const u8{
        "\x1b[?47h",   "\x1b[?47l",
        "\x1b[?1047h", "\x1b[?1047l",
        "\x1b[?1049h", "\x1b[?1049l",
        "\x1b[?2048h", "\x1b[?2048l",
    };
    var offset: usize = 0;
    while (offset < input.len) {
        var skipped = false;
        for (sequences) |sequence| {
            if (std.mem.startsWith(u8, input[offset..], sequence)) {
                offset += sequence.len;
                skipped = true;
                break;
            }
        }
        if (skipped) continue;
        try out.append(alloc, input[offset]);
        offset += 1;
    }
}

const reset_state_sequence = "\x0f\x1b(B" ++
    "\x1b[0m\x1b[0 q\x1b[2l\x1b[12h\x1b[20l" ++
    "\x1b[?1l\x1b[?5l\x1b[?6l\x1b[?7h\x1b[?8h" ++
    "\x1b[4l\x1b[r\x1b[?69l\x1b[?25h" ++
    "\x1b[?66l\x1b[?67l\x1b[?1035l\x1b[?1036l\x1b[?1039l" ++
    "\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1005l\x1b[?1006l\x1b[?1015l\x1b[?1016l" ++
    "\x1b[?2004l\x1b[?1004l\x1b[?2031l\x1b[?2033l\x1b[?2048l" ++
    "\x1b[>4;0m\x1b[=0;1u";
const restore_terminal_sequence = reset_state_sequence ++ "\x1b[?2026l";
const sanitize_sequence = reset_state_sequence ++ "\x1b[H\x1b[2J";

const ViewportRow = struct {
    bytes: std.ArrayList(u8) = .empty,
    node: ?*const anyopaque = null,
    serial: u64 = 0,
    offset: u16 = 0,
    valid: bool = false,

    fn deinit(self: *ViewportRow, alloc: std.mem.Allocator) void {
        self.bytes.deinit(alloc);
    }

    fn capturePin(self: *ViewportRow, pin: vt.Pin) void {
        self.node = @ptrCast(pin.node);
        self.serial = pin.node.serial;
        self.offset = pin.y;
        self.valid = true;
    }

    fn matchesPin(self: *const ViewportRow, pin: vt.Pin) bool {
        if (!self.valid) return false;
        if (self.node != @as(*const anyopaque, @ptrCast(pin.node))) return false;
        if (self.serial != pin.node.serial) return false;
        return self.offset == pin.y;
    }
};

fn viewportRowReusable(entry: *const ViewportRow, pin: vt.Pin, full_render: bool) bool {
    if (full_render or !entry.valid) return false;
    if (!entry.matchesPin(pin)) return false;
    return !pin.isDirty();
}

fn viewportPin(term: *vt.Terminal, y: u16) ?vt.Pin {
    if (term.cols == 0 or y >= term.rows) return null;
    return term.screens.active.pages.pin(.{ .viewport = .{ .x = 0, .y = y } });
}

fn reverseSlice(comptime T: type, items: []T) void {
    if (items.len < 2) return;
    var left: usize = 0;
    var right: usize = items.len - 1;
    while (left < right) {
        const tmp = items[left];
        items[left] = items[right];
        items[right] = tmp;
        left += 1;
        right -= 1;
    }
}

fn rotateLeft(comptime T: type, items: []T, amount: usize) void {
    if (items.len < 2) return;
    const shift = amount % items.len;
    if (shift == 0) return;
    reverseSlice(T, items[0..shift]);
    reverseSlice(T, items[shift..]);
    reverseSlice(T, items);
}

fn appendTermRow(
    alloc: std.mem.Allocator,
    term: *vt.Terminal,
    y: u16,
    out: *std.ArrayList(u8),
) !void {
    const screen = term.screens.active;
    if (term.cols == 0 or y >= term.rows) return;
    const start = viewportPin(term, y) orelse return;
    const end = screen.pages.pin(.{ .viewport = .{
        .x = term.cols - 1,
        .y = y,
    } }) orelse return;

    var formatter: vt.formatter.ScreenFormatter = .init(screen, .{ .emit = .vt });
    formatter.content = .{ .selection = vt.Selection.init(start, end, true) };

    const begin = out.items.len;
    {
        var aw: std.Io.Writer.Allocating = .fromArrayList(alloc, out);
        defer out.* = aw.toArrayList();
        aw.writer.print("{f}", .{formatter}) catch return error.OutOfMemory;
    }
    if (std.mem.indexOf(u8, out.items[begin..], "\x1b]8;") != null) {
        try out.appendSlice(alloc, "\x1b]8;;\x1b\\");
    }
}

const PaneRowCache = struct {
    rows: std.ArrayList(ViewportRow) = .empty,

    fn deinit(self: *PaneRowCache, alloc: std.mem.Allocator) void {
        for (self.rows.items) |*row| row.deinit(alloc);
        self.rows.deinit(alloc);
    }

    fn ensure(self: *PaneRowCache, alloc: std.mem.Allocator, count: u16) !void {
        while (self.rows.items.len < count) try self.rows.append(alloc, .{});
        while (self.rows.items.len > count) {
            var row = self.rows.pop() orelse break;
            row.deinit(alloc);
        }
    }

    fn detectScrollUp(self: *PaneRowCache, term: *vt.Terminal, visible_rows: u16, full_render: bool) u16 {
        if (full_render) return 0;
        const row_count: usize = @intCast(@min(visible_rows, term.rows));
        if (row_count < 3 or self.rows.items.len < row_count) return 0;

        var best_delta: usize = 0;
        var best_overlap: usize = 0;
        var delta: usize = 1;
        while (delta < row_count) : (delta += 1) {
            const overlap = row_count - delta;
            if (overlap < 2 or overlap < row_count / 3) break;

            var y: usize = 0;
            while (y < overlap) : (y += 1) {
                const pin = viewportPin(term, @intCast(y)) orelse break;
                if (!self.rows.items[y + delta].matchesPin(pin)) break;
            }

            if (y == overlap and overlap > best_overlap) {
                best_delta = delta;
                best_overlap = overlap;
            }
        }

        return @intCast(best_delta);
    }

    fn rotateRegionScrollUp(self: *PaneRowCache, top: u16, visible_rows: u16, delta: u16) void {
        const start: usize = @min(@as(usize, @intCast(top)), self.rows.items.len);
        const available = self.rows.items.len - start;
        const row_count: usize = @min(@as(usize, @intCast(visible_rows)), available);
        const shift: usize = @intCast(delta);
        if (shift == 0 or shift >= row_count) return;

        const region = self.rows.items[start .. start + row_count];
        rotateLeft(ViewportRow, region, shift);
        for (region[row_count - shift .. row_count]) |*row| {
            row.valid = false;
        }
    }

    fn appendRow(
        self: *PaneRowCache,
        alloc: std.mem.Allocator,
        term: *vt.Terminal,
        y: u16,
        full_render: bool,
        out: *std.ArrayList(u8),
    ) !void {
        try self.ensure(alloc, term.rows);
        const pin = viewportPin(term, y) orelse {
            if (y < self.rows.items.len) self.rows.items[y].valid = false;
            return;
        };
        const entry = &self.rows.items[y];
        if (viewportRowReusable(entry, pin, full_render)) {
            try out.appendSlice(alloc, entry.bytes.items);
            return;
        }

        entry.bytes.clearRetainingCapacity();
        try appendTermRow(alloc, term, y, &entry.bytes);
        entry.capturePin(pin);
        try out.appendSlice(alloc, entry.bytes.items);
    }
};

const PaneId = enum(u1) {
    main = 0,
    split = 1,
};

const GraphicsState = struct {
    uploaded: std.AutoHashMapUnmanaged(u64, UploadedImage) = .{},
    next_outer_id: u32 = outer_image_id_start,

    const UploadedImage = struct {
        outer_id: u32,
        len: usize,
        width: u32,
        height: u32,
        format_code: u32,
    };

    fn deinit(self: *GraphicsState, alloc: std.mem.Allocator) void {
        self.uploaded.deinit(alloc);
    }

    fn deleteAll(self: *GraphicsState, alloc: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        if (comptime !kitty_graphics_enabled) {
            return;
        }

        var iter = self.uploaded.iterator();
        while (iter.next()) |entry| {
            try emitDeleteImage(alloc, out, entry.value_ptr.outer_id);
        }
        self.uploaded.clearRetainingCapacity();
    }

    fn needsUpdate(self: *GraphicsState, main_pane: *Pane, split_pane: ?*Pane) bool {
        if (comptime !kitty_graphics_enabled) return false;
        if (self.paneNeedsUpdate(main_pane)) return true;
        if (split_pane) |pane| {
            if (self.paneNeedsUpdate(pane)) return true;
        }
        return false;
    }

    fn paneNeedsUpdate(self: *GraphicsState, pane: *Pane) bool {
        const storage = &pane.term.screens.active.kitty_images;
        if (!storage.dirty) return false;
        return self.uploaded.count() != 0 or storage.placements.count() != 0;
    }

    fn render(
        self: *GraphicsState,
        alloc: std.mem.Allocator,
        out: *std.ArrayList(u8),
        layout: Layout,
        main_pane: *Pane,
        split_pane: ?*Pane,
        force: bool,
    ) !void {
        if (comptime !kitty_graphics_enabled) {
            return;
        }

        const update = force or self.needsUpdate(main_pane, split_pane);
        if (!update) return;

        // Scrolling marks Kitty placements dirty. Keep image payloads cached and
        // refresh only placements unless the whole composed screen is rebuilt.
        if (force) {
            try self.deleteAll(alloc, out);
        } else {
            try self.deletePlacements(alloc, out);
        }

        try self.renderPane(alloc, out, .main, main_pane, 0);
        main_pane.term.screens.active.kitty_images.dirty = false;
        if (layout.split_visible) {
            if (split_pane) |pane| {
                try self.renderPane(alloc, out, .split, pane, layout.splitTop());
                pane.term.screens.active.kitty_images.dirty = false;
            }
        }
    }

    fn deletePlacements(self: *GraphicsState, alloc: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        var iter = self.uploaded.iterator();
        while (iter.next()) |entry| {
            try emitDeletePlacements(alloc, out, entry.value_ptr.outer_id);
        }
    }

    fn renderPane(
        self: *GraphicsState,
        alloc: std.mem.Allocator,
        out: *std.ArrayList(u8),
        pane_id: PaneId,
        pane: *Pane,
        origin_row: u16,
    ) !void {
        const storage = &pane.term.screens.active.kitty_images;
        const screen = pane.term.screens.active;
        const viewport_tl_pin = screen.pages.pin(.{ .viewport = .{ .x = 0, .y = 0 } }) orelse return;
        const viewport_tl = (screen.pages.pointFromPin(.screen, viewport_tl_pin) orelse return).screen;

        var placement_seq: u32 = 1;
        var iter = storage.placements.iterator();
        while (iter.next()) |entry| : (placement_seq +%= 1) {
            const image = storage.images.get(entry.key_ptr.image_id) orelse continue;
            const outer_id = try self.ensureImage(alloc, out, pane_id, image) orelse continue;
            const request = placementRequest(pane, image, entry.value_ptr.*, viewport_tl, origin_row, placement_seq) orelse continue;
            try emitPlacement(alloc, out, outer_id, request);
        }
    }

    fn ensureImage(
        self: *GraphicsState,
        alloc: std.mem.Allocator,
        out: *std.ArrayList(u8),
        pane_id: PaneId,
        image: anytype,
    ) !?u32 {
        const format_code = imageFormatCode(image) orelse return null;
        const key = imageMapKey(pane_id, image.id);
        const existing = self.uploaded.getPtr(key);
        if (existing) |entry| {
            if (entry.len == image.data.len and
                entry.width == image.width and
                entry.height == image.height and
                entry.format_code == format_code)
            {
                return entry.outer_id;
            }
            try emitDeleteImage(alloc, out, entry.outer_id);
            try emitImageUpload(alloc, out, entry.outer_id, image, format_code);
            entry.* = .{
                .outer_id = entry.outer_id,
                .len = image.data.len,
                .width = image.width,
                .height = image.height,
                .format_code = format_code,
            };
            return entry.outer_id;
        }

        const outer_id = self.next_outer_id;
        self.next_outer_id +%= 1;
        if (self.next_outer_id == 0) self.next_outer_id = outer_image_id_start;
        try emitImageUpload(alloc, out, outer_id, image, format_code);
        try self.uploaded.put(alloc, key, .{
            .outer_id = outer_id,
            .len = image.data.len,
            .width = image.width,
            .height = image.height,
            .format_code = format_code,
        });
        return outer_id;
    }
};

const PlacementRequest = struct {
    row: u32,
    col: u32,
    placement_id: u32,
    source_x: u32,
    source_y: u32,
    source_width: u32,
    source_height: u32,
    x_offset: u32,
    y_offset: u32,
    columns: u32,
    rows: u32,
    z: i32,
};

fn imageMapKey(pane_id: PaneId, image_id: u32) u64 {
    return (@as(u64, @intFromEnum(pane_id)) << 32) | image_id;
}

fn imageFormatCode(image: anytype) ?u32 {
    return switch (image.format) {
        .rgb => 24,
        .rgba => 32,
        else => null,
    };
}

fn placementRequest(
    pane: *Pane,
    image: anytype,
    placement: anytype,
    viewport_tl: anytype,
    origin_row: u16,
    placement_id: u32,
) ?PlacementRequest {
    switch (placement.location) {
        .pin => |pin| if (pin.garbage) return null,
        .virtual => return null,
    }

    const rect = placement.rect(image, &pane.term) orelse return null;
    const rect_tl = (pane.term.screens.active.pages.pointFromPin(.screen, rect.top_left) orelse return null).screen;
    const pixel_size = placement.pixelSize(image, &pane.term);
    const grid_size = placement.gridSize(image, &pane.term);
    if (pixel_size.width == 0 or pixel_size.height == 0 or grid_size.cols == 0 or grid_size.rows == 0) return null;

    var row: i64 = @as(i64, rect_tl.y) - @as(i64, viewport_tl.y);
    var col: i64 = @as(i64, rect_tl.x) - @as(i64, viewport_tl.x);
    var rows: u32 = grid_size.rows;
    var cols: u32 = grid_size.cols;
    var source_x = @min(placement.source_x, image.width);
    var source_y = @min(placement.source_y, image.height);
    var source_width = if (placement.source_width > 0)
        @min(placement.source_width, image.width - source_x)
    else
        image.width - source_x;
    var source_height = if (placement.source_height > 0)
        @min(placement.source_height, image.height - source_y)
    else
        image.height - source_y;
    if (source_width == 0 or source_height == 0) return null;

    if (row < 0) {
        const skipped: u32 = @intCast(@min(@as(i64, rows), -row));
        const skipped_px = skipped * pane.cell_size.height;
        const skipped_source = scaledSourceDelta(skipped_px, pixel_size.height, source_height);
        source_y += skipped_source;
        source_height -|= skipped_source;
        rows -= skipped;
        row = 0;
    }
    if (col < 0) {
        const skipped: u32 = @intCast(@min(@as(i64, cols), -col));
        const skipped_px = skipped * pane.cell_size.width;
        const skipped_source = scaledSourceDelta(skipped_px, pixel_size.width, source_width);
        source_x += skipped_source;
        source_width -|= skipped_source;
        cols -= skipped;
        col = 0;
    }
    if (row >= pane.term.rows or col >= pane.term.cols or rows == 0 or cols == 0) return null;

    const visible_rows = @as(u32, pane.term.rows) - @as(u32, @intCast(row));
    const visible_cols = @as(u32, pane.term.cols) - @as(u32, @intCast(col));
    if (rows > visible_rows) {
        const clipped_rows = rows - visible_rows;
        const clipped_px = clipped_rows * pane.cell_size.height;
        source_height -|= scaledSourceDelta(clipped_px, pixel_size.height, source_height);
        rows = visible_rows;
    }
    if (cols > visible_cols) {
        const clipped_cols = cols - visible_cols;
        const clipped_px = clipped_cols * pane.cell_size.width;
        source_width -|= scaledSourceDelta(clipped_px, pixel_size.width, source_width);
        cols = visible_cols;
    }
    if (source_width == 0 or source_height == 0 or rows == 0 or cols == 0) return null;

    return .{
        .row = @as(u32, origin_row) + @as(u32, @intCast(row)),
        .col = @intCast(col),
        .placement_id = placement_id,
        .source_x = source_x,
        .source_y = source_y,
        .source_width = source_width,
        .source_height = source_height,
        .x_offset = placement.x_offset,
        .y_offset = placement.y_offset,
        .columns = cols,
        .rows = rows,
        .z = placement.z,
    };
}

fn scaledSourceDelta(pixel_delta: u32, total_pixels: u32, source_length: u32) u32 {
    if (pixel_delta == 0 or total_pixels == 0 or source_length == 0) return 0;
    return @min(@as(u32, @intCast((@as(u64, pixel_delta) * source_length) / total_pixels)), source_length);
}

const ImageReference = union(enum) {
    id: u32,
    number: u32,
};

fn emitImageUploadReferenced(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    reference: ImageReference,
    image: anytype,
    format_code: u32,
) !void {
    if (image.data.len == 0) return;
    const reference_key: u8, const reference_value: u32 = switch (reference) {
        .id => |value| .{ 'i', value },
        .number => |value| .{ 'I', value },
    };
    var offset: usize = 0;
    while (offset < image.data.len) {
        const remaining = image.data.len - offset;
        const chunk_len = @min(kitty_upload_chunk_bytes, remaining);
        const end = offset + chunk_len;
        const more = end < image.data.len;
        const chunk = image.data[offset..end];
        const encoded_len = std.base64.standard.Encoder.calcSize(chunk.len);
        const encoded = try alloc.alloc(u8, encoded_len);
        defer alloc.free(encoded);
        _ = std.base64.standard.Encoder.encode(encoded, chunk);

        if (offset == 0) {
            if (more) {
                try out.print(
                    alloc,
                    "\x1b_Ga=t,t=d,f={d},s={d},v={d},{c}={d},m=1,q=2;{s}\x1b\\",
                    .{ format_code, image.width, image.height, reference_key, reference_value, encoded },
                );
            } else {
                try out.print(
                    alloc,
                    "\x1b_Ga=t,t=d,f={d},s={d},v={d},{c}={d},q=2;{s}\x1b\\",
                    .{ format_code, image.width, image.height, reference_key, reference_value, encoded },
                );
            }
        } else {
            try out.print(
                alloc,
                "\x1b_Gm={d},q=2;{s}\x1b\\",
                .{ @intFromBool(more), encoded },
            );
        }

        offset = end;
    }
}

fn emitImageUpload(alloc: std.mem.Allocator, out: *std.ArrayList(u8), outer_id: u32, image: anytype, format_code: u32) !void {
    try emitImageUploadReferenced(alloc, out, .{ .id = outer_id }, image, format_code);
}

fn emitPlacementReferenced(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    reference: ImageReference,
    request: PlacementRequest,
) !void {
    const reference_key: u8, const reference_value: u32 = switch (reference) {
        .id => |value| .{ 'i', value },
        .number => |value| .{ 'I', value },
    };
    try out.print(
        alloc,
        "\x1b[{d};{d}H\x1b_Ga=p,{c}={d},p={d},x={d},y={d},w={d},h={d},X={d},Y={d},c={d},r={d},z={d},C=1,q=2;\x1b\\",
        .{
            request.row + 1,
            request.col + 1,
            reference_key,
            reference_value,
            request.placement_id,
            request.source_x,
            request.source_y,
            request.source_width,
            request.source_height,
            request.x_offset,
            request.y_offset,
            request.columns,
            request.rows,
            request.z,
        },
    );
}

fn emitPlacement(alloc: std.mem.Allocator, out: *std.ArrayList(u8), outer_id: u32, request: PlacementRequest) !void {
    try emitPlacementReferenced(alloc, out, .{ .id = outer_id }, request);
}

fn emitDeleteImage(alloc: std.mem.Allocator, out: *std.ArrayList(u8), outer_id: u32) !void {
    try out.print(alloc, "\x1b_Ga=d,d=I,i={d},q=2;\x1b\\", .{outer_id});
}

fn emitDeletePlacements(alloc: std.mem.Allocator, out: *std.ArrayList(u8), outer_id: u32) !void {
    try out.print(alloc, "\x1b_Ga=d,d=i,i={d},q=2;\x1b\\", .{outer_id});
}

fn emitDeletePlacementAt(alloc: std.mem.Allocator, out: *std.ArrayList(u8), row: u32, col: u32) !void {
    try out.print(
        alloc,
        "\x1b_Ga=d,d=p,x={d},y={d},q=2;\x1b\\",
        .{ col + 1, row + 1 },
    );
}

fn rawImageReference(image: anytype) ?ImageReference {
    if (image.number != 0) return .{ .number = image.number };
    if (image.implicit_id) return null;
    if (image.id != 0) return .{ .id = image.id };
    return null;
}

fn rawRestoreImageReference(storage: anytype, image: anytype) ImageReference {
    if (image.number != 0) {
        const newest = storage.imageByNumber(image.number) orelse return .{ .id = image.id };
        if (newest.id == image.id) return .{ .number = image.number };
    }
    return .{ .id = image.id };
}

fn emitDeleteImageReferenced(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    reference: ImageReference,
) !void {
    switch (reference) {
        .id => |value| try out.print(alloc, "\x1b_Ga=d,d=I,i={d},q=2;\x1b\\", .{value}),
        .number => |value| try out.print(alloc, "\x1b_Ga=d,d=N,I={d},q=2;\x1b\\", .{value}),
    }
}

const RawGraphicsOwnership = struct {
    references: std.AutoHashMapUnmanaged(u32, ImageReference) = .{},

    fn deinit(self: *RawGraphicsOwnership, alloc: std.mem.Allocator) void {
        self.references.deinit(alloc);
    }

    fn clear(self: *RawGraphicsOwnership) void {
        self.references.clearRetainingCapacity();
    }

    fn capture(
        self: *RawGraphicsOwnership,
        alloc: std.mem.Allocator,
        pane: *Pane,
    ) !void {
        self.clear();
        if (comptime !kitty_graphics_enabled) return;
        const storage = &pane.term.screens.active.kitty_images;
        var iter = storage.images.iterator();
        while (iter.next()) |entry| {
            try self.references.put(
                alloc,
                entry.key_ptr.*,
                rawRestoreImageReference(storage, entry.value_ptr.*),
            );
        }
    }
};

fn rawPlacementId(key: anytype) u32 {
    return switch (key.placement_id.tag) {
        .internal => 0,
        .external => key.placement_id.id,
    };
}

fn appendRawGraphicsRemoval(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    pane: *Pane,
    ownership: *const RawGraphicsOwnership,
) !bool {
    if (comptime !kitty_graphics_enabled) return false;
    const storage = &pane.term.screens.active.kitty_images;
    var emitted = false;
    var owned_iter = ownership.references.iterator();
    while (owned_iter.next()) |entry| {
        try emitDeleteImageReferenced(alloc, out, entry.value_ptr.*);
        emitted = true;
    }

    var image_iter = storage.images.iterator();
    while (image_iter.next()) |entry| {
        if (ownership.references.contains(entry.key_ptr.*)) continue;
        const reference = rawImageReference(entry.value_ptr.*) orelse continue;
        try emitDeleteImageReferenced(alloc, out, reference);
        emitted = true;
    }

    const screen = pane.term.screens.active;
    const viewport_tl_pin = screen.pages.pin(.{ .viewport = .{ .x = 0, .y = 0 } }) orelse return emitted;
    const viewport_tl = (screen.pages.pointFromPin(.screen, viewport_tl_pin) orelse return emitted).screen;
    var iter = storage.placements.iterator();
    while (iter.next()) |entry| {
        const image = storage.images.get(entry.key_ptr.image_id) orelse continue;
        if (ownership.references.contains(entry.key_ptr.image_id)) continue;
        // Stable application references can remove both the placements and
        // payload exactly. Implicit IDs may differ between our shadow model
        // and the outer terminal, so remove their visible placement by cell.
        if (rawImageReference(image) != null) continue;
        const request = placementRequest(
            pane,
            image,
            entry.value_ptr.*,
            viewport_tl,
            0,
            rawPlacementId(entry.key_ptr.*),
        ) orelse continue;
        try emitDeletePlacementAt(alloc, out, request.row, request.col);
        emitted = true;
    }
    return emitted;
}

fn appendRawGraphicsRestore(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    pane: *Pane,
) !void {
    if (comptime !kitty_graphics_enabled) return;
    const storage = &pane.term.screens.active.kitty_images;

    // Image numbers resolve to the newest transmission. Preserve that
    // ordering when rebuilding the app-owned outer-terminal image state.
    var image_ids: std.ArrayList(u32) = .empty;
    defer image_ids.deinit(alloc);
    var image_iter = storage.images.iterator();
    while (image_iter.next()) |entry| {
        var insert_at = image_ids.items.len;
        while (insert_at > 0) {
            const previous = storage.images.get(image_ids.items[insert_at - 1]) orelse break;
            if (previous.generation <= entry.value_ptr.generation) break;
            insert_at -= 1;
        }
        try image_ids.insert(alloc, insert_at, entry.key_ptr.*);
    }
    for (image_ids.items) |image_id| {
        const image = storage.images.get(image_id) orelse continue;
        const format_code = imageFormatCode(image) orelse continue;
        const reference = rawRestoreImageReference(storage, image);
        try emitImageUploadReferenced(alloc, out, reference, image, format_code);
    }

    const screen = pane.term.screens.active;
    const viewport_tl_pin = screen.pages.pin(.{ .viewport = .{ .x = 0, .y = 0 } }) orelse return;
    const viewport_tl = (screen.pages.pointFromPin(.screen, viewport_tl_pin) orelse return).screen;
    var placement_iter = storage.placements.iterator();
    while (placement_iter.next()) |entry| {
        const image = storage.images.get(entry.key_ptr.image_id) orelse continue;
        const request = placementRequest(
            pane,
            image,
            entry.value_ptr.*,
            viewport_tl,
            0,
            rawPlacementId(entry.key_ptr.*),
        ) orelse continue;
        const reference = rawRestoreImageReference(storage, image);
        try emitPlacementReferenced(alloc, out, reference, request);
    }
}

const Compositor = struct {
    alloc: std.mem.Allocator,
    row_cache: std.ArrayList(std.ArrayList(u8)) = .empty,
    main_rows: PaneRowCache = .{},
    split_rows: PaneRowCache = .{},
    primary_graphics: GraphicsState = .{},
    alternate_graphics: GraphicsState = .{},
    body: std.ArrayList(u8) = .empty,
    scratch: std.ArrayList(u8) = .empty,
    frame: std.ArrayList(u8) = .empty,
    cursor_scratch: std.ArrayList(u8) = .empty,
    last_cursor_state: std.ArrayList(u8) = .empty,
    cursor_valid: bool = false,
    full_render: bool = true,

    fn deinit(self: *Compositor) void {
        for (self.row_cache.items) |*row| row.deinit(self.alloc);
        self.row_cache.deinit(self.alloc);
        self.main_rows.deinit(self.alloc);
        self.split_rows.deinit(self.alloc);
        self.primary_graphics.deinit(self.alloc);
        self.alternate_graphics.deinit(self.alloc);
        self.body.deinit(self.alloc);
        self.scratch.deinit(self.alloc);
        self.frame.deinit(self.alloc);
        self.cursor_scratch.deinit(self.alloc);
        self.last_cursor_state.deinit(self.alloc);
    }

    fn invalidate(self: *Compositor) void {
        self.full_render = true;
        self.cursor_valid = false;
        for (self.main_rows.rows.items) |*row| row.valid = false;
        for (self.split_rows.rows.items) |*row| row.valid = false;
    }

    fn graphicsFor(self: *Compositor, key: vt.ScreenSet.Key) *GraphicsState {
        return switch (key) {
            .primary => &self.primary_graphics,
            .alternate => &self.alternate_graphics,
        };
    }

    fn render(
        self: *Compositor,
        layout: Layout,
        main_pane: *Pane,
        split_pane: ?*Pane,
        include_graphics: bool,
    ) !void {
        while (self.row_cache.items.len < layout.rows) try self.row_cache.append(self.alloc, .empty);
        while (self.row_cache.items.len > layout.rows) {
            var row = self.row_cache.pop() orelse break;
            row.deinit(self.alloc);
        }

        self.body.clearRetainingCapacity();
        self.scratch.clearRetainingCapacity();

        self.cursor_scratch.clearRetainingCapacity();
        {
            var aw: std.Io.Writer.Allocating = .fromArrayList(self.alloc, &self.cursor_scratch);
            defer self.cursor_scratch = aw.toArrayList();
            try writeComposedCursor(&aw.writer, layout, main_pane);
        }
        const cursor_state = self.cursor_scratch.items;
        const cursor_changed = !self.cursor_valid or
            !std.mem.eql(u8, self.last_cursor_state.items, cursor_state);
        const graphics = self.graphicsFor(main_pane.term.screens.active_key);
        const graphics_dirty = include_graphics and (self.full_render or graphics.needsUpdate(main_pane, split_pane));

        // Composed mode is a pure absolute repaint. Never mutate the outer
        // terminal with a scroll prediction: a single false positive shifts
        // unrelated rows and cannot be repaired by later row diffs.
        _ = main_pane.takePendingScrolls();
        if (split_pane) |pane| _ = pane.takePendingScrolls();
        try self.main_rows.ensure(self.alloc, main_pane.term.rows);

        if (split_pane) |pane| {
            try self.split_rows.ensure(self.alloc, pane.term.rows);
        }

        for (0..layout.rows) |row_index| {
            self.scratch.clearRetainingCapacity();
            try self.composeRow(layout, main_pane, split_pane, @intCast(row_index), &self.scratch);
            const cache = &self.row_cache.items[row_index];
            if (!self.full_render and std.mem.eql(u8, cache.items, self.scratch.items)) continue;
            cache.clearRetainingCapacity();
            try cache.appendSlice(self.alloc, self.scratch.items);
            try self.body.print(self.alloc, "\x1b[{d};1H", .{row_index + 1});
            try self.body.appendSlice(self.alloc, self.scratch.items);
        }

        if (self.body.items.len > 0 or cursor_changed or graphics_dirty) {
            self.frame.clearRetainingCapacity();
            try self.frame.appendSlice(self.alloc, synchronized_update_begin);
            try self.frame.appendSlice(self.alloc, "\x1b[?25l");
            try self.frame.appendSlice(self.alloc, self.body.items);
            if (include_graphics) {
                try graphics.render(
                    self.alloc,
                    &self.frame,
                    layout,
                    main_pane,
                    split_pane,
                    self.full_render,
                );
            }
            try self.frame.appendSlice(self.alloc, cursor_state);
            try self.frame.appendSlice(self.alloc, synchronized_update_end);
            try outer_terminal.write(self.frame.items);
        }

        self.cursor_valid = true;
        self.last_cursor_state.clearRetainingCapacity();
        try self.last_cursor_state.appendSlice(self.alloc, cursor_state);
        main_pane.term.screens.active.pages.clearDirty();
        if (include_graphics) main_pane.term.screens.active.kitty_images.dirty = false;
        if (split_pane) |pane| {
            pane.term.screens.active.pages.clearDirty();
            if (include_graphics) pane.term.screens.active.kitty_images.dirty = false;
        }
        self.full_render = false;
    }

    fn canPaneScrollFastPath(
        self: *Compositor,
        graphics: *const GraphicsState,
        screen: vt.ScreenSet.Key,
        visible_rows: u16,
        graphics_dirty: bool,
    ) bool {
        _ = self;
        _ = graphics;
        _ = screen;
        _ = visible_rows;
        _ = graphics_dirty;
        return false;
    }

    fn applyPendingScrolls(
        self: *Compositor,
        cache: *PaneRowCache,
        screen: vt.ScreenSet.Key,
        outer_top: u16,
        pane_visible_rows: u16,
        pending: PendingScrollBatch,
    ) !void {
        if (pending.overflow) return;
        for (pending.items[0..pending.len]) |scroll| {
            if (scroll.screen != screen) continue;
            if (scroll.top >= pane_visible_rows or scroll.bottom >= pane_visible_rows) continue;
            const height = scroll.height();
            if (height < 2) continue;
            const delta: u16 = @intCast(@min(scroll.count, height));
            if (delta == 0 or delta >= height) continue;
            try self.emitScrollUp(outer_top + scroll.top, height, delta);
            self.rotateOuterRowsForRegion(outer_top + scroll.top, height, delta);
            cache.rotateRegionScrollUp(scroll.top, height, delta);
        }
    }

    fn emitScrollUp(self: *Compositor, top: u16, visible_rows: u16, delta: u16) !void {
        if (visible_rows == 0 or delta == 0) return;
        const first = top + 1;
        const last = top + visible_rows;
        try self.body.print(
            self.alloc,
            "\x1b[{d};{d}r\x1b[{d}S\x1b[r",
            .{ first, last, delta },
        );
    }

    fn rotateOuterRowsForRegion(self: *Compositor, top: u16, visible_rows: u16, delta: u16) void {
        const start: usize = @min(@as(usize, @intCast(top)), self.row_cache.items.len);
        const available = self.row_cache.items.len - start;
        const row_count: usize = @min(@as(usize, @intCast(visible_rows)), available);
        const shift: usize = @intCast(delta);
        if (shift == 0 or shift >= row_count) return;

        const region = self.row_cache.items[start .. start + row_count];
        rotateLeft(std.ArrayList(u8), region, shift);
        for (region[row_count - shift .. row_count]) |*row| {
            row.clearRetainingCapacity();
        }
    }

    fn composeRow(
        self: *Compositor,
        layout: Layout,
        main_pane: *Pane,
        split_pane: ?*Pane,
        y: u16,
        out: *std.ArrayList(u8),
    ) !void {
        try out.appendSlice(self.alloc, sgr_reset);
        try out.appendSlice(self.alloc, "\x1b[K");
        if (y < layout.main_rows) {
            try self.main_rows.appendRow(self.alloc, &main_pane.term, y, self.full_render, out);
        } else if (layout.border_row != null and y == layout.border_row.?) {
            try out.appendSlice(self.alloc, style_dim);
            for (0..layout.paneCols()) |_| try out.appendSlice(self.alloc, "─");
            try out.appendSlice(self.alloc, sgr_reset);
        } else if (split_pane) |pane| {
            const split_y = y - layout.splitTop();
            if (split_y < pane.term.rows) {
                try self.split_rows.appendRow(self.alloc, &pane.term, split_y, self.full_render, out);
            }
        }
        try self.appendScrollbarCell(layout, main_pane, split_pane, y, out);
        try out.appendSlice(self.alloc, sgr_reset);
    }

    fn appendScrollbarCell(
        self: *Compositor,
        layout: Layout,
        main_pane: *Pane,
        split_pane: ?*Pane,
        y: u16,
        out: *std.ArrayList(u8),
    ) !void {
        const col = layout.scrollbarCol() orelse return;
        const cell = scrollbarCell(layout, main_pane, split_pane, y) orelse return;
        try out.print(self.alloc, "\x1b[{d};{d}H", .{ y + 1, col });
        switch (cell) {
            .track => {
                try out.appendSlice(self.alloc, style_dim);
                try out.appendSlice(self.alloc, scrollbar_track);
            },
            .thumb => {
                try out.appendSlice(self.alloc, sgr_reset);
                try out.appendSlice(self.alloc, scrollbar_thumb);
            },
        }
    }
};

const ScrollbarCell = enum { track, thumb };

fn scrollbarCell(layout: Layout, main_pane: *Pane, split_pane: ?*Pane, y: u16) ?ScrollbarCell {
    if (!layout.scrollbarVisible()) return null;

    if (y < layout.main_rows) {
        return paneScrollbarCell(main_pane, y, layout.main_rows);
    }
    if (layout.border_row != null and y == layout.border_row.?) return .track;
    if (split_pane) |pane| {
        if (y >= layout.splitTop()) {
            const split_y = y - layout.splitTop();
            if (split_y < layout.split_rows) return paneScrollbarCell(pane, split_y, layout.split_rows);
        }
    }
    return null;
}

fn paneScrollbarCell(pane: *Pane, y: u16, track_len: u16) ScrollbarCell {
    const info = scrollbarInfo(pane, track_len) orelse return .track;
    return if (y >= info.thumb_start and y < info.thumb_start + info.thumb_len) .thumb else .track;
}

fn writeComposedCursor(writer: *std.Io.Writer, layout: Layout, pane: *Pane) !void {
    const screen = pane.term.screens.active;
    const cursor = &pane.term.screens.active.cursor;
    const point = screen.pages.pointFromPin(.viewport, cursor.page_pin.*) orelse {
        try writeHiddenCursorState(writer, &pane.term);
        return;
    };
    const viewport = point.viewport;
    if (viewport.y >= layout.main_rows or viewport.x >= layout.paneCols()) {
        try writeHiddenCursorState(writer, &pane.term);
        return;
    }
    try writePaneCursorState(writer, &pane.term, viewport.y, viewport.x);
}

fn writePaneCursorState(writer: *std.Io.Writer, term: *const vt.Terminal, row: usize, col: usize) !void {
    const cursor = &term.screens.active.cursor;
    try writeCursorStyle(writer, cursor.cursor_style, term.modes.get(.cursor_blinking));
    try writer.print("\x1b[{d};{d}H", .{ row + 1, col + 1 });
    try writer.writeAll(if (term.modes.get(.cursor_visible)) "\x1b[?25h" else "\x1b[?25l");
}

fn writeHiddenCursorState(writer: *std.Io.Writer, term: *const vt.Terminal) !void {
    const cursor = &term.screens.active.cursor;
    try writeCursorStyle(writer, cursor.cursor_style, term.modes.get(.cursor_blinking));
    try writer.writeAll("\x1b[?25l");
}

fn writeCursorStyle(writer: *std.Io.Writer, style: vt.Screen.CursorStyle, blinking: bool) !void {
    const code: u8 = switch (style) {
        .bar => if (blinking) 5 else 6,
        .block => if (blinking) 1 else 2,
        .underline => if (blinking) 3 else 4,
        .block_hollow => if (blinking) 1 else 2,
    };
    try writer.print("\x1b[{d} q", .{code});
}

const KittyKey = struct {
    codepoint: u21,
    modifiers: u16,
    len: usize,
};

fn parseKittyKey(input: []const u8) ?KittyKey {
    const max_len = 64;
    if (input.len < 4 or input[0] != 0x1b or input[1] != '[') return null;

    var end: usize = 2;
    while (end < input.len and end < max_len) : (end += 1) {
        const byte = input[end];
        if (byte == 'u') break;
        if (!std.ascii.isDigit(byte) and byte != ';' and byte != ':') return null;
    }
    if (end >= input.len or input[end] != 'u') return null;

    const body = input[2..end];
    if (body.len == 0) return null;

    var first_end = body.len;
    if (std.mem.indexOfAny(u8, body, ";:")) |idx| first_end = idx;
    if (first_end == 0) return null;

    const codepoint = std.fmt.parseUnsigned(u21, body[0..first_end], 10) catch return null;
    var modifiers: u16 = 1;
    if (first_end < body.len and body[first_end] == ';') {
        const rest = body[first_end + 1 ..];
        var second_end = rest.len;
        if (std.mem.indexOfAny(u8, rest, ";:")) |idx| second_end = idx;
        if (second_end > 0) {
            modifiers = std.fmt.parseUnsigned(u16, rest[0..second_end], 10) catch return null;
        }
    }

    return .{
        .codepoint = codepoint,
        .modifiers = modifiers,
        .len = end + 1,
    };
}

fn kittyModifiersIncludeCtrl(modifiers: u16) bool {
    return modifiers > 0 and ((modifiers - 1) & 4) != 0;
}

fn kittyKeyIsPrefix(key: KittyKey) bool {
    return kittyModifiersIncludeCtrl(key.modifiers) and
        (key.codepoint == 'b' or key.codepoint == 'B' or key.codepoint == 0x02);
}

fn kittyKeyCommand(key: KittyKey) ?u8 {
    if (key.modifiers != 1 or key.codepoint > std.math.maxInt(u8)) return null;
    return @intCast(key.codepoint);
}

fn parseModifyOtherKey(input: []const u8) ?KittyKey {
    const max_len = 64;
    if (input.len < 8 or !std.mem.startsWith(u8, input, "\x1b[27;")) return null;

    var end: usize = 5;
    while (end < input.len and end < max_len) : (end += 1) {
        const byte = input[end];
        if (byte == '~') break;
        if (!std.ascii.isDigit(byte) and byte != ';') return null;
    }
    if (end >= input.len or input[end] != '~') return null;

    var fields = std.mem.splitScalar(u8, input[5..end], ';');
    const modifiers_text = fields.next() orelse return null;
    const codepoint_text = fields.next() orelse return null;
    if (fields.next() != null or modifiers_text.len == 0 or codepoint_text.len == 0) return null;
    return .{
        .codepoint = std.fmt.parseUnsigned(u21, codepoint_text, 10) catch return null,
        .modifiers = std.fmt.parseUnsigned(u16, modifiers_text, 10) catch return null,
        .len = end + 1,
    };
}

const PrefixParser = struct {
    pending: bool = false,

    fn feed(self: *PrefixParser, alloc: std.mem.Allocator, input: []const u8) !PrefixResult {
        var result = PrefixResult{};
        var start: usize = 0;
        var i: usize = 0;
        while (i < input.len) {
            const byte = input[i];
            if (self.pending) {
                if (start < i) try result.forwarded.appendSlice(alloc, input[start..i]);
                self.pending = false;

                if (parseKittyKey(input[i..])) |key| {
                    if (kittyKeyCommand(key)) |command| {
                        try applyCommand(&result, alloc, command);
                        i += key.len;
                        start = i;
                        continue;
                    }
                }

                try applyCommand(&result, alloc, byte);
                i += 1;
                start = i;
                continue;
            }
            if (byte == 0x02) {
                if (start < i) try result.forwarded.appendSlice(alloc, input[start..i]);
                self.pending = true;
                i += 1;
                start = i;
                continue;
            }
            if (parseKittyKey(input[i..])) |key| {
                if (kittyKeyIsPrefix(key)) {
                    if (start < i) try result.forwarded.appendSlice(alloc, input[start..i]);
                    self.pending = true;
                    i += key.len;
                    start = i;
                    continue;
                }
            }
            if (parseModifyOtherKey(input[i..])) |key| {
                if (kittyKeyIsPrefix(key)) {
                    if (start < i) try result.forwarded.appendSlice(alloc, input[start..i]);
                    self.pending = true;
                    i += key.len;
                    start = i;
                    continue;
                }
            }
            i += 1;
        }
        if (start < input.len) try result.forwarded.appendSlice(alloc, input[start..]);
        return result;
    }

    fn applyCommand(result: *PrefixResult, alloc: std.mem.Allocator, byte: u8) !void {
        switch (byte) {
            'x' => result.close_split = true,
            's' => result.open_split = true,
            'b' => try result.forwarded.append(alloc, 0x02),
            else => {
                try result.forwarded.append(alloc, 0x02);
                try result.forwarded.append(alloc, byte);
            },
        }
    }

    fn flush(self: *PrefixParser, alloc: std.mem.Allocator) !?[]u8 {
        if (!self.pending) return null;
        self.pending = false;
        return try alloc.dupe(u8, &.{0x02});
    }
};

const PrefixResult = struct {
    forwarded: std.ArrayList(u8) = .empty,
    close_split: bool = false,
    open_split: bool = false,

    fn deinit(self: *PrefixResult, alloc: std.mem.Allocator) void {
        self.forwarded.deinit(alloc);
    }
};

const mouse_modifier_mask: u16 = 4 | 8 | 16;
const mouse_motion_mask: u16 = 32;

const WheelAction = enum { up, down, left, right };

const SgrMouseEvent = struct {
    cb: u16,
    x: u16,
    y: u16,
    final: u8,
    len: usize,

    fn baseButton(self: SgrMouseEvent) u16 {
        return self.cb & ~(mouse_modifier_mask | mouse_motion_mask);
    }

    fn isRelease(self: SgrMouseEvent) bool {
        return self.final == 'm';
    }

    fn isMotion(self: SgrMouseEvent) bool {
        return self.final == 'M' and (self.cb & mouse_motion_mask) != 0;
    }

    fn isPrimaryPress(self: SgrMouseEvent) bool {
        return self.final == 'M' and !self.isMotion() and self.baseButton() == 0;
    }

    fn wheelAction(self: SgrMouseEvent) ?WheelAction {
        return switch (self.baseButton()) {
            64 => .up,
            65 => .down,
            66 => .left,
            67 => .right,
            else => null,
        };
    }
};

const SgrMouseParseResult = union(enum) {
    none,
    incomplete,
    event: SgrMouseEvent,
};

fn parseSgrMouse(input: []const u8) SgrMouseParseResult {
    const prefix = "\x1b[<";
    if (input.len == 0) return .none;
    if (input.len < prefix.len) return .none;
    if (!std.mem.eql(u8, input[0..prefix.len], prefix)) return .none;
    if (input.len > max_sgr_mouse_sequence) return .none;

    var i: usize = prefix.len;
    const cb = parseSgrMouseNumber(input, &i) orelse return if (i == input.len) .incomplete else .none;
    if (i >= input.len) return .incomplete;
    if (input[i] != ';') return .none;
    i += 1;

    const x = parseSgrMouseNumber(input, &i) orelse return if (i == input.len) .incomplete else .none;
    if (i >= input.len) return .incomplete;
    if (input[i] != ';') return .none;
    i += 1;

    const y = parseSgrMouseNumber(input, &i) orelse return if (i == input.len) .incomplete else .none;
    if (i >= input.len) return .incomplete;
    const final = input[i];
    if (final != 'M' and final != 'm') return .none;

    return .{ .event = .{
        .cb = cb,
        .x = x,
        .y = y,
        .final = final,
        .len = i + 1,
    } };
}

fn parseSgrMouseNumber(input: []const u8, index: *usize) ?u16 {
    const start = index.*;
    var value: u32 = 0;
    while (index.* < input.len and std.ascii.isDigit(input[index.*])) : (index.* += 1) {
        value = value * 10 + (input[index.*] - '0');
        if (value > std.math.maxInt(u16)) return null;
    }
    if (index.* == start) return null;
    return @intCast(value);
}

const MousePaneHit = struct {
    pane: PaneId,
    x: u16,
    y: u16,
};

const ScrollbarHit = struct {
    pane: PaneId,
    y: u16,
    track_len: u16,
};

const MouseHit = union(enum) {
    pane: MousePaneHit,
    scrollbar: ScrollbarHit,
    border,
    outside,
};

fn hitTestMouse(layout: Layout, split_available: bool, x: u16, y: u16) MouseHit {
    if (x < 1 or y < 1 or x > layout.cols or y > layout.rows) return .outside;
    const pane_cols = layout.paneCols();
    if (y <= layout.main_rows) {
        if (layout.scrollbarCol()) |col| {
            if (x == col) return .{ .scrollbar = .{ .pane = .main, .y = y, .track_len = layout.main_rows } };
        }
        if (x <= pane_cols) return .{ .pane = .{ .pane = .main, .x = x, .y = y } };
        return .outside;
    }
    if (layout.border_row) |border_row| {
        if (y == border_row + 1) return .border;
    }
    if (layout.split_visible and split_available and y > layout.splitTop()) {
        const local_y = y - layout.splitTop();
        if (local_y >= 1 and local_y <= layout.split_rows) {
            if (layout.scrollbarCol()) |col| {
                if (x == col) return .{ .scrollbar = .{ .pane = .split, .y = local_y, .track_len = layout.split_rows } };
            }
            if (x <= pane_cols) return .{ .pane = .{ .pane = .split, .x = x, .y = local_y } };
            return .outside;
        }
    }
    return .outside;
}

const ScrollbarInfo = struct {
    total: usize,
    offset: usize,
    len: usize,
    track_len: u16,
    thumb_start: u16,
    thumb_len: u16,
    max_offset: usize,
    max_thumb_start: u16,
};

fn scrollbarInfo(pane: *Pane, track_len: u16) ?ScrollbarInfo {
    if (track_len == 0) return null;
    const scrollbar = pane.term.screens.active.pages.scrollbar();
    if (scrollbar.total == 0 or scrollbar.len == 0) return null;

    const total = @max(scrollbar.total, scrollbar.len);
    const len = @min(scrollbar.len, total);
    const max_offset = total - len;
    const track: usize = @intCast(track_len);
    const thumb_raw = @max(@divTrunc(track * len, total), 1);
    const thumb_len: u16 = @intCast(@min(thumb_raw, track));
    const max_thumb_start = track_len - thumb_len;
    const thumb_start: u16 = if (max_offset == 0 or max_thumb_start == 0)
        0
    else
        @intCast(@min(@divTrunc(scrollbar.offset * @as(usize, @intCast(max_thumb_start)), max_offset), @as(usize, @intCast(max_thumb_start))));

    return .{
        .total = total,
        .offset = @min(scrollbar.offset, max_offset),
        .len = len,
        .track_len = track_len,
        .thumb_start = thumb_start,
        .thumb_len = thumb_len,
        .max_offset = max_offset,
        .max_thumb_start = max_thumb_start,
    };
}

fn scrollbarTargetOffset(info: ScrollbarInfo, local_y: u16, grab_offset: u16) usize {
    if (info.max_offset == 0 or info.max_thumb_start == 0) return 0;
    const bounded_y = @min(@max(local_y, 1), info.track_len);
    const local0: usize = @as(usize, @intCast(bounded_y)) - 1;
    const grab = @min(@as(usize, @intCast(grab_offset)), local0);
    const desired = @min(local0 - grab, @as(usize, @intCast(info.max_thumb_start)));
    return @divTrunc(desired * info.max_offset + @divTrunc(@as(usize, @intCast(info.max_thumb_start)), 2), @as(usize, @intCast(info.max_thumb_start)));
}

fn encodeMouseForPane(writer: *std.Io.Writer, pane: *const Pane, event: SgrMouseEvent, x: u16, y: u16) !void {
    switch (pane.term.flags.mouse_format) {
        .x10 => try encodeX10Mouse(writer, event, x, y),
        .urxvt => try writer.print("\x1b[{d};{d};{d}M", .{ 32 + event.cb, x, y }),
        .utf8, .sgr, .sgr_pixels => try encodeSgrMouse(writer, event, x, y),
    }
}

fn encodeSgrMouse(writer: *std.Io.Writer, event: SgrMouseEvent, x: u16, y: u16) !void {
    try writer.print("\x1b[<{d};{d};{d}{c}", .{ event.cb, x, y, event.final });
}

fn encodeX10Mouse(writer: *std.Io.Writer, event: SgrMouseEvent, x: u16, y: u16) !void {
    const cb: u16 = if (event.final == 'm') 3 else event.cb;
    if (cb > 223 or x > 223 or y > 223) {
        return encodeSgrMouse(writer, event, x, y);
    }
    try writer.writeAll("\x1b[M");
    try writer.writeByte(32 + @as(u8, @intCast(cb)));
    try writer.writeByte(32 + @as(u8, @intCast(x)));
    try writer.writeByte(32 + @as(u8, @intCast(y)));
}

const ScrollbarDrag = struct {
    pane: PaneId,
    track_top: u16,
    track_len: u16,
    grab_offset: u16,
};

const App = struct {
    alloc: std.mem.Allocator,
    config: Config,
    layout: Layout,
    main_pane: *Pane,
    split_pane: ?*Pane,
    split_autoclose: bool = false,
    split_generation: ?u64 = null,
    next_split_generation: u64 = 1,
    raw_terminal: RawTerminal,
    compositor: Compositor,
    render_scheduler: RenderScheduler = .{},
    prefix: PrefixParser = .{},
    input_buffer: std.ArrayList(u8) = .empty,
    deferred_main_state: std.ArrayList(u8) = .empty,
    deferred_main_offset: usize = 0,
    deferred_catchup_due_ns: ?i128 = null,
    screen_switch_mirror: ScreenSwitchMirror = .{},
    host_effect_mirror: HostEffectMirror = .{},
    raw_control_scanner: RawControlScanner = .{},
    outer_input_filter: OuterInputFilter = .{},
    outer_input_protocol: OuterInputProtocol = .{},
    deferred_outer_reports: std.ArrayList(DeferredOuterReportDelivery) = .empty,
    pending_color_queries: std.ArrayList(PendingColorQuery) = .empty,
    deferred_outer_report_due_ns: ?i128 = null,
    outer_primary_touched: bool = false,
    outer_alternate_touched: bool = false,
    outer_primary_graphics: RawGraphicsOwnership = .{},
    outer_alternate_graphics: RawGraphicsOwnership = .{},
    direct_main_painted_bytes: usize = 0,
    main_passthrough_cursor: PlainCursorState = .{},
    main_passthrough_outer_active: bool = false,
    scrollbar_drag: ?ScrollbarDrag = null,
    composed: bool,
    last_size: ptypkg.Winsize,
    active_split_rows: u16,
    pending_resize: ?ptypkg.Winsize = null,
    resize_due_ns: ?i128 = null,
    cell_size: CellSize,
    control_runtime: ?ControlRuntime = null,
    control_connections: std.ArrayList(ControlConnection) = .empty,
    terminal_restore_needed: bool = false,
    graphics_normalization_enabled: bool = false,

    fn init(alloc: std.mem.Allocator, config: Config) !App {
        var control_runtime: ?ControlRuntime = ControlRuntime.init(alloc) catch |err| blk: {
            var stderr = std.Io.File.stderr().writer(currentIo(), &.{});
            stderr.interface.print(
                "tinymux: control socket unavailable ({s}); continuing without pane control\n",
                .{@errorName(err)},
            ) catch {};
            break :blk null;
        };
        errdefer if (control_runtime) |*runtime| runtime.deinit(alloc);

        const outer_size = ptypkg.getSize(stdout_fd) catch ptypkg.makeWinsize(24, 80);
        const cell_size = CellSize.fromWinsize(outer_size);
        const split_visible = config.split_cmd != null;
        const layout = Layout.compute(outer_size.row, outer_size.col, split_visible, config.split_rows);
        const cwd = std.process.currentPathAlloc(currentIo(), alloc) catch null;
        defer if (cwd) |path| alloc.free(path);

        const outer_term = getenv("TERM");
        const colorterm = getenv("COLORTERM");
        var main_env = try currentEnvMap(alloc);
        defer main_env.deinit();
        if (!config.seamless) {
            const main_term = selectTerm(.auto, outer_term, colorterm);
            try main_env.put("TERM", main_term);
        }
        if (config.handoff_state) |state| {
            try main_env.put("TINYMUX_HANDOFF_STATE", state);
            try main_env.put("TINYMUX_SEAMLESS", "1");
        }
        try applyTinymuxEnv(
            alloc,
            &main_env,
            if (control_runtime) |*runtime| runtime else null,
            config.kitty_compat,
            "1",
            if (config.session) .main_session else .nested_main,
        );
        const main_pane = try Pane.create(
            alloc,
            config.main_argv,
            &main_env,
            layout.main_rows,
            layout.paneCols(),
            cell_size,
            cwd,
        );
        errdefer main_pane.destroy();

        var split_pane: ?*Pane = null;
        if (config.split_cmd) |cmd| {
            var split_env = try cloneEnvMap(alloc, &main_env);
            defer split_env.deinit();
            try split_env.put("TERM", selectTerm(config.split_term, outer_term, colorterm));
            try applyTinymuxEnv(
                alloc,
                &split_env,
                if (control_runtime) |*runtime| runtime else null,
                config.kitty_compat,
                "2",
                .auxiliary,
            );
            const shell = getenv("SHELL") orelse "/bin/sh";
            const split_argv = [_][]const u8{ shell, "-lc", cmd };
            split_pane = try Pane.create(
                alloc,
                &split_argv,
                &split_env,
                @max(layout.split_rows, 1),
                layout.paneCols(),
                cell_size,
                cwd,
            );
        }

        var raw_terminal = try RawTerminal.enable(stdin_fd);
        errdefer raw_terminal.restore();

        return .{
            .alloc = alloc,
            .config = config,
            .layout = layout,
            .main_pane = main_pane,
            .split_pane = split_pane,
            .split_autoclose = false,
            .split_generation = if (split_pane != null) 1 else null,
            .next_split_generation = if (split_pane != null) 2 else 1,
            .raw_terminal = raw_terminal,
            .compositor = .{ .alloc = alloc },
            .render_scheduler = .{},
            .composed = split_visible,
            .last_size = outer_size,
            .active_split_rows = config.split_rows,
            .cell_size = cell_size,
            .control_runtime = control_runtime,
            .control_connections = .empty,
            .outer_input_protocol = .{ .state = .fromPane(main_pane) },
            .terminal_restore_needed = !config.seamless,
            .graphics_normalization_enabled = outerSupportsKittyGraphics(outer_term),
        };
    }

    fn deinit(self: *App) void {
        self.restoreOuterTerminal();
        self.raw_terminal.restore();
        if (self.split_pane) |pane| pane.destroy();
        self.main_pane.destroy();
        self.input_buffer.deinit(self.alloc);
        self.deferred_outer_reports.deinit(self.alloc);
        self.pending_color_queries.deinit(self.alloc);
        self.deferred_main_state.deinit(self.alloc);
        self.compositor.deinit();
        self.outer_primary_graphics.deinit(self.alloc);
        self.outer_alternate_graphics.deinit(self.alloc);
        for (self.control_connections.items) |*connection| connection.deinit(self.alloc);
        self.control_connections.deinit(self.alloc);
        if (self.control_runtime) |*runtime| runtime.deinit(self.alloc);
    }

    fn run(self: *App) !void {
        if (self.composed) {
            try self.beginOuterComposition();
            self.terminal_restore_needed = true;
            self.compositor.invalidate();
            try self.compositor.render(self.layout, self.main_pane, self.split_pane, true);
            self.render_scheduler.rendered(nanoTimestamp());
        }

        var running = true;
        while (running) {
            self.main_pane.reapIfExited();
            if (!self.main_pane.alive) {
                try self.drainMainForExit();
                break;
            }
            if (self.split_pane) |pane| pane.reapIfExited();
            try self.closeAutoSplitIfExited();

            try self.checkResize(nanoTimestamp());
            try self.flushRawControlIfDue(nanoTimestamp());
            try self.flushOuterInputIfDue(nanoTimestamp());

            var fds_storage: [4 + max_control_connections]posix.pollfd = undefined;
            var count: usize = 0;
            const stdin_index = count;
            fds_storage[count] = .{ .fd = stdin_fd, .events = posix.POLL.IN, .revents = 0 };
            count += 1;

            var control_index: ?usize = null;
            if (self.control_runtime) |*runtime| {
                control_index = count;
                fds_storage[count] = .{ .fd = runtime.server.socket.handle, .events = posix.POLL.IN, .revents = 0 };
                count += 1;
            }

            var main_index: ?usize = null;
            if (self.main_pane.pty_fd >= 0) {
                main_index = count;
                fds_storage[count] = .{ .fd = self.main_pane.pty_fd, .events = posix.POLL.IN, .revents = 0 };
                count += 1;
            }

            var split_index: ?usize = null;
            if (self.split_pane) |pane| {
                if (pane.pty_fd >= 0) {
                    split_index = count;
                    fds_storage[count] = .{ .fd = pane.pty_fd, .events = posix.POLL.IN, .revents = 0 };
                    count += 1;
                }
            }

            const control_connections_start = count;
            const polled_control_connections = self.control_connections.items.len;
            for (self.control_connections.items) |connection| {
                fds_storage[count] = .{
                    .fd = connection.fd,
                    .events = posix.POLL.IN,
                    .revents = 0,
                };
                count += 1;
            }

            const now = nanoTimestamp();
            const timeout = self.pollTimeoutMs(now);
            _ = try posix.poll(fds_storage[0..count], timeout);

            if (control_index) |index| {
                if (fds_storage[index].revents & posix.POLL.IN != 0) {
                    try self.acceptControlConnections();
                }
            }

            var control_offset = polled_control_connections;
            while (control_offset > 0) {
                control_offset -= 1;
                const poll_index = control_connections_start + control_offset;
                if (fds_storage[poll_index].revents != 0) {
                    try self.readControlConnection(control_offset);
                }
            }
            self.expireControlConnections(nanoTimestamp());

            if (fds_storage[stdin_index].revents & posix.POLL.IN != 0) {
                if (try self.readInput(&running)) {
                    self.render_scheduler.noteInput(nanoTimestamp());
                }
            }

            var pane_stats: DrainStats = .{};
            self.direct_main_painted_bytes = 0;
            if (main_index) |index| {
                if (fds_storage[index].revents != 0) {
                    pane_stats.record(try self.readPane(self.main_pane, .main));
                }
            }

            if (split_index) |index| {
                if (self.split_pane) |pane| {
                    if (fds_storage[index].revents != 0) {
                        pane_stats.record(try self.readPane(pane, .split));
                    }
                }
            }
            if (self.deferred_outer_reports.items.len > 0) {
                pane_stats.merge(try self.drainReadyPanes(interactive_pty_drain_budget_ns));
            }
            if (pane_stats.bytes > 0) {
                const drain_now = nanoTimestamp();
                pane_stats.merge(try self.drainReadyPanes(self.render_scheduler.ptyDrainBudget(drain_now, pane_stats)));
                if (self.composed) {
                    var model_stats = pane_stats;
                    model_stats.bytes -|= self.direct_main_painted_bytes;
                    if (model_stats.bytes == 0 and self.direct_main_painted_bytes >= pane_stats.bytes) {
                        model_stats.saturated = false;
                        model_stats.reads = 0;
                    }
                    if (model_stats.bytes > 0 or model_stats.saturated) {
                        if (self.direct_main_painted_bytes > 0) model_stats.reads = 1;
                        const damage_now = nanoTimestamp();
                        const kind = self.render_scheduler.dirtyKindForDamage(damage_now, model_stats);
                        self.render_scheduler.markDirty(kind);
                    }
                }
            }
            // Raw output wins the current turn. Catch the shadow model up on
            // the next otherwise-idle turn so sustained passthrough retains
            // direct-path throughput and interactive gaps still converge.
            if (pane_stats.bytes == 0) self.advanceDeferredMainState();
            if (try self.flushDeferredOuterReportsIfDue(nanoTimestamp())) {
                self.render_scheduler.noteInput(nanoTimestamp());
            }
            try self.closeAutoSplitIfExited();

            if (self.composed and
                (!pane_stats.saturated or self.render_scheduler.mustRenderUnderLoad(nanoTimestamp())))
            {
                try self.renderIfDue();
            }
        }
    }

    fn renderIfDue(self: *App) !void {
        if (!self.composed) return;
        const render_now = nanoTimestamp();
        if (!self.render_scheduler.shouldRender(render_now)) return;
        try self.endComposedMainPassthrough();
        self.flushDeferredMainState();
        try self.compositor.render(self.layout, self.main_pane, self.split_pane, true);
        self.render_scheduler.rendered(nanoTimestamp());
    }

    fn beginOuterComposition(self: *App) !void {
        self.screen_switch_mirror.reset();
        self.host_effect_mirror.reset();
        var bytes: [512]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        try self.outer_input_protocol.enterComposed(.fromPane(self.main_pane), &writer);
        try outer_terminal.write(writer.buffered());
        self.outer_primary_touched = false;
        self.outer_alternate_touched = false;
        switch (self.main_pane.term.screens.active_key) {
            .primary => self.outer_primary_touched = true,
            .alternate => self.outer_alternate_touched = true,
        }
    }

    fn markOuterScreenTouched(self: *App, key: vt.ScreenSet.Key) void {
        switch (key) {
            .primary => self.outer_primary_touched = true,
            .alternate => self.outer_alternate_touched = true,
        }
    }

    fn rawGraphicsFor(self: *App, key: vt.ScreenSet.Key) *RawGraphicsOwnership {
        return switch (key) {
            .primary => &self.outer_primary_graphics,
            .alternate => &self.outer_alternate_graphics,
        };
    }

    fn removeRawGraphicsForComposition(self: *App) !void {
        if (comptime !kitty_graphics_enabled) return;
        const active_key = self.main_pane.term.screens.active_key;
        var selected_key = active_key;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.alloc);

        for ([_]vt.ScreenSet.Key{ .primary, .alternate }) |key| {
            if (self.main_pane.term.screens.get(key) == null) continue;
            self.main_pane.term.screens.switchTo(key);
            var deletes: std.ArrayList(u8) = .empty;
            defer deletes.deinit(self.alloc);
            if (self.main_pane.graphics_seen) {
                try deletes.appendSlice(self.alloc, "\x1b_Ga=d,d=A,q=2;\x1b\\");
            }
            const removed_modeled = try appendRawGraphicsRemoval(
                self.alloc,
                &deletes,
                self.main_pane,
                self.rawGraphicsFor(key),
            );
            if (deletes.items.len == 0 and !removed_modeled) continue;
            if (selected_key != key) {
                try out.appendSlice(self.alloc, switch (key) {
                    .primary => "\x1b[?1047l",
                    .alternate => "\x1b[?1047h",
                });
                selected_key = key;
            }
            try out.appendSlice(self.alloc, deletes.items);
            self.markOuterScreenTouched(key);
        }

        self.main_pane.term.screens.switchTo(active_key);
        if (selected_key != active_key) {
            try out.appendSlice(self.alloc, switch (active_key) {
                .primary => "\x1b[?1047l",
                .alternate => "\x1b[?1047h",
            });
        }
        if (out.items.len == 0) {
            self.outer_primary_graphics.clear();
            self.outer_alternate_graphics.clear();
            return;
        }
        try out.insertSlice(self.alloc, 0, synchronized_update_begin);
        try out.appendSlice(self.alloc, synchronized_update_end);
        try outer_terminal.write(out.items);
        self.outer_primary_graphics.clear();
        self.outer_alternate_graphics.clear();
    }

    fn pollTimeoutMs(self: *const App, now_ns: i128) i32 {
        var timeout: i32 = if (self.composed)
            self.render_scheduler.pollTimeoutMs(now_ns)
        else
            50;

        if (!self.composed and self.deferredMainStateLen() > 0) {
            const due = self.deferred_catchup_due_ns orelse now_ns;
            if (now_ns >= due) return 0;
            const remaining_ns = due - now_ns;
            const remaining_ms: i32 = @intCast(@max(
                @as(i128, 1),
                @divTrunc(remaining_ns + std.time.ns_per_ms - 1, std.time.ns_per_ms),
            ));
            timeout = @min(timeout, remaining_ms);
        }

        if (self.pending_resize != null) {
            const due_ns = self.resize_due_ns orelse return timeout;
            if (now_ns >= due_ns) return 0;
            const remaining_ns = due_ns - now_ns;
            const remaining_ms: i32 = @intCast(@max(@as(i128, 1), @divTrunc(remaining_ns + std.time.ns_per_ms - 1, std.time.ns_per_ms)));
            timeout = @min(timeout, remaining_ms);
        }

        if (self.raw_control_scanner.due_ns) |due_ns| {
            if (now_ns >= due_ns) return 0;
            const remaining_ns = due_ns - now_ns;
            const remaining_ms: i32 = @intCast(@max(
                @as(i128, 1),
                @divTrunc(remaining_ns + std.time.ns_per_ms - 1, std.time.ns_per_ms),
            ));
            timeout = @min(timeout, remaining_ms);
        }

        if (self.outer_input_filter.due_ns) |due_ns| {
            if (now_ns >= due_ns) return 0;
            const remaining_ns = due_ns - now_ns;
            const remaining_ms: i32 = @intCast(@max(
                @as(i128, 1),
                @divTrunc(remaining_ns + std.time.ns_per_ms - 1, std.time.ns_per_ms),
            ));
            timeout = @min(timeout, remaining_ms);
        }

        if (self.deferred_outer_report_due_ns) |due_ns| {
            if (now_ns >= due_ns) return 0;
            const remaining_ns = due_ns - now_ns;
            const remaining_ms: i32 = @intCast(@max(
                @as(i128, 1),
                @divTrunc(remaining_ns + std.time.ns_per_ms - 1, std.time.ns_per_ms),
            ));
            timeout = @min(timeout, remaining_ms);
        }

        return timeout;
    }

    fn deleteCompositorGraphicsOnOuterScreens(
        self: *App,
        out: *std.ArrayList(u8),
    ) !void {
        if (comptime !kitty_graphics_enabled) return;
        const active_key = self.main_pane.term.screens.active_key;
        var selected_key = active_key;

        for ([_]vt.ScreenSet.Key{ .primary, .alternate }) |key| {
            const graphics = self.compositor.graphicsFor(key);
            if (graphics.uploaded.count() == 0) continue;
            if (selected_key != key) {
                try out.appendSlice(self.alloc, switch (key) {
                    .primary => "\x1b[?1047l",
                    .alternate => "\x1b[?1047h",
                });
                selected_key = key;
            }
            try graphics.deleteAll(self.alloc, out);
        }

        if (selected_key != active_key) {
            try out.appendSlice(self.alloc, switch (active_key) {
                .primary => "\x1b[?1047l",
                .alternate => "\x1b[?1047h",
            });
        }
    }

    fn restoreOuterTerminal(self: *App) void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.alloc);
        self.endComposedMainPassthrough() catch {};
        self.deleteCompositorGraphicsOnOuterScreens(&out) catch {};
        if (self.terminal_restore_needed) {
            out.appendSlice(self.alloc, restore_terminal_sequence) catch {};
            self.terminal_restore_needed = false;
        }
        outer_terminal.write(out.items) catch {};
    }

    fn readInput(self: *App, running: *bool) !bool {
        var buf: [8192]u8 = undefined;
        const n = os.read(stdin_fd, &buf) catch |err| switch (err) {
            error.WouldBlock => return false,
            error.InputOutput => {
                running.* = false;
                return false;
            },
            else => return err,
        };
        if (n == 0) {
            running.* = false;
            return false;
        }

        var filtered: std.ArrayList(u8) = .empty;
        defer filtered.deinit(self.alloc);
        try self.filterOuterInput(buf[0..n], &filtered);
        if (filtered.items.len == 0) return true;
        try self.dispatchInput(filtered.items);
        return true;
    }

    fn dispatchInput(self: *App, bytes: []const u8) !void {
        if (!self.composed) {
            try self.forwardKeyboardInput(bytes);
            return;
        }

        try self.input_buffer.appendSlice(self.alloc, bytes);
        try self.processComposedInputBuffer();
    }

    fn allDecimal(bytes: []const u8) bool {
        if (bytes.len == 0) return false;
        for (bytes) |byte| if (byte < '0' or byte > '9') return false;
        return true;
    }

    fn isSizeReportResponse(sequence: []const u8) bool {
        if (sequence.len < 7 or
            sequence[0] != 0x1b or
            sequence[1] != '[' or
            sequence[sequence.len - 1] != 't')
        {
            return false;
        }
        var fields = std.mem.splitScalar(u8, sequence[2 .. sequence.len - 1], ';');
        const kind = fields.next() orelse return false;
        const expected: usize = if (std.mem.eql(u8, kind, "4") or
            std.mem.eql(u8, kind, "6") or
            std.mem.eql(u8, kind, "8"))
            2
        else if (std.mem.eql(u8, kind, "48"))
            4
        else
            return false;
        var count: usize = 0;
        while (fields.next()) |field| {
            if (!allDecimal(field)) return false;
            count += 1;
        }
        return count == expected;
    }

    fn deferredOuterReport(sequence: []const u8) ?DeferredOuterReport {
        if (std.mem.eql(u8, sequence, "\x1b[I")) return .focus_in;
        if (std.mem.eql(u8, sequence, "\x1b[O")) return .focus_out;
        if (std.mem.eql(u8, sequence, "\x1b[?997;1n")) return .color_scheme_dark;
        if (std.mem.eql(u8, sequence, "\x1b[?997;2n")) return .color_scheme_light;
        if (std.mem.eql(u8, sequence, "\x1b[?999;1n")) return .visibility_visible;
        if (std.mem.eql(u8, sequence, "\x1b[?999;2n")) return .visibility_hidden;
        return null;
    }

    fn queueOuterReport(self: *App, report: DeferredOuterReport) !void {
        const query: ?PendingColorQuery = switch (report) {
            .color_scheme_dark, .color_scheme_light => if (self.pending_color_queries.items.len > 0)
                self.pending_color_queries.orderedRemove(0)
            else
                null,
            else => null,
        };
        const scheme: ?vt.device_status.ColorScheme = switch (report) {
            .color_scheme_dark => .dark,
            .color_scheme_light => .light,
            else => null,
        };
        if (scheme) |value| {
            self.main_pane.color_scheme = value;
            if (self.split_pane) |pane| pane.color_scheme = value;
        }
        const visible: ?bool = switch (report) {
            .visibility_visible => true,
            .visibility_hidden => false,
            else => null,
        };
        if (visible) |value| {
            self.main_pane.term.flags.visible = value;
            if (self.split_pane) |pane| pane.term.flags.visible = value;
        }
        try self.deferred_outer_reports.append(self.alloc, .{
            .report = report,
            .query = query,
        });
        if (self.deferred_outer_report_due_ns == null) {
            self.deferred_outer_report_due_ns = nanoTimestamp() + terminal_report_settle_ns;
        }
    }

    fn finishOuterInputSequence(
        self: *App,
        out: *std.ArrayList(u8),
    ) !void {
        const sequence = self.outer_input_filter.buffered();
        if (self.outer_input_filter.bracketed_paste) {
            if (std.mem.eql(u8, sequence, "\x1b[201~")) {
                if (self.outer_input_filter.paste_forward_markers) {
                    try out.appendSlice(self.alloc, sequence);
                }
                self.outer_input_filter.bracketed_paste = false;
                self.outer_input_filter.paste_forward_markers = false;
            } else {
                try out.appendSlice(self.alloc, sequence);
            }
        } else if (std.mem.eql(u8, sequence, "\x1b[200~")) {
            self.outer_input_filter.bracketed_paste = true;
            self.outer_input_filter.paste_forward_markers = !self.composed or
                self.outer_input_protocol.state.bracketed_paste;
            if (self.outer_input_filter.paste_forward_markers) {
                try out.appendSlice(self.alloc, sequence);
            }
        } else if (deferredOuterReport(sequence)) |report| {
            try self.queueOuterReport(report);
        } else if (isSizeReportResponse(sequence)) {
            std.log.scoped(.input).warn("discarded unsolicited terminal size report", .{});
        } else {
            try out.appendSlice(self.alloc, sequence);
        }
        self.outer_input_filter.resetSequence();
    }

    fn filterOuterInput(
        self: *App,
        bytes: []const u8,
        out: *std.ArrayList(u8),
    ) !void {
        var direct_start: ?usize = if (self.outer_input_filter.state == .ground) 0 else null;
        var i: usize = 0;
        while (i < bytes.len) : (i += 1) {
            const byte = bytes[i];
            switch (self.outer_input_filter.state) {
                .ground => {
                    if (byte != 0x1b) continue;
                    if (direct_start) |start| try out.appendSlice(self.alloc, bytes[start..i]);
                    self.outer_input_filter.start(nanoTimestamp());
                    direct_start = null;
                },
                .escape => {
                    if (!self.outer_input_filter.append(byte, nanoTimestamp())) {
                        try out.appendSlice(self.alloc, self.outer_input_filter.buffered());
                        try out.append(self.alloc, byte);
                        self.outer_input_filter.resetSequence();
                        direct_start = i + 1;
                        continue;
                    }
                    if (byte == '[') {
                        self.outer_input_filter.state = .csi;
                    } else {
                        try out.appendSlice(self.alloc, self.outer_input_filter.buffered());
                        self.outer_input_filter.resetSequence();
                        direct_start = i + 1;
                    }
                },
                .csi => {
                    if (!self.outer_input_filter.append(byte, nanoTimestamp())) {
                        try out.appendSlice(self.alloc, self.outer_input_filter.buffered());
                        try out.append(self.alloc, byte);
                        self.outer_input_filter.resetSequence();
                        direct_start = i + 1;
                        continue;
                    }
                    if (byte >= 0x40 and byte <= 0x7e) {
                        try self.finishOuterInputSequence(out);
                        direct_start = i + 1;
                    }
                },
            }
        }
        if (direct_start) |start| try out.appendSlice(self.alloc, bytes[start..]);
    }

    fn flushOuterInputIfDue(self: *App, now_ns: i128) !void {
        const due_ns = self.outer_input_filter.due_ns orelse return;
        if (now_ns < due_ns) return;
        var pending: [128]u8 = undefined;
        const len = self.outer_input_filter.len;
        @memcpy(pending[0..len], self.outer_input_filter.buffered());
        self.outer_input_filter.resetSequence();
        try self.dispatchInput(pending[0..len]);
    }

    fn flushDeferredOuterReportsIfDue(self: *App, now_ns: i128) !bool {
        const due_ns = self.deferred_outer_report_due_ns orelse return false;
        if (now_ns < due_ns) return false;

        const state = self.outer_input_protocol.state;
        var forwarded = false;
        for (self.deferred_outer_reports.items) |delivery| {
            const report = delivery.report;
            if (delivery.query) |query| {
                if (self.paneForId(query.pane)) |pane| {
                    pane.writeTerminalReply(report.bytes(), query.owner);
                    forwarded = true;
                }
                continue;
            }
            const subscribed = switch (report) {
                .focus_in, .focus_out => state.focus_event,
                .color_scheme_dark, .color_scheme_light => state.report_color_scheme,
                .visibility_visible, .visibility_hidden => state.report_visibility,
            };
            if (subscribed) {
                try self.main_pane.writeInput(report.bytes());
                forwarded = true;
            } else {
                std.log.scoped(.input).warn(
                    "discarded terminal report {s} while its pane subscription is disabled",
                    .{@tagName(report)},
                );
            }
        }
        self.deferred_outer_reports.clearRetainingCapacity();
        self.deferred_outer_report_due_ns = null;
        return forwarded;
    }

    fn processComposedInputBuffer(self: *App) !void {
        var forward_start: usize = 0;
        var cursor: usize = 0;
        var retain_start: ?usize = null;
        const bytes = self.input_buffer.items;

        while (cursor < bytes.len) {
            if (bytes[cursor] != 0x1b) {
                cursor += 1;
                continue;
            }

            switch (parseSgrMouse(bytes[cursor..])) {
                .none => cursor += 1,
                .incomplete => {
                    if (forward_start < cursor) try self.forwardKeyboardInput(bytes[forward_start..cursor]);
                    if (!self.composed) {
                        if (cursor < bytes.len) try self.forwardKeyboardInput(bytes[cursor..]);
                        self.input_buffer.clearRetainingCapacity();
                        return;
                    }
                    retain_start = cursor;
                    break;
                },
                .event => |event| {
                    if (forward_start < cursor) try self.forwardKeyboardInput(bytes[forward_start..cursor]);
                    if (!self.composed) {
                        try self.forwardKeyboardInput(bytes[cursor..]);
                        self.input_buffer.clearRetainingCapacity();
                        return;
                    }

                    try self.handleSgrMouse(event);
                    cursor += event.len;
                    forward_start = cursor;
                },
            }
        }

        if (retain_start) |start| {
            const remaining = bytes[start..];
            std.mem.copyForwards(u8, self.input_buffer.items[0..remaining.len], remaining);
            self.input_buffer.shrinkRetainingCapacity(remaining.len);
            return;
        }

        if (forward_start < bytes.len) try self.forwardKeyboardInput(bytes[forward_start..]);
        self.input_buffer.clearRetainingCapacity();
    }

    fn forwardKeyboardInput(self: *App, bytes: []const u8) !void {
        const parse_prefix = self.composed or self.config.split_cmd != null;
        if (!parse_prefix) {
            try self.main_pane.writeInput(bytes);
            return;
        }
        var result = try self.prefix.feed(self.alloc, bytes);
        defer result.deinit(self.alloc);
        const keyboard_disabled = self.composed and self.outer_input_protocol.state.keyboard_disabled;
        if (!keyboard_disabled and result.forwarded.items.len > 0) {
            try self.main_pane.writeInput(result.forwarded.items);
        }
        if (result.close_split) {
            if (self.split_pane != null) {
                try self.closeSplit();
            } else {
                try self.main_pane.writeInput(&.{ 0x02, 'x' });
            }
        }
        if (result.open_split) {
            if (!self.composed and self.split_pane == null and self.config.split_cmd != null) {
                try self.openSplit();
            } else {
                try self.main_pane.writeInput(&.{ 0x02, 's' });
            }
        }
    }

    fn handleSgrMouse(self: *App, event: SgrMouseEvent) !void {
        if (self.scrollbar_drag) |drag| {
            if (event.isRelease()) {
                self.scrollbar_drag = null;
                return;
            }
            if (event.isMotion()) {
                try self.dragScrollbar(drag, event.y);
                return;
            }
            return;
        }

        const hit = hitTestMouse(self.layout, self.split_pane != null, event.x, event.y);
        switch (hit) {
            .outside, .border => return,
            .scrollbar => |scrollbar_hit| {
                const pane = self.paneForId(scrollbar_hit.pane) orelse return;
                if (event.wheelAction()) |wheel| {
                    switch (wheel) {
                        .up => self.scrollPaneViewport(pane, -wheel_scroll_rows),
                        .down => self.scrollPaneViewport(pane, wheel_scroll_rows),
                        .left, .right => {},
                    }
                    return;
                }
                if (event.isPrimaryPress()) {
                    try self.startScrollbarDrag(scrollbar_hit, event.y);
                    return;
                }
                if (event.isRelease()) self.scrollbar_drag = null;
            },
            .pane => |pane_hit| {
                const pane = self.paneForId(pane_hit.pane) orelse return;

                if (pane.term.flags.mouse_event != .none) {
                    var buf: [64]u8 = undefined;
                    var writer = std.Io.Writer.fixed(&buf);
                    try encodeMouseForPane(&writer, pane, event, pane_hit.x, pane_hit.y);
                    try pane.writeInput(writer.buffered());
                    return;
                }

                const wheel = event.wheelAction() orelse return;
                if (pane.term.screens.active_key == .alternate and
                    pane.term.modes.get(.mouse_alternate_scroll))
                {
                    const application = pane.term.modes.get(.cursor_keys);
                    const sequence: []const u8 = switch (wheel) {
                        .up => if (application) "\x1bOA" else "\x1b[A",
                        .down => if (application) "\x1bOB" else "\x1b[B",
                        .right => if (application) "\x1bOC" else "\x1b[C",
                        .left => if (application) "\x1bOD" else "\x1b[D",
                    };
                    try pane.writeInput(sequence);
                    return;
                }

                const delta: isize = switch (wheel) {
                    .up => -wheel_scroll_rows,
                    .down => wheel_scroll_rows,
                    .left, .right => return,
                };
                self.scrollPaneViewport(pane, delta);
            },
        }
    }

    fn paneForId(self: *App, pane: PaneId) ?*Pane {
        return switch (pane) {
            .main => self.main_pane,
            .split => self.split_pane,
        };
    }

    fn scrollbarTrackTop(self: *const App, pane: PaneId) u16 {
        return switch (pane) {
            .main => 1,
            .split => self.layout.splitTop() + 1,
        };
    }

    fn scrollPaneViewport(self: *App, pane: *Pane, delta: isize) void {
        self.endComposedMainPassthrough() catch {};
        if (pane == self.main_pane) self.flushDeferredMainState();
        pane.term.scrollViewport(.{ .delta = delta });
        self.compositor.invalidate();
        self.render_scheduler.markDirty(.urgent);
    }

    fn startScrollbarDrag(self: *App, hit: ScrollbarHit, absolute_y: u16) !void {
        const pane = self.paneForId(hit.pane) orelse return;
        try self.endComposedMainPassthrough();
        if (pane == self.main_pane) self.flushDeferredMainState();
        const info = scrollbarInfo(pane, hit.track_len) orelse return;
        const local0 = @as(u16, hit.y - 1);
        const thumb_end = info.thumb_start + info.thumb_len;
        const grab_offset: u16 = if (local0 >= info.thumb_start and local0 < thumb_end)
            local0 - info.thumb_start
        else
            @min(info.thumb_len / 2, info.thumb_len - 1);
        const drag: ScrollbarDrag = .{
            .pane = hit.pane,
            .track_top = self.scrollbarTrackTop(hit.pane),
            .track_len = hit.track_len,
            .grab_offset = grab_offset,
        };
        self.scrollbar_drag = drag;
        try self.dragScrollbar(drag, absolute_y);
    }

    fn dragScrollbar(self: *App, drag: ScrollbarDrag, absolute_y: u16) !void {
        if (drag.track_len == 0) return;
        const pane = self.paneForId(drag.pane) orelse return;
        try self.endComposedMainPassthrough();
        if (pane == self.main_pane) self.flushDeferredMainState();
        const info = scrollbarInfo(pane, drag.track_len) orelse return;
        const track_top: usize = @intCast(drag.track_top);
        const track_bottom: usize = track_top + @as(usize, @intCast(drag.track_len)) - 1;
        const absolute: usize = @intCast(absolute_y);
        const local_y: u16 = if (absolute <= track_top)
            1
        else if (absolute >= track_bottom)
            drag.track_len
        else
            @intCast(absolute - track_top + 1);
        const target = scrollbarTargetOffset(info, local_y, drag.grab_offset);
        pane.term.screens.active.scroll(.{ .row = target });
        self.compositor.invalidate();
        self.render_scheduler.markDirty(.urgent);
    }

    const WhichPane = enum { main, split };

    fn readPane(self: *App, pane: *Pane, which: WhichPane) !usize {
        var buf: [64 * 1024]u8 = undefined;
        return try self.readPaneInto(pane, which, &buf);
    }

    fn readPaneInto(self: *App, pane: *Pane, which: WhichPane, buf: *[64 * 1024]u8) !usize {
        const n = os.read(pane.pty_fd, buf) catch {
            pane.markDead();
            return 0;
        };
        if (n == 0) {
            pane.markDead();
            return 0;
        }
        if (!self.graphics_normalization_enabled or
            !pane.graphics_normalizer.needsProcessing(buf[0..n]))
        {
            try self.processPaneOutput(pane, which, buf[0..n]);
            try self.flushPaneOuterQueries(pane, which);
            return n;
        }
        var normalized: std.ArrayList(u8) = .empty;
        defer normalized.deinit(self.alloc);
        const normalization = try pane.graphics_normalizer.feed(
            currentIo(),
            self.alloc,
            getenv("TMPDIR") orelse "/tmp",
            buf[0..n],
            &normalized,
        );
        pane.graphics_seen = pane.graphics_seen or normalization.graphics;
        pane.graphics_dropped = pane.graphics_dropped or normalization.dropped;
        try self.processPaneOutput(pane, which, normalized.items);
        try self.flushPaneOuterQueries(pane, which);
        return n;
    }

    fn processPaneOutput(self: *App, pane: *Pane, which: WhichPane, bytes: []const u8) !void {
        if (!self.composed and which == .main) {
            try self.forwardRawMainOutput(bytes);
        } else if (self.composed and which == .main) {
            try self.endComposedMainPassthrough();
            self.flushDeferredMainState();
            try self.mirrorMainScreenSwitches(bytes);
            pane.feedWithReplies(bytes, pane.foregroundPgrp());
            try self.syncOuterInputProtocol();
            self.syncMainPassthroughCursor();
        } else {
            pane.feedWithReplies(bytes, pane.foregroundPgrp());
        }
    }

    fn flushPaneOuterQueries(self: *App, pane: *Pane, which: WhichPane) !void {
        const count = pane.color_scheme_queries_to_outer;
        if (count == 0) return;
        const query = PendingColorQuery{
            .pane = switch (which) {
                .main => .main,
                .split => .split,
            },
            .owner = pane.color_scheme_query_owner,
        };
        pane.color_scheme_queries_to_outer = 0;
        pane.color_scheme_query_owner = null;

        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(self.alloc);
        for (0..count) |_| {
            try self.pending_color_queries.append(self.alloc, query);
            try bytes.appendSlice(self.alloc, "\x1b[?996n");
        }
        try outer_terminal.write(bytes.items);
    }

    fn mirrorMainScreenSwitches(self: *App, bytes: []const u8) !void {
        var mirrored: std.ArrayList(u8) = .empty;
        defer mirrored.deinit(self.alloc);
        try self.screen_switch_mirror.feed(
            self.alloc,
            bytes,
            &mirrored,
            &self.outer_primary_touched,
            &self.outer_alternate_touched,
        );
        try self.host_effect_mirror.feed(self.alloc, bytes, &mirrored);
        if (mirrored.items.len == 0) return;
        try outer_terminal.write(mirrored.items);
        self.compositor.invalidate();
    }

    fn syncOuterInputProtocol(self: *App) !void {
        var bytes: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        try self.outer_input_protocol.sync(.fromPane(self.main_pane), &writer);
        if (writer.buffered().len > 0) try outer_terminal.write(writer.buffered());
    }

    fn rawModeNeedsPaneState(self: *const App) bool {
        return self.config.split_cmd != null or self.control_runtime != null;
    }

    fn deferMainState(self: *App, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        if (self.deferred_main_offset > 0 and
            self.deferred_main_state.items.len + bytes.len > deferred_raw_state_limit)
        {
            self.compactDeferredMainState();
        }
        if (self.deferredMainStateLen() + bytes.len > deferred_raw_state_limit) {
            self.flushDeferredMainState();
        }
        if (bytes.len > deferred_raw_state_limit) {
            self.main_pane.feed(bytes);
            return;
        }
        const total_required = self.deferred_main_state.items.len + bytes.len;
        if (bytes.len >= deferred_raw_bulk_prealloc_trigger and self.deferred_main_state.capacity < total_required) {
            try self.deferred_main_state.ensureTotalCapacity(
                self.alloc,
                @min(deferred_raw_state_limit, @max(total_required, deferred_raw_bulk_prealloc_bytes)),
            );
        }
        try self.deferred_main_state.appendSlice(self.alloc, bytes);
        self.deferred_catchup_due_ns = nanoTimestamp() + deferred_raw_catchup_delay_ns;
    }

    fn deferredMainStateLen(self: *const App) usize {
        return self.deferred_main_state.items.len - self.deferred_main_offset;
    }

    fn compactDeferredMainState(self: *App) void {
        if (self.deferred_main_offset == 0) return;
        const remaining = self.deferredMainStateLen();
        if (remaining > 0) {
            std.mem.copyForwards(
                u8,
                self.deferred_main_state.items[0..remaining],
                self.deferred_main_state.items[self.deferred_main_offset..],
            );
        }
        self.deferred_main_state.shrinkRetainingCapacity(remaining);
        self.deferred_main_offset = 0;
    }

    fn advanceDeferredMainState(self: *App) void {
        if (self.composed or self.deferredMainStateLen() == 0) return;
        const now = nanoTimestamp();
        if (self.deferred_catchup_due_ns) |due| {
            if (now < due) return;
        }
        const bulk = self.deferredMainStateLen() >= deferred_raw_bulk_threshold;
        const byte_budget = if (bulk) deferred_raw_bulk_catchup_bytes else deferred_raw_catchup_bytes;
        const time_budget = if (bulk) deferred_raw_bulk_catchup_ns else deferred_raw_catchup_ns;
        const started = nanoTimestamp();
        var processed: usize = 0;
        while (self.deferredMainStateLen() > 0 and processed < byte_budget) {
            const n = @min(
                self.deferredMainStateLen(),
                @min(deferred_raw_catchup_slice, byte_budget - processed),
            );
            const end = self.deferred_main_offset + n;
            self.main_pane.feed(self.deferred_main_state.items[self.deferred_main_offset..end]);
            self.deferred_main_offset = end;
            processed += n;
            if (nanoTimestamp() - started >= time_budget) break;
        }
        if (self.deferredMainStateLen() == 0) {
            self.deferred_main_state.clearRetainingCapacity();
            self.deferred_main_offset = 0;
            self.deferred_catchup_due_ns = null;
        } else if (self.deferred_main_offset >= deferred_raw_bulk_prealloc_bytes and
            self.deferred_main_offset >= self.deferredMainStateLen())
        {
            self.compactDeferredMainState();
        }
        if (self.deferredMainStateLen() > 0) self.deferred_catchup_due_ns = nanoTimestamp();
        self.syncMainPassthroughCursor();
    }

    fn flushDeferredMainState(self: *App) void {
        if (self.deferredMainStateLen() == 0) return;
        self.main_pane.feed(self.deferred_main_state.items[self.deferred_main_offset..]);
        self.deferred_main_state.clearRetainingCapacity();
        self.deferred_main_offset = 0;
        self.deferred_catchup_due_ns = null;
        self.syncMainPassthroughCursor();
    }

    fn passRawMainBytes(self: *App, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try outer_terminal.write(bytes);
        if (self.rawModeNeedsPaneState()) try self.deferMainState(bytes);
    }

    fn isLocalTerminalQuery(sequence: []const u8) bool {
        if (std.mem.eql(u8, sequence, "\x1bZ")) return true;
        if (sequence.len < 3 or
            sequence[0] != 0x1b or
            sequence[1] != '[')
        {
            return false;
        }
        const final = sequence[sequence.len - 1];
        const body = sequence[2 .. sequence.len - 1];
        return switch (final) {
            'c' => std.mem.eql(u8, body, "") or
                std.mem.eql(u8, body, "0") or
                std.mem.eql(u8, body, ">") or
                std.mem.eql(u8, body, ">0") or
                std.mem.eql(u8, body, "=") or
                std.mem.eql(u8, body, "=0"),
            'n' => std.mem.eql(u8, body, "5") or
                std.mem.eql(u8, body, "6") or
                std.mem.eql(u8, body, "?6") or
                std.mem.eql(u8, body, "?996") or
                std.mem.eql(u8, body, "?997") or
                std.mem.eql(u8, body, "?998"),
            'p' => std.mem.startsWith(u8, body, "?") and
                std.mem.endsWith(u8, body, "$") and
                body.len > 2,
            'q' => std.mem.eql(u8, body, ">"),
            't' => std.mem.eql(u8, body, "14") or
                std.mem.eql(u8, body, "16") or
                std.mem.eql(u8, body, "18") or
                std.mem.eql(u8, body, "21"),
            'u' => std.mem.eql(u8, body, "?"),
            else => false,
        };
    }

    fn shouldInterceptRawControlSequence(sequence: []const u8) bool {
        return std.mem.eql(u8, sequence, "\x1b[?2048h") or
            std.mem.eql(u8, sequence, "\x1b[?2048l") or
            isLocalTerminalQuery(sequence);
    }

    fn noteRawControlSequence(self: *App, sequence: []const u8) void {
        self.outer_input_protocol.noteRawControlSequence(sequence);
        if (std.mem.eql(u8, sequence, "\x1bc")) {
            self.main_pane.in_band_size_owner = null;
        }
    }

    fn forwardRawMainOutput(self: *App, bytes: []const u8) !void {
        const now_ns = nanoTimestamp();
        var outer_start: ?usize = if (self.raw_control_scanner.state == .ground) 0 else null;
        var sequence_start: ?usize = null;
        var i: usize = 0;
        while (i < bytes.len) : (i += 1) {
            const byte = bytes[i];
            switch (self.raw_control_scanner.state) {
                .ground => {
                    if (byte != 0x1b) {
                        const offset = std.mem.indexOfScalar(u8, bytes[i + 1 ..], 0x1b) orelse {
                            i = bytes.len;
                            break;
                        };
                        i += offset + 1;
                    }
                    self.raw_control_scanner.start(now_ns);
                    sequence_start = i;
                },
                .escape => {
                    if (!self.raw_control_scanner.append(byte, now_ns)) {
                        if (sequence_start == null) {
                            try self.passRawMainBytes(self.raw_control_scanner.buffered());
                            outer_start = i;
                        }
                        self.raw_control_scanner.reset();
                        sequence_start = null;
                        continue;
                    }
                    if (byte == '[') {
                        self.raw_control_scanner.state = .csi;
                    } else {
                        const sequence = self.raw_control_scanner.buffered();
                        const intercepted = shouldInterceptRawControlSequence(sequence);
                        if (intercepted) {
                            if (sequence_start) |start| {
                                if (outer_start) |outer| try self.passRawMainBytes(bytes[outer..start]);
                            }
                            self.flushDeferredMainState();
                            self.main_pane.feedWithReplies(sequence, self.main_pane.foregroundPgrp());
                            outer_start = i + 1;
                        } else if (sequence_start == null) {
                            try self.passRawMainBytes(sequence);
                            outer_start = i + 1;
                        }
                        if (!intercepted) self.noteRawControlSequence(sequence);
                        self.raw_control_scanner.reset();
                        sequence_start = null;
                    }
                },
                .csi => {
                    if (!self.raw_control_scanner.append(byte, now_ns)) {
                        if (sequence_start == null) {
                            try self.passRawMainBytes(self.raw_control_scanner.buffered());
                            outer_start = i;
                        }
                        self.raw_control_scanner.reset();
                        sequence_start = null;
                        continue;
                    }
                    if (byte >= 0x40 and byte <= 0x7e) {
                        const sequence = self.raw_control_scanner.buffered();
                        const intercepted = shouldInterceptRawControlSequence(sequence);
                        if (intercepted) {
                            if (sequence_start) |start| {
                                if (outer_start) |outer| try self.passRawMainBytes(bytes[outer..start]);
                            }
                            self.flushDeferredMainState();
                            self.main_pane.feedWithReplies(sequence, self.main_pane.foregroundPgrp());
                            outer_start = i + 1;
                        } else if (sequence_start == null) {
                            try self.passRawMainBytes(sequence);
                            outer_start = i + 1;
                        }
                        if (!intercepted) self.noteRawControlSequence(sequence);
                        self.raw_control_scanner.reset();
                        sequence_start = null;
                    }
                },
            }
        }
        if (self.raw_control_scanner.state == .ground) {
            if (outer_start) |start| try self.passRawMainBytes(bytes[start..]);
        } else if (sequence_start) |start| {
            if (outer_start) |outer| try self.passRawMainBytes(bytes[outer..start]);
        }
    }

    fn flushRawControlPending(self: *App) !void {
        if (self.raw_control_scanner.state == .ground) return;
        try self.passRawMainBytes(self.raw_control_scanner.buffered());
        self.raw_control_scanner.reset();
    }

    fn flushRawControlIfDue(self: *App, now_ns: i128) !void {
        const due_ns = self.raw_control_scanner.due_ns orelse return;
        if (now_ns < due_ns) return;
        try self.flushRawControlPending();
    }

    fn tryComposedMainPassthrough(self: *App, bytes: []const u8) !bool {
        if (!self.main_pane.ascii_fast_feed_enabled) return false;
        if (!self.mainPaneLiveBottom()) return false;
        // A PTY read can end in the middle of a terminal sequence. Until both
        // incremental mirrors return to ground, the continuation must pass
        // through the VT model rather than being mistaken for printable text.
        if (self.screen_switch_mirror.state != .ground or self.host_effect_mirror.state != .ground) return false;
        const graphics = self.compositor.graphicsFor(self.main_pane.term.screens.active_key);
        if (graphics.uploaded.count() != 0) return false;
        if (graphics.needsUpdate(self.main_pane, self.split_pane)) return false;

        if (!self.main_passthrough_outer_active and self.deferredMainStateLen() == 0) {
            self.syncMainPassthroughCursor();
        }
        const cursor = plainPassthroughEndState(bytes, self.layout.paneCols(), self.main_passthrough_cursor) orelse return false;
        try self.writeComposedMainPassthrough(bytes);
        try self.deferMainState(bytes);
        self.main_passthrough_cursor = cursor;
        self.direct_main_painted_bytes += bytes.len;
        return true;
    }

    fn syncMainPassthroughCursor(self: *App) void {
        const cursor = self.main_pane.term.screens.active.cursor;
        self.main_passthrough_cursor = .{
            .col = @intCast(@min(cursor.x, std.math.maxInt(u16))),
            .pending_wrap = cursor.pending_wrap,
        };
    }

    fn mainPaneLiveBottom(self: *App) bool {
        const info = scrollbarInfo(self.main_pane, self.layout.main_rows) orelse return true;
        return info.offset == info.max_offset;
    }

    fn writeComposedMainPassthrough(self: *App, bytes: []const u8) !void {
        if (self.layout.main_rows == 0) return;
        try self.beginComposedMainPassthrough();
        try outer_terminal.write(bytes);
    }

    fn beginComposedMainPassthrough(self: *App) !void {
        if (self.main_passthrough_outer_active) return;
        var buf: [96]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        try writer.print("\x1b[?69h\x1b[1;{d}r\x1b[1;{d}s", .{ self.layout.main_rows, self.layout.paneCols() });
        try outer_terminal.write(writer.buffered());
        self.main_passthrough_outer_active = true;
    }

    fn endComposedMainPassthrough(self: *App) !void {
        if (!self.main_passthrough_outer_active) return;
        try outer_terminal.write("\x1b[r\x1b[s\x1b[?69l");
        self.main_passthrough_outer_active = false;
    }

    fn drainReadyPanes(self: *App, budget_ns: i128) !DrainStats {
        const deadline = nanoTimestamp() + budget_ns;
        var stats: DrainStats = .{};
        var buf: [64 * 1024]u8 = undefined;

        while (true) {
            if (stats.reads >= pty_drain_max_reads or
                stats.bytes >= pty_drain_max_bytes or
                nanoTimestamp() >= deadline)
            {
                stats.saturated = try self.panesReady();
                return stats;
            }

            var fds_storage: [2]posix.pollfd = undefined;
            var which_storage: [2]WhichPane = undefined;
            var count: usize = 0;

            if (self.main_pane.pty_fd >= 0) {
                fds_storage[count] = .{ .fd = self.main_pane.pty_fd, .events = posix.POLL.IN, .revents = 0 };
                which_storage[count] = .main;
                count += 1;
            }
            if (self.split_pane) |pane| {
                if (pane.pty_fd >= 0) {
                    fds_storage[count] = .{ .fd = pane.pty_fd, .events = posix.POLL.IN, .revents = 0 };
                    which_storage[count] = .split;
                    count += 1;
                }
            }
            if (count == 0) return stats;

            const ready = try posix.poll(fds_storage[0..count], 0);
            if (ready == 0) return stats;

            for (fds_storage[0..count], which_storage[0..count]) |fd, which| {
                if (fd.revents == 0) continue;
                const pane = switch (which) {
                    .main => self.main_pane,
                    .split => self.split_pane orelse continue,
                };
                const n = try self.readPaneInto(pane, which, &buf);
                if (n == 0) continue;
                stats.record(n);
                if (stats.reads >= pty_drain_max_reads or stats.bytes >= pty_drain_max_bytes) {
                    stats.saturated = try self.panesReady();
                    return stats;
                }
            }
        }
    }

    fn panesReady(self: *App) !bool {
        var fds_storage: [2]posix.pollfd = undefined;
        var count: usize = 0;

        if (self.main_pane.pty_fd >= 0) {
            fds_storage[count] = .{ .fd = self.main_pane.pty_fd, .events = posix.POLL.IN, .revents = 0 };
            count += 1;
        }
        if (self.split_pane) |pane| {
            if (pane.pty_fd >= 0) {
                fds_storage[count] = .{ .fd = pane.pty_fd, .events = posix.POLL.IN, .revents = 0 };
                count += 1;
            }
        }
        if (count == 0) return false;
        return try posix.poll(fds_storage[0..count], 0) > 0;
    }

    fn controlRuntimePtr(self: *App) ?*const ControlRuntime {
        return if (self.control_runtime) |*runtime| runtime else null;
    }

    fn acceptControlConnections(self: *App) !void {
        const runtime = if (self.control_runtime) |*runtime| runtime else return;
        const accepted = try runtime.server.accept(currentIo());
        const fd = accepted.socket.handle;
        if (self.control_connections.items.len >= max_control_connections) {
            accepted.close(currentIo());
            return;
        }

        try setNonblocking(fd);
        try self.control_connections.append(self.alloc, .{
            .fd = fd,
            .accepted_ns = nanoTimestamp(),
        });
    }

    fn readControlConnection(self: *App, index: usize) !void {
        var closed = false;
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const n = os.read(self.control_connections.items[index].fd, &buf) catch |err| switch (err) {
                error.WouldBlock => break,
                else => {
                    self.removeControlConnection(index);
                    return;
                },
            };
            if (n == 0) {
                closed = true;
                break;
            }
            const connection = &self.control_connections.items[index];
            if (connection.input.items.len + n > max_control_request) {
                writeControlResponse(connection.fd, false, "ControlRequestTooLarge");
                self.removeControlConnection(index);
                return;
            }
            try connection.input.appendSlice(self.alloc, buf[0..n]);
        }

        const connection = &self.control_connections.items[index];
        var request = ControlRequest.readBuffer(self.alloc, connection.input.items) catch |err| {
            if (err == error.IncompleteControlRequest and !closed) return;
            writeControlResponse(connection.fd, false, @errorName(err));
            self.removeControlConnection(index);
            return;
        };
        defer request.deinit(self.alloc);

        var response_buf: [128]u8 = undefined;
        const response = self.executeControlRequest(&request, &response_buf) catch |err| {
            if (!isControlClientError(err)) return err;
            writeControlResponse(connection.fd, false, @errorName(err));
            self.removeControlConnection(index);
            return;
        };
        writeControlResponse(connection.fd, true, response);
        self.removeControlConnection(index);
    }

    fn isControlClientError(err: anyerror) bool {
        return switch (err) {
            error.MissingSplitRows,
            error.InvalidCharacter,
            error.Overflow,
            error.InvalidSplitRows,
            error.MissingSplitCommand,
            error.UnsupportedControlCommand,
            error.UnsupportedPaneOption,
            error.MissingPaneGeneration,
            error.SplitAlreadyOpen,
            error.TerminalTooSmall,
            => true,
            else => false,
        };
    }

    fn expireControlConnections(self: *App, now_ns: i128) void {
        var index = self.control_connections.items.len;
        while (index > 0) {
            index -= 1;
            const connection = &self.control_connections.items[index];
            if (now_ns - connection.accepted_ns < control_connection_timeout_ns) continue;
            writeControlResponse(connection.fd, false, "ControlRequestTimeout");
            self.removeControlConnection(index);
        }
    }

    fn removeControlConnection(self: *App, index: usize) void {
        var connection = self.control_connections.swapRemove(index);
        connection.deinit(self.alloc);
    }

    fn executeControlRequest(
        self: *App,
        request: *ControlRequest,
        response_buf: []u8,
    ) ![]const u8 {
        const command = try parseNativeCommand(request.argv);
        switch (command) {
            .pane_run => |pane| {
                try self.prepareAuxiliaryEnv(&request.env);
                const generation = try self.openSplitWith(
                    pane.argv,
                    &request.env,
                    request.cwd,
                    pane.rows,
                    true,
                );
                return try std.fmt.bufPrint(response_buf, "{d}", .{generation});
            },
            .pane_close => |generation| {
                if (self.split_generation == generation) try self.closeSplit();
                return try std.fmt.bufPrint(response_buf, "{d}", .{generation});
            },
            .pane_status => {
                const generation = self.split_generation orelse return "none";
                return try std.fmt.bufPrint(response_buf, "{d}", .{generation});
            },
        }
    }

    fn prepareAuxiliaryEnv(self: *App, env: *EnvMap) !void {
        const outer_term = getenv("TERM");
        const colorterm = getenv("COLORTERM");
        try env.put("TERM", selectTerm(self.config.split_term, outer_term, colorterm));
        try applyTinymuxEnv(
            self.alloc,
            env,
            self.controlRuntimePtr(),
            self.config.kitty_compat,
            "2",
            .auxiliary,
        );
    }

    fn createSplitPaneFrom(
        self: *App,
        argv: []const []const u8,
        env: *EnvMap,
        cwd: ?[]const u8,
        rows: u16,
    ) !*Pane {
        return try Pane.create(
            self.alloc,
            argv,
            env,
            @max(rows, 1),
            self.layout.paneCols(),
            self.cell_size,
            cwd,
        );
    }

    fn openSplit(self: *App) !void {
        const cmd = self.config.split_cmd orelse return;
        if (self.split_pane != null) return;

        var split_env = try currentEnvMap(self.alloc);
        defer split_env.deinit();
        const outer_term = getenv("TERM");
        const colorterm = getenv("COLORTERM");
        try split_env.put("TERM", selectTerm(self.config.split_term, outer_term, colorterm));
        try applyTinymuxEnv(
            self.alloc,
            &split_env,
            self.controlRuntimePtr(),
            self.config.kitty_compat,
            "2",
            .auxiliary,
        );

        const cwd = std.process.currentPathAlloc(currentIo(), self.alloc) catch null;
        defer if (cwd) |path| self.alloc.free(path);

        const shell = getenv("SHELL") orelse "/bin/sh";
        const split_argv = [_][]const u8{ shell, "-lc", cmd };
        _ = try self.openSplitWith(
            &split_argv,
            &split_env,
            cwd,
            self.config.split_rows,
            false,
        );
    }

    fn openSplitWith(
        self: *App,
        argv: []const []const u8,
        env: *EnvMap,
        cwd: ?[]const u8,
        rows: u16,
        autoclose: bool,
    ) !u64 {
        if (self.split_pane != null) return error.SplitAlreadyOpen;

        try self.drainMainForSplitTransition();
        try self.flushRawControlPending();
        self.flushDeferredMainState();

        self.active_split_rows = rows;
        self.layout = Layout.compute(self.last_size.row, self.last_size.col, true, self.active_split_rows);
        if (!self.layout.split_visible) return error.TerminalTooSmall;
        self.scrollbar_drag = null;
        const pane = try self.createSplitPaneFrom(argv, env, cwd, self.layout.split_rows);
        errdefer pane.destroy();
        try self.beginOuterComposition();
        try self.removeRawGraphicsForComposition();
        try self.main_pane.resize(self.layout.main_rows, self.layout.paneCols(), self.cell_size);

        self.split_pane = pane;
        self.split_autoclose = autoclose;
        const generation = self.next_split_generation;
        self.next_split_generation = if (generation == std.math.maxInt(u64)) 1 else generation + 1;
        self.split_generation = generation;
        self.composed = true;
        self.terminal_restore_needed = true;
        self.compositor.invalidate();
        try self.compositor.render(self.layout, self.main_pane, self.split_pane, true);
        self.render_scheduler.rendered(nanoTimestamp());
        return generation;
    }

    fn closeSplit(self: *App) !void {
        const pane = self.split_pane orelse return;
        try self.endComposedMainPassthrough();
        try self.drainMainForSplitTransition();
        try self.endComposedMainPassthrough();
        self.flushDeferredMainState();

        pane.terminate();
        pane.destroy();
        self.split_pane = null;
        self.split_autoclose = false;
        self.split_generation = null;
        self.layout = Layout.compute(self.last_size.row, self.last_size.col, false, self.active_split_rows);
        self.scrollbar_drag = null;
        try self.main_pane.resize(self.layout.main_rows, self.layout.paneCols(), self.cell_size);
        self.active_split_rows = self.config.split_rows;
        try outer_terminal.write(reset_state_sequence);
        try self.reconcileMainToOuter();

        self.composed = false;
        self.render_scheduler.rendered(nanoTimestamp());
    }

    fn reconcileMainToOuter(self: *App) !void {
        const active_key = self.main_pane.term.screens.active_key;
        if (active_key == .primary) {
            if (self.outer_alternate_touched and self.main_pane.term.screens.get(.alternate) != null) {
                try self.renderMainOnOuterScreen(.alternate, false);
            }
            try self.renderMainOnOuterScreen(.primary, true);
        } else {
            if (self.outer_primary_touched) try self.renderMainOnOuterScreen(.primary, false);
            try self.renderMainOnOuterScreen(.alternate, true);
        }
        self.main_pane.term.screens.switchTo(active_key);
        self.outer_primary_touched = false;
        self.outer_alternate_touched = false;
        self.screen_switch_mirror.reset();
        self.host_effect_mirror.reset();
        self.outer_input_protocol.adoptRaw(.fromPane(self.main_pane));
    }

    fn renderMainOnOuterScreen(
        self: *App,
        key: vt.ScreenSet.Key,
        restore_terminal_state: bool,
    ) !void {
        if (self.main_pane.term.screens.get(key) == null) return;
        self.main_pane.term.screens.switchTo(key);
        try outer_terminal.write(switch (key) {
            .primary => "\x1b[?1047l",
            .alternate => "\x1b[?1047h",
        });

        var graphics_handoff: std.ArrayList(u8) = .empty;
        defer graphics_handoff.deinit(self.alloc);
        try self.compositor.graphicsFor(key).deleteAll(self.alloc, &graphics_handoff);
        if (graphics_handoff.items.len > 0) try outer_terminal.write(graphics_handoff.items);

        if (restore_terminal_state) {
            const modes = try self.main_pane.terminalModes(self.alloc);
            defer self.alloc.free(modes);
            try outer_terminal.write(modes);
        }
        self.compositor.invalidate();
        try self.compositor.render(self.layout, self.main_pane, null, false);

        graphics_handoff.clearRetainingCapacity();
        try graphics_handoff.appendSlice(self.alloc, synchronized_update_begin);
        try appendRawGraphicsRestore(self.alloc, &graphics_handoff, self.main_pane);
        try graphics_handoff.appendSlice(self.alloc, synchronized_update_end);
        try outer_terminal.write(graphics_handoff.items);
        try self.rawGraphicsFor(key).capture(self.alloc, self.main_pane);

        const screen_state = try self.main_pane.screenState(self.alloc);
        defer self.alloc.free(screen_state);
        try outer_terminal.write(screen_state);
    }

    fn closeAutoSplitIfExited(self: *App) !void {
        if (!self.split_autoclose) return;
        const pane = self.split_pane orelse return;
        if (pane.pty_fd >= 0) return;
        try self.closeSplit();
    }

    fn drainMainForSplitTransition(self: *App) !void {
        while (self.main_pane.pty_fd >= 0) {
            var fds = [_]posix.pollfd{.{
                .fd = self.main_pane.pty_fd,
                .events = posix.POLL.IN,
                .revents = 0,
            }};
            const ready = try posix.poll(&fds, 0);
            if (ready == 0) break;
            if (fds[0].revents == 0) break;

            var buf: [64 * 1024]u8 = undefined;
            _ = try self.readPaneInto(self.main_pane, .main, &buf);
        }
    }

    fn drainMainForExit(self: *App) !void {
        const deadline = milliTimestamp() + exit_drain_ms;
        while (self.main_pane.pty_fd >= 0 and milliTimestamp() < deadline) {
            var fds = [_]posix.pollfd{.{
                .fd = self.main_pane.pty_fd,
                .events = posix.POLL.IN,
                .revents = 0,
            }};
            const ready = try posix.poll(&fds, 10);
            if (ready == 0) break;
            if (fds[0].revents == 0) continue;

            var buf: [64 * 1024]u8 = undefined;
            const n = os.read(self.main_pane.pty_fd, &buf) catch break;
            if (n == 0) break;

            const bytes = buf[0..n];
            if (!self.composed) {
                try self.forwardRawMainOutput(bytes);
            } else {
                self.main_pane.feedWithReplies(bytes, self.main_pane.foregroundPgrp());
            }
        }
        try self.flushRawControlPending();
        self.main_pane.closePty();
    }

    fn checkResize(self: *App, now_ns: i128) !void {
        const size = ptypkg.getSize(stdout_fd) catch return;
        if (sameGridSize(size, self.last_size)) {
            self.pending_resize = null;
            self.resize_due_ns = null;
            self.last_size.xpixel = size.xpixel;
            self.last_size.ypixel = size.ypixel;
            return;
        }

        try self.queueResize(size, now_ns);
    }

    fn queueResize(self: *App, size: ptypkg.Winsize, now_ns: i128) !void {
        const pending_changed = if (self.pending_resize) |pending|
            !sameGridSize(size, pending)
        else
            true;

        self.pending_resize = size;
        if (!self.composed) {
            self.resize_due_ns = now_ns;
        } else if (pending_changed or self.resize_due_ns == null) {
            self.resize_due_ns = now_ns + resize_quiet_ns;
        }

        try self.applyPendingResize(now_ns);
    }

    fn applyPendingResize(self: *App, now_ns: i128) !void {
        const size = self.pending_resize orelse return;
        const due_ns = self.resize_due_ns orelse return;
        if (now_ns < due_ns) return;

        self.pending_resize = null;
        self.resize_due_ns = null;
        self.last_size = size;
        self.cell_size = CellSize.fromWinsize(size);
        self.layout = Layout.compute(size.row, size.col, self.composed, self.active_split_rows);
        self.scrollbar_drag = null;
        try self.endComposedMainPassthrough();
        self.flushDeferredMainState();
        try self.main_pane.resize(self.layout.main_rows, self.layout.paneCols(), self.cell_size);
        if (self.split_pane) |pane| {
            try pane.resize(@max(self.layout.split_rows, 1), self.layout.paneCols(), self.cell_size);
        }
        self.compositor.invalidate();
        self.render_scheduler.markDirty(.bulk);
    }
};

test "CLI parsing supports split options and separator" {
    const args = [_][]const u8{
        "tinymux",
        "--split",
        "watch date",
        "--split-rows",
        "5",
        "--split-term",
        "xterm-direct",
        "--",
        "sh",
        "-lc",
        "echo main",
    };
    const cfg = try parseArgs(&args);
    try std.testing.expectEqualStrings("watch date", cfg.split_cmd.?);
    try std.testing.expectEqual(@as(u16, 5), cfg.split_rows);
    try std.testing.expectEqual(TermChoice.xterm_direct, cfg.split_term);
    try std.testing.expectEqualStrings("sh", cfg.main_argv[0]);
}

test "CLI parsing supports raw only mode" {
    const args = [_][]const u8{ "tinymux", "--", "vim" };
    const cfg = try parseArgs(&args);
    try std.testing.expect(cfg.split_cmd == null);
    try std.testing.expect(cfg.kitty_compat);
    try std.testing.expectEqualStrings("vim", cfg.main_argv[0]);
}

test "CLI parsing can disable Kitty compatibility" {
    const args = [_][]const u8{ "tinymux", "--no-kitty-compat", "--", "vim" };
    const cfg = try parseArgs(&args);
    try std.testing.expect(!cfg.kitty_compat);
    try std.testing.expectEqualStrings("vim", cfg.main_argv[0]);
}

test "Kitty parser accepts direnv-instant launch and keeps argv opaque" {
    const args = [_][]const u8{
        "@",
        "--to",
        "unix:/tmp/tinymux.sock",
        "launch",
        "--location",
        "hsplit",
        "--keep-focus",
        "--self",
        "/bin/direnv-instant",
        "watch",
        "/tmp/stderr",
        "/tmp/socket",
    };
    const launch = try parseKittyCommand(&args);
    try std.testing.expectEqualStrings("unix:/tmp/tinymux.sock", launch.address.?);
    try std.testing.expectEqualStrings("/bin/direnv-instant", launch.argv[0]);
    try std.testing.expectEqualStrings("watch", launch.argv[1]);
}

test "Kitty parser accepts equals options" {
    const args = [_][]const u8{
        "@",
        "--to=unix:/tmp/tinymux.sock",
        "launch",
        "--location=hsplit",
        "--keep-focus",
        "--self",
        "sh",
        "-lc",
        "echo split",
    };
    const launch = try parseKittyCommand(&args);
    try std.testing.expectEqualStrings("unix:/tmp/tinymux.sock", launch.address.?);
    try std.testing.expectEqualStrings("sh", launch.argv[0]);
    try std.testing.expectEqualStrings("-lc", launch.argv[1]);
}

test "Kitty parser rejects unsupported layouts" {
    const args = [_][]const u8{
        "@",
        "launch",
        "--location",
        "vsplit",
        "--keep-focus",
        "--self",
        "sh",
    };
    try std.testing.expectError(error.UnsupportedKittyLocation, parseKittyCommand(&args));
}

test "Kitty parser rejects unsupported remote-control commands" {
    const args = [_][]const u8{ "@", "ls" };
    try std.testing.expectError(error.UnsupportedKittyGlobalOption, parseKittyCommand(&args));
}

test "control request failures distinguish client errors from transition failures" {
    try std.testing.expect(App.isControlClientError(error.SplitAlreadyOpen));
    try std.testing.expect(App.isControlClientError(error.UnsupportedPaneOption));
    try std.testing.expect(!App.isControlClientError(error.OutOfMemory));
    try std.testing.expect(!App.isControlClientError(error.InputOutput));
}

test "screen switch mirror forwards only application buffer changes" {
    const alloc = std.testing.allocator;
    var mirror: ScreenSwitchMirror = .{};
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var primary = false;
    var alternate = false;

    try mirror.feed(alloc, "before\x1b[?104", &out, &primary, &alternate);
    try mirror.feed(alloc, "9hafter\x1b[31m\x1b[?1049l", &out, &primary, &alternate);

    try std.testing.expectEqualStrings("\x1b[?1049h\x1b[?1049l", out.items);
    try std.testing.expect(primary);
    try std.testing.expect(alternate);
}

test "host effect mirror forwards generic main terminal semantics" {
    const alloc = std.testing.allocator;
    var mirror: HostEffectMirror = .{};
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try mirror.feed(alloc, "\x1b]133;A\x1b", &out);
    try mirror.feed(alloc, "\\\x1b]52;c;secret\x07\x1b]7;file:///tmp\x07", &out);

    try std.testing.expectEqualStrings("\x1b]133;A\x1b\\\x1b]7;file:///tmp\x07", out.items);
}

test "host effect mirror discards oversized OSC through its terminator" {
    const alloc = std.testing.allocator;
    var mirror: HostEffectMirror = .{};
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try mirror.feed(alloc, "\x1b]52;c;", &out);
    const oversized: [5000]u8 = @splat('x');
    try mirror.feed(alloc, &oversized, &out);
    try mirror.feed(alloc, "\x07\x1b]7;file:///after\x07", &out);

    try std.testing.expectEqualStrings("\x1b]7;file:///after\x07", out.items);
}

test "raw control classifier recognizes locally answered terminal queries" {
    const queries = [_][]const u8{
        "\x1bZ",
        "\x1b[c",
        "\x1b[>0c",
        "\x1b[5n",
        "\x1b[?6n",
        "\x1b[?2048$p",
        "\x1b[>q",
        "\x1b[14t",
        "\x1b[16t",
        "\x1b[18t",
        "\x1b[21t",
        "\x1b[?u",
    };
    for (queries) |query| try std.testing.expect(App.isLocalTerminalQuery(query));

    const passthrough = [_][]const u8{
        "\x1b[31m",
        "\x1b[?1049h",
        "\x1b[22;0t",
        "\x1b[>1u",
        "\x1b]0;title\x07",
    };
    for (passthrough) |sequence| {
        try std.testing.expect(!App.isLocalTerminalQuery(sequence));
    }
}

test "outer input filter recognizes only complete size reports" {
    const reports = [_][]const u8{
        "\x1b[4;384;640t",
        "\x1b[6;16;8t",
        "\x1b[8;24;80t",
        "\x1b[48;24;80;384;640t",
    };
    for (reports) |report| try std.testing.expect(App.isSizeReportResponse(report));

    const input = [_][]const u8{
        "\x1b[18t",
        "\x1b[8;24t",
        "\x1b[48;24;80;384t",
        "\x1b[48;24;bad;384;640t",
        "\x1b[A",
    };
    for (input) |sequence| {
        try std.testing.expect(!App.isSizeReportResponse(sequence));
    }
}

test "terminal mode handoff excludes screen switches and mode 2048" {
    const alloc = std.testing.allocator;
    var filtered: std.ArrayList(u8) = .empty;
    defer filtered.deinit(alloc);
    try appendWithoutScreenSwitchModes(
        alloc,
        &filtered,
        "a\x1b[?1049hb\x1b[?2048hc\x1b[?2048ld\x1b[31me",
    );
    try std.testing.expectEqualStrings("abcd\x1b[31me", filtered.items);
}

test "layout clamps split while preserving rows when possible" {
    const normal = Layout.compute(32, 100, true, 9);
    try std.testing.expectEqual(@as(u16, 22), normal.main_rows);
    try std.testing.expectEqual(@as(u16, 9), normal.split_rows);
    try std.testing.expectEqual(@as(?u16, 22), normal.border_row);
    try std.testing.expect(normal.scrollbarVisible());
    try std.testing.expectEqual(@as(u16, 99), normal.paneCols());
    try std.testing.expectEqual(@as(?u16, 100), normal.scrollbarCol());

    const tiny = Layout.compute(2, 80, true, 9);
    try std.testing.expect(!tiny.split_visible);
    try std.testing.expectEqual(@as(u16, 2), tiny.main_rows);
    try std.testing.expect(!tiny.scrollbarVisible());
    try std.testing.expectEqual(@as(u16, 80), tiny.paneCols());

    const clamped = Layout.compute(4, 80, true, 99);
    try std.testing.expectEqual(@as(u16, 1), clamped.main_rows);
    try std.testing.expectEqual(@as(u16, 2), clamped.split_rows);
}

test "mouse hit testing targets main border and split rows" {
    const layout = Layout.compute(24, 80, true, 9);

    switch (hitTestMouse(layout, true, 10, 5)) {
        .pane => |hit| {
            try std.testing.expectEqual(PaneId.main, hit.pane);
            try std.testing.expectEqual(@as(u16, 10), hit.x);
            try std.testing.expectEqual(@as(u16, 5), hit.y);
        },
        else => return error.ExpectedMainHit,
    }

    switch (hitTestMouse(layout, true, 80, 5)) {
        .scrollbar => |hit| {
            try std.testing.expectEqual(PaneId.main, hit.pane);
            try std.testing.expectEqual(@as(u16, 5), hit.y);
            try std.testing.expectEqual(@as(u16, 14), hit.track_len);
        },
        else => return error.ExpectedMainScrollbarHit,
    }

    switch (hitTestMouse(layout, true, 10, 15)) {
        .border => {},
        else => return error.ExpectedBorderHit,
    }

    switch (hitTestMouse(layout, true, 80, 15)) {
        .border => {},
        else => return error.ExpectedBorderHit,
    }

    switch (hitTestMouse(layout, true, 10, 16)) {
        .pane => |hit| {
            try std.testing.expectEqual(PaneId.split, hit.pane);
            try std.testing.expectEqual(@as(u16, 10), hit.x);
            try std.testing.expectEqual(@as(u16, 1), hit.y);
        },
        else => return error.ExpectedSplitHit,
    }

    switch (hitTestMouse(layout, true, 80, 16)) {
        .scrollbar => |hit| {
            try std.testing.expectEqual(PaneId.split, hit.pane);
            try std.testing.expectEqual(@as(u16, 1), hit.y);
            try std.testing.expectEqual(@as(u16, 9), hit.track_len);
        },
        else => return error.ExpectedSplitScrollbarHit,
    }

    switch (hitTestMouse(layout, true, 81, 16)) {
        .outside => {},
        else => return error.ExpectedOutsideHit,
    }
}

test "winsize grid comparison ignores pixel-only changes" {
    const a = ptypkg.makeWinsize(24, 80);
    var b = ptypkg.makeWinsize(24, 80);
    b.xpixel = 641;
    b.ypixel = 480;

    try std.testing.expect(sameGridSize(a, b));
    try std.testing.expect(!sameGridSize(a, ptypkg.makeWinsize(24, 81)));
    try std.testing.expect(!sameGridSize(a, ptypkg.makeWinsize(25, 80)));
}

test "composed pending resize waits for quiet deadline" {
    const alloc = std.testing.allocator;
    var pane: Pane = .{
        .alloc = alloc,
        .pty_fd = -1,
        .child_pid = 0,
        .command_title = "test",
        .cell_size = .{},
        .term = try initTerminal(alloc, .{ .cols = 80, .rows = 24 }),
        .stream = undefined,
    };
    defer pane.term.deinit(alloc);

    var app: App = .{
        .alloc = alloc,
        .config = .{ .main_argv = &.{"sh"} },
        .layout = Layout.compute(24, 80, false, default_split_rows),
        .main_pane = &pane,
        .split_pane = null,
        .raw_terminal = undefined,
        .compositor = .{ .alloc = alloc },
        .composed = true,
        .last_size = ptypkg.makeWinsize(24, 80),
        .active_split_rows = default_split_rows,
        .cell_size = .{},
    };
    defer app.compositor.deinit();

    const now = 1_000 * std.time.ns_per_ms;
    try app.queueResize(ptypkg.makeWinsize(30, 100), now);

    try std.testing.expectEqual(now + resize_quiet_ns, app.resize_due_ns.?);
    try std.testing.expectEqual(@as(u16, 24), pane.term.rows);
    try std.testing.expectEqual(@as(u16, 80), pane.term.cols);
    try std.testing.expect(app.pending_resize != null);

    try app.queueResize(ptypkg.makeWinsize(32, 120), now + resize_quiet_ns / 2);
    const extended_due = now + resize_quiet_ns / 2 + resize_quiet_ns;
    try std.testing.expectEqual(extended_due, app.resize_due_ns.?);

    try app.applyPendingResize(now + resize_quiet_ns);
    try std.testing.expectEqual(@as(u16, 24), pane.term.rows);
    try std.testing.expectEqual(@as(u16, 80), pane.term.cols);

    try app.applyPendingResize(extended_due);
    try std.testing.expectEqual(app.layout.main_rows, pane.term.rows);
    try std.testing.expectEqual(app.layout.paneCols(), pane.term.cols);
    try std.testing.expect(app.pending_resize == null);
    try std.testing.expect(app.resize_due_ns == null);
    try std.testing.expectEqual(@as(u16, 32), app.last_size.row);
    try std.testing.expectEqual(@as(u16, 120), app.last_size.col);
}

test "outer input protocol establishes and synchronizes composed input state" {
    var protocol_state: OuterInputProtocol = .{};
    const desired: PaneInputState = .{
        .encoding = .{
            .linefeed = true,
            .cursor_keys = true,
            .keypad_keys = true,
            .backarrow_key_mode = true,
            .ignore_keypad_with_numlock = true,
            .alt_esc_prefix = true,
            .alt_sends_escape = true,
            .modify_other_keys_2 = true,
            .kitty_flags = 5,
        },
        .focus_event = true,
        .bracketed_paste = true,
    };

    var enter_bytes: [1024]u8 = undefined;
    var enter_writer = std.Io.Writer.fixed(&enter_bytes);
    try protocol_state.enterComposed(desired, &enter_writer);
    const enter = enter_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, enter, composed_input_reset) != null);
    try std.testing.expect(std.mem.indexOf(u8, enter, composed_input_capture) != null);
    try std.testing.expect(std.mem.indexOf(u8, enter, "\x1b[12h") != null);
    try std.testing.expect(std.mem.indexOf(u8, enter, "\x1b[20h") != null);
    try std.testing.expect(std.mem.indexOf(u8, enter, "\x1b[?1h") != null);
    try std.testing.expect(std.mem.indexOf(u8, enter, "\x1b[?66h") != null);
    try std.testing.expect(std.mem.indexOf(u8, enter, "\x1b[?67h") != null);
    try std.testing.expect(std.mem.indexOf(u8, enter, "\x1b[?1035h") != null);
    try std.testing.expect(std.mem.indexOf(u8, enter, "\x1b[?1036h") != null);
    try std.testing.expect(std.mem.indexOf(u8, enter, "\x1b[?1039h") != null);
    try std.testing.expect(std.mem.indexOf(u8, enter, "\x1b[>4;2m") != null);
    try std.testing.expect(std.mem.indexOf(u8, enter, "\x1b[=5;1u") != null);

    var reset = desired;
    reset.encoding.cursor_keys = false;
    reset.encoding.modify_other_keys_2 = false;
    reset.encoding.kitty_flags = 0;
    reset.focus_event = false;
    reset.bracketed_paste = false;
    var sync_bytes: [256]u8 = undefined;
    var sync_writer = std.Io.Writer.fixed(&sync_bytes);
    try protocol_state.sync(reset, &sync_writer);
    const synced = sync_writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, synced, "\x1b[?1l") != null);
    try std.testing.expect(std.mem.indexOf(u8, synced, "\x1b[>4;0m") != null);
    try std.testing.expect(std.mem.indexOf(u8, synced, "\x1b[=0;1u") != null);
    try std.testing.expect(std.mem.indexOf(u8, synced, "\x1b[?1004l") == null);
    try std.testing.expect(std.mem.indexOf(u8, synced, "\x1b[?2004l") == null);
}

test "every terminal mode has an explicit input ownership policy" {
    try std.testing.expectEqual(InputModePolicy.mirror_to_outer, inputModePolicy(.cursor_keys));
    try std.testing.expectEqual(InputModePolicy.pin_outer_default, inputModePolicy(.autorepeat));
    try std.testing.expectEqual(InputModePolicy.virtualize_in_mux, inputModePolicy(.focus_event));
    try std.testing.expectEqual(InputModePolicy.synthesize_report, inputModePolicy(.report_visibility));
    try std.testing.expectEqual(InputModePolicy.display_state, inputModePolicy(.wraparound));
}

test "outer input protocol observes raw report subscriptions" {
    var protocol_state: OuterInputProtocol = .{};
    protocol_state.noteRawControlSequence("\x1b[?1004h");
    protocol_state.noteRawControlSequence("\x1b[?2004h");
    protocol_state.noteRawControlSequence("\x1b[?2031h");
    protocol_state.noteRawControlSequence("\x1b[?2033h");
    try std.testing.expect(protocol_state.state.focus_event);
    try std.testing.expect(protocol_state.state.bracketed_paste);
    try std.testing.expect(protocol_state.state.report_color_scheme);
    try std.testing.expect(protocol_state.state.report_visibility);

    protocol_state.noteRawControlSequence("\x1b[?1004l");
    protocol_state.noteRawControlSequence("\x1b[?2004l");
    protocol_state.noteRawControlSequence("\x1b[?2031l");
    protocol_state.noteRawControlSequence("\x1b[?2033l");
    try std.testing.expect(!protocol_state.state.focus_event);
    try std.testing.expect(!protocol_state.state.bracketed_paste);
    try std.testing.expect(!protocol_state.state.report_color_scheme);
    try std.testing.expect(!protocol_state.state.report_visibility);
}

test "prefix parser recognizes modifyOtherKeys control-b" {
    const alloc = std.testing.allocator;
    var parser: PrefixParser = .{};
    var result = try parser.feed(alloc, "\x1b[27;5;98~x");
    defer result.deinit(alloc);
    try std.testing.expect(result.close_split);
    try std.testing.expectEqual(@as(usize, 0), result.forwarded.items.len);
}

test "prefix parser closes split and forwards literal prefix" {
    const alloc = std.testing.allocator;
    var parser: PrefixParser = .{};

    var literal = try parser.feed(alloc, "\x02b");
    defer literal.deinit(alloc);
    try std.testing.expectEqualStrings("\x02", literal.forwarded.items);
    try std.testing.expect(!literal.close_split);

    var close = try parser.feed(alloc, "\x02x");
    defer close.deinit(alloc);
    try std.testing.expect(close.close_split);
    try std.testing.expectEqual(@as(usize, 0), close.forwarded.items.len);

    var open = try parser.feed(alloc, "\x02s");
    defer open.deinit(alloc);
    try std.testing.expect(open.open_split);
    try std.testing.expectEqual(@as(usize, 0), open.forwarded.items.len);

    var encoded_prefix = try parser.feed(alloc, "\x1b[98;5u");
    defer encoded_prefix.deinit(alloc);
    try std.testing.expect(!encoded_prefix.open_split);
    try std.testing.expectEqual(@as(usize, 0), encoded_prefix.forwarded.items.len);

    var encoded_open = try parser.feed(alloc, "s");
    defer encoded_open.deinit(alloc);
    try std.testing.expect(encoded_open.open_split);
    try std.testing.expectEqual(@as(usize, 0), encoded_open.forwarded.items.len);
}

test "prefix parser forwards unknown bindings unchanged" {
    const alloc = std.testing.allocator;
    var parser: PrefixParser = .{};
    var result = try parser.feed(alloc, "a\x02zb");
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings("a\x02zb", result.forwarded.items);
}

test "prefix parser forwards non-prefix kitty keys unchanged" {
    const alloc = std.testing.allocator;
    var parser: PrefixParser = .{};
    var result = try parser.feed(alloc, "a\x1b[99;5ub");
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings("a\x1b[99;5ub", result.forwarded.items);
    try std.testing.expect(!result.close_split);
    try std.testing.expect(!result.open_split);
}

test "SGR mouse parser accepts wheel events and preserves partial input" {
    switch (parseSgrMouse("\x1b[<64;10;5M")) {
        .event => |event| {
            try std.testing.expectEqual(@as(u16, 64), event.cb);
            try std.testing.expectEqual(@as(u16, 10), event.x);
            try std.testing.expectEqual(@as(u16, 5), event.y);
            try std.testing.expectEqual(@as(u8, 'M'), event.final);
            try std.testing.expectEqual(@as(usize, 11), event.len);
            try std.testing.expectEqual(WheelAction.up, event.wheelAction().?);
        },
        else => return error.ExpectedSgrMouse,
    }

    switch (parseSgrMouse("\x1b[<65;10;5M")) {
        .event => |event| try std.testing.expectEqual(WheelAction.down, event.wheelAction().?),
        else => return error.ExpectedSgrMouse,
    }
    switch (parseSgrMouse("\x1b[<32;80;2M")) {
        .event => |event| {
            try std.testing.expect(event.isMotion());
            try std.testing.expectEqual(@as(u16, 0), event.baseButton());
        },
        else => return error.ExpectedSgrMouse,
    }
    switch (parseSgrMouse("\x1b[<0;80;2m")) {
        .event => |event| try std.testing.expect(event.isRelease()),
        else => return error.ExpectedSgrMouse,
    }

    switch (parseSgrMouse("\x1b[<64;10;")) {
        .incomplete => {},
        else => return error.ExpectedIncompleteSgrMouse,
    }
    switch (parseSgrMouse("\x1b[<64;x;5M")) {
        .none => {},
        else => return error.ExpectedNoSgrMouse,
    }
    switch (parseSgrMouse("\x1b[64;10;5M")) {
        .none => {},
        else => return error.ExpectedNoSgrMouse,
    }
    switch (parseSgrMouse("\x1b")) {
        .none => {},
        else => return error.ExpectedNoSgrMouse,
    }
    switch (parseSgrMouse("\x1b[")) {
        .none => {},
        else => return error.ExpectedNoSgrMouse,
    }
}

test "mouse forwarding encoder remaps coordinates into child pane space" {
    const alloc = std.testing.allocator;
    var pane: Pane = .{
        .alloc = alloc,
        .pty_fd = -1,
        .child_pid = 0,
        .command_title = "test",
        .cell_size = .{},
        .term = try initTerminal(alloc, .{ .cols = 80, .rows = 9 }),
        .stream = undefined,
    };
    defer pane.term.deinit(alloc);

    const event: SgrMouseEvent = .{ .cb = 64, .x = 10, .y = 20, .final = 'M', .len = 12 };

    var sgr_buf: [64]u8 = undefined;
    var sgr_writer = std.Io.Writer.fixed(&sgr_buf);
    pane.term.flags.mouse_format = .sgr;
    try encodeMouseForPane(&sgr_writer, &pane, event, 10, 5);
    try std.testing.expectEqualStrings("\x1b[<64;10;5M", sgr_writer.buffered());

    var x10_buf: [16]u8 = undefined;
    var x10_writer = std.Io.Writer.fixed(&x10_buf);
    pane.term.flags.mouse_format = .x10;
    try encodeMouseForPane(&x10_writer, &pane, event, 10, 5);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x1b, '[', 'M', 96, 42, 37 }, x10_writer.buffered());
}

test "scrollbar target offset maps gutter rows to absolute scrollback rows" {
    const info: ScrollbarInfo = .{
        .total = 40,
        .offset = 30,
        .len = 10,
        .track_len = 10,
        .thumb_start = 7,
        .thumb_len = 2,
        .max_offset = 30,
        .max_thumb_start = 8,
    };

    try std.testing.expectEqual(@as(usize, 0), scrollbarTargetOffset(info, 1, 0));
    try std.testing.expectEqual(@as(usize, 30), scrollbarTargetOffset(info, 10, 0));
    try std.testing.expect(scrollbarTargetOffset(info, 5, 1) < scrollbarTargetOffset(info, 10, 1));
}

test "render scheduler renders first dirty frame immediately" {
    var scheduler: RenderScheduler = .{};
    const now: i128 = 1_000 * std.time.ns_per_ms;

    scheduler.markDirty(.normal);

    try std.testing.expect(scheduler.shouldRender(now));
    try std.testing.expectEqual(@as(i32, 0), scheduler.pollTimeoutMs(now));
}

test "render scheduler spaces sustained normal damage" {
    var scheduler: RenderScheduler = .{};
    const rendered_at: i128 = 1_000 * std.time.ns_per_ms;

    scheduler.rendered(rendered_at);
    scheduler.markDirty(.normal);

    try std.testing.expect(!scheduler.shouldRender(rendered_at + 3 * std.time.ns_per_ms));
    try std.testing.expectEqual(
        @as(i32, 1),
        scheduler.pollTimeoutMs(rendered_at + 3 * std.time.ns_per_ms),
    );
    try std.testing.expect(scheduler.shouldRender(rendered_at + composed_frame_interval_ns));
}

test "render scheduler urgent damage bypasses frame spacing" {
    var scheduler: RenderScheduler = .{};
    const rendered_at: i128 = 1_000 * std.time.ns_per_ms;

    scheduler.rendered(rendered_at);
    scheduler.markDirty(.urgent);

    try std.testing.expect(scheduler.shouldRender(rendered_at + std.time.ns_per_ms));
    try std.testing.expectEqual(@as(i32, 0), scheduler.pollTimeoutMs(rendered_at + std.time.ns_per_ms));
}

test "render scheduler bulk damage uses bulk frame spacing" {
    var scheduler: RenderScheduler = .{};
    const rendered_at: i128 = 1_000 * std.time.ns_per_ms;

    scheduler.rendered(rendered_at);
    scheduler.markDirty(.urgent);
    scheduler.markDirty(.bulk);

    try std.testing.expect(!scheduler.shouldRender(rendered_at + composed_frame_interval_ns));
    try std.testing.expect(scheduler.shouldRender(rendered_at + bulk_frame_interval_ns));
}

test "render scheduler bounds coalescing under continuous PTY load" {
    var scheduler: RenderScheduler = .{};
    const rendered_at: i128 = 1_000 * std.time.ns_per_ms;

    scheduler.rendered(rendered_at);
    scheduler.markDirty(.bulk);

    try std.testing.expect(!scheduler.mustRenderUnderLoad(rendered_at + bulk_max_coalesce_ns - 1));
    try std.testing.expect(scheduler.mustRenderUnderLoad(rendered_at + bulk_max_coalesce_ns));
}

test "render scheduler keeps bulk mode sticky briefly" {
    var scheduler: RenderScheduler = .{};
    const bulk_at: i128 = 1_000 * std.time.ns_per_ms;

    scheduler.noteBulk(bulk_at);

    try std.testing.expect(scheduler.bulkActive(bulk_at + bulk_sticky_window_ns - 1));
    try std.testing.expect(!scheduler.bulkActive(bulk_at + bulk_sticky_window_ns));
}

test "render scheduler normal damage clears bulk pacing" {
    var scheduler: RenderScheduler = .{};
    const rendered_at: i128 = 1_000 * std.time.ns_per_ms;

    scheduler.rendered(rendered_at);
    scheduler.markDirty(.bulk);
    scheduler.markDirty(.normal);

    try std.testing.expect(scheduler.shouldRender(rendered_at + composed_frame_interval_ns));
}

test "render scheduler clean state idles without rendering" {
    const scheduler: RenderScheduler = .{};

    try std.testing.expect(!scheduler.shouldRender(0));
    try std.testing.expectEqual(@as(i32, composed_idle_poll_ms), scheduler.pollTimeoutMs(0));
}

test "render scheduler recent input lowers drain budget" {
    var scheduler: RenderScheduler = .{};
    const input_at: i128 = 1_000 * std.time.ns_per_ms;

    scheduler.noteInput(input_at);

    var small: DrainStats = .{};
    small.record(1);

    try std.testing.expectEqual(
        @as(i128, interactive_pty_drain_budget_ns),
        scheduler.ptyDrainBudget(input_at + interactive_input_window_ns, small),
    );
    try std.testing.expectEqual(
        @as(i128, bulk_pty_drain_budget_ns),
        scheduler.ptyDrainBudget(input_at + interactive_input_window_ns + 1, small),
    );
}

test "render scheduler bulk first read overrides recent input drain budget" {
    var scheduler: RenderScheduler = .{};
    const input_at: i128 = 1_000 * std.time.ns_per_ms;
    scheduler.noteInput(input_at);

    var bulk: DrainStats = .{};
    bulk.record(bulk_damage_bytes);

    try std.testing.expectEqual(
        @as(i128, bulk_pty_drain_budget_ns),
        scheduler.ptyDrainBudget(input_at + std.time.ns_per_ms, bulk),
    );
}

test "render scheduler treats small multi-read echo after input as urgent" {
    var scheduler: RenderScheduler = .{};
    const input_at: i128 = 1_000 * std.time.ns_per_ms;
    scheduler.noteInput(input_at);

    var echo: DrainStats = .{};
    for (0..bulk_damage_reads) |_| echo.record(8);

    try std.testing.expect(echo.bulkish());
    try std.testing.expectEqual(
        RenderScheduler.DirtyKind.urgent,
        scheduler.dirtyKindForDamage(input_at + std.time.ns_per_ms, echo),
    );
    try std.testing.expect(!scheduler.bulkActive(input_at + std.time.ns_per_ms));
}

test "drain stats classify sustained output as bulk" {
    var by_bytes: DrainStats = .{};
    by_bytes.record(bulk_damage_bytes);
    try std.testing.expect(by_bytes.bulkish());

    var by_reads: DrainStats = .{};
    for (0..bulk_damage_reads) |_| by_reads.record(1);
    try std.testing.expect(by_reads.bulkish());

    var small: DrainStats = .{};
    small.record(1);
    try std.testing.expect(!small.bulkish());
}

test "plain passthrough cursor state tracks soft wraps" {
    var state = (plainPassthroughEndState("abcd", 5, .{}) orelse return error.ExpectedCursorState);
    try std.testing.expectEqual(@as(u16, 4), state.col);
    try std.testing.expect(!state.pending_wrap);

    state = (plainPassthroughEndState("e", 5, state) orelse return error.ExpectedCursorState);
    try std.testing.expectEqual(@as(u16, 4), state.col);
    try std.testing.expect(state.pending_wrap);

    state = (plainPassthroughEndState("f", 5, state) orelse return error.ExpectedCursorState);
    try std.testing.expectEqual(@as(u16, 1), state.col);
    try std.testing.expect(!state.pending_wrap);

    state = (plainPassthroughEndState("\rxy", 5, state) orelse return error.ExpectedCursorState);
    try std.testing.expectEqual(@as(u16, 2), state.col);
    try std.testing.expect(!state.pending_wrap);

    state = (plainPassthroughEndState("z\nq", 5, state) orelse return error.ExpectedCursorState);
    try std.testing.expectEqual(@as(u16, 4), state.col);
    try std.testing.expect(!state.pending_wrap);
}

test "plain ascii fast feed matches vt stream repaint" {
    const alloc = std.testing.allocator;
    var fast: Pane = .{
        .alloc = alloc,
        .pty_fd = -1,
        .child_pid = 0,
        .command_title = "fast",
        .cell_size = .{},
        .term = try initTerminal(alloc, .{ .cols = 8, .rows = 3, .max_scrollback_bytes = scrollback_bytes }),
        .stream = undefined,
    };
    defer fast.term.deinit(alloc);
    fast.stream = .initAlloc(alloc, Pane.StreamHandler.init(&fast));
    defer fast.stream.deinit();

    var slow: Pane = .{
        .alloc = alloc,
        .pty_fd = -1,
        .child_pid = 0,
        .command_title = "slow",
        .cell_size = .{},
        .ascii_fast_feed_enabled = false,
        .term = try initTerminal(alloc, .{ .cols = 8, .rows = 3, .max_scrollback_bytes = scrollback_bytes }),
        .stream = undefined,
    };
    defer slow.term.deinit(alloc);
    slow.stream = .initAlloc(alloc, Pane.StreamHandler.init(&slow));
    defer slow.stream.deinit();

    const input =
        "one\r\n" ++
        "two\r\n" ++
        "three\r\n" ++
        "four\r\n" ++
        "five\r\n";
    fast.feed(input);
    slow.feed(input);

    const fast_repaint = try fast.repaint(alloc);
    defer alloc.free(fast_repaint);
    const slow_repaint = try slow.repaint(alloc);
    defer alloc.free(slow_repaint);

    try std.testing.expectEqualStrings(slow_repaint, fast_repaint);
    try std.testing.expectEqual(slow.pending_scroll_count, fast.pending_scroll_count);
}

test "composed cursor mirrors child cursor style" {
    const alloc = std.testing.allocator;
    var pane: Pane = .{
        .alloc = alloc,
        .pty_fd = -1,
        .child_pid = 0,
        .command_title = "test",
        .cell_size = .{},
        .term = try initTerminal(alloc, .{ .cols = 10, .rows = 5 }),
        .stream = undefined,
    };
    defer pane.term.deinit(alloc);
    var stream = pane.term.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b[3;4H");
    pane.term.screens.active.cursor.cursor_style = .bar;
    pane.term.modes.set(.cursor_blinking, true);

    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeComposedCursor(&writer, Layout.compute(5, 10, false, 0), &pane);

    try std.testing.expectEqualStrings("\x1b[5 q\x1b[3;4H\x1b[?25h", writer.buffered());
}

test "composed cursor mirrors child cursor visibility" {
    const alloc = std.testing.allocator;
    var pane: Pane = .{
        .alloc = alloc,
        .pty_fd = -1,
        .child_pid = 0,
        .command_title = "test",
        .cell_size = .{},
        .term = try initTerminal(alloc, .{ .cols = 10, .rows = 5 }),
        .stream = undefined,
    };
    defer pane.term.deinit(alloc);
    pane.term.modes.set(.cursor_visible, false);

    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeComposedCursor(&writer, Layout.compute(5, 10, false, 0), &pane);

    try std.testing.expectEqualStrings("\x1b[2 q\x1b[1;1H\x1b[?25l", writer.buffered());
}

test "composed cursor hides when child cursor is outside the viewport" {
    const alloc = std.testing.allocator;
    var pane: Pane = .{
        .alloc = alloc,
        .pty_fd = -1,
        .child_pid = 0,
        .command_title = "test",
        .cell_size = .{},
        .term = try initTerminal(alloc, .{ .cols = 10, .rows = 3, .max_scrollback_bytes = scrollback_bytes }),
        .stream = undefined,
    };
    defer pane.term.deinit(alloc);

    var stream = pane.term.vtStream();
    defer stream.deinit();
    stream.nextSlice("one\r\ntwo\r\nthree\r\nfour");
    pane.term.scrollViewport(.{ .delta = -1 });

    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeComposedCursor(&writer, Layout.compute(3, 10, false, 0), &pane);

    try std.testing.expectEqualStrings("\x1b[2 q\x1b[?25l", writer.buffered());
}

test "cursor style maps Ghostty-only hollow block to DECSCUSR block" {
    var buf: [16]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try writeCursorStyle(&writer, .block_hollow, false);

    try std.testing.expectEqualStrings("\x1b[2 q", writer.buffered());
}

test "pane stream handler records full-pane upward scrolls" {
    const alloc = std.testing.allocator;

    var pane: Pane = undefined;
    pane.alloc = alloc;
    pane.pty_fd = -1;
    pane.child_pid = 0;
    pane.alive = false;
    pane.reaped = true;
    pane.command_title = "test";
    pane.reply_route = .discard;
    pane.cell_size = .{};
    pane.term = try initTerminal(alloc, .{ .cols = 20, .rows = 3 });
    defer pane.term.deinit(alloc);
    pane.pending_scroll_count = 0;
    pane.pending_scroll_overflow = false;
    pane.stream = .initAlloc(alloc, Pane.StreamHandler.init(&pane));
    defer pane.stream.deinit();

    pane.feed("one\r\ntwo\r\nthree\r\nfour\r\n");

    const pending = pane.takePendingScrolls();
    try std.testing.expect(!pending.overflow);
    try std.testing.expectEqual(@as(usize, 1), pending.len);
    try std.testing.expectEqual(vt.ScreenSet.Key.primary, pending.items[0].screen);
    try std.testing.expectEqual(@as(u16, 0), pending.items[0].top);
    try std.testing.expectEqual(@as(u16, 2), pending.items[0].bottom);
    try std.testing.expectEqual(@as(usize, 2), pending.items[0].count);
}

test "pane stream handler keeps alternate-screen scrolls separate" {
    const alloc = std.testing.allocator;

    var pane: Pane = undefined;
    pane.alloc = alloc;
    pane.pty_fd = -1;
    pane.child_pid = 0;
    pane.alive = false;
    pane.reaped = true;
    pane.command_title = "test";
    pane.reply_route = .discard;
    pane.cell_size = .{};
    pane.term = try initTerminal(alloc, .{ .cols = 20, .rows = 3 });
    defer pane.term.deinit(alloc);
    pane.pending_scroll_count = 0;
    pane.pending_scroll_overflow = false;
    pane.stream = .initAlloc(alloc, Pane.StreamHandler.init(&pane));
    defer pane.stream.deinit();

    pane.feed("\x1b[?1049h\x1b[1S");

    const pending = pane.takePendingScrolls();
    try std.testing.expect(!pending.overflow);
    try std.testing.expectEqual(@as(usize, 1), pending.len);
    try std.testing.expectEqual(vt.ScreenSet.Key.alternate, pending.items[0].screen);
    try std.testing.expectEqual(@as(u16, 0), pending.items[0].top);
    try std.testing.expectEqual(@as(u16, 2), pending.items[0].bottom);
    try std.testing.expectEqual(@as(usize, 1), pending.items[0].count);
}

test "pane feed repairs stale cursor caches before erase line" {
    const alloc = std.testing.allocator;

    var pane: Pane = .{
        .alloc = alloc,
        .pty_fd = -1,
        .child_pid = 0,
        .alive = false,
        .reaped = true,
        .command_title = "test",
        .cell_size = .{},
        .term = try initTerminal(alloc, .{ .cols = 20, .rows = 3 }),
        .stream = undefined,
    };
    defer pane.term.deinit(alloc);
    pane.stream = .initAlloc(alloc, Pane.StreamHandler.init(&pane));
    defer pane.stream.deinit();

    const screen = pane.term.screens.active;
    const stale_row = screen.cursor.page_pin.down(1).?.rowAndCell();
    const stale_cell = screen.cursor.page_pin.down(2).?.rowAndCell();
    screen.cursor.page_row = stale_row.row;
    screen.cursor.page_cell = stale_cell.cell;

    pane.feed("\x1b[K");

    const expected = screen.cursor.page_pin.rowAndCell();
    try std.testing.expectEqual(expected.row, screen.cursor.page_row);
    try std.testing.expectEqual(expected.cell, screen.cursor.page_cell);
    try std.testing.expectEqual(@as(u64, 1), pane.cursor_repair_count);
    try std.testing.expect(pane.model_epoch > 0);
}

test "lazygit-style bottom-row loader preserves the alternate-screen top row" {
    const alloc = std.testing.allocator;

    var pane: Pane = .{
        .alloc = alloc,
        .pty_fd = -1,
        .child_pid = 0,
        .alive = false,
        .reaped = true,
        .command_title = "test",
        .cell_size = .{},
        .term = try initTerminal(alloc, .{ .cols = 20, .rows = 4 }),
        .stream = undefined,
    };
    defer pane.term.deinit(alloc);
    pane.stream = .initAlloc(alloc, Pane.StreamHandler.init(&pane));
    defer pane.stream.deinit();

    pane.feed(
        "\x1b[?1049h\x1b[2J" ++
            "\x1b[1;1HTOP_SENTINEL" ++
            "\x1b[4;1H\x1b[2KLOAD_FRAME_1" ++
            "\x1b[4;1H\x1b[2KLOAD_FRAME_2" ++
            "\x1b[4;1H\x1b[2KLOAD_DONE",
    );

    var top: std.ArrayList(u8) = .empty;
    defer top.deinit(alloc);
    try appendTermRow(alloc, &pane.term, 0, &top);
    var bottom: std.ArrayList(u8) = .empty;
    defer bottom.deinit(alloc);
    try appendTermRow(alloc, &pane.term, 3, &bottom);

    try std.testing.expectEqual(vt.ScreenSet.Key.alternate, pane.term.screens.active_key);
    try std.testing.expect(std.mem.indexOf(u8, top.items, "TOP_SENTINEL") != null);
    try std.testing.expect(std.mem.indexOf(u8, bottom.items, "LOAD_DONE") != null);
    try std.testing.expectEqual(@as(u16, 3), pane.term.screens.active.cursor.y);
}

test "pane stream handler records partial-region upward scrolls" {
    const alloc = std.testing.allocator;

    var pane: Pane = undefined;
    pane.alloc = alloc;
    pane.pty_fd = -1;
    pane.child_pid = 0;
    pane.alive = false;
    pane.reaped = true;
    pane.command_title = "test";
    pane.reply_route = .discard;
    pane.cell_size = .{};
    pane.term = try initTerminal(alloc, .{ .cols = 20, .rows = 5 });
    defer pane.term.deinit(alloc);
    pane.pending_scroll_count = 0;
    pane.pending_scroll_overflow = false;
    pane.stream = .initAlloc(alloc, Pane.StreamHandler.init(&pane));
    defer pane.stream.deinit();

    pane.feed("\x1b[2;5r\x1b[1S");

    const pending = pane.takePendingScrolls();
    try std.testing.expect(!pending.overflow);
    try std.testing.expectEqual(@as(usize, 1), pending.len);
    try std.testing.expectEqual(vt.ScreenSet.Key.primary, pending.items[0].screen);
    try std.testing.expectEqual(@as(u16, 1), pending.items[0].top);
    try std.testing.expectEqual(@as(u16, 4), pending.items[0].bottom);
    try std.testing.expectEqual(@as(usize, 1), pending.items[0].count);
}

test "graphics update ignores text-only scroll dirty without placements" {
    const alloc = std.testing.allocator;
    var pane: Pane = .{
        .alloc = alloc,
        .pty_fd = -1,
        .child_pid = 0,
        .command_title = "test",
        .cell_size = .{},
        .term = try initTerminal(alloc, .{
            .cols = 10,
            .rows = 3,
            .max_scrollback_bytes = scrollback_bytes,
            .kitty_image_storage_limit = kitty_image_storage_limit,
            .kitty_image_loading_limits = kitty_image_loading_limits,
        }),
        .stream = undefined,
    };
    defer pane.term.deinit(alloc);

    pane.term.screens.active.kitty_images.dirty = true;
    var graphics: GraphicsState = .{};
    defer graphics.deinit(alloc);

    try std.testing.expect(!graphics.needsUpdate(&pane, null));
}

test "pane row cache detects upward viewport scroll" {
    const alloc = std.testing.allocator;

    var term = try initTerminal(alloc, .{ .cols = 20, .rows = 4 });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();

    stream.nextSlice("\x1b[HAAA\r\nBBB\r\nCCC\r\nDDD");

    var cache: PaneRowCache = .{};
    defer cache.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    for (0..4) |y| {
        out.clearRetainingCapacity();
        try cache.appendRow(alloc, &term, @intCast(y), false, &out);
    }
    term.screens.active.pages.clearDirty();

    stream.nextSlice("\r\nEEE");

    try std.testing.expectEqual(@as(u16, 1), cache.detectScrollUp(&term, 4, false));
    cache.rotateRegionScrollUp(0, 4, 1);

    for (0..3) |y| {
        const pin = viewportPin(&term, @intCast(y)).?;
        try std.testing.expect(cache.rows.items[y].matchesPin(pin));
    }
    try std.testing.expect(!cache.rows.items[3].valid);
}

test "pane viewport scroll changes visible top row" {
    const alloc = std.testing.allocator;

    var term = try initTerminal(alloc, .{ .cols = 20, .rows = 3, .max_scrollback_bytes = scrollback_bytes });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();

    stream.nextSlice("one\r\ntwo\r\nthree\r\nfour");
    const before = viewportPin(&term, 0).?;
    term.scrollViewport(.{ .delta = -1 });
    const after = viewportPin(&term, 0).?;

    try std.testing.expect(!before.eql(after));
}

test "outer row cache rotation clears newly exposed rows" {
    const alloc = std.testing.allocator;

    var compositor: Compositor = .{ .alloc = alloc };
    defer compositor.deinit();

    while (compositor.row_cache.items.len < 4) try compositor.row_cache.append(alloc, .empty);
    for (compositor.row_cache.items, 0..) |*row, i| {
        try row.print(alloc, "row{d}", .{i});
    }

    compositor.rotateOuterRowsForRegion(0, 4, 1);

    try std.testing.expectEqualStrings("row1", compositor.row_cache.items[0].items);
    try std.testing.expectEqualStrings("row2", compositor.row_cache.items[1].items);
    try std.testing.expectEqualStrings("row3", compositor.row_cache.items[2].items);
    try std.testing.expectEqual(@as(usize, 0), compositor.row_cache.items[3].items.len);
}

test "outer row cache rotation works for split region" {
    const alloc = std.testing.allocator;

    var compositor: Compositor = .{ .alloc = alloc };
    defer compositor.deinit();

    while (compositor.row_cache.items.len < 6) try compositor.row_cache.append(alloc, .empty);
    for (compositor.row_cache.items, 0..) |*row, i| {
        try row.print(alloc, "row{d}", .{i});
    }

    compositor.rotateOuterRowsForRegion(4, 2, 1);

    try std.testing.expectEqualStrings("row0", compositor.row_cache.items[0].items);
    try std.testing.expectEqualStrings("row3", compositor.row_cache.items[3].items);
    try std.testing.expectEqualStrings("row5", compositor.row_cache.items[4].items);
    try std.testing.expectEqual(@as(usize, 0), compositor.row_cache.items[5].items.len);
}

test "split pane scroll fast path emits split scroll region" {
    const alloc = std.testing.allocator;

    var compositor: Compositor = .{ .alloc = alloc };
    defer compositor.deinit();

    const layout = Layout.compute(6, 20, true, 2);
    try compositor.emitScrollUp(layout.splitTop(), layout.split_rows, 1);

    try std.testing.expectEqualStrings("\x1b[5;6r\x1b[1S\x1b[r", compositor.body.items);
}

test "composed panes never mutate the outer terminal with a scroll fast path" {
    const alloc = std.testing.allocator;

    var compositor: Compositor = .{ .alloc = alloc };
    defer compositor.deinit();
    compositor.full_render = false;

    var graphics: GraphicsState = .{};
    defer graphics.deinit(alloc);

    try std.testing.expect(!compositor.canPaneScrollFastPath(&graphics, .primary, 3, false));
    try std.testing.expect(!compositor.canPaneScrollFastPath(&graphics, .alternate, 3, false));
}

test "term selection preserves graphics-capable outer terminals" {
    try std.testing.expectEqualStrings("xterm-ghostty", selectTerm(.auto, "xterm-ghostty", null));
    try std.testing.expectEqualStrings("xterm-kitty", selectTerm(.auto, "xterm-kitty", null));
    try std.testing.expectEqualStrings("xterm-direct", selectTerm(.auto, "xterm-256color", "truecolor"));
    try std.testing.expectEqualStrings("xterm-256color", selectTerm(.auto, "xterm-256color", null));
    try std.testing.expectEqualStrings("xterm-direct", selectTerm(.xterm_direct, null, null));
    try std.testing.expectEqualStrings("xterm-256color", selectTerm(.xterm_256color, null, null));
    try std.testing.expectEqualStrings("xterm-ghostty", selectTerm(.xterm_ghostty, null, null));
    try std.testing.expectEqualStrings("xterm-kitty", selectTerm(.xterm_kitty, null, null));
}

test "raw graphics handoff preserves application image references and placements" {
    if (comptime !kitty_graphics_enabled) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var pane: Pane = .{
        .alloc = alloc,
        .pty_fd = -1,
        .child_pid = 0,
        .command_title = "test",
        .cell_size = .{},
        .term = try initTerminal(alloc, .{
            .cols = 10,
            .rows = 5,
            .max_scrollback_bytes = scrollback_bytes,
            .kitty_image_storage_limit = kitty_image_storage_limit,
            .kitty_image_loading_limits = kitty_image_loading_limits,
        }),
        .stream = undefined,
    };
    defer pane.term.deinit(alloc);
    pane.cell_size.applyToTerm(&pane.term);

    var stream = pane.term.vtStream();
    defer stream.deinit();
    stream.nextSlice(
        "\x1b[4;6H" ++
            "\x1b_Ga=T,f=24,t=d,i=77,p=23,s=1,v=1,c=2,r=2,q=2;////\x1b\\" ++
            "\x1b[2;3H" ++
            "\x1b_Ga=T,f=24,t=d,I=42,p=24,s=1,v=1,c=1,r=1,q=2;////\x1b\\" ++
            "\x1b[3;4H" ++
            "\x1b_Ga=T,f=24,t=d,I=42,p=25,s=1,v=1,c=1,r=1,q=2;AAAA\x1b\\",
    );

    const newest_numbered_id = pane.term.screens.active.kitty_images.imageByNumber(42).?.id;
    var older_numbered_id: ?u32 = null;
    var numbered_iter = pane.term.screens.active.kitty_images.images.iterator();
    while (numbered_iter.next()) |entry| {
        if (entry.value_ptr.number == 42 and entry.key_ptr.* != newest_numbered_id) {
            older_numbered_id = entry.key_ptr.*;
        }
    }
    try std.testing.expect(older_numbered_id != null);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var ownership: RawGraphicsOwnership = .{};
    defer ownership.deinit(alloc);
    try std.testing.expect(try appendRawGraphicsRemoval(alloc, &out, &pane, &ownership));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "a=d,d=I,i=77") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out.items, "a=d,d=N,I=42"));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "d=p") == null);

    out.clearRetainingCapacity();
    try appendRawGraphicsRestore(alloc, &out, &pane);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "a=t,t=d,f=24,s=1,v=1,i=77") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.items, "a=t,t=d,f=24,s=1,v=1,I=42"));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "a=p,i=77,p=23") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "a=p,I=42,p=25") != null);
    var older_upload_buf: [96]u8 = undefined;
    const older_upload = try std.fmt.bufPrint(
        &older_upload_buf,
        "a=t,t=d,f=24,s=1,v=1,i={d}",
        .{older_numbered_id.?},
    );
    try std.testing.expect(std.mem.indexOf(u8, out.items, older_upload) != null);
    var older_placement_buf: [64]u8 = undefined;
    const older_placement = try std.fmt.bufPrint(
        &older_placement_buf,
        "a=p,i={d},p=24",
        .{older_numbered_id.?},
    );
    try std.testing.expect(std.mem.indexOf(u8, out.items, older_placement) != null);

    try ownership.capture(alloc, &pane);
    out.clearRetainingCapacity();
    try std.testing.expect(try appendRawGraphicsRemoval(alloc, &out, &pane, &ownership));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.items, "a=d,d=N,I=42"));
    var older_delete_buf: [64]u8 = undefined;
    const older_delete = try std.fmt.bufPrint(
        &older_delete_buf,
        "a=d,d=I,i={d}",
        .{older_numbered_id.?},
    );
    try std.testing.expect(std.mem.indexOf(u8, out.items, older_delete) != null);
}

test "graphics replay keeps image upload cached across placement updates" {
    if (comptime !kitty_graphics_enabled) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var pane: Pane = .{
        .alloc = alloc,
        .pty_fd = -1,
        .child_pid = 0,
        .command_title = "test",
        .cell_size = .{},
        .term = try initTerminal(alloc, .{
            .cols = 10,
            .rows = 5,
            .max_scrollback_bytes = scrollback_bytes,
            .kitty_image_storage_limit = kitty_image_storage_limit,
            .kitty_image_loading_limits = kitty_image_loading_limits,
        }),
        .stream = undefined,
    };
    defer pane.term.deinit(alloc);
    pane.cell_size.applyToTerm(&pane.term);

    var stream = pane.term.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b_Ga=T,f=24,t=d,i=1,s=1,v=1,c=1,r=1,q=2;////\x1b\\");

    var graphics: GraphicsState = .{};
    defer graphics.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const layout = Layout.compute(5, 10, false, 0);
    try graphics.render(alloc, &out, layout, &pane, null, true);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b_Ga=t") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "f=24,s=1,v=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[1;1H\x1b_Ga=p") != null);
    try std.testing.expect(!pane.term.screens.active.kitty_images.dirty);

    out.clearRetainingCapacity();
    pane.term.screens.active.kitty_images.dirty = true;
    try graphics.render(alloc, &out, layout, &pane, null, false);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b_Ga=t") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b_Ga=d,d=i") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[1;1H\x1b_Ga=p") != null);
    try std.testing.expect(!pane.term.screens.active.kitty_images.dirty);
}

test "graphics replay skips garbage placement pins after scrollback pruning" {
    if (comptime !kitty_graphics_enabled) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var pane: Pane = .{
        .alloc = alloc,
        .pty_fd = -1,
        .child_pid = 0,
        .command_title = "test",
        .cell_size = .{},
        .term = try initTerminal(alloc, .{
            .cols = 10,
            .rows = 5,
            .max_scrollback_bytes = scrollback_bytes,
            .kitty_image_storage_limit = kitty_image_storage_limit,
            .kitty_image_loading_limits = kitty_image_loading_limits,
        }),
        .stream = undefined,
    };
    defer pane.term.deinit(alloc);
    pane.cell_size.applyToTerm(&pane.term);

    var stream = pane.term.vtStream();
    defer stream.deinit();
    stream.nextSlice("\x1b_Ga=T,f=24,t=d,i=1,s=1,v=1,c=1,r=1,q=2;////\x1b\\");

    var graphics: GraphicsState = .{};
    defer graphics.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const layout = Layout.compute(5, 10, false, 0);
    try graphics.render(alloc, &out, layout, &pane, null, true);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[1;1H\x1b_Ga=p") != null);

    var iter = pane.term.screens.active.kitty_images.placements.iterator();
    while (iter.next()) |entry| {
        switch (entry.value_ptr.location) {
            .pin => |pin| pin.garbage = true,
            .virtual => {},
        }
    }

    out.clearRetainingCapacity();
    pane.term.screens.active.kitty_images.dirty = true;
    try graphics.render(alloc, &out, layout, &pane, null, false);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b_Ga=d,d=i") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b_Ga=p") == null);
    try std.testing.expect(!pane.term.screens.active.kitty_images.dirty);
}

test "viewport row cache invalidates clean rows that scrolled" {
    const alloc = std.testing.allocator;

    var term = try initTerminal(alloc, .{ .cols = 20, .rows = 4 });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();

    stream.nextSlice("\x1b[HAAA\r\nBBB\r\nCCC\r\nDDD");
    const screen = term.screens.active;

    var entries: [4]ViewportRow = .{ .{}, .{}, .{}, .{} };
    defer for (&entries) |*entry| entry.deinit(alloc);
    for (0..4) |y| {
        const pin = screen.pages.pin(.{ .viewport = .{ .x = 0, .y = @intCast(y) } }).?;
        try appendTermRow(alloc, &term, @intCast(y), &entries[y].bytes);
        entries[y].capturePin(pin);
    }
    screen.pages.clearDirty();

    for (0..4) |y| {
        const pin = screen.pages.pin(.{ .viewport = .{ .x = 0, .y = @intCast(y) } }).?;
        try std.testing.expect(viewportRowReusable(&entries[y], pin, false));
    }

    stream.nextSlice("\r\nEEE");
    var clean_moved: usize = 0;
    for (0..4) |y| {
        const pin = screen.pages.pin(.{ .viewport = .{ .x = 0, .y = @intCast(y) } }).?;
        if (!pin.isDirty()) {
            clean_moved += 1;
            try std.testing.expect(!viewportRowReusable(&entries[y], pin, false));
        }
    }
    try std.testing.expect(clean_moved > 0);
}
