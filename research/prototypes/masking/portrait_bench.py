#!/usr/bin/env python3
"""Hair edges on real portraits: matting solvers against a learned reference.

There is no hand-matted portrait set yet, so ViTMatte (hustvl/vitmatte-base-composition-1k)
stands in for ground truth, as OneFormer does for sky: its training data (Composition-1k) is
research-only, so it can never ship. Every candidate gets the same trimap, built from Vision's
person mask (what Redlamp computes today): sure person well inside it, sure background well
outside, and an uncertain band between, wider outwards where hair pokes out. (DSC03301 uses the
Subject mask: in that dark, low-key photo Vision's person segmentation misses the head.)

The reference is computed with the widest trimap (1.2% in, 3.5% out), so it decides every pixel
any candidate might; all candidates are scored over that same band.

    research/prototypes/masking/.venv/bin/python research/prototypes/masking/portrait_bench.py

Portraits: build/edge-cases/<name>.jpg with <name>-people.png (from `redlamp mask --kind people`).
Scores, in the uncertain band: mean absolute error against the reference, and the share of
strands (reference 0.1-0.9 beyond Vision's edge) each candidate keeps (coverage > 0.1).
"""

import pathlib
import sys
import time

import numpy as np
from PIL import Image
from scipy import ndimage

ROOT = pathlib.Path(__file__).resolve().parents[3]
WORK = ROOT / "build/edge-cases"
PORTRAITS = {"DSC02005": "DSC02005-people.png", "DSC03301": "DSC03301-subject.png",
             "DSC02424": "DSC02424-people-1.png", "DSC01584": "DSC01584-people.png"}


def trimap(coarse, inner=0.006, outer=0.02):
    """Sure person (1), sure background (0), unknown (0.5); widths as fractions of the long side."""
    long = max(coarse.shape)
    person = coarse > 0.5
    inside = ndimage.distance_transform_edt(person)
    outside = ndimage.distance_transform_edt(~person)
    out = np.full(coarse.shape, 0.5, np.float32)
    out[inside > inner * long] = 1
    out[outside > outer * long] = 0
    return out


class ViTMatte:
    def __init__(self):
        import torch
        from transformers import VitMatteForImageMatting, VitMatteImageProcessor

        self.torch = torch
        self.processor = VitMatteImageProcessor.from_pretrained("hustvl/vitmatte-base-composition-1k")
        self.model = VitMatteForImageMatting.from_pretrained("hustvl/vitmatte-base-composition-1k").eval()
        self.device = "mps" if torch.backends.mps.is_available() else "cpu"
        self.model.to(self.device)

    def __call__(self, image, tri):
        tri_image = Image.fromarray((tri * 255).astype(np.uint8))
        inputs = self.processor(images=image, trimaps=tri_image, return_tensors="pt").to(self.device)
        with self.torch.no_grad():
            alpha = self.model(**inputs).alphas[0, 0].float().cpu().numpy()
        return np.clip(alpha[: image.height, : image.width], 0, 1)


def solvers():
    import pymatting

    import sky_matte

    def closed_form(image, tri, coarse):
        return pymatting.estimate_alpha_cf(
            image.astype(np.float64), tri.astype(np.float64), laplacian_kwargs={"epsilon": 1e-5},
        )

    def knn(image, tri, coarse):
        return pymatting.estimate_alpha_knn(image.astype(np.float64), tri.astype(np.float64))

    def learning(image, tri, coarse):
        return pymatting.estimate_alpha_lbdm(image.astype(np.float64), tri.astype(np.float64))

    def colour_model(image, tri, coarse):
        return sky_matte.refine_subject(image, coarse)

    return {"vision": lambda image, tri, coarse: coarse, "closed-form": closed_form, "knn": knn,
            "learning-based": learning, "colour-model": colour_model}


def main():
    reference = ViTMatte()
    candidates = solvers()
    totals = {name: [] for name in candidates}
    for name, mask_name in PORTRAITS.items():
        image = Image.open(WORK / f"{name}.jpg").convert("RGB")
        array = np.asarray(image, np.float32) / 255
        coarse = np.asarray(Image.open(WORK / mask_name).convert("L").resize(image.size, Image.BILINEAR), np.float32) / 255
        tri = trimap(coarse)
        wide = trimap(coarse, inner=0.012, outer=0.035)
        Image.fromarray((tri * 255).astype(np.uint8)).save(WORK / f"{name}-trimap.png")
        started = time.perf_counter()
        truth = reference(image, wide)
        print(f"{name}: reference in {time.perf_counter() - started:.1f} s", flush=True)
        Image.fromarray((truth * 255).astype(np.uint8)).save(WORK / f"{name}-vitmatte.png")
        unknown = wide == 0.5
        strands = unknown & (coarse < 0.5) & (truth > 0.1) & (truth < 0.9)
        for method, solve in candidates.items():
            started = time.perf_counter()
            try:
                alpha = np.clip(solve(array, tri, coarse), 0, 1)
            except Exception as error:  # noqa: BLE001
                print(f"  {method}: failed ({error})")
                continue
            elapsed = time.perf_counter() - started
            Image.fromarray((alpha * 255 + 0.5).astype(np.uint8)).save(WORK / f"{name}-{method}.png")
            mae = float(np.abs(alpha - truth)[unknown].mean())
            kept = float((alpha[strands] > 0.1).mean()) if strands.any() else float("nan")
            totals[method].append((mae, kept, elapsed))
            print(f"  {method:15s} band MAE {mae:.3f}  strands kept {kept:.2f}  {elapsed:.1f} s", flush=True)
    print("\nmean over portraits")
    for method, rows in totals.items():
        if rows:
            a = np.array(rows)
            print(f"  {method:15s} band MAE {a[:, 0].mean():.3f}  strands kept {np.nanmean(a[:, 1]):.2f}  {a[:, 2].mean():.1f} s")


if __name__ == "__main__":
    sys.exit(main())
