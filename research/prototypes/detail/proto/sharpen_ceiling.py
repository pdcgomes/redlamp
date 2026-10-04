"""Is the band equivalent's loss the fit, or any linear filter? Exact linearised Richardson-Lucy and
unsharp responses applied by FFT (reflect-padded) to log D and to linear D, against real RL."""

from __future__ import annotations

import itertools
import sys

import numpy as np

sys.path.insert(0, "/Users/pedrogomes/src/darkroom/research/prototypes/restoration")
from common import TESTSET, load_manifest, poisson_gaussian_noise, read_rgb, srgb_to_linear, linear_to_srgb  # noqa

from detail import FLOOR, REC2020, gaussian, rl_linear, unsharp_linear
from sharpen_bands import LOW_ISO, apply_boost, psnr, richardson_lucy, separate


def fft_filter(x, transfer):
    pad = 32
    p = np.pad(x, pad, mode="reflect")
    fy = np.fft.fftfreq(p.shape[0])[:, None]
    fx = np.fft.fftfreq(p.shape[1])[None, :]
    out = np.real(np.fft.ifft2(np.fft.fft2(p) * transfer(fx ** 2 + fy ** 2)))
    return out[pad:-pad, pad:-pad].astype(np.float32)


def main():
    manifest = load_manifest()
    crops, degradations, noise = list(manifest["crops"]), list(manifest["degradations"]), manifest["noise"]
    cases = ["soft_g1.5", "defocus_r4", "defocus_r3_noise"]
    radius, amount, d = 2.0, 1.0, 1.0
    sigma = 0.8 * radius
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
        clean = separate(linear, a, b, 3)
        dl = np.maximum(clean @ REC2020, 0) + FLOOR
        log_d = np.log2(dl)
        details = {
            "RL4 (SHP-01)": np.log2(np.maximum(richardson_lucy(dl, sigma), 1e-6)) - log_d,
            "linearised RL4 on log D": fft_filter(log_d, lambda f2: rl_linear(f2, sigma) - 1),
            "linearised RL4 on linear D": np.log2(np.maximum(fft_filter(dl, lambda f2: rl_linear(f2, sigma)), 1e-6))
            - log_d,
            "unsharp on log D (Detail 0)": log_d - gaussian(log_d, sigma),
        }
        for name, detail in details.items():
            out = np.clip(linear_to_srgb(apply_boost(linear, detail, amount, d)), 0, 1)
            gains.setdefault((name, case), []).append(psnr(out, target) - base)
    print(f"Radius {radius} / Amount {int(amount * 100)} / Detail {int(d * 100)}, separator k=3 for all; mean dB gain")
    print("| detail | " + " | ".join(cases) + " |")
    for name in ["RL4 (SHP-01)", "linearised RL4 on log D", "linearised RL4 on linear D", "unsharp on log D (Detail 0)"]:
        print(f"| {name} | " + " | ".join(f"{np.mean(gains[(name, c)]):+.2f}" for c in cases) + " |")


if __name__ == "__main__":
    main()
