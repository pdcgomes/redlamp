#!/usr/bin/env python3
"""RM-20's second way to a sharp generative fill: detail transfer. A fill made on a coarser pyramid
level keeps its shapes, and its fine texture is copied from the photo at full size, patch by patch,
each patch chosen by an exhaustive search guided by the upsampled fill (Hertzmann et al., "Image
Analogies", SIGGRAPH 2001, for the guided copy; Criminisi, Pérez and Toyama, 2004, for exhaustive
exemplar search, as content-aware fill does).

    python3 detail_transfer.py <dump folder> --seed 0 -o <fill folder>

The dump folder is what the prototype engine (branch rm-20/fill-prototypes) writes with
REDLAMP_FILL_DUMP: crop.json, the coarse crop and its fill in the photo's camera RGB, the area at
full size around the spot, and the coarse crop's whole extent at full size (context-*), which the
detail is copied from. The fill folder gets fill.json and fill.f32 over the spot's area, which
`redlamp render … --fill-import <spot>=<folder>` stores as the spot's fill, rendered without the
photo's noise added again: the copied detail carries it.

Everything is in the square root of linear camera RGB, as content-aware fill matches, where shot
noise is about the same at every brightness. With L a Gaussian low-pass at the coarse level's own
resolution, the fill is L(guide) + (photo - L(photo)) at the chosen source:

1. Every coarse texel of the hole, on a grid of every second texel, is matched against every
   candidate in the coarse crop (5 × 5 patches of the coarse fill against the photo's, outside the
   hole), by distances in a 24-dimensional projection of the patches; the 16 best are kept.
2. At full size, in raster order, each block of the hole (8 × 8 pixels, matched over the 16 × 16
   around it) takes the candidate, of those 16 moved up to 2 pixels either way, whose low-pass
   matches the guide's and whose detail matches what is already there: the photo's own outside
   the hole, and the blocks placed before it. Blocks are cut straight, not blended, so the copied
   detail keeps its contrast and its noise.

Needs numpy, scipy and torch (the search runs on the GPU through MPS when it's there).
"""

import argparse
import json
import pathlib
import time

import numpy as np
import torch
from scipy import ndimage


def load(folder, name, shape):
    return np.fromfile(folder / name, dtype=np.float32).reshape(shape)


def low_pass(image, sigma):
    return np.stack([ndimage.gaussian_filter(image[..., c], sigma, mode="reflect") for c in range(3)], axis=-1)


def patches(image, centres, half):
    """Flattened (2·half+1)² patches of `image` around `centres` (N × 2, x y), edges clamped."""
    h, w = image.shape[:2]
    offsets = np.arange(-half, half + 1)
    ys = np.clip(centres[:, 1, None, None] + offsets[None, :, None], 0, h - 1)
    xs = np.clip(centres[:, 0, None, None] + offsets[None, None, :], 0, w - 1)
    return image[ys, xs].reshape(len(centres), -1)


def coarse_matches(fill, photo, hole, k=16, half=2, dims=24, device="cpu"):
    """For every second coarse texel in `hole`, the `k` best source texels outside it."""
    h, w = hole.shape
    blocked = ndimage.binary_dilation(hole, iterations=half + 1)
    ys, xs = np.nonzero(~blocked)
    inside = (ys >= half) & (ys < h - half) & (xs >= half) & (xs < w - half)
    sources = np.stack([xs[inside], ys[inside]], axis=1)
    grid = np.zeros_like(hole)
    grid[::2, ::2] = True
    ty, tx = np.nonzero(ndimage.binary_dilation(hole, iterations=2) & grid)
    targets = np.stack([tx, ty], axis=1)
    a = patches(fill, targets, half)
    b = patches(photo, sources, half)
    mean = b.mean(axis=0)
    # A projection fitted on a sample of the sources.
    rng = np.random.default_rng(0)
    sample = b[rng.choice(len(b), size=min(len(b), 20000), replace=False)] - mean
    _, _, vt = np.linalg.svd(sample, full_matrices=False)
    basis = vt[:dims].T.astype(np.float32)
    pa = torch.from_numpy(((a - mean) @ basis).astype(np.float32)).to(device)
    pb = torch.from_numpy(((b - mean) @ basis).astype(np.float32)).to(device)
    nb = (pb * pb).sum(1)
    best = []
    for start in range(0, len(pa), 256):
        chunk = pa[start:start + 256]
        d = (chunk * chunk).sum(1, keepdim=True) + nb[None, :] - 2 * chunk @ pb.T
        best.append(torch.topk(d, k, dim=1, largest=False).indices.cpu().numpy())
    return targets, sources[np.concatenate(best)]


def transfer(dump, seed, out, sigma_scale=0.6, block=8, jitter=2, weight=2.0, device=None):
    started = time.time()
    info = json.loads((dump / "crop.json").read_text())
    crop, area = info["crop"], info["area"]
    context = json.loads((dump / "context.json").read_text())
    scale = crop["scale"]
    cw, ch = crop["width"], crop["height"]
    w, h = context["width"], context["height"]
    device = device or ("mps" if torch.backends.mps.is_available() else "cpu")

    photo_coarse = np.sqrt(np.maximum(load(dump, "crop-camera.f32", (ch, cw, 3)), 0))
    fill_coarse = np.sqrt(np.maximum(load(dump, f"crop-fill-camera-{seed}.f32", (ch, cw, 3)), 0))
    hole_coarse = load(dump, "crop-mask.f32", (ch, cw)) > 0.5
    # At full size over the coarse crop's whole extent: what the fill copies from.
    photo = np.sqrt(np.maximum(load(dump, "context-camera.f32", (h, w, 3)), 0))
    mask = load(dump, "context-mask.f32", (h, w)) > 0.5

    # The guide: the coarse fill upsampled bilinearly, inside the mask.
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float32)
    u = (context["x"] + xs + 0.5) / scale - 0.5 - crop["x"]
    v = (context["y"] + ys + 0.5) / scale - 0.5 - crop["y"]
    upsampled = np.stack([
        ndimage.map_coordinates(fill_coarse[..., c], [v, u], order=1, mode="nearest") for c in range(3)
    ], axis=-1)
    del xs, ys, u, v
    guide = np.where(mask[..., None], upsampled, photo)
    sigma = sigma_scale * scale
    guide_low, photo_low = low_pass(guide, sigma), low_pass(photo, sigma)
    detail = photo - photo_low

    targets, candidates = coarse_matches(fill_coarse, photo_coarse, hole_coarse, device=device)
    searched = time.time()

    # Sources at full size keep clear of the hole by a patch's reach.
    half = block
    forbidden = ndimage.binary_dilation(mask, iterations=half + jitter + 1)
    integral = np.pad(forbidden.astype(np.int32).cumsum(0).cumsum(1), ((1, 0), (1, 0)))

    def clear(x, y):
        x0, y0, x1, y1 = x - half, y - half, x + half + 1, y + half + 1
        if x0 < 0 or y0 < 0 or x1 > w or y1 > h:
            return False
        return integral[y1, x1] - integral[y0, x1] - integral[y1, x0] + integral[y0, x0] == 0

    # A coarse texel (in the crop) to a full-size pixel (in the context).
    shift = np.array([context["x"] - crop["x"] * scale, context["y"] - crop["y"] * scale], dtype=np.float32)

    def to_context(coarse):
        return (coarse + 0.5) * scale - 0.5 - shift

    target_full = to_context(targets.astype(np.float32))
    candidate_full = to_context(candidates.astype(np.float32))
    by_texel = {(int(x), int(y)): index for index, (x, y) in enumerate(targets)}

    def nearest(cx, cy):
        """The coarse target nearest a full-size pixel (targets lie on every second texel)."""
        tu = (context["x"] + cx + 0.5) / scale - 0.5 - crop["x"]
        tv = (context["y"] + cy + 0.5) / scale - 0.5 - crop["y"]
        tx, ty = int(round(tu / 2)) * 2, int(round(tv / 2)) * 2
        for radius in range(0, 6, 2):
            for dy in range(-radius, radius + 1, 2):
                for dx in range(-radius, radius + 1, 2):
                    if (tx + dx, ty + dy) in by_texel:
                        return by_texel[(tx + dx, ty + dy)]
        return None

    known = ~mask
    out_detail = np.where(known[..., None], detail, 0).astype(np.float32)
    offsets = np.arange(-half, half + 1)
    jitters = [(dx, dy) for dy in range(-jitter, jitter + 1) for dx in range(-jitter, jitter + 1)]
    blocks_y, blocks_x = np.nonzero(ndimage.binary_dilation(mask[block // 2::block, block // 2::block], iterations=1))
    placed = missed = 0
    for by, bx in sorted(zip(blocks_y.tolist(), blocks_x.tolist())):
        cx, cy = bx * block + block // 2, by * block + block // 2
        if cx >= w or cy >= h:
            continue
        index = nearest(cx, cy)
        options = []
        if index is not None:
            offset = np.array([cx, cy]) - target_full[index]
            for candidate in candidate_full[index]:
                base = np.round(candidate + offset).astype(int)
                for dx, dy in jitters:
                    sx, sy = base[0] + dx, base[1] + dy
                    if clear(sx, sy):
                        options.append((sx, sy))
        if not options:
            missed += 1
            continue
        options = np.array(options)
        ty = np.clip(cy + offsets[:, None], 0, h - 1)
        tx = np.clip(cx + offsets[None, :], 0, w - 1)
        target_low = guide_low[ty, tx].reshape(-1)
        target_detail = out_detail[ty, tx].reshape(-1)
        target_known = np.repeat(known[ty, tx].reshape(-1), 3)
        sy = options[:, 1, None, None] + offsets[None, :, None]
        sx = options[:, 0, None, None] + offsets[None, None, :]
        cost = ((photo_low[sy, sx].reshape(len(options), -1) - target_low) ** 2).mean(1)
        if target_known.any():
            source_detail = detail[sy, sx].reshape(len(options), -1)
            cost = cost + weight * (((source_detail - target_detail) ** 2)[:, target_known]).mean(1)
        sx0, sy0 = options[int(np.argmin(cost))]
        # The block itself, cut straight.
        y0, x0 = cy - block // 2, cx - block // 2
        rows = slice(max(y0, 0), min(y0 + block, h))
        columns = slice(max(x0, 0), min(x0 + block, w))
        source = detail[
            sy0 - block // 2 + rows.start - y0: sy0 - block // 2 + rows.stop - y0,
            sx0 - block // 2 + columns.start - x0: sx0 - block // 2 + columns.stop - x0,
        ]
        inside = mask[rows, columns]
        out_detail[rows, columns][inside] = source[inside]
        known[rows, columns] |= inside
        placed += 1

    result = np.where(mask[..., None], np.maximum(guide_low + out_detail, 0), photo)
    # The stored fill covers the spot's area, where the context reaches it.
    x0, y0 = max(area["x"], context["x"]), max(area["y"], context["y"])
    x1 = min(area["x"] + area["width"], context["x"] + w)
    y1 = min(area["y"] + area["height"], context["y"] + h)
    camera = (result[y0 - context["y"]:y1 - context["y"], x0 - context["x"]:x1 - context["x"]] ** 2).astype(np.float32)
    out.mkdir(parents=True, exist_ok=True)
    camera.tofile(out / "fill.f32")
    total = time.time() - started
    (out / "fill.json").write_text(json.dumps({
        "box": [x0, y0, x1 - x0, y1 - y0], "photo": info["photo"],
        "model": "detail-transfer", "noise": False,
        "seconds": {"search": round(searched - started, 2), "total": round(total, 2)},
        "blocks": placed, "missed": missed, "device": device,
    }, indent=2) + "\n")
    print(f"{dump.name}: {placed} blocks ({missed} without a source), search {searched - started:.1f} s, total {total:.1f} s on {device}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("dump", type=pathlib.Path)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("-o", "--out", type=pathlib.Path, required=True)
    parser.add_argument("--sigma", type=float, default=0.6, help="the low-pass, in coarse texels")
    parser.add_argument("--device")
    args = parser.parse_args()
    transfer(args.dump, args.seed, args.out, sigma_scale=args.sigma, device=args.device)


if __name__ == "__main__":
    main()
