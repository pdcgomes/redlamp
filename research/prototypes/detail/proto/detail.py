"""W4-DESIGN prototype (TON-06): shared filters, today's detail stage, and the proposed decomposition.

Everything works on 2-D float32 arrays of linear luminance or log2 luminance, rows x columns.
"""

from __future__ import annotations

import json
from pathlib import Path

import cv2
import numpy as np
from scipy import ndimage

OUT = Path("/tmp/w4-detail")
B3 = np.array([1, 4, 6, 4, 1], np.float32) / 16
FLOOR = 1.0 / 1024
REC2020 = np.array([0.2627, 0.6780, 0.0593], np.float32)
WHITE_SIGMAS = [0.8908, 0.2007, 0.0856, 0.0413, 0.0205, 0.0102, 0.0051]


# --- Basic filters ---------------------------------------------------------------------------


def atrous_blur(x: np.ndarray, step: int) -> np.ndarray:
    kernel = np.zeros(4 * step + 1, np.float32)
    kernel[::step] = B3
    return cv2.sepFilter2D(x.astype(np.float32), -1, kernel, kernel, borderType=cv2.BORDER_REPLICATE)


def atrous(x: np.ndarray, scales: int, first_step: int = 1) -> tuple[list[np.ndarray], np.ndarray]:
    """B3-spline à-trous bands w_0 .. w_{scales-1} and the residual (holes first_step, 2 first_step, ...)."""
    bands, current = [], x.astype(np.float32)
    for s in range(scales):
        coarse = atrous_blur(current, first_step << s)
        bands.append(current - coarse)
        current = coarse
    return bands, current


def edge_avoiding_atrous(x: np.ndarray, scales: int, sigma_r: float, first_step: int = 1):
    """Edge-avoiding à-trous (Dammertz et al. 2010; Hanika et al. 2011): each tap weighted by how alike
    its value is to the centre's, so strong edges stay in the coarse levels. Non-separable 5x5."""
    bands, current = [], x.astype(np.float32)
    for s in range(scales):
        step = first_step << s
        padded = np.pad(current, 2 * step, mode="edge")
        h, w = current.shape
        total = np.zeros_like(current)
        weights = np.zeros_like(current)
        for i, wi in enumerate(B3):
            for j, wj in enumerate(B3):
                tap = padded[i * step:i * step + h, j * step:j * step + w]
                r = np.exp(-0.5 * ((tap - current) / sigma_r) ** 2)
                total += wi * wj * r * tap
                weights += wi * wj * r
        coarse = total / weights
        bands.append(current - coarse)
        current = coarse
    return bands, current


def gaussian(x: np.ndarray, sigma: float) -> np.ndarray:
    radius = min(int(np.ceil(3 * sigma)), 12)
    return cv2.GaussianBlur(x.astype(np.float32), (2 * radius + 1, 2 * radius + 1), sigma,
                            borderType=cv2.BORDER_REPLICATE)


def box_mips(x: np.ndarray, levels: int) -> list[np.ndarray]:
    """Metal's generateMipmaps: each level the 2x2 box average of the one before (odd edges dropped)."""
    mips = [x.astype(np.float32)]
    for _ in range(levels):
        p = mips[-1]
        h, w = (p.shape[0] // 2) * 2, (p.shape[1] // 2) * 2
        p = p[:h, :w]
        mips.append(0.25 * (p[0::2, 0::2] + p[1::2, 0::2] + p[0::2, 1::2] + p[1::2, 1::2]))
    return mips


def bspline_at(level_image: np.ndarray, level: int, target_level: int, shape: tuple[int, int]) -> np.ndarray:
    """`logLumaAt`'s sampling: the cubic B-spline (no prefilter) through a pyramid level, at the texel
    centres of `target_level` (clamp to edge)."""
    scale = 2.0 ** (target_level - level)

    def along(image, positions, axis):
        i = np.floor(positions).astype(int)
        f = positions - i
        weights = [(1 - f) ** 3 / 6, (4 - 6 * f ** 2 + 3 * f ** 3) / 6, (1 + 3 * f + 3 * f ** 2 - 3 * f ** 3) / 6,
                   f ** 3 / 6]
        n = image.shape[axis]
        out = 0
        for k, wk in enumerate(weights):
            taps = np.take(image, np.clip(i - 1 + k, 0, n - 1), axis=axis)
            out = out + (wk[:, None] if axis == 0 else wk[None, :]) * taps
        return out

    ys = (np.arange(shape[0]) + 0.5) * scale - 0.5
    xs = (np.arange(shape[1]) + 0.5) * scale - 0.5
    return along(along(level_image, ys, 0), xs, 1).astype(np.float32)


def bilinear_resize(x: np.ndarray, shape: tuple[int, int]) -> np.ndarray:
    """The develop kernel's sampling of the detail output: bilinear at output pixel centres."""
    ys = (np.arange(shape[0]) + 0.5) * x.shape[0] / shape[0] - 0.5
    xs = (np.arange(shape[1]) + 0.5) * x.shape[1] / shape[1] - 0.5
    yy, xx = np.meshgrid(ys, xs, indexing="ij")
    return ndimage.map_coordinates(x, [yy, xx], order=1, mode="nearest").astype(np.float32)


def lanczos_resize(x: np.ndarray, shape: tuple[int, int]) -> np.ndarray:
    """Antialiased Lanczos-3 downscale (MPSImageLanczosScale)."""
    from PIL import Image
    return np.asarray(Image.fromarray(x.astype(np.float32), mode="F").resize((shape[1], shape[0]), Image.LANCZOS),
                      np.float32)


def box_filter(x: np.ndarray, radius: int) -> np.ndarray:
    return cv2.blur(x.astype(np.float32), (2 * radius + 1, 2 * radius + 1), borderType=cv2.BORDER_REPLICATE)


def guided_coefficients(guide: np.ndarray, radius: int, epsilon: float) -> tuple[np.ndarray, np.ndarray]:
    """Self-guided filter (He, Sun and Tang 2010) coefficients, averaged: output = a * guide + b."""
    mean = box_filter(guide, radius)
    var = box_filter(guide * guide, radius) - mean * mean
    a = var / (var + epsilon)
    b = mean - a * mean
    return box_filter(a, radius), box_filter(b, radius)


# --- Frequency responses ----------------------------------------------------------------------


def band_responses(f: np.ndarray, scales: int, fy: np.ndarray | None = None, first_step: int = 1):
    """Responses of the à-trous bands (and residual) at frequencies f (cycles per pixel), 1-D or 2-D."""
    def h(nu):
        return np.cos(np.pi * nu) ** 4
    c = np.ones_like(f)
    bands = []
    for s in range(scales):
        step = first_step << s
        hs = h(step * f) if fy is None else h(step * f) * h(step * fy)
        bands.append(c * (1 - hs))
        c = c * hs
    return bands, c


def rl_linear(f2: np.ndarray, sigma: float, iterations: int = 4) -> np.ndarray:
    """Linearised Richardson-Lucy from the observation (estimate_0 = D) with a Gaussian PSF: the
    transfer function from log D's fluctuations to the estimate's (Landweber form)."""
    g = np.exp(-2 * np.pi ** 2 * sigma ** 2 * f2)
    q = (1 - g * g) ** iterations
    return q + (1 - q) / np.maximum(g, 1e-12)


def unsharp_linear(f2: np.ndarray, sigma: float) -> np.ndarray:
    return 1 - np.exp(-2 * np.pi ** 2 * sigma ** 2 * f2)


def fit_band_weights(target, scales: int, n: int = 64, spectrum_power: float = 1.0) -> tuple[np.ndarray, float]:
    """Least-squares weights a_s so that sum a_s W_s(fx, fy) matches target(fx^2 + fy^2) over the
    frequency plane, weighted by a natural-image spectrum |f|^-power. Returns weights and the
    relative RMS error of the fit."""
    f = (np.arange(n) + 0.5) / (2 * n)
    fx, fy = np.meshgrid(f, f, indexing="ij")
    bands, _ = band_responses(fx, scales, fy)
    A = np.stack([b.ravel() for b in bands], 1)
    t = target(fx ** 2 + fy ** 2).ravel()
    w = (fx ** 2 + fy ** 2).ravel() ** (-spectrum_power / 2)
    sw = np.sqrt(w)
    weights, *_ = np.linalg.lstsq(A * sw[:, None], t * sw, rcond=None)
    err = np.sqrt(np.sum(w * (A @ weights - t) ** 2) / np.sum(w * t ** 2))
    return weights.astype(np.float32), float(err)


# --- Data ---------------------------------------------------------------------------------------


def load_dump(name: str) -> tuple[np.ndarray, dict]:
    meta = json.loads((OUT / f"{name}_meta.json").read_text())
    rgb = np.fromfile(OUT / f"{name}_rgb.f32", np.float32).reshape(meta["height"], meta["width"], 3)
    return rgb, meta


def luminance(rgb: np.ndarray, meta: dict) -> np.ndarray:
    return (rgb @ np.array(meta["luma"][:3], np.float32)).astype(np.float32)


def log_luma(y: np.ndarray) -> np.ndarray:
    return np.log2(np.maximum(y, 0) + FLOOR).astype(np.float32)
