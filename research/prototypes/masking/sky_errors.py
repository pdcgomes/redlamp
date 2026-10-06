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

`eval` makes today's Sky mask, with the redlamp build at mask_bench.CLI, for every photo in the
evaluation set whose cell tests Sky, beside the one `mask_bench.py eval` made, and writes to
build/mask-bench/sky-eval/ how much sky each photo gains and loses (over a quarter of coverage)
and a sheet per cell, each photo where the two differ most: the photo, then the earlier mask
and today's, over mid-grey.

    .venv/bin/python sky_errors.py eval [cell ...]
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


def evaluation_set(cells=()):
    out = mb.OUT / "sky-eval"
    (out / "sheets").mkdir(parents=True, exist_ok=True)
    report, rows = {}, {}
    for path, stem, cell, masks in mb.eval_photos():
        if "sky" not in masks or (cells and cell not in cells):
            continue
        target = out / f"{stem}-sky.png"
        result = subprocess.run([str(mb.CLI), "mask", str(path), "--kind", "sky", "-o", str(target)],
                                capture_output=True, text=True)
        if result.returncode != 0 or not target.exists():
            report[stem] = {"cell": cell, "failed": (result.stderr or result.stdout).strip()[-160:]}
            continue
        size = Image.open(target).size
        today = np.asarray(Image.open(target).convert("L"), np.float32) / 255
        before = mb.eval_mask(stem, "sky", size)
        if before is None:
            report[stem] = {"cell": cell, "failed": "no earlier mask"}
            continue
        change = today - before
        report[stem] = {"cell": cell, "gained": float((change > 0.25).mean()), "lost": float((change < -0.25).mean())}
        preview = mb.OUT / "eval" / f"{stem}-photo.jpg"
        photo = np.asarray(Image.open(preview if preview.exists() else path).convert("RGB").resize(size, Image.LANCZOS),
                           np.float32)
        height, width = min(400, size[1]), min(600, size[0])
        summed = ndimage.uniform_filter(np.abs(change), size=(height, width), mode="constant")
        y, x = np.unravel_index(np.argmax(summed), summed.shape)
        y0, x0 = int(np.clip(y - height // 2, 0, size[1] - height)), int(np.clip(x - width // 2, 0, size[0] - width))
        crop = photo[y0:y0 + height, x0:x0 + width]

        def over_grey(matte):
            a = matte[y0:y0 + height, x0:x0 + width, None]
            return a * crop + (1 - a) * 128

        rows.setdefault(cell, []).append(np.concatenate(
            [np.pad(p, ((0, 6), (0, 6), (0, 0)), constant_values=255) for p in (crop, over_grey(before), over_grey(today))],
            axis=1))
        print(f"{stem}: gained {report[stem]['gained']:.4f}, lost {report[stem]['lost']:.4f}", flush=True)
    for cell, cell_rows in rows.items():
        width = max(r.shape[1] for r in cell_rows)
        Image.fromarray(np.concatenate(
            [np.pad(r, ((0, 0), (0, width - r.shape[1]), (0, 0)), constant_values=255) for r in cell_rows], axis=0,
        ).astype(np.uint8)).save(out / "sheets" / f"{cell}.jpg", quality=88)
    (out / "report.json").write_text(json.dumps(report, indent=1))
    made = [r for r in report.values() if "gained" in r]
    for cell in sorted({r["cell"] for r in made}):
        cell_rows = [r for r in made if r["cell"] == cell]
        print(f"  {cell:22s} n={len(cell_rows):2d}  gained {np.mean([r['gained'] for r in cell_rows]):.4f}"
              f"  lost {np.mean([r['lost'] for r in cell_rows]):.4f}")


if __name__ == "__main__":
    if sys.argv[1:2] == ["eval"]:
        evaluation_set(tuple(sys.argv[2:]))
    else:
        main()
