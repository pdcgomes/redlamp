#include "RedlampShaderTypes.h"

// Noise reduction: an à-trous B3-spline decomposition in a noise-stabilised opponent space,
// with every scale's detail shrunk towards zero where it is indistinguishable from noise.

constant float kB3[5] = {1.0f / 16.0f, 4.0f / 16.0f, 6.0f / 16.0f, 4.0f / 16.0f, 1.0f / 16.0f};

// Generalised Anscombe transform for variance = a·v + b: afterwards the noise is 1 at every level.
static inline float3 stabilize(float3 v, float3 a, float3 b) {
    float3 root = sqrt(b);
    float3 shot = 2.0f * (sqrt(max(a * v + b, 0.0f)) - root) / max(a, 1e-12f);
    return select(shot, v / root, a < 1e-9f);
}

static inline float3 unstabilize(float3 f, float3 a, float3 b) {
    float3 root = sqrt(b);
    float3 u = 0.5f * a * f + root;
    // u·|u| keeps the inverse monotonic below black.
    float3 shot = (u * abs(u) - b) / max(a, 1e-12f);
    return select(shot, f * root, a < 1e-9f);
}

// Orthonormal, so unit noise per channel stays unit noise per axis.
static inline float3 toOpponent(float3 c) {
    return float3(
        (c.r + c.g + c.b) * 0.57735027f,
        (c.r - c.b) * 0.70710678f,
        (c.r - 2.0f * c.g + c.b) * 0.40824829f);
}

static inline float3 fromOpponent(float3 o) {
    float y = o.x * 0.57735027f;
    return float3(
        y + o.y * 0.70710678f + o.z * 0.40824829f,
        y - o.z * 0.81649658f,
        y - o.y * 0.70710678f + o.z * 0.40824829f);
}

// Non-negative garrote: detail well above the threshold passes almost unchanged, detail below it
// goes. Chroma shrinks as one vector so hues don't shift.
static inline float3 shrink(float3 d, float3 t) {
    float3 kept = d;
    if (t.x > 0.0f) {
        float r = d.x / t.x;
        kept.x = r * r > 1.0f ? d.x * (1.0f - 1.0f / (r * r)) : 0.0f;
    }
    if (t.y > 0.0f && t.z > 0.0f) {
        float2 r = d.yz / t.yz;
        float r2 = dot(r, r);
        kept.yz = r2 > 1.0f ? d.yz * (1.0f - 1.0f / r2) : 0.0f;
    }
    return kept;
}

constexpr sampler kNoiseGainSampler(filter::linear, address::clamp_to_edge, coord::normalized);

// The lens-shading gain the pyramid carries at a work texel (see NoiseGain): dividing it out
// returns the values to the sensor's own noise, which the model describes.
static inline float3 noiseGainAt(texture2d<float, access::sample> gain, texture2d<float, access::read> pyramid,
                                 uint2 gid, constant DenoiseParams &p) {
    uint level = uint(p.origin.z);
    int2 levelSize = int2(pyramid.get_width(level), pyramid.get_height(level));
    int2 at = clamp(int2(gid) + p.origin.xy, int2(0), levelSize - 1);
    return max(gain.sample(kNoiseGainSampler, (float2(at) + 0.5f) / float2(levelSize)).rgb, 1e-3f);
}

kernel void rl_denoise_prepare(
    texture2d<float, access::read> pyramid [[texture(0)]],
    texture2d<half, access::write> out [[texture(1)]],
    texture2d<float, access::sample> noiseGain [[texture(2)]],
    constant DenoiseParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= p.size.x || int(gid.y) >= p.size.y) return;
    uint level = uint(p.origin.z);
    int2 levelSize = int2(pyramid.get_width(level), pyramid.get_height(level));
    int2 at = clamp(int2(gid) + p.origin.xy, int2(0), levelSize - 1);
    float3 value = pyramid.read(uint2(at), level).rgb / noiseGainAt(noiseGain, pyramid, gid, p);
    out.write(half4(half3(toOpponent(stabilize(value, p.a.xyz, p.b.xyz))), 1.0h), gid);
}

kernel void rl_denoise_rows(
    texture2d<half, access::read> current [[texture(0)]],
    texture2d<half, access::write> rows [[texture(1)]],
    constant DenoiseParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= p.size.x || int(gid.y) >= p.size.y) return;
    float3 sum = 0.0f;
    for (int i = -2; i <= 2; i++) {
        int x = clamp(int(gid.x) + i * p.scale.x, 0, p.size.x - 1);
        sum += kB3[i + 2] * float3(current.read(uint2(x, gid.y)).rgb);
    }
    rows.write(half4(half3(sum), 1.0h), gid);
}

// Finishes this scale's blur, keeps what of its detail isn't noise, and on the coarsest scale
// writes the result back in pyramid units. threshold.x is the luma threshold per unit of
// Luminance strength, threshold.w that strength; with scale.w set, masks' Noise (local.w) adds to it.
kernel void rl_denoise_columns(
    texture2d<half, access::read> rows [[texture(0)]],
    texture2d<half, access::read> current [[texture(1)]],
    texture2d<half, access::write> next [[texture(2)]],
    texture2d<half, access::read_write> result [[texture(3)]],
    texture2d<float, access::read> local [[texture(4)]],
    texture2d<float, access::read> pyramid [[texture(5)]],
    texture2d<float, access::sample> noiseGain [[texture(6)]],
    constant DenoiseParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= p.size.x || int(gid.y) >= p.size.y) return;
    float3 coarse = 0.0f;
    for (int i = -2; i <= 2; i++) {
        int y = clamp(int(gid.y) + i * p.scale.x, 0, p.size.y - 1);
        coarse += kB3[i + 2] * float3(rows.read(uint2(gid.x, y)).rgb);
    }
    float3 detail = float3(current.read(gid).rgb) - coarse;
    float strength = p.threshold.w + (p.scale.w != 0 ? local.read(gid).w : 0.0f);
    float3 threshold = float3(p.threshold.x * max(strength, 0.0f), p.threshold.yz);
    float3 total = shrink(detail, threshold);
    if (p.scale.y == 0) total += float3(result.read(gid).rgb);
    if (p.scale.z != 0) {
        float3 value = unstabilize(fromOpponent(total + coarse), p.a.xyz, p.b.xyz)
            * noiseGainAt(noiseGain, pyramid, gid, p);
        next.write(half4(half3(max(value, 0.0f)), 1.0h), gid);
    } else {
        result.write(half4(half3(total), 1.0h), gid);
        next.write(half4(half3(coarse), 1.0h), gid);
    }
}
