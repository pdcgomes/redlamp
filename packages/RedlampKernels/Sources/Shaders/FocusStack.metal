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
