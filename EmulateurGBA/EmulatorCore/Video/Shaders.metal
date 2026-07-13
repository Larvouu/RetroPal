#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
    float alpha;
};

// Single-screen shader (GBA, GB, GBC) — hardcoded fullscreen quad
vertex VertexOut vertexShader(uint vid [[vertex_id]]) {
    float2 positions[6] = {
        float2(-1, -1), float2(1, -1), float2(-1, 1),
        float2(-1,  1), float2(1, -1), float2( 1, 1)
    };
    float2 texCoords[6] = {
        float2(0, 1), float2(1, 1), float2(0, 0),
        float2(0, 0), float2(1, 1), float2(1, 0)
    };
    VertexOut out;
    out.position = float4(positions[vid], 0, 1);
    out.texCoord = texCoords[vid];
    out.alpha = 1.0;
    return out;
}

// Dual-screen shader (NDS) — vertex buffer with position + texcoord + alpha per
// vertex. Alpha carries a preset's per-screen opacity (1.0 on the default path).
// packed_float2 keeps the struct stride at 20 bytes, matching the Swift-side
// five-Float vertex struct exactly (a plain float2 would pad the stride to 24).
struct NDSVertexIn {
    packed_float2 position;
    packed_float2 texCoord;
    float alpha;
};

vertex VertexOut ndsVertexShader(uint vid [[vertex_id]],
                                 const device NDSVertexIn* vertices [[buffer(0)]]) {
    VertexOut out;
    out.position = float4(float2(vertices[vid].position), 0, 1);
    out.texCoord = float2(vertices[vid].texCoord);
    out.alpha = vertices[vid].alpha;
    return out;
}

// The emulator textures' own alpha channel is deliberately ignored (the cores
// fill it inconsistently); a quad is opaque unless its vertex alpha says
// otherwise. With alpha == 1, the blended NDS pipeline's output is identical to
// the old non-blended one.
fragment float4 fragmentShader(VertexOut in [[stage_in]],
                                texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(mag_filter::nearest, min_filter::nearest);
    return float4(tex.sample(s, in.texCoord).rgb, in.alpha);
}
