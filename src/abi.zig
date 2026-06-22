const std = @import("std");

pub const chunk_size: u32 = 16;
pub const max_brush_radius: u32 = 64;
pub const default_seed: u32 = 0x51A7_DA7A;

pub const Material = enum(u8) {
    empty = 0,
    sand = 1,
    water = 2,
    stone = 3,
};

pub const Intent = enum(u32) {
    stay = 0,
    down = 1,
    down_left = 2,
    down_right = 3,
    left = 4,
    right = 5,
};

/// Motion uses the same direction numbering as Intent so the low proposal bits
/// remain backward-compatible with the existing movement pipeline.
pub const MotionDirection = enum(u3) {
    none = 0,
    down = 1,
    down_left = 2,
    down_right = 3,
    left = 4,
    right = 5,
};

/// Canonical optional per-cell movement tendency. Only the low seven bits are
/// currently meaningful; the rest remain zero for future channel evolution.
pub const Motion = packed struct(u32) {
    direction: MotionDirection = .none,
    strength: u4 = 0,
    reserved: u25 = 0,

    pub fn bits(self: Motion) u32 {
        return @bitCast(self);
    }
};

/// Movement proposals carry deterministic channel outcomes for both acceptance
/// and rejection, allowing ResolveMain to commit Motion without reading a
/// channel another workgroup may already have updated.
pub const MovementProposal = packed struct(u32) {
    direction: MotionDirection = .none,
    accepted_motion: u7 = 0,
    rejected_motion: u7 = 0,
    reserved: u15 = 0,

    pub fn bits(self: MovementProposal) u32 {
        return @bitCast(self);
    }
};

pub const Cell = packed struct(u32) {
    material: Material,
    variant: u8 = 0,
    flags: u8 = 0,
    reserved: u8 = 0,

    pub fn make(material: Material, variant: u8) Cell {
        return .{ .material = material, .variant = variant };
    }

    pub fn bits(self: Cell) u32 {
        return @bitCast(self);
    }
};

/// This layout is mirrored exactly by SimPush in shaders/sim.hlsl. Keep every
/// field 32-bit so HLSL and Zig have identical packing on every driver.
pub const SimPush = extern struct {
    width: u32,
    height: u32,
    padded_width: u32,
    padded_height: u32,
    chunks_x: u32,
    chunks_y: u32,
    tick: u32,
    seed: u32,
    brush_x: u32 = 0,
    brush_y: u32 = 0,
    brush_radius: u32 = 0,
    brush_material: u32 = 0,
    command_flags: u32 = 0,
    test_case: u32 = 0,
    channel_flags: u32 = 0,
    reserved1: u32 = 0,
};

pub const RenderPush = extern struct {
    width: u32,
    height: u32,
    padded_width: u32,
    viewport_width: u32,
    viewport_height: u32,
    seed: u32,
    reserved0: u32 = 0,
    reserved1: u32 = 0,
};

pub const TestResult = extern struct {
    failures: u32 = 0,
    sand_count: u32 = 0,
    water_count: u32 = 0,
    stone_count: u32 = 0,
    state_hash: u32 = 0,
    active_count: u32 = 0,
    cell_hash: u32 = 0,
    motion_hash: u32 = 0,
};

pub const channel_motion: u32 = 1 << 0;

pub fn alignUp(value: u64, alignment: u64) u64 {
    std.debug.assert(alignment != 0 and std.math.isPowerOfTwo(alignment));
    return (value + alignment - 1) & ~(alignment - 1);
}

pub fn padded(value: u32) u32 {
    return @intCast(alignUp(value, chunk_size));
}

pub fn coreBytes(width: u32, height: u32) u64 {
    return @as(u64, padded(width)) * padded(height) * @sizeOf(u32) * 3;
}

pub fn motionBytes(width: u32, height: u32) u64 {
    return @as(u64, padded(width)) * padded(height) * @sizeOf(Motion);
}

test "GPU ABI is stable" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Cell));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(SimPush));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(RenderPush));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(TestResult));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Motion));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(MovementProposal));
    try std.testing.expectEqual(@as(u32, 1088), padded(1080));
    try std.testing.expect(coreBytes(1920, 1080) < 32 * 1024 * 1024);
    try std.testing.expectEqual(@as(u64, 1920 * 1088 * 4), motionBytes(1920, 1080));
}

test "cell packing" {
    const cell = Cell{ .material = .water, .variant = 0x5a, .flags = 0xa5 };
    try std.testing.expectEqual(@as(u32, 0x00a55a02), cell.bits());
}

test "alignment" {
    try std.testing.expectEqual(@as(u64, 256), alignUp(129, 256));
    try std.testing.expectEqual(@as(u64, 512), alignUp(512, 256));
}

test "motion and movement proposal packing" {
    const motion = Motion{ .direction = .right, .strength = 9 };
    try std.testing.expectEqual(@as(u32, 0x4d), motion.bits());
    const proposal = MovementProposal{
        .direction = .left,
        .accepted_motion = @truncate(motion.bits()),
        .rejected_motion = 0x12,
    };
    try std.testing.expectEqual(@as(u32, 0x0000_4a6c), proposal.bits());
}
