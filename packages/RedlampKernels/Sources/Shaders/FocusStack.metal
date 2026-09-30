#include "RedlampShaderTypes.h"

// Focus stacking: frames are warped into the reference frame's geometry, then fused.

struct StackWarpParams {
    float4 transform;         // a, b, tx, ty: output (reference) pixel -> source pixel, x' = a x - b y + tx, y' = b x + a y + ty
    float4 gain;              // xyz per-channel gain to the reference's brightness
    int4 size;                // xy output size, zw source size
};

static inline float lanczos3(float x) {
    x = abs(x);
    if (x < 1e-5f) return 1.0f;
    if (x >= 3.0f) return 0.0f;
    float px = M_PI_F * x;
    return 3.0f * sin(px) * sin(px / 3.0f) / (px * px);
}

// One frame resampled into the reference's pixels with Lanczos-3. The reference is the narrowest
// view, so frames are only ever magnified slightly and need no anti-alias prefilter. Alpha is 1
// where the source covers the pixel, 0 outside it.
kernel void rl_stack_warp(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> out [[texture(1)]],
    constant StackWarpParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= p.size.x || int(gid.y) >= p.size.y) return;
    float2 position = float2(gid);
    float2 at = float2(
        p.transform.x * position.x - p.transform.y * position.y + p.transform.z,
        p.transform.y * position.x + p.transform.x * position.y + p.transform.w);
    int2 last = p.size.zw - 1;
    bool inside = at.x >= 0.0f && at.y >= 0.0f && at.x <= float(last.x) && at.y <= float(last.y);
    int2 base = int2(floor(at));
    float2 fraction = at - float2(base);
    float wx[6];
    for (int i = 0; i < 6; i++) {
        wx[i] = lanczos3(fraction.x - float(i - 2));
    }
    float3 sum = 0.0f;
    float total = 0.0f;
    for (int j = 0; j < 6; j++) {
        float wy = lanczos3(fraction.y - float(j - 2));
        for (int i = 0; i < 6; i++) {
            float weight = wx[i] * wy;
            sum += weight * source.read(uint2(clamp(base + int2(i - 2, j - 2), int2(0), last))).rgb;
            total += weight;
        }
    }
    // Lanczos rings below zero at hard edges; light can't be negative.
    float3 rgb = max(sum / total, 0.0f) * p.gain.xyz;
    out.write(float4(rgb, inside ? 1.0f : 0.0f), gid);
}

// MARK: - Laplacian pyramids (Burt & Adelson 1983), with OpenCV's pyrDown / pyrUp filters.

constant float kBinomial[5] = {1.0f / 16.0f, 4.0f / 16.0f, 6.0f / 16.0f, 4.0f / 16.0f, 1.0f / 16.0f};

// Mirror without repeating the edge sample ("dcb|abcd|cba").
static inline int mirror(int index, int count) {
    if (count == 1) return 0;
    int period = 2 * count - 2;
    index %= period;
    if (index < 0) index += period;
    return index < count ? index : period - index;
}

static inline float4 readMirrored(texture2d<float, access::read> image, int2 at) {
    int2 size = int2(image.get_width(), image.get_height());
    return image.read(uint2(mirror(at.x, size.x), mirror(at.y, size.y)));
}

// Twice the size in each direction: binomial interpolation (OpenCV's pyrUp), per axis
// (in[m-1] + 6 in[m] + in[m+1]) / 8 at even positions and (in[m] + in[m+1]) / 2 at odd ones.
static inline float3 upsamplingWeights(int x, thread int &base) {
    if ((x & 1) == 0) {
        base = (x >> 1) - 1;
        return float3(0.125f, 0.75f, 0.125f);
    }
    base = x >> 1;
    return float3(0.5f, 0.5f, 0.0f);
}

static inline float4 upsampled(texture2d<float, access::read> coarse, int2 at) {
    int baseX;
    int baseY;
    float3 wx = upsamplingWeights(at.x, baseX);
    float3 wy = upsamplingWeights(at.y, baseY);
    float4 sum = 0.0f;
    for (int j = 0; j < 3; j++) {
        for (int i = 0; i < 3; i++) {
            float w = wx[i] * wy[j];
            if (w > 0.0f) {
                sum += w * readMirrored(coarse, int2(baseX + i, baseY + j));
            }
        }
    }
    return sum;
}

// Half the size (rounded up): 5 x 5 binomial blur, then every other sample (OpenCV's pyrDown).
kernel void rl_stack_pyr_down(
    texture2d<float, access::read> fine [[texture(0)]],
    texture2d<float, access::write> coarse [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= coarse.get_width() || gid.y >= coarse.get_height()) return;
    int2 center = 2 * int2(gid);
    float4 sum = 0.0f;
    for (int j = 0; j < 5; j++) {
        for (int i = 0; i < 5; i++) {
            sum += kBinomial[i] * kBinomial[j] * readMirrored(fine, center + int2(i - 2, j - 2));
        }
    }
    coarse.write(sum, gid);
}

// A Laplacian level: the fine image minus the upsampled next level.
kernel void rl_stack_laplacian(
    texture2d<float, access::read> fine [[texture(0)]],
    texture2d<float, access::read> coarse [[texture(1)]],
    texture2d<float, access::write> detail [[texture(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= detail.get_width() || gid.y >= detail.get_height()) return;
    detail.write(fine.read(gid) - upsampled(coarse, int2(gid)), gid);
}

// Collapsing: the upsampled coarser result plus this level's detail.
kernel void rl_stack_collapse(
    texture2d<float, access::read> coarse [[texture(0)]],
    texture2d<float, access::read> detail [[texture(1)]],
    texture2d<float, access::write> fine [[texture(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= fine.get_width() || gid.y >= fine.get_height()) return;
    fine.write(upsampled(coarse, int2(gid)) + detail.read(gid), gid);
}

// MARK: - Fusion accumulators

struct StackFuseParams {
    float4 frame;             // x frame index, y Auto window (frames), z Auto release ratio (on root saliency), w grit (root saliency)
    int4 flags;               // x level has per-coefficient selection (Auto, Detail), y level suppresses grit, z first frame
};

constant float3 kSalienceLuma = float3(0.25f, 0.5f, 0.25f);

// How strong a detail coefficient is: the square root of its 3 x 3 Gaussian-weighted (sigma 1)
// squared luma. The root keeps small values representable in half floats; it preserves order.
static inline float salience(texture2d<float, access::read> detail, int2 at) {
    const float w[3] = {0.27406862f, 0.45186276f, 0.27406862f};
    float sum = 0.0f;
    for (int j = 0; j < 3; j++) {
        for (int i = 0; i < 3; i++) {
            float y = dot(readMirrored(detail, at + int2(i - 1, j - 1)).rgb, kSalienceLuma);
            sum += w[i] * w[j] * y * y;
        }
    }
    return sqrt(sum);
}

static inline float tent(float depth, float frame) {
    return max(0.0f, 1.0f - abs(depth - frame));
}

// Adds one frame's Laplacian level. `blend` sums tent-weighted coefficients (the depth-map blend);
// for Auto, `near` keeps the most salient coefficient among frames within the window of the depth
// estimate and `far` the most salient outside it (alpha holds the salience, -1 when empty).
kernel void rl_stack_fuse_auto(
    texture2d<float, access::read> detail [[texture(0)]],
    texture2d<float, access::sample> depth [[texture(1)]],
    texture2d<float, access::read_write> blend [[texture(2)]],
    texture2d<float, access::read_write> near [[texture(3)]],
    texture2d<float, access::read_write> far [[texture(4)]],
    constant StackFuseParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= detail.get_width() || gid.y >= detail.get_height()) return;
    constexpr sampler bilinear(coord::normalized, filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5f) / float2(detail.get_width(), detail.get_height());
    float d = depth.sample(bilinear, uv).r;
    float4 coefficient = detail.read(gid);
    float weight = tent(d, p.frame.x);
    float3 blended = weight * coefficient.rgb + (p.flags.z != 0 ? 0.0f : blend.read(gid).rgb);
    blend.write(float4(blended, 1.0f), gid);
    if (p.flags.x == 0) return;
    float s = salience(detail, int2(gid));
    bool inside = abs(d - p.frame.x) <= p.frame.y;
    float4 candidate = float4(coefficient.rgb, s);
    if (inside) {
        float4 best = p.flags.z != 0 ? float4(0.0f, 0.0f, 0.0f, -1.0f) : near.read(gid);
        near.write(s > best.a ? candidate : best, gid);
        if (p.flags.z != 0) far.write(float4(0.0f, 0.0f, 0.0f, -1.0f), gid);
    } else {
        float4 best = p.flags.z != 0 ? float4(0.0f, 0.0f, 0.0f, -1.0f) : far.read(gid);
        far.write(s > best.a ? candidate : best, gid);
        if (p.flags.z != 0) near.write(float4(0.0f, 0.0f, 0.0f, -1.0f), gid);
    }
}

// Auto's choice per coefficient: the near candidate, unless a far one is `release` times as salient
// (crossing hairs); where both are below the grit level on the finest levels, the depth-map blend.
kernel void rl_stack_choose_auto(
    texture2d<float, access::read> blend [[texture(0)]],
    texture2d<float, access::read> near [[texture(1)]],
    texture2d<float, access::read> far [[texture(2)]],
    texture2d<float, access::write> chosen [[texture(3)]],
    constant StackFuseParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= chosen.get_width() || gid.y >= chosen.get_height()) return;
    float4 n = near.read(gid);
    float4 f = far.read(gid);
    float4 result = n.a < 0.0f || f.a > p.frame.z * max(n.a, 0.0f) ? f : n;
    if (result.a < 0.0f) result = blend.read(gid);
    if (p.flags.y != 0 && max(n.a, f.a) < p.frame.w) result = blend.read(gid);
    chosen.write(float4(result.rgb, 1.0f), gid);
}

// Detail (Burt & Kolczynski 1993): the most salient coefficient among all frames; on the coarsest
// level (flags.x = 0) the average instead.
kernel void rl_stack_fuse_detail(
    texture2d<float, access::read> detail [[texture(0)]],
    texture2d<float, access::read_write> best [[texture(1)]],
    constant StackFuseParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= detail.get_width() || gid.y >= detail.get_height()) return;
    float4 coefficient = detail.read(gid);
    if (p.flags.x == 0) {
        float3 sum = coefficient.rgb + (p.flags.z != 0 ? 0.0f : best.read(gid).rgb);
        best.write(float4(sum, 1.0f), gid);
        return;
    }
    float s = salience(detail, int2(gid));
    float4 current = p.flags.z != 0 ? float4(0.0f, 0.0f, 0.0f, -1.0f) : best.read(gid);
    best.write(s > current.a ? float4(coefficient.rgb, s) : current, gid);
}

// Smooth: the frame blended in by its tent weight around the depth estimate, in the image domain;
// alpha keeps the minimum coverage over frames (1 where every frame has data).
kernel void rl_stack_fuse_smooth(
    texture2d<float, access::read> frame [[texture(0)]],
    texture2d<float, access::sample> depth [[texture(1)]],
    texture2d<float, access::read_write> sum [[texture(2)]],
    constant StackFuseParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= frame.get_width() || gid.y >= frame.get_height()) return;
    constexpr sampler bilinear(coord::normalized, filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5f) / float2(frame.get_width(), frame.get_height());
    float weight = tent(depth.sample(bilinear, uv).r, p.frame.x);
    float4 value = frame.read(gid);
    float4 previous = p.flags.z != 0 ? float4(0.0f, 0.0f, 0.0f, 1.0f) : sum.read(gid);
    sum.write(float4(previous.rgb + weight * value.rgb, min(previous.a, value.a)), gid);
}

// The fused image: collapsed colour with negatives (pyramid ringing) clamped, and alpha from
// `coverage` (1 where every frame has data).
kernel void rl_stack_finish(
    texture2d<float, access::read> color [[texture(0)]],
    texture2d<float, access::read> coverage [[texture(1)]],
    texture2d<float, access::write> out [[texture(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    out.write(float4(max(color.read(gid).rgb, 0.0f), coverage.read(gid).a), gid);
}

// Divides an accumulated sum by the frame count (Detail's coarsest level).
kernel void rl_stack_scale(
    texture2d<float, access::read_write> image [[texture(0)]],
    constant StackFuseParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= image.get_width() || gid.y >= image.get_height()) return;
    float4 value = image.read(gid);
    image.write(float4(value.rgb * p.frame.x, value.a), gid);
}
