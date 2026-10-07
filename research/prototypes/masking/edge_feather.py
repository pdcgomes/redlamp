#!/usr/bin/env python3
"""Edge and Feather that keep an AI mask's partial coverage (MSK-31).

Feather (0...100) and Edge (-100...100) shape an AI mask as it's drawn: blurred twice by a box of
half the larger reach (reach: 1.5% of the mask's long side), then cut at a level Edge moves from
the middle, as sharply as Feather allows (GrayMask.shaped). Stray hairs and soft wisps, a few
pixels wide and partly covered, blur to almost nothing and fall below the cut: any Edge or Feather
throws them away. The candidate shapes the mask's body only (what a grey opening by a 7 px square
keeps) and adds the rest back: whole for Feather and an outward Edge, faded by an inward Edge's
share (-50 keeps half). Scored on hair_bench's heads, from today's matte (Refine Edges' output,
`refine-app-strands-r3`): the strands kept, and the background taken in.

    research/prototypes/masking/.venv/bin/python research/prototypes/masking/edge_feather.py
"""

import json
import pathlib
import sys

import numpy as np
from PIL import Image
from scipy import ndimage

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import hair_bench as hb  # noqa: E402

START = "refine-app-strands-r3"
REACH = 0.015
SETTINGS = [(50, 0), (0, 50), (0, -50), (30, 30), (100, 0)]


def shaped(mask, feather, edge, reach):
    """GrayMask.shaped."""
    if (feather == 0 and edge == 0) or reach <= 0:
        return mask
    feather_reach = min(max(feather, 0), 100) / 100 * reach
    edge_reach = min(abs(edge), 100) / 100 * reach
    larger = max(feather_reach, edge_reach)
    radius = max(round(larger / 2), 1)
    blurred = ndimage.uniform_filter(ndimage.uniform_filter(mask, 2 * radius + 1, mode="nearest"),
                                     2 * radius + 1, mode="nearest")
    softness = max(0.5 * feather_reach / larger, 0.02)
    level = min(max(0.5 - min(max(edge, -100), 100) / 200 * edge_reach / larger, softness), 1 - softness)
    t = np.clip((blurred - (level - softness)) / (2 * softness), 0, 1)
    return t * t * (3 - 2 * t)


def kept(mask, feather, edge, reach, radius=3):
    """The body shaped, the detail added back (faded by an inward Edge)."""
    if (feather == 0 and edge == 0) or reach <= 0:
        return mask
    body = ndimage.grey_opening(mask, size=(2 * radius + 1, 2 * radius + 1))
    detail = mask - body
    gain = 1 - min(max(-edge, 0), 100) / 100
    return np.clip(shaped(body, feather, edge, reach) + detail * gain, 0, 1)


def main():
    scenes = json.loads((hb.WORK / "scenes.json").read_text())
    totals = {}
    for scene in scenes:
        path = hb.WORK / f"{scene}-{START}.png"
        if not path.exists():
            continue
        mask = np.asarray(Image.open(path).convert("L"), np.float32) / 255
        truth = np.load(hb.WORK / f"{scene}-truth.npz")
        thin = truth["thin"].astype(bool)
        person = truth["sky"].astype(np.float32)
        reach = max(1, round(max(mask.shape) * REACH))
        background = person < 0.02
        for feather, edge in SETTINGS:
            for name, fn in (("today", shaped), ("kept", kept)):
                out = fn(mask, feather, edge, reach)
                row = (float((out[thin] > 0.1).mean()), float((out[background] > 0.1).mean()))
                totals.setdefault((feather, edge, name), []).append(row)
        print(f"{scene}: done", flush=True)
    base = []
    for scene in scenes:
        path = hb.WORK / f"{scene}-{START}.png"
        if path.exists():
            mask = np.asarray(Image.open(path).convert("L"), np.float32) / 255
            truth = np.load(hb.WORK / f"{scene}-truth.npz")
            base.append(float((mask[truth["thin"].astype(bool)] > 0.1).mean()))
    print(f"\nwithout Edge or Feather: strands kept {np.mean(base):.3f}")
    for (feather, edge, name), rows in totals.items():
        a = np.array(rows)
        print(f"Feather {feather:3d} Edge {edge:+4d} {name:5s}: strands kept {a[:, 0].mean():.3f}  "
              f"background taken in {a[:, 1].mean():.4f}")


if __name__ == "__main__":
    main()
