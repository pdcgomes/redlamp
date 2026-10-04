"""Separator on 4 against 5 ladder scales (margin), with RL4, Radius 2 / Amount 100 / Detail 100 and defaults."""
import itertools, sys
import numpy as np
sys.path.insert(0, "/Users/pedrogomes/src/darkroom/research/prototypes/restoration")
from common import TESTSET, load_manifest, poisson_gaussian_noise, read_rgb, srgb_to_linear, linear_to_srgb  # noqa
from detail import FLOOR, REC2020, WHITE_SIGMAS, atrous, gaussian
from sharpen_bands import LOW_ISO, apply_boost, garrote, psnr, richardson_lucy, separate

def sep(linear, a, b, scales, k=3.0):
    y = np.maximum(linear @ REC2020, 0).astype(np.float32)
    bands, residual = atrous(y, scales)
    local = np.stack([gaussian(linear[..., c], 2.0) for c in range(3)], -1)
    sigma_y = np.sqrt(np.maximum(a * local + b, 0) @ (REC2020 ** 2))
    return np.maximum(residual + sum(garrote(w, k * WHITE_SIGMAS[s] * sigma_y) for s, w in enumerate(bands)), 0) + FLOOR

def sharpen(linear, dl, amount, radius, d):
    sigma = 0.8 * radius
    log_d = np.log2(dl)
    usm = log_d - gaussian(log_d, sigma)
    deconv = np.log2(np.maximum(richardson_lucy(dl, sigma), 1e-6)) - log_d
    return apply_boost(linear, (1 - d) * usm + d * deconv, amount, d)

m = load_manifest(); crops, degs, noise = list(m["crops"]), list(m["degradations"]), m["noise"]
cases = ["soft_g1.5", "defocus_r4", "defocus_r3_noise"]
gains = {}
for crop, case in itertools.product(crops, cases):
    lq = read_rgb(TESTSET / "lq" / f"{crop}__{case}.png"); gt = read_rgb(TESTSET / "gt" / f"{crop}.png")
    lin = srgb_to_linear(lq).astype(np.float32); noisy = m["degradations"][case].get("noise")
    a, b = (noise["a"], noise["b"]) if noisy else LOW_ISO
    target = gt if not noisy else poisson_gaussian_noise(gt, seed=1000 * crops.index(crop) + degs.index(case), a=noise["a"], b=noise["b"])
    base = psnr(lq, target)
    for (r, am, d) in [(2.0, 1.0, 1.0), (1.0, 0.4, 0.25)]:
        for name, dl in [("SHP-01", np.maximum(separate(lin, a, b, 3) @ REC2020, 0) + FLOOR), ("ladder 5 scales", sep(lin, a, b, 5)), ("ladder 4 scales", sep(lin, a, b, 4))]:
            out = np.clip(linear_to_srgb(sharpen(lin, dl, am, r, d)), 0, 1)
            gains.setdefault((name, r, am, d, case), []).append(psnr(out, target) - base)
for (r, am, d) in [(2.0, 1.0, 1.0), (1.0, 0.4, 0.25)]:
    for name in ["SHP-01", "ladder 5 scales", "ladder 4 scales"]:
        print(f"R{r} A{int(am*100)} D{int(d*100)} {name}: " + " ".join(f"{np.mean(gains[(name, r, am, d, c)]):+.2f}" for c in cases))
