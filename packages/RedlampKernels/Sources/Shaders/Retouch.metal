#include "RedlampShaderTypes.h"

// Heal and Clone spots (see RetouchStage.swift), in the pyramid's linear camera RGB at full
// resolution. Clone copies the source circle over the destination. Heal is Poisson image editing
// (Pérez, Gangnet and Blake, 2003): it keeps the source's texture and takes its colour and
// brightness from the destination's rim, solving Laplace's equation for the difference between
// the two inside the circle. On a disc that solution is the Poisson integral of the rim's
// values, so it needs no iterative solver. The difference is a ratio (a difference of logs),
// so texture scales with the light around it as it does in a photo, and can't go negative.

struct RetouchParams {
    int4 box;          // xy origin, zw size of the destination's bounding box, in level-0 texels
    float4 circle;     // xy destination centre, z radius (texels), w where the feather starts (share of the radius)
    float4 source;     // xy source centre (texels), z opacity 0...1, w 1 = heal
    int4 samples;      // x points on the rim
};

constexpr sampler retouchSampler(coord::pixel, address::clamp_to_edge, filter::linear);

// The average over a square of side `side` texels about `at`.
static float3 patchAverage(texture2d<float, access::sample> image, float2 at, float side)
{
    float3 sum = 0.0f;
    for (int y = 0; y < 4; y++) {
        for (int x = 0; x < 4; x++) {
            float2 offset = (float2(x, y) + 0.5f) / 4.0f - 0.5f;
            sum += image.sample(retouchSampler, at + offset * side, level(0)).rgb;
        }
    }
    return sum / 16.0f;
}

// The log ratio of destination to source at each rim point, both averaged over the rim's
// spacing, so the rim's noise doesn't ripple through the circle.
kernel void rl_retouch_rim(
    texture2d<float, access::sample> image [[texture(0)]],
    device float4 *rim [[buffer(1)]],
    constant RetouchParams &p [[buffer(0)]],
    uint gid [[thread_position_in_grid]])
{
    if (int(gid) >= p.samples.x) return;
    float radius = p.circle.z;
    float angle = 2.0f * M_PI_F * (float(gid) + 0.5f) / float(p.samples.x);
    float2 direction = float2(cos(angle), sin(angle)) * radius;
    float side = max(1.0f, 2.0f * M_PI_F * radius / float(p.samples.x));
    float3 destination = patchAverage(image, p.circle.xy + direction, side);
    float3 source = patchAverage(image, p.source.xy + direction, side);
    float3 ratio = log(max(destination, 1e-5f)) - log(max(source, 1e-5f));
    rim[gid] = float4(clamp(ratio, -8.0f, 8.0f), 0.0f);
}

kernel void rl_retouch_apply(
    texture2d<float, access::sample> image [[texture(0)]],
    texture2d<float, access::write> out [[texture(1)]],
    device const float4 *rim [[buffer(1)]],
    constant RetouchParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= p.box.z || int(gid.y) >= p.box.w) return;
    float2 at = float2(p.box.xy) + float2(gid) + 0.5f;
    float4 destination = image.sample(retouchSampler, at, level(0));
    float2 offset = at - p.circle.xy;
    float radius = p.circle.z;
    float distance = length(offset);
    if (distance >= radius) {
        out.write(destination, gid);
        return;
    }
    float alpha = (1.0f - smoothstep(p.circle.w * radius, radius, distance)) * p.source.z;
    float3 replacement = image.sample(retouchSampler, p.source.xy + offset, level(0)).rgb;
    if (p.source.w > 0.5f) {
        // The Poisson kernel, (R² - r²) / |R e - x|², normalised; R² - r² cancels.
        float3 sum = 0.0f;
        float weights = 0.0f;
        for (int i = 0; i < p.samples.x; i++) {
            float angle = 2.0f * M_PI_F * (float(i) + 0.5f) / float(p.samples.x);
            float2 toRim = float2(cos(angle), sin(angle)) * radius - offset;
            float weight = 1.0f / max(dot(toRim, toRim), 1e-4f);
            sum += rim[i].rgb * weight;
            weights += weight;
        }
        replacement *= exp(sum / weights);
    }
    out.write(float4(mix(destination.rgb, replacement, alpha), destination.a), gid);
}
