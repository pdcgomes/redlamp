#!/usr/bin/env python3
"""People parts, a second look: SAM 3 again on a crop around each part the whole photo found.

A moustache is a few cells of the decoder's 288 × 288 output on the whole photo, so its mask is a
blob over the lip. Re-encoding a padded square around the part gives it the full 1008 × 1008
input; the zoomed map is kept only near the first one (another person's hair in the crop stays
out). Needs sam3_people_parts.py's whole-photo maps.

    research/prototypes/masking/.venv-sam3-coreml/bin/python research/prototypes/masking/sam3_part_zoom.py

Writes build/people-parts/<photo>-zoom-<part>.png and <photo>-zoom-sheet.jpg (whole photo on the
left, zoomed on the right, around the part).
"""

import pathlib
import sys
import time

import coremltools as ct
import numpy as np
from PIL import Image
from scipy import ndimage

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from sam3_people_parts import EDGES, MODELS, PARTS, SIZE, WORK, resized, text_features  # noqa: E402

ZOOMED = ["hair", "facial-hair"]


def box(mask, size, pad=0.35):
    ys, xs = np.nonzero(mask > 0.5)
    if xs.size == 0:
        return None
    side = int(max(xs.max() - xs.min(), ys.max() - ys.min()) * (1 + 2 * pad))
    side = max(min(side, *size), 64)
    cx, cy = (xs.min() + xs.max()) // 2, (ys.min() + ys.max()) // 2
    left = int(np.clip(cx - side // 2, 0, size[0] - side))
    top = int(np.clip(cy - side // 2, 0, size[1] - side))
    return left, top, side


def main():
    prompts = text_features()
    units = ct.ComputeUnit.CPU_AND_GPU
    encoder = ct.models.MLModel(str(MODELS / "Sam3ImageEncoder.mlpackage"), compute_units=units)
    decoder = ct.models.MLModel(str(MODELS / "Sam3TextDecoder.mlpackage"), compute_units=units)
    for name in sys.argv[1:] or ["DSC02005", "DSC03301", "DSC02424"]:
        image = Image.open(EDGES / f"{name}.jpg").convert("RGB")
        panels = []
        for part in ZOOMED:
            whole = sum(np.asarray(Image.open(WORK / f"{name}-whole-{part}-{k}.png"), np.float32) / 255
                        for k in ("instances", "semantic")) / 2
            found = box(whole, image.size)
            if found is None:
                continue
            left, top, side = found
            started = time.perf_counter()
            crop = image.crop((left, top, left + side, top + side))
            levels = encoder.predict({"image": crop.resize((SIZE, SIZE), Image.BILINEAR)})
            instances = np.zeros((288, 288), np.float32)
            semantic = np.zeros((288, 288), np.float32)
            for text in PARTS[part]:
                features, mask = prompts[text]
                out = decoder.predict({**{f"fpn{i}": levels[f"fpn{i}"] for i in range(3)},
                                       "text": features, "textMask": mask})
                instances = np.maximum(instances, out["instances"][0, 0])
                semantic = np.maximum(semantic, out["semantic"][0, 0])
            zoomed = np.zeros_like(whole)
            zoomed[top:top + side, left:left + side] = resized((instances + semantic) / 2, (side, side))
            near = ndimage.binary_dilation(whole > 0.25, iterations=max(4, side // 40))
            zoomed *= near
            print(f"{name} {part}: crop {side}px, {time.perf_counter() - started:.2f} s, "
                  f"cover whole {(whole > 0.5).mean():.4f} zoomed {(zoomed > 0.5).mean():.4f}", flush=True)
            Image.fromarray((zoomed * 255).astype(np.uint8)).save(WORK / f"{name}-zoom-{part}.png")
            region = (left, top, left + side, top + side)
            base = np.asarray(image.crop(region), np.float32)
            for values in (whole, zoomed):
                alpha = values[top:top + side, left:left + side, None] * 0.6
                tinted = base * (1 - alpha) + np.array((255, 0, 200), np.float32) * alpha
                panels.append(Image.fromarray(np.clip(tinted, 0, 255).astype(np.uint8)).resize((512, 512)))
        sheet = Image.new("RGB", (1024, 512 * (len(panels) // 2)))
        for i, panel in enumerate(panels):
            sheet.paste(panel, ((i % 2) * 512, (i // 2) * 512))
        sheet.save(WORK / f"{name}-zoom-sheet.jpg", quality=88)


if __name__ == "__main__":
    main()
