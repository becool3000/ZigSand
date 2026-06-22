struct RenderPush {
    uint width;
    uint height;
    uint paddedWidth;
    uint viewportWidth;
    uint viewportHeight;
    uint seed;
    uint reserved0;
    uint reserved1;
};

[[vk::push_constant]] ConstantBuffer<RenderPush> Push;
[[vk::binding(0, 0)]] StructuredBuffer<uint> Cells;

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
    return float3(0.008, 0.010, 0.014);
}

float4 FragmentMain(float4 position : SV_Position) : SV_Target0 {
    float scale = min((float)Push.viewportWidth / (float)Push.width, (float)Push.viewportHeight / (float)Push.height);
    float2 drawSize = float2((float)Push.width, (float)Push.height) * scale;
    float2 offset = (float2((float)Push.viewportWidth, (float)Push.viewportHeight) - drawSize) * 0.5;
    float2 local = position.xy - offset;
    if (local.x < 0.0 || local.y < 0.0 || local.x >= drawSize.x || local.y >= drawSize.y)
        return float4(0.002, 0.003, 0.005, 1.0);
    uint2 coord;
    coord.x = min((uint)(local.x / scale), Push.width - 1u);
    coord.y = Push.height - 1u - min((uint)(local.y / scale), Push.height - 1u);
    uint cell = Cells[coord.y * Push.paddedWidth + coord.x];
    return float4(Palette(cell), 1.0);
}

