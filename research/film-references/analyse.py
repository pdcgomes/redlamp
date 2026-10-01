#!/usr/bin/env python3
"""Compares Redlamp's film looks with photographs shot on each film.

The two sets show different scenes (our looks are rendered on the CC0 look-development set by
`redlamp recipe film --validate`; the references are Commons photographs), so absolute values
mostly measure scene content. The test is relative: whether the looks order the stocks as the
photographs do (Spearman rank correlation per statistic), and which stocks sit furthest from
their references once the overall scene offset is taken out.

Usage: analyse.py [--out build/film-validation/report.md]
"""
import json
import math
import pathlib
import statistics
import sys

import numpy as np
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parents[2]
REFERENCES = ROOT / "build/film-references"
RENDERS = ROOT / "build/film-validation"
MONOCHROME = ("tri-x", "t-max", "hp5", "delta", "fp4", "pan-f")


def oklab(image):
    rgb = np.asarray(image.convert("RGB"), dtype=np.float32) / 255
    linear = np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)
    m1 = np.array([[0.4122214708, 0.5363325363, 0.0514459929],
                   [0.2119034982, 0.6806995451, 0.1073969566],
                   [0.0883024619, 0.2817188376, 0.6299787005]])
    m2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468],
                   [1.9779984951, -2.4285922050, 0.4505937099],
                   [0.0259040371, 0.7827717662, -0.8086757660]])
    lms = np.cbrt(np.maximum(linear.reshape(-1, 3) @ m1.T, 0))
    return lms @ m2.T


def image_stats(path):
    image = Image.open(path)
    image.thumbnail((384, 384))
    lab = oklab(image)
    L, a, b = lab[:, 0], lab[:, 1], lab[:, 2]
    C = np.hypot(a, b)
    hue = (np.degrees(np.arctan2(b, a)) + 360) % 360
    stats = {
        "black (L p5)": np.percentile(L, 5),
        "median L": np.percentile(L, 50),
        "white (L p95)": np.percentile(L, 95),
        "contrast (p95 − p5)": np.percentile(L, 95) - np.percentile(L, 5),
        "saturation (mean C)": C.mean(),
        "warmth (mean b)": b.mean(),
        "tint (mean a)": a.mean(),
    }

    def region(mask, key):
        if mask.sum() > 0.01 * len(L):
            stats[key + " chroma"] = C[mask].mean()
            stats[key + " hue"] = math.degrees(math.atan2(b[mask].mean(), a[mask].mean())) % 360

    region((hue > 110) & (hue < 165) & (C > 0.04), "foliage")
    region((hue > 215) & (hue < 270) & (C > 0.03) & (L > 0.5), "sky")
    region((hue > 35) & (hue < 80) & (C > 0.03) & (C < 0.15) & (L > 0.45) & (L < 0.85), "skin")
    neutral = C < 0.035
    for name, mask in (("shadow", neutral & (L < 0.35)), ("highlight", neutral & (L > 0.75))):
        if mask.sum() > 0.01 * len(L):
            stats[name + " tint b"] = b[mask].mean()
            stats[name + " tint a"] = a[mask].mean()
    return stats


def set_stats(folder):
    per_image = [image_stats(p) for p in sorted(folder.iterdir()) if p.suffix.lower() in (".jpg", ".jpeg", ".png")]
    keys = {k for s in per_image for k in s}
    return {k: statistics.median([s[k] for s in per_image if k in s]) for k in keys
            if sum(k in s for s in per_image) >= 3}


def spearman(x, y):
    rx = np.argsort(np.argsort(x)).astype(float)
    ry = np.argsort(np.argsort(y)).astype(float)
    return float(np.corrcoef(rx, ry)[0, 1])


def main():
    out = pathlib.Path(sys.argv[sys.argv.index("--out") + 1]) if "--out" in sys.argv else RENDERS / "report.md"
    looks = json.loads((RENDERS / "looks.json").read_text())
    default = set_stats(RENDERS / "default")
    rows = {}
    for look, film in sorted(looks.items()):
        rows[look] = (film, set_stats(RENDERS / look), set_stats(REFERENCES / film))
    lines = ["# Film looks against photographs shot on the films", "",
             f"{len(rows)} looks; each rendered on the 40-image look-development set, against "
             "Wikimedia Commons photographs of the same stock (build/film-references).", ""]
    findings = []
    for monochrome in (False, True):
        group = {k: v for k, v in rows.items() if any(m in k for m in MONOCHROME) == monochrome}
        keys = sorted(set.intersection(*(set(v[1]) & set(v[2]) for v in group.values())))
        if monochrome:
            keys = [k for k in keys if k in ("black (L p5)", "median L", "white (L p95)", "contrast (p95 − p5)")]
        lines += [f"## {'Black and white' if monochrome else 'Colour'}", "",
                  "| Statistic | Rank agreement (Spearman) | Scene offset (looks − references) |", "| --- | --- | --- |"]
        for key in keys:
            look_values = np.array([group[k][1][key] for k in group])
            ref_values = np.array([group[k][2][key] for k in group])
            rho = spearman(look_values, ref_values) if len(group) > 2 else float("nan")
            offset = float(np.median(look_values - ref_values))
            lines.append(f"| {key} | {rho:+.2f} | {offset:+.3f} |")
            spread = float(np.std(ref_values)) or 1e-6
            for name, lv, rv in zip(group, look_values, ref_values):
                residual = (lv - rv - offset) / spread
                if abs(residual) > 1.5:
                    findings.append((abs(residual), name, key, lv, rv, residual))
        lines.append("")
    lines += ["## Largest departures", "",
              "Once the overall scene offset is removed, in units of the references' spread across stocks "
              "(positive: the look has more of it than the photographs).", "",
              "| Look | Statistic | Look | Photographs | Departure |", "| --- | --- | --- | --- | --- |"]
    for _, name, key, lv, rv, residual in sorted(findings, reverse=True)[:30]:
        lines.append(f"| {name} | {key} | {lv:.3f} | {rv:.3f} | {residual:+.1f} |")
    lines += ["", "## Per look", ""]
    for name, (film, look, ref) in rows.items():
        keys = [k for k in ("contrast (p95 − p5)", "saturation (mean C)", "warmth (mean b)", "foliage hue",
                            "sky hue", "shadow tint b", "highlight tint b") if k in look and k in ref]
        cells = ", ".join(f"{k.split(' (')[0]} {look[k]:.3f}/{ref[k]:.3f}" for k in keys)
        lines.append(f"- **{name}** ({film}): {cells}")
    lines += ["", "Redlamp's default rendering of the same set: " + ", ".join(
        f"{k.split(' (')[0]} {default[k]:.3f}" for k in ("contrast (p95 − p5)", "saturation (mean C)", "warmth (mean b)")
        if k in default)]
    out.write_text("\n".join(lines) + "\n")
    print(out)


if __name__ == "__main__":
    main()
