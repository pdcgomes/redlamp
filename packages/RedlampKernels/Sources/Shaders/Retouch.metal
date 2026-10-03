#include "RedlampShaderTypes.h"

// Heal and Clone spots (see RetouchStage.swift), in the pyramid's linear camera RGB at full
// resolution. Clone copies the source shape over the destination. Heal is Poisson image editing
// (Pérez, Gangnet and Blake, 2003): it keeps the source's texture and takes its colour and
// brightness from the destination's rim, solving Laplace's equation for the difference between
// the two inside the spot. On a disc that solution is the Poisson integral of the rim's values,
// so it needs no iterative solver; a brushed spot's outline is weighed the same way. The
// difference is a ratio (a difference of logs), so texture scales with the light around it as
// it does in a photo, and can't go negative.

struct RetouchParams {
    int4 box;          // xy origin, zw size of the destination's bounding box, in level-0 texels
    float4 shape;      // x radius (texels), y where the feather starts (share of the radius), z rim spacing (texels), w the rim's median reach (texels)
    float4 source;     // xy from the destination to the source (texels), or the fill's origin; z opacity 0...1, w 1 = heal
    int4 counts;       // x points on the rim, y points on the stroke (1 for a circle), z 1 = from the fill texture (Remove), w 1 = the region's alpha texture
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

// How far `at` is from the stroke (from the point, for a circle).
static float strokeDistance(float2 at, device const float2 *stroke, int count)
{
    float nearest = length(at - stroke[0]);
    for (int i = 1; i < count; i++) {
        float2 a = stroke[i - 1], b = stroke[i];
        float2 ab = b - a;
        float t = clamp(dot(at - a, ab) / max(dot(ab, ab), 1e-6f), 0.0f, 1.0f);
        nearest = min(nearest, length(at - (a + ab * t)));
    }
    return nearest;
}

// The log ratio of destination to source at each rim point, both averaged over the rim's
// spacing, so the rim's noise doesn't ripple through the spot.
kernel void rl_retouch_rim(
    texture2d<float, access::sample> image [[texture(0)]],
    texture2d<float, access::sample> fill [[texture(2)]],
    device float4 *ratios [[buffer(1)]],
    device const float2 *rim [[buffer(2)]],
    constant RetouchParams &p [[buffer(0)]],
    uint gid [[thread_position_in_grid]])
{
    if (int(gid) >= p.counts.x) return;
    float side = max(1.0f, p.shape.z);
    float3 destination = patchAverage(image, rim[gid], side);
    float3 source = p.counts.z == 1 ? patchAverage(fill, rim[gid] - p.source.xy, side)
        : patchAverage(image, rim[gid] + p.source.xy, side);
    float3 ratio = log(max(destination, 1e-5f)) - log(max(source, 1e-5f));
    ratios[gid] = float4(clamp(ratio, -8.0f, 8.0f), 0.0f);
}

// Each rim point's ratio, replaced by the median of its neighbours' within `shape.w` (by their
// sum over the channels): a twig or wire crossing the rim is a few dark points among many, and
// would otherwise bleed into the spot. A smooth change along the rim passes through.
kernel void rl_retouch_rim_median(
    device const float4 *ratios [[buffer(1)]],
    device const float2 *rim [[buffer(2)]],
    device float4 *filtered [[buffer(4)]],
    constant RetouchParams &p [[buffer(0)]],
    uint gid [[thread_position_in_grid]])
{
    if (int(gid) >= p.counts.x) return;
    constexpr int capacity = 63;
    float keys[capacity];
    int indices[capacity];
    int count = 0;
    float reach2 = p.shape.w * p.shape.w;
    for (int j = 0; j < p.counts.x && count < capacity; j++) {
        float2 d = rim[j] - rim[gid];
        if (dot(d, d) > reach2) continue;
        float key = ratios[j].r + ratios[j].g + ratios[j].b;
        int at = count++;
        while (at > 0 && keys[at - 1] > key) {
            keys[at] = keys[at - 1];
            indices[at] = indices[at - 1];
            at--;
        }
        keys[at] = key;
        indices[at] = j;
    }
    filtered[gid] = count > 0 ? ratios[indices[count / 2]] : ratios[gid];
}

kernel void rl_retouch_apply(
    texture2d<float, access::sample> image [[texture(0)]],
    texture2d<float, access::write> out [[texture(1)]],
    texture2d<float, access::sample> fill [[texture(2)]],
    texture2d<float, access::sample> region [[texture(3)]],
    device const float4 *ratios [[buffer(1)]],
    device const float2 *rim [[buffer(2)]],
    device const float2 *stroke [[buffer(3)]],
    constant RetouchParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= p.box.z || int(gid.y) >= p.box.w) return;
    float2 at = float2(p.box.xy) + float2(gid) + 0.5f;
    float4 destination = image.sample(retouchSampler, at, level(0));
    float radius = p.shape.x;
    float alpha;
    if (p.counts.w == 1) {
        constexpr sampler normalized(coord::normalized, address::clamp_to_edge, filter::linear);
        alpha = region.sample(normalized, (float2(gid) + 0.5f) / float2(p.box.zw)).r;
    } else {
        float distance = strokeDistance(at, stroke, p.counts.y);
        alpha = distance >= radius ? 0.0f : 1.0f - smoothstep(p.shape.y * radius, radius, distance);
    }
    if (alpha <= 0.0f) {
        out.write(destination, gid);
        return;
    }
    alpha *= p.source.z;
    float3 replacement = p.counts.z == 1 ? fill.sample(retouchSampler, at - p.source.xy, level(0)).rgb
        : image.sample(retouchSampler, at + p.source.xy, level(0)).rgb;
    if (p.source.w > 0.5f) {
        // Each rim point weighs 1 / d²: on a disc that is the Poisson kernel, (R² - r²) / |R e - x|²
        // normalised, since R² - r² cancels; along a stroke's straight sides, the half-plane's.
        float3 sum = 0.0f;
        float weights = 0.0f;
        for (int i = 0; i < p.counts.x; i++) {
            float2 toRim = rim[i] - at;
            float weight = 1.0f / max(dot(toRim, toRim), 1e-4f);
            sum += ratios[i].rgb * weight;
            weights += weight;
        }
        replacement *= exp(sum / weights);
    }
    out.write(float4(mix(destination.rgb, replacement, alpha), destination.a), gid);
}
