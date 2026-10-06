"""Where two drawings of one mask differ on a real photo, and how much (MSK-26).

Real photos have no true coverage, so this compares what two renders draw of the same stored mask
(from `redlamp render --mask-bitmap kind=mask.png --coverage --process 12|13`): over the band where
either is partly covered, the mean difference and the share of pixels that move by more than 0.2,
and crops where they differ most (the photo, each drawing in the app's red overlay, and the
difference), for judging by eye which follows the photo.

    .venv/bin/python drawn_compare.py <photo> <a.png> <b.png> --out <sheet.png> [--crops 3] [--size 320]
"""

import argparse

import numpy as np
from PIL import Image, ImageDraw, ImageOps

RED = np.array([0.95, 0.18, 0.18], dtype=np.float32)


def coverage(path, size):
    image = Image.open(path).convert("L")
    if image.size != size:
        image = image.resize(size, Image.BILINEAR)
    return np.asarray(image, dtype=np.float32) / 255


def overlay(photo, cover):
    return photo * (1 - 0.55 * cover[..., None]) + RED * 0.55 * cover[..., None]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("photo")
    parser.add_argument("a")
    parser.add_argument("b")
    parser.add_argument("--out", required=True)
    parser.add_argument("--crops", type=int, default=3)
    parser.add_argument("--size", type=int, default=320)
    parser.add_argument("--labels", default="process 12,process 13")
    args = parser.parse_args()

    photo_image = ImageOps.exif_transpose(Image.open(args.photo)).convert("RGB")
    photo = np.asarray(photo_image, dtype=np.float32) / 255
    size = photo_image.size
    a, b = coverage(args.a, size), coverage(args.b, size)
    band = ((a > 0.02) & (a < 0.98)) | ((b > 0.02) & (b < 0.98))
    moved = np.abs(a - b)
    print(
        f"{args.photo.split('/')[-1]}: {size[0]}x{size[1]}, band {band.mean():.2%} of the photo; "
        f"over it the drawings differ by {moved[band].mean():.3f} on average, "
        f"{(moved[band] > 0.2).mean():.1%} of it by more than 0.2"
    )

    # The windows where the drawings differ most, apart from each other.
    s = args.size
    h, w = moved.shape
    window = np.add.reduceat(np.add.reduceat(moved, np.arange(0, h, s // 2), axis=0), np.arange(0, w, s // 2), axis=1)
    picks = []
    for flat in np.argsort(window, axis=None)[::-1]:
        y, x = np.unravel_index(flat, window.shape)
        y, x = min(y * (s // 2), h - s), min(x * (s // 2), w - s)
        if all(abs(y - py) >= s or abs(x - px) >= s for py, px in picks):
            picks.append((y, x))
        if len(picks) == args.crops:
            break
    labels = ["photo", *args.labels.split(","), "difference"]
    sheet = Image.new("RGB", (4 * (s + 4) - 4, len(picks) * (s + 20)), (22, 22, 22))
    draw = ImageDraw.Draw(sheet)
    for row, (y, x) in enumerate(picks):
        tiles = [
            photo[y : y + s, x : x + s],
            overlay(photo[y : y + s, x : x + s], a[y : y + s, x : x + s]),
            overlay(photo[y : y + s, x : x + s], b[y : y + s, x : x + s]),
            np.repeat(np.clip(moved[y : y + s, x : x + s] * 4, 0, 1)[..., None], 3, axis=2),
        ]
        for column, (label, tile) in enumerate(zip(labels, tiles)):
            left, top = column * (s + 4), row * (s + 20)
            draw.text((left + 3, top + 3), f"{label}  ({x},{y})" if column == 0 else label, fill=(230, 230, 230))
            sheet.paste(Image.fromarray(np.round(np.clip(tile, 0, 1) * 255).astype(np.uint8)), (left, top + 18))
    sheet.save(args.out)


if __name__ == "__main__":
    main()
