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

// Lee's sigma filter (1983) across channels: a neighbour's chroma counts as much as its luma
// resembles the centre's, so colour doesn't average across luminance edges (a lamp's rim).
static inline float edgeWeight(float luma, float centre, constant DenoiseParams &p) {
    if (p.edge.x <= 0.0f) return 1.0f;
    float d = (luma - centre) / p.edge.x;
    return exp(-0.5f * d * d);
}

// Luma is blurred plainly; chroma by edge-stopping weights, whose sum goes in alpha so the
// column pass can normalise.
kernel void rl_denoise_rows(
    texture2d<half, access::read> current [[texture(0)]],
    texture2d<half, access::write> rows [[texture(1)]],
    constant DenoiseParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= p.size.x || int(gid.y) >= p.size.y) return;
    float centre = float(current.read(gid).r);
    float luma = 0.0f;
    float2 chroma = 0.0f;
    float weights = 0.0f;
    for (int i = -2; i <= 2; i++) {
        int x = clamp(int(gid.x) + i * p.scale.x, 0, p.size.x - 1);
        float3 sample = float3(current.read(uint2(x, gid.y)).rgb);
        float w = kB3[i + 2] * edgeWeight(sample.x, centre, p);
        luma += kB3[i + 2] * sample.x;
        chroma += w * sample.yz;
        weights += w;
    }
    rows.write(half4(half(luma), half2(chroma / max(weights, 1e-6f)), half(weights)), gid);
}

// This scale's luma and chroma thresholds. threshold.x is the luma threshold per unit of
// Luminance strength, threshold.w that strength; with scale.w set, masks' Noise (local.w) adds to it.
static inline float3 thresholdsAt(texture2d<float, access::read> local, uint2 gid, constant DenoiseParams &p) {
    float strength = p.threshold.w + (p.scale.w != 0 ? local.read(gid).w : 0.0f);
    return float3(p.threshold.x * max(strength, 0.0f), p.threshold.yz);
}

// Adds this scale's kept detail to the finer scales' (scale.y is 0 after the first), and on the
// coarsest scale (scale.z) writes the result back in pyramid units, or with edge.z leaves it in
// `result` as rl_denoise_nonlocal's guide.
static inline void accumulate(float3 kept, float3 coarse, texture2d<half, access::read_write> result,
                              texture2d<half, access::write> out, texture2d<float, access::read> pyramid,
                              texture2d<float, access::sample> noiseGain, uint2 gid, constant DenoiseParams &p) {
    float3 total = kept;
    if (p.scale.y == 0) total += float3(result.read(gid).rgb);
    if (p.scale.z != 0 && p.edge.z != 0) {
        result.write(half4(half3(total + coarse), 1.0h), gid);
    } else if (p.scale.z != 0) {
        float3 value = unstabilize(fromOpponent(total + coarse), p.a.xyz, p.b.xyz)
            * noiseGainAt(noiseGain, pyramid, gid, p);
        out.write(half4(half3(max(value, 0.0f)), 1.0h), gid);
    } else {
        result.write(half4(half3(total), 1.0h), gid);
    }
}

// Finishes this scale's blur. With a luma energy radius (edge.y) it leaves the coarser level in
// `next` and the detail in `details` for rl_denoise_shrink; otherwise it shrinks the detail
// itself, and `next` is the output on the coarsest scale.
kernel void rl_denoise_columns(
    texture2d<half, access::read> rows [[texture(0)]],
    texture2d<half, access::read> current [[texture(1)]],
    texture2d<half, access::write> next [[texture(2)]],
    texture2d<half, access::read_write> result [[texture(3)]],
    texture2d<float, access::read> local [[texture(4)]],
    texture2d<float, access::read> pyramid [[texture(5)]],
    texture2d<float, access::sample> noiseGain [[texture(6)]],
    texture2d<half, access::write> details [[texture(7)]],
    constant DenoiseParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= p.size.x || int(gid.y) >= p.size.y) return;
    float3 here = float3(current.read(gid).rgb);
    float luma = 0.0f;
    float2 chroma = 0.0f;
    float weights = 0.0f;
    for (int i = -2; i <= 2; i++) {
        int y = clamp(int(gid.y) + i * p.scale.x, 0, p.size.y - 1);
        float4 row = float4(rows.read(uint2(gid.x, y)));
        float w = kB3[i + 2] * edgeWeight(float(current.read(uint2(gid.x, y)).r), here.x, p);
        luma += kB3[i + 2] * row.x;
        chroma += w * row.yz;
        weights += w;
    }
    float3 coarse = float3(luma, chroma / max(weights, 1e-6f));
    float3 detail = here - coarse;
    if (p.edge.y > 0.0f) {
        next.write(half4(half3(coarse), 1.0h), gid);
        details.write(half4(half3(detail), 1.0h), gid);
        return;
    }
    if (p.scale.z == 0) next.write(half4(half3(coarse), 1.0h), gid);
    accumulate(shrink(detail, thresholdsAt(local, gid, p)), coarse, result, next, pyramid, noiseGain, gid, p);
}

// Luma shrunk by its neighbourhood's energy (Lee's local statistics, 1980): the garrote with the
// coefficient's own square replaced by the mean square of the (2r+1)² around it at this scale's
// spacing, so faint texture beside real texture survives while flat noise still goes.
kernel void rl_denoise_shrink(
    texture2d<half, access::read> details [[texture(0)]],
    texture2d<half, access::read> coarse [[texture(1)]],
    texture2d<half, access::read_write> result [[texture(2)]],
    texture2d<half, access::write> out [[texture(3)]],
    texture2d<float, access::read> local [[texture(4)]],
    texture2d<float, access::read> pyramid [[texture(5)]],
    texture2d<float, access::sample> noiseGain [[texture(6)]],
    constant DenoiseParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= p.size.x || int(gid.y) >= p.size.y) return;
    float3 detail = float3(details.read(gid).rgb);
    float3 threshold = thresholdsAt(local, gid, p);
    float3 kept = shrink(detail, threshold);
    if (threshold.x > 0.0f) {
        int radius = int(p.edge.y);
        float energy = 0.0f;
        for (int dy = -radius; dy <= radius; dy++) {
            for (int dx = -radius; dx <= radius; dx++) {
                int2 at = clamp(int2(gid) + int2(dx, dy) * p.scale.x, int2(0), p.size.xy - 1);
                float d = float(details.read(uint2(at)).r);
                energy += d * d;
            }
        }
        energy /= float((2 * radius + 1) * (2 * radius + 1));
        kept.x = detail.x * max(1.0f - threshold.x * threshold.x / max(energy, 1e-12f), 0.0f);
    }
    accumulate(kept, float3(coarse.read(gid).rgb), result, out, pyramid, noiseGain, gid, p);
}

// Non-local means (Buades, Coll and Morel 2005) guided by the wavelet result: luma becomes an
// average of the noisy luma around it, each texel weighted by how alike the guide's 3×3 patches
// around the two are, so texture the shrinkage flattened comes back where its neighbourhood
// repeats it. Chroma keeps the guide's. nonLocal.x is the search radius (at most
// kNonLocalReach - 1), z the RMS patch difference (stabilised units) that weighs 1/e per unit of
// Luminance strength.
//
// Dispatched as kNonLocalThreads threadgroups, each covering a kNonLocalTile² tile whose
// neighbourhood it loads into threadgroup memory once. A thread computes a 2×4 block of texels,
// so for each offset the squared differences of neighbouring patches are summed once per row.
constant int kNonLocalTile = 32;
constant int kNonLocalReach = 4;
constant int kNonLocalSpan = kNonLocalTile + 2 * kNonLocalReach;
constant int kBlockWidth = 2;
constant int kBlockHeight = 4;

kernel void rl_denoise_nonlocal(
    texture2d<half, access::read> guide [[texture(0)]],
    texture2d<float, access::read> pyramid [[texture(1)]],
    texture2d<float, access::sample> noiseGain [[texture(2)]],
    texture2d<float, access::read> local [[texture(3)]],
    texture2d<half, access::write> out [[texture(4)]],
    constant DenoiseParams &p [[buffer(0)]],
    uint2 tid [[thread_position_in_threadgroup]],
    uint2 threads [[threads_per_threadgroup]],
    uint2 group [[threadgroup_position_in_grid]])
{
    threadgroup float guides[kNonLocalSpan * kNonLocalSpan];
    threadgroup float noisy[kNonLocalSpan * kNonLocalSpan];
    int2 tile = int2(group) * kNonLocalTile;
    uint level = uint(p.origin.z);
    int2 levelSize = int2(pyramid.get_width(level), pyramid.get_height(level));
    int count = int(threads.x * threads.y);
    for (int i = int(tid.y * threads.x + tid.x); i < kNonLocalSpan * kNonLocalSpan; i += count) {
        int2 at = clamp(tile - kNonLocalReach + int2(i % kNonLocalSpan, i / kNonLocalSpan), int2(0), p.size.xy - 1);
        guides[i] = float(guide.read(uint2(at)).r);
        int2 source = clamp(at + p.origin.xy, int2(0), levelSize - 1);
        float3 value = pyramid.read(uint2(source), level).rgb / noiseGainAt(noiseGain, pyramid, uint2(at), p);
        noisy[i] = toOpponent(stabilize(value, p.a.xyz, p.b.xyz)).x;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // The block's top-left texel, in the tile and in threadgroup memory.
    int2 block = int2(tid) * int2(kBlockWidth, kBlockHeight);
    int origin = (block.y + kNonLocalReach) * kNonLocalSpan + block.x + kNonLocalReach;
    float inverse[kBlockHeight][kBlockWidth];
    float sums[kBlockHeight][kBlockWidth];
    float weights[kBlockHeight][kBlockWidth];
    bool any = false;
    for (int j = 0; j < kBlockHeight; j++) {
        for (int i = 0; i < kBlockWidth; i++) {
            int2 at = min(tile + block + int2(i, j), p.size.xy - 1);
            float strength = p.threshold.w + (p.scale.w != 0 ? local.read(uint2(at)).w : 0.0f);
            float h = p.nonLocal.z * max(strength, 0.0f);
            inverse[j][i] = h > 0.0f ? 1.0f / (9.0f * h * h) : 0.0f;
            any = any || h > 0.0f;
            sums[j][i] = 0.0f;
            weights[j][i] = 0.0f;
        }
    }
    int search = any ? int(p.nonLocal.x) : 0;
    for (int dy = -search; dy <= search; dy++) {
        for (int dx = -search; dx <= search; dx++) {
            int offset = dy * kNonLocalSpan + dx;
            // Each row's 3-wide patch sums, from the block's row above to its row below.
            float rows[kBlockHeight + 2][kBlockWidth];
            for (int r = 0; r < kBlockHeight + 2; r++) {
                int start = origin + (r - 1) * kNonLocalSpan - 1;
                float d[kBlockWidth + 2];
                for (int c = 0; c < kBlockWidth + 2; c++) {
                    float difference = guides[start + c] - guides[start + c + offset];
                    d[c] = difference * difference;
                }
                for (int i = 0; i < kBlockWidth; i++) {
                    rows[r][i] = d[i] + d[i + 1] + d[i + 2];
                }
            }
            for (int j = 0; j < kBlockHeight; j++) {
                for (int i = 0; i < kBlockWidth; i++) {
                    float distance = rows[j][i] + rows[j + 1][i] + rows[j + 2][i];
                    float w = exp(-distance * inverse[j][i]);
                    sums[j][i] += w * noisy[origin + j * kNonLocalSpan + i + offset];
                    weights[j][i] += w;
                }
            }
        }
    }
    for (int j = 0; j < kBlockHeight; j++) {
        for (int i = 0; i < kBlockWidth; i++) {
            int2 at = tile + block + int2(i, j);
            if (at.x >= p.size.x || at.y >= p.size.y) continue;
            float3 here = float3(guide.read(uint2(at)).rgb);
            float luma = weights[j][i] > 0.0f ? sums[j][i] / weights[j][i] : noisy[origin + j * kNonLocalSpan + i];
            float3 value = unstabilize(fromOpponent(float3(luma, here.yz)), p.a.xyz, p.b.xyz)
                * noiseGainAt(noiseGain, pyramid, uint2(at), p);
            out.write(half4(half3(max(value, 0.0f)), 1.0h), uint2(at));
        }
    }
}
