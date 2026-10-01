#include "RedlampShaderTypes.h"

// The light halation and bloom spread, per session: the pyramid's highlights at reduced
// resolution. Scattered light only shows around bright light, so only highlights are kept,
// fading in from `threshold`. Those near the sensor's clip point get back the energy clipping took:
// film records a street light many stops above mid-grey and glows with all of it, where a sensor
// stops at its clip point.

struct GlowParams {
    int4 size;                // xy map size, z pyramid level read (two by two texels per map texel), w 1 = small lights only
    float4 shape;             // x gain at the clip point, y threshold start, z threshold end, w clip knee start (pyramid units)
};

kernel void rl_glow_source(
    texture2d<float, access::read> pyramid [[texture(0)]],
    texture2d<float, access::write> out [[texture(1)]],
    constant GlowParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= p.size.x || int(gid.y) >= p.size.y) return;
    uint level = uint(p.size.z);
    uint2 levelSize = uint2(max(pyramid.get_width(level), 1u), max(pyramid.get_height(level), 1u));
    float3 sum = 0.0f;
    for (uint y = 0; y < 2; y++) {
        for (uint x = 0; x < 2; x++) {
            uint2 at = min(gid * 2 + uint2(x, y), levelSize - 1);
            float3 v = max(pyramid.read(at, level).rgb, 0.0f);
            float peak = max3(v.r, v.g, v.b);
            float clipped = smoothstep(p.shape.w, 1.0f, peak);
            // Small lights only: a clipped sky or window is bright all around, and clipping cost
            // it far less than a lamp, so its surroundings (32 times coarser) withhold the boost.
            if (p.size.w == 1) {
                uint coarse = min(level + 5, pyramid.get_num_mip_levels() - 1);
                uint2 coarseSize = uint2(max(pyramid.get_width(coarse), 1u), max(pyramid.get_height(coarse), 1u));
                float3 around = pyramid.read(min(at >> (coarse - level), coarseSize - 1), coarse).rgb;
                clipped *= 1.0f - smoothstep(0.2f, 0.6f, max3(around.r, around.g, around.b));
            }
            float gain = smoothstep(p.shape.y, p.shape.z, peak) * mix(1.0f, p.shape.x, clipped);
            sum += v * gain;
        }
    }
    out.write(float4(sum * 0.25f, 1.0f), gid);
}
