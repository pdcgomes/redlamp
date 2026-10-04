"""Per-level weights for the proposed Texture (ladder band log2(c1/c3), soft limit 0.25) so the fitted
preview shows it as a same-size export does: fitted on the Nikon, validated on three more cameras
at sizes spread over each level's range. Also today's Texture and Clarity's fine end for reference."""

from __future__ import annotations

import sys

import numpy as np

from detail import FLOOR, bilinear_resize, box_mips, lanczos_resize, load_dump, luminance
from arc04 import ladder, todays_texture

LIMIT = 0.25


def proposed(mips, level, t, weights):
    """log2(c1 / c3) at level 0 and 1 below the band (exact ladder); at level L >= 1 the texels stand
    in for c1 and the band ends at c3 or one level beyond the texels, times weights[L]."""
    gain = t if t > 0 else 0.5 * t
    y = mips[level]
    if level == 0:
        lv = ladder(y, 0, 3)
        detail = np.log2(lv[1] + FLOOR) - np.log2(lv[3] + FLOOR)
    else:
        end = max(3, level + 1)
        lv = ladder(y, level, end)
        detail = weights.get(level, 1.0) * (np.log2(y + FLOOR) - np.log2(lv[end] + FLOOR))
    return gain * LIMIT * np.tanh(detail / LIMIT)


def ratio(y, method, t, edge):
    h, w = y.shape
    scale = max(h, w) / edge
    shape = (round(h / scale), round(w / scale))
    mips = box_mips(y, 7)
    level = int(np.floor(np.log2(scale) + 0.01))
    export = lanczos_resize(y * np.exp2(method(mips, 0, t)), shape) - lanczos_resize(y, shape)
    preview = bilinear_resize(mips[level] * np.exp2(method(mips, level, t)), shape) - bilinear_resize(mips[level], shape)
    r = np.sqrt((preview ** 2).sum() / (export ** 2).sum())
    c = (preview * export).sum() / np.sqrt((preview ** 2).sum() * (export ** 2).sum())
    return float(r), float(c), level


def main():
    nikon = luminance(*load_dump("DSC_0750"))
    weights = {}
    # Fit: the ratio is close to linear in the weight for small effects; two passes.
    for level, edge in [(1, 2000), (2, 1000), (3, 700)]:
        weights[level] = 1.0
        for _ in range(2):
            r, _, got = ratio(nikon, lambda m, l, t: proposed(m, l, t, weights), 0.6, edge)
            assert got == level
            weights[level] /= r
    weights[4] = weights[3] * weights[3] / weights[2]
    print("fitted weights:", {k: round(v, 3) for k, v in weights.items()})
    names = ["DSC_0750", "Pentax_K-1-Mark-II", "Nikon_Coolpix-P7700", "Sony_ILCE-7CM2"]
    for name in names:
        y = luminance(*load_dump(name))
        long = max(y.shape)
        print(f"\n{name} ({y.shape[1]}x{y.shape[0]})")
        for edge in (700, 1000, 2000, round(long / 2.6), round(long / 5.2), round(long / 10.4)):
            cells = []
            for label, method in [("today", todays_texture),
                                  ("proposed", lambda m, l, t: proposed(m, l, t, weights))]:
                r, c, level = ratio(y, method, 0.6, edge)
                cells.append(f"{label} {r:.2f} ({c:.2f})")
            print(f"  {edge:5d} px (level {level}): " + ", ".join(cells))


if __name__ == "__main__":
    main()
