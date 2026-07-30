const std = @import("std");
const os = @import("posix_compat.zig");

const max_bytes: usize = 64 * 1024 * 1024;
const magic = "TMXVT1\n";

var file: ?std.posix.fd_t = null;
var written: usize = 0;

pub fn initFromEnv() !void {
    const path = getenv("TINYMUX_VT_TRACE") orelse return;
    if (path.len == 0) return;

    const opened = try std.posix.openat(std.posix.AT.FDCWD, path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
    }, 0o600);
    errdefer os.close(opened);
    file = opened;
    writeBytes(magic);
}

pub fn deinit() void {
    if (file) |opened| os.close(opened);
    file = null;
    written = 0;
}

pub fn feed(pid: std.posix.pid_t, bytes: []const u8) void {
    record(1, pid, bytes);
}

pub fn resize(
    pid: std.posix.pid_t,
    rows: u16,
    cols: u16,
    cell_width: u32,
    cell_height: u32,
) void {
    var payload: [12]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], rows, .little);
    std.mem.writeInt(u16, payload[2..4], cols, .little);
    std.mem.writeInt(u32, payload[4..8], cell_width, .little);
    std.mem.writeInt(u32, payload[8..12], cell_height, .little);
    record(2, pid, &payload);
}

fn record(kind: u8, pid: std.posix.pid_t, payload: []const u8) void {
    if (file == null or payload.len > std.math.maxInt(u32)) return;
    const record_len = 1 + @sizeOf(i32) + @sizeOf(u32) + payload.len;
    if (written + record_len > max_bytes) return;

    var header: [9]u8 = undefined;
    header[0] = kind;
    const pid_bits: u32 = @bitCast(@as(i32, @intCast(pid)));
    std.mem.writeInt(u32, header[1..5], pid_bits, .little);
    std.mem.writeInt(u32, header[5..9], @intCast(payload.len), .little);
    writeBytes(&header);
    writeBytes(payload);
}

fn writeBytes(bytes: []const u8) void {
    const opened = file orelse return;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = os.write(opened, bytes[offset..]) catch {
            os.close(opened);
            file = null;
            return;
        };
        if (count == 0) return;
        offset += count;
        written += count;
    }
}

fn getenv(name: [*:0]const u8) ?[:0]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}
