#include "RedlampShaderTypes.h"

// MARK: - Color helpers

constant float3 kRec2020Luma = float3(0.2627f, 0.6780f, 0.0593f);
constant float kMiddleGrey = 0.18f;
constant float kBandHues[8] = { 25.0f, 55.0f, 100.0f, 140.0f, 195.0f, 255.0f, 300.0f, 340.0f };

static inline float3 mul3(float4 r0, float4 r1, float4 r2, float3 v) {
    return float3(dot(r0.xyz, v), dot(r1.xyz, v), dot(r2.xyz, v));
}

static inline float signedCbrt(float x) { return sign(x) * pow(abs(x), 1.0f / 3.0f); }

// Björn Ottosson's OKLab, from linear Rec.2020 (his linear-sRGB matrices composed with
// Rec.2020 -> sRGB, so values match the sRGB-based OKLab in RedlampColor).
static inline float3 rec2020ToOKLab(float3 c) {
    float l = 0.6167557872f * c.r + 0.3601983994f * c.g + 0.0230458134f * c.b;
    float m = 0.2651330640f * c.r + 0.6358393641f * c.g + 0.0990275718f * c.b;
    float s = 0.1001026342f * c.r + 0.2039065194f * c.g + 0.6959908464f * c.b;
    l = signedCbrt(l); m = signedCbrt(m); s = signedCbrt(s);
    return float3(
        0.2104542553f * l + 0.7936177850f * m - 0.0040720468f * s,
        1.9779984951f * l - 2.4285922050f * m + 0.4505937099f * s,
        0.0259040371f * l + 0.7827717662f * m - 0.8086757660f * s);
}

static inline float3 okLabToRec2020(float3 lab) {
    float l = lab.x + 0.3963377774f * lab.y + 0.2158037573f * lab.z;
    float m = lab.x - 0.1055613458f * lab.y - 0.0638541728f * lab.z;
    float s = lab.x - 0.0894841775f * lab.y - 1.2914855480f * lab.z;
    l = l * l * l; m = m * m * m; s = s * s * s;
    return float3(
        2.1399067357f * l - 1.2463895088f * m + 0.1064827730f * s,
        -0.8847358625f * l + 2.1632309821f * m - 0.2784951194f * s,
        -0.0485737580f * l - 0.4545031429f * m + 1.5030769009f * s);
}

static inline float srgbEncode(float x) {
    return x <= 0.0031308f ? 12.92f * x : 1.055f * pow(x, 1.0f / 2.4f) - 0.055f;
}

static inline float srgbDecode(float x) {
    return x <= 0.04045f ? x / 12.92f : pow((x + 0.055f) / 1.055f, 2.4f);
}

static inline float3 srgbEncode3(float3 c) { return float3(srgbEncode(c.r), srgbEncode(c.g), srgbEncode(c.b)); }
static inline float3 srgbDecode3(float3 c) { return float3(srgbDecode(c.r), srgbDecode(c.g), srgbDecode(c.b)); }

// Filmic curve (Narkowicz's ACES fit).
static inline float filmic(float x) {
    return (x * (2.51f * x + 0.03f)) / (x * (2.43f * x + 0.59f) + 0.14f);
}

// Scene -> display tone curve. Below 0.8 display (about +1.6 EV above middle grey) it is the
// filmic curve normalised so scene 1.0 maps to 1. Above that, a shoulder in log2 space that
// joins with matching slope and reaches white smoothly at +4 EV, so highlights roll off over
// 1.5 EV beyond the old clip point while sensor-saturated areas still render white.
constant float kShoulderStart = 0.54358851f;    // scene value where the curve reaches 0.8
constant float kShoulderStartY = 0.8f;
constant float kShoulderWidthEV = 2.40548194f;  // join to white (0.18 * 2^4)
constant float kShoulderPower = 3.25537943f;    // matches the filmic slope at the join
constant float kFilmicAtOne = 0.80379747f;

static inline float toneCurveChannel(float x) {
    if (x <= kShoulderStart) return filmic(x) / kFilmicAtOne;
    float u = min(log2(x / kShoulderStart) / kShoulderWidthEV, 1.0f);
    return 1.0f - (1.0f - kShoulderStartY) * pow(1.0f - u, kShoulderPower);
}

// Per-channel curve, with each channel's position between the smallest and largest kept, so
// hue survives the curve and bright saturated colors head towards white without shifting.
static inline float3 toneCurve(float3 x) {
    float3 y = float3(toneCurveChannel(x.r), toneCurveChannel(x.g), toneCurveChannel(x.b));
    float lo = min3(x.r, x.g, x.b);
    float hi = max3(x.r, x.g, x.b);
    if (hi - lo < 1e-7f) return y;
    float yLo = min3(y.r, y.g, y.b);
    float yHi = max3(y.r, y.g, y.b);
    return yLo + (yHi - yLo) * (x - lo) / (hi - lo);
}

// The tone curve's exact inverse, for input that is already display-referred (a JPEG): the
// filmic part is a quadratic in x, the shoulder a power in log2.
static inline float inverseToneCurveChannel(float y) {
    y = clamp(y, 0.0f, 1.0f);
    if (y <= kShoulderStartY) {
        float t = y * kFilmicAtOne;
        float a = 2.43f * t - 2.51f, b = 0.59f * t - 0.03f, c = 0.14f * t;
        return max((-b - sqrt(max(b * b - 4.0f * a * c, 0.0f))) / (2.0f * a), 0.0f);
    }
    float u = 1.0f - pow((1.0f - y) / (1.0f - kShoulderStartY), 1.0f / kShoulderPower);
    return kShoulderStart * exp2(u * kShoulderWidthEV);
}

static inline float3 inverseToneCurve(float3 y) {
    float3 x = float3(inverseToneCurveChannel(y.r), inverseToneCurveChannel(y.g), inverseToneCurveChannel(y.b));
    float lo = min3(y.r, y.g, y.b);
    float hi = max3(y.r, y.g, y.b);
    if (hi - lo < 1e-7f) return x;
    float xLo = inverseToneCurveChannel(lo);
    float xHi = inverseToneCurveChannel(hi);
    return xLo + (xHi - xLo) * (y - lo) / (hi - lo);
}

// Fits a linear Rec.2020 color into the output gamut: channels are clipped to [0, 1], then each
// channel's position between the smallest and largest is restored. That keeps hue and nearly all
// saturation; mapping at constant OKLab lightness instead visibly dulls vivid colors.
static inline float3 gamutMap(float3 rec2020, constant DevelopParams &p) {
    float3 rgb = mul3(p.displayToOutput0, p.displayToOutput1, p.displayToOutput2, rec2020);
    float3 clipped = clamp(rgb, 0.0f, 1.0f);
    float lo = min3(rgb.r, rgb.g, rgb.b);
    float hi = max3(rgb.r, rgb.g, rgb.b);
    if (hi - lo < 1e-7f) return clipped;
    float clippedLo = min3(clipped.r, clipped.g, clipped.b);
    float clippedHi = max3(clipped.r, clipped.g, clipped.b);
    return clippedLo + (clippedHi - clippedLo) * (rgb - lo) / (hi - lo);
}

// The most chroma an OKLab lightness and hue can have inside the output gamut (bisection).
static inline float maxChroma(float lightness, float hueRadians, constant DevelopParams &p) {
    float2 direction = float2(cos(hueRadians), sin(hueRadians));
    float inside = 0.0f;
    float outside = 0.5f;
    for (int i = 0; i < 10; i++) {
        float c = 0.5f * (inside + outside);
        float3 rgb = mul3(p.displayToOutput0, p.displayToOutput1, p.displayToOutput2,
                          okLabToRec2020(float3(lightness, c * direction)));
        bool fits = all(rgb >= -1e-4f) && all(rgb <= 1.0001f);
        inside = fits ? c : inside;
        outside = fits ? outside : c;
    }
    return inside;
}

// Gamut-relative saturation: a boost from `chroma` towards `target` approaches the gamut
// boundary instead of passing it, so already vivid colours don't clip flat. Small boosts are
// unchanged; reductions pass through.
static inline float boostChroma(float chroma, float target, float lightness, float hueRadians,
                                constant DevelopParams &p) {
    if (target <= chroma) return target;
    float headroom = maxChroma(lightness, hueRadians, p) - chroma;
    if (headroom <= 1e-5f) return chroma;
    return chroma + headroom * (1.0f - exp(-(target - chroma) / headroom));
}

static inline float hueDistance(float a, float b) {
    float d = fmod(abs(a - b), 360.0f);
    return d > 180.0f ? 360.0f - d : d;
}

static inline float hueBump(float hue, float centre, float width) {
    float d = hueDistance(hue, centre) / width;
    return d >= 1.0f ? 0.0f : 0.5f + 0.5f * cos(d * M_PI_F);
}

static inline float sampleLUT(constant float *lut, float x) {
    float position = clamp(x, 0.0f, 1.0f) * 1023.0f;
    uint i = uint(position);
    uint j = min(i + 1, 1023u);
    return mix(lut[i], lut[j], position - float(i));
}

// MARK: - Base Look tables

// SceneLogEncoding in RedlampEngineAPI: stops from middle grey, -10...+6.5 EV to 0...1.
constant float kSceneLogMinimumEV = -10.0f;
constant float kSceneLogRangeEV = 16.5f;

static inline float3 sceneLogEncode3(float3 linear) {
    float3 ev = log2(max(linear, 1e-9f) / kMiddleGrey);
    return clamp((ev - kSceneLogMinimumEV) / kSceneLogRangeEV, 0.0f, 1.0f);
}

static inline float3 lookTableEntry(texture3d<half, access::read> table, int3 p) {
    return float3(table.read(uint3(p)).rgb);
}

// Tetrahedral interpolation of a size³ table (matches LookTable.sample on the CPU).
static inline float3 sampleLookTable(texture3d<half, access::read> table, float3 c, float size) {
    float n = size - 1.0f;
    float3 p = clamp(c, 0.0f, 1.0f) * n;
    int3 b = min(int3(p), int3(int(n) - 1));
    float3 f = p - float3(b);
    float3 c000 = lookTableEntry(table, b);
    float3 c111 = lookTableEntry(table, b + int3(1, 1, 1));
    if (f.x > f.y) {
        if (f.y > f.z) {
            float3 c100 = lookTableEntry(table, b + int3(1, 0, 0)), c110 = lookTableEntry(table, b + int3(1, 1, 0));
            return c000 + f.x * (c100 - c000) + f.y * (c110 - c100) + f.z * (c111 - c110);
        } else if (f.x > f.z) {
            float3 c100 = lookTableEntry(table, b + int3(1, 0, 0)), c101 = lookTableEntry(table, b + int3(1, 0, 1));
            return c000 + f.x * (c100 - c000) + f.z * (c101 - c100) + f.y * (c111 - c101);
        } else {
            float3 c001 = lookTableEntry(table, b + int3(0, 0, 1)), c101 = lookTableEntry(table, b + int3(1, 0, 1));
            return c000 + f.z * (c001 - c000) + f.x * (c101 - c001) + f.y * (c111 - c101);
        }
    }
    if (f.z > f.y) {
        float3 c001 = lookTableEntry(table, b + int3(0, 0, 1)), c011 = lookTableEntry(table, b + int3(0, 1, 1));
        return c000 + f.z * (c001 - c000) + f.y * (c011 - c001) + f.x * (c111 - c011);
    } else if (f.z > f.x) {
        float3 c010 = lookTableEntry(table, b + int3(0, 1, 0)), c011 = lookTableEntry(table, b + int3(0, 1, 1));
        return c000 + f.y * (c010 - c000) + f.z * (c011 - c010) + f.x * (c111 - c011);
    }
    float3 c010 = lookTableEntry(table, b + int3(0, 1, 0)), c110 = lookTableEntry(table, b + int3(1, 1, 0));
    return c000 + f.y * (c010 - c000) + f.x * (c110 - c010) + f.z * (c111 - c110);
}

static inline float hash(uint2 p, uint seed) {
    uint n = p.x * 1973u + p.y * 9277u + seed * 26699u;
    n = (n << 13u) ^ n;
    n = n * (n * n * 15731u + 789221u) + 1376312589u;
    return float(n & 0x7fffffffu) / float(0x7fffffff);
}

static inline float valueNoise(float2 p, uint seed) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0f - 2.0f * f);
    uint2 c = uint2(int2(i) + 100000);
    float a = hash(c, seed);
    float b = hash(c + uint2(1, 0), seed);
    float cc = hash(c + uint2(0, 1), seed);
    float d = hash(c + uint2(1, 1), seed);
    return mix(mix(a, b, f.x), mix(cc, d, f.x), f.y);
}

// One channel of grain: a coarse and a fine octave of value noise, `size` full-resolution
// pixels across. With a `footprint` (full-resolution pixels per output pixel, 0 at full
// resolution or above) octaves finer than a pixel are sampled at the pixel and attenuated by
// how many grains it averages.
static inline float grainNoise(float2 position, float size, float footprint, float roughness, uint coarseSeed, uint fineSeed) {
    float fineSize = size * 0.5f;
    float coarse = (valueNoise(position / max(size, footprint), coarseSeed) - 0.5f)
        * (footprint > 0.0f ? min(1.0f, size / footprint) : 1.0f);
    float fine = (valueNoise(position / max(fineSize, footprint), fineSeed) - 0.5f)
        * (footprint > 0.0f ? min(1.0f, fineSize / footprint) : 1.0f);
    return mix(coarse, fine, roughness);
}

// MARK: - Mood effects

// Two or three soft, coloured glows from just outside the frame's edges (mostly the sides, where
// light gets in at a camera's film gate), screened over the image. `mood.y` turns them from cool
// (-1) to warm (+1); `mood.z` picks a different arrangement.
static inline float3 lightLeak(float3 encoded, float2 q, float aspect, float4 mood) {
    uint seed = uint(mood.z * 997.0f) + 3u;
    float3 leak = 0.0f;
    for (uint i = 0; i < 3; i++) {
        if (i == 2 && hash(uint2(i, 9u), seed) < 0.5f) break;
        float side = hash(uint2(i, 1u), seed);
        float along = mix(0.1f, 0.9f, hash(uint2(i, 2u), seed));
        float size = mix(0.3f, 0.75f, hash(uint2(i, 3u), seed));
        float2 centre, scale;
        if (side < 0.42f) { centre = float2(-0.1f, along); scale = float2(size * 0.55f, size); }
        else if (side < 0.84f) { centre = float2(aspect + 0.1f, along); scale = float2(size * 0.55f, size); }
        else if (side < 0.92f) { centre = float2(along * aspect, -0.1f); scale = float2(size, size * 0.55f); }
        else { centre = float2(along * aspect, 1.1f); scale = float2(size, size * 0.55f); }
        float2 d = (q - centre) / scale;
        float w = exp(-2.0f * dot(d, d));
        float3 warm = mix(float3(1.0f, 0.42f, 0.08f), float3(1.0f, 0.15f, 0.2f), hash(uint2(i, 4u), seed));
        warm = mix(warm, float3(1.0f, 0.82f, 0.32f), 0.35f * hash(uint2(i, 5u), seed));
        float3 cool = mix(float3(0.25f, 0.55f, 1.0f), float3(0.6f, 0.3f, 1.0f), hash(uint2(i, 4u), seed));
        leak += mix(cool, warm, 0.5f + 0.5f * mood.y) * w;
    }
    leak = min(leak * mood.x * 1.2f, 1.0f);
    return 1.0f - (1.0f - encoded) * (1.0f - leak);
}

// Dust: at most one speck per cell of 60 frame pixels, mostly small and dark (dust on a scanned
// negative or slide), a few bright. A speck smaller than an output pixel fades by its share of it.
static inline float3 dust(float3 encoded, float2 position, float framePixel, float footprint, float amount) {
    float cell = 60.0f * framePixel;
    int2 c = int2(floor(position / cell));
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int2 at = c + int2(dx, dy);
            uint2 key = uint2(at + 100000);
            if (hash(key, 41u) >= 0.06f * amount) continue;
            float2 centre = (float2(at) + float2(hash(key, 43u), hash(key, 47u))) * cell;
            float radius = mix(1.2f, 9.0f, pow(hash(key, 53u), 2.5f)) * framePixel;
            float2 offset = position - centre;
            float stretch = mix(1.0f, 2.5f, hash(key, 61u));
            float angle = hash(key, 67u) * 6.2831853f;
            float2 axis = float2(cos(angle), sin(angle));
            float along = dot(offset, axis) / stretch;
            float across = dot(offset, float2(-axis.y, axis.x));
            float distance = length(float2(along, across));
            float soft = max(radius * 0.35f, footprint * 0.5f);
            float coverage = (1.0f - smoothstep(radius - soft, radius + soft, distance))
                * min(1.0f, radius * radius / (footprint * footprint));
            float3 speck = hash(key, 59u) < 0.75f ? float3(0.04f) : float3(0.96f);
            encoded = mix(encoded, speck, coverage * 0.85f);
        }
    }
    return encoded;
}

// Scratches: fine vertical lines down the frame, as a film's travel through a camera or
// projector leaves them, flickering in strength along their length.
static inline float3 scratches(float3 encoded, float2 position, float2 fullSize, float framePixel, float footprint, float amount) {
    float bucket = 45.0f * framePixel;
    int b = int(floor(position.x / bucket));
    for (int db = -1; db <= 1; db++) {
        uint2 key = uint2(uint(b + db + 100000), 7u);
        if (hash(key, 71u) >= 0.05f * amount) continue;
        float x = (float(b + db) + hash(key, 73u)) * bucket;
        float width = mix(1.0f, 3.0f, hash(key, 79u)) * framePixel;
        float start = hash(key, 83u) * fullSize.y * 0.7f;
        float extent = mix(0.3f, 1.0f, hash(key, 89u)) * fullSize.y;
        float inside = smoothstep(start, start + 40.0f * framePixel, position.y)
            * (1.0f - smoothstep(start + extent - 40.0f * framePixel, start + extent, position.y));
        float soft = max(width * 0.5f, footprint * 0.5f);
        float coverage = (1.0f - smoothstep(width - soft, width + soft, abs(position.x - x)))
            * min(1.0f, width / footprint) * inside;
        float flicker = 0.45f + 0.55f * valueNoise(float2(x, position.y / (180.0f * framePixel)), 97u);
        float3 line = hash(key, 101u) < 0.6f ? float3(0.95f) : float3(0.08f);
        encoded = mix(encoded, line, coverage * flicker * 0.7f);
    }
    return encoded;
}

// A border over the photo's edges (FrameStyle): a keyline, a white print border, a 35 mm film
// rebate with its sprocket holes, or a slide mount. `q` is in frame heights; `pixel` is an output
// pixel in the same units, for antialiasing.
static inline float3 frameBorder(float3 encoded, float2 q, float aspect, int style, float size, float pixel) {
    float toEdge = min(min(q.x, aspect - q.x), min(q.y, 1.0f - q.y));
    if (style == 1) {
        float width = 0.006f * size;
        return mix(encoded, float3(0.02f), 1.0f - smoothstep(width - pixel, width + pixel, toEdge));
    }
    if (style == 2) {
        float width = 0.035f * size;
        float paper = 1.0f - smoothstep(width - pixel, width + pixel, toEdge);
        return mix(encoded, float3(0.96f, 0.955f, 0.94f), paper);
    }
    if (style == 3) {
        // The rebate runs along the long sides with the sprocket holes in it (a 35 mm frame is
        // eight perforations long), with a thin black edge on the short sides.
        bool landscape = aspect >= 1.0f;
        float2 r = landscape ? q : float2(q.y * aspect, q.x / aspect);
        float span = landscape ? aspect : 1.0f / aspect;
        float band = 0.13f * size, side = 0.02f * size;
        float alongEdge = min(r.y, 1.0f - r.y);
        float black = max(1.0f - smoothstep(band - pixel, band + pixel, alongEdge),
                          1.0f - smoothstep(side - pixel, side + pixel, min(r.x, span - r.x)));
        float pitch = span / 8.0f;
        float2 hole = float2(fmod(r.x + pitch * 0.5f, pitch) - pitch * 0.5f, alongEdge - band * 0.5f);
        float2 halfSize = float2(pitch * 0.29f, band * 0.3f);
        float2 outside = abs(hole) - halfSize + 0.01f * size;
        float holeDistance = length(max(outside, 0.0f)) + min(max(outside.x, outside.y), 0.0f) - 0.01f * size;
        float lit = (1.0f - smoothstep(-pixel, pixel, holeDistance)) * step(alongEdge, band);
        float3 rebate = mix(float3(0.015f, 0.012f, 0.01f), float3(0.98f, 0.93f, 0.84f), lit);
        return mix(encoded, rebate, black);
    }
    if (style == 4) {
        float inset = 0.06f * size, radius = 0.035f * size;
        float2 halfWindow = float2(aspect * 0.5f - inset, 0.5f - inset);
        float2 outside = abs(q - float2(aspect * 0.5f, 0.5f)) - halfWindow + radius;
        float distance = length(max(outside, 0.0f)) + min(max(outside.x, outside.y), 0.0f) - radius;
        float mount = smoothstep(-pixel, pixel, distance);
        float bevel = smoothstep(0.0f, 0.012f * size, distance);
        return mix(encoded, mix(float3(0.8f, 0.79f, 0.77f), float3(0.93f, 0.925f, 0.91f), bevel), mount);
    }
    return encoded;
}

// MARK: - Glow

// A wide, smooth blur with a long tail, as a point spread falls off: six half-octave levels
// from `radius` (a fraction of the long side), each a hexagon of taps around the centre so the
// coarse mip levels' blocks don't show. `core` gets the first three levels only, a tighter spread.
static inline float3 wideGlow(texture2d<float, access::sample> map, float2 uv, float radius, thread float3 &core) {
    constexpr sampler mipSampler(coord::normalized, filter::linear, mip_filter::linear, address::clamp_to_edge);
    float2 size = float2(map.get_width(0), map.get_height(0));
    float baseLevel = log2(max(radius * max(size.x, size.y), 1.0f));
    float maxLevel = float(map.get_num_mip_levels() - 1);
    const float2 hexagon[6] = {
        float2(1.0f, 0.0f), float2(0.5f, 0.866f), float2(-0.5f, 0.866f),
        float2(-1.0f, 0.0f), float2(-0.5f, -0.866f), float2(0.5f, -0.866f),
    };
    float3 sum = 0.0f;
    float total = 0.0f;
    core = 0.0f;
    float coreTotal = 0.0f;
    for (int step = 0; step < 6; step++) {
        float lod = min(baseLevel + 0.5f * float(step), maxLevel);
        float2 texel = exp2(lod) / size;
        float rotation = 0.5f * float(step);
        float2x2 turn = float2x2(float2(cos(rotation), sin(rotation)), float2(-sin(rotation), cos(rotation)));
        float3 taps = map.sample(mipSampler, uv, level(lod)).rgb;
        for (int i = 0; i < 6; i++) {
            taps += map.sample(mipSampler, uv + texel * 1.2f * (turn * hexagon[i]), level(lod)).rgb;
        }
        float weight = exp2(-0.35f * float(step));
        sum += weight * taps / 7.0f;
        total += weight;
        if (step < 3) {
            core += weight * taps / 7.0f;
            coreTotal += weight;
        }
    }
    core /= coreTotal;
    return sum / total;
}

// MARK: - Masks

#include "Masks.h"

// MARK: - Develop

kernel void rl_develop(
    texture2d<float, access::sample> source [[texture(0)]],
    texture2d<float, access::write> out [[texture(1)]],
    texture2d<float, access::sample> denoised [[texture(2)]],
    constant DevelopParams &p [[buffer(0)]],
    constant float *toneLUT [[buffer(1)]],
    constant float *mixer [[buffer(2)]],
    constant MaskLayerGPU *layers [[buffer(3)]],
    constant MaskComponentGPU *components [[buffer(4)]],
    texture3d<half, access::read> lookTable [[texture(3)]],
    texture2d<float, access::sample> hazeMap [[texture(4)]],
    texture2d<float, access::sample> glowSource [[texture(5)]],
    texture2d<float, access::sample> glowLights [[texture(8)]],
    texture2d_array<float, access::sample> maskRasters [[texture(6)]],
    texture2d<float, access::sample> maskGuide [[texture(7)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint width = uint(p.outputSize.x);
    uint height = uint(p.outputSize.y);
    if (gid.x >= width || gid.y >= height) return;

    constexpr sampler linearSampler(coord::normalized, filter::linear, mip_filter::linear, address::clamp_to_edge);
    // The whole developed (cropped) frame, so vignette and grain don't depend on the region...
    float2 uv = p.region.xy + (float2(gid) + 0.5f) / float2(width, height) * p.region.zw;
    // ...and the photo point behind it, which masks are placed in.
    float2 imageUV;
    bool outsideImage = outputToImage(uv, p, imageUV);
    float2 sourceUV = orient(imageUV, int(p.geometry.x));
    float3 camera;
    if (p.denoised.z > 0.0f) {
        constexpr sampler areaSampler(coord::normalized, filter::linear, address::clamp_to_edge);
        camera = denoised.sample(areaSampler, (sourceUV - p.denoised.xy) / p.denoised.zw).rgb;
    } else {
        camera = source.sample(linearSampler, sourceUV, level(p.geometry.y)).rgb;
    }
    // Lens vignetting, Lightroom's manual Vignetting: positive lightens the corners, by up to a
    // stop, from the midpoint outwards.
    if (p.lens.y != 0.0f) {
        float radius = length((imageUV - 0.5f) * lensScale(p));
        camera *= exp2(p.lens.y * smoothstep(0.9f * p.lens.z, 1.0f, radius));
    }

    // Mask coverage for every layer, then the summed local adjustments.
    int layerCount = min(int(p.masks.x), kMaxMaskLayers);
    float coverage[kMaxMaskLayers];
    float2 maskPosition = float2(imageUV.x * p.toImage0.w, imageUV.y);
    float4 localColor = 0.0f;
    float4 localTone = 0.0f;
    float2 localTone2 = 0.0f;
    float localDehaze = 0.0f;
    float2 localGlow = 0.0f;
    MaskImages maskImages = { maskRasters, maskGuide };
    float textureMagnitude = -1.0f;
    for (int i = 0; i < layerCount; i++) {
        coverage[i] = evaluateMaskLayer(layers[i], components, maskPosition, maskImages);
        if (layers[i].detail.y != 0.0f) {
            if (textureMagnitude < 0.0f) {
                textureMagnitude = maskTextureMagnitude(source, sourceUV, uint(layers[i].detail.z));
            }
            coverage[i] *= maskDetailFactor(textureMagnitude, layers[i].detail.y);
        }
        localColor += coverage[i] * layers[i].color;
        localTone += coverage[i] * layers[i].tone;
        localTone2 += coverage[i] * layers[i].tone2.xy;
        localDehaze += coverage[i] * layers[i].detail.x;
        localGlow += coverage[i] * layers[i].glow.xy;
    }

    // Scene-referred: white balance (global and local), camera matrix, exposure.
    // Dehaze, in the camera RGB the haze map was measured in: invert I = J t + A (1 - t), with the
    // transmission t from the dark channel prior; negative values add a neutral veil a little
    // darker than the airlight.
    float dehaze = p.haze.w + localDehaze;
    if (dehaze != 0.0f) {
        constexpr sampler hazeSampler(coord::normalized, filter::linear, address::clamp_to_edge);
        float3 airlight = p.haze.xyz;
        if (dehaze > 0.0f) {
            float dark = hazeMap.sample(hazeSampler, sourceUV).r;
            float transmission = max(1.0f - 0.95f * min(dehaze, 1.0f) * dark, 0.2f);
            camera = max((camera - airlight) / transmission + airlight, 0.0f);
        } else {
            float veil = 0.8f * (airlight.r + airlight.g + airlight.b) / 3.0f;
            camera += (veil - camera) * (0.3f * min(-dehaze, 1.0f));
        }
    }
    // Process 3: a bitmap is already rendered, so it stands in for the tone curve's output: undo
    // the curve here and the default edit shows the file as it is (as Lightroom does).
    if (p.render.x > 0.5f) {
        float3 shown = clamp(mul3(p.camToWork0, p.camToWork1, p.camToWork2, camera), 0.0f, 1.0f);
        // Undoing the curve saturates bright colours beyond the camera's (sRGB) primaries, so a
        // channel may go negative here; working space takes it back.
        camera = mul3(p.workToCam0, p.workToCam1, p.workToCam2, inverseToneCurve(shown));
    }
    camera *= p.wbRatio.xyz;
    camera *= float3(exp2(localColor.x * 0.6f), exp2(-localColor.y * 0.4f), exp2(-localColor.x * 0.6f));
    float3 scene = max(mul3(p.camToWork0, p.camToWork1, p.camToWork2, camera), 0.0f);
    scene *= p.tone.x * exp2(localTone.x);
    // Halation and bloom: highlight light scattered on its way to the image (see Glow.metal),
    // added in scene light. Halation reflects off the film base behind the emulsion, so it
    // reaches the red layer widest, the green a little and the blue (on top) not at all; its
    // colour is the light's own red. Bloom spreads every colour, and a diffusion filter also
    // spreads a little of all the light, which lowers contrast.
    // Masks add to (or take from) the glow where they cover; the radii stay global.
    float halationAmount = max(p.glow.x + localGlow.x, 0.0f);
    float bloomAmount = max(p.glow.z + localGlow.y, 0.0f);
    if (halationAmount > 0.0f || bloomAmount > 0.0f) {
        float3 toScene = p.wbRatio.xyz * p.tone.x * exp2(localTone.x);
        constexpr sampler glowSampler(coord::normalized, filter::linear, address::clamp_to_edge);
        // Inside an evenly bright area the scattered light is the area's own, which a print or
        // scan balances out; only light spilling past edges shows. So glow is what the
        // surroundings send beyond the pixel's own highlight light.
        float3 own = glowSource.sample(glowSampler, sourceUV, level(0.0f)).rgb;
        float3 core;
        if (halationAmount > 0.0f) {
            float3 wide = p.render.y > 0.5f ? wideGlow(glowLights, sourceUV, p.glow.y, core)
                : wideGlow(glowSource, sourceUV, p.glow.y, core);
            wide = max(mul3(p.camToWork0, p.camToWork1, p.camToWork2, max(wide - own, 0.0f) * toScene), 0.0f);
            core = max(mul3(p.camToWork0, p.camToWork1, p.camToWork2, max(core - own, 0.0f) * toScene), 0.0f);
            float h = 0.12f * halationAmount;
            scene.r += h * mix(dot(wide, kRec2020Luma), wide.r, 0.5f);
            scene.g += 0.25f * h * mix(dot(core, kRec2020Luma), core.g, 0.5f);
        }
        if (bloomAmount > 0.0f) {
            float3 spread = wideGlow(glowSource, sourceUV, p.glow.w, core);
            float3 highlights = max(mul3(p.camToWork0, p.camToWork1, p.camToWork2,
                max(spread - own, 0.0f) * toScene), 0.0f);
            float3 all = max(mul3(p.camToWork0, p.camToWork1, p.camToWork2,
                wideGlow(source, sourceUV, p.glow.w, core) * toScene), 0.0f);
            scene = mix(scene, all, 0.1f * bloomAmount) + 0.08f * bloomAmount * highlights;
        }
    }
    // Tone controls in log space around middle grey, applied as a luminance ratio.
    float luma = max(dot(scene, kRec2020Luma), 1e-7f);
    float ev = log2(luma / kMiddleGrey);
    float highlightWeight = smoothstep(-0.5f, 2.5f, ev);
    float shadowWeight = (1.0f - smoothstep(-4.5f, 0.0f, ev)) * smoothstep(-10.0f, -5.5f, ev);
    float adjustedEV = ev * (1.0f + p.tone.y + localTone.y * 0.32f)
        + (p.tone.z + localTone.z) * 1.25f * highlightWeight
        + (p.tone.w + localTone.w) * 1.6f * shadowWeight
        + localTone2.x * 0.9f * smoothstep(0.5f, 3.0f, ev)
        + localTone2.y * 0.9f * (1.0f - smoothstep(-8.0f, -2.5f, ev));
    // Dynamic range: compress highlights above +0.5 EV (monotonic for compression <= 0.5).
    if (p.recipe.z > 0.0f) {
        adjustedEV -= p.recipe.z * smoothstep(0.5f, 4.5f, adjustedEV) * (adjustedEV - 0.5f);
    }
    scene *= exp2(adjustedEV - ev);

    // Black and white points, then the tone curve to display-referred (still Rec.2020 primaries).
    float blackPoint = p.tone2.y;
    scene = max((scene - blackPoint) / (1.0f - blackPoint), 0.0f);
    float3 display = toneCurve(scene / p.tone2.x);

    // A scene-referred Base Look (a film model) takes the place of the tone curve.
    if (p.lookTable.x > 0.0f && p.lookTable.z > 0.5f) {
        float3 film = sampleLookTable(lookTable, sceneLogEncode3(scene / p.tone2.x), p.lookTable.y);
        display = max(mix(display, srgbDecode3(max(film, 0.0f)), p.lookTable.x), 0.0f);
    }
    // A display-referred Base Look's table, on the tone curve's output, under every user color control.
    if (p.lookTable.x > 0.0f && p.lookTable.z < 0.5f) {
        float3 looked = sampleLookTable(lookTable, srgbEncode3(clamp(display, 0.0f, 1.0f)), p.lookTable.y);
        display = max(mix(display, srgbDecode3(max(looked, 0.0f)), p.lookTable.x), 0.0f);
    }
    // Perceptual color work in OKLCh.
    float3 lab = rec2020ToOKLab(display);
    float chroma = length(lab.yz);
    float hue = atan2(lab.z, lab.y) * (180.0f / M_PI_F);
    if (hue < 0.0f) hue += 360.0f;

    float saturation = p.color.y;
    float vibrance = p.color.x;
    float skin = hueBump(hue, 55.0f, 30.0f);
    float lowChroma = 1.0f - smoothstep(0.0f, 0.18f, chroma);
    saturation *= 1.0f + vibrance * lowChroma * (vibrance > 0.0f ? (1.0f - 0.6f * skin) : 1.0f);
    saturation *= 1.0f + p.look.x * hueBump(hue, 150.0f, 55.0f);
    saturation *= 1.0f - p.look.y * skin * 0.5f;

    if (p.look.z > 0.5f) {
        // Partition-of-unity weights between the two nearest band centres.
        float hueShift = 0.0f, bandSaturation = 0.0f, bandLuminance = 0.0f;
        for (int i = 0; i < 8; i++) {
            int j = (i + 1) % 8;
            float start = kBandHues[i];
            float end = j == 0 ? kBandHues[0] + 360.0f : kBandHues[j];
            float h = hue < start ? hue + 360.0f : hue;
            if (h >= start && h < end) {
                float t = smoothstep(0.0f, 1.0f, (h - start) / (end - start));
                hueShift = mix(mixer[i], mixer[j], t);
                bandSaturation = mix(mixer[8 + i], mixer[8 + j], t);
                bandLuminance = mix(mixer[16 + i], mixer[16 + j], t);
                break;
            }
        }
        float colorfulness = smoothstep(0.0f, 0.04f, chroma);
        hue += hueShift * 30.0f * colorfulness;
        saturation *= 1.0f + bandSaturation;
        lab.x += bandLuminance * 0.15f * colorfulness * smoothstep(0.0f, 0.1f, chroma);
    }

    saturation *= 1.0f + localColor.w;
    hue += localColor.z * smoothstep(0.0f, 0.04f, chroma);
    chroma = boostChroma(chroma, chroma * max(saturation, 0.0f), lab.x, hue * (M_PI_F / 180.0f), p);
    // Color chrome: deeper, denser tones in strongly saturated colors (blues for FX Blue).
    if ((p.recipe.x > 0.0f || p.recipe.y > 0.0f) && p.color.w < 0.5f) {
        float depth = (p.recipe.x + p.recipe.y * hueBump(hue, 255.0f, 45.0f)) * smoothstep(0.05f, 0.2f, chroma);
        lab.x *= 1.0f - 0.12f * depth;
        chroma *= 1.0f + 0.06f * depth;
    }
    if (p.color.w > 0.5f) chroma = 0.0f;
    float hueRadians = hue * (M_PI_F / 180.0f);
    lab.y = chroma * cos(hueRadians);
    lab.z = chroma * sin(hueRadians) + p.color.z;

    if (p.gradeShape.z > 0.5f) {
        float blending = p.gradeShape.x;
        float pivot = 0.5f - p.gradeShape.y * 0.2f;
        float width = 0.08f + 0.3f * blending;
        float L = clamp(lab.x, 0.0f, 1.0f);
        float shadows = 1.0f - smoothstep(pivot - 0.2f - width, pivot - 0.2f + width, L);
        float highlights = smoothstep(pivot + 0.2f - width, pivot + 0.2f + width, L);
        float midtones = max(0.0f, 1.0f - shadows - highlights);
        float3 offset = shadows * p.gradeShadows.xyz + midtones * p.gradeMidtones.xyz
                        + highlights * p.gradeHighlights.xyz + p.gradeGlobal.xyz;
        lab.y += offset.x;
        lab.z += offset.y;
        lab.x += offset.z;
    }

    // Curve, vignette and grain work on sRGB-transfer-encoded Rec.2020 values; the gamut is
    // only reduced to the output's at the end.
    float3 encoded = srgbEncode3(max(okLabToRec2020(lab), 0.0f));

    if (p.tone2.z > 0.5f) {
        encoded = float3(sampleLUT(toneLUT, encoded.r), sampleLUT(toneLUT, encoded.g), sampleLUT(toneLUT, encoded.b));
    }

    // Post-crop vignette.
    if (p.vignette.x != 0.0f) {
        // Roundness 0 follows the frame's aspect, +1 is a circle, -1 a rounded rectangle.
        float aspect = p.geometry.w;
        float roundness = p.vignette.z;
        float2 q = (uv - 0.5f) * 2.0f;
        if (roundness > 0.0f) {
            if (aspect >= 1.0f) q.x *= mix(1.0f, aspect, roundness);
            else q.y *= mix(1.0f, 1.0f / aspect, roundness);
        }
        float exponent = roundness < 0.0f ? mix(2.0f, 8.0f, -roundness) : 2.0f;
        float distance = pow(pow(abs(q.x), exponent) + pow(abs(q.y), exponent), 1.0f / exponent);
        float start = mix(0.15f, 1.25f, p.vignette.y);
        float feather = mix(0.02f, 1.1f, p.vignette.w);
        float amount = smoothstep(start - feather * 0.5f, start + feather * 0.5f, distance);
        if (p.vignette.x < 0.0f) {
            encoded *= 1.0f + p.vignette.x * amount;
        } else {
            encoded += (1.0f - encoded) * p.vignette.x * amount;
        }
    }

    // Mood effects, in whole-photo coordinates so they stay put as you zoom, and sized to the
    // frame (a "frame pixel" is 1/3000 of the long side) so they look the same at any resolution.
    float2 framePosition = float2(uv.x * p.geometry.w, uv.y);
    if (p.mood0.x > 0.0f) {
        encoded = lightLeak(encoded, framePosition, p.geometry.w, p.mood0);
    }
    if (p.mood0.w > 0.0f || p.mood1.x > 0.0f) {
        float2 fullSize = p.outputSize.z * p.outputSize.xy / p.region.zw;
        float2 fullPosition = p.region.xy * fullSize + float2(gid) * p.outputSize.z;
        float framePixel = max(fullSize.x, fullSize.y) / 3000.0f;
        float footprint = max(p.outputSize.z, 1.0f);
        if (p.mood0.w > 0.0f) {
            encoded = dust(encoded, fullPosition, framePixel, footprint, p.mood0.w);
        }
        if (p.mood1.x > 0.0f) {
            encoded = scratches(encoded, fullPosition, fullSize, framePixel, footprint, p.mood1.x);
        }
    }

    // Film grain, anchored to full-resolution pixel coordinates so it is zoom-stable.
    if (p.grain.x > 0.0f) {
        float2 fullSize = p.outputSize.z * p.outputSize.xy / p.region.zw;
        float2 fullPosition = p.region.xy * fullSize + float2(gid) * p.outputSize.z;
        float size = mix(0.6f, 3.5f, p.grain.y);
        // Process 2 sizes grain to the frame: the same on a 24 MP photo (6000 pixels long), and
        // proportionally larger or smaller on others, as film's grain is to its frame.
        if (p.grain2.y > 0.5f) size *= max(fullSize.x, fullSize.y) / 6000.0f;
        // Below full resolution each output pixel averages several grains, as downscaling an
        // export does, so the preview shows the grain the export will have. Process 2's grain
        // can be finer than a pixel, so it averages at full resolution too.
        float footprint = p.grain2.y > 0.5f ? max(p.outputSize.z, 1.0f)
            : (p.outputSize.z > 1.001f ? p.outputSize.z : 0.0f);
        float roughness = p.grain.z * 0.6f;
        uint seed = uint(p.grain.w);
        float3 noise = grainNoise(fullPosition, size, footprint, roughness, seed, seed + 17u);
        // Colour grain: each dye layer has its own grains, so the noise decorrelates per channel.
        if (p.grain2.x > 0.0f) {
            float3 layers = float3(
                grainNoise(fullPosition, size, footprint, roughness, seed + 31u, seed + 47u),
                grainNoise(fullPosition, size, footprint, roughness, seed + 59u, seed + 71u),
                grainNoise(fullPosition, size, footprint, roughness, seed + 83u, seed + 97u));
            noise = mix(noise, layers, p.grain2.x);
        }
        float L = dot(encoded, float3(0.2126f, 0.7152f, 0.0722f));
        // Process 2 follows film: grain shows most in the low midtones and shadows, where a
        // negative is thin, and fades in the highlights; process 1 peaks evenly in the midtones.
        float weight = p.grain2.y > 0.5f
            ? 0.25f + 3.2f * pow(max(L, 0.0f), 0.75f) * pow(max(1.0f - L, 0.0f), 1.4f)
            : 0.35f + 2.6f * L * (1.0f - L);
        encoded += noise * p.grain.x * 0.16f * weight;
    }

    // The frame is drawn last, over the grain, so its edges stay clean.
    if (p.mood1.y > 0.5f) {
        float pixel = p.region.w / max(float(height), 1.0f);
        encoded = frameBorder(encoded, framePosition, p.geometry.w, int(p.mood1.y + 0.5f), mix(0.4f, 1.6f, p.mood1.z), pixel);
    }

    // Into the output gamut, sRGB-transfer encoded (sRGB and Display P3 share the curve).
    encoded = srgbEncode3(gamutMap(srgbDecode3(max(encoded, 0.0f)), p));

    if (p.tone2.w > 0.5f) {
        if (any(encoded >= 0.998f)) encoded = float3(1.0f, 0.1f, 0.1f);
        else if (all(encoded <= 0.002f)) encoded = float3(0.15f, 0.35f, 1.0f);
    }

    // The selected mask's overlay: masks.w is the colour plus 8 × the style (MaskOverlayStyle).
    int overlay = int(p.masks.y);
    if (overlay >= 0 && overlay < layerCount) {
        const float3 overlayColors[4] = {
            float3(0.95f, 0.18f, 0.18f), float3(0.2f, 0.9f, 0.3f), float3(0.25f, 0.45f, 1.0f), float3(1.0f),
        };
        int code = int(p.masks.w);
        float3 tint = overlayColors[clamp(code & 7, 0, 3)];
        float cover = coverage[overlay];
        float grey = dot(encoded, float3(0.2126f, 0.7152f, 0.0722f));
        switch (code >> 3) {
        case 1: encoded = mix(float3(grey), tint, cover * 0.55f); break;
        case 2: encoded *= cover; break;
        case 3: encoded = mix(float3(1.0f), encoded, cover); break;
        case 4: encoded = float3(cover); break;
        case 5: {
            constexpr sampler guideSampler(coord::normalized, filter::linear, address::clamp_to_edge);
            float lightness = maskGuide.sample(guideSampler, imageUV).x;
            encoded = mix(float3(lightness), tint, cover * 0.55f);
            break;
        }
        default: encoded = mix(encoded, tint, cover * 0.55f); break;
        }
    }

    // Output encoding: 0 linear output primaries, 1 sRGB-encoded sRGB, 2 sRGB-encoded Display P3,
    // 4 OKLab (the output primaries are Rec.2020 then).
    int encoding = int(p.geometry.z);
    // Where rotation or Transform leaves no photo, the frame is white, as Lightroom's is.
    if (outsideImage) encoded = float3(1.0f);
    float3 result = encoding == 4 ? rec2020ToOKLab(srgbDecode3(encoded))
        : encoding == 0 || encoding == 3 ? srgbDecode3(encoded) : encoded;
    out.write(float4(result, 1.0f), gid);
}

// MARK: - Histogram

struct HistogramParams {
    uint width;
    uint height;
    uint step;
    uint linearInput;   // 1 when the texture holds linear values that need encoding
};

kernel void rl_histogram(
    texture2d<float, access::read> image [[texture(0)]],
    device atomic_uint *bins [[buffer(0)]],
    constant HistogramParams &p [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]],
    uint tid [[thread_index_in_threadgroup]],
    uint2 tgSize [[threads_per_threadgroup]])
{
    threadgroup atomic_uint local[1024];
    uint threads = tgSize.x * tgSize.y;
    for (uint i = tid; i < 1024; i += threads) {
        atomic_store_explicit(&local[i], 0u, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    uint2 pixel = gid * p.step;
    if (pixel.x < p.width && pixel.y < p.height) {
        float3 c = image.read(pixel).rgb;
        if (p.linearInput == 1) c = srgbEncode3(clamp(c, 0.0f, 1.0f));
        c = clamp(c, 0.0f, 1.0f);
        float luma = dot(c, float3(0.2126f, 0.7152f, 0.0722f));
        atomic_fetch_add_explicit(&local[uint(c.r * 255.0f + 0.5f)], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&local[256 + uint(c.g * 255.0f + 0.5f)], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&local[512 + uint(c.b * 255.0f + 0.5f)], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&local[768 + uint(luma * 255.0f + 0.5f)], 1u, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint i = tid; i < 1024; i += threads) {
        uint value = atomic_load_explicit(&local[i], memory_order_relaxed);
        if (value > 0) atomic_fetch_add_explicit(&bins[i], value, memory_order_relaxed);
    }
}

// A linear export, downscaled, to the sRGB transfer curve (which Display P3 shares).
kernel void rl_encode_srgb(
    texture2d<float, access::read> linear [[texture(0)]],
    texture2d<float, access::write> out [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    out.write(float4(srgbEncode3(clamp(linear.read(gid).rgb, 0.0f, 1.0f)), 1.0f), gid);
}
