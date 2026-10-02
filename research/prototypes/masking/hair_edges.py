#!/usr/bin/env python3
"""Hair edges both ways: SAM 3's where hair meets skin, the person's matte where it meets the background.

SAM 3's hair (sam3_people_parts.py) draws the hairline and the beard's edge well, but at 288 ×
288 it misses strands against the background, which the person's closed-form matte (what
Redlamp computes for People) keeps. Where hair meets the background the hair's coverage is the
person's, so a candidate takes the matte there: near SAM 3's hair, wherever SAM 3 sees none of
the person's other parts (face, skin, clothes, facial hair).

Scored against ViTMatte's matte of the person (portrait_bench.py's reference, the open trimap),
which stands for the hair's own where the hair meets the background:
  * band MAE: mean absolute error over the hair's outer band (within reach of SAM 3's hair, away
    from the other parts, where the reference or a candidate is neither 0 nor 1);
  * strands: of the reference's strand pixels (0.1-0.9) beyond SAM 3's hair, the share kept (> 0.1);
  * on skin: mean hair coverage where SAM 3's other parts are sure (> 0.8): bleed, lower is better.

    research/prototypes/masking/.venv-sam3-coreml/bin/python research/prototypes/masking/hair_edges.py
"""

import pathlib

import numpy as np
from PIL import Image
from scipy import ndimage

ROOT = pathlib.Path(__file__).resolve().parents[3]
EDGES = ROOT / "build/edge-cases"
PARTS = ROOT / "build/people-parts"
PORTRAITS = {"DSC02005": "DSC02005-swift-cf.png", "DSC03301": "DSC03301-swift-cf.png",
             "DSC02424": "DSC02424-swift-cf-1.png", "DSC01584": "DSC01584-swift-cf.png"}
REACH = 0.02


def load(path, size):
    return np.asarray(Image.open(path).convert("L").resize(size, Image.BILINEAR), np.float32) / 255


def part(name, which, size):
    return sum(load(PARTS / f"{name}-whole-{which}-{k}.png", size) for k in ("instances", "semantic")) / 2


def box(a, r):
    return ndimage.uniform_filter(a, size=2 * r + 1, mode="nearest")


def guided(p, guide, r=4, eps=1e-3):
    mi, mp = box(guide, r), box(p, r)
    a = (box(guide * p, r) - mi * mp) / (box(guide * guide, r) - mi * mi + eps)
    return np.clip(box(a, r) * guide + box(mp - a * mi, r), 0, 1)


def main():
    rows = []
    for name, matte_name in PORTRAITS.items():
        image = Image.open(EDGES / f"{name}.jpg").convert("RGB")
        size = image.size
        gray = np.asarray(image.convert("L"), np.float32) / 255
        long = max(size)
        facial = part(name, "facial-hair", size)
        hair_raw = np.clip(part(name, "hair", size) - facial, 0, 1)
        others = np.maximum.reduce([part(name, p, size) for p in ("face", "body-skin", "clothes", "facial-hair")])
        sam = guided(np.maximum(hair_raw - 0.1, 0) / 0.9, gray)
        person = load(EDGES / matte_name, size)
        truth = load(EDGES / f"{name}-vitmatte-open.png", size)
        near = ndimage.distance_transform_edt(sam <= 0.5) <= REACH * long
        free = np.clip(person - others, 0, 1) * near
        candidates = {
            "sam3": sam,
            "sam3+matte": np.maximum(sam, free),
            "sam3+matte (others snapped)": np.maximum(sam, np.clip(person - guided(others, gray), 0, 1) * near),
        }
        hair_region = sam > 0.5
        outside = near & (others < 0.2)
        strands = outside & ~hair_region & (truth > 0.1) & (truth < 0.9)
        sure_other = others > 0.8
        for label, mask in candidates.items():
            band = outside & (((truth > 0.02) & (truth < 0.98)) | ((mask > 0.02) & (mask < 0.98)))
            mae = float(np.abs(mask - truth)[band].mean())
            kept = float((mask[strands] > 0.1).mean()) if strands.any() else float("nan")
            bleed = float(mask[sure_other].mean())
            rows.append((name, label, mae, kept, bleed))
            print(f"{name} {label:28s} band MAE {mae:.3f}  strands {kept:.2f}  on skin {bleed:.4f}", flush=True)
            Image.fromarray((mask * 255).astype(np.uint8)).save(PARTS / f"{name}-hair-{label.split()[0]}.png")
    print()
    for label in dict.fromkeys(r[1] for r in rows):
        sel = np.array([r[2:] for r in rows if r[1] == label])
        print(f"mean {label:28s} band MAE {sel[:, 0].mean():.3f}  strands {np.nanmean(sel[:, 1]):.2f}  "
              f"on skin {sel[:, 2].mean():.4f}")


if __name__ == "__main__":
    main()
