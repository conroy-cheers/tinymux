const std = @import("std");
const posix = std.posix;
const os = @import("posix_compat.zig");

pub fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = try os.write(fd, bytes[written..]);
        if (n == 0) return error.WriteFailed;
        written += n;
    }
}
