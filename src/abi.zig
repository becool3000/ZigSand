const std = @import("std");

pub const chunk_size: u32 = 16;
pub const max_brush_radius: u32 = 64;
pub const default_seed: u32 = 0x51A7_DA7A;

pub const Material = enum(u8) {
    empty = 0,
    sand = 1,
    water = 2,
    stone = 3,
    steam = 4,
    cloud = 5,
};

pub const Intent = enum(u32) {
    stay = 0,
    down = 1,
    down_left = 2,
    down_right = 3,
    left = 4,
    right = 5,
    up = 6,
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
    up = 6,
};

pub const RenderView = enum(u32) {
    cells = 0,
    motion = 1,
    disturbance = 2,
    pressure = 3,
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

/// Canonical optional surface-energy layer. V1 intentionally uses only four
/// bits so propagation remains integer, bounded, and easy to hash.
pub const Disturbance = packed struct(u32) {
    energy: u4 = 0,
    reserved: u28 = 0,

    pub fn bits(self: Disturbance) u32 {
        return @bitCast(self);
    }
};

/// Canonical optional body-pressure layer. V0 uses one unsigned byte while the
/// remaining bits stay zero for future range or flag expansion.
pub const Pressure = packed struct(u32) {
    amount: u8 = 0,
    reserved: u24 = 0,

    pub fn bits(self: Pressure) u32 {
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
    uses_motion: u1 = 0,
    reserved: u14 = 0,

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

    pub fn makeWithState(material: Material, variant: u8, state: u8) Cell {
        return .{ .material = material, .variant = variant, .flags = state };
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
    view_mode: u32 = @intFromEnum(RenderView.cells),
    channel_flags: u32 = channel_motion | channel_disturbance | channel_pressure,
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
    disturbance_hash: u32 = 0,
    disturbed_cells: u32 = 0,
    pressure_hash: u32 = 0,
    pressurized_cells: u32 = 0,
    steam_count: u32 = 0,
    cloud_count: u32 = 0,
};

pub const channel_motion: u32 = 1 << 0;
pub const channel_disturbance: u32 = 1 << 1;
pub const channel_pressure: u32 = 1 << 2;

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

pub fn disturbanceBytes(width: u32, height: u32) u64 {
    return @as(u64, padded(width)) * padded(height) * @sizeOf(Disturbance);
}

pub fn pressureBytes(width: u32, height: u32) u64 {
    return @as(u64, padded(width)) * padded(height) * @sizeOf(Pressure);
}

test "GPU ABI is stable" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Cell));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(SimPush));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(RenderPush));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(TestResult));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Motion));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Disturbance));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Pressure));
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(MovementProposal));
    try std.testing.expectEqual(@as(u32, 1088), padded(1080));
    try std.testing.expect(coreBytes(1920, 1080) < 32 * 1024 * 1024);
    try std.testing.expectEqual(@as(u64, 1920 * 1088 * 4), motionBytes(1920, 1080));
    try std.testing.expectEqual(@as(u64, 1920 * 1088 * 4), disturbanceBytes(1920, 1080));
    try std.testing.expectEqual(@as(u64, 1920 * 1088 * 4), pressureBytes(1920, 1080));
}

test "cell packing" {
    const cell = Cell{ .material = .water, .variant = 0x5a, .flags = 0xa5 };
    try std.testing.expectEqual(@as(u32, 0x00a55a02), cell.bits());
}

test "atmosphere material IDs and packed state are stable" {
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(Material.steam));
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(Material.cloud));
    try std.testing.expectEqual(@as(u32, 0x00c85a05), (Cell.makeWithState(.cloud, 0x5a, 200)).bits());
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

test "intent and motion direction encodings are stable" {
    try std.testing.expectEqual(@as(u32, 6), @intFromEnum(Intent.up));
    try std.testing.expectEqual(@as(u3, 6), @intFromEnum(MotionDirection.up));
}

test "render-view encodings are stable" {
    try std.testing.expectEqual(@as(u32, 3), @intFromEnum(RenderView.pressure));
    const push = RenderPush{
        .width = 0,
        .height = 0,
        .padded_width = 0,
        .viewport_width = 0,
        .viewport_height = 0,
        .seed = 0,
    };
    try std.testing.expectEqual(channel_motion | channel_disturbance | channel_pressure, push.channel_flags);
}

test "disturbance packing" {
    try std.testing.expectEqual(@as(u32, 15), (Disturbance{ .energy = 15 }).bits());
}

test "pressure packing" {
    try std.testing.expectEqual(@as(u32, 255), (Pressure{ .amount = 255 }).bits());
}
