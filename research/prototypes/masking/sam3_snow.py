#!/usr/bin/env python3
"""Snow for Landscape masks (MSK-22): which SAM 3 text prompts find snow, on CC0 snow photos.

    research/prototypes/masking/.venv-sam3-coreml/bin/python research/prototypes/masking/sam3_snow.py <folder>

For each photo in the folder (JPEGs) and each candidate prompt, the map the app makes of a
prompt (SAM3Concepts.map: the instances scoring over 0.4 merged, averaged with the dense semantic
map times the presence score) at 288 x 288. Writes <photo>-<prompt>.png beside the photos and
prints, for each prompt, the share of each photo it covers above 0.5.
"""

import pathlib
import sys

import numpy as np
import torch
from PIL import Image
from transformers import Sam3Model, Sam3Processor

CANDIDATES = ["snow", "snowy ground", "ice", "snowfield", "snow-covered mountain", "glacier", "snowcap", "frost"]
SIZE = 288


def main(folder):
    photos = sorted(p for p in folder.glob("*.jpg") if "-" in p.stem and not p.stem.endswith("sheet"))
    model = Sam3Model.from_pretrained("facebook/sam3", torch_dtype=torch.float32).eval()
    processor = Sam3Processor.from_pretrained("facebook/sam3")
    texts = {}
    with torch.no_grad():
        for prompt in CANDIDATES:
            tokens = processor(text=prompt, return_tensors="pt")
            texts[prompt] = (model.get_text_features(input_ids=tokens["input_ids"], attention_mask=tokens["attention_mask"],
                                                     return_dict=True), tokens["attention_mask"])
    print("prompt".ljust(24) + "".join(p.stem[:18].ljust(20) for p in photos))
    coverage = {prompt: [] for prompt in CANDIDATES}
    for photo in photos:
        image = Image.open(photo).convert("RGB").resize((1008, 1008))
        inputs = processor(images=image, return_tensors="pt")
        with torch.no_grad():
            vision = model.get_vision_features(pixel_values=inputs["pixel_values"])
            for prompt in CANDIDATES:
                text, mask = texts[prompt]
                outputs = model(vision_embeds=vision, text_embeds=text, attention_mask=mask)
                results = processor.post_process_instance_segmentation(
                    outputs, threshold=0.4, mask_threshold=0.5, target_sizes=[[SIZE, SIZE]],
                )[0]
                instances = np.zeros((SIZE, SIZE), dtype=np.float32)
                for instance in results["masks"]:
                    instances = np.maximum(instances, instance.float().numpy())
                presence = torch.sigmoid(outputs.presence_logits[0, 0]).item()
                dense = torch.sigmoid(outputs.semantic_seg[0, 0]).float().numpy() * presence
                dense = np.asarray(Image.fromarray(dense).resize((SIZE, SIZE), Image.BILINEAR))
                combined = (instances + dense) / 2
                Image.fromarray((np.clip(combined, 0, 1) * 255).astype(np.uint8)).save(
                    folder / f"{photo.stem}-{prompt.replace(' ', '_')}.png")
                coverage[prompt].append(float(np.mean(combined > 0.5)))
    for prompt in CANDIDATES:
        print(prompt.ljust(24) + "".join(f"{value:.3f}".ljust(20) for value in coverage[prompt]))


if __name__ == "__main__":
    main(pathlib.Path(sys.argv[1]))
