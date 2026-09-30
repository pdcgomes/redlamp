#include "RedlampShaderTypes.h"

// The haze map for Dehaze: the dark channel prior (K. He, J. Sun & X. Tang, "Single image haze
// removal using dark channel prior", CVPR 2009): in haze-free outdoor images, most patches have
// some pixel that is dark in some channel, so a patch's darkest value relative to the airlight
// measures how much airlight has been added there.

struct HazeParams {
    int4 size;                // xy map size, z block size in full-resolution pixels, w filter radius
    int4 mode;                // x 0 minimum, 1 Gaussian; y 0 rows, 1 columns
    float4 airlight;          // xyz airlight in the pyramid's camera RGB, w Gaussian sigma
};

// Each map texel: the darkest channel, relative to the airlight, over its block of pixels.
kernel void rl_haze_dark(
    texture2d<float, access::read> pyramid [[texture(0)]],
    texture2d<float, access::write> out [[texture(1)]],
    constant HazeParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= p.size.x || int(gid.y) >= p.size.y) return;
    int2 size = int2(pyramid.get_width(0), pyramid.get_height(0));
    int2 start = int2(gid) * p.size.z;
    int2 end = min(start + p.size.z, size);
    float3 airlight = max(p.airlight.xyz, float3(1e-3f));
    float darkest = 1.0f;
    for (int y = start.y; y < end.y; y++) {
        for (int x = start.x; x < end.x; x++) {
            float3 v = pyramid.read(uint2(x, y), 0).rgb / airlight;
            darkest = min(darkest, min3(v.r, v.g, v.b));
        }
    }
    out.write(float4(clamp(darkest, 0.0f, 1.0f)), gid);
}

// One direction of the patch minimum, or of the smoothing blur.
kernel void rl_haze_filter(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant HazeParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= p.size.x || int(gid.y) >= p.size.y) return;
    int2 step = p.mode.y == 0 ? int2(1, 0) : int2(0, 1);
    int radius = p.size.w;
    float result;
    if (p.mode.x == 0) {
        result = 1.0f;
        for (int i = -radius; i <= radius; i++) {
            int2 at = clamp(int2(gid) + i * step, int2(0), p.size.xy - 1);
            result = min(result, input.read(uint2(at)).r);
        }
    } else {
        float sigma = p.airlight.w;
        float sum = 0.0f;
        float total = 0.0f;
        for (int i = -radius; i <= radius; i++) {
            int2 at = clamp(int2(gid) + i * step, int2(0), p.size.xy - 1);
            float weight = exp(-0.5f * float(i * i) / (sigma * sigma));
            sum += weight * input.read(uint2(at)).r;
            total += weight;
        }
        result = sum / total;
    }
    output.write(float4(result), gid);
}
