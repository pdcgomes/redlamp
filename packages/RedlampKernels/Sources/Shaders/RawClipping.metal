#include "RedlampShaderTypes.h"

// Photosites the sensor clipped, painted over a developed frame at the develop kernel's sampling
// position: each clipped channel in its own colour, two mixing, black where all three clipped.
// The pyramid keeps reconstructed highlights above each channel's clip level, which is
// `clip.xyz` there, times the lens-shading gain where `clip.w` is 1 (gain maps applied after
// clipping).
kernel void rl_raw_clipping(
    texture2d<float, access::sample> source [[texture(0)]],
    texture2d<float, access::write> out [[texture(1)]],
    texture2d<float, access::sample> noiseGain [[texture(2)]],
    constant DevelopParams &p [[buffer(0)]],
    constant float4 &clip [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint width = uint(p.outputSize.x);
    uint height = uint(p.outputSize.y);
    if (gid.x >= width || gid.y >= height) return;
    constexpr sampler linearSampler(coord::normalized, filter::linear, mip_filter::linear, address::clamp_to_edge);
    float2 uv = p.region.xy + (float2(gid) + 0.5f) / float2(width, height) * p.region.zw;
    float2 imageUV;
    if (outputToImage(uv, p, imageUV)) return;
    float2 sourceUV = orient(imageUV, int(p.geometry.x));
    float3 camera = source.sample(linearSampler, sourceUV, level(p.geometry.y)).rgb;
    float3 limit = clip.xyz;
    if (clip.w > 0.5f) limit *= noiseGain.sample(linearSampler, sourceUV).rgb;
    bool3 clipped = camera >= limit;
    if (!any(clipped)) return;
    out.write(float4(all(clipped) ? float3(0.0f) : float3(clipped), 1.0f), gid);
}
