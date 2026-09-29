# B. Super resolution and upscaling — landscape survey

Author: research agent, 2026-09-29. Scope: brief section 3.B. All licenses checked on
2026-09-29 from the primary source named next to each claim. Local measurements were made
on the Redlamp test machine (Apple M1 Ultra, 128 GB, macOS 26.6.2 build 25G83); the
scratch code lives in `/tmp/vtsr` and `/tmp/srbench` and was not added to the repo.

## TL;DR

- **No off-the-shelf open SR model is shippable.** Every open single-image or burst SR model
  I checked is either non-commercial itself (S-Lab, CC BY-NC, SUPIR's licence, Huawei
  CC BY-NC-SA) or has permissive code but weights trained on research-only data (DIV2K,
  ImageNet, FFHQ) or data with no stated terms (Flickr2K, OST, LSDIR, LAION). The
  permissively licensed architectures (SwinIR, HAT, DAT, SPAN, Real-ESRGAN, OSEDiff) are
  **Fine-tune only**: usable as code, but they must be retrained on data we own.
- **Apple ships a usable, fidelity-leaning SR on OS 26.** The API is
  `VTSuperResolutionScalerConfiguration` together with `VTFrameProcessor`. On the M1 Ultra
  it reports **4x only**, accepts **at most 1920×1920 input per call**, takes half-float
  RGBA (`RGhA`), and **clips output to [0, 1]**. It beat Lanczos by +1.0 to +2.0 dB PSNR at
  an effective 2x on two CC0 photos, where Real-ESRGAN lost 1.7 to 4.8 dB. It processes a
  1920×1920 tile in about 0.59 s.
- **Raw-aware SR is better in principle and in the literature.** Adobe trains on raw, joint
  with Raw Details, and the peer-reviewed evidence (Zhang 2019, Xu 2019, BSRAW, NTIRE RAW SR)
  agrees. But the published gains are measured against weak RGB baselines. The quality gap
  over "good demosaic, then a fidelity-trained RGB SR" is plausibly moderate, not dramatic.
  I found no controlled comparison against a strong modern RGB pipeline.
- **Hallucination is the core product risk.** GAN and diffusion upscalers invent texture by
  design (the perception–distortion trade-off). A photographer's 2x tool should be
  regression-trained (L1 or Charbonnier), have its output checked for consistency against
  the input, and show a "where did detail come from" map.
- **Recommendation.**
  - Keep SR in **Phase 4**.
  - **Phase 4a, about 3–4 engineer-weeks:** ship "Enhance → Super Resolution 2x" on the
    VideoToolbox scaler. Run it at 4x, then downsample to 2x, inside a tiling,
    range-encoding and fidelity-guard wrapper. Output a derived linear DNG, as Adobe does.
  - **Phase 4b, about 10–16 engineer-weeks plus compute:** train our own raw-to-RGB joint
    demosaic + 2x SR network on our own raw captures. Share the data and training
    infrastructure with AI denoise (workstream A) and ML demosaic (workstream F).
  - **Skip diffusion upscalers** entirely.
  - **Defer burst SR.**

## 1. The benchmark: Adobe Super Resolution and Raw Details

Evidence (Eric Chan, "Pack more megapixels into your photos with Adobe Super Resolution",
2021-03-10, https://blog.adobe.com/en/publish/2021/03/10/from-the-acr-team-super-resolution):

- "we used millions of pairs of low-resolution and high-resolution image patches". The
  crops are 128×128 patches "from detailed regions of real photos".
- "for Bayer and X-Trans raw files … we train directly from the raw data, which enables us
  to optimize the end-to-end quality … when you apply Super Resolution to a raw file,
  you're also getting the Enhance Details goodness as part of the deal." It also says that
  combining the two steps "results in higher quality and better performance".
- Training focused on "challenging" examples, meaning textured, detailed regions.
- It is fixed at 2x: "twice the width and twice the height … four times the total pixel
  count". The output is a new DNG, and current adjustments carry over. The limits are
  65,000 px on the long side and 500 MP. It runs on Core ML and Windows ML on the GPU.
- It also works on JPEG, PNG and TIFF, though Adobe advises using raw "whenever possible".

Enhance Details (2019, https://blog.adobe.com/en/publish/2019/02/12/enhance-details) is a
CNN demosaic that targets "false colors and zippering" for Bayer and X-Trans. It was renamed
**Raw Details** by 2023. The Denoise post
(https://blog.adobe.com/en/publish/2023/04/18/denoise-demystified) says Denoise performs
demosaicing and denoising "in a single step", and "when you apply Denoise to a raw file,
you're also getting Raw Details".

Assessment: Adobe's design is a single raw-to-RGB network family. Demosaic, denoise and SR
are joint functions that share a trunk, and the output is baked into a DNG. That
architecture, not a better generative prior, is what makes Adobe's SR look "faithful". It is
also 2x only, which is the conservative choice.

**Pixelmator Pro (Apple).** Apple's product page (https://www.apple.com/pixelmator-pro/)
says only: "Super Resolution analyzes your image and automatically scales up the resolution
so it stays sharp. And it can even enhance details". I could not retrieve Pixelmator's 2019
technical blog post, because it now redirects to apple.com and the Wayback Machine was
rate-limited or returned 404. Its scale factor, architecture and training data are therefore
**unverified**. Treat it as a competitor feature only. Its model is not available to us,
except possibly through the VideoToolbox scaler, which is a different API with no public
link to Pixelmator.

## 2. Apple-provided options

### 2.1 VideoToolbox `VTSuperResolutionScalerConfiguration` (OS 26) — exists, verified

Documentation, from
https://developer.apple.com/tutorials/data/documentation/videotoolbox/vtsuperresolutionscalerconfiguration.json
and the linked symbol pages:

- **Availability:** iOS, iPadOS, Mac Catalyst and macOS **26.0**. `VTFrameProcessor` itself
  has existed since macOS 15.4.
- **Initializer:** `init?(frameWidth:frameHeight:scaleFactor:inputType:usePrecomputedFlow:qualityPrioritization:revision:)`.
  `inputType` is `.image` or `.video`. The initializer "Returns nil if dimensions are out of
  range or revision is unsupported".
- **Maximum sizes:** "With … InputTypeImage, maximum width is 1920" and "maximum height is
  1920 on macOS and 1080 on iOS".
- **Model download:** "The super-resolution processor may require ML models which the
  framework needs to download … verify that the necessary models are present by checking
  configurationModelStatus … drive download with user awareness".
- **Versioning:** there is a `Revision` enum with `revision1` only: "A new enum case with a
  higher revision number is added when the processing algorithm is updated."
- **Parameters:** `VTSuperResolutionScalerParameters(sourceFrame:previousFrame:previousOutputFrame:opticalFlow:submissionMode:destinationFrame:)`.
  Use `.random` submission mode for unrelated stills.
- **WWDC25 session 300** (https://developer.apple.com/videos/play/wwdc2025/300/) says it is
  "ideal for application like photo enhancement and media restoration", and "Two ML models
  are available for super resolution, one for images and the other for videos."
- **Low-latency variant:** `VTLowLatencySuperResolutionScalerConfiguration` is a
  "lightweight super scaler" for video conferencing. It is not relevant to stills.

Local probe (M1 Ultra, macOS 26.6.2). Evidence:

| Query | Result |
|---|---|
| `isSupported` | true |
| `supportedScaleFactors` | **[4]** only |
| `supportedRevisions` / default | revision1 |
| `.image` at 1920×1920, 1920×1080, 1024×1024 | valid configuration |
| `.image` at 2048×2048, 4000×3000 | nil (out of range) |
| Supported pixel formats | `RGhA` (kCVPixelFormatType_64RGBAHalf) |
| Model status | ready (the OS already had the assets; no download needed) |
| `startSession` | 0.10–0.54 s |
| 960×640 → 3840×2560 | 0.23–0.72 s first call, **~0.15 s** steady state |
| 1920×1920 → 7680×7680 | 0.71–0.81 s first call, **~0.59 s** steady state |
| Input scaled ×4 in linear space (max 4.0) | output max **1.000**: values above 1 are clipped |
| Low-latency variant | max input 960×960, min 96×96 |

Quality probe. Two CC0 Wikimedia photos were used, both JPEGs and therefore already
processed:
[Lincoln DSC01970](https://commons.wikimedia.org/wiki/File:!941_Lincoln_Continental_Coupe,_Series_57_-_Automobile_Driving_Museum_-_El_Segundo,_CA_-_DSC01970.jpg)
and
[Defurovy Lažany square](https://commons.wikimedia.org/wiki/File:!Defurovy_La%C5%BEany_-_n%C3%A1m%C4%9Bst%C3%AD.jpg).
Method: take a centre crop as ground truth, downscale it with Lanczos to 960×640, upscale,
and compute sRGB PSNR with an 8 px border excluded. The "effective 2x" result was produced
as VT 4x followed by a Lanczos 0.5 downscale. Evidence:

| Image, factor | Lanczos | VT SR | Real-ESRGAN x2plus |
|---|---|---|---|
| Lincoln, 2x | 34.03 dB | **36.07 dB** | 32.30 dB |
| Square, 2x | 31.90 dB | **32.93 dB** | 27.11 dB |
| Lincoln, 4x | 28.38 dB | **30.09 dB** | — |
| Square, 4x | 26.70 dB | **28.03 dB** | — |

Visually (crops in `/tmp/vtsr/*_gt_vt_realesrgan.png`), VT SR sharpens edges and keeps
gravel and wall texture close to the ground truth. Real-ESRGAN produces the familiar
"oil-paint" look: it flattens the gravel, smooths the faces and adds crisp invented edges.

Caveats: two images is not a benchmark; the degradation is synthetic (Lanczos, no raw, no
noise); and the model's training data and determinism are undocumented.

Assessment:

- It is the only **shippable, zero-licence-risk, fidelity-leaning** SR available today.
  Apple is responsible for its weights.
- **Constraint 1: 4x only.** 2x means running at 4x and downsampling. Compute and memory
  scale with the 4x output: a 1920² tile produces 7680² × 8 bytes, about 472 MB of
  half-float per tile. That is fine on a Mac. On an 8 GB iPhone it needs 1920×1080 tiles
  and should be released tile by tile.
- **Constraint 2: output is clipped to [0, 1].** Our linear scene-referred data must be
  mapped into [0, 1] with an invertible encoding (for example exposure normalization plus
  a log or sRGB-like OETF), and the mapping inverted afterwards. The model was probably
  trained on display-referred content, so a display-like encoding is also likely to be
  closest to its training distribution. Specular highlights above the normalization point
  still need handling, either by excluding them or by processing them with Lanczos.
- **Constraint 3: reproducibility.** The weights are an OS-managed download that could change
  under `revision1`, and cross-device determinism is unknown. The result must therefore be
  baked or cached and recorded as `vt.sr.image.rev1 + OS build`. That fits "Enhance →
  derived DNG" naturally.
- **Constraint 4: black box.** There is no strength control, no uncertainty output and no
  raw input. Our own fidelity guard (section 5) would wrap it.
- **Speed:** 24 MP at an effective 2x takes about 7–9 overlapped tiles × 0.59 s, so roughly
  5–6 s on the M1 Ultra plus resampling. That is acceptable for a background Enhance job.
  iPhone speed is unmeasured.

### 2.2 MetalFX spatial and temporal scalers — not appropriate for photos

The MetalFX documentation (https://developer.apple.com/tutorials/data/documentation/metalfx.json)
describes the framework as "upscaling lower-resolution content to save GPU time". The
temporal scaler needs "pixel color, depth, and motion information". The spatial scaler "only
requires a pixel color input texture". OS 26 adds `MTLFXTemporalDenoisedScaler` and
`MTLFXFrameInterpolator`.

Assessment: these are real-time game upscalers built around jittered renders and motion
vectors. The spatial scaler is an edge-adaptive filter. Neither aims at photographic
fidelity, and neither produces offline, reproducible output. At most, the spatial scaler
could be used for viewport zoom above 100%, where Lanczos from the mip pyramid is already
adequate. Verdict: **skip for SR**.

### 2.3 Core Image

`CILanczosScaleTransform` and `CIEdgePreserveUpsample` exist (the docs pages resolve under
`documentation/coreimage/`). I found no ML super-resolution filter in Core Image. My search
was not exhaustive, but it covered the CIFilter scaling pages. Lanczos is our baseline and
the fallback for highlights.

## 3. Open single-image SR landscape

### 3.1 Fidelity-oriented (L1-trained) transformers and CNNs

- **SwinIR** (arXiv 2108.10257, https://github.com/JingyunLiang/SwinIR): Apache-2.0.
  Classical SR is trained on DIV2K or DF2K. Real-world SwinIR adds OST, WED, FFHQ,
  Manga109 and SCUT-CTW1500 (README table).
- **HAT** (arXiv 2205.04437, https://github.com/XPixelGroup/HAT): Apache-2.0. From the README
  (x4, no ImageNet pretraining): SwinIR 11.9 M params, Urban100 27.45 dB; HAT-S 9.6 M,
  27.87 dB; HAT 20.8 M, 102.4 G multiply-adds for a 64×64 input, 27.97 dB. HAT-L uses
  ImageNet pretraining.
- **DAT** (arXiv 2308.03364, https://github.com/zhengchen1999/DAT): Apache-2.0, trained on
  DF2K.
- **SRFormer / SRFormerV2** (arXiv 2303.09735, https://github.com/HVision-NKU/SRFormer):
  **CC BY-NC 4.0** (LICENSE.txt: "Attribution-NonCommercial 4.0 International").
- **SPAN** (arXiv 2311.12770, https://github.com/hongyuanyu/SPAN): Apache-2.0 ("This project is
  released under the Apache 2.0 license"). It won the **NTIRE 2024 Efficient SR** main track
  as team XiaomiMM (arXiv 2404.10343, Table 1): 0.151 M params, 9.83 GFLOPs, 5.59 ms average
  on an RTX 3090, x4. This is an efficiency contest, not a quality one: the rule is
  "maintaining a PSNR of approximately 26.90 dB" on DIV2K_LSDIR_valid.
- **NTIRE 2025 Efficient SR** (arXiv 2504.10686): the overall winner was the EMSR team
  (0.131 M params, 8.54 G FLOPs), with XiaomiMM second. The runtime reference is an RTX A6000.

Local Core ML timing (coremltools 9.0, FP16 ML Program, median of 5 predictions from Python;
SPAN used random weights because only speed matters):

| Model | Input tile | CPU_AND_GPU | CPU_AND_NE |
|---|---|---|---|
| SPAN x4 (48 ch) | 256² | 9.8 ms | 13.5 ms |
| SPAN x4 (48 ch) | 512² | 33.3 ms | 52.6 ms |
| RRDBNet x2 (Real-ESRGAN x2plus weights) | 256² | 56.3 ms | 59.6 ms |

Assessment:

- An SPAN-class CNN processes about 8 MP of input per second on the M1 Ultra GPU, so 24 MP
  at 2x takes a few seconds. RRDBNet takes about 20 s.
- SwinIR, HAT and DAT use window attention, which converts to Core ML with more effort and
  typically falls back from the Neural Engine. At 10–20 M params they would run several
  times slower than SPAN. Their roughly +0.5 dB Urban100 advantage over SwinIR-class models
  is visible mainly on synthetic bicubic benchmarks.
- For an iPhone-capable 2x model, an **SPAN/EMSR-class CNN, widened for quality**, is the
  right design point. A HAT-S-class model is the Mac-only "quality" option.

### 3.2 GAN-based

- **ESRGAN** (arXiv 1809.00219): Apache-2.0.
- **Real-ESRGAN** (arXiv 2107.10833, https://github.com/xinntao/Real-ESRGAN): code
  **BSD-3-Clause** (GitHub API). Training data per docs/Training.md: "We use DF2K (DIV2K and
  Flickr2K) + OST datasets". The weights are GitHub release assets with no separate licence,
  so the weights licence is **UNCLEAR**. It is tainted by data in any case.
- **Real-ESRGAN-ncnn-vulkan** carries a NOASSERTION licence (GitHub API) and was not examined
  further.
- **LDL** (arXiv 2203.09195) builds a local artifact map to suppress GAN artifacts. This is
  relevant to a fidelity guard.

Assessment: Real-ESRGAN's degradation model assumes heavy blur, noise and JPEG artifacts. On
clean camera files it over-denoises and paints, as my local test showed (−1.7 and −4.8 dB
versus Lanczos). Wrong prior for raw files.

### 3.3 Diffusion-based

| Model | Code licence (verified) | Base / weights | Training data |
|---|---|---|---|
| StableSR (2305.07015) | **S-Lab License 1.0**: "use for non-commercial purpose" | SD 2.1 (768v / base) | DF2K+OST (README) |
| SUPIR (2401.13627) | **SUPIR Software License**, "strictly for non-commercial purposes" | SDXL (openrail++) + LLaVA | not examined |
| SeeSR (2311.16518) | Apache-2.0 | SD-2-base, via a third-party HF mirror, plus RAM (Apache-2.0) | LSDIR + FFHQ10k (README) |
| OSEDiff (2406.08177) | Apache-2.0 | SD 2.1-base (the official HF repo returned HTTP 401 on 2026-09-29; the README links the mirror `Manojb/stable-diffusion-2-1-base`, card `openrail++`) | LSDIR (84,991) + FFHQ 10k (README) |
| DiffBIR (2308.15070) | Apache-2.0; HF weights tagged apache-2.0 | SD 2.1 (IRControlNet) | v2: "filtered laion2b-en"; v2.1: "filtered unsplash"; v1: ImageNet-1k (README) |
| PASD (2308.14469) | Apache-2.0; PASD-SDXL HF tagged apache-2.0 | SD1.5 / SDXL | DIV2K, DIV8K, FFHQ_5K, Flickr2K, OST, Unsplash2K (README) |
| InvSR (2412.09013) | **S-Lab License 1.0** (NC) | SD-Turbo (Stability AI Community License) | not examined |

Assessment:

- **Licence.** StableSR, SUPIR and InvSR are out. The others are Apache-2.0 code on top of
  OpenRAIL++-M Stable Diffusion bases, whose training data (LAION) has unclear copyright
  status, and they are fine-tuned on FFHQ (dataset CC BY-NC-SA 4.0, verified at
  https://github.com/NVlabs/ffhq-dataset) or LSDIR (images: no terms found).
- **Compute.** These are 0.9–3 B parameter models. OSEDiff is one-step and was "applied to the
  OPPO Find X8 series" (README), so on-device use is possible. It is still one to two orders
  of magnitude above SPAN.
- **Hallucination.** These models exist to synthesize plausible texture.
- **Verdict:** skip for Redlamp. At most, run one of them internally as a "what hallucination
  looks like" reference in the evaluation harness, and only where the licence allows
  evaluation (Apache-2.0 ones only).

### 3.4 The training-data problem (all SR families)

- **DIV2K** (https://data.vision.ee.ethz.ch/cvl/DIV2K/): "this dataset is made available for
  academic research purpose only … the copyright belongs to the original owners." **Research-only.**
- **Flickr2K** (EDSR, https://cv.snu.ac.kr/research/EDSR/Flickr2K.tar): no terms found in the
  EDSR README. **UNCLEAR** (Flickr images of mixed licences).
- **OST** (SFTGAN, https://github.com/xinntao/SFTGAN): no terms in the README. **UNCLEAR.**
- **LSDIR** (https://github.com/ofsoundof/LSDIR): the repo is MIT, but the README states no
  image licence. **UNCLEAR.**
- **FFHQ:** dataset CC BY-NC-SA 4.0; images CC BY, BY-NC, PD. **Non-commercial.**
- **ImageNet** (https://image-net.org/download-images.php): "for non-commercial research and/or
  educational purposes". **Research-only.**

Assessment: the whole public SR model zoo is trained on these datasets, so **any shipped SR
model we don't get from Apple must be trained by us**. The good news is that SR is the
easiest restoration task to self-supervise: downsample our own high-resolution raws in the
raw domain. No paired capture is needed for the base model. Pairs from optical zoom, as in
Zhang 2019, are a refinement.

## 4. Raw-domain and burst SR

### 4.1 Burst / multi-frame

- **Wronski et al. 2019, "Handheld Multi-Frame Super-Resolution"** (arXiv 1905.03277; Google
  Pixel Super Res Zoom). It is classical, with no learning: "we supplant the use of
  traditional demosaicing … with a multiframe super-resolution algorithm that creates a
  complete RGB image directly from a burst of CFA raw images … natural hand tremor", and it
  runs at "100 milliseconds per 12-megapixel RAW input burst frame" on phones. The Google
  blog
  (https://research.google/blog/see-better-and-further-with-super-res-zoom-on-the-pixel-3/)
  says most of the gain "at least for modest zoom factors like 2-3x comes from our
  multi-frame approach". No official code; implement from the paper.
  **Patent status: not verified** (Google Patents search was unavailable from this
  environment). Treat it as a likely-patented Google technique until checked.
- **DBSR** (Bhat et al., arXiv 2101.10997, https://github.com/goutamgmb/deep-burst-sr):
  "Licensed under CC BY-NC-SA 4.0 … released for academic research use only". This repo
  also hosts the BurstSR dataset. **Research-only.**
- **BSRT** (arXiv 2204.08332): MIT code. Trained on BurstSR / SyntheticBurst (NC data).
  **Fine-tune only.**
- **Burstormer** (arXiv 2304.01194): MIT code, same data. **Fine-tune only.**

Assessment: burst SR only applies when the user has shot a handheld burst of a static scene,
which is rare for DSLR and mirrorless users and common on phones. It overlaps with the
focus-stacking alignment infrastructure (workstream G). A Wronski-style merge could later
become a "merge burst to high-res" feature. **Defer**, but reuse G's alignment code and
revisit once G ships. Do a patent check first.

### 4.2 Single-image raw SR

- **Zhang et al. 2019, "Zoom To Learn, Learn To Zoom"** (arXiv 1905.05169;
  https://github.com/ceciliavision/zoom-learn-zoom, **CC BY-NC 4.0**). "It is beneficial to
  use real, RAW sensor data for training … synthesizing sensor data by resampling
  high-resolution RGB images is an oversimplified approximation … resulting in worse image
  quality." It contributes the SR-RAW dataset (optical-zoom pairs) and the CoBi loss for
  misaligned pairs.
- **Xu et al. 2019, "Towards Real Scene Super-Resolution with Raw Images"** (arXiv 1905.12156):
  "super-resolution with raw data helps recover fine details and clear structures". It uses
  a simulated imaging pipeline for data.
- **Qian et al. 2019, "Rethinking … Demosaicing, Denoising, and Super-Resolution Pipeline"**
  (arXiv 1905.02538). For sequential pipelines, the order matters: DN→SR→DM beats the
  conventional DM→DN→SR. For end-to-end networks, adding a pipeline order yields "only a
  consistent but insignificant improvement". I read this as: joint beats sequential, and
  once the processing is joint, internal ordering matters little.
- **BSRAW** (Conde et al., arXiv 2312.15487): blind raw SR with a realistic degradation
  pipeline (noise, defocus, exposure).
- **NTIRE 2024 RAW SR challenge** (arXiv 2404.16223) and the **NTIRE 2025 RAW Restoration and
  SR challenge** (arXiv 2506.02197): 2x Bayer SR with unknown noise and blur, 45 submitting
  teams each year. Both reports say raw SR "is not as explored as in the RGB domain".

### 4.3 Is raw-aware SR meaningfully better than RGB upscaling afterwards?

Evidence for:

- Adobe ships SR joint with Raw Details and states that doing so gives "higher quality and
  better performance".
- Zhang 2019 and Xu 2019 both show gains from raw input.
- Physically, a demosaic has already interpolated two of every three colour samples and
  applied anti-zipper smoothing. An RGB upscaler therefore starts from an image that has
  lost the aliasing information that true SR exploits, and it may also amplify demosaic
  artifacts such as maze patterns, false colour and zippering.

Evidence against, or open:

- The published comparisons use RGB baselines produced by simple ISPs or RGB models trained
  on synthetic bicubic data, not a strong demosaic plus a fidelity-trained RGB SR. Qian 2019
  suggests the benefit comes from *joint processing*, not from raw input per se.
- I found **no controlled study** of "Redlamp-class demosaic (RCD/AMaZE) + L1-trained RGB 2x"
  against "joint raw 2x" on real camera raws.

Assessment:

- Raw-aware SR is meaningfully better for **fine, high-frequency, near-Nyquist detail** such
  as foliage, fabric, hair and text, and for **X-Trans**. These are exactly the cases where
  demosaic artifacts would otherwise be upscaled.
- For already-soft or noisy images the difference is small.
- The larger practical win is architectural. One raw-to-RGB network that denoises,
  demosaics and optionally upsamples 2x replaces three stages and three sets of artifacts,
  which is what Adobe converged on. So the recommendation is to build SR **as the 2x head of
  the same raw-domain network as AI denoise and ML demosaic** (A and F), not as a separate
  RGB model.
- Test for this: an A/B on our own X-Trans and 24/45 MP Bayer raws, comparing VT-SR-on-RCD
  with the joint model once it exists.

## 5. Hallucination risk and how to constrain it

Evidence:

- **Blau & Michaeli, "The Perception-Distortion Tradeoff"** (arXiv 1711.06077). Perceptual
  quality and distortion (PSNR) are at odds. Any method that looks "natural" beyond the MMSE
  point must deviate from the most likely reconstruction.
- **Ren et al. 2025, "Hallucination Score"** (arXiv 2507.14367). Hallucinations in generative
  SR "are not well-characterized with existing image metrics … they are orthogonal to both
  exact fidelity and no-reference quality". The authors use an MLLM-based score with
  differentiable proxies for fine-tuning.
- **Uncertainty quantification:** Angelopoulos et al. 2022, conformal image-to-image regression
  with per-pixel intervals (arXiv 2202.05265); Belhasin et al. 2023, principal uncertainty
  quantification (arXiv 2305.10124); Wang & Chuang 2026, UGDiff, which restores high
  frequencies only where estimated uncertainty is high and preserves fidelity elsewhere
  (arXiv 2608.25998).
- **Local evidence:** Real-ESRGAN −1.7 and −4.8 dB below Lanczos with visible invented edges;
  VT SR +1.0 and +2.0 dB above Lanczos with no obvious invented texture in the crops.

Proposed design constraints for Redlamp SR (assessment):

1. **Training objective.** L1 or Charbonnier loss, optionally with a small, frequency-limited
   perceptual term. No adversarial loss and no diffusion prior in the default model. This
   sits near the MMSE end of the perception–distortion curve on purpose.
2. **Back-projection consistency check.** Downsample the SR output with the same kernel used
   in training and compare it with the input. Where the residual exceeds the noise model
   (from workstream A), fall back locally to Lanczos, or at least flag the region. This is
   cheap, model-agnostic, and also works around the black-box VideoToolbox scaler.
3. **"Invented detail" map.** Show the per-pixel magnitude of the high-frequency difference
   between SR and Lanczos, optionally scaled by an uncertainty head where our own model has
   one. It works like the focus-peaking overlay, so the user can see where detail was added.
4. **Strength blend and a 2x cap.** A 0–100 blend between Lanczos and SR, with no 4x in the UI
   initially. Adobe also caps at 2x.
5. **Provenance.** Record the model id and revision in the recipe and in the derived DNG's
   XMP. Consider a C2PA "AI-enhanced" assertion (see F).
6. **Evaluation.**
   - Measure PSNR, SSIM, LPIPS and DISTS on degraded-then-restored pairs from **our own**
     raws.
   - Run blind A/B tests against Adobe Super Resolution and against Lanczos with sharpening.
   - Include a "hallucination panel": text, faces at small scale, repeating textures, and
     fine random texture such as gravel and foliage, where a good result must *not* invent
     structure.

## 6. Shortlist

| Candidate | Code license | Weights license | Data | Quality evidence | Apple Silicon fit | Verdict |
|---|---|---|---|---|---|---|
| **VT `VTSuperResolutionScaler` (.image)** | Apple SDK (OS API) | Apple, OS-downloaded | undisclosed | +1.0 to +2.0 dB over Lanczos at 2x and 4x (local, n=2); no visible invention | 0.59 s per 1920² tile (M1 Ultra); 4x only; clips to [0,1]; iOS max 1920×1080 | **Adopt now (Phase 4a)** behind a wrapper |
| Own raw→RGB joint demosaic + 2x SR (SPAN/NAFNet-class) | ours (MPL-2.0) | ours | our own raw captures + synthetic degradation | literature: joint raw SR beats sequential (1905.02538, 1905.05169, Adobe) | SPAN-class ~8 MP/s input on GPU (local timing) | **Build (Phase 4b)**, sharing A's infrastructure |
| SPAN / EMSR (NTIRE ESR winners) | Apache-2.0 | trained on DIV2K/LSDIR | research-only / UNCLEAR | ~26.9 dB DIV2K_LSDIR x4 (challenge floor) | 9.8 ms per 256² on GPU | **Fine-tune only** (architecture reference) |
| HAT / HAT-S | Apache-2.0 | DF2K (+ImageNet) | research-only | Urban100 x4 27.97 / 27.87 dB (README) | 9.6–20.8 M params; window attention; Mac only | Fine-tune only (Mac "quality" option, later) |
| SwinIR / DAT | Apache-2.0 | DIV2K/DF2K (+FFHQ etc.) | research-only | SwinIR Urban100 x4 27.45 dB | as HAT | Fine-tune only |
| SRFormer | CC BY-NC 4.0 | same | research-only | +0.1–0.3 dB over SwinIR (paper) | as HAT | Research-only |
| Real-ESRGAN / ESRGAN | BSD-3 / Apache-2.0 | UNCLEAR (release assets) | DF2K+OST | local: −1.7 / −4.8 dB vs Lanczos; paints texture | RRDBNet 56 ms per 256² (x2) | Fine-tune only; wrong objective (**skip**) |
| OSEDiff / SeeSR / DiffBIR / PASD | Apache-2.0 | on SD (OpenRAIL++) | LAION/LSDIR/FFHQ/ImageNet | best no-reference perceptual scores; hallucinates by design | 0.9–3 B params | **Skip** (licence, hallucination, compute) |
| StableSR / SUPIR / InvSR | S-Lab NC / SUPIR NC / S-Lab NC | NC | various | — | heavy | Research-only |
| Wronski 2019 burst SR | paper only | n/a | n/a | Pixel Super Res Zoom; ~2x | 100 ms per 12 MP frame on phone | **Defer**; clean-room later; patent check |
| DBSR / BSRT / Burstormer | CC BY-NC-SA / MIT / MIT | BurstSR (NC) | NC | NTIRE burst benchmarks | moderate | Research-only / Fine-tune only |
| MetalFX spatial/temporal | Apple SDK | n/a | n/a | real-time game upscaling | real-time | **Skip** for SR |

## 7. License matrix

| Candidate | Code license (source) | Weights license (source) | Training data (terms) | Obligations (attribution, patents) | Verdict |
|---|---|---|---|---|---|
| VT Super Resolution Scaler | Apple SDK, platform API (developer.apple.com VideoToolbox docs) | Apple-owned model downloaded by the OS; no redistribution by us | undisclosed | Apple Developer Program terms; none extra | **Shippable** (as an OS API) |
| Real-ESRGAN | BSD-3-Clause (api.github.com/repos/xinntao/Real-ESRGAN) | none stated for release .pth: **UNCLEAR** | DIV2K "academic research purpose only"; Flickr2K, OST: no terms (**UNCLEAR**) | BSD notice | Fine-tune only |
| ESRGAN | Apache-2.0 (GitHub API) | as above | DIV2K/Flickr2K/OST | Apache NOTICE; patent grant | Fine-tune only |
| SwinIR | Apache-2.0 (GitHub API) | release assets, no separate licence: UNCLEAR | DIV2K/DF2K (+OST, WED, FFHQ CC BY-NC-SA, Manga109) | Apache | Fine-tune only |
| HAT | Apache-2.0 (GitHub API) | UNCLEAR (Drive / Baidu) | DF2K + ImageNet ("non-commercial research") | Apache | Fine-tune only |
| DAT | Apache-2.0 (GitHub API) | UNCLEAR (Drive) | DF2K | Apache | Fine-tune only |
| SPAN | Apache-2.0 (README: "released under the Apache 2.0 license") | UNCLEAR (Drive) | DIV2K / LSDIR (UNCLEAR) | Apache | Fine-tune only |
| SRFormer | CC BY-NC 4.0 (LICENSE.txt) | same | DF2K | NC | Research-only |
| StableSR | S-Lab License 1.0: "use for non-commercial purpose" (LICENSE.txt) | same (HF card "other") | DF2K+OST | NC | Research-only |
| SUPIR | SUPIR Software License: "strictly for non-commercial purposes" (LICENSE, README) | proprietary NC | not examined | NC; SDXL openrail++ | Research-only |
| SeeSR | Apache-2.0 (GitHub API) | UNCLEAR; built on SD-2-base (OpenRAIL++-M) + RAM (Apache-2.0) | LSDIR + FFHQ (NC) | OpenRAIL use restrictions | Fine-tune only (skip) |
| OSEDiff | Apache-2.0 (GitHub API) | UNCLEAR; SD 2.1-base (mirror card `openrail++`; official repo 401) | LSDIR + FFHQ (NC) | OpenRAIL use restrictions | Fine-tune only (skip) |
| DiffBIR | Apache-2.0 (GitHub API) | HF `lxq007/DiffBIR-v2` card: apache-2.0, on SD 2.1 | laion2b-en / Unsplash / ImageNet: **UNCLEAR** | OpenRAIL | Fine-tune only (skip) |
| PASD | Apache-2.0 (GitHub API) | HF `yangtao9009/PASD-SDXL` card: apache-2.0, on SDXL (openrail++) | DIV2K, DIV8K, FFHQ, Flickr2K, OST, Unsplash2K | OpenRAIL | Fine-tune only (skip) |
| InvSR | S-Lab License 1.0 (LICENSE) | NC; on SD-Turbo (Stability AI Community License) | not examined | NC | Research-only |
| DBSR + BurstSR dataset | CC BY-NC-SA 4.0: "academic research use only" (LICENSE) | same | BurstSR (same) | NC-SA | Research-only |
| BSRT | MIT (GitHub API) | UNCLEAR (Drive) | BurstSR / SyntheticBurst (NC) | MIT notice | Fine-tune only |
| Burstormer | MIT (GitHub API) | UNCLEAR | BurstSR (NC) | MIT notice | Fine-tune only |
| Zoom-Learn-Zoom + SR-RAW | CC BY-NC 4.0 (LICENSE) | NC | SR-RAW | NC | Research-only |
| Wronski 2019 | no code; paper (arXiv 1905.03277) | n/a | n/a | **patent status unverified** (Google) | Implement from paper after a patent check |
| Our own joint model | MPL-2.0 | ours | our captures (must be documented, with model release forms if people appear) | none | **Shippable** |

## 8. Recommendation, effort and roadmap

Recommendation: **adopt, then build.** Keep the feature in Phase 4, but split it in two.

**Phase 4a: "Enhance → Super Resolution" on VideoToolbox. About 3–4 engineer-weeks.**
- Tiled wrapper (0.5 w). Use 1920×1920 tiles on macOS and 1920×1080 on iOS, with a
  32–64 px overlap and feathered blend, running on the P3 inference lane. Make it
  cancellable, with progress reporting and thermal back-off. This reuses the shared tiled
  inference framework once it exists.
- Range encoding (0.5–1 w). Normalize exposure, apply an invertible OETF into [0, 1],
  process, invert, and route clipped highlights to Lanczos. Validate that the round trip
  does not shift colour.
- 4x → 2x (0.25 w). Downsample the 4x result immediately per tile with an area or Lanczos
  filter, so the 4x image is never held whole.
- Fidelity guard (1 w). Back-projection residual check against the input, the
  invented-detail overlay, and a strength blend.
- Output (0.5–1 w). A derived linear DNG (or Redlamp "virtual raw") with the source
  reference, recipe, and `vt.superres.image.revision1` plus OS build in XMP. Handle model
  download UX through `configurationModelStatus` and `downloadConfigurationModel`.
- Evaluation (0.5 w, overlapping). A/B against Adobe SR on 30–50 of our own raws, and
  timing on an A17 Pro.

**Phase 4b: own raw-domain 2x head. About 10–16 engineer-weeks plus GPU compute.**
- This depends on A's data pipeline: calibrated noise models, a synthetic degradation
  pipeline, and our own raw capture library. It also depends on F's ML demosaic work.
- Architecture: an SPAN/NAFNet-style CNN that is Neural-Engine friendly (convolutions and
  pixel-shuffle only). Its input is packed Bayer or X-Trans plus a noise map; its output is
  linear RGB at 1x (demosaic/denoise) or 2x (SR).
- Training: L1/Charbonnier loss, self-supervised pairs made by raw-domain downsampling of our
  high-resolution raws, and a small optical-zoom pair set for validation (the Zhang 2019
  methodology, on our own captures).
- Effort breakdown: data pipeline about 3 weeks (shared with A), model and training about
  4–6 weeks, Core ML conversion and quantization about 1–2 weeks, evaluation and tuning
  about 2–3 weeks.
- Compute: rough estimate, 1–3 weeks of a single 8-GPU node, similar to the NTIRE-scale
  models above.
- Ship it only if blind tests beat Phase 4a. Keep VT as the fallback for non-raw inputs.

**Skip:** diffusion or GAN upscalers, and 4x in the UI.
**Defer:** burst SR. Revisit after G's alignment work ships, with a patent check.

Roadmap placement: Phase 4a can move to late Phase 3 cheaply if we want "feature parity"
optics, because it has no training dependency. Phase 4b should follow A's AI denoise
(Phase 3). SR then becomes one more head on the same raw network, which makes its marginal
cost far lower than a standalone SR project.

## 9. Risks and open questions

- **VT black-box risk.**
  - We cannot pin weights. Apple may update the `revision1` assets or add revisions, so old
    edits could re-render differently. Mitigation: bake the output and record the revision.
  - The training data, behaviour on noisy input, and determinism across devices and OS
    versions are all unknown.
  - Test whether results are bitwise-identical across two Macs and one iPhone on the same
    OS build.
- **The clip-to-[0,1] behaviour** makes true scene-linear or HDR processing lossy unless it is
  range-encoded. The best encoding (log or sRGB-like) needs an experiment. Does the model
  behave worse on log-encoded input than on display-encoded input?
- **iOS limits.** The maximum is 1920×1080 per call, and the model download is OS-managed and
  may require user consent or network. Unmeasured: A17 Pro speed, memory, and thermal
  behaviour on 48 MP ProRAW.
- **Noise.** SR on noisy high-ISO raws will amplify noise. Run order should be denoise, then
  SR, or joint (Phase 4b). Adobe's DNG approach lets users chain Denoise and SR; we need the
  same composition rule.
- **Legal.** Our own training captures need documented provenance and, where people appear,
  model releases. Wronski-style burst SR needs a patent search. There is no licence exposure
  from VT.
- **Evaluation data.** DIV2K, Urban100 and similar sets are research-only or unclear, so
  internal benchmarking on them is itself questionable for a commercial project. Build our
  own evaluation set from CC0 and own captures. The two Wikimedia CC0 images used here are a
  start.
- **Open question.** Does "VT SR on top of our RCD demosaic" already reach Adobe SR parity on
  Bayer files? If yes, Phase 4b can drop to "only if X-Trans or foliage cases fail".
- **Open question.** Is a 4x mode ever needed (crop-heavy wildlife)? If so, it should come with
  a louder hallucination warning and the invented-detail overlay on by default.
