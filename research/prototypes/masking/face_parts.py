#!/usr/bin/env python3
"""People's face parts on the evaluation set's faces, as Redlamp makes them today (MSK-30).

Face Skin, Eyebrows, Eye Sclera, Iris and Pupil, Lips and Teeth are drawn from Vision's 76 face
landmarks as polygons with a 2 px feather. The set has no labels for them, so they're judged by
eye: for every photo in the face cells (`face-*` in research/mask-eval/manifest.json), redlamp
makes each part, and a sheet per cell shows each face at 100%: the photo, then every part tinted
its own colour over it, then each part alone over mid-grey. Writes build/mask-bench/face-parts/.

    research/prototypes/masking/.venv/bin/python research/prototypes/masking/face_parts.py

Seen on 7 October 2026 (16 of the 18 faces; Vision finds no face in the two eye close-ups): Lips
follow the lips' outer edge, loosely on some faces (into a beard), with the mouth's opening cut
out. Teeth covers only the middle teeth, as a blocky shape: on the five teeth photos it covers 45%
to 91% of the tooth-coloured pixels inside the open mouth (67% on average), and up to a fifth of it
lies on lips or gums. Eyebrows are loose outlines, drawn even where a fringe hides the brows, so
they'd edit hair. Iris and Eye Sclera sit roughly on the eyes.
"""

import json
import os
import pathlib
import subprocess
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import mask_bench as mb  # noqa: E402

OUT = mb.OUT / "face-parts"
CLI = pathlib.Path(os.environ.get("REDLAMP_CLI", mb.ROOT / "build/DerivedData-masking/Build/Products/Release/redlamp"))
PARTS = {
    "faceSkin": (255, 200, 120), "eyebrows": (120, 60, 255), "eyeSclera": (0, 255, 255),
    "iris": (255, 0, 160), "lips": (255, 40, 40), "teeth": (80, 255, 80),
}
CROP = 520


def masks_for(path, stem):
    found = {}
    for part in PARTS:
        target = OUT / f"{stem}-{part}.png"
        if not target.exists() and not list(OUT.glob(f"{stem}-{part}-*.png")):
            result = subprocess.run([str(CLI), "mask", str(path), "--kind", f"people:{part}", "-o", str(target)],
                                    capture_output=True, text=True)
            if result.returncode != 0:
                found[part] = (result.stderr or result.stdout).strip().splitlines()[-1][-120:]
                continue
        paths = [target] if target.exists() else sorted(OUT.glob(f"{stem}-{part}-*.png"))
        found[part] = paths
    return found


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "sheets").mkdir(exist_ok=True)
    manifest = json.loads(mb.EVAL.read_text())
    rows, report = {}, {}
    for item in manifest["images"]:
        if not item["cell"].startswith("face"):
            continue
        path = mb.ROOT / "build/mask-eval" / item["file"]
        stem = pathlib.Path(item["file"]).stem
        found = masks_for(path, stem)
        report[stem] = {part: (len(value) if isinstance(value, list) else value) for part, value in found.items()}
        skin_paths = found.get("faceSkin")
        if not isinstance(skin_paths, list):
            print(f"{stem}: no face skin ({skin_paths})")
            continue
        size = Image.open(skin_paths[0]).size
        photo = np.asarray(Image.open(path).convert("RGB").resize(size, Image.LANCZOS), np.float32)
        loaded = {}
        for part, value in found.items():
            if isinstance(value, list):
                loaded[part] = np.max([np.asarray(Image.open(p).convert("L").resize(size, Image.BILINEAR),
                                                  np.float32) / 255 for p in value], axis=0)
        # Each face: the largest face skin's box, widened.
        skin = loaded["faceSkin"]
        ys, xs = np.nonzero(skin > 0.5)
        if len(xs) == 0:
            continue
        cx, cy = int(xs.mean()), int(ys.mean())
        half = max(int(max(xs.max() - xs.min(), ys.max() - ys.min()) * 0.7), CROP // 4)
        x0, x1 = max(cx - half, 0), min(cx + half, size[0])
        y0, y1 = max(cy - half, 0), min(cy + half, size[1])

        def fit(a):
            image = Image.fromarray(np.clip(a[y0:y1, x0:x1], 0, 255).astype(np.uint8))
            return np.asarray(image.resize((CROP, round(CROP * (y1 - y0) / (x1 - x0))), Image.LANCZOS), np.float32)

        tinted = photo.copy()
        for part, colour in PARTS.items():
            if part in loaded and part != "faceSkin":
                a = loaded[part][..., None] * 0.6
                tinted = tinted * (1 - a) + np.array(colour, np.float32) * a
        panels = [fit(photo), fit(tinted)]
        for part in ("lips", "teeth", "iris", "eyeSclera"):
            if part in loaded:
                a = loaded[part][..., None]
                panels.append(fit(a * photo + (1 - a) * 128))
        rows.setdefault(item["cell"], []).append(
            np.concatenate([np.pad(p, ((0, 6), (0, 6), (0, 0)), constant_values=255) for p in panels], axis=1))
        print(f"{stem}: {report[stem]}", flush=True)
    for cell, cell_rows in rows.items():
        width = max(r.shape[1] for r in cell_rows)
        sheet = np.concatenate([np.pad(r, ((0, 0), (0, width - r.shape[1]), (0, 0)), constant_values=255)
                                for r in cell_rows], axis=0)
        Image.fromarray(sheet.astype(np.uint8)).save(OUT / "sheets" / f"{cell}.jpg", quality=88)
    (OUT / "report.json").write_text(json.dumps(report, indent=1) + "\n")


if __name__ == "__main__":
    main()
