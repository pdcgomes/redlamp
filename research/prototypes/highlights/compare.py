"""Measures every candidate's renders of one raw against main's, and writes comparison strips:
one picture per setting, a crop of each candidate stacked top to bottom with its name.

Usage: compare.py <raw> <renders dir> <crop: x0,y0,x1,y1 as fractions> [<truth dir> <truth candidate>]"""
import json
import sys
from pathlib import Path

import numpy as np
import tifffile
from PIL import Image, ImageDraw, ImageFont

import measure

raw, folder = sys.argv[1], Path(sys.argv[2])
crop = [float(v) for v in sys.argv[3].split(",")]
truth = Path(sys.argv[4]) if len(sys.argv) > 4 and sys.argv[4] else None
truth_candidate = sys.argv[5] if len(sys.argv) > 5 and sys.argv[5] else "main"
settings = [s for s in ["defaults", "highlights-80", "exposure-1.5", "exposure-3", "auto"]
            if (folder / f"main-{s}.tif").exists()]
candidates = [c for c in (sys.argv[6].split(",") if len(sys.argv) > 6 else ["main", "a", "b", "c", "d", "e", "ef", "e8"])
              if (folder / f"{c}-defaults.tif").exists()]
font = ImageFont.load_default(size=22)
report = {}
for setting in settings:
    strips = []
    for candidate in candidates:
        path = folder / f"{candidate}-{setting}.tif"
        reference = folder / f"main-{setting}.tif"
        result = measure.measure(raw, str(path), str(reference) if candidate != "main" else None)
        if truth is not None:
            true_path = truth / f"{truth_candidate}-{setting}.tif"
            other = measure.oklab_from_linear_srgb(measure.decode(str(true_path)))
            lab = measure.oklab_from_linear_srgb(measure.decode(str(path)))
            classes, _ = measure.class_map(raw, lab.shape[:2])
            delta = np.linalg.norm(lab - other, axis=-1) * 100
            chroma_error = np.hypot(lab[..., 1] - other[..., 1], lab[..., 2] - other[..., 2]) * 100
            clipped = classes > 0
            result["truth"] = {
                "clipped_delta_mean": round(float(delta[clipped].mean()), 3) if clipped.any() else None,
                "clipped_delta_p95": round(float(np.percentile(delta[clipped], 95)), 3) if clipped.any() else None,
                "clipped_chroma_error_mean": round(float(chroma_error[clipped].mean()), 3) if clipped.any() else None,
                "unclipped_delta_mean": round(float(delta[~clipped].mean()), 3),
            }
        report[f"{candidate}/{setting}"] = result
        image = tifffile.imread(str(path))[..., :3]
        h, w = image.shape[:2]
        part = image[int(crop[1] * h): int(crop[3] * h), int(crop[0] * w): int(crop[2] * w)]
        strip = Image.fromarray((part.astype(np.float64) / 257 + 0.5).astype(np.uint8))
        draw = ImageDraw.Draw(strip)
        label = {"main": "main (process 14)", "a": "A: CAM-08 corrected", "b": "B: A, two or three clipped fade to neutral",
                 "c": "C: each area's border colour", "d": "D: A, all three clipped fade to neutral",
                 "e": "E, its first form: the fade reaches every photosite",
                 "e8": "E8: E, rim blocks near clipping only",
                 "ef": "E: D, predicted from both where two clipped, fade near the clip"}[candidate]
        draw.rectangle([0, 0, 12 * len(label) + 16, 32], fill=(0, 0, 0))
        draw.text((8, 4), label, fill=(255, 255, 255), font=font)
        strips.append(strip)
    width = max(s.width for s in strips)
    sheet = Image.new("RGB", (width, sum(s.height + 6 for s in strips)), (20, 20, 20))
    y = 0
    for s in strips:
        sheet.paste(s, (0, y))
        y += s.height + 6
    out = folder.parent.parent / "pictures" / f"{folder.name}-{setting}.jpg"
    out.parent.mkdir(exist_ok=True)
    sheet.save(out, quality=90)
(folder / "report.json").write_text(json.dumps(report, indent=1))
for key, result in report.items():
    classes = ", ".join(f"{k} C{v['chroma_mean']:.3f} h{v['hue']:+.0f} sRGB{tuple(round(x) for x in v['srgb8'])}"
                        for k, v in result["classes"].items())
    band = result["band"]
    line = f"{key:22s} {classes} | edge p99 {band['edge_gradient_p99']} (unclipped {band['unclipped_gradient_p99']})"
    if "elsewhere" in result:
        e = result["elsewhere"]
        line += f" | elsewhere mean {e['delta_mean']} max {e['delta_max']} >0.5: {e['share_over_0.5']}"
    if "truth" in result:
        t = result["truth"]
        line += f" | vs truth clipped dE {t['clipped_delta_mean']} p95 {t['clipped_delta_p95']} chroma err {t['clipped_chroma_error_mean']}"
    print(line)
