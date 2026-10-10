"""A quick look at balanced camera RGB, close to rl_develop's defaults: exposure, Highlights (without
the edge-aware base), the tone curve with its hue-keeping channel positions, gamut map into sRGB and
the sRGB encoding. No base look, so colours are close but not the engine's."""
import numpy as np
from PIL import Image

import cam08

MIDDLE_GREY = 0.18
LUMA = np.array([0.2627, 0.6780, 0.0593])
SHOULDER_START, SHOULDER_Y, SHOULDER_EV, SHOULDER_POWER, FILMIC_AT_ONE = 0.54358851, 0.8, 2.40548194, 3.25537943, 0.80379747
REC2020_TO_SRGB = np.linalg.inv(cam08.SRGB_TO_REC2020)


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def filmic(x):
    return (x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14)


def curve_channel(x):
    u = np.minimum(np.log2(np.maximum(x, 1e-9) / SHOULDER_START) / SHOULDER_EV, 1)
    return np.where(x <= SHOULDER_START, filmic(x) / FILMIC_AT_ONE, 1 - (1 - SHOULDER_Y) * (1 - u) ** SHOULDER_POWER)


def tone_curve(x):
    y = curve_channel(x)
    lo, hi = x.min(-1, keepdims=True), x.max(-1, keepdims=True)
    ylo, yhi = y.min(-1, keepdims=True), y.max(-1, keepdims=True)
    keep = hi - lo < 1e-7
    return np.where(keep, y, ylo + (yhi - ylo) * (x - lo) / np.maximum(hi - lo, 1e-7))


def gamut_map(rgb):
    clipped = np.clip(rgb, 0, 1)
    lo, hi = rgb.min(-1, keepdims=True), rgb.max(-1, keepdims=True)
    clo, chi = clipped.min(-1, keepdims=True), clipped.max(-1, keepdims=True)
    keep = hi - lo < 1e-7
    return np.where(keep, clipped, clo + (chi - clo) * (rgb - lo) / np.maximum(hi - lo, 1e-7))


def develop(m: cam08.Mosaic, balanced: np.ndarray, exposure: float = 0.0, highlights: float = 0.0) -> np.ndarray:
    """Display-referred linear sRGB in [0, 1]."""
    scene = np.maximum(balanced @ (cam08.SRGB_TO_REC2020 @ m.rgb_cam).T, 0) * 2 ** exposure
    ev = np.log2(np.maximum(scene @ LUMA, 1e-7) / MIDDLE_GREY)
    adjusted = ev + highlights / 100 * 1.25 * smoothstep(-0.5, 2.5, ev)
    scene = scene * (2 ** (adjusted - ev))[..., None]
    shown = tone_curve(scene)
    return gamut_map(shown @ REC2020_TO_SRGB.T)


def encode(linear):
    return np.where(linear <= 0.0031308, 12.92 * linear, 1.055 * np.power(np.maximum(linear, 0), 1 / 2.4) - 0.055)


def save(path, linear):
    Image.fromarray((np.clip(encode(linear), 0, 1) * 255 + 0.5).astype(np.uint8)).save(path, quality=92)
