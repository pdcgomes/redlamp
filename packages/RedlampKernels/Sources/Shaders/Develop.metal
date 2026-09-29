#include "RedlampShaderTypes.h"

// MARK: - Color helpers

constant float3 kRec2020Luma = float3(0.2627f, 0.6780f, 0.0593f);
constant float kMiddleGrey = 0.18f;
constant float kBandHues[8] = { 25.0f, 55.0f, 100.0f, 140.0f, 195.0f, 255.0f, 300.0f, 340.0f };

static inline float3 mul3(float4 r0, float4 r1, float4 r2, float3 v) {
    return float3(dot(r0.xyz, v), dot(r1.xyz, v), dot(r2.xyz, v));
}

static inline float signedCbrt(float x) { return sign(x) * pow(abs(x), 1.0f / 3.0f); }

// Björn Ottosson's OKLab, from linear sRGB.
static inline float3 linearSRGBToOKLab(float3 c) {
    float l = 0.4122214708f * c.r + 0.5363325363f * c.g + 0.0514459929f * c.b;
    float m = 0.2119034982f * c.r + 0.6806995451f * c.g + 0.1073969566f * c.b;
    float s = 0.0883024619f * c.r + 0.2817188376f * c.g + 0.6299787005f * c.b;
    l = signedCbrt(l); m = signedCbrt(m); s = signedCbrt(s);
    return float3(
        0.2104542553f * l + 0.7936177850f * m - 0.0040720468f * s,
        1.9779984951f * l - 2.4285922050f * m + 0.4505937099f * s,
        0.0259040371f * l + 0.7827717662f * m - 0.8086757660f * s);
}

static inline float3 okLabToLinearSRGB(float3 lab) {
    float l = lab.x + 0.3963377774f * lab.y + 0.2158037573f * lab.z;
    float m = lab.x - 0.1055613458f * lab.y - 0.0638541728f * lab.z;
    float s = lab.x - 0.0894841775f * lab.y - 1.2914855480f * lab.z;
    l = l * l * l; m = m * m * m; s = s * s * s;
    return float3(
        4.0767416621f * l - 3.3077115913f * m + 0.2309699292f * s,
        -1.2684380046f * l + 2.6097574011f * m - 0.3413193965f * s,
        -0.0041960863f * l - 0.7034186147f * m + 1.7076147010f * s);
}

static inline float srgbEncode(float x) {
    return x <= 0.0031308f ? 12.92f * x : 1.055f * pow(x, 1.0f / 2.4f) - 0.055f;
}

static inline float srgbDecode(float x) {
    return x <= 0.04045f ? x / 12.92f : pow((x + 0.055f) / 1.055f, 2.4f);
}

static inline float3 srgbEncode3(float3 c) { return float3(srgbEncode(c.r), srgbEncode(c.g), srgbEncode(c.b)); }
static inline float3 srgbDecode3(float3 c) { return float3(srgbDecode(c.r), srgbDecode(c.g), srgbDecode(c.b)); }

// Filmic curve (Narkowicz's ACES fit), normalised so `white` maps to 1.
static inline float filmic(float x) {
    return (x * (2.51f * x + 0.03f)) / (x * (2.43f * x + 0.59f) + 0.14f);
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

// Maps oriented output coordinates to source texture coordinates (LibRaw flip codes).
static inline float2 orient(float2 uv, int orientation) {
    switch (orientation) {
    case 3: return float2(1.0f - uv.x, 1.0f - uv.y);
    case 5: return float2(1.0f - uv.y, uv.x);
    case 6: return float2(uv.y, 1.0f - uv.x);
    default: return uv;
    }
}

// MARK: - Develop

kernel void rl_develop(
    texture2d<float, access::sample> source [[texture(0)]],
    texture2d<float, access::write> out [[texture(1)]],
    constant DevelopParams &p [[buffer(0)]],
    constant float *toneLUT [[buffer(1)]],
    constant float *mixer [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint width = uint(p.outputSize.x);
    uint height = uint(p.outputSize.y);
    if (gid.x >= width || gid.y >= height) return;

    constexpr sampler linearSampler(coord::normalized, filter::linear, mip_filter::linear, address::clamp_to_edge);
    float2 uv = (float2(gid) + 0.5f) / float2(width, height);
    float2 sourceUV = orient(uv, int(p.geometry.x));
    float3 camera = source.sample(linearSampler, sourceUV, level(p.geometry.y)).rgb;
    // Scene-referred: white balance, camera matrix, exposure.
    camera *= p.wbRatio.xyz;
    float3 scene = max(mul3(p.camToWork0, p.camToWork1, p.camToWork2, camera), 0.0f);
    scene *= p.tone.x;
    // Tone controls in log space around middle grey, applied as a luminance ratio.
    float luma = max(dot(scene, kRec2020Luma), 1e-7f);
    float ev = log2(luma / kMiddleGrey);
    float highlightWeight = smoothstep(-0.5f, 2.5f, ev);
    float shadowWeight = (1.0f - smoothstep(-4.5f, 0.0f, ev)) * smoothstep(-10.0f, -5.5f, ev);
    float adjustedEV = ev * (1.0f + p.tone.y) + p.tone.z * 1.25f * highlightWeight + p.tone.w * 1.6f * shadowWeight;
    scene *= exp2(adjustedEV - ev);

    // Black and white points, then the filmic tone map to display-referred.
    float blackPoint = p.tone2.y;
    scene = max((scene - blackPoint) / (1.0f - blackPoint), 0.0f);
    float whiteNorm = filmic(1.0f);
    float3 x = scene / p.tone2.x;
    float3 display = float3(filmic(x.r), filmic(x.g), filmic(x.b)) / whiteNorm;
    float3 linearRGB = mul3(p.workToDisplay0, p.workToDisplay1, p.workToDisplay2, display);
    // Perceptual color work in OKLCh.
    float3 lab = linearSRGBToOKLab(linearRGB);
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

    chroma *= max(saturation, 0.0f);
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

    linearRGB = clamp(okLabToLinearSRGB(lab), 0.0f, 1.0f);
    float3 encoded = srgbEncode3(linearRGB);

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

    // Film grain, anchored to full-resolution pixel coordinates so it is zoom-stable.
    if (p.grain.x > 0.0f) {
        float2 fullPosition = float2(gid) * p.outputSize.z;
        float size = mix(0.6f, 3.5f, p.grain.y);
        float coarse = valueNoise(fullPosition / size, uint(p.grain.w));
        float fine = valueNoise(fullPosition / (size * 0.5f), uint(p.grain.w) + 17u);
        float noise = mix(coarse, fine, p.grain.z * 0.6f) - 0.5f;
        float L = dot(encoded, float3(0.2126f, 0.7152f, 0.0722f));
        float midtoneWeight = 0.35f + 2.6f * L * (1.0f - L);
        encoded += noise * p.grain.x * 0.16f * midtoneWeight;
    }

    encoded = clamp(encoded, 0.0f, 1.0f);

    if (p.tone2.w > 0.5f) {
        if (any(encoded >= 0.998f)) encoded = float3(1.0f, 0.1f, 0.1f);
        else if (all(encoded <= 0.002f)) encoded = float3(0.15f, 0.35f, 1.0f);
    }

    // Output encoding: 0 linear (extended) display primaries, 1 sRGB-encoded, 2 P3-encoded.
    int encoding = int(p.geometry.z);
    float3 result;
    if (encoding == 1) {
        result = encoded;
    } else {
        float3 outputLinear = mul3(p.displayToOutput0, p.displayToOutput1, p.displayToOutput2, srgbDecode3(encoded));
        result = encoding == 2 ? srgbEncode3(clamp(outputLinear, 0.0f, 1.0f)) : outputLinear;
    }
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
