// ZigSand's simulation is integer-only. Every pass reads the canonical grid;
// only CommitMain mutates it. That separation makes cell results independent
// of GPU workgroup scheduling.

static const uint MATERIAL_EMPTY = 0u;
static const uint MATERIAL_SAND = 1u;
static const uint MATERIAL_WATER = 2u;
static const uint MATERIAL_STONE = 3u;
static const uint MATERIAL_STEAM = 4u;
static const uint MATERIAL_CLOUD = 5u;

static const uint INTENT_STAY = 0u;
static const uint INTENT_DOWN = 1u;
static const uint INTENT_DOWN_LEFT = 2u;
static const uint INTENT_DOWN_RIGHT = 3u;
static const uint INTENT_LEFT = 4u;
static const uint INTENT_RIGHT = 5u;
static const uint INTENT_UP = 6u;
static const uint INVALID_INDEX = 0xffffffffu;
static const uint CHUNK_SIZE = 16u;
static const uint TRAIT_PHASE_MASK = 0x3u;
static const uint TRAIT_MOBILITY_SHIFT = 2u;
static const uint TRAIT_MOBILITY_MASK = 0x1cu;
static const uint TRAIT_USES_MOTION = 1u << 5u;
static const uint TRAIT_VALID = 1u << 8u;
static const uint TRAIT_BLOCKS_PRESSURE = 1u << 10u;
static const uint PHASE_LIQUID = 2u;
static const uint PHASE_GAS = 3u;
static const uint MOBILITY_POWDER = 2u;
static const uint MOBILITY_GAS = 4u;
static const uint TRAIT_FRICTION_SHIFT = 12u;
static const uint TRAIT_MOTION_DECAY_SHIFT = 16u;
static const uint TRAIT_PRESSURE_RESPONSE_SHIFT = 20u;
static const uint TRAIT_DISTURBANCE_DECAY_SHIFT = 24u;
static const uint TRAIT_SURFACE_RESPONSE_SHIFT = 28u;
static const uint TRAIT_NIBBLE_MASK = 0xfu;
static const uint CHANNEL_MOTION = 1u;
static const uint CHANNEL_DISTURBANCE = 1u << 1u;
static const uint CHANNEL_PRESSURE = 1u << 2u;
static const uint MOTION_DIRECTION_MASK = 0x7u;
static const uint MOTION_STRENGTH_SHIFT = 3u;
static const uint MOTION_MASK = 0x7fu;
static const uint PROPOSAL_ACCEPTED_SHIFT = 3u;
static const uint PROPOSAL_REJECTED_SHIFT = 10u;
static const uint PROPOSAL_USES_MOTION = 1u << 17u;
static const uint WATER_START_STRENGTH = 15u;
static const uint SAND_START_STRENGTH = 7u;
static const uint DISTURBANCE_MASK = 0xfu;
static const uint DISTURBANCE_WRITE = 1u << 31u;
static const uint PRESSURE_MASK = 0xffu;
static const uint PRESSURE_WRITE = 1u << 30u;
// Atmosphere equilibrium is intentionally tuned for a visible cloud ceiling.
// About one supported surface cell in 1024 evaporates per tick, while Cloud
// age advances once per 32 ticks. Uncapped mode reaches that equilibrium much
// faster in wall time without changing the deterministic tick result.
static const uint EVAPORATION_MASK = 0x3ffu;
static const uint CLOUD_AGE_CADENCE_MASK = 0x1fu;

// Canonical cell storage is never globally swapped. Active chunks produce a
// scratch result, commit it back in place, and only the two activity-list roles
// change between ticks. This keeps sleeping chunks valid without snapshot copies.
struct SimPush {
    uint width;
    uint height;
    uint paddedWidth;
    uint paddedHeight;
    uint chunksX;
    uint chunksY;
    uint tick;
    uint seed;
    uint brushX;
    uint brushY;
    uint brushRadius;
    uint brushMaterial;
    uint commandFlags;
    uint testCase;
    uint channelFlags;
    uint reserved1;
};

struct TestResult {
    uint failures;
    uint sandCount;
    uint waterCount;
    uint stoneCount;
    uint stateHash;
    uint activeCount;
    uint cellHash;
    uint motionHash;
    uint disturbanceHash;
    uint disturbedCells;
    uint pressureHash;
    uint pressurizedCells;
    uint steamCount;
    uint cloudCount;
};

// Read-only material metadata. This 32-byte layout is mirrored exactly by
// src/material.zig; evolving per-cell state never belongs in this table.
struct MaterialSpec {
    uint traits;
    uint density;
    uint electricalResistance;
    int defaultTemperatureMc;
    uint heatCapacity;
    int ignitionPointMc;
    uint reactionOffset;
    uint reactionCount;
};

[[vk::push_constant]] ConstantBuffer<SimPush> Push;
[[vk::binding(0, 0)]] RWStructuredBuffer<uint> Cells;
[[vk::binding(1, 0)]] RWStructuredBuffer<uint> Scratch;
[[vk::binding(2, 0)]] RWStructuredBuffer<uint> Intents;
[[vk::binding(3, 0)]] RWStructuredBuffer<uint> NowFlags;
[[vk::binding(4, 0)]] RWStructuredBuffer<uint> NowList;
[[vk::binding(5, 0)]] RWStructuredBuffer<uint> NowMeta;
[[vk::binding(6, 0)]] RWStructuredBuffer<uint> NowArgs;
[[vk::binding(7, 0)]] RWStructuredBuffer<uint> NextFlags;
[[vk::binding(8, 0)]] RWStructuredBuffer<uint> NextList;
[[vk::binding(9, 0)]] RWStructuredBuffer<uint> NextMeta;
[[vk::binding(10, 0)]] RWStructuredBuffer<uint> NextArgs;
[[vk::binding(11, 0)]] RWStructuredBuffer<TestResult> Results;
[[vk::binding(12, 0)]] StructuredBuffer<MaterialSpec> MaterialSpecs;
[[vk::binding(13, 0)]] RWStructuredBuffer<uint> MotionChannel;
[[vk::binding(14, 0)]] RWStructuredBuffer<uint> DisturbanceChannel;
[[vk::binding(15, 0)]] RWStructuredBuffer<uint> PressureChannel;

uint Mix(uint value) {
    value ^= value >> 16u;
    value *= 0x7feb352du;
    value ^= value >> 15u;
    value *= 0x846ca68bu;
    value ^= value >> 16u;
    return value;
}

uint MaterialOf(uint cell) { return cell & 0xffu; }
uint CellState(uint cell) { return (cell >> 16u) & 0xffu; }
uint MakeCell(uint material, uint2 coord) {
    uint variant = Mix(coord.x ^ (coord.y * 0x9e3779b9u) ^ Push.seed) & 0xffu;
    return material | (variant << 8u);
}
uint MakeCellState(uint material, uint2 coord, uint state) {
    return MakeCell(material, coord) | ((state & 0xffu) << 16u);
}
uint WithMaterialState(uint cell, uint material, uint state) {
    return (cell & 0x0000ff00u) | (material & 0xffu) | ((state & 0xffu) << 16u);
}

bool InBounds(int2 coord) {
    return coord.x >= 0 && coord.y >= 0 && coord.x < (int)Push.width && coord.y < (int)Push.height;
}

uint IndexOf(int2 coord) {
    return (uint)coord.y * Push.paddedWidth + (uint)coord.x;
}

uint SampleCell(int2 coord) {
    return InBounds(coord) ? Cells[IndexOf(coord)] : MakeCell(MATERIAL_STONE, uint2(0u, 0u));
}

int2 IntentTarget(int2 source, uint intent) {
    if (intent == INTENT_DOWN) return source + int2(0, -1);
    if (intent == INTENT_DOWN_LEFT) return source + int2(-1, -1);
    if (intent == INTENT_DOWN_RIGHT) return source + int2(1, -1);
    if (intent == INTENT_LEFT) return source + int2(-1, 0);
    if (intent == INTENT_RIGHT) return source + int2(1, 0);
    if (intent == INTENT_UP) return source + int2(0, 1);
    return source;
}

uint PhaseOf(MaterialSpec spec) { return spec.traits & TRAIT_PHASE_MASK; }
uint MobilityOf(MaterialSpec spec) { return (spec.traits & TRAIT_MOBILITY_MASK) >> TRAIT_MOBILITY_SHIFT; }
bool UsesMotion(MaterialSpec spec) { return (spec.traits & TRAIT_USES_MOTION) != 0u; }
bool BlocksPressure(MaterialSpec spec) { return (spec.traits & TRAIT_BLOCKS_PRESSURE) != 0u; }
uint FrictionOf(MaterialSpec spec) { return (spec.traits >> TRAIT_FRICTION_SHIFT) & TRAIT_NIBBLE_MASK; }
uint MotionDecayOf(MaterialSpec spec) { return (spec.traits >> TRAIT_MOTION_DECAY_SHIFT) & TRAIT_NIBBLE_MASK; }
uint PressureResponseOf(MaterialSpec spec) { return (spec.traits >> TRAIT_PRESSURE_RESPONSE_SHIFT) & TRAIT_NIBBLE_MASK; }
uint DisturbanceDecayOf(MaterialSpec spec) { return (spec.traits >> TRAIT_DISTURBANCE_DECAY_SHIFT) & TRAIT_NIBBLE_MASK; }
uint SurfaceResponseOf(MaterialSpec spec) { return (spec.traits >> TRAIT_SURFACE_RESPONSE_SHIFT) & TRAIT_NIBBLE_MASK; }

bool MotionEnabled() { return (Push.channelFlags & CHANNEL_MOTION) != 0u; }
uint ReadMotion(uint index) { return MotionEnabled() ? (MotionChannel[index] & MOTION_MASK) : 0u; }
void WriteMotion(uint index, uint motion) {
    if (MotionEnabled()) MotionChannel[index] = motion & MOTION_MASK;
}

bool DisturbanceEnabled() { return (Push.channelFlags & CHANNEL_DISTURBANCE) != 0u; }
uint ReadDisturbance(uint index) { return DisturbanceEnabled() ? (DisturbanceChannel[index] & DISTURBANCE_MASK) : 0u; }
void WriteDisturbance(uint index, uint disturbance) {
    if (DisturbanceEnabled()) DisturbanceChannel[index] = disturbance & DISTURBANCE_MASK;
}

bool PressureEnabled() { return (Push.channelFlags & CHANNEL_PRESSURE) != 0u; }
uint ReadPressure(uint index) { return PressureEnabled() ? (PressureChannel[index] & PRESSURE_MASK) : 0u; }
uint ReadPressureAt(int2 coord) { return PressureEnabled() && InBounds(coord) ? ReadPressure(IndexOf(coord)) : 0u; }
void WritePressure(uint index, uint pressure) {
    if (PressureEnabled()) PressureChannel[index] = pressure & PRESSURE_MASK;
}

uint PressureBiasedSide(int2 coord, uint index, uint pressure, uint fallback) {
    if (pressure == 0u) return fallback;
    uint leftHead = ReadPressureAt(coord + int2(-1, 0)) +
        ReadPressureAt(coord + int2(-1, 1)) + ReadPressureAt(coord + int2(-1, -1));
    uint rightHead = ReadPressureAt(coord + int2(1, 0)) +
        ReadPressureAt(coord + int2(1, 1)) + ReadPressureAt(coord + int2(1, -1));
    if (leftHead < rightHead) return INTENT_LEFT;
    if (rightHead < leftHead) return INTENT_RIGHT;
    uint key = Mix(index ^ Push.tick ^ Push.seed ^ pressure ^ 0x27d4eb2du);
    return (key & 0xffu) < pressure ? ((key & 0x100u) == 0u ? INTENT_LEFT : INTENT_RIGHT) : fallback;
}

uint MotionDirectionOf(uint motion) { return motion & MOTION_DIRECTION_MASK; }
uint MotionStrengthOf(uint motion) { return (motion >> MOTION_STRENGTH_SHIFT) & 0xfu; }
uint MakeMotion(uint direction, uint strength) {
    strength = min(strength, 15u);
    return strength == 0u ? 0u : (direction & MOTION_DIRECTION_MASK) | (strength << MOTION_STRENGTH_SHIFT);
}
uint DecayStrength(uint strength, uint amount) { return strength > amount ? strength - amount : 0u; }

uint PackProposal(uint direction, uint acceptedMotion, uint rejectedMotion) {
    return (direction & MOTION_DIRECTION_MASK) |
        ((acceptedMotion & MOTION_MASK) << PROPOSAL_ACCEPTED_SHIFT) |
        ((rejectedMotion & MOTION_MASK) << PROPOSAL_REJECTED_SHIFT);
}
uint ProposalDirection(uint proposal) { return proposal & MOTION_DIRECTION_MASK; }
uint ProposalAcceptedMotion(uint proposal) { return (proposal >> PROPOSAL_ACCEPTED_SHIFT) & MOTION_MASK; }
uint ProposalRejectedMotion(uint proposal) { return (proposal >> PROPOSAL_REJECTED_SHIFT) & MOTION_MASK; }
bool ProposalUsesMotion(uint proposal) { return (proposal & PROPOSAL_USES_MOTION) != 0u; }

uint OppositeSide(uint direction) { return direction == INTENT_LEFT ? INTENT_RIGHT : INTENT_LEFT; }
bool HasHorizontalMotion(uint motion) {
    uint direction = MotionDirectionOf(motion);
    return MotionStrengthOf(motion) > 0u && (direction == INTENT_LEFT || direction == INTENT_RIGHT ||
        direction == INTENT_DOWN_LEFT || direction == INTENT_DOWN_RIGHT);
}
uint HorizontalSideOf(uint motion) {
    uint direction = MotionDirectionOf(motion);
    return direction == INTENT_LEFT || direction == INTENT_DOWN_LEFT ? INTENT_LEFT : INTENT_RIGHT;
}
uint DownwardMotionForSide(uint side) { return side == INTENT_LEFT ? INTENT_DOWN_LEFT : INTENT_DOWN_RIGHT; }
uint HashedWaterSide(uint index) {
    return (Mix(index ^ Push.tick ^ Push.seed ^ 0xa511e9b3u) & 1u) == 0u ? INTENT_LEFT : INTENT_RIGHT;
}

bool PowderCanEnter(MaterialSpec source, uint destinationMaterial) {
    if (destinationMaterial == MATERIAL_EMPTY) return true;
    MaterialSpec destination = MaterialSpecs[destinationMaterial];
    uint destinationPhase = PhaseOf(destination);
    return (destination.traits & TRAIT_VALID) != 0u && source.density > destination.density &&
        (destinationPhase == PHASE_LIQUID || destinationPhase == PHASE_GAS);
}

bool WaterCanEnter(MaterialSpec source, uint material) {
    if (material == MATERIAL_EMPTY) return true;
    MaterialSpec destination = MaterialSpecs[material];
    return (destination.traits & TRAIT_VALID) != 0u &&
        PhaseOf(destination) == PHASE_GAS && source.density > destination.density;
}

bool GasCanEnter(MaterialSpec source, uint material) {
    if (material == MATERIAL_EMPTY) return true;
    MaterialSpec destination = MaterialSpecs[material];
    return (destination.traits & TRAIT_VALID) != 0u &&
        PhaseOf(destination) == PHASE_LIQUID && source.density < destination.density;
}

bool GasCanRiseThrough(MaterialSpec source, uint material) {
    if (material == MATERIAL_EMPTY) return true;
    MaterialSpec destination = MaterialSpecs[material];
    if ((destination.traits & TRAIT_VALID) == 0u || source.density >= destination.density)
        return false;
    uint phase = PhaseOf(destination);
    return phase == PHASE_LIQUID || MobilityOf(destination) == MOBILITY_POWDER;
}

void AppendNowChunk(int2 chunk) {
    if (chunk.x < 0 || chunk.y < 0 || chunk.x >= (int)Push.chunksX || chunk.y >= (int)Push.chunksY) return;
    uint chunkIndex = (uint)chunk.y * Push.chunksX + (uint)chunk.x;
    uint previous;
    InterlockedCompareExchange(NowFlags[chunkIndex], 0u, 1u, previous);
    if (previous == 0u) {
        uint slot;
        InterlockedAdd(NowMeta[0], 1u, slot);
        NowList[slot] = chunkIndex;
        InterlockedMax(NowArgs[0], slot + 1u);
    }
}

void AppendNextChunk(int2 chunk) {
    if (chunk.x < 0 || chunk.y < 0 || chunk.x >= (int)Push.chunksX || chunk.y >= (int)Push.chunksY) return;
    uint chunkIndex = (uint)chunk.y * Push.chunksX + (uint)chunk.x;
    uint previous;
    InterlockedCompareExchange(NextFlags[chunkIndex], 0u, 1u, previous);
    if (previous == 0u) {
        uint slot;
        InterlockedAdd(NextMeta[0], 1u, slot);
        NextList[slot] = chunkIndex;
        InterlockedMax(NextArgs[0], slot + 1u);
    }
}

void ActivateNowHalo(int2 coord) {
    int2 chunk = coord / (int)CHUNK_SIZE;
    [unroll] for (int y = -1; y <= 1; ++y)
        [unroll] for (int x = -1; x <= 1; ++x)
            AppendNowChunk(chunk + int2(x, y));
}

void ActivateNextHalo(int2 coord) {
    int2 chunk = coord / (int)CHUNK_SIZE;
    [unroll] for (int y = -1; y <= 1; ++y)
        [unroll] for (int x = -1; x <= 1; ++x)
            AppendNextChunk(chunk + int2(x, y));
}

uint ScenarioCell(int2 coord) {
    if (!InBounds(coord)) return MakeCell(MATERIAL_STONE, uint2(max(coord, 0)));
    if (coord.x == 0 || coord.y == 0 || coord.x == (int)Push.width - 1 || coord.y == (int)Push.height - 1)
        return MakeCell(MATERIAL_STONE, (uint2)coord);

    if (Push.testCase != 0u) {
        if (Push.testCase == 1u && all(coord == int2(8, 8))) return MakeCell(MATERIAL_SAND, (uint2)coord);
        if (Push.testCase == 2u) {
            if (all(coord == int2(8, 8))) return MakeCell(MATERIAL_SAND, (uint2)coord);
            if (all(coord == int2(7, 7)) || all(coord == int2(8, 7)) || all(coord == int2(9, 7))) return MakeCell(MATERIAL_STONE, (uint2)coord);
        }
        if (Push.testCase == 3u) {
            if (all(coord == int2(8, 8))) return MakeCell(MATERIAL_SAND, (uint2)coord);
            if (all(coord == int2(8, 7))) return MakeCell(MATERIAL_STONE, (uint2)coord);
        }
        if (Push.testCase == 4u && all(coord == int2(8, 8))) return MakeCell(MATERIAL_WATER, (uint2)coord);
        if (Push.testCase == 5u) {
            if (all(coord == int2(8, 8))) return MakeCell(MATERIAL_WATER, (uint2)coord);
            if (all(coord == int2(8, 7))) return MakeCell(MATERIAL_STONE, (uint2)coord);
        }
        if (Push.testCase == 6u) {
            if (all(coord == int2(8, 9))) return MakeCell(MATERIAL_SAND, (uint2)coord);
            if (all(coord == int2(8, 8))) return MakeCell(MATERIAL_WATER, (uint2)coord);
            if (all(coord == int2(7, 8)) || all(coord == int2(9, 8)) ||
                all(coord == int2(7, 7)) || all(coord == int2(8, 7)) || all(coord == int2(9, 7)))
                return MakeCell(MATERIAL_STONE, (uint2)coord);
        }
        if (Push.testCase == 7u) {
            if (all(coord == int2(8, 9))) return MakeCell(MATERIAL_SAND, (uint2)coord);
            if (all(coord == int2(8, 8))) return MakeCell(MATERIAL_WATER, (uint2)coord);
        }
        if (Push.testCase == 8u) {
            if (all(coord == int2(7, 9)) || all(coord == int2(9, 9))) return MakeCell(MATERIAL_SAND, (uint2)coord);
            if (all(coord == int2(6, 8)) || all(coord == int2(7, 8)) || all(coord == int2(9, 8)) || all(coord == int2(10, 8))) return MakeCell(MATERIAL_STONE, (uint2)coord);
        }
        if (Push.testCase == 9u && all(coord == int2(8, 8))) return MakeCell(MATERIAL_STONE, (uint2)coord);
        if (Push.testCase == 11u && all(coord == int2(15, 16))) return MakeCell(MATERIAL_SAND, (uint2)coord);
        if (Push.testCase == 14u) {
            // Compact determinism fixture: powder/liquid displacement, several
            // movement conflicts, and activity crossing both 16-cell axes.
            if (coord.y == 7 && coord.x >= 4 && coord.x <= 27 && coord.x != 15 && coord.x != 16)
                return MakeCell(MATERIAL_STONE, (uint2)coord);
            if (coord.x == 8 && coord.y >= 8 && coord.y <= 14)
                return MakeCell(MATERIAL_STONE, (uint2)coord);
            if (coord.x >= 11 && coord.x <= 20 && coord.y >= 9 && coord.y <= 11)
                return MakeCell(MATERIAL_WATER, (uint2)coord);
            if ((coord.x == 15 || coord.x == 16) && coord.y == 16)
                return MakeCell(MATERIAL_WATER, (uint2)coord);
            if (coord.x >= 12 && coord.x <= 19 && coord.y >= 18 && coord.y <= 22)
                return MakeCell(MATERIAL_SAND, (uint2)coord);
            if ((coord.x == 15 || coord.x == 16) && coord.y == 17)
                return MakeCell(MATERIAL_SAND, (uint2)coord);
        }
        if (Push.testCase == 15u) {
            // Open basin spanning chunk boundaries with a small falling Water
            // sheet. ScenarioMotion seeds opposing lateral tendencies.
            if (coord.y == 6 && coord.x >= 4 && coord.x <= 27)
                return MakeCell(MATERIAL_STONE, (uint2)coord);
            if ((coord.x == 4 || coord.x == 27) && coord.y >= 6 && coord.y <= 18)
                return MakeCell(MATERIAL_STONE, (uint2)coord);
            if (coord.x >= 13 && coord.x <= 18 && coord.y >= 21 && coord.y <= 24)
                return MakeCell(MATERIAL_WATER, (uint2)coord);
        }
        if (Push.testCase == 16u) {
            // Sand sheet falling across chunk boundaries onto a short shelf;
            // repeated diagonal avalanches exercise brief powder tendency.
            if (coord.y == 6 && coord.x >= 3 && coord.x <= 28)
                return MakeCell(MATERIAL_STONE, (uint2)coord);
            if (coord.y == 13 && coord.x >= 14 && coord.x <= 17)
                return MakeCell(MATERIAL_STONE, (uint2)coord);
            if (coord.x >= 13 && coord.x <= 18 && coord.y >= 18 && coord.y <= 22)
                return MakeCell(MATERIAL_SAND, (uint2)coord);
        }
        if (Push.testCase == 17u) {
            // Two-level Water surface in a shallow basin. A central seeded
            // impulse must spread deterministically across connected surface.
            if (coord.y == 6 && coord.x >= 3 && coord.x <= 28)
                return MakeCell(MATERIAL_STONE, (uint2)coord);
            if ((coord.x == 3 || coord.x == 28) && coord.y >= 6 && coord.y <= 12)
                return MakeCell(MATERIAL_STONE, (uint2)coord);
            if (coord.y == 7 && coord.x >= 4 && coord.x <= 27)
                return MakeCell(MATERIAL_WATER, (uint2)coord);
            if (coord.y == 8 && coord.x >= 12 && coord.x <= 19)
                return MakeCell(MATERIAL_WATER, (uint2)coord);
        }
        if (Push.testCase == 18u) {
            // Deep, motionless Water column spanning chunk boundaries. Its
            // open surface drains while integer head pressure grows downward.
            if (coord.y == 4 && coord.x >= 2 && coord.x <= 29)
                return MakeCell(MATERIAL_STONE, (uint2)coord);
            if ((coord.x == 2 || coord.x == 29) && coord.y >= 4 && coord.y <= 20)
                return MakeCell(MATERIAL_STONE, (uint2)coord);
            if (coord.x >= 3 && coord.x <= 28 && coord.y >= 5 && coord.y <= 14)
                return MakeCell(MATERIAL_WATER, (uint2)coord);
        }
        if (Push.testCase == 20u) {
            if (all(coord == int2(8, 8))) return MakeCell(MATERIAL_WATER, (uint2)coord);
            if (all(coord == int2(8, 7)) || all(coord == int2(7, 8)) || all(coord == int2(9, 8)))
                return MakeCell(MATERIAL_STONE, (uint2)coord);
        }
        if (Push.testCase == 21u && all(coord == int2(8, 8)))
            return MakeCell(MATERIAL_STEAM, (uint2)coord);
        if (Push.testCase == 22u && all(coord == int2(9, 8)))
            return MakeCellState(MATERIAL_CLOUD, (uint2)coord, 255u);
        if (Push.testCase == 23u) {
            // Mixed compact atmosphere fixture: supported Water, rising Steam,
            // and old Cloud. Total H2O material count must remain constant.
            if (coord.y == 5 && coord.x >= 4 && coord.x <= 27)
                return MakeCell(MATERIAL_STONE, (uint2)coord);
            if (coord.y == 6 && coord.x >= 6 && coord.x <= 10)
                return MakeCell(MATERIAL_WATER, (uint2)coord);
            if (coord.y == 24 && coord.x >= 12 && coord.x <= 15)
                return MakeCell(MATERIAL_STEAM, (uint2)coord);
            if (coord.y == 28 && coord.x >= 18 && coord.x <= 21)
                return MakeCellState(MATERIAL_CLOUD, (uint2)coord, 220u + (uint)(coord.x - 18));
        }
        if (Push.testCase == 24u) {
            // Direct powder/gas density swap: Sand must displace Steam down,
            // while Steam simultaneously rises into the Sand source.
            if (all(coord == int2(8, 9))) return MakeCell(MATERIAL_SAND, (uint2)coord);
            if (all(coord == int2(8, 8))) return MakeCell(MATERIAL_STEAM, (uint2)coord);
        }
        if (Push.testCase == 25u) {
            // Steam starts under a three-cell Sand cap in a narrow shaft. It
            // must climb through powder swaps instead of remaining trapped.
            if (coord.y == 7 && coord.x >= 7 && coord.x <= 9)
                return MakeCell(MATERIAL_STONE, (uint2)coord);
            if ((coord.x == 7 || coord.x == 9) && coord.y >= 8 && coord.y <= 12)
                return MakeCell(MATERIAL_STONE, (uint2)coord);
            if (all(coord == int2(8, 8))) return MakeCell(MATERIAL_STEAM, (uint2)coord);
            if (coord.x == 8 && coord.y >= 9 && coord.y <= 11)
                return MakeCell(MATERIAL_SAND, (uint2)coord);
        }
        return MakeCell(MATERIAL_EMPTY, (uint2)coord);
    }

    uint x = (uint)coord.x;
    uint y = (uint)coord.y;
    if (y < Push.height / 5u && x > Push.width / 4u && x < (Push.width * 3u) / 4u)
        return MakeCell(MATERIAL_WATER, (uint2)coord);
    if (y > (Push.height * 3u) / 4u && y < (Push.height * 7u) / 8u && x > Push.width / 3u && x < (Push.width * 2u) / 3u)
        return MakeCell(MATERIAL_SAND, (uint2)coord);
    if (y == Push.height / 3u && x > Push.width / 10u && x < Push.width / 3u)
        return MakeCell(MATERIAL_STONE, (uint2)coord);
    return MakeCell(MATERIAL_EMPTY, (uint2)coord);
}

uint ScenarioMotion(int2 coord, uint cell) {
    if (!MotionEnabled() || MaterialOf(cell) != MATERIAL_WATER) return 0u;
    if (Push.testCase == 15u) {
        uint direction = coord.x <= 15 ? INTENT_RIGHT : INTENT_LEFT;
        return MakeMotion(direction, WATER_START_STRENGTH);
    }
    return 0u;
}

uint ScenarioDisturbance(int2 coord, uint cell) {
    if (!DisturbanceEnabled() || MaterialOf(cell) != MATERIAL_WATER) return 0u;
    if (Push.testCase == 17u && (all(coord == int2(15, 8)) || all(coord == int2(16, 8))))
        return 15u;
    return 0u;
}

uint ScenarioPressure(int2 coord, uint cell) {
    // Pressure is derived from topology rather than seeded. Keeping this
    // initializer explicit makes reset/hash semantics unambiguous.
    if (!PressureEnabled() || MaterialOf(cell) != MATERIAL_WATER) return 0u;
    return 0u;
}

[numthreads(16, 16, 1)]
void InitMain(uint3 dispatchId : SV_DispatchThreadID) {
    if (dispatchId.x >= Push.paddedWidth || dispatchId.y >= Push.paddedHeight) return;
    int2 coord = int2(dispatchId.xy);
    uint index = dispatchId.y * Push.paddedWidth + dispatchId.x;
    uint cell = ScenarioCell(coord);
    Cells[index] = cell;
    Scratch[index] = cell;
    Intents[index] = PackProposal(INTENT_STAY, 0u, 0u);
    WriteMotion(index, ScenarioMotion(coord, cell));
    WriteDisturbance(index, ScenarioDisturbance(coord, cell));
    WritePressure(index, ScenarioPressure(coord, cell));
}

[numthreads(256, 1, 1)]
void InitActivityMain(uint3 dispatchId : SV_DispatchThreadID) {
    uint chunkCount = Push.chunksX * Push.chunksY;
    if (dispatchId.x < chunkCount) {
        NowFlags[dispatchId.x] = 1u;
        NowList[dispatchId.x] = dispatchId.x;
        NextFlags[dispatchId.x] = 0u;
    }
    if (dispatchId.x == 0u) {
        NowMeta[0] = chunkCount;
        NowArgs[0] = chunkCount;
        NowArgs[1] = 1u;
        NowArgs[2] = 1u;
        NextMeta[0] = 0u;
        NextArgs[0] = 0u;
        NextArgs[1] = 1u;
        NextArgs[2] = 1u;
    }
}

[numthreads(16, 16, 1)]
void PaintMain(uint3 dispatchId : SV_DispatchThreadID) {
    if ((Push.commandFlags & 1u) == 0u) return;
    int2 offset = int2(dispatchId.xy) - int2((int)Push.brushRadius, (int)Push.brushRadius);
    if (dot(offset, offset) > (int)(Push.brushRadius * Push.brushRadius)) return;
    int2 coord = int2((int)Push.brushX, (int)Push.brushY) + offset;
    if (!InBounds(coord) || coord.x == 0 || coord.y == 0 || coord.x == (int)Push.width - 1 || coord.y == (int)Push.height - 1) return;
    Cells[IndexOf(coord)] = MakeCell(Push.brushMaterial, (uint2)coord);
    WriteMotion(IndexOf(coord), 0u);
    WriteDisturbance(IndexOf(coord), 0u);
    WritePressure(IndexOf(coord), 0u);
    ActivateNowHalo(coord);
    ActivateNextHalo(coord);
}

groupshared uint IntentTile[18u * 18u];

uint IntentTileCell(int2 coord, int2 base) {
    int2 tile = coord - (base - int2(1, 1));
    if (tile.x >= 0 && tile.y >= 0 && tile.x < 18 && tile.y < 18)
        return IntentTile[(uint)tile.y * 18u + (uint)tile.x];
    return SampleCell(coord);
}

[numthreads(16, 16, 1)]
void IntentMain(uint3 groupId : SV_GroupID, uint3 localId : SV_GroupThreadID, uint groupIndex : SV_GroupIndex) {
    uint chunkIndex = NowList[groupId.x];
    int2 base = int2((int)(chunkIndex % Push.chunksX) * 16, (int)(chunkIndex / Push.chunksX) * 16);
    for (uint i = groupIndex; i < 18u * 18u; i += 256u) {
        int2 tileCoord = int2((int)(i % 18u), (int)(i / 18u));
        IntentTile[i] = SampleCell(base + tileCoord - int2(1, 1));
    }
    GroupMemoryBarrierWithGroupSync();

    int2 coord = base + int2(localId.xy);
    if (!InBounds(coord)) return;
    uint index = IndexOf(coord);
    uint material = MaterialOf(IntentTileCell(coord, base));
    MaterialSpec spec = MaterialSpecs[material];
    uint intent = INTENT_STAY;
    uint acceptedMotion = 0u;
    uint rejectedMotion = 0u;
    // Intents are movement proposals. Powder behavior is selected entirely by
    // immutable traits; material identity is not part of Sand's movement rule.
    if (MobilityOf(spec) == MOBILITY_POWDER) {
        uint currentMotion = UsesMotion(spec) ? ReadMotion(index) : 0u;
        uint currentStrength = MotionStrengthOf(currentMotion);
        uint decay = MotionDecayOf(spec);
        uint rejectionDecay = min(15u, decay + FrictionOf(spec));
        uint preferredSide = HasHorizontalMotion(currentMotion) ? HorizontalSideOf(currentMotion) :
            ((Mix(index ^ Push.tick ^ Push.seed) & 1u) == 0u ? INTENT_LEFT : INTENT_RIGHT);
        uint below = MaterialOf(IntentTileCell(coord + int2(0, -1), base));
        if (PowderCanEnter(spec, below)) {
            intent = INTENT_DOWN;
            if (HasHorizontalMotion(currentMotion)) {
                uint strength = DecayStrength(currentStrength, decay);
                acceptedMotion = MakeMotion(DownwardMotionForSide(preferredSide), strength);
                rejectedMotion = MakeMotion(OppositeSide(preferredSide), DecayStrength(strength, rejectionDecay));
            }
        } else {
            bool left = PowderCanEnter(spec, MaterialOf(IntentTileCell(coord + int2(-1, -1), base)));
            bool right = PowderCanEnter(spec, MaterialOf(IntentTileCell(coord + int2(1, -1), base)));
            if (left && right) intent = preferredSide == INTENT_LEFT ? INTENT_DOWN_LEFT : INTENT_DOWN_RIGHT;
            else if (left) intent = INTENT_DOWN_LEFT;
            else if (right) intent = INTENT_DOWN_RIGHT;

            if (intent != INTENT_STAY) {
                uint chosenSide = intent == INTENT_DOWN_LEFT ? INTENT_LEFT : INTENT_RIGHT;
                bool continuing = HasHorizontalMotion(currentMotion) && chosenSide == HorizontalSideOf(currentMotion);
                uint strength = continuing ? DecayStrength(currentStrength, decay) :
                    (currentStrength > 0u ? DecayStrength(currentStrength, rejectionDecay) : SAND_START_STRENGTH);
                acceptedMotion = MakeMotion(intent, strength);
                rejectedMotion = MakeMotion(OppositeSide(chosenSide), DecayStrength(strength, rejectionDecay));
            }
        }
    } else if (material == MATERIAL_WATER) {
        uint currentMotion = UsesMotion(spec) ? ReadMotion(index) : 0u;
        uint currentStrength = MotionStrengthOf(currentMotion);
        uint decay = MotionDecayOf(spec);
        uint rejectionDecay = min(15u, decay + FrictionOf(spec));
        uint preferredSide = HasHorizontalMotion(currentMotion) ? HorizontalSideOf(currentMotion) : HashedWaterSide(index);
        uint disturbance = ReadDisturbance(index);
        uint disturbanceKey = Mix(index ^ (Push.tick * 0x85ebca6bu) ^ Push.seed ^ disturbance);
        if (disturbance > 0u && (disturbanceKey & 0xfu) < disturbance)
            preferredSide = (disturbanceKey & 0x10u) == 0u ? INTENT_LEFT : INTENT_RIGHT;
        uint currentPressure = ReadPressure(index);
        preferredSide = PressureBiasedSide(coord, index, currentPressure, preferredSide);
        uint below = MaterialOf(IntentTileCell(coord + int2(0, -1), base));
        if (WaterCanEnter(spec, below)) {
            intent = INTENT_DOWN;
            // Gravity maintains a small downward tendency; a lateral component
            // survives the fall and becomes the preferred basin direction.
            uint strength = max(WATER_START_STRENGTH, DecayStrength(currentStrength, decay));
            acceptedMotion = MakeMotion(DownwardMotionForSide(preferredSide), strength);
            rejectedMotion = MakeMotion(OppositeSide(preferredSide), DecayStrength(strength, rejectionDecay));
        } else {
            bool left = WaterCanEnter(spec, MaterialOf(IntentTileCell(coord + int2(-1, 0), base)));
            bool right = WaterCanEnter(spec, MaterialOf(IntentTileCell(coord + int2(1, 0), base)));
            if (left && right) intent = preferredSide;
            else if (left) intent = INTENT_LEFT;
            else if (right) intent = INTENT_RIGHT;

            if (intent != INTENT_STAY) {
                uint chosenSide = intent;
                bool continuing = HasHorizontalMotion(currentMotion) && chosenSide == HorizontalSideOf(currentMotion);
                uint strength = continuing ? DecayStrength(currentStrength, decay) :
                    (currentStrength > 0u ? DecayStrength(currentStrength, rejectionDecay) : WATER_START_STRENGTH);
                acceptedMotion = MakeMotion(intent, strength);
                uint rejectionStrength = strength > 0u ? strength : (currentStrength > 0u ? currentStrength : WATER_START_STRENGTH);
                rejectedMotion = MakeMotion(OppositeSide(chosenSide), DecayStrength(rejectionStrength, rejectionDecay));
            } else {
                acceptedMotion = currentStrength > 0u ?
                    MakeMotion(OppositeSide(preferredSide), DecayStrength(currentStrength, rejectionDecay)) : 0u;
                rejectedMotion = acceptedMotion;
            }
        }
    } else if (MobilityOf(spec) == MOBILITY_GAS) {
        // Gas mobility is trait-selected. Friction becomes a deterministic
        // cadence control: Steam rises every tick while denser Cloud drifts
        // more slowly without requiring another per-cell channel.
        uint period = material == MATERIAL_CLOUD ? 1u : 1u + FrictionOf(spec) / 4u;
        if ((Push.tick + index) % period == 0u) {
            bool left = GasCanEnter(spec, MaterialOf(IntentTileCell(coord + int2(-1, 0), base)));
            bool right = GasCanEnter(spec, MaterialOf(IntentTileCell(coord + int2(1, 0), base)));
            uint preferred = (Mix(index ^ Push.tick ^ Push.seed ^ 0x165667b1u) & 1u) == 0u ? INTENT_LEFT : INTENT_RIGHT;
            if (material == MATERIAL_CLOUD && (left || right)) {
                if (left && right) intent = preferred;
                else if (left) intent = INTENT_LEFT;
                else intent = INTENT_RIGHT;
            }
            uint above = MaterialOf(IntentTileCell(coord + int2(0, 1), base));
            if (intent == INTENT_STAY && GasCanRiseThrough(spec, above)) {
                intent = INTENT_UP;
            } else if (intent == INTENT_STAY) {
                if (left && right) intent = preferred;
                else if (left) intent = INTENT_LEFT;
                else if (right) intent = INTENT_RIGHT;
            }
        }
    }
    uint proposal = PackProposal(intent, acceptedMotion, rejectedMotion);
    if (UsesMotion(spec)) proposal |= PROPOSAL_USES_MOTION;
    Intents[index] = proposal;
}

static const int RESOLVE_HALO = 3;
static const uint RESOLVE_TILE = 22u;
groupshared uint ResolveCells[RESOLVE_TILE * RESOLVE_TILE];
groupshared uint ResolveIntents[RESOLVE_TILE * RESOLVE_TILE];

uint ResolveCell(int2 coord, int2 base) {
    int2 tile = coord - (base - int2(RESOLVE_HALO, RESOLVE_HALO));
    if (tile.x >= 0 && tile.y >= 0 && tile.x < (int)RESOLVE_TILE && tile.y < (int)RESOLVE_TILE)
        return ResolveCells[(uint)tile.y * RESOLVE_TILE + (uint)tile.x];
    return SampleCell(coord);
}

uint ResolveProposal(int2 coord, int2 base) {
    if (!InBounds(coord)) return PackProposal(INTENT_STAY, 0u, 0u);
    int2 tile = coord - (base - int2(RESOLVE_HALO, RESOLVE_HALO));
    if (tile.x >= 0 && tile.y >= 0 && tile.x < (int)RESOLVE_TILE && tile.y < (int)RESOLVE_TILE)
        return ResolveIntents[(uint)tile.y * RESOLVE_TILE + (uint)tile.x];
    return Intents[IndexOf(coord)];
}

void RawConsiderCandidate(int2 source, int2 destination, int2 base, inout uint bestSource, inout uint bestHash) {
    if (!InBounds(source)) return;
    uint proposal = ResolveProposal(source, base);
    uint direction = ProposalDirection(proposal);
    if (direction == INTENT_STAY || any(IntentTarget(source, direction) != destination)) return;
    uint sourceIndex = IndexOf(source);
    uint key = Mix(sourceIndex ^ (Push.tick * 0x9e3779b9u) ^ Push.seed);
    if (bestSource == INVALID_INDEX || key < bestHash || (key == bestHash && sourceIndex < bestSource)) {
        bestSource = sourceIndex;
        bestHash = key;
    }
}

uint RawWinnerFor(int2 destination, int2 base) {
    uint bestSource = INVALID_INDEX;
    uint bestHash = 0xffffffffu;
    RawConsiderCandidate(destination + int2(0, 1), destination, base, bestSource, bestHash);
    RawConsiderCandidate(destination + int2(1, 1), destination, base, bestSource, bestHash);
    RawConsiderCandidate(destination + int2(-1, 1), destination, base, bestSource, bestHash);
    RawConsiderCandidate(destination + int2(-1, 0), destination, base, bestSource, bestHash);
    RawConsiderCandidate(destination + int2(1, 0), destination, base, bestSource, bestHash);
    RawConsiderCandidate(destination + int2(0, -1), destination, base, bestSource, bestHash);
    return bestSource;
}

void ConsiderCandidate(int2 source, int2 destination, int2 base, inout uint bestSource, inout uint bestHash) {
    if (!InBounds(source)) return;
    uint proposal = ResolveProposal(source, base);
    uint direction = ProposalDirection(proposal);
    if (direction == INTENT_STAY || any(IntentTarget(source, direction) != destination)) return;

    uint destinationMaterial = MaterialOf(ResolveCell(destination, base));
    uint rawIncomingToSource = RawWinnerFor(source, base);
    bool sourceCanReceiveDisplacedDestination =
        rawIncomingToSource == INVALID_INDEX || rawIncomingToSource == IndexOf(destination);
    if (destinationMaterial != MATERIAL_EMPTY && !sourceCanReceiveDisplacedDestination)
        return;

    uint sourceIndex = IndexOf(source);
    uint key = Mix(sourceIndex ^ (Push.tick * 0x9e3779b9u) ^ Push.seed);
    if (bestSource == INVALID_INDEX || key < bestHash || (key == bestHash && sourceIndex < bestSource)) {
        bestSource = sourceIndex;
        bestHash = key;
    }
}

uint WinnerFor(int2 destination, int2 base) {
    uint bestSource = INVALID_INDEX;
    uint bestHash = 0xffffffffu;
    ConsiderCandidate(destination + int2(0, 1), destination, base, bestSource, bestHash);
    ConsiderCandidate(destination + int2(1, 1), destination, base, bestSource, bestHash);
    ConsiderCandidate(destination + int2(-1, 1), destination, base, bestSource, bestHash);
    ConsiderCandidate(destination + int2(-1, 0), destination, base, bestSource, bestHash);
    ConsiderCandidate(destination + int2(1, 0), destination, base, bestSource, bestHash);
    ConsiderCandidate(destination + int2(0, -1), destination, base, bestSource, bestHash);
    return bestSource;
}

bool SourceAccepted(int2 source, int2 base) {
    if (!InBounds(source)) return false;
    uint proposal = ResolveProposal(source, base);
    uint direction = ProposalDirection(proposal);
    if (direction == INTENT_STAY) return false;
    return WinnerFor(IntentTarget(source, direction), base) == IndexOf(source);
}

[numthreads(16, 16, 1)]
void ResolveMain(uint3 groupId : SV_GroupID, uint3 localId : SV_GroupThreadID, uint groupIndex : SV_GroupIndex) {
    uint chunkIndex = NowList[groupId.x];
    int2 base = int2((int)(chunkIndex % Push.chunksX) * 16, (int)(chunkIndex / Push.chunksX) * 16);
    for (uint i = groupIndex; i < RESOLVE_TILE * RESOLVE_TILE; i += 256u) {
        int2 tileCoord = int2((int)(i % RESOLVE_TILE), (int)(i / RESOLVE_TILE));
        int2 coord = base + tileCoord - int2(RESOLVE_HALO, RESOLVE_HALO);
        ResolveCells[i] = SampleCell(coord);
        ResolveIntents[i] = InBounds(coord) ? Intents[IndexOf(coord)] : PackProposal(INTENT_STAY, 0u, 0u);
    }
    GroupMemoryBarrierWithGroupSync();

    int2 coord = base + int2(localId.xy);
    if (!InBounds(coord)) return;
    uint index = IndexOf(coord);
    uint current = ResolveCell(coord, base);
    uint incoming = WinnerFor(coord, base);
    bool leaving = SourceAccepted(coord, base);
    uint output = current;
    uint currentProposal = ResolveProposal(coord, base);
    uint outputMotion = ProposalDirection(currentProposal) == INTENT_STAY ?
        ProposalAcceptedMotion(currentProposal) : ProposalRejectedMotion(currentProposal);
    bool writesMotion = ProposalUsesMotion(currentProposal);

    if (incoming != INVALID_INDEX) {
        int2 source = int2((int)(incoming % Push.paddedWidth), (int)(incoming / Push.paddedWidth));
        uint sourceProposal = ResolveProposal(source, base);
        output = ResolveCell(source, base);
        outputMotion = ProposalAcceptedMotion(sourceProposal);
        writesMotion = writesMotion || ProposalUsesMotion(sourceProposal);
    } else if (leaving) {
        int2 target = IntentTarget(coord, ProposalDirection(currentProposal));
        uint targetCell = ResolveCell(target, base);
        uint targetProposal = ResolveProposal(target, base);
        bool targetLeaving = SourceAccepted(target, base);
        MaterialSpec sourceSpec = MaterialSpecs[MaterialOf(current)];
        MaterialSpec targetSpec = MaterialSpecs[MaterialOf(targetCell)];
        uint sourcePhase = PhaseOf(sourceSpec);
        uint targetPhase = PhaseOf(targetSpec);
        bool powderDisplacesLowerDensity = MobilityOf(sourceSpec) == MOBILITY_POWDER &&
            (targetPhase == PHASE_LIQUID || targetPhase == PHASE_GAS) &&
            sourceSpec.density > targetSpec.density;
        bool gasRises = sourcePhase == PHASE_GAS &&
            (targetPhase == PHASE_LIQUID || MobilityOf(targetSpec) == MOBILITY_POWDER) &&
            sourceSpec.density < targetSpec.density;
        bool liquidFallsThroughGas = sourcePhase == PHASE_LIQUID && targetPhase == PHASE_GAS &&
            sourceSpec.density > targetSpec.density;
        bool displacesStationaryMaterial = (powderDisplacesLowerDensity || gasRises || liquidFallsThroughGas) && !targetLeaving;
        if (displacesStationaryMaterial) {
            output = targetCell;
            outputMotion = ProposalDirection(targetProposal) == INTENT_STAY ?
                ProposalAcceptedMotion(targetProposal) : ProposalRejectedMotion(targetProposal);
            writesMotion = writesMotion || ProposalUsesMotion(targetProposal);
        } else {
            output = MakeCell(MATERIAL_EMPTY, (uint2)coord);
            outputMotion = 0u;
        }
    }

    Scratch[index] = output;
    // IntentMain is the only pass that reads canonical Motion. Resolve can
    // therefore fuse destination-owned Motion commit without a scratch grid.
    // The proposal carries channel participation, avoiding material-table loads
    // and full-grid stores for cells that never own Motion.
    if (writesMotion) WriteMotion(index, outputMotion);
    if (ProposalDirection(currentProposal) != INTENT_STAY || output != current || outputMotion != 0u)
        ActivateNextHalo(coord);
}

uint AtmosphereResolvedCell(int2 coord) {
    if (InBounds(coord)) return Scratch[IndexOf(coord)];
    return MakeCell(MATERIAL_STONE, uint2(0u, 0u));
}

bool IsEvaporationSurface(uint cell, int2 coord) {
    if (MaterialOf(cell) != MATERIAL_WATER) return false;
    uint above = MaterialOf(AtmosphereResolvedCell(coord + int2(0, 1)));
    uint below = MaterialOf(AtmosphereResolvedCell(coord + int2(0, -1)));
    bool supported = below == MATERIAL_WATER || below == MATERIAL_SAND || below == MATERIAL_STONE;
    return above == MATERIAL_EMPTY && supported;
}

uint ApplyAtmosphereTransition(uint cell, int2 coord, uint index) {
    uint material = MaterialOf(cell);
    if (material == MATERIAL_WATER && IsEvaporationSurface(cell, coord)) {
        // Existing behavior fixtures remain isolated; scenario zero is the
        // interactive world and 20+ are atmosphere fixtures. Runtime chance is
        // an integer hash, never scheduler or atomic arrival order.
        bool atmosphereEnabled = Push.testCase == 0u || Push.testCase >= 20u;
        bool forcedFixture = Push.testCase == 20u && all(coord == int2(8, 8));
        uint key = Mix(index ^ (Push.tick * 0x9e3779b9u) ^ Push.seed ^ cell ^ 0xb5297a4du);
        if (atmosphereEnabled && (forcedFixture || (key & EVAPORATION_MASK) == 0u))
            return WithMaterialState(cell, MATERIAL_STEAM, 0u);
    }

    if (material == MATERIAL_STEAM) {
        uint cloudBase = (Push.height * 7u) / 8u;
        if ((uint)coord.y >= cloudBase)
            return WithMaterialState(cell, MATERIAL_CLOUD, 0u);
    }

    if (material == MATERIAL_CLOUD) {
        uint age = CellState(cell);
        uint variant = (cell >> 8u) & 0xffu;
        uint rainAge = 120u + (variant & 0x7fu);
        if (age >= rainAge)
            return WithMaterialState(cell, MATERIAL_WATER, 0u);
        if (((Push.tick + index) & CLOUD_AGE_CADENCE_MASK) == 0u)
            age = min(255u, age + 1u);
        return WithMaterialState(cell, MATERIAL_CLOUD, age);
    }
    return cell;
}

uint RainMotion(uint index) {
    uint key = Mix(index ^ (Push.tick * 0x85ebca6bu) ^ Push.seed ^ 0x6ac690c5u);
    uint side = (key & 1u) == 0u ? INTENT_LEFT : INTENT_RIGHT;
    return MakeMotion(side, 6u);
}

[numthreads(16, 16, 1)]
void CommitMain(uint3 groupId : SV_GroupID, uint3 localId : SV_GroupThreadID) {
    uint chunkIndex = NowList[groupId.x];
    int2 base = int2((int)(chunkIndex % Push.chunksX) * 16, (int)(chunkIndex / Push.chunksX) * 16);
    int2 coord = base + int2(localId.xy);
    if (InBounds(coord)) {
        uint index = IndexOf(coord);
        uint resolved = Scratch[index];
        uint committed = ApplyAtmosphereTransition(resolved, coord, index);
        Cells[index] = committed;
        uint channelResult = Intents[index];
        // With Disturbance disabled, CommitMain is Pressure's commit owner.
        // Otherwise DisturbanceMain already committed Pressure before reusing
        // this proposal word.
        if (PressureEnabled() && !DisturbanceEnabled() && (channelResult & PRESSURE_WRITE) != 0u)
            WritePressure(index, channelResult);
        if (DisturbanceEnabled() && (channelResult & DISTURBANCE_WRITE) != 0u)
            WriteDisturbance(index, channelResult);

        uint resolvedMaterial = MaterialOf(resolved);
        uint committedMaterial = MaterialOf(committed);
        if (committedMaterial != resolvedMaterial) {
            if (resolvedMaterial == MATERIAL_CLOUD && committedMaterial == MATERIAL_WATER) {
                WriteMotion(index, RainMotion(index));
                WriteDisturbance(index, 15u);
            } else {
                WriteMotion(index, 0u);
                WriteDisturbance(index, 0u);
            }
            WritePressure(index, 0u);
        }

        // Time-dependent surface and atmospheric cells keep only their local
        // chunk halo awake. Static interior Water can still sleep normally.
        if (committed != resolved || committedMaterial == MATERIAL_STEAM ||
            committedMaterial == MATERIAL_CLOUD || IsEvaporationSurface(committed, coord))
            ActivateNextHalo(coord);
    }
}

// Movement proposals are dead after ResolveMain, so DisturbanceMain reuses the
// same u32 grid as active-only scratch and reads resolved cells from Scratch.
// One later commit writes both canonical channels.
groupshared uint DisturbanceCells[18u * 18u];

uint SampleResolvedCell(int2 coord) {
    if (InBounds(coord)) return Scratch[IndexOf(coord)];
    return MakeCell(MATERIAL_STONE, uint2(0u, 0u));
}

uint DisturbanceTileIndex(int2 coord, int2 base) {
    int2 tile = coord - (base - int2(1, 1));
    return (uint)tile.y * 18u + (uint)tile.x;
}

bool InDisturbanceTile(int2 coord, int2 base) {
    int2 tile = coord - (base - int2(1, 1));
    return tile.x >= 0 && tile.y >= 0 && tile.x < 18 && tile.y < 18;
}

uint DisturbanceCell(int2 coord, int2 base) {
    if (InDisturbanceTile(coord, base)) return DisturbanceCells[DisturbanceTileIndex(coord, base)];
    return SampleResolvedCell(coord);
}

uint DisturbanceValue(int2 coord) {
    if (!InBounds(coord)) return 0u;
    return ReadDisturbance(IndexOf(coord));
}

bool IsSurfaceWater(int2 coord, int2 base) {
    return MaterialOf(DisturbanceCell(coord, base)) == MATERIAL_WATER &&
        MaterialOf(DisturbanceCell(coord + int2(0, 1), base)) == MATERIAL_EMPTY;
}

bool HasFallingWaterAbove(int2 coord, int2 base) {
    int2 above = coord + int2(0, 1);
    if (MaterialOf(DisturbanceCell(above, base)) != MATERIAL_WATER) return false;
    uint motion = ReadMotion(IndexOf(above));
    uint direction = MotionDirectionOf(motion);
    return MotionStrengthOf(motion) > 0u &&
        (direction == INTENT_DOWN || direction == INTENT_DOWN_LEFT || direction == INTENT_DOWN_RIGHT);
}

uint PressureValue(int2 coord) {
    return InBounds(coord) ? ReadPressure(IndexOf(coord)) : 0u;
}

bool IsResolvedWater(int2 coord, int2 base) {
    return MaterialOf(DisturbanceCell(coord, base)) == MATERIAL_WATER;
}

bool SupportsPressureBelow(int2 coord, int2 base) {
    uint material = MaterialOf(DisturbanceCell(coord, base));
    if (material == MATERIAL_WATER) return true;
    MaterialSpec spec = MaterialSpecs[material];
    return (spec.traits & TRAIT_VALID) != 0u && BlocksPressure(spec);
}

// Pressure is a synchronous body channel: every destination gathers from the
// prior canonical layer and the resolved cell topology, then proposes exactly
// one bounded integer value. No neighbor is ever written by this pass.
[numthreads(16, 16, 1)]
void PressureMain(uint3 groupId : SV_GroupID, uint3 localId : SV_GroupThreadID, uint groupIndex : SV_GroupIndex) {
    uint chunkIndex = NowList[groupId.x];
    int2 base = int2((int)(chunkIndex % Push.chunksX) * 16, (int)(chunkIndex / Push.chunksX) * 16);
    for (uint i = groupIndex; i < 18u * 18u; i += 256u) {
        int2 tileCoord = int2((int)(i % 18u), (int)(i / 18u));
        int2 tileCoordWorld = base + tileCoord - int2(1, 1);
        DisturbanceCells[i] = SampleResolvedCell(tileCoordWorld);
    }
    GroupMemoryBarrierWithGroupSync();

    int2 coord = base + int2(localId.xy);
    if (!InBounds(coord)) return;
    uint index = IndexOf(coord);
    bool resolvedWater = IsResolvedWater(coord, base);
    bool participates = resolvedWater || MaterialOf(Cells[index]) == MATERIAL_WATER;
    uint current = participates ? PressureValue(coord) : 0u;
    uint next = 0u;

    if (resolvedWater) {
        MaterialSpec spec = MaterialSpecs[MATERIAL_WATER];
        uint response = max(1u, PressureResponseOf(spec));
        uint aboveMaterial = MaterialOf(DisturbanceCell(coord + int2(0, 1), base));

        // Empty directly above is a pressure-release surface. Otherwise retain
        // a little prior force, build integer head from Water above, and gather
        // attenuated support from connected neighbors.
        if (aboveMaterial != MATERIAL_EMPTY) {
            next = current > 0u ? current - 1u : 0u;
            if (aboveMaterial == MATERIAL_WATER)
                next = max(next, min(PRESSURE_MASK, PressureValue(coord + int2(0, 1)) + response));
            if (IsResolvedWater(coord + int2(-1, 0), base))
                next = max(next, DecayStrength(PressureValue(coord + int2(-1, 0)), 1u));
            if (IsResolvedWater(coord + int2(1, 0), base))
                next = max(next, DecayStrength(PressureValue(coord + int2(1, 0)), 1u));
            if (IsResolvedWater(coord + int2(0, -1), base))
                next = max(next, DecayStrength(PressureValue(coord + int2(0, -1)), response));
            if (SupportsPressureBelow(coord + int2(0, -1), base))
                next = max(next, response);
        }
    }

    Intents[index] = participates ? (PRESSURE_WRITE | next) : 0u;
    if (participates && next != current) ActivateNextHalo(coord);
}

[numthreads(16, 16, 1)]
void DisturbanceMain(uint3 groupId : SV_GroupID, uint3 localId : SV_GroupThreadID, uint groupIndex : SV_GroupIndex) {
    uint chunkIndex = NowList[groupId.x];
    int2 base = int2((int)(chunkIndex % Push.chunksX) * 16, (int)(chunkIndex / Push.chunksX) * 16);
    for (uint i = groupIndex; i < 18u * 18u; i += 256u) {
        int2 tileCoord = int2((int)(i % 18u), (int)(i / 18u));
        int2 coord = base + tileCoord - int2(1, 1);
        DisturbanceCells[i] = SampleResolvedCell(coord);
    }
    GroupMemoryBarrierWithGroupSync();

    int2 coord = base + int2(localId.xy);
    if (!InBounds(coord)) return;
    uint index = IndexOf(coord);
    uint pressureResult = Intents[index];
    if (PressureEnabled() && (pressureResult & PRESSURE_WRITE) != 0u)
        WritePressure(index, pressureResult);
    uint resolvedMaterial = MaterialOf(DisturbanceCell(coord, base));
    bool participates = resolvedMaterial == MATERIAL_WATER || MaterialOf(Cells[index]) == MATERIAL_WATER;
    uint current = participates ? DisturbanceValue(coord) : 0u;
    uint next = 0u;
    if (IsSurfaceWater(coord, base)) {
        MaterialSpec spec = MaterialSpecs[MATERIAL_WATER];
        uint decay = DisturbanceDecayOf(spec);
        next = DecayStrength(current, decay);

        uint motionStrength = MotionStrengthOf(ReadMotion(index));
        uint response = SurfaceResponseOf(spec);
        if (motionStrength > 0u && response > 0u) {
            uint emission = min(15u, (motionStrength * response + 14u) / 15u);
            next = max(next, emission);
        }
        if (HasFallingWaterAbove(coord, base))
            next = 15u;

        if (IsSurfaceWater(coord + int2(-1, 0), base))
            next = max(next, DecayStrength(DisturbanceValue(coord + int2(-1, 0)), decay));
        if (IsSurfaceWater(coord + int2(1, 0), base))
            next = max(next, DecayStrength(DisturbanceValue(coord + int2(1, 0)), decay));
    }

    Intents[index] = participates ? (DISTURBANCE_WRITE | next) : 0u;
    if (participates && (next != current || next != 0u)) ActivateNextHalo(coord);
}

[numthreads(1, 1, 1)]
void ValidateMain(uint3 dispatchId : SV_DispatchThreadID) {
    TestResult result = (TestResult)0;
    for (uint y = 0u; y < Push.height; ++y) {
        for (uint x = 0u; x < Push.width; ++x) {
            uint cell = Cells[y * Push.paddedWidth + x];
            uint material = MaterialOf(cell);
            if (material == MATERIAL_SAND) result.sandCount++;
            else if (material == MATERIAL_WATER) result.waterCount++;
            else if (material == MATERIAL_STONE) result.stoneCount++;
            else if (material == MATERIAL_STEAM) result.steamCount++;
            else if (material == MATERIAL_CLOUD) result.cloudCount++;
            result.cellHash = Mix(result.cellHash ^ cell ^ (x + y * Push.paddedWidth));
        }
    }
    // Canonical channel order is Cells, Motion, Disturbance, then Pressure.
    // Component hashes make a mismatch diagnosable while stateHash covers all
    // enabled layers without reading the grids back to the host.
    result.stateHash = result.cellHash;
    if (MotionEnabled()) {
        for (uint y = 0u; y < Push.height; ++y) {
            for (uint x = 0u; x < Push.width; ++x) {
                uint index = x + y * Push.paddedWidth;
                uint motion = MotionChannel[index] & MOTION_MASK;
                if (motion != 0u) result.motionHash = Mix(result.motionHash ^ motion ^ index);
                result.stateHash = Mix(result.stateHash ^ motion ^ index ^ 0x6d2b79f5u);
            }
        }
    }
    if (DisturbanceEnabled()) {
        for (uint y = 0u; y < Push.height; ++y) {
            for (uint x = 0u; x < Push.width; ++x) {
                uint index = x + y * Push.paddedWidth;
                uint disturbance = DisturbanceChannel[index] & DISTURBANCE_MASK;
                if (disturbance != 0u) {
                    result.disturbanceHash = Mix(result.disturbanceHash ^ disturbance ^ index);
                    result.disturbedCells++;
                }
                result.stateHash = Mix(result.stateHash ^ disturbance ^ index ^ 0x1b873593u);
            }
        }
    }
    if (PressureEnabled()) {
        for (uint y = 0u; y < Push.height; ++y) {
            for (uint x = 0u; x < Push.width; ++x) {
                uint index = x + y * Push.paddedWidth;
                uint pressure = PressureChannel[index] & PRESSURE_MASK;
                if (pressure != 0u) {
                    result.pressureHash = Mix(result.pressureHash ^ pressure ^ index);
                    result.pressurizedCells++;
                }
                result.stateHash = Mix(result.stateHash ^ pressure ^ index ^ 0x9e3779b9u);
            }
        }
    }
    result.activeCount = NextMeta[0];

    if (Push.testCase == 1u && MaterialOf(Cells[IndexOf(int2(8, 7))]) != MATERIAL_SAND) result.failures |= 1u;
    if (Push.testCase == 2u && MaterialOf(Cells[IndexOf(int2(8, 8))]) != MATERIAL_SAND) result.failures |= 2u;
    if (Push.testCase == 3u) {
        uint sourceIndex = IndexOf(int2(8, 8));
        int expectedX = (Mix(sourceIndex ^ Push.tick ^ Push.seed) & 1u) == 0u ? 7 : 9;
        if (MaterialOf(Cells[IndexOf(int2(expectedX, 7))]) != MATERIAL_SAND) result.failures |= 4u;
    }
    if (Push.testCase == 4u && MaterialOf(Cells[IndexOf(int2(8, 7))]) != MATERIAL_WATER) result.failures |= 8u;
    if (Push.testCase == 5u) {
        uint sourceIndex = IndexOf(int2(8, 8));
        int expectedX = (Mix(sourceIndex ^ Push.tick ^ Push.seed ^ 0xa511e9b3u) & 1u) == 0u ? 7 : 9;
        if (MaterialOf(Cells[IndexOf(int2(expectedX, 8))]) != MATERIAL_WATER) result.failures |= 16u;
    }
    if (Push.testCase == 6u && (MaterialOf(Cells[IndexOf(int2(8, 8))]) != MATERIAL_SAND ||
        MaterialOf(Cells[IndexOf(int2(8, 9))]) != MATERIAL_WATER || result.sandCount != 1u || result.waterCount != 1u))
        result.failures |= 32u;
    if (Push.testCase == 7u && (result.sandCount != 1u || result.waterCount != 1u)) result.failures |= 64u;
    if (Push.testCase == 8u) {
        uint left = IndexOf(int2(7, 9));
        uint right = IndexOf(int2(9, 9));
        uint leftKey = Mix(left ^ (Push.tick * 0x9e3779b9u) ^ Push.seed);
        uint rightKey = Mix(right ^ (Push.tick * 0x9e3779b9u) ^ Push.seed);
        int2 expected = (leftKey < rightKey || (leftKey == rightKey && left < right)) ? int2(7, 9) : int2(9, 9);
        if (result.sandCount != 2u || result.activeCount == 0u || Cells[IndexOf(int2(8, 8))] != MakeCell(MATERIAL_SAND, (uint2)expected)) result.failures |= 128u;
    }
    if (Push.testCase == 9u && (Cells[IndexOf(int2(8, 8))] != MakeCell(MATERIAL_STONE, uint2(8, 8)) || result.stoneCount == 0u)) result.failures |= 256u;
    if (Push.testCase == 10u && result.activeCount != 0u) result.failures |= 512u;
    if (Push.testCase == 11u && (MaterialOf(Cells[IndexOf(int2(15, 15))]) != MATERIAL_SAND || result.activeCount != 4u)) result.failures |= 1024u;
    if (Push.testCase == 13u && Push.paddedWidth > Push.width) {
        uint paddedCell = Cells[Push.paddedWidth + Push.width];
        if (MaterialOf(paddedCell) != MATERIAL_STONE) result.failures |= 4096u;
    }
    if (Push.testCase == 15u && (result.waterCount != 24u || result.motionHash == 0u)) result.failures |= 8192u;
    if (Push.testCase == 16u && (result.sandCount != 30u || result.motionHash == 0u)) result.failures |= 32768u;
    if (Push.testCase == 17u && (result.waterCount != 32u || result.disturbanceHash == 0u || result.disturbedCells <= 2u)) result.failures |= 16384u;
    if (Push.testCase == 18u && (result.waterCount != 260u || result.pressureHash == 0u || result.pressurizedCells < 100u)) result.failures |= 262144u;
    if (Push.testCase == 20u && (result.waterCount != 0u || result.steamCount != 1u ||
        MaterialOf(Cells[IndexOf(int2(8, 8))]) != MATERIAL_STEAM)) result.failures |= 524288u;
    if (Push.testCase == 21u && (result.steamCount != 1u ||
        MaterialOf(Cells[IndexOf(int2(8, 9))]) != MATERIAL_STEAM)) result.failures |= 1048576u;
    if (Push.testCase == 22u && (result.cloudCount != 0u || result.waterCount != 1u ||
        MaterialOf(Cells[IndexOf(int2(9, 8))]) != MATERIAL_WATER)) result.failures |= 2097152u;
    if (Push.testCase == 23u && result.waterCount + result.steamCount + result.cloudCount != 13u)
        result.failures |= 4194304u;
    if (Push.testCase == 24u && (result.sandCount != 1u || result.steamCount != 1u ||
        MaterialOf(Cells[IndexOf(int2(8, 8))]) != MATERIAL_SAND ||
        MaterialOf(Cells[IndexOf(int2(8, 9))]) != MATERIAL_STEAM))
        result.failures |= 8388608u;
    if (Push.testCase == 25u && (result.sandCount != 3u || result.steamCount != 1u ||
        MaterialOf(Cells[IndexOf(int2(8, 8))]) != MATERIAL_SAND ||
        MaterialOf(Cells[IndexOf(int2(8, 9))]) != MATERIAL_SAND ||
        MaterialOf(Cells[IndexOf(int2(8, 10))]) != MATERIAL_SAND ||
        MaterialOf(Cells[IndexOf(int2(8, 12))]) != MATERIAL_STEAM))
        result.failures |= 16777216u;

    uint chunkCount = Push.chunksX * Push.chunksY;
    if (result.activeCount > chunkCount) result.failures |= 65536u;
    uint checkedCount = min(result.activeCount, chunkCount);
    for (uint i = 0u; i < checkedCount; ++i) {
        uint chunk = NextList[i];
        if (chunk >= chunkCount || NextFlags[chunk] != 1u) {
            result.failures |= 131072u;
            continue;
        }
        for (uint j = i + 1u; j < checkedCount; ++j)
            if (NextList[j] == chunk) result.failures |= 131072u;
    }
    Results[0] = result;
}
