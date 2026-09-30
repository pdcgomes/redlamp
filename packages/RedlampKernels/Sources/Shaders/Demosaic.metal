#include "RedlampShaderTypes.h"

// MARK: - Raw normalisation

// Black-subtracts (with each row's and column's banding offset, zero without banding), scales
// to the white level and applies the as-shot white balance. Values above 1 are kept: a channel
// with a large multiplier only clips at its own level, and highlight reconstruction deals with
// photosites that did clip.
kernel void rl_cfa_normalize(
    device const ushort *raw [[buffer(0)]],
    constant CFAParams &p [[buffer(1)]],
    constant float *blackPattern [[buffer(2)]],
    constant uchar *colorPattern [[buffer(3)]],
    device const float *rowOffsets [[buffer(4)]],
    device const float *columnOffsets [[buffer(5)]],
    texture2d<float, access::write> out [[texture(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.height) return;
    uint position = (gid.y % p.patternHeight) * p.patternWidth + (gid.x % p.patternWidth);
    float black = blackPattern[position];
    float banding = rowOffsets[gid.y] + columnOffsets[gid.x];
    float value = (float(raw[gid.y * p.width + gid.x]) - black - banding) / max(p.white - black, 1.0f);
    value = max(value * p.multipliers[colorPattern[position]], 0.0f);
    out.write(float4(value), gid);
}

// MARK: - DNG gain maps

// One GainMap opcode (see GainMap in RedlampServices).
struct GainMapGPU {
    int4 area;           // top, left, bottom, right (pixels)
    int4 grid;           // row pitch, column pitch, points V, points H
    float4 placement;    // spacing V, spacing H, origin V, origin H (fractions of the image)
    int4 planes;         // first plane, plane count, map planes, first gain index
};

// The product of every map's gain for one plane of a pixel, bilinear on each map's grid.
static inline float gainAt(constant GainMapGPU *maps, uint count, constant float *gains,
                           int x, int y, int plane, uint width, uint height) {
    float product = 1.0f;
    for (uint i = 0; i < count; i++) {
        GainMapGPU m = maps[i];
        if (y < m.area.x || y >= m.area.z || x < m.area.y || x >= m.area.w) continue;
        if ((y - m.area.x) % m.grid.x != 0 || (x - m.area.y) % m.grid.y != 0) continue;
        if (plane < m.planes.x || plane >= m.planes.x + m.planes.y) continue;
        float v = clamp((float(y) / float(height) - m.placement.z) / m.placement.x, 0.0f, float(m.grid.z - 1));
        float h = clamp((float(x) / float(width) - m.placement.w) / m.placement.y, 0.0f, float(m.grid.w - 1));
        int v0 = int(v);
        int h0 = int(h);
        int v1 = min(v0 + 1, m.grid.z - 1);
        int h1 = min(h0 + 1, m.grid.w - 1);
        int mapPlane = min(plane - m.planes.x, m.planes.z - 1);
        int stride = m.planes.z;
        int base = m.planes.w + mapPlane;
        float g00 = gains[base + (v0 * m.grid.w + h0) * stride];
        float g01 = gains[base + (v0 * m.grid.w + h1) * stride];
        float g10 = gains[base + (v1 * m.grid.w + h0) * stride];
        float g11 = gains[base + (v1 * m.grid.w + h1) * stride];
        float fv = v - float(v0);
        float fh = h - float(h0);
        product *= mix(mix(g00, g01, fh), mix(g10, g11, fh), fv);
    }
    return product;
}

// Applies a mosaic's gain maps in place, after sensor cleanup and highlight reconstruction
// (which judge clipping against the sensor's own levels) and before demosaicing.
kernel void rl_cfa_apply_gain_maps(
    texture2d<float, access::read_write> cfa [[texture(0)]],
    constant uint &count [[buffer(0)]],
    constant GainMapGPU *maps [[buffer(1)]],
    constant float *gains [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint width = cfa.get_width();
    uint height = cfa.get_height();
    if (gid.x >= width || gid.y >= height) return;
    float gain = gainAt(maps, count, gains, int(gid.x), int(gid.y), 0, width, height);
    if (gain != 1.0f) cfa.write(cfa.read(gid) * gain, gid);
}

// Linear (already demosaiced) raw, e.g. ProRAW DNGs; gain maps apply per channel (pad0 of them).
kernel void rl_rgb_normalize(
    device const ushort *raw [[buffer(0)]],
    constant CFAParams &p [[buffer(1)]],
    constant float *blackPattern [[buffer(2)]],
    constant GainMapGPU *maps [[buffer(3)]],
    constant float *gains [[buffer(4)]],
    texture2d<float, access::write> out [[texture(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.height) return;
    uint index = (gid.y * p.width + gid.x) * p.channels;
    float3 value = float3(raw[index], raw[index + 1], raw[index + 2]);
    float3 black = float3(blackPattern[0], blackPattern[1], blackPattern[2]);
    value = (value - black) / max(float3(p.white) - black, float3(1.0f));
    if (p.pad0 > 0) {
        for (int c = 0; c < 3; c++) {
            value[c] *= gainAt(maps, p.pad0, gains, int(gid.x), int(gid.y), c, p.width, p.height);
        }
    }
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

// MARK: - Sensor cleanup

struct HotPixelParams {
    uint width;
    uint height;
    uint patternWidth;
    uint patternHeight;
    float threshold;     // noise sigmas above every neighbour
    float ratio;         // and this many times the brightest neighbour
    float pad1;
    float pad2;
    float4 a;            // noise per CFA colour, normalised units: variance = a · value + b
    float4 b;
};

// Replaces stuck-high photosites with the mean of their same-colour neighbours. A sample only
// counts as hot when it is several times brighter than every neighbour within two pixels, and
// well clear of their noise. The adjacent photosites of other colours count too: a white point
// highlight spills into those. Saturated colour detail finer than the colour's own sampling
// (red and blue are every other photosite) can exceed its neighbours, but not by the ratio.
kernel void rl_cfa_repair_hot_pixels(
    texture2d<float, access::read> cfa [[texture(0)]],
    texture2d<float, access::write> out [[texture(1)]],
    constant HotPixelParams &p [[buffer(0)]],
    constant uchar *pattern [[buffer(1)]],
    device atomic_uint *repaired [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.height) return;
    int x = int(gid.x);
    int y = int(gid.y);
    uint color = pattern[(gid.y % p.patternHeight) * p.patternWidth + gid.x % p.patternWidth];
    float value = cfa.read(gid).r;
    float highest = 0.0f;
    float sameSum = 0.0f;
    int sameCount = 0;
    for (int dy = -2; dy <= 2; dy++) {
        for (int dx = -2; dx <= 2; dx++) {
            int qx = x + dx;
            int qy = y + dy;
            if ((dx == 0 && dy == 0) || qx < 0 || qy < 0 || qx >= int(p.width) || qy >= int(p.height)) continue;
            float neighbour = cfa.read(uint2(qx, qy)).r;
            uint neighbourColor = pattern[(uint(qy) % p.patternHeight) * p.patternWidth + uint(qx) % p.patternWidth];
            bool adjacent = abs(dx) <= 1 && abs(dy) <= 1;
            if (neighbourColor == color) {
                sameSum += neighbour;
                sameCount++;
            }
            if (neighbourColor == color || adjacent) highest = max(highest, neighbour);
        }
    }
    float sigma = sqrt(max(p.a[color] * highest + p.b[color], 0.0f));
    if (sameCount > 0 && value > p.ratio * highest + p.threshold * sigma) {
        value = sameSum / float(sameCount);
        atomic_fetch_add_explicit(repaired, 1u, memory_order_relaxed);
    }
    out.write(float4(value), gid);
}

struct HighlightParams {
    uint width;
    uint height;
    uint patternWidth;
    uint patternHeight;
    float4 clip;         // xyz clip level per colour (white-balanced), w level for fully clipped areas
};

// Rebuilds clipped photosites from the unclipped colours around them (see HighlightModel):
// the prediction in cube-root space from the means of its bright neighbours (at least half their
// clip level: darker ones belong to another surface, such as a twig against the sky), never below the
// clip level and at most two stops above it. Where every colour clipped, the lowest neutral
// consistent with all of them.
kernel void rl_cfa_reconstruct_highlights(
    texture2d<float, access::read> cfa [[texture(0)]],
    texture2d<float, access::write> out [[texture(1)]],
    constant HighlightParams &p [[buffer(0)]],
    constant uchar *pattern [[buffer(1)]],
    constant float4 *model [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.height) return;
    uint color = pattern[(gid.y % p.patternHeight) * p.patternWidth + gid.x % p.patternWidth];
    float value = cfa.read(gid).r;
    if (value < p.clip[color]) {
        out.write(float4(value), gid);
        return;
    }
    float3 sums = 0.0f;
    float3 counts = 0.0f;
    for (int dy = -2; dy <= 2; dy++) {
        for (int dx = -2; dx <= 2; dx++) {
            int qx = int(gid.x) + dx;
            int qy = int(gid.y) + dy;
            if (qx < 0 || qy < 0 || qx >= int(p.width) || qy >= int(p.height)) continue;
            uint neighbourColor = pattern[(uint(qy) % p.patternHeight) * p.patternWidth + uint(qx) % p.patternWidth];
            float neighbour = cfa.read(uint2(qx, qy)).r;
            if (neighbour < p.clip[neighbourColor] && neighbour >= 0.5f * p.clip[neighbourColor]) {
                sums[neighbourColor] += neighbour;
                counts[neighbourColor] += 1.0f;
            }
        }
    }
    bool first = counts[(color + 1) % 3] > 0.0f;
    bool second = counts[(color + 2) % 3] > 0.0f;
    if (!first && !second) {
        out.write(float4(p.clip.w), gid);
        return;
    }
    float4 m = model[color * 3 + (first && second ? 0 : (first ? 1 : 2))];
    float3 means = select(float3(0.0f), sums / max(counts, float3(1.0f)), counts > 0.0f);
    float root = m.x + dot(m.yzw, powr(means, float3(1.0f / 3.0f)));
    float predicted = root > 0.0f ? root * root * root : 0.0f;
    out.write(float4(clamp(predicted, p.clip[color], 4.0f * p.clip[color])), gid);
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
    out.write(float4(max(rgb, 0.0f), 1.0f), gid);
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
    out.write(float4(max(rgb, 0.0f), 1.0f), gid);
}
