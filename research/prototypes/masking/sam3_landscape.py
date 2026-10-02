#!/usr/bin/env python3
"""SAM 3 for the Landscape bake-off: text prompts for each of Lightroom's Landscape classes.

Runs in its own environment (Transformers 5), on the analysis renders landscape_bakeoff.py writes:

    research/prototypes/masking/.venv-sam3/bin/python research/prototypes/masking/sam3_landscape.py

Every instance of every prompt in a class is merged into that class's mask (each pixel keeping its
highest-scoring instance). Writes build/landscape-bakeoff/<photo>-sam3-<class>.png and the time.
"""

import json
import pathlib
import time

import numpy as np
import torch
from PIL import Image
from transformers import Sam3Model, Sam3Processor

ROOT = pathlib.Path(__file__).resolve().parents[3]
WORK = ROOT / "build/landscape-bakeoff"
PROMPTS = {
    "water": ["water", "sea", "lake", "river"],
    "vegetation": ["tree", "grass", "lawn", "meadow", "bush", "plant"],
    "mountains": ["mountain", "hill"],
    "architecture": ["building"],
    "natural-ground": ["ground", "sand", "rock", "dirt"],
    "artificial-ground": ["road", "pavement", "floor"],
}


def main():
    # The analysis renders: the PNGs the reference has masks for.
    renders = sorted(p for p in WORK.glob("*.png") if (WORK / f"{p.stem}-reference-water.png").exists())
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    started = time.perf_counter()
    model = Sam3Model.from_pretrained("facebook/sam3").to(device).eval()
    processor = Sam3Processor.from_pretrained("facebook/sam3")
    print(f"loaded on {device} in {time.perf_counter() - started:.1f} s, {len(renders)} renders", flush=True)
    times = {}
    for render in renders:
        if all((WORK / f"{render.stem}-sam3-{cls}.png").exists() for cls in PROMPTS):
            continue
        image = Image.open(render).convert("RGB")
        started = time.perf_counter()
        for cls, prompts in PROMPTS.items():
            mask = np.zeros((image.height, image.width), dtype=np.float32)
            for prompt in prompts:
                inputs = processor(images=image, text=prompt, return_tensors="pt").to(device)
                with torch.no_grad():
                    outputs = model(**inputs)
                results = processor.post_process_instance_segmentation(
                    outputs, threshold=0.4, mask_threshold=0.5, target_sizes=inputs.get("original_sizes").tolist(),
                )[0]
                for instance in results["masks"]:
                    mask = np.maximum(mask, instance.float().cpu().numpy())
            Image.fromarray((mask * 255).astype(np.uint8)).save(WORK / f"{render.stem}-sam3-{cls}.png")
        times[render.stem] = round(time.perf_counter() - started, 2)
        print(f"{render.stem}: {times[render.stem]} s", flush=True)
    (WORK / "sam3-times.json").write_text(json.dumps(times, indent=2))


if __name__ == "__main__":
    main()
