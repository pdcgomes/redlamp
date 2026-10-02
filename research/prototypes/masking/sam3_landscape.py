#!/usr/bin/env python3
"""SAM 3 for the Landscape bake-off: text prompts for each of Lightroom's Landscape classes.

Runs in its own environment (Transformers 5), on the analysis renders landscape_bakeoff.py writes:

    research/prototypes/masking/.venv-sam3/bin/python research/prototypes/masking/sam3_landscape.py

As a Core ML version would run it: the image encoded once per photo, each prompt's text once, and
only the small decoder per prompt. Two candidates per class:
  * sam3: every instance of every prompt merged (each pixel keeping its highest instance);
  * sam3sem: SAM 3's dense semantic map for each prompt, gated by its presence score, maxed over
    the class's prompts (one 288 × 288 map per prompt: what Landscape's stuff classes need, and
    much less for a decoder to produce than 200 instance masks).
Writes build/landscape-bakeoff/<photo>-<candidate>-<class>.png.
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
    model = Sam3Model.from_pretrained("facebook/sam3").to(device).eval()
    processor = Sam3Processor.from_pretrained("facebook/sam3")
    texts = {}
    with torch.no_grad():
        for prompt in {p for prompts in PROMPTS.values() for p in prompts}:
            tokens = processor(text=prompt, return_tensors="pt").to(device)
            texts[prompt] = (model.get_text_features(input_ids=tokens["input_ids"], attention_mask=tokens["attention_mask"],
                                                     return_dict=True), tokens["attention_mask"])
    times = {}
    for render in renders:
        image = Image.open(render).convert("RGB")
        started = time.perf_counter()
        inputs = processor(images=image, return_tensors="pt").to(device)
        size = inputs["original_sizes"].tolist()
        with torch.no_grad():
            vision = model.get_vision_features(pixel_values=inputs["pixel_values"])
            for cls, prompts in PROMPTS.items():
                instances = np.zeros((image.height, image.width), dtype=np.float32)
                semantic = np.zeros((image.height, image.width), dtype=np.float32)
                for prompt in prompts:
                    text, mask = texts[prompt]
                    outputs = model(vision_embeds=vision, text_embeds=text, attention_mask=mask)
                    results = processor.post_process_instance_segmentation(
                        outputs, threshold=0.4, mask_threshold=0.5, target_sizes=size,
                    )[0]
                    for instance in results["masks"]:
                        instances = np.maximum(instances, instance.float().cpu().numpy())
                    presence = torch.sigmoid(outputs.presence_logits[0, 0]).item()
                    dense = torch.sigmoid(outputs.semantic_seg[0, 0]).float().cpu().numpy() * presence
                    dense = np.asarray(Image.fromarray(dense).resize((image.width, image.height), Image.BILINEAR))
                    semantic = np.maximum(semantic, dense)
                Image.fromarray((instances * 255).astype(np.uint8)).save(WORK / f"{render.stem}-sam3-{cls}.png")
                Image.fromarray((np.clip(semantic, 0, 1) * 255).astype(np.uint8)).save(WORK / f"{render.stem}-sam3sem-{cls}.png")
        times[render.stem] = round(time.perf_counter() - started, 2)
        print(f"{render.stem}: {times[render.stem]} s", flush=True)
    (WORK / "sam3-times.json").write_text(json.dumps(times, indent=2))


if __name__ == "__main__":
    main()
