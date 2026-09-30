#include "RedlampShaderTypes.h"

// Capture sharpening: log-luminance unsharp masking. Boosting detail in stops keeps it
// independent of exposure, and scaling RGB by one ratio leaves colours alone.

struct SharpenParams {
    int4 origin;              // xy source texel of the work area's first texel, z source level
    int4 size;                // xy work area size, z blur direction (0 rows, 1 columns), w masks' Sharpness in `local`
    float4 luma;              // xyz source RGB to luminance, w floor added before the log
    float4 shape;             // x gain, y halo scale (stops), z edge threshold (stops per texel), w blur sigma (texels)
};

static inline float3 readSource(texture2d<float, access::read> source, constant SharpenParams &p, int2 at) {
    uint level = uint(p.origin.z);
    int2 levelSize = int2(source.get_width(level), source.get_height(level));
    return source.read(uint2(clamp(at + p.origin.xy, int2(0), levelSize - 1)), level).rgb;
}

kernel void rl_sharpen_log(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> logLuma [[texture(1)]],
    constant SharpenParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= p.size.x || int(gid.y) >= p.size.y) return;
    float luminance = max(dot(readSource(source, p, int2(gid)), p.luma.xyz), 0.0f);
    logLuma.write(float4(log2(luminance + p.luma.w)), gid);
}

// One direction of a Gaussian blur.
kernel void rl_sharpen_blur(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant SharpenParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= p.size.x || int(gid.y) >= p.size.y) return;
    float sigma = p.shape.w;
    int radius = min(int(ceil(3.0f * sigma)), 12);
    int2 step = p.size.z == 0 ? int2(1, 0) : int2(0, 1);
    float sum = 0.0f;
    float total = 0.0f;
    for (int i = -radius; i <= radius; i++) {
        float weight = exp(-0.5f * float(i * i) / (sigma * sigma));
        int2 at = clamp(int2(gid) + i * step, int2(0), p.size.xy - 1);
        sum += weight * input.read(uint2(at)).r;
        total += weight;
    }
    output.write(float4(sum / total), gid);
}

kernel void rl_sharpen_apply(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::read> logLuma [[texture(1)]],
    texture2d<float, access::read> blurred [[texture(2)]],
    texture2d<float, access::write> out [[texture(3)]],
    texture2d<float, access::read> local [[texture(4)]],
    constant SharpenParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= p.size.x || int(gid.y) >= p.size.y) return;
    int2 at = int2(gid);
    float detail = logLuma.read(gid).r - blurred.read(gid).r;
    // Masks add to the gain; below zero it softens.
    float gain = max(p.shape.x + (p.size.w != 0 ? local.read(gid).z : 0.0f), -1.0f);
    // Small detail is boosted by the full gain; large (edge) detail saturates at the halo scale.
    float halo = p.shape.y;
    float boost = gain * halo * tanh(detail / halo);
    if (p.shape.z > 0.0f) {
        int2 last = p.size.xy - 1;
        float dx = blurred.read(uint2(clamp(at + int2(1, 0), int2(0), last))).r
            - blurred.read(uint2(clamp(at - int2(1, 0), int2(0), last))).r;
        float dy = blurred.read(uint2(clamp(at + int2(0, 1), int2(0), last))).r
            - blurred.read(uint2(clamp(at - int2(0, 1), int2(0), last))).r;
        float edge = 0.5f * length(float2(dx, dy));
        boost *= smoothstep(0.5f * p.shape.z, p.shape.z, edge);
    }
    out.write(float4(readSource(source, p, at) * exp2(boost), 1.0f), gid);
}
