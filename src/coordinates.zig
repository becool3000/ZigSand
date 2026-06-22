const std = @import("std");

pub const CellCoordinate = struct { x: u32, y: u32 };

/// Maps top-left-origin window pixels through the renderer's letterbox into
/// bottom-left-origin simulation coordinates.
pub fn windowToCell(mouse_x: i32, mouse_y: i32, viewport_width: u32, viewport_height: u32, world_width: u32, world_height: u32) ?CellCoordinate {
    if (viewport_width == 0 or viewport_height == 0) return null;
    const view_w = @as(f64, @floatFromInt(viewport_width));
    const view_h = @as(f64, @floatFromInt(viewport_height));
    const scale = @min(view_w / @as(f64, @floatFromInt(world_width)), view_h / @as(f64, @floatFromInt(world_height)));
    const draw_w = @as(f64, @floatFromInt(world_width)) * scale;
    const draw_h = @as(f64, @floatFromInt(world_height)) * scale;
    const local_x = @as(f64, @floatFromInt(mouse_x)) - (view_w - draw_w) * 0.5;
    const local_y = @as(f64, @floatFromInt(mouse_y)) - (view_h - draw_h) * 0.5;
    if (local_x < 0 or local_y < 0 or local_x >= draw_w or local_y >= draw_h) return null;
    const x: u32 = @intFromFloat(local_x / scale);
    const top_y: u32 = @intFromFloat(local_y / scale);
    return .{ .x = x, .y = world_height - 1 - top_y };
}

test "coordinate mapping respects aspect letterboxing and Y flip" {
    try std.testing.expectEqual(CellCoordinate{ .x = 0, .y = 1079 }, windowToCell(0, 0, 1920, 1080, 1920, 1080).?);
    try std.testing.expectEqual(CellCoordinate{ .x = 960, .y = 539 }, windowToCell(640, 360, 1280, 720, 1920, 1080).?);
    try std.testing.expect(windowToCell(0, 0, 1000, 1000, 1920, 1080) == null);
}
