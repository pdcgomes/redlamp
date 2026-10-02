#!/usr/bin/env python3
"""Sky edge matting prototype: a coarse sky mask in, per-pixel sky coverage out, at 4096 px.

Sky is smooth, so the colour of the sky behind any pixel can be estimated from the sure sky
around it; so can the foreground's, from sure foreground. A pixel's coverage is then where its
colour lies between the two, in linear light (where mixing happens):

    alpha = dot(I - F, B - F) / |B - F|^2

which is blue-screen matting with a known, smoothly varying backing (Smith and Blinn, 1996).
Only an uncertain band around the coarse edge is solved; where sky and foreground colours are
too close to tell apart, the coarse mask stays.

    research/prototypes/masking/.venv/bin/python research/prototypes/masking/sky_matte.py <coarse method>...

reads build/edge-bench/<scene>-<method>.png for every scene, writes <scene>-<method>+matte.png.
`refine` is what SkyMatte.swift ports. `refine_subject` is the same idea for people and hair
(research only: see the MSK-17 note), scored by hair_bench.py; `refine_guided` the colour guided
filter it was compared with.
"""

import json
import pathlib
import sys
import time

import numpy as np
from PIL import Image
from scipy import ndimage

ROOT = pathlib.Path(__file__).resolve().parents[3]
WORK = ROOT / "build/edge-bench"


def srgb_to_linear(x):
    return np.where(x <= 0.04045, x / 12.92, ((x + 0.055) / 1.055) ** 2.4)


def pull_push(values, weights, levels=None):
    """Fills `values` (H, W, C) where `weights` (H, W) is 0 from the weighted values nearby,
    coarse to fine (the pull-push of Gortler et al., 1996)."""
    pyramid = []
    v, w = values * weights[..., None], weights.astype(np.float32)
    while min(w.shape) > 1 and (levels is None or len(pyramid) < levels):
        pyramid.append((v, w))
        h, wd = w.shape
        h2, w2 = (h + 1) // 2, (wd + 1) // 2
        pad_v = np.zeros((h2 * 2, w2 * 2, v.shape[2]), np.float32)
        pad_w = np.zeros((h2 * 2, w2 * 2), np.float32)
        pad_v[:h, :wd], pad_w[:h, :wd] = v, w
        v = pad_v.reshape(h2, 2, w2, 2, -1).sum(axis=(1, 3))
        w = pad_w.reshape(h2, 2, w2, 2).sum(axis=(1, 3))
    filled = v / np.maximum(w, 1e-6)[..., None]
    for v, w in reversed(pyramid):
        up = np.repeat(np.repeat(filled, 2, axis=0), 2, axis=1)[: w.shape[0], : w.shape[1]]
        up = ndimage.uniform_filter(up, size=(3, 3, 1))
        mean = v / np.maximum(w, 1e-6)[..., None]
        confidence = np.minimum(w, 1)[..., None]
        filled = confidence * mean + (1 - confidence) * up
    return filled


def without_strands(linear, front, size=7):
    """The background behind each pixel with strands narrower than `size` taken out: a grey-level
    closing erases dark ones, an opening light ones; of the two, the one further from the
    subject's colour."""
    closed = np.stack([ndimage.grey_closing(linear[..., c], size=size) for c in range(3)], -1)
    opened = np.stack([ndimage.grey_opening(linear[..., c], size=size) for c in range(3)], -1)
    far_closed = ((closed - front) ** 2).sum(-1)
    far_opened = ((opened - front) ** 2).sum(-1)
    return np.where((far_closed >= far_opened)[..., None], closed, opened)


def colours(linear, sky, solid, w, h, separation=0.04):
    """The sky and foreground colours behind every pixel: the sky from a quarter of the size (it
    is smooth), the foreground at full size but only a few levels up (it varies more). Foreground
    samples close to the sky's colour there are left out: inside a crown the coarse mask cut out
    whole, they are sky seen between twigs."""
    small = (w // 4, h // 4)
    sky_small = np.asarray(Image.fromarray(sky.astype(np.uint8) * 255).resize(small, Image.BOX), np.float32) / 255
    linear_small = np.stack([np.asarray(Image.fromarray(linear[..., c]).resize(small, Image.BOX)) for c in range(3)], -1)
    behind = pull_push(linear_small, (sky_small > 0.99).astype(np.float32))
    behind = np.stack([np.asarray(Image.fromarray(behind[..., c].astype(np.float32)).resize((w, h), Image.BILINEAR))
                       for c in range(3)], -1)
    # Weighted by how far from the sky's colour, so pure foreground outweighs pixels mixed with sky.
    distinct = np.clip((np.sqrt(((linear - behind) ** 2).sum(-1)) - separation) / 0.25, 0, 1) ** 3
    # Any pixel not sure sky can show the foreground's colour; pure ones count most.
    weights = solid * distinct
    if weights.sum() >= 1:
        return behind, pull_push(linear, weights, levels=7)
    # No sure foreground (every trunk inside the band): one colour for it, from the purest
    # pixels that aren't sure sky. Learnt locally, each pixel would learn its own colour.
    weights = (~sky) * distinct ** 2
    if weights.sum() < 1:
        return behind, None
    colour = (linear * weights[..., None]).sum(axis=(0, 1)) / weights.sum()
    return behind, np.broadcast_to(colour, linear.shape)


def solve(linear, behind, front, tolerance):
    difference = behind - front
    span = (difference ** 2).sum(-1)
    alpha = ((linear - front) * difference).sum(-1) / np.maximum(span, 1e-8)
    alpha = np.clip((alpha - 0.04) / 0.92, 0, 1)
    confidence = np.clip((np.sqrt(span) - tolerance[0]) / (tolerance[1] - tolerance[0]), 0, 1)
    return alpha, confidence


def without_strands(linear, front, size=7):
    """The background behind each pixel with strands narrower than `size` taken out: a grey-level
    closing erases dark ones, an opening light ones; of the two, the one further from the
    subject's colour."""
    closed = np.stack([ndimage.grey_closing(linear[..., c], size=size) for c in range(3)], -1)
    opened = np.stack([ndimage.grey_opening(linear[..., c], size=size) for c in range(3)], -1)
    far_closed = ((closed - front) ** 2).sum(-1)
    far_opened = ((opened - front) ** 2).sum(-1)
    return np.where((far_closed >= far_opened)[..., None], closed, opened)


def smooth_colour(linear, samples, w, h):
    """The colour of `samples` behind every pixel, from 4x4 blocks entirely made of them, spread
    by pull-push and read back bilinearly."""
    small = (w // 4, h // 4)
    weight = np.asarray(Image.fromarray(samples.astype(np.uint8) * 255).resize(small, Image.BOX), np.float32) / 255
    linear_small = np.stack([np.asarray(Image.fromarray(linear[..., c]).resize(small, Image.BOX)) for c in range(3)], -1)
    filled = pull_push(linear_small, (weight > 0.99).astype(np.float32))
    return np.stack([np.asarray(Image.fromarray(filled[..., c].astype(np.float32)).resize((w, h), Image.BILINEAR))
                     for c in range(3)], -1)


def colours(linear, sky, solid, w, h, separation=0.04):
    """The sky and foreground colours behind every pixel: the sky from a quarter of the size (it
    is smooth), the foreground at full size but only a few levels up (it varies more). Foreground
    samples close to the sky's colour there are left out: inside a crown the coarse mask cut out
    whole, they are sky seen between twigs."""
    small = (w // 4, h // 4)
    sky_small = np.asarray(Image.fromarray(sky.astype(np.uint8) * 255).resize(small, Image.BOX), np.float32) / 255
    linear_small = np.stack([np.asarray(Image.fromarray(linear[..., c]).resize(small, Image.BOX)) for c in range(3)], -1)
    behind = pull_push(linear_small, (sky_small > 0.99).astype(np.float32))
    behind = np.stack([np.asarray(Image.fromarray(behind[..., c].astype(np.float32)).resize((w, h), Image.BILINEAR))
                       for c in range(3)], -1)
    # Weighted by how far from the sky's colour, so pure foreground outweighs pixels mixed with sky.
    distinct = np.clip((np.sqrt(((linear - behind) ** 2).sum(-1)) - separation) / 0.25, 0, 1) ** 3
    # Any pixel not sure sky can show the foreground's colour; pure ones count most.
    weights = solid * distinct
    if weights.sum() >= 1:
        return behind, pull_push(linear, weights, levels=7)
    # No sure foreground (every trunk inside the band): one colour for it, from the purest
    # pixels that aren't sure sky. Learnt locally, each pixel would learn its own colour.
    weights = (~sky) * distinct ** 2
    if weights.sum() < 1:
        return behind, None
    colour = (linear * weights[..., None]).sum(axis=(0, 1)) / weights.sum()
    return behind, np.broadcast_to(colour, linear.shape)


def solve(linear, behind, front, tolerance):
    difference = behind - front
    span = (difference ** 2).sum(-1)
    alpha = ((linear - front) * difference).sum(-1) / np.maximum(span, 1e-8)
    alpha = np.clip((alpha - 0.04) / 0.92, 0, 1)
    confidence = np.clip((np.sqrt(span) - tolerance[0]) / (tolerance[1] - tolerance[0]), 0, 1)
    return alpha, confidence


def refine(image, coarse, band=0.012, reach=0.06, tolerance=(0.015, 0.06), passes=2, intrusions=True, strict=True):
    """`image` sRGB 0...1 (H, W, 3), `coarse` sky 0...1 (H, W) at the same size."""
    linear = srgb_to_linear(image).astype(np.float32)
    h, w = coarse.shape
    long = max(h, w)
    edge = (coarse > 0.5) ^ ndimage.binary_erosion(coarse > 0.5)
    distance = ndimage.distance_transform_edt(~edge)
    near = (distance <= max(4, band * long)) | ((coarse > 0.1) & (coarse < 0.9))
    # On the foreground side, further: sky seen through a crown the coarse mask cut out whole.
    far = (distance <= reach * long) & (coarse <= 0.5) & ~near
    # Inside the coarse sky, twigs, wires and leaves the model never saw.
    inside = (coarse > 0.5) & ~near & ~far
    sky = (coarse > 0.9) & ~near
    solid = (coarse < 0.1) & ~near
    if not sky.any():
        return coarse
    for _ in range(passes):
        behind, front = colours(linear, sky, solid, w, h)
        if front is None:
            return coarse
        alpha, confidence = solve(linear, behind, front, tolerance)
        refined = confidence * alpha + (1 - confidence) * coarse
        # Far from the edge, keep only strongly sky-like pixels connected to the sky through
        # sky-like ones.
        likely = (refined > 0.5) & (near | far | (coarse > 0.5))
        labels, _ = ndimage.label(likely)
        anchored = np.unique(labels[(coarse > 0.5) & likely])
        connected = np.isin(labels, anchored[anchored > 0])
        result = np.where(near, refined, coarse)
        result = np.where(far & connected, refined, result)
        # There, only what is clearly not sky: noise and cloud texture stay sky.
        intrusion = inside & (refined < 0.75) & (confidence > 0.5) & intrusions
        result = np.where(intrusion, refined, result)
        # The next pass learns the colours from what this one found.
        sky = ((result > 0.97) & (confidence > 0.5)) | ((coarse > 0.9) & ~near & ((result > 0.9) | ~strict))
        solid = (result < 0.03) & ((confidence > 0.5) | ~(near | far))
    return result.astype(np.float32)


def main():
    scenes = json.loads((WORK / "scenes.json").read_text())
    for method in sys.argv[1:]:
        started = time.perf_counter()
        for scene in scenes:
            path = WORK / f"{scene}-{method}.png"
            if not path.exists():
                continue
            image = np.asarray(Image.open(WORK / f"{scene}.png").convert("RGB"), np.float32) / 255
            coarse = Image.open(path).convert("L").resize((image.shape[1], image.shape[0]), Image.BILINEAR)
            alpha = refine(image, np.asarray(coarse, np.float32) / 255)
            Image.fromarray((alpha * 255 + 0.5).astype(np.uint8)).save(WORK / f"{scene}-{method}+matte.png")
        print(f"{method}: {(time.perf_counter() - started) / len(scenes):.1f} s per scene")


if __name__ == "__main__":
    main()


def refine_subject(image, coarse, band=0.012, reach=0.06, tolerance=(0.015, 0.06), passes=2, link=0.12, size=7, relative=True):
    """The subject style, for people and subjects: both colours learnt locally (neither the
    subject nor what is behind it is smooth); strands reaching out into the background are
    sought as far as `reach`, kept where they connect to the subject; nothing is taken from
    inside the subject (the background seen through hair can look like skin)."""
    linear = srgb_to_linear(image).astype(np.float32)
    h, w = coarse.shape
    long = max(h, w)
    edge = (coarse > 0.5) ^ ndimage.binary_erosion(coarse > 0.5)
    distance = ndimage.distance_transform_edt(~edge)
    near = (distance <= max(4, band * long)) | ((coarse > 0.1) & (coarse < 0.9))
    far = (distance <= reach * long) & (coarse <= 0.5) & ~near
    inner = (coarse > 0.9) & ~near
    outer = (coarse < 0.1) & ~near
    if not inner.any() or not outer.any():
        return coarse
    result = coarse
    for _ in range(passes):
        # The subject's colour from inside it, then the background's from samples weighted by how
        # far from it: strands lying over the background would otherwise teach it their colour.
        front = pull_push(linear, inner.astype(np.float32), levels=7)
        # The background's colour with strands erased, learnt from the background side only.
        behind = pull_push(without_strands(linear, front, size), outer.astype(np.float32), levels=7)
        difference = front - behind
        span = (difference ** 2).sum(-1)
        alpha = ((linear - behind) * difference).sum(-1) / np.maximum(span, 1e-8)
        alpha = np.clip((alpha - 0.04) / 0.92, 0, 1)
        if relative:
            # Told apart relative to their brightness: in a dark photo every linear difference is small.
            level = np.maximum(front.mean(-1), behind.mean(-1)) + 0.01
            contrast = np.sqrt(span) / level
            confidence = np.clip((contrast - 0.25) / 0.5, 0, 1)
        else:
            confidence = np.clip((np.sqrt(span) - tolerance[0]) / (tolerance[1] - tolerance[0]), 0, 1)
        refined = confidence * alpha + (1 - confidence) * coarse
        likely = (refined > link) & (near | far | (coarse > 0.5))
        labels, _ = ndimage.label(likely)
        anchored = np.unique(labels[(coarse > 0.5) & likely])
        connected = np.isin(labels, anchored[anchored > 0])
        # Beyond the silhouette only thin structures: hair poking out is thin, a large blob there
        # is background.
        blob = ndimage.binary_dilation(ndimage.binary_opening(likely & far, iterations=4), iterations=2)
        result = np.where(near, refined, coarse)
        result = np.where(far & connected & ~blob, refined, result)
        inner = ((result > 0.97) & (confidence > 0.5)) | ((coarse > 0.9) & ~near & (result > 0.9))
        outer = ((result < 0.03) & (confidence > 0.5)) | ((coarse < 0.1) & ~(near | far))
    return result.astype(np.float32)


def box(x, r):
    return ndimage.uniform_filter(x, size=2 * r + 1, mode="nearest")


def guided_colour(guide, p, r, eps):
    """He, Sun and Tang's guided filter with a colour guide: `guide` (H, W, 3), `p` (H, W)."""
    mean_i = np.stack([box(guide[..., c], r) for c in range(3)], -1)
    mean_p = box(p, r)
    cov_ip = np.stack([box(guide[..., c] * p, r) for c in range(3)], -1) - mean_i * mean_p[..., None]
    var = np.empty(guide.shape[:2] + (3, 3), np.float32)
    for a in range(3):
        for b in range(a, 3):
            v = box(guide[..., a] * guide[..., b], r) - mean_i[..., a] * mean_i[..., b]
            var[..., a, b] = var[..., b, a] = v
    var += eps * np.eye(3, dtype=np.float32)
    a = np.linalg.solve(var, cov_ip[..., None])[..., 0]
    b = mean_p - (a * mean_i).sum(-1)
    mean_a = np.stack([box(a[..., c], r) for c in range(3)], -1)
    return (mean_a * guide).sum(-1) + box(b, r)


def refine_guided(image, coarse, radii=(16, 4), eps=1e-3):
    """The coarse mask snapped to the photo's colour edges at full size, coarse radius first."""
    out = coarse
    for r in radii:
        out = np.clip(guided_colour(image.astype(np.float32), out.astype(np.float32), r, eps), 0, 1)
    return out
