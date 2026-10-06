#!/usr/bin/env python3
"""Edge-aware application of a mask's edit (MSK-27): a prototype.

Redlamp applies a mask's edit to each pixel's own colour, scaled by the pixel's coverage: at a
pixel part sky and part branch, Exposure ev is a gain of 2^(coverage·ev) on the mixed colour, so
the branch's share is edited too and the sky's by too little. Applied at the edge instead, the
edit reaches only the light the masked side gives the pixel: for Exposure, C + (2^ev - 1)·M,
where M is that light (coverage times the masked side's pure colour). This compares estimates of
M on edge_bench's skies and hair_bench's heads, through each scene's true coverage and today's
mask:

- blend: today's application, simulated (no estimate needed);
- inside: M from the masked side's pure colour, filled in from the nearest pixels wholly inside;
- outside: M as what's left of the pixel once the other side's pure colour, filled in the same
  way, is taken out;
- both: the two weighted by coverage, each where its error is smallest: the inside estimate's
  error grows with coverage and the outside's with what's left, so their mix errs by at most a
  quarter of the two together;
- ml: pymatting's multi-level foreground estimate (Germer et al., 2020).

Each result is written as a linear DNG, developed by redlamp, and scored with mask_bench's halo
against the scene edited before compositing; `mixedL` is the mean lightness difference over the
pixels mostly outside the mask, as the quality gate in MaskRenderTests measures it. Run
`mask_bench.py run` first.

    .venv/bin/python edge_apply.py [--sets edge,hair] [--methods blend,inside,outside,both,ml]
"""

import argparse
import json
import pathlib
import sys

import cv2
import numpy as np

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import mask_bench as mb  # noqa: E402

OUT = mb.OUT / "apply"
METHODS = ("blend", "inside", "outside", "both", "ml")


def fill(colour, weight):
    """`colour` where `weight` is 1, and elsewhere the colour of the weighted pixels nearest it,
    from a push-pull pyramid."""
    h, w = weight.shape
    if min(h, w) <= 4:
        mean = (colour * weight[..., None]).sum((0, 1)) / max(float(weight.sum()), 1e-6)
        return np.broadcast_to(mean, colour.shape).astype(np.float32)
    size = ((w + 1) // 2, (h + 1) // 2)
    small_weight = cv2.resize(weight, size, interpolation=cv2.INTER_AREA)
    small = cv2.resize(colour * weight[..., None], size, interpolation=cv2.INTER_AREA)
    small /= np.maximum(small_weight, 1e-6)[..., None]
    coarse = cv2.resize(fill(small, np.minimum(small_weight * 4, 1)), (w, h), interpolation=cv2.INTER_LINEAR)
    return weight[..., None] * colour + (1 - weight[..., None]) * coarse


def masked_light(method, colour, alpha):
    """The light the masked side gives each pixel, at most the pixel's own."""
    a = alpha[..., None]
    inside = lambda: a * fill(colour, (alpha >= 0.98).astype(np.float32))  # noqa: E731
    outside = lambda: colour - (1 - a) * fill(colour, (alpha <= 0.02).astype(np.float32))  # noqa: E731
    if method == "inside":
        light = inside()
    elif method == "outside":
        light = outside()
    elif method == "both":
        light = (1 - a) * inside() + a * outside()
    elif method == "ml":
        from pymatting import estimate_foreground_ml

        light = a * estimate_foreground_ml(colour.astype(np.float64), alpha.astype(np.float64)).astype(np.float32)
    return np.clip(light, 0, colour)


def edited(method, colour, alpha, ev):
    if method == "blend":
        return colour * (2.0 ** (alpha * ev))[..., None]
    return colour + (2.0**ev - 1) * masked_light(method, colour, alpha)


def coverage(path, shape):
    mask = cv2.imread(str(path), cv2.IMREAD_GRAYSCALE).astype(np.float32) / 255
    if mask.shape != shape:
        mask = cv2.resize(mask, (shape[1], shape[0]), interpolation=cv2.INTER_LINEAR)
    return mask


def mixed_lightness(edit, ideal, truth):
    difference = mb.lab(edit)[..., 0] - mb.lab(ideal)[..., 0]
    return float(difference[(truth > 0.05) & (truth < 0.5)].mean())


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--sets", default="edge,hair")
    parser.add_argument("--methods", default=",".join(METHODS))
    parser.add_argument("--cli", default=str(mb.CLI))
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    report_path = OUT / "report.json"
    report = json.loads(report_path.read_text()) if report_path.exists() else {}
    methods = args.methods.split(",")
    for name in args.sets.split(","):
        spec, bench = mb.SETS[name], mb.OUT / name
        for scene in json.loads((spec["work"] / "scenes.json").read_text()):
            colour = mb.linear(spec["work"] / f"{scene}.png")
            truth = np.load(spec["work"] / f"{scene}-truth.npz")["sky"].astype(np.float32)
            ideal = bench / f"{scene}-ideal-render.png"
            masks = {"truth": truth, "stored": coverage(bench / f"{scene}-stored.png", truth.shape)}
            for source, alpha in masks.items():
                for method in methods:
                    raw, render = OUT / f"{scene}-{source}-{method}.dng", OUT / f"{scene}-{source}-{method}.png"
                    mb.write_dng(raw, edited(method, colour, alpha, spec["ev"]))
                    mb.redlamp(args.cli, "render", raw, "--16bit", "-o", render)
                    row = mb.halo(render, ideal, truth) | {"mixedL": mixed_lightness(render, ideal, truth)}
                    report.setdefault(name, {}).setdefault(scene, {}).setdefault(source, {})[method] = row
                    raw.unlink()
                    print(f"{name}/{scene} {source} {method}: halo {row['haloDE']:.2f}, rim {row['rimL']:+.2f}, "
                          f"mixed {row['mixedL']:+.2f}, deep {row['deepDE'] or 0:.2f}", flush=True)
            if "blend" in methods:
                own = mb.lab(bench / f"{scene}-oracle-edit.png")
                simulated = mb.lab(OUT / f"{scene}-truth-blend.png")
                report[name][scene]["blendCheckDE"] = float(np.linalg.norm(own - simulated, axis=-1).mean())
            report_path.write_text(json.dumps(report, indent=1))
    for name in args.sets.split(","):
        scenes = report.get(name, {})
        print(f"\n{name} ({len(scenes)} scenes; simulated blend against redlamp's own edit: "
              f"{np.mean([s.get('blendCheckDE', np.nan) for s in scenes.values()]):.2f} ΔE)")
        for source in ("truth", "stored"):
            for method in methods:
                rows = [s[source][method] for s in scenes.values() if method in s.get(source, {})]
                if rows:
                    mean = lambda key: np.mean([r[key] for r in rows if r[key] is not None])  # noqa: E731
                    print(f"  {source:6} {method:7}: halo {mean('haloDE'):.2f}, rim {mean('rimL'):+.2f}, "
                          f"mixed {mean('mixedL'):+.2f} (worst {max(r['mixedL'] for r in rows):+.2f}), "
                          f"deep {mean('deepDE'):.2f}")


if __name__ == "__main__":
    main()
