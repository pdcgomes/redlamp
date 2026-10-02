#!/usr/bin/env python3
"""People parts by SAM 3's text prompts, on the Core ML conversion (convert_sam3.py).

Lightroom's People parts that Vision can't give on a camera photo: Hair (Vision's hair matte
comes only with iPhone portraits), Facial Hair, Body Skin and Clothes. Each part is a few
prompts, decoded from one encoding; two framings are compared: the whole photo squashed to
1008 × 1008 (what Landscape does), and a square crop around each person (from Vision's person
mask), so a beard isn't a few cells of the 288 × 288 output.

    research/prototypes/masking/.venv-sam3-coreml/bin/python research/prototypes/masking/sam3_people_parts.py

Writes build/people-parts/<photo>-<framing>-<part>-<instances|semantic>.png, an overlay sheet
per photo, and times.json.
"""

import json
import pathlib
import sys
import time

import coremltools as ct
import numpy as np
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parents[3]
MODELS = ROOT / "build/models"
EDGES = ROOT / "build/edge-cases"
WORK = ROOT / "build/people-parts"
SIZE = 1008
PARTS = {
    "hair": ["hair"],
    "facial-hair": ["beard", "mustache", "facial hair"],
    "body-skin": ["skin", "arm", "hand", "neck", "leg"],
    "clothes": ["clothing", "shirt", "jacket", "dress", "trousers"],
    "face": ["face"],
}
PORTRAITS = {"DSC02005": "DSC02005-people.png", "DSC03301": "DSC03301-subject.png",
             "DSC02424": "DSC02424-people-1.png", "DSC01584": "DSC01584-people.png"}
COLOURS = {"hair": (255, 170, 0), "facial-hair": (255, 0, 200), "body-skin": (0, 220, 255),
           "clothes": (90, 255, 90), "face": (255, 255, 255)}


def text_features():
    """Each prompt's text features, from PyTorch's text encoder once, then from the cache."""
    cache = WORK / "prompts.npz"
    wanted = [p for prompts in PARTS.values() for p in prompts]
    if cache.exists():
        stored = np.load(cache)
        if all(f"{p}/features" in stored for p in wanted):
            return {p: (stored[f"{p}/features"], stored[f"{p}/mask"]) for p in wanted}
    import torch
    from transformers import Sam3Model, Sam3Processor

    model = Sam3Model.from_pretrained("facebook/sam3", torch_dtype=torch.float32).eval()
    processor = Sam3Processor.from_pretrained("facebook/sam3")
    out = {}
    for prompt in wanted:
        tokens = processor(text=prompt, return_tensors="pt")
        with torch.no_grad():
            features = model.get_text_features(input_ids=tokens["input_ids"], attention_mask=tokens["attention_mask"],
                                               return_dict=True).pooler_output
        out[prompt] = (features.numpy().astype(np.float16).astype(np.float32),
                       tokens["attention_mask"].numpy().astype(np.int32))
    np.savez(cache, **{f"{p}/features": f for p, (f, _) in out.items()}, **{f"{p}/mask": m for p, (_, m) in out.items()})
    return out


def person_box(mask, size, pad=0.12):
    """A square around the person, padded, clamped to the photo: (left, top, side)."""
    ys, xs = np.nonzero(mask > 0.5)
    left, right, top, bottom = xs.min(), xs.max(), ys.min(), ys.max()
    side = int(max(right - left, bottom - top) * (1 + 2 * pad))
    side = min(side, *size)
    cx, cy = (left + right) // 2, (top + bottom) // 2
    left = int(np.clip(cx - side // 2, 0, size[0] - side))
    top = int(np.clip(cy - side // 2, 0, size[1] - side))
    return left, top, side


def decode(encoder, decoder, image, prompts):
    levels = encoder.predict({"image": image.resize((SIZE, SIZE), Image.BILINEAR)})
    maps = {}
    for part, texts in PARTS.items():
        instances = np.zeros((288, 288), np.float32)
        semantic = np.zeros((288, 288), np.float32)
        for text in texts:
            features, mask = prompts[text]
            out = decoder.predict({"fpn0": levels["fpn0"], "fpn1": levels["fpn1"], "fpn2": levels["fpn2"],
                                   "text": features, "textMask": mask})
            instances = np.maximum(instances, out["instances"][0, 0])
            semantic = np.maximum(semantic, out["semantic"][0, 0])
        maps[part] = (instances, semantic)
    return maps


def resized(values, size):
    return np.asarray(Image.fromarray(np.clip(values, 0, 1).astype(np.float32)).resize(size, Image.BILINEAR))


def overlay(image, maps):
    base = np.asarray(image, np.float32) * 0.45
    for part, values in maps.items():
        if part == "face":
            continue
        alpha = values[..., None] * 0.65
        base = base * (1 - alpha) + np.array(COLOURS[part], np.float32) * alpha
    return Image.fromarray(np.clip(base, 0, 255).astype(np.uint8))


def main():
    WORK.mkdir(parents=True, exist_ok=True)
    prompts = text_features()
    units = ct.ComputeUnit.CPU_AND_GPU
    encoder = ct.models.MLModel(str(MODELS / "Sam3ImageEncoder.mlpackage"), compute_units=units)
    decoder = ct.models.MLModel(str(MODELS / "Sam3TextDecoder.mlpackage"), compute_units=units)
    names = sys.argv[1:] or list(PORTRAITS)
    times = {}
    for name in names:
        image = Image.open(EDGES / f"{name}.jpg").convert("RGB")
        person = np.asarray(Image.open(EDGES / PORTRAITS[name]).convert("L").resize(image.size), np.float32) / 255
        sheets = []
        for framing in ("whole", "crop"):
            started = time.perf_counter()
            if framing == "whole":
                maps = decode(encoder, decoder, image, prompts)
                full = {p: tuple(resized(v, image.size) for v in pair) for p, pair in maps.items()}
            else:
                left, top, side = person_box(person, image.size)
                crop = image.crop((left, top, left + side, top + side))
                maps = decode(encoder, decoder, crop, prompts)
                full = {}
                for p, pair in maps.items():
                    placed = []
                    for v in pair:
                        canvas = np.zeros((image.size[1], image.size[0]), np.float32)
                        canvas[top:top + side, left:left + side] = resized(v, (side, side))
                        placed.append(canvas)
                    full[p] = tuple(placed)
            times[f"{name}-{framing}"] = round(time.perf_counter() - started, 2)
            mean = {}
            for part, (instances, semantic) in full.items():
                for kind, values in (("instances", instances), ("semantic", semantic)):
                    Image.fromarray((values * 255).astype(np.uint8)).save(WORK / f"{name}-{framing}-{part}-{kind}.png")
                mean[part] = (instances + semantic) / 2
                coverage = {k: float((v > 0.5).mean()) for k, v in (("inst", instances), ("sem", semantic))}
                print(f"{name} {framing} {part}: {coverage}", flush=True)
            sheets.append(overlay(image, mean))
        sheet = Image.new("RGB", (image.size[0] * 2, image.size[1]))
        for i, s in enumerate(sheets):
            sheet.paste(s, (i * image.size[0], 0))
        sheet.resize((sheet.width // 2, sheet.height // 2)).save(WORK / f"{name}-sheet.jpg", quality=88)
    (WORK / "times.json").write_text(json.dumps(times, indent=2))
    print(times)


if __name__ == "__main__":
    main()
