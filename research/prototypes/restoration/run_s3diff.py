"""Run S3Diff (one-step diffusion SR on SD-Turbo, arXiv 2409.17058) over the upscaling items.

S3Diff hard-codes CUDA, so this imports a copy of its repo with CUDA calls pointed at MPS:
  git clone https://github.com/ArcticHare105/S3Diff build/oss/S3Diff
  cp -R build/oss/S3Diff build/oss/S3Diff-mps
  (in S3Diff-mps: replace `.cuda()` with `.to("mps")` and "cuda" device strings with "mps")
It needs its own pinned environment (diffusers 0.25.1, transformers 4.35.2, peft 0.10.0):
  uv venv --python python3.12 build/s3diff-venv
  VIRTUAL_ENV=build/s3diff-venv uv pip install torch torchvision diffusers==0.25.1 transformers==4.35.2 \
      peft==0.10.0 huggingface_hub==0.22.2 accelerate omegaconf einops opencv-python-headless pillow scipy timm

Weights: zhangap/S3Diff (Apache-2.0) and stabilityai/sd-turbo (Stability AI Community Licence, which
permits evaluation). The same fixed prompts and guidance scale 1.07 as the authors' inference script.

Usage: build/s3diff-venv/bin/python research/prototypes/restoration/run_s3diff.py
"""

from __future__ import annotations

import json
import os
import sys
import time
from types import SimpleNamespace

os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

import numpy as np
import torch
import torch.nn.functional as F

from common import OUT, REPO, TESTSET, load_manifest, read_rgb, write_rgb

S3DIFF = REPO / "build/oss/S3Diff-mps"
sys.path[:0] = [str(S3DIFF), str(S3DIFF / "src")]
os.chdir(S3DIFF)

from huggingface_hub import hf_hub_download, snapshot_download  # noqa: E402

from de_net import DEResNet  # noqa: E402
from s3diff_tile import S3Diff  # noqa: E402
from utils.wavelet_color import wavelet_color_fix  # noqa: E402

POS = "A high-resolution, 8K, ultra-realistic image with sharp focus, vibrant colors, and natural lighting."
NEG = "oil painting, cartoon, blur, dirty, messy, low quality, deformation, low resolution, oversmooth"
METHOD = "s3diff"


def main() -> None:
    torch.manual_seed(0)
    args = SimpleNamespace(latent_tiled_size=96, latent_tiled_overlap=32, vae_encoder_tiled_size=1024,
                           vae_decoder_tiled_size=224)
    net = S3Diff(sd_path=snapshot_download("stabilityai/sd-turbo"),
                 pretrained_path=hf_hub_download("zhangap/S3Diff", "s3diff.pkl"), args=args)
    net.set_eval()
    net.to("mps")
    de = DEResNet(num_in_ch=3, num_degradation=2)
    de.load_model(hf_hub_download("zhangap/S3Diff", "de_net.pth"))
    de = de.to("mps").eval()

    from PIL import Image

    manifest = load_manifest()
    items = [i for i in manifest["items"] if i["task"] == "sr"] + [r for r in manifest["real"] if r["task"] == "sr"]
    times = {}
    for index, item in enumerate(items):
        lr = torch.from_numpy(read_rgb(TESTSET / item["lq"]).transpose(2, 0, 1))[None].to("mps")
        for attempt in range(2 if index == 0 else 1):  # the first item runs twice to warm up
            torch.manual_seed(0)
            start = time.perf_counter()
            with torch.no_grad():
                h, w = lr.shape[2:]
                up = F.interpolate(lr, size=(h * item["factor"], w * item["factor"]), mode="bilinear",
                                   align_corners=False)
                norm = (up * 2 - 1).clamp(-1, 1)
                pad_h, pad_w = (-norm.shape[2]) % 64, (-norm.shape[3]) % 64
                norm = F.pad(norm, (0, pad_w, 0, pad_h), mode="reflect")
                out = net(norm, de(lr), pos_prompt=[POS], neg_prompt=[NEG])
                out = (out[:, :, : up.shape[2], : up.shape[3]] * 0.5 + 0.5).clamp(0, 1)
            torch.mps.synchronize()
            elapsed = time.perf_counter() - start
        out_pil = Image.fromarray((out[0].permute(1, 2, 0).cpu().numpy() * 255 + 0.5).astype(np.uint8))
        up_pil = Image.fromarray((up[0].permute(1, 2, 0).cpu().numpy() * 255 + 0.5).astype(np.uint8))
        fixed = np.asarray(wavelet_color_fix(out_pil, up_pil)).astype(np.float32) / 255
        write_rgb(OUT / "outputs" / METHOD / f"{item['id']}.png", fixed)
        times[item["id"]] = elapsed
        print(f"{item['id']}: {elapsed:.2f} s", flush=True)
    (OUT / "runs").mkdir(parents=True, exist_ok=True)
    (OUT / "runs" / f"{METHOD}.json").write_text(json.dumps(dict(
        method=METHOD, task="sr", device="mps", times=times, mps_driver_peak_bytes=torch.mps.driver_allocated_memory(),
        note="S3Diff one-step diffusion on SD-Turbo, authors' prompts, guidance 1.07, wavelet colour fix; "
             "Apache-2.0 code and weights, SD-Turbo Stability AI Community Licence"), indent=1))


if __name__ == "__main__":
    main()
