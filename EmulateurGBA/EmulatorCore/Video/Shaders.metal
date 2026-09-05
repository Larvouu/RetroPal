#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
    float alpha;
};

// Single-screen shader (GBA, GB, GBC, SNES, NES, PS1) — hardcoded fullscreen quad.
//
// `uvScale` is the fraction of the texture the live picture occupies. It is
// (1, 1) for every console whose picture and buffer are the same size, which is
// all of them except the PlayStation: that one allocates its texture at the
// largest resolution it can produce and draws into the top-left corner, because
// a PS1 game changes resolution mid-game and a texture cannot.
//
// Scaling HERE rather than in the fragment shaders is what keeps this change
// small and total: both fragment paths, the plain boot one and the filtered
// one, receive coordinates that are already correct, so neither had to learn
// about it. The filters keep working because `gameSize` is the TEXTURE's size,
// so `uv * gameSize` still lands on the live picture's own pixel grid.
vertex VertexOut vertexShader(uint vid [[vertex_id]],
                              constant float2& uvScale [[buffer(0)]]) {
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
    out.texCoord = texCoords[vid] * uvScale;
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

// Plain nearest fragment — the BOOT pipeline. Trivial on purpose: its
// pipeline state compiles near-instantly, so the first frame never waits on
// the (heavier) filter shader below; EmulatorMetalView builds the filtered
// pipelines asynchronously and swaps them in once ready. The emulator
// textures' own alpha channel is deliberately ignored (the cores fill it
// inconsistently); a quad is opaque unless its vertex alpha says otherwise.
fragment float4 fragmentShader(VertexOut in [[stage_in]],
                                texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(mag_filter::nearest, min_filter::nearest);
    return float4(tex.sample(s, in.texCoord).rgb, in.alpha);
}

// MARK: - Video filters (1.2.4)
//
// One parameterized fragment shared by the LIVE view (both pipelines) and the
// OFFSCREEN share-card renderer (VideoFilterRenderer) — one source of truth,
// so a shared screenshot/clip looks exactly like the screen. All single-pass.
// Effect density derives from screen-space derivatives (fwidth), so the same
// shader is correct at any output size; effects fade out when the scale is too
// small to show them cleanly (no moiré).
//
// The emulator textures' own alpha channel is deliberately ignored (the cores
// fill it inconsistently); a quad is opaque unless its vertex alpha says
// otherwise. With filter none + alpha 1 the output is byte-identical to the
// old plain nearest fragment.

// Mirrors Swift's VideoFilter.metalIndex — keep in sync.
constant uint kFilterNone = 0;
constant uint kFilterScanlines = 1;
constant uint kFilterLCDGrid = 2;
constant uint kFilterDotMatrix = 3;
constant uint kFilterCRT = 4;
constant uint kFilterSmooth = 5;
constant uint kFilterSharp = 6;

// Mirrors Swift's FilterUniforms — keep layouts in sync (16 bytes).
struct FilterUniforms {
    uint filterType;
    uint screenCount;   // 1, or 2 for the stacked NDS texture (per-screen CRT warp)
    // The TEXTURE's pixel size (e.g. 240x160, 256x384, 1024x512), which for
    // every console but the PlayStation is also the live picture's size. Paired
    // with the vertex stage's `uvScale` it always resolves to the live pixel
    // grid: uv is scaled down by the same factor gameSize is scaled up.
    float2 gameSize;
    // The fraction of the texture the live picture occupies — the same value the
    // vertex stage multiplies its texture coordinates by. Only the CRT filter
    // reads it, and only because that one has to normalise uv into -1...1.
    float2 uvScale;
};

// Sharp-bilinear: nearest-neighbour blockiness with a sub-display-pixel linear
// ramp at texel edges — anti-aliased pixels at non-integer scales, no blur.
static float3 sampleSharp(texture2d<float> tex, float2 uv, float2 gameSize) {
    constexpr sampler lin(mag_filter::linear, min_filter::linear);
    float2 p = uv * gameSize;
    float2 scale = max(float2(1.0), 1.0 / max(fwidth(p), float2(1e-6)));
    float2 f = fract(p);
    float2 c = clamp((f - 0.5) * scale + 0.5, 0.0, 1.0);
    float2 snapped = (floor(p) + c) / gameSize;
    return tex.sample(lin, snapped).rgb;
}

// Row-shadow factor for scanline-style filters: darkens between game rows,
// fading out below ~4 display px per row so shrunken output never moirés.
static float scanlineShade(float py, float strength) {
    float density = 1.0 / max(fwidth(py), 1e-6);       // display px per game row
    float fade = clamp((density - 2.0) * 0.5, 0.0, 1.0);
    float d = abs(fract(py) - 0.5) * 2.0;              // 0 row centre → 1 row edge
    return 1.0 - strength * fade * smoothstep(0.55, 1.0, d);
}

fragment float4 filteredFragment(VertexOut in [[stage_in]],
                                 texture2d<float> tex [[texture(0)]],
                                 constant FilterUniforms& u [[buffer(0)]]) {
    constexpr sampler near(mag_filter::nearest, min_filter::nearest);
    constexpr sampler lin(mag_filter::linear, min_filter::linear);
    float2 uv = in.texCoord;
    float3 rgb;

    switch (u.filterType) {
    case kFilterSmooth:
        rgb = tex.sample(lin, uv).rgb;
        break;

    case kFilterSharp:
        rgb = sampleSharp(tex, uv, u.gameSize);
        break;

    case kFilterScanlines: {
        rgb = tex.sample(near, uv).rgb;
        rgb *= scanlineShade(uv.y * u.gameSize.y, 0.35);
        rgb *= 1.06;                                    // brightness compensation
        break;
    }

    case kFilterLCDGrid: {
        // Thin dark lattice on every game-pixel boundary — the handheld LCD look.
        rgb = tex.sample(near, uv).rgb;
        float2 p = uv * u.gameSize;
        float2 d = abs(fract(p) - 0.5) * 2.0;
        float2 density = 1.0 / max(fwidth(p), float2(1e-6));
        // The grid band is ~1 display pixel wide whatever the zoom.
        float2 band = 1.0 - 1.0 / max(density, float2(2.0));
        float g = 1.0;
        g *= 1.0 - 0.4 * smoothstep(band.x, 1.0, d.x);
        g *= 1.0 - 0.4 * smoothstep(band.y, 1.0, d.y);
        float fade = clamp((min(density.x, density.y) - 2.0) * 0.5, 0.0, 1.0);
        rgb *= mix(1.0, g, fade);
        rgb *= 1.04;
        break;
    }

    case kFilterDotMatrix: {
        // Rounded-square dots with a soft gap — the dot-matrix cell look.
        rgb = tex.sample(near, uv).rgb;
        float2 p = uv * u.gameSize;
        float2 f = abs(fract(p) - 0.5) * 2.0;
        float2 f4 = f * f; f4 = f4 * f4;                // f^4: squircle distance
        float d = length(f4);
        float2 density = 1.0 / max(fwidth(p), float2(1e-6));
        float fade = clamp((min(density.x, density.y) - 3.0) * 0.5, 0.0, 1.0);
        float cell = 1.0 - 0.45 * smoothstep(0.6, 1.15, d);
        rgb *= mix(1.0, cell, fade);
        rgb *= 1.05;
        break;
    }

    case kFilterCRT: {
        // Mild per-screen barrel warp (texture space, so each stacked NDS
        // screen curves on its own) + scanlines + an aperture-style vertical
        // triad mask at display-pixel scale + a corner vignette.
        // NORMALISE INTO THE LIVE PICTURE FIRST. `uv` arrives already scaled by
        // `uvScale`, so on the PlayStation — the one console that draws into a
        // corner of a larger texture — it never reaches 1, and `uv * 2 - 1` put
        // the warp's own centre outside the picture entirely. That is the
        // mispositioning seen in game and not on the share cards, which crop the
        // frame before filtering it and so hand this a full 0...1. Every other
        // console passes (1, 1) and is untouched by the division.
        float2 span = max(u.uvScale, float2(1e-6));
        float2 n = uv / span;
        float sc = float(u.screenCount);
        float screenIdx = clamp(floor(n.y * sc), 0.0, sc - 1.0);
        float2 local = float2(n.x, n.y * sc - screenIdx) * 2.0 - 1.0;
        float r2 = dot(local, local);
        // NORMALISED BY THE CORNER'S OWN WARP, so the corner still lands on the
        // corner. Without the divisor the warp pushes the outer edge past the
        // texture, that band falls through the guard below and renders BLACK,
        // and the picture reads as having shrunk and moved inside its own frame
        // the moment this filter is switched on — reported from a device, and it
        // cost the outer 3.4% of every edge. The curve itself is unchanged: the
        // centre is still magnified relative to the rim, which is the whole
        // point of a barrel.
        const float warp = 0.035;
        local *= (1.0 + warp * r2) / (1.0 + warp * 2.0);
        // Cannot fire now (the corner maps to exactly 1.0 and every other point
        // falls inside), and kept as the guard it always was.
        if (any(abs(local) > float2(1.0))) return float4(0.0, 0.0, 0.0, in.alpha);
        float2 warped = (local + 1.0) * 0.5;
        // ...and back out through the same fraction it came in by.
        uv = float2(warped.x, (screenIdx + warped.y) / sc) * span;

        rgb = sampleSharp(tex, uv, u.gameSize);
        rgb *= scanlineShade(uv.y * u.gameSize.y, 0.30);

        int col = int(in.position.x) % 3;               // display-pixel triads
        float3 mask = float3(0.92);
        mask[col] = 1.08;
        rgb *= mask;

        rgb *= 1.0 - 0.18 * r2;                         // corner vignette
        rgb *= 1.10;                                    // brightness compensation
        break;
    }

    default:
        rgb = tex.sample(near, uv).rgb;
        break;
    }
    return float4(rgb, in.alpha);
}
