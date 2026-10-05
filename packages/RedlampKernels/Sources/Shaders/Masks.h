// Mask coverage, shared by the develop kernel and the detail stage so both see the same masks.
#ifndef REDLAMP_MASKS_H
#define REDLAMP_MASKS_H

#include "RedlampShaderTypes.h"

constant int kMaxMaskLayers = 16;
// Entries in each of a mask's four Curves tables (DevelopParameters.maskCurveSize).
constant int kMaskCurveSize = 256;

// A mask's Curves table, kMaskCurveSize entries over 0...1.
static inline float sampleMaskCurve(constant float *table, float x) {
    float position = clamp(x, 0.0f, 1.0f) * float(kMaskCurveSize - 1);
    uint i = uint(position);
    uint j = min(i + 1, uint(kMaskCurveSize - 1));
    return mix(table[i], table[j], position - float(i));
}
constant int kMaxColorSamples = 5;

// Component kinds, as written by DevelopParameters.gpuComponent.
constant float kMaskLinear = 1.0f;
constant float kMaskRadial = 2.0f;
constant float kMaskRaster = 3.0f;
constant float kMaskLuminance = 4.0f;
constant float kMaskColor = 5.0f;
constant float kMaskDepth = 7.0f;

// The images range and raster components read. `guide` is OKLab (L 0...1) of the photo with its
// global edit, over the whole oriented frame; `rasters` holds brush and AI coverage in mask space.
// `edges` holds AI masks' guided filter coefficients (a, b, trust) in the sensor's orientation
// (process 13, MaskEdges.swift), applied to the pixel's log luminance `ev` at `sourceUV`.
struct MaskImages {
    texture2d_array<float, access::sample> rasters;
    texture2d<float, access::sample> guide;
    texture2d_array<float, access::sample> edges;
    float2 sourceUV;
    float ev;
};

// The camera RGB luminance the edge coefficients are guided by (ToneBase.logLuminance).
static inline float maskEdgeEV(float3 camera) {
    return log2(max(dot(camera, float3(0.25f, 0.5f, 0.25f)), 1e-6f));
}

static inline float2 maskUV(float2 p, float inverseAspect) {
    return float2(p.x * inverseAspect, p.y);
}

// Colour sample i of a colour range component: xy its position (mask UV), z the guide level whose
// texels average the sample's disc.
static inline float3 colorSample(MaskComponentGPU c, int i) {
    switch (i) {
    case 0: return float3(c.extra0.xy, c.extra3.x);
    case 1: return float3(c.extra0.zw, c.extra3.y);
    case 2: return float3(c.extra1.xy, c.extra3.z);
    case 3: return float3(c.extra1.zw, c.extra3.w);
    default: return float3(c.extra2.xy, c.extra2.z);
    }
}

// Distance between two OKLab colours for Color Range: hue and chroma count fully, lightness less,
// so a sampled blue sky stays selected from its bright horizon to its darker zenith.
static inline float colorRangeDistance(float3 a, float3 b) {
    float3 d = a - b;
    return length(float3(d.x * 0.45f, d.y, d.z));
}

// Coverage of one component at an aspect-corrected position.
static inline float evaluateMaskComponent(MaskComponentGPU c, float2 p, MaskImages images) {
    constexpr sampler maskSampler(coord::normalized, filter::linear, mip_filter::linear, address::clamp_to_edge);
    float weight = 0.0f;
    float kind = c.shape.x;
    if (kind < 0.5f) {
        // A raster without its bitmap: nothing.
    } else if (kind < 1.5f) {
        float2 start = c.geometry.xy;
        float2 axis = c.geometry.zw - start;
        float t = dot(p - start, axis) / max(dot(axis, axis), 1e-8f);
        weight = 1.0f - smoothstep(0.0f, 1.0f, t);
    } else if (kind < 2.5f) {
        float2 q = p - c.geometry.xy;
        float2 rotated = float2(q.x * c.rotation.x + q.y * c.rotation.y, -q.x * c.rotation.y + q.y * c.rotation.x);
        float distance = length(rotated / max(c.geometry.zw, float2(1e-5f)));
        float inner = min(1.0f - clamp(c.shape.w, 0.0f, 1.0f), 0.999f);
        weight = 1.0f - smoothstep(inner, 1.0f, distance);
    } else if (kind < 3.5f) {
        // geometry: x slice, y 1 / aspect; for an AI mask from process 13, z its edge coefficients'
        // slice plus one and w the guide's offset: its edge follows the photo's own, where the
        // photo has one, at the pixel's resolution.
        weight = images.rasters.sample(maskSampler, maskUV(p, c.geometry.y), uint(c.geometry.x)).r;
        if (c.geometry.z > 0.5f) {
            constexpr sampler edgeSampler(coord::normalized, filter::linear, address::clamp_to_edge);
            float3 e = images.edges.sample(edgeSampler, images.sourceUV, uint(c.geometry.z - 0.5f)).xyz;
            float guided = clamp(e.x * (images.ev - c.geometry.w) + e.y, 0.0f, 1.0f);
            weight = mix(weight, guided, clamp(e.z, 0.0f, 1.0f));
        }
    } else if (kind < 4.5f) {
        // geometry: lightness where coverage starts, is full, stops being full, ends (0...1);
        // rotation: x 1 / aspect, y guide level.
        float lightness = images.guide.sample(maskSampler, maskUV(p, c.rotation.x), level(c.rotation.y)).x;
        float4 g = c.geometry;
        float rise = g.y > g.x ? smoothstep(g.x, g.y, lightness) : step(g.y, lightness);
        float fall = g.w > g.z ? 1.0f - smoothstep(g.z, g.w, lightness) : step(lightness, g.z);
        weight = min(rise, fall);
    } else if (kind > 6.5f && kind < 7.5f) {
        // A trapezoid on a depth map (near is 1): geometry as for luminance; rotation: x slice,
        // y 1 / aspect.
        float depth = images.rasters.sample(maskSampler, maskUV(p, c.rotation.y), uint(c.rotation.x)).r;
        float4 g = c.geometry;
        float rise = g.y > g.x ? smoothstep(g.x, g.y, depth) : step(g.y, depth);
        float fall = g.w > g.z ? 1.0f - smoothstep(g.z, g.w, depth) : step(depth, g.z);
        weight = min(rise, fall);
    } else if (kind < 5.5f) {
        // geometry: x sample count, y tolerance, z 1 / aspect, w guide level for the pixel.
        float3 pixel = images.guide.sample(maskSampler, maskUV(p, c.geometry.z), level(c.geometry.w)).xyz;
        float tolerance = max(c.geometry.y, 1e-4f);
        int count = min(int(c.geometry.x), kMaxColorSamples);
        for (int i = 0; i < count; i++) {
            float3 s = colorSample(c, i);
            float3 reference = images.guide.sample(maskSampler, s.xy, level(s.z)).xyz;
            float d = colorRangeDistance(pixel, reference);
            weight = max(weight, 1.0f - smoothstep(0.35f * tolerance, tolerance, d));
        }
    }
    return c.shape.z > 0.5f ? 1.0f - weight : weight;
}

constant float kMaskReference = 6.0f;

static inline float combineMaskCoverage(float coverage, float w, int operation, bool first) {
    if (first) return operation == 1 ? 0.0f : w;
    if (operation == 0) return max(coverage, w);
    if (operation == 1) return coverage * (1.0f - w);
    return coverage * w;
}

// A referenced mask's components (never references themselves).
static inline float evaluateMaskComponents(
    constant MaskComponentGPU *components, int first, int count, float2 p, MaskImages images)
{
    float coverage = 0.0f;
    for (int i = 0; i < count; i++) {
        MaskComponentGPU c = components[first + i];
        float w = abs(c.shape.x - kMaskReference) < 0.5f ? 0.0f : evaluateMaskComponent(c, p, images);
        coverage = combineMaskCoverage(coverage, w, int(c.shape.y), i == 0);
    }
    return coverage;
}

// Combines a layer's components in order: add = union, subtract, intersect. A reference
// component (geometry: first component and count of the mask it reuses) evaluates that mask.
static inline float evaluateMaskLayer(
    MaskLayerGPU layer, constant MaskComponentGPU *components, float2 p, MaskImages images)
{
    int first = int(layer.tone2.z);
    int count = int(layer.tone2.w);
    float coverage = 0.0f;
    for (int i = 0; i < count; i++) {
        MaskComponentGPU c = components[first + i];
        float w;
        if (abs(c.shape.x - kMaskReference) < 0.5f) {
            w = evaluateMaskComponents(components, int(c.geometry.x), int(c.geometry.y), p, images);
            if (c.shape.z > 0.5f) w = 1.0f - w;
        } else {
            w = evaluateMaskComponent(c, p, images);
        }
        coverage = combineMaskCoverage(coverage, w, int(c.shape.y), i == 0);
    }
    return coverage;
}

// Local texture for a mask's Detail refinement: the Scharr gradient of log luminance, in stops
// per texel, at a fixed pyramid level (so it doesn't change with zoom).
template <access A>
static inline float maskTextureMagnitude(texture2d<float, A> pyramid, float2 sourceUV, uint level) {
    int2 size = int2(pyramid.get_width(level), pyramid.get_height(level));
    int2 centre = int2(sourceUV * float2(size));
    float l[3][3];
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            uint2 q = uint2(clamp(centre + int2(dx, dy), int2(0), size - 1));
            float3 rgb = pyramid.read(q, level).rgb;
            l[dy + 1][dx + 1] = log2(max(dot(rgb, float3(0.3f, 0.5f, 0.2f)), 1e-4f));
        }
    }
    float gx = (3.0f * (l[0][2] - l[0][0]) + 10.0f * (l[1][2] - l[1][0]) + 3.0f * (l[2][2] - l[2][0])) / 32.0f;
    float gy = (3.0f * (l[2][0] - l[0][0]) + 10.0f * (l[2][1] - l[0][1]) + 3.0f * (l[2][2] - l[0][2])) / 32.0f;
    return length(float2(gx, gy));
}

// Detail above 0 keeps textured areas, below 0 flat ones; the further from 0, the stricter.
static inline float maskDetailFactor(float magnitude, float amount) {
    if (amount == 0.0f) return 1.0f;
    float strictness = amount > 0.0f ? amount : 1.0f + amount;
    float threshold = 0.015f + 0.5f * strictness * strictness;
    float textured = smoothstep(threshold * 0.5f, threshold * 1.5f, magnitude);
    return amount > 0.0f ? textured : 1.0f - textured;
}

// The inverse of `orient`: source texture coordinates to oriented image coordinates.
static inline float2 unorient(float2 uv, int orientation) {
    switch (orientation) {
    case 3: return float2(1.0f - uv.x, 1.0f - uv.y);
    case 5: return float2(uv.y, 1.0f - uv.x);
    case 6: return float2(1.0f - uv.y, uv.x);
    default: return uv;
    }
}

#endif
