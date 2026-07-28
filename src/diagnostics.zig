const std = @import("std");

var mutex: std.Thread.Mutex = .{};
var file: ?std.fs.File = null;

pub fn initFromEnv() !void {
    const path = std.posix.getenv("TINYMUX_LOG") orelse return;
    if (path.len == 0) return;

    var opened = try std.fs.cwd().createFile(path, .{
        .read = false,
        .truncate = false,
        .mode = 0o600,
    });
    errdefer opened.close();
    try opened.seekFromEnd(0);
    file = opened;
}

pub fn deinit() void {
    mutex.lock();
    defer mutex.unlock();
    if (file) |opened| opened.close();
    file = null;
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    mutex.lock();
    defer mutex.unlock();

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
    opened.writeAll(writer.buffered()) catch {};
}
