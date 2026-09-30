# H2. Open-model survey: Topaz-like upscaling, sharpening/deblurring, face restoration

Appendix to [H-topaz-upscale-sharpen.md](H-topaz-upscale-sharpen.md), which has the bake-off results
and the recommendation.

Author: research agent. All licences were checked on **2026-09-30** from the primary
source named next to each claim, following `docs/research/notes/_conventions.md`. The
source URL patterns used were:

- Repo licence: `gh api repos/<org>/<repo>` (SPDX) plus the LICENSE text itself
  (`gh api repos/<org>/<repo>/license`).
- Weights: `https://huggingface.co/api/models/<id>` (`cardData.license`), or the GitHub
  release asset list (`gh api repos/<org>/<repo>/releases`).
- Community upscalers: the OpenModelDB per-model JSON at
  `https://raw.githubusercontent.com/OpenModelDB/open-model-database/main/data/models/<id>.json`.
- Papers: the arXiv abstract pages (`https://export.arxiv.org/abs/<id>`) and the HTML full
  text (`https://arxiv.org/html/<id>`) for benchmark tables.

Scratch downloads were temporary and were not added to the repo. **Nothing in this appendix was
run locally.** All speed and quality numbers here are the authors' own, and the Apple Silicon
feasibility notes are assessments. The measured bake-off is in
[H-topaz-upscale-sharpen.md](H-topaz-upscale-sharpen.md) section 6.

This note does **not** repeat the models covered in
[B-super-resolution.md](B-super-resolution.md): SwinIR, HAT
(classic), DAT, SRFormer, SPAN, ESRGAN, Real-ESRGAN, StableSR, SUPIR, SeeSR, OSEDiff,
DiffBIR, PASD and InvSR. The one exception is SUPIR and DiffBIR, which are re-checked here
only for whether they allow internal evaluation (section 3).

## TL;DR

- **Internal evaluation is allowed for most, but not all, popular models.**
  - **Allowed:** permissive code with weights that carry no extra terms (Apache/MIT/BSD),
    FLUX.1-dev's NC licence, the Stability AI Community Licence and NVIDIA's NC licence.
    The last three explicitly carve out testing and evaluation.
  - **Not allowed for a commercial company:** S-Lab / Pi-Lab licences, the SupPixel
    licence (SUPIR, HYPIR), the "Academic Public License" (MPRNet, PromptIR, LoFormer),
    Stripformer's modified MIT, CC BY-NC(-SA) weights, and PolyForm Noncommercial.
- **SUPIR (and HYPIR, same licensor): evaluation is NOT allowed.** The SupPixel licence
  defines Commercial Use as "any use … for the purpose of … conducting business operations,
  or creating products or services for sale or profit" and says the weights "may only be
  used for non-commercial purposes". HYPIR's Hugging Face card says `apache-2.0`, which
  contradicts its repo LICENSE, so it is UNCLEAR at best, and the stricter text governs.
- **DiffBIR: evaluation IS allowed.** The code is Apache-2.0, the HF weights
  (`lxq007/DiffBIR-v2`) are tagged apache-2.0, and the base model
  (`ByteDance/sd2.1-base-zsnr-laionaes5`) is openrail++.
- **pyiqa / IQA-PyTorch is now PolyForm Noncommercial 1.0.0.** It moved from CC BY-NC-SA 4.0
  in commit `ccac804` on 2026-04-09, and its HF weights repo is `cc-by-nc-sa-4.0`. **Do not
  use it in the eval harness.** Use LPIPS (BSD-2), DISTS (MIT), MUSIQ (Apache-2.0,
  google-research) and MANIQA (Apache-2.0) directly, and reimplement CLIP-IQA from the
  paper on OpenAI CLIP (MIT).
- **Deblur is the one area with clean-ish data.**
  - The GoPro, REDS and RealBlur datasets are all **CC BY 4.0** (dataset pages).
  - NAFNet (MIT), Restormer and FFTformer (MIT) GoPro weights are therefore close to
    shippable, pending a weights-licence confirmation. Restormer was relicensed from
    "Academic Public License" to MIT on 2025-10-23.
  - This is the strongest "use off the shelf, or retrain cheaply on the same CC BY data"
    story in this survey.
- **OpenModelDB community upscalers are mostly labelled CC-BY-4.0, but their data is
  tainted.** Nomos-v2 and nomos_uni are "distilled" from DIV8K, FFHQ, KonIQ, LSDIR,
  Flickr2K, FiveK and Unsplash (neosr README), and most are fine-tuned from DF2K or ImageNet
  pretrains. They are fine for evaluation and not for shipping. 4x-UltraSharp and
  UltraSharpV2 are **CC BY-NC-SA 4.0**.
- **One-step diffusion SR.**
  - S3Diff and AdcSR are Apache-2.0 with HF weights, and their bases (SD-Turbo, SD 2.1)
    allow evaluation.
  - PiSA-SR has the fidelity/perception dials we want (λ_pix, λ_sem), but its repo has **no
    LICENSE file** (the README claims Apache-2.0) and its weights are Google Drive or Baidu
    only.
  - TSD-SR is Apache-2.0, sits on SD3-medium (now Stability Community Licence) and ships its
    weights on Google Drive or OneDrive.
  - DreamClear is Apache-2.0, but its PixArt-α base is **AGPL-3.0** on HF.
  - LucidFlux is FLUX.1-dev NC, where evaluation is explicitly allowed.
  - ResShift, SinSR and DiT4SR are NC.
- **Nothing here changes B's product conclusion.** For shipping, we still train our own
  models. The value of this survey is a **licence-clean bake-off set** for the eval harness
  (section 11), plus the finding that motion and defocus deblur can reuse CC BY data.

## 0. "Eval allowed" — licence families and the deciding clause

| Licence family (where found) | Internal eval by a commercial project? | Deciding clause (verbatim) | Source |
|---|---|---|---|
| MIT | **Yes** | "to deal in the Software without restriction, including without limitation the rights to use, copy, modify…" | e.g. megvii-research/NAFNet LICENSE |
| Apache-2.0 | **Yes** | patent grant "to make, have made, use, offer to sell, sell, import…"; copyright grant to "reproduce, prepare Derivative Works of…" | e.g. XPixelGroup/DiffBIR LICENSE |
| BSD-2/3 | **Yes** | "Redistribution and use in source and binary forms … are permitted" | richzhang/PerceptualSimilarity |
| CC BY 4.0 / CC BY-SA 4.0 (weights, datasets) | **Yes** | no use restriction; attribution (and SA on adaptations) | OpenModelDB JSONs; GoPro/REDS/RealBlur pages |
| NVIDIA Source Code License-NC (StyleGAN2 in GFPGAN) | **Yes, evaluation only** | "'non-commercially' means for research or evaluation purposes only" (§3.3) | NVlabs/stylegan2 LICENSE.txt |
| FLUX.1 [dev] Non-Commercial v1.1.1 (LucidFlux) | **Yes, non-production** | "(ii) use by commercial or for-profit entities for testing, evaluation, or non-commercial research and development in a non-production environment" | W2GenAI-Lab/LucidFlux LICENSE |
| Stability AI Community Licence (SD-Turbo, SD3-medium, SD3.5) | **Yes** | "'Non-Commercial Purpose' means … such as personal use (i.e., hobbyist) or evaluation and testing"; commercial use free below "US $1,000,000" annual revenue | huggingface.co/stabilityai/sd-turbo LICENSE.md |
| Stability NC Research Community (older SD3-medium-diffusers copy, Dec 2023) | Unclear, leaning yes | "'Non-Commercial Uses' means … research or non-commercial purposes. Non-Commercial Uses does not include any production use" | HF stable-diffusion-3-medium-diffusers LICENSE |
| CreativeML OpenRAIL++-M (SD 2.1, SDXL) | **Yes** | use-based restrictions only (text not re-fetched; card tag `openrail++`) | HF cards |
| AGPL-3.0 (IFAN, DRBNet, PixArt-α weights) | **Yes, internal only** | "You may make, run and propagate covered works that you do not convey, without conditions" | codeslake/IFAN LICENSE |
| CC BY-NC(-SA) 4.0 (UltraSharp, SinSR code, pyiqa weights, FFHQ) | **No (conservative)** | "NonCommercial means not primarily intended for or directed towards commercial advantage or monetary compensation" | creativecommons.org legalcode.txt |
| S-Lab 1.0 (CodeFormer, ResShift, CLIP-IQA), Pi-Lab 1.0 (DiT4SR) | **No** | "Redistribution and use for non-commercial purpose … are permitted"; "In the event that … use for commercial purpose … is required, please contact" | LICENSE files |
| SupPixel licence (SUPIR, HYPIR) | **No** | Commercial Use = "any use … for the purpose of generating revenue, conducting business operations, or creating products or services"; weights "may only be used for non-commercial purposes" | Fanghua-Yu/SUPIR, XPixelGroup/HYPIR LICENSE |
| "Academic Public License" (MPRNet, PromptIR, LoFormer) | **No** | "free for use in noncommercial settings: at academic institutions … and at non-profit research organizations"; "✗ Commercial Use" | LICENSE.md files |
| Stripformer (modified MIT) | **No** | "to deal in the Software with non-commercial usage" | pp00704831/Stripformer-ECCV-2022- license |
| PolyForm Noncommercial 1.0.0 (pyiqa) | **No** | permitted: "Personal use for research … without any anticipated commercial application" and use by "charitable organization, educational institution, public research organization…" | chaofengc/IQA-PyTorch LICENSE |
| No LICENSE file (MIMO-UNet, AutoDIR, GKMNet, RealBlur repo code) | **Unclear** (no grant = no permission) | — | GitHub API `license: null` |

Assessment:

- "Internal evaluation to choose a model for a paid app" is directed towards commercial
  advantage. So every NC family except the three with explicit evaluation carve-outs
  (NVIDIA, FLUX-dev, Stability Community) is marked No.
- Training-data terms (DIV2K, FFHQ, ImageNet) govern the dataset, not the use of released
  weights. I therefore mark weights trained on them as "Yes (data flagged)" when the
  weights' own terms allow evaluation.

## 1. Upscaling beyond B

### 1.1 Architectures and official weights

**HAT real-world GAN weights (Real_HAT_GAN_SRx4 / _sharper)**

- Paper: arXiv 2205.04437 (CVPR 2023); extended version arXiv 2309.05239.
- Repo: https://github.com/XPixelGroup/HAT.
- Code licence: Apache-2.0 (LICENSE).
- Weights licence: none stated → **UNCLEAR**.
- Weights download: README "pretrained models are available at Google Drive … or Baidu
  Netdisk" (folder https://drive.google.com/drive/folders/1HpmReFfoUqUbnAOQ7rvOeNU3uf_m69w0).
  The official files are Drive/Baidu only. `anchuang/Real_HAT_GAN_SRx4_sharper` on HF is an
  unlicensed third-party mirror.
- Training (README): "The default settings in the training configs (almost the same as
  Real-ESRGAN)", i.e. a DF2K+OST-style setup (**research-only / UNCLEAR**). "Real_HAT_GAN_SRx4
  … would have better fidelity", while "_sharper" has better perceptual quality.
- Params: HAT 20.8 M. There are no real-world benchmark numbers.
- Eval allowed: yes (Apache; weights unlicensed).
- spandrel: **yes** (HAT).
- Verdict: **Fine-tune only.**

**DRCT**

- Paper: arXiv 2404.00722 (CVPRW 2024, NTIRE SR x4).
- Repo: https://github.com/ming053l/DRCT.
- Code licence: **MIT** (LICENSE).
- Weights licence: none stated (Google Drive "Model zoo"). HF `ming0531/DRCT` is tagged
  mit but contains only a README.
- Data: DF2K; Real-DRCT-GAN uses "DF2K + OST300" (README); DRCT-XL is pretrained on
  ImageNet.
- README (x4, no x2 pretraining): DRCT 14.13 M params, Urban100 28.06 dB; DRCT-L 27.58 M,
  28.70 dB.
- Eval allowed: yes.
- spandrel: **yes** (DRCT).
- Verdict: **Fine-tune only.**

**ATD (Adaptive Token Dictionary)**

- Paper: arXiv 2401.08209 (CVPR 2024, per the repo's CVF link).
- Repo: https://github.com/LabShuHangGU/Adaptive-Token-Dictionary (the API now resolves to
  CVL-UESTC/…).
- Code licence: Apache-2.0 (LICENSE.txt).
- Weights licence: none stated; Google Drive only.
- Paper Table 4, x4: 20.3 M params, Urban100 28.17 dB, Manga109 32.62 dB. Table 6: 417 G
  FLOPs. ATD-light x4: 769 K params, Urban100 26.97 dB.
- Data: DF2K (research-only).
- Eval allowed: yes.
- spandrel: **yes** (ATD).
- Verdict: **Fine-tune only.**

**MambaIR / MambaIRv2**

- Papers: arXiv 2402.15648 (ECCV 2024) and 2411.15269 (CVPR 2025).
- Repo: https://github.com/csguoh/MambaIR.
- Code licence: Apache-2.0.
- Weights: HF `cguoh/MambaIR` is tagged **apache-2.0**; GitHub release v1.0 hosts the
  MambaIRv2 `.pth` files.
- README: MambaIRv2 classicSR x4 Urban100 27.89 dB; MambaIR x4 27.68 dB.
- Data: DF2K/DIV2K.
- Runtime: needs the CUDA `mamba_ssm` and `causal_conv1d` kernels (README install: "CUDA
  11.7"). **Not feasible on the M1 without porting the selective scan.**
- Eval allowed: yes.
- spandrel: **no**.
- Verdict: **Fine-tune only** (architecture reference).

**AuraSR-v2 (fal)**

- Architecture: a GigaGAN-style image-conditioned 4x GAN (arXiv 2303.05511 is the GigaGAN
  paper; AuraSR itself has no paper).
- Code: https://github.com/fal-ai/aura-sr, **CC-BY-SA-4.0** (GitHub API).
- Weights: HF `fal/AuraSR-v2`, card **apache-2.0**; files `model.safetensors` and
  `model.ckpt`.
- Training data: not disclosed → **UNCLEAR**. The model card says it is for "upscaling
  generated images".
- Eval allowed: yes.
- spandrel: **yes** (AuraSR).
- Verdict: **Fine-tune only** (data unknown).

### 1.2 OpenModelDB community photo upscalers

The OpenModelDB repo itself is GPL-3.0, but that covers the website and database code; the
per-model `license` field states the weights licence. The entries below all come from
`data/models/<id>.json`.

| Model (arch, scale) | `license` field | Pretrained from (JSON) | Dataset (JSON) | Download (exact) | spandrel |
|---|---|---|---|---|---|
| 4x-Nomos8kSC (ESRGAN 64nf/23nb) | CC-BY-4.0 | 4x-realesrgan-x4plus | Nomos8k_sfw (6118) | https://github.com/Phhofm/models/raw/main/4xNomos8kSC/4xNomos8kSC.pth | yes |
| 4x-Nomos8kSCHAT-L (HAT-L) | CC-BY-4.0 | 4x-HAT-L-SRx4-ImageNet-pretrain | Nomos8k_sfw | Google Drive only (…/file/d/1gh7HDKzf9aZw-rA8WYQy1ZZ8D0MAIHxR) | yes |
| 4x-NomosUniDAT-otf (DAT) | CC-BY-4.0 | 4x-DAT | nomos_uni (2989) | Google Drive only | yes |
| 4x-NomosUniDAT2-box (DAT2) | CC-BY-4.0 | 4x-DAT-2 | nomos_uni | Google Drive only | yes |
| 4x-Nomos2-hq-dat2 (DAT2) | CC-BY-4.0 | 4x-DAT-2 | nomosv2 (6000) | https://github.com/Phhofm/models/releases/download/4xNomos2_hq_dat2/4xNomos2_hq_dat2.pth | yes |
| 4x-Nomos2-hq-atd (ATD) | CC-BY-4.0 | 4x-003-ATD-SRx4-finetune | nomosv2 | https://github.com/Phhofm/models/releases/download/4xNomos2_hq_atd/4xNomos2_hq_atd.safetensors | yes |
| 4xNomos2_hq_drct-l (DRCT-L) | HF card cc-by-4.0 | (not checked) | nomosv2 | https://huggingface.co/Phips/4xNomos2_hq_drct-l/resolve/main/4xNomos2_hq_drct-l.safetensors | yes |
| 4x-Nomos2-realplksr-dysample | CC-BY-4.0 | 4x-mssim-realplksr-dysample-pretrain | Nomos-v2 | https://github.com/Phhofm/models/releases/download/4xNomos2_realplksr_dysample/4xNomos2_realplksr_dysample.pth | yes (RealPLKSR) |
| 4x-RealWebPhoto-v4-dat2 | CC-BY-4.0 | 4x-DAT-2 | 4xRealWebPhoto_v4 (8492) | https://github.com/Phhofm/models/releases/download/4xRealWebPhoto_v4_dat2/4xRealWebPhoto_v4_dat2.safetensors | yes |
| 4x-RealWebPhoto-v4-drct-l | CC-BY-4.0 | 4x-mssim-drct-l-pretrain | 4xRealWebPhoto_v4 | https://huggingface.co/Phips/4xRealWebPhoto_v4_drct-l/resolve/main/4xRealWebPhoto_v4_drct-l.safetensors | yes |
| 4x-NomosWebPhoto-atd / -RealPLKSR | CC-BY-4.0 | 4x-003-ATD / 4x-realplksr-gan-pretrain | Nomos-v2 | https://github.com/Phhofm/models/releases/download/4xNomosWebPhoto_atd/4xNomosWebPhoto_atd.safetensors | yes |
| 4x-LSDIR / 4x-LSDIRplus (ESRGAN), 4x-LSDIRDAT | CC-BY-4.0 | none / none / 4x-DAT | LSDIR (84,991) | https://github.com/Phhofm/models/raw/main/4xLSDIR/4xLSDIR.pth | yes |
| 2x-NomosUni-span-multijpg / -compact-multijpg | CC-BY-4.0 | 2x-span-anime-pretrain / 2x-Compact-Pretrain | Nomos_Uni | Google Drive only | yes |
| 4x-PurePhoto-span / -RealPLSKR | CC-BY-SA-4.0 | none | "6500 / 8684 handpicked photos" (source unstated) | https://github.com/starinspace/StarinspaceUpscale/releases/download/Models/4xPurePhoto-span.pth | yes |
| **4x-UltraSharp** (ESRGAN) | **CC-BY-NC-SA-4.0** | 4x-UniScale-Balanced | "RAW images shot by myself, SignatureEdits, AdobeMIT-5K, DIV2K, …" | MEGA folder only | yes |
| **4x-UltraSharpV2** (DAT2) | **CC-BY-NC-SA-4.0** (JSON and HF card) | none | "Private dataset" | https://huggingface.co/Kim2091/UltraSharpV2/resolve/main/4x-UltraSharpV2.safetensors | yes |

Evidence on the datasets:

- The neosr README (https://github.com/neosr-project/neosr, Apache-2.0) says its datasets
  "distill only the best images from the academic and community datasets … including
  Adobe-MIT-5k, RAISE, LSDIR, LIU4k-v2, KONIQ-10k, Nikon LL RAW, DIV8k, FFHQ, Flickr2k,
  ModernAnimation1080_v2, Rawsamples, SignatureEdits, Hasselblad raw samples and Unsplash".
- MIT-Adobe FiveK (https://data.csail.mit.edu/graphics/fivek/): "You can use these photos
  for research".
- The newer BHI dataset (HF `Phips/BHI`) carries a cc-by-4.0 card, but it is itself curated
  from those academic sets.

Assessment:

- The CC-BY-4.0 label is the author's claim over weights **derived from research-only data
  and research pretrains**, so for shipping the weights licence is **UNCLEAR**.
- For **evaluation** it is the best-documented, most "Topaz-like" photo upscaler family,
  and it is all spandrel-loadable.
- Drop UltraSharp from the bake-off: it is NC.

### 1.3 NTIRE 2025 SR x4 winners (arXiv 2504.14582)

- **Track 1 (fidelity):** "The SamsungAICamera team achieves the top performance (33.46 dB)"
  on DIV2K test. Its method "combines … HAT and … NAFnet".
- **Track 2 (perception):** "SNUCV … ranks first". It uses "MambaIRv2" as upsampler plus
  "TSD-SR" and "directly use[s] its pretrained weights".
- Weights: the challenge repo https://github.com/zhengchen1999/NTIRE2025_ImageSR_x4 (MIT)
  says team weights are on Baidu or Google Drive, "Some participants would like to keep
  their models confidential". Per-team weight licences were **not verified**.

Assessment: the winners are compositions of models already covered here (HAT+NAFNet;
MambaIRv2+TSD-SR). There is no new distributable model to add.

## 2. One-step and fast diffusion SR

Benchmark numbers are from each paper's own tables (arXiv HTML, x4, 512² GT crops,
SeeSR/StableSR test sets). The "Speed" column carries each paper's own timing, with the GPU
where the paper states it; it is not comparable across rows.

| Model | Paper Table: RealSR PSNR / LPIPS / MUSIQ / CLIPIQA | Params | Speed (paper's own) |
|---|---|---|---|
| S3Diff | 25.03 / 0.2699 / 67.89 / 0.6722 (Tab. 1) | 34.5 M trainable on SD-Turbo | 0.62 s/img (Tab.) |
| PiSA-SR (λ_pix = λ_sem = 1) | 25.50 / 0.2672 / 70.15 / 0.6702 (Tab. 2) | 1.30 B total | 0.09 s (1 step); 0.13 s adjustable (2 steps) |
| TSD-SR | 24.81 / 0.2743 / 71.19 / 0.7160 (Tab. 1) | on SD3-medium | 0.136 s (Tab.) |
| AdcSR | 25.47 / 0.2885 / 69.90 / 0.6731 (Tab. C.2) | **456 M**, 496 GMACs | 0.03 s on A100; **65 ms on Snapdragon 8 Gen 4** (Tab. C.3) |
| HYPIR (SD2) | DIV2K: 22.16 / 0.2318 / 72.58 / 0.7467 (Tab. 1) | SD 2.1 + LoRA | n/a |

**S3Diff**

- Paper: arXiv 2409.17058. Repo: https://github.com/ArcticHare105/S3Diff.
- Code: Apache-2.0. Weights: HF `zhangap/S3Diff`, **apache-2.0** (`s3diff.pkl`,
  `de_net.pth`).
- Base: **SD-Turbo** (Stability AI Community Licence: evaluation allowed; commercial use
  below $1 M revenue).
- Data: "LSDIR + 10K samples from FFHQ" (README) → FFHQ is NC.
- Eval allowed: **yes**. spandrel: no.
- Verdict: **Fine-tune only** (skip for shipping).

**PiSA-SR**

- Paper: arXiv 2412.03017 (CVPR 2025). Repo: https://github.com/csslc/PiSA-SR.
- **Code licence UNCLEAR:** the README says "released under the Apache 2.0 license", but
  the repo contains **no LICENSE file** (the GitHub API returns 404; root listing checked).
- Weights: "GoogleDrive … or BaiduNetdisk" only (`pisa_sr.pkl`). No HF release (the HF
  search found only the third-party `ndtran0101/pisa-sr-diffusers`).
- Base: SD-2.1-base (the official HF repo returns 401; mirror `sd2-community/…` is
  openrail++) plus RAM.
- Training data: not stated in the README; my search of the paper text did not find it
  named → **UNCLEAR**.
- The fidelity/perception control:
  - README: "By increasing the guidance scale λ_pix on the pixel-level LoRA … degradations
    … can be gradually removed; however, a too-strong λ_pix will make the SR image
    over-smoothed. By increasing … λ_sem … more semantic details; nonetheless, a too-high
    λ_sem will generate visual artifacts."
  - Paper Table 5 on RealSR: pixel-only V1 gives 27.28 dB / MUSIQ 49.02; semantic-heavy V2
    gives 24.13 dB / 70.69.
  - This is exactly the "strength dial" B asked for. **The idea is reimplementable from the
    paper.**
- Eval allowed: **unclear** (README-only Apache statement).
- Verdict: **Fine-tune only** (design reference).

**TSD-SR**

- Paper: arXiv 2411.18263 (CVPR 2025). Repo: https://github.com/Microtreei/TSD-SR.
- Code: Apache-2.0.
- Weights: LoRA files on Google Drive / OneDrive only.
- Base: **SD3-medium**. HF `stabilityai/stable-diffusion-3-medium` is now "stabilityai-ai-community";
  the `-diffusers` copy still ships the Dec-2023 NC Research licence.
- Data: "LSDIR, FLICKR2K, DIV2K, FFHQ" (README).
- Speed: "40 times faster than SeeSR" (abstract).
- Eval allowed: **yes** (Community Licence). spandrel: no.
- Verdict: **Fine-tune only.**

**AdcSR**

- Paper: arXiv 2411.13383 (CVPR 2025). Repo: https://github.com/Guaishou74851/AdcSR.
- Code: Apache-2.0. Weights: HF `Guaishou74851/AdcSR` (Apache LICENSE file in the repo),
  `weight/net_params_200.pkl` plus `weight/pretrained/{halfDecoder.ckpt, osediff.pkl,
  DAPE.pth, ram_swin_large_14m.pth}`.
- Base: SD 2.1 (pruned, distilled from OSEDiff).
- Data: LSDIR (README).
- Numbers: "74% fewer parameters" than OSEDiff; DRealSR 28.10 dB / MUSIQ 66.26, 456 M
  params (Tab. 1).
- Eval allowed: **yes**. spandrel: no.
- Verdict: **Fine-tune only.** It is the most mobile-plausible diffusion SR here (65 ms on
  a phone NPU/GPU per the paper).

**HYPIR (XPixel / SupPixel)**

- Paper: arXiv 2507.20590. Repo: https://github.com/XPixelGroup/HYPIR.
- Code/weights licence: **SupPixel "HYPIR Software License Agreement"**, non-commercial
  only (same text as SUPIR; see section 3).
- The HF card `lxq007/HYPIR` says `apache-2.0` (only YAML front matter). This contradicts
  the LICENSE and README "Non-Commercial Use Only Declaration" → **UNCLEAR, treat as NC**.
- Data: "approximately 20 million high-quality image patches … and an additional 70
  thousand face images". The paper also claims "DIV2K dataset (licensed CC BY 4.0)", which
  contradicts DIV2K's own "academic research purpose only".
- Eval allowed: **no**.
- Verdict: **Research-only** (and we may not even evaluate).

**DreamClear**

- Paper: arXiv 2410.18666 (NeurIPS 2024). Repo: https://github.com/shallowdream204/DreamClear.
- README: "The provided code and pre-trained weights are licensed under the Apache 2.0
  license". HF `shallowdream204/DreamClear` is apache-2.0.
- Base: **PixArt-α 1024 (HF `PixArt-alpha/PixArt-alpha` card: agpl-3.0)**, T5-XXL, and
  LLaVA-v1.6-vicuna-13b.
- Data: a "privacy-safe" pipeline producing "one million high-quality images" by generation
  and filtering (paper).
- Eval allowed: yes (AGPL permits running).
- Verdict: **Avoid** for shipping (AGPL base). It is also a 13 B-class stack and infeasible
  as a bake-off on the M1.

**SinSR**

- Paper: arXiv 2311.14760 (CVPR 2024). Repo: https://github.com/wyf0912/SinSR.
- Code: "CC BY-NC-SA 4.0 … released for academic research use only" (LICENSE).
- Base: ResShift (S-Lab).
- Eval allowed: **no**. Verdict: **Research-only.**

**ResShift**

- Paper: arXiv 2307.12348 (NeurIPS 2023, TPAMI). Repo: https://github.com/zsyOAOA/ResShift.
- Code: **S-Lab License 1.0**.
- Eval allowed: **no**. Verdict: **Research-only.**

**LucidFlux**

- Paper: arXiv 2509.22414 (ICLR 2026 per README). Repo: https://github.com/W2GenAI-Lab/LucidFlux.
- Code LICENSE: **FLUX.1 [dev] Non-Commercial License v1.1.1**. HF `W2GenAI/LucidFlux` is
  "other / flux-1-dev".
- Base: FLUX.1-dev (gated, NC). Training-data metadata is published on HF.
- Memory: "as little as 28 GB VRAM" (README).
- Eval allowed: **yes, non-production** (clause (ii) above).
- Verdict: **Research-only.** It is a useful "ceiling" reference for generative SR if we
  ever want one.

**DiT4SR**

- Paper: arXiv 2503.23580 (ICCV 2025). Repo: https://github.com/adam-duan/DiT4SR.
- Code: **"Pi-Lab License 1.0"** (S-Lab clone, NC). HF `acceptee/DiT4SR` is "other /
  pi-lab-license-1.0".
- Base: SD3.5-medium (Stability Community). Data: DIV2K, DIV8K, Flickr2K, Flickr8K, NKUSR8K.
- Eval allowed: **no**. Verdict: **Research-only.**

**Thera (arbitrary-scale SR)**

- Paper: arXiv 2311.17643 (TMLR 2025). Repo: https://github.com/prs-eth/thera.
- Code: Apache-2.0. Weights: HF `prs-eth/thera-{edsr,rdn}-{air,plus,pro}`, apache-2.0
  (`model.pkl`).
- Runtime: JAX/Flax (requirements pin `jaxlib==0.4.11+cuda11`), so the M1 needs a CPU JAX
  install. Data: DIV2K (per paper setup).
- Eval allowed: yes. spandrel: no.
- Verdict: **Fine-tune only.** Interesting for "any-scale" export sizes because it is
  anti-aliased by design.

## 3. SUPIR and DiffBIR — can a commercial company evaluate them internally?

**SUPIR** (arXiv 2401.13627, CVPR 2024; https://github.com/Fanghua-Yu/SUPIR). Evidence:

- LICENSE §1(c) defines Commercial Use as "any use of the Licensed Software or its
  components, in whole or in part, for the purpose of generating revenue, conducting
  business operations, or creating products or services for sale or profit".
- §3(a): "the proprietary neural network weights, biases, and architecture may only be used
  for non-commercial purposes. Any commercial use … is strictly prohibited without express
  written permission".
- The README adds: "made available for use, reproduction, and distribution strictly for
  non-commercial purposes … not primarily intended for or directed towards commercial
  advantage".

Assessment: **Evaluation is not allowed.** Benchmarking inside a company to choose or tune a
commercial product is "conducting business operations" directed towards commercial
advantage. The same verdict applies to **HYPIR**, whose licence text is identical apart
from the name. The only route is written permission (jinjin.gu@suppixel.ai).

**DiffBIR** (arXiv 2308.15070, ECCV 2024 per README; https://github.com/XPixelGroup/DiffBIR).
Evidence:

- LICENSE is Apache-2.0.
- HF `lxq007/DiffBIR-v2` is tagged **apache-2.0** and contains `DiffBIR_v2.1.pt`, `v2.pth`,
  `v1_face.pth`, `v1_general.pth` and two SwinIR stage-1 checkpoints.
- The v2.1 release note says it is "based on SD2.1-zsnr". HF
  `ByteDance/sd2.1-base-zsnr-laionaes5` is **openrail++**.
- Training data:
  - v2: "filtered laion2b-en".
  - v2.1: "the unsplash dataset". The Lite vs Full variant is not stated: per
    github.com/unsplash/datasets, Lite is "available for commercial and noncommercial
    usage" and Full is "available for noncommercial usage".
  - v1_face: FFHQ.

Assessment: **Evaluation is allowed** (Apache-2.0 weights plus an OpenRAIL++ base).
Shipping stays "Fine-tune only (skip)", as in B, because the data is UNCLEAR.

## 4. Motion deblur

Training-data terms are the important new finding here:

- **GoPro**: "GOPRO dataset is released under CC BY 4.0 license"
  (https://seungjunnah.github.io/Datasets/gopro.html).
- **REDS**: "REDS dataset is released under CC BY 4.0 license" (…/reds.html).
- **RealBlur**: "The RealBlur dataset is released under CC BY 4.0 license"
  (https://github.com/rimchang/RealBlur README). Its training recipe also uses BSD-B
  (HF `rimchang/RealBlur`), whose terms were **not checked**.

The benchmark below is from the FFTformer paper, Table 1 (arXiv 2211.12250): GoPro test,
PSNR / SSIM / params. It is one consistent table covering the whole group.

| Model | GoPro PSNR | SSIM | Params |
|---|---|---|---|
| MIMO-UNet+ | 32.45 | 0.9567 | 16.1 M |
| MPRNet | 32.66 | 0.9589 | 20.1 M |
| Restormer | 32.92 | 0.9611 | 26.1 M |
| Uformer-B | 33.06 | 0.9670 | 50.9 M |
| Stripformer | 33.08 | 0.9624 | 19.7 M |
| NAFNet (width64) | 33.71 | 0.9668 | 67.9 M |
| FFTformer | **34.21** | 0.9692 | 16.6 M |

Restormer is trained on GoPro only and reaches HIDE 31.22 dB and RealBlur-J 28.96 dB
without fine-tuning (Restormer Tab. 2). FFTformer's RealBlur-trained model reaches
RealBlur-J 32.62 dB (FFTformer Tab. 2).

**NAFNet**

- Paper: arXiv 2204.04676 (ECCV 2022). Repo: https://github.com/megvii-research/NAFNet.
- Code: **MIT** (plus bundled BasicSR Apache-2.0).
- Weights (README): NAFNet-GoPro-width64 is 33.7103 dB; NAFNet-REDS-width64 (deblur with
  JPEG) is 29.0903 dB. Both are Google Drive / Baidu only. MIT MLX ports exist on HF
  (`mlx-community/NAFNet-GoPro-width64`, `…-REDS-width64`); these are third-party, "Faithful
  NHWC port … parity … ~1e-6".
- Data: GoPro / REDS (**CC BY 4.0**).
- Eval allowed: **yes**. spandrel: **yes** (NAFNet).
- Verdict: **Shippable candidate.** The weights have no separate licence, so confirm with
  Megvii or retrain on GoPro (cheap).

**Restormer (motion deblurring)**

- Paper: arXiv 2111.09881 (CVPR 2022). Repo: https://github.com/swz30/Restormer.
- Code: **MIT** since commit `68dc6ac` on 2025-10-23 (previously "Academic Public License").
- Weights: GitHub release v1.0 `motion_deblurring.pth` (99 MB), published 2022-03-30 under
  the old licence. It carries no separate licence → **UNCLEAR, most plausibly MIT now**.
- Data: GoPro only (paper).
- Eval allowed: **yes**. spandrel: **yes, via `spandrel_extra_arches`**. That MIT package
  says it contains "architectures with restrictive licenses", which reflects Restormer's
  old licence.
- Verdict: **Shippable candidate** (pending weights confirmation).

**FFTformer**

- Paper: arXiv 2211.12250 (CVPR 2023). Repo: https://github.com/kkkls/FFTformer.
- Code: **MIT** (`license`).
- Weights: GitHub release `pretrain_model/fftformer_GoPro.pth` (63 MB); the RealBlur model
  is Google Drive only.
- Data: GoPro / RealBlur (CC BY 4.0).
- Eval allowed: **yes**. spandrel: **yes**.
- Verdict: **Shippable candidate** (pending weights confirmation). Relies on `torch.fft`,
  so MPS support needs a check.

**Stripformer**

- Paper: arXiv 2204.04627 (ECCV 2022 Oral). Repo: https://github.com/pp00704831/Stripformer-ECCV-2022-.
- Licence: "Permission … to deal in the Software **with non-commercial usage**".
- Weights: Google Drive only.
- Eval allowed: **no**. spandrel: no. Verdict: **Research-only.**

**MIMO-UNet / MIMO-UNet+**

- Paper: arXiv 2108.05054 (ICCV 2021). Repo: https://github.com/chosj95/MIMO-UNet.
- Licence: **none** (API 404).
- Weights: Google Drive (including a RealBlur MIMO-UNet+).
- Eval allowed: **unclear**. spandrel: no.
- Verdict: **UNCLEAR → treat as Research-only.**

**MPRNet**

- Paper: arXiv 2102.02808 (CVPR 2021). Repo: https://github.com/swz30/MPRNet.
- Licence: **"Academic Public License"** (✗ Commercial Use).
- Eval allowed: **no**. spandrel: yes (extra arches). Verdict: **Research-only.**

**Uformer**

- Paper: arXiv 2106.03106 (CVPR 2022). Repo: https://github.com/ZhendongWang6/Uformer.
- Code: MIT.
- Weights: OneDrive/SharePoint links (per spandrel README); HF third-party mirror
  `CaveMindLabs/uformer-restoration-models` (mit; `Uformer_B_GoPro.pth`).
- Eval allowed: yes. spandrel: **yes**.
- Verdict: **Shippable candidate** (GoPro data). It is heavy (50.9 M params).

**LoFormer**

- Repo: https://github.com/INVOKERer/LoFormer. Licence: **"Academic Public License"**.
- arXiv ID not verified.
- Eval allowed: **no**. Verdict: **Research-only.**

Also noted, but outside this brief's scope: the NTIRE 2025 Event-Based Deblurring challenge
(arXiv 2504.12401) needs event cameras, so it is irrelevant to Redlamp.

## 5. Defocus deblur

**DPDD terms.**

- Repo: https://github.com/Abdullah-Abuolaim/defocus-deblurring-dual-pixel, MIT.
- The dataset is 500 Canon scenes at 6720×4480 (README).
- The README states no dataset-specific terms, the dataset is hosted on sync.com, and the
  project page returned no licence text → **UNCLEAR** (probably governed by the repo MIT,
  but not stated).

**Restormer (single-image defocus deblurring, trained on DPDD)**

- Paper Table 3, DPDD combined: **S 25.98 dB / LPIPS 0.178**; dual-pixel D is 26.66 dB.
- Weights: `single_image_defocus_deblurring.pth` (GitHub release v1.0).
- Eval allowed: **yes**. spandrel: yes (extra arches).
- Verdict: **Fine-tune only** (DPDD UNCLEAR).

**IFAN**

- Paper: arXiv 2108.13610 (CVPR 2021). Repo: https://github.com/codeslake/IFAN.
- Licence: **AGPL-3.0**.
- Weights: OneDrive / Dropbox. Data: DPDD.
- Eval allowed: yes (AGPL, internal). spandrel: no. Verdict: **Avoid** (for anything
  beyond internal evaluation).

**DRBNet**

- Venue: CVPR 2022. arXiv ID not verified. Repo: https://github.com/lingyanruan/DRBNet.
- Licence: **AGPL-3.0**.
- Data: LFDOF + DPDD (the README links LFDOF, DPDD, CUHK and RealDOF).
- Eval allowed: yes (internal). Verdict: **Avoid.**

**GKMNet**

- Venue: NeurIPS 2021. Repo: https://github.com/csZcWu/GKMNet.
- Licence: **none**.
- Eval allowed: unclear. Verdict: **UNCLEAR / skip.**

## 6. All-in-one / universal restoration

Typical training data for this family:

- PromptIR / AdaIR: BSD400+WED (noise), Rain100L, SOTS (RESIDE), plus GoPro and LOL for the
  5-task setting.
- InstructIR additionally uses FiveK (research-only).
- DA-CLIP uses GoPro, RESIDE-6k, DIV2K+Flickr2K, LOL, RainDrop, Rain100H, SRD, Snow100K and
  CelebA-HQ (README table).

These are a mix of research-only and UNCLEAR sets; none are fully clean.

**PromptIR**

- Paper: arXiv 2306.13090 (NeurIPS 2023). Repo: https://github.com/va1shn9v/PromptIR.
- Licence: **Academic Public License**.
- Weights: GitHub release v1.0 `model.ckpt`; HF `deepinv/promptir` is a mirror.
- Numbers: 3-task average 32.06 / 0.913 (Tab. 1).
- Eval allowed: **no**. spandrel: no. Verdict: **Research-only.**

**InstructIR**

- Paper: arXiv 2401.16468 (ECCV 2024). Repo: https://github.com/mv-lab/InstructIR.
- Code: MIT. Weights: HF `marcosv/InstructIR` **mit** (`im_instructir-7d.pt`,
  `lm_instructir-7d.pt`).
- Text encoder: `TaylorAI/bge-micro-v2` (HF card mit).
- Architecture: NAFNet-style, width 32 (configs/eval5d.yml). "+1dB over previous all-in-one
  methods" (abstract).
- Eval allowed: **yes** (data flagged). spandrel: no.
- Verdict: **Fine-tune only.**

**DA-CLIP / universal IR-SDE**

- Paper: arXiv 2310.01018 (ICLR 2024). Repo: https://github.com/Algolzw/daclip-uir.
- Code: MIT. Weights: HF `weblzw/daclip-uir-ViT-B-32-irsde` **mit**. That card is linked
  from the README as the official "Model Card"; it holds `daclip_ViT-B-32.pt`,
  `universal-ir.pth`, `wild-ir.pth` and others.
- Eval allowed: yes. Runtime: SDE sampling, slow (not measured).
- Verdict: **Fine-tune only.**

**AdaIR**

- Paper: arXiv 2403.14614 (ICLR 2025). Repo: https://github.com/c-yn/AdaIR.
- Code: MIT. Weights: Google Drive only.
- Numbers: 3-task average 32.69 / 0.918; 5-task average 30.20 / 0.910, with GoPro 28.12 dB
  inside the 5-task setting (paper Tab. 1 and Tab. 5).
- Eval allowed: yes. spandrel: no.
- Verdict: **Fine-tune only.**

**AutoDIR**

- Paper: arXiv 2310.10123 (ECCV 2024). Repo: https://github.com/jiangyitong/AutoDIR.
- Licence: **none**. Base: latent diffusion ("based on StableDiffusion … InstructPix2Pix,
  stablesr").
- Weights: Google Drive.
- Eval allowed: unclear. Verdict: **UNCLEAR / skip.**

**DiffBIR v2.1**: see section 3. It works as a generative all-in-one (BSR, BFR, BID tasks
through one IRControlNet). Eval yes; shipping Fine-tune only.

## 7. Face restoration

**FFHQ terms** (https://github.com/NVlabs/ffhq-dataset LICENSE.txt):

- "The dataset itself … is made available under Creative Commons BY-NC-SA 4.0 license by
  NVIDIA Corporation. You can use, redistribute, and adapt it for non-commercial purposes".
- The images themselves are CC BY 2.0, CC BY-NC 2.0, PDM or CC0.

Every face model below is FFHQ-trained, so none is shippable as-is.

**GFPGAN**

- Paper: arXiv 2101.04061 (CVPR 2021). Repo: https://github.com/TencentARC/GFPGAN.
- LICENSE: "GFPGAN is licensed under the Apache License Version 2.0 **except for the
  third-party components**". It lists:
  - "StyleGAN2 … modified from … stylegan2-pytorch" (MIT) together with the NVIDIA
    Source Code License-NC.
  - "DFDNet … Their license is Creative Commons Attribution-NonCommercial-ShareAlike 4.0".
- The "clean" architecture (v1.2+ `GFPGANCleanv1-NoCE-C2`, v1.3, v1.4) "does not require
  customized CUDA extensions". It avoids NVIDIA's CUDA ops, but the StyleGAN2 generator
  design and the FFHQ-trained StyleGAN2 prior remain. The NVIDIA NC text still appears in
  GFPGAN's LICENSE.
- Weights: GitHub releases `v1.3.4/GFPGANv1.4.pth` (332 MB), `v1.3.0/GFPGANv1.3.pth`.
- Eval allowed: **yes** for the NVIDIA part ("research or evaluation purposes only"), but
  **unclear** for the DFDNet-derived code (CC BY-NC-SA). Widely used; flag it.
- spandrel: **yes** (in the MIT core package).
- Verdict: **Research-only.**

**CodeFormer**

- Paper: arXiv 2206.11253 (NeurIPS 2022). Repo: https://github.com/sczhou/CodeFormer.
- Licence: **S-Lab 1.0** (NC).
- Weights: GitHub release `v0.1.0/codeformer.pth`.
- Numbers: CelebA-Test LPIPS 0.299, FID 60.62, IDS 0.60 (paper Tab. 1).
- Eval allowed: **no**. spandrel: yes (extra arches). Verdict: **Research-only.**

**RestoreFormer / RestoreFormer++**

- Papers: CVPR 2022, and arXiv 2308.07228 (TPAMI). Repos: https://github.com/wzhouxiff/RestoreFormer
  and https://github.com/wzhouxiff/RestoreFormerPlusPlus, both **Apache-2.0**.
- Weights: GitHub release `v1.0.0/RestoreFormer++.ckpt`; RestoreFormer v1 is also at
  `TencentARC/GFPGAN` `v1.3.4/RestoreFormer.pth`.
- Data: FFHQ.
- Numbers: CelebA-Test FID 41.15, PSNR 25.31 (PMRF Tab. 1).
- Eval allowed: **yes**. spandrel: **yes** (RestoreFormer v1; ++ not listed).
- Verdict: **Fine-tune only.**

**PMRF (Posterior-Mean Rectified Flow)**

- Paper: arXiv 2410.00418 (ICLR 2025). Repo: https://github.com/ohayonguy/PMRF.
- Code: **MIT**. Weights: HF `ohayonguy/PMRF_blind_face_image_restoration` **mit**
  (`model.safetensors`).
- It "approximates the optimal estimator that minimizes the Mean Squared Error … under a
  perfect perceptual quality constraint". That makes it the most principled
  fidelity/realism trade-off here.
- CelebA-Test (Tab. 1): FID 37.46, PSNR 26.37, LPIPS 0.3470. For comparison: CodeFormer
  53.16 / 25.15, GFPGAN 46.72 / 24.99, DiffBIR 59.06 / 25.39.
- Data: FFHQ. Needs `natten` for the HDiT backbone; natten support on macOS was **not
  verified**. It also uses DifFace's SwinIR stage-1.
- Eval allowed: **yes**. spandrel: no.
- Verdict: **Fine-tune only.**

**DiffBIR face (v1_face.pth; v2.1 with the face task)**: Apache-2.0 weights; FFHQ. Eval
yes; Fine-tune only.

**NTIRE 2025 Real-World Face Restoration** (arXiv 2504.14600): "The AllForFace team
achieved the top ranking", under an AdaFace identity gate. The repo
https://github.com/zhengchen1999/NTIRE2025_RealWorld_Face_Restoration is MIT. Per-team
weight licences were **not verified**.

## 8. Joint denoise + sharpen

- I found no notable open model dedicated to "noise-aware deblur" for camera files that is
  distinct from the all-in-one family.
- The practical options are:
  - **NAFNet-REDS** ("Image Deblurring with JPEG artifacts", REDS CC BY 4.0).
  - Restormer / NAFNet SIDD denoise checkpoints. SIDD terms were **not checked**.
  - InstructIR / AdaIR multi-task models.
- NTIRE 2025 RAIM (arXiv 2506.01394) was won by MiAlgo (Track 1 final score 112.18), but
  its weights and licence were not checked.
- Assessment: for Redlamp this belongs in workstream A (raw-domain joint denoise). None of
  these RGB models is a substitute.

## 9. IQA tooling for the evaluation harness

| Tool | Code licence (source) | Weights | Training data | Eval allowed |
|---|---|---|---|---|
| **pyiqa / IQA-PyTorch** | **PolyForm Noncommercial 1.0.0** (LICENSE, changed from CC BY-NC-SA 4.0 in commit ccac804, 2026-04-09); README adds "NTU S-Lab License for applicable components" | HF `chaofengc/IQA-PyTorch-Weights` **cc-by-nc-sa-4.0** (hosts MUSIQ, TOPIQ, MANIQA, CLIPIQA+, LPIPS, DISTS …) | various | **No** |
| LPIPS | BSD-2-Clause (richzhang/PerceptualSimilarity) | in repo `lpips/weights/v0.1/{alex,vgg,squeeze}.pth` (BSD-2) | BAPPS; ImageNet backbones | **Yes** |
| DISTS | MIT (dingkeyan93/DISTS) | in repo `DISTS_pytorch/weights.pt` | KADID-10k ("freely available to the research community") | **Yes** (data flagged) |
| MUSIQ | Apache-2.0 (google-research/google-research `musiq/`) | GCS bucket `gresearch/musiq` (koniq/spaq/ava/paq2piq `.npz`); TF Hub | KonIQ-10k ("freely available to the research community"), SPAQ, AVA, PaQ-2-PiQ | **Yes** (data flagged) |
| MANIQA | Apache-2.0 (IIGROUP/MANIQA) | GitHub releases (PIPAL22 / KonIQ / KADID) | PIPAL, KonIQ, KADID | **Yes** (data flagged) |
| CLIP-IQA (official) | **S-Lab 1.0** (IceClear/CLIP-IQA) | release `iter_80000.pth` (CLIP-IQA+) | KonIQ | **No** |
| CLIP-IQA (zero-shot, own implementation) | ours, from the paper | OpenAI CLIP (openai/CLIP **MIT**) | — | **Yes** |
| TOPIQ | via pyiqa only | cc-by-nc-sa-4.0 | — | **No** |

Assessment: build the harness on LPIPS + DISTS + MUSIQ (the google-research implementation)
+ MANIQA (the IIGROUP implementation) + our own zero-shot CLIP-IQA. Do not install pyiqa,
not even for a quick comparison.

## 10. Licence matrix

Row format per `_conventions.md`, plus an "Eval allowed" column. Checked 2026-09-30.

| Candidate | Code license (source) | Weights license (source) | Training data (terms) | Obligations (attribution, patents) | Verdict | Eval allowed |
|---|---|---|---|---|---|---|
| HAT Real_HAT_GAN_SRx4(_sharper) | Apache-2.0 (XPixelGroup/HAT LICENSE) | none stated; GDrive/Baidu → UNCLEAR | Real-ESRGAN-style DF2K+OST (research-only / UNCLEAR) | Apache NOTICE, patent grant | Fine-tune only | Yes |
| DRCT / DRCT-L | MIT (ming053l/DRCT) | none stated; GDrive → UNCLEAR | DF2K (+ImageNet for XL; OST300 for Real-DRCT-GAN) | MIT notice | Fine-tune only | Yes |
| ATD | Apache-2.0 (LICENSE.txt) | none stated; GDrive → UNCLEAR | DF2K | Apache | Fine-tune only | Yes |
| MambaIR / MambaIRv2 | Apache-2.0 | HF cguoh/MambaIR apache-2.0 | DF2K/DIV2K (research-only) | Apache; needs CUDA mamba_ssm | Fine-tune only | Yes |
| AuraSR-v2 | CC-BY-SA-4.0 (fal-ai/aura-sr) | apache-2.0 (HF fal/AuraSR-v2) | undisclosed → UNCLEAR | attribution; SA on code adaptations | Fine-tune only | Yes |
| OpenModelDB Nomos/RealWebPhoto/LSDIR (helaman) | arch repos Apache/MIT | CC-BY-4.0 (OpenModelDB JSON) but data-tainted → UNCLEAR | Nomos-v2 / nomos_uni / LSDIR, distilled from DIV8K, FFHQ, KonIQ, FiveK… (research-only / UNCLEAR); DF2K/ImageNet pretrains | CC BY attribution | Fine-tune only | Yes |
| 4x-PurePhoto (span/RealPLKSR) | arch MIT/Apache | CC-BY-SA-4.0 (JSON) | "handpicked photos", source unstated → UNCLEAR | attribution, SA | Fine-tune only | Yes |
| 4x-UltraSharp / UltraSharpV2 | arch Apache (ESRGAN/DAT) | **CC-BY-NC-SA-4.0** (JSON; HF card) | includes DIV2K, FiveK / "private" | NC-SA | Research-only | No |
| S3Diff | Apache-2.0 | HF zhangap/S3Diff apache-2.0; base SD-Turbo (Stability Community) | LSDIR + FFHQ 10k (NC) | Stability AUP; revenue cap for commercial | Fine-tune only | Yes |
| PiSA-SR | **UNCLEAR**: README "Apache 2.0", no LICENSE file | none; GDrive/Baidu; base SD 2.1 (openrail++) + RAM | not stated → UNCLEAR | OpenRAIL use restrictions | Fine-tune only (design ref) | Unclear |
| TSD-SR | Apache-2.0 | none stated (GDrive/OneDrive); base SD3-medium (Stability Community) | LSDIR, Flickr2K, DIV2K, FFHQ | Stability AUP | Fine-tune only | Yes |
| AdcSR | Apache-2.0 | HF Guaishou74851/AdcSR (Apache LICENSE); SD 2.1 derived | LSDIR | OpenRAIL use restrictions | Fine-tune only | Yes |
| HYPIR | **SupPixel NC licence** (LICENSE) | HF card "apache-2.0" contradicts LICENSE → UNCLEAR/NC; SD 2.1 base | ~20 M patches + 70 k faces | NC; written permission needed | Research-only | **No** |
| DreamClear | Apache-2.0 (README "code and pre-trained weights") | apache-2.0; base PixArt-α **AGPL-3.0** (HF card) + LLaVA | 1 M generated images (paper) | AGPL on base | Avoid | Yes (internal) |
| SinSR | CC BY-NC-SA 4.0 ("academic research use only") | same | ResShift-style ImageNet | NC-SA | Research-only | No |
| ResShift | S-Lab 1.0 | same | ImageNet / FFHQ | NC | Research-only | No |
| LucidFlux | FLUX.1-dev Non-Commercial v1.1.1 | HF "flux-1-dev"; base FLUX.1-dev (NC, gated) | metadata on HF | NC; attribution notice | Research-only | Yes (non-production) |
| DiT4SR | Pi-Lab 1.0 (NC) | HF pi-lab-license-1.0; base SD3.5-medium | DIV2K, DIV8K, Flickr2K/8K, NKUSR8K | NC | Research-only | No |
| Thera | Apache-2.0 | HF prs-eth/thera-* apache-2.0 | DIV2K (research-only) | Apache | Fine-tune only | Yes |
| SUPIR (re-check) | SupPixel NC licence | NC proprietary | not examined | "strictly for non-commercial purposes" | Research-only | **No** |
| DiffBIR v2 / v2.1 (re-check) | Apache-2.0 | HF lxq007/DiffBIR-v2 apache-2.0; base SD2.1-zsnr (openrail++) | laion2b-en subset / "unsplash" (Lite vs Full unstated) / FFHQ → UNCLEAR | OpenRAIL use restrictions | Fine-tune only (skip) | **Yes** |
| NAFNet (GoPro / REDS) | MIT (+BasicSR Apache) | none stated (GDrive/Baidu); MLX ports on HF are MIT (third party) | GoPro / REDS **CC BY 4.0** | MIT; CC BY attribution to Nah et al. | **Shippable candidate** (confirm weights, or retrain on GoPro) | Yes |
| Restormer (motion / defocus) | MIT since 2025-10-23 (was Academic Public License) | release v1.0 (2022), no separate licence → UNCLEAR (likely MIT) | motion: GoPro (CC BY 4.0); defocus: DPDD (UNCLEAR) | MIT; CC BY attribution | Motion: **Shippable candidate**; defocus: Fine-tune only | Yes |
| FFTformer | MIT | release `fftformer_GoPro.pth`, no separate licence → UNCLEAR | GoPro / RealBlur (CC BY 4.0) | MIT; CC BY | **Shippable candidate** (confirm weights) | Yes |
| Uformer | MIT | OneDrive; HF mirror (third party, mit) | GoPro (CC BY 4.0) / SIDD (not checked) | MIT | Shippable candidate (GoPro) | Yes |
| Stripformer | modified MIT, "non-commercial usage" | GDrive | GoPro / RealBlur | NC | Research-only | No |
| MIMO-UNet(+) | **none** | GDrive | GoPro / RealBlur | — | UNCLEAR → Research-only | Unclear |
| MPRNet | Academic Public License | GDrive | GoPro | NC | Research-only | No |
| LoFormer | Academic Public License | — | — | NC | Research-only | No |
| IFAN | AGPL-3.0 | OneDrive/Dropbox | DPDD (UNCLEAR) | AGPL | Avoid | Yes (internal) |
| DRBNet | AGPL-3.0 | release (not listed) | LFDOF + DPDD | AGPL | Avoid | Yes (internal) |
| GKMNet | none | — | DPDD | — | UNCLEAR / skip | Unclear |
| DPDD dataset | repo MIT (Abuolaim) | n/a | no dataset terms stated → UNCLEAR | cite ECCV 2020 | UNCLEAR | Yes (as test data, flagged) |
| PromptIR | Academic Public License | release model.ckpt | BSD400/WED/Rain100L/SOTS | NC | Research-only | No |
| InstructIR | MIT | HF marcosv/InstructIR mit (+ bge-micro-v2 mit) | BSD/WED/Rain100L/SOTS/GoPro/LOL/FiveK (mixed, FiveK research-only) | MIT | Fine-tune only | Yes |
| DA-CLIP / IR-SDE | MIT | HF weblzw/daclip-uir-ViT-B-32-irsde mit | 10 sets incl. DIV2K, CelebA-HQ | MIT | Fine-tune only | Yes |
| AdaIR | MIT | GDrive, none stated | as PromptIR (+GoPro, LOL) | MIT | Fine-tune only | Yes |
| AutoDIR | none | GDrive | mixed; SD-based | — | UNCLEAR / skip | Unclear |
| GFPGAN v1.3/v1.4 | Apache-2.0 **except** StyleGAN2 (NVIDIA NC) + DFDNet (CC BY-NC-SA) parts | release assets, none stated | FFHQ (CC BY-NC-SA 4.0) | NVIDIA NC ("research or evaluation"); NC-SA | Research-only | Yes (NVIDIA part) / unclear (DFDNet part); flag |
| CodeFormer | S-Lab 1.0 | release v0.1.0 | FFHQ | NC | Research-only | No |
| RestoreFormer / RestoreFormer++ | Apache-2.0 | releases, none stated | FFHQ (NC) | Apache | Fine-tune only | Yes |
| PMRF | MIT | HF ohayonguy/PMRF_… mit | FFHQ (NC) | MIT | Fine-tune only | Yes |
| pyiqa / IQA-PyTorch | **PolyForm Noncommercial 1.0.0** | HF cc-by-nc-sa-4.0 | various | NC | Avoid (for us) | **No** |
| LPIPS | BSD-2-Clause | bundled, BSD-2 | BAPPS | BSD notice | Shippable (tooling) | Yes |
| DISTS | MIT | bundled | KADID-10k (research) | MIT | Tooling OK | Yes |
| MUSIQ | Apache-2.0 (google-research) | GCS checkpoints | KonIQ/SPAQ/AVA/PaQ2PiQ (research) | Apache | Tooling OK | Yes |
| MANIQA | Apache-2.0 | releases | PIPAL/KonIQ/KADID | Apache | Tooling OK | Yes |
| CLIP-IQA (official) | S-Lab 1.0 | release | KonIQ | NC | Research-only | No |

## 11. Bake-off shortlist (for the internal evaluation harness)

Selection rules:

- (a) Eval allowed, or unclear but widely used (flagged).
- (b) Directly downloadable weights.
- (c) Plausible on the M1 Ultra with PyTorch MPS or CPU. MPS paths are **unmeasured**; set
  `PYTORCH_ENABLE_MPS_FALLBACK=1` for missing ops, and tile at 512² with overlap.
- Prefer spandrel-loadable models.

| # | Role | Model | spandrel | Exact download (file) | Notes |
|---|---|---|---|---|---|
| 1 | GAN / real-world upscaler (transformer) | 4xNomos2_hq_dat2 | yes (DAT) | https://github.com/Phhofm/models/releases/download/4xNomos2_hq_dat2/4xNomos2_hq_dat2.pth (`4xNomos2_hq_dat2.pth`) | CC-BY-4.0 (data-tainted); "hq" = trained for clean inputs, closest to camera files |
| 2 | GAN / real-world upscaler (large) | 4xNomos2_hq_drct-l | yes (DRCT) | https://huggingface.co/Phips/4xNomos2_hq_drct-l/resolve/main/4xNomos2_hq_drct-l.safetensors (`4xNomos2_hq_drct-l.safetensors`) | CC-BY-4.0 (data-tainted); DRCT-L 27.58 M params; slowest of the GANs |
| 3 | GAN upscaler (classic ESRGAN, fast) | 4xNomos8kSC | yes (ESRGAN) | https://github.com/Phhofm/models/raw/main/4xNomos8kSC/4xNomos8kSC.pth (`4xNomos8kSC.pth`) | CC-BY-4.0; RRDB 64nf/23nb; JPEG and blur OTF-trained |
| 4 | GAN upscaler (GigaGAN-style) | AuraSR-v2 | yes (AuraSR) | https://huggingface.co/fal/AuraSR-v2/resolve/main/model.safetensors (`model.safetensors`) | apache-2.0 weights, data undisclosed; tuned for generated images, so a "what over-sharpening looks like" reference |
| 5 | One-step diffusion upscaler | S3Diff | no | https://huggingface.co/zhangap/S3Diff/resolve/main/s3diff.pkl and https://huggingface.co/zhangap/S3Diff/resolve/main/de_net.pth, plus base https://huggingface.co/stabilityai/sd-turbo (`sd_turbo.safetensors` / diffusers folders) | Apache + Stability Community; ~1 B-class SD-Turbo UNet at fp16/fp32 on MPS |
| 6 | One-step diffusion upscaler (light) | AdcSR | no | https://huggingface.co/Guaishou74851/AdcSR/resolve/main/weight/net_params_200.pkl (+ `weight/pretrained/halfDecoder.ckpt`, `osediff.pkl`, `DAPE.pth`, `ram_swin_large_14m.pth`) | 456 M params; may need SD 2.1-base, whose official HF repo returns 401 (mirror `sd2-community/stable-diffusion-2-1-base`, openrail++) |
| 7 | Motion deblur | Restormer (motion) | yes (`spandrel_extra_arches`) | https://github.com/swz30/Restormer/releases/download/v1.0/motion_deblurring.pth (`motion_deblurring.pth`) | MIT (since 2025-10); GoPro CC BY 4.0; GoPro 32.92 dB, 26.1 M |
| 8 | Motion deblur | FFTformer (GoPro) | yes | https://github.com/kkkls/FFTformer/releases/download/pretrain_model/fftformer_GoPro.pth (`fftformer_GoPro.pth`) | MIT; GoPro 34.21 dB, 16.6 M; uses `torch.fft` (check MPS op coverage) |
| 9 | Motion deblur (+JPEG variant) | NAFNet-GoPro-width64 | yes (NAFNet) | Google Drive https://drive.google.com/file/d/1S0PVRbyTakYY9a82kujgZLbMihfNBLfC/view (official `.pth`); MLX port https://huggingface.co/mlx-community/NAFNet-GoPro-width64/resolve/main/model.safetensors | MIT; GoPro 33.71 dB; the REDS width64 (JPEG-blur) model is at https://drive.google.com/file/d/14D4V4raNYIOhETfcuuLI3bGLB-OYIv6X/view |
| 10 | Defocus deblur | Restormer (single-image defocus) | yes (extra arches) | https://github.com/swz30/Restormer/releases/download/v1.0/single_image_defocus_deblurring.pth (`single_image_defocus_deblurring.pth`) | DPDD combined 25.98 dB / LPIPS 0.178; DPDD terms UNCLEAR |
| 11 | All-in-one | InstructIR (7-task) | no | https://huggingface.co/marcosv/InstructIR/resolve/main/im_instructir-7d.pt and …/lm_instructir-7d.pt, plus text encoder https://huggingface.co/TaylorAI/bge-micro-v2 | all MIT; small NAFNet-style width-32 net, CPU/MPS-friendly |
| 12 | Face restoration (fast, widely used) | GFPGAN v1.4 | yes (GFPGAN) | https://github.com/TencentARC/GFPGAN/releases/download/v1.3.4/GFPGANv1.4.pth (`GFPGANv1.4.pth`) | **Flag:** Apache-2.0 except StyleGAN2 (NVIDIA NC: evaluation allowed) and DFDNet (CC BY-NC-SA) parts; FFHQ |
| 13 | Face restoration (best fidelity/perception) | PMRF | no | https://huggingface.co/ohayonguy/PMRF_blind_face_image_restoration/resolve/main/model.safetensors (`model.safetensors`) | MIT; CelebA-Test FID 37.46 / PSNR 26.37; needs `natten` (macOS support unverified) |

Alternates if a slot fails:

- **Face:** RestoreFormer (spandrel, Apache) at
  https://github.com/TencentARC/GFPGAN/releases/download/v1.3.4/RestoreFormer.pth, or
  RestoreFormer++ at
  https://github.com/wzhouxiff/RestoreFormerPlusPlus/releases/download/v1.0.0/RestoreFormer++.ckpt.
- **Generative multi-step reference:** DiffBIR v2.1 (Apache) at
  https://huggingface.co/lxq007/DiffBIR-v2/resolve/main/DiffBIR_v2.1.pt.
- **Diffusion reference with a fidelity dial:** PiSA-SR (licence UNCLEAR, weights on Google
  Drive at https://drive.google.com/drive/folders/1oLetijWNd59xwJE5oU-eXylQBifxWdss). Use
  only after the licence is clarified with the authors.
- **Deblur:** Uformer-B GoPro via the third-party HF mirror
  https://huggingface.co/CaveMindLabs/uformer-restoration-models/resolve/main/Uformer_B_GoPro.pth.

Excluded on purpose: SUPIR, HYPIR, CodeFormer, UltraSharp(V2), MPRNet, PromptIR,
Stripformer, SinSR, ResShift and DiT4SR (eval not allowed); MambaIR (CUDA-only kernels);
DreamClear and LucidFlux (tens of GB of weights; FLUX/PixArt terms). Their papers stay
useful as design references.

Harness notes (assessment):

- Evaluate on **our own raws**, degraded synthetically (the B §5 protocol) plus real
  soft/handheld captures. Score with LPIPS/DISTS (full-reference) and MUSIQ/MANIQA/our own
  CLIP-IQA (no-reference).
- Always include the B "hallucination panel".
- Record model id + file SHA-256 per run. The OpenModelDB JSONs carry `sha256` for each
  file.

## 12. Not verified / open issues

- Weights licences for the NAFNet, Restormer and FFTformer GoPro checkpoints are not stated
  separately. Before promoting any to "Shippable", get written confirmation from the authors,
  or retrain on GoPro/REDS (CC BY 4.0) ourselves, which is cheap. The Restormer release
  predates the relicensing to MIT.
- DPDD, SIDD, BSD-B, PIPAL, SPAQ, AVA: dataset terms were not found or not checked.
- arXiv IDs for LoFormer and DRBNet were not verified; GKMNet has no arXiv ID.
- PiSA-SR training data and actual repo licence need an author query.
- The HYPIR HF card (apache-2.0) contradicts its repo LICENSE; the NC reading is assumed.
- natten on macOS (PMRF), `torch.fft` on MPS (FFTformer), and SD-Turbo/SD2.1 pipelines on
  MPS were not run. All M1 feasibility statements are unmeasured.
- Per-team weights and licences for the NTIRE 2025 winners (SR x4, face, RAIM) were not
  inspected.
