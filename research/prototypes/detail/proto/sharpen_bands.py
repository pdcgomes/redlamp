"""Sharpening on the shared decomposition against SHP-01 (separator + Richardson-Lucy), on the
restoration test set SHP-01 was calibrated on (shp01_calibrate.py's protocol and seeds).

Band equivalent: log2 luminance -> 5 B3 à-trous bands; each band shrunk by a non-negative garrote at
k noise sigmas (the noise of log luminance at that scale, from the noise model and the local level);
the unsharp and deconvolution details are fixed weighted sums of the shrunk bands, fitted to the
unsharp mask's and the linearised 4-iteration Richardson-Lucy's responses for the Radius.
"""

from __future__ import annotations

import itertools
import sys
import time

import numpy as np

sys.path.insert(0, "/Users/pedrogomes/src/darkroom/research/prototypes/restoration")
from common import TESTSET, load_manifest, poisson_gaussian_noise, read_rgb, srgb_to_linear, linear_to_srgb  # noqa

from detail import (FLOOR, REC2020, WHITE_SIGMAS, atrous, atrous_blur, fit_band_weights, gaussian, rl_linear,
                    unsharp_linear)

OPPONENT = np.array([[0.57735027] * 3, [0.70710678, 0, -0.70710678], [0.40824829, -0.81649658, 0.40824829]],
                    np.float32)
LOW_ISO = (2e-4, 1e-6)
SCALES = 5


def separate(linear_rgb, a, b, k):
    """shp01_calibrate.separate: the GAT opponent à-trous garrote at k sigmas, luma and chroma."""
    if k <= 0:
        return linear_rgb
    root = np.sqrt(b)
    stabilized = (2 * (np.sqrt(np.maximum(a * linear_rgb + b, 0)) - root) / a).astype(np.float32)
    current = stabilized @ OPPONENT.T
    total = np.zeros_like(current)
    for scale in range(5):
        coarse = np.stack([atrous_blur(current[..., c], 1 << scale) for c in range(3)], axis=-1)
        detail = current - coarse
        t = k * WHITE_SIGMAS[scale]
        r2 = (detail[..., 0] / t) ** 2
        total[..., 0] += np.where(r2 > 1, detail[..., 0] * (1 - 1 / np.maximum(r2, 1e-12)), 0)
        c2 = (detail[..., 1] ** 2 + detail[..., 2] ** 2) / t ** 2
        total[..., 1:] += np.where(c2 > 1, 1 - 1 / np.maximum(c2, 1e-12), 0)[..., None] * detail[..., 1:]
        current = coarse
    stabilized = (total + current) @ OPPONENT
    u = 0.5 * a * stabilized + root
    return np.maximum((u * np.abs(u) - b) / a, 0)


def richardson_lucy(d, sigma, n=4):
    estimate = d.copy()
    for _ in range(n):
        estimate = estimate * gaussian(d / np.maximum(gaussian(estimate, sigma), 1e-6), sigma)
    return estimate


def apply_boost(linear_rgb, detail, amount, detail_slider):
    halo = 0.08 + 0.9 * detail_slider ** 2
    return linear_rgb * np.exp2(amount * halo * np.tanh(detail / halo))[..., None]


def shp01(linear, a, b, amount, radius, d, k=3):
    clean = separate(linear, a, b, k)
    d_luma = np.maximum(clean @ REC2020, 0) + FLOOR
    log_d = np.log2(d_luma)
    sigma = 0.8 * radius
    usm = log_d - gaussian(log_d, sigma)
    deconv = np.log2(np.maximum(richardson_lucy(d_luma, sigma), 1e-6)) - log_d
    return apply_boost(linear, (1 - d) * usm + d * deconv, amount, d)


WEIGHTS: dict[float, tuple[np.ndarray, np.ndarray]] = {}


def weights_for(sigma: float):
    if sigma not in WEIGHTS:
        usm, _ = fit_band_weights(lambda f2: unsharp_linear(f2, sigma), SCALES)
        rl, _ = fit_band_weights(lambda f2: rl_linear(f2, sigma) - 1, SCALES)
        WEIGHTS[sigma] = (usm, rl)
    return WEIGHTS[sigma]


def garrote(w, t):
    r2 = (w / np.maximum(t, 1e-12)) ** 2
    return np.where(r2 > 1, w * (1 - 1 / np.maximum(r2, 1e-12)), 0).astype(np.float32)


def band_sharpen(linear, a, b, amount, radius, d, k=3.0, noise_scale=1.0):
    """The proposal: one log-luminance decomposition, garrote per band, fitted weights."""
    y = np.maximum(linear @ REC2020, 0)
    log_y = np.log2(y + FLOOR)
    bands, _ = atrous(log_y, SCALES)
    # Noise of luminance from the model, at a smoothed local level per channel.
    local = np.stack([gaussian(linear[..., c], 2.0) for c in range(3)], -1)
    var_y = np.maximum(a * local + b, 0) @ (REC2020 ** 2)
    sigma_log = np.sqrt(var_y) / ((np.maximum(local @ REC2020, 0) + FLOOR) * np.log(2)) * noise_scale
    shrunk = [garrote(w, k * WHITE_SIGMAS[s] * sigma_log) if k > 0 else w for s, w in enumerate(bands)]
    usm_w, rl_w = weights_for(0.8 * radius)
    usm = sum(wt * band for wt, band in zip(usm_w, shrunk))
    deconv = sum(wt * band for wt, band in zip(rl_w, shrunk))
    return apply_boost(linear, (1 - d) * usm + d * deconv, amount, d)


def psnr(a, b):
    a, b = a[8:-8, 8:-8], b[8:-8, 8:-8]
    return float(10 * np.log10(1 / max(((a - b) ** 2).mean(), 1e-12)))


def main():
    print("Fitted band weights (5 B3 à-trous bands, natural-image weighting) and relative fit error")
    for radius in [0.5, 1.0, 1.5, 2.0, 3.0]:
        sigma = 0.8 * radius
        usm, e1 = fit_band_weights(lambda f2: unsharp_linear(f2, sigma), SCALES)
        rl, e2 = fit_band_weights(lambda f2: rl_linear(f2, sigma) - 1, SCALES)
        print(f"  Radius {radius}: unsharp {np.round(usm, 3)} (err {e1:.3f}); RL4 {np.round(rl, 3)} (err {e2:.3f})")

    manifest = load_manifest()
    crops = list(manifest["crops"])
    degradations = list(manifest["degradations"])
    noise = manifest["noise"]
    cases = ["soft_g1.5", "defocus_r4", "defocus_r3_noise"]
    settings = [(2.0, 1.0, 1.0), (2.0, 1.0, 0.25), (1.0, 0.4, 0.25), (1.0, 1.0, 1.0), (1.5, 1.0, 0.5)]
    methods = {
        "SHP-01": lambda lin, a, b, am, r, d: shp01(lin, a, b, am, r, d),
        "bands k3": lambda lin, a, b, am, r, d: band_sharpen(lin, a, b, am, r, d, k=3),
        "bands k2": lambda lin, a, b, am, r, d: band_sharpen(lin, a, b, am, r, d, k=2),
        "bands k0": lambda lin, a, b, am, r, d: band_sharpen(lin, a, b, am, r, d, k=0),
    }
    gains = {}
    timings = {m: 0.0 for m in methods}
    for crop, case in itertools.product(crops, cases):
        lq = read_rgb(TESTSET / "lq" / f"{crop}__{case}.png")
        gt = read_rgb(TESTSET / "gt" / f"{crop}.png")
        linear = srgb_to_linear(lq).astype(np.float32)
        noisy = manifest["degradations"][case].get("noise")
        a, b = (noise["a"], noise["b"]) if noisy else LOW_ISO
        target = gt
        if noisy:
            target = poisson_gaussian_noise(gt, seed=1000 * crops.index(crop) + degradations.index(case),
                                            a=noise["a"], b=noise["b"])
        base = psnr(lq, target)
        for (radius, amount, d), (name, method) in itertools.product(settings, methods.items()):
            start = time.perf_counter()
            out = np.clip(linear_to_srgb(method(linear, a, b, amount, radius, d)), 0, 1)
            timings[name] += time.perf_counter() - start
            gains.setdefault((name, radius, amount, d, case), []).append(psnr(out, target) - base)
        print(f"{crop} {case}", flush=True)

    print("\nMean PSNR gain over the input (dB), 14 crops per case")
    print("| Radius / Amount / Detail | method | " + " | ".join(cases) + " |")
    for radius, amount, d in settings:
        for name in methods:
            cells = [f"{np.mean(gains[(name, radius, amount, d, c)]):+.2f}" for c in cases]
            print(f"| {radius} / {int(amount * 100)} / {int(d * 100)} | {name} | " + " | ".join(cells) + " |")

    # Flat noise: how much sharpening grows noise on a flat grey patch.
    print("\nFlat noise growth (std after / before), grey 0.18 linear, a=1.5e-3 b=2e-6")
    rng = np.random.default_rng(5)
    flat = np.full((512, 512, 3), 0.18, np.float32)
    a, b = noise["a"], noise["b"]
    flat = (flat + rng.normal(size=flat.shape).astype(np.float32) * np.sqrt(a * flat + b)).astype(np.float32)
    y0 = (flat @ REC2020)[32:-32, 32:-32].std()
    for (radius, amount, d), (name, method) in itertools.product([(1.0, 1.0, 0.0), (1.0, 1.0, 0.25), (2.0, 1.0, 1.0)],
                                                                   methods.items()):
        out = method(flat, a, b, amount, radius, d)
        print(f"  R{radius} A{int(amount * 100)} D{int(d * 100)} {name}: {(out @ REC2020)[32:-32, 32:-32].std() / y0:.3f}")
    print("\nseconds per method (CPU, all crops):", {k: round(v, 1) for k, v in timings.items()})


if __name__ == "__main__":
    main()
