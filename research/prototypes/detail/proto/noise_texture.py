"""Texture +100 after noise reduction (NR Luminance 60, Color 25), on the engine's own outputs:
today (measured on the un-denoised pyramid, from the engine) against the ladder of the NR output,
without and with the separator's garrote on Texture's bands (3 noise sigmas of linear luminance)."""

from __future__ import annotations

import json

import numpy as np

from detail import FLOOR, OUT, atrous

W, H = 1024, 768


def load(name):
    return np.fromfile(OUT / f"{name}.f32", np.float32).reshape(H, W)


def garrote(w, t):
    r2 = (w / np.maximum(t, 1e-12)) ** 2
    return np.where(r2 > 1, w * (1 - 1 / np.maximum(r2, 1e-12)), 0).astype(np.float32)


def calibrate():
    """Per-scale noise of the ladder's bands for unit noise variance of luminance (this sensor, level 0)."""
    meta = json.loads((OUT / "nflat_meta.json").read_text())
    y = load("nflat_in_Y")
    bands, _ = atrous(y, 4)
    w = np.array(meta["luma"][:3])
    var_y = (np.array(meta["a"]) * 0.1 + np.array(meta["b"])) @ (w ** 2)
    k = [float(b[64:-64, 64:-64].std() / np.sqrt(var_y)) for b in bands]
    return k, meta


def texture(y_nr, meta, k, t=1.0, limit=0.25, shrink=0.0):
    bands, c3 = atrous(y_nr, 3)
    w = np.array(meta["luma"][:3])
    local = c3  # the local level; neutral scenes, so luminance noise from Y alone
    var_y = np.maximum(np.mean(meta["a"]) * local + np.mean(meta["b"]), 0) * (w ** 2).sum()
    if shrink > 0:
        kept = [garrote(bands[s], shrink * k[s] * np.sqrt(var_y)) for s in (1, 2)]
    else:
        kept = [bands[1], bands[2]]
    c1 = c3 + kept[0] + kept[1]
    detail = np.log2(c1 + FLOOR) - np.log2(c3 + FLOOR)
    gain = t if t > 0 else 0.5 * t
    boost = gain * (detail if limit is None else limit * np.tanh(detail / limit))
    return y_nr * np.exp2(boost)


def flat_noise(y):
    c = y[64:-64, 64:-64]
    return float(c.std() / c.mean())


def stripes(y):
    """Amplitude (stops) of the 12 px stripes, and the noise left once they're removed."""
    c = np.log2(y[64:-64, 64:-64])
    x = np.arange(64, W - 64)
    s, co = np.sin(2 * np.pi * x / 12), np.cos(2 * np.pi * x / 12)
    profile = c.mean(0)
    a, b = 2 * (profile - profile.mean()) @ s / len(x), 2 * (profile - profile.mean()) @ co / len(x)
    model = a * s + b * co
    residual = c - c.mean() - model[None, :]
    return float(np.hypot(a, b)), float(residual.std())


def main():
    k, meta = calibrate()
    print("ladder band noise per unit luminance noise (scales 0-3):", " ".join(f"{v:.3f}" for v in k))
    flat_in, flat_nr, flat_today = load("nflat_in_Y"), load("nflat_nr_Y"), load("nflat_nrtex_Y")
    st_in, st_nr, st_today = load("nstripes_in_Y"), load("nstripes_nr_Y"), load("nstripes_nrtex_Y")
    rows = [
        ("input", flat_in, st_in),
        ("NR L60 C25", flat_nr, st_nr),
        ("today: NR + Texture +100 (engine)", flat_today, st_today),
        ("ladder of NR output, limit 0.25", texture(flat_nr, meta, k), texture(st_nr, meta, k)),
        ("ladder of NR output, garrote 2 sigma, limit 0.25", texture(flat_nr, meta, k, shrink=2),
         texture(st_nr, meta, k, shrink=2)),
        ("ladder of NR output, garrote 3 sigma, limit 0.25", texture(flat_nr, meta, k, shrink=3),
         texture(st_nr, meta, k, shrink=3)),
        ("ladder of NR output, garrote 3 sigma, no limit", texture(flat_nr, meta, k, shrink=3, limit=None),
         texture(st_nr, meta, k, shrink=3, limit=None)),
    ]
    print("| | flat noise (relative) | stripes' amplitude (stops) | noise beside the stripes (stops) |")
    for name, flat, st in rows:
        amplitude, residual = stripes(st)
        print(f"| {name} | {flat_noise(flat):.4f} | {amplitude:.3f} | {residual:.4f} |")


if __name__ == "__main__":
    main()
