"""Shared helpers for the Core ML timing prototypes."""

import collections
import json
import pathlib
import statistics
import time

import coremltools as ct
import numpy as np
from coremltools.models.compute_plan import MLComputePlan

COMPUTE_UNITS = {
    "cpuOnly": ct.ComputeUnit.CPU_ONLY,
    "cpuAndGPU": ct.ComputeUnit.CPU_AND_GPU,
    "cpuAndNeuralEngine": ct.ComputeUnit.CPU_AND_NE,
    "all": ct.ComputeUnit.ALL,
}

ROOT = pathlib.Path(__file__).resolve().parents[3]
DATA = ROOT / "build" / "proto-data"
OUT = ROOT / "build" / "proto-out"


def median_ms(fn, runs: int, warmup: int = 2) -> tuple[float, float]:
    """Median and p90 wall-clock milliseconds of `fn` after `warmup` calls."""
    for _ in range(warmup):
        fn()
    samples = []
    for _ in range(runs):
        t0 = time.perf_counter()
        fn()
        samples.append((time.perf_counter() - t0) * 1000)
    samples.sort()
    return statistics.median(samples), samples[min(len(samples) - 1, int(0.9 * len(samples)))]


def compile_once(package: pathlib.Path) -> pathlib.Path:
    """Compile an .mlpackage to a stable .mlmodelc next to it, so repeated loads can hit the OS cache."""
    compiled = package.with_suffix(".mlmodelc")
    if not compiled.exists():
        ct.utils.compile_model(str(package), str(compiled))
    return compiled


def load_timed(compiled: pathlib.Path, units: str):
    t0 = time.perf_counter()
    model = ct.models.CompiledMLModel(str(compiled), compute_units=COMPUTE_UNITS[units])
    return model, time.perf_counter() - t0


def placement(compiled: pathlib.Path, units: str) -> dict:
    """Count ML Program ops by the compute device Core ML prefers for them."""
    plan = MLComputePlan.load_from_path(str(compiled), compute_units=COMPUTE_UNITS[units])
    counts: collections.Counter = collections.Counter()
    cost: collections.Counter = collections.Counter()
    program = plan.model_structure.program
    for function in program.functions.values():
        for op in function.block.operations:
            usage = plan.get_compute_device_usage_for_mlprogram_operation(op)
            if usage is None:
                continue
            device = type(usage.preferred_compute_device).__name__.replace("ML", "").replace("ComputeDevice", "")
            counts[device] += 1
            estimate = plan.get_estimated_cost_for_mlprogram_operation(op)
            if estimate is not None:
                cost[device] += estimate.weight
    total_cost = sum(cost.values()) or 1.0
    return {
        "ops": dict(counts),
        "costShare": {k: round(v / total_cost, 3) for k, v in cost.items()},
    }


def psnr(a: np.ndarray, b: np.ndarray, peak: float = 1.0) -> float:
    mse = float(np.mean((a.astype(np.float64) - b.astype(np.float64)) ** 2))
    return float("inf") if mse == 0 else 10 * np.log10(peak * peak / mse)


def write_json(name: str, payload: dict) -> pathlib.Path:
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / name
    path.write_text(json.dumps(payload, indent=2))
    return path
