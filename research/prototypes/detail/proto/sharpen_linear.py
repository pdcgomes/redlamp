"""Sharpening reading a linear-luminance decomposition: (1) as the separator (garrote on the bands of
linear Y, instead of a second noise reduction in the stabilised opponent space), then real RL; (2) the
deconvolution as fitted band weights in linear light instead of RL iterations."""

from __future__ import annotations

import itertools
import sys

import numpy as np

sys.path.insert(0, "/Users/pedrogomes/src/darkroom/research/prototypes/restoration")
from common import TESTSET, load_manifest, poisson_gaussian_noise, read_rgb, srgb_to_linear, linear_to_srgb  # noqa

from detail import FLOOR, REC2020, WHITE_SIGMAS, atrous, fit_band_weights, gaussian, rl_linear, unsharp_linear
from sharpen_bands import LOW_ISO, apply_boost, garrote, psnr, richardson_lucy, separate

SCALES = 5


def linear_separator(linear, a, b, k=3.0):
    """Clean linear luminance: the garrote on 5 à-trous bands of linear Y at k sigmas of Y's noise."""
    y = np.maximum(linear @ REC2020, 0).astype(np.float32)
    bands, residual = atrous(y, SCALES)
    local = np.stack([gaussian(linear[..., c], 2.0) for c in range(3)], -1)
    sigma_y = np.sqrt(np.maximum(a * local + b, 0) @ (REC2020 ** 2))
    return residual + sum(garrote(w, k * WHITE_SIGMAS[s] * sigma_y) for s, w in enumerate(bands)), bands, residual, sigma_y


def detail_from(dl, sigma, d, rl_mode, bands=None, sigma_y=None, k=3.0):
    log_d = np.log2(dl)
    usm = log_d - gaussian(log_d, sigma)
    if rl_mode == "rl":
        estimate = richardson_lucy(dl, sigma)
    else:
        weights, _ = fit_band_weights(lambda f2: rl_linear(f2, sigma) - 1, SCALES)
        shrunk = [garrote(w, k * WHITE_SIGMAS[s] * sigma_y) for s, w in enumerate(bands)]
        estimate = dl + sum(wt * band for wt, band in zip(weights, shrunk))
    deconv = np.log2(np.maximum(estimate, 1e-6)) - log_d
    return (1 - d) * usm + d * deconv


def methods(linear, a, b, amount, radius, d):
    sigma = 0.8 * radius
    gat = np.maximum(separate(linear, a, b, 3) @ REC2020, 0) + FLOOR
    lin, bands, residual, sigma_y = linear_separator(linear, a, b)
    lin = np.maximum(lin, 0) + FLOOR
    gat_bands, _ = atrous(gat - FLOOR, SCALES)
    out = {
        "SHP-01 (GAT separator, RL4)": detail_from(gat, sigma, d, "rl"),
        "linear-Y garrote separator, RL4": detail_from(lin, sigma, d, "rl"),
        "GAT separator, band-fitted RL (linear light)": detail_from(gat, sigma, d, "bands", gat_bands,
                                                                    np.zeros_like(sigma_y), 0),
        "linear-Y garrote, band-fitted RL (linear light)": detail_from(lin, sigma, d, "bands", bands, sigma_y),
    }
    return {name: apply_boost(linear, detail, amount, d) for name, detail in out.items()}


def main():
    manifest = load_manifest()
    crops, degradations, noise = list(manifest["crops"]), list(manifest["degradations"]), manifest["noise"]
    cases = ["soft_g1.5", "defocus_r4", "defocus_r3_noise"]
    settings = [(2.0, 1.0, 1.0), (1.0, 0.4, 0.25), (1.0, 1.0, 0.25), (1.5, 1.0, 0.5)]
    gains = {}
    for crop, case in itertools.product(crops, cases):
        lq = read_rgb(TESTSET / "lq" / f"{crop}__{case}.png")
        gt = read_rgb(TESTSET / "gt" / f"{crop}.png")
        linear = srgb_to_linear(lq).astype(np.float32)
        noisy = manifest["degradations"][case].get("noise")
        a, b = (noise["a"], noise["b"]) if noisy else LOW_ISO
        target = gt if not noisy else poisson_gaussian_noise(
            gt, seed=1000 * crops.index(crop) + degradations.index(case), a=noise["a"], b=noise["b"])
        base = psnr(lq, target)
        for radius, amount, d in settings:
            for name, image in methods(linear, a, b, amount, radius, d).items():
                out = np.clip(linear_to_srgb(image), 0, 1)
                gains.setdefault((name, radius, amount, d, case), []).append(psnr(out, target) - base)
    names = list(methods(np.full((64, 64, 3), 0.2, np.float32), 1e-3, 1e-6, 1, 1, 1))
    print("| Radius / Amount / Detail | method | " + " | ".join(cases) + " |")
    for radius, amount, d in settings:
        for name in names:
            cells = [f"{np.mean(gains[(name, radius, amount, d, c)]):+.2f}" for c in cases]
            print(f"| {radius} / {int(amount * 100)} / {int(d * 100)} | {name} | " + " | ".join(cells) + " |")
    rng = np.random.default_rng(5)
    a, b = noise["a"], noise["b"]
    for level in (0.02, 0.18):
        flat = np.full((512, 512, 3), level, np.float32)
        flat = (flat + rng.normal(size=flat.shape).astype(np.float32) * np.sqrt(a * flat + b)).astype(np.float32)
        y0 = (flat @ REC2020)[32:-32, 32:-32].std()
        for radius, amount, d in [(1.0, 1.0, 0.25), (2.0, 1.0, 1.0)]:
            for name, image in methods(flat, a, b, amount, radius, d).items():
                print(f"flat {level}, R{radius} A{int(amount * 100)} D{int(d * 100)}, {name}: noise x"
                      f"{(image @ REC2020)[32:-32, 32:-32].std() / y0:.3f}")


if __name__ == "__main__":
    main()
