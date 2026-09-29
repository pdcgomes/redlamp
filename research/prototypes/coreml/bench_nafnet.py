"""Convert NAFNet variants to Core ML and time them per compute unit.

Measures, per variant and tile size: load time, median/p90 prediction latency,
op placement from MLComputePlan, and output fidelity against the PyTorch fp32
reference (which is how cross-device reproducibility shows up in practice).

Usage:
  build/research-venv/bin/python research/prototypes/coreml/bench_nafnet.py [--quick]
"""

import argparse
import math
import pathlib
import sys

import coremltools as ct
import coremltools.optimize.coreml as cto
import numpy as np
import torch
from PIL import Image

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from common import DATA, OUT, compile_once, load_timed, median_ms, placement, psnr, write_json  # noqa: E402
from nafnet_arch import NAFNet  # noqa: E402

VARIANTS = {
    # sRGB model with the published SIDD weights (research-only data terms; timing and fidelity only).
    "srgb-w32-sidd": dict(img_channel=3, width=32),
    # Raw-domain shapes (packed Bayer, 4 channels) with random weights: latency does not depend on weights.
    "raw-w16": dict(img_channel=4, width=16),
    "raw-w32": dict(img_channel=4, width=32),
}
UNITS = ["cpuAndGPU", "cpuAndNeuralEngine", "all"]
OVERLAP = 32


def build(variant: str) -> tuple[torch.nn.Module, bool]:
    # Converted packages are cached on disk, so random weights must be identical across runs.
    torch.manual_seed(0)
    model = NAFNet(**VARIANTS[variant]).eval()
    trained = False
    weights = DATA / "NAFNet-SIDD-width32.pth"
    if variant == "srgb-w32-sidd" and weights.exists():
        state = torch.load(weights, map_location="cpu", weights_only=False)
        model.load_state_dict(state.get("params", state), strict=True)
        trained = True
    return model, trained


def convert(model: torch.nn.Module, channels: int, tile: int, path: pathlib.Path) -> pathlib.Path:
    if path.exists():
        return path
    example = torch.rand(1, channels, tile, tile)
    traced = torch.jit.trace(model, example)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="x", shape=example.shape, dtype=np.float16)],
        outputs=[ct.TensorType(name="y", dtype=np.float16)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS15,
    )
    mlmodel.save(str(path))
    return path


def compressed(base: pathlib.Path, kind: str) -> pathlib.Path:
    path = base.with_name(base.stem + f"-{kind}.mlpackage")
    if path.exists():
        return path
    model = ct.models.MLModel(str(base), skip_model_load=True)
    if kind == "pal8":
        config = cto.OptimizationConfig(global_config=cto.OpPalettizerConfig(mode="kmeans", nbits=8))
        model = cto.palettize_weights(model, config)
    elif kind == "pal6":
        config = cto.OptimizationConfig(global_config=cto.OpPalettizerConfig(mode="kmeans", nbits=6))
        model = cto.palettize_weights(model, config)
    elif kind == "int8":
        config = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric"))
        model = cto.linear_quantize_weights(model, config)
    model.save(str(path))
    return path


def test_input(channels: int, tile: int) -> tuple[np.ndarray, np.ndarray]:
    """A clean crop of an MIT-licensed test frame plus seeded Gaussian noise (sigma = 25/255)."""
    frame = Image.open(DATA / "stacks" / "pcb_000.JPG").convert("RGB")
    left, top = (frame.width - tile) // 2, (frame.height - tile) // 2
    clean = np.asarray(frame.crop((left, top, left + tile, top + tile)), dtype=np.float32) / 255.0
    clean = clean.transpose(2, 0, 1)[None]
    if channels == 4:
        clean = np.concatenate([clean, clean[:, 1:2]], axis=1)
    rng = np.random.default_rng(1234)
    noisy = np.clip(clean + rng.normal(0, 25 / 255, clean.shape), 0, 1).astype(np.float32)
    return clean, noisy


def tiles_for(width: int, height: int, tile: int) -> int:
    step = tile - 2 * OVERLAP
    return math.ceil(width / step) * math.ceil(height / step)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--quick", action="store_true", help="one tile size, fewer runs")
    args = parser.parse_args()
    tiles = [512] if args.quick else [256, 512]
    runs = 5 if args.quick else 12
    models_dir = OUT / "models"
    models_dir.mkdir(parents=True, exist_ok=True)
    results = []

    for variant in VARIANTS:
        model, trained = build(variant)
        channels = VARIANTS[variant]["img_channel"]
        params = sum(p.numel() for p in model.parameters())
        for tile in tiles:
            clean, noisy = test_input(channels, tile)
            with torch.no_grad():
                reference = model(torch.from_numpy(noisy)).numpy()
            base = convert(model, channels, tile, models_dir / f"nafnet-{variant}-{tile}.mlpackage")
            packages = {"fp16": base}
            if variant == "srgb-w32-sidd" and tile == 512:
                for kind in ("pal8", "pal6", "int8"):
                    packages[kind] = compressed(base, kind)

            for weights_kind, package in packages.items():
                compiled = compile_once(package)
                row = {
                    "variant": variant, "trainedWeights": trained, "params": params, "tile": tile,
                    "weights": weights_kind,
                    "packageMB": round(sum(f.stat().st_size for f in package.rglob("*") if f.is_file()) / 2**20, 1),
                    "placement": {u: placement(compiled, u) for u in ("cpuAndNeuralEngine", "all")},
                    "units": {},
                }
                outputs = {}
                for units in UNITS:
                    mlmodel, load_s = load_timed(compiled, units)
                    feed = {"x": noisy.astype(np.float16)}
                    median, p90 = median_ms(lambda: mlmodel.predict(feed), runs=runs)
                    out = mlmodel.predict(feed)["y"].astype(np.float32)
                    outputs[units] = out
                    sensor = (6000, 4000) if channels == 3 else (3000, 2000)
                    row["units"][units] = {
                        "loadSeconds": round(load_s, 2),
                        "medianMs": round(median, 1),
                        "p90Ms": round(p90, 1),
                        "est24MPSeconds": round(tiles_for(*sensor, tile) * median / 1000, 1),
                        "psnrVsTorchFp32": round(psnr(out, reference), 2),
                        "maxAbsVsTorchFp32": float(np.max(np.abs(out - reference))),
                    }
                    if trained:
                        row["units"][units]["denoisePsnr"] = round(psnr(np.clip(out, 0, 1), clean), 2)
                row["crossUnitPsnrGpuVsAne"] = round(psnr(outputs["cpuAndGPU"], outputs["cpuAndNeuralEngine"]), 2)
                if trained:
                    row["noisyInputPsnr"] = round(psnr(noisy, clean), 2)
                    row["torchFp32DenoisePsnr"] = round(psnr(np.clip(reference, 0, 1), clean), 2)
                results.append(row)
                print(f"{variant} tile={tile} {weights_kind}: " + ", ".join(
                    f"{u} {row['units'][u]['medianMs']} ms (load {row['units'][u]['loadSeconds']} s, "
                    f"PSNR vs fp32 {row['units'][u]['psnrVsTorchFp32']})" for u in UNITS), flush=True)

    path = write_json("nafnet-bench.json", {"machine": "Apple M1 Ultra", "results": results})
    print(f"wrote {path}")


if __name__ == "__main__":
    main()
