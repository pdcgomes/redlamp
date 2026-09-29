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
    float4 workToDisplay0;    // linear Rec.2020 -> linear sRGB (rows)
    float4 workToDisplay1;
    float4 workToDisplay2;
    float4 displayToOutput0;  // linear sRGB -> output primaries (rows)
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
};

#endif
