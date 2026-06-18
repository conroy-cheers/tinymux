const std = @import("std");
const posix = std.posix;
const vt = @import("ghostty-vt");
const ptypkg = @import("pty.zig");
const protocol = @import("protocol.zig");

pub const version = "0.1.0";

const stdin_fd: posix.fd_t = 0;
const stdout_fd: posix.fd_t = 1;

const default_split_rows: u16 = 9;
const repaint_interval_ms: i64 = 16;
const scrollback_bytes: usize = 512 * 1024;

const sgr_reset = "\x1b[0m";
const style_dim = "\x1b[2m";
const synchronized_update_begin = "\x1b[?2026h";
const synchronized_update_end = "\x1b[?2026l";
const enter_canvas = "\x1b[?1049h\x1b[?25l\x1b[H\x1b[2J";
const leave_canvas = "\x1b[0m\x1b[?25h\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1005l\x1b[?1006l\x1b[?2004l\x1b[?1004l\x1b[?2026l\x1b[?1049l";

extern "c" fn cfmakeraw(termios_p: *posix.termios) void;

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
        \\  tinymux --split <split-cmd> [--split-rows <n>] [--split-term auto|xterm-256color|xterm-direct] -- <main-argv...>
        \\  tinymux -- <main-argv...>
        \\
    , .{@errorName(err)});
}

const TermChoice = enum {
    auto,
    xterm_256color,
    xterm_direct,

    fn parse(value: []const u8) !TermChoice {
        if (std.mem.eql(u8, value, "auto")) return .auto;
        if (std.mem.eql(u8, value, "xterm-256color")) return .xterm_256color;
        if (std.mem.eql(u8, value, "xterm-direct")) return .xterm_direct;
        return error.UnsupportedTerm;
    }
};

fn selectTerm(choice: TermChoice, outer_term: ?[]const u8, colorterm: ?[]const u8) []const u8 {
    return switch (choice) {
        .xterm_256color => "xterm-256color",
        .xterm_direct => "xterm-direct",
        .auto => if (outerHasTruecolor(outer_term, colorterm))
            "xterm-direct"
        else
            "xterm-256color",
    };
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

const Pane = struct {
    alloc: std.mem.Allocator,
    pty_fd: posix.fd_t,
    child_pid: posix.pid_t,
    alive: bool = true,
    reaped: bool = false,
    command_title: []const u8,
    passthrough: bool = false,
    feeding_discarded: bool = false,
    term: vt.Terminal,
    stream: Stream,

    pub const Stream = vt.TerminalStream;

    fn create(
        alloc: std.mem.Allocator,
        argv: []const []const u8,
        env: *std.process.EnvMap,
        rows: u16,
        cols: u16,
        cwd: ?[]const u8,
    ) !*Pane {
        const self = try alloc.create(Pane);
        errdefer alloc.destroy(self);

        const spawned = try ptypkg.spawnInPty(alloc, .{
            .argv = argv,
            .env = env,
            .size = ptypkg.makeWinsize(rows, cols),
            .cwd = cwd,
        });
        errdefer posix.close(spawned.master);

        self.* = .{
            .alloc = alloc,
            .pty_fd = spawned.master,
            .child_pid = spawned.pid,
            .command_title = try alloc.dupe(u8, argv[0]),
            .term = undefined,
            .stream = undefined,
        };
        errdefer alloc.free(self.command_title);

        self.term = try vt.Terminal.init(alloc, .{
            .cols = cols,
            .rows = rows,
            .max_scrollback = scrollback_bytes,
        });
        errdefer self.term.deinit(alloc);

        var handler: Stream.Handler = .init(&self.term);
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

    fn fromHandler(handler: *Stream.Handler) *Pane {
        const stream: *Stream = @alignCast(@fieldParentPtr("handler", handler));
        return @alignCast(@fieldParentPtr("stream", stream));
    }

    const DeviceAttributes = EffectReturn("device_attributes");

    fn EffectReturn(comptime field_name: []const u8) type {
        const Effects = Stream.Handler.Effects;
        const field = std.meta.fieldInfo(
            Effects,
            @field(std.meta.FieldEnum(Effects), field_name),
        );
        const Fn = @typeInfo(field.type).optional.child;
        return @typeInfo(@typeInfo(Fn).pointer.child).@"fn".return_type.?;
    }

    fn effectWritePty(handler: *Stream.Handler, data: [:0]const u8) void {
        const self = fromHandler(handler);
        if (self.passthrough and !self.feeding_discarded) return;
        if (self.pty_fd < 0) return;
        protocol.writeAll(self.pty_fd, data) catch {};
    }

    fn effectDeviceAttributes(handler: *Stream.Handler) DeviceAttributes {
        _ = handler;
        return .{};
    }

    fn effectSize(handler: *Stream.Handler) ?vt.size_report.Size {
        const self = fromHandler(handler);
        return .{
            .rows = self.term.rows,
            .columns = self.term.cols,
            .cell_width = 8,
            .cell_height = 16,
        };
    }

    fn effectXtversion(handler: *Stream.Handler) []const u8 {
        _ = handler;
        return "tinymux " ++ version;
    }

    fn feed(self: *Pane, bytes: []const u8) void {
        self.stream.nextSlice(bytes);
    }

    fn writeInput(self: *Pane, bytes: []const u8) !void {
        if (!self.alive or self.pty_fd < 0) return;
        try protocol.writeAll(self.pty_fd, bytes);
    }

    fn resize(self: *Pane, rows: u16, cols: u16) !void {
        try self.term.resize(self.alloc, cols, rows);
        if (self.pty_fd >= 0) {
            try ptypkg.Pty.setSize(self.pty_fd, ptypkg.makeWinsize(rows, cols));
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
const sanitize_sequence = reset_state_sequence ++ "\x1b[H\x1b[2J";

const ViewportRow = struct {
    bytes: std.ArrayList(u8) = .empty,
    node: ?*const anyopaque = null,
    offset: u16 = 0,
    valid: bool = false,

    fn deinit(self: *ViewportRow, alloc: std.mem.Allocator) void {
        self.bytes.deinit(alloc);
    }
};

fn viewportRowReusable(entry: *const ViewportRow, pin: vt.Pin, full_render: bool) bool {
    if (full_render or !entry.valid) return false;
    if (entry.node != @as(*const anyopaque, @ptrCast(pin.node))) return false;
    if (entry.offset != pin.y) return false;
    return !pin.isDirty();
}

fn appendTermRow(
    alloc: std.mem.Allocator,
    term: *vt.Terminal,
    y: u16,
    out: *std.ArrayList(u8),
) !void {
    const screen = term.screens.active;
    if (term.cols == 0 or y >= term.rows) return;
    const start = screen.pages.pin(.{ .viewport = .{ .x = 0, .y = y } }) orelse return;
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

    fn appendRow(
        self: *PaneRowCache,
        alloc: std.mem.Allocator,
        term: *vt.Terminal,
        y: u16,
        full_render: bool,
        out: *std.ArrayList(u8),
    ) !void {
        try self.ensure(alloc, term.rows);
        const pin = term.screens.active.pages.pin(.{ .viewport = .{ .x = 0, .y = y } }) orelse {
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
        entry.node = @ptrCast(pin.node);
        entry.offset = pin.y;
        entry.valid = true;
        try out.appendSlice(alloc, entry.bytes.items);
    }
};

const Compositor = struct {
    alloc: std.mem.Allocator,
    row_cache: std.ArrayList(std.ArrayList(u8)) = .empty,
    main_rows: PaneRowCache = .{},
    split_rows: PaneRowCache = .{},
    full_render: bool = true,

    fn deinit(self: *Compositor) void {
        for (self.row_cache.items) |*row| row.deinit(self.alloc);
        self.row_cache.deinit(self.alloc);
        self.main_rows.deinit(self.alloc);
        self.split_rows.deinit(self.alloc);
    }

    fn invalidate(self: *Compositor) void {
        self.full_render = true;
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

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.alloc);
        var scratch: std.ArrayList(u8) = .empty;
        defer scratch.deinit(self.alloc);

        for (0..layout.rows) |row_index| {
            scratch.clearRetainingCapacity();
            try self.composeRow(layout, main_pane, split_pane, @intCast(row_index), &scratch);
            const cache = &self.row_cache.items[row_index];
            if (!self.full_render and std.mem.eql(u8, cache.items, scratch.items)) continue;
            cache.clearRetainingCapacity();
            try cache.appendSlice(self.alloc, scratch.items);
            try body.print(self.alloc, "\x1b[{d};1H", .{row_index + 1});
            try body.appendSlice(self.alloc, scratch.items);
        }

        var cursor_buf: [64]u8 = undefined;
        var cursor_writer = std.Io.Writer.fixed(&cursor_buf);
        try writeComposedCursor(&cursor_writer, layout, main_pane);
        const cursor = cursor_writer.buffered();

        if (body.items.len > 0 or !self.full_render) {
            var frame: std.ArrayList(u8) = .empty;
            defer frame.deinit(self.alloc);
            try frame.appendSlice(self.alloc, synchronized_update_begin);
            try frame.appendSlice(self.alloc, "\x1b[?25l");
            try frame.appendSlice(self.alloc, body.items);
            try frame.appendSlice(self.alloc, cursor);
            try frame.appendSlice(self.alloc, "\x1b[?25h");
            try frame.appendSlice(self.alloc, synchronized_update_end);
            try protocol.writeAll(stdout_fd, frame.items);
        }

        main_pane.term.screens.active.pages.clearDirty();
        if (split_pane) |pane| pane.term.screens.active.pages.clearDirty();
        self.full_render = false;
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

fn writeComposedCursor(writer: *std.Io.Writer, layout: Layout, pane: *Pane) !void {
    const cursor = &pane.term.screens.active.cursor;
    const row = @min(@as(u16, @intCast(cursor.y)), layout.main_rows - 1);
    const col = @min(@as(u16, @intCast(cursor.x)), layout.cols - 1);
    try writer.print("\x1b[{d};{d}H", .{ row + 1, col + 1 });
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
    prefix: PrefixParser = .{},
    composed: bool,
    canvas_active: bool = false,
    last_size: ptypkg.Winsize,

    fn init(alloc: std.mem.Allocator, config: Config) !App {
        const outer_size = ptypkg.getSize(stdout_fd) catch ptypkg.makeWinsize(24, 80);
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
            .composed = split_visible,
            .last_size = outer_size,
        };
    }

    fn deinit(self: *App) void {
        if (self.canvas_active) protocol.writeAll(stdout_fd, leave_canvas) catch {};
        self.raw_terminal.restore();
        if (self.split_pane) |pane| pane.destroy();
        self.main_pane.destroy();
        self.compositor.deinit();
    }

    fn run(self: *App) !void {
        self.main_pane.passthrough = !self.composed;
        if (self.composed) {
            try protocol.writeAll(stdout_fd, enter_canvas);
            self.canvas_active = true;
            self.compositor.invalidate();
        }

        var next_repaint = std.time.milliTimestamp();
        var running = true;
        while (running) {
            self.main_pane.reapIfExited();
            if (!self.main_pane.alive and self.main_pane.pty_fd < 0) break;
            if (self.split_pane) |pane| pane.reapIfExited();

            try self.checkResize();

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

            const now = std.time.milliTimestamp();
            const timeout: i32 = if (self.composed)
                @intCast(@max(@as(i64, 0), @min(@as(i64, repaint_interval_ms), next_repaint - now)))
            else
                50;
            _ = try posix.poll(fds_storage[0..count], timeout);

            if (fds_storage[stdin_index].revents != 0) {
                try self.readInput(&running);
            }

            if (main_index) |index| {
                if (fds_storage[index].revents != 0) {
                    try self.readPane(self.main_pane, .main);
                }
            }

            if (split_index) |index| {
                if (self.split_pane) |pane| {
                    if (fds_storage[index].revents != 0) {
                        try self.readPane(pane, .split);
                    }
                }
            }

            if (self.composed and std.time.milliTimestamp() >= next_repaint) {
                try self.compositor.render(self.layout, self.main_pane, self.split_pane);
                next_repaint = std.time.milliTimestamp() + repaint_interval_ms;
            }
        }
    }

    fn readInput(self: *App, running: *bool) !void {
        var buf: [8192]u8 = undefined;
        const n = posix.read(stdin_fd, &buf) catch |err| switch (err) {
            error.InputOutput => {
                running.* = false;
                return;
            },
            else => return err,
        };
        if (n == 0) {
            running.* = false;
            return;
        }
        if (!self.composed and self.split_pane == null) {
            try self.main_pane.writeInput(buf[0..n]);
            return;
        }
        var result = try self.prefix.feed(self.alloc, buf[0..n]);
        defer result.deinit(self.alloc);
        if (result.close_split) {
            try self.closeSplit();
        }
        if (result.forwarded.items.len > 0) {
            try self.main_pane.writeInput(result.forwarded.items);
        }
    }

    const WhichPane = enum { main, split };

    fn readPane(self: *App, pane: *Pane, which: WhichPane) !void {
        var buf: [64 * 1024]u8 = undefined;
        const n = posix.read(pane.pty_fd, &buf) catch {
            pane.markDead();
            return;
        };
        if (n == 0) {
            pane.markDead();
            return;
        }
        const bytes = buf[0..n];
        pane.feed(bytes);
        if (!self.composed and which == .main) {
            try protocol.writeAll(stdout_fd, bytes);
        } else {
            self.compositor.full_render = self.compositor.full_render or which == .split;
        }
    }

    fn closeSplit(self: *App) !void {
        const pane = self.split_pane orelse return;
        pane.terminate();
        pane.destroy();
        self.split_pane = null;
        self.composed = false;
        self.main_pane.passthrough = true;
        self.canvas_active = false;
        try protocol.writeAll(stdout_fd, leave_canvas);
        self.layout = Layout.compute(self.last_size.row, self.last_size.col, false, self.config.split_rows);
        try self.main_pane.resize(self.layout.main_rows, self.layout.cols);
        const repaint = try self.main_pane.repaint(self.alloc);
        defer self.alloc.free(repaint);
        try protocol.writeAll(stdout_fd, repaint);
    }

    fn checkResize(self: *App) !void {
        const size = ptypkg.getSize(stdout_fd) catch return;
        if (size.row == self.last_size.row and size.col == self.last_size.col) return;
        self.last_size = size;
        self.layout = Layout.compute(size.row, size.col, self.composed, self.config.split_rows);
        try self.main_pane.resize(self.layout.main_rows, self.layout.cols);
        if (self.split_pane) |pane| {
            try pane.resize(@max(self.layout.split_rows, 1), self.layout.cols);
        }
        self.compositor.invalidate();
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

test "term selection auto prefers direct color only when detected" {
    try std.testing.expectEqualStrings("xterm-direct", selectTerm(.auto, "xterm-ghostty", null));
    try std.testing.expectEqualStrings("xterm-direct", selectTerm(.auto, "xterm-256color", "truecolor"));
    try std.testing.expectEqualStrings("xterm-256color", selectTerm(.auto, "xterm-256color", null));
    try std.testing.expectEqualStrings("xterm-direct", selectTerm(.xterm_direct, null, null));
    try std.testing.expectEqualStrings("xterm-256color", selectTerm(.xterm_256color, null, null));
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
