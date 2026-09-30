#include "RedlampShaderTypes.h"

// Bayer demosaicing with directional filtering and a posteriori decision (D. Menon, S. Andriani
// and G. Calvagno, IEEE Transactions on Image Processing 16(1), 2007), from the paper:
//   1. green at red and blue sites, estimated along rows and along columns with the
//      [-1/4, 1/2, 1/2, 1/2, -1/4] filter, and each direction's colour difference;
//   2. per pixel, the direction whose colour difference varies least over a 5 x 5 window;
//   3. red and blue at green sites from the neighbouring colour differences;
//   4. the missing red or blue at blue and red sites along the chosen direction.

struct MenonParams {
    uint width;
    uint height;
    uint patternWidth;
    uint patternHeight;
};

static inline int reflectIndex(int v, int size) {
    if (v < 0) v = -v;
    if (v >= size) v = 2 * (size - 1) - v;
    return clamp(v, 0, size - 1);
}

static inline float cfaAt(texture2d<float, access::read> t, int x, int y, constant MenonParams &p) {
    return t.read(uint2(reflectIndex(x, int(p.width)), reflectIndex(y, int(p.height)))).r;
}

// Reflection keeps Bayer parity, so the colour at a reflected position is the colour here.
static inline uint colorAt(constant uchar *pattern, int x, int y, constant MenonParams &p) {
    uint px = uint(reflectIndex(x, int(p.width))) % p.patternWidth;
    uint py = uint(reflectIndex(y, int(p.height))) % p.patternHeight;
    return pattern[py * p.patternWidth + px];
}

// Pass 1: xy green along rows and columns, zw the colour difference (non-green minus green)
// along rows and columns.
kernel void rl_menon_directional(
    texture2d<float, access::read> cfa [[texture(0)]],
    texture2d<float, access::write> out [[texture(1)]],
    constant MenonParams &p [[buffer(0)]],
    constant uchar *pattern [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.height) return;
    int x = int(gid.x);
    int y = int(gid.y);
    float c = cfaAt(cfa, x, y, p);
    // The same filter estimates green at a red or blue site, or the row's (column's) other
    // colour at a green site.
    float alongRow = 0.5f * (cfaAt(cfa, x - 1, y, p) + cfaAt(cfa, x + 1, y, p))
        + 0.25f * (2.0f * c - cfaAt(cfa, x - 2, y, p) - cfaAt(cfa, x + 2, y, p));
    float alongColumn = 0.5f * (cfaAt(cfa, x, y - 1, p) + cfaAt(cfa, x, y + 1, p))
        + 0.25f * (2.0f * c - cfaAt(cfa, x, y - 2, p) - cfaAt(cfa, x, y + 2, p));
    if (colorAt(pattern, x, y, p) == 1) {
        out.write(float4(c, c, alongRow - c, alongColumn - c), gid);
    } else {
        out.write(float4(alongRow, alongColumn, c - alongRow, c - alongColumn), gid);
    }
}

// Pass 2: green, and the chosen direction (1 rows, -1 columns, 0 both).
kernel void rl_menon_green(
    texture2d<float, access::read> cfa [[texture(0)]],
    texture2d<float, access::read> directional [[texture(1)]],
    texture2d<float, access::write> out [[texture(2)]],
    texture2d<float, access::write> directions [[texture(3)]],
    constant MenonParams &p [[buffer(0)]],
    constant uchar *pattern [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.height) return;
    int x = int(gid.x);
    int y = int(gid.y);
    float rows = 0.0f;
    float columns = 0.0f;
    for (int dy = -2; dy <= 2; dy++) {
        for (int dx = -2; dx <= 2; dx++) {
            int qx = reflectIndex(x + dx, int(p.width));
            int qy = reflectIndex(y + dy, int(p.height));
            float4 here = directional.read(uint2(qx, qy));
            float4 right = directional.read(uint2(reflectIndex(qx + 2, int(p.width)), qy));
            float4 below = directional.read(uint2(qx, reflectIndex(qy + 2, int(p.height))));
            rows += abs(here.z - right.z);
            columns += abs(here.w - below.w);
        }
    }
    float direction = rows < columns ? 1.0f : (columns < rows ? -1.0f : 0.0f);
    float green;
    if (colorAt(pattern, x, y, p) == 1) {
        green = cfaAt(cfa, x, y, p);
    } else {
        float4 d = directional.read(gid);
        green = direction > 0.0f ? d.x : (direction < 0.0f ? d.y : 0.5f * (d.x + d.y));
    }
    out.write(float4(green), gid);
    directions.write(float4(direction), gid);
}

// Pass 3: RGB with red and blue filled at green sites.
kernel void rl_menon_rb_at_green(
    texture2d<float, access::read> cfa [[texture(0)]],
    texture2d<float, access::read> green [[texture(1)]],
    texture2d<float, access::write> out [[texture(2)]],
    constant MenonParams &p [[buffer(0)]],
    constant uchar *pattern [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.height) return;
    int x = int(gid.x);
    int y = int(gid.y);
    float g = green.read(gid).x;
    uint color = colorAt(pattern, x, y, p);
    float3 rgb = float3(g);
    if (color == 1) {
        // Each green site has one colour along its row and the other along its column.
        float rowDifference = 0.5f * (cfaAt(cfa, x - 1, y, p) - green.read(uint2(reflectIndex(x - 1, int(p.width)), y)).x
            + cfaAt(cfa, x + 1, y, p) - green.read(uint2(reflectIndex(x + 1, int(p.width)), y)).x);
        float columnDifference = 0.5f * (cfaAt(cfa, x, y - 1, p) - green.read(uint2(x, reflectIndex(y - 1, int(p.height)))).x
            + cfaAt(cfa, x, y + 1, p) - green.read(uint2(x, reflectIndex(y + 1, int(p.height)))).x);
        uint rowColor = colorAt(pattern, x + 1, y, p);
        uint columnColor = colorAt(pattern, x, y + 1, p);
        rgb[rowColor] = g + rowDifference;
        rgb[columnColor] = g + columnDifference;
    } else {
        rgb[color] = cfaAt(cfa, x, y, p);
    }
    out.write(float4(rgb, 1.0f), gid);
}

// A green site's difference between one colour and green, from pass 3.
static inline float differenceAt(texture2d<float, access::read> partial, int x, int y, uint channel,
                                 constant MenonParams &p) {
    float4 q = partial.read(uint2(reflectIndex(x, int(p.width)), reflectIndex(y, int(p.height))));
    return q[channel] - q.g;
}

// Pass 4: the missing colour at red and blue sites, from the colour difference at the green
// neighbours along the chosen direction; written to the pyramid's full-resolution level.
kernel void rl_menon_rb_at_rb(
    texture2d<float, access::read> partial [[texture(0)]],
    texture2d<float, access::read> directions [[texture(1)]],
    texture2d<float, access::write> out [[texture(2)]],
    constant MenonParams &p [[buffer(0)]],
    constant uchar *pattern [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.height) return;
    int x = int(gid.x);
    int y = int(gid.y);
    float4 here = partial.read(gid);
    float3 rgb = here.rgb;
    uint color = colorAt(pattern, x, y, p);
    if (color != 1) {
        uint missing = 2 - color;
        float rows = 0.5f * (differenceAt(partial, x - 1, y, missing, p) + differenceAt(partial, x + 1, y, missing, p));
        float columns = 0.5f * (differenceAt(partial, x, y - 1, missing, p) + differenceAt(partial, x, y + 1, missing, p));
        float direction = directions.read(gid).x;
        float d = direction > 0.0f ? rows : (direction < 0.0f ? columns : 0.5f * (rows + columns));
        rgb[missing] = rgb.g + d;
    }
    out.write(float4(max(rgb, 0.0f), 1.0f), gid);
}
