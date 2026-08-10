const std = @import("std");
const vt = @import("ghostty-vt");
const wuffs = @import("wuffs");

const max_control_string_bytes: usize = 128 * 1024 * 1024;
const max_image_bytes: usize = 320 * 1024 * 1024;
const kitty_chunk_bytes: usize = 3000;
const delete_all_images = "\x1b_Ga=d,d=A,q=2;\x1b\\";

pub const FeedResult = struct {
    graphics: bool = false,
    dropped: bool = false,

    fn merge(self: *FeedResult, other: FeedResult) void {
        self.graphics = self.graphics or other.graphics;
        self.dropped = self.dropped or other.dropped;
    }
};

/// Normalizes every image protocol Tinymux advertises into direct Kitty RGBA.
/// Ordinary terminal bytes and non-image control strings are preserved exactly.
/// A graphics sequence that cannot be represented is replaced with a Kitty
/// delete-all command, so it can never create an untracked outer-terminal layer.
pub const Normalizer = struct {
    state: State = .ground,
    utf8_continuations: u3 = 0,
    pending: std.ArrayList(u8) = .empty,
    overflowed: bool = false,
    multipart: Multipart = .{},

    const State = enum {
        ground,
        escape,
        apc,
        apc_escape,
        dcs,
        dcs_escape,
        osc,
        osc_escape,
    };

    const Multipart = struct {
        metadata: std.ArrayList(u8) = .empty,
        encoded: std.ArrayList(u8) = .empty,
        active: bool = false,

        fn reset(self: *Multipart) void {
            self.metadata.clearRetainingCapacity();
            self.encoded.clearRetainingCapacity();
            self.active = false;
        }

        fn deinit(self: *Multipart, alloc: std.mem.Allocator) void {
            self.metadata.deinit(alloc);
            self.encoded.deinit(alloc);
        }
    };

    pub fn deinit(self: *Normalizer, alloc: std.mem.Allocator) void {
        self.pending.deinit(alloc);
        self.multipart.deinit(alloc);
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
                    try self.appendPending(alloc, byte);
                    if (byte == 0x9c or (self.state == .osc and byte == 0x07)) {
                        result.merge(try self.complete(io, alloc, temp_dir, out));
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
                    try self.appendPending(alloc, byte);
                    if (byte == '\\') {
                        result.merge(try self.complete(io, alloc, temp_dir, out));
                    } else if (byte != 0x1b) {
                        self.state = switch (self.state) {
                            .apc_escape => .apc,
                            .dcs_escape => .dcs,
                            .osc_escape => .osc,
                            else => unreachable,
                        };
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
        if (self.state == .ground) return .{};
        const graphics = self.pendingLooksLikeGraphics();
        if (graphics) {
            try out.appendSlice(alloc, delete_all_images);
        } else if (!self.overflowed) {
            try out.appendSlice(alloc, self.pending.items);
        }
        self.resetSequence();
        return .{ .graphics = graphics, .dropped = graphics };
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
            else => unreachable,
        };
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
        self.state = .ground;
    }

    fn complete(
        self: *Normalizer,
        io: std.Io,
        alloc: std.mem.Allocator,
        temp_dir: []const u8,
        out: *std.ArrayList(u8),
    ) !FeedResult {
        defer self.resetSequence();
        if (self.overflowed) {
            try out.appendSlice(alloc, delete_all_images);
            return .{ .graphics = true, .dropped = true };
        }

        const body = self.sequenceBody() orelse {
            try out.appendSlice(alloc, self.pending.items);
            return .{};
        };
        return switch (baseState(self.state)) {
            .apc => if (std.mem.startsWith(u8, body, "G"))
                try normalizeKitty(io, alloc, temp_dir, body[1..], self.pending.items, out)
            else preserve: {
                try out.appendSlice(alloc, self.pending.items);
                break :preserve .{};
            },
            .dcs => if (sixelPayload(body)) |payload|
                try normalizeSixel(alloc, payload, out)
            else preserve: {
                try out.appendSlice(alloc, self.pending.items);
                break :preserve .{};
            },
            .osc => if (std.mem.startsWith(u8, body, "1337;"))
                try self.normalizeIterm(alloc, body[5..], out)
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
        command: []const u8,
        out: *std.ArrayList(u8),
    ) !FeedResult {
        if (std.mem.startsWith(u8, command, "File=")) {
            const value = command[5..];
            const colon = std.mem.indexOfScalar(u8, value, ':') orelse return dropGraphics(alloc, out);
            return normalizeItermImage(alloc, value[0..colon], value[colon + 1 ..], out);
        }
        if (std.mem.startsWith(u8, command, "MultipartFile=")) {
            self.multipart.reset();
            self.multipart.active = true;
            try self.multipart.metadata.appendSlice(alloc, command[14..]);
            return .{ .graphics = true };
        }
        if (std.mem.startsWith(u8, command, "FilePart=")) {
            if (!self.multipart.active) return dropGraphics(alloc, out);
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
            return normalizeItermImage(
                alloc,
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
    return byte == 0x1b or byte == 0x90 or byte == 0x9d or byte == 0x9f;
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
    return .{ .graphics = true, .dropped = true };
}

fn normalizeKitty(
    io: std.Io,
    alloc: std.mem.Allocator,
    temp_dir: []const u8,
    body: []const u8,
    original: []const u8,
    out: *std.ArrayList(u8),
) !FeedResult {
    var cmd = vt.kitty.graphics.CommandParser.parseString(alloc, body) catch
        return dropGraphics(alloc, out);
    defer cmd.deinit(alloc);

    switch (cmd.control) {
        .transmit_animation_frame, .control_animation, .compose_animation => return dropGraphics(alloc, out),
        else => {},
    }
    if (cmd.display()) |display| {
        if (display.virtual_placement or display.parent_id != 0 or
            display.parent_placement_id != 0 or display.horizontal_offset != 0 or
            display.vertical_offset != 0)
        {
            return dropGraphics(alloc, out);
        }
    }

    const transmission = cmd.transmission() orelse {
        try out.appendSlice(alloc, original);
        return .{ .graphics = true };
    };
    if (transmission.medium == .direct) {
        try out.appendSlice(alloc, original);
        return .{ .graphics = true };
    }

    var loading = vt.kitty.graphics.LoadingImage.init(
        io,
        alloc,
        &cmd,
        .allWithTempDir(temp_dir),
    ) catch return dropGraphics(alloc, out);
    defer loading.deinit(alloc);
    var image = loading.complete(alloc) catch return dropGraphics(alloc, out);
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
    return .{ .graphics = true };
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

fn normalizeSixel(alloc: std.mem.Allocator, payload: []const u8, out: *std.ArrayList(u8)) !FeedResult {
    var image = decodeSixel(alloc, payload) catch return dropGraphics(alloc, out);
    defer image.deinit(alloc);
    try emitRgba(alloc, out, image, .{});
    return .{ .graphics = true };
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
    metadata: []const u8,
    encoded: []const u8,
    out: *std.ArrayList(u8),
) !FeedResult {
    var display: DisplayOptions = .{};
    var inline_image = false;
    var fields = std.mem.splitScalar(u8, metadata, ';');
    while (fields.next()) |field| {
        const equals = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        const key = field[0..equals];
        const value = field[equals + 1 ..];
        if (std.mem.eql(u8, key, "inline")) inline_image = std.mem.eql(u8, value, "1");
        if (std.mem.eql(u8, key, "width")) display.columns = parseCellDimension(value);
        if (std.mem.eql(u8, key, "height")) display.rows = parseCellDimension(value);
        if (std.mem.eql(u8, key, "doNotMoveCursor")) display.cursor_none = std.mem.eql(u8, value, "1");
    }
    if (!inline_image) return dropGraphics(alloc, out);

    const Decoder = std.base64.standard.Decoder;
    const decoded_len = Decoder.calcSizeForSlice(encoded) catch return dropGraphics(alloc, out);
    if (decoded_len == 0 or decoded_len > max_image_bytes) return dropGraphics(alloc, out);
    const encoded_image = try alloc.alloc(u8, decoded_len);
    defer alloc.free(encoded_image);
    Decoder.decode(encoded_image, encoded) catch return dropGraphics(alloc, out);

    var image = decodeRasterImage(alloc, encoded_image) catch return dropGraphics(alloc, out);
    defer image.deinit(alloc);
    try emitRgba(alloc, out, image, display);
    return .{ .graphics = true };
}

fn parseCellDimension(value: []const u8) u32 {
    if (value.len == 0 or std.mem.eql(u8, value, "auto")) return 0;
    for (value) |byte| if (byte < '0' or byte > '9') return 0;
    return std.fmt.parseInt(u32, value, 10) catch 0;
}

fn decodeRasterImage(alloc: std.mem.Allocator, data: []const u8) !DecodedImage {
    const decoded = if (std.mem.startsWith(u8, data, "\x89PNG\r\n\x1a\n"))
        try wuffs.png.decode(alloc, data)
    else if (std.mem.startsWith(u8, data, "\xff\xd8\xff"))
        try wuffs.jpeg.decode(alloc, data)
    else
        return error.UnsupportedImageFormat;
    return .{ .width = decoded.width, .height = decoded.height, .data = decoded.data };
}

const SixelExtent = struct {
    width: u32 = 0,
    height: u32 = 0,
    declared_width: u32 = 0,
    declared_height: u32 = 0,
};

const Rgba = [4]u8;

fn decodeSixel(alloc: std.mem.Allocator, data: []const u8) !DecodedImage {
    var extent: SixelExtent = .{};
    try walkSixel(data, &extent, null, 0, 0);
    const width = @max(extent.width, extent.declared_width);
    const height = @max(extent.height, extent.declared_height);
    if (width == 0 or height == 0 or width > 10000 or height > 10000) return error.InvalidSixel;
    const pixel_count = try std.math.mul(usize, @as(usize, width), @as(usize, height));
    const byte_count = try std.math.mul(usize, pixel_count, 4);
    if (byte_count > max_image_bytes) return error.ImageTooLarge;
    const pixels = try alloc.alloc(u8, byte_count);
    @memset(pixels, 0);
    errdefer alloc.free(pixels);
    try walkSixel(data, null, pixels, width, height);
    return .{ .width = width, .height = height, .data = pixels };
}

fn walkSixel(
    data: []const u8,
    extent: ?*SixelExtent,
    pixels: ?[]u8,
    width: u32,
    height: u32,
) !void {
    var palette: [256]Rgba = undefined;
    initSixelPalette(&palette);
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
    try testing.expect(std.mem.endsWith(u8, out.items, "\x1b\\"));
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
    try testing.expect(std.mem.startsWith(u8, out.items, "\x1b_Ga=T,t=d,f=32,s=1,v=1,c=2,r=3"));
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
