#!/usr/bin/env python3
"""The glass set's composites (INF-14, RM-22): photos through glass whose truth is exact.

    BENCHMARK_OUT=build/benchmarks/glass python3 research/prototypes/reflections/make_glass.py --case c01-kitchen-cafe
    BENCHMARK_OUT=build/benchmarks/glass python3 research/prototypes/reflections/make_glass.py --all

Each case is a transmitted photo plus a reflection made from another photo, both CC0 files from
Wikimedia Commons (never Unsplash or Pexels uploads). In linear light, the reflection source is
scaled to cover the frame, mirrored, blurred with a Gaussian, optionally doubled by a shifted and
dimmer ghost (the glass's second surface), and weighted by a smooth falloff across the glass; the
transmitted photo is optionally tinted by the glass; the photo through glass is their sum, clipped
at white as a camera clips it. Each case writes, in $BENCHMARK_OUT:

    <case>.tif             the photo through glass, sRGB, 16-bit
    <case>-truth.tif       the transmitted photo as it is behind the glass (tint included), sRGB, 16-bit
    <case>-reflection.tif  the reflection layer, linear light, 16-bit, clipped at 1
    <case>.json            the case's parameters and sources

The sources are downloaded once into $BENCHMARK_OUT/sources/ and checked against their SHA-256. The
same arguments make the same files every time. Needs NumPy and Pillow.
"""

import argparse
import hashlib
import json
import os
import pathlib
import sys
import time
import urllib.request

import numpy as np

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import glassio  # noqa: E402

# The CC0 files the composites are made from: each one's Commons page, URL, author, licence and SHA-256.
SOURCE_FILE = pathlib.Path(__file__).resolve().parent / "sources.json"

CASES = {
    "c01-kitchen-cafe": dict(t="kitchen-cafe", r="pavillon-de-flore", strength=0.30, blur=0.003, falloff="gradient", long_side=8160, seed=1,
                             notes="A building and sky reflected softly over a café interior, at the source's full 50 MP"),
    "c02-bookstore": dict(t="bookstore", r="river-trees", strength=0.30, blur=0.004, ghost=(0.005, 0.5), falloff="blob", seed=2,
                          notes="Trees reflected over a bookshop, with a shifted ghost from the glass's second surface"),
    "c03-living-room": dict(t="living-room", r="kwun-tong", strength=0.25, blur=0.0008, falloff="gradient", seed=3,
                            notes="Office towers reflected sharply, as when the reflection is near the focus"),
    "c04-sarphatistraat": dict(t="sarphatistraat", r="cafe-seats", strength=0.35, blur=0.003, falloff="gradient", seed=4,
                               notes="A street seen from inside a café, with the room reflected in the window"),
    "c05-dove-lake": dict(t="dove-lake", r="tuntorp-clouds", strength=0.35, blur=0.006, falloff="gradient", seed=5,
                          notes="A bright evening sky reflected over a landscape; the brightest parts clip"),
    "c06-unnameable-books": dict(t="unnameable-books", r="streetlight", strength=1.2, blur=0.002, falloff="none", seed=6,
                                 notes="A street lamp reflected over a bookshop: a small clipped highlight"),
    "c07-kitchen-cafe-tinted": dict(t="kitchen-cafe", r="river-trees", strength=0.20, blur=0.004, falloff="blob", tint=(0.90, 0.97, 0.93), seed=7,
                                    notes="Green-tinted glass: the tint belongs to the truth, so it should stay"),
    "c08-bookstore-faint": dict(t="bookstore", r="kwun-tong", strength=0.08, blur=0.004, falloff="gradient", seed=8,
                                notes="A faint reflection: the photo should be left nearly alone"),
    "c09-sarphatistraat-ghost": dict(t="sarphatistraat", r="pavillon-de-flore", strength=0.25, blur=0.002, ghost=(0.008, 0.7), falloff="gradient", seed=9,
                                     notes="A strong double image, as thick double glazing makes"),
    "c10-dove-lake-soft": dict(t="dove-lake", r="cafe-seats", strength=0.30, blur=0.015, falloff="blob", seed=10,
                               notes="A very soft, out-of-focus interior over a landscape"),
    "c11-living-room-lamp": dict(t="living-room", r="streetlight", strength=0.8, blur=0.004, ghost=(0.004, 0.5), falloff="none", seed=11,
                                 notes="A lamp and its ghost reflected over a wall of pictures"),
    "c12-unnameable-books-sky": dict(t="unnameable-books", r="tuntorp-clouds", strength=0.45, blur=0.004, falloff="gradient", seed=12,
                                     notes="A strong, bright reflection over a dark interior"),
}
DEFAULT_LONG_SIDE = 4096
FALLOFF_FLOOR = 0.35
UA = {"User-Agent": "redlamp-benchmarks (https://github.com/pdcgomes/redlamp)"}


def sources():
    return json.loads(SOURCE_FILE.read_text())


def fetch(out, key):
    entry = sources()[key]
    path = out / "sources" / f"{key}.jpg"
    if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest() != entry["sha256"]:
        path.parent.mkdir(parents=True, exist_ok=True)
        data = urllib.request.urlopen(urllib.request.Request(entry["url"], headers=UA), timeout=180).read()
        if hashlib.sha256(data).hexdigest() != entry["sha256"]:
            raise SystemExit(f"{key}: SHA-256 differs from sources.json")
        path.write_bytes(data)
        time.sleep(1.5)
    return path


def gaussian_blur(image, sigma):
    """Gaussian blur by FFT, with the edges mirrored so nothing wraps around."""
    if sigma < 0.3:
        return image
    pad = int(np.ceil(3 * sigma))
    padded = np.pad(image, ((pad, pad), (pad, pad), (0, 0)), mode="reflect")
    h, w = padded.shape[:2]
    fy = np.fft.fftfreq(h)[:, None]
    fx = np.fft.rfftfreq(w)[None, :]
    kernel = np.exp(-2 * (np.pi * sigma) ** 2 * (fx**2 + fy**2))
    out = np.stack([np.fft.irfft2(np.fft.rfft2(padded[..., c]) * kernel, s=(h, w)) for c in range(padded.shape[2])], axis=2)
    return out[pad:-pad, pad:-pad].astype(np.float32)


def shift(image, dx, dy):
    """The image moved by whole pixels, its edge repeated into the gap."""
    out = np.roll(image, (dy, dx), axis=(0, 1))
    if dy > 0:
        out[:dy] = out[dy : dy + 1]
    elif dy < 0:
        out[dy:] = out[dy - 1 : dy]
    if dx > 0:
        out[:, :dx] = out[:, dx : dx + 1]
    elif dx < 0:
        out[:, dx:] = out[:, dx - 1 : dx]
    return out


def falloff(kind, height, width, rng):
    """A smooth weight across the glass in [FALLOFF_FLOOR, 1]: a ramp at a random angle or a broad blob."""
    if kind == "none":
        return np.ones((height, width, 1), np.float32)
    y, x = np.mgrid[0:height, 0:width].astype(np.float32)
    x, y = x / max(height, width), y / max(height, width)
    if kind == "gradient":
        angle = rng.uniform(0, 2 * np.pi)
        ramp = np.cos(angle) * x + np.sin(angle) * y
        weight = (ramp - ramp.min()) / max(ramp.max() - ramp.min(), 1e-6)
    else:
        cx, cy = rng.uniform(0.2, 0.8) * width / max(height, width), rng.uniform(0.2, 0.8) * height / max(height, width)
        weight = np.exp(-((x - cx) ** 2 + (y - cy) ** 2) / (2 * 0.35**2))
    return (FALLOFF_FLOOR + (1 - FALLOFF_FLOOR) * weight)[..., None].astype(np.float32)


def cover(image, width, height):
    """The image scaled to cover width × height and cut to it, centred, in linear light."""
    h, w = image.shape[:2]
    scale = max(width / w, height / h)
    sw, sh = max(width, round(w * scale)), max(height, round(h * scale))
    scaled = glassio.resize_linear(image, sw, sh)
    x0, y0 = (sw - width) // 2, (sh - height) // 2
    return scaled[y0 : y0 + height, x0 : x0 + width]


def make(out, case_id):
    case = CASES[case_id]
    rng = np.random.default_rng(case["seed"])
    transmitted = glassio.srgb_to_linear(glassio.read(fetch(out, case["t"])))
    long_side = case.get("long_side", DEFAULT_LONG_SIDE)
    h, w = transmitted.shape[:2]
    if max(h, w) != long_side:
        scale = long_side / max(h, w)
        w, h = round(w * scale), round(h * scale)
        transmitted = np.clip(glassio.resize_linear(transmitted, w, h), 0, 1)
    source = glassio.srgb_to_linear(glassio.read(fetch(out, case["r"])))
    reflected = cover(source, w, h)[:, ::-1]
    sigma = case["blur"] * long_side
    layer = gaussian_blur(np.clip(reflected, 0, None), sigma)
    if case.get("ghost"):
        offset, gain = case["ghost"]
        angle = rng.uniform(0, 2 * np.pi)
        dx, dy = round(np.cos(angle) * offset * long_side), round(np.sin(angle) * offset * long_side)
        layer = layer + gain * shift(layer, dx, dy)
    layer = case["strength"] * falloff(case["falloff"], h, w, rng) * layer
    truth = transmitted * np.asarray(case.get("tint", (1, 1, 1)), np.float32)
    through = np.clip(truth + layer, 0, 1)
    glassio.write_tiff16(out / f"{case_id}.tif", glassio.linear_to_srgb(through))
    glassio.write_tiff16(out / f"{case_id}-truth.tif", glassio.linear_to_srgb(truth))
    glassio.write_tiff16(out / f"{case_id}-reflection.tif", np.clip(layer, 0, 1))
    clipped = float(np.mean(np.any(truth + layer >= 1, axis=2)))
    info = {**case, "id": case_id, "size": [w, h], "blur_sigma_px": round(sigma, 2), "clipped_fraction": round(clipped, 5),
            "reflection_mean": [round(float(v), 4) for v in layer.reshape(-1, 3).mean(0)],
            "sources": {k: sources()[case[k]] for k in ("t", "r")}}
    (out / f"{case_id}.json").write_text(json.dumps(info, indent=2, ensure_ascii=False) + "\n")
    print(f"{case_id}: {w}×{h}, blur σ {sigma:.1f} px, {100 * clipped:.2f}% clipped")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--case", choices=sorted(CASES))
    group.add_argument("--all", action="store_true")
    args = parser.parse_args()
    out = pathlib.Path(os.environ.get("BENCHMARK_OUT", pathlib.Path(__file__).resolve().parents[3] / "build/benchmarks/glass"))
    out.mkdir(parents=True, exist_ok=True)
    for case_id in sorted(CASES) if args.all else [args.case]:
        make(out, case_id)


if __name__ == "__main__":
    main()
