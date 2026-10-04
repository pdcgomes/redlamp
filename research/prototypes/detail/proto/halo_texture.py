"""Texture at +100 on a 3.3-stop step and on stripes: today's band against the ladder band, with and
without a soft limit (Clarity's form), and the ladder taken in linear or log luminance."""

from __future__ import annotations

import numpy as np

from detail import FLOOR, atrous_blur, box_mips, bspline_at
from arc04 import todays_texture

W, H = 1024, 64


def scene(kind: str, period: float = 6) -> np.ndarray:
    x = np.arange(W)[None, :].repeat(H, 0).astype(np.float32)
    if kind == "step":
        return np.where(x < W // 2, 0.04, 0.4).astype(np.float32)
    if kind == "step1":
        return np.where(x < W // 2, 0.1, 0.2).astype(np.float32)
    if kind == "line":
        return np.where((x == W // 2) | (x == W // 2 + 1), 0.4, 0.04).astype(np.float32)
    if kind == "stripes":
        return (0.2 * 2 ** (0.15 * np.sin(2 * np.pi * x / period))).astype(np.float32)
    raise ValueError(kind)


def ladder_detail(y, log_first=False):
    """Texture's detail from the B3 ladder: log2(c1 / c3) (linear ladder) or c1 - c3 of log2 Y."""
    if log_first:
        ly = np.log2(y + FLOOR)
        c1 = atrous_blur(ly, 1)
        return c1 - atrous_blur(atrous_blur(c1, 2), 4)
    c1 = atrous_blur(y, 1)
    c3 = atrous_blur(atrous_blur(c1, 2), 4)
    return np.log2(c1 + FLOOR) - np.log2(c3 + FLOOR)


def boost(detail, t, limit=None):
    gain = t if t > 0 else 0.5 * t
    if limit is None:
        return gain * detail
    return gain * limit * np.tanh(detail / limit)


VARIANTS = {
    "today": lambda y, t: todays_texture(box_mips(y, 4), 0, t),
    "ladder (linear), no limit": lambda y, t: boost(ladder_detail(y), t),
    "ladder (linear), limit 0.25": lambda y, t: boost(ladder_detail(y), t, 0.25),
    "ladder (linear), limit 0.35": lambda y, t: boost(ladder_detail(y), t, 0.35),
    "ladder (log), no limit": lambda y, t: boost(ladder_detail(y, True), t),
    "ladder (log), limit 0.25": lambda y, t: boost(ladder_detail(y, True), t, 0.25),
    "ladder (log), limit 0.35": lambda y, t: boost(ladder_detail(y, True), t, 0.35),
}


def main():
    edge = W // 2
    rows = slice(24, 40)
    print("Texture +100 at 1:1, synthetic scenes (no demosaic). Peaks and 2-16 px bands in stops; gain on stripes.")
    for name, variant in VARIANTS.items():
        cells = []
        for kind in ("step", "step1", "line"):
            y = scene(kind)
            d = variant(y, 1.0)[rows].mean(0)
            dark = d[edge - 48:edge - 1]
            bright = d[edge + 2:edge + 48] if kind != "line" else d[edge + 2:edge + 48]
            if kind == "line":
                cells.append(f"line: on {d[edge]:+.2f}, beside {d[edge - 16:edge - 1].min():+.2f}")
            else:
                cells.append(f"{kind}: dark {dark.min():+.2f} (band {d[edge - 16:edge - 2].mean():+.2f}), "
                             f"bright {bright.max():+.2f} (band {d[edge + 3:edge + 17].mean():+.2f})")
        gains = []
        for period in (4, 6, 12, 24, 48):
            y = scene("stripes", period)
            out = np.log2(y * np.exp2(variant(y, 1.0)) + 1e-9)[rows, 128:-128]
            gains.append(out.std() / np.log2(y[rows, 128:-128]).std())
        print(f"  {name}:\n    " + "\n    ".join(cells) + "\n    stripes (4, 6, 12, 24, 48 px): " +
              " ".join(f"{g:.2f}" for g in gains))


if __name__ == "__main__":
    main()
