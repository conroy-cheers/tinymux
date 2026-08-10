const std = @import("std");
const vt = @import("ghostty-vt");
const wuffs = @import("wuffs");

const max_control_string_bytes: usize = 128 * 1024 * 1024;
const max_image_bytes: usize = 320 * 1024 * 1024;
const kitty_chunk_bytes: usize = 3000;
const delete_all_images = "\x1b_Ga=d,d=A,q=2;\x1b\\";

pub const Mode = enum {
    raw,
    composed,
};

pub const Geometry = struct {
    rows: u16 = 24,
    columns: u16 = 80,
    cell_width: u32 = 8,
    cell_height: u32 = 16,
};

pub const FeedOptions = struct {
    mode: Mode = .composed,
    geometry: Geometry = .{},
};

pub const Effect = enum(u3) {
    /// The sequence was fully modeled and can be removed by reference.
    precise,
    /// The sequence was fully modeled but has no stable outer-terminal
    /// reference. Composition requires an outer clear, but the shadow image
    /// can be retained and redrawn.
    clear_retain,
    /// The sequence is safe in raw mode but cannot be faithfully composed.
    /// Both the outer-terminal layer and shadow graphics must be cleared.
    clear_discard,
    /// The sequence cleared all Kitty graphics on the active screen.
    cleared,
    /// A positively identified graphics layer cannot be normalized or erased.
    unmanaged,
};

pub const Event = struct {
    /// End offset in the output buffer after applying this event. Processing
    /// output through this offset before the event attributes it to the screen
    /// that was active at the exact point the graphics sequence completed.
    output_end: usize,
    effect: Effect,
};

pub const FeedResult = struct {
    graphics: bool = false,
    dropped: bool = false,
    effect: ?Effect = null,

    fn merge(self: *FeedResult, other: FeedResult) void {
        self.graphics = self.graphics or other.graphics;
        self.dropped = self.dropped or other.dropped;
        if (other.effect) |effect| self.effect = mergeEffect(self.effect, effect);
    }
};

fn mergeEffect(current: ?Effect, next: Effect) Effect {
    const previous = current orelse return next;
    if (next == .cleared) return .cleared;
    if (previous == .cleared) return next;
    return if (@intFromEnum(next) > @intFromEnum(previous)) next else previous;
}

/// Normalizes every image protocol Tinymux advertises into direct Kitty RGBA.
/// Ordinary terminal bytes and non-image control strings are preserved exactly.
/// A graphics sequence that cannot be represented is replaced with a Kitty
/// delete-all command, so it can never create an untracked outer-terminal layer.
pub const Normalizer = struct {
    state: State = .ground,
    utf8_continuations: u3 = 0,
    string_utf8_continuations: u3 = 0,
    pending: std.ArrayList(u8) = .empty,
    completed_events: std.ArrayList(Event) = .empty,
    pending_replies: std.ArrayList(u8) = .empty,
    overflowed: bool = false,
    passthrough_string: bool = false,
    streamed_graphics_effect: ?Effect = null,
    kitty_transfer_effect: ?Effect = null,
    multipart: Multipart = .{},
    sixel_palette: [256]Rgba = undefined,
    sixel_palette_initialized: bool = false,
    sixel_scrolling: bool = true,
    sixel_scrolls_right: bool = false,
    sixel_private_palette: bool = false,

    const State = enum {
        ground,
        escape,
        apc,
        apc_escape,
        dcs,
        dcs_escape,
        osc,
        osc_escape,
        csi,
    };

    const Multipart = struct {
        metadata: std.ArrayList(u8) = .empty,
        encoded: std.ArrayList(u8) = .empty,
        active: bool = false,
        passthrough: bool = false,

        fn reset(self: *Multipart) void {
            self.metadata.clearRetainingCapacity();
            self.encoded.clearRetainingCapacity();
            self.active = false;
            self.passthrough = false;
        }

        fn deinit(self: *Multipart, alloc: std.mem.Allocator) void {
            self.metadata.deinit(alloc);
            self.encoded.deinit(alloc);
        }
    };

    pub fn deinit(self: *Normalizer, alloc: std.mem.Allocator) void {
        self.pending.deinit(alloc);
        self.completed_events.deinit(alloc);
        self.pending_replies.deinit(alloc);
        self.multipart.deinit(alloc);
    }

    pub fn events(self: *const Normalizer) []const Event {
        return self.completed_events.items;
    }

    pub fn replies(self: *const Normalizer) []const u8 {
        return self.pending_replies.items;
    }

    pub fn hasPending(self: *const Normalizer) bool {
        return self.state != .ground;
    }

    pub fn needsProcessing(self: *const Normalizer, input: []const u8) bool {
        if (self.hasPending() or self.utf8_continuations > 0) return true;
        for (input, 0..) |byte, i| {
            // Route UTF-8 through `feed` so a character split across PTY reads
            // cannot make a continuation byte look like an 8-bit C1 string
            // introducer in the following chunk.
            if (byte >= 0x80) return true;
            if (byte != 0x1b) continue;
            if (i + 1 == input.len) return true;
            const next = input[i + 1];
            if (next == '_' or next == 'P' or next == ']') return true;
            if (next == '[' and csiMayBeSixelMode(input[i..])) return true;
        }
        return false;
    }

    pub fn feed(
        self: *Normalizer,
        io: std.Io,
        alloc: std.mem.Allocator,
        temp_dir: []const u8,
        input: []const u8,
        out: *std.ArrayList(u8),
    ) !FeedResult {
        return self.feedWithOptions(io, alloc, temp_dir, .{}, input, out);
    }

    pub fn feedWithOptions(
        self: *Normalizer,
        io: std.Io,
        alloc: std.mem.Allocator,
        temp_dir: []const u8,
        options: FeedOptions,
        input: []const u8,
        out: *std.ArrayList(u8),
    ) !FeedResult {
        self.completed_events.clearRetainingCapacity();
        self.pending_replies.clearRetainingCapacity();
        var result: FeedResult = .{};
        var i: usize = 0;
        while (i < input.len) {
            switch (self.state) {
                .ground => {
                    const start = i;
                    while (i < input.len and !self.beginsString(input[i])) : (i += 1) {}
                    if (i > start) try out.appendSlice(alloc, input[start..i]);
                    if (i == input.len) break;
                    try self.begin(alloc, input[i]);
                    i += 1;
                },
                .escape => {
                    const byte = input[i];
                    i += 1;
                    try self.appendPending(alloc, byte);
                    self.state = switch (byte) {
                        '_' => .apc,
                        'P' => .dcs,
                        ']' => .osc,
                        '[' => .csi,
                        else => state: {
                            if (!self.overflowed) try out.appendSlice(alloc, self.pending.items);
                            self.resetSequence();
                            break :state .ground;
                        },
                    };
                },
                .apc, .dcs, .osc => {
                    const byte = input[i];
                    i += 1;
                    const is_utf8_data = self.stringByteIsUtf8Data(byte);
                    if (self.passthrough_string) {
                        try out.append(alloc, byte);
                    } else {
                        try self.appendPending(alloc, byte);
                        try self.beginPassthroughIfPossible(alloc, options, out);
                    }
                    if (!is_utf8_data and (byte == 0x9c or (self.state == .osc and byte == 0x07))) {
                        if (self.passthrough_string) {
                            if (self.streamed_graphics_effect) |effect| {
                                const completed: FeedResult = .{ .graphics = true, .effect = effect };
                                try self.recordEvent(alloc, out, completed);
                                result.merge(completed);
                            }
                            self.resetSequence();
                        } else {
                            const completed = try self.complete(io, alloc, temp_dir, options, out);
                            try self.recordEvent(alloc, out, completed);
                            result.merge(completed);
                        }
                    } else if (byte == 0x1b) {
                        self.state = switch (self.state) {
                            .apc => .apc_escape,
                            .dcs => .dcs_escape,
                            .osc => .osc_escape,
                            else => unreachable,
                        };
                    }
                },
                .apc_escape, .dcs_escape, .osc_escape => {
                    const byte = input[i];
                    i += 1;
                    if (self.passthrough_string) {
                        try out.append(alloc, byte);
                    } else {
                        try self.appendPending(alloc, byte);
                    }
                    if (byte == '\\') {
                        if (self.passthrough_string) {
                            if (self.streamed_graphics_effect) |effect| {
                                const completed: FeedResult = .{ .graphics = true, .effect = effect };
                                try self.recordEvent(alloc, out, completed);
                                result.merge(completed);
                            }
                            self.resetSequence();
                        } else {
                            const completed = try self.complete(io, alloc, temp_dir, options, out);
                            try self.recordEvent(alloc, out, completed);
                            result.merge(completed);
                        }
                    } else if (byte != 0x1b) {
                        self.state = switch (self.state) {
                            .apc_escape => .apc,
                            .dcs_escape => .dcs,
                            .osc_escape => .osc,
                            else => unreachable,
                        };
                    }
                },
                .csi => {
                    const byte = input[i];
                    i += 1;
                    try self.appendPending(alloc, byte);
                    if (byte >= 0x40 and byte <= 0x7e) {
                        if (std.mem.eql(u8, self.pending.items, "\x1b[?80h") or
                            std.mem.eql(u8, self.pending.items, "\x9b?80h"))
                        {
                            self.sixel_scrolling = false;
                        } else if (std.mem.eql(u8, self.pending.items, "\x1b[?80l") or
                            std.mem.eql(u8, self.pending.items, "\x9b?80l"))
                        {
                            self.sixel_scrolling = true;
                        } else if (std.mem.eql(u8, self.pending.items, "\x1b[?8452h") or
                            std.mem.eql(u8, self.pending.items, "\x9b?8452h"))
                        {
                            self.sixel_scrolls_right = true;
                        } else if (std.mem.eql(u8, self.pending.items, "\x1b[?8452l") or
                            std.mem.eql(u8, self.pending.items, "\x9b?8452l"))
                        {
                            self.sixel_scrolls_right = false;
                        } else if (std.mem.eql(u8, self.pending.items, "\x1b[?1070h") or
                            std.mem.eql(u8, self.pending.items, "\x9b?1070h"))
                        {
                            self.sixel_private_palette = true;
                        } else if (std.mem.eql(u8, self.pending.items, "\x1b[?1070l") or
                            std.mem.eql(u8, self.pending.items, "\x9b?1070l"))
                        {
                            self.sixel_private_palette = false;
                        }
                        if (!self.overflowed) try out.appendSlice(alloc, self.pending.items);
                        self.resetSequence();
                    }
                },
            }
        }
        return result;
    }

    /// Flush an unterminated non-graphics string on shutdown. Recognized image
    /// strings fail closed because forwarding a partial image would recreate
    /// precisely the unmanaged state this layer exists to prevent.
    pub fn finish(self: *Normalizer, alloc: std.mem.Allocator, out: *std.ArrayList(u8)) !FeedResult {
        self.completed_events.clearRetainingCapacity();
        self.pending_replies.clearRetainingCapacity();
        if (self.state == .ground) return .{};
        if (self.passthrough_string) {
            if (self.streamed_graphics_effect != null) {
                // Close the partial APC before issuing the safety clear. A
                // terminal must not display a direct transfer until its APC is
                // terminated, and the following clear keeps model and outer
                // state converged if it accepted any partial state.
                try out.appendSlice(alloc, "\x1b\\" ++ delete_all_images);
                self.resetSequence();
                const result: FeedResult = .{ .graphics = true, .dropped = true, .effect = .cleared };
                try self.recordEvent(alloc, out, result);
                return result;
            }
            self.resetSequence();
            return .{};
        }
        const graphics = self.pendingLooksLikeGraphics();
        if (graphics) {
            try out.appendSlice(alloc, delete_all_images);
        } else if (!self.overflowed) {
            try out.appendSlice(alloc, self.pending.items);
        }
        self.resetSequence();
        const result: FeedResult = .{
            .graphics = graphics,
            .dropped = graphics,
            .effect = if (graphics) .cleared else null,
        };
        try self.recordEvent(alloc, out, result);
        return result;
    }

    fn begin(self: *Normalizer, alloc: std.mem.Allocator, byte: u8) !void {
        self.pending.clearRetainingCapacity();
        self.overflowed = false;
        try self.pending.append(alloc, byte);
        self.state = switch (byte) {
            0x1b => .escape,
            0x9f => .apc,
            0x90 => .dcs,
            0x9d => .osc,
            0x9b => .csi,
            else => unreachable,
        };
    }

    fn recordEvent(
        self: *Normalizer,
        alloc: std.mem.Allocator,
        out: *const std.ArrayList(u8),
        result: FeedResult,
    ) !void {
        const effect = result.effect orelse return;
        try self.completed_events.append(alloc, .{
            .output_end = out.items.len,
            .effect = effect,
        });
    }

    fn stringByteIsUtf8Data(self: *Normalizer, byte: u8) bool {
        if (self.string_utf8_continuations > 0) {
            if (byte >= 0x80 and byte <= 0xbf) {
                self.string_utf8_continuations -= 1;
                return true;
            }
            self.string_utf8_continuations = 0;
        }
        self.string_utf8_continuations = switch (byte) {
            0xc2...0xdf => 1,
            0xe0...0xef => 2,
            0xf0...0xf4 => 3,
            else => 0,
        };
        return self.string_utf8_continuations > 0;
    }

    fn beginPassthroughIfPossible(
        self: *Normalizer,
        alloc: std.mem.Allocator,
        options: FeedOptions,
        out: *std.ArrayList(u8),
    ) !void {
        if (self.overflowed or self.passthrough_string) return;
        const bytes = self.pending.items;
        const body_start: usize = if (bytes.len >= 2 and bytes[0] == 0x1b) 2 else 1;
        if (body_start > bytes.len) return;
        const body = bytes[body_start..];
        const non_graphics = switch (baseState(self.state)) {
            .apc => body.len > 0 and body[0] != 'G',
            .osc => if (body.len <= "1337;".len)
                !std.mem.startsWith(u8, "1337;", body)
            else
                !std.mem.startsWith(u8, body, "1337;"),
            .dcs => dcsHeaderIsNonSixel(body),
            else => false,
        };
        if (!non_graphics) {
            if (baseState(self.state) != .apc or body.len < 3 or body[0] != 'G') return;
            const separator = std.mem.indexOfScalar(u8, body[1..], ';') orelse return;
            // We call this immediately after every byte, so the first time a
            // separator is visible it is necessarily the final byte here.
            if (separator + 2 != body.len) return;
            var cmd = vt.kitty.graphics.CommandParser.parseString(alloc, body[1..]) catch return;
            defer cmd.deinit(alloc);
            const transmission = cmd.transmission() orelse return;
            if (transmission.medium != .direct) return;
            switch (cmd.control) {
                .transmit_animation_frame, .control_animation, .compose_animation => return,
                else => {},
            }
            if (cmd.display()) |display| {
                const relative = display.parent_id != 0 or display.parent_placement_id != 0 or
                    display.horizontal_offset != 0 or display.vertical_offset != 0;
                if (relative and options.mode == .composed) return;
            }
            const continuation = !std.mem.containsAtLeast(u8, body[1 .. separator + 1], 1, "a=") and
                !std.mem.containsAtLeast(u8, body[1 .. separator + 1], 1, "t=") and
                std.mem.containsAtLeast(u8, body[1 .. separator + 1], 1, "m=");
            const effect = if (continuation)
                self.kitty_transfer_effect orelse kittyReferenceEffect(cmd)
            else
                kittyReferenceEffect(cmd);
            self.kitty_transfer_effect = if (transmission.more_chunks) effect else null;
            try out.appendSlice(alloc, bytes);
            self.pending.clearRetainingCapacity();
            self.passthrough_string = true;
            self.streamed_graphics_effect = effect;
            return;
        }
        try out.appendSlice(alloc, bytes);
        self.pending.clearRetainingCapacity();
        self.passthrough_string = true;
    }

    fn beginsString(self: *Normalizer, byte: u8) bool {
        if (self.utf8_continuations > 0) {
            if (byte >= 0x80 and byte <= 0xbf) {
                self.utf8_continuations -= 1;
                return false;
            }
            // Invalid UTF-8 ends the partial character. Reconsider this byte
            // normally so a real C1 control sequence is still recognized.
            self.utf8_continuations = 0;
        }

        if (isStringIntroducer(byte)) return true;
        self.utf8_continuations = switch (byte) {
            0xc2...0xdf => 1,
            0xe0...0xef => 2,
            0xf0...0xf4 => 3,
            else => 0,
        };
        return false;
    }

    fn appendPending(self: *Normalizer, alloc: std.mem.Allocator, byte: u8) !void {
        if (self.overflowed) return;
        if (self.pending.items.len >= max_control_string_bytes) {
            self.pending.clearRetainingCapacity();
            self.overflowed = true;
            return;
        }
        try self.pending.append(alloc, byte);
    }

    fn resetSequence(self: *Normalizer) void {
        self.pending.clearRetainingCapacity();
        self.overflowed = false;
        self.passthrough_string = false;
        self.streamed_graphics_effect = null;
        self.string_utf8_continuations = 0;
        self.state = .ground;
    }

    fn complete(
        self: *Normalizer,
        io: std.Io,
        alloc: std.mem.Allocator,
        temp_dir: []const u8,
        options: FeedOptions,
        out: *std.ArrayList(u8),
    ) !FeedResult {
        defer self.resetSequence();
        if (self.overflowed) {
            try out.appendSlice(alloc, delete_all_images);
            return .{ .graphics = true, .dropped = true, .effect = .cleared };
        }

        const body = self.sequenceBody() orelse {
            try out.appendSlice(alloc, self.pending.items);
            return .{};
        };
        return switch (baseState(self.state)) {
            .apc => if (std.mem.startsWith(u8, body, "G"))
                try normalizeKitty(
                    io,
                    alloc,
                    temp_dir,
                    options.mode,
                    body[1..],
                    self.pending.items,
                    out,
                    &self.pending_replies,
                )
            else preserve: {
                try out.appendSlice(alloc, self.pending.items);
                break :preserve .{};
            },
            .dcs => if (sixelPayload(body)) |payload|
                try normalizeSixel(self, alloc, body, payload, options.geometry, out)
            else preserve: {
                try out.appendSlice(alloc, self.pending.items);
                break :preserve .{};
            },
            .osc => if (std.mem.startsWith(u8, body, "1337;"))
                try self.normalizeIterm(alloc, options.geometry, body[5..], out)
            else preserve: {
                try out.appendSlice(alloc, self.pending.items);
                break :preserve .{};
            },
            else => unreachable,
        };
    }

    fn sequenceBody(self: *const Normalizer) ?[]const u8 {
        const bytes = self.pending.items;
        const prefix: usize = if (bytes.len >= 2 and bytes[0] == 0x1b) 2 else 1;
        const suffix: usize = if (bytes.len >= 2 and bytes[bytes.len - 2] == 0x1b and bytes[bytes.len - 1] == '\\')
            2
        else
            1;
        if (prefix + suffix > bytes.len) return null;
        return bytes[prefix .. bytes.len - suffix];
    }

    fn pendingLooksLikeGraphics(self: *const Normalizer) bool {
        if (self.overflowed) return self.state != .escape;
        const bytes = self.pending.items;
        return switch (baseState(self.state)) {
            .apc => (bytes.len >= 3 and bytes[0] == 0x1b and bytes[1] == '_' and bytes[2] == 'G') or
                (bytes.len >= 2 and bytes[0] == 0x9f and bytes[1] == 'G'),
            .dcs => sixelPayloadIncomplete(bytes),
            .osc => std.mem.indexOf(u8, bytes, "1337;File") != null or
                std.mem.indexOf(u8, bytes, "1337;MultipartFile") != null,
            else => false,
        };
    }

    fn normalizeIterm(
        self: *Normalizer,
        alloc: std.mem.Allocator,
        geometry: Geometry,
        command: []const u8,
        out: *std.ArrayList(u8),
    ) !FeedResult {
        if (std.mem.startsWith(u8, command, "File=")) {
            const value = command[5..];
            const colon = std.mem.indexOfScalar(u8, value, ':') orelse return dropGraphics(alloc, out);
            if (!itermInline(value[0..colon])) {
                try out.appendSlice(alloc, self.pending.items);
                return .{};
            }
            return normalizeItermImage(alloc, geometry, value[0..colon], value[colon + 1 ..], out);
        }
        if (std.mem.startsWith(u8, command, "MultipartFile=")) {
            self.multipart.reset();
            self.multipart.active = true;
            try self.multipart.metadata.appendSlice(alloc, command[14..]);
            if (!itermInline(command[14..])) {
                self.multipart.passthrough = true;
                try out.appendSlice(alloc, self.pending.items);
                return .{};
            }
            return .{ .graphics = true };
        }
        if (std.mem.startsWith(u8, command, "FilePart=")) {
            if (!self.multipart.active) return dropGraphics(alloc, out);
            if (self.multipart.passthrough) {
                try out.appendSlice(alloc, self.pending.items);
                return .{};
            }
            if (self.multipart.encoded.items.len + command.len - 9 > max_control_string_bytes) {
                self.multipart.reset();
                return dropGraphics(alloc, out);
            }
            try self.multipart.encoded.appendSlice(alloc, command[9..]);
            return .{ .graphics = true };
        }
        if (std.mem.eql(u8, command, "FileEnd")) {
            if (!self.multipart.active) return dropGraphics(alloc, out);
            defer self.multipart.reset();
            if (self.multipart.passthrough) {
                try out.appendSlice(alloc, self.pending.items);
                return .{};
            }
            return normalizeItermImage(
                alloc,
                geometry,
                self.multipart.metadata.items,
                self.multipart.encoded.items,
                out,
            );
        }

        // Other OSC 1337 commands are unrelated to images.
        try out.appendSlice(alloc, self.pending.items);
        return .{};
    }
};

fn isStringIntroducer(byte: u8) bool {
    return byte == 0x1b or byte == 0x90 or byte == 0x9b or byte == 0x9d or byte == 0x9f;
}

fn csiMayBeSixelMode(bytes: []const u8) bool {
    for ([_][]const u8{
        "\x1b[?80h",
        "\x1b[?80l",
        "\x1b[?8452h",
        "\x1b[?8452l",
        "\x1b[?1070h",
        "\x1b[?1070l",
    }) |sequence| {
        const len = @min(bytes.len, sequence.len);
        if (std.mem.eql(u8, bytes[0..len], sequence[0..len])) return true;
    }
    return false;
}

fn dcsHeaderIsNonSixel(body: []const u8) bool {
    for (body) |byte| {
        if (byte >= 0x40 and byte <= 0x7e) return byte != 'q';
    }
    return false;
}

fn baseState(state: Normalizer.State) Normalizer.State {
    return switch (state) {
        .apc, .apc_escape => .apc,
        .dcs, .dcs_escape => .dcs,
        .osc, .osc_escape => .osc,
        else => state,
    };
}

fn dropGraphics(alloc: std.mem.Allocator, out: *std.ArrayList(u8)) !FeedResult {
    try out.appendSlice(alloc, delete_all_images);
    return .{ .graphics = true, .dropped = true, .effect = .cleared };
}

fn normalizeKitty(
    io: std.Io,
    alloc: std.mem.Allocator,
    temp_dir: []const u8,
    mode: Mode,
    body: []const u8,
    original: []const u8,
    out: *std.ArrayList(u8),
    replies: *std.ArrayList(u8),
) !FeedResult {
    var cmd = vt.kitty.graphics.CommandParser.parseString(alloc, body) catch
        return dropGraphics(alloc, out);
    defer cmd.deinit(alloc);

    const advanced_animation = switch (cmd.control) {
        .transmit_animation_frame, .control_animation, .compose_animation => true,
        else => false,
    };
    if (advanced_animation) {
        if (mode == .composed) return dropGraphics(alloc, out);
        try out.appendSlice(alloc, original);
        return .{ .graphics = true, .effect = .clear_discard };
    }

    const clears_all = switch (cmd.control) {
        .delete => |deletion| switch (deletion) {
            .all => |delete_payload| delete_payload,
            else => false,
        },
        else => false,
    };
    if (cmd.display()) |display| {
        const relative = display.parent_id != 0 or
            display.parent_placement_id != 0 or display.horizontal_offset != 0 or
            display.vertical_offset != 0;
        if (relative and mode == .composed) return dropGraphics(alloc, out);
        if (display.virtual_placement and relative) return dropGraphics(alloc, out);
        if (relative and cmd.transmission() == null) {
            try out.appendSlice(alloc, original);
            return .{ .graphics = true, .effect = .clear_discard };
        }
    }

    const transmission = cmd.transmission() orelse {
        try out.appendSlice(alloc, original);
        return .{
            .graphics = true,
            .effect = if (clears_all) .cleared else kittyReferenceEffect(cmd),
        };
    };
    if (transmission.medium == .direct) {
        try out.appendSlice(alloc, original);
        return .{ .graphics = true, .effect = kittyReferenceEffect(cmd) };
    }

    var loading = vt.kitty.graphics.LoadingImage.init(
        io,
        alloc,
        &cmd,
        .allWithTempDir(temp_dir),
    ) catch {
        try appendKittyErrorReply(alloc, replies, cmd, "EINVAL: image transport unavailable");
        return dropGraphics(alloc, out);
    };
    defer loading.deinit(alloc);
    var image = loading.complete(alloc) catch {
        try appendKittyErrorReply(alloc, replies, cmd, "EINVAL: image load failed");
        return dropGraphics(alloc, out);
    };
    defer image.deinit(alloc);

    const pixels = try imageAsKittyPixels(alloc, &image);
    defer if (pixels.owned) alloc.free(pixels.data);
    try emitKittyDirect(
        alloc,
        out,
        switch (cmd.control) {
            .query => 'q',
            .transmit => 't',
            .transmit_and_display => 'T',
            else => unreachable,
        },
        transmission,
        cmd.display(),
        quietCode(cmd.quiet),
        pixels.format,
        image.width,
        image.height,
        pixels.data,
    );
    return .{ .graphics = true, .effect = kittyReferenceEffect(cmd) };
}

fn appendKittyErrorReply(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    cmd: anytype,
    message: []const u8,
) !void {
    if (cmd.quiet == .failures) return;
    try out.appendSlice(alloc, "\x1b_G");
    var separator: []const u8 = "";
    if (cmd.transmission()) |transmission| {
        if (transmission.image_id != 0) {
            try out.print(alloc, "i={d}", .{transmission.image_id});
            separator = ",";
        }
        if (transmission.image_number != 0) {
            try out.print(alloc, "{s}I={d}", .{ separator, transmission.image_number });
            separator = ",";
        }
    }
    if (cmd.display()) |display| {
        if (display.placement_id != 0) {
            try out.print(alloc, "{s}p={d}", .{ separator, display.placement_id });
        }
    }
    try out.print(alloc, ";{s}\x1b\\", .{message});
}

fn kittyReferenceEffect(cmd: anytype) Effect {
    if (cmd.display()) |display| {
        if (display.parent_id != 0 or display.parent_placement_id != 0 or
            display.horizontal_offset != 0 or display.vertical_offset != 0)
        {
            return .clear_discard;
        }
        if (display.image_id == 0 and display.image_number == 0) return .clear_retain;
    }
    if (cmd.transmission()) |transmission| {
        if (transmission.image_id == 0 and transmission.image_number == 0) return .clear_retain;
    }
    return .precise;
}

const KittyPixels = struct {
    format: u32,
    data: []const u8,
    owned: bool = false,
};

fn imageAsKittyPixels(alloc: std.mem.Allocator, image: anytype) !KittyPixels {
    return switch (image.format) {
        .rgb => .{ .format = 24, .data = image.data },
        .rgba => .{ .format = 32, .data = image.data },
        .gray, .gray_alpha => convert: {
            const channels: usize = if (image.format == .gray) 1 else 2;
            const data = try alloc.alloc(u8, @as(usize, image.width) * @as(usize, image.height) * 4);
            var src: usize = 0;
            var dst: usize = 0;
            while (src < image.data.len) : (src += channels) {
                const value = image.data[src];
                data[dst] = value;
                data[dst + 1] = value;
                data[dst + 2] = value;
                data[dst + 3] = if (channels == 2) image.data[src + 1] else 255;
                dst += 4;
            }
            break :convert .{ .format = 32, .data = data, .owned = true };
        },
        .png => unreachable,
    };
}

fn quietCode(quiet: anytype) u8 {
    return switch (quiet) {
        .no => 0,
        .ok => 1,
        .failures => 2,
    };
}

const DisplayOptions = struct {
    columns: u32 = 0,
    rows: u32 = 0,
    cursor_none: bool = false,
};

fn emitKittyDirect(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    action: u8,
    transmission: anytype,
    display: anytype,
    quiet: u8,
    format: u32,
    width: u32,
    height: u32,
    data: []const u8,
) !void {
    if (data.len == 0) return;
    var offset: usize = 0;
    while (offset < data.len) {
        const end = @min(offset + kitty_chunk_bytes, data.len);
        const more = end < data.len;
        const chunk = data[offset..end];
        const encoded_len = std.base64.standard.Encoder.calcSize(chunk.len);
        const encoded = try alloc.alloc(u8, encoded_len);
        defer alloc.free(encoded);
        _ = std.base64.standard.Encoder.encode(encoded, chunk);

        if (offset == 0) {
            try out.print(alloc, "\x1b_Ga={c},t=d,f={d},s={d},v={d}", .{ action, format, width, height });
            if (transmission.image_id != 0) try out.print(alloc, ",i={d}", .{transmission.image_id});
            if (transmission.image_number != 0) try out.print(alloc, ",I={d}", .{transmission.image_number});
            if (@as(u32, @bitCast(transmission.usage)) != 0) {
                try out.print(alloc, ",N={d}", .{@as(u32, @bitCast(transmission.usage))});
            }
            if (display) |d| try appendDisplay(alloc, out, d);
            try out.print(alloc, ",m={d},q={d};{s}\x1b\\", .{ @intFromBool(more), quiet, encoded });
        } else {
            try out.print(alloc, "\x1b_Gm={d},q={d};{s}\x1b\\", .{ @intFromBool(more), quiet, encoded });
        }
        offset = end;
    }
}

fn emitRgba(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    image: DecodedImage,
    display: DisplayOptions,
) !void {
    var offset: usize = 0;
    while (offset < image.data.len) {
        const end = @min(offset + kitty_chunk_bytes, image.data.len);
        const more = end < image.data.len;
        const chunk = image.data[offset..end];
        const encoded_len = std.base64.standard.Encoder.calcSize(chunk.len);
        const encoded = try alloc.alloc(u8, encoded_len);
        defer alloc.free(encoded);
        _ = std.base64.standard.Encoder.encode(encoded, chunk);
        if (offset == 0) {
            try out.print(
                alloc,
                "\x1b_Ga=T,t=d,f=32,s={d},v={d}",
                .{ image.width, image.height },
            );
            if (display.columns != 0) try out.print(alloc, ",c={d}", .{display.columns});
            if (display.rows != 0) try out.print(alloc, ",r={d}", .{display.rows});
            if (display.cursor_none) try out.appendSlice(alloc, ",C=1");
            try out.print(alloc, ",m={d},q=2;{s}\x1b\\", .{ @intFromBool(more), encoded });
        } else {
            try out.print(alloc, "\x1b_Gm={d},q=2;{s}\x1b\\", .{ @intFromBool(more), encoded });
        }
        offset = end;
    }
}

fn appendDisplay(alloc: std.mem.Allocator, out: *std.ArrayList(u8), d: anytype) !void {
    if (d.placement_id != 0) try out.print(alloc, ",p={d}", .{d.placement_id});
    if (d.x != 0) try out.print(alloc, ",x={d}", .{d.x});
    if (d.y != 0) try out.print(alloc, ",y={d}", .{d.y});
    if (d.width != 0) try out.print(alloc, ",w={d}", .{d.width});
    if (d.height != 0) try out.print(alloc, ",h={d}", .{d.height});
    if (d.x_offset != 0) try out.print(alloc, ",X={d}", .{d.x_offset});
    if (d.y_offset != 0) try out.print(alloc, ",Y={d}", .{d.y_offset});
    if (d.columns != 0) try out.print(alloc, ",c={d}", .{d.columns});
    if (d.rows != 0) try out.print(alloc, ",r={d}", .{d.rows});
    if (d.cursor_movement == .none) try out.appendSlice(alloc, ",C=1");
    if (d.virtual_placement) try out.appendSlice(alloc, ",U=1");
    if (d.parent_id != 0) try out.print(alloc, ",P={d}", .{d.parent_id});
    if (d.parent_placement_id != 0) try out.print(alloc, ",Q={d}", .{d.parent_placement_id});
    if (d.horizontal_offset != 0) try out.print(alloc, ",H={d}", .{d.horizontal_offset});
    if (d.vertical_offset != 0) try out.print(alloc, ",V={d}", .{d.vertical_offset});
    if (d.z != 0) try out.print(alloc, ",z={d}", .{d.z});
}

fn sixelPayload(body: []const u8) ?[]const u8 {
    for (body, 0..) |byte, i| {
        if (byte >= 0x40 and byte <= 0x7e) {
            if (byte != 'q') return null;
            return body[i + 1 ..];
        }
    }
    return null;
}

fn sixelPayloadIncomplete(bytes: []const u8) bool {
    const body_start: usize = if (bytes.len >= 2 and bytes[0] == 0x1b and bytes[1] == 'P')
        2
    else if (bytes.len >= 1 and bytes[0] == 0x90)
        1
    else
        return false;
    for (bytes[body_start..]) |byte| {
        if (byte >= 0x40 and byte <= 0x7e) return byte == 'q';
    }
    return false;
}

fn normalizeSixel(
    self: *Normalizer,
    alloc: std.mem.Allocator,
    body: []const u8,
    payload: []const u8,
    geometry: Geometry,
    out: *std.ArrayList(u8),
) !FeedResult {
    if (!self.sixel_palette_initialized or self.sixel_private_palette) {
        initSixelPalette(&self.sixel_palette);
        self.sixel_palette_initialized = true;
    }
    const params = parseSixelParams(body) orelse return dropGraphics(alloc, out);
    var image = decodeSixel(alloc, payload, &self.sixel_palette, params) catch return dropGraphics(alloc, out);
    defer image.deinit(alloc);
    const columns = ceilCells(image.width, geometry.cell_width) orelse return dropGraphics(alloc, out);
    const rows = ceilCells(image.height, geometry.cell_height) orelse return dropGraphics(alloc, out);
    try emitRgba(alloc, out, image, .{
        .columns = columns,
        .rows = rows,
        .cursor_none = true,
    });
    if (self.sixel_scrolling and rows > 0) {
        try out.print(alloc, "\x1b[{d}B", .{rows});
        if (self.sixel_scrolls_right) {
            if (columns > 0) try out.print(alloc, "\x1b[{d}C", .{columns});
        } else {
            try out.append(alloc, '\r');
        }
    }
    return .{ .graphics = true, .effect = .clear_retain };
}

const SixelParams = struct {
    aspect_vertical: u32 = 200,
    aspect_horizontal: u32 = 100,
    transparent: bool = false,
};

fn parseSixelParams(body: []const u8) ?SixelParams {
    const final = std.mem.indexOfScalar(u8, body, 'q') orelse return null;
    var values = [_]u32{ 0, 0, 0 };
    var fields = std.mem.splitScalar(u8, body[0..final], ';');
    var index: usize = 0;
    while (fields.next()) |field| : (index += 1) {
        if (index >= values.len) return null;
        if (field.len == 0) continue;
        values[index] = std.fmt.parseInt(u32, field, 10) catch return null;
    }
    // Modern sixel implementations, including xterm, render the default
    // macro using square pixels. Preserve explicit legacy macro ratios.
    const vertical = [_]u32{ 100, 200, 450, 300, 250, 183, 150, 130, 112, 100 };
    const macro = if (values[0] < vertical.len) values[0] else 0;
    return .{
        .aspect_vertical = vertical[macro],
        .aspect_horizontal = 100,
        .transparent = values[1] == 1,
    };
}

const DecodedImage = struct {
    width: u32,
    height: u32,
    data: []u8,

    fn deinit(self: *DecodedImage, alloc: std.mem.Allocator) void {
        alloc.free(self.data);
    }
};

fn normalizeItermImage(
    alloc: std.mem.Allocator,
    geometry: Geometry,
    metadata: []const u8,
    encoded: []const u8,
    out: *std.ArrayList(u8),
) !FeedResult {
    var width: ItermDimension = .auto;
    var height: ItermDimension = .auto;
    var preserve_aspect_ratio = true;
    var cursor_none = false;
    var fields = std.mem.splitScalar(u8, metadata, ';');
    while (fields.next()) |field| {
        const equals = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        const key = field[0..equals];
        const value = field[equals + 1 ..];
        if (std.mem.eql(u8, key, "width")) width = parseItermDimension(value) orelse return dropGraphics(alloc, out);
        if (std.mem.eql(u8, key, "height")) height = parseItermDimension(value) orelse return dropGraphics(alloc, out);
        if (std.mem.eql(u8, key, "preserveAspectRatio")) preserve_aspect_ratio = !std.mem.eql(u8, value, "0");
        if (std.mem.eql(u8, key, "doNotMoveCursor")) cursor_none = std.mem.eql(u8, value, "1");
    }

    const Decoder = std.base64.standard.Decoder;
    const decoded_len = Decoder.calcSizeForSlice(encoded) catch return dropGraphics(alloc, out);
    if (decoded_len == 0 or decoded_len > max_image_bytes) return dropGraphics(alloc, out);
    const encoded_image = try alloc.alloc(u8, decoded_len);
    defer alloc.free(encoded_image);
    Decoder.decode(encoded_image, encoded) catch return dropGraphics(alloc, out);

    var image = decodeRasterImage(alloc, encoded_image) catch return dropGraphics(alloc, out);
    defer image.deinit(alloc);
    const display = resolveItermDisplay(
        geometry,
        image.width,
        image.height,
        width,
        height,
        preserve_aspect_ratio,
        cursor_none,
    ) orelse return dropGraphics(alloc, out);
    try emitRgba(alloc, out, image, display);
    return .{ .graphics = true, .effect = .clear_retain };
}

fn itermInline(metadata: []const u8) bool {
    var fields = std.mem.splitScalar(u8, metadata, ';');
    while (fields.next()) |field| {
        const equals = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        if (std.mem.eql(u8, field[0..equals], "inline")) {
            return std.mem.eql(u8, field[equals + 1 ..], "1");
        }
    }
    return false;
}

const ItermDimension = union(enum) {
    auto,
    cells: u32,
    pixels: u32,
    percent: u32,
};

fn parseItermDimension(value: []const u8) ?ItermDimension {
    if (value.len == 0 or std.mem.eql(u8, value, "auto")) return .auto;
    var digits = value;
    const kind: enum { cells, pixels, percent } = if (std.mem.endsWith(u8, value, "px")) kind: {
        digits = value[0 .. value.len - 2];
        break :kind .pixels;
    } else if (std.mem.endsWith(u8, value, "%")) kind: {
        digits = value[0 .. value.len - 1];
        break :kind .percent;
    } else .cells;
    if (digits.len == 0) return null;
    for (digits) |byte| if (byte < '0' or byte > '9') return null;
    const number = std.fmt.parseInt(u32, digits, 10) catch return null;
    if (number == 0) return null;
    return switch (kind) {
        .cells => .{ .cells = number },
        .pixels => .{ .pixels = number },
        .percent => .{ .percent = @min(number, 100) },
    };
}

fn dimensionPixels(
    dimension: ItermDimension,
    natural: u32,
    cells: u16,
    cell_pixels: u32,
) ?struct { pixels: u64, automatic: bool, exact_cells: ?u32 = null } {
    return switch (dimension) {
        .auto => .{ .pixels = natural, .automatic = true },
        .cells => |value| .{
            .pixels = std.math.mul(u64, value, cell_pixels) catch return null,
            .automatic = false,
            .exact_cells = value,
        },
        .pixels => |value| .{ .pixels = value, .automatic = false },
        .percent => |value| .{
            .pixels = (std.math.mul(u64, cells, cell_pixels) catch return null) * value / 100,
            .automatic = false,
        },
    };
}

fn ceilCells(pixels: u64, cell_pixels: u32) ?u32 {
    if (cell_pixels == 0) return null;
    const value = (pixels + cell_pixels - 1) / cell_pixels;
    return std.math.cast(u32, @max(value, 1));
}

fn resolveItermDisplay(
    geometry: Geometry,
    natural_width: u32,
    natural_height: u32,
    width: ItermDimension,
    height: ItermDimension,
    preserve_aspect_ratio: bool,
    cursor_none: bool,
) ?DisplayOptions {
    if (natural_width == 0 or natural_height == 0 or geometry.cell_width == 0 or geometry.cell_height == 0) return null;
    var requested_width = dimensionPixels(width, natural_width, geometry.columns, geometry.cell_width) orelse return null;
    var requested_height = dimensionPixels(height, natural_height, geometry.rows, geometry.cell_height) orelse return null;

    if (preserve_aspect_ratio) {
        if (requested_width.automatic and !requested_height.automatic) {
            requested_width.pixels = requested_height.pixels * natural_width / natural_height;
        } else if (!requested_width.automatic and requested_height.automatic) {
            requested_height.pixels = requested_width.pixels * natural_height / natural_width;
        } else if (!requested_width.automatic and !requested_height.automatic) {
            if (requested_width.pixels * natural_height > requested_height.pixels * natural_width) {
                requested_width.pixels = requested_height.pixels * natural_width / natural_height;
                requested_width.exact_cells = null;
            } else {
                requested_height.pixels = requested_width.pixels * natural_height / natural_width;
                requested_height.exact_cells = null;
            }
        }
    }

    const columns = requested_width.exact_cells orelse ceilCells(requested_width.pixels, geometry.cell_width) orelse return null;
    const rows = requested_height.exact_cells orelse ceilCells(requested_height.pixels, geometry.cell_height) orelse return null;
    if (columns > 10000 or rows > 10000) return null;
    return .{ .columns = columns, .rows = rows, .cursor_none = cursor_none };
}

fn decodeRasterImage(alloc: std.mem.Allocator, data: []const u8) !DecodedImage {
    const decoded = if (std.mem.startsWith(u8, data, "\x89PNG\r\n\x1a\n"))
        try wuffs.png.decode(alloc, data)
    else if (std.mem.startsWith(u8, data, "\xff\xd8\xff"))
        try wuffs.jpeg.decode(alloc, data)
    else
        return error.UnsupportedImageFormat;
    const pixel_count = try std.math.mul(usize, decoded.width, decoded.height);
    const byte_count = try std.math.mul(usize, pixel_count, 4);
    if (decoded.width == 0 or decoded.height == 0 or
        decoded.width > 10000 or decoded.height > 10000 or
        byte_count > max_image_bytes or decoded.data.len > max_image_bytes)
    {
        alloc.free(decoded.data);
        return error.ImageTooLarge;
    }
    return .{ .width = decoded.width, .height = decoded.height, .data = decoded.data };
}

const SixelExtent = struct {
    width: u32 = 0,
    height: u32 = 0,
    declared_width: u32 = 0,
    declared_height: u32 = 0,
    aspect_vertical: u32 = 1,
    aspect_horizontal: u32 = 1,
};

const Rgba = [4]u8;

fn decodeSixel(
    alloc: std.mem.Allocator,
    data: []const u8,
    persistent_palette: *[256]Rgba,
    params: SixelParams,
) !DecodedImage {
    var extent: SixelExtent = .{
        .aspect_vertical = params.aspect_vertical,
        .aspect_horizontal = params.aspect_horizontal,
    };
    var extent_palette = persistent_palette.*;
    try walkSixel(data, &extent_palette, &extent, null, 0, 0);
    const width = @max(extent.width, extent.declared_width);
    const height = @max(extent.height, extent.declared_height);
    if (width == 0 or height == 0 or width > 10000 or height > 10000) return error.InvalidSixel;
    const pixel_count = try std.math.mul(usize, @as(usize, width), @as(usize, height));
    const byte_count = try std.math.mul(usize, pixel_count, 4);
    if (byte_count > max_image_bytes) return error.ImageTooLarge;
    const pixels = try alloc.alloc(u8, byte_count);
    if (params.transparent) {
        @memset(pixels, 0);
    } else {
        var offset: usize = 0;
        while (offset < pixels.len) : (offset += 4) {
            @memcpy(pixels[offset .. offset + 4], &persistent_palette[0]);
        }
    }
    errdefer alloc.free(pixels);
    var paint_palette = persistent_palette.*;
    try walkSixel(data, &paint_palette, null, pixels, width, height);
    persistent_palette.* = paint_palette;
    var image: DecodedImage = .{ .width = width, .height = height, .data = pixels };
    if (extent.aspect_vertical != extent.aspect_horizontal) {
        image = try scaleSixelAspect(alloc, image, extent.aspect_vertical, extent.aspect_horizontal);
    }
    return image;
}

fn walkSixel(
    data: []const u8,
    palette: *[256]Rgba,
    extent: ?*SixelExtent,
    pixels: ?[]u8,
    width: u32,
    height: u32,
) !void {
    var color_index: usize = 0;
    var x: u32 = 0;
    var y: u32 = 0;
    var i: usize = 0;
    while (i < data.len) {
        const byte = data[i];
        switch (byte) {
            '$' => {
                x = 0;
                i += 1;
            },
            '-' => {
                x = 0;
                y +|= 6;
                i += 1;
            },
            '!' => {
                i += 1;
                const repeat = parseSixelNumber(data, &i) orelse return error.InvalidSixel;
                if (i >= data.len or data[i] < '?' or data[i] > '~') return error.InvalidSixel;
                try paintSixelColumn(data[i] - '?', repeat, palette[color_index], &x, y, extent, pixels, width, height);
                i += 1;
            },
            '#' => {
                i += 1;
                const index = parseSixelNumber(data, &i) orelse return error.InvalidSixel;
                color_index = @min(@as(usize, index), palette.len - 1);
                if (i < data.len and data[i] == ';') {
                    i += 1;
                    const mode = parseSixelNumber(data, &i) orelse return error.InvalidSixel;
                    if (i >= data.len or data[i] != ';') return error.InvalidSixel;
                    i += 1;
                    const a = parseSixelNumber(data, &i) orelse return error.InvalidSixel;
                    if (i >= data.len or data[i] != ';') return error.InvalidSixel;
                    i += 1;
                    const b = parseSixelNumber(data, &i) orelse return error.InvalidSixel;
                    if (i >= data.len or data[i] != ';') return error.InvalidSixel;
                    i += 1;
                    const c = parseSixelNumber(data, &i) orelse return error.InvalidSixel;
                    palette[color_index] = switch (mode) {
                        1 => hlsToRgba(a, b, c),
                        2 => .{ percentByte(a), percentByte(b), percentByte(c), 255 },
                        else => return error.InvalidSixel,
                    };
                }
            },
            '"' => {
                i += 1;
                var values = [_]u32{ 0, 0, 0, 0 };
                var count: usize = 0;
                while (count < values.len) : (count += 1) {
                    values[count] = parseSixelNumber(data, &i) orelse 0;
                    if (i >= data.len or data[i] != ';') {
                        count += 1;
                        break;
                    }
                    i += 1;
                }
                if (extent) |e| if (count >= 4) {
                    e.declared_width = values[2];
                    e.declared_height = values[3];
                };
                if (extent) |e| if (count >= 2 and values[0] != 0 and values[1] != 0) {
                    e.aspect_vertical = values[0];
                    e.aspect_horizontal = values[1];
                };
            },
            '?'...'~' => {
                try paintSixelColumn(byte - '?', 1, palette[color_index], &x, y, extent, pixels, width, height);
                i += 1;
            },
            else => i += 1,
        }
        if (x > 10000 or y > 10000) return error.ImageTooLarge;
    }
}

fn scaleSixelAspect(
    alloc: std.mem.Allocator,
    source: DecodedImage,
    vertical: u32,
    horizontal: u32,
) !DecodedImage {
    if (vertical == 0 or horizontal == 0) return source;
    const scaled_height_u64 = (@as(u64, source.height) * vertical + horizontal - 1) / horizontal;
    const scaled_height = std.math.cast(u32, @max(scaled_height_u64, 1)) orelse return error.ImageTooLarge;
    if (scaled_height == source.height) return source;
    const count = try std.math.mul(usize, @as(usize, source.width), @as(usize, scaled_height));
    const bytes = try std.math.mul(usize, count, 4);
    if (bytes > max_image_bytes) return error.ImageTooLarge;
    const data = try alloc.alloc(u8, bytes);
    errdefer alloc.free(data);
    for (0..scaled_height) |dst_y| {
        const src_y = @min((@as(u64, dst_y) * horizontal) / vertical, source.height - 1);
        const src_start = @as(usize, source.width) * @as(usize, @intCast(src_y)) * 4;
        const dst_start = @as(usize, source.width) * dst_y * 4;
        @memcpy(data[dst_start .. dst_start + @as(usize, source.width) * 4], source.data[src_start .. src_start + @as(usize, source.width) * 4]);
    }
    alloc.free(source.data);
    return .{ .width = source.width, .height = scaled_height, .data = data };
}

fn parseSixelNumber(data: []const u8, i: *usize) ?u32 {
    const start = i.*;
    var value: u32 = 0;
    while (i.* < data.len and data[i.*] >= '0' and data[i.*] <= '9') : (i.* += 1) {
        value = std.math.mul(u32, value, 10) catch return null;
        value = std.math.add(u32, value, data[i.*] - '0') catch return null;
    }
    return if (i.* == start) null else value;
}

fn paintSixelColumn(
    pattern: u8,
    repeat: u32,
    color: Rgba,
    x: *u32,
    y: u32,
    extent: ?*SixelExtent,
    pixels: ?[]u8,
    width: u32,
    height: u32,
) !void {
    if (repeat == 0) return;
    const end_x = std.math.add(u32, x.*, repeat) catch return error.ImageTooLarge;
    if (extent) |e| {
        e.width = @max(e.width, end_x);
        e.height = @max(e.height, std.math.add(u32, y, 6) catch return error.ImageTooLarge);
    }
    if (pixels) |dst| {
        var px = x.*;
        while (px < end_x and px < width) : (px += 1) {
            var bit: u3 = 0;
            while (bit < 6) : (bit += 1) {
                const py = y + @as(u32, bit);
                if (py >= height) continue;
                if (pattern & (@as(u8, 1) << bit) == 0) continue;
                const offset = (@as(usize, py) * @as(usize, width) + @as(usize, px)) * 4;
                @memcpy(dst[offset .. offset + 4], &color);
            }
        }
    }
    x.* = end_x;
}

fn initSixelPalette(palette: *[256]Rgba) void {
    const ansi = [_][3]u8{
        .{ 0, 0, 0 },       .{ 205, 0, 0 },   .{ 0, 205, 0 },   .{ 205, 205, 0 },
        .{ 0, 0, 238 },     .{ 205, 0, 205 }, .{ 0, 205, 205 }, .{ 229, 229, 229 },
        .{ 127, 127, 127 }, .{ 255, 0, 0 },   .{ 0, 255, 0 },   .{ 255, 255, 0 },
        .{ 92, 92, 255 },   .{ 255, 0, 255 }, .{ 0, 255, 255 }, .{ 255, 255, 255 },
    };
    for (ansi, 0..) |rgb, i| palette[i] = .{ rgb[0], rgb[1], rgb[2], 255 };
    for (16..232) |i| {
        const n = i - 16;
        const r = n / 36;
        const g = (n / 6) % 6;
        const b = n % 6;
        palette[i] = .{ cubeByte(r), cubeByte(g), cubeByte(b), 255 };
    }
    for (232..256) |i| {
        const value: u8 = @intCast(8 + (i - 232) * 10);
        palette[i] = .{ value, value, value, 255 };
    }
}

fn cubeByte(value: usize) u8 {
    return if (value == 0) 0 else @intCast(55 + value * 40);
}

fn percentByte(value: u32) u8 {
    const bounded: u32 = @min(value, 100);
    return @intCast((bounded * @as(u32, 255) + 50) / 100);
}

fn hlsToRgba(hue_raw: u32, lightness_raw: u32, saturation_raw: u32) Rgba {
    const h = @as(f64, @floatFromInt(hue_raw % 360)) / 360.0;
    const l = @as(f64, @floatFromInt(@min(lightness_raw, 100))) / 100.0;
    const s = @as(f64, @floatFromInt(@min(saturation_raw, 100))) / 100.0;
    if (s == 0) {
        const value: u8 = @intFromFloat(@round(l * 255.0));
        return .{ value, value, value, 255 };
    }
    const q = if (l < 0.5) l * (1.0 + s) else l + s - l * s;
    const p = 2.0 * l - q;
    return .{
        hueByte(p, q, h + 1.0 / 3.0),
        hueByte(p, q, h),
        hueByte(p, q, h - 1.0 / 3.0),
        255,
    };
}

fn hueByte(p: f64, q: f64, hue_raw: f64) u8 {
    var hue = hue_raw;
    if (hue < 0) hue += 1;
    if (hue > 1) hue -= 1;
    const value = if (hue < 1.0 / 6.0)
        p + (q - p) * 6.0 * hue
    else if (hue < 0.5)
        q
    else if (hue < 2.0 / 3.0)
        p + (q - p) * (2.0 / 3.0 - hue) * 6.0
    else
        p;
    return @intFromFloat(@round(std.math.clamp(value, 0.0, 1.0) * 255.0));
}

test "normalizer preserves fragmented non-graphics strings" {
    const testing = std.testing;
    var normalizer: Normalizer = .{};
    defer normalizer.deinit(testing.allocator);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    _ = try normalizer.feed(testing.io, testing.allocator, "/tmp", "a\x1b]0;hel", &out);
    _ = try normalizer.feed(testing.io, testing.allocator, "/tmp", "lo\x1b\\b", &out);
    try testing.expectEqualStrings("a\x1b]0;hello\x1b\\b", out.items);
}

test "normalizer preserves fragmented UTF-8 across C1 byte values" {
    const testing = std.testing;
    var normalizer: Normalizer = .{};
    defer normalizer.deinit(testing.allocator);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const text = "before ❯АП after";

    for (text) |byte| {
        _ = try normalizer.feed(testing.io, testing.allocator, "/tmp", &.{byte}, &out);
    }

    try testing.expectEqualStrings(text, out.items);
    try testing.expect(!normalizer.hasPending());
}

test "normalizer still recognizes standalone 8-bit C1 strings" {
    const testing = std.testing;
    var normalizer: Normalizer = .{};
    defer normalizer.deinit(testing.allocator);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);

    _ = try normalizer.feed(testing.io, testing.allocator, "/tmp", "\x9d0;title\x07", &out);

    try testing.expectEqualStrings("\x9d0;title\x07", out.items);
    try testing.expect(!normalizer.hasPending());
}

test "normalizer identifies the zero-copy fast path" {
    const testing = std.testing;
    var normalizer: Normalizer = .{};
    defer normalizer.deinit(testing.allocator);
    try testing.expect(!normalizer.needsProcessing("plain text\r\n\x1b[31mCSI is not a control string"));
    try testing.expect(normalizer.needsProcessing("\x1b]0;title\x07"));

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    _ = try normalizer.feed(testing.io, testing.allocator, "/tmp", "\x1b]0;part", &out);
    try testing.expect(normalizer.needsProcessing("ial\x07"));
}

test "normalizer converts sixel to direct kitty rgba" {
    const testing = std.testing;
    var normalizer: Normalizer = .{};
    defer normalizer.deinit(testing.allocator);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const result = try normalizer.feed(
        testing.io,
        testing.allocator,
        "/tmp",
        "\x1bPq#1;2;100;0;0~\x1b\\",
        &out,
    );
    try testing.expect(result.graphics);
    try testing.expect(!result.dropped);
    try testing.expect(std.mem.startsWith(u8, out.items, "\x1b_Ga=T,t=d,f=32,s=1,v=6"));
    try testing.expect(std.mem.indexOf(u8, out.items, "\x1b\\\x1b[1B\r") != null);
}

test "sixel P2 selects opaque or transparent background" {
    const testing = std.testing;
    var palette: [256]Rgba = undefined;
    initSixelPalette(&palette);

    var opaque_image = try decodeSixel(testing.allocator, "?", &palette, .{ .transparent = false });
    defer opaque_image.deinit(testing.allocator);
    var transparent_image = try decodeSixel(testing.allocator, "?", &palette, .{ .transparent = true });
    defer transparent_image.deinit(testing.allocator);

    try testing.expectEqual(opaque_image.data.len, transparent_image.data.len);
    var alpha: usize = 3;
    while (alpha < opaque_image.data.len) : (alpha += 4) {
        try testing.expectEqual(@as(u8, 255), opaque_image.data[alpha]);
        try testing.expectEqual(@as(u8, 0), transparent_image.data[alpha]);
    }
}

test "normalizer honors sixel cursor movement modes" {
    const testing = std.testing;
    var normalizer: Normalizer = .{};
    defer normalizer.deinit(testing.allocator);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);

    _ = try normalizer.feed(
        testing.io,
        testing.allocator,
        "/tmp",
        "\x1b[?80h\x1bPq~\x1b\\",
        &out,
    );
    try testing.expect(std.mem.endsWith(u8, out.items, "\x1b\\"));

    out.clearRetainingCapacity();
    _ = try normalizer.feed(
        testing.io,
        testing.allocator,
        "/tmp",
        "\x1b[?80l\x1b[?8452h\x1bPq~\x1b\\",
        &out,
    );
    try testing.expect(std.mem.endsWith(u8, out.items, "\x1b\\\x1b[1B\x1b[1C"));
}

test "normalizer converts iTerm inline PNG to direct kitty rgba" {
    const testing = std.testing;
    var normalizer: Normalizer = .{};
    defer normalizer.deinit(testing.allocator);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";
    const sequence = try std.fmt.allocPrint(
        testing.allocator,
        "\x1b]1337;File=inline=1;width=2;height=3:{s}\x07",
        .{png},
    );
    defer testing.allocator.free(sequence);
    const result = try normalizer.feed(testing.io, testing.allocator, "/tmp", sequence, &out);
    try testing.expect(result.graphics);
    try testing.expect(!result.dropped);
    // preserveAspectRatio defaults to true, so the 1x1 source fits inside
    // the requested 2x3-cell box without stretching.
    try testing.expect(std.mem.startsWith(u8, out.items, "\x1b_Ga=T,t=d,f=32,s=1,v=1,c=2,r=1"));
}

test "normalizer supports iTerm pixel percent and stretch dimensions" {
    const testing = std.testing;
    var normalizer: Normalizer = .{};
    defer normalizer.deinit(testing.allocator);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";
    const sequence = try std.fmt.allocPrint(
        testing.allocator,
        "\x1b]1337;File=inline=1;width=50%;height=48px;preserveAspectRatio=0:{s}\x07",
        .{png},
    );
    defer testing.allocator.free(sequence);
    const result = try normalizer.feedWithOptions(
        testing.io,
        testing.allocator,
        "/tmp",
        .{ .geometry = .{ .rows = 24, .columns = 80, .cell_width = 8, .cell_height = 16 } },
        sequence,
        &out,
    );
    try testing.expect(result.graphics);
    try testing.expectEqual(Effect.clear_retain, result.effect.?);
    try testing.expect(std.mem.startsWith(u8, out.items, "\x1b_Ga=T,t=d,f=32,s=1,v=1,c=40,r=3"));
}

test "normalizer preserves non-inline iTerm transfers" {
    const testing = std.testing;
    var normalizer: Normalizer = .{};
    defer normalizer.deinit(testing.allocator);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const sequence = "\x1b]1337;File=name=dGVzdA==;inline=0:ZGF0YQ==\x07";
    const result = try normalizer.feed(testing.io, testing.allocator, "/tmp", sequence, &out);
    try testing.expect(!result.graphics);
    try testing.expectEqualStrings(sequence, out.items);
}

test "normalizer preserves UTF-8 inside streamed non-image OSC" {
    const testing = std.testing;
    var normalizer: Normalizer = .{};
    defer normalizer.deinit(testing.allocator);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const sequence = "\x1b]0;Über ❯ title\x1b\\";
    for (sequence) |byte| {
        _ = try normalizer.feed(testing.io, testing.allocator, "/tmp", &.{byte}, &out);
    }
    try testing.expectEqualStrings(sequence, out.items);
    try testing.expect(!normalizer.hasPending());
}

test "normalizer records ordered graphics event offsets" {
    const testing = std.testing;
    var normalizer: Normalizer = .{};
    defer normalizer.deinit(testing.allocator);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    _ = try normalizer.feed(
        testing.io,
        testing.allocator,
        "/tmp",
        "before\x1b_Ga=T,f=24,t=d,i=7,s=1,v=1,q=2;////\x1b\\after",
        &out,
    );
    try testing.expectEqual(@as(usize, 1), normalizer.events().len);
    const event = normalizer.events()[0];
    try testing.expectEqual(Effect.precise, event.effect);
    try testing.expectEqualStrings("after", out.items[event.output_end..]);
}

test "normalizer streams fragmented direct Kitty payloads" {
    const testing = std.testing;
    var normalizer: Normalizer = .{};
    defer normalizer.deinit(testing.allocator);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const first = "before\x1b_Ga=T,f=24,t=d,i=7,s=1,v=1,q=2;//";
    const second = "//\x1b\\after";

    const first_result = try normalizer.feedWithOptions(
        testing.io,
        testing.allocator,
        "/tmp",
        .{ .mode = .raw },
        first,
        &out,
    );
    try testing.expect(!first_result.graphics);
    try testing.expectEqualStrings(first, out.items);
    try testing.expect(normalizer.hasPending());

    const second_result = try normalizer.feedWithOptions(
        testing.io,
        testing.allocator,
        "/tmp",
        .{ .mode = .raw },
        second,
        &out,
    );
    try testing.expect(second_result.graphics);
    try testing.expectEqual(Effect.precise, second_result.effect.?);
    try testing.expectEqualStrings(first ++ second, out.items);
    try testing.expectEqual(@as(usize, 1), normalizer.events().len);
    try testing.expectEqualStrings("after", out.items[normalizer.events()[0].output_end..]);
}

test "normalizer preserves advanced Kitty graphics only in raw mode" {
    const testing = std.testing;
    const animation = "\x1b_Ga=a,s=3,i=1;\x1b\\";
    var raw: Normalizer = .{};
    defer raw.deinit(testing.allocator);
    var raw_out: std.ArrayList(u8) = .empty;
    defer raw_out.deinit(testing.allocator);
    const raw_result = try raw.feedWithOptions(
        testing.io,
        testing.allocator,
        "/tmp",
        .{ .mode = .raw },
        animation,
        &raw_out,
    );
    try testing.expectEqualStrings(animation, raw_out.items);
    try testing.expectEqual(Effect.clear_discard, raw_result.effect.?);

    var composed: Normalizer = .{};
    defer composed.deinit(testing.allocator);
    var composed_out: std.ArrayList(u8) = .empty;
    defer composed_out.deinit(testing.allocator);
    const composed_result = try composed.feed(testing.io, testing.allocator, "/tmp", animation, &composed_out);
    try testing.expect(composed_result.dropped);
    try testing.expectEqual(Effect.cleared, composed_result.effect.?);
    try testing.expectEqualStrings(delete_all_images, composed_out.items);
}

test "normalizer preserves static Kitty virtual placements" {
    const testing = std.testing;
    var normalizer: Normalizer = .{};
    defer normalizer.deinit(testing.allocator);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const sequence = "\x1b_Ga=T,f=24,t=d,i=7,p=3,U=1,s=1,v=1,c=1,r=1,q=2;////\x1b\\";
    const result = try normalizer.feed(testing.io, testing.allocator, "/tmp", sequence, &out);
    try testing.expect(!result.dropped);
    try testing.expectEqual(Effect.precise, result.effect.?);
    try testing.expectEqualStrings(sequence, out.items);
}

test "normalizer returns a Kitty error for failed external transport" {
    const testing = std.testing;
    const path = "/tmp/tinymux-definitely-missing-image";
    const encoded_len = std.base64.standard.Encoder.calcSize(path.len);
    const encoded = try testing.allocator.alloc(u8, encoded_len);
    defer testing.allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, path);
    const sequence = try std.fmt.allocPrint(
        testing.allocator,
        "\x1b_Ga=T,f=24,t=f,s=1,v=1,i=9,p=4,q=0;{s}\x1b\\",
        .{encoded},
    );
    defer testing.allocator.free(sequence);
    var normalizer: Normalizer = .{};
    defer normalizer.deinit(testing.allocator);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const result = try normalizer.feed(testing.io, testing.allocator, "/tmp", sequence, &out);
    try testing.expect(result.dropped);
    try testing.expect(std.mem.indexOf(u8, normalizer.replies(), "i=9,p=4;EINVAL") != null);
}

test "normalizer assembles iTerm multipart images" {
    const testing = std.testing;
    var normalizer: Normalizer = .{};
    defer normalizer.deinit(testing.allocator);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";
    const split = png.len / 2;
    const start = "\x1b]1337;MultipartFile=inline=1;width=4;height=2\x07";
    const part_one = try std.fmt.allocPrint(testing.allocator, "\x1b]1337;FilePart={s}\x07", .{png[0..split]});
    defer testing.allocator.free(part_one);
    const part_two = try std.fmt.allocPrint(testing.allocator, "\x1b]1337;FilePart={s}\x07", .{png[split..]});
    defer testing.allocator.free(part_two);
    const end = "\x1b]1337;FileEnd\x07";
    _ = try normalizer.feed(testing.io, testing.allocator, "/tmp", start, &out);
    _ = try normalizer.feed(testing.io, testing.allocator, "/tmp", part_one, &out);
    _ = try normalizer.feed(testing.io, testing.allocator, "/tmp", part_two, &out);
    const result = try normalizer.feed(testing.io, testing.allocator, "/tmp", end, &out);
    try testing.expect(result.graphics);
    try testing.expect(!result.dropped);
    try testing.expect(std.mem.startsWith(u8, out.items, "\x1b_Ga=T,t=d,f=32,s=1,v=1,c=4,r=2"));
}

test "normalizer loads fragmented Kitty file transport once" {
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(testing.io, .{ .sub_path = "pixel.rgb", .data = &.{ 1, 2, 3 } });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try tmp_dir.dir.realPathFile(testing.io, "pixel.rgb", &path_buf)];
    var temp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const temp_dir = temp_buf[0..try tmp_dir.dir.realPath(testing.io, &temp_buf)];
    const encoded_len = std.base64.standard.Encoder.calcSize(path.len);
    const encoded = try testing.allocator.alloc(u8, encoded_len);
    defer testing.allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, path);
    const sequence = try std.fmt.allocPrint(
        testing.allocator,
        "\x1b_Ga=T,f=24,t=f,s=1,v=1,c=1,r=1,q=2;{s}\x1b\\",
        .{encoded},
    );
    defer testing.allocator.free(sequence);

    var normalizer: Normalizer = .{};
    defer normalizer.deinit(testing.allocator);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const split = sequence.len / 2;
    const first = try normalizer.feed(testing.io, testing.allocator, temp_dir, sequence[0..split], &out);
    try testing.expect(!first.graphics);
    try testing.expectEqual(@as(usize, 0), out.items.len);
    const second = try normalizer.feed(testing.io, testing.allocator, temp_dir, sequence[split..], &out);
    try testing.expect(second.graphics);
    try testing.expect(!second.dropped);
    try testing.expect(std.mem.startsWith(u8, out.items, "\x1b_Ga=T,t=d,f=24,s=1,v=1,c=1,r=1"));
    try testing.expect(std.mem.indexOf(u8, out.items, "t=f") == null);
    try tmp_dir.dir.access(testing.io, "pixel.rgb", .{});
}

test "normalizer consumes Kitty temporary-file transport" {
    const testing = std.testing;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const name = "tty-graphics-protocol-pixel.rgb";
    try tmp_dir.dir.writeFile(testing.io, .{ .sub_path = name, .data = &.{ 4, 5, 6 } });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = path_buf[0..try tmp_dir.dir.realPathFile(testing.io, name, &path_buf)];
    var temp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const temp_dir = temp_buf[0..try tmp_dir.dir.realPath(testing.io, &temp_buf)];
    const encoded_len = std.base64.standard.Encoder.calcSize(path.len);
    const encoded = try testing.allocator.alloc(u8, encoded_len);
    defer testing.allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, path);
    const sequence = try std.fmt.allocPrint(
        testing.allocator,
        "\x1b_Ga=t,f=24,t=t,s=1,v=1,i=12,q=2;{s}\x1b\\",
        .{encoded},
    );
    defer testing.allocator.free(sequence);
    var normalizer: Normalizer = .{};
    defer normalizer.deinit(testing.allocator);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const result = try normalizer.feed(testing.io, testing.allocator, temp_dir, sequence, &out);
    try testing.expect(result.graphics);
    try testing.expect(!result.dropped);
    try testing.expect(std.mem.startsWith(u8, out.items, "\x1b_Ga=t,t=d,f=24,s=1,v=1,i=12"));
    try testing.expectError(error.FileNotFound, tmp_dir.dir.access(testing.io, name, .{}));
}

test "normalizer fails unsupported Kitty animation closed" {
    const testing = std.testing;
    var normalizer: Normalizer = .{};
    defer normalizer.deinit(testing.allocator);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const result = try normalizer.feed(testing.io, testing.allocator, "/tmp", "\x1b_Ga=a,s=3,i=1;\x1b\\", &out);
    try testing.expect(result.graphics);
    try testing.expect(result.dropped);
    try testing.expectEqualStrings(delete_all_images, out.items);
}
