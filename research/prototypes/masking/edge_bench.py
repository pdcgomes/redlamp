#!/usr/bin/env python3
"""Sky-edge benchmark: thin structures over real skies, with known coverage.

The sky bake-off (MSK-17) scores masks against OneFormer with a 1%-of-the-diagonal tolerance,
so it can't see twigs, leaf gaps, wires or stray hairs. This builds images whose true sky
coverage is known exactly, at the 4096 px the renderer stores masks at:

  * sky plates: the all-sky band at the top of the bake-off's sky photos (OneFormer says every
    pixel is sky), stretched to the frame, plus three synthetic skies (clear gradient, sunset,
    overcast);
  * foregrounds drawn procedurally at 4x supersampling (so coverage is exact): bare trees
    (recursive branches tapering to sub-pixel twigs), leafy trees (branches plus leaf clusters
    with sky between them), power lines, and a skyline with antennae;
  * composited in linear light, then a lens blur (sigma 0.8 px) and sensor noise, and
    encoded to sRGB. The true sky coverage gets the same blur.

    research/prototypes/masking/.venv/bin/python research/prototypes/masking/edge_bench.py generate
    research/prototypes/masking/.venv/bin/python research/prototypes/masking/edge_bench.py score <method>...

`score` reads build/edge-bench/<scene>-<method>.png (any size; resampled to 4096) and reports,
per scene and on average:
  * band MAE: mean absolute coverage error where the truth is mixed or near an edge (within
    16 px of a pixel between 2% and 98%), the matting error that matters for an adjustment;
  * thin MAE: the same error over pixels at least 10% covered by thin foreground (twigs, wires,
    antennae: structures under 4 px wide), where coarse masks fail first;
  * thin recall: of the pixels at least 60% thin foreground, the share the mask keeps out of the
    sky (coverage < 0.5);
  * leak: the share of solid foreground (coverage under 2%) the mask calls sky (> 0.5);
  * IoU at 0.5.
"""

import json
import math
import pathlib
import sys

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

ROOT = pathlib.Path(__file__).resolve().parents[3]
BAKEOFF = ROOT / "build/masking-bakeoff"
WORK = ROOT / "build/edge-bench"
WIDTH, HEIGHT = 4096, 2731
SUPER = 4


def srgb_to_linear(x):
    return np.where(x <= 0.04045, x / 12.92, ((x + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(x):
    x = np.clip(x, 0, 1)
    return np.where(x <= 0.0031308, x * 12.92, 1.055 * x ** (1 / 2.4) - 0.055)


# MARK: - Skies

def photo_plates():
    plates = []
    for reference in sorted(BAKEOFF.glob("*-oneformer-ade20k-swin-large.png")):
        stem = reference.name.replace("-oneformer-ade20k-swin-large.png", "")
        sky = np.asarray(Image.open(reference).convert("L")) > 127
        rows = sky.mean(axis=1)
        band = 0
        while band < len(rows) and rows[band] > 0.99:
            band += 1
        if band < sky.shape[0] * 0.08:
            continue
        render = Image.open(BAKEOFF / f"{stem}.png").convert("RGB")
        plate = render.crop((0, 0, render.width, int(band * 0.95))).resize((WIDTH, HEIGHT), Image.BICUBIC)
        linear = srgb_to_linear(np.asarray(plate, dtype=np.float32) / 255)
        # Vignetted corners are dark, not sky.
        if np.percentile(linear.mean(axis=2), 0.5) < 0.05:
            continue
        plates.append((stem, linear))
    return plates


def synthetic_plates():
    y = np.linspace(0, 1, HEIGHT, dtype=np.float32)[:, None, None]
    x = np.linspace(0, 1, WIDTH, dtype=np.float32)[None, :, None]
    clear = (1 - y) * np.array([0.10, 0.25, 0.65]) + y * np.array([0.45, 0.60, 0.85]) + 0 * x
    sunset = (1 - y) * np.array([0.25, 0.20, 0.45]) + y * np.array([1.0, 0.45, 0.12]) + 0 * x
    rng = np.random.default_rng(7)
    clouds = ndimage.gaussian_filter(rng.standard_normal((HEIGHT // 16, WIDTH // 16)), 6)
    clouds = np.asarray(Image.fromarray(clouds.astype(np.float32)).resize((WIDTH, HEIGHT), Image.BICUBIC))
    clouds = (clouds - clouds.min()) / (clouds.max() - clouds.min())
    overcast = (0.55 + 0.25 * clouds[..., None]) * np.array([0.92, 0.95, 1.0]) + 0 * y
    return [("clear", clear.astype(np.float32)), ("sunset", sunset.astype(np.float32)),
            ("overcast", overcast.astype(np.float32))]


# MARK: - Foregrounds (drawn at SUPER x, so coverage is exact after averaging)

class Canvas:
    def __init__(self):
        self.size = (WIDTH * SUPER, HEIGHT * SUPER)
        self.solid = Image.new("L", self.size, 0)
        self.thin = Image.new("L", self.size, 0)
        self.solid_draw = ImageDraw.Draw(self.solid)
        self.thin_draw = ImageDraw.Draw(self.thin)

    def line(self, a, b, width):
        """`width` in final pixels; under 4 px counts as thin."""
        draw = self.thin_draw if width < 4 else self.solid_draw
        w = max(1, int(round(width * SUPER)))
        points = [(a[0] * SUPER, a[1] * SUPER), (b[0] * SUPER, b[1] * SUPER)]
        draw.line(points, fill=255, width=w)
        r = w / 2
        for p in points:
            draw.ellipse((p[0] - r, p[1] - r, p[0] + r, p[1] + r), fill=255)

    def blob(self, centre, radius):
        x, y = centre[0] * SUPER, centre[1] * SUPER
        r = radius * SUPER
        self.solid_draw.ellipse((x - r, y - r, x + r, y + r), fill=255)

    def polygon(self, points):
        self.solid_draw.polygon([(x * SUPER, y * SUPER) for x, y in points], fill=255)

    def coverage(self):
        def down(image):
            a = np.asarray(image, dtype=np.float32) / 255
            return a.reshape(HEIGHT, SUPER, WIDTH, SUPER).mean(axis=(1, 3))
        thin = down(self.thin)
        solid = down(self.solid)
        return np.clip(thin + solid, 0, 1), np.clip(thin * (1 - solid), 0, 1)


def branch(canvas, rng, start, angle, length, width, depth, leaves):
    end = (start[0] + length * math.cos(angle), start[1] - length * math.sin(angle))
    canvas.line(start, end, width)
    if leaves and width < 3 and rng.random() < 0.5:
        for _ in range(rng.integers(2, 6)):
            canvas.blob((end[0] + rng.normal(0, length * 0.3), end[1] + rng.normal(0, length * 0.3)),
                        rng.uniform(3, 12))
    if depth == 0 or width < 0.35:
        return
    for _ in range(rng.integers(2, 4)):
        branch(canvas, rng, end, angle + rng.normal(0, 0.45), length * rng.uniform(0.62, 0.82),
               width * rng.uniform(0.55, 0.72), depth - 1, leaves)


def tree(canvas, rng, base_x, height, leaves):
    base = (base_x, HEIGHT)
    trunk = rng.uniform(26, 44)
    top = (base_x + rng.normal(0, 20), HEIGHT - height * 0.35)
    canvas.line(base, top, trunk)
    for _ in range(rng.integers(3, 5)):
        branch(canvas, rng, top, math.pi / 2 + rng.normal(0, 0.6), height * 0.22, trunk * 0.5, 9, leaves)


def wires(canvas, rng):
    for k in range(4):
        y0 = HEIGHT * rng.uniform(0.15, 0.5)
        sag = rng.uniform(40, 160)
        width = rng.uniform(0.8, 2.5)
        points = [(x, y0 + sag * (1 - ((x / WIDTH) * 2 - 1) ** 2)) for x in np.linspace(0, WIDTH, 200)]
        for a, b in zip(points, points[1:]):
            canvas.line(a, b, width)


def skyline(canvas, rng):
    x = 0.0
    while x < WIDTH:
        w = rng.uniform(150, 500)
        h = HEIGHT * rng.uniform(0.15, 0.45)
        canvas.polygon([(x, HEIGHT), (x, HEIGHT - h), (x + w, HEIGHT - h), (x + w, HEIGHT)])
        if rng.random() < 0.5:
            ax = x + rng.uniform(0.2, 0.8) * w
            canvas.line((ax, HEIGHT - h), (ax, HEIGHT - h - rng.uniform(80, 300)), rng.uniform(1.0, 3.0))
        x += w + rng.uniform(0, 60)


def foreground(kind, rng):
    canvas = Canvas()
    if kind == "bare":
        for base in np.linspace(WIDTH * 0.2, WIDTH * 0.8, 2):
            tree(canvas, rng, base + rng.normal(0, 200), HEIGHT * rng.uniform(0.8, 1.1), leaves=False)
    elif kind == "leafy":
        tree(canvas, rng, WIDTH * 0.5, HEIGHT * 1.0, leaves=True)
    elif kind == "wires":
        wires(canvas, rng)
        skyline(canvas, rng)
    elif kind == "skyline":
        skyline(canvas, rng)
        tree(canvas, rng, WIDTH * 0.75, HEIGHT * 0.7, leaves=False)
    return canvas.coverage()


def foreground_colour(rng, kind):
    """A dark, textured foreground in linear light."""
    base = np.array({"bare": [0.035, 0.03, 0.025], "leafy": [0.03, 0.05, 0.02],
                     "wires": [0.02, 0.02, 0.02], "skyline": [0.08, 0.075, 0.07]}[kind])
    texture = ndimage.gaussian_filter(rng.standard_normal((HEIGHT // 4, WIDTH // 4)), 2)
    texture = np.asarray(Image.fromarray(texture.astype(np.float32)).resize((WIDTH, HEIGHT), Image.BILINEAR))
    return (base[None, None, :] * np.exp(0.5 * texture)[..., None]).astype(np.float32)


def generate():
    WORK.mkdir(parents=True, exist_ok=True)
    plates = photo_plates() + synthetic_plates()
    kinds = ["bare", "leafy", "wires", "skyline"]
    scenes = []
    rng = np.random.default_rng(2026)
    pairs = [(name, sky, kinds[(2 * index + k) % len(kinds)]) for index, (name, sky) in enumerate(plates) for k in (0, 1)]
    for name, sky, kind in pairs:
        alpha, thin = foreground(kind, rng)
        colour = foreground_colour(rng, kind)
        image = alpha[..., None] * colour + (1 - alpha[..., None]) * sky
        image = ndimage.gaussian_filter(image, sigma=(0.8, 0.8, 0))
        truth = ndimage.gaussian_filter(1 - alpha, 0.8)
        thin = ndimage.gaussian_filter(thin, 0.8)
        noise = rng.standard_normal(image.shape).astype(np.float32) * (0.004 + 0.01 * np.sqrt(np.clip(image, 0, 1)))
        encoded = linear_to_srgb(image + noise)
        scene = f"{kind}-{name}"
        Image.fromarray((encoded * 255 + 0.5).astype(np.uint8)).save(WORK / f"{scene}.png")
        np.savez_compressed(WORK / f"{scene}-truth.npz", sky=truth.astype(np.float16), thin=thin.astype(np.float16))
        scenes.append(scene)
        print(f"{scene}: sky {truth.mean():.3f}, thin {(thin > 0.3).mean():.4f}")
    (WORK / "scenes.json").write_text(json.dumps(scenes, indent=2))


# MARK: - Scoring

def score_mask(mask, truth, thin):
    mixed = (truth > 0.02) & (truth < 0.98)
    band = ndimage.binary_dilation(mixed, iterations=16)
    solid = truth < 0.02
    thin_pixels = thin > 0.6
    touched = thin > 0.1
    return {
        "bandMAE": float(np.abs(mask - truth)[band].mean()),
        "thinMAE": float(np.abs(mask - truth)[touched].mean()) if touched.any() else None,
        "thinRecall": float((mask[thin_pixels] < 0.5).mean()) if thin_pixels.any() else None,
        "leak": float((mask[solid] > 0.5).mean()),
        "iou": float(((mask > 0.5) & (truth > 0.5)).sum() / max(((mask > 0.5) | (truth > 0.5)).sum(), 1)),
    }


def load(path):
    image = Image.open(path).convert("L")
    if image.size != (WIDTH, HEIGHT):
        image = image.resize((WIDTH, HEIGHT), Image.BILINEAR)
    return np.asarray(image, dtype=np.float32) / 255


def score(methods):
    scenes = json.loads((WORK / "scenes.json").read_text())
    results = {}
    for method in methods:
        rows = []
        for scene in scenes:
            path = WORK / f"{scene}-{method}.png"
            if not path.exists():
                continue
            truth = np.load(WORK / f"{scene}-truth.npz")
            row = score_mask(load(path), truth["sky"].astype(np.float32), truth["thin"].astype(np.float32))
            rows.append({"scene": scene, **row})
        results[method] = rows
        if not rows:
            print(f"{method}: no masks")
            continue
        def mean(key):
            values = [r[key] for r in rows if r[key] is not None]
            return float(np.mean(values)) if values else float("nan")
        print(f"{method:28s} n={len(rows):2d}  band MAE {mean('bandMAE'):.3f}  thin MAE {mean('thinMAE'):.3f}"
              f"  thin recall {mean('thinRecall'):.3f}"
              f"  leak {mean('leak'):.4f}  IoU {mean('iou'):.3f}")
    out = WORK / "scores.json"
    previous = json.loads(out.read_text()) if out.exists() else {}
    previous.update(results)
    out.write_text(json.dumps(previous, indent=2))


if __name__ == "__main__":
    if sys.argv[1:2] == ["generate"]:
        generate()
    elif sys.argv[1:2] == ["score"]:
        score(sys.argv[2:])
    else:
        sys.exit(__doc__)
