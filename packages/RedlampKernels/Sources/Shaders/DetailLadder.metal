#include "RedlampShaderTypes.h"

// Process 10: one decomposition behind Texture, Clarity and sharpening. An à-trous B3-spline
// ladder of the work area's linear luminance (after noise reduction): c0 is the luminance, each
// coarser level c(s+1) the B3 spline of c(s) with holes 2^s, and band s = c(s) - c(s+1). Four
// bands and the residual c4 reconstruct the luminance exactly. Texture reads the ratio of two
// levels, Clarity the third level against its edge-aware base, and sharpening's separator keeps
// the bands that stand out of the noise. See docs/plans/2026-10-03-detail-decomposition-design.md.

constant float kLadderB3[5] = {1.0f / 16.0f, 4.0f / 16.0f, 6.0f / 16.0f, 4.0f / 16.0f, 1.0f / 16.0f};

struct LadderParams {
    int4 origin;              // xy source texel of the work area's first texel, z source level
    int4 size;                // xy work area size, z scale (0-3), w hole spacing in texels
    int4 place;               // xy work area origin in pyramid texels at the work level, z work level, w the level local means are read at
    float4 luma;              // xyz source RGB to luminance, w floor added before the log
    float4 a;                 // noise per channel in pyramid units: variance = a · value + b
    float4 b;
    float4 thresholds;        // the separator's threshold per band, per unit of luminance noise
};

static inline float ladderLuma(texture2d<float, access::read> source, constant LadderParams &p, int2 at) {
    uint level = uint(p.origin.z);
    int2 levelSize = int2(source.get_width(level), source.get_height(level));
    float3 rgb = source.read(uint2(clamp(at + p.origin.xy, int2(0), levelSize - 1)), level).rgb;
    return max(dot(rgb, p.luma.xyz), 0.0f);
}

// The B3 spline along a row of this scale's level (the source's luminance on scale 0).
kernel void rl_ladder_rows(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::read> level [[texture(1)]],
    texture2d<float, access::write> rows [[texture(2)]],
    constant LadderParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= p.size.x || int(gid.y) >= p.size.y) return;
    float sum = 0.0f;
    for (int i = -2; i <= 2; i++) {
        int2 at = int2(clamp(int(gid.x) + i * p.size.w, 0, p.size.x - 1), int(gid.y));
        sum += kLadderB3[i + 2] * (p.size.z == 0 ? ladderLuma(source, p, at) : level.read(uint2(at)).r);
    }
    rows.write(float4(sum), gid);
}

// Finishes the spline down the columns: the next level, and this scale's band in `bands` (one
// channel per scale). The last scale writes the next level as the residual.
kernel void rl_ladder_columns(
    texture2d<float, access::read> rows [[texture(0)]],
    texture2d<float, access::read> source [[texture(1)]],
    texture2d<float, access::read> level [[texture(2)]],
    texture2d<float, access::write> next [[texture(3)]],
    texture2d<half, access::read_write> bands [[texture(4)]],
    texture2d<half, access::write> residual [[texture(5)]],
    constant LadderParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= p.size.x || int(gid.y) >= p.size.y) return;
    float coarse = 0.0f;
    for (int i = -2; i <= 2; i++) {
        int y = clamp(int(gid.y) + i * p.size.w, 0, p.size.y - 1);
        coarse += kLadderB3[i + 2] * rows.read(uint2(gid.x, y)).r;
    }
    int scale = p.size.z;
    float fine = scale == 0 ? ladderLuma(source, p, int2(gid)) : level.read(gid).r;
    half4 detail = scale == 0 ? half4(0.0h) : bands.read(gid);
    detail[scale] = half(fine - coarse);
    bands.write(detail, gid);
    if (scale == 3) {
        residual.write(half4(half(coarse)), gid);
    } else {
        next.write(float4(coarse), gid);
    }
}

constexpr sampler kLadderSampler(filter::linear, address::clamp_to_edge, coord::normalized);

// The luminance's noise sigma at a work texel, from the noise model and the local mean of each
// channel (a coarser pyramid level), with the lens-shading gain the pyramid carries (NoiseGain).
static inline float lumaNoise(texture2d<float, access::sample> pyramid, texture2d<float, access::sample> noiseGain,
                              constant LadderParams &p, uint2 gid) {
    uint workLevel = uint(p.place.z);
    float2 levelSize = float2(pyramid.get_width(workLevel), pyramid.get_height(workLevel));
    float2 uv = (float2(p.place.xy) + float2(gid) + 0.5f) / levelSize;
    float3 mean = max(pyramid.sample(kLadderSampler, uv, level(float(p.place.w))).rgb, 0.0f);
    float3 gain = max(noiseGain.sample(kLadderSampler, uv).rgb, 1e-3f);
    float3 variance = gain * p.a.xyz * mean + gain * gain * p.b.xyz;
    float3 weights = p.luma.xyz;
    return sqrt(max(dot(weights * weights, variance), 0.0f));
}

// Sharpening's separator: the residual plus each band shrunk by a non-negative garrote at its
// threshold, so detail that stands out of the noise is kept and the noise isn't. Written as the
// clean luminance D (plus the log's floor), as rl_sharpen_luma writes it.
kernel void rl_ladder_separate(
    texture2d<half, access::read> bands [[texture(0)]],
    texture2d<half, access::read> residual [[texture(1)]],
    texture2d<float, access::sample> pyramid [[texture(2)]],
    texture2d<float, access::sample> noiseGain [[texture(3)]],
    texture2d<float, access::write> linearLuma [[texture(4)]],
    constant LadderParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= p.size.x || int(gid.y) >= p.size.y) return;
    float sigma = lumaNoise(pyramid, noiseGain, p, gid);
    float4 detail = float4(bands.read(gid));
    float4 t = p.thresholds * sigma;
    float4 r2 = detail * detail / max(t * t, 1e-20f);
    float4 kept = select(float4(0.0f), detail * (1.0f - 1.0f / r2), r2 > 1.0f);
    float clean = float(residual.read(gid).r) + kept.x + kept.y + kept.z + kept.w;
    linearLuma.write(float4(max(clean, 0.0f) + p.luma.w), gid);
}

struct DetailApplyParams {
    int4 origin;              // xy source texel of the work area's first texel, z source level
    int4 size;                // xy work area size, z masks' amounts in `local`, w source softening available
    int4 place;               // xy work area origin in pyramid texels at the work level, z work level
    int4 bands;               // x Texture's fine level, y its coarse level (ladder indices, 0 the texels; x > y for none), z Clarity's fine level (5 for none), w 1 = sharpening
    float4 luma;              // xyz source RGB to luminance, w floor added before the log
    float4 texture;           // x Texture (slider / 100), y limit (stops), z gain, w the preview's weight
    float4 clarity;           // x Clarity (slider / 100), y limit (stops), z gain
    float4 sharpen;           // x Amount's gain, y halo scale (stops), z edge threshold (stops per texel), w Detail's share of deconvolution
    float4 frame;             // xy the work level's size in texels
};

// The ladder's level `index` (0 the texels, 4 the residual) as the residual plus coarser bands.
static inline float ladderLevel(float4 detail, float residual, int index) {
    float level = residual;
    if (index <= 3) level += detail.w;
    if (index <= 2) level += detail.z;
    if (index <= 1) level += detail.y;
    if (index <= 0) level += detail.x;
    return max(level, 0.0f);
}

// Texture, Clarity and sharpening as one ratio applied to the source RGB, so colours stay.
kernel void rl_detail_apply(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<half, access::read> bands [[texture(1)]],
    texture2d<half, access::read> residual [[texture(2)]],
    texture2d<float, access::read> analysis [[texture(3)]],
    texture2d<float, access::read> local [[texture(4)]],
    texture2d<float, access::read> sourceLog [[texture(5)]],
    texture2d<float, access::read> sourceBlurred [[texture(6)]],
    texture2d<float, access::sample> clarityBase [[texture(7)]],
    texture2d<float, access::write> out [[texture(8)]],
    constant DetailApplyParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= p.size.x || int(gid.y) >= p.size.y) return;
    int2 at = int2(gid);
    uint sourceLevel = uint(p.origin.z);
    int2 sourceSize = int2(source.get_width(sourceLevel), source.get_height(sourceLevel));
    float3 rgb = source.read(uint2(clamp(at + p.origin.xy, int2(0), sourceSize - 1)), sourceLevel).rgb;
    float4 amounts = p.size.z != 0 ? local.read(gid) : float4(0.0f);
    float4 detail = float4(bands.read(gid));
    float coarsest = float(residual.read(gid).r);
    float floorLuma = p.luma.w;
    float boost = 0.0f;

    float textureAmount = p.texture.x + amounts.x;
    if (textureAmount != 0.0f && p.bands.x <= p.bands.y) {
        // Removing all of Texture's band looks blurred, so negative Texture only softens it.
        float gain = textureAmount > 0.0f ? p.texture.z * textureAmount : 0.5f * textureAmount;
        float band = log2(ladderLevel(detail, coarsest, p.bands.x) + floorLuma)
            - log2(ladderLevel(detail, coarsest, p.bands.y) + floorLuma);
        // The limit holds back what an edge's step puts in the band, where halos would come from.
        float limit = p.texture.y;
        boost += p.texture.w * gain * limit * tanh(band / limit);
    }

    float clarityAmount = p.clarity.x + amounts.y;
    if (clarityAmount != 0.0f && p.bands.z <= 4) {
        // Edge-aware (`ClarityBase`): the band ends at an edge-preserving base of the same
        // luminance, so a strong edge isn't Clarity's detail.
        constexpr sampler baseSampler(coord::normalized, filter::linear, address::clamp_to_edge);
        float2 uv = (float2(p.place.xy) + float2(gid) + 0.5f) / p.frame.xy;
        float fine = log2(ladderLevel(detail, coarsest, p.bands.z) + floorLuma);
        float2 ab = clarityBase.sample(baseSampler, uv).rg;
        float limit = p.clarity.y;
        float band = fine - (ab.x * fine + ab.y);
        boost += p.clarity.z * clarityAmount * limit * tanh(band / limit);
    }

    if (p.bands.w != 0) {
        // Masks add to the gain; below zero it softens.
        float gain = max(p.sharpen.x + amounts.z, -1.0f);
        float3 measured = analysis.read(gid).xyz;
        float sharpDetail;
        if (gain < 0.0f && p.size.w != 0) {
            // Softening blurs the source itself, noise included.
            sharpDetail = sourceLog.read(gid).r - sourceBlurred.read(gid).r;
        } else {
            sharpDetail = mix(measured.x, measured.y, gain < 0.0f ? 0.0f : p.sharpen.w);
        }
        float halo = p.sharpen.y;
        float sharpBoost = gain * halo * tanh(sharpDetail / halo);
        if (p.sharpen.z > 0.0f) {
            int2 last = p.size.xy - 1;
            float dx = analysis.read(uint2(clamp(at + int2(1, 0), int2(0), last))).z
                - analysis.read(uint2(clamp(at - int2(1, 0), int2(0), last))).z;
            float dy = analysis.read(uint2(clamp(at + int2(0, 1), int2(0), last))).z
                - analysis.read(uint2(clamp(at - int2(0, 1), int2(0), last))).z;
            float edge = 0.5f * length(float2(dx, dy));
            sharpBoost *= smoothstep(0.5f * p.sharpen.z, p.sharpen.z, edge);
        }
        boost += sharpBoost;
    }
    out.write(float4(rgb * exp2(boost), 1.0f), gid);
}
