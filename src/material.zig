const std = @import("std");
const abi = @import("abi.zig");

pub const max_materials: usize = 256;
pub const no_ignition_temperature: i32 = std.math.maxInt(i32);

pub const Phase = enum(u32) {
    none = 0,
    solid = 1,
    liquid = 2,
    gas = 3,
};

pub const Mobility = enum(u32) {
    none = 0,
    static = 1,
    powder = 2,
    fluid = 3,
    gas = 4,
};

pub const trait_phase_mask: u32 = 0x3;
pub const trait_mobility_shift: u5 = 2;
pub const trait_mobility_mask: u32 = 0x7 << trait_mobility_shift;
pub const trait_uses_motion: u32 = 1 << 5;
pub const trait_valid: u32 = 1 << 8;
pub const trait_conductive: u32 = 1 << 9;
pub const trait_blocks_pressure: u32 = 1 << 10;
pub const trait_compressible: u32 = 1 << 11;
pub const trait_friction_shift: u5 = 12;
pub const trait_motion_decay_shift: u5 = 16;
pub const trait_pressure_response_shift: u5 = 20;
pub const trait_disturbance_decay_shift: u5 = 24;
pub const trait_surface_response_shift: u5 = 28;
pub const trait_nibble_mask: u32 = 0xf;

pub const TraitOptions = struct {
    phase: Phase,
    mobility: Mobility,
    uses_motion: bool = false,
    conductive: bool = false,
    blocks_pressure: bool = false,
    compressible: bool = false,
    friction: u4 = 0,
    motion_decay: u4 = 0,
    pressure_response: u4 = 0,
    disturbance_decay: u4 = 0,
    surface_response: u4 = 0,
};

/// Immutable per-material data mirrored exactly by MaterialSpec in sim.hlsl.
/// Dynamic values such as a cell's current temperature belong in separate
/// canonical GPU state channels, not in this table or the packed cell word.
pub const MaterialSpec = extern struct {
    traits: u32,
    density: u32,
    electrical_resistance: u32,
    default_temperature_mc: i32,
    heat_capacity: u32,
    ignition_point_mc: i32,
    reaction_offset: u32 = 0,
    reaction_count: u32 = 0,

    pub fn init(options: TraitOptions, density: u32, electrical_resistance: u32, default_temperature_mc: i32, heat_capacity: u32, ignition_point_mc: i32) MaterialSpec {
        return .{
            .traits = encodeTraits(options),
            .density = density,
            .electrical_resistance = electrical_resistance,
            .default_temperature_mc = default_temperature_mc,
            .heat_capacity = heat_capacity,
            .ignition_point_mc = ignition_point_mc,
        };
    }

    pub fn phase(self: MaterialSpec) Phase {
        return @enumFromInt(self.traits & trait_phase_mask);
    }

    pub fn mobility(self: MaterialSpec) Mobility {
        return @enumFromInt((self.traits & trait_mobility_mask) >> trait_mobility_shift);
    }

    pub fn isValid(self: MaterialSpec) bool {
        return (self.traits & trait_valid) != 0;
    }

    pub fn usesMotion(self: MaterialSpec) bool {
        return (self.traits & trait_uses_motion) != 0;
    }

    pub fn blocksPressure(self: MaterialSpec) bool {
        return (self.traits & trait_blocks_pressure) != 0;
    }

    pub fn friction(self: MaterialSpec) u4 {
        return @truncate(self.traits >> trait_friction_shift);
    }

    pub fn motionDecay(self: MaterialSpec) u4 {
        return @truncate(self.traits >> trait_motion_decay_shift);
    }

    pub fn pressureResponse(self: MaterialSpec) u4 {
        return @truncate(self.traits >> trait_pressure_response_shift);
    }

    pub fn disturbanceDecay(self: MaterialSpec) u4 {
        return @truncate(self.traits >> trait_disturbance_decay_shift);
    }

    pub fn surfaceResponse(self: MaterialSpec) u4 {
        return @truncate(self.traits >> trait_surface_response_shift);
    }
};

/// Host-side contract for future pair reactions. Rules are sorted by their
/// canonical material pair and stable rule ID. No reaction GPU pass exists yet.
pub const ReactionRule = extern struct {
    material_a: u32,
    material_b: u32,
    output_a: u32,
    output_b: u32,
    minimum_temperature_mc: i32,
    priority: u32,
    rule_id: u32,
    flags: u32 = 0,
};

pub const Entry = struct {
    id: u8,
    spec: *const MaterialSpec,
};

pub const MaterialRegistry = struct {
    specs: [max_materials]MaterialSpec = .{invalid_spec} ** max_materials,

    pub fn builtins() MaterialRegistry {
        var registry: MaterialRegistry = .{};
        registry.add(@intFromEnum(abi.Material.empty), MaterialSpec.init(.{
            .phase = .none,
            .mobility = .none,
        }, 0, std.math.maxInt(u32), 20_000, 0, no_ignition_temperature)) catch unreachable;
        registry.add(@intFromEnum(abi.Material.sand), MaterialSpec.init(.{
            .phase = .solid,
            .mobility = .powder,
            .uses_motion = true,
            .blocks_pressure = true,
            .friction = 4,
            .motion_decay = 2,
            .disturbance_decay = 8,
        }, 1600, std.math.maxInt(u32), 20_000, 830, no_ignition_temperature)) catch unreachable;
        registry.add(@intFromEnum(abi.Material.water), MaterialSpec.init(.{
            .phase = .liquid,
            .mobility = .fluid,
            .uses_motion = true,
            .conductive = true,
            .friction = 0,
            .motion_decay = 1,
            .pressure_response = 4,
            .disturbance_decay = 1,
            .surface_response = 8,
        }, 1000, 1000, 20_000, 4184, no_ignition_temperature)) catch unreachable;
        registry.add(@intFromEnum(abi.Material.stone), MaterialSpec.init(.{
            .phase = .solid,
            .mobility = .static,
            .blocks_pressure = true,
            .friction = 15,
            .motion_decay = 15,
            .disturbance_decay = 15,
        }, 2600, std.math.maxInt(u32), 20_000, 790, no_ignition_temperature)) catch unreachable;
        registry.add(@intFromEnum(abi.Material.steam), MaterialSpec.init(.{
            .phase = .gas,
            .mobility = .gas,
            .friction = 0,
            .motion_decay = 15,
            .disturbance_decay = 15,
        }, 1, std.math.maxInt(u32), 100_000, 2010, no_ignition_temperature)) catch unreachable;
        registry.add(@intFromEnum(abi.Material.cloud), MaterialSpec.init(.{
            .phase = .gas,
            .mobility = .gas,
            .friction = 8,
            .motion_decay = 15,
            .disturbance_decay = 15,
        }, 2, std.math.maxInt(u32), 20_000, 4184, no_ignition_temperature)) catch unreachable;
        registry.validate(&.{}) catch unreachable;
        return registry;
    }

    pub fn add(self: *MaterialRegistry, id: u8, spec: MaterialSpec) !void {
        if (self.specs[id].isValid()) return error.DuplicateMaterial;
        if (!spec.isValid()) return error.InvalidMaterialSpec;
        self.specs[id] = spec;
    }

    pub fn get(self: *const MaterialRegistry, id: u8) ?*const MaterialSpec {
        const spec = &self.specs[id];
        return if (spec.isValid()) spec else null;
    }

    pub fn list(self: *const MaterialRegistry) Iterator {
        return .{ .registry = self };
    }

    pub fn gpuSlice(self: *const MaterialRegistry) []const MaterialSpec {
        return &self.specs;
    }

    pub fn validate(self: *const MaterialRegistry, reactions: []const ReactionRule) !void {
        var found_empty = false;
        for (self.specs, 0..) |spec, id| {
            if (!spec.isValid()) continue;
            if ((spec.traits & trait_phase_mask) > @intFromEnum(Phase.gas)) return error.InvalidPhase;
            if (((spec.traits & trait_mobility_mask) >> trait_mobility_shift) > @intFromEnum(Mobility.gas)) return error.InvalidMobility;
            const reaction_end = @as(u64, spec.reaction_offset) + spec.reaction_count;
            if (reaction_end > reactions.len) return error.InvalidReactionRange;
            if (id == @intFromEnum(abi.Material.empty)) found_empty = true;
        }
        if (!found_empty) return error.MissingEmptyMaterial;

        for (reactions, 0..) |rule, index| {
            if (rule.material_a > rule.material_b) return error.NonCanonicalReactionPair;
            if (rule.material_a >= max_materials or rule.material_b >= max_materials) return error.InvalidReactionMaterial;
            if (self.get(@intCast(rule.material_a)) == null or self.get(@intCast(rule.material_b)) == null) return error.InvalidReactionMaterial;
            if (index == 0) continue;
            const prior = reactions[index - 1];
            const sorted = prior.material_a < rule.material_a or
                (prior.material_a == rule.material_a and prior.material_b < rule.material_b) or
                (prior.material_a == rule.material_a and prior.material_b == rule.material_b and prior.rule_id < rule.rule_id);
            if (!sorted) return error.UnsortedReactionRules;
        }
    }

    pub const Iterator = struct {
        registry: *const MaterialRegistry,
        next_id: usize = 0,

        pub fn next(self: *Iterator) ?Entry {
            while (self.next_id < max_materials) {
                const id = self.next_id;
                self.next_id += 1;
                if (self.registry.specs[id].isValid()) return .{ .id = @intCast(id), .spec = &self.registry.specs[id] };
            }
            return null;
        }
    };
};

const invalid_spec = MaterialSpec{
    .traits = 0,
    .density = 0,
    .electrical_resistance = 0,
    .default_temperature_mc = 0,
    .heat_capacity = 0,
    .ignition_point_mc = 0,
};

fn encodeTraits(options: TraitOptions) u32 {
    var traits = trait_valid |
        (@intFromEnum(options.phase) & trait_phase_mask) |
        ((@intFromEnum(options.mobility) << trait_mobility_shift) & trait_mobility_mask);
    if (options.uses_motion) traits |= trait_uses_motion;
    if (options.conductive) traits |= trait_conductive;
    if (options.blocks_pressure) traits |= trait_blocks_pressure;
    if (options.compressible) traits |= trait_compressible;
    traits |= @as(u32, options.friction) << trait_friction_shift;
    traits |= @as(u32, options.motion_decay) << trait_motion_decay_shift;
    traits |= @as(u32, options.pressure_response) << trait_pressure_response_shift;
    traits |= @as(u32, options.disturbance_decay) << trait_disturbance_decay_shift;
    traits |= @as(u32, options.surface_response) << trait_surface_response_shift;
    return traits;
}

test "material GPU ABI and trait encoding are stable" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(MaterialSpec));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(MaterialSpec, "traits"));
    try std.testing.expectEqual(@as(usize, 28), @offsetOf(MaterialSpec, "reaction_count"));
    try std.testing.expectEqual(@as(u32, 3), @intFromEnum(Phase.gas));
    try std.testing.expectEqual(@as(u32, 4), @intFromEnum(Mobility.gas));

    const registry = MaterialRegistry.builtins();
    const sand = registry.get(@intFromEnum(abi.Material.sand)).?;
    try std.testing.expectEqual(Phase.solid, sand.phase());
    try std.testing.expectEqual(Mobility.powder, sand.mobility());
    try std.testing.expectEqual(@as(u32, 1600), sand.density);
    try std.testing.expect(sand.usesMotion());
    try std.testing.expect(sand.blocksPressure());
    try std.testing.expectEqual(@as(u4, 4), sand.friction());
    try std.testing.expectEqual(@as(u4, 2), sand.motionDecay());

    const water = registry.get(@intFromEnum(abi.Material.water)).?;
    try std.testing.expect(water.usesMotion());
    try std.testing.expect(!water.blocksPressure());
    try std.testing.expectEqual(@as(u4, 0), water.friction());
    try std.testing.expectEqual(@as(u4, 1), water.motionDecay());
    try std.testing.expectEqual(@as(u4, 4), water.pressureResponse());
    try std.testing.expectEqual(@as(u4, 1), water.disturbanceDecay());
    try std.testing.expectEqual(@as(u4, 8), water.surfaceResponse());

    const steam = registry.get(@intFromEnum(abi.Material.steam)).?;
    try std.testing.expectEqual(Phase.gas, steam.phase());
    try std.testing.expectEqual(Mobility.gas, steam.mobility());
    try std.testing.expectEqual(@as(u32, 1), steam.density);

    const cloud = registry.get(@intFromEnum(abi.Material.cloud)).?;
    try std.testing.expectEqual(Phase.gas, cloud.phase());
    try std.testing.expectEqual(@as(u4, 8), cloud.friction());

    const stone = registry.get(@intFromEnum(abi.Material.stone)).?;
    try std.testing.expect(stone.blocksPressure());
}

test "material registry rejects duplicates and invalid reaction ranges" {
    var registry = MaterialRegistry.builtins();
    const sand = registry.get(@intFromEnum(abi.Material.sand)).?.*;
    try std.testing.expectError(error.DuplicateMaterial, registry.add(@intFromEnum(abi.Material.sand), sand));

    registry.specs[@intFromEnum(abi.Material.sand)].reaction_count = 1;
    try std.testing.expectError(error.InvalidReactionRange, registry.validate(&.{}));
}

test "material registry lists only defined stable IDs" {
    const registry = MaterialRegistry.builtins();
    var iterator = registry.list();
    var expected_id: u8 = 0;
    while (iterator.next()) |entry| : (expected_id += 1) {
        try std.testing.expectEqual(expected_id, entry.id);
        try std.testing.expect(entry.spec.isValid());
    }
    try std.testing.expectEqual(@as(u8, 6), expected_id);
}
