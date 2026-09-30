#include "RedlampShaderTypes.h"

// Capture sharpening, noise-aware: the detail to boost is measured on a denoised copy of the
// luminance (the separator), mixed between a log-luminance unsharp mask and Richardson-Lucy
// deconvolution by Detail, and applied as one ratio to the untouched source RGB. Where the clean
// luminance is flat the ratio is 1, so the photo's noise passes through as it was. Boosting detail
// in stops keeps it independent of exposure, and scaling RGB by one ratio leaves colours alone.

struct SharpenParams {
    int4 origin;              // xy source texel of the work area's first texel, z source level
    int4 size;                // xy work area size, z blur direction (0 rows, 1 columns), w masks' Sharpness in `local`
    float4 luma;              // xyz source RGB to luminance, w floor added before the log
    float4 shape;             // x gain, y halo scale (stops), z edge threshold (stops per texel), w blur sigma (texels)
    float4 deconvolution;     // x Detail's share of deconvolution, y step (0 ratio, 1 update), z source softening available
};

static inline float3 readSource(texture2d<float, access::read> source, constant SharpenParams &p, int2 at) {
    uint level = uint(p.origin.z);
    int2 levelSize = int2(source.get_width(level), source.get_height(level));
    return source.read(uint2(clamp(at + p.origin.xy, int2(0), levelSize - 1)), level).rgb;
}

static inline float gaussianRow(texture2d<float, access::read> input, constant SharpenParams &p, int2 at, int2 step) {
    float sigma = p.shape.w;
    int radius = min(int(ceil(3.0f * sigma)), 12);
    float sum = 0.0f;
    float total = 0.0f;
    for (int i = -radius; i <= radius; i++) {
        float weight = exp(-0.5f * float(i * i) / (sigma * sigma));
        sum += weight * input.read(uint2(clamp(at + i * step, int2(0), p.size.xy - 1))).r;
        total += weight;
    }
    return sum / total;
}

// Log luminance of the source (for masks' negative Sharpness, which softens it).
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

// The separator's clean luminance D, linear (also the first deconvolution estimate) and in stops.
kernel void rl_sharpen_luma(
    texture2d<float, access::read> separated [[texture(0)]],
    texture2d<float, access::write> linearLuma [[texture(1)]],
    texture2d<float, access::write> logLuma [[texture(2)]],
    constant SharpenParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= p.size.x || int(gid.y) >= p.size.y) return;
    float luminance = max(dot(separated.read(gid).rgb, p.luma.xyz), 0.0f) + p.luma.w;
    linearLuma.write(float4(luminance), gid);
    logLuma.write(float4(log2(luminance)), gid);
}

// One direction of a Gaussian blur.
kernel void rl_sharpen_blur(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant SharpenParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= p.size.x || int(gid.y) >= p.size.y) return;
    int2 step = p.size.z == 0 ? int2(1, 0) : int2(0, 1);
    output.write(float4(gaussianRow(input, p, int2(gid), step)), gid);
}

// Half a Richardson-Lucy iteration: finishes a Gaussian blur down the columns of `rows`, then either
// divides the observed luminance by it (step 0: ratio = D / blur(estimate)) or multiplies the
// estimate by it (step 1: estimate' = estimate · blur(ratio)). The PSF is symmetric, so it needs
// no flip.
kernel void rl_deconvolve_columns(
    texture2d<float, access::read> rows [[texture(0)]],
    texture2d<float, access::read> operand [[texture(1)]],
    texture2d<float, access::write> output [[texture(2)]],
    constant SharpenParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= p.size.x || int(gid.y) >= p.size.y) return;
    float blurred = gaussianRow(rows, p, int2(gid), int2(0, 1));
    float value = operand.read(gid).r;
    output.write(float4(p.deconvolution.y == 0.0f ? value / max(blurred, 1e-6f) : value * blurred), gid);
}

// Packs what sharpening measured on the clean luminance, which none of Amount, Detail or Masking
// change: x unsharp detail, y deconvolution detail, z blurred log luminance (all in stops).
kernel void rl_sharpen_analysis(
    texture2d<float, access::read> logLuma [[texture(0)]],
    texture2d<float, access::read> blurred [[texture(1)]],
    texture2d<float, access::read> estimate [[texture(2)]],
    texture2d<float, access::write> analysis [[texture(3)]],
    constant SharpenParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= p.size.x || int(gid.y) >= p.size.y) return;
    float cleanLog = logLuma.read(gid).r;
    float smooth = blurred.read(gid).r;
    float deconvolved = log2(max(estimate.read(gid).r, 1e-6f)) - cleanLog;
    analysis.write(float4(cleanLog - smooth, deconvolved, smooth, 0.0f), gid);
}

kernel void rl_sharpen_apply(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::read> analysis [[texture(1)]],
    texture2d<float, access::write> out [[texture(2)]],
    texture2d<float, access::read> local [[texture(3)]],
    texture2d<float, access::read> sourceLog [[texture(4)]],
    texture2d<float, access::read> sourceBlurred [[texture(5)]],
    constant SharpenParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= p.size.x || int(gid.y) >= p.size.y) return;
    int2 at = int2(gid);
    // Masks add to the gain; below zero it softens.
    float gain = max(p.shape.x + (p.size.w != 0 ? local.read(gid).z : 0.0f), -1.0f);
    float3 measured = analysis.read(gid).xyz;
    float detail;
    if (gain < 0.0f && p.deconvolution.z != 0.0f) {
        // Softening blurs the source itself, noise included.
        detail = sourceLog.read(gid).r - sourceBlurred.read(gid).r;
    } else {
        detail = mix(measured.x, measured.y, gain < 0.0f ? 0.0f : p.deconvolution.x);
    }
    // Small detail is boosted by the full gain; large (edge) detail saturates at the halo scale.
    float halo = p.shape.y;
    float boost = gain * halo * tanh(detail / halo);
    if (p.shape.z > 0.0f) {
        int2 last = p.size.xy - 1;
        float dx = analysis.read(uint2(clamp(at + int2(1, 0), int2(0), last))).z
            - analysis.read(uint2(clamp(at - int2(1, 0), int2(0), last))).z;
        float dy = analysis.read(uint2(clamp(at + int2(0, 1), int2(0), last))).z
            - analysis.read(uint2(clamp(at - int2(0, 1), int2(0), last))).z;
        float edge = 0.5f * length(float2(dx, dy));
        boost *= smoothstep(0.5f * p.shape.z, p.shape.z, edge);
    }
    out.write(float4(readSource(source, p, at) * exp2(boost), 1.0f), gid);
}
