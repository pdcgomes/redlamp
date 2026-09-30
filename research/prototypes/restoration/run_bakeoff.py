"""Run every bake-off method over the test set and record wall time.

Methods are grouped by task:
  sr     - upscalers, evaluated on the 2x / 4x degradations and the real 2x crops
  deblur - sharpening and deblur, on the blur degradations and the real defocus crops
  face   - background upscale + face restoration, on the face crops at 4x

Networks load through spandrel (MIT) and run on the Apple GPU through PyTorch MPS in float32.
A 4x-only upscaler answers a 2x request by running at 4x and downscaling (as note B does for Apple's scaler).

Usage:
  build/restoration-venv/bin/python research/prototypes/restoration/run_bakeoff.py [--only a,b] [--task sr]
Outputs: build/proto-out/restoration/outputs/<method>/<item>.png and runs/<method>.json
"""

from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path

os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

import cv2
import numpy as np
import torch

from common import (OUT, TESTSET, WEIGHTS, gaussian_psf, linear_to_srgb, load_manifest, read_rgb, srgb_to_linear,
                    write_rgb)
from fetch_models import MODELS

DEVICE = torch.device("mps" if torch.backends.mps.is_available() else "cpu")


def sync() -> None:
    if DEVICE.type == "mps":
        torch.mps.synchronize()


def resize(image: np.ndarray, factor: float, interpolation=cv2.INTER_LANCZOS4) -> np.ndarray:
    h, w = image.shape[:2]
    size = (int(round(w * factor)), int(round(h * factor)))
    if factor < 1:
        interpolation = cv2.INTER_AREA
    return np.clip(cv2.resize(image, size, interpolation=interpolation), 0, 1)


def luminance_unsharp(image: np.ndarray, amount: float, sigma: float) -> np.ndarray:
    """Unsharp mask on log luminance applied as one ratio to RGB, like Redlamp's Detail stage."""
    linear = srgb_to_linear(image)
    y = np.clip(linear @ np.array([0.2126, 0.7152, 0.0722], np.float32), 1e-5, None)
    log_y = np.log(y)
    detail = log_y - cv2.GaussianBlur(log_y, (0, 0), sigma)
    ratio = np.exp(amount * detail)[..., None]
    return np.clip(linear_to_srgb(linear * ratio), 0, 1)


# --- Methods ----------------------------------------------------------------------------------


class Method:
    id: str
    task: str
    scale = 1
    note = ""

    def load(self) -> None:
        pass

    def __call__(self, image: np.ndarray, factor: int, item: dict) -> np.ndarray:
        raise NotImplementedError


class Lanczos(Method):
    task = "sr"
    note = "Lanczos-4 in sRGB"

    def __init__(self, sharpen: float = 0.0):
        self.sharpen = sharpen
        self.id = "lanczos_usm" if sharpen else "lanczos"
        if sharpen:
            self.note = f"Lanczos-4 then luminance unsharp mask (amount {sharpen}, sigma 1.0 px)"

    def __call__(self, image, factor, item):
        out = resize(image, factor)
        return luminance_unsharp(out, self.sharpen, 1.0) if self.sharpen else out


class Unsharp(Method):
    task = "deblur"

    def __init__(self, amount: float, sigma: float):
        self.amount, self.sigma = amount, sigma
        self.id = "usm"
        self.note = f"luminance unsharp mask amount {amount}, sigma {sigma} px (Redlamp-style sharpening, strong)"

    def __call__(self, image, factor, item):
        return luminance_unsharp(image, self.amount, self.sigma)


class RichardsonLucy(Method):
    """Richardson-Lucy in linear light. `oracle` uses the true PSF (an upper bound for classical
    non-blind deconvolution); otherwise a Gaussian guess stands in for a lens profile or blind estimate."""

    task = "deblur"

    def __init__(self, oracle: bool, iterations: int = 30, guess_sigma: float = 1.6):
        self.oracle, self.iterations, self.guess_sigma = oracle, iterations, guess_sigma
        self.id = "rl_oracle" if oracle else "rl_gauss"
        self.note = (f"Richardson-Lucy, {iterations} iterations, true PSF" if oracle else
                     f"Richardson-Lucy, {iterations} iterations, Gaussian PSF guess sigma {guess_sigma} px")

    def __call__(self, image, factor, item):
        if self.oracle:
            if "degradation" not in item:
                return None
            psf_path = TESTSET / "psf" / f"{item['degradation']}.npy"
            psf = np.load(psf_path)
        else:
            psf = gaussian_psf(self.guess_sigma)
        return richardson_lucy(image, psf, self.iterations)


def richardson_lucy(image: np.ndarray, psf: np.ndarray, iterations: int) -> np.ndarray:
    pad = psf.shape[0]
    linear = np.pad(srgb_to_linear(image), ((pad, pad), (pad, pad), (0, 0)), mode="reflect") + 1e-4
    estimate = linear.copy()
    flipped = psf[::-1, ::-1]
    for _ in range(iterations):
        blurred = cv2.filter2D(estimate, -1, psf, borderType=cv2.BORDER_REFLECT)
        ratio = linear / np.maximum(blurred, 1e-6)
        estimate *= cv2.filter2D(ratio, -1, flipped, borderType=cv2.BORDER_REFLECT)
    return np.clip(linear_to_srgb(estimate[pad:-pad, pad:-pad] - 1e-4), 0, 1)


class Network(Method):
    """A spandrel-loadable image-to-image network."""

    def __init__(self, model_id: str, task: str, note: str = ""):
        self.id, self.task, self.note = model_id, task, note or MODELS[model_id][2]
        self.model = None

    def load(self):
        import spandrel
        import spandrel_extra_arches

        spandrel_extra_arches.install(ignore_duplicates=True)
        path = WEIGHTS / MODELS[self.id][1]
        self.model = spandrel.ModelLoader(device=DEVICE).load_from_file(str(path)).eval()
        self.scale = self.model.scale

    @torch.inference_mode()
    def infer(self, image: np.ndarray) -> np.ndarray:
        h, w = image.shape[:2]
        req = self.model.size_requirements
        multiple = max(req.multiple_of, 1)
        target_h = max(req.minimum, -(-h // multiple) * multiple)
        target_w = max(req.minimum, -(-w // multiple) * multiple)
        if req.square:
            target_h = target_w = max(target_h, target_w)
        padded = np.pad(image, ((0, target_h - h), (0, target_w - w), (0, 0)), mode="reflect")
        tensor = torch.from_numpy(np.ascontiguousarray(padded.transpose(2, 0, 1)))[None].to(DEVICE)
        out = self.model(tensor)
        sync()
        out = out[0].clamp(0, 1).float().cpu().numpy().transpose(1, 2, 0)
        return out[: h * self.scale, : w * self.scale]

    def __call__(self, image, factor, item):
        if self.task == "deblur":
            return self.infer(image)
        out = self.infer(image)
        if self.scale != factor:
            out = resize(out, factor / self.scale)
        return out


class NoiseAwareSharpen(Method):
    """Topaz's published recipe for Noise-Aware Sharpen: "Noise is detected and removed. Image is sharpened.
    Noise is added back exactly as it was." Denoise with Restormer (real noise), deblur the clean estimate with
    Restormer (defocus), then optionally add the removed residual back."""

    task = "deblur"

    def __init__(self, add_back: bool):
        self.add_back = add_back
        self.id = "noise_aware" if add_back else "denoise_then_deblur"
        self.note = ("Restormer real-noise denoise, Restormer defocus deblur, " +
                     ("then the removed noise added back (Topaz's published Noise-Aware recipe)" if add_back
                      else "noise not added back"))

    def load(self):
        self.denoise = Network("restormer_denoise", "deblur")
        self.deblur = Network("restormer_defocus", "deblur")
        self.denoise.load()
        self.deblur.load()

    def __call__(self, image, factor, item):
        clean = self.denoise.infer(image)
        sharp = self.deblur.infer(clean)
        return np.clip(sharp + (image - clean), 0, 1) if self.add_back else sharp


class InstructIR(Method):
    """All-in-one restoration steered by a text instruction (arXiv 2401.16468, MIT; weights in the repo,
    text encoder TaylorAI/bge-micro-v2). Needs build/oss/InstructIR (git clone https://github.com/mv-lab/InstructIR)."""

    task = "deblur"
    id = "instructir"
    prompt = "I took this photo while I was running, can you stabilize the image? it is too blurry"
    note = f"InstructIR 7-task model, prompt: \"{prompt}\"; MIT code and weights"

    def load(self):
        import sys

        import yaml

        repo = Path(__file__).resolve().parents[3] / "build/oss/InstructIR"
        sys.path.insert(0, str(repo))
        from models import instructir
        from text.models import LanguageModel, LMHead

        cfg = yaml.safe_load((repo / "configs/eval5d.yml").read_text())
        m, llm = cfg["model"], cfg["llm"]
        self.model = instructir.create_model(input_channels=m["in_ch"], width=m["width"], enc_blks=m["enc_blks"],
                                             middle_blk_num=m["middle_blk_num"], dec_blks=m["dec_blks"],
                                             txtdim=m["textdim"])
        self.model.load_state_dict(torch.load(repo / "models/im_instructir-7d.pt", map_location="cpu"))
        self.model = self.model.to(DEVICE).eval()
        head = LMHead(embedding_dim=llm["model_dim"], hidden_dim=llm["embd_dim"], num_classes=llm["nclasses"])
        head.load_state_dict(torch.load(repo / "models/lm_instructir-7d.pt", map_location="cpu"))
        with torch.inference_mode():
            self.text, _ = head(LanguageModel(model=llm["model"])(self.prompt))
        self.text = self.text.to(DEVICE)

    @torch.inference_mode()
    def __call__(self, image, factor, item):
        tensor = torch.from_numpy(np.ascontiguousarray(image.transpose(2, 0, 1)))[None].to(DEVICE)
        out = self.model(tensor, self.text)
        sync()
        return out[0].clamp(0, 1).cpu().numpy().transpose(1, 2, 0)


# FFHQ-aligned 5-point template for a 512 px face (the convention GFPGAN, CodeFormer and RestoreFormer use).
FFHQ_TEMPLATE = np.array([[192.98138, 239.94708], [318.90277, 240.1936], [256.63416, 314.01935],
                          [201.26117, 371.41043], [313.08905, 371.15118]], np.float32)


class FacePipeline(Method):
    """Background upscale with Real-ESRGAN, then detect (YuNet), align, restore each face and paste it back."""

    task = "face"

    def __init__(self, face_model: str, background: Network):
        self.id = f"face_{face_model}"
        self.face_model, self.background = face_model, background
        self.note = f"Real-ESRGAN x4plus background + {face_model} faces; " + MODELS[face_model][2]

    def load(self):
        if self.background.model is None:
            self.background.load()
        self.face = Network(self.face_model, "face")
        self.face.load()
        self.detector = cv2.FaceDetectorYN.create(str(WEIGHTS / MODELS["yunet"][1]), "", (320, 320), 0.6)

    def __call__(self, image, factor, item):
        base = self.background(image, factor, item)
        h, w = base.shape[:2]
        self.detector.setInputSize((w, h))
        _, faces = self.detector.detect((base[..., ::-1] * 255).astype(np.uint8))
        out = base.copy()
        for face in faces if faces is not None else []:
            landmarks = face[4:14].reshape(5, 2).astype(np.float32)
            matrix, _ = cv2.estimateAffinePartial2D(landmarks, FFHQ_TEMPLATE, method=cv2.LMEDS)
            aligned = cv2.warpAffine(base, matrix, (512, 512), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT)
            restored = self.face.infer(aligned)
            inverse = cv2.invertAffineTransform(matrix)
            back = cv2.warpAffine(restored, inverse, (w, h), flags=cv2.INTER_LINEAR)
            mask = np.zeros((512, 512), np.float32)
            cv2.rectangle(mask, (40, 40), (472, 472), 1.0, -1)
            mask = cv2.GaussianBlur(mask, (0, 0), 20)
            mask = cv2.warpAffine(mask, inverse, (w, h), flags=cv2.INTER_LINEAR)[..., None]
            out = out * (1 - mask) + back * mask
        return np.clip(out, 0, 1)


def methods() -> list[Method]:
    background = Network("realesrgan_x4plus", "sr")
    return [
        Lanczos(), Lanczos(sharpen=0.6),
        Network("realesrnet_x4plus", "sr"), background,
        Network("swinir_real_psnr_x4", "sr"), Network("swinir_real_gan_x4", "sr"),
        Network("nomos8ksc_hatl", "sr"), Network("aurasr_v2", "sr"),
        Unsharp(1.0, 1.5), RichardsonLucy(oracle=True), RichardsonLucy(oracle=False),
        Network("nafnet_gopro_w32", "deblur"), Network("restormer_motion", "deblur"),
        Network("restormer_defocus", "deblur"), Network("fftformer_gopro", "deblur"), InstructIR(),
        NoiseAwareSharpen(add_back=False), NoiseAwareSharpen(add_back=True),
        FacePipeline("gfpgan_v14", background), FacePipeline("restoreformer", background),
    ]


def items_for(method: Method, manifest: dict) -> list[dict]:
    if method.task == "face":
        return [i for i in manifest["items"] if "faces" in i["tags"] and i["task"] == "sr" and i["factor"] == 4]
    if isinstance(method, NoiseAwareSharpen):
        return [i for i in manifest["items"] if manifest["degradations"][i["degradation"]].get("noise")]
    items = [i for i in manifest["items"] if i["task"] == method.task]
    if not isinstance(method, RichardsonLucy) or not method.oracle:
        items += [r for r in manifest["real"] if r["task"] == method.task]
    return items


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", help="comma-separated method ids")
    parser.add_argument("--task", choices=["sr", "deblur", "face"])
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    manifest = load_manifest()
    only = set(args.only.split(",")) if args.only else None
    for method in methods():
        if (only and method.id not in only) or (args.task and method.task != args.task):
            continue
        items = items_for(method, manifest)
        run_path = OUT / "runs" / f"{method.id}.json"
        if run_path.exists() and not args.force:
            print(f"{method.id}: done already")
            continue
        try:
            method.load()
        except Exception as error:  # a missing or unloadable model shouldn't stop the others
            print(f"{method.id}: load failed: {error!r}")
            continue
        times, peak = {}, 0
        for index, item in enumerate(items):
            image = read_rgb(TESTSET / item["lq"])
            if index == 0:
                method(image, item["factor"], item)  # warm-up (kernel compilation, allocation)
            start = time.perf_counter()
            out = method(image, item["factor"], item)
            sync()
            elapsed = time.perf_counter() - start
            if out is None:
                continue
            if DEVICE.type == "mps":
                peak = max(peak, torch.mps.driver_allocated_memory())
            times[item["id"]] = elapsed
            write_rgb(OUT / "outputs" / method.id / f"{item['id']}.png", out)
        run_path.parent.mkdir(parents=True, exist_ok=True)
        run_path.write_text(json.dumps(dict(method=method.id, task=method.task, note=method.note,
                                            device=str(DEVICE), times=times, mps_driver_peak_bytes=peak), indent=1))
        print(f"{method.id}: {len(times)} items, median {np.median(list(times.values())):.3f} s")
        if DEVICE.type == "mps":
            torch.mps.empty_cache()


if __name__ == "__main__":
    main()
