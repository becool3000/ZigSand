struct RenderPush {
    uint width;
    uint height;
    uint paddedWidth;
    uint viewportWidth;
    uint viewportHeight;
    uint seed;
    uint viewMode;
    uint channelFlags;
    float cameraCenterX;
    float cameraCenterY;
    float zoom;
    uint reserved2;
};

static const uint CHANNEL_MOTION = 1u;
static const uint CHANNEL_DISTURBANCE = 1u << 1u;
static const uint CHANNEL_PRESSURE = 1u << 2u;

[[vk::push_constant]] ConstantBuffer<RenderPush> Push;
[[vk::binding(0, 0)]] StructuredBuffer<uint> Cells;
[[vk::binding(1, 0)]] StructuredBuffer<uint> MotionChannel;
[[vk::binding(2, 0)]] StructuredBuffer<uint> DisturbanceChannel;
[[vk::binding(3, 0)]] StructuredBuffer<uint> PressureChannel;

struct VertexOutput {
    float4 position : SV_Position;
};

VertexOutput VertexMain(uint vertexId : SV_VertexID) {
    VertexOutput output;
    float2 position = float2((vertexId << 1) & 2, vertexId & 2);
    output.position = float4(position * 2.0 - 1.0, 0.0, 1.0);
    return output;
}

float3 Palette(uint cell) {
    uint material = cell & 0xffu;
    float variation = (float)((cell >> 8u) & 0xffu) / 255.0;
    if (material == 1u) return lerp(float3(0.72, 0.48, 0.16), float3(1.0, 0.82, 0.35), variation);
    if (material == 2u) return lerp(float3(0.02, 0.20, 0.55), float3(0.12, 0.52, 0.95), variation);
    if (material == 3u) return lerp(float3(0.22, 0.23, 0.25), float3(0.48, 0.50, 0.53), variation);
    if (material == 4u) return lerp(float3(0.30, 0.48, 0.62), float3(0.68, 0.88, 0.94), variation);
    if (material == 5u) {
        float age = (float)((cell >> 16u) & 0xffu) / 255.0;
        return lerp(float3(0.46, 0.52, 0.62), float3(0.96, 0.98, 1.0), saturate(variation * 0.45 + age * 0.55));
    }
    return float3(0.008, 0.010, 0.014);
}

float3 MotionPalette(uint value, uint cell) {
    uint direction = value & 0x7u;
    float strength = (float)((value >> 3u) & 0xfu) / 15.0;
    if (strength <= 0.0) return Palette(cell) * 0.12;
    float3 color = float3(0.3, 0.7, 1.0);
    if (direction == 1u) color = float3(0.15, 0.35, 1.0);
    else if (direction == 2u) color = float3(0.15, 0.75, 1.0);
    else if (direction == 3u) color = float3(0.65, 0.35, 1.0);
    else if (direction == 4u) color = float3(0.0, 1.0, 0.8);
    else if (direction == 5u) color = float3(1.0, 0.55, 0.05);
    else if (direction == 6u) color = float3(0.35, 1.0, 0.15);
    else if (direction == 7u) color = float3(1.0, 0.15, 0.45);
    return color * (0.2 + strength * 0.8);
}

float3 DisturbancePalette(uint value, uint cell) {
    float energy = (float)(value & 0xfu) / 15.0;
    if (energy <= 0.0) return Palette(cell) * 0.12;
    float3 low = float3(0.1, 0.15, 0.8);
    float3 high = float3(1.0, 0.2, 0.75);
    return lerp(low, high, energy);
}

float3 PressurePalette(uint value, uint cell) {
    float pressure = (float)(value & 0xffu) / 255.0;
    if (pressure <= 0.0) return Palette(cell) * 0.12;
    float3 cold = float3(0.02, 0.15, 0.75);
    float3 middle = float3(0.0, 0.95, 0.85);
    float3 hot = float3(1.0, 0.15, 0.03);
    return pressure < 0.5 ? lerp(cold, middle, pressure * 2.0) :
        lerp(middle, hot, (pressure - 0.5) * 2.0);
}

bool EmptyAt(int2 coord) {
    if (coord.x < 0 || coord.y < 0 || coord.x >= (int)Push.width || coord.y >= (int)Push.height)
        return false;
    uint index = (uint)coord.y * Push.paddedWidth + (uint)coord.x;
    return (Cells[index] & 0xffu) == 0u;
}

bool MotionEnabled() { return (Push.channelFlags & CHANNEL_MOTION) != 0u; }
bool DisturbanceEnabled() { return (Push.channelFlags & CHANNEL_DISTURBANCE) != 0u; }
bool PressureEnabled() { return (Push.channelFlags & CHANNEL_PRESSURE) != 0u; }

float3 DirectionalFoamTint(uint direction) {
    // All directions remain recognizably foam-white, with a small hue shift
    // that preserves the useful information from the Motion debug view.
    if (direction == 1u) return float3(0.82, 0.94, 1.00); // down: ice
    if (direction == 2u) return float3(0.72, 1.00, 0.90); // down-left: seafoam
    if (direction == 3u) return float3(0.91, 0.84, 1.00); // down-right: lavender
    if (direction == 4u) return float3(0.76, 1.00, 0.97); // left: aqua
    if (direction == 5u) return float3(1.00, 0.92, 0.78); // right: pearl
    return float3(0.90, 0.96, 1.00);
}

float3 WaterWithMotionFoam(uint cell, uint motion, uint2 coord) {
    float3 water = Palette(cell);
    if ((cell & 0xffu) != 2u) return water;

    uint strengthBits = (motion >> 3u) & 0xfu;
    if (strengthBits == 0u) return water;

    int2 signedCoord = int2(coord);
    bool openBoundary = EmptyAt(signedCoord + int2(0, 1)) ||
        EmptyAt(signedCoord + int2(-1, 0)) || EmptyAt(signedCoord + int2(1, 0)) ||
        EmptyAt(signedCoord + int2(0, -1));
    float edge = openBoundary ? 1.0 : 0.0;
    float strength = (float)strengthBits / 15.0;

    // Stable per-cell grain keeps the highlight broken into foam rather than
    // turning every moving Water cell into a flat white slab. Interior motion
    // receives only a faint tint; exposed moving boundaries receive the crest.
    uint variant = (cell >> 8u) & 0xffu;
    uint grainBits = (variant * 73u + coord.x * 17u + coord.y * 29u + Push.seed) & 0xffu;
    float grain = (float)grainBits / 255.0;
    float coverage = saturate(strength * 0.65 + edge * 0.55 - grain * 0.55);
    float foamAmount = coverage * lerp(0.12, 0.88, edge);
    return lerp(water, DirectionalFoamTint(motion & 0x7u), foamAmount);
}

float4 FragmentMain(float4 position : SV_Position) : SV_Target0 {
    float zoom = max(Push.zoom, 1.0);
    float2 viewWorldSize = float2((float)Push.width, (float)Push.height) / zoom;
    float scale = min((float)Push.viewportWidth / viewWorldSize.x, (float)Push.viewportHeight / viewWorldSize.y);
    float2 drawSize = viewWorldSize * scale;
    float2 offset = (float2((float)Push.viewportWidth, (float)Push.viewportHeight) - drawSize) * 0.5;
    float2 local = position.xy - offset;
    if (local.x < 0.0 || local.y < 0.0 || local.x >= drawSize.x || local.y >= drawSize.y)
        return float4(0.002, 0.003, 0.005, 1.0);
    float2 viewMin = float2(Push.cameraCenterX, Push.cameraCenterY) - viewWorldSize * 0.5;
    float worldX = viewMin.x + local.x / scale;
    float worldY = viewMin.y + viewWorldSize.y - local.y / scale - 0.0001;
    if (worldX < 0.0 || worldY < 0.0 || worldX >= (float)Push.width || worldY >= (float)Push.height)
        return float4(0.002, 0.003, 0.005, 1.0);
    uint2 coord;
    coord.x = min((uint)worldX, Push.width - 1u);
    coord.y = min((uint)worldY, Push.height - 1u);
    uint index = coord.y * Push.paddedWidth + coord.x;
    uint cell = Cells[index];
    uint motion = 0u;
    uint disturbance = 0u;
    uint pressure = 0u;
    if (MotionEnabled()) motion = MotionChannel[index];
    if (DisturbanceEnabled()) disturbance = DisturbanceChannel[index];
    if (PressureEnabled()) pressure = PressureChannel[index];

    float3 color = WaterWithMotionFoam(cell, motion, coord);
    if (Push.viewMode == 1u) color = MotionPalette(motion, cell);
    else if (Push.viewMode == 2u) color = DisturbancePalette(disturbance, cell);
    else if (Push.viewMode == 3u) color = PressurePalette(pressure, cell);
    return float4(color, 1.0);
}
