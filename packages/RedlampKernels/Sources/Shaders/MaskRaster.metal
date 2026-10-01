#include "Masks.h"

// Brush and AI mask rasters: coverage in mask space (the oriented frame), one slice per component.
//
// A brush stroke is drawn in two steps. `rl_mask_stroke` keeps, per pixel, the strongest dab
// weight of a run of segments in a scratch slice; `rl_mask_stroke_apply` then composites the
// stroke into its component's slice once and clears the scratch, so a stroke's own overlapping
// dabs never build up, while separate strokes do (by Flow, up to Density).

kernel void rl_mask_clear(
    texture2d_array<float, access::write> rasters [[texture(0)]],
    constant MaskRasterParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= p.box.z || int(gid.y) >= p.box.w) return;
    rasters.write(float4(0.0f), uint2(p.box.xy) + gid, uint(p.info.x));
}

kernel void rl_mask_stroke(
    texture2d_array<float, access::read_write> scratch [[texture(0)]],
    texture2d<float, access::sample> guide [[texture(1)]],
    constant MaskRasterParams &p [[buffer(0)]],
    constant float4 *points [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= p.box.z || int(gid.y) >= p.box.w) return;
    uint2 pixel = uint2(p.box.xy) + gid;
    float2 q = float2(pixel) + 0.5f;
    float radius = max(p.brush.x, 0.5f);
    float inner = min(1.0f - clamp(p.brush.y, 0.0f, 1.0f), 0.999f);
    int count = p.info.y;
    float best = 0.0f;
    float2 nearest = q;
    for (int i = 0; i < max(count - 1, 1); i++) {
        float4 a = points[i];
        float4 b = count > 1 ? points[i + 1] : a;
        float2 ab = b.xy - a.xy;
        float t = clamp(dot(q - a.xy, ab) / max(dot(ab, ab), 1e-6f), 0.0f, 1.0f);
        float2 closest = a.xy + t * ab;
        float d = length(q - closest) / radius;
        if (d >= 1.0f) continue;
        float w = (1.0f - smoothstep(inner, 1.0f, d)) * mix(a.z, b.z, t);
        if (w > best) {
            best = w;
            nearest = closest;
        }
    }
    if (best <= 0.0f) return;
    if (p.info.z != 0) {
        // Auto Mask: only colours like the one under the stroke, read from the analysis guide.
        constexpr sampler guideSampler(coord::normalized, filter::linear, address::clamp_to_edge);
        float3 here = guide.sample(guideSampler, q / p.raster.xy).xyz;
        float3 there = guide.sample(guideSampler, nearest / p.raster.xy).xyz;
        best *= 1.0f - smoothstep(0.025f, 0.07f, colorRangeDistance(here, there));
    }
    if (best > scratch.read(pixel, 0).r) scratch.write(float4(best), pixel, 0);
}

kernel void rl_mask_stroke_apply(
    texture2d_array<float, access::read_write> scratch [[texture(0)]],
    texture2d_array<float, access::read_write> rasters [[texture(1)]],
    constant MaskRasterParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= p.box.z || int(gid.y) >= p.box.w) return;
    uint2 pixel = uint2(p.box.xy) + gid;
    float s = scratch.read(pixel, 0).r;
    if (s <= 0.0f) return;
    scratch.write(float4(0.0f), pixel, 0);
    uint slice = uint(p.info.x);
    float c = rasters.read(pixel, slice).r;
    float flow = p.brush.z;
    if (p.info.w != 0) c *= 1.0f - flow * s;
    else c += max(p.brush.w - c, 0.0f) * flow * s;
    rasters.write(float4(clamp(c, 0.0f, 1.0f)), pixel, slice);
}

// An AI mask's bitmap, resampled into its slice.
kernel void rl_mask_upload(
    texture2d<float, access::sample> bitmap [[texture(0)]],
    texture2d_array<float, access::write> rasters [[texture(1)]],
    constant MaskRasterParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= p.box.z || int(gid.y) >= p.box.w) return;
    constexpr sampler bitmapSampler(coord::normalized, filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5f) / p.raster.xy;
    rasters.write(float4(bitmap.sample(bitmapSampler, uv).r), gid, uint(p.info.x));
}
