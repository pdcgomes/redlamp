"""A NumPy model of Redlamp's raw stages up to the demosaic, for studying clipped highlights.

It follows the code on main (process 12, CAM-08): `rl_cfa_normalize`, `HighlightModel.fit` and
`rl_cfa_reconstruct_highlights` (Demosaic.metal, HighlightModel.swift), and replaces the demosaic
with 2 x 2 (Bayer) or 3 x 3 (X-Trans) binning, which keeps a flat sky's colour. Hot-pixel repair is
skipped. Values are white-balanced camera RGB, normalised so the white level is 1 before the
multipliers.
"""
import os
from dataclasses import dataclass

import numpy as np
import rawpy

CLIP_FRACTION = 0.99


@dataclass
class Mosaic:
    path: str
    raw: np.ndarray  # uint16 image area
    colors: np.ndarray  # 0 R, 1 G, 2 B per photosite
    black: np.ndarray  # per photosite
    white: float
    balance: np.ndarray  # as-shot multipliers over their smallest
    rgb_cam: np.ndarray  # camera (balanced) to linear sRGB, LibRaw's
    block: int


XYZ_RGB = np.array([
    [0.412453, 0.357580, 0.180423],
    [0.212671, 0.715160, 0.072169],
    [0.019334, 0.119193, 0.950227],
])


def rgb_cam_from(cam_xyz: np.ndarray) -> np.ndarray:
    """LibRaw's rgb_cam: balanced camera RGB to linear sRGB, neutral to neutral."""
    if not np.any(cam_xyz):
        return np.eye(3)
    cam_rgb = cam_xyz @ XYZ_RGB
    cam_rgb = cam_rgb / cam_rgb.sum(axis=1, keepdims=True)
    return np.linalg.inv(cam_rgb)


def white_level(raw: np.ndarray, nominal: float) -> float:
    """WhiteLevel.measured: a spike at the data's maximum marks where photosites clip."""
    hist = np.bincount(raw.ravel(), minlength=65536)
    maximum = int(np.nonzero(hist)[0][-1])
    if maximum <= 0.5 * nominal:
        return nominal
    spike = hist[max(0, maximum - 4) : maximum + 1].sum()
    below = hist[max(0, maximum - 100) : max(0, maximum - 10)]
    background = below.sum() // max(len(below), 1)
    enough = max(16, raw.size // 500_000)
    if spike >= enough and spike >= 20 * (background * 5 + 1):
        return float(maximum)
    return nominal


def load(path: str) -> Mosaic:
    with rawpy.imread(path) as r:
        raw = r.raw_image_visible.copy()
        colors = r.raw_colors_visible.copy()
        colors[colors == 3] = 1
        desc = r.color_desc.decode()
        # rawpy's colour indices follow color_desc; map them onto R, G, B.
        lut = np.array(["RGB".index(ch) if ch in "RGB" else 1 for ch in desc])
        colors = lut[r.raw_colors_visible]
        blacks = np.array(r.black_level_per_channel, dtype=np.float32)
        black = blacks[r.raw_colors_visible]
        wb = np.array(r.camera_whitebalance[:3], dtype=np.float64)
        if wb.min() <= 0:
            wb = np.array(r.daylight_whitebalance[:3], dtype=np.float64)
        balance = wb / wb.min()
        rgb_cam = rgb_cam_from(np.array(r.rgb_xyz_matrix)[:3, :3])
        pattern_w = r.raw_pattern.shape[1]
        nominal = float(r.white_level)
    white = white_level(raw, nominal)
    stops = float(os.environ.get("CAM08_OVEREXPOSE", "0"))
    if stops:
        # As REDLAMP_PROTO_OVEREXPOSE does: more light on every photosite, clipped at the white level.
        raw = np.clip(np.rint((raw.astype(np.float32) - black) * 2 ** stops + black), 0, white).astype(np.uint16)
    return Mosaic(path, raw, colors.astype(np.int8), black, white, balance, rgb_cam,
                  3 if pattern_w % 3 == 0 else 2)


def normalise(m: Mosaic) -> np.ndarray:
    value = (m.raw.astype(np.float32) - m.black) / np.maximum(m.white - m.black, 1)
    return np.maximum(value * m.balance[m.colors].astype(np.float32), 0)


def clip_levels(m: Mosaic) -> np.ndarray:
    return (CLIP_FRACTION * m.balance).astype(np.float32)


def blocks(m: Mosaic, cfa: np.ndarray):
    """Per block: whether any photosite clipped (raw), and each colour's mean (balanced)."""
    b = m.block
    h, w = (m.raw.shape[0] // b) * b, (m.raw.shape[1] // b) * b
    raw = m.raw[:h, :w].astype(np.float32)
    threshold = m.black[:h, :w] + CLIP_FRACTION * (m.white - m.black[:h, :w])
    clipped = (raw >= threshold).reshape(h // b, b, w // b, b).any(axis=(1, 3))
    means = np.zeros((h // b, w // b, 3), np.float64)
    colors = m.colors[:h, :w].reshape(h // b, b, w // b, b)
    values = cfa[:h, :w].reshape(h // b, b, w // b, b)
    for c in range(3):
        sel = colors == c
        means[..., c] = (values * sel).sum(axis=(1, 3)) / np.maximum(sel.sum(axis=(1, 3)), 1)
    return clipped, means


def dilate(mask: np.ndarray, radius: int) -> np.ndarray:
    out = mask.copy()
    h, w = mask.shape
    horizontal = mask.copy()
    for d in range(1, radius + 1):
        horizontal[:, d:] |= mask[:, :-d]
        horizontal[:, :-d] |= mask[:, d:]
    out = horizontal.copy()
    for d in range(1, radius + 1):
        out[d:, :] |= horizontal[:-d, :]
        out[:-d, :] |= horizontal[d:, :]
    return out


def fit(m: Mosaic, cfa: np.ndarray):
    """HighlightModel.fit: the rim's colour offsets in cube-root space, or None if nothing clipped."""
    clipped, means = blocks(m, cfa)
    if not clipped.any():
        return None
    rim = dilate(clipped, 2) & ~clipped
    clip = clip_levels(m)
    bright = (means >= 0.5 * clip).all(axis=-1)
    reference = np.cbrt(means[rim & bright])
    rim_info = {"rim_blocks": int(rim.sum()), "rim_bright": int((rim & bright).sum()),
                "rim_mean_all": means[rim].mean(axis=0), "rim_mean_bright": means[rim & bright].mean(axis=0)
                if (rim & bright).any() else None,
                "rim_bright_where": np.argwhere(rim & bright)}
    coefficients = []
    for c in range(3):
        first, second = (c + 1) % 3, (c + 2) % 3
        for observed in ([first, second], [first], [second]):
            offset = 0.0
            if len(reference) >= 64:
                offset = float(np.mean(reference[:, c] - reference[:, observed].mean(axis=1)))
            entry = [offset, 0.0, 0.0, 0.0]
            for o in observed:
                entry[o + 1] = 1 / len(observed)
            coefficients.append(entry)
    return {"clip": clip, "w": float(clip.max()), "coefficients": np.array(coefficients, np.float32),
            "rim_samples": len(reference), "clipped_blocks": int(clipped.sum()), **rim_info}


def neighbourhood_means(m: Mosaic, cfa: np.ndarray, usable: np.ndarray, radius: int = 2):
    """Sum and count of usable neighbours of each colour within a (2r+1)^2 window."""
    h, w = cfa.shape
    sums = np.zeros((3, h, w), np.float32)
    counts = np.zeros((3, h, w), np.float32)
    padded_v = np.pad(np.where(usable, cfa, 0), radius)
    padded_u = np.pad(usable, radius)
    padded_c = np.pad(m.colors, radius, constant_values=-1)
    for dy in range(-radius, radius + 1):
        for dx in range(-radius, radius + 1):
            v = padded_v[radius + dy : radius + dy + h, radius + dx : radius + dx + w]
            u = padded_u[radius + dy : radius + dy + h, radius + dx : radius + dx + w]
            c = padded_c[radius + dy : radius + dy + h, radius + dx : radius + dx + w]
            for k in range(3):
                sel = u & (c == k)
                sums[k] += np.where(sel, v, 0)
                counts[k] += sel
    return sums, counts


def reconstruct(m: Mosaic, cfa: np.ndarray, model) -> np.ndarray:
    """rl_cfa_reconstruct_highlights."""
    if model is None:
        return cfa
    clip = model["clip"]
    own_clip = clip[m.colors]
    clipped = cfa >= own_clip
    usable = (cfa < own_clip) & (cfa >= 0.5 * own_clip)
    sums, counts = neighbourhood_means(m, cfa, usable)
    out = cfa.copy()
    ys, xs = np.nonzero(clipped)
    color = m.colors[ys, xs].astype(np.int64)
    first = counts[(color + 1) % 3, ys, xs] > 0
    second = counts[(color + 2) % 3, ys, xs] > 0
    none = ~first & ~second
    which = np.where(first & second, 0, np.where(first, 1, 2))
    coeff = model["coefficients"][color * 3 + which]
    means = np.stack([np.where(counts[k, ys, xs] > 0, sums[k, ys, xs] / np.maximum(counts[k, ys, xs], 1), 0)
                      for k in range(3)], axis=1)
    root = coeff[:, 0] + (coeff[:, 1:] * np.cbrt(means)).sum(axis=1)
    predicted = np.where(root > 0, root ** 3, 0)
    low = clip[color]
    value = np.clip(predicted, low, 4 * low)
    value[none] = model["w"]
    out[ys, xs] = value
    return out


def binned(m: Mosaic, cfa: np.ndarray) -> np.ndarray:
    """Each block's mean per colour: a flat area's balanced camera RGB at 1/block resolution."""
    b = m.block
    h, w = (cfa.shape[0] // b) * b, (cfa.shape[1] // b) * b
    colors = m.colors[:h, :w].reshape(h // b, b, w // b, b)
    values = cfa[:h, :w].reshape(h // b, b, w // b, b)
    rgb = np.zeros((h // b, w // b, 3), np.float32)
    for c in range(3):
        sel = colors == c
        rgb[..., c] = (values * sel).sum(axis=(1, 3)) / np.maximum(sel.sum(axis=(1, 3)), 1)
    return rgb


def clipped_channels(m: Mosaic) -> np.ndarray:
    """Per block, a bit per colour (1 R, 2 G, 4 B) set when any of its photosites clipped."""
    b = m.block
    h, w = (m.raw.shape[0] // b) * b, (m.raw.shape[1] // b) * b
    raw = m.raw[:h, :w].astype(np.float32)
    threshold = m.black[:h, :w] + CLIP_FRACTION * (m.white - m.black[:h, :w])
    over = (raw >= threshold).reshape(h // b, b, w // b, b)
    colors = m.colors[:h, :w].reshape(h // b, b, w // b, b)
    bits = np.zeros((h // b, w // b), np.int8)
    for c in range(3):
        bits |= ((over & (colors == c)).any(axis=(1, 3)) * (1 << c)).astype(np.int8)
    return bits


SRGB_TO_REC2020 = np.array([
    [0.6274039, 0.3292830, 0.0433131],
    [0.0690973, 0.9195404, 0.0113623],
    [0.0163914, 0.0880133, 0.8955953],
])
REC2020_TO_XYZ = np.array([
    [0.6369580, 0.1446169, 0.1688810],
    [0.2627002, 0.6779981, 0.0593017],
    [0.0000000, 0.0280727, 1.0609851],
])
XYZ_TO_LMS = np.array([
    [0.8189330101, 0.3618667424, -0.1288597137],
    [0.0329845436, 0.9293118715, 0.0361456387],
    [0.0482003018, 0.2643662691, 0.6338517070],
])
LMS_TO_LAB = np.array([
    [0.2104542553, 0.7936177850, -0.0040720468],
    [1.9779984951, -2.4285922050, 0.4505937099],
    [0.0259040371, 0.7827717662, -0.8086757660],
])


def to_rec2020(m: Mosaic, rgb: np.ndarray) -> np.ndarray:
    return rgb @ (SRGB_TO_REC2020 @ m.rgb_cam).T


def oklab(rec2020: np.ndarray) -> np.ndarray:
    xyz = rec2020 @ REC2020_TO_XYZ.T
    lms = np.cbrt(np.maximum(xyz @ XYZ_TO_LMS.T, 0))
    return lms @ LMS_TO_LAB.T


def chroma_at_equal_lightness(rec2020: np.ndarray) -> np.ndarray:
    """OKLab chroma of the colour scaled to OKLab L = 0.8 (an unclipped light grey's lightness),
    so colours above white are compared as they look once pulled below it."""
    luminance = rec2020 @ REC2020_TO_XYZ[1]
    target = 0.8 ** 3  # OKLab L is about the cube root of luminance for neutrals
    scaled = rec2020 * (target / np.maximum(luminance, 1e-6))[..., None]
    lab = oklab(scaled)
    return np.hypot(lab[..., 1], lab[..., 2]), np.degrees(np.arctan2(lab[..., 2], lab[..., 1]))
