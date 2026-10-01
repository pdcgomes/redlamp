#!/usr/bin/env python3
"""SAM 3 for the sky bake-off (MSK-17): a text prompt ("sky") on each analysis render.

SAM 3 needs Transformers 5, while Florence-2 needs 4.x, so it runs in its own environment and
writes its masks where sky_bakeoff.py scores them:

    research/prototypes/masking/.venv-sam3/bin/python research/prototypes/masking/sam3_sky.py

The weights are gated (facebook/sam3, Meta's SAM License): a Hugging Face login that has been
granted access is needed. Every instance SAM 3 finds is merged into one mask, keeping each
pixel's highest instance score.
"""

import pathlib
import sys
import time

import numpy as np
import torch
from PIL import Image
from transformers import Sam3Model, Sam3Processor

ROOT = pathlib.Path(__file__).resolve().parents[3]
WORK = ROOT / "build/masking-bakeoff"
NAME = "sam3-text-sky"


def main():
    # The analysis renders are the PNGs that have a classical mask beside them.
    renders = [p for p in WORK.glob("*.png") if (WORK / f"{p.stem}-classical.png").exists()]
    if not renders:
        sys.exit("run sky_bakeoff.py first: it writes the analysis renders")
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    started = time.perf_counter()
    model = Sam3Model.from_pretrained("facebook/sam3").to(device).eval()
    processor = Sam3Processor.from_pretrained("facebook/sam3")
    print(f"loaded on {device} in {time.perf_counter() - started:.1f} s")
    for render in sorted(renders):
        image = Image.open(render).convert("RGB")
        started = time.perf_counter()
        inputs = processor(images=image, text="sky", return_tensors="pt").to(device)
        with torch.no_grad():
            outputs = model(**inputs)
        results = processor.post_process_instance_segmentation(
            outputs, threshold=0.4, mask_threshold=0.5, target_sizes=inputs.get("original_sizes").tolist(),
        )[0]
        elapsed = time.perf_counter() - started
        mask = np.zeros((image.height, image.width), dtype=np.float32)
        for instance, score in zip(results["masks"], results["scores"]):
            mask = np.maximum(mask, instance.float().cpu().numpy() * float(score > 0))
        Image.fromarray((mask * 255).astype(np.uint8)).save(WORK / f"{render.stem}-{NAME}.png")
        (WORK / f"{render.stem}-{NAME}.seconds").write_text(f"{elapsed:.3f}")
        print(f"{render.stem}: {len(results['masks'])} instances, sky {mask.mean():.3f}, {elapsed:.2f} s")


if __name__ == "__main__":
    main()
