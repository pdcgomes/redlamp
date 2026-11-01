"""DN-17's tables: the open raw denoisers against Redlamp's default and best setting, and the results file.

Reads build/proto-out/raw-denoise/scores.json (score.py) and real/scores.json (real_pairs.py score), and
writes build/proto-out/raw-denoise/dn17-summary.md; with --results it also writes the per-case numbers in
INF-14's format (research/benchmarks/results/), the cases named as research/benchmarks/denoise.json names
them. Run with build/dn11-venv after score.py and real_pairs.py score:

    ../../../build/dn11-venv/bin/python dn17_report.py [--results ../../benchmarks/results/denoise-open-models-2026-11-01.json]
"""

import argparse
import collections
import json
from pathlib import Path

import numpy as np

from common import NOISE_LEVELS, OUT, read_json

REAL = OUT / "real"
PHOTOS = ["photo-sony", "photo-nikon", "photo-canon", "photo-fuji", "leaves"]
LEVELS = list(NOISE_LEVELS)

METHODS = {
    "rl-c25": "Redlamp default (Color 25)",
    "rl-l50": "Redlamp, Luminance 50",
    "model-autoshade": "AutoShade v2 as its sidecar runs it, then Redlamp's demosaic",
    "model-autoshade-nofield": "AutoShade v2 without its noise field, then Redlamp's demosaic",
    "model-buades": "Buades 2026, then Redlamp's demosaic",
    "model-pmrid": "PMRID, then Redlamp's demosaic",
    "model-rr-jdd": "RawForge joint model (JDD, 768 px tiles)",
    "model-rr-treenet": "RawRefinery TreeNet (Bayer), for reference",
    "model-rr-xtrans-treenet": "RawForge X-Trans TreeNet, after LibRaw's Markesteijn",
    "model-rr-xtrans-restormer": "RawForge X-Trans Restormer, after LibRaw's Markesteijn",
    "model-starfish": "Starfish (joint)",
    "rr-libraw-3pass": "LibRaw's Markesteijn, no noise reduction",
}
ROWS = {
    "bayer": ["rl-c25", "rl-l50", "model-autoshade", "model-autoshade-nofield", "model-buades", "model-pmrid",
              "model-rr-jdd", "model-rr-treenet", "model-starfish"],
    "xtrans": ["rl-c25", "rl-l50", "model-rr-xtrans-treenet", "model-rr-xtrans-restormer", "model-rr-jdd",
               "model-starfish"],
}
CLEAN_ROWS = [("clean-none", "Redlamp's demosaic (Menon; Markesteijn on X-Trans)"), ("clean-starfish", "Starfish")]

# Which RawNIND scenes each model trained on (DN-17 §3): AutoShade's validation split is RawNIND's test_reserve
# and unknown_sensor scenes; Buades 2026 trained on TitusToys' and boardgames_top's clean frames (and about 96
# other RawNIND scenes, not listed by name); RawForge's models on a random 80% of every RawNIND pair; PMRID
# (SID) and Starfish (DIV2K) on none.
HELD_OUT = {"TEST_MuseeL-vases-A7C", "TEST_Vaxt-i-trad", "TEST_7D-2", "TEST_MuseeL-bluebirds-A7C", "TEST_Pen-pile",
            "UNK_TEST_LucieB_board", "UNK_LucieB_bedroom_tapestry"}


def mean(values):
    return float(np.mean(values)) if values else float("nan")


def synthetic_tables(by):
    lines = []
    for cfa, rows in ROWS.items():
        lines += [f"## Synthetic {cfa}: photos and dead leaves (5 scenes), colour PSNR (dB) / texture kept", "",
                  "| Method | " + " | ".join(LEVELS) + " |", "| --- |" + " --- |" * len(LEVELS)]
        for method in rows:
            cells = []
            for level in LEVELS:
                vals = [by[(s, cfa, level)][method] for s in PHOTOS if method in by[(s, cfa, level)]]
                cells.append(f"{mean([v['cpsnr'] for v in vals]):.2f} / {mean([v['texture'] for v in vals]):.2f}"
                             if len(vals) == len(PHOTOS) else "")
            if any(cells):
                lines.append(f"| {METHODS[method]} | " + " | ".join(cells) + " |")
        lines.append("")
        for level in LEVELS:
            lines += [f"### {cfa}, {level}: charts", "",
                      "| Method | Edge MTF50 | Zone false colour | Text PSNR | Text detail kept | Text spurious detail | "
                      "Flat luma noise | Flat chroma noise | Shadow cast | Shadow level |",
                      "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
            for method in rows:
                e, z, t = (by[(scene, cfa, level)].get(method) for scene in ("edge", "zone", "text"))
                if not (e and z and t):
                    continue
                lines.append(
                    f"| {METHODS[method]} | {e['edge_mtf50']:.3f} | {z['false_colour']:.4f} | {t['text_cpsnr']:.2f} | "
                    f"{t['text_texture']:.2f} | {t['text_spurious']:.2f} | {t['flat_luma_noise']:.4f} | "
                    f"{t['flat_chroma_noise']:.4f} | {t['shadow_bias']:.4f} | {t['shadow_level']:+.4f} |")
            lines.append("")
        lines += [f"### {cfa}: noise-free mosaics", "",
                  "| Demosaic | Photo colour PSNR | Texture | Edge MTF50 | Zone false colour | Text PSNR | Text spurious |",
                  "| --- | --- | --- | --- | --- | --- | --- |"]
        for method, label in CLEAN_ROWS:
            e, z, t = (by[(scene, cfa, "clean")].get(method) for scene in ("edge", "zone", "text"))
            ph = [by[(s, cfa, "clean")][method] for s in PHOTOS if method in by[(s, cfa, "clean")]]
            if e and z and t and len(ph) == len(PHOTOS):
                lines.append(f"| {label} | {mean([p['cpsnr'] for p in ph]):.2f} | {mean([p['texture'] for p in ph]):.2f} | "
                             f"{e['edge_mtf50']:.3f} | {z['false_colour']:.4f} | {t['text_cpsnr']:.2f} | {t['text_spurious']:.2f} |")
        lines.append("")
    truth = by[("edge", "-", "-")]["truth"]["edge_mtf50"]
    lines += [f"Truth's edge MTF50 (lens and pixel aperture): {truth:.3f} cycles per pixel.", ""]
    return lines


def real_tables(rows, meta):
    lines = []
    highest = {name: max(int(i) for i in m["isos"]) for name, m in meta.items()}
    table = collections.defaultdict(list)
    for r in rows:
        level = "highest" if r["iso"] == highest[r["scene"]] else "lower"
        scene = r["scene"].split("-", 1)[1]
        groups = ["all"] + (["held out"] if scene in HELD_OUT else [])
        for g in groups:
            table[(r["cfa"], g, level, r["method"])].append(r)
    for cfa, rowset, groups in (("Bayer", ROWS["bayer"], ("held out", "all")), ("X-Trans", ROWS["xtrans"], ("all",))):
        for group in groups:
            n = len({r["scene"] for (c, g, _, _), v in table.items() if c == cfa and g == group for r in v})
            lines += [f"## RawNIND {cfa}, {group} ({n} scenes): colour PSNR full resolution / binned, texture kept", "",
                      "| Method | Highest ISO of each scene | Lower ISO |", "| --- | --- | --- |"]
            for method in rowset:
                cells = []
                for level in ("highest", "lower"):
                    v = table.get((cfa, group, level, method), [])
                    cells.append(f"{mean([x['cpsnr'] for x in v]):.2f} / {mean([x['cpsnr_binned'] for x in v]):.2f}, "
                                 f"{mean([x['texture'] for x in v]):.2f} (n={len(v)})" if v else "")
                if any(cells):
                    lines.append(f"| {METHODS[method]} | " + " | ".join(cells) + " |")
            lines.append("")
    lines += ["## RawNIND per scene, highest ISO: colour PSNR full resolution", ""]
    scenes = sorted({r["scene"] for r in rows})
    methods = ["rl-c25", "rl-l50", "model-autoshade", "model-autoshade-nofield", "model-buades", "model-pmrid",
               "model-rr-jdd", "model-rr-xtrans-restormer", "model-starfish"]
    lines += ["| Scene | ISO | " + " | ".join(methods) + " |", "| --- | --- |" + " --- |" * len(methods)]
    for scene in scenes:
        cells = []
        for method in methods:
            v = [r for r in rows if r["scene"] == scene and r["method"] == method and r["iso"] == highest[scene]]
            cells.append(f"{v[0]['cpsnr']:.2f}" if v else "")
        lines.append(f"| {scene} | {highest[scene]} | " + " | ".join(cells) + " |")
    lines.append("")
    return lines


def case_id(scene, cfa, level):
    return f"synthetic-{scene}-{cfa}-{level}"


def real_case_id(scene, iso):
    return f"rawnind-{scene}-iso{iso}"


def results(scores, rows, path):
    keep = set(METHODS) | {"clean-none", "clean-starfish"}
    out = []
    for s in scores:
        if s["method"] in keep and s["cfa"] != "-":
            out.append({"case": case_id(s["scene"], s["cfa"], s["level"]), "method": s["method"],
                        "scores": {k: round(v, 5) for k, v in s.items() if isinstance(v, float)}})
    for r in rows:
        if r["method"] in keep:
            out.append({"case": real_case_id(r["scene"], r["iso"]), "method": r["method"],
                        "scores": {k: round(r[k], 5) for k in ("cpsnr", "cpsnr_binned", "ssim", "texture")}})
    data = read_json(path) if path.exists() else {}
    data["results"] = out
    path.write_text(json.dumps(data, indent=1) + "\n")
    print(f"{len(out)} results in {path}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--results", help="the results file to fill (its header is kept)")
    args = parser.parse_args()
    scores = json.load(open(OUT / "scores.json"))
    by = collections.defaultdict(dict)
    for s in scores:
        by[(s["scene"], s["cfa"], s["level"])][s["method"]] = s
    lines = ["# DN-17: open raw denoisers against Redlamp", ""] + synthetic_tables(by)
    rows, meta = [], {}
    if (REAL / "scores.json").exists():
        rows, meta = json.load(open(REAL / "scores.json")), read_json(REAL / "meta.json")
        lines += real_tables(rows, meta)
    (OUT / "dn17-summary.md").write_text("\n".join(lines))
    print("\n".join(lines))
    if args.results:
        results(scores, rows, Path(args.results))


if __name__ == "__main__":
    main()
