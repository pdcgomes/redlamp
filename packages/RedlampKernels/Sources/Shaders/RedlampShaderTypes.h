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
    float4 geometry;          // x orientation, y source LOD, z output encoding, w output frame aspect
    float4 outputSize;        // x width, y height, z full-resolution scale
    float4 masks;             // x layer count, y overlay layer index (-1 none), z component count, w overlay color
    float4 region;            // rendered part of the output frame: xy origin, zw size (normalized)
    float4 denoised;          // area covered by the denoised texture: xy origin, zw size (normalized, source); z 0 = none
    float4 lookTable;         // x Base Look table amount (0 = none, 1 = 100%), y table size, z 1 = scene-referred
    float4 recipe;            // x color chrome, y chrome FX blue (0...1), z dynamic-range highlight compression
    float4 haze;              // xyz airlight (pyramid camera RGB), w Dehaze (slider / 100); needs the haze map
    float4 glow;              // x halation amount, y halation radius, z bloom amount, w bloom radius (radii as fractions of the long side)
    float4 grain2;            // x colour grain (0 monochrome, 1 independent per layer), y 1 = process 2 grain
    float4 render;            // process 3: x 1 = bitmap input is display-referred, y 1 = halation from small lights only; process 7: z 1 = edge-aware Highlights and Shadows; process 8: w 1 = the refined haze map
    float4 workToCam0;        // linear Rec.2020 -> camera RGB (rows), the inverse of camToWork
    float4 workToCam1;
    float4 workToCam2;
    float4 mood0;             // x light leak amount, y leak warmth (-1 cool...1 warm), z leak variation (0...1), w dust
    float4 mood1;             // x scratches, y frame style (FrameStyle), z frame size (0...1)
    float4 toImage0;          // output frame (0...1) to the photo (0...1, EXIF-oriented): homography rows
    float4 toImage1;          // (crop, straighten, Transform, user orientation; see GeometryMap);
    float4 toImage2;          // toImage0.w is the photo's aspect, which masks are shaped in
    float4 lens;              // x radial distortion k (see GeometryMap), y lens vignetting (slider / 100), z its midpoint (0...1)
    float4 hueSat;            // process 4: x 1 = apply the camera profile's HueSatMap, y the cool map's weight,
                              // z 1 = its value axis is sRGB-encoded
    float4 toProPhoto0;       // linear Rec.2020 to linear ProPhoto (D50), rows
    float4 toProPhoto1;
    float4 toProPhoto2;
    float4 fromProPhoto0;
    float4 fromProPhoto1;
    float4 fromProPhoto2;
    float4 lensProfile;       // x 1 = apply the photo's lens profile (the lens table buffer), yz its optical
                              // centre (0...1), w 1 = red and blue are recorded at their own scale
    float4 lensProfile2;      // xy photo offset to the profile's radius per unit, z radius per table entry
    float4 defringe;          // x purple amount, y green amount (0...1)
    float4 defringeHue;       // OKLab hue bands in degrees: x, y purple from and to, z, w green
    float4 gainTable;         // process 5: x the profile's gain table map's strength (gain to this power), y its gamma, z the
                              // BaselineExposure gain its input assumes, w the weight of max(R, G, B)
    float4 gainTableWeights;  // weights of R, G, B and min(R, G, B) (ProPhoto)
    float4 gainTableGrid;     // xy the map's origin, zw its spacing, relative to the raw image
    float4 calibration;       // x Calibration's Shadows Tint (-1 green ... 1 magenta)
    float4 vignette2;         // x Post-Crop Vignetting's Highlights (0...1)
    float4 spots;             // x 1 = Visualize Spots, y its threshold (log luminance)
};

// Noise reduction over one work area of the pyramid.
struct DenoiseParams {
    int4 origin;              // xy first texel of the work area, z pyramid level
    int4 size;                // xy work area size in texels
    int4 scale;               // x à-trous hole spacing, y 1 on the finest scale, z 1 on the coarsest
    float4 a;                 // noise per channel in pyramid units: variance = a · value + b
    float4 b;
    float4 threshold;         // x luma, yz chroma: detail below these is removed (0 keeps it)
    float4 edge;              // x luma difference (stabilised units) at which chroma stops averaging (0 off),
                              // y radius of the luma energy neighbourhood (0: each coefficient alone),
                              // z leave the result in stabilised units for the non-local pass
    float4 nonLocal;          // see rl_denoise_nonlocal
};

// Photo coordinates to half-diagonal units about the centre, so the lens is round at any aspect.
static inline float2 lensScale(constant DevelopParams &p) {
    float aspect = p.toImage0.w;
    return float2(aspect, 1.0f) / (0.5f * sqrt(aspect * aspect + 1.0f));
}

// The lens profile as a table over the radius: per entry, where red, green and blue were recorded
// as a multiple of the radius, and the vignetting gain (see LensCorrection).
constant int kLensTableSize = 64;

static inline float lensRadius(float2 imageUV, constant DevelopParams &p) {
    return length((imageUV - p.lensProfile.yz) * p.lensProfile2.xy);
}

static inline float4 lensTableAt(constant float4 *table, float radius, constant DevelopParams &p) {
    float x = clamp(radius / p.lensProfile2.z, 0.0f, float(kLensTableSize - 1));
    int i = min(int(x), kLensTableSize - 2);
    return mix(table[i], table[i + 1], x - float(i));
}

// The photo point (0...1, EXIF-oriented) behind an output-frame point, through the geometry
// homography and the lens (the manual slider, then the photo's profile), where green was
// recorded, and red and blue where the profile has them; returns whether it falls outside the
// photo (or behind the virtual camera).
static inline bool outputToImage(float2 uv, constant DevelopParams &p, constant float4 *lensTable,
                                 thread float2 &imageUV, thread float2 &redUV, thread float2 &blueUV) {
    float3 point = float3(uv, 1.0f);
    float3 mapped = float3(dot(p.toImage0.xyz, point), dot(p.toImage1.xyz, point), dot(p.toImage2.xyz, point));
    imageUV = mapped.xy / max(mapped.z, 1e-9f);
    // Lens distortion: where the camera recorded the corrected point.
    if (p.lens.x != 0.0f) {
        float2 offset = (imageUV - 0.5f) * lensScale(p);
        imageUV = 0.5f + (imageUV - 0.5f) * (1.0f + p.lens.x * dot(offset, offset));
    }
    redUV = imageUV;
    blueUV = imageUV;
    if (p.lensProfile.x > 0.5f) {
        float4 scale = lensTableAt(lensTable, lensRadius(imageUV, p), p);
        float2 offset = imageUV - p.lensProfile.yz;
        imageUV = p.lensProfile.yz + offset * scale.y;
        redUV = p.lensProfile.yz + offset * scale.x;
        blueUV = p.lensProfile.yz + offset * scale.z;
    }
    return mapped.z <= 0.0f || any(imageUV < 0.0f) || any(imageUV > 1.0f);
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

// One mask component. Coordinates are aspect-corrected: x is scaled by width/height so
// distances are isotropic.
struct MaskComponentGPU {
    float4 geometry;          // linear: start.xy, end.xy; radial: center.xy, radius.xy; others: see Masks.h
    float4 shape;             // x kind (1 linear, 2 radial, 3 raster, 4 luminance, 5 color, 6 mask reference, 7 depth), y operation (0 add, 1 subtract, 2 intersect), z inverted, w feather 0...1
    float4 rotation;          // radial: x cos, y sin of the rotation; luminance: x 1 / aspect, y guide level
    float4 extra0;            // color range samples: 0 and 1 positions (mask UV)
    float4 extra1;            // samples 2 and 3 positions
    float4 extra2;            // sample 4 position and guide level
    float4 extra3;            // guide levels of samples 0 to 3
};

// One run of brush segments, or one raster operation, over an area of a mask raster.
struct MaskRasterParams {
    int4 box;                 // xy first pixel, zw size of the area touched
    int4 info;                // x slice, y point count (1 = a single dab), z auto mask, w erase
    float4 brush;             // x radius in raster pixels, y feather 0...1, z flow 0...1, w density 0...1
    float4 raster;            // xy raster size in pixels
};

// One mask layer's local adjustments, already scaled by the mask's Amount.
struct MaskLayerGPU {
    float4 color;             // x temperature, y tint, z hue shift (degrees), w saturation
    float4 tone;              // x exposure (EV), y contrast, z highlights, w shadows
    float4 tone2;             // x whites, y blacks, z first component index, w component count
    float4 detail;            // x Dehaze (slider / 100), y Detail refinement (-1...1), z pyramid level it measures texture at
    float4 glow;              // x halation, y bloom, z defringe, w moiré (slider / 100, scaled by the mask's Amount);
                              // halation, bloom and defringe add to the global amounts
};

#endif
