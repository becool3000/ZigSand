const std = @import("std");
const abi = @import("abi.zig");

pub const Mode = enum { interactive, gpu_tests, benchmark };

pub const Options = struct {
    width: u32 = 1920,
    height: u32 = 1080,
    tps: u32 = 60,
    seed: u32 = abi.default_seed,
    validation: bool = false,
    uncapped: bool = false,
    mode: Mode = .interactive,
    benchmark_seconds: u32 = 10,

    pub fn parse(args: []const []const u8) !Options {
        var result = Options{};
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--validation")) {
                result.validation = true;
            } else if (std.mem.eql(u8, arg, "--uncapped")) {
                result.uncapped = true;
            } else if (std.mem.eql(u8, arg, "--gpu-tests")) {
                result.mode = .gpu_tests;
                result.width = 32;
                result.height = 32;
            } else if (std.mem.eql(u8, arg, "--width")) {
                i += 1;
                if (i >= args.len) return error.MissingOptionValue;
                result.width = try parseBounded(args[i], 16, 8192);
            } else if (std.mem.eql(u8, arg, "--height")) {
                i += 1;
                if (i >= args.len) return error.MissingOptionValue;
                result.height = try parseBounded(args[i], 16, 8192);
            } else if (std.mem.eql(u8, arg, "--tps")) {
                i += 1;
                if (i >= args.len) return error.MissingOptionValue;
                result.tps = try parseBounded(args[i], 1, 1000);
            } else if (std.mem.eql(u8, arg, "--seed")) {
                i += 1;
                if (i >= args.len) return error.MissingOptionValue;
                result.seed = try std.fmt.parseUnsigned(u32, args[i], 0);
            } else if (std.mem.eql(u8, arg, "--benchmark")) {
                i += 1;
                if (i >= args.len) return error.MissingOptionValue;
                result.mode = .benchmark;
                result.benchmark_seconds = try parseBounded(args[i], 1, 3600);
            } else {
                return error.UnknownOption;
            }
        }
        return result;
    }
};

fn parseBounded(text: []const u8, min: u32, max: u32) !u32 {
    const value = try std.fmt.parseUnsigned(u32, text, 10);
    if (value < min or value > max) return error.OptionOutOfRange;
    return value;
}

test "CLI defaults" {
    const args = [_][]const u8{"zigsand"};
    const options = try Options.parse(&args);
    try std.testing.expectEqual(@as(u32, 1920), options.width);
    try std.testing.expectEqual(@as(u32, 60), options.tps);
    try std.testing.expectEqual(Mode.interactive, options.mode);
}

test "CLI custom benchmark" {
    const args = [_][]const u8{ "zigsand", "--width", "640", "--height", "480", "--benchmark", "4", "--validation" };
    const options = try Options.parse(&args);
    try std.testing.expectEqual(@as(u32, 640), options.width);
    try std.testing.expectEqual(@as(u32, 480), options.height);
    try std.testing.expectEqual(@as(u32, 4), options.benchmark_seconds);
    try std.testing.expect(options.validation);
}

test "CLI uncapped simulation" {
    const args = [_][]const u8{ "zigsand", "--uncapped" };
    const options = try Options.parse(&args);
    try std.testing.expect(options.uncapped);
}
