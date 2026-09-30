"""Score the bake-off outputs and draw contact sheets.

Full-reference (synthetic items with ground truth): PSNR (RGB, 8 px border excluded), SSIM (luminance),
LPIPS (AlexNet, BSD-2) and DISTS (MIT). Lower LPIPS / DISTS is better.
Consistency: for upscaling, downscale the output with the degradation's bicubic kernel and compare it with
the input ("back-projection PSNR", note B section 5). Low values mean the output is not an upscale of the input
any more: detail was invented or content changed. For synthetic blur, re-blur with the true PSF and compare.
No-reference: zero-shot CLIP-IQA ("Good photo." vs "Bad photo.", Wang et al. 2023, arXiv 2207.12396),
reimplemented on OpenAI CLIP ViT-B/32 (MIT) because the pyiqa package is non-commercial. Higher is "better
looking"; it rewards invented crispness, so it is reported next to the consistency score, never alone.

Usage: build/restoration-venv/bin/python research/prototypes/restoration/score.py [--sheets-only]
Writes build/proto-out/restoration/{scores.csv,summary.md} and docs/research/images/restoration-*.jpg
"""

from __future__ import annotations

import argparse
import csv
import json
from collections import defaultdict

import cv2
import numpy as np
import torch
from skimage.metrics import structural_similarity

from common import (OUT, REPO, TESTSET, convolve_linear, downscale, load_manifest, poisson_gaussian_noise,
                    read_rgb)

IMAGES = REPO / "docs/research/images"
DEVICE = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
BORDER = 8

LABELS = {
    "lanczos": "Lanczos", "lanczos_usm": "Lanczos+USM", "vt_superres": "Apple VT SR",
    "realesrnet_x4plus": "Real-ESRNet (L1)", "realesrgan_x4plus": "Real-ESRGAN",
    "swinir_real_psnr_x4": "SwinIR-L (L1)", "swinir_real_gan_x4": "SwinIR-L GAN", "nomos8ksc_hatl": "HAT-L Nomos",
    "aurasr_v2": "AuraSR v2", "s3diff": "S3Diff (diffusion)", "usm": "Unsharp mask", "rl_gauss": "R-L, guessed PSF",
    "rl_oracle": "R-L, true PSF", "nafnet_gopro_w32": "NAFNet GoPro", "restormer_motion": "Restormer motion",
    "restormer_defocus": "Restormer defocus", "fftformer_gopro": "FFTformer", "instructir": "InstructIR",
    "face_gfpgan_v14": "GFPGAN 1.4", "face_restoreformer": "RestoreFormer",
    "denoise_then_deblur": "Denoise, then deblur", "noise_aware": "Noise-aware (noise added back)",
    "input": "(degraded input)",
}


def psnr(a: np.ndarray, b: np.ndarray, border: int = BORDER) -> float:
    if border:
        a, b = a[border:-border, border:-border], b[border:-border, border:-border]
    mse = float(((a - b) ** 2).mean())
    return 10 * np.log10(1 / max(mse, 1e-12))


def luma(x: np.ndarray) -> np.ndarray:
    return x @ np.array([0.299, 0.587, 0.114], np.float32)


class Metrics:
    def __init__(self):
        import lpips
        from DISTS_pytorch import DISTS
        from transformers import CLIPModel, CLIPProcessor

        self.lpips = lpips.LPIPS(net="alex", verbose=False).to(DEVICE).eval()
        self.dists = DISTS().to(DEVICE).eval()
        self.clip = CLIPModel.from_pretrained("openai/clip-vit-base-patch32").to(DEVICE).eval()
        self.processor = CLIPProcessor.from_pretrained("openai/clip-vit-base-patch32")
        with torch.inference_mode():
            text = self.processor(text=["Good photo.", "Bad photo."], return_tensors="pt", padding=True)
            pooled = self.clip.text_model(**{k: v.to(DEVICE) for k, v in text.items()}).pooler_output
            features = self.clip.text_projection(pooled)
            self.text = features / features.norm(dim=-1, keepdim=True)

    @staticmethod
    def tensor(x: np.ndarray) -> torch.Tensor:
        return torch.from_numpy(np.ascontiguousarray(x.transpose(2, 0, 1)))[None].to(DEVICE)

    @torch.inference_mode()
    def full_reference(self, out: np.ndarray, gt: np.ndarray) -> dict:
        o, g = self.tensor(out), self.tensor(gt)
        return dict(
            psnr=psnr(out, gt),
            ssim=float(structural_similarity(luma(out)[BORDER:-BORDER, BORDER:-BORDER],
                                             luma(gt)[BORDER:-BORDER, BORDER:-BORDER], data_range=1.0)),
            lpips=float(self.lpips(o * 2 - 1, g * 2 - 1).item()),
            dists=float(self.dists(o, g, batch_average=True).item()),
        )

    @torch.inference_mode()
    def clipiqa(self, out: np.ndarray) -> float:
        inputs = self.processor(images=(np.clip(out, 0, 1) * 255).astype(np.uint8), return_tensors="pt")
        pooled = self.clip.vision_model(pixel_values=inputs["pixel_values"].to(DEVICE)).pooler_output
        features = self.clip.visual_projection(pooled)
        features = features / features.norm(dim=-1, keepdim=True)
        logits = 100 * features @ self.text.T
        return float(logits.softmax(dim=-1)[0, 0].item())


def consistency(out: np.ndarray, lq: np.ndarray, item: dict, manifest: dict) -> float | None:
    """How well the output, re-degraded, reproduces the input it was made from."""
    if item["task"] == "sr" or item["factor"] > 1:
        factor = item["factor"]
        down = downscale(out, factor)
        return psnr(down, lq, border=max(BORDER // factor, 2))
    degradation = item.get("degradation")
    psf_path = TESTSET / "psf" / f"{degradation}.npy" if degradation else None
    if psf_path is None or not psf_path.exists() or manifest["degradations"][degradation].get("noise"):
        return None
    return psnr(convolve_linear(out, np.load(psf_path)), lq)


def noisy_ground_truth(gt: np.ndarray, item: dict, manifest: dict) -> np.ndarray:
    """The sharp ground truth carrying the same noise draw as the degraded input (make_testset's seeding):
    the target of a sharpener that keeps the photo's noise, as Topaz's Noise-Aware Sharpen does."""
    seed = 1000 * list(manifest["crops"]).index(item["crop"]) + list(manifest["degradations"]).index(item["degradation"])
    return poisson_gaussian_noise(gt, seed=seed, **manifest["noise"])


def score(manifest: dict) -> list[dict]:
    metrics = Metrics()
    lookup = {i["id"]: i for i in manifest["items"] + manifest["real"]}
    rows = []
    for run_path in sorted((OUT / "runs").glob("*.json")):
        run = json.loads(run_path.read_text())
        method = run["method"]
        for item_id, seconds in run["times"].items():
            item = lookup[item_id]
            out = read_rgb(OUT / "outputs" / method / f"{item_id}.png")
            lq = read_rgb(TESTSET / item["lq"])
            row = dict(method=method, task=run["task"], item=item_id, crop=item["crop"],
                       degradation=item.get("degradation", "real"), tags="|".join(item["tags"]), seconds=seconds,
                       clipiqa=metrics.clipiqa(out), consistency=consistency(out, lq, item, manifest))
            if "gt" in item:
                gt = read_rgb(TESTSET / item["gt"])
                row.update(metrics.full_reference(out, gt))
                if manifest["degradations"][item["degradation"]].get("noise"):
                    row["psnr_noisy_gt"] = psnr(out, noisy_ground_truth(gt, item, manifest))
            rows.append(row)
        print(f"scored {method}")
    # The untouched degraded input, so a method can be judged on whether it helps at all.
    for item in manifest["items"]:
        if item["task"] != "deblur":
            continue
        lq, gt = read_rgb(TESTSET / item["lq"]), read_rgb(TESTSET / item["gt"])
        row = dict(method="input", task="deblur", item=item["id"], crop=item["crop"], degradation=item["degradation"],
                   tags="|".join(item["tags"]), seconds=0.0, clipiqa=metrics.clipiqa(lq), consistency=None,
                   **metrics.full_reference(lq, gt))
        if manifest["degradations"][item["degradation"]].get("noise"):
            row["psnr_noisy_gt"] = psnr(lq, noisy_ground_truth(gt, item, manifest))
        rows.append(row)
    return rows


def summarise(rows: list[dict]) -> str:
    def mean(values):
        values = [v for v in values if v is not None]
        return float(np.mean(values)) if values else float("nan")

    lines = ["# Bake-off summary (generated by score.py)", ""]
    groups = {"sr": ["x2", "x4", "x4_real", "real"],
              "deblur": ["soft_g1.5", "defocus_r4", "motion_lin15", "motion_traj21", "defocus_r3_noise", "real"],
              "face": ["x4", "x4_real"], "sr-faces": ["x4", "x4_real"]}
    for task, degradations in groups.items():
        source = task.removesuffix("-faces")
        methods = sorted({r["method"] for r in rows if r["task"] == source},
                         key=lambda m: -1 if m == "input" else list(LABELS).index(m) if m in LABELS else 99)
        for degradation in degradations:
            subset = [r for r in rows if r["task"] == source and r["degradation"] == degradation
                      and (task != "sr-faces" or "faces" in r["tags"])]
            if not subset:
                continue
            real = degradation == "real"
            noisy = any("psnr_noisy_gt" in r and r["psnr_noisy_gt"] is not None for r in subset)
            lines += [f"## {task} / {degradation}", ""]
            header = "| Method | " + ("" if real else "PSNR | SSIM | LPIPS | DISTS | ") + \
                     ("PSNR vs noisy GT | " if noisy else "") + "Consistency PSNR | CLIP-IQA | Median s |"
            lines += [header, "|" + "---|" * (header.count("|") - 1)]
            for method in methods:
                sel = [r for r in subset if r["method"] == method]
                if not sel:
                    continue
                cells = [LABELS.get(method, method)]
                if not real:
                    cells += [f"{mean(r['psnr'] for r in sel):.2f}", f"{mean(r['ssim'] for r in sel):.3f}",
                              f"{mean(r['lpips'] for r in sel):.3f}", f"{mean(r['dists'] for r in sel):.3f}"]
                if noisy:
                    cells.append(f"{mean(r.get('psnr_noisy_gt') for r in sel):.2f}")
                cells += [f"{mean(r['consistency'] for r in sel):.2f}", f"{mean(r['clipiqa'] for r in sel):.3f}",
                          f"{np.median([r['seconds'] for r in sel]):.3f}"]
                lines.append("| " + " | ".join(cells) + " |")
            lines.append("")
    return "\n".join(lines)


# --- Contact sheets ---------------------------------------------------------------------------


def tile(image: np.ndarray, box: tuple[int, int, int], label: str) -> np.ndarray:
    x, y, size = box
    crop = image[y:y + size, x:x + size]
    crop = cv2.resize(crop, (256, 256), interpolation=cv2.INTER_NEAREST if size <= 128 else cv2.INTER_AREA)
    out = (np.clip(crop, 0, 1) * 255).astype(np.uint8)[..., ::-1].copy()
    cv2.rectangle(out, (0, 0), (256, 22), (0, 0, 0), -1)
    cv2.putText(out, label, (5, 16), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 255, 255), 1, cv2.LINE_AA)
    return out


def sheet(name: str, rows: list[tuple[str, tuple[int, int, int]]], methods: list[str], manifest: dict) -> None:
    lookup = {i["id"]: i for i in manifest["items"] + manifest["real"]}
    lines = []
    for item_id, (x, y, size) in rows:
        item = lookup[item_id]
        lq = read_rgb(TESTSET / item["lq"])
        f = item["factor"]
        lq_up = cv2.resize(lq, (lq.shape[1] * f, lq.shape[0] * f), interpolation=cv2.INTER_NEAREST)
        tiles = [tile(lq_up, (x, y, size), f"input ({item.get('degradation', 'real')})")]
        for method in methods:
            path = OUT / "outputs" / method / f"{item_id}.png"
            if path.exists():
                tiles.append(tile(read_rgb(path), (x, y, size), LABELS.get(method, method)))
        if "gt" in item:
            tiles.append(tile(read_rgb(TESTSET / item["gt"]), (x, y, size), "ground truth"))
        lines.append(np.concatenate(tiles, 1))
    width = max(line.shape[1] for line in lines)
    lines = [np.pad(line, ((0, 0), (0, width - line.shape[1]), (0, 0))) for line in lines]
    IMAGES.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(IMAGES / f"restoration-{name}.jpg"), np.concatenate(lines, 0), [cv2.IMWRITE_JPEG_QUALITY, 86])
    print(f"wrote restoration-{name}.jpg")


def sheets(manifest: dict) -> None:
    upscalers = ["lanczos", "vt_superres", "realesrnet_x4plus", "realesrgan_x4plus", "swinir_real_psnr_x4",
                 "swinir_real_gan_x4", "nomos8ksc_hatl", "aurasr_v2", "s3diff"]
    sheet("upscale", [("fuji_text__x4", (140, 240, 160)), ("sony_branches__x4", (180, 120, 160)),
                      ("square_people__x4_real", (250, 250, 160)), ("leica_dial__x4", (200, 120, 160)),
                      ("canon_wall__x4_real", (150, 150, 160))], upscalers, manifest)
    sheet("upscale-real", [("fuji_text__real", (100, 100, 192)), ("sony_branches__real", (100, 100, 192)),
                           ("nikon_monkey__real", (100, 60, 192)), ("iphone_grass__real", (100, 100, 192))],
          upscalers, manifest)
    deblur = ["usm", "rl_gauss", "rl_oracle", "nafnet_gopro_w32", "restormer_motion", "restormer_defocus",
              "fftformer_gopro", "instructir"]
    sheet("deblur", [("fuji_text__defocus_r4", (180, 280, 160)), ("leica_dial__motion_traj21", (200, 120, 160)),
                     ("canon_wall__motion_lin15", (150, 150, 160)), ("sony_branches__soft_g1.5", (180, 120, 160)),
                     ("nikon_monkey__defocus_r3_noise", (170, 120, 160)),
                     ("fuji_plush_defocus__real", (150, 150, 200))], deblur, manifest)
    sheet("noise-aware", [("nikon_monkey__defocus_r3_noise", (170, 120, 160)),
                          ("sony_branches__defocus_r3_noise", (180, 120, 160)),
                          ("leica_fur__defocus_r3_noise", (150, 150, 160))],
          ["rl_gauss", "restormer_defocus", "instructir", "denoise_then_deblur", "noise_aware"], manifest)
    sheet("faces", [("exp64_faces__x4", (140, 90, 220)), ("sts135_faces__x4_real", (40, 80, 220)),
                    ("sts135_faces__x4", (260, 60, 220))],
          ["lanczos", "realesrgan_x4plus", "face_gfpgan_v14", "face_restoreformer", "s3diff"], manifest)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sheets-only", action="store_true")
    args = parser.parse_args()
    manifest = load_manifest()
    if not args.sheets_only:
        rows = score(manifest)
        with open(OUT / "scores.csv", "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=sorted({k for r in rows for k in r}))
            writer.writeheader()
            writer.writerows(rows)
        (OUT / "summary.md").write_text(summarise(rows))
        print(f"wrote {OUT / 'summary.md'}")
    sheets(manifest)


if __name__ == "__main__":
    main()
