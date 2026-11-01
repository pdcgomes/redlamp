#!/usr/bin/env python3
"""Remove Reflections at the photo's full resolution (RM-22).

The model works at about a megapixel. Rather than upsample its output, this estimates the reflection
layer at the model's resolution and subtracts it from the full-size photo in linear light, which keeps
the photo's own detail and gives an Amount:

    1. I_w, the photo averaged down in linear light to the working size (short side --size), goes to
       the model sRGB-encoded; O_w, its output, comes back and is linearised.
    2. Drift: WindowSeat also brightens the transmitted scene, by 13 to 50% on the glass set's
       composites, as if it removed the glass's own loss of light. Each channel of O_w is scaled by
       the --quantile quantile of I_w / O_w over the well-exposed pixels, both smoothed: a reflection
       only ever adds light, so the low end of that ratio is where the photo has the least of it.
       --drift affine fits a·O_w + b on the lower envelope instead; --drift off leaves O_w as it is.
    3. R_w = max(I_w − O', 0), smoothed by --smooth working pixels (2 by default): what differs at
       the finest scale of the working image is mostly the model's own texture, not reflection.
    4. Clipped highlights: --clip exclude leaves the clipped share of each working pixel out of R's
       upsampling; --clip replace also puts the corrected model output in the photo's clipped pixels.
       Both scored worse on the glass set than leaving them alone (--clip off, the default).
    5. T = I − amount·R, with R the upsampled R_w; at a negative amount, (1 − |a|)·I + |a|·R, the
       reflection alone at −1, as Lightroom's Amount does at −100.

    fullres.py --model build/rm22/windowseat-q4 --size 768 --out-dir build/rm22/out/fullres photo.tif

Each photo writes <stem>-output.tif (the model's output upsampled with Lanczos in sRGB, as WindowSeat
itself does), <stem>-subtract.tif and <stem>-reflection.tif (R, linear). The model's output at the
working size is kept as <stem>-model-<tag>.tif and reused with --reuse.
"""

import argparse
import json
import os
import pathlib
import time

import numpy as np
from PIL import Image

import glassio
import windowseat_mlx

CLIP = 0.985  # sRGB value from which a channel counts as clipped


def area_downsample(lin, width, height):
    return np.clip(glassio.resize_linear(lin, width, height, Image.BOX), 0, None)


def upsample(lin, width, height):
    return glassio.resize_linear(lin, width, height, Image.BICUBIC)


def fit_gain(inp, out, quantile=0.2, blur=2.0):
    """Per channel, the quantile of inp / out over well-exposed pixels, both smoothed, kept within [0.5, 1.5]."""
    a, b = smooth(inp, blur), smooth(out, blur)
    gains = []
    for c in range(3):
        ok = (b[..., c] > 0.01) & (b[..., c] < 0.9) & (a[..., c] < 0.95)
        gains.append(float(np.clip(np.quantile(a[..., c][ok] / b[..., c][ok], quantile), 0.5, 1.5)) if ok.sum() > 100 else 1.0)
    return [(g, 0.0) for g in gains]


def fit_drift(inp, out, quantile=0.2, valid=None, iterations=12):
    """Per channel, a and b with inp ≈ a·out + b on the lower envelope (quantile regression by IRLS)."""
    params = []
    for c in range(3):
        x, y = out[..., c].ravel(), inp[..., c].ravel()
        keep = np.ones_like(x, bool) if valid is None else valid.ravel()
        keep &= (x > 0.002) & (y > 0.002)
        x, y = x[keep], y[keep]
        if x.size > 200_000:
            pick = np.random.default_rng(0).choice(x.size, 200_000, replace=False)
            x, y = x[pick], y[pick]
        a, b = 1.0, 0.0
        for _ in range(iterations):
            r = y - (a * x + b)
            w = np.where(r >= 0, quantile, 1 - quantile) / np.maximum(np.abs(r), 1e-4)
            sw, sx, sy = w.sum(), (w * x).sum(), (w * y).sum()
            sxx, sxy = (w * x * x).sum(), (w * x * y).sum()
            det = sw * sxx - sx * sx
            if abs(det) < 1e-12:
                break
            a, b = (sw * sxy - sx * sy) / det, (sxx * sy - sx * sxy) / det
        params.append((float(a), float(b)))
    return params


def smooth(lin, sigma):
    if sigma <= 0:
        return lin
    radius = int(np.ceil(3 * sigma))
    k = np.exp(-0.5 * (np.arange(-radius, radius + 1) / sigma) ** 2)
    k /= k.sum()
    pad = np.pad(lin, ((radius, radius), (radius, radius), (0, 0)), mode="reflect")
    rows = sum(k[i] * pad[i : i + lin.shape[0]] for i in range(len(k)))
    return sum(k[i] * rows[:, i : i + lin.shape[1]] for i in range(len(k)))


def dilate_feather(mask, radius):
    """A soft version of a boolean mask: grown by `radius` pixels and feathered over as many again."""
    if radius <= 0 or not mask.any():
        return mask.astype(np.float32)
    m = mask.astype(np.float32)[..., None]
    grown = smooth(m, radius / 2) > 0.02
    return np.clip(smooth(grown.astype(np.float32), radius / 2), 0, 1)[..., 0]


def estimate(photo, model_output_w, size, quantile=0.2, smooth_px=2.0, clip_handling="off", drift="gain"):
    """The reflection layer and what's needed to apply it, from the full-size photo (sRGB, float) and the
    model's output at the working size (sRGB, float). clip_handling: "off" upsamples R_w as it is;
    "exclude" leaves the clipped share of each working pixel out of the upsampling; "replace" also
    puts the corrected model output in the photo's clipped pixels, grown and feathered."""
    height, width = photo.shape[:2]
    wh, ww = model_output_w.shape[:2]
    lin = glassio.srgb_to_linear(photo)
    lin_w = area_downsample(lin, ww, wh)
    out_w = glassio.srgb_to_linear(model_output_w)
    clipped = np.any(photo >= CLIP, axis=2)
    clip_w = area_downsample(clipped.astype(np.float32)[..., None], ww, wh)[..., 0] if clipped.any() else np.zeros((wh, ww), np.float32)
    if drift == "gain":
        params = fit_gain(lin_w, out_w, quantile)
    elif drift == "affine":
        params = fit_drift(lin_w, out_w, quantile, valid=clip_w < 0.01)
    else:
        params = [(1.0, 0.0)] * 3
    corrected = np.stack([a * out_w[..., c] + b for c, (a, b) in enumerate(params)], axis=2)
    reflection_w = smooth(np.maximum(lin_w - corrected, 0), smooth_px)
    blend = corrected_up = None
    if clip_handling != "off" and clipped.any():
        weight = np.clip(1 - clip_w, 0, 1)[..., None]
        reflection = upsample(reflection_w * weight, width, height) / np.maximum(upsample(weight, width, height), 1e-3)
        if clip_handling == "replace":
            blend = dilate_feather(clipped, max(2, round(min(width, height) / size)))[..., None]
            corrected_up = np.maximum(upsample(corrected, width, height), 0)
    else:
        reflection = upsample(reflection_w, width, height)
    reflection = np.maximum(reflection, 0)
    return {"lin": lin, "reflection": reflection, "blend": blend, "corrected_up": corrected_up, "drift": params, "clipped": float(clipped.mean())}


def apply(est, amount=1.0):
    lin, reflection = est["lin"], est["reflection"]
    if amount < 0:
        out = (1 + amount) * lin - amount * reflection
    else:
        out = lin - amount * reflection
        if est["blend"] is not None:
            target = (1 - amount) * lin + amount * est["corrected_up"]
            out = (1 - est["blend"]) * out + est["blend"] * target
    return glassio.linear_to_srgb(np.clip(out, 0, 1))


def upsampled_output(model_output_w, width, height):
    """The model's output brought to full size the way WindowSeat's own script does: Lanczos in sRGB."""
    return glassio.resize(model_output_w, width, height, linear=False)


def model_output(model, photo, size, scale=1.0):
    """The model's output for the photo averaged down so its short side is size × scale, in tiles of `size`:
    at scale 1 one row of tiles, as WindowSeat does by default; above 1, more tiles nearer the photo's own
    scale, as its --more-tiles does."""
    width, height = windowseat_mlx.working_size(photo.shape[1], photo.shape[0], round(size * scale))
    lin_w = area_downsample(glassio.srgb_to_linear(photo), width, height)
    return windowseat_mlx.remove(model, glassio.linear_to_srgb(lin_w), size)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", type=pathlib.Path, required=True)
    parser.add_argument("--size", type=int, default=768)
    parser.add_argument("--scale", type=float, default=1.0, help="work at size × scale on the short side, in tiles of size")
    parser.add_argument("--amount", type=float, default=1.0)
    parser.add_argument("--quantile", type=float, default=0.2)
    parser.add_argument("--smooth", type=float, default=2.0)
    parser.add_argument("--clip", choices=("off", "exclude", "replace"), default="off")
    parser.add_argument("--drift", choices=("gain", "affine", "off"), default="gain")
    parser.add_argument("--reuse", action="store_true", help="reuse a model output already in --out-dir")
    parser.add_argument("--out-dir", type=pathlib.Path, required=True)
    parser.add_argument("inputs", type=pathlib.Path, nargs="+")
    args = parser.parse_args()
    args.out_dir.mkdir(parents=True, exist_ok=True)
    tag = f"{args.model.name}-{args.size}" + (f"x{args.scale:g}" if args.scale != 1 else "")
    model = None
    for path in args.inputs:
        photo = glassio.read(path)
        cached = args.out_dir / f"{path.stem}-model-{tag}.tif"
        start = time.time()
        if args.reuse and cached.exists():
            out_w = glassio.read(cached)
        else:
            if model is None:
                model = windowseat_mlx.load(args.model)
            out_w = model_output(model, photo, args.size, args.scale)
            glassio.write_tiff16(cached, out_w)
        model_seconds = time.time() - start
        start = time.time()
        est = estimate(photo, out_w, args.size, args.quantile, args.smooth, args.clip, args.drift)
        result = apply(est, args.amount)
        post_seconds = time.time() - start
        glassio.write_tiff16(args.out_dir / f"{path.stem}-subtract.tif", result)
        glassio.write_tiff16(args.out_dir / f"{path.stem}-reflection.tif", np.clip(est["reflection"], 0, 1))
        glassio.write_tiff16(args.out_dir / f"{path.stem}-output.tif", upsampled_output(out_w, photo.shape[1], photo.shape[0]))
        print(json.dumps({"input": path.name, "size": list(photo.shape[1::-1]), "working": list(out_w.shape[1::-1]), "model_seconds": round(model_seconds, 1),
                          "full_resolution_seconds": round(post_seconds, 1), "drift": [[round(a, 3), round(b, 4)] for a, b in est["drift"]],
                          "clipped": round(est["clipped"], 4), "loadavg": round(os.getloadavg()[0], 1)}), flush=True)


if __name__ == "__main__":
    main()
