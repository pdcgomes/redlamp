#!/usr/bin/env python3
"""8-bit weights for the converted ViTMatte-base (MSK-32), in blocks of 32, checked against fp16
on a tile of DSC02005's hair, with the time a tile takes on the GPU and with every compute unit.
One scale per output channel (int8 per channel) differed from fp16 by 0.028 on average and 0.28
at worst over the unsure pixels; one per block of 32 weights by 0.0018 and 0.035, at 104 MB
(a few small layers whose sizes don't divide by 32 stay fp16).

    research/prototypes/masking/.venv-coreml/bin/python research/prototypes/masking/compress_vitmatte.py

Reads build/models/ViTMatteBase-1024.mlpackage (convert_vitmatte.py), writes
build/models/ViTMatteBaseW8-1024.mlpackage. `vitmatte_bench.py --coreml` scores either on the
heads.
"""

import pathlib
import sys
import time

import coremltools as ct
import coremltools.optimize.coreml as cto
import numpy as np

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from convert_vitmatte import portrait_tile  # noqa: E402

MODELS = pathlib.Path(__file__).resolve().parents[3] / "build/models"
SOURCE = MODELS / "ViTMatteBase-1024.mlpackage"
DESTINATION = MODELS / "ViTMatteBaseW8-1024.mlpackage"


def timed(model, feed):
    model.predict(feed)
    started = time.perf_counter()
    for _ in range(3):
        alpha = model.predict(feed)["alpha"][0, 0]
    return alpha, (time.perf_counter() - started) / 3


def main():
    config = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(
        mode="linear_symmetric", dtype="int8", granularity="per_block", block_size=32,
    ))
    cto.linear_quantize_weights(ct.models.MLModel(str(SOURCE)), config=config).save(str(DESTINATION))
    image, tri = portrait_tile()
    feed = {
        "image": (image.astype(np.float32) / 255).transpose(2, 0, 1)[None],
        "trimap": tri.astype(np.float32)[None, None],
    }
    unsure = tri == 0.5
    results = {}
    for path in (SOURCE, DESTINATION):
        for units in (ct.ComputeUnit.CPU_AND_GPU, ct.ComputeUnit.ALL):
            alpha, seconds = timed(ct.models.MLModel(str(path), compute_units=units), feed)
            results[(path.name, units.name)] = alpha
            print(f"{path.name} on {units.name}: {seconds * 1000:.0f} ms a tile")
    full = results[(SOURCE.name, "CPU_AND_GPU")]
    for key, alpha in results.items():
        difference = np.abs(alpha - full)[unsure]
        print(f"{key[0]} on {key[1]} against fp16 on the GPU: mean {difference.mean():.4f}, worst {difference.max():.3f}")


if __name__ == "__main__":
    main()
