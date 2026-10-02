#!/usr/bin/env python3
"""The Core ML conversion of SAM 3 (convert_sam3.py) on the Landscape bake-off, on the GPU.

    research/prototypes/masking/.venv-sam3-coreml/bin/python research/prototypes/masking/sam3_coreml_landscape.py

Encodes each analysis render once (squashed to 1008 × 1008), decodes every prompt from the
precomputed text features (Sam3Prompts.bin), and writes the two candidates sam3_landscape.py
writes from PyTorch, as coreml (instances) and coremlsem (semantic): build/landscape-bakeoff/
<photo>-coreml-<class>.png and -coremlsem-.
"""

import json
import pathlib
import time

import coremltools as ct
import numpy as np
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parents[3]
MODELS = ROOT / "build/models"
WORK = ROOT / "build/landscape-bakeoff"
SIZE = 1008


def prompts():
    index = json.loads((MODELS / "Sam3Prompts.json").read_text())
    blob = (MODELS / "Sam3Prompts.bin").read_bytes()
    out = {}
    for prompt, entry in index.items():
        features = int(np.prod(entry["features"]))
        mask = int(np.prod(entry["mask"]))
        values = np.frombuffer(blob, dtype=np.float16, count=features + mask, offset=entry["offset"])
        out.setdefault(entry["class"], []).append((
            values[:features].reshape(entry["features"]).astype(np.float32),
            values[features:].reshape(entry["mask"]).astype(np.int32),
        ))
    return out


def main():
    units = ct.ComputeUnit.CPU_AND_GPU
    encoder = ct.models.MLModel(str(MODELS / "Sam3ImageEncoder.mlpackage"), compute_units=units)
    decoder = ct.models.MLModel(str(MODELS / "Sam3TextDecoder.mlpackage"), compute_units=units)
    classes = prompts()
    renders = sorted(p for p in WORK.glob("*.png") if (WORK / f"{p.stem}-reference-water.png").exists())
    times = {}
    for render in renders:
        image = Image.open(render).convert("RGB")
        started = time.perf_counter()
        levels = encoder.predict({"image": image.resize((SIZE, SIZE), Image.BILINEAR)})
        for cls, entries in classes.items():
            instances = np.zeros((288, 288), np.float32)
            semantic = np.zeros((288, 288), np.float32)
            for text, mask in entries:
                out = decoder.predict({"fpn0": levels["fpn0"], "fpn1": levels["fpn1"], "fpn2": levels["fpn2"],
                                       "text": text, "textMask": mask})
                instances = np.maximum(instances, out["instances"][0, 0])
                semantic = np.maximum(semantic, out["semantic"][0, 0])
            for name, values in (("coreml", instances), ("coremlsem", semantic)):
                full = Image.fromarray(np.clip(values, 0, 1).astype(np.float32)).resize(image.size, Image.BILINEAR)
                Image.fromarray((np.asarray(full) * 255).astype(np.uint8)).save(WORK / f"{render.stem}-{name}-{cls}.png")
        times[render.stem] = round(time.perf_counter() - started, 2)
        print(f"{render.stem}: {times[render.stem]} s", flush=True)
    (WORK / "coreml-times.json").write_text(json.dumps(times, indent=2))


if __name__ == "__main__":
    main()
