#!/usr/bin/env python3
"""Sky mask bake-off (tracker MSK-17): Redlamp's shippable candidates against open models.

For each sky photo in the CC0 look-development set (research/look-dev/manifest.json):
  1. `redlamp render` writes the analysis render (default develop, sRGB, 2048 px), the image
     every AI mask is computed from;
  2. `redlamp mask --kind sky` runs the classical estimate, and with REDLAMP_SKY_METHOD=sam
     Segment Anything 2.1 seeded inside it;
  3. OneFormer (ADE20K, Swin-L), Florence-2 and Depth Anything 3 Mono-L's sky head run here in
     PyTorch.

OneFormer is trained on ADE20K (non-commercial) and can never ship: it is the quality ceiling,
and stands in for hand-labelled ground truth until the labelled set exists. Scores are IoU and
a boundary F-score (edges within 1% of the diagonal) against it, plus wall-clock time.

    KMP_DUPLICATE_LIB_OK=TRUE research/prototypes/masking/.venv/bin/python research/prototypes/masking/sky_bakeoff.py

The environment: torch, torchvision, transformers==4.49 (Florence-2's remote code needs 4.x),
pillow, numpy, scipy, timm, einops, and Depth Anything 3 installed with `--no-deps` from
github.com/ByteDance-Seed/Depth-Anything-3 plus its runtime imports (addict, omegaconf, opencv,
pycolmap, ...; not xformers, which doesn't build on macOS). KMP_DUPLICATE_LIB_OK is needed because
pycolmap and torch each bring an OpenMP runtime.
"""

import json
import os
import pathlib
import subprocess
import sys
import time

import numpy as np
from PIL import Image
from scipy import ndimage

ROOT = pathlib.Path(__file__).resolve().parents[3]
LOOKDEV = ROOT / "build/look-dev"
WORK = ROOT / "build/masking-bakeoff"
CLI = ROOT / "build/DerivedData/Build/Products/Release/redlamp"


def sky_photos():
    manifest = json.loads((ROOT / "research/look-dev/manifest.json").read_text())
    items = manifest if isinstance(manifest, list) else manifest.get("images", manifest.get("files", []))
    names = [item.get("file") or item.get("name") or item.get("filename") for item in items if "sky" in json.dumps(item)]
    return [LOOKDEV / name for name in names if name and (LOOKDEV / name).exists()]


def run(command, env=None):
    started = time.perf_counter()
    result = subprocess.run(command, capture_output=True, text=True, env={**os.environ, **(env or {})})
    return result, time.perf_counter() - started


def load_mask(path, size):
    if not path.exists():
        return None
    mask = Image.open(path).convert("L").resize(size, Image.BILINEAR)
    return np.asarray(mask, dtype=np.float32) / 255


class OneFormer:
    name = "oneformer-ade20k-swin-large"

    def __init__(self):
        import torch
        from transformers import OneFormerForUniversalSegmentation, OneFormerProcessor

        self.torch = torch
        # Its post-processing uses float64, which MPS doesn't have.
        self.device = "cpu"
        self.processor = OneFormerProcessor.from_pretrained("shi-labs/oneformer_ade20k_swin_large")
        self.model = OneFormerForUniversalSegmentation.from_pretrained("shi-labs/oneformer_ade20k_swin_large")
        self.model.to(self.device).eval()
        labels = self.model.config.id2label
        self.sky = [int(i) for i, name in labels.items() if name.strip().lower() == "sky"]

    def __call__(self, image):
        inputs = self.processor(images=image, task_inputs=["semantic"], return_tensors="pt")
        inputs = {k: v.to(self.device) if hasattr(v, "to") else v for k, v in inputs.items()}
        with self.torch.no_grad():
            outputs = self.model(**inputs)
        semantic = self.processor.post_process_semantic_segmentation(outputs, target_sizes=[image.size[::-1]])[0]
        return np.isin(semantic.cpu().numpy(), self.sky).astype(np.float32)


class Florence2:
    name = "florence-2-base"

    def __init__(self):
        import torch
        from transformers import AutoModelForCausalLM, AutoProcessor

        self.torch = torch
        self.model = AutoModelForCausalLM.from_pretrained(
            "microsoft/Florence-2-base", trust_remote_code=True, torch_dtype=torch.float32,
        ).eval()
        self.processor = AutoProcessor.from_pretrained("microsoft/Florence-2-base", trust_remote_code=True)

    def __call__(self, image):
        from PIL import ImageDraw

        task = "<REFERRING_EXPRESSION_SEGMENTATION>"
        inputs = self.processor(text=task + "sky", images=image, return_tensors="pt")
        with self.torch.no_grad():
            ids = self.model.generate(
                input_ids=inputs["input_ids"], pixel_values=inputs["pixel_values"], max_new_tokens=1024, num_beams=3,
            )
        text = self.processor.batch_decode(ids, skip_special_tokens=False)[0]
        parsed = self.processor.post_process_generation(text, task=task, image_size=image.size)[task]
        canvas = Image.new("L", image.size, 0)
        draw = ImageDraw.Draw(canvas)
        for polygons in parsed.get("polygons", []):
            for polygon in polygons:
                if len(polygon) >= 6:
                    draw.polygon(polygon, fill=255)
        return np.asarray(canvas, dtype=np.float32) / 255


class DepthAnything3Sky:
    """Depth Anything 3 Mono-L's sky head (thresholded at 0.5 by the package), at 504 px."""

    name = "da3-mono-large-sky"

    def __init__(self):
        import torch
        from depth_anything_3.api import DepthAnything3

        self.model = DepthAnything3.from_pretrained("depth-anything/DA3MONO-LARGE")
        # One image at a time: its preprocessing pool needs semaphores the sandbox may not allow.
        preprocess = self.model.input_processor
        self.model.input_processor = lambda *args, **kwargs: preprocess(
            *args, **{**kwargs, "sequential": True, "num_workers": 1},
        )
        self.device = "mps" if torch.backends.mps.is_available() else "cpu"
        try:
            self.model = self.model.to(self.device)
        except Exception:  # noqa: BLE001 - fall back to the CPU
            self.device = "cpu"
            self.model = self.model.to("cpu")
        self.model.eval()

    def __call__(self, image):
        prediction = self.model.inference([np.asarray(image)], process_res=504)
        sky = getattr(prediction, "sky", None)
        if sky is None:
            raise RuntimeError("no sky output")
        mask = Image.fromarray((np.asarray(sky[0], dtype=np.uint8) * 255)).resize(image.size, Image.BILINEAR)
        return np.asarray(mask, dtype=np.float32) / 255


def iou(a, b):
    a, b = a > 0.5, b > 0.5
    union = np.logical_or(a, b).sum()
    return 1.0 if union == 0 else np.logical_and(a, b).sum() / union


def boundary_f(a, b, tolerance):
    def edge(mask):
        mask = mask > 0.5
        return mask ^ ndimage.binary_erosion(mask)

    ea, eb = edge(a), edge(b)
    if ea.sum() == 0 and eb.sum() == 0:
        return 1.0
    da = ndimage.distance_transform_edt(~ea)
    db = ndimage.distance_transform_edt(~eb)
    precision = (db[ea] <= tolerance).mean() if ea.sum() else 0
    recall = (da[eb] <= tolerance).mean() if eb.sum() else 0
    return 0.0 if precision + recall == 0 else 2 * precision * recall / (precision + recall)


# Candidates run elsewhere (their own environments) whose masks are scored when present.
PRECOMPUTED = ["sam3-text-sky", "redlamp-auto", "redlamp-da3"]


def main():
    score_only = "--score-only" in sys.argv
    if not CLI.exists() and not score_only:
        sys.exit("build the CLI first: SCHEME=redlamp CONFIGURATION=Release mise run build")
    WORK.mkdir(parents=True, exist_ok=True)
    photos = sky_photos()
    print(f"{len(photos)} sky photos")
    candidates = {}
    factories = () if score_only else (OneFormer, Florence2, DepthAnything3Sky)
    for factory in factories:
        try:
            candidates[factory.name] = factory()
        except Exception as error:  # noqa: BLE001 - a candidate that won't load is reported, not fatal
            print(f"{factory.name}: could not load ({type(error).__name__}: {str(error)[:120]})")
    rows = []
    for photo in photos:
        stem = photo.stem
        render = WORK / f"{stem}.png"
        if not render.exists():
            run([str(CLI), "render", str(photo), "-o", str(render), "--size", "2048"])
        image = Image.open(render).convert("RGB")
        size = image.size
        times = {}
        for method, env in (("classical", {}), ("sam", {"REDLAMP_SKY_METHOD": "sam", "REDLAMP_EVALUATION_MODELS": "1"})):
            out = WORK / f"{stem}-{method}.png"
            timing = WORK / f"{stem}-{method}.seconds"
            if not score_only:
                result, elapsed = run([str(CLI), "mask", str(photo), "--kind", "sky", "-o", str(out)], env)
                if result.returncode != 0 and out.exists():
                    out.unlink()
                timing.write_text(f"{elapsed:.3f}")
            if timing.exists():
                times[method] = float(timing.read_text())
        masks = {method: load_mask(WORK / f"{stem}-{method}.png", size) for method in ("classical", "sam")}
        names = list(candidates) + PRECOMPUTED + ([] if not score_only else [
            OneFormer.name, Florence2.name, DepthAnything3Sky.name,
        ])
        for name in names:
            if name in candidates:
                continue
            masks[name] = load_mask(WORK / f"{stem}-{name}.png", size)
            timing = WORK / f"{stem}-{name}.seconds"
            if timing.exists():
                times[name] = float(timing.read_text())
        for name, candidate in candidates.items():
            out = WORK / f"{stem}-{name}.png"
            timing = WORK / f"{stem}-{name}.seconds"
            if not out.exists():
                started = time.perf_counter()
                try:
                    Image.fromarray((candidate(image) * 255).astype(np.uint8)).save(out)
                    timing.write_text(f"{time.perf_counter() - started:.3f}")
                except Exception as error:  # noqa: BLE001
                    print(f"{name} failed on {stem}: {error}")
            if timing.exists():
                times[name] = float(timing.read_text())
            masks[name] = load_mask(out, size)
        reference = masks.get(OneFormer.name)
        tolerance = 0.01 * np.hypot(*size)
        row = {"photo": stem, "skyFraction": None if reference is None else float((reference > 0.5).mean())}
        for method, mask in masks.items():
            if method == OneFormer.name:
                continue
            if mask is None or reference is None:
                row[method] = None
                continue
            row[method] = {
                "iou": round(float(iou(mask, reference)), 3),
                "boundaryF": round(float(boundary_f(mask, reference, tolerance)), 3),
                "seconds": round(times.get(method, 0), 2),
            }
        rows.append(row)
        print(json.dumps(row))
    (WORK / "results.json").write_text(json.dumps(rows, indent=2))
    contact_sheet(photos, sorted(set(m for r in rows for m in r if m not in ("photo", "skyFraction"))))
    summarize(rows)


def summarize(rows):
    methods = sorted({key for row in rows for key in row if key not in ("photo", "skyFraction")})
    print("\nmethod                      found   mean IoU   mean boundary F   (vs OneFormer, photos with sky)")
    for method in methods:
        scored = [row[method] for row in rows if row.get("skyFraction") and row.get(method)]
        with_sky = [row for row in rows if row.get("skyFraction")]
        found = len(scored)
        mean_iou = np.mean([s["iou"] for s in scored]) if scored else float("nan")
        mean_f = np.mean([s["boundaryF"] for s in scored]) if scored else float("nan")
        print(f"{method:26s}  {found:2d}/{len(with_sky):2d}   {mean_iou:8.3f}   {mean_f:15.3f}")


def contact_sheet(photos, methods):
    columns = ["render", "oneformer-ade20k-swin-large"] + [m for m in methods if m != "oneformer-ade20k-swin-large"]
    cell = (320, 214)
    sheet = Image.new("RGB", (cell[0] * len(columns), cell[1] * len(photos)), (30, 30, 30))
    for row, photo in enumerate(photos):
        render = Image.open(WORK / f"{photo.stem}.png").convert("RGB")
        for column, method in enumerate(columns):
            if method == "render":
                tile = render
            else:
                path = WORK / f"{photo.stem}-{method}.png"
                if not path.exists():
                    continue
                mask = Image.open(path).convert("L").resize(render.size)
                tint = Image.new("RGB", render.size, (255, 60, 60))
                tile = Image.composite(Image.blend(render, tint, 0.55), render, mask)
            tile = tile.copy()
            tile.thumbnail(cell)
            sheet.paste(tile, (column * cell[0], row * cell[1]))
    sheet.save(WORK / "contact-sheet.jpg", quality=85)
    print(f"contact sheet: {WORK / 'contact-sheet.jpg'} (columns: {', '.join(columns)})")


if __name__ == "__main__":
    main()
