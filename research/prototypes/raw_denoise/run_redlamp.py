"""Renders the test set through Redlamp's real pipeline, with and without the pre-demosaic prototypes.

Writes the prototype mosaics, a jobs.json for the harness (harness/RawDenoiseHarnessTests.swift),
then runs the harness from a worktree where it has been copied into the engine's test target:

    python run_redlamp.py --worktree ../../../../darkroom-rawdn

Contestants per (scene, CFA, level), all through Redlamp's normalisation, hot-photosite repair and
demosaic (Menon with the dual blend for Bayer, the generic interpolation for X-Trans):

- rl-*: the noisy mosaic with the Detail panel's noise reduction at several settings
- rl-malvar-*: Bayer through Malvar, He & Cutler, for reference
- pre-nlm-*: the mosaic denoised by `prototype.cfa_nlm` first
- pre-half-*: the same, keeping half the noise for the Detail panel
- clean-none: the noise-free mosaic, demosaic only (the best Redlamp's demosaic can do)

When a prototype has run, the noise profile handed to Redlamp is the residual noise measured against
the clean mosaic (an oracle; a product would predict it).
"""

import argparse
import os
import subprocess
import time

import numpy as np

from common import AS_SHOT, CFAS, NOISE_LEVELS, OUT, SIZE, TESTSET, read_json, save_f32, write_json
from prototype import blend, cfa_nlm

H = 0.6

RL_RENDERS = {
    "none": {},
    "c25": {"color": 25},
    "l25": {"luminance": 25, "color": 25},
    "l50": {"luminance": 50, "color": 25},
    "l75": {"luminance": 75, "color": 25},
    "l100": {"luminance": 100, "color": 50},
}
PRE_RENDERS = {"none": {}, "c25": {"color": 25}, "l25": {"luminance": 25, "color": 25}}
HALF_RENDERS = {"c25": {"color": 25}, "l25": {"luminance": 25, "color": 25}, "l50": {"luminance": 50, "color": 25}}


def job(name, mosaic_path, cfa_name, a, b, renders, out_dir, demosaic="menon"):
    cfa = CFAS[cfa_name]
    return {
        "name": name, "mosaic": str(mosaic_path), "width": SIZE, "height": SIZE,
        "cfa": [int(v) for v in cfa.flatten()], "cfaWidth": cfa.shape[1], "cfaHeight": cfa.shape[0],
        "noiseA": [a] * 3, "noiseB": [b] * 3, "asShot": list(AS_SHOT), "demosaic": demosaic, "dual": True,
        "renders": [{"out": str(out_dir / f"{prefix}.f32"), "settings": s} for prefix, s in renders.items()],
    }


def prepare(only=None):
    manifest = read_json(TESTSET / "manifest.json")
    jobs, timings = [], {}
    for scene in manifest["scenes"]:
        if only and scene not in only:
            continue
        for cfa_name in CFAS:
            clean = np.fromfile(TESTSET / scene / f"{cfa_name}-clean.f32", "<f4").reshape(SIZE, SIZE)
            base = OUT / "renders" / scene / cfa_name
            a0, b0 = NOISE_LEVELS["iso3200"]
            jobs.append(job(f"{scene}-{cfa_name}-clean", TESTSET / scene / f"{cfa_name}-clean.f32", cfa_name,
                            a0, b0, {"clean-none": {}}, base))
            for level, (a, b) in NOISE_LEVELS.items():
                path = TESTSET / scene / f"{cfa_name}-{level}.f32"
                out = base / level
                jobs.append(job(f"{scene}-{cfa_name}-{level}", path, cfa_name, a, b,
                                {f"rl-{k}": v for k, v in RL_RENDERS.items()}, out))
                if cfa_name == "bayer":
                    jobs.append(job(f"{scene}-{cfa_name}-{level}-malvar", path, cfa_name, a, b,
                                    {"rl-malvar-none": {}, "rl-malvar-l50": RL_RENDERS["l50"]}, out, "malvar"))
                noisy = np.fromfile(path, "<f4").reshape(SIZE, SIZE)
                started = time.perf_counter()
                denoised = cfa_nlm(noisy, CFAS[cfa_name], a, b, h=H)
                timings[f"{scene}-{cfa_name}-{level}"] = time.perf_counter() - started
                expected = np.mean(a * np.maximum(clean, 0) + b)
                for variant, mosaic, renders in [
                    ("pre-nlm", denoised, PRE_RENDERS),
                    ("pre-half", blend(noisy, denoised, 0.5), HALF_RENDERS),
                ]:
                    residual = float(np.mean((mosaic - clean)[16:-16, 16:-16] ** 2) / expected)
                    mpath = OUT / "mosaics" / scene / cfa_name / f"{level}-{variant}.f32"
                    save_f32(mpath, mosaic)
                    jobs.append(job(f"{scene}-{cfa_name}-{level}-{variant}", mpath, cfa_name,
                                    a * residual, b * residual,
                                    {f"{variant}-{k}": v for k, v in renders.items()}, out))
    folder = OUT / "harness"
    write_json(folder / "jobs.json", jobs)
    write_json(OUT / "prototype-timings.json", timings)
    return folder


def run(folder, worktree):
    env = dict(os.environ, TEST_RUNNER_REDLAMP_RAWDN_DIR=str(folder))
    command = [
        "mise", "exec", "--", "xcodebuild", "test-without-building", "-workspace", "Redlamp.xcworkspace",
        "-scheme", "RedlampEngine", "-destination", "platform=macOS,arch=arm64",
        "-derivedDataPath", os.path.join(worktree, "build/DerivedData-rawdn"), "-only-testing:RedlampEngineTests/RawDenoiseHarnessTests",
    ]
    result = subprocess.run(command, cwd=worktree, env=env, capture_output=True, text=True)
    log = OUT / "harness.log"
    log.write_text(result.stdout + result.stderr)
    tail = [line for line in result.stdout.splitlines() if "Test run" in line or "passed" in line or "failed" in line]
    print("\n".join(tail[-5:]))
    return result.returncode


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--worktree", required=True)
    parser.add_argument("--only", nargs="*")
    args = parser.parse_args()
    folder = prepare(args.only)
    raise SystemExit(run(folder, os.path.abspath(args.worktree)))
