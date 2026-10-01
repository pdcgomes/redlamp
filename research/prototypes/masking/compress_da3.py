#!/usr/bin/env python3
"""8-bit weights for the converted Depth Anything 3 model, checked against fp16 on the bake-off
renders (sky agreement and depth correlation).

    research/prototypes/masking/.venv-coreml/bin/python research/prototypes/masking/compress_da3.py
"""

import pathlib

import coremltools as ct
import coremltools.optimize.coreml as cto
import numpy as np
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parents[3]
SOURCE = ROOT / "build/models/DepthAnything3MonoLarge.mlpackage"
DESTINATION = ROOT / "build/models/DepthAnything3MonoLargeW8.mlpackage"


def main():
    full = ct.models.MLModel(str(SOURCE), compute_units=ct.ComputeUnit.CPU_AND_GPU)
    config = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8"))
    compressed = cto.linear_quantize_weights(full, config=config)
    compressed.save(str(DESTINATION))
    compressed = ct.models.MLModel(str(DESTINATION), compute_units=ct.ComputeUnit.CPU_AND_GPU)
    work = ROOT / "build/masking-bakeoff"
    renders = sorted(p for p in work.glob("*.png") if (work / f"{p.stem}-classical.png").exists())
    agreements, correlations = [], []
    for render in renders:
        image = Image.open(render).convert("RGB").resize((504, 336), Image.BICUBIC)
        a = full.predict({"image": image})
        b = compressed.predict({"image": image})
        agreements.append(((a["sky"] >= 0.5) == (b["sky"] >= 0.5)).mean())
        correlations.append(np.corrcoef(a["depth"].ravel(), b["depth"].ravel())[0, 1])
    print(f"{len(renders)} renders: sky agreement min {min(agreements):.4f}, depth correlation min {min(correlations):.4f}")


if __name__ == "__main__":
    main()
