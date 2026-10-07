"""Figures for the DN-11 note, from CC0 and synthetic sources only (docs/research/images/dn11-*.jpg).

- dn11-cfa-patterns.jpg: the Bayer and X-Trans tiles
- dn11-primer.jpg: one crop of the CC0 Sony scene as the sensor records it (each photosite in its
  filter's colour), demosaiced, with high-ISO noise, demosaiced with that noise, denoised after
  demosaicing (Redlamp today) and denoised before demosaicing (the prototype)
- dn11-sheet-<scene>-<cfa>-<level>.jpg: contact sheets of 1:1 crops, enlarged 3x, per contestant
"""

import sys

import numpy as np
import rawpy
from PIL import Image, ImageDraw, ImageFont

from common import AS_SHOT, BAYER, CFAS, OUT, ROOT, SIZE, TESTSET, XTRANS, cfa_index, load_rgb

IMAGES = ROOT / "docs/research/images"
FONT = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 18)
SMALL = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 15)
BG = (24, 24, 24)
FG = (225, 225, 225)


def camera_to_srgb(file="_DSC0009.ARW"):
    """The camera's matrix from rawpy (LibRaw's table), rows normalised so neutral stays neutral."""
    raw = rawpy.imread(str(ROOT / "tests/fixtures/raw" / file))
    xyz_to_cam = np.array(raw.rgb_xyz_matrix[:3, :3], np.float64)
    srgb_to_xyz = np.array([[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]])
    srgb_to_cam = xyz_to_cam @ srgb_to_xyz
    srgb_to_cam /= srgb_to_cam.sum(1, keepdims=True)
    return np.linalg.inv(srgb_to_cam)


def display(rgb, matrix=None, exposure=1.0):
    x = rgb * exposure
    if matrix is not None:
        x = x @ matrix.T
    x = np.clip(x, 0, 1)
    x = np.where(x <= 0.0031308, 12.92 * x, 1.055 * x ** (1 / 2.4) - 0.055)
    return (x * 255 + 0.5).astype(np.uint8)


def enlarge(a, k):
    return np.repeat(np.repeat(a, k, 0), k, 1)


def labelled_grid(panels, columns, title=None, caption=None, pad=10):
    h, w = panels[0][1].shape[:2]
    rows = (len(panels) + columns - 1) // columns
    top = 34 if title else 0
    bottom = 28 if caption else 0
    sheet = Image.new("RGB", (columns * (w + pad) + pad, top + rows * (h + pad + 24) + pad + bottom), BG)
    draw = ImageDraw.Draw(sheet)
    if title:
        draw.text((pad, 8), title, font=FONT, fill=FG)
    for i, (label, image) in enumerate(panels):
        x = pad + (i % columns) * (w + pad)
        y = top + pad + (i // columns) * (h + pad + 24)
        draw.text((x, y), label, font=SMALL, fill=FG)
        sheet.paste(Image.fromarray(image), (x, y + 22))
    if caption:
        draw.text((pad, sheet.height - bottom + 4), caption, font=SMALL, fill=(170, 170, 170))
    return sheet


def cfa_figure():
    colours = np.array([[200, 50, 50], [60, 170, 70], [60, 90, 210]], np.uint8)
    panels = []
    for name, cfa in [("Bayer (2 x 2 tile, repeated)", BAYER), ("Fujifilm X-Trans (6 x 6 tile)", XTRANS)]:
        tiles = np.tile(cfa, (12 // cfa.shape[0], 12 // cfa.shape[1]))
        image = enlarge(colours[tiles], 26)
        image[::26, :] = 24
        image[:, ::26] = 24
        counts = [(cfa == c).sum() * 100 // cfa.size for c in range(3)]
        panels.append((f"{name}: red {counts[0]}%, green {counts[1]}%, blue {counts[2]}%", image))
    sheet = labelled_grid(panels, 2)
    sheet.save(IMAGES / "dn11-cfa-patterns.jpg", quality=85, subsampling=0)


def primer():
    scene, level, cfa_name = "photo-fuji", "iso12800", "bayer"
    y0, x0, n, k = 405, 300, 80, 5
    matrix = camera_to_srgb("AFXT2720.RAF")
    truth = load_rgb(TESTSET / scene / "truth.f32", SIZE, SIZE)
    clean = np.fromfile(TESTSET / scene / f"{cfa_name}-clean.f32", "<f4").reshape(SIZE, SIZE)
    noisy = np.fromfile(TESTSET / scene / f"{cfa_name}-{level}.f32", "<f4").reshape(SIZE, SIZE)
    index = cfa_index(BAYER, SIZE, SIZE)

    def as_mosaic(m):
        balanced = m * np.array(AS_SHOT, np.float32)[index]
        rgb = np.zeros((SIZE, SIZE, 3), np.float32)
        np.put_along_axis(rgb, index[..., None], balanced[..., None], axis=2)
        return rgb

    crop = lambda a: a[y0:y0 + n, x0:x0 + n]
    r = OUT / "renders" / scene / cfa_name
    show = lambda rgb, ex=2.2, m=matrix: enlarge(display(crop(rgb), m, ex), k)
    # A mosaic shows each photosite in its filter's own colour, without the camera matrix.
    panels = [
        ("1. What the sensor records: one colour per photosite", show(as_mosaic(clean), 1.6, None)),
        ("2. Demosaiced (Redlamp)", show(load_rgb(r / "clean-none.f32", SIZE, SIZE))),
        ("3. The truth, every colour measured", show(truth)),
        ("4. The same mosaic at a very high ISO", show(as_mosaic(noisy), 1.6, None)),
        ("5. Noisy, demosaiced, no noise reduction", show(load_rgb(r / level / "rl-none.f32", SIZE, SIZE))),
        ("6. Denoised after demosaicing (Redlamp, Luminance 50)", show(load_rgb(r / level / "rl-l50.f32", SIZE, SIZE))),
        ("7. Denoised on the mosaic, then demosaiced (prototype)", show(load_rgb(r / level / "pre-nlm-c25.f32", SIZE, SIZE))),
    ]
    sheet = labelled_grid(panels, 4, caption="CC0 Fujifilm X-T3 raw (raw.pixls.us), binned 3 x 3 to full colour, re-mosaicked "
                          "as Bayer, with simulated ISO 12800-like noise. 80 px crop at 5x.")
    sheet.save(IMAGES / "dn11-primer.jpg", quality=85, subsampling=0)


def sheet(scene, cfa_name, level, methods, box, k=3, matrix=None, exposure=2.2, name=None):
    y0, x0, n = box
    truth = load_rgb(TESTSET / scene / "truth.f32", SIZE, SIZE)
    r = OUT / "renders" / scene / cfa_name
    panels = [("Truth", enlarge(display(truth[y0:y0 + n, x0:x0 + n], matrix, exposure), k))]
    for label, method in methods:
        path = (r / f"{method}.f32") if method.startswith("clean") else (r / level / f"{method}.f32")
        if not path.exists():
            continue
        image = load_rgb(path, SIZE, SIZE)[y0:y0 + n, x0:x0 + n]
        panels.append((label, enlarge(display(image, matrix, exposure), k)))
    out = labelled_grid(panels, 4, caption=f"{scene}, {cfa_name}, {level}: {n} px crops at {k}x")
    out.save(IMAGES / (name or f"dn11-sheet-{scene}-{cfa_name}-{level}.jpg"), quality=85, subsampling=0)


def demosaic_sheet():
    """Noise-free mosaics: Redlamp's demosaics against a learned one, Bayer and X-Trans."""
    panels = []
    matrix = camera_to_srgb()
    for scene, box, m in [("photo-sony", (300, 360, 96), matrix), ("text", (60, 8, 96), None)]:
        y0, x0, n = box
        k = 3
        truth = load_rgb(TESTSET / scene / "truth.f32", SIZE, SIZE)
        show = lambda img: enlarge(display(img[y0:y0 + n, x0:x0 + n], m, 2.2), k)
        panels.append(("Truth", show(truth)))
        for cfa_name, name in [("bayer", "Bayer"), ("xtrans", "X-Trans")]:
            r = OUT / "renders" / scene / cfa_name
            panels.append((f"{name}, Redlamp", show(load_rgb(r / "clean-none.f32", SIZE, SIZE))))
            panels.append((f"{name}, demosaicnet (learned)", show(load_rgb(r / "clean-demosaicnet.f32", SIZE, SIZE))))
    out = labelled_grid(panels, 5, caption="Noise-free mosaics, demosaic only. CC0 Sony crop and a synthetic chart; 96 px at 3x.")
    out.save(IMAGES / "dn11-demosaic.jpg", quality=85, subsampling=0)


METHODS = [
    ("Redlamp demosaic, no noise", "clean-none"),
    ("Redlamp, no noise reduction", "rl-none"),
    ("Redlamp default (Color 25)", "rl-c25"),
    ("Redlamp, Luminance 50", "rl-l50"),
    ("Prototype: mosaic denoised first", "pre-nlm-c25"),
    ("Prototype: half first, Luminance 25", "pre-half-l25"),
    ("RawNIND joint model (research only)", "model-nind"),
    ("Buades 2026, then Redlamp (research only)", "model-buades-c25"),
    ("RawNIND linear after Redlamp (research only)", "model-nind-linear"),
]


if __name__ == "__main__":
    IMAGES.mkdir(parents=True, exist_ok=True)
    cfa_figure()
    primer()
    demosaic_sheet()
    sony = camera_to_srgb()
    for cfa_name in CFAS:
        sheet("text", cfa_name, "iso51200", METHODS, (16, 8, 128))
    sheet("photo-sony", "bayer", "iso12800", METHODS, (300, 360, 128), matrix=sony)
    print("figures written", file=sys.stderr)
