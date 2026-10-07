"""SKIP-17: Bayer noise reduction at two process versions, on the DN-11 test set and the RawNIND Bayer
pairs.

SKIP-17 compared NR v1's Bayer noise table, measured through Malvar's demosaic (process 14), with the
same table measured through Menon's (an experimental process 15 that `NoiseCalibration.sigmas`
switched on, not kept): at equal texture kept they scored within 0.1 dB (DN-11 note, section 9).
It serves for any change that ships behind a new process version.

Every render goes through the harness (harness/RawDenoiseHarnessTests.swift) with the same mosaic,
noise profile and Detail panel settings; only the process version differs.

    python calibration_compare.py prepare
    python calibration_compare.py run --worktree ../../../../darkroom-xtrans
    python calibration_compare.py score

Synthetic scenes are scored against their truth (score.py), the real pairs against the clean frame
through Redlamp's own demosaic (real_pairs.py's full-resolution score).
"""

import argparse
import json
import os
from collections import defaultdict

import numpy as np
from scipy.ndimage import uniform_filter

from common import AS_SHOT, BAYER, NOISE_LEVELS, OUT, SIZE, TESTSET, load_rgb, read_json, write_json
from run_redlamp import run
from score import fidelity, flat_noise

COMPARE = OUT / "dn15"
REAL = OUT / "real"
PROCESSES = [14, 15]
SETTINGS = {
    "c25": {"color": 25},
    "c50": {"color": 50},
    "c75": {"color": 75},
    "l25": {"luminance": 25, "color": 25},
    "l50": {"luminance": 50, "color": 25},
    "l75": {"luminance": 75, "color": 25},
    "l100": {"luminance": 100, "color": 50},
}


def renders(out_dir):
    return [{"out": str(out_dir / f"p{p}-{k}.f32"), "settings": s, "process": p}
            for p in PROCESSES for k, s in SETTINGS.items()]


def job(name, mosaic, cfa, a, b, wb, out_dir):
    return {
        "name": name, "mosaic": str(mosaic), "width": SIZE, "height": SIZE,
        "cfa": [int(v) for v in cfa.flatten()], "cfaWidth": cfa.shape[1], "cfaHeight": cfa.shape[0],
        "noiseA": a, "noiseB": b, "asShot": [float(v) for v in wb], "demosaic": "menon", "dual": True,
        "renders": renders(out_dir),
    }


def prepare():
    jobs = []
    manifest = read_json(TESTSET / "manifest.json")
    for scene in manifest["scenes"]:
        for level, (a, b) in NOISE_LEVELS.items():
            jobs.append(job(f"{scene}-{level}", TESTSET / scene / f"bayer-{level}.f32", BAYER, [a] * 3, [b] * 3,
                            AS_SHOT, COMPARE / "synthetic" / scene / level))
    meta = read_json(REAL / "meta.json")
    for name, m in meta.items():
        if m["tile"] != 2:
            continue
        cfa = np.load(REAL / name / "colors.npy")[:2, :2]
        wb = read_json(REAL / "harness" / "jobs.json")
        wb = next(j["asShot"] for j in wb if j["name"] == f"{name}-gt")
        for iso, info in m["isos"].items():
            jobs.append(job(f"{name}-{iso}", REAL / name / f"iso{iso}" / "noisy.f32", cfa, info["a"], info["b"], wb,
                            COMPARE / "real" / name / f"iso{iso}"))
    write_json(COMPARE / "harness" / "jobs.json", jobs)
    print(f"{len(jobs)} jobs, {sum(len(j['renders']) for j in jobs)} renders")


def score():
    enc = lambda x: np.sqrt(np.clip(x, 0, None))
    manifest = read_json(TESTSET / "manifest.json")
    rows = []
    for scene in manifest["scenes"]:
        truth = load_rgb(TESTSET / scene / "truth.f32", SIZE, SIZE)
        for level in NOISE_LEVELS:
            for p in PROCESSES:
                for k in SETTINGS:
                    img = load_rgb(COMPARE / "synthetic" / scene / level / f"p{p}-{k}.f32", SIZE, SIZE)
                    row = {"set": "synthetic", "scene": scene, "level": level, "process": p, "setting": k,
                           **fidelity(img, truth)}
                    if scene == "text":
                        row.update(flat_noise(img, truth, manifest["regions"]["text"]["flat"]))
                    rows.append(row)
    meta = read_json(REAL / "meta.json")
    for name, m in meta.items():
        if m["tile"] != 2:
            continue
        ref = np.fromfile(REAL / name / "clean-none.f32", "<f4").reshape(SIZE, SIZE, 3)
        top = max(int(i) for i in m["isos"])
        for iso in m["isos"]:
            for p in PROCESSES:
                for k in SETTINGS:
                    img = np.fromfile(COMPARE / "real" / name / f"iso{iso}" / f"p{p}-{k}.f32", "<f4")
                    img = img.reshape(SIZE, SIZE, 3)
                    a, r = enc(img)[16:-16, 16:-16], enc(ref)[16:-16, 16:-16]
                    hp = lambda x: x - uniform_filter(x, 3)
                    la, lr = a.mean(-1), r.mean(-1)
                    rows.append({
                        "set": "real", "scene": name, "level": "highest ISO" if int(iso) == top else "lower ISOs",
                        "process": p, "setting": k,
                        "cpsnr": float(10 * np.log10(1 / np.mean((a - r) ** 2))),
                        "texture": float(np.sum(hp(la) * hp(lr)) / np.sum(hp(lr) ** 2)),
                    })
    write_json(COMPARE / "scores.json", rows)

    table = defaultdict(list)
    for r in rows:
        table[(r["set"], r["level"], r["setting"], r["process"])].append(r)
    lines = ["# SKIP-17: Bayer noise table, process 14 (Malvar's) against 15 (Menon's)", "",
             "Colour PSNR (dB) / texture kept, means over scenes. Flat noise: the text scene's grey patch, "
             "luma / chroma.", ""]
    for group in ["synthetic", "real"]:
        levels = sorted({k[1] for k in table if k[0] == group})
        for level in levels:
            lines += [f"## {group}, {level}", "", "| Setting | Process 14 | Process 15 | Change |", "| --- | --- | --- | --- |"]
            for k in SETTINGS:
                cells = []
                for p in PROCESSES:
                    v = table[(group, level, k, p)]
                    cells.append((np.mean([x["cpsnr"] for x in v]), np.mean([x["texture"] for x in v])))
                (c14, t14), (c15, t15) = cells
                lines.append(f"| {k} | {c14:.2f} / {t14:.2f} | {c15:.2f} / {t15:.2f} | {c15 - c14:+.2f} dB / {t15 - t14:+.2f} |")
            if group == "synthetic":
                lines += ["", "| Setting | Flat noise, 14 | Flat noise, 15 |", "| --- | --- | --- |"]
                for k in SETTINGS:
                    f = [[x for x in table[(group, level, k, p)] if x["scene"] == "text"][0] for p in PROCESSES]
                    lines.append(f"| {k} | {f[0]['flat_luma_noise']:.4f} / {f[0]['flat_chroma_noise']:.4f} "
                                 f"| {f[1]['flat_luma_noise']:.4f} / {f[1]['flat_chroma_noise']:.4f} |")
            lines.append("")
    (COMPARE / "summary.md").write_text("\n".join(lines))
    print("\n".join(lines))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("step", choices=["prepare", "run", "score"])
    parser.add_argument("--worktree")
    args = parser.parse_args()
    if args.step == "prepare":
        prepare()
    elif args.step == "run":
        raise SystemExit(run(COMPARE / "harness", os.path.abspath(args.worktree)))
    else:
        score()
