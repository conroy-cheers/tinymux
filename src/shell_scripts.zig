const std = @import("std");

pub const InitShell = enum {
    fish,
    sh,
    bash,
    zsh,
    nu,
};

pub const DirenvShell = enum {
    bash,
    zsh,
    fish,
    nu,
};

pub const DirenvChildInit = struct {
    prefix: ?[]const u8 = null,
    hook: []const u8,
    guard: []const u8,
};

pub fn parseInitShell(name: []const u8) ?InitShell {
    if (std.mem.eql(u8, name, "fish")) return .fish;
    if (std.mem.eql(u8, name, "sh")) return .sh;
    if (std.mem.eql(u8, name, "bash")) return .bash;
    if (std.mem.eql(u8, name, "zsh")) return .zsh;
    if (std.mem.eql(u8, name, "nu") or std.mem.eql(u8, name, "nushell")) return .nu;
    return null;
}

pub fn parseDirenvShell(name: []const u8) ?DirenvShell {
    if (std.mem.eql(u8, name, "bash")) return .bash;
    if (std.mem.eql(u8, name, "zsh")) return .zsh;
    if (std.mem.eql(u8, name, "fish")) return .fish;
    if (std.mem.eql(u8, name, "nu") or std.mem.eql(u8, name, "nushell")) return .nu;
    return null;
}

pub fn initScript(shell: InitShell) []const u8 {
    return switch (shell) {
        .fish => @embedFile("scripts/init/fish.fish"),
        .sh => @embedFile("scripts/init/sh.sh"),
        .bash => @embedFile("scripts/init/bash.sh"),
        .zsh => @embedFile("scripts/init/zsh.zsh"),
        .nu => @embedFile("scripts/init/nushell.nu"),
    };
}

pub fn direnvHook(shell: DirenvShell) []const u8 {
    return switch (shell) {
        .bash => @embedFile("scripts/direnv/bash-hook.sh"),
        .zsh => @embedFile("scripts/direnv/zsh-hook.zsh"),
        .fish => @embedFile("scripts/direnv/fish-hook.fish"),
        .nu => @embedFile("scripts/direnv/nushell-hook.nu"),
    };
}

pub fn direnvChildInit(shell: DirenvShell) DirenvChildInit {
    return switch (shell) {
        .bash => .{
            .prefix = @embedFile("scripts/direnv/bash-child-prefix.sh"),
            .hook = @embedFile("scripts/direnv/bash-hook.sh"),
            .guard = @embedFile("scripts/direnv/bash-child-guard.sh"),
        },
        .zsh => .{
            .prefix = @embedFile("scripts/direnv/zsh-child-prefix.zsh"),
            .hook = @embedFile("scripts/direnv/zsh-hook.zsh"),
            .guard = @embedFile("scripts/direnv/zsh-child-guard.zsh"),
        },
        .fish => .{
            .prefix = @embedFile("scripts/direnv/fish-child-prefix.fish"),
            .hook = @embedFile("scripts/direnv/fish-hook.fish"),
            .guard = @embedFile("scripts/direnv/fish-child-guard.fish"),
        },
        .nu => .{
            .hook = @embedFile("scripts/direnv/nushell-hook.nu"),
            .guard = @embedFile("scripts/direnv/nushell-child-guard.nu"),
        },
    };
}
