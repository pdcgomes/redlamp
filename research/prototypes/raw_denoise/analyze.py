"""Turns scores.json into the tables in build/proto-out/raw-denoise/summary.md."""

import json
from collections import defaultdict

import numpy as np

from common import NOISE_LEVELS, OUT

PHOTOS = ["photo-sony", "photo-nikon", "photo-canon", "photo-fuji", "leaves"]
METHODS = [
    ("clean-none", "Redlamp demosaic, noise-free mosaic (ceiling)"),
    ("rl-none", "Redlamp, no noise reduction"),
    ("rl-c25", "Redlamp default (Color 25)"),
    ("rl-l25", "Redlamp, Luminance 25"),
    ("rl-l50", "Redlamp, Luminance 50"),
    ("rl-l75", "Redlamp, Luminance 75"),
    ("rl-malvar-l50", "Malvar demosaic, Luminance 50"),
    ("pre-nlm-c25", "Mosaic NL-means, then Redlamp (Color 25)"),
    ("pre-half-l25", "Half mosaic NL-means, then Luminance 25"),
    ("model-nind", "RawNIND joint Bayer model (2025)"),
    ("model-gharbi", "Gharbi 2016 joint, noise-aware"),
    ("model-buades", "Buades 2026 raw denoiser, then Redlamp demosaic"),
    ("model-buades-c25", "Buades 2026, then Redlamp Color 25"),
    ("model-pmrid", "PMRID raw denoiser, then Redlamp demosaic"),
    ("model-pmrid-c25", "PMRID, then Redlamp Color 25"),
    ("model-nind-linear", "RawNIND linear model after Redlamp's demosaic"),
]
CLEAN = [("clean-none", "Redlamp demosaic"), ("clean-demosaicnet", "demosaicnet (learned demosaic)")]


def main():
    scores = json.load(open(OUT / "scores.json"))
    by = defaultdict(dict)
    for s in scores:
        by[(s["scene"], s["cfa"], s["level"])][s["method"]] = s
    lines = ["# DN-11 measured comparison", ""]

    lines += ["## Photos and dead leaves (5 scenes): colour PSNR (dB) / texture kept", ""]
    for cfa in ["bayer", "xtrans"]:
        lines += [f"### {cfa}", "", "| Method | " + " | ".join(NOISE_LEVELS) + " |",
                  "| --- |" + " --- |" * len(NOISE_LEVELS)]
        for method, label in METHODS:
            cells = []
            for level in NOISE_LEVELS:
                vals = []
                for scene in PHOTOS:
                    key = (scene, cfa, "clean") if method == "clean-none" else (scene, cfa, level)
                    if method in by[key]:
                        vals.append((by[key][method]["cpsnr"], by[key][method]["texture"]))
                cells.append(f"{np.mean([v[0] for v in vals]):.2f} / {np.mean([v[1] for v in vals]):.2f}"
                             if len(vals) == len(PHOTOS) else "")
            if any(cells):
                lines.append(f"| {label} | " + " | ".join(cells) + " |")
        lines.append("")

    lines += ["## Charts", ""]
    truth_edge = by[("edge", "-", "-")]["truth"]["edge_mtf50"]
    lines += [f"Truth (the lens and pixel aperture): edge MTF50 {truth_edge:.3f} cycles/pixel.", ""]
    lines += ["Noise-free mosaics, demosaic only:", "",
              "| CFA | Demosaic | Edge MTF50 | MTF at Nyquist | Zone false colour | Photo CPSNR | Texture | Text PSNR |",
              "| --- | --- | --- | --- | --- | --- | --- | --- |"]
    for cfa in ["bayer", "xtrans"]:
        for method, label in CLEAN:
            c = by[("edge", cfa, "clean")].get(method)
            if not c:
                continue
            z = by[("zone", cfa, "clean")][method]
            t = by[("text", cfa, "clean")][method]
            ph = [by[(s, cfa, "clean")][method] for s in PHOTOS]
            lines.append(f"| {cfa} | {label} | {c['edge_mtf50']:.3f} | {c['edge_mtf_nyquist']:.3f} | {z['false_colour']:.4f} | "
                         f"{np.mean([p['cpsnr'] for p in ph]):.2f} | {np.mean([p['texture'] for p in ph]):.2f} | {t['cpsnr']:.2f} |")
    lines.append("")
    for level in NOISE_LEVELS:
        lines += [f"### {level}", "",
                  "| Method | CFA | Edge MTF50 | Zone false colour | Text PSNR | Flat luma noise | Flat chroma noise | Chroma grain coarseness | Shadow colour bias | Shadow level |",
                  "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
        for cfa in ["bayer", "xtrans"]:
            for method, label in METHODS[1:]:
                e = by[("edge", cfa, level)].get(method)
                z = by[("zone", cfa, level)].get(method)
                t = by[("text", cfa, level)].get(method)
                if not (e and z and t):
                    continue
                lines.append(
                    f"| {label} | {cfa} | {e['edge_mtf50']:.3f} | {z['false_colour']:.4f} | {t['cpsnr']:.2f} | "
                    f"{t['flat_luma_noise']:.4f} | {t['flat_chroma_noise']:.4f} | {t['flat_chroma_coarseness']:.2f} | "
                    f"{t['shadow_bias']:.4f} | {t['shadow_level']:+.4f} |")
        lines.append("")
    (OUT / "summary.md").write_text("\n".join(lines))
    print("\n".join(lines))


if __name__ == "__main__":
    main()
