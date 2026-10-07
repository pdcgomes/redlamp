"""Builds the DN-11 test set in build/proto-data/raw-denoise/testset.

Every scene is a balanced camera RGB image with exact truth at every pixel:

- Charts, rendered at 4x and box-filtered to the pixel grid after a mild Gaussian blur (the lens):
  a slanted edge, a Siemens star, a zone plate, dead leaves, and text with flat patches.
- Photos: crops of CC0 base-ISO raws from raw.pixls.us (tests/fixtures/raw), binned 2 x 2 (Bayer)
  or 3 x 3 (X-Trans) so each pixel has measured red, green and blue and no demosaic is involved.

Each scene is mosaicked through Bayer and X-Trans, with the white balance removed, and given exact
Poisson-Gaussian noise at three ISO-like levels. Writes truth.f32 per scene, a mosaic per
(scene, CFA, level), and manifest.json. Nothing here is committed.
"""

import numpy as np
import rawpy
from PIL import Image, ImageDraw, ImageFont
from scipy.ndimage import gaussian_filter

from common import (
    AS_SHOT, CFAS, NOISE_LEVELS, ROOT, SIZE, TESTSET, add_noise, mosaic, save_f32, write_json,
)

SS = 4  # supersampling
LENS_SIGMA = 0.45  # Gaussian lens blur, in output pixels

DARK, LIGHT = 0.05, 0.45


def finish(hi: np.ndarray) -> np.ndarray:
    """Lens blur, then the pixel aperture (a box over each output pixel)."""
    blurred = gaussian_filter(hi, sigma=(LENS_SIGMA * SS, LENS_SIGMA * SS, 0))
    n = hi.shape[0] // SS
    return blurred.reshape(n, SS, n, SS, 3).mean(axis=(1, 3)).astype(np.float32)


def grid(n: int):
    c = (np.arange(n) + 0.5) / SS
    return np.meshgrid(c, c)


def slanted_edge() -> np.ndarray:
    n = SIZE * SS
    x, y = grid(n)
    angle = np.deg2rad(5)
    cx = SIZE / 2
    side = (x - cx) * np.cos(angle) + (y - cx) * np.sin(angle) > 0
    value = np.where(side, LIGHT, DARK)
    return finish(np.repeat(value[..., None], 3, axis=2))


def siemens_star(cycles: int = 72) -> np.ndarray:
    n = SIZE * SS
    x, y = grid(n)
    theta = np.arctan2(y - SIZE / 2, x - SIZE / 2)
    value = np.where(np.sin(cycles * theta) > 0, LIGHT, DARK)
    return finish(np.repeat(value[..., None], 3, axis=2))


def zone_plate() -> np.ndarray:
    """A circular chirp reaching 0.5 cycles per pixel (Nyquist) at the edge's midpoints."""
    n = SIZE * SS
    x, y = grid(n)
    r2 = (x - SIZE / 2) ** 2 + (y - SIZE / 2) ** 2
    k = np.pi * 0.5 / (SIZE / 2)  # instantaneous frequency k r / pi cycles per pixel
    value = (DARK + LIGHT) / 2 + (LIGHT - DARK) / 2 * np.cos(k * r2)
    return finish(np.repeat(value[..., None], 3, axis=2))


def dead_leaves(seed: int = 5) -> np.ndarray:
    n = SIZE * SS
    rng = np.random.default_rng(seed)
    image = np.full((n, n, 3), 0.18, np.float32)
    rmin, rmax = 2 * SS, 90 * SS
    for _ in range(6000):
        u = rng.uniform()
        r = 1 / np.sqrt(rmin ** -2 - u * (rmin ** -2 - rmax ** -2))
        cx, cy = rng.uniform(0, n, 2)
        grey = 0.04 + 0.6 * rng.uniform() * rng.uniform()
        tint = rng.uniform(-0.5, 0.5, 3)
        colour = np.maximum(grey * (1 + 0.8 * tint), 0.01)
        x0, x1 = int(max(0, cx - r)), int(min(n, cx + r + 1))
        y0, y1 = int(max(0, cy - r)), int(min(n, cy + r + 1))
        if x0 >= x1 or y0 >= y1:
            continue
        yy, xx = np.mgrid[y0:y1, x0:x1]
        inside = (xx - cx) ** 2 + (yy - cy) ** 2 <= r * r
        image[y0:y1, x0:x1][inside] = colour
    return finish(image)


def text_and_patches() -> np.ndarray:
    """Text at several sizes in neutral and coloured pairs, a flat grey patch, a dark patch and
    saturated colour patches."""
    n = SIZE * SS
    canvas = Image.new("RGB", (n, n), (0, 0, 0))
    draw = ImageDraw.Draw(canvas)
    font_path = "/System/Library/Fonts/Supplemental/Arial.ttf"
    pairs = [((230, 230, 230), (25, 25, 25)), ((200, 40, 40), (30, 60, 200)), ((40, 160, 60), (190, 60, 170))]
    y = 0
    for size in (7, 9, 12, 16):
        for fg, bg in pairs:
            height = int(size * 1.6 * SS)
            draw.rectangle([0, y, n // 2, y + height], fill=bg)
            font = ImageFont.truetype(font_path, size * SS)
            draw.text((4 * SS, y + 2 * SS), "Hamburgefonstiv 0123456789 RAW", font=font, fill=fg)
            y += height
    # Patches on the right half: flat grey, dark grey (shadow colour bias), saturated colours.
    half = n // 2
    draw.rectangle([half, 0, n, half], fill=(118, 118, 118))  # about 0.18 after decoding
    draw.rectangle([half, half, n, half + n // 4], fill=(36, 36, 36))  # about 0.02
    colours = [(200, 30, 30), (30, 170, 40), (30, 50, 210), (220, 200, 30)]
    w = (n - half) // 4
    for i, c in enumerate(colours):
        draw.rectangle([half + i * w, half + n // 4, half + (i + 1) * w, n], fill=c)
    srgb = np.asarray(canvas, np.float32) / 255
    linear = np.where(srgb <= 0.04045, srgb / 12.92, ((srgb + 0.055) / 1.055) ** 2.4)
    return finish(linear * 0.95)


REGIONS = {
    # Pixel boxes (x0, y0, x1, y1) on the 768 px scenes, used by score.py.
    "text": {"flat": (420, 40, 730, 350), "dark": (420, 420, 730, 550), "text": (8, 8, 376, 760)},
}


def photo_crops() -> dict:
    """Binned crops of CC0 base-ISO raws, chosen as the most detailed SIZE x SIZE windows."""
    sources = [
        ("sony", "_DSC0009.ARW", 2),
        ("nikon", "DSC_0750.NEF", 2),
        ("canon", "Canon_EOS_R6_RAW_ISO_100_nocrop_nodual.CR3", 2),
        ("fuji", "AFXT2720.RAF", 3),
    ]
    scenes = {}
    for name, file, b in sources:
        raw = rawpy.imread(str(ROOT / "tests/fixtures/raw" / file))
        data = raw.raw_image_visible.astype(np.float32)
        colors = raw.raw_colors_visible.copy()
        colors[colors == 3] = 1
        black = np.array(raw.black_level_per_channel, np.float32)[raw.raw_colors_visible]
        data = (data - black) / (raw.white_level - black)
        h, w = data.shape
        h, w = h // (b * 2) * (b * 2), w // (b * 2) * (b * 2)
        data, colors = data[:h, :w], colors[:h, :w]
        blocks = lambda a: a.reshape(h // b, b, w // b, b).transpose(0, 2, 1, 3).reshape(h // b, w // b, b * b)
        values, kinds = blocks(data), blocks(colors)
        rgb = np.stack([
            (values * (kinds == c)).sum(-1) / np.maximum((kinds == c).sum(-1), 1) for c in range(3)
        ], -1)
        wb = np.array(raw.camera_whitebalance[:3], np.float32)
        rgb = rgb * (wb / wb[1])
        # The most detailed window, by the energy of a Laplacian of luma on a coarse grid.
        luma = rgb.mean(-1)
        lap = np.abs(luma - gaussian_filter(luma, 1.5))
        best, where = -1, (0, 0)
        for y0 in range(0, luma.shape[0] - SIZE, SIZE // 4):
            for x0 in range(0, luma.shape[1] - SIZE, SIZE // 4):
                window = luma[y0:y0 + SIZE, x0:x0 + SIZE]
                if np.percentile(window, 99.5) > 0.9:  # avoid clipped areas
                    continue
                e = lap[y0:y0 + SIZE, x0:x0 + SIZE].mean()
                if e > best:
                    best, where = e, (y0, x0)
        y0, x0 = where
        crop = rgb[y0:y0 + SIZE, x0:x0 + SIZE]
        # High-ISO frames are exposed as usual for their ISO: put the median balanced green at 0.15.
        crop = crop * (0.15 / max(np.median(crop[..., 1]), 1e-4))
        crop = np.clip(crop, 0, 0.95)
        scenes[f"photo-{name}"] = {"rgb": crop.astype(np.float32), "source": file, "bin": b, "origin": [int(x0), int(y0)]}
    return scenes


def main():
    TESTSET.mkdir(parents=True, exist_ok=True)
    scenes = {
        "edge": {"rgb": slanted_edge()},
        "star": {"rgb": siemens_star()},
        "zone": {"rgb": zone_plate()},
        "leaves": {"rgb": dead_leaves()},
        "text": {"rgb": text_and_patches()},
    }
    scenes.update(photo_crops())
    manifest = {"size": SIZE, "asShot": AS_SHOT, "levels": {k: list(v) for k, v in NOISE_LEVELS.items()},
                "regions": REGIONS, "scenes": {}}
    for s, (name, scene) in enumerate(scenes.items()):
        rgb = scene["rgb"]
        save_f32(TESTSET / name / "truth.f32", rgb)
        entry = {k: v for k, v in scene.items() if k != "rgb"}
        entry["mosaics"] = {}
        for cfa_name, cfa in CFAS.items():
            clean = mosaic(rgb, cfa)
            save_f32(TESTSET / name / f"{cfa_name}-clean.f32", clean)
            entry["mosaics"][f"{cfa_name}-clean"] = {"cfa": cfa_name, "level": None}
            for l, (level, (a, b)) in enumerate(NOISE_LEVELS.items()):
                noisy = add_noise(clean, a, b, seed=1000 * s + 10 * l + (cfa_name == "xtrans"))
                save_f32(TESTSET / name / f"{cfa_name}-{level}.f32", noisy)
                entry["mosaics"][f"{cfa_name}-{level}"] = {"cfa": cfa_name, "level": level}
        manifest["scenes"][name] = entry
        Image.fromarray((np.clip(rgb / 0.6, 0, 1) ** (1 / 2.2) * 255).astype(np.uint8)).save(
            TESTSET / name / "truth.png")
        print(name, rgb.shape, f"mean {rgb.mean():.3f}")
    write_json(TESTSET / "manifest.json", manifest)


if __name__ == "__main__":
    main()
