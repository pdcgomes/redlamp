#!/usr/bin/env python3
"""Refine Edges at the size masks are stored at (MSK-31).

Refine Edges snaps an AI mask's edges to the photo with a guided filter (He, Sun and Tang) of
radius 1/128 of the mask's width (32 px at 4096) and epsilon 4e-4, guided by the analysis render's
luminance at 2048 px, upsampled to the mask. Masks have been stored at 4096 px and matted per
pixel since MSK-17, so the filter now runs on a matte finer than its guide. This scores it on
hair_bench's heads against guided filters at the mask's size with smaller radii, from two
starting points: today's matte (closed-form with ViTMatte's strands, `strands-r3`) and the coarse
mask a fresh Vision mask stands in for (`coarse`), and against Refine Edges as the app now does it
(`redlamp mask --from … --refine-edges`: the edge solved again per pixel, with ViTMatte's strands).
Writes <scene>-refine-<variant>-<start>.png for `hair_bench.py score`.

    research/prototypes/masking/.venv/bin/python research/prototypes/masking/refine_edges.py
"""

import json
import os
import pathlib
import subprocess
import sys

import numpy as np
from PIL import Image
from scipy import ndimage

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import hair_bench as hb  # noqa: E402

VARIANTS = {
    # name: (guide's long side, or None for the mask's own size; radius as a share of the width; epsilon)
    "today": (2048, 1 / 128, 4e-4),
    "full-r8": (None, 8 / 4096, 4e-4),
    "full-r4": (None, 4 / 4096, 1e-4),
    "full-r2": (None, 2 / 4096, 1e-4),
}
STARTS = ["strands-r3", "coarse"]
CLI = pathlib.Path(os.environ.get("REDLAMP_CLI", hb.ROOT / "build/DerivedData-masking/Build/Products/Release/redlamp"))


def box(values, radius):
    return ndimage.uniform_filter(values, size=2 * radius + 1, mode="nearest")


def guided(mask, guide, radius, epsilon):
    mean_i, mean_p = box(guide, radius), box(mask, radius)
    variance = box(guide * guide, radius) - mean_i * mean_i
    covariance = box(guide * mask, radius) - mean_i * mean_p
    a = covariance / (variance + epsilon)
    b = mean_p - a * mean_i
    return np.clip(box(a, radius) * guide + box(b, radius), 0, 1)


def luminance(path, size, long_side):
    image = Image.open(path).convert("L")
    if long_side:
        scale = long_side / max(image.size)
        image = image.resize((round(image.width * scale), round(image.height * scale)), Image.BILINEAR)
    return np.asarray(image.resize(size, Image.BILINEAR), np.float32) / 255


def main():
    scenes = json.loads((hb.WORK / "scenes.json").read_text())
    for scene in scenes:
        for start in STARTS:
            source = hb.WORK / f"{scene}-{start}.png"
            if not source.exists():
                continue
            mask = np.asarray(Image.open(source).convert("L"), np.float32) / 255
            size = (mask.shape[1], mask.shape[0])
            for name, (long_side, share, epsilon) in VARIANTS.items():
                target = hb.WORK / f"{scene}-refine-{name}-{start}.png"
                if target.exists():
                    continue
                guide = luminance(hb.WORK / f"{scene}.png", size, long_side)
                radius = max(4 if name == "today" else 1, round(share * size[0]))
                out = guided(mask, guide, radius, epsilon)
                Image.fromarray((out * 255 + 0.5).astype(np.uint8)).save(target)
            target = hb.WORK / f"{scene}-refine-app-{start}.png"
            if not target.exists():
                result = subprocess.run([str(CLI), "mask", str(hb.WORK / f"{scene}.png"), "--kind", "subject", "--from",
                                         str(source), "--refine-edges", "-o", str(target)], capture_output=True, text=True)
                if result.returncode != 0:
                    print(f"  {scene} {start}: {(result.stderr or result.stdout).strip()[-160:]}")
        print(f"{scene}: refined", flush=True)
    hb.score(STARTS + [f"refine-{name}-{start}" for start in STARTS for name in [*VARIANTS, "app"]])


if __name__ == "__main__":
    main()
