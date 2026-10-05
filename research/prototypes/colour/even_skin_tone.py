#!/usr/bin/env python3
"""Even Skin Tone (TON-29): the preset's values, tried on portraits with the engine's arithmetic.

A port of the develop kernel's Point Color (`Develop.metal`, `PointColorMath.swift`): each axis of a
swatch's range a trapezoid (hue in degrees, chroma in stops, lightness), fading over its last
`fade`, times the colourfulness ramp and the mask's coverage; uniformity scales distances from the
swatch's colour by 1 - u * weight. The swatch's colour is the mask's own: the median of lightness,
a and b under the mask, weighted by coverage, faint edges left out, as `PointColor.metal` measures
it. Chroma changes skip the engine's gamut-relative boost, which only slows increases.

Each portrait is a JPEG render, so its OKLab stands in for what Point Color receives after the tone
curve. The mask is the face (all of it: eyes, brows and lips too, which the app's Face Skin leaves
out, so the range has to keep them out here) and the body's skin, from SAM 3.

Scores, over the mask's colourful part (coverage above 0.5, chroma 0.02 or more), the skin:
- selected: the share of it the swatch selects more than half;
- hue spread: the interquartile range of hue, in degrees;
- chroma spread: the interquartile range of log2 chroma, in stops;
- colour detail: how much of a and b's detail below 2 px is left;
- spill: the mean change (OKLab distance x 100) of colours under the mask more than 45 degrees of
  hue from the skin's, or near-grey, which should barely move: lips, teeth, eyes, stubble, clothes.

    research/prototypes/masking/.venv/bin/python research/prototypes/colour/even_skin_tone.py \\
        --images ~/src/darkroom/build

Portraits: <images>/edge-cases/<name>.jpg with <images>/people-parts/<name>-whole-face-semantic.png
and -whole-body-skin-semantic.png; none is committed. Figures and the table go to
build/proto-out/even-skin/ in this checkout.
"""

import argparse
import pathlib

import numpy as np
from PIL import Image
from scipy import ndimage

ROOT = pathlib.Path(__file__).resolve().parents[3]
OUT = ROOT / "build/proto-out/even-skin"
NAMES = ["DSC02005", "DSC01584", "DSC02424", "DSC03301"]

# OKLab (B. Ottosson, "A perceptual color space for image processing", 2020), from linear sRGB.
M1 = np.array([[0.4122214708, 0.5363325363, 0.0514459929],
               [0.2119034982, 0.6806995451, 0.1073969566],
               [0.0883024619, 0.2817188376, 0.6299787005]])
M2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468],
               [1.9779984951, -2.4285922050, 0.4505937099],
               [0.0259040371, 0.7827717662, -0.8086757660]])

# The preset (MaskPresets.swift): slider values.
EVEN_SKIN_TONE = dict(hue_u=50, sat_u=35, lum_u=0, hue_range=47, sat_range=64, lum_range=37, smoothness=50)


def to_oklab(srgb):
    linear = np.where(srgb <= 0.04045, srgb / 12.92, ((srgb + 0.055) / 1.055) ** 2.4)
    return np.cbrt(linear @ M1.T) @ M2.T


def from_oklab(lab):
    linear = np.clip(((lab @ np.linalg.inv(M2).T) ** 3) @ np.linalg.inv(M1).T, 0, 1)
    return np.where(linear <= 0.0031308, linear * 12.92, 1.055 * linear ** (1 / 2.4) - 0.055)


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / np.maximum(e1 - e0, 1e-9), 0, 1)
    return t * t * (3 - 2 * t)


def wrap(degrees):
    return (degrees + 180) % 360 - 180


def weighted_median(values, weights):
    order = np.argsort(values)
    cumulative = np.cumsum(weights[order])
    return values[order][np.searchsorted(cumulative, 0.5 * cumulative[-1])]


def own_colour(lab, coverage, greys=True):
    """The mask's own colour, as PointColor.metal measures it: per-channel weighted medians, near-greys
    left out unless `greys`."""
    chroma = np.hypot(lab[..., 1], lab[..., 2])
    weight = coverage * (1 if greys else smoothstep(0.01, 0.03, chroma))
    under = (coverage >= 0.25) & (np.round(weight * 255) > 0)
    weights = np.round(weight[under] * 255)
    L, a, b = (weighted_median(lab[..., i][under], weights) for i in range(3))
    return L, np.hypot(a, b), np.degrees(np.arctan2(b, a)) % 360


def point_color(lab, coverage, swatch, values):
    """The kernel's Point Color for one swatch on a mask: the pulled OKLab and the weight."""
    L, a, b = lab[..., 0], lab[..., 1], lab[..., 2]
    C = np.hypot(a, b)
    h = np.degrees(np.arctan2(b, a)) % 360
    sL, sC, sh = swatch
    width = np.array([5 + 85 * values["hue_range"] / 100, 0.25 + 2.75 * values["sat_range"] / 100,
                      0.05 + 0.95 * values["lum_range"] / 100])
    fade = 0.1 + 0.9 * values["smoothness"] / 100
    distance = [np.abs(wrap(h - sh)), np.abs(np.log2(np.maximum(C, 1e-4) / max(sC, 0.02))), np.abs(L - sL)]
    weight = np.ones_like(L)
    for axis in range(3):
        weight *= 1 - smoothstep(width[axis] * (1 - fade), width[axis], distance[axis])
    weight *= smoothstep(0, 0.04, C) * coverage
    hue = h + wrap(h - sh) * (-values["hue_u"] / 100 * weight)
    chroma = C * np.exp2(np.log2(np.maximum(C, 1e-4) / max(sC, 0.02)) * (-values["sat_u"] / 100 * weight))
    lightness = L + (L - sL) * (-values["lum_u"] / 100 * weight)
    radians = np.radians(hue)
    return np.stack([lightness, chroma * np.cos(radians), chroma * np.sin(radians)], -1), weight


def detail(channel):
    return channel - ndimage.gaussian_filter(channel, 2)


def scores(lab, out, weight, solid, swatch):
    def hue_and_chroma(x):
        C = np.hypot(x[..., 1], x[..., 2])
        return wrap(np.degrees(np.arctan2(x[..., 2], x[..., 1])) - swatch[2]), np.log2(np.maximum(C, 1e-4))

    def iqr(values):
        q1, q3 = np.percentile(values, [25, 75])
        return q3 - q1

    dh, logC = hue_and_chroma(lab)
    dh2, logC2 = hue_and_chroma(out)
    C = np.hypot(lab[..., 1], lab[..., 2])
    # Skin: the mask's colourful part; near-greys there (white clothes, grey hair, teeth) have no hue to even.
    skin = solid & (C >= 0.02)
    centre = np.median(dh[skin])
    other = solid & ((np.abs(wrap(dh - centre)) > 45) | (C < 0.02))
    kept = sum(np.abs(detail(out[..., i]))[skin].mean() for i in (1, 2))
    before = sum(np.abs(detail(lab[..., i]))[skin].mean() for i in (1, 2))
    change = np.linalg.norm(out - lab, axis=-1) * 100
    return dict(
        hue=(iqr(wrap(dh[skin] - centre)), iqr(wrap(dh2[skin] - centre))),
        chroma=(iqr(logC[skin]), iqr(logC2[skin])), selected=(weight[skin] > 0.5).mean(),
        detail=kept / before, spill=change[other].mean() if other.any() else 0.0, other=other.mean() / solid.mean(),
    )


def load(images, name):
    srgb = np.asarray(Image.open(images / "edge-cases" / f"{name}.jpg").convert("RGB"), float) / 255
    parts = images / "people-parts"
    face, body = (np.asarray(Image.open(parts / f"{name}-whole-{part}-semantic.png").convert("L"), float) / 255
                  for part in ("face", "body-skin"))
    return srgb, np.maximum(face, body)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--images", type=pathlib.Path, default=ROOT / "build")
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    grid = [dict(EVEN_SKIN_TONE, hue_u=hu, sat_u=su) for hu, su in ((30, 20), (50, 35), (70, 50), (100, 100))]
    rows = ["| Photo | Median | Hue U | Sat U | Lum Range | Selected | Hue spread (°) | Chroma spread (stops) "
            "| Colour detail kept | Spill (ΔE×100) |",
            "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
    for name in NAMES:
        srgb, coverage = load(args.images, name)
        lab = to_oklab(srgb)
        solid = coverage > 0.5
        for greys in (True, False):
            swatch = own_colour(lab, coverage, greys)
            print(f"{name}: own colour {'with' if greys else 'without'} near-greys: L {swatch[0]:.3f} C {swatch[1]:.3f} "
                  f"h {swatch[2]:.1f}, mask {solid.mean():.1%}")
            for values in grid:
                out, weight = point_color(lab, coverage, swatch, values)
                s = scores(lab, out, weight, solid, swatch)
                preset = values == EVEN_SKIN_TONE and not greys
                rows.append(
                    f"| {name}{' (preset)' if preset else ''} | {'all' if greys else 'no greys'} | {values['hue_u']} "
                    f"| {values['sat_u']} | {values['lum_range']} | {s['selected']:.0%} "
                    f"| {s['hue'][0]:.1f} → {s['hue'][1]:.1f} | {s['chroma'][0]:.2f} → {s['chroma'][1]:.2f} "
                    f"| {s['detail']:.0%} | {s['spill']:.2f} on {s['other']:.0%} |")
                if preset:
                    ys, xs = np.nonzero(solid)
                    box = (max(xs.min() - 40, 0), max(ys.min() - 40, 0), min(xs.max() + 40, srgb.shape[1]),
                           min(ys.max() + 40, srgb.shape[0]))
                    x0, y0, x1, y1 = box
                    pair = np.concatenate([srgb[y0:y1, x0:x1], np.clip(from_oklab(out), 0, 1)[y0:y1, x0:x1]], axis=1)
                    figure = Image.fromarray((pair * 255).round().astype(np.uint8))
                    figure.thumbnail((1600, 1000))
                    figure.save(OUT / f"{name}-before-after.jpg", quality=90)
                    Image.fromarray((weight * 255).round().astype(np.uint8)).crop(box).save(OUT / f"{name}-weight.png")
    (OUT / "scores.md").write_text("\n".join(rows) + "\n")
    print("\n".join(rows))


if __name__ == "__main__":
    main()
