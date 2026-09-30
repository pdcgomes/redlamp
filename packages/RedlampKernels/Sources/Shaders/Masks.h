// Mask coverage, shared by the develop kernel and the detail stage so both see the same masks.
#ifndef REDLAMP_MASKS_H
#define REDLAMP_MASKS_H

#include "RedlampShaderTypes.h"

constant int kMaxMaskLayers = 16;

// Coverage of one component at an aspect-corrected position.
static inline float evaluateMaskComponent(MaskComponentGPU c, float2 p) {
    float weight;
    if (c.shape.x < 1.5f) {
        float2 start = c.geometry.xy;
        float2 axis = c.geometry.zw - start;
        float t = dot(p - start, axis) / max(dot(axis, axis), 1e-8f);
        weight = 1.0f - smoothstep(0.0f, 1.0f, t);
    } else {
        float2 q = p - c.geometry.xy;
        float2 rotated = float2(q.x * c.rotation.x + q.y * c.rotation.y, -q.x * c.rotation.y + q.y * c.rotation.x);
        float distance = length(rotated / max(c.geometry.zw, float2(1e-5f)));
        float inner = min(1.0f - clamp(c.shape.w, 0.0f, 1.0f), 0.999f);
        weight = 1.0f - smoothstep(inner, 1.0f, distance);
    }
    return c.shape.z > 0.5f ? 1.0f - weight : weight;
}

// Combines a layer's components in order: add = union, subtract, intersect.
static inline float evaluateMaskLayer(MaskLayerGPU layer, constant MaskComponentGPU *components, float2 p) {
    int first = int(layer.tone2.z);
    int count = int(layer.tone2.w);
    float coverage = 0.0f;
    for (int i = 0; i < count; i++) {
        MaskComponentGPU c = components[first + i];
        float w = evaluateMaskComponent(c, p);
        int operation = int(c.shape.y);
        if (i == 0) coverage = operation == 1 ? 0.0f : w;
        else if (operation == 0) coverage = max(coverage, w);
        else if (operation == 1) coverage *= 1.0f - w;
        else coverage *= w;
    }
    return coverage;
}

// The inverse of `orient`: source texture coordinates to oriented image coordinates.
static inline float2 unorient(float2 uv, int orientation) {
    switch (orientation) {
    case 3: return float2(1.0f - uv.x, 1.0f - uv.y);
    case 5: return float2(uv.y, 1.0f - uv.x);
    case 6: return float2(1.0f - uv.y, uv.x);
    default: return uv;
    }
}

#endif
