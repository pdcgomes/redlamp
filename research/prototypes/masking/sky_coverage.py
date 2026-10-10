#!/usr/bin/env python3
"""Why the Sky mask covers too little of pixels inside the edge band, and what fixes it (MSK-28).

On edge_bench's 12 skies, today's Sky mask covers too little of pixels that are mostly branch,
which leaves a light rim where the sky is darkened. SkyMatte solves each edge pixel's coverage as
where its colour lies between the sky's colour behind it and the foreground's, in linear light;
a foreground colour that holds some sky makes every mixed pixel look less sky than it is, the
more so the more branch it is.

`refine` is SkyMatte.refine as it was in Swift, with switches for the changes tried. The true
colours come from replaying edge_bench.generate's random draws: the sky plate and the
foreground's colour behind every pixel.

What it found (10 October 2026): the sky's colour estimate is right; the bias is the second
pass's foreground colour, learnt from the foreground nearest each edge, which still holds a few
percent sky. SkyMatte now learns it only from pixels more than 2 px from any the pass took as
more than 0.15 sky, and leaves coverage from 0.12 to 0.88 where the colour puts it (`interior-dead1`).
Also counting sky the colour sees but the pass didn't take back (`interior-dead1-r`) recovers more
sky between dense twigs but takes snow under an overcast sky for sky on the evaluation set. The
coarse mask's few percent of sky kept over foreground beyond the band darkens dark foreground
under a sky edit; zeroing it (`floor`) loses sky in dense crowns, so SkyMatte now keeps it only as
far as the colour allows (`interior-dead1-floorc`). What sky is still left out (`missed`) is mostly
the X-S20 plate's vignetted sides, which the coarse mask left out and whose colour the sky
estimate carries in from brighter sky; the true sky colour (`oracle-sky`) would take the halo
from 2.10 to 1.99 dE.

    .venv/bin/python sky_coverage.py check                the port against the CLI's masks
    .venv/bin/python sky_coverage.py diagnose             where the bias comes from, per scene
    .venv/bin/python sky_coverage.py variants <name>...   each change on the 12 skies
    .venv/bin/python sky_coverage.py halo <name>...       their masks through the engine: halo and rim
    .venv/bin/python sky_coverage.py eval <label>         the CLI's Sky masks for the evaluation set
    .venv/bin/python sky_coverage.py compare <a> <b>      what changed between two of those, with sheets

The coarse masks (SkyMatte off) are build/mask-bench/sky-coverage/<scene>-coarse.png:

    REDLAMP_SKY_MATTE=off redlamp mask <scene>.png --kind sky -o <scene>-coarse.png
"""

import json
import os
import pathlib
import subprocess
import sys

import numpy as np
from PIL import Image
from scipy import ndimage

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import edge_bench as eb  # noqa: E402
import mask_bench as mb  # noqa: E402
from sky_matte import pull_push  # noqa: E402

OUT = mb.OUT / "sky-coverage"
TABLE = eb.srgb_to_linear(np.arange(256, dtype=np.float64) / 255).astype(np.float32)

BAND, REACH = 0.012, 0.06
TOLERANCE = (0.015, 0.06)
EDGE_REACH = 2
WALLED_OFF_LINE = 0.12
WALLED_PRIOR = 0.5 / 255


# MARK: - The truth

def replay():
    """Each scene's sky plate and foreground colour in linear light, from edge_bench.generate's
    draws replayed (the drawing itself takes no random numbers, so it is skipped)."""

    class Blank:
        def line(self, *_):
            pass

        def blob(self, *_):
            pass

        def polygon(self, *_):
            pass

        def coverage(self):
            return None, None

    drawn = eb.Canvas
    eb.Canvas = Blank
    try:
        plates = eb.photo_plates() + eb.synthetic_plates()
        kinds = ["bare", "leafy", "wires", "skyline"]
        rng = np.random.default_rng(2026)
        pairs = [(name, sky, kinds[(2 * index + k) % len(kinds)])
                 for index, (name, sky) in enumerate(plates) for k in (0, 1)]
        for name, sky, kind in pairs:
            eb.foreground(kind, rng)
            colour = eb.foreground_colour(rng, kind)
            rng.standard_normal((eb.HEIGHT, eb.WIDTH, 3))
            yield f"{kind}-{name}", sky.astype(np.float32), colour
    finally:
        eb.Canvas = drawn


def truth_colours(scene):
    path = OUT / f"{scene}-colours.npz"
    if not path.exists():
        OUT.mkdir(parents=True, exist_ok=True)
        for name, sky, colour in replay():
            np.savez_compressed(OUT / f"{name}-colours.npz", sky=sky.astype(np.float16), front=colour.astype(np.float16))
    data = np.load(path)
    return data["sky"].astype(np.float32), data["front"].astype(np.float32)


def scene_inputs(scene):
    rgb = np.asarray(Image.open(eb.WORK / f"{scene}.png").convert("RGB"))
    coarse = np.asarray(Image.open(OUT / f"{scene}-coarse.png").convert("L"))
    truth = np.load(eb.WORK / f"{scene}-truth.npz")
    return rgb, coarse, truth["sky"].astype(np.float32), truth["thin"].astype(np.float32)


# MARK: - SkyMatte, as in Swift

def resized(mask_u8, width, height):
    """GrayMask.resized(to:): bilinear between pixel centres, rounded to 8 bits."""
    h, w = mask_u8.shape
    if (w, h) == (width, height):
        return mask_u8.astype(np.float32) / 255
    fy = np.clip((np.arange(height) + 0.5) * (h / height) - 0.5, 0, h - 1)
    fx = np.clip((np.arange(width) + 0.5) * (w / width) - 0.5, 0, w - 1)
    y0, x0 = fy.astype(int), fx.astype(int)
    y1, x1 = np.minimum(y0 + 1, h - 1), np.minimum(x0 + 1, w - 1)
    ty, tx = (fy - y0)[:, None], (fx - x0)[None, :]
    m = mask_u8.astype(np.float64)
    top = m[y0][:, x0] * (1 - tx) + m[y0][:, x1] * tx
    bottom = m[y1][:, x0] * (1 - tx) + m[y1][:, x1] * tx
    return (np.floor(top * (1 - ty) + bottom * ty + 0.5) / 255).astype(np.float32)


def chamfer(inside, limit):
    """SkyMatte.distance: pixels from the boundary of `inside`, a 3-4 chamfer, capped."""
    h, w = inside.shape
    boundary = np.zeros_like(inside)
    boundary[:, 1:] |= inside[:, 1:] != inside[:, :-1]
    boundary[:, :-1] |= inside[:, :-1] != inside[:, 1:]
    boundary[1:] |= inside[1:] != inside[:-1]
    boundary[:-1] |= inside[:-1] != inside[1:]
    d = np.where(boundary, 0.0, (limit + 2) * 3).astype(np.float64)
    ramp = 3.0 * np.arange(w)
    for y in range(h):
        row = d[y]
        if y > 0:
            above = d[y - 1]
            row = np.minimum(row, above + 3)
            row[1:] = np.minimum(row[1:], above[:-1] + 4)
            row[:-1] = np.minimum(row[:-1], above[1:] + 4)
        d[y] = np.minimum.accumulate(row - ramp) + ramp
    for y in range(h - 1, -1, -1):
        row = d[y]
        if y < h - 1:
            below = d[y + 1]
            row = np.minimum(row, below + 3)
            row[:-1] = np.minimum(row[:-1], below[1:] + 4)
            row[1:] = np.minimum(row[1:], below[:-1] + 4)
        flipped = row[::-1]
        d[y] = (np.minimum.accumulate(flipped - ramp) + ramp)[::-1]
    return d / 3


def regions(mask):
    h, w = mask.shape
    long = max(w, h)
    sw, sh = max(1, w // 4), max(1, h // 4)
    xs = np.minimum(np.arange(sw) * 4 + 2, w - 1)
    ys = np.minimum(np.arange(sh) * 4 + 2, h - 1)
    small = mask[np.ix_(ys, xs)]
    reach = REACH * long
    distance = chamfer(small > 0.5, reach / 4)
    rows = np.minimum(np.arange(h) // 4, sh - 1)
    cols = np.minimum(np.arange(w) // 4, sw - 1)
    d = distance[np.ix_(rows, cols)] * 4
    band = max(4, BAND * long)
    near = (d <= band) | ((mask > 0.1) & (mask < 0.9))
    far = ~near & (d <= reach) & (mask <= 0.5)
    inside = ~near & (mask > 0.5)
    return near, far, inside


def sky_colour(linear, sky):
    """SkyColour: 4x4 block means where every pixel is sky, pull-pushed, read back bilinearly."""
    h, w = sky.shape
    sw, sh = max(1, w // 4), max(1, h // 4)
    blocks = linear[: sh * 4, : sw * 4].reshape(sh, 4, sw, 4, 3).mean(axis=(1, 3))
    weights = sky[: sh * 4, : sw * 4].reshape(sh, 4, sw, 4).all(axis=(1, 3)).astype(np.float32)
    filled = pull_push(blocks.astype(np.float32), weights)
    fx = (np.arange(w) + 0.5) / 4 - 0.5
    fy = (np.arange(h) + 0.5) / 4 - 0.5
    x0 = np.clip(np.floor(fx).astype(int), 0, sw - 1)
    y0 = np.clip(np.floor(fy).astype(int), 0, sh - 1)
    x1, y1 = np.minimum(x0 + 1, sw - 1), np.minimum(y0 + 1, sh - 1)
    tx = np.clip(fx - x0, 0, 1)[None, :, None]
    ty = np.clip(fy - y0, 0, 1)[:, None, None]
    top = filled[y0][:, x0] * (1 - tx) + filled[y0][:, x1] * tx
    bottom = filled[y1][:, x0] * (1 - tx) + filled[y1][:, x1] * tx
    return (top * (1 - ty) + bottom * ty).astype(np.float32)


def foreground_colour(linear, behind, sky, solid, levels=7, scale=None):
    separation = np.sqrt(((linear - behind) ** 2).sum(-1))
    distinct = np.where(sky, 0, np.clip((separation - 0.04) / 0.25, 0, 1)).astype(np.float32)
    weights = np.where(solid, distinct ** 3, 0).astype(np.float32)
    if scale is not None:
        weights *= scale
    if weights.sum() >= 1:
        return pull_push(linear, weights, levels=levels)
    weights = np.where(~sky, distinct ** 2, 0)
    if weights.sum() < 1:
        return None
    return np.broadcast_to((linear * weights[..., None]).sum(axis=(0, 1)) / weights.sum(), linear.shape)


def project(linear, behind, front):
    """Where each colour lies on the line from the foreground's colour to the sky's (0 at the
    foreground, 1 at the sky), how far apart the two are, and how far off the line it lies."""
    difference = behind - front
    span = (difference ** 2).sum(-1)
    projected = ((linear - front) * difference).sum(-1) / np.maximum(span, 1e-8)
    off = np.sqrt(((linear - front - projected[..., None] * difference) ** 2).sum(-1)) / np.maximum(np.sqrt(span), 1e-4)
    return projected, np.sqrt(span), off


def remap(projected, kind="linear"):
    if kind == "none":
        return np.clip(projected, 0, 1)
    if kind == "narrow":
        return np.clip((projected - 0.02) / 0.96, 0, 1)
    if kind == "dead":
        # 0 below 0.04 and 1 above 0.96, as today, so noise on pure foreground and sky stays
        # there; unchanged from 0.12 to 0.88; joined smoothly (cubic, matching slopes) between.
        a, b = 0.04, 0.12

        def low(p):
            t = np.clip((p - a) / (b - a), 0, 1)
            return np.where(p <= a, 0, np.where(p >= b, p, b * (3 * t * t - 2 * t ** 3) + (b - a) * (t ** 3 - t * t)))

        p = np.clip(projected, 0, 1)
        return np.where(p < 0.5, low(p), 1 - low(1 - p))
    if kind == "soft":
        # Unchanged between 0.1 and 0.9; noise about 0 and 1 still lands on 0 and 1.
        c = 0.1
        p = np.clip(projected, 0, 1)
        low = p * p * (2 * c - p) / (c * c)
        q = 1 - p
        high = 1 - q * q * (2 * c - q) / (c * c)
        return np.where(p < c, low, np.where(p > 1 - c, high, p))
    return np.clip((projected - 0.04) / 0.92, 0, 1)


def connected(region, seeds):
    labels, _ = ndimage.label(region)
    anchored = np.unique(labels[region & seeds])
    return np.isin(labels, anchored[anchored > 0])


def refine(rgb, coarse, solid_rule="today", remap_kind="linear", passes=2, keep=None, levels=7, distance=2, unsure=0.15,
           fallback=0.01, decide_kind=None, touched_by="result", floor=False, true_sky=None):
    """SkyMatte.refine. `keep`, if given, collects each pass's colours and solve. Coverage is
    written with `remap_kind`; what's sky, foreground and taken back is decided on
    `decide_kind`'s scale (the same, unless given)."""
    decide_kind = decide_kind or remap_kind
    h, w = rgb.shape[:2]
    mask = resized(coarse, w, h)
    near, far, inside = regions(mask)
    parts = {"near": near, "far": far, "inside": inside, "mask": mask}
    linear = TABLE[rgb]
    sky = (mask > 0.9) & ~near
    solid = (mask < 0.1) & ~near
    if not sky.any():
        return mask, parts
    seeds = mask > 0.5
    solved_region = near | far | inside
    if floor == "colour":
        # The coarse foreground beyond the reach is solved too, wherever the coarse mask has some
        # sky there.
        solved_region = solved_region | (mask > 0)
    result = mask
    scale = None
    for _ in range(passes):
        behind = sky_colour(linear, sky) if true_sky is None else true_sky
        front = foreground_colour(linear, behind, sky, solid, levels, scale)
        if front is None:
            return mask, parts
        projected, span, off = project(linear, behind, front)
        sure = np.clip((span - TOLERANCE[0]) / (TOLERANCE[1] - TOLERANCE[0]), 0, 1)
        refined = np.where(solved_region, sure * remap(projected, decide_kind) + (1 - sure) * mask, mask)
        written = np.where(solved_region, sure * remap(projected, remap_kind) + (1 - sure) * mask, mask)
        confidence = np.where(solved_region, sure, 0)
        off_line = np.where(solved_region, off, 1)
        likely = (refined > 0.5) & (near | far | (mask > 0.5))
        accepted = connected(likely, seeds) | (far & (refined > 0.9) & (confidence > 0.9)
                                               & (off_line < WALLED_OFF_LINE) & (mask > WALLED_PRIOR))
        edged = ndimage.binary_dilation(accepted, structure=np.ones((2 * EDGE_REACH + 1,) * 2, bool))
        intrusion = inside & (refined < 0.75) & (confidence > 0.5)
        chosen = near | (far & edged) | intrusion
        # `floor`: the coarse foreground not taken back is foreground, not the few percent of
        # sky a soft coarse mask leaves over it.
        if floor == "colour":
            # Coarse foreground not taken back keeps the coarse mask only where its colour isn't
            # sure it's foreground: the colour can lower it there, never raise it.
            kept = np.where(mask <= 0.5, np.minimum(mask, refined), mask)
        else:
            kept = np.where(mask > 0.5, mask, 0) if floor else mask
        output = np.where(chosen, written, kept)
        result = np.where(chosen, refined, kept)
        if keep is not None:
            keep.append({"behind": behind, "front": front, "projected": projected, "confidence": confidence,
                         "result": result, "solid": solid, "sky": sky, "refined": refined, "off_line": off_line,
                         "accepted": accepted})
        sky = ((result > 0.97) & (confidence > 0.5)) | ((mask > 0.9) & ~near & (result > 0.9))
        solid = (result < 0.03) & ((confidence > 0.5) | ~(near | far))
        if solid_rule in ("interior", "weighted"):
            # Only foreground a few pixels from anything with sky in it: mixed pixels sit within
            # a pixel or two of the edge. `weighted` keeps the others at `fallback` of the weight,
            # for foreground with no interior within reach.
            # `refined` also counts sky the colour sees but this pass didn't take back.
            touched = (result > unsure) | ((refined > unsure) if touched_by == "refined" else False)
            clear = ~ndimage.binary_dilation(touched, structure=np.ones((2 * distance + 1,) * 2, bool))
            if solid_rule == "interior":
                solid &= clear
            else:
                scale = np.where(clear, 1, fallback).astype(np.float32)
    return output.astype(np.float32), parts


# MARK: - Scores

BINS = ((0.05, 0.25), (0.25, 0.5), (0.5, 0.75), (0.75, 0.95))


def coverage_scores(result, truth, thin, near):
    scores = eb.score_mask(result, truth, thin)
    error = result - truth
    for low, high in BINS:
        pick = (truth > low) & (truth < high)
        scores[f"bias {low:.2f}-{high:.2f}"] = float(error[pick].mean())
        scores[f"bias in band {low:.2f}-{high:.2f}"] = float(error[pick & near].mean()) if (pick & near).any() else None
    branch = (truth > 0.05) & (truth < 0.5)
    sky = (truth >= 0.5) & (truth < 0.95)
    scores["bias branch"] = float(error[branch].mean())
    scores["bias sky"] = float(error[sky].mean())
    return scores


def scenes():
    return json.loads((eb.WORK / "scenes.json").read_text())


def check():
    """The port against the masks the CLI made (build/mask-bench/edge/<scene>-stored.png)."""
    for scene in scenes():
        rgb, coarse, truth, thin = scene_inputs(scene)
        result, parts = refine(rgb, coarse)
        swift = np.asarray(Image.open(mb.OUT / "edge" / f"{scene}-stored.png").convert("L"), np.float32) / 255
        ours = np.round(result * 255) / 255
        difference = np.abs(ours - swift)
        near = parts["near"]
        print(f"{scene:28s} differ by over 2 levels: {(difference > 2.5 / 255).mean():.5f} of pixels, "
              f"{(difference[near] > 2.5 / 255).mean():.5f} in the band; mean {difference[near].mean() * 255:.2f} levels; "
              f"band MAE swift {eb.score_mask(swift, truth, thin)['bandMAE']:.4f} port {eb.score_mask(ours, truth, thin)['bandMAE']:.4f}",
              flush=True)


def diagnose(name="today"):
    """Per scene, at band pixels mostly branch: the final bias, and what the coverage would be
    with the true colours, the true sky only, the true foreground only; how far the
    foreground estimate sits toward the sky (a share of the way), each pass."""
    print(f"{'scene':28s} {'final':>7s} | per pass: {'est':>6s} {'trueF':>6s} {'trueS':>6s} {'both':>6s} {'F->sky':>7s} {'F off':>6s}")
    for scene in scenes():
        rgb, coarse, truth, thin = scene_inputs(scene)
        sky_true, front_true = truth_colours(scene)
        keep = []
        result, parts = refine(rgb, coarse, keep=keep, **VARIANTS[name])
        linear = TABLE[rgb]
        pick = parts["near"] & (truth > 0.05) & (truth < 0.5)
        line = f"{scene:28s} {(result - truth)[pick].mean():+7.3f} |"
        for k in keep:
            est, _, _ = project(linear, k["behind"], k["front"])
            with_f, _, _ = project(linear, k["behind"], front_true)
            with_s, _, _ = project(linear, sky_true, k["front"])
            both, _, _ = project(linear, sky_true, front_true)
            d = sky_true - front_true
            share = ((k["front"] - front_true) * d).sum(-1) / np.maximum((d * d).sum(-1), 1e-8)
            _, _, off = project(k["front"], sky_true, front_true)
            line += (f" {(est - truth)[pick].mean():+6.3f} {(with_f - truth)[pick].mean():+6.3f}"
                     f" {(with_s - truth)[pick].mean():+6.3f} {(both - truth)[pick].mean():+6.3f}"
                     f" {np.median(share[pick]):+7.3f} {np.median(off[pick]):6.3f} |")
        print(line, flush=True)


def missed(name="interior-dead1"):
    """Per scene: the sure sky (truth at least 0.98) left out (under 0.5), by region, and what
    keeps it out where it is in the reach: no sky seen by the models (coarse 0), or colours that
    fail the walled-in test (refined over 0.9, sure of the colours, near the line); and the
    coverage left on pure foreground (truth at most 0.02) beyond the band."""
    print(f"{'scene':28s} {'missed':>7s} {'near':>6s} {'far':>6s} {'other':>6s} | far: {'coarse0':>7s} {'colourOK':>8s} {'both':>6s} | floor far {'other':>6s}")
    for scene in scenes():
        rgb, coarse, truth, thin = scene_inputs(scene)
        keep = []
        result, parts = refine(rgb, coarse, keep=keep, **VARIANTS[name])
        k = keep[-1]
        near, far, inside, mask = parts["near"], parts["far"], parts["inside"], parts["mask"]
        other = ~(near | far | inside)
        sure_sky = truth >= 0.98
        lost = sure_sky & (result < 0.5)
        n = max(sure_sky.sum(), 1)
        lost_far = lost & far
        colour_ok = (k["refined"] > 0.9) & (k["confidence"] > 0.9) & (k["off_line"] < WALLED_OFF_LINE)
        prior = mask > WALLED_PRIOR
        m = max(lost_far.sum(), 1)
        pure = truth <= 0.02
        print(f"{scene:28s} {lost.sum() / n:7.4f} {(lost & near).sum() / n:6.4f} {lost_far.sum() / n:6.4f} {(lost & other).sum() / n:6.4f} |"
              f" {(lost_far & ~prior).sum() / m:7.2f} {(lost_far & colour_ok).sum() / m:8.2f} {(lost_far & colour_ok & ~prior).sum() / m:6.2f} |"
              f" {result[pure & far].mean() if (pure & far).any() else 0:9.4f} {result[pure & other].mean() if (pure & other).any() else 0:6.4f}",
              flush=True)


VARIANTS = {
    "today": {},
    "interior": {"solid_rule": "interior"},
    "soft": {"remap_kind": "soft"},
    "interior-soft": {"solid_rule": "interior", "remap_kind": "soft"},
    "interior-soft-3": {"solid_rule": "interior", "remap_kind": "soft", "passes": 3},
    "interior-soft-l9": {"solid_rule": "interior", "remap_kind": "soft", "levels": 9},
    "weighted": {"solid_rule": "weighted"},
    "weighted-soft": {"solid_rule": "weighted", "remap_kind": "soft"},
    "interior-softp": {"solid_rule": "interior", "remap_kind": "soft", "decide_kind": "linear"},
    "interior-narrow": {"solid_rule": "interior", "remap_kind": "narrow", "decide_kind": "linear"},
    "weighted-softp": {"solid_rule": "weighted", "remap_kind": "soft", "decide_kind": "linear"},
    "interior-d3": {"solid_rule": "interior", "distance": 3},
    "interior-u05": {"solid_rule": "interior", "unsure": 0.05},
    "interior-dead": {"solid_rule": "interior", "remap_kind": "dead", "decide_kind": "linear"},
    "interior-dead1": {"solid_rule": "interior", "remap_kind": "dead"},
    "interior-dead1-r": {"solid_rule": "interior", "remap_kind": "dead", "touched_by": "refined"},
    "interior-dead1-r-floor": {"solid_rule": "interior", "remap_kind": "dead", "touched_by": "refined", "floor": True},
    "floor": {"floor": True},
    "interior-dead1-floorc": {"solid_rule": "interior", "remap_kind": "dead", "floor": "colour"},
    "interior-dead1-floor": {"solid_rule": "interior", "remap_kind": "dead", "floor": True},
    "oracle-sky": {"solid_rule": "interior", "remap_kind": "dead", "true_sky": True},
}


def variants(names):
    rows = {}
    for name in names:
        options = VARIANTS[name]
        out = OUT / name
        out.mkdir(parents=True, exist_ok=True)
        rows[name] = {}
        for scene in scenes():
            rgb, coarse, truth, thin = scene_inputs(scene)
            given = {**options, "true_sky": truth_colours(scene)[0]} if options.get("true_sky") else options
            result, parts = refine(rgb, coarse, **given)
            Image.fromarray(np.round(np.clip(result, 0, 1) * 255).astype(np.uint8)).save(out / f"{scene}-stored.png")
            rows[name][scene] = coverage_scores(np.round(result * 255) / 255, truth, thin, parts["near"])
            s = rows[name][scene]
            print(f"{name:14s} {scene:28s} bias branch {s['bias branch']:+.3f} sky {s['bias sky']:+.3f}  band {s['bandMAE']:.4f}"
                  f"  thin {s['thinMAE']:.3f}  recall {s['thinRecall']:.3f}  leak {s['leak']:.4f}", flush=True)
        mean = lambda key: np.mean([r[key] for r in rows[name].values() if r[key] is not None])  # noqa: E731
        print(f"{name:14s} {'mean':28s} bias branch {mean('bias branch'):+.3f} sky {mean('bias sky'):+.3f}  band {mean('bandMAE'):.4f}"
              f"  thin {mean('thinMAE'):.3f}  recall {mean('thinRecall'):.3f}  leak {mean('leak'):.4f}", flush=True)
    report = OUT / "variants.json"
    previous = json.loads(report.read_text()) if report.exists() else {}
    previous.update(rows)
    report.write_text(json.dumps(previous, indent=1))


def halo(names):
    """Each variant's masks through the engine: the scene's linear DNG edited by Exposure -1.5
    through the mask (process 14's edge-aware application), against the ideal edit, as
    mask_bench.py scores it. Needs `mask_bench.py run --sets edge` once, for the DNGs and the
    ideal renders."""
    edge = mb.OUT / "edge"
    report = OUT / "halo.json"
    previous = json.loads(report.read_text()) if report.exists() else {}
    for name in names:
        rows = {}
        for scene in scenes():
            mask = OUT / name / f"{scene}-stored.png"
            edit = OUT / name / f"{scene}-edit.png"
            mb.redlamp(mb.CLI, "render", edge / f"{scene}.dng", "--mask-bitmap", f"sky={mask}",
                       "--mask-set", f"local.exposure={eb.EDIT_EV}", "--16bit", "-o", edit)
            truth = np.load(eb.WORK / f"{scene}-truth.npz")["sky"].astype(np.float32)
            rows[scene] = mb.halo(edit, edge / f"{scene}-ideal-render.png", truth)
            print(f"{name:16s} {scene:28s} halo {rows[scene]['haloDE']:.2f} dE  rim {rows[scene]['rimL']:+.2f} L*", flush=True)
        mean = lambda key: np.mean([r[key] for r in rows.values()])  # noqa: E731
        spread = max(abs(r["rimL"]) for r in rows.values())
        print(f"{name:16s} {'mean':28s} halo {mean('haloDE'):.2f} dE  rim {mean('rimL'):+.2f} L*  (largest rim {spread:.2f})", flush=True)
        previous[name] = rows
        report.write_text(json.dumps(previous, indent=1))


# MARK: - The evaluation set

def eval_masks(label):
    """The Sky mask, from the CLI at $REDLAMP_CLI (else mask_bench.CLI), for every photo of the
    evaluation set whose cell tests Sky, into build/mask-bench/sky-coverage/eval-<label>/."""
    cli = pathlib.Path(os.environ.get("REDLAMP_CLI", mb.CLI))
    out = OUT / f"eval-{label}"
    out.mkdir(parents=True, exist_ok=True)
    for path, stem, cell, masks in mb.eval_photos():
        target = out / f"{stem}-sky.png"
        if "sky" not in masks or target.exists():
            continue
        try:
            mb.redlamp(cli, "mask", path, "--kind", "sky", "-o", target)
        except RuntimeError as error:
            print(f"{stem}: {str(error).splitlines()[-1][-160:]}", flush=True)
            continue
        print(f"{stem}: done", flush=True)


def eval_port(stems, names):
    """The port's variants on evaluation photos that are JPEGs, into eval-port-<variant>/: the
    photo resized to the CLI's mask (the engine solves on its render at that size), the coarse
    mask from the CLI with SkyMatte off. `eval-port-today` against `eval-baseline` shows how
    close the port comes on real photos."""
    from PIL import ImageOps

    cli = pathlib.Path(os.environ.get("REDLAMP_CLI", mb.CLI))
    coarse_dir = OUT / "eval-coarse"
    coarse_dir.mkdir(parents=True, exist_ok=True)
    photos = {stem: path for path, stem, cell, masks in mb.eval_photos() if "sky" in masks}
    for stem in stems:
        path = photos[stem]
        coarse_path = coarse_dir / f"{stem}.png"
        if not coarse_path.exists():
            subprocess.run([str(cli), "mask", str(path), "--kind", "sky", "-o", str(coarse_path)], check=True,
                           capture_output=True, env={**os.environ, "REDLAMP_SKY_MATTE": "off"})
        size = Image.open(OUT / "eval-baseline" / f"{stem}-sky.png").size
        rgb = np.asarray(ImageOps.exif_transpose(Image.open(path)).convert("RGB").resize(size, Image.LANCZOS))
        coarse = np.asarray(Image.open(coarse_path).convert("L"))
        for name in names:
            out = OUT / f"eval-port-{name}"
            out.mkdir(parents=True, exist_ok=True)
            result, _ = refine(rgb, coarse, **VARIANTS[name])
            Image.fromarray(np.round(np.clip(result, 0, 1) * 255).astype(np.uint8)).save(out / f"{stem}-sky.png")
        print(f"{stem}: done", flush=True)


def eval_compare(before, after):
    """How much sky each photo gains and loses from `before` to `after` (over a quarter of
    coverage), and a sheet per cell, each photo where the two differ most: the photo, then the
    two masks over mid-grey."""
    out = OUT / f"eval-{before}-vs-{after}"
    out.mkdir(parents=True, exist_ok=True)
    report, rows = {}, {}
    for path, stem, cell, masks in mb.eval_photos():
        a, b = OUT / f"eval-{before}" / f"{stem}-sky.png", OUT / f"eval-{after}" / f"{stem}-sky.png"
        if "sky" not in masks or not a.exists() or not b.exists():
            continue
        first = np.asarray(Image.open(a).convert("L"), np.float32) / 255
        second = np.asarray(Image.open(b).convert("L"), np.float32) / 255
        size = (first.shape[1], first.shape[0])
        change = second - first
        mixed = (first > 0.02) & (first < 0.98)
        report[stem] = {"cell": cell, "gained": float((change > 0.25).mean()), "lost": float((change < -0.25).mean()),
                        "meanChangeAtMixed": float(change[mixed].mean()) if mixed.any() else 0.0}
        preview = mb.OUT / "eval" / f"{stem}-photo.jpg"
        photo = np.asarray(Image.open(preview if preview.exists() else path).convert("RGB").resize(size, Image.LANCZOS),
                           np.float32)
        height, width = min(400, size[1]), min(600, size[0])
        summed = ndimage.uniform_filter(np.abs(change), size=(height, width), mode="constant")
        y, x = np.unravel_index(np.argmax(summed), summed.shape)
        y0, x0 = int(np.clip(y - height // 2, 0, size[1] - height)), int(np.clip(x - width // 2, 0, size[0] - width))
        crop = photo[y0:y0 + height, x0:x0 + width]

        def over_grey(matte):
            m = matte[y0:y0 + height, x0:x0 + width, None]
            return m * crop + (1 - m) * 128

        rows.setdefault(cell, []).append(np.concatenate(
            [np.pad(p, ((0, 6), (0, 6), (0, 0)), constant_values=255) for p in (crop, over_grey(first), over_grey(second))],
            axis=1))
        r = report[stem]
        print(f"{stem:40s} {cell:20s} gained {r['gained']:.4f}  lost {r['lost']:.4f}  mean change at mixed {r['meanChangeAtMixed']:+.3f}",
              flush=True)
    for cell, cell_rows in rows.items():
        width = max(r.shape[1] for r in cell_rows)
        Image.fromarray(np.concatenate(
            [np.pad(r, ((0, 0), (0, width - r.shape[1]), (0, 0)), constant_values=255) for r in cell_rows], axis=0,
        ).astype(np.uint8)).save(out / f"{cell}.jpg", quality=88)
    (out / "report.json").write_text(json.dumps(report, indent=1))


if __name__ == "__main__":
    command = sys.argv[1:2]
    if command == ["check"]:
        check()
    elif command == ["diagnose"]:
        diagnose(*sys.argv[2:3])
    elif command == ["missed"]:
        missed(*sys.argv[2:3])
    elif command == ["variants"]:
        variants(sys.argv[2:] or list(VARIANTS))
    elif command == ["halo"]:
        halo(sys.argv[2:])
    elif command == ["eval"]:
        eval_masks(sys.argv[2])
    elif command == ["compare"]:
        eval_compare(sys.argv[2], sys.argv[3])
    elif command == ["eval-port"]:
        # eval-port <variant>[,<variant>...] <stem>...
        eval_port(sys.argv[3:], sys.argv[2].split(","))
    else:
        sys.exit(__doc__)
