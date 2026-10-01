#include "Masks.h"

// Masks' Texture, Clarity, Sharpness and Noise for the detail stage: per work texel, the sum of
// each mask's coverage times its amounts. Layers reuse MaskLayerGPU: `color` holds the four
// amounts (slider / 100, scaled by the mask's Amount), tone2.zw the component range.

struct DetailLocalParams {
    int4 place;               // xy work area origin in pyramid texels, z pyramid level, w orientation
    int4 size;                // xy work area size, z layer count
    float4 geometry;          // x aspect ratio (oriented width / height)
};

kernel void rl_detail_local(
    texture2d<float, access::read> pyramid [[texture(0)]],
    texture2d<float, access::write> out [[texture(1)]],
    constant DetailLocalParams &p [[buffer(0)]],
    constant MaskLayerGPU *layers [[buffer(1)]],
    constant MaskComponentGPU *components [[buffer(2)]],
    texture2d_array<float, access::sample> maskRasters [[texture(2)]],
    texture2d<float, access::sample> maskGuide [[texture(3)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= p.size.x || int(gid.y) >= p.size.y) return;
    uint level = uint(p.place.z);
    float2 levelSize = float2(pyramid.get_width(level), pyramid.get_height(level));
    float2 uv = unorient((float2(p.place.xy) + float2(gid) + 0.5f) / levelSize, p.place.w);
    float2 position = float2(uv.x * p.geometry.x, uv.y);
    float4 amounts = 0.0f;
    MaskImages maskImages = { maskRasters, maskGuide };
    float2 sourceUV = (float2(p.place.xy) + float2(gid) + 0.5f) / levelSize;
    float textureMagnitude = -1.0f;
    for (int i = 0; i < min(p.size.z, kMaxMaskLayers); i++) {
        float coverage = evaluateMaskLayer(layers[i], components, position, maskImages);
        if (layers[i].detail.y != 0.0f) {
            if (textureMagnitude < 0.0f) {
                textureMagnitude = maskTextureMagnitude(pyramid, sourceUV, uint(layers[i].detail.z));
            }
            coverage *= maskDetailFactor(textureMagnitude, layers[i].detail.y);
        }
        amounts += coverage * layers[i].color;
    }
    out.write(amounts, gid);
}
