#!/usr/bin/env python3
"""8-bit weights for the converted Depth Anything 3 models, checked against fp16 on the bake-off
renders (sky agreement and depth correlation), merged into one package with a `landscape`
(default) and a `portrait` function. Their weights are identical, so the package stores them once.

    research/prototypes/masking/.venv-coreml/bin/python research/prototypes/masking/compress_da3.py
"""

import pathlib
import shutil

import coremltools as ct
import coremltools.optimize.coreml as cto
import numpy as np
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parents[3]
MODELS = ROOT / "build/models"
DESTINATION = MODELS / "DepthAnything3MonoLargeW8.mlpackage"
SIZES = {"landscape": (504, 336), "portrait": (336, 504)}


def compress(orientation):
    source = MODELS / f"DepthAnything3MonoLarge-{orientation}.mlpackage"
    destination = MODELS / f"DepthAnything3MonoLargeW8-{orientation}.mlpackage"
    full = ct.models.MLModel(str(source), compute_units=ct.ComputeUnit.CPU_AND_GPU)
    config = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8"))
    cto.linear_quantize_weights(full, config=config).save(str(destination))
    compressed = ct.models.MLModel(str(destination), compute_units=ct.ComputeUnit.CPU_AND_GPU)
    work = ROOT / "build/masking-bakeoff"
    renders = sorted(p for p in work.glob("*.png") if (work / f"{p.stem}-classical.png").exists())
    agreements, correlations = [], []
    for render in renders:
        image = Image.open(render).convert("RGB").resize(SIZES[orientation], Image.BICUBIC)
        a = full.predict({"image": image})
        b = compressed.predict({"image": image})
        agreements.append(((a["sky"] >= 0.5) == (b["sky"] >= 0.5)).mean())
        correlations.append(np.corrcoef(a["depth"].ravel(), b["depth"].ravel())[0, 1])
    print(f"{orientation}, {len(renders)} renders: sky agreement min {min(agreements):.4f}, "
          f"depth correlation min {min(correlations):.4f}")
    return destination


def main():
    parts = {orientation: compress(orientation) for orientation in SIZES}
    descriptor = ct.utils.MultiFunctionDescriptor()
    for orientation, path in parts.items():
        descriptor.add_function(str(path), src_function_name="main", target_function_name=orientation)
    descriptor.default_function_name = "landscape"
    if DESTINATION.exists():
        shutil.rmtree(DESTINATION)
    ct.utils.save_multifunction(descriptor, str(DESTINATION))
    size = sum(f.stat().st_size for f in DESTINATION.rglob("*") if f.is_file())
    print(f"{DESTINATION}: {size / 1e6:.0f} MB")
    for orientation, (width, height) in SIZES.items():
        model = ct.models.MLModel(str(DESTINATION), function_name=orientation, compute_units=ct.ComputeUnit.CPU_AND_GPU)
        out = model.predict({"image": Image.new("RGB", (width, height), (120, 160, 220))})
        print(f"  {orientation}: sky {out['sky'].shape}, depth {out['depth'].shape}")


if __name__ == "__main__":
    main()
