#include <metal_stdlib>
using namespace metal;

struct CanvasVertexOut {
    float4 position [[position]];
    float2 uv;
};

// `rect` is the image quad in NDC: left, top, right, bottom.
vertex CanvasVertexOut rl_canvas_vertex(uint vid [[vertex_id]], constant float4 &rect [[buffer(0)]]) {
    const float2 corners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };
    float2 c = corners[vid];
    CanvasVertexOut out;
    out.position = float4(mix(rect.x, rect.z, c.x), mix(rect.y, rect.w, c.y), 0.0, 1.0);
    out.uv = c;
    return out;
}

// `clip` keeps the half-plane where dot(clip.xyz, (x, y, 1)) <= 0, in drawable pixels.
fragment float4 rl_canvas_fragment(
    CanvasVertexOut in [[stage_in]],
    texture2d<float> image [[texture(0)]],
    constant uint &nearest [[buffer(0)]],
    constant float4 &clip [[buffer(1)]])
{
    if (dot(clip.xyz, float3(in.position.xy, 1.0)) > 0.0) {
        discard_fragment();
    }
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    constexpr sampler nearestSampler(filter::nearest, address::clamp_to_edge);
    return nearest ? image.sample(nearestSampler, in.uv) : image.sample(linearSampler, in.uv);
}
