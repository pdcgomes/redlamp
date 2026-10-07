/*
 * Frank Markesteijn's demosaic for Fujifilm X-Trans sensors, one pass, ported to Metal for Redlamp
 * from LibRaw 0.22.2, src/demosaic/xtrans_demosaic.cpp (LibRaw::xtrans_interpolate).
 *
 * Original: Copyright 2019-2025 LibRaw LLC (info@libraw.org). LibRaw uses code from dcraw.c,
 * copyright 1997-2018 by Dave Coffin; LibRaw does not use RESTRICTED code from dcraw.c. LibRaw is
 * licensed under the GNU LGPL 2.1 or the CDDL 1.0, at the user's choice; Redlamp uses the CDDL.
 *
 * This file is covered by the Common Development and Distribution License (CDDL) Version 1.0
 * (LICENSES/CDDL-1.0.txt), not by the MPL-2.0 that covers the rest of Redlamp.
 *
 * Modifications by the Redlamp contributors, 2026: the CPU tiles became GPU kernels over bands of
 * rows; one pass only (three measured no better); floating-point samples, white-balanced and
 * normalised so that 1 is the clip level, with no clipping above it; colour conversion to CIELab
 * from the session's camera matrix; each kernel writes what its neighbours read in a separate
 * texture where LibRaw relied on the order of its loops.
 */

#include "RedlampShaderTypes.h"

struct XTransParams {
    uint width;          // the image
    uint height;
    uint bandTop;        // the image row of the band's first row
    uint bandRows;       // rows in the band, apron included
    uint outTop;         // image rows this band writes to the output
    uint outBottom;
    int solitaryRow;     // a solitary green's position in the 3 x 3 cell (LibRaw's sgrow, sgcol)
    int solitaryColumn;
    float4 xyzCam[3];    // camera RGB to XYZ, each row divided by D65's white (rows)
};

static inline int xmod(int v, int m) {
    int r = v % m;
    return r < 0 ? r + m : r;
}

static inline uint xcolor(constant uchar *pattern, int x, int y) {
    return pattern[xmod(y, 6) * 6 + xmod(x, 6)];
}

static inline float xsample(texture2d<float, access::read> cfa, int x, int y, constant XTransParams &p) {
    return cfa.read(uint2(clamp(x, 0, int(p.width) - 1), clamp(y, 0, int(p.height) - 1))).r;
}

static inline constant int2 *xhex(constant int2 *hex, int x, int y) {
    return hex + (xmod(y, 3) * 3 + xmod(x, 3)) * 8;
}

// LibRaw's image[][1] after its first loop: a green's own value, or a red or blue photosite's
// lowest green neighbour.
static inline float xgreen(texture2d<float, access::read> cfa, constant uchar *pattern, constant int2 *hex,
                           int x, int y, constant XTransParams &p) {
    if (xcolor(pattern, x, y) == 1) return xsample(cfa, x, y, p);
    constant int2 *h = xhex(hex, x, y);
    float lowest = INFINITY;
    for (int k = 0; k < 6; k++) lowest = min(lowest, xsample(cfa, x + h[k].x, y + h[k].y, p));
    return lowest;
}

// LibRaw's image[][f] for red or blue f: the photosite's value if it is that colour, else 0.
static inline float xchannel(texture2d<float, access::read> cfa, constant uchar *pattern, uint f,
                             int x, int y, constant XTransParams &p) {
    return xcolor(pattern, x, y) == f ? xsample(cfa, x, y, p) : 0.0f;
}

static inline uint2 xlocal(uint2 gid, int2 offset, constant XTransParams &p) {
    return uint2(clamp(int(gid.x) + offset.x, 0, int(p.width) - 1),
                 clamp(int(gid.y) + offset.y, 0, int(p.bandRows) - 1));
}

#define XPLANE(planes, d, offset) float4(planes.read(xlocal(gid, (offset), p), (d)))

// Green at red and blue photosites along four directions (horizontal, vertical and the two
// diagonals), limited to the range of the six nearest greens; every plane starts from the mosaic.
kernel void rl_xtrans_green(
    texture2d<float, access::read> cfa [[texture(0)]],
    texture2d_array<half, access::write> planes [[texture(1)]],
    constant XTransParams &p [[buffer(0)]],
    constant uchar *pattern [[buffer(1)]],
    constant int2 *hex [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.bandRows) return;
    int x = int(gid.x);
    int y = int(p.bandTop + gid.y);
    float v = xsample(cfa, x, y, p);
    uint f = xcolor(pattern, x, y);
    if (f == 1) {
        for (uint d = 0; d < 4; d++) planes.write(half4(0.0h, half(v), 0.0h, 1.0h), gid, d);
        return;
    }
    constant int2 *h = xhex(hex, x, y);
    float lowest = INFINITY, highest = -INFINITY;
    for (int k = 0; k < 6; k++) {
        float g = xsample(cfa, x + h[k].x, y + h[k].y, p);
        lowest = min(lowest, g);
        highest = max(highest, g);
    }
    #define G(o) xgreen(cfa, pattern, hex, x + (o).x, y + (o).y, p)
    #define F(o) xchannel(cfa, pattern, f, x + (o).x, y + (o).y, p)
    float c[4];
    c[0] = 174.0f * (G(h[1]) + G(h[0])) - 46.0f * (G(2 * h[1]) + G(2 * h[0]));
    c[1] = 223.0f * G(h[3]) + 33.0f * G(h[2]) + 92.0f * (v - F(-h[2]));
    for (int k = 0; k < 2; k++) {
        c[2 + k] = 164.0f * G(h[4 + k]) + 92.0f * G(-2 * h[4 + k])
            + 33.0f * (2.0f * v - F(3 * h[4 + k]) - F(-3 * h[4 + k]));
    }
    #undef G
    #undef F
    uint flip = xmod(y - p.solitaryRow, 3) == 0 ? 1u : 0u;
    for (uint k = 0; k < 4; k++) {
        float g = clamp(c[k] / 256.0f, lowest, highest);
        planes.write(half4(half(f == 0 ? v : 0.0f), half(g), half(f == 2 ? v : 0.0f), 1.0h), gid, k ^ flip);
    }
}

// Red and blue at solitary greens, horizontally, vertically and (for the diagonal planes) along
// whichever of two candidates disagrees least with green.
kernel void rl_xtrans_solitary(
    texture2d_array<half, access::read_write> planes [[texture(0)]],
    constant XTransParams &p [[buffer(0)]],
    constant uchar *pattern [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.bandRows) return;
    int x = int(gid.x);
    int y = int(p.bandTop + gid.y);
    if (xmod(y - p.solitaryRow, 3) != 0 || xmod(x - p.solitaryColumn, 3) != 0) return;
    int h = int(xcolor(pattern, x + 1, y));
    if (h == 1) return;
    float diff[6] = {0, 0, 0, 0, 0, 0};
    float colour[3][6];
    int2 i = int2(1, 0);
    uint plane = 0;
    for (int d = 0; d < 6; d++) {
        for (int c = 0; c < 2; c++) {
            int2 o = i * (1 << c);
            float4 centre = XPLANE(planes, plane, int2(0));
            float4 ahead = XPLANE(planes, plane, o);
            float4 behind = XPLANE(planes, plane, -o);
            float g = 2.0f * centre.g - ahead.g - behind.g;
            colour[h][d] = g + ahead[h] + behind[h];
            if (d > 1) {
                float t = ahead.g - behind.g - ahead[h] + behind[h];
                diff[d] += t * t + g * g;
            }
            h ^= 2;
        }
        if (d > 1 && (d & 1) && diff[d - 1] < diff[d]) {
            colour[0][d] = colour[0][d - 1];
            colour[2][d] = colour[2][d - 1];
        }
        if (d < 2 || (d & 1)) {
            float4 current = XPLANE(planes, plane, int2(0));
            planes.write(half4(half(max(colour[0][d] / 2.0f, 0.0f)), half(current.g),
                               half(max(colour[2][d] / 2.0f, 0.0f)), 1.0h), gid, plane);
            plane++;
        }
        i = i.yx;
        h ^= 2;
    }
}

// Red at blue photosites and blue at red ones, from the pair partner or the solitary greens three
// photosites away, whichever green agrees with. Written to `scratch`, merged by the next kernel.
kernel void rl_xtrans_opposite(
    texture2d_array<half, access::read> planes [[texture(0)]],
    texture2d_array<half, access::write> scratch [[texture(1)]],
    constant XTransParams &p [[buffer(0)]],
    constant uchar *pattern [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.bandRows) return;
    int x = int(gid.x);
    int y = int(p.bandTop + gid.y);
    uint own = xcolor(pattern, x, y);
    if (own == 1) return;
    uint f = 2 - own;
    bool vertical = xmod(y - p.solitaryRow, 3) != 0;
    int2 near = vertical ? int2(0, 1) : int2(1, 0);
    int2 far = vertical ? int2(3, 0) : int2(0, 3);
    for (uint d = 0; d < 4; d++) {
        float g0 = XPLANE(planes, d, int2(0)).g;
        bool parity = vertical ? (d & 1) != 0 : (d & 1) == 0;
        bool useNear = d > 1 || parity
            || (abs(g0 - XPLANE(planes, d, near).g) + abs(g0 - XPLANE(planes, d, -near).g))
                < 2.0f * (abs(g0 - XPLANE(planes, d, far).g) + abs(g0 - XPLANE(planes, d, -far).g));
        int2 o = useNear ? near : far;
        float4 ahead = XPLANE(planes, d, o);
        float4 behind = XPLANE(planes, d, -o);
        float value = (ahead[f] + behind[f] + 2.0f * g0 - ahead.g - behind.g) / 2.0f;
        scratch.write(half4(half(max(value, 0.0f)), 0.0h, 0.0h, 0.0h), gid, d);
    }
}

kernel void rl_xtrans_opposite_merge(
    texture2d_array<half, access::read_write> planes [[texture(0)]],
    texture2d_array<half, access::read> scratch [[texture(1)]],
    constant XTransParams &p [[buffer(0)]],
    constant uchar *pattern [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.bandRows) return;
    uint own = xcolor(pattern, int(gid.x), int(p.bandTop + gid.y));
    if (own == 1) return;
    uint f = 2 - own;
    for (uint d = 0; d < 4; d++) {
        half4 value = planes.read(gid, d);
        value[f] = scratch.read(gid, d).x;
        planes.write(value, gid, d);
    }
}

// Red and blue at the greens of 2 x 2 green blocks, from the hexagon's neighbours along each
// plane's direction. Written to `scratch`, merged by the next kernel.
kernel void rl_xtrans_blocks(
    texture2d_array<half, access::read> planes [[texture(0)]],
    texture2d_array<half, access::write> scratch [[texture(1)]],
    constant XTransParams &p [[buffer(0)]],
    constant int2 *hex [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.bandRows) return;
    int x = int(gid.x);
    int y = int(p.bandTop + gid.y);
    if (xmod(y - p.solitaryRow, 3) == 0 || xmod(x - p.solitaryColumn, 3) == 0) return;
    constant int2 *h = xhex(hex, x, y);
    for (uint d = 0; d < 4; d++) {
        int2 a = h[2 * d];
        int2 b = h[2 * d + 1];
        float g0 = XPLANE(planes, d, int2(0)).g;
        float4 pa = XPLANE(planes, d, a);
        float4 pb = XPLANE(planes, d, b);
        float red, blue;
        if (any(a + b != int2(0))) {
            float g = 3.0f * g0 - 2.0f * pa.g - pb.g;
            red = (g + 2.0f * pa.r + pb.r) / 3.0f;
            blue = (g + 2.0f * pa.b + pb.b) / 3.0f;
        } else {
            float g = 2.0f * g0 - pa.g - pb.g;
            red = (g + pa.r + pb.r) / 2.0f;
            blue = (g + pa.b + pb.b) / 2.0f;
        }
        scratch.write(half4(half(max(red, 0.0f)), half(max(blue, 0.0f)), 0.0h, 0.0h), gid, d);
    }
}

kernel void rl_xtrans_blocks_merge(
    texture2d_array<half, access::read_write> planes [[texture(0)]],
    texture2d_array<half, access::read> scratch [[texture(1)]],
    constant XTransParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.bandRows) return;
    int x = int(gid.x);
    int y = int(p.bandTop + gid.y);
    if (xmod(y - p.solitaryRow, 3) == 0 || xmod(x - p.solitaryColumn, 3) == 0) return;
    for (uint d = 0; d < 4; d++) {
        half4 value = planes.read(gid, d);
        half4 s = scratch.read(gid, d);
        value.r = s.x;
        value.b = s.y;
        planes.write(value, gid, d);
    }
}

static inline float xlabf(float t) {
    return t > 0.008856f ? pow(t, 1.0f / 3.0f) : 7.787f * t + 16.0f / 116.0f;
}

static inline float3 xlab(float3 rgb, constant XTransParams &p) {
    float3 xyz = clamp(float3(dot(p.xyzCam[0].xyz, rgb), dot(p.xyzCam[1].xyz, rgb), dot(p.xyzCam[2].xyz, rgb)),
                       0.0f, 1.0f);
    float3 f = float3(xlabf(xyz.x), xlabf(xyz.y), xlabf(xyz.z));
    return float3(116.0f * f.y - 16.0f, 500.0f * (f.x - f.y), 200.0f * (f.y - f.z));
}

// How much each plane's CIELab bends along its own direction at each pixel.
kernel void rl_xtrans_derivatives(
    texture2d_array<half, access::read> planes [[texture(0)]],
    texture2d_array<float, access::write> derivatives [[texture(1)]],
    constant XTransParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.bandRows) return;
    const int2 steps[4] = {int2(1, 0), int2(0, 1), int2(1, 1), int2(-1, 1)};
    for (uint d = 0; d < 4; d++) {
        float3 l0 = xlab(XPLANE(planes, d, int2(0)).rgb, p);
        float3 la = xlab(XPLANE(planes, d, steps[d]).rgb, p);
        float3 lb = xlab(XPLANE(planes, d, -steps[d]).rgb, p);
        float g = 2.0f * l0.x - la.x - lb.x;
        float a = 2.0f * l0.y - la.y - lb.y + g * 500.0f / 232.0f;
        float b = 2.0f * l0.z - la.z - lb.z - g * 500.0f / 580.0f;
        derivatives.write(float4(g * g + a * a + b * b), gid, d);
    }
}

// Per plane, how many of the 3 x 3 neighbours bend no more than 8 times the flattest plane here.
kernel void rl_xtrans_homogeneity(
    texture2d_array<float, access::read> derivatives [[texture(0)]],
    texture2d_array<uint, access::write> homogeneity [[texture(1)]],
    constant XTransParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.bandRows) return;
    float threshold = INFINITY;
    for (uint d = 0; d < 4; d++) threshold = min(threshold, derivatives.read(gid, d).r);
    threshold *= 8.0f;
    for (uint d = 0; d < 4; d++) {
        uint count = 0;
        for (int v = -1; v <= 1; v++) {
            for (int h = -1; h <= 1; h++) {
                if (derivatives.read(xlocal(gid, int2(h, v), p), d).r <= threshold) count++;
            }
        }
        homogeneity.write(uint4(count), gid, d);
    }
}

// The average of the planes that are most homogeneous over 5 x 5, into the band's output rows.
// The 8 photosites at the image's edges keep the generic interpolation written before.
kernel void rl_xtrans_average(
    texture2d_array<half, access::read> planes [[texture(0)]],
    texture2d_array<uint, access::read> homogeneity [[texture(1)]],
    texture2d<float, access::write> out [[texture(2)]],
    constant XTransParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.bandRows) return;
    uint y = p.bandTop + gid.y;
    if (y < p.outTop || y >= p.outBottom || y < 8 || y + 8 >= p.height || gid.x < 8 || gid.x + 8 >= p.width) return;
    uint sums[4];
    uint best = 0;
    for (uint d = 0; d < 4; d++) {
        sums[d] = 0;
        for (int v = -2; v <= 2; v++) {
            for (int h = -2; h <= 2; h++) sums[d] += homogeneity.read(xlocal(gid, int2(h, v), p), d).r;
        }
        best = max(best, sums[d]);
    }
    best -= best >> 3;
    float3 total = 0.0f;
    float count = 0.0f;
    for (uint d = 0; d < 4; d++) {
        if (sums[d] >= best) {
            total += XPLANE(planes, d, int2(0)).rgb;
            count += 1.0f;
        }
    }
    out.write(float4(max(total / count, 0.0f), 1.0f), uint2(gid.x, y));
}
