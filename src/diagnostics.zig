const std = @import("std");
const os = @import("posix_compat.zig");

var file: ?std.posix.fd_t = null;

pub fn initFromEnv() !void {
    const path = getenv("TINYMUX_LOG") orelse return;
    if (path.len == 0) return;

    const opened = try std.posix.openat(std.posix.AT.FDCWD, path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
    }, 0o600);
    errdefer os.close(opened);
    file = opened;
}

pub fn deinit() void {
    if (file) |opened| os.close(opened);
    file = null;
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const opened = file orelse return;
    var storage: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&storage);
    const scope_suffix = if (scope == .default)
        ": "
    else
        "(" ++ @tagName(scope) ++ "): ";
    writer.print(level.asText() ++ scope_suffix ++ format, args) catch {
        const marker = "...[truncated]";
        if (writer.end + marker.len <= storage.len) writer.writeAll(marker) catch {};
    };
    writer.writeByte('\n') catch {};
    writeAll(opened, writer.buffered());
}

fn getenv(name: [*:0]const u8) ?[:0]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = os.write(fd, bytes[offset..]) catch return;
        if (written == 0) return;
        offset += written;
    }
}
