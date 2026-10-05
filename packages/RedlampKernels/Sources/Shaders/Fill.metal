#include "RedlampShaderTypes.h"

// Content-aware fill for Remove spots (see ContentAwareFill.swift). Exemplar-based inpainting
// (Criminisi, Pérez and Toyama, 2004) copies whole patches into the hole one at a time; this
// kernel scores every candidate source patch against the patch being filled, over the pixels
// already known, so the search is exhaustive rather than PatchMatch's randomised one.

struct FillCostParams {
    int4 size;        // xy working region size, z patch half-size, w candidate stride
    int4 target;      // xy centre of the patch being filled
    int4 candidates;  // xy first candidate centre, zw candidates across and down
};

kernel void rl_fill_costs(
    device const float4 *image [[buffer(1)]],
    device const uchar *known [[buffer(2)]],
    device const uchar *sourceOK [[buffer(3)]],
    device float *costs [[buffer(4)]],
    constant FillCostParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= p.candidates.z || int(gid.y) >= p.candidates.w) return;
    int width = p.size.x, height = p.size.y, reach = p.size.z;
    int2 q = p.candidates.xy + int2(gid) * p.size.w;
    int index = int(gid.y) * p.candidates.z + int(gid.x);
    if (!sourceOK[q.y * width + q.x]) {
        costs[index] = INFINITY;
        return;
    }
    float sum = 0.0f;
    for (int dy = -reach; dy <= reach; dy++) {
        for (int dx = -reach; dx <= reach; dx++) {
            int2 t = p.target.xy + int2(dx, dy);
            if (t.x < 0 || t.y < 0 || t.x >= width || t.y >= height) continue;
            if (!known[t.y * width + t.x]) continue;
            float3 d = image[t.y * width + t.x].rgb - image[(q.y + dy) * width + q.x + dx].rgb;
            sum += dot(d, d);
        }
    }
    costs[index] = sum;
}

struct FillRenderParams {
    int4 box;       // xy origin, zw size of the area rendered, in level-0 texels
    int4 offsets;   // xy origin of the offset map in level-0 texels, zw its size
    float4 scale;   // x level-0 texels per offset-map texel
};

// The fill at full resolution: each texel copies from where the patches covering it at the working
// level came from (the offset map holds those moves in level-0 texels), the four nearest cells'
// copies weighed bilinearly, so neighbouring patches meet softly rather than in steps.
kernel void rl_fill_render(
    texture2d<float, access::sample> image [[texture(0)]],
    texture2d<float, access::read> offsets [[texture(1)]],
    texture2d<float, access::write> out [[texture(2)]],
    constant FillRenderParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= p.box.z || int(gid.y) >= p.box.w) return;
    constexpr sampler pixels(coord::pixel, address::clamp_to_edge, filter::linear);
    float2 at = float2(p.box.xy) + float2(gid) + 0.5f;
    float2 cell = (at - float2(p.offsets.xy)) / p.scale.x - 0.5f;
    int2 first = int2(floor(cell));
    float2 t = cell - float2(first);
    float4 sum = 0.0f;
    for (int j = 0; j < 2; j++) {
        for (int i = 0; i < 2; i++) {
            int2 c = clamp(first + int2(i, j), int2(0), p.offsets.zw - 1);
            float weight = (i == 0 ? 1.0f - t.x : t.x) * (j == 0 ? 1.0f - t.y : t.y);
            float2 move = offsets.read(uint2(c)).xy;
            sum += weight * image.sample(pixels, at + move, level(0));
        }
    }
    out.write(sum, gid);
}

struct FillStoredParams {
    int4 box;       // xy origin, zw size of the area rendered, in level-0 texels
    int4 fill;      // xy origin, zw size of the stored fill, in level-0 texels
    float4 noiseA;  // the photo's noise: variance a · value + b per channel, in pyramid units
    float4 noiseB;
    float4 peak;    // x: the stored values' scale (value = stored² · peak); y: the spot's seed
};

static inline float fillHash(uint2 p, uint salt) {
    uint h = p.x * 0x8da6b343u ^ p.y * 0xd8163841u ^ salt * 0xcb1ab31fu;
    h ^= h >> 15; h *= 0x2c1b3c6du; h ^= h >> 12; h *= 0x297a2d39u; h ^= h >> 15;
    return (float(h >> 8) + 0.5f) / 16777216.0f;
}

// A generative fill kept with the edit (RM-10), at full resolution: the stored fill sampled
// bilinearly over its box, with noise the photo's own noise model gives its values (the fill comes
// out cleaner than the sensor), and the photo as it is outside the box.
kernel void rl_fill_stored(
    texture2d<float, access::read> image [[texture(0)]],
    texture2d<float, access::sample> stored [[texture(1)]],
    texture2d<float, access::write> out [[texture(2)]],
    constant FillStoredParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= p.box.z || int(gid.y) >= p.box.w) return;
    int2 at = p.box.xy + int2(gid);
    float2 uv = (float2(at - p.fill.xy) + 0.5f) / float2(p.fill.zw);
    if (any(uv < 0.0f) || any(uv > 1.0f)) {
        out.write(image.read(uint2(at)), gid);
        return;
    }
    constexpr sampler bilinear(coord::normalized, address::clamp_to_edge, filter::linear);
    float3 encoded = stored.sample(bilinear, uv).rgb;
    float3 value = encoded * encoded * p.peak.x;
    uint salt = as_type<uint>(p.peak.y);
    float r1 = sqrt(-2.0f * log(fillHash(uint2(at), salt))), a1 = 6.2831853f * fillHash(uint2(at), salt + 1u);
    float r2 = sqrt(-2.0f * log(fillHash(uint2(at), salt + 2u))), a2 = 6.2831853f * fillHash(uint2(at), salt + 3u);
    float3 gaussian = float3(r1 * cos(a1), r1 * sin(a1), r2 * cos(a2));
    float3 deviation = sqrt(max(p.noiseA.xyz * value + p.noiseB.xyz, 0.0f));
    out.write(float4(max(value + deviation * gaussian, 0.0f), 1.0f), gid);
}
