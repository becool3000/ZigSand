const std = @import("std");
const cli = @import("cli.zig");
const app = @import("app.zig");

pub fn main(init: std.process.Init) !void {
    var iterator = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer iterator.deinit();
    var storage: [32][]const u8 = undefined;
    var count: usize = 0;
    while (iterator.next()) |arg| {
        if (count == storage.len) return error.TooManyArguments;
        storage[count] = arg;
        count += 1;
    }
    const options = cli.Options.parse(storage[0..count]) catch |err| {
        std.log.err("invalid command line: {s}", .{@errorName(err)});
        printUsage();
        return err;
    };
    try app.run(init.gpa, options);
}

fn printUsage() void {
    std.debug.print(
        \\Usage: zigsand [--width N] [--height N] [--tps N] [--seed N]
        \\               [--validation] [--uncapped] [--benchmark seconds] [--gpu-tests]
        \\
    , .{});
}

test {
    _ = @import("abi.zig");
    _ = @import("cli.zig");
    _ = @import("coordinates.zig");
    _ = @import("material.zig");
    _ = @import("shader_manifest.zig");
    _ = @import("suballocator.zig");
}
