#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
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
    return out;
}

// Dual-screen shader (NDS) — vertex buffer with position + texcoord per vertex
struct NDSVertexIn {
    float2 position;
    float2 texCoord;
};

vertex VertexOut ndsVertexShader(uint vid [[vertex_id]],
                                 const device NDSVertexIn* vertices [[buffer(0)]]) {
    VertexOut out;
    out.position = float4(vertices[vid].position, 0, 1);
    out.texCoord = vertices[vid].texCoord;
    return out;
}

fragment float4 fragmentShader(VertexOut in [[stage_in]],
                                texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(mag_filter::nearest, min_filter::nearest);
    return tex.sample(s, in.texCoord);
}
