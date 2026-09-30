"""Download the bake-off weights into build/proto-data/restoration/weights.

Only models whose terms allow internal evaluation are listed (see the licence matrix in
docs/research/notes/H-topaz-upscale-sharpen.md). Nothing here ships; weights are never committed.

Usage:
  build/restoration-venv/bin/python research/prototypes/restoration/fetch_models.py [model ...]
"""

from __future__ import annotations

import sys
import urllib.request

from common import WEIGHTS

GH = "https://github.com"
HF = "https://huggingface.co"

# id: (url, file name, licence note). "gdrive:<id>" URLs go through gdown.
MODELS = {
    # Upscalers: fidelity-trained and GAN-trained versions of the same network, plus community and GigaGAN models.
    "realesrnet_x4plus": (f"{GH}/xinntao/Real-ESRGAN/releases/download/v0.1.1/RealESRNet_x4plus.pth",
                          "RealESRNet_x4plus.pth", "BSD-3 code; weights unstated; DF2K+OST data"),
    "realesrgan_x4plus": (f"{GH}/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth",
                          "RealESRGAN_x4plus.pth", "BSD-3 code; weights unstated; DF2K+OST data"),
    "swinir_real_psnr_x4": (f"{GH}/JingyunLiang/SwinIR/releases/download/v0.0/"
                            "003_realSR_BSRGAN_DFOWMFC_s64w8_SwinIR-L_x4_PSNR.pth",
                            "SwinIR-L_realSR_x4_PSNR.pth", "Apache-2.0 code; weights unstated; DF2K+OST+WED+FFHQ+..."),
    "swinir_real_gan_x4": (f"{GH}/JingyunLiang/SwinIR/releases/download/v0.0/"
                           "003_realSR_BSRGAN_DFOWMFC_s64w8_SwinIR-L_x4_GAN.pth",
                           "SwinIR-L_realSR_x4_GAN.pth", "Apache-2.0 code; weights unstated"),
    "nomos8ksc_hatl": (f"{HF}/Phips/4xNomos8kSCHAT-L/resolve/main/4xNomos8kSCHAT-L.safetensors",
                       "4xNomos8kSCHAT-L.safetensors", "HF card CC-BY-4.0; Nomos8k dataset terms unclear"),
    "aurasr_v2": (f"{HF}/fal/AuraSR-v2/resolve/main/model.safetensors", "AuraSR-v2.safetensors",
                  "HF card Apache-2.0; training data undisclosed"),
    # Deblur.
    "nafnet_gopro_w32": ("gdrive:1zgALzrLCC_tcXKu_iHQTHukKUVT1aodI", "NAFNet-GoPro-width32.pth",
                         "MIT code; weights unstated; GoPro dataset"),
    "restormer_motion": (f"{GH}/swz30/Restormer/releases/download/v1.0/motion_deblurring.pth",
                         "Restormer_motion_deblurring.pth", "MIT code; weights unstated; GoPro"),
    "restormer_defocus": (f"{GH}/swz30/Restormer/releases/download/v1.0/single_image_defocus_deblurring.pth",
                          "Restormer_single_image_defocus.pth", "MIT code; weights unstated; DPDD (Canon)"),
    "restormer_denoise": (f"{GH}/swz30/Restormer/releases/download/v1.0/real_denoising.pth",
                          "Restormer_real_denoising.pth", "MIT code; weights unstated; SIDD (MIT per its site)"),
    "fftformer_gopro": (f"{GH}/kkkls/FFTformer/releases/download/pretrain_model/fftformer_GoPro.pth",
                        "fftformer_GoPro.pth", "MIT code; weights unstated; GoPro"),
    # Faces (applied to aligned 512 px face crops after background upscaling).
    "gfpgan_v14": (f"{GH}/TencentARC/GFPGAN/releases/download/v1.3.0/GFPGANv1.4.pth", "GFPGANv1.4.pth",
                   "Apache-2.0 code with NVIDIA StyleGAN2 parts; FFHQ (CC BY-NC-SA)"),
    "restoreformer": (f"{GH}/TencentARC/GFPGAN/releases/download/v1.3.4/RestoreFormer.pth", "RestoreFormer.pth",
                      "Apache-2.0 code; FFHQ (CC BY-NC-SA)"),
    # CodeFormer, SUPIR, HYPIR, UltraSharp, MPRNet, PromptIR and Stripformer are left out: their terms don't
    # allow evaluation by a commercial project (H2-open-model-survey.md section 0).
    # Face detector used to find and align faces (OpenCV Zoo YuNet, MIT).
    "yunet": ("https://github.com/opencv/opencv_zoo/raw/main/models/face_detection_yunet/"
              "face_detection_yunet_2023mar.onnx", "face_detection_yunet_2023mar.onnx", "MIT (opencv_zoo)"),
}


def fetch(model_id: str) -> None:
    url, name, _ = MODELS[model_id]
    out = WEIGHTS / name
    if out.exists() and out.stat().st_size > 0:
        return
    WEIGHTS.mkdir(parents=True, exist_ok=True)
    print(f"{model_id}: {url}")
    if url.startswith("gdrive:"):
        import gdown

        gdown.download(id=url.removeprefix("gdrive:"), output=str(out), quiet=True)
        return
    request = urllib.request.Request(url, headers={"User-Agent": "RedlampResearch/1.0"})
    tmp = out.with_suffix(out.suffix + ".part")
    with urllib.request.urlopen(request) as response, open(tmp, "wb") as f:
        while chunk := response.read(1 << 20):
            f.write(chunk)
    tmp.rename(out)


if __name__ == "__main__":
    for model_id in sys.argv[1:] or MODELS:
        fetch(model_id)
