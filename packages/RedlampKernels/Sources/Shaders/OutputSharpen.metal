#include <metal_stdlib>
using namespace metal;

// Output sharpening for a downscaled export (EDT-28): an unsharp mask on encoded luminance, with a
// Gaussian of sigma 0.6 px cut to 3 x 3, weighted by a tone mask that fades it out towards black
// and white, so edges into either get no halo. Luminance is taken in linear light and then encoded,
// so an edge between colours of equal luminance isn't sharpened. Its change is applied as one ratio
// to the three encoded channels, so colours keep their hue and saturation at edges.
//
// Fitted to Lightroom's Screen sharpening, measured from its exports of a test chart (2026-11-18).

struct OutputSharpenParams {
    int4 size;    // width, height
    float4 shape; // amount, centre weight, side weight, corner weight
    float4 luma;  // the output primaries' luminance weights
};

static inline float encodeChannel(float x) {
    return x <= 0.0031308f ? 12.92f * x : 1.055f * pow(x, 1.0f / 2.4f) - 0.055f;
}

static inline float3 readPixel(texture2d<float, access::read> linear, int2 at, int2 size) {
    uint2 clamped = uint2(clamp(at, int2(0), size - 1));
    return clamp(linear.read(clamped).rgb, 0.0f, 1.0f);
}

static inline float encodedLuminance(texture2d<float, access::read> linear, int2 at, int2 size, float3 weights) {
    return encodeChannel(dot(readPixel(linear, at, size), weights));
}

static inline float smoothRise(float lo, float hi, float x) {
    float t = clamp((x - lo) / (hi - lo), 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

// The share of full strength by encoded luminance, fitted to Lightroom's (0 at 0.05, 1 at 0.55, 0.03 at 0.95).
static inline float toneMask(float y) {
    return smoothRise(0.015f, 0.605f, y) * (1.0f - smoothRise(0.568f, 0.997f, y));
}

kernel void rl_encode_srgb_sharpened(
    texture2d<float, access::read> linear [[texture(0)]],
    texture2d<float, access::write> out [[texture(1)]],
    constant OutputSharpenParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= p.size.x || int(gid.y) >= p.size.y) return;
    int2 at = int2(gid);
    int2 size = p.size.xy;
    float3 weights = p.luma.rgb;
    float3 c = readPixel(linear, at, size);
    float3 centre = float3(encodeChannel(c.r), encodeChannel(c.g), encodeChannel(c.b));
    float y = encodeChannel(dot(c, weights));
    float sides = encodedLuminance(linear, at + int2(-1, 0), size, weights)
        + encodedLuminance(linear, at + int2(1, 0), size, weights)
        + encodedLuminance(linear, at + int2(0, -1), size, weights)
        + encodedLuminance(linear, at + int2(0, 1), size, weights);
    float corners = encodedLuminance(linear, at + int2(-1, -1), size, weights)
        + encodedLuminance(linear, at + int2(1, -1), size, weights)
        + encodedLuminance(linear, at + int2(-1, 1), size, weights)
        + encodedLuminance(linear, at + int2(1, 1), size, weights);
    float blurred = p.shape.y * y + p.shape.z * sides + p.shape.w * corners;
    float sharpened = clamp(y + p.shape.x * toneMask(y) * (y - blurred), 0.0f, 1.0f);
    float ratio = y > 1e-4f ? sharpened / y : 1.0f;
    out.write(float4(clamp(centre * ratio, 0.0f, 1.0f), 1.0f), gid);
}
