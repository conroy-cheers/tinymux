//! PTY allocation and child process spawning.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const os = @import("posix_compat.zig");

extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname_r(fd: c_int, buf: [*]u8, len: usize) c_int;
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;

pub const Tio = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos => struct {
        pub const IOCGWINSZ: c_ulong = 0x40087468;
        pub const IOCSWINSZ: c_ulong = 0x80087467;
        pub const IOCSCTTY: c_ulong = 0x20007461;
    },
    else => struct {
        pub const IOCGWINSZ: c_ulong = std.c.T.IOCGWINSZ;
        pub const IOCSWINSZ: c_ulong = std.c.T.IOCSWINSZ;
        pub const IOCSCTTY: c_ulong = std.c.T.IOCSCTTY;
    },
};

pub const Winsize = std.posix.winsize;

pub fn makeWinsize(rows: u16, cols: u16) Winsize {
    return .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
}

pub const Pty = struct {
    master: posix.fd_t,
    slave: posix.fd_t,

    pub fn open(size: Winsize) !Pty {
        const flags: u32 = @bitCast(posix.O{
            .ACCMODE = .RDWR,
            .NOCTTY = true,
        });
        const master = posix_openpt(@bitCast(flags));
        if (master < 0) return error.OpenPtyFailed;
        errdefer os.close(master);

        if (grantpt(master) != 0) return error.OpenPtyFailed;
        if (unlockpt(master) != 0) return error.OpenPtyFailed;

        var path_buf: [128]u8 = undefined;
        if (ptsname_r(master, &path_buf, path_buf.len) != 0) {
            return error.OpenPtyFailed;
        }
        const path_len = std.mem.indexOfScalar(u8, &path_buf, 0) orelse {
            return error.OpenPtyFailed;
        };
        const slave_path = path_buf[0..path_len :0];

        const slave = std.c.open(slave_path, @bitCast(flags), @as(std.c.mode_t, 0));
        if (slave < 0) return error.OpenPtyFailed;
        errdefer os.close(slave);

        if (ioctl(slave, Tio.IOCSWINSZ, @intFromPtr(&size)) != 0) {
            return error.IoctlFailed;
        }

        return .{ .master = master, .slave = slave };
    }

    pub fn setSize(fd: posix.fd_t, size: Winsize) !void {
        if (ioctl(fd, Tio.IOCSWINSZ, @intFromPtr(&size)) != 0) {
            return error.IoctlFailed;
        }
    }
};

pub fn getSize(fd: posix.fd_t) !Winsize {
    var ws: Winsize = undefined;
    if (ioctl(fd, Tio.IOCGWINSZ, @intFromPtr(&ws)) != 0) {
        return error.IoctlFailed;
    }
    if (ws.row == 0) ws.row = 24;
    if (ws.col == 0) ws.col = 80;
    return ws;
}

pub const SpawnOptions = struct {
    argv: []const []const u8,
    env: *std.process.Environ.Map,
    size: Winsize,
    cwd: ?[]const u8 = null,
};

pub const Spawned = struct {
    pid: posix.pid_t,
    master: posix.fd_t,
};

pub fn spawnInPty(alloc: std.mem.Allocator, opts: SpawnOptions) !Spawned {
    if (opts.argv.len == 0) return error.EmptyArgv;

    const pty = try Pty.open(opts.size);
    errdefer os.close(pty.master);
    errdefer os.close(pty.slave);

    const argv = try alloc.allocSentinel(?[*:0]const u8, opts.argv.len, null);
    defer alloc.free(argv);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    for (opts.argv, 0..) |arg, i| {
        argv[i] = try arena.allocator().dupeZ(u8, arg);
    }
    const env_block = try opts.env.createPosixBlock(arena.allocator(), .{});
    const exec_paths = try executablePaths(arena.allocator(), opts.argv[0], opts.env);
    const cwd_z: ?[:0]const u8 = if (opts.cwd) |d|
        try arena.allocator().dupeZ(u8, d)
    else
        null;

    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        if (std.c.setsid() < 0) std.process.exit(127);
        if (ioctl(pty.slave, Tio.IOCSCTTY, @as(c_ulong, 0)) != 0) std.process.exit(127);

        if (std.c.dup2(pty.slave, 0) < 0) std.process.exit(127);
        if (std.c.dup2(pty.slave, 1) < 0) std.process.exit(127);
        if (std.c.dup2(pty.slave, 2) < 0) std.process.exit(127);
        if (pty.slave > 2) os.close(pty.slave);
        os.close(pty.master);

        if (cwd_z) |d| if (std.c.chdir(d) != 0) std.process.exit(127);

        for (exec_paths) |path| {
            _ = std.c.execve(path.ptr, argv, env_block.slice.ptr);
        }
        std.process.exit(127);
    }

    os.close(pty.slave);
    return .{ .pid = pid, .master = pty.master };
}

fn executablePaths(
    alloc: std.mem.Allocator,
    file: []const u8,
    env: *std.process.Environ.Map,
) ![]const [:0]const u8 {
    if (std.mem.indexOfScalar(u8, file, '/') != null) {
        const paths = try alloc.alloc([:0]const u8, 1);
        paths[0] = try alloc.dupeZ(u8, file);
        return paths;
    }

    const path_value = env.get("PATH") orelse "/usr/bin:/bin";
    var paths: std.ArrayList([:0]const u8) = .empty;
    var entries = std.mem.splitScalar(u8, path_value, ':');
    while (entries.next()) |entry| {
        const candidate = if (entry.len == 0)
            file
        else
            try std.fs.path.join(alloc, &.{ entry, file });
        try paths.append(alloc, try alloc.dupeZ(u8, candidate));
    }
    return paths.items;
}
