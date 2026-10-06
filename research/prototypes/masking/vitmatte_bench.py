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

`eval` makes, with redlamp and ViTMatte (REDLAMP_EVALUATION_MODELS=1), the Subject and People
masks of every photo in the evaluation set whose cell tests them, beside the closed-form ones
`mask_bench.py eval` made, and writes to build/mask-bench/eval-vitmatte/: the masks, report.json
(per photo: the time, and the mean difference between the two over their edges) and a sheet per
cell, each photo at 100% where the two differ most: the photo, then closed-form's matte and
ViTMatte's over mid-grey.

    .venv/bin/python vitmatte_bench.py eval

`strands` keeps closed-form's matte and adds only the thin part of what ViTMatte adds to it: what
a grey opening (erosion, then dilation) by a square `2r + 1` px wide removes from the addition,
so strands stay and patches of background drop out. It scores that on the heads for r = 2, 3 and
5, and, for --radius, writes build/mask-bench/eval-strands/: how much each evaluation photo's
matte gains over closed-form's, and a sheet per cell where it gains most (the photo, closed-form's
matte, then the result, over mid-grey).

    .venv/bin/python vitmatte_bench.py strands [--radius 3]
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


class CoreMLMatter:
    """The converted model (convert_vitmatte.py), on 1024 px tiles."""

    def __init__(self, path, units):
        import coremltools as ct

        units = {"gpu": ct.ComputeUnit.CPU_AND_GPU, "all": ct.ComputeUnit.ALL}[units]
        self.model = ct.models.MLModel(str(path), compute_units=units)

    def __call__(self, image, tri):
        feed = {
            "image": (image.astype(np.float32) / 255).transpose(2, 0, 1)[None],
            "trimap": tri.astype(np.float32)[None, None],
        }
        return np.clip(self.model.predict(feed)["alpha"][0, 0], 0, 1)


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


def evaluation_set(folder="eval-vitmatte"):
    import os
    import subprocess

    import mask_bench as mb
    from scipy import ndimage

    out = mb.OUT / folder
    (out / "sheets").mkdir(parents=True, exist_ok=True)
    report = {}
    rows = {}
    environment = {**os.environ, "REDLAMP_EVALUATION_MODELS": "1"}
    # Masks an earlier run made keep the time it logged.
    log = hb.ROOT / "build/logs/masking-vitmatte-eval.log"
    logged = {}
    if log.exists():
        for line in log.read_text().splitlines():
            parts = line.split(": ")
            if len(parts) == 2 and " s, difference " in parts[1]:
                logged[parts[0]] = float(parts[1].split(" s,")[0])
    for path, stem, cell, masks in mb.eval_photos():
        for kind in (k for k in ("subject", "people") if k in masks):
            made = sorted(out.glob(f"{stem}-{kind}*.png"))
            if made and f"{stem} {kind}" in logged:
                seconds = logged[f"{stem} {kind}"]
            else:
                started = time.perf_counter()
                result = subprocess.run(
                    [str(mb.CLI), "mask", str(path), "--kind", kind, "-o", str(out / f"{stem}-{kind}.png")],
                    capture_output=True, text=True, env=environment,
                )
                seconds = time.perf_counter() - started
                made = sorted(out.glob(f"{stem}-{kind}*.png"))
                if result.returncode != 0 or not made:
                    report[f"{stem} {kind}"] = {"cell": cell, "failed": (result.stderr or result.stdout).strip()[-160:]}
                    continue
            size = Image.open(made[0]).size
            vit = np.max([np.asarray(Image.open(p).convert("L").resize(size, Image.BILINEAR), np.float32) / 255
                          for p in made], axis=0)
            closed = mb.eval_mask(stem, kind, size)
            if closed is None:
                report[f"{stem} {kind}"] = {"cell": cell, "seconds": seconds, "failed": "no closed-form mask"}
                continue
            edge = ndimage.binary_dilation(
                ((closed > 0.02) & (closed < 0.98)) | ((vit > 0.02) & (vit < 0.98)), iterations=2,
            )
            difference = np.abs(vit - closed)
            report[f"{stem} {kind}"] = {
                "cell": cell, "seconds": round(seconds, 1),
                "difference": float(difference[edge].mean()) if edge.any() else 0.0,
                "added": float(((vit - closed) > 0.25).mean()), "removed": float(((closed - vit) > 0.25).mean()),
            }
            preview = mb.OUT / "eval" / f"{stem}-photo.jpg"
            source = preview if preview.exists() else path
            photo = np.asarray(Image.open(source).convert("RGB").resize(size, Image.LANCZOS), np.float32)
            height, width = min(400, size[1]), min(600, size[0])
            summed = ndimage.uniform_filter(difference, size=(height, width), mode="constant")
            y, x = np.unravel_index(np.argmax(summed), summed.shape)
            y0 = int(np.clip(y - height // 2, 0, size[1] - height))
            x0 = int(np.clip(x - width // 2, 0, size[0] - width))
            crop = photo[y0:y0 + height, x0:x0 + width]

            def over_grey(matte):
                a = matte[y0:y0 + height, x0:x0 + width, None]
                return a * crop + (1 - a) * 128

            panels = [crop, over_grey(closed), over_grey(vit)]
            row = np.concatenate([np.pad(p, ((0, 6), (0, 6), (0, 0)), constant_values=255) for p in panels], axis=1)
            rows.setdefault(cell, []).append(row)
            print(f"{stem} {kind}: {seconds:.1f} s, difference {report[f'{stem} {kind}']['difference']:.3f}", flush=True)
    (out / "report.json").write_text(json.dumps(report, indent=1))
    for cell, cell_rows in rows.items():
        width = max(r.shape[1] for r in cell_rows)
        sheet = np.concatenate([np.pad(r, ((0, 0), (0, width - r.shape[1]), (0, 0)), constant_values=255)
                                for r in cell_rows], axis=0)
        Image.fromarray(sheet.astype(np.uint8)).save(out / "sheets" / f"{cell}.jpg", quality=88)
    made = [r for r in report.values() if "difference" in r]
    print(f"\n{len(made)} masks with ViTMatte, {len(report) - len(made)} not; median {np.median([r['seconds'] for r in made]):.1f} s")
    for cell in sorted({r["cell"] for r in made}):
        cell_rows = [r for r in made if r["cell"] == cell]
        print(f"  {cell:24s} n={len(cell_rows):2d}  difference {np.mean([r['difference'] for r in cell_rows]):.3f}"
              f"  added {np.mean([r['added'] for r in cell_rows]):.4f}  removed {np.mean([r['removed'] for r in cell_rows]):.4f}")


def thin_part(extra, radius):
    """What a grey opening by a square 2r + 1 px wide removes from `extra`: its strands."""
    from scipy import ndimage

    size = (2 * radius + 1, 2 * radius + 1)
    return extra - ndimage.grey_dilation(ndimage.grey_erosion(extra, size=size), size=size)


def with_strands(closed, vit, radius):
    return np.clip(closed + thin_part(np.clip(vit - closed, 0, 1), radius), 0, 1)


def strands(radius):
    import mask_bench as mb
    from scipy import ndimage

    vit_method = "vitmatte-coreml-ViTMatteBaseW8B32-1024-gpu-0.05"
    methods = []
    for r in (2, 3, 5):
        for scene in json.loads((hb.WORK / "scenes.json").read_text()):
            def load(method):
                return np.asarray(Image.open(hb.WORK / f"{scene}-{method}.png").convert("L"), np.float32) / 255

            out = with_strands(load("cf"), load(vit_method), r)
            Image.fromarray((out * 255 + 0.5).astype(np.uint8)).save(hb.WORK / f"{scene}-strands-r{r}.png")
        methods.append(f"strands-r{r}")
    hb.score(["cf", vit_method, *methods])

    out = mb.OUT / "eval-strands"
    (out / "sheets").mkdir(parents=True, exist_ok=True)
    report = json.loads((mb.OUT / "eval-vitmatte" / "report.json").read_text())
    photos = {stem: (path, cell) for path, stem, cell, _ in mb.eval_photos()}
    rows, gains = {}, {}
    for key, entry in report.items():
        if "difference" not in entry:
            continue
        stem, kind = key.rsplit(" ", 1)
        made = sorted((mb.OUT / "eval-vitmatte").glob(f"{stem}-{kind}*.png"))
        size = Image.open(made[0]).size
        vit = np.max([np.asarray(Image.open(p).convert("L").resize(size, Image.BILINEAR), np.float32) / 255
                      for p in made], axis=0)
        closed = mb.eval_mask(stem, kind, size)
        result = with_strands(closed, vit, radius)
        gain = result - closed
        gains[key] = {"cell": entry["cell"], "added": float((gain > 0.25).mean()),
                      "vitmatteAdded": entry["added"]}
        path, cell = photos[stem]
        preview = mb.OUT / "eval" / f"{stem}-photo.jpg"
        source = preview if preview.exists() else path
        photo = np.asarray(Image.open(source).convert("RGB").resize(size, Image.LANCZOS), np.float32)
        height, width = min(400, size[1]), min(600, size[0])
        summed = ndimage.uniform_filter(gain, size=(height, width), mode="constant")
        y, x = np.unravel_index(np.argmax(summed), summed.shape)
        y0 = int(np.clip(y - height // 2, 0, size[1] - height))
        x0 = int(np.clip(x - width // 2, 0, size[0] - width))
        crop = photo[y0:y0 + height, x0:x0 + width]

        def over_grey(matte):
            a = matte[y0:y0 + height, x0:x0 + width, None]
            return a * crop + (1 - a) * 128

        panels = [crop, over_grey(closed), over_grey(result)]
        rows.setdefault(cell, []).append(
            np.concatenate([np.pad(p, ((0, 6), (0, 6), (0, 0)), constant_values=255) for p in panels], axis=1))
    for cell, cell_rows in rows.items():
        width = max(r.shape[1] for r in cell_rows)
        sheet = np.concatenate([np.pad(r, ((0, 0), (0, width - r.shape[1]), (0, 0)), constant_values=255)
                                for r in cell_rows], axis=0)
        Image.fromarray(sheet.astype(np.uint8)).save(out / "sheets" / f"{cell}.jpg", quality=88)
    (out / "report.json").write_text(json.dumps(gains, indent=1))
    print(f"\nevaluation set, r = {radius}: share of each frame covered over a quarter more than closed-form's")
    for cell in sorted({g["cell"] for g in gains.values()}):
        cell_gains = [g for g in gains.values() if g["cell"] == cell]
        print(f"  {cell:24s} n={len(cell_gains):2d}  with strands {np.mean([g['added'] for g in cell_gains]):.4f}"
              f"  ViTMatte {np.mean([g['vitmatteAdded'] for g in cell_gains]):.4f}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("command", nargs="?", default="heads", choices=("heads", "portraits", "eval", "strands"))
    parser.add_argument("--radius", type=int, default=3)
    parser.add_argument("--folder", default="eval-vitmatte", help="where `eval` writes, under build/mask-bench")
    parser.add_argument("--model", default="base", choices=("small", "base"))
    parser.add_argument("--outer", type=float, default=0.02)
    parser.add_argument("--coreml", type=pathlib.Path, help="a converted package instead of the PyTorch model")
    parser.add_argument("--units", default="gpu", choices=("gpu", "all"))
    args = parser.parse_args()
    if args.command == "eval":
        evaluation_set(args.folder)
        return
    if args.command == "strands":
        strands(args.radius)
        return
    matter = CoreMLMatter(args.coreml, args.units) if args.coreml else Matter(args.model)
    if args.command == "portraits":
        portraits(matter, args.outer)
        return
    model = f"coreml-{args.coreml.stem}-{args.units}" if args.coreml else args.model
    method = f"vitmatte-{model}-{args.outer:g}"
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
