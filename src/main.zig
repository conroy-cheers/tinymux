const std = @import("std");
const posix = std.posix;
const vt = @import("ghostty-vt");
const ptypkg = @import("pty.zig");
const protocol = @import("protocol.zig");

pub const version = "0.1.0";

const stdin_fd: posix.fd_t = 0;
const stdout_fd: posix.fd_t = 1;

const default_split_rows: u16 = 9;
const exit_drain_ms: i64 = 50;
const raw_transition_drain_ms: i64 = 120;
const raw_transition_idle_ms: i32 = 10;
const composed_idle_poll_ms: i32 = 50;
const composed_frame_interval_ns: i128 = 4 * std.time.ns_per_ms;
const bulk_frame_interval_ns: i128 = 8 * std.time.ns_per_ms;
const bulk_sticky_window_ns: i128 = 120 * std.time.ns_per_ms;
const interactive_input_window_ns: i128 = 50 * std.time.ns_per_ms;
const interactive_pty_drain_budget_ns: i128 = 1 * std.time.ns_per_ms;
const bulk_pty_drain_budget_ns: i128 = 6 * std.time.ns_per_ms;
const pty_drain_max_reads: usize = 128;
const pty_drain_max_bytes: usize = 8 * 1024 * 1024;
const bulk_damage_bytes: usize = 16 * 1024;
const bulk_damage_reads: usize = 2;
const scrollback_bytes: usize = 512 * 1024;
const kitty_image_storage_limit: usize = 320 * 1024 * 1024;
const kitty_upload_chunk_bytes: usize = 3000;
const outer_image_id_start: u32 = 0x70000000;
const default_cell_width: u32 = 8;
const default_cell_height: u32 = 16;
const kitty_graphics_enabled = @hasField(vt.Screen, "kitty_images");

const sgr_reset = "\x1b[0m";
const style_dim = "\x1b[2m";
const synchronized_update_begin = "\x1b[?2026h";
const synchronized_update_end = "\x1b[?2026l";
const enter_canvas = "\x1b[?1049h\x1b[?25l\x1b[H\x1b[2J";
const leave_canvas = restore_terminal_sequence ++ "\x1b[?1049l";

extern "c" fn cfmakeraw(termios_p: *posix.termios) void;

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

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const alloc = debug_allocator.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    const config = parseArgs(args) catch |err| {
        try printUsage(err);
        return err;
    };

    var app = try App.init(alloc, config);
    defer app.deinit();
    try app.run();
}

fn printUsage(err: anyerror) !void {
    var stderr = std.fs.File.stderr().writer(&.{});
    try stderr.interface.print(
        \\tinymux: {s}
        \\
        \\usage:
        \\  tinymux --split <split-cmd> [--split-rows <n>] [--split-term auto|xterm-256color|xterm-direct|xterm-kitty|xterm-ghostty] -- <main-argv...>
        \\  tinymux -- <main-argv...>
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
        return containsIgnoreCase(term, "kitty") or containsIgnoreCase(term, "ghostty");
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
    main_argv: []const []const u8,
};

fn parseArgs(args: []const []const u8) !Config {
    var config: Config = .{ .main_argv = &.{} };
    var i: usize = 1;
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
        } else {
            return error.UnknownArgument;
        }
        i += 1;
    }
    if (!saw_separator) return error.MissingCommandSeparator;
    if (i >= args.len) return error.MissingMainCommand;
    config.main_argv = args[i..];
    return config;
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

const Pane = struct {
    alloc: std.mem.Allocator,
    pty_fd: posix.fd_t,
    child_pid: posix.pid_t,
    alive: bool = true,
    reaped: bool = false,
    command_title: []const u8,
    passthrough: bool = false,
    feeding_discarded: bool = false,
    cell_size: CellSize,
    term: vt.Terminal,
    stream: Stream,
    pending_scroll_up: usize = 0,

    pub const TerminalHandler = vt.TerminalStream.Handler;
    pub const Stream = vt.Stream(StreamHandler);

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
                .color_scheme = null,
                .device_attributes = effectDeviceAttributes,
                .enquiry = null,
                .size = effectSize,
                .title_changed = null,
                .pwd_changed = null,
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
            const scroll_up = self.fullPaneScrollUp(action, value);
            self.terminal_handler.vt(action, value);
            if (scroll_up > 0) self.pane.noteScrollUp(scroll_up);
        }

        fn fullPaneScrollUp(
            self: *StreamHandler,
            comptime action: Action.Tag,
            value: Action.Value(action),
        ) usize {
            const term = self.terminal_handler.terminal;
            if (!fullPaneScrollRegion(term)) return 0;
            return switch (action) {
                .linefeed, .index, .next_line => if (cursorWillScrollUp(term)) 1 else 0,
                .scroll_up => @min(value, term.rows),
                else => 0,
            };
        }

        fn fullPaneScrollRegion(term: *const Terminal) bool {
            return term.rows > 0 and term.cols > 0 and
                term.scrolling_region.top == 0 and
                term.scrolling_region.bottom == term.rows - 1 and
                term.scrolling_region.left == 0 and
                term.scrolling_region.right == term.cols - 1;
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
        env: *std.process.EnvMap,
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
        errdefer posix.close(spawned.master);

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
            try vt.Terminal.init(alloc, .{
                .cols = cols,
                .rows = rows,
                .max_scrollback = scrollback_bytes,
                .kitty_image_storage_limit = kitty_image_storage_limit,
                .kitty_image_loading_limits = .all,
            })
        else
            try vt.Terminal.init(alloc, .{
                .cols = cols,
                .rows = rows,
                .max_scrollback = scrollback_bytes,
            });
        errdefer self.term.deinit(alloc);
        self.cell_size.applyToTerm(&self.term);

        const handler = StreamHandler.init(self);
        self.stream = .initAlloc(alloc, handler);
        return self;
    }

    fn destroy(self: *Pane) void {
        self.terminate();
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
        if (self.passthrough and !self.feeding_discarded) return;
        if (self.pty_fd < 0) return;
        protocol.writeAll(self.pty_fd, data) catch {};
    }

    fn effectDeviceAttributes(handler: *TerminalHandler) DeviceAttributes {
        _ = handler;
        return .{};
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

    fn feed(self: *Pane, bytes: []const u8) void {
        self.stream.nextSlice(bytes);
    }

    fn noteScrollUp(self: *Pane, count: usize) void {
        self.pending_scroll_up = std.math.add(usize, self.pending_scroll_up, count) catch std.math.maxInt(usize);
    }

    fn takePendingScrollUp(self: *Pane) usize {
        const count = self.pending_scroll_up;
        self.pending_scroll_up = 0;
        return count;
    }

    fn writeInput(self: *Pane, bytes: []const u8) !void {
        if (!self.alive or self.pty_fd < 0) return;
        try protocol.writeAll(self.pty_fd, bytes);
    }

    fn resize(self: *Pane, rows: u16, cols: u16, cell_size: CellSize) !void {
        self.cell_size = cell_size;
        try self.term.resize(self.alloc, cols, rows);
        self.cell_size.applyToTerm(&self.term);
        if (self.pty_fd >= 0) {
            try ptypkg.Pty.setSize(self.pty_fd, self.cell_size.makeWinsize(rows, cols));
        }
    }

    fn closePty(self: *Pane) void {
        if (self.pty_fd >= 0) {
            posix.close(self.pty_fd);
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
        for (0..10) |_| {
            if (self.reap(posix.W.NOHANG)) return;
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }

        posix.kill(self.child_pid, posix.SIG.TERM) catch {};
        for (0..10) |_| {
            if (self.reap(posix.W.NOHANG)) return;
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }

        posix.kill(self.child_pid, posix.SIG.KILL) catch {};
        _ = self.reap(0);
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
        try writer.print("\x1b[{d};{d}H", .{ row + 1, col + 1 });
    }
};

const reset_state_sequence = "\x0f\x1b(B" ++
    "\x1b[0m\x1b[0 q\x1b[?1l\x1b[?5l\x1b[?6l\x1b[?7h" ++
    "\x1b[4l\x1b[r\x1b[?69l\x1b[?25h" ++
    "\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1005l\x1b[?1006l" ++
    "\x1b[?2004l\x1b[?1004l\x1b[>4;0m\x1b[=0;1u";
const restore_terminal_sequence = reset_state_sequence ++ "\x1b[?2026l\x1b[?2031l";
const sanitize_sequence = reset_state_sequence ++ "\x1b[H\x1b[2J";

const ViewportRow = struct {
    bytes: std.ArrayList(u8) = .empty,
    node: ?*const anyopaque = null,
    offset: u16 = 0,
    valid: bool = false,

    fn deinit(self: *ViewportRow, alloc: std.mem.Allocator) void {
        self.bytes.deinit(alloc);
    }

    fn capturePin(self: *ViewportRow, pin: vt.Pin) void {
        self.node = @ptrCast(pin.node);
        self.offset = pin.y;
        self.valid = true;
    }

    fn matchesPin(self: *const ViewportRow, pin: vt.Pin) bool {
        if (!self.valid) return false;
        if (self.node != @as(*const anyopaque, @ptrCast(pin.node))) return false;
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

    fn rotateScrollUp(self: *PaneRowCache, visible_rows: u16, delta: u16) void {
        const row_count: usize = @min(@as(usize, @intCast(visible_rows)), self.rows.items.len);
        const shift: usize = @intCast(delta);
        if (shift == 0 or shift >= row_count) return;

        rotateLeft(ViewportRow, self.rows.items[0..row_count], shift);
        for (self.rows.items[row_count - shift .. row_count]) |*row| {
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

    fn needsReset(self: *GraphicsState, main_pane: *Pane, split_pane: ?*Pane) bool {
        if (comptime !kitty_graphics_enabled) return false;
        if (self.paneNeedsReset(main_pane)) return true;
        if (split_pane) |pane| {
            if (self.paneNeedsReset(pane)) return true;
        }
        return false;
    }

    fn paneNeedsReset(self: *GraphicsState, pane: *Pane) bool {
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

        const reset = force or self.needsReset(main_pane, split_pane);
        if (!reset) return;

        try self.deleteAll(alloc, out);
        try self.renderPane(alloc, out, .main, main_pane, 0);
        main_pane.term.screens.active.kitty_images.dirty = false;
        if (layout.split_visible) {
            if (split_pane) |pane| {
                try self.renderPane(alloc, out, .split, pane, layout.splitTop());
                pane.term.screens.active.kitty_images.dirty = false;
            }
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
        .placement_id = if (placement_id == 0) 1 else placement_id,
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

fn emitImageUpload(alloc: std.mem.Allocator, out: *std.ArrayList(u8), outer_id: u32, image: anytype, format_code: u32) !void {
    if (image.data.len == 0) return;
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
                    "\x1b_Ga=t,t=d,f={d},s={d},v={d},i={d},m=1,q=2;{s}\x1b\\",
                    .{ format_code, image.width, image.height, outer_id, encoded },
                );
            } else {
                try out.print(
                    alloc,
                    "\x1b_Ga=t,t=d,f={d},s={d},v={d},i={d},q=2;{s}\x1b\\",
                    .{ format_code, image.width, image.height, outer_id, encoded },
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

fn emitPlacement(alloc: std.mem.Allocator, out: *std.ArrayList(u8), outer_id: u32, request: PlacementRequest) !void {
    try out.print(
        alloc,
        "\x1b[{d};{d}H\x1b_Ga=p,i={d},p={d},x={d},y={d},w={d},h={d},X={d},Y={d},c={d},r={d},z={d},C=1,q=2;\x1b\\",
        .{
            request.row + 1,
            request.col + 1,
            outer_id,
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

fn emitDeleteImage(alloc: std.mem.Allocator, out: *std.ArrayList(u8), outer_id: u32) !void {
    try out.print(alloc, "\x1b_Ga=d,d=I,i={d},q=2;\x1b\\", .{outer_id});
}

const Compositor = struct {
    alloc: std.mem.Allocator,
    row_cache: std.ArrayList(std.ArrayList(u8)) = .empty,
    main_rows: PaneRowCache = .{},
    split_rows: PaneRowCache = .{},
    graphics: GraphicsState = .{},
    body: std.ArrayList(u8) = .empty,
    scratch: std.ArrayList(u8) = .empty,
    frame: std.ArrayList(u8) = .empty,
    cursor_valid: bool = false,
    cursor_row: u16 = 0,
    cursor_col: u16 = 0,
    full_render: bool = true,

    fn deinit(self: *Compositor) void {
        for (self.row_cache.items) |*row| row.deinit(self.alloc);
        self.row_cache.deinit(self.alloc);
        self.main_rows.deinit(self.alloc);
        self.split_rows.deinit(self.alloc);
        self.graphics.deinit(self.alloc);
        self.body.deinit(self.alloc);
        self.scratch.deinit(self.alloc);
        self.frame.deinit(self.alloc);
    }

    fn invalidate(self: *Compositor) void {
        self.full_render = true;
        self.cursor_valid = false;
        for (self.main_rows.rows.items) |*row| row.valid = false;
        for (self.split_rows.rows.items) |*row| row.valid = false;
    }

    fn render(self: *Compositor, layout: Layout, main_pane: *Pane, split_pane: ?*Pane) !void {
        if (!layout.split_visible) return;
        while (self.row_cache.items.len < layout.rows) try self.row_cache.append(self.alloc, .empty);
        while (self.row_cache.items.len > layout.rows) {
            var row = self.row_cache.pop() orelse break;
            row.deinit(self.alloc);
        }

        self.body.clearRetainingCapacity();
        self.scratch.clearRetainingCapacity();

        const cursor_pos = composedCursorPos(layout, main_pane);
        const cursor_changed = !self.cursor_valid or
            self.cursor_row != cursor_pos.row or
            self.cursor_col != cursor_pos.col;
        const graphics_dirty = self.full_render or self.graphics.needsReset(main_pane, split_pane);

        const pending_scroll_up = main_pane.takePendingScrollUp();
        try self.main_rows.ensure(self.alloc, main_pane.term.rows);
        const scroll_delta = if (self.canMainScrollFastPath(layout, graphics_dirty))
            self.mainScrollDelta(layout, main_pane, pending_scroll_up)
        else
            0;
        if (scroll_delta > 0) {
            try self.emitMainScrollUp(layout, scroll_delta);
            self.rotateOuterRowsForMainScroll(layout.main_rows, scroll_delta);
            self.main_rows.rotateScrollUp(layout.main_rows, scroll_delta);
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

        var cursor_buf: [64]u8 = undefined;
        var cursor_writer = std.Io.Writer.fixed(&cursor_buf);
        try writeComposedCursor(&cursor_writer, cursor_pos);
        const cursor = cursor_writer.buffered();

        if (self.body.items.len > 0 or cursor_changed or graphics_dirty) {
            self.frame.clearRetainingCapacity();
            try self.frame.appendSlice(self.alloc, synchronized_update_begin);
            try self.frame.appendSlice(self.alloc, "\x1b[?25l");
            try self.frame.appendSlice(self.alloc, self.body.items);
            try self.graphics.render(
                self.alloc,
                &self.frame,
                layout,
                main_pane,
                split_pane,
                self.full_render,
            );
            try self.frame.appendSlice(self.alloc, cursor);
            try self.frame.appendSlice(self.alloc, "\x1b[?25h");
            try self.frame.appendSlice(self.alloc, synchronized_update_end);
            try protocol.writeAll(stdout_fd, self.frame.items);
        }

        self.cursor_valid = true;
        self.cursor_row = cursor_pos.row;
        self.cursor_col = cursor_pos.col;
        main_pane.term.screens.active.pages.clearDirty();
        if (split_pane) |pane| pane.term.screens.active.pages.clearDirty();
        self.full_render = false;
    }

    fn canMainScrollFastPath(self: *Compositor, layout: Layout, graphics_dirty: bool) bool {
        if (self.full_render or graphics_dirty) return false;
        if (self.graphics.uploaded.count() != 0) return false;
        if (layout.main_rows < 3) return false;
        return true;
    }

    fn mainScrollDelta(self: *Compositor, layout: Layout, main_pane: *Pane, pending_scroll_up: usize) u16 {
        const max_delta = layout.main_rows - 1;
        if (pending_scroll_up > 0) return @intCast(@min(pending_scroll_up, max_delta));
        return self.main_rows.detectScrollUp(&main_pane.term, layout.main_rows, self.full_render);
    }

    fn emitMainScrollUp(self: *Compositor, layout: Layout, delta: u16) !void {
        try self.body.print(
            self.alloc,
            "\x1b[1;{d}r\x1b[{d}S\x1b[r",
            .{ layout.main_rows, delta },
        );
    }

    fn rotateOuterRowsForMainScroll(self: *Compositor, main_rows: u16, delta: u16) void {
        const row_count: usize = @min(@as(usize, @intCast(main_rows)), self.row_cache.items.len);
        const shift: usize = @intCast(delta);
        if (shift == 0 or shift >= row_count) return;

        rotateLeft(std.ArrayList(u8), self.row_cache.items[0..row_count], shift);
        for (self.row_cache.items[row_count - shift .. row_count]) |*row| {
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
            for (0..layout.cols) |_| try out.appendSlice(self.alloc, "─");
            try out.appendSlice(self.alloc, sgr_reset);
        } else if (split_pane) |pane| {
            const split_y = y - layout.splitTop();
            if (split_y < pane.term.rows) {
                try self.split_rows.appendRow(self.alloc, &pane.term, split_y, self.full_render, out);
            }
        }
        try out.appendSlice(self.alloc, sgr_reset);
    }
};

const CursorPos = struct {
    row: u16,
    col: u16,
};

fn composedCursorPos(layout: Layout, pane: *Pane) CursorPos {
    const cursor = &pane.term.screens.active.cursor;
    const row = @min(@as(u16, @intCast(cursor.y)), layout.main_rows - 1);
    const col = @min(@as(u16, @intCast(cursor.x)), layout.cols - 1);
    return .{ .row = row, .col = col };
}

fn writeComposedCursor(writer: *std.Io.Writer, cursor: CursorPos) !void {
    try writer.print("\x1b[{d};{d}H", .{ cursor.row + 1, cursor.col + 1 });
}

const PrefixParser = struct {
    pending: bool = false,

    fn feed(self: *PrefixParser, alloc: std.mem.Allocator, input: []const u8) !PrefixResult {
        var result = PrefixResult{};
        var start: usize = 0;
        var i: usize = 0;
        while (i < input.len) : (i += 1) {
            const byte = input[i];
            if (self.pending) {
                if (start < i) try result.forwarded.appendSlice(alloc, input[start..i]);
                self.pending = false;
                switch (byte) {
                    'x' => result.close_split = true,
                    'b' => try result.forwarded.append(alloc, 0x02),
                    else => {
                        try result.forwarded.append(alloc, 0x02);
                        try result.forwarded.append(alloc, byte);
                    },
                }
                start = i + 1;
                continue;
            }
            if (byte == 0x02) {
                if (start < i) try result.forwarded.appendSlice(alloc, input[start..i]);
                self.pending = true;
                start = i + 1;
            }
        }
        if (start < input.len) try result.forwarded.appendSlice(alloc, input[start..]);
        return result;
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

    fn deinit(self: *PrefixResult, alloc: std.mem.Allocator) void {
        self.forwarded.deinit(alloc);
    }
};

const App = struct {
    alloc: std.mem.Allocator,
    config: Config,
    layout: Layout,
    main_pane: *Pane,
    split_pane: ?*Pane,
    raw_terminal: RawTerminal,
    compositor: Compositor,
    render_scheduler: RenderScheduler = .{},
    prefix: PrefixParser = .{},
    composed: bool,
    last_size: ptypkg.Winsize,
    cell_size: CellSize,

    fn init(alloc: std.mem.Allocator, config: Config) !App {
        const outer_size = ptypkg.getSize(stdout_fd) catch ptypkg.makeWinsize(24, 80);
        const cell_size = CellSize.fromWinsize(outer_size);
        const split_visible = config.split_cmd != null;
        const layout = Layout.compute(outer_size.row, outer_size.col, split_visible, config.split_rows);
        const cwd = std.fs.cwd().realpathAlloc(alloc, ".") catch null;
        defer if (cwd) |path| alloc.free(path);

        const outer_term = posix.getenv("TERM");
        const colorterm = posix.getenv("COLORTERM");
        const main_term = selectTerm(.auto, outer_term, colorterm);

        var main_env = try std.process.getEnvMap(alloc);
        defer main_env.deinit();
        try main_env.put("TERM", main_term);
        try main_env.put("TINYMUX", "1");
        const main_pane = try Pane.create(
            alloc,
            config.main_argv,
            &main_env,
            layout.main_rows,
            layout.cols,
            cell_size,
            cwd,
        );
        errdefer main_pane.destroy();

        var split_pane: ?*Pane = null;
        if (config.split_cmd) |cmd| {
            var split_env = try std.process.getEnvMap(alloc);
            defer split_env.deinit();
            try split_env.put("TERM", selectTerm(config.split_term, outer_term, colorterm));
            try split_env.put("TINYMUX", "1");
            const shell = posix.getenv("SHELL") orelse "/bin/sh";
            const split_argv = [_][]const u8{ shell, "-lc", cmd };
            split_pane = try Pane.create(
                alloc,
                &split_argv,
                &split_env,
                @max(layout.split_rows, 1),
                layout.cols,
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
            .raw_terminal = raw_terminal,
            .compositor = .{ .alloc = alloc },
            .render_scheduler = .{},
            .composed = split_visible,
            .last_size = outer_size,
            .cell_size = cell_size,
        };
    }

    fn deinit(self: *App) void {
        self.restoreOuterTerminal();
        self.raw_terminal.restore();
        if (self.split_pane) |pane| pane.destroy();
        self.main_pane.destroy();
        self.compositor.deinit();
    }

    fn run(self: *App) !void {
        self.main_pane.passthrough = !self.composed;
        if (self.composed) {
            try protocol.writeAll(stdout_fd, enter_canvas);
            self.compositor.invalidate();
            self.render_scheduler.markDirty(.urgent);
        }

        var running = true;
        while (running) {
            self.main_pane.reapIfExited();
            if (!self.main_pane.alive) {
                try self.drainMainForExit();
                break;
            }
            if (self.split_pane) |pane| pane.reapIfExited();

            try self.checkResize();
            try self.renderIfDue();

            var fds_storage: [3]posix.pollfd = undefined;
            var count: usize = 0;
            const stdin_index = count;
            fds_storage[count] = .{ .fd = stdin_fd, .events = posix.POLL.IN, .revents = 0 };
            count += 1;

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

            const now = std.time.nanoTimestamp();
            const timeout: i32 = if (self.composed)
                self.render_scheduler.pollTimeoutMs(now)
            else
                50;
            _ = try posix.poll(fds_storage[0..count], timeout);

            if (fds_storage[stdin_index].revents != 0) {
                if (try self.readInput(&running)) {
                    self.render_scheduler.noteInput(std.time.nanoTimestamp());
                }
            }

            var pane_stats: DrainStats = .{};
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
            if (pane_stats.bytes > 0) {
                const drain_now = std.time.nanoTimestamp();
                pane_stats.merge(try self.drainReadyPanes(self.render_scheduler.ptyDrainBudget(drain_now, pane_stats)));
                if (self.composed) {
                    const damage_now = std.time.nanoTimestamp();
                    if (pane_stats.bulkish()) self.render_scheduler.noteBulk(damage_now);
                    const kind: RenderScheduler.DirtyKind = if (pane_stats.bulkish() or
                        self.render_scheduler.bulkActive(damage_now))
                        .bulk
                    else if (self.render_scheduler.recentlyInput(damage_now))
                        .urgent
                    else
                        .normal;
                    self.render_scheduler.markDirty(kind);
                }
            }

            if (self.composed) {
                try self.renderIfDue();
            }
        }
    }

    fn renderIfDue(self: *App) !void {
        if (!self.composed) return;
        const render_now = std.time.nanoTimestamp();
        if (!self.render_scheduler.shouldRender(render_now)) return;
        try self.compositor.render(self.layout, self.main_pane, self.split_pane);
        self.render_scheduler.rendered(std.time.nanoTimestamp());
    }

    fn restoreOuterTerminal(self: *App) void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.alloc);
        self.compositor.graphics.deleteAll(self.alloc, &out) catch {};
        out.appendSlice(self.alloc, leave_canvas) catch {};
        protocol.writeAll(stdout_fd, out.items) catch {};
    }

    fn readInput(self: *App, running: *bool) !bool {
        var buf: [8192]u8 = undefined;
        const n = posix.read(stdin_fd, &buf) catch |err| switch (err) {
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
        if (!self.composed and self.split_pane == null) {
            try self.main_pane.writeInput(buf[0..n]);
            return true;
        }
        var result = try self.prefix.feed(self.alloc, buf[0..n]);
        defer result.deinit(self.alloc);
        if (result.close_split) {
            try self.closeSplit();
        }
        if (result.forwarded.items.len > 0) {
            try self.main_pane.writeInput(result.forwarded.items);
        }
        return true;
    }

    const WhichPane = enum { main, split };

    fn readPane(self: *App, pane: *Pane, which: WhichPane) !usize {
        var buf: [64 * 1024]u8 = undefined;
        return try self.readPaneInto(pane, which, &buf);
    }

    fn readPaneInto(self: *App, pane: *Pane, which: WhichPane, buf: *[64 * 1024]u8) !usize {
        const n = posix.read(pane.pty_fd, buf) catch {
            pane.markDead();
            return 0;
        };
        if (n == 0) {
            pane.markDead();
            return 0;
        }
        const bytes = buf[0..n];
        if (!self.composed and which == .main) {
            try protocol.writeAll(stdout_fd, bytes);
        } else {
            pane.feed(bytes);
        }
        return n;
    }

    fn drainReadyPanes(self: *App, budget_ns: i128) !DrainStats {
        const deadline = std.time.nanoTimestamp() + budget_ns;
        var stats: DrainStats = .{};
        var buf: [64 * 1024]u8 = undefined;

        while (true) {
            if (stats.reads >= pty_drain_max_reads or
                stats.bytes >= pty_drain_max_bytes or
                std.time.nanoTimestamp() >= deadline)
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

    fn closeSplit(self: *App) !void {
        const pane = self.split_pane orelse return;
        pane.terminate();
        pane.destroy();
        self.split_pane = null;
        self.layout = Layout.compute(self.last_size.row, self.last_size.col, false, self.config.split_rows);
        try self.main_pane.resize(self.layout.main_rows, self.layout.cols, self.cell_size);
        try self.drainMainForRawTransition();
        self.composed = false;
        self.main_pane.passthrough = true;
        var leave: std.ArrayList(u8) = .empty;
        defer leave.deinit(self.alloc);
        try self.compositor.graphics.deleteAll(self.alloc, &leave);
        try leave.appendSlice(self.alloc, leave_canvas);
        try protocol.writeAll(stdout_fd, leave.items);
        const repaint = try self.main_pane.repaint(self.alloc);
        defer self.alloc.free(repaint);
        var raw_repaint: std.ArrayList(u8) = .empty;
        defer raw_repaint.deinit(self.alloc);
        try raw_repaint.appendSlice(self.alloc, repaint);
        try self.compositor.graphics.render(
            self.alloc,
            &raw_repaint,
            self.layout,
            self.main_pane,
            null,
            true,
        );
        var cursor_buf: [64]u8 = undefined;
        var cursor_writer = std.Io.Writer.fixed(&cursor_buf);
        try self.main_pane.writeCursorPos(&cursor_writer);
        try raw_repaint.appendSlice(self.alloc, cursor_writer.buffered());
        try protocol.writeAll(stdout_fd, raw_repaint.items);
    }

    fn drainMainForRawTransition(self: *App) !void {
        const deadline = std.time.milliTimestamp() + raw_transition_drain_ms;
        while (self.main_pane.pty_fd >= 0 and std.time.milliTimestamp() < deadline) {
            var fds = [_]posix.pollfd{.{
                .fd = self.main_pane.pty_fd,
                .events = posix.POLL.IN,
                .revents = 0,
            }};
            const ready = try posix.poll(&fds, raw_transition_idle_ms);
            if (ready == 0) break;
            if (fds[0].revents == 0) continue;

            var buf: [64 * 1024]u8 = undefined;
            const n = posix.read(self.main_pane.pty_fd, &buf) catch {
                self.main_pane.markDead();
                return;
            };
            if (n == 0) {
                self.main_pane.markDead();
                return;
            }
            self.main_pane.feed(buf[0..n]);
        }
    }

    fn drainMainForExit(self: *App) !void {
        const deadline = std.time.milliTimestamp() + exit_drain_ms;
        while (self.main_pane.pty_fd >= 0 and std.time.milliTimestamp() < deadline) {
            var fds = [_]posix.pollfd{.{
                .fd = self.main_pane.pty_fd,
                .events = posix.POLL.IN,
                .revents = 0,
            }};
            const ready = try posix.poll(&fds, raw_transition_idle_ms);
            if (ready == 0) break;
            if (fds[0].revents == 0) continue;

            var buf: [64 * 1024]u8 = undefined;
            const n = posix.read(self.main_pane.pty_fd, &buf) catch break;
            if (n == 0) break;

            const bytes = buf[0..n];
            if (!self.composed) {
                try protocol.writeAll(stdout_fd, bytes);
            } else {
                self.main_pane.feed(bytes);
            }
        }
        self.main_pane.closePty();
    }

    fn checkResize(self: *App) !void {
        const size = ptypkg.getSize(stdout_fd) catch return;
        if (size.row == self.last_size.row and size.col == self.last_size.col and
            size.xpixel == self.last_size.xpixel and size.ypixel == self.last_size.ypixel) return;
        self.last_size = size;
        self.cell_size = CellSize.fromWinsize(size);
        self.layout = Layout.compute(size.row, size.col, self.composed, self.config.split_rows);
        try self.main_pane.resize(self.layout.main_rows, self.layout.cols, self.cell_size);
        if (self.split_pane) |pane| {
            try pane.resize(@max(self.layout.split_rows, 1), self.layout.cols, self.cell_size);
        }
        self.compositor.invalidate();
        self.render_scheduler.markDirty(.urgent);
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
    try std.testing.expectEqualStrings("vim", cfg.main_argv[0]);
}

test "layout clamps split while preserving rows when possible" {
    const normal = Layout.compute(32, 100, true, 9);
    try std.testing.expectEqual(@as(u16, 22), normal.main_rows);
    try std.testing.expectEqual(@as(u16, 9), normal.split_rows);
    try std.testing.expectEqual(@as(?u16, 22), normal.border_row);

    const tiny = Layout.compute(2, 80, true, 9);
    try std.testing.expect(!tiny.split_visible);
    try std.testing.expectEqual(@as(u16, 2), tiny.main_rows);

    const clamped = Layout.compute(4, 80, true, 99);
    try std.testing.expectEqual(@as(u16, 1), clamped.main_rows);
    try std.testing.expectEqual(@as(u16, 2), clamped.split_rows);
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
}

test "prefix parser forwards unknown bindings unchanged" {
    const alloc = std.testing.allocator;
    var parser: PrefixParser = .{};
    var result = try parser.feed(alloc, "a\x02zb");
    defer result.deinit(alloc);
    try std.testing.expectEqualStrings("a\x02zb", result.forwarded.items);
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

test "pane stream handler records full-pane upward scrolls" {
    const alloc = std.testing.allocator;

    var pane: Pane = undefined;
    pane.alloc = alloc;
    pane.pty_fd = -1;
    pane.child_pid = 0;
    pane.alive = false;
    pane.reaped = true;
    pane.command_title = "test";
    pane.passthrough = false;
    pane.feeding_discarded = false;
    pane.cell_size = .{};
    pane.term = try vt.Terminal.init(alloc, .{ .cols = 20, .rows = 3 });
    defer pane.term.deinit(alloc);
    pane.pending_scroll_up = 0;
    pane.stream = .initAlloc(alloc, Pane.StreamHandler.init(&pane));
    defer pane.stream.deinit();

    pane.feed("one\r\ntwo\r\nthree\r\nfour\r\n");

    try std.testing.expectEqual(@as(usize, 2), pane.takePendingScrollUp());
}

test "graphics reset ignores text-only scroll dirty without placements" {
    const alloc = std.testing.allocator;
    var pane: Pane = .{
        .alloc = alloc,
        .pty_fd = -1,
        .child_pid = 0,
        .command_title = "test",
        .cell_size = .{},
        .term = try vt.Terminal.init(alloc, .{
            .cols = 10,
            .rows = 3,
            .max_scrollback = scrollback_bytes,
            .kitty_image_storage_limit = kitty_image_storage_limit,
            .kitty_image_loading_limits = .all,
        }),
        .stream = undefined,
    };
    defer pane.term.deinit(alloc);

    pane.term.screens.active.kitty_images.dirty = true;
    var graphics: GraphicsState = .{};
    defer graphics.deinit(alloc);

    try std.testing.expect(!graphics.needsReset(&pane, null));
}

test "pane row cache detects upward viewport scroll" {
    const alloc = std.testing.allocator;

    var term = try vt.Terminal.init(alloc, .{ .cols = 20, .rows = 4 });
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
    cache.rotateScrollUp(4, 1);

    for (0..3) |y| {
        const pin = viewportPin(&term, @intCast(y)).?;
        try std.testing.expect(cache.rows.items[y].matchesPin(pin));
    }
    try std.testing.expect(!cache.rows.items[3].valid);
}

test "outer row cache rotation clears newly exposed rows" {
    const alloc = std.testing.allocator;

    var compositor: Compositor = .{ .alloc = alloc };
    defer compositor.deinit();

    while (compositor.row_cache.items.len < 4) try compositor.row_cache.append(alloc, .empty);
    for (compositor.row_cache.items, 0..) |*row, i| {
        try row.print(alloc, "row{d}", .{i});
    }

    compositor.rotateOuterRowsForMainScroll(4, 1);

    try std.testing.expectEqualStrings("row1", compositor.row_cache.items[0].items);
    try std.testing.expectEqualStrings("row2", compositor.row_cache.items[1].items);
    try std.testing.expectEqualStrings("row3", compositor.row_cache.items[2].items);
    try std.testing.expectEqual(@as(usize, 0), compositor.row_cache.items[3].items.len);
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

test "graphics replay emits outer image upload and placement" {
    if (comptime !kitty_graphics_enabled) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var pane: Pane = .{
        .alloc = alloc,
        .pty_fd = -1,
        .child_pid = 0,
        .command_title = "test",
        .cell_size = .{},
        .term = try vt.Terminal.init(alloc, .{
            .cols = 10,
            .rows = 5,
            .max_scrollback = scrollback_bytes,
            .kitty_image_storage_limit = kitty_image_storage_limit,
            .kitty_image_loading_limits = .all,
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
}

test "viewport row cache invalidates clean rows that scrolled" {
    const alloc = std.testing.allocator;

    var term = try vt.Terminal.init(alloc, .{ .cols = 20, .rows = 4 });
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
        entries[y].node = @ptrCast(pin.node);
        entries[y].offset = pin.y;
        entries[y].valid = true;
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
