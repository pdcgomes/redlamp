#!/usr/bin/env python3
"""ViTMatte against closed-form matting on hair_bench's heads (MSK-32).

hair_bench's scenes come with the person's exact coverage, and coarse masks that stand in for
Vision's. Each head is matted from its coarse mask as Redlamp mattes a Subject: sure person well
inside it, sure background well outside, and an unsure band between (1% of the long side inside,
`--outer` outside, 2% for ClosedFormMatte). ViTMatte solves the band at the scenes' 4096 px in
1024 px tiles overlapping by 128 px, blended by a tent across the overlap, running only the tiles
the band reaches, as the app would. Writes build/hair-bench/<scene>-vitmatte-<model>-<outer>.png
for `hair_bench.py score`, and the time each scene took.

    .venv/bin/python vitmatte_bench.py [--model small|base] [--outer 0.02]

`portraits` mattes the four portraits in build/edge-cases from Vision's own masks the same way,
at the size Redlamp stores masks at (4096 px on the long side), and writes, in
build/mask-bench/vitmatte/, a 100% crop of each head's hair: the photo, then closed-form's matte
and ViTMatte's composited over mid-grey, where haze shows as a fog of the photo's colour.

    .venv/bin/python vitmatte_bench.py portraits [--model base] [--outer 0.05]
"""

import argparse
import json
import pathlib
import sys
import time

import numpy as np
from PIL import Image

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import hair_bench as hb  # noqa: E402
from portrait_bench import trimap  # noqa: E402

TILE, OVERLAP = 1024, 128


class Matter:
    def __init__(self, size):
        import torch
        from transformers import VitMatteForImageMatting, VitMatteImageProcessor

        name = f"hustvl/vitmatte-{size}-composition-1k"
        self.torch = torch
        self.processor = VitMatteImageProcessor.from_pretrained(name)
        self.model = VitMatteForImageMatting.from_pretrained(name).eval()
        self.device = "mps" if torch.backends.mps.is_available() else "cpu"
        self.model.to(self.device)

    def __call__(self, image, tri):
        inputs = self.processor(
            images=Image.fromarray(image), trimaps=Image.fromarray((tri * 255).astype(np.uint8)),
            return_tensors="pt",
        ).to(self.device)
        with self.torch.no_grad():
            alpha = self.model(**inputs).alphas[0, 0].float().cpu().numpy()
        return np.clip(alpha[: image.shape[0], : image.shape[1]], 0, 1)


def window(height, width):
    """A tile's blending weight: 1 inside, falling linearly across the overlap to the edges."""
    def ramp(n):
        x = np.arange(n, dtype=np.float32) + 0.5
        return np.clip(np.minimum(x, n - x) / OVERLAP, 1e-3, 1)

    return ramp(height)[:, None] * ramp(width)[None, :]


def starts(length):
    step = TILE - OVERLAP
    positions = list(range(0, max(length - TILE, 0) + 1, step))
    if positions[-1] + TILE < length:
        positions.append(length - TILE)
    return positions


def tiled(matter, image, tri):
    height, width = tri.shape
    total = np.zeros((height, width), np.float32)
    weight = np.zeros((height, width), np.float32)
    tiles = 0
    for y in starts(height):
        for x in starts(width):
            part = tri[y:y + TILE, x:x + TILE]
            if not (part == 0.5).any():
                continue
            w = window(*part.shape)
            total[y:y + TILE, x:x + TILE] += matter(image[y:y + TILE, x:x + TILE], part) * w
            weight[y:y + TILE, x:x + TILE] += w
            tiles += 1
    out = tri.copy()
    unknown = tri == 0.5
    out[unknown] = (total / np.maximum(weight, 1e-6))[unknown]
    return out, tiles


def portraits(matter, outer):
    from portrait_bench import PORTRAITS, WORK

    out = hb.ROOT / "build/mask-bench/vitmatte"
    out.mkdir(parents=True, exist_ok=True)
    for name in PORTRAITS:
        photo = Image.open(WORK / f"{name}.jpg").convert("RGB")
        scale = 4096 / max(photo.size)
        if scale < 1:
            photo = photo.resize((round(photo.width * scale), round(photo.height * scale)), Image.LANCZOS)
        image = np.asarray(photo)

        def load(suffix):
            path = WORK / f"{name}-{suffix}.png"
            if not path.exists():
                path = WORK / f"{name}-{suffix}-1.png"
            mask = Image.open(path).convert("L").resize(photo.size, Image.BILINEAR)
            return np.asarray(mask, np.float32) / 255

        coarse, closed = load("vision"), load("swift-cf")
        started = time.perf_counter()
        alpha, tiles = tiled(matter, image, trimap(coarse, inner=0.01, outer=outer))
        print(f"{name}: {tiles} tiles in {time.perf_counter() - started:.1f} s", flush=True)
        Image.fromarray((alpha * 255 + 0.5).astype(np.uint8)).save(out / f"{name}-vitmatte.png")
        rows = np.nonzero((coarse > 0.5).any(axis=1))[0]
        top = rows[0] if len(rows) else 0
        columns = np.nonzero(coarse[min(top + 40, coarse.shape[0] - 1)] > 0.5)[0]
        centre = int(columns.mean()) if len(columns) else image.shape[1] // 2
        y0 = int(np.clip(top - 150, 0, image.shape[0] - 500))
        x0 = int(np.clip(centre - 400, 0, image.shape[1] - 800))
        crop = image[y0:y0 + 500, x0:x0 + 800].astype(np.float32)

        def over_grey(matte):
            a = matte[y0:y0 + 500, x0:x0 + 800, None]
            return a * crop + (1 - a) * 128

        panels = [crop, over_grey(closed), over_grey(alpha)]
        sheet = np.concatenate([np.pad(p, ((0, 0), (0, 8), (0, 0)), constant_values=255) for p in panels], axis=1)
        Image.fromarray(sheet.astype(np.uint8)).save(out / f"{name}-sheet.jpg", quality=92)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("command", nargs="?", default="heads", choices=("heads", "portraits"))
    parser.add_argument("--model", default="base", choices=("small", "base"))
    parser.add_argument("--outer", type=float, default=0.02)
    args = parser.parse_args()
    matter = Matter(args.model)
    if args.command == "portraits":
        portraits(matter, args.outer)
        return
    method = f"vitmatte-{args.model}-{args.outer:g}"
    for scene in json.loads((hb.WORK / "scenes.json").read_text()):
        image = np.asarray(Image.open(hb.WORK / f"{scene}.png").convert("RGB"))
        coarse = np.asarray(Image.open(hb.WORK / f"{scene}-coarse.png").convert("L"), np.float32) / 255
        tri = trimap(coarse, inner=0.01, outer=args.outer)
        started = time.perf_counter()
        alpha, tiles = tiled(matter, image, tri)
        Image.fromarray((alpha * 255 + 0.5).astype(np.uint8)).save(hb.WORK / f"{scene}-{method}.png")
        print(f"{scene}: {tiles} tiles in {time.perf_counter() - started:.1f} s", flush=True)
    hb.score(["cf", method])


if __name__ == "__main__":
    main()
