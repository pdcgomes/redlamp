#include "RedlampShaderTypes.h"

// MARK: - Raw normalisation

// Black-subtracts, scales to the white level and applies the as-shot white balance.
// Values are clipped at 1 after white balance, so sensor-clipped highlights stay neutral.
kernel void rl_cfa_normalize(
    device const ushort *raw [[buffer(0)]],
    constant CFAParams &p [[buffer(1)]],
    constant float *blackPattern [[buffer(2)]],
    constant uchar *colorPattern [[buffer(3)]],
    texture2d<float, access::write> out [[texture(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.height) return;
    uint position = (gid.y % p.patternHeight) * p.patternWidth + (gid.x % p.patternWidth);
    float black = blackPattern[position];
    float value = (float(raw[gid.y * p.width + gid.x]) - black) / max(p.white - black, 1.0f);
    value = clamp(value * p.multipliers[colorPattern[position]], 0.0f, 1.0f);
    out.write(float4(value), gid);
}

// Linear (already demosaiced) raw, e.g. ProRAW DNGs.
kernel void rl_rgb_normalize(
    device const ushort *raw [[buffer(0)]],
    constant CFAParams &p [[buffer(1)]],
    constant float *blackPattern [[buffer(2)]],
    texture2d<float, access::write> out [[texture(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.height) return;
    uint index = (gid.y * p.width + gid.x) * p.channels;
    float3 value = float3(raw[index], raw[index + 1], raw[index + 2]);
    float3 black = float3(blackPattern[0], blackPattern[1], blackPattern[2]);
    value = (value - black) / max(float3(p.white) - black, float3(1.0f));
    value = clamp(value * p.multipliers.xyz, 0.0f, 1.0f);
    out.write(float4(value, 1.0f), gid);
}

// MARK: - Demosaic

struct DemosaicParams {
    uint width;
    uint height;
    uint patternWidth;
    uint patternHeight;
};

// Reflects about the edge pixel, which preserves Bayer parity.
static inline int reflect(int v, int size) {
    if (v < 0) v = -v;
    if (v >= size) v = 2 * (size - 1) - v;
    return clamp(v, 0, size - 1);
}

static inline float sampleCFA(texture2d<float, access::read> t, int x, int y, int w, int h) {
    return t.read(uint2(reflect(x, w), reflect(y, h))).r;
}

static inline uint cfaColor(constant uchar *pattern, constant DemosaicParams &p, int x, int y) {
    uint px = uint(x) % p.patternWidth;
    uint py = uint(y) % p.patternHeight;
    return pattern[py * p.patternWidth + px];
}

// Malvar–He–Cutler gradient-corrected bilinear demosaic for 2x2 Bayer patterns.
kernel void rl_demosaic_bayer(
    texture2d<float, access::read> cfa [[texture(0)]],
    texture2d<float, access::write> out [[texture(1)]],
    constant DemosaicParams &p [[buffer(0)]],
    constant uchar *pattern [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.height) return;
    int x = int(gid.x);
    int y = int(gid.y);
    int w = int(p.width);
    int h = int(p.height);

    #define S(dx, dy) sampleCFA(cfa, x + (dx), y + (dy), w, h)
    float c = S(0, 0);
    float cross1 = S(-1, 0) + S(1, 0) + S(0, -1) + S(0, 1);
    float cross2 = S(-2, 0) + S(2, 0) + S(0, -2) + S(0, 2);
    float diagonal = S(-1, -1) + S(1, -1) + S(-1, 1) + S(1, 1);

    uint color = cfaColor(pattern, p, x, y);
    float3 rgb;
    if (color == 1) {
        float horizontal = (4.0f * (S(-1, 0) + S(1, 0)) + 5.0f * c - (S(-2, 0) + S(2, 0))
                            - diagonal + 0.5f * (S(0, -2) + S(0, 2))) / 8.0f;
        float vertical = (4.0f * (S(0, -1) + S(0, 1)) + 5.0f * c - (S(0, -2) + S(0, 2))
                          - diagonal + 0.5f * (S(-2, 0) + S(2, 0))) / 8.0f;
        bool redRow = cfaColor(pattern, p, x + 1, y) == 0;
        rgb = redRow ? float3(horizontal, c, vertical) : float3(vertical, c, horizontal);
    } else {
        float green = (2.0f * cross1 + 4.0f * c - cross2) / 8.0f;
        float opposite = (6.0f * c + 2.0f * diagonal - 1.5f * cross2) / 8.0f;
        rgb = color == 0 ? float3(c, green, opposite) : float3(opposite, green, c);
    }
    #undef S
    out.write(float4(clamp(rgb, 0.0f, 1.0f), 1.0f), gid);
}

// Distance-weighted same-color interpolation for any CFA up to 6x6 (X-Trans).
kernel void rl_demosaic_generic(
    texture2d<float, access::read> cfa [[texture(0)]],
    texture2d<float, access::write> out [[texture(1)]],
    constant DemosaicParams &p [[buffer(0)]],
    constant uchar *pattern [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.height) return;
    int x = int(gid.x);
    int y = int(gid.y);
    float3 sum = 0.0f;
    float3 weight = 0.0f;
    uint own = cfaColor(pattern, p, x, y);
    float ownValue = cfa.read(gid).r;

    for (int dy = -2; dy <= 2; dy++) {
        for (int dx = -2; dx <= 2; dx++) {
            int sx = x + dx;
            int sy = y + dy;
            if (sx < 0 || sy < 0 || sx >= int(p.width) || sy >= int(p.height)) continue;
            uint color = cfaColor(pattern, p, sx, sy);
            float w = (dx == 0 && dy == 0) ? 4.0f : 1.0f / float(dx * dx + dy * dy);
            float v = cfa.read(uint2(sx, sy)).r;
            if (color == 0) { sum.r += w * v; weight.r += w; }
            else if (color == 1) { sum.g += w * v; weight.g += w; }
            else { sum.b += w * v; weight.b += w; }
        }
    }
    float3 rgb = sum / max(weight, float3(1e-6f));
    if (own == 0) rgb.r = ownValue;
    else if (own == 1) rgb.g = ownValue;
    else rgb.b = ownValue;
    out.write(float4(clamp(rgb, 0.0f, 1.0f), 1.0f), gid);
}
