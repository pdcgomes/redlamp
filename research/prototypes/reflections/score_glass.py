#!/usr/bin/env python3
"""Scores Remove Reflections on the glass set (RM-22, INF-14) and draws its blind picks' pairs.

    score_glass.py --variants windowseat-q4:768,windowseat-q8:768 --round glass-2026-11-01

For each composite, against its truth at full resolution in sRGB: PSNR, SSIM (scikit-image, 7×7
windows, per channel) and detail PSNR, the PSNR of the high-pass component (the image less its
Gaussian blur at σ = 2 px), which shows what upsampling loses. Methods: the photo as it is (`input`),
the model's output upsampled (`output`, Lanczos in sRGB as WindowSeat's script does) and the
full-resolution subtraction (`subtract`, fullres.py), for each model variant; with --ablations, the
subtraction for the first variant without drift correction, with the affine drift fit, without
smoothing, and with each clipped-highlight mode. Model outputs are kept in --work and reused.

For the real photos it writes both methods at full size for the first variant, and pairs.json for
picks.py: two 100% crops a photo, where the estimated reflection is strongest and where the photo has
the most detail under some reflection. Writes research/benchmarks/results/glass-<round>.json.
"""

import argparse
import json
import os
import pathlib
import subprocess
import sys
import time

import numpy as np
from skimage.metrics import structural_similarity

import fullres
import glassio
import windowseat_mlx

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "research/benchmarks"))
import benchmarks  # noqa: E402

CROP = (1024, 683)


def psnr(a, b):
    return float(10 * np.log10(1 / max(np.mean((a - b) ** 2), 1e-12)))


def highpass(image):
    return image - fullres.smooth(image, 2.0)


def scores(result, truth, truth_detail):
    return {
        "psnr": round(psnr(result, truth), 3),
        "ssim": round(float(structural_similarity(result, truth, channel_axis=2, data_range=1.0)), 4),
        "detail_psnr": round(psnr(highpass(result), truth_detail), 3),
    }


def crops(photo, reflection):
    """Two crop boxes: the strongest estimated reflection, and the most detail where there is reflection."""
    height, width = photo.shape[:2]
    cw, ch = min(CROP[0], width), min(CROP[1], height)
    luminance = reflection.mean(axis=2)
    detail = np.abs(highpass(photo).mean(axis=2))
    best = {}
    for y in range(0, height - ch + 1, 128):
        for x in range(0, width - cw + 1, 128):
            r = float(luminance[y : y + ch, x : x + cw].mean())
            d = float(detail[y : y + ch, x : x + cw].mean())
            for name, value in (("reflection", r), ("detail", d * min(r / max(luminance.mean(), 1e-6), 1.0))):
                if value > best.get(name, (-1,))[0]:
                    best[name] = (value, [x, y, cw, ch])
    boxes = [best["reflection"][1]]
    other = best["detail"][1]
    if abs(other[0] - boxes[0][0]) >= cw // 2 or abs(other[1] - boxes[0][1]) >= ch // 2:
        boxes.append(other)
    return boxes


def git_commit():
    return subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--variants", default="windowseat-q4:768")
    parser.add_argument("--models", type=pathlib.Path, default=ROOT / "build/rm22")
    parser.add_argument("--work", type=pathlib.Path, default=ROOT / "build/rm22/out/glass")
    parser.add_argument("--round", default="glass-2026-11-01")
    parser.add_argument("--ablations", action="store_true")
    parser.add_argument("--real", action="store_true", help="also write the real photos' results and pairs.json")
    parser.add_argument("--cases", help="comma-separated case IDs (default: all)")
    parser.add_argument("--outputs-only", action="store_true", help="make the model outputs and stop")
    args = parser.parse_args()
    args.work.mkdir(parents=True, exist_ok=True)
    cases = benchmarks.cases("glass")
    if args.cases:
        cases = [c for c in cases if c["id"] in args.cases.split(",")]
    # name:size or name:size:scale; the scale works nearer the photo's own resolution in more tiles.
    variants = [(v.split(":")[0], int(v.split(":")[1]), float(v.split(":")[2]) if v.count(":") == 2 else 1.0) for v in args.variants.split(",")]
    tag_of = lambda name, size, scale: f"{name}-{size}" + (f"x{scale:g}" if scale != 1 else "")

    # Model outputs at the working size, made once per variant and kept.
    for name, size, scale in variants:
        missing = [c for c in cases if not (args.work / f"{c['id']}-model-{tag_of(name, size, scale)}.tif").exists() and (c["score"] == "truth" or args.real)]
        if not missing:
            continue
        if name == "windowseat-bf16":
            transformer, vae, _ = windowseat_mlx.build_from_base(args.models / "models/qwen-image-edit-2509", args.models / "models/windowseat/transformer_lora", 16)
            prompt = windowseat_mlx.mx.load(str(args.models / "models/windowseat/text_embeddings/state_dict.safetensors"))
            model = windowseat_mlx.SimpleNamespace(transformer=transformer, vae=vae, embeds=prompt["prompt_embeds"], mask=prompt["prompt_mask"].astype(windowseat_mlx.mx.int32), info={"bits": 16})
        else:
            model = windowseat_mlx.load(args.models / name)
        for case in missing:
            photo = glassio.read(benchmarks.resolve("glass", case))
            start = time.time()
            out_w = fullres.model_output(model, photo, size, scale)
            glassio.write_tiff16(args.work / f"{case['id']}-model-{tag_of(name, size, scale)}.tif", out_w)
            print(json.dumps({"case": case["id"], "variant": tag_of(name, size, scale), "working": list(out_w.shape[1::-1]), "seconds": round(time.time() - start, 1), "loadavg": round(os.getloadavg()[0], 1)}), flush=True)
        del model
    if args.outputs_only:
        return

    results, pairs = [], []
    first = tag_of(*variants[0])
    for case in cases:
        photo = glassio.read(benchmarks.resolve("glass", case))
        height, width = photo.shape[:2]
        if case["score"] == "truth":
            truth = glassio.read(benchmarks.resolve("glass", case).with_name(case["truth"]))
            truth_detail = highpass(truth)
            entry = {"case": case["id"], "size": [width, height], "methods": {"input": scores(photo, truth, truth_detail)}}
            for name, size, scale in variants:
                tag = tag_of(name, size, scale)
                out_w = glassio.read(args.work / f"{case['id']}-model-{tag}.tif")
                entry["methods"][f"output/{tag}"] = scores(fullres.upsampled_output(out_w, width, height), truth, truth_detail)
                start = time.time()
                est = fullres.estimate(photo, out_w, size)
                result = fullres.apply(est)
                seconds = time.time() - start
                entry["methods"][f"subtract/{tag}"] = {**scores(result, truth, truth_detail), "seconds": round(seconds, 1)}
                gains = np.array([a for a, _ in est["drift"]], np.float32)
                corrected = glassio.linear_to_srgb(np.clip(glassio.srgb_to_linear(out_w) * gains, 0, 1))
                entry["methods"][f"output-corrected/{tag}"] = scores(fullres.upsampled_output(corrected, width, height), truth, truth_detail)
                entry.setdefault("drift", {})[tag] = [[round(a, 3), round(b, 4)] for a, b in est["drift"]]
                if args.ablations and tag == first:
                    for label, kwargs in (("no-drift", {"drift": "off"}), ("affine-drift", {"drift": "affine"}), ("no-smooth", {"smooth_px": 0.0}), ("clip-exclude", {"clip_handling": "exclude"}), ("clip-replace", {"clip_handling": "replace"})):
                        entry["methods"][f"subtract-{label}/{tag}"] = scores(fullres.apply(fullres.estimate(photo, out_w, size, **kwargs)), truth, truth_detail)
                    glassio.write_jpeg(args.work / f"{case['id']}-subtract-{tag}.jpg", result)
                    glassio.write_jpeg(args.work / f"{case['id']}-output-{tag}.jpg", fullres.upsampled_output(out_w, width, height))
            entry["clipped"] = round(est["clipped"], 4)
            results.append(entry)
            print(json.dumps(entry), flush=True)
        elif args.real:
            out_w = glassio.read(args.work / f"{case['id']}-model-{first}.tif")
            est = fullres.estimate(photo, out_w, variants[0][1])
            images = {"output": fullres.upsampled_output(out_w, width, height), "subtract": fullres.apply(est)}
            paths = {}
            for method, image in images.items():
                paths[method] = args.work / f"{case['id']}-{method}-{first}.jpg"
                glassio.write_jpeg(paths[method], image, quality=97)
            for k, box in enumerate(crops(photo, est["reflection"])):
                pairs.append({"case": f"{case['id']} ({'strongest reflection' if k == 0 else 'detail'})", "a": {"method": f"output/{first}", "image": str(paths["output"])},
                              "b": {"method": f"subtract/{first}", "image": str(paths["subtract"])}, "crop": box})
            print(json.dumps({"case": case["id"], "drift": [[round(a, 3), round(b, 4)] for a, b in est["drift"]], "clipped": round(est["clipped"], 4)}), flush=True)

    if pairs:
        (args.work / "pairs.json").write_text(json.dumps(pairs, indent=2) + "\n")
    if not results:
        return
    out = ROOT / "research/benchmarks/results" / f"{args.round}.json"
    previous = json.loads(out.read_text()) if out.exists() else {}
    # A run adds its variants to what earlier runs of the same round scored.
    merged = {c["case"]: c for c in previous.get("cases", [])}
    for entry in results:
        old = merged.get(entry["case"], {})
        entry["methods"] = {**old.get("methods", {}), **entry["methods"]}
        entry["drift"] = {**old.get("drift", {}), **entry.get("drift", {})}
        merged[entry["case"]] = entry
    results = [merged[c["id"]] for c in benchmarks.cases("glass") if c["id"] in merged]
    methods = sorted({m for r in results for m in r["methods"]})
    complete = lambda m: [r for r in results if m in r["methods"]]
    summary = {m: {"cases": len(complete(m)), **{k: round(float(np.mean([r["methods"][m][k] for r in complete(m)])), 3) for k in ("psnr", "ssim", "detail_psnr")}} for m in methods}
    document = {
        "set": "glass",
        "round": args.round,
        "date": time.strftime("%Y-%m-%d"),
        "commit": git_commit(),
        "metric": "Against the truth at full resolution, sRGB: PSNR (dB), SSIM (scikit-image, 7×7 windows, per channel), detail PSNR (dB, the high-pass less a Gaussian at σ 2 px)",
        "methods": {
            "input": "The photo through glass, untouched",
            "output/<variant>-<size>": "WindowSeat's output at the working size (short side <size>, square tiles of that side), upsampled with Lanczos in sRGB",
            "output-corrected/<variant>-<size>": "The same output with the drift gain the subtraction uses applied first, then upsampled: what upsampling alone costs",
            "subtract/<variant>-<size>": "The reflection layer from the same output, upsampled and subtracted in linear light (fullres.py, defaults)",
            "<size>x2": "The working size twice <size> on the short side, in tiles of <size>",
            "subtract-no-drift": "The same without the drift correction",
            "subtract-affine-drift": "The same with the drift fitted as a·O + b on the lower envelope rather than a gain",
            "subtract-no-smooth": "The same without smoothing the reflection layer",
            "subtract-clip-exclude": "The same with clipped pixels left out of the reflection layer's upsampling",
            "subtract-clip-replace": "The same with, in addition, the corrected model output in the photo's clipped pixels",
        },
        "model": previous.get("model", {}),
        "cases": results,
        "summary": summary,
    }
    out.write_text(json.dumps(document, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps(summary, indent=1))


if __name__ == "__main__":
    main()
