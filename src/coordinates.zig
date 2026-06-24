const std = @import("std");

pub const CellCoordinate = struct { x: u32, y: u32 };

/// Maps top-left-origin window pixels through the renderer's letterbox into
/// bottom-left-origin simulation coordinates.
pub fn windowToCell(
    mouse_x: i32,
    mouse_y: i32,
    viewport_width: u32,
    viewport_height: u32,
    world_width: u32,
    world_height: u32,
    camera_center_x: f32,
    camera_center_y: f32,
    zoom: f32,
) ?CellCoordinate {
    if (viewport_width == 0 or viewport_height == 0) return null;
    const view_w = @as(f64, @floatFromInt(viewport_width));
    const view_h = @as(f64, @floatFromInt(viewport_height));
    const z = @max(@as(f64, @floatCast(zoom)), 1.0);
    const camera_w = @as(f64, @floatFromInt(world_width)) / z;
    const camera_h = @as(f64, @floatFromInt(world_height)) / z;
    const scale = @min(view_w / camera_w, view_h / camera_h);
    const draw_w = camera_w * scale;
    const draw_h = camera_h * scale;
    const local_x = @as(f64, @floatFromInt(mouse_x)) - (view_w - draw_w) * 0.5;
    const local_y = @as(f64, @floatFromInt(mouse_y)) - (view_h - draw_h) * 0.5;
    if (local_x < 0 or local_y < 0 or local_x >= draw_w or local_y >= draw_h) return null;
    const min_x = @as(f64, @floatCast(camera_center_x)) - camera_w * 0.5;
    const min_y = @as(f64, @floatCast(camera_center_y)) - camera_h * 0.5;
    const world_x = min_x + local_x / scale;
    const world_y = min_y + camera_h - local_y / scale - 0.0001;
    if (world_x < 0 or world_y < 0 or world_x >= @as(f64, @floatFromInt(world_width)) or world_y >= @as(f64, @floatFromInt(world_height)))
        return null;
    return .{ .x = @intFromFloat(world_x), .y = @intFromFloat(world_y) };
}

test "coordinate mapping respects aspect letterboxing and Y flip" {
    try std.testing.expectEqual(CellCoordinate{ .x = 0, .y = 1079 }, windowToCell(0, 0, 1920, 1080, 1920, 1080, 960, 540, 1).?);
    try std.testing.expectEqual(CellCoordinate{ .x = 960, .y = 539 }, windowToCell(640, 360, 1280, 720, 1920, 1080, 960, 540, 1).?);
    try std.testing.expect(windowToCell(0, 0, 1000, 1000, 1920, 1080, 960, 540, 1) == null);
}
