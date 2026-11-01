#!/usr/bin/env python3
"""The removal benchmark's composites (INF-14; RM-20, RM-21): an object pasted onto a clean part of a
CC0 photo, the photo itself being the truth a fill is scored against.

    BENCHMARK_OUT=build/benchmarks/removal python3 research/prototypes/generative/make_removal_composites.py \
        --case composite-paving
    ... --all

Each case decodes a CC0 raw from raw.pixls.us (a file the fixture tasks or the look-development set
already fetch, or else downloaded here and checked against its SHA-256) with LibRaw through rawpy:
linear, as-shot white balance, sRGB primaries, no automatic brightening. It crops a region at full
resolution and pastes an object onto it: a blob whose outline is a superellipse bent by a few low
harmonics drawn from the case's seed, filled with a texture cut from a donor photo and shaded
towards its edge. Into BENCHMARK_OUT it writes:

    <id>.dng          the composite, a linear DNG whose camera RGB is linear sRGB (D65), so Redlamp
                      and Lightroom open it as a raw and measure its noise
    <id>-truth.dng    the same crop without the object
    <id>-mask.png     the area to remove, the object grown by 4 pixels (255 inside)
    <id>-marked.jpg   the composite with that area outlined, for the bench task's step pictures

The same arguments make the same files on the same rawpy (LibRaw) version.

Needs numpy, scipy, Pillow, tifffile and rawpy (MIT, with LibRaw inside it under LGPL-2.1 or
CDDL-1.0): research use only, nothing here ships. Install them into a virtual environment under
build/ (`uv pip install numpy scipy pillow tifffile rawpy`).
"""

import argparse
import hashlib
import os
import pathlib
import time
import urllib.request

import numpy as np
import rawpy
import tifffile
from PIL import Image, ImageDraw
from scipy import ndimage

ROOT = pathlib.Path(__file__).resolve().parents[3]

# CC0 raws from raw.pixls.us; the licence is each file's in raw.pixls.us's repository listing
# (https://raw.pixls.us/json/getrepository.php?set=all), read on 1 November 2026.
SOURCES = {
    "d7500": {
        "path": "tests/fixtures/shoots/scenes/Nikon_D7500_RAW_NIKON_D7500_12BIT_COMPRESSED.NEF",
        "url": "https://raw.pixls.us/getfile.php/1531/nice/Nikon%20-%20D7500%20-%2012bit%2012bit%20compressed%20(Lossy%20(type%202))%20(3:2).NEF",
        "sha256": "ad53ee232836ba707d3d6820b5f9c015f129599aef7737adcec4a07b803b8891",
    },
    "x100vi": {
        "path": "build/look-dev/Fujifilm_X100VI.RAF",
        "url": "https://raw.pixls.us/getfile.php/7302/nice/Fujifilm%20-%20X100VI%20-%2014bit%2014bit%20compressed%20(3:2).RAF",
        "sha256": "7f19c7c5914542b91829ac2e41c8d4c10e414b28b0f7a793001e1a979c8c6056",
    },
    "umc-r10c": {
        "path": "build/look-dev/Sony_UMC-R10C.arw",
        "url": "https://raw.pixls.us/getfile.php/7540/nice/Sony%20-%20UMC-R10C%20-%2012bit%20(3:2).arw",
        "sha256": "b67055a69dc7adffbcd2d62fc438300f0a3ec219bd778cbd87994288eb2de7c5",
    },
    "s22-ultra": {
        "path": "build/look-dev/Samsung_Galaxy-S22-Ultra.dng",
        "url": "https://raw.pixls.us/getfile.php/6625/nice/Samsung%20-%20Galaxy%20S22%20Ultra%20-%204:3.dng",
        "sha256": "13ddd4b117299d16d47b6404ad1981258a00b6bce60382524a51cab15a41334d",
    },
    "7d2": {
        "path": "build/look-dev/Canon_EOS-7D-Mark-II.dng",
        "url": "https://raw.pixls.us/getfile.php/7023/nice/Canon%20-%20EOS%207D%20Mark%20II%20-%2016bit%20(3:2).dng",
        "sha256": "090e01f9a7a860b2f2f0ead770b8a9ba3b17ea98dc1997835c6bda2fc0a2ae54",
    },
}

# Regions are fractions of the photo as shown: [x, y, width, height]. An object's centre and size
# are fractions of the crop; its donor region is a fraction of the donor photo.
RED_CAR = ("d7500", [0.12, 0.53, 0.26, 0.08])
CASES = {
    "composite-paving": {
        "source": "d7500", "crop": [0.02, 0.725, 0.76, 0.275],
        "object": {"centre": [0.45, 0.5], "size": [0.42, 0.78], "donor": RED_CAR, "seed": 11},
        "notes": "Paving bricks in rows, a large object across them",
    },
    "composite-wall": {
        "source": "d7500", "crop": [0.1, 0.3, 0.52, 0.22],
        "object": {"centre": [0.38, 0.5], "size": [0.3, 0.8], "donor": RED_CAR, "seed": 12},
        "notes": "A brick house front with windows, a white door and a gutter",
    },
    "composite-grass": {
        "source": "umc-r10c", "crop": [0.04, 0.66, 0.62, 0.32],
        "object": {"centre": [0.5, 0.55], "size": [0.4, 0.75], "donor": RED_CAR, "seed": 13},
        "notes": "Rough grass and earth, a large object on it",
    },
    "composite-windows": {
        "source": "umc-r10c", "crop": [0.46, 0.14, 0.5, 0.52],
        "object": {"centre": [0.45, 0.45], "size": [0.24, 0.3], "donor": RED_CAR, "seed": 14},
        "notes": "A modern building front: windows, orange panels and corrugated cladding",
    },
    "composite-facade": {
        "source": "x100vi", "crop": [0.05, 0.15, 0.45, 0.3],
        "object": {"centre": [0.5, 0.5], "size": [0.3, 0.3], "donor": RED_CAR, "seed": 15},
        "notes": "A stone church front: tall arched windows, a rose window and courses of stone",
    },
    "composite-railing": {
        "source": "x100vi", "crop": [0.5, 0.66, 0.5, 0.3],
        "object": {"centre": [0.62, 0.45], "size": [0.25, 0.35], "donor": RED_CAR, "seed": 16},
        "notes": "A metal railing beside steps and a doorway, the object over the railing",
    },
    "composite-water": {
        "source": "s22-ultra", "crop": [0.0, 0.42, 0.62, 0.42],
        "object": {"centre": [0.45, 0.22], "size": [0.22, 0.4], "donor": RED_CAR, "seed": 17},
        "notes": "Open water below a shoreline, the object across the shore's line",
    },
}


def source_file(name):
    source = SOURCES[name]
    path = ROOT / source["path"]
    if not path.exists():
        path = pathlib.Path(os.environ.get("BENCHMARK_OUT", ROOT / "build" / "benchmarks" / "removal")) / "sources" / path.name
        if not path.exists():
            path.parent.mkdir(parents=True, exist_ok=True)
            request = urllib.request.Request(source["url"], headers={"User-Agent": "redlamp-benchmarks"})
            with urllib.request.urlopen(request, timeout=300) as response:
                path.write_bytes(response.read())
            time.sleep(2)
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != source["sha256"]:
        raise SystemExit(f"{path}: SHA-256 {digest}, expected {source['sha256']}")
    return path


DECODED = {}


def decoded(name):
    """Linear sRGB, 0…1, as LibRaw develops it with the camera's white balance and no brightening."""
    if name not in DECODED:
        with rawpy.imread(str(source_file(name))) as raw:
            rgb = raw.postprocess(
                use_camera_wb=True, no_auto_bright=True, output_bps=16, gamma=(1, 1),
                output_color=rawpy.ColorSpace.sRGB, demosaic_algorithm=rawpy.DemosaicAlgorithm.AHD,
            )
        DECODED[name] = rgb.astype(np.float32) / 65535
    return DECODED[name]


def region(image, box):
    height, width = image.shape[:2]
    x, y = int(round(box[0] * width)), int(round(box[1] * height))
    w, h = int(round(box[2] * width)), int(round(box[3] * height))
    return image[y:y + h, x:x + w]


def blob(width, height, centre, size, seed):
    """The object's coverage (0…1, antialiased) over a width × height crop."""
    rng = np.random.default_rng(seed)
    harmonics = [(k, rng.uniform(0.03, 0.09) / k ** 0.5, rng.uniform(0, 2 * np.pi)) for k in (2, 3, 5)]
    ys, xs = np.mgrid[0:height, 0:width].astype(np.float32) + 0.5
    cx, cy = centre[0] * width, centre[1] * height
    rx, ry = size[0] * width / 2, size[1] * height / 2
    u, v = (xs - cx) / rx, (ys - cy) / ry
    angle = np.arctan2(v, u)
    bend = 1 + sum(a * np.cos(k * angle + p) for k, a, p in harmonics)
    power = 3.0
    radius = (np.abs(u) ** power + np.abs(v) ** power) ** (1 / power) / bend
    # About one pixel of antialiasing at the edge.
    edge = 1.0 / max(min(rx, ry), 1.0)
    return np.clip((1 - radius) / edge + 0.5, 0, 1).astype(np.float32), radius


def paste(background, spec):
    height, width = background.shape[:2]
    coverage, radius = blob(width, height, spec["centre"], spec["size"], spec["seed"])
    ys, xs = np.nonzero(coverage > 0)
    y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
    donor_name, donor_box = spec["donor"]
    donor = region(decoded(donor_name), donor_box)
    # The donor's texture resized to the object's box, channel by channel in float.
    patch = np.stack([
        np.asarray(Image.fromarray(donor[..., c]).resize((x1 - x0, y1 - y0), Image.BICUBIC)) for c in range(3)
    ], axis=-1)
    shade = 0.45 + 0.55 * np.clip((1 - radius[y0:y1, x0:x1]) / 0.25, 0, 1) ** 0.6
    composite = background.copy()
    alpha = coverage[y0:y1, x0:x1, None]
    composite[y0:y1, x0:x1] = background[y0:y1, x0:x1] * (1 - alpha) + np.clip(patch * shade[..., None], 0, 1) * alpha
    mask = ndimage.binary_dilation(coverage > 0.01, iterations=4)
    return composite, mask


def write_dng(path, rgb, model):
    """A linear DNG whose camera RGB is linear sRGB, balanced for D65."""
    xyz_to_srgb = [3.2406, -1.5372, -0.4986, -0.9689, 1.8758, 0.0415, 0.0557, -0.2040, 1.0570]
    srational = [v for x in xyz_to_srgb for v in (int(round(x * 10000)), 10000)]
    tifffile.imwrite(
        path, np.round(np.clip(rgb, 0, 1) * 65535).astype(np.uint16), photometric=34892, planarconfig="contig",
        metadata=None, extratags=[
            (254, 4, 1, 0, True), (271, "s", 0, "Redlamp", True), (272, "s", 0, model, True),
            (274, 3, 1, 1, True), (50706, 1, 4, (1, 4, 0, 0), True), (50707, 1, 4, (1, 1, 0, 0), True),
            (50708, "s", 0, f"Redlamp {model}", True), (50717, 4, 3, (65535, 65535, 65535), True),
            (50721, 10, 9, srational, True), (50778, 3, 1, 21, True), (50728, 5, 3, (1, 1, 1, 1, 1, 1), True),
        ],
    )


def marked(composite, mask, path, width=1600):
    """The composite as an sRGB JPEG, the area to remove outlined in red."""
    shown = np.clip(composite / max(np.percentile(composite, 99.5), 1e-6), 0, 1)
    shown = np.where(shown <= 0.0031308, shown * 12.92, 1.055 * shown ** (1 / 2.4) - 0.055)
    image = Image.fromarray(np.round(shown * 255).astype(np.uint8))
    scale = width / image.width
    image = image.resize((width, round(image.height * scale)), Image.LANCZOS)
    small = np.asarray(Image.fromarray(mask.astype(np.uint8) * 255).resize(image.size, Image.NEAREST)) > 127
    outline = small & ~ndimage.binary_erosion(small, iterations=3)
    pixels = np.asarray(image).copy()
    pixels[outline] = (255, 32, 32)
    Image.fromarray(pixels).save(path, quality=90)


def make(case_id, out):
    spec = CASES[case_id]
    background = region(decoded(spec["source"]), spec["crop"])
    height, width = background.shape[:2]
    background = background[: height // 2 * 2, : width // 2 * 2]
    composite, mask = paste(background, spec["object"])
    write_dng(out / f"{case_id}.dng", composite, "Removal composite")
    write_dng(out / f"{case_id}-truth.dng", background, "Removal composite")
    Image.fromarray(mask.astype(np.uint8) * 255).save(out / f"{case_id}-mask.png")
    marked(composite, mask, out / f"{case_id}-marked.jpg")
    share = mask.mean()
    print(f"{case_id}: {background.shape[1]}x{background.shape[0]}, object {share:.1%} of the frame")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--case", action="append", choices=sorted(CASES))
    parser.add_argument("--all", action="store_true")
    args = parser.parse_args()
    out = pathlib.Path(os.environ.get("BENCHMARK_OUT", ROOT / "build" / "benchmarks" / "removal"))
    out.mkdir(parents=True, exist_ok=True)
    for case_id in sorted(CASES) if args.all else args.case or []:
        make(case_id, out)


if __name__ == "__main__":
    main()
