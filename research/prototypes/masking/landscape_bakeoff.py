#!/usr/bin/env python3
"""Landscape mask bake-off (MSK-17's next step): Lightroom's Landscape classes on the CC0
look-development set, against OneFormer.

Lightroom splits Landscape into Sky (Redlamp has it), Water, Vegetation, Mountains, Architecture,
Natural Ground and Artificial Ground. OneFormer (ADE20K, Swin-L; non-commercial data, never ships)
stands in for ground truth, its 150 classes grouped into those six. Candidates write
build/landscape-bakeoff/<photo>-<candidate>-<class>.png; `score` compares them.

    KMP_DUPLICATE_LIB_OK=TRUE research/prototypes/masking/.venv/bin/python \\
        research/prototypes/masking/landscape_bakeoff.py reference
    research/prototypes/masking/.venv-sam3/bin/python research/prototypes/masking/sam3_landscape.py
    research/prototypes/masking/.venv/bin/python research/prototypes/masking/landscape_bakeoff.py score sam3

Scores per class: IoU on the photos where the reference covers at least 1% of the frame; the
false-positive share (the candidate's coverage) on photos where it covers under 0.2%.
"""

import json
import pathlib
import subprocess
import sys

import numpy as np
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parents[3]
LOOKDEV = ROOT / "build/look-dev"
WORK = ROOT / "build/landscape-bakeoff"
CLI = ROOT / "build/DerivedData/Build/Products/Release/redlamp"

# ADE20K labels (as OneFormer's config names them) in each Lightroom class.
CLASSES = {
    "water": ["water", "sea", "river", "lake", "waterfall", "swimming pool", "fountain"],
    "vegetation": ["tree", "grass", "plant", "flower", "palm"],
    "mountains": ["mountain", "hill"],
    "architecture": ["building", "house", "skyscraper", "tower", "bridge", "hovel", "column", "booth", "awning"],
    "natural-ground": ["earth", "sand", "field", "dirt track", "land", "rock", "snow"],
    "artificial-ground": ["road", "sidewalk", "floor", "path", "runway", "stairs", "stairway", "step", "pier"],
}


def photos():
    manifest = json.loads((ROOT / "research/look-dev/manifest.json").read_text())
    return [LOOKDEV / item["file"] for item in manifest["images"] if (LOOKDEV / item["file"]).exists()]


def render(photo):
    out = WORK / f"{photo.stem}.png"
    if not out.exists():
        subprocess.run([str(CLI), "render", str(photo), "-o", str(out), "--size", "2048"], capture_output=True)
    return out


def reference():
    import torch
    from transformers import OneFormerForUniversalSegmentation, OneFormerProcessor

    WORK.mkdir(parents=True, exist_ok=True)
    processor = OneFormerProcessor.from_pretrained("shi-labs/oneformer_ade20k_swin_large")
    model = OneFormerForUniversalSegmentation.from_pretrained("shi-labs/oneformer_ade20k_swin_large").eval()
    labels = {name.strip().lower(): int(i) for i, name in model.config.id2label.items()}
    ids = {}
    for cls, names in CLASSES.items():
        found = []
        for name in names:
            matches = [i for label, i in labels.items() if label == name or label.split(",")[0].strip() == name]
            if not matches:
                print(f"  {cls}: no ADE20K label '{name}'")
            found += matches
        ids[cls] = sorted(set(found))
        print(f"{cls}: {[model.config.id2label[i] for i in ids[cls]]}")
    for photo in photos():
        stem = photo.stem
        if all((WORK / f"{stem}-reference-{cls}.png").exists() for cls in CLASSES):
            continue
        image = Image.open(render(photo)).convert("RGB")
        inputs = processor(images=image, task_inputs=["semantic"], return_tensors="pt")
        with torch.no_grad():
            outputs = model(**inputs)
        semantic = processor.post_process_semantic_segmentation(outputs, target_sizes=[image.size[::-1]])[0].numpy()
        for cls, wanted in ids.items():
            mask = np.isin(semantic, wanted).astype(np.uint8) * 255
            Image.fromarray(mask).save(WORK / f"{stem}-reference-{cls}.png")
        print(stem, {cls: round(float(np.isin(semantic, w).mean()), 3) for cls, w in ids.items()}, flush=True)


# Lightroom's Landscape classes don't overlap: where several claim a pixel, the first here wins
# (grass is vegetation, not ground; a road is artificial ground even if "ground" also fired).
PRECEDENCE = ["water", "vegetation", "architecture", "mountains", "artificial-ground", "natural-ground"]


def exclusive(candidate):
    """Writes <photo>-<candidate>x-<class>.png: `candidate`'s masks made exclusive by precedence."""
    for photo in photos():
        stem = photo.stem
        paths = [WORK / f"{stem}-{candidate}-{cls}.png" for cls in PRECEDENCE]
        if not all(p.exists() for p in paths):
            continue
        taken = None
        for cls, path in zip(PRECEDENCE, paths):
            mask = np.asarray(Image.open(path).convert("L"), np.float32) / 255
            if taken is None:
                taken = np.zeros_like(mask)
            own = np.clip(mask - taken, 0, 1)
            taken = np.maximum(taken, mask)
            Image.fromarray((own * 255 + 0.5).astype(np.uint8)).save(WORK / f"{stem}-{candidate}x-{cls}.png")


def load(path, size):
    if not path.exists():
        return None
    return np.asarray(Image.open(path).convert("L").resize(size, Image.BILINEAR), np.float32) / 255


def score(candidates):
    rows = {}
    for photo in photos():
        stem = photo.stem
        render_path = WORK / f"{stem}.png"
        if not render_path.exists():
            continue
        size = Image.open(render_path).size
        for cls in CLASSES:
            truth = load(WORK / f"{stem}-reference-{cls}.png", size)
            if truth is None:
                continue
            share = float((truth > 0.5).mean())
            for candidate in candidates:
                mask = load(WORK / f"{stem}-{candidate}-{cls}.png", size)
                if mask is None:
                    continue
                entry = rows.setdefault((candidate, cls), {"iou": [], "fp": []})
                if share >= 0.01:
                    a, b = mask > 0.5, truth > 0.5
                    entry["iou"].append(float((a & b).sum() / max((a | b).sum(), 1)))
                elif share < 0.002:
                    entry["fp"].append(float((mask > 0.5).mean()))
    print(f"{'candidate':12s} {'class':18s} {'photos':>6s} {'mean IoU':>9s} {'false +':>8s}")
    for (candidate, cls), entry in sorted(rows.items()):
        iou = np.mean(entry["iou"]) if entry["iou"] else float("nan")
        fp = np.mean(entry["fp"]) if entry["fp"] else float("nan")
        print(f"{candidate:12s} {cls:18s} {len(entry['iou']):6d} {iou:9.3f} {fp:8.4f}")
    (WORK / "scores.json").write_text(json.dumps({f"{c}/{k}": v for (c, k), v in rows.items()}, indent=2))


if __name__ == "__main__":
    if sys.argv[1:2] == ["reference"]:
        reference()
    elif sys.argv[1:2] == ["exclusive"]:
        exclusive(sys.argv[2])
    elif sys.argv[1:2] == ["score"]:
        score(sys.argv[2:])
    else:
        sys.exit(__doc__)
