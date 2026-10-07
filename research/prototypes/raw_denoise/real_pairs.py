"""Real noise: RawNIND clean and noisy frames of the same tripod scene (fetch_rawnind.py).

For each scene and ISO: crop the same detailed SIZE x SIZE window (keeping the CFA phase), match the
noisy frame's exposure to the clean one per colour, and fit its Poisson-Gaussian profile from the
difference (as a calibrated profile would give it). Then render through Redlamp (run_redlamp's
harness) with and without the pre-demosaic prototype, and score two ways:

- full resolution, against the clean frame through Redlamp's own demosaic (fair between noise
  reduction methods that share that demosaic)
- binned to full colour (2 x 2 Bayer, 3 x 3 X-Trans) against the clean frame binned the same way
  (fair between different demosaics, but blind to the finest detail)

    python real_pairs.py prepare && python real_pairs.py run --worktree ../../../../darkroom-rawdn
    python real_pairs.py score
"""

import argparse
import json
import os

import numpy as np
import rawpy
from scipy.ndimage import gaussian_filter, uniform_filter
from skimage.metrics import structural_similarity

from common import DATA, OUT, SIZE, read_json, save_f32, write_json
from prototype import blend, cfa_nlm
from run_redlamp import H, run

RAWNIND = DATA / "rawnind"
REAL = OUT / "real"

# Pairs whose frames don't match closely enough to serve as ground truth.
EXCLUDE = {
    "bayer-Bark": "the best alignment lies at the edge of the search (the frames moved)",
    "xtrans-tree1": "an outdoor tree moving between frames (the fitted read noise collapses to zero)",
}

RENDERS = {
    "rl-none": {}, "rl-c25": {"color": 25}, "rl-l25": {"luminance": 25, "color": 25},
    "rl-l50": {"luminance": 50, "color": 25}, "rl-l75": {"luminance": 75, "color": 25},
}


def load(path):
    raw = rawpy.imread(str(path))
    data = raw.raw_image_visible.astype(np.float32)
    colors = raw.raw_colors_visible.copy()
    colors[colors == 3] = 1
    black = np.array(raw.black_level_per_channel, np.float32)[raw.raw_colors_visible]
    tile = raw.raw_pattern.shape[0]
    wb = np.array(raw.camera_whitebalance[:3], np.float64)
    return (data - black) / (raw.white_level - black), colors, tile, wb / wb[1]


def bin_rgb(mosaic, colors, b):
    h, w = (mosaic.shape[0] // b) * b, (mosaic.shape[1] // b) * b
    blocks = lambda a: a[:h, :w].reshape(h // b, b, w // b, b).transpose(0, 2, 1, 3).reshape(h // b, w // b, b * b)
    v, k = blocks(mosaic), blocks(colors)
    return np.stack([(v * (k == c)).sum(-1) / np.maximum((k == c).sum(-1), 1) for c in range(3)], -1)


def choose_window(gt, colors, tile):
    b = 2 if tile == 2 else 3
    rgb = bin_rgb(gt, colors, b)
    luma = rgb.mean(-1)
    lap = np.abs(luma - gaussian_filter(luma, 1.5))
    n = SIZE // b
    best, where = -1, (0, 0)
    for y in range(n // 2, luma.shape[0] - n - n // 2, n // 4):
        for x in range(n // 2, luma.shape[1] - n - n // 2, n // 4):
            if np.percentile(rgb[y:y + n, x:x + n], 99.5) > 0.85:
                continue
            e = lap[y:y + n, x:x + n].mean()
            if e > best:
                best, where = e, (y, x)
    # Back to photosites, on a multiple of 6 so the tile's phase is the same as the frame's.
    return where[0] * b // 6 * 6, where[1] * b // 6 * 6


def best_shift(gt, noisy, tile, y0, x0):
    """The lattice shift (whole tiles) that best aligns the noisy crop with the clean one."""
    step = 2 if tile == 2 else 6
    ref = uniform_filter(gt[y0:y0 + SIZE, x0:x0 + SIZE], step)
    best, shift = np.inf, (0, 0)
    for dy in range(-12, 13, step):
        for dx in range(-12, 13, step):
            cand = uniform_filter(noisy[y0 + dy:y0 + dy + SIZE, x0 + dx:x0 + dx + SIZE], step)
            e = np.mean(((cand - ref) / (ref.mean() + 1e-6))[24:-24, 24:-24] ** 2)
            if e < best:
                best, shift = e, (dy, dx)
    return shift


def fit_profile(gt, noisy, colors):
    """Per colour: the exposure gain, then variance = a * signal + b by weighted least squares."""
    gains, a_s, b_s = [], [], []
    smooth_gt = gaussian_filter(gt, 3)
    smooth_noisy = gaussian_filter(noisy, 3)
    for c in range(3):
        m = colors == c
        g = float(np.sum(smooth_noisy[m] * smooth_gt[m]) / max(np.sum(smooth_gt[m] ** 2), 1e-12))
        gains.append(g)
    gain_map = np.array(gains, np.float32)[colors]
    matched = noisy / gain_map
    residual = matched - gt
    for c in range(3):
        m = (colors == c)
        x, r = gt[m], residual[m]
        edges = np.quantile(x, np.linspace(0.02, 0.98, 25))
        centres, variances, counts = [], [], []
        for lo, hi in zip(edges[:-1], edges[1:]):
            sel = (x >= lo) & (x < hi)
            if sel.sum() > 500:
                centres.append(x[sel].mean())
                variances.append(np.var(r[sel]))
                counts.append(sel.sum())
        A = np.stack([centres, np.ones(len(centres))], 1)
        w = np.array(counts) / np.maximum(np.array(variances), 1e-12) ** 2
        coef = np.linalg.lstsq(A * np.sqrt(w)[:, None], np.array(variances) * np.sqrt(w), rcond=None)[0]
        a_s.append(float(max(coef[0], 1e-7)))
        b_s.append(float(max(coef[1], 1e-9)))
    return matched.astype(np.float32), gains, a_s, b_s


def job(name, path, cfa_tile, a, b, wb, renders, out_dir):
    return {
        "name": name, "mosaic": str(path), "width": SIZE, "height": SIZE,
        "cfa": [int(v) for v in cfa_tile.flatten()], "cfaWidth": cfa_tile.shape[1], "cfaHeight": cfa_tile.shape[0],
        "noiseA": a, "noiseB": b, "asShot": [float(v) for v in wb], "demosaic": "menon", "dual": True,
        "renders": [{"out": str(out_dir / f"{k}.f32"), "settings": v} for k, v in renders.items()],
    }


def prepare():
    subset = read_json(RAWNIND / "subset.json")
    jobs, meta = [], {}
    for entry in subset:
        name = f"{entry['cfa'].lower().replace('-', '')}-{entry['scene']}"
        if name in EXCLUDE:
            continue
        gt, colors, tile, wb = load(RAWNIND / entry["gt"])
        y0, x0 = choose_window(gt, colors, tile)
        crop = lambda a, dy=0, dx=0: a[y0 + dy:y0 + dy + SIZE, x0 + dx:x0 + dx + SIZE]
        cfa_tile = colors[y0:y0 + tile, x0:x0 + tile]
        gtc, colc = crop(gt), crop(colors)
        base = REAL / name
        save_f32(base / "gt.f32", gtc)
        np.save(base / "colors.npy", colc)
        jobs.append(job(f"{name}-gt", base / "gt.f32", cfa_tile, [2e-5] * 3, [5e-7] * 3, wb,
                        {"clean-none": {}}, base))
        meta[name] = {"cfa": entry["cfa"], "tile": tile, "origin": [int(x0), int(y0)], "isos": {}}
        for iso, file in entry["noisy"].items():
            noisy, _, _, _ = load(RAWNIND / file)
            dy, dx = best_shift(gt, noisy, tile, y0, x0)
            matched, gains, a, b = fit_profile(gtc, crop(noisy, dy, dx), colc)
            out = base / f"iso{iso}"
            save_f32(out / "noisy.f32", matched)
            jobs.append(job(f"{name}-{iso}", out / "noisy.f32", cfa_tile, a, b, wb, RENDERS, out))
            pattern = np.tile(cfa_tile, (SIZE // tile, SIZE // tile))
            assert np.array_equal(pattern, colc)
            # The prototype with one profile for every colour (the mean), as run_redlamp uses.
            a1, b1 = float(np.mean(a)), float(np.mean(b))
            denoised = cfa_nlm(matched, cfa_tile, a1, b1, h=H)
            expected = np.mean(np.array(a)[colc] * np.maximum(gtc, 0) + np.array(b)[colc])
            for variant, mosaic, renders in [
                ("pre-nlm", denoised, {"pre-nlm-c25": {"color": 25}}),
                ("pre-half", blend(matched, denoised, 0.5), {"pre-half-l25": {"luminance": 25, "color": 25}}),
            ]:
                residual = float(np.mean((mosaic - gtc)[16:-16, 16:-16] ** 2) / expected)
                path = out / f"{variant}.mosaic.f32"
                save_f32(path, mosaic)
                jobs.append(job(f"{name}-{iso}-{variant}", path, cfa_tile, [v * residual for v in a],
                                [v * residual for v in b], wb, renders, out))
            meta[name]["isos"][str(iso)] = {"shift": [dy, dx], "gains": gains, "a": a, "b": b, "file": file}
            print(name, iso, "shift", (dy, dx), "a", np.round(a, 6), "b", np.format_float_scientific(np.mean(b), 2))
    folder = REAL / "harness"
    write_json(folder / "jobs.json", jobs)
    write_json(REAL / "meta.json", meta)


def score():
    meta = read_json(REAL / "meta.json")
    rows = []
    enc = lambda x: np.sqrt(np.clip(x, 0, None))
    for name, m in meta.items():
        base = REAL / name
        b = 2 if m["tile"] == 2 else 3
        colc = np.load(base / "colors.npy")
        gt = np.fromfile(base / "gt.f32", "<f4").reshape(SIZE, SIZE)
        wb = None
        ref = np.fromfile(base / "clean-none.f32", "<f4").reshape(SIZE, SIZE, 3)
        # The binned reference, white-balanced like the renders (balanced camera RGB).
        gt_bin = bin_rgb(gt, colc, b)
        gain = np.array([ref[..., c].mean() / max(gt_bin[..., c].mean(), 1e-9) for c in range(3)])
        gt_bin = gt_bin * gain
        for iso in m["isos"]:
            for path in sorted((base / f"iso{iso}").glob("*.f32")):
                if path.name.endswith(".mosaic.f32") or path.name == "noisy.f32":
                    continue
                img = np.fromfile(path, "<f4").reshape(SIZE, SIZE, 3)
                a, r = enc(img)[16:-16, 16:-16], enc(ref)[16:-16, 16:-16]
                n = SIZE // b
                binned = img[:n * b, :n * b].reshape(n, b, n, b, 3).mean((1, 3))
                ab, rb = enc(binned)[8:-8, 8:-8], enc(gt_bin)[8:-8, 8:-8]
                hp = lambda x: x - uniform_filter(x, 3)
                la, lr = a.mean(-1), r.mean(-1)
                rows.append({
                    "scene": name, "cfa": m["cfa"], "iso": int(iso), "method": path.stem,
                    "cpsnr": float(10 * np.log10(1 / np.mean((a - r) ** 2))),
                    "ssim": float(structural_similarity(la, lr, data_range=1.0)),
                    "texture": float(np.sum(hp(la) * hp(lr)) / np.sum(hp(lr) ** 2)),
                    "cpsnr_binned": float(10 * np.log10(1 / np.mean((ab - rb) ** 2))),
                })
    (REAL / "scores.json").write_text(json.dumps(rows, indent=1))
    from collections import defaultdict
    table = defaultdict(list)
    for r in rows:
        level = "high" if r["iso"] == max(int(i) for i in meta[r["scene"]]["isos"]) else "lower"
        table[(r["cfa"], level, r["method"])].append(r)
    for key in sorted(table):
        v = table[key]
        print(key, f"n={len(v)} cpsnr {np.mean([x['cpsnr'] for x in v]):.2f} binned {np.mean([x['cpsnr_binned'] for x in v]):.2f} "
              f"ssim {np.mean([x['ssim'] for x in v]):.3f} texture {np.mean([x['texture'] for x in v]):.2f}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("step", choices=["prepare", "run", "score"])
    parser.add_argument("--worktree")
    args = parser.parse_args()
    if args.step == "prepare":
        prepare()
    elif args.step == "run":
        raise SystemExit(run(REAL / "harness", os.path.abspath(args.worktree)))
    else:
        score()
