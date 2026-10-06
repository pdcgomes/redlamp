#!/usr/bin/env python3
"""Where the Sky mask goes wrong, and at which stage (MSK-28).

On edge_bench's 12 skies (exact coverage), the coarse mask (Segment Anything seeded inside the
classical estimate, combined with Depth Anything 3, before SkyMatte; `REDLAMP_SKY_MATTE=off`)
and the mask as stored (after SkyMatte), each scored against the truth:

- sky missed: the share of sure sky (truth at least 0.98) a mask leaves out (below 0.5), and of
  that, the share in patches of at least 400 px (the rest is small gaps);
- sky under-covered: the share of sure sky covered only partly (0.5 to 0.9);
- foreground as sky: the share of sure foreground (truth at most 0.02) a mask covers (over 0.5);
- edge error: the mean error where the truth is mixed, and 2 px around.

Writes build/mask-bench/sky-errors/<scene>-<stage>.png, the scene darkened with red where sky is
missed, yellow where it is under-covered and blue where foreground is taken as sky, and report.json.

    .venv/bin/python sky_errors.py
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
import edge_bench as eb  # noqa: E402
import mask_bench as mb  # noqa: E402

OUT = mb.OUT / "sky-errors"


def scores(mask, truth):
    sky, foreground = truth >= 0.98, truth <= 0.02
    missed = sky & (mask < 0.5)
    labels, count = ndimage.label(missed)
    sizes = ndimage.sum(missed, labels, range(1, count + 1)) if count else np.array([])
    band = ndimage.binary_dilation((truth > 0.02) & (truth < 0.98), iterations=2)
    return {
        "missed": float(missed.sum() / max(sky.sum(), 1)),
        "missedInPatches": float(sizes[sizes >= 400].sum() / max(missed.sum(), 1)) if count else 0.0,
        "underCovered": float((sky & (mask >= 0.5) & (mask < 0.9)).sum() / max(sky.sum(), 1)),
        "foregroundAsSky": float((foreground & (mask > 0.5)).sum() / max(foreground.sum(), 1)),
        "edge": float(np.abs(mask - truth)[band].mean()),
    }, missed


def error_map(image, mask, truth, missed):
    out = np.asarray(image, np.float32) * 0.45
    out[missed] = (230, 40, 40)
    out[(truth >= 0.98) & (mask >= 0.5) & (mask < 0.9)] = (230, 200, 40)
    out[(truth <= 0.02) & (mask > 0.5)] = (40, 90, 230)
    return Image.fromarray(out.astype(np.uint8))


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    environment = {**os.environ, "REDLAMP_SKY_MATTE": "off"}
    report = {}
    for scene in json.loads((eb.WORK / "scenes.json").read_text()):
        image_path = eb.WORK / f"{scene}.png"
        coarse_path = OUT / f"{scene}-coarse-mask.png"
        if not coarse_path.exists():
            subprocess.run([str(mb.CLI), "mask", str(image_path), "--kind", "sky", "-o", str(coarse_path)],
                           check=True, capture_output=True, env=environment)
        truth = np.load(eb.WORK / f"{scene}-truth.npz")["sky"].astype(np.float32)
        image = Image.open(image_path).convert("RGB")
        report[scene] = {}
        for stage, path in (("coarse", coarse_path), ("stored", mb.OUT / "edge" / f"{scene}-stored.png")):
            mask = np.asarray(Image.open(path).convert("L").resize(image.size, Image.BILINEAR), np.float32) / 255
            report[scene][stage], missed = scores(mask, truth)
            error_map(image, mask, truth, missed).save(OUT / f"{scene}-{stage}.png")
        row = report[scene]
        print(f"{scene:28s} " + "  ".join(
            f"{stage}: missed {row[stage]['missed']:.3f} ({row[stage]['missedInPatches']:.0%} in patches), "
            f"under {row[stage]['underCovered']:.3f}, fg {row[stage]['foregroundAsSky']:.4f}, edge {row[stage]['edge']:.3f}"
            for stage in ("coarse", "stored")), flush=True)
    (OUT / "report.json").write_text(json.dumps(report, indent=1))
    for stage in ("coarse", "stored"):
        mean = lambda key: np.mean([r[stage][key] for r in report.values()])  # noqa: E731
        print(f"\n{stage}: sky missed {mean('missed'):.3f} ({mean('missedInPatches'):.0%} of it in patches), "
              f"under-covered {mean('underCovered'):.3f}, foreground as sky {mean('foregroundAsSky'):.4f}, "
              f"edge {mean('edge'):.3f}")


if __name__ == "__main__":
    main()
