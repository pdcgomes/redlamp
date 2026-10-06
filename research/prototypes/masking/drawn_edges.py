"""What the renderer draws of an AI mask from process 13 (MSK-07), beside the mask as stored.

Process 13's develop kernel doesn't draw a stored AI mask as it is. `MaskEdges.texels` samples it
onto the analysis grid (the photo's mipmap whose long side is 1024 to 2047 px), fits it there to
the log luminance of the photo's linear camera RGB with a guided filter (radius 3, epsilon 0.02),
and `Masks.h` mixes the stored coverage towards that fit by a trust: the guide's local variance
against epsilon, which nears 1 at any edge in the photo. This replays those steps on the CPU, so a
mask can be compared with what's drawn of it until `redlamp render` can write the drawn coverage.

    .venv/bin/python drawn_edges.py <photo> <mask.png>... --out <dir> [--crop x,y,w,h]...

The photo is read as sRGB (a JPEG or PNG), whose linear values stand for the camera RGB a raw
would have; masks are 8-bit PNGs in the photo's orientation. Writes <mask>-drawn.png for each
mask, a sheet of the crops (photo, then each mask as stored and as drawn, in the app's red Color
Overlay at 55%), and prints how far the drawn mask moves from the stored one.
"""

import argparse
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

RADIUS = 3  # MaskEdges.radius
EPSILON = 0.02  # MaskEdges.epsilon
ANALYSIS_LONG_EDGE = 1024  # SessionBuilder.analysisLongEdge
LUMA = np.array([0.25, 0.5, 0.25], dtype=np.float32)  # ToneBase.lumaWeights, maskEdgeEV
RED = np.array([0.95, 0.18, 0.18], dtype=np.float32)  # the overlay's red
OPACITY = 0.55


def srgb_to_linear(x):
    return np.where(x <= 0.04045, x / 12.92, ((x + 0.055) / 1.055) ** 2.4)


def box(values, radius):
    """BoxFilter.blur: the mean over a (2r+1)² window, the edge pixels repeated beyond the border."""
    padded = np.pad(values, radius, mode="edge")
    c = np.cumsum(np.cumsum(padded, axis=0), axis=1)
    c = np.pad(c, ((1, 0), (1, 0)))
    n = 2 * radius + 1
    h, w = values.shape
    return (c[n : n + h, n : n + w] - c[:h, n : n + w] - c[n : n + h, :w] + c[:h, :w]) / (n * n)


def half(rgb):
    """One mipmap level down: the mean of each 2 x 2 block."""
    h, w = rgb.shape[0] // 2, rgb.shape[1] // 2
    return rgb[: 2 * h, : 2 * w].reshape(h, 2, w, 2, -1).mean(axis=(1, 3))


def bilinear(values, width, height):
    """`values` sampled at the centres of a width x height grid over the same frame (clamped)."""
    vh, vw = values.shape[:2]
    x = np.clip((np.arange(width) + 0.5) / width * vw - 0.5, 0, vw - 1)
    y = np.clip((np.arange(height) + 0.5) / height * vh - 0.5, 0, vh - 1)
    x0, y0 = np.floor(x).astype(int), np.floor(y).astype(int)
    x1, y1 = np.minimum(x0 + 1, vw - 1), np.minimum(y0 + 1, vh - 1)
    fx, fy = (x - x0)[None, :], (y - y0)[:, None]
    if values.ndim == 3:
        fx, fy = fx[..., None], fy[..., None]
    top = values[y0][:, x0] * (1 - fx) + values[y0][:, x1] * fx
    bottom = values[y1][:, x0] * (1 - fx) + values[y1][:, x1] * fx
    return top * (1 - fy) + bottom * fy


def analysis_grid(linear):
    """SessionBuilder.maps: the mipmap level whose long side is 1024 to 2047 px."""
    levels = int(math.floor(math.log2(max(linear.shape[:2])))) + 1
    level = max(0, levels - 1 - int(math.log2(ANALYSIS_LONG_EDGE)))
    grid = linear
    for _ in range(level):
        grid = half(grid)
    return grid


def log_luminance(rgb):
    return np.log2(np.maximum(rgb @ LUMA, 1e-6))


def drawn(coverage, linear):
    """Masks.h for an AI mask from process 13, at the photo's full size."""
    grid = analysis_grid(linear)
    gh, gw = grid.shape[:2]
    guide = log_luminance(grid)
    offset = guide.mean()
    guide = guide - offset
    sampled = bilinear(coverage, gw, gh)
    mean_i, mean_p = box(guide, RADIUS), box(sampled, RADIUS)
    variance = box(guide * guide, RADIUS) - mean_i * mean_i
    covariance = box(guide * sampled, RADIUS) - mean_i * mean_p
    a = covariance / (variance + EPSILON)
    b = mean_p - a * mean_i
    a, b = box(a, RADIUS), box(b, RADIUS)
    trust = box(np.maximum(variance, 0) / (np.maximum(variance, 0) + EPSILON), RADIUS)
    texels = np.stack([a, b, trust], axis=-1).astype(np.float16).astype(np.float32)
    h, w = linear.shape[:2]
    e = bilinear(texels, w, h)
    ev = log_luminance(linear)
    guided = np.clip(e[..., 0] * (ev - offset) + e[..., 1], 0, 1)
    raster = bilinear(coverage, w, h) if coverage.shape != (h, w) else coverage
    return raster + (guided - raster) * np.clip(e[..., 2], 0, 1), np.clip(e[..., 2], 0, 1)


def overlay(photo, coverage):
    return photo * (1 - coverage[..., None] * OPACITY) + RED * coverage[..., None] * OPACITY


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("photo")
    parser.add_argument("masks", nargs="+")
    parser.add_argument("--out", required=True)
    parser.add_argument("--reference", action="append", default=[], help="a mask shown as it is, not drawn")
    parser.add_argument("--crop", action="append", default=[], help="x,y,w,h in the photo's pixels")
    parser.add_argument("--scale", type=int, default=2, help="crops are enlarged this many times, nearest neighbour")
    args = parser.parse_args()

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    photo = np.asarray(Image.open(args.photo).convert("RGB"), dtype=np.float32) / 255
    linear = srgb_to_linear(photo).astype(np.float32)
    h, w = photo.shape[:2]

    columns = [("photo", photo)]
    for path in map(Path, args.masks):
        stored = np.asarray(Image.open(path).convert("L"), dtype=np.float32) / 255
        if stored.shape != (h, w):
            stored = bilinear(stored, w, h)
        result, trust = drawn(stored, linear)
        Image.fromarray(np.round(result * 255).astype(np.uint8)).save(out / f"{path.stem}-drawn.png")
        edge = (stored > 0.02) & (stored < 0.98)
        moved = np.abs(result - stored)
        print(
            f"{path.name}: grid {analysis_grid(linear).shape[1]}x{analysis_grid(linear).shape[0]}; "
            f"over the stored mask's soft edge ({edge.mean():.1%} of the photo) the drawn mask moves "
            f"{moved[edge].mean():.3f} on average, trust {trust[edge].mean():.2f}; "
            f"partly covered pixels (0.2 to 0.8) {((stored > 0.2) & (stored < 0.8)).sum()} stored, "
            f"{((result > 0.2) & (result < 0.8)).sum()} drawn; "
            f"stored >= 0.5 drawn < 0.25: {((stored >= 0.5) & (result < 0.25)).sum()} px; "
            f"stored < 0.1 drawn > 0.25: {((stored < 0.1) & (result > 0.25)).sum()} px"
        )
        columns.append((f"{path.stem}, stored", overlay(photo, stored)))
        columns.append((f"{path.stem}, drawn", overlay(photo, result)))
    for path in map(Path, args.reference):
        reference = np.asarray(Image.open(path).convert("L"), dtype=np.float32) / 255
        if reference.shape != (h, w):
            reference = bilinear(reference, w, h)
        columns.append((path.stem, overlay(photo, reference)))

    crops = [tuple(int(v) for v in c.split(",")) for c in args.crop] or [(0, 0, w, h)]
    label = 16
    tiles = []
    for x, y, cw, ch in crops:
        row = []
        for name, image in columns:
            tile = Image.fromarray(np.round(np.clip(image[y : y + ch, x : x + cw], 0, 1) * 255).astype(np.uint8))
            row.append((name, tile.resize((cw * args.scale, ch * args.scale), Image.NEAREST)))
        tiles.append(row)
    width = sum(tile.width for _, tile in tiles[0]) + 4 * (len(tiles[0]) - 1)
    height = sum(row[0][1].height + label for row in tiles) + 4 * (len(tiles) - 1)
    sheet = Image.new("RGB", (width, height), (24, 24, 24))
    draw = ImageDraw.Draw(sheet)
    top = 0
    for row in tiles:
        left = 0
        for name, tile in row:
            draw.text((left + 4, top + 2), name, fill=(220, 220, 220))
            sheet.paste(tile, (left, top + label))
            left += tile.width + 4
        top += row[0][1].height + label + 4
    sheet.save(out / f"{Path(args.photo).stem}-drawn-sheet.png")
    print(f"sheet: {out / (Path(args.photo).stem + '-drawn-sheet.png')}")


if __name__ == "__main__":
    main()
