"""ARC-04 in simulation: Texture's (and Clarity's fine end's) effect in a fitted preview against a
same-size export (full resolution, then Lanczos), for today's bands and the proposed ladder.

Preview: the detail stage at the work level L (the pyramid's box mips), optionally at a finer level
then box-averaged to L, then the develop kernel's bilinear sampling to the output size.
Export: the stage at level 0, then a Lanczos-3 downscale.
"""

from __future__ import annotations

import sys

import numpy as np

from detail import FLOOR, atrous_blur, bilinear_resize, box_mips, bspline_at, lanczos_resize, load_dump, luminance


def todays_texture(mips, level, t):
    """LocalContrast.metal's Texture at work level `level` (band 1...3, keepsRendered)."""
    amount = t if t > 0 else 0.5 * t
    shape = mips[level].shape
    fine_level, coarse_level = max(1, level), 3
    if not (fine_level < coarse_level or (fine_level == coarse_level and level > 0)):
        return np.zeros(shape, np.float32)
    fine = np.log2(mips[level] + FLOOR) if fine_level <= level else np.log2(
        bspline_at(mips[fine_level], fine_level, level, shape) + FLOOR)
    coarse = np.log2(bspline_at(mips[coarse_level], coarse_level, level, shape) + FLOOR)
    return amount * (fine - coarse)


def ladder(y, level, scales):
    """c_level .. c_scales of the B3 ladder of linear luminance, computed on level `level`'s texels
    (holes 2^(s - level) texels for full-resolution scale s)."""
    levels = {level: y}
    current = y
    for s in range(level, scales):
        current = atrous_blur(current, 1 << (s - level))
        levels[s + 1] = current
    return levels


def ladder_texture(mips, level, t, fine=1, coarse=3, correct=False):
    """Proposed Texture: log2(c_fine / c_coarse) of the ladder at work level `level`. Where the fine
    end is finer than the texels, the texels stand in for it (optionally with the B3-against-box
    correction, a [1, 4, 1] / 6 smoothing)."""
    amount = t if t > 0 else 0.5 * t
    y = mips[level]
    if level >= coarse:
        return np.zeros(y.shape, np.float32)
    levels = ladder(y, level, coarse)
    if fine > level:
        c_fine = levels[fine]
    elif correct and level > 0:
        k = np.array([1, 4, 1], np.float32) / 6
        import cv2
        c_fine = cv2.sepFilter2D(y, -1, k, k, borderType=cv2.BORDER_REPLICATE)
    else:
        c_fine = y
    return amount * (np.log2(c_fine + FLOOR) - np.log2(levels[coarse] + FLOOR))


def ladder_variance(s):
    """Variance (px^2, per axis) of the B3 ladder's c_s at full resolution."""
    return (4 ** s - 1) / 3


def matched_texture(mips, level, t, fine=1, coarse=3):
    """Proposed Texture with the variance-matching rule: at level L, the band from the first ladder
    level beyond the texels (or c_fine, when finer exists) to c_coarse, or the level's own finest
    band, weighted so its low-frequency (f^2) response equals the full-resolution band's."""
    amount = t if t > 0 else 0.5 * t
    y = mips[level]
    target = ladder_variance(coarse) - ladder_variance(fine)
    if level < fine:
        levels = ladder(y, level, coarse)
        return amount * (np.log2(levels[fine] + FLOOR) - np.log2(levels[coarse] + FLOOR))
    # The texels stand in for c_fine; the band ends at c_coarse, or one level beyond the texels.
    end = max(coarse, level + 1)
    levels = ladder(y, level, end)
    available = sum(4 ** s for s in range(level, end))
    weight = target / available
    return amount * weight * (np.log2(y + FLOOR) - np.log2(levels[end] + FLOOR))


def simulate(y_full, method, t, edge, cap=None):
    h, w = y_full.shape
    scale = max(h, w) / edge
    out_shape = (round(h / scale), round(w / scale))
    mips = box_mips(y_full, 6)
    # Export: level 0, then Lanczos.
    boost0 = method(mips, 0, t)
    export_base = lanczos_resize(y_full, out_shape)
    export_edit = lanczos_resize(y_full * np.exp2(boost0), out_shape)
    # Preview at the work level (capped), box-averaged back to the output's level when finer.
    level = int(np.floor(np.log2(scale) + 0.01))
    work = level if cap is None else min(level, cap)
    edited = mips[work] * np.exp2(method(mips, work, t))
    for _ in range(level - work):
        edited = box_mips(edited, 1)[1]
    base = mips[level]
    edited = edited[:base.shape[0], :base.shape[1]]
    preview_base = bilinear_resize(base, out_shape)
    preview_edit = bilinear_resize(edited, out_shape)
    shown, exported = preview_edit - preview_base, export_edit - export_base
    ratio = np.sqrt((shown ** 2).sum() / (exported ** 2).sum())
    corr = (shown * exported).sum() / np.sqrt((shown ** 2).sum() * (exported ** 2).sum())
    return ratio, corr, level, work


def main():
    names = sys.argv[1:] or ["DSC_0750"]
    for name in names:
        rgb, meta = load_dump(name)
        y = luminance(rgb, meta)
        print(f"\n{name} ({meta['width']}x{meta['height']})")
        variants = [
            ("today", todays_texture, None),
            ("today, cap 2", todays_texture, 2),
            ("ladder c1/c3, variance-matched", matched_texture, None),
        ]
        for label, method, cap in variants:
            cells = []
            for t in (0.6, -0.6):
                for edge in (700, 1000, 2000):
                    ratio, corr, level, work = simulate(y, method, t, edge, cap)
                    cells.append(f"{edge}px {t:+.1f}: {ratio:.2f} ({corr:.2f}) L{level}/{work}")
            print(f"  {label}:\n    " + "\n    ".join(cells))


if __name__ == "__main__":
    main()
