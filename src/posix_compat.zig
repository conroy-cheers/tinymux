const std = @import("std");

pub fn close(fd: std.posix.fd_t) void {
    _ = std.c.close(fd);
}

pub fn read(fd: std.posix.fd_t, buffer: []u8) !usize {
    if (buffer.len == 0) return 0;
    while (true) {
        const result = std.c.read(fd, buffer.ptr, @min(buffer.len, 0x7ffff000));
        switch (std.c.errno(result)) {
            .SUCCESS => return @intCast(result),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .BADF => return error.NotOpenForReading,
            .IO => return error.InputOutput,
            .ISDIR => return error.IsDir,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .NOTCONN => return error.SocketNotConnected,
            .CONNRESET => return error.ConnectionResetByPeer,
            .TIMEDOUT => return error.ConnectionTimedOut,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}

pub fn write(fd: std.posix.fd_t, bytes: []const u8) !usize {
    if (bytes.len == 0) return 0;
    while (true) {
        const result = std.c.write(fd, bytes.ptr, @min(bytes.len, 0x7ffff000));
        switch (std.c.errno(result)) {
            .SUCCESS => return @intCast(result),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .BADF => return error.NotOpenForWriting,
            .IO => return error.InputOutput,
            .NOBUFS, .NOMEM => return error.SystemResources,
            .ACCES => return error.AccessDenied,
            .PERM => return error.PermissionDenied,
            .PIPE => return error.BrokenPipe,
            .CONNRESET => return error.ConnectionResetByPeer,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}
