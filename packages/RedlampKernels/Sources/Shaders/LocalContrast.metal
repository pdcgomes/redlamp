#include "RedlampShaderTypes.h"

// Texture and Clarity: gains on bands of log-luminance detail between pyramid levels. The bands
// come from the whole-image pyramid, so a work area needs no margin for them and tiles agree.

struct LocalContrastParams {
    int4 origin;              // xy source texel of the work area's first texel, z source level
    int4 size;                // xy work area size, z masks' Texture and Clarity in `local`
    int4 place;               // xy work area origin in pyramid texels at the work level, z work level
    int4 levels;              // xy Texture's fine and coarse pyramid levels, zw Clarity's
    float4 luma;              // xyz pyramid RGB to luminance, w floor added before the log
    float4 shape;             // x Texture, y Clarity (slider / 100), z Clarity limit (stops)
};

// Log luminance of a pyramid level at `uv`, cubic B-spline interpolated (four bilinear taps), so
// the coarse levels come back smooth rather than with the bilinear grid.
static inline float logLumaAt(texture2d<float, access::sample> pyramid, float2 uv, int mip, float4 luma) {
    constexpr sampler s(coord::normalized, filter::linear, mip_filter::nearest, address::clamp_to_edge);
    float2 size = float2(pyramid.get_width(uint(mip)), pyramid.get_height(uint(mip)));
    float2 position = uv * size - 0.5f;
    float2 i = floor(position);
    float2 f = position - i;
    float2 f2 = f * f;
    float2 f3 = f2 * f;
    float2 w0 = (1.0f - 3.0f * f + 3.0f * f2 - f3) / 6.0f;
    float2 w1 = (4.0f - 6.0f * f2 + 3.0f * f3) / 6.0f;
    float2 w2 = (1.0f + 3.0f * f + 3.0f * f2 - 3.0f * f3) / 6.0f;
    float2 w3 = f3 / 6.0f;
    float2 g0 = w0 + w1;
    float2 g1 = w2 + w3;
    float2 h0 = (i - 0.5f + w1 / g0) / size;
    float2 h1 = (i + 1.5f + w3 / g1) / size;
    float lod = float(mip);
    float3 c = g0.y * (g0.x * pyramid.sample(s, float2(h0.x, h0.y), level(lod)).rgb
                       + g1.x * pyramid.sample(s, float2(h1.x, h0.y), level(lod)).rgb)
             + g1.y * (g0.x * pyramid.sample(s, float2(h0.x, h1.y), level(lod)).rgb
                       + g1.x * pyramid.sample(s, float2(h1.x, h1.y), level(lod)).rgb);
    return log2(max(dot(c, luma.xyz), 0.0f) + luma.w);
}

kernel void rl_local_contrast(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::sample> pyramid [[texture(1)]],
    texture2d<float, access::write> out [[texture(2)]],
    texture2d<float, access::read> local [[texture(3)]],
    constant LocalContrastParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= p.size.x || int(gid.y) >= p.size.y) return;
    uint sourceLevel = uint(p.origin.z);
    int2 sourceSize = int2(source.get_width(sourceLevel), source.get_height(sourceLevel));
    float3 rgb = source.read(uint2(clamp(int2(gid) + p.origin.xy, int2(0), sourceSize - 1)), sourceLevel).rgb;

    uint workLevel = uint(p.place.z);
    float2 levelSize = float2(pyramid.get_width(workLevel), pyramid.get_height(workLevel));
    float2 uv = (float2(p.place.xy) + float2(gid) + 0.5f) / levelSize;
    float2 amounts = p.shape.xy + (p.size.z != 0 ? local.read(gid).xy : float2(0.0f));
    // Removing all of Texture's band looks blurred, so negative Texture only softens it.
    float texture = amounts.x > 0.0f ? amounts.x : 0.5f * amounts.x;
    float clarity = 0.7f * amounts.y;
    float boost = 0.0f;
    if (texture != 0.0f && p.levels.x < p.levels.y) {
        boost += texture * (logLumaAt(pyramid, uv, p.levels.x, p.luma) - logLumaAt(pyramid, uv, p.levels.y, p.luma));
    }
    if (clarity != 0.0f && p.levels.z < p.levels.w) {
        float detail = logLumaAt(pyramid, uv, p.levels.z, p.luma) - logLumaAt(pyramid, uv, p.levels.w, p.luma);
        float limit = p.shape.z;
        boost += clarity * limit * tanh(detail / limit);
    }
    out.write(float4(rgb * exp2(boost), 1.0f), gid);
}
