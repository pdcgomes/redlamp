# D. Object removal, healing and distraction removal

Research notes for workstream D of the [brief](../ai-and-computational-photography-brief.md).
All licenses, patents and API facts checked 2026-09-29 unless stated. "Evidence" = cited
primary source; "Assessment" = our judgement. Nothing here is legal advice; the patent section
in particular needs counsel before we ship anything PatchMatch-shaped.

## Summary

- **There is no shippable, off-the-shelf learned inpainting model.** Every mainstream
  non-diffusion inpainter with good quality (LaMa/Big-LaMa, MI-GAN, MAT, CoModGAN, FcF, ZITS,
  MISF) is trained on Places2/Places365, whose terms say "You will use the data only for
  non-commercial research and educational purposes". Several also carry NVIDIA NC code or
  CC BY-NC weights. Diffusion inpainters are either NC (FLUX dev family), revenue-capped
  (SD 3.5), LAION-derived OpenRAIL (SD 1.5/SDXL inpainting), or too large for an 8 GB iPhone.
- **Recommendation: build.** Ship classical Heal/Clone/Dust in Phase 3 (Poisson-style
  blending, no PatchMatch), and train our own LaMa-class (or MI-GAN-class) inpainter from
  scratch on public-domain images (PD12M, Megalith-10M) plus our own captures. The LaMa
  architecture is Apache-2.0 and well documented, so "Fine-tune only" is really "retrain only".
- **PatchMatch is patented and live.** Adobe's core PatchMatch patent US8285055B1 is
  "Active" with adjusted expiration **2031-04-09**; Generalized PatchMatch US8571328B2 to
  2031-10-19; the content-aware "semantic constraint" patent US8355592B1 to 2031-08-12. The
  Criminisi exemplar-inpainting, example-based tiling, Poisson "guided interpolation"
  (Microsoft) and Healing Brush (Adobe) patents are all expired.
- **Apple provides no public inpainting or "Clean Up" API** on macOS/iOS 26 or 27, and no
  C2PA API in ImageIO, PhotoKit, AVFoundation, Core Image or Vision. Vision does provide
  person instance masks (iOS 18/macOS 15+), lens-smudge detection (26+) and, new in 27,
  tap/scribble/rectangle iterative segmentation.
- **C2PA:** spec 2.4 (April 2026). `c2pa-rs` is "MIT OR Apache-2.0" and `c2pa-swift` is
  Apache-2.0, so both are compatible with MPL-2.0. Recommend labeling learned fill as
  `compositeWithTrainedAlgorithmicMedia` with region-scoped `changes`, and classical heal as a
  plain `c2pa.edited`, behind an export option, with a visible in-app "Generated fill" badge.

## 1. Inpainting landscape

### 1.1 Non-diffusion (GAN / feed-forward) inpainters

**LaMa / Big-LaMa** (Suvorov et al., WACV 2022, arXiv:2109.07161).
- Evidence: fast Fourier convolutions give an image-wide receptive field. The paper
  reports that the model "generalizes surprisingly well to resolutions that are higher than
  those seen at train time". The README says ~2k when trained at 256×256
  (https://github.com/advimman/lama). The best released model is "Big-LaMa (Places2, Places
  Challenge)"; there are also CelebA-HQ models.
- Code: Apache-2.0 (GitHub API `license.spdx_id = Apache-2.0`).
- Weights: hosted on Google Drive and `smartywu/big-lama` on Hugging Face (HF tag
  apache-2.0, 381 MB zip). No separate weights license upstream.
- Training data: Places365 / Places-Challenge. The Places2 download page's terms (Wayback
  capture of 2021-02-20,
  https://web.archive.org/web/20210220220343/http://places2.csail.mit.edu/download.html)
  say, verbatim: "You will use the data only for non-commercial research and educational
  purposes. You will NOT distribute the above images." The live site was unreachable from
  our network (connection refused). A 2023 capture says the legacy dataset is available
  "for research purposes" via a form.
- Model size: 208 MB fp32 ONNX (Carve/LaMa-ONNX, fixed 512×512 input), so roughly 52M
  parameters.
- Training-time dependency: LaMa's "high receptive field perceptual loss" uses a
  segmentation network pretrained on ADE20K. A clean-room retrain must swap it for a loss
  network with clean provenance (see Risks).
- Verdict: **Fine-tune only** (retrain from scratch).

**Core ML ports of LaMa.**
- Evidence: `mlboydaisuke/LaMa-CoreML` (HF, card license apache-2.0): 187 MB, 800×800
  input, "Peak RAM ~600 MB", minimum iOS 17, compute units `all`.
- `mallman/CoreMLaMa` (Apache-2.0) converts Big-LaMa. Its README: "runs well on macOS, on
  the GPU. I have received several reports of unsuccessful attempts to run this model on
  iOS, especially with fp16 precision on the Neural Engine."
- `john-rocky/lama-cleaner-iOS` (MIT) is a sample app.
- All of these redistribute Places-trained weights, so none is shippable.
- Assessment: the FFT ops probably keep LaMa off the Neural Engine and on the GPU. We need
  to time it on the M1 Ultra and an A17 Pro (not done in this pass).

**MI-GAN** (Sargsyan et al., ICCV 2023, "A Simple Baseline for Image Inpainting on Mobile
Devices", https://github.com/Picsart-AI-Research/MI-GAN).
- Code: `LICENSE` MIT, and `LICENSE-WEIGHTS` is also MIT. However, the repo vendors NVIDIA
  `torch_utils/` files whose headers say "Any use, reproduction, disclosure or distribution
  ... without an express license agreement from NVIDIA CORPORATION is strictly prohibited".
  They are imported by `migan.py` (`upfirdn2d`, `conv2d_resample`) but not by
  `migan_inference.py`.
- Data: Places2 (256/512) and FFHQ. MI-GAN is distilled from a Co-Mod-GAN teacher, which
  itself uses NVIDIA NC code.
- Size: ONNX 29.5 MB (`andraniksargsyan/migan`), roughly 7M parameters. The README claims
  "one order of magnitude smaller and faster than recent SOTA approaches".
- Verdict: MIT weights, but NC training data. **Fine-tune only** (retrain from scratch, and
  reimplement the model code from the paper).

**MAT** (Li et al., CVPR 2022, arXiv:2203.15270).
- Repo `LICENSE` is "Creative Commons Attribution-NonCommercial 4.0 International".
- Verdict: **Research-only**.

**CoModGAN** (Zhao et al., ICLR 2021, arXiv:2103.10428, https://github.com/zsyzzsoft/co-mod-gan).
- Own code is BSD-3-style, but the bundled "LICENSE FOR stylegan2" is "Nvidia Source Code
  License-NC": "The Work and any derivative works thereof only may be used or intended for
  use non-commercially."
- Verdict: **Avoid** (code); weights **Research-only**.

**FcF** (Jain et al., WACV 2023, arXiv:2208.03382, https://github.com/SHI-Labs/FcF-Inpainting).
- Apache-2.0 "except for the third-party components". It includes stylegan2-ada-pytorch
  under the NVIDIA Source Code License: "'non-commercially' means for research or
  evaluation purposes only."
- Trained on Places2 and CelebA-HQ.
- Verdict: **Research-only**.

**ZITS / ZITS++** (arXiv:2203.00867, 2210.05950).
- Code: Apache-2.0 (GitHub API).
- Trained on Places2 and others.
- Verdict: **Fine-tune only**. The multi-stage transformer plus line/edge priors is heavy
  for on-device use.

**MISF** (arXiv:2203.06304, https://github.com/tsingqguo/misf).
- **No license file** (GitHub API `license: null`), so all rights are reserved.
- Verdict: **Research-only / UNCLEAR**.

**CM-GAN** (Adobe, arXiv:2203.11947).
- Repo is Apache-2.0 (GitHub API). The object-aware training uses Places2.
- A related Samsung application, "Object removal with fourier-based cascaded modulation
  gan" (US20250173835A1), is **Pending** on Google Patents.
- Verdict: **Fine-tune only**, with a patent watch.

**AOT-GAN** (Apache-2.0).
- Trained on Places2, CelebA-HQ and others.
- Verdict: **Fine-tune only**.

**Feature refinement for high resolution** (Geomagical, arXiv:2206.13644, repo
`geomagical/lama-with-refiner`, Apache-2.0).
- Optimizes intermediate feature maps at inference against a multiscale consistency loss.
- Assessment: this needs gradients at inference time. That is not possible in Core ML; it
  would need MPSGraph autodiff and costs tens of forward/backward passes. It is a Mac-only
  "HD quality" option at best.

### 1.2 Diffusion and large editing models

| Model | Weights license (verbatim / source) | Data | Fit |
|---|---|---|---|
| SD 1.5 inpainting (`stable-diffusion-v1-5/stable-diffusion-inpainting`) | `creativeml-openrail-m` (HF cardData); use-based restrictions must flow down | "440k steps of inpainting training at resolution 512x512 on 'laion-aesthetics v2 5+'" (model card) | ~1B params; Core ML conversions exist (e.g. `jc-builds/sd-v1-5-inpainting-coreml`). LAION provenance risk |
| SD 2 inpainting (`stabilityai/stable-diffusion-2-inpainting`) | HF API returns "Invalid username or password", so the repo is gone or private (checked 2026-09-29) | LAION-5B subsets | UNCLEAR availability |
| SDXL inpainting 0.1 (`diffusers/...-inpainting-0.1`) | `openrail++` | LAION-derived | 2.6B UNet; Mac only |
| SD 3.5 Large/Medium | Stability Community License: free only for those "generating annual revenue of less than US $1,000,000"; above that "any licenses granted ... shall terminate" (https://stability.ai/community-license-agreement) | undisclosed | Revenue cap is incompatible with an open-source App Store product |
| FLUX.1 Fill [dev], Kontext [dev], FLUX.2 [dev] | FLUX [dev] Non-Commercial License: "use ... in direct interactions with or that has impact on end users ... is not a Non-Commercial Purpose" (https://bfl.ai/legal/non-commercial-license-terms) | undisclosed | **Research-only** |
| FLUX.2 [klein] 4B | Apache-2.0 ("Open weights available for commercial use", HF card) | **undisclosed** | 4B params, "~13GB VRAM"; multi-reference editing, not mask inpainting. UNCLEAR data; Mac-only experiment |
| Qwen-Image-Edit(-2509) | Apache-2.0 (HF cardData) | undisclosed | ~20B; not on-device |
| BrushNet (TencentARC) | Code "licensed under the Apache License Version 2.0 except for the third-party components" | built on SD 1.5/SDXL | Inherits base-model terms |
| PowerPaint (open-mmlab) | Code MIT; HF `JunhaoZhuang/PowerPaint-v2-1` tagged apache-2.0 | built on SD 1.5 | Inherits OpenRAIL-M + LAION |
| CommonCanvas-XL-C | `cc-by-sa-4.0` (HF) | CommonCatalog CC-BY images | Text-to-image only. Could be fine-tuned into an inpainter; BY-SA ShareAlike/DRM clause is an App Store risk |

Assessment:
- Diffusion is the wrong tool for *removal*. It hallucinates objects, is non-deterministic
  unless seeds and numerics are pinned, costs seconds to tens of seconds per region on
  device, and every candidate has a license or provenance problem.
- It is only compelling for "generative fill / expand" (adding content). We should defer
  that. If we ever do it, it should be Mac-only and trained or fine-tuned on
  public-domain data.

### 1.3 Apple-provided options

- Evidence: we scanned the full DocC symbol indexes
  (`https://developer.apple.com/tutorials/data/index/<framework>`) for Vision, Core Image,
  ImageIO, PhotoKit, AVFoundation, CoreMedia and ImagePlayground. We searched for
  inpaint/cleanup/removal/C2PA/provenance and got **zero matches**. The Photos app's
  "Clean Up" has no public API. Image Playground is prompt-to-image generation, not
  mask-based removal.
- Useful Vision building blocks for D (from DocC JSON):
  - `GeneratePersonInstanceMaskRequest`: iOS 18 / macOS 15.
  - `GenerateForegroundInstanceMaskRequest`.
  - `DetectLensSmudgeRequest`: iOS/macOS 26, "requires a device with A14 Bionic and later
    or device with M1 and later".
  - `GenerateIterativeSegmentationRequest`: **iOS/macOS 27.0**, "generates a segmentation
    mask from points, a rectangle, or a scribble". It is useful for "brush to select a
    distraction", but it is above our 26 floor, so it needs `if #available` gating and a
    SAM fallback from workstream C.
  - Apple also introduced **Core AI** (iOS/macOS 27.0, "Run AI models in your app on
    Apple silicon"). Runtime choice is a shared-infrastructure question.
- Verdict: Apple gives us masks, not fills.

### 1.4 Quality, speed and resolution on device

- Evidence:
  - LaMa is trained at 256 px (Places) and 512 px crops.
  - IOPaint (`Sanster/IOPaint`, Apache-2.0, archived 2025) exposes "HD strategies":
    Original, Resize and Crop.
  - The Core ML LaMa port runs at 800×800 with ~600 MB peak RAM.
  - MI-GAN is about 7x smaller than Big-LaMa by file size.
- Assessment on quality:
  - **Small to medium regions** (sensor dust, blemishes, a person under ~10% of the frame,
    wires): a LaMa-class model inside a crop-around-mask window matches Lightroom's
    non-generative Remove.
  - **Large regions with structure** (a car across a façade, a tourist in front of
    railings): LaMa's periodic-structure completion clearly beats patch methods. It still
    loses to diffusion when there is no plausible nearby texture to continue.
- Recommended high-resolution strategy (engine-side, tiled, cancellable):
  1. Take the mask's bounding box and dilate it by max(64 px, 1.5× the mask radius) to get
     a context crop.
  2. Downscale the crop so the long side is ≤1024 (or 512 on iPhone). Run the network in a
     display-referred encoding: exposure-normalized linear to a log/sRGB-like transfer,
     because the networks are trained on sRGB.
  3. Upscale the fill, invert the transfer back to scene-linear, and composite only inside
     the feathered mask.
  4. Restore high frequencies. Add luminance texture by guided upsampling from the
     low-resolution fill, and add **synthetic sensor noise from our workstream-A noise
     profile** so the filled area is not "too clean" in high-ISO files.
  5. Blend the seam with a Poisson/membrane solve (section 3).
  6. For very large masks, iterate coarse to fine: a 512 pass for structure, then a
     1024 crop pass seeded with the upsampled coarse result.
- Assessment on performance (unmeasured, needs a prototype):
  - A ~50M-parameter FFC network at 512² on an M-series GPU should take well under 1 s.
  - An ~7M-parameter all-conv MI-GAN-class model should be ANE-friendly and fast on the
    A17 Pro.
  - Budget P3-lane inference at ≤2 s per region on the iPhone floor.
- Pipeline placement and reproducibility:
  - Healing and fill run as a retouch stage in scene-linear space after
    demosaic/denoise and before tone and color edits. Later slider moves then apply
    consistently to the filled pixels, which is how Lightroom behaves.
  - Because ANE, GPU and OS versions can change numerics, we **cache the filled patch**
    (bounding box only, half-float, compressed) keyed by (model id+version, source
    hash, mask hash, seed). We store it as a sidecar resource, like AI masks. Re-rendering
    on another device uses the cached patch and never re-infers silently.

## 2. Distraction detection

| Distraction | Classical enough? | Model needed? | Recommended route |
|---|---|---|---|
| Sensor dust | **Yes** | No (optional) | Per-image blob detector plus cross-shoot consistency; "Visualize Spots" view |
| Extra people | Partly (ranking) | Yes (masks) | Vision person instance masks plus a heuristic "main subject vs. background people" ranker; fill with our inpainter |
| Power lines / wires | No | Yes | Train our own thin-structure segmenter on **synthetic wires** rendered on PD imagery; tile-based fill |
| Window reflections | No | Yes, and hard | Defer; license-clean data does not exist |
| Lens smudge (capture QA) | — | Apple API | `DetectLensSmudgeRequest` (26+) as a culling hint, not removal |

**Dust.** Evidence: Adobe Camera Raw 17.5 (August 2025) added "Automatically detect and
remove spots created by dust on your camera's sensor". 17.4 (June 2025) added "Quickly
remove extra people" and "Automatically detect and remove reflections caused by glass
windows" (Camera Raw "What's new", Wayback capture 2025,
`https://helpx.adobe.com/camera-raw/using/whats-new.html`). So these three are now table
stakes for Lightroom users.

Assessment: dust is a classical problem, and a strong one:
1. **Physics.** A dust shadow is a soft, roughly circular, *multiplicative* attenuation
   (a few percent to ~20%) at a fixed **sensor** position. It is sharper and smaller at
   small apertures (f/11 and narrower) and nearly invisible wide open. Its apparent
   position shifts slightly and radially with exit-pupil distance, which depends on lens
   and focal length.
2. **Per-image detection.** Work in log-luminance of the linear, pre-crop, pre-geometry
   image. Apply a band-pass (difference of Gaussians) tuned to a 5–60 px radius. Keep
   blobs with negative contrast, roundness, low chroma change (dust is near-neutral), and
   local smoothness of the surroundings (sky and walls). The false-positive guard is a
   texture/edge-energy mask.
3. **Cross-shoot consistency** (our differentiator). Accumulate candidates in sensor
   coordinates across all images from the same body within a time window. Spots that
   recur at the same position (± the radial shift predicted from f-number and focal length)
   with consistent attenuation are dust with high confidence. This also lets us detect
   spots in busy images where single-image detection fails.
4. **"Visualize Spots".** Show a thresholded, normalized high-pass (Lightroom's
   equivalent). It is a one-pass Metal kernel with a slider.
5. **Removal.** Most dust can be removed by *division* (flat-field style gain correction
   estimated from the ring around the spot), not by inpainting. This preserves real
   texture under the spot. Fall back to heal or inpaint for dense or opaque spots.

**People.**
- Vision gives person instance masks. Apple's WWDC23 material described a small maximum
  instance count; we did not re-verify the exact limit.
- Ranking "distracting" people is heuristic: size, distance from frame center and focus
  point, defocus (local sharpness), saliency (`GenerateAttentionBasedSaliencyImageRequest`),
  and whether the person overlaps the main subject mask.
- Adobe US9665962B2 "Image distractor detection and processing" is **Active**, anticipated
  expiration 2035-07-29. Our ranking must be designed from first principles, and counsel
  should compare it to the claims before we ship it.

**Wires.**
- Evidence: Chiu et al., "Automatic High Resolution Wire Segmentation and Removal"
  (CVPR 2023, arXiv:2304.00221, Adobe + UIUC). It uses a two-stage global+local segmenter
  and "a tile-based inpainting strategy". Only test images of the WireSegHR dataset were
  released (https://github.com/adobe-research/auto-wire-removal). The repo has **no
  license** (GitHub API `license: null`) and no code, so it is **UNCLEAR** and should not
  be used even for evaluation without permission.
- TTPLA (https://github.com/R3ab/ttpla_dataset) has an Apache-2.0 repo, but the images
  are aerial transmission-tower frames on Google Drive with no separate image terms. That
  makes the images **UNCLEAR**, and they are a domain mismatch for ground-level photos.
- Assessment: wires are the one distraction where **synthetic data is excellent**. Render
  catenary curves with random thickness (1–12 px), sag, defocus blur, JPEG/noise,
  sky-dependent color and occasional insulators onto PD12M and Megalith sky/landscape
  images, and add a few hundred hand-labelled own photos for validation. A small
  high-resolution-friendly segmenter (U-Net on tiles plus a global low-resolution branch,
  as in the paper's idea) is enough.

**Reflections.**
- Code licenses are fine: ERRNet (MIT), IBCLN (BSD-2-Clause), DSRNet and YTMT (Apache-2.0),
  and perceptual-reflection-removal (Apache-2.0). RDNet (CVPR 2025) has **no license**.
- Training data is PASCAL VOC-style synthetic blends plus small real pair sets with
  unclear terms, so weights are **UNCLEAR**. Quality on real window photos is still
  inconsistent in the literature.
- Assessment: **defer**. If pursued later, capture our own real pairs (glass in / glass
  out on a tripod) plus synthetic blends on PD imagery.

## 3. Classical healing, and where AI wins

- Evidence: **Poisson image editing** (Pérez, Gangnet, Blake, SIGGRAPH 2003, DOI
  10.1145/882262.882269) is covered by Microsoft **US6856705B2** "Image blending by guided
  interpolation". Google Patents shows it as **Expired - Fee Related** (adjusted expiration
  2023-06-08).
- Adobe's **Healing Brush** patent **US6587592B2** "Generating replacement data values for
  an image region" (Georgiev, Hamburg, Chien) is **Expired - Lifetime**. Adobe
  **US7512288B1** "Image blending using non-affine interpolation" is also **Expired -
  Lifetime**.
- Recommended classical toolset (Phase 3, no PatchMatch):
  1. **Clone**: a user-chosen source offset with a feathered alpha.
  2. **Heal**: clone plus a Poisson/membrane correction. Solve the Laplace equation for
     the boundary mismatch on the GPU with a multigrid or Jacobi solver on the mask
     bounding box. This is effectively Healing Brush behavior, and those patents are
     expired.
  3. **Auto-source for Heal**: an **exhaustive** GPU search for the best source offset.
     Compute the SSD of a boundary ring over candidate offsets in a limited window at 1/4
     resolution, then refine at full resolution. This is plain template matching. For
     brush-sized regions it is cheap on Metal and avoids PatchMatch's randomized
     propagation and search, which is what US8285055B1 claims.
  4. **Exemplar fill for tiny regions**: Criminisi-style priority-ordered patch filling.
     Microsoft **US6987520B2** is Expired - Fee Related (adjusted expiration 2023-03-30),
     and the companion **US7088870B2** "example-based tiling" is also expired. This is
     optional, because the learned inpainter supersedes it.
- Where AI clearly wins (assessment): large holes (more than ~2–3% of the frame, or wider
  than ~100 px at 24 MP); regions crossing **structure** (lines, edges, repeated
  architecture) where the inpainter's global receptive field continues geometry; semantic
  context (removing a person from a bench should produce *bench*); and one-click automatic
  flows (people, wires) where no user picks a source.
- Where classical wins or ties: dust and small blemishes (division or heal keeps true
  texture and grain); skin retouching with a user-chosen source; exact reproducibility
  (classical is deterministic, bit-exact and cheap to re-render, so nothing needs caching);
  and high-ISO grain continuity.

## 4. Patent notes

Source: Google Patents pages (https://patents.google.com/patent/<number>/en), fetched
2026-09-29. Google notes "The legal status is an assumption and is not a legal conclusion."
We did not check USPTO maintenance-fee records.

| Patent | Title / scope | Assignee | Status | Expiry (per Google) |
|---|---|---|---|---|
| US8285055B1 | "Determining correspondence between image regions". Claim 1 is the PatchMatch loop: propagate from "mappings of nearby pixels" and select from a "third mapping obtained by perturbing" | Adobe | **Active** | 2031-04-09 (adjusted) |
| US8811749B1 | Continuation, same title | Adobe | **Active** | 2029-04-27 |
| US8571328B2 | Same title (Generalized PatchMatch, with Princeton) | Adobe | **Active** | 2031-10-19 |
| US8861869B2 | Same title (continuation of US8571328) | Adobe | **Active** | 2030-08-16 (anticipated) |
| US8355592B1 | "Generating a modified image with semantic constraint" (constrained PatchMatch fill) | Adobe | **Active** | 2031-08-12 |
| US9317773B2 | "Patch-based synthesis techniques using color and color gradient voting" | Adobe | **Active** | 2032-08-02 (anticipated) |
| US9396530B2 | "Low memory content aware image modification" | Adobe | **Active** | 2034-10-15 |
| US10467739B2 | "Content aware fill based on similar images" | Adobe | **Active** | 2035-05-19 |
| US10074033B2 | "Using labels to track high-frequency offsets for patch-matching algorithms" | Adobe | **Active** | 2037-01-24 |
| US9665962B2 | "Image distractor detection and processing" | Adobe | **Active** | 2035-07-29 (anticipated) |
| US6856705B2 | Poisson "Image blending by guided interpolation" | Microsoft | Expired - Fee Related | (2023-06-08) |
| US6987520B2 | "Image region filling by exemplar-based inpainting" (Criminisi) | Microsoft | Expired - Fee Related | (2023-03-30) |
| US7088870B2 | "Image region filling by example-based tiling" | Microsoft | Expired - Fee Related | (2023-10-19) |
| US6587592B2 | Healing Brush, "Generating replacement data values for an image region" | Adobe | Expired - Lifetime | — |
| US20250173835A1 | "Object removal with fourier-based cascaded modulation gan" | Samsung | **Pending** | — |

Assessment:
- Do **not** implement PatchMatch (randomized init plus propagation plus random search)
  or Adobe-style content-aware fill in the shipping product before ~2031–2032 without a
  freedom-to-operate opinion. Our alternatives do not match claim 1: exhaustive GPU
  template search, learned inpainting, and expired Criminisi and Poisson methods.
- Watch the Samsung FFC-GAN application if we adopt an FFC-plus-cascaded-modulation
  architecture.
- Newer Adobe filings exist around learned inpainting, for example US20250139748A1 "deep
  visual guided patch match models for image inpainting" and US20230368339A1. Counsel
  should review a claim map before Phase 3 ships.

## 5. Generative content policy (C2PA / Content Credentials)

- Evidence on the specification: C2PA **2.4, "April 2026"** (version history in
  https://spec.c2pa.org/specifications/specifications/2.4/specs/C2PA_Specification.html).
  Relevant parts:
  - Pre-defined actions include `c2pa.opened`, `c2pa.adjustedColor` ("Changes to tone,
    saturation, etc."; `c2pa.color_adjustments` is deprecated), `c2pa.cropped`,
    `c2pa.edited` ("editorial transformations"), `c2pa.enhanced` ("noise reduction ...
    sharpening ... non-editorial") and `c2pa.drawing`.
  - Actions v2 has a `changes` field: "A list of the regions of interest of the resource
    that were changed". Region roles include `c2pa.edited` and `c2pa.deleted`.
  - `digitalSourceType` uses IPTC terms such as `trainedAlgorithmicMedia` and
    `compositeWithTrainedAlgorithmicMedia`.
  - 2.4 adds an **AI Model Disclosure** assertion (`modelName`, `modelIdentifier`, ...).
  - A signer is "trusted" by validators only if its certificate chains to the **C2PA
    Trust List**.
- Evidence on SDKs:
  - `contentauth/c2pa-rs` (workspace version 0.92.0-dev): "distributed under the terms of
    both the MIT license ... and the Apache License (Version 2.0)" (crate
    `license = "MIT OR Apache-2.0"`). Its `deny.toml` allows only permissive licenses plus
    MPL-2.0 for dependencies.
  - `contentauth/c2pa-swift` (Apache-2.0): "iOS 16.0+ / macOS 14.0+", Swift
    Package/XCFramework, "Hardware-backed signing with Secure Enclave".
  - `c2patool` is Apache-2.0 and `c2pa-js` is MIT.
- Evidence on Apple: no C2PA or Content Credentials symbols in any Apple framework index we
  scanned (section 1.3). We found no public statement of platform support. Treat Apple as
  providing **none**. We could not load the c2pa.org member list (rendered client-side).

**Recommended policy.**
1. **Always label internally.** Every learned-fill region gets a visible "Generated fill"
   chip in the Heal/Remove panel and in edit history, with the model id and version
   (this is already required for reproducibility). Classical heal/clone/dust is labeled
   "Retouch".
2. **Export option "Include Content Credentials"**, off by default globally. It becomes
   **pre-checked, with a one-line explanation, whenever the image contains generated
   fill**. The user can still uncheck it (their files, their choice), but the default
   nudges toward honesty.
3. **Manifest content:**
   - `c2pa.opened` with the raw as ingredient. Preserve any camera-signed manifest as the
     parent ingredient.
   - `c2pa.adjustedColor` / `c2pa.cropped` for global edits.
   - `c2pa.edited` with `changes` region-maps for classical retouch, and no AI source
     type.
   - For learned fill: `c2pa.edited` with `digitalSourceType =
     compositeWithTrainedAlgorithmicMedia`, `changes` regions, and an AI Model Disclosure
     assertion naming our model.
   - The software agent is "Redlamp <version>".
   - **No personal identity by default** (privacy); an optional CAWG identity comes later.
4. **Also write** the XMP `Iptc4xmpExt:DigitalSourceType` when fill is present. It is
   cheap and read by more tools than C2PA.
5. **Signing:** v1 signs with a per-device Secure Enclave key and a self-issued
   certificate. Validators will show "unrecognized signer", but the history is still
   tamper-evident. Getting on the C2PA Trust List needs a CA-issued certificate and
   conformance work, and it conflicts with our no-server stance. That is a product
   decision for later.
6. Classical-only edits are never described as "AI". Learned inpainting **is** AI and is
   disclosed even though it is not text-prompted. That is the trustworthy line for a
   photographer's tool.

## 6. Shortlist

| Candidate | Code license | Weights license | Data | Quality evidence | Apple Silicon fit | Verdict |
|---|---|---|---|---|---|---|
| Classical Heal/Clone + Poisson | ours | n/a | n/a | Expired Healing Brush / Poisson art | Metal, ms per region | **Build (P3)** |
| Dust detector (per-image + cross-shoot) | ours | n/a | own captures | Matches Camera Raw 17.5 feature | Metal, one pass | **Build (P3)** |
| LaMa architecture retrained (ours) | Apache-2.0 (advimman/lama) | ours | PD12M, Megalith-10M, own | LaMa paper; high-res generalization | GPU likely (FFT); ~50M params, ~100 MB fp16 | **Build (P3/P4)** |
| MI-GAN architecture retrained (ours) | MIT (reimplement; avoid NVIDIA files) | ours | same | ICCV 2023 mobile baseline | ~7M params, ANE-friendly (assessment) | **Build, iPhone tier** |
| Big-LaMa released weights | Apache-2.0 | none stated (HF tag apache-2.0) | Places (NC) | strong | runs via Core ML ports | **Research-only benchmark** |
| MAT | CC BY-NC 4.0 | same | Places/CelebA-HQ | strong at large holes | heavy transformer | Research-only |
| CoModGAN / FcF | NVIDIA NC parts | — | Places | good | — | Avoid / Research-only |
| SD 1.5 / SDXL inpainting | OpenRAIL-M / ++ | same | LAION | good generative fill | 1–2.6B; Mac-only | Defer (provenance risk) |
| FLUX Fill/Kontext dev | NC | NC | undisclosed | state of the art | too big | Research-only |
| FLUX.2 klein 4B | Apache-2.0 | Apache-2.0 | **undisclosed** | editing, not removal | 13 GB VRAM | UNCLEAR; watch |
| Vision person masks | Apple API | — | — | production | ANE | **Adopt** |
| Wire segmenter (ours) | ours | ours | synthetic on PD images | Chiu 2023 shows feasibility | small U-Net, tiled | **Build (P4)** |
| Reflection removal nets | MIT/BSD/Apache | UNCLEAR | VOC synth etc. | inconsistent | — | Defer |
| c2pa-rs / c2pa-swift | MIT OR Apache-2.0 / Apache-2.0 | n/a | n/a | reference SDK | Swift package | **Adopt** |

## 7. License matrix

| Candidate | Code license (source) | Weights license (source) | Training data (terms) | Obligations (attribution, patents) | Verdict |
|---|---|---|---|---|---|
| LaMa / Big-LaMa | Apache-2.0 (github.com/advimman/lama, API) | Unstated upstream; HF `smartywu/big-lama` tag apache-2.0 | Places365/Challenge: "only for non-commercial research and educational purposes" (Wayback 2021-02-20) | Apache NOTICE; ADE20K loss net provenance | Fine-tune only (retrain) |
| LaMa Core ML ports | Apache-2.0 (mallman/CoreMLaMa); MIT (lama-cleaner-iOS) | Card says apache-2.0 (mlboydaisuke/LaMa-CoreML), derived from Places weights | Places (NC) | — | Research-only |
| MI-GAN | MIT (LICENSE) + NVIDIA "strictly prohibited" headers in torch_utils | MIT (LICENSE-WEIGHTS) | Places2 (NC), FFHQ (per-image CC incl. BY-NC), Co-Mod-GAN teacher | Reimplement, avoid NVIDIA files | Fine-tune only (retrain) |
| MAT | CC BY-NC 4.0 (repo LICENSE) | CC BY-NC 4.0 | Places, CelebA-HQ | NC | Research-only |
| CoModGAN | BSD-style + "Nvidia Source Code License-NC" | unstated | Places, FFHQ | NC | Avoid |
| FcF | Apache-2.0 except stylegan2-ada (NVIDIA: "research or evaluation purposes only") | unstated | Places, CelebA-HQ | NC parts | Research-only |
| ZITS / ZITS++ | Apache-2.0 (API) | unstated | Places2 etc. | — | Fine-tune only |
| MISF | none (API null) | unstated | Places2 etc. | all rights reserved | Research-only (UNCLEAR) |
| CM-GAN | Apache-2.0 (API) | unstated | Places2 | Samsung FFC-GAN application pending | Fine-tune only |
| SD 1.5 inpainting | CreativeML OpenRAIL-M | OpenRAIL-M (HF) | LAION-aesthetics v2 5+ | Use restrictions flow down; data provenance | Defer / UNCLEAR |
| SDXL inpainting 0.1 | — | openrail++ (HF) | LAION-derived | same | Defer / UNCLEAR |
| SD 3.5 | — | Stability Community License, US$1M revenue cap | undisclosed | registration, cap | Avoid |
| FLUX.1 Fill/Kontext [dev], FLUX.2 [dev] | — | FLUX [dev] Non-Commercial | undisclosed | NC | Research-only |
| FLUX.2 [klein] 4B | Apache-2.0 | Apache-2.0 (HF) | undisclosed | — | UNCLEAR (data) |
| BrushNet | Apache-2.0 "except for the third-party components" | on SD bases | LAION via base | inherits | Defer |
| PowerPaint | MIT (API) | apache-2.0 tag (HF) on SD 1.5 | LAION via base | inherits OpenRAIL-M | Defer |
| CommonCanvas-XL-C | — | CC BY-SA 4.0 (HF) | CommonCatalog CC-BY | BY-SA incl. "no Effective Technological Measures" | UNCLEAR (App Store DRM) |
| IOPaint (lama-cleaner) | Apache-2.0 (archived) | bundles third-party weights | various | reference for HD strategy only | Research/reference |
| Reflection: ERRNet / IBCLN / DSRNet | MIT / BSD-2-Clause / Apache-2.0 | unstated | VOC synthetic + small real sets | — | Fine-tune only |
| RDNet | none | unstated | — | — | Research-only |
| WireSegHR test set | no license, no code | — | Adobe-collected | ask Adobe | UNCLEAR |
| TTPLA | Apache-2.0 (repo) | YOLACT models | aerial images, no image terms | — | UNCLEAR |
| c2pa-rs | MIT OR Apache-2.0 | n/a | n/a | notices | Shippable |
| c2pa-swift | Apache-2.0 | n/a | n/a | NOTICE | Shippable |

## 8. Recommendations and effort (engineer-weeks)

| Item | Phase | Decision | Effort |
|---|---|---|---|
| Clone + Heal (Poisson/multigrid), brush UX, exhaustive auto-source, sidecar ops | P3 | Build | 5–7 ew |
| Dust: detector, cross-shoot accumulation in sensor space, division-based removal, Visualize Spots | P3 | Build | 3–4 ew |
| Inpainting data pipeline (PD12M + Megalith download and filtering, mask generator for object-shaped, thick-stroke and wire masks) | P3 | Build | 2–3 ew |
| Train LaMa-class inpainter (clean-room code, clean perceptual loss), eval harness (FID/LPIPS on held-out PD images plus blind A/B) | P3→P4 | Build | 6–8 ew + compute (assessment: on the order of 1–3k A100 GPU-hours for ~50M params at 256–512 px) |
| MI-GAN-class distilled student for iPhone | P4 | Build | 3–4 ew + ~0.5k GPU-hours |
| Core ML/Metal integration: crop-around-mask, coarse-to-fine, noise re-synthesis, patch cache and versioning | P3 | Build | 3–4 ew |
| Remove People (Vision masks + ranker + fill) | P4 | Build | 2–3 ew |
| Wire segmentation (synthetic data + model + tiled fill) | P4 | Build | 5–7 ew |
| C2PA export (c2pa-swift, manifest builder, UI badge, XMP DigitalSourceType) | P3 | Adopt SDK | 2–3 ew |
| Reflection removal | — | Defer | (8+ ew if revived) |
| Diffusion "generative fill/expand" | — | Defer | — |

Interim (before our model lands):
- Ship Heal/Clone/Dust plus Remove using classical fill for small regions.
- Label large-region removal as "coming".
- Do **not** ship Places-trained weights, even as an "experimental" download.

## 9. Risks and open questions

1. **Training provenance of our own model.**
   - PD12M's metadata is CDLA-Permissive-2.0 and it claims "entirely public domain and
     CC0 licensed images".
   - Megalith-10M lists Flickr "No known copyright restrictions", US Gov, CC0 and PDM,
     but warns "conduct your own independent analysis".
   - We need a filtering and audit pass: drop watermarks, people's faces if desired, and
     artworks.
2. **Loss-network provenance.** LaMa's high receptive field perceptual loss uses an
   ADE20K-pretrained segmenter. We must replace it with one trained on data we have rights
   to, or accept a legal opinion that loss networks do not taint weights. Open question
   for counsel.
3. **ShareAlike / DRM.** CC BY-SA 4.0 assets (CommonCanvas weights, HDR+ and Intel-TAU
   data in workstream E) include "You may not ... apply any Effective Technological
   Measures". The interaction with App Store FairPlay needs counsel.
4. **Patents.** We need a PatchMatch freedom-to-operate opinion, a review of US9665962B2
   (distractor detection) against our people ranker, and a watch on the Samsung FFC-GAN
   application.
5. **Numerics drift** across ANE, GPU and OS versions. Mitigated by caching filled
   patches, but this adds sidecar size (assessment: tens to hundreds of KB per region).
6. **Quality bar.** Users will compare against Lightroom Generative Remove (Firefly,
   cloud). A LaMa-class model will lose on large semantic fills. Mitigate with a
   multi-candidate UI (3 seeds/variants) and honest positioning ("on-device, private").
7. **Unverified in this pass:** LaMa and MI-GAN latency on M1 Ultra and A17 Pro; Vision
   person-instance limit; USPTO maintenance status of the Adobe patents; the live Places2
   terms page (unreachable).

## 10. Test data (with licenses)

| Set | Use | License / terms | OK for us? |
|---|---|---|---|
| Own captures: dusty-sensor sequences at f/2.8–f/22 on sky/walls, several bodies | dust detector | ours | Yes |
| raw.pixls.us | raw-domain heal/fill tests across cameras | uploads declared "into the public domain" under CC0 (upload form) | Yes |
| PD12M held-out split + synthetic masks | inpainting eval (FID/LPIPS) | CDLA-Permissive-2.0 metadata; PD/CC0 images | Yes |
| Megalith-10M held-out | inpainting eval | MIT list; Flickr PD/CC0/no-known-restrictions | Yes, after audit |
| Own "distraction" set: 300–500 photos with people, wires, signs, labelled masks | end-to-end eval | ours | Yes |
| Places365 val | literature comparison only | "non-commercial research and educational purposes" | Research-only; avoid for product decisions |
| WireSegHR test | wire benchmark | no license | Ask Adobe first |
| TTPLA | wire/pylon | repo Apache-2.0, image terms absent | UNCLEAR |
| CelebA-HQ / FFHQ | faces | NC / per-image incl. BY-NC ("free use ... for non-commercial purposes") | Research-only |
