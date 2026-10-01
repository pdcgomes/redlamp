// Parameter blocks shared by the Metal kernels. Every field is a 32-bit scalar or a
// float4 so the layout matches the Swift mirrors in KernelParams.swift exactly.
#ifndef REDLAMP_SHADER_TYPES_H
#define REDLAMP_SHADER_TYPES_H

#include <metal_stdlib>
using namespace metal;

struct CFAParams {
    uint width;
    uint height;
    uint channels;       // 1 for a mosaic, 3 or 4 for linear raw
    uint patternWidth;   // CFA repeat (2 for Bayer, 6 for X-Trans)
    uint patternHeight;
    uint pad0;
    uint pad1;
    float white;
    float4 multipliers;  // as-shot white balance, smallest channel = 1
};

struct DevelopParams {
    float4 camToWork0;        // camera RGB -> linear Rec.2020 (rows)
    float4 camToWork1;
    float4 camToWork2;
    float4 displayToOutput0;  // linear Rec.2020 -> output primaries (rows)
    float4 displayToOutput1;
    float4 displayToOutput2;
    float4 wbRatio;           // xyz: user / as-shot multipliers
    float4 tone;              // x exposure gain, y contrast, z highlights, w shadows
    float4 tone2;             // x white point, y black point, z curve on, w clipping overlay
    float4 color;             // x vibrance, y saturation gain, z warmth, w monochrome
    float4 look;              // x green boost, y skin softening, z mixer on, w unused
    float4 gradeShadows;      // xy OKLab ab offset, z luminance
    float4 gradeMidtones;
    float4 gradeHighlights;
    float4 gradeGlobal;
    float4 gradeShape;        // x blending, y balance, z grading on
    float4 vignette;          // amount, midpoint, roundness, feather
    float4 grain;             // amount, size, roughness, seed
    float4 geometry;          // x orientation, y source LOD, z output encoding, w aspect
    float4 outputSize;        // x width, y height, z full-resolution scale
    float4 masks;             // x layer count, y overlay layer index (-1 none), z component count, w overlay color
    float4 region;            // rendered part of the image: xy origin, zw size (normalized, oriented)
    float4 denoised;          // area covered by the denoised texture: xy origin, zw size (normalized, source); z 0 = none
    float4 lookTable;         // x Base Look table amount (0 = none, 1 = 100%), y table size, z 1 = scene-referred
    float4 recipe;            // x color chrome, y chrome FX blue (0...1), z dynamic-range highlight compression
    float4 haze;              // xyz airlight (pyramid camera RGB), w Dehaze (slider / 100); needs the haze map
    float4 glow;              // x halation amount, y halation radius, z bloom amount, w bloom radius (radii as fractions of the long side)
    float4 grain2;            // x colour grain (0 monochrome, 1 independent per layer), y 1 = process 2 grain
};

// Noise reduction over one work area of the pyramid.
struct DenoiseParams {
    int4 origin;              // xy first texel of the work area, z pyramid level
    int4 size;                // xy work area size in texels
    int4 scale;               // x à-trous hole spacing, y 1 on the finest scale, z 1 on the coarsest
    float4 a;                 // noise per channel in pyramid units: variance = a · value + b
    float4 b;
    float4 threshold;         // x luma, yz chroma: detail below these is removed (0 keeps it)
};

// Maps oriented output coordinates to source texture coordinates (LibRaw flip codes).
static inline float2 orient(float2 uv, int orientation) {
    switch (orientation) {
    case 3: return float2(1.0f - uv.x, 1.0f - uv.y);
    case 5: return float2(1.0f - uv.y, uv.x);
    case 6: return float2(uv.y, 1.0f - uv.x);
    default: return uv;
    }
}

// One mask component. Coordinates are aspect-corrected: x is scaled by width/height so
// distances are isotropic.
struct MaskComponentGPU {
    float4 geometry;          // linear: start.xy, end.xy; radial: center.xy, radius.xy
    float4 shape;             // x kind (1 linear, 2 radial), y operation (0 add, 1 subtract, 2 intersect), z inverted, w feather 0...1
    float4 rotation;          // x cos, y sin of the radial rotation
};

// One mask layer's local adjustments, already scaled by the mask's Amount.
struct MaskLayerGPU {
    float4 color;             // x temperature, y tint, z hue shift (degrees), w saturation
    float4 tone;              // x exposure (EV), y contrast, z highlights, w shadows
    float4 tone2;             // x whites, y blacks, z first component index, w component count
    float4 detail;            // x Dehaze (slider / 100)
};

#endif
