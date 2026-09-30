"""Calibrate SHP-01 (noise-aware capture sharpening) before it goes into Metal.

Mirrors the planned GPU algorithm on the restoration bake-off test set (make_testset.py):

1. Separator: the Detail stage's denoiser. Generalised Anscombe stabilisation, the orthonormal
   opponent transform, a 5-scale B3 à-trous decomposition, and a non-negative garrote on luma and
   chroma at `k` noise sigmas per scale. The luminance of the result is the clean luminance D.
2. Richardson-Lucy on linear D for N iterations, with a Gaussian PSF of sigma = 0.8 x Radius.
3. Detail in stops: usm = log2 D - blur(log2 D); deconv = log2 S - log2 D; mix by d = Detail / 100.
4. boost = Amount x halo x tanh(detail / halo), halo = 0.08 + 0.9 x Detail^2 (as today); the output is
   the *input* RGB times exp2(boost), so noise passes through where D is flat.

"Today" is the shipped sharpening: the same boost, but from the noisy luminance, with d = 0.

Usage: build/restoration-venv/bin/python research/prototypes/restoration/shp01_calibrate.py
Writes build/proto-out/shp01/{grid.json,summary.md} and docs/research/images/shp01-calibration.jpg
"""

from __future__ import annotations

import itertools
import json

import cv2
import numpy as np
import torch

from common import OUT, REPO, TESTSET, load_manifest, poisson_gaussian_noise, read_rgb, srgb_to_linear, linear_to_srgb

WORK = OUT.parent / "shp01"
LUMA = np.array([0.2627, 0.6780, 0.0593], np.float32)  # Rec. 2020, as the engine uses
B3 = np.array([1, 4, 6, 4, 1], np.float32) / 16
WHITE_SIGMAS = [0.8908, 0.2007, 0.0856, 0.0413, 0.0205]  # NoiseCalibration.white, level 0
LOW_ISO = (2e-4, 1e-6)  # noise model assumed for the renders' own (base-ISO) noise
FLOOR = 1.0 / 1024  # the log floor the engine adds


def atrous_blur(x: np.ndarray, step: int) -> np.ndarray:
    kernel = np.zeros(4 * step + 1, np.float32)
    kernel[::step] = B3
    return cv2.sepFilter2D(x, -1, kernel, kernel, borderType=cv2.BORDER_REPLICATE)


OPPONENT = np.array([[0.57735027] * 3, [0.70710678, 0, -0.70710678], [0.40824829, -0.81649658, 0.40824829]],
                    np.float32)


def separate(linear_rgb: np.ndarray, a: float, b: float, k: float) -> np.ndarray:
    """The clean linear RGB the separator leaves (GPU: encodeDenoise at k sigmas, luma and chroma).

    Chroma must be shrunk too: the opponent luma axis weights R, G, B equally, but sharpening reads
    Rec. 2020 luminance, which picks up the chroma axes' noise. Luma alone let flat noise grow 17-29%.
    """
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


def gaussian(x: np.ndarray, sigma: float) -> np.ndarray:
    radius = min(int(np.ceil(3 * sigma)), 12)
    return cv2.GaussianBlur(x, (2 * radius + 1, 2 * radius + 1), sigma, borderType=cv2.BORDER_REPLICATE)


def richardson_lucy(d: np.ndarray, sigma: float, iterations: list[int]) -> dict[int, np.ndarray]:
    """Estimates after each requested iteration count (Gaussian PSF is symmetric, so no flip)."""
    estimate, out = d.copy(), {}
    for i in range(1, max(iterations) + 1):
        estimate = estimate * gaussian(d / np.maximum(gaussian(estimate, sigma), 1e-6), sigma)
        if i in iterations:
            out[i] = estimate.copy()
    return out


def apply_boost(linear_rgb: np.ndarray, detail: np.ndarray, amount: float, detail_slider: float) -> np.ndarray:
    halo = 0.08 + 0.9 * detail_slider ** 2
    boost = amount * halo * np.tanh(detail / halo)
    return linear_rgb * np.exp2(boost)[..., None]


def todays_sharpening(linear_rgb: np.ndarray, amount: float, radius: float, detail_slider: float) -> np.ndarray:
    log_y = np.log2(np.maximum(linear_rgb @ LUMA, 0) + FLOOR)
    return apply_boost(linear_rgb, log_y - gaussian(log_y, 0.8 * radius), amount, detail_slider)


def psnr(a: np.ndarray, b: np.ndarray) -> float:
    a, b = a[8:-8, 8:-8], b[8:-8, 8:-8]
    return float(10 * np.log10(1 / max(((a - b) ** 2).mean(), 1e-12)))


def high_frequency(srgb: np.ndarray) -> float:
    """Mean absolute Laplacian of luma: how crisp an image reads."""
    luma = (srgb @ np.array([0.299, 0.587, 0.114])).astype(np.float32)
    return float(np.abs(cv2.Laplacian(luma, cv2.CV_32F)).mean())


def main() -> None:
    WORK.mkdir(parents=True, exist_ok=True)
    manifest = load_manifest()
    crops = list(manifest["crops"])
    degradations = list(manifest["degradations"])
    noise = manifest["noise"]
    cases = ["soft_g1.5", "defocus_r4", "defocus_r3_noise"]
    ks, radii, iteration_counts = [0, 2, 3, 4], [1.0, 1.5, 2.0], [3, 4, 6, 8]
    ds, amounts = [0, 0.25, 0.5, 0.75, 1.0], [0.4, 1.0, 1.5]

    rows = []
    for crop, case in itertools.product(crops, cases):
        lq = read_rgb(TESTSET / "lq" / f"{crop}__{case}.png")
        gt = read_rgb(TESTSET / "gt" / f"{crop}.png")
        linear = srgb_to_linear(lq).astype(np.float32)
        a, b = (noise["a"], noise["b"]) if manifest["degradations"][case].get("noise") else LOW_ISO
        target = gt
        if manifest["degradations"][case].get("noise"):
            seed = 1000 * crops.index(crop) + degradations.index(case)
            target = poisson_gaussian_noise(gt, seed=seed, a=noise["a"], b=noise["b"])
        base = dict(crop=crop, case=case, input=psnr(lq, target))
        for radius in radii:
            for amount in amounts:
                out = linear_to_srgb(todays_sharpening(linear, amount, radius, 0.25))
                rows.append(dict(base, method="today", k=None, radius=radius, n=None, d=None, amount=amount,
                                 psnr=psnr(np.clip(out, 0, 1), target), hf=high_frequency(np.clip(out, 0, 1))))
        for k in ks:
            clean = separate(linear, a, b, k)
            d_luma = np.maximum(clean @ LUMA, 0) + FLOOR
            log_d = np.log2(d_luma)
            for radius in radii:
                sigma = 0.8 * radius
                usm = log_d - gaussian(log_d, sigma)
                estimates = richardson_lucy(d_luma, sigma, iteration_counts)
                for n, s in estimates.items():
                    deconv = np.log2(np.maximum(s, 1e-6)) - log_d
                    for d, amount in itertools.product(ds, amounts):
                        detail = (1 - d) * usm + d * deconv
                        out = np.clip(linear_to_srgb(apply_boost(linear, detail, amount, d)), 0, 1)
                        rows.append(dict(base, method="shp01", k=k, radius=radius, n=n, d=d, amount=amount,
                                         psnr=psnr(out, target), hf=high_frequency(out)))
        print(f"{crop} {case}", flush=True)
    (WORK / "grid.json").write_text(json.dumps(rows))
    summarise(rows)
    sheet(manifest)


def mean_psnr_gain(rows, **match) -> float:
    sel = [r for r in rows if all(r[key] == value for key, value in match.items())]
    return float(np.mean([r["psnr"] - r["input"] for r in sel])) if sel else float("nan")


def summarise(rows: list[dict]) -> None:
    lines = ["# SHP-01 calibration (generated by shp01_calibrate.py)", "",
             "Mean PSNR gain over the input, in dB (14 crops per case). The noisy case is scored against the sharp",
             "ground truth carrying the same noise, so keeping the noise is right and removing it is penalised.", ""]
    cases = ["soft_g1.5", "defocus_r4", "defocus_r3_noise"]
    lines += ["## Today (unsharp mask on noisy luma, Detail 25)", "",
              "| Radius | Amount | " + " | ".join(cases) + " |", "|---|---|" + "---|" * len(cases)]
    for radius, amount in itertools.product([1.0, 1.5, 2.0], [0.4, 1.0, 1.5]):
        cells = [f"{mean_psnr_gain(rows, method='today', radius=radius, amount=amount, case=c):+.2f}" for c in cases]
        lines.append(f"| {radius} | {amount} | " + " | ".join(cells) + " |")
    lines += ["", "## SHP-01: best settings per separator strength k and iteration count N (Radius 2, Amount 1.0)", "",
              "| k | N | d=0 | d=0.25 | d=0.5 | d=0.75 | d=1 | (case) |", "|---|---|---|---|---|---|---|---|"]
    for case in cases:
        for k, n in itertools.product([0, 2, 3, 4], [3, 4, 6, 8]):
            cells = [f"{mean_psnr_gain(rows, method='shp01', k=k, n=n, d=d, radius=2.0, amount=1.0, case=case):+.2f}"
                     for d in [0, 0.25, 0.5, 0.75, 1.0]]
            lines.append(f"| {k} | {n} | " + " | ".join(cells) + f" | {case} |")
    lines += ["", "## Defaults (Amount 40, Radius 1, Detail 25): crispness and PSNR gain", "",
              "| Method | mean |Laplacian| (soft_g1.5) | PSNR gain soft | noisy |", "|---|---|---|---|"]

    def hf(sel):
        return float(np.mean([r["hf"] for r in sel]))

    today = [r for r in rows if r["method"] == "today" and r["radius"] == 1.0 and r["amount"] == 0.4]
    lines.append(f"| today | {hf([r for r in today if r['case'] == 'soft_g1.5']):.4f} | "
                 f"{mean_psnr_gain(rows, method='today', radius=1.0, amount=0.4, case='soft_g1.5'):+.2f} | "
                 f"{mean_psnr_gain(rows, method='today', radius=1.0, amount=0.4, case='defocus_r3_noise'):+.2f} |")
    for k, n in itertools.product([2, 3, 4], [3, 4, 6]):
        sel = [r for r in rows if r["method"] == "shp01" and r["k"] == k and r["n"] == n and r["radius"] == 1.0
               and r["amount"] == 0.4 and r["d"] == 0.25]
        lines.append(f"| shp01 k={k} N={n} | {hf([r for r in sel if r['case'] == 'soft_g1.5']):.4f} | "
                     f"{mean_psnr_gain(rows, method='shp01', k=k, n=n, radius=1.0, amount=0.4, d=0.25, case='soft_g1.5'):+.2f} | "
                     f"{mean_psnr_gain(rows, method='shp01', k=k, n=n, radius=1.0, amount=0.4, d=0.25, case='defocus_r3_noise'):+.2f} |")
    (WORK / "summary.md").write_text("\n".join(lines) + "\n")
    print((WORK / "summary.md").read_text())


def sheet(manifest: dict, k: float = 3, n: int = 4) -> None:
    """Contact sheet: input, today at Amount 100 / Detail 25, SHP-01 at Detail 25 and 100, ground truth."""
    noise = manifest["noise"]
    lines = []
    for item, (x, y) in [("sony_branches__soft_g1.5", (180, 120)), ("fuji_text__defocus_r4", (180, 280)),
                         ("nikon_monkey__defocus_r3_noise", (170, 120)), ("leica_fur__defocus_r3_noise", (150, 150))]:
        crop, case = item.split("__")
        lq = read_rgb(TESTSET / "lq" / f"{item}.png")
        linear = srgb_to_linear(lq).astype(np.float32)
        a, b = (noise["a"], noise["b"]) if manifest["degradations"][case].get("noise") else LOW_ISO
        clean = separate(linear, a, b, k)
        d_luma = np.maximum(clean @ LUMA, 0) + FLOOR
        log_d = np.log2(d_luma)
        s = richardson_lucy(d_luma, 1.6, [n])[n]
        usm, deconv = log_d - gaussian(log_d, 1.6), np.log2(np.maximum(s, 1e-6)) - log_d
        tiles = [("input", lq), ("today, Amount 100", todays_sharpening(linear, 1.0, 2.0, 0.25))]
        for d in (0.25, 1.0):
            tiles.append((f"SHP-01, Detail {int(d * 100)}", apply_boost(linear, (1 - d) * usm + d * deconv, 1.0, d)))
        tiles.append(("ground truth", read_rgb(TESTSET / "gt" / f"{crop}.png")))
        row = []
        for index, (label, image) in enumerate(tiles):
            srgb = image if index in (0, len(tiles) - 1) else linear_to_srgb(image)
            tile = (np.clip(srgb[y:y + 160, x:x + 160], 0, 1) * 255).astype(np.uint8)
            tile = cv2.resize(tile, (320, 320), interpolation=cv2.INTER_NEAREST)[..., ::-1].copy()
            cv2.rectangle(tile, (0, 0), (320, 22), (0, 0, 0), -1)
            cv2.putText(tile, label, (5, 16), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 255, 255), 1, cv2.LINE_AA)
            row.append(tile)
        lines.append(np.concatenate(row, 1))
    path = REPO / "docs/research/images/shp01-calibration.jpg"
    cv2.imwrite(str(path), np.concatenate(lines, 0), [cv2.IMWRITE_JPEG_QUALITY, 86])
    print(f"wrote {path}")


if __name__ == "__main__":
    torch.set_num_threads(1)
    main()
