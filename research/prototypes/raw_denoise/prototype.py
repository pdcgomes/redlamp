"""Pre-demosaic prototypes: classical denoising on the mosaic, before Redlamp's demosaic.

`cfa_nlm` is non-local means on the mosaic (Buades, Coll & Morel 2005) restricted to offsets that
keep the CFA phase, so a patch is only compared with patches of the same colour layout (the idea
behind BM3D-CFA, Danielyan et al. 2009). Patch distances are normalised by the Poisson-Gaussian
variance predicted from a same-colour local mean, so one strength works at every brightness and ISO,
and averaging happens on the linear raw values, so means are kept.

`blend` keeps part of the noise (a light clean-up that leaves the rest to the Detail panel).
"""

import numpy as np
from scipy.ndimage import gaussian_filter, uniform_filter

from common import cfa_index


def phase_offsets(cfa: np.ndarray, radius: int) -> list:
    """Offsets within `radius` under which the CFA tile maps onto itself."""
    th, tw = cfa.shape
    rows, cols = np.arange(th)[:, None], np.arange(tw)[None, :]
    offsets = []
    for dy in range(-radius, radius + 1):
        for dx in range(-radius, radius + 1):
            if (dy, dx) != (0, 0) and np.array_equal(cfa[(rows + dy) % th, (cols + dx) % tw], cfa):
                offsets.append((dy, dx))
    return offsets


def same_colour_mean(raw: np.ndarray, cfa: np.ndarray, sigma: float = 2.0) -> np.ndarray:
    """A local mean at every photosite from photosites of its own colour."""
    index = cfa_index(cfa, *raw.shape)
    out = np.zeros_like(raw)
    for c in range(3):
        mask = (index == c).astype(np.float32)
        num = gaussian_filter(raw * mask, sigma, mode="wrap")
        den = gaussian_filter(mask, sigma, mode="wrap")
        out[index == c] = (num / np.maximum(den, 1e-6))[index == c]
    return out


def cfa_nlm(raw: np.ndarray, cfa: np.ndarray, a: float, b: float, h: float = 0.45,
            patch: int | None = None, radius: int | None = None) -> np.ndarray:
    th = cfa.shape[0]
    patch = patch or (5 if th == 2 else 7)
    radius = radius or (8 if th == 2 else 9)
    variance = a * np.maximum(same_colour_mean(raw, cfa), 0) + b
    total = np.zeros_like(raw, dtype=np.float64)
    weights = np.zeros_like(raw, dtype=np.float64)
    best = np.zeros_like(raw, dtype=np.float64)
    for dy, dx in phase_offsets(cfa, radius):
        other = np.roll(raw, (-dy, -dx), axis=(0, 1))
        other_var = np.roll(variance, (-dy, -dx), axis=(0, 1))
        distance = uniform_filter((raw - other) ** 2 / (variance + other_var), patch, mode="wrap")
        w = np.exp(-np.maximum(distance - 1.0, 0) / (h * h))
        total += w * other
        weights += w
        best = np.maximum(best, w)
    # The centre counts as much as its best match (the usual NL-means convention), and never less
    # than 0.1, so a photosite with no similar patch keeps its own value.
    centre = np.maximum(best, 0.1)
    total += centre * raw
    weights += centre
    return (total / np.maximum(weights, 1e-12)).astype(np.float32)


def blend(noisy: np.ndarray, denoised: np.ndarray, keep: float) -> np.ndarray:
    return (denoised + keep * (noisy - denoised)).astype(np.float32)
