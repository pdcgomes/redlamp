#!/usr/bin/env python3
"""Prototype: give back the sky Segment Anything leaves out between bare branches (MSK-17).

SAM treats a leafless tree crown as one object and cuts around it. The sky seen through the
branches is then left out, so a darkened sky keeps bright patches inside every bare tree.
This pass learns the sky's colour where SAM is sure, then adds pixels of that colour above
the sky's lowest reach in each column (where crowns sit), with a soft falloff so pixels mixed
with thin branches get partial coverage.

    research/prototypes/masking/.venv/bin/python research/prototypes/masking/branch_refine.py
"""

import pathlib
import sys

import numpy as np
from PIL import Image
from scipy import ndimage

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from sky_bakeoff import WORK, boundary_f, iou, load_mask  # noqa: E402


def srgb_to_linear(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def oklab(rgb):
    lin = srgb_to_linear(rgb)
    lms = lin @ np.array([[0.4122214708, 0.2119034982, 0.0883024619],
                          [0.5363325363, 0.6806995451, 0.2817188376],
                          [0.0514459929, 0.1073969566, 0.6299787005]])
    lms = np.cbrt(np.maximum(lms, 0))
    return lms @ np.array([[0.2104542553, 1.9779984951, 0.0259040371],
                           [0.7936177850, -2.4285922050, 0.7827717662],
                           [-0.0040720468, 0.4505937099, -0.8086757660]])


def refine(image, sky, tolerance=0.09, reach=0.04):
    """`image` sRGB 0...1 (H, W, 3), `sky` soft 0...1. Returns the refined soft mask."""
    height, width = sky.shape
    lab = oklab(image)
    sure = sky > 0.9
    if sure.sum() < 100:
        return sky
    # The sky's colour varies with height (brighter at the horizon): a reference per row band,
    # from the sure sky in that band or the nearest band that has some.
    bands = 16
    rows = np.minimum((np.arange(height) * bands) // height, bands - 1)
    reference = np.zeros((bands, 3))
    have = np.zeros(bands, dtype=bool)
    for band in range(bands):
        pixels = lab[(rows == band)[:, None] & sure]
        if len(pixels) > 50:
            reference[band] = np.median(pixels, axis=0)
            have[band] = True
    for band in range(bands):
        if not have[band]:
            nearest = np.flatnonzero(have)[np.argmin(np.abs(np.flatnonzero(have) - band))]
            reference[band] = reference[nearest]
    distance = np.linalg.norm((lab - reference[rows][:, None, :]) * np.array([0.6, 1, 1]), axis=-1)
    match = 1 - np.clip((distance - tolerance * 0.4) / (tolerance * 0.6), 0, 1)

    # Where crowns can be: above the lowest sure sky in each column (smoothed across columns),
    # plus a little reach below it.
    lowest = np.where(sure.any(axis=0), height - 1 - np.argmax(sure[::-1], axis=0), 0).astype(float)
    lowest = ndimage.maximum_filter1d(lowest, size=max(3, width // 20))
    lowest = ndimage.uniform_filter1d(lowest, size=max(3, width // 40))
    allowed = np.arange(height)[:, None] <= lowest[None, :] + reach * height

    # Only regions touching the sky: grow from it through matching pixels. (Bridging gaps of a
    # few pixels fills more of a dense bare crown but leaks into tree lines: not worth it.)
    candidate = allowed & (match > 0.3)
    labels, _ = ndimage.label(candidate | (sky > 0.5))
    touching = np.unique(labels[sky > 0.5])
    connected = np.isin(labels, touching[touching > 0])
    added = np.where(connected & allowed, match, 0)
    return np.maximum(sky, added)


def main():
    rows = []
    for render in sorted(WORK.glob("*.png")):
        if not (WORK / f"{render.stem}-sam.png").exists():
            continue
        image = np.asarray(Image.open(render).convert("RGB"), dtype=np.float32) / 255
        size = (image.shape[1], image.shape[0])
        reference = load_mask(WORK / f"{render.stem}-oneformer-ade20k-swin-large.png", size)
        sam = load_mask(WORK / f"{render.stem}-sam.png", size)
        refined = refine(image, sam)
        Image.fromarray((refined * 255).astype(np.uint8)).save(WORK / f"{render.stem}-sam-refined-py.png")
        tolerance = 0.01 * np.hypot(*size)
        rows.append((render.stem, iou(sam, reference), iou(refined, reference),
                     boundary_f(sam, reference, tolerance), boundary_f(refined, reference, tolerance)))
    for stem, a, b, fa, fb in rows:
        print(f"{stem[:26]:27s} IoU {a:.3f} -> {b:.3f}   F {fa:.3f} -> {fb:.3f}")
    print(f"{'mean':27s} IoU {np.mean([r[1] for r in rows]):.3f} -> {np.mean([r[2] for r in rows]):.3f}"
          f"   F {np.mean([r[3] for r in rows]):.3f} -> {np.mean([r[4] for r in rows]):.3f}")


if __name__ == "__main__":
    main()
