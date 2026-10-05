#include <metal_stdlib>
using namespace metal;

// A mask's own colour for Point Color (TON-29): the weighted median of what Point Color receives
// under the mask, from a small render of it (output encoding 5) whose alpha is the mask's coverage.
// Three histograms, of OKLab lightness, a and b, then the median of each. Near-greys under the mask
// (white clothes, grey hair, teeth) are left out: Point Color barely changes them, and where they
// outnumber the skin they'd make its colour grey.

constant uint kPointColorBins = 1024;
// The histograms' spans: lightness 0...1.25 (highlights past white included), a and b ±0.5.
constant float kPointColorLightnessSpan = 1.25f;
constant float kPointColorOpponentSpan = 0.5f;

static inline uint pointColorBin(float value, float low, float span) {
    return min(uint(max((value - low) / span, 0.0f) * float(kPointColorBins)), kPointColorBins - 1);
}

kernel void rl_point_color_histogram(
    texture2d<float, access::read> input [[texture(0)]],
    device atomic_uint *bins [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= input.get_width() || gid.y >= input.get_height()) return;
    float4 texel = input.read(gid);
    // Soft edges count for less, and the faintest not at all.
    if (texel.w < 0.25f) return;
    uint weight = uint(texel.w * smoothstep(0.01f, 0.03f, length(texel.yz)) * 255.0f + 0.5f);
    if (weight == 0) return;
    float opponent = 2.0f * kPointColorOpponentSpan;
    atomic_fetch_add_explicit(
        &bins[pointColorBin(texel.x, 0.0f, kPointColorLightnessSpan)], weight, memory_order_relaxed);
    atomic_fetch_add_explicit(
        &bins[kPointColorBins + pointColorBin(texel.y, -kPointColorOpponentSpan, opponent)], weight,
        memory_order_relaxed);
    atomic_fetch_add_explicit(
        &bins[2 * kPointColorBins + pointColorBin(texel.z, -kPointColorOpponentSpan, opponent)], weight,
        memory_order_relaxed);
}

// The value at half the histogram's weight, placed within its bin in proportion.
static float pointColorMedian(device const uint *bins, float low, float span, uint total) {
    float middle = 0.5f * float(total);
    float below = 0.0f;
    for (uint i = 0; i < kPointColorBins; i++) {
        float count = float(bins[i]);
        if (count > 0.0f && below + count >= middle) {
            return low + (float(i) + (middle - below) / count) / float(kPointColorBins) * span;
        }
        below += count;
    }
    return low + span;
}

// One thread: the medians of the histograms in `bins`, as OKLCh in `colors[slot]`, w the weight
// under the mask (0 when nothing is under it).
kernel void rl_point_color_median(
    device const uint *bins [[buffer(0)]],
    device float4 *colors [[buffer(1)]],
    constant uint &slot [[buffer(2)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid != 0) return;
    uint total = 0;
    for (uint i = 0; i < kPointColorBins; i++) total += bins[i];
    if (total == 0) {
        colors[slot] = float4(0.0f);
        return;
    }
    float opponent = 2.0f * kPointColorOpponentSpan;
    float lightness = pointColorMedian(bins, 0.0f, kPointColorLightnessSpan, total);
    float a = pointColorMedian(bins + kPointColorBins, -kPointColorOpponentSpan, opponent, total);
    float b = pointColorMedian(bins + 2 * kPointColorBins, -kPointColorOpponentSpan, opponent, total);
    float hue = atan2(b, a) * (180.0f / M_PI_F);
    colors[slot] = float4(lightness, length(float2(a, b)), hue < 0.0f ? hue + 360.0f : hue, float(total) / 255.0f);
}
