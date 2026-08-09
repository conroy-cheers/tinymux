const std = @import("std");

pub const InitShell = enum {
    fish,
    sh,
    bash,
    zsh,
    nu,
};

pub fn parseInitShell(name: []const u8) ?InitShell {
    if (std.mem.eql(u8, name, "fish")) return .fish;
    if (std.mem.eql(u8, name, "sh")) return .sh;
    if (std.mem.eql(u8, name, "bash")) return .bash;
    if (std.mem.eql(u8, name, "zsh")) return .zsh;
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
