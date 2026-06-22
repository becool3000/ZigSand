const std = @import("std");

pub const Shader = struct {
    name: []const u8,
    source: []const u8,
    entry: []const u8,
    profile: []const u8,
};

pub const shaders = [_]Shader{
    .{ .name = "init_spv", .source = "shaders/sim.hlsl", .entry = "InitMain", .profile = "cs_6_6" },
    .{ .name = "activity_spv", .source = "shaders/sim.hlsl", .entry = "InitActivityMain", .profile = "cs_6_6" },
    .{ .name = "paint_spv", .source = "shaders/sim.hlsl", .entry = "PaintMain", .profile = "cs_6_6" },
    .{ .name = "intent_spv", .source = "shaders/sim.hlsl", .entry = "IntentMain", .profile = "cs_6_6" },
    .{ .name = "resolve_spv", .source = "shaders/sim.hlsl", .entry = "ResolveMain", .profile = "cs_6_6" },
    .{ .name = "commit_spv", .source = "shaders/sim.hlsl", .entry = "CommitMain", .profile = "cs_6_6" },
    .{ .name = "validate_spv", .source = "shaders/sim.hlsl", .entry = "ValidateMain", .profile = "cs_6_6" },
    .{ .name = "vertex_spv", .source = "shaders/render.hlsl", .entry = "VertexMain", .profile = "vs_6_0" },
    .{ .name = "fragment_spv", .source = "shaders/render.hlsl", .entry = "FragmentMain", .profile = "ps_6_0" },
};

test "shader manifest is complete and unique" {
    try std.testing.expect(shaders.len == 9);
    for (shaders, 0..) |shader, index| {
        try std.testing.expect(shader.name.len != 0 and shader.entry.len != 0 and shader.source.len != 0);
        for (shaders[index + 1 ..]) |other| try std.testing.expect(!std.mem.eql(u8, shader.name, other.name));
    }
    try std.testing.expect(@embedFile("init_spv").len != 0);
    try std.testing.expect(@embedFile("fragment_spv").len != 0);
}
