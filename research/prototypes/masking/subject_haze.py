#!/usr/bin/env python3
"""Subject masks and the haze closed-form leaves beside hair: how far inside Vision's edge to doubt.

Vision's Subject mask can run a few pixels outside the hair, onto a smooth background. The trimap
takes everything 0.6% of the long side inside the mask's edge as sure subject, so that sliver of
background is held at full coverage and the solve spreads a haze from it. Candidates: wider inner
bands. Solved with pymatting (the same matting energy as ClosedFormMatte) at 1024 px, scored as
portrait_bench.py does along the person's edge (the wide band around Vision's person mask, where
ViTMatte's matte stands for the truth; Subject also covers objects the person reference doesn't).

    research/prototypes/masking/.venv/bin/python research/prototypes/masking/subject_haze.py

Needs build/subject-haze/<photo>-coarse.png (`redlamp mask --kind subject` with REDLAMP_EDGE_MATTE=off).
"""

import pathlib
import sys

import numpy as np
import pymatting
from PIL import Image

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from portrait_bench import trimap  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parents[3]
EDGES = ROOT / "build/edge-cases"
WORK = ROOT / "build/subject-haze"
PEOPLE = {"DSC02005": "DSC02005-people.png", "DSC03301": "DSC03301-subject.png",
          "DSC02424": "DSC02424-people-1.png", "DSC01584": "DSC01584-people.png", "dancer": "dancer-people-vision.png"}
LONG = 1024
INNER = (0.006, 0.01, 0.015, 0.02)


def load(path, size, mode="L"):
    image = Image.open(path).convert(mode).resize(size, Image.BILINEAR)
    return np.asarray(image, np.float64) / 255


def main():
    totals = {}
    for name, people in PEOPLE.items():
        source = EDGES / (f"{name}.jpg" if (EDGES / f"{name}.jpg").exists() else f"{name}.png")
        full = Image.open(source)
        size = (round(full.width * LONG / max(full.size)), round(full.height * LONG / max(full.size)))
        image = load(source, size, "RGB")
        subject = load(WORK / f"{name}-coarse.png", size)
        person = load(EDGES / people, size)
        truth = load(EDGES / f"{name}-vitmatte-open.png", size)
        unknown = trimap(person, inner=0.012, outer=0.035) == 0.5
        strands = unknown & (person < 0.5) & (truth > 0.1) & (truth < 0.9)
        background = unknown & (truth < 0.02)
        for inner in INNER:
            alpha = np.clip(pymatting.estimate_alpha_cf(image, trimap(subject, inner=inner, outer=0.02),
                                                        laplacian_kwargs={"epsilon": 1e-5}), 0, 1)
            row = (float(np.abs(alpha - truth)[unknown].mean()), float((alpha[strands] > 0.1).mean()),
                   float(alpha[background].mean()))
            totals.setdefault(inner, []).append(row)
            print(f"{name:9s} inner {inner:.3f}: MAE {row[0]:.4f} strands {row[1]:.2f} haze {row[2]:.4f}", flush=True)
    print("\nmean")
    for inner, rows in totals.items():
        a = np.array(rows)
        print(f"  inner {inner:.3f}: MAE {a[:, 0].mean():.4f} strands {a[:, 1].mean():.2f} haze {a[:, 2].mean():.4f}")


if __name__ == "__main__":
    main()
