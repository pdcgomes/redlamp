# E. Auto adjustments and personalization

Research notes for workstream E of the [brief](../ai-and-computational-photography-brief.md).
Licenses, dataset terms and API facts checked 2026-09-29. "Evidence" = cited primary source;
"Assessment" = our judgement.

## Summary

- **The benchmark datasets cannot train a shippable model.**
  - MIT-Adobe FiveK: "solely for your own research purposes".
  - PPR10K: "non-commercial research purposes only".
  - For white balance, only **Cube++** (CC BY 4.0) is cleanly commercial.
  - **Intel-TAU** and **HDR+** are CC BY-SA 4.0: commercial use is allowed, with
    ShareAlike and DRM caveats.
  - Gehler-Shi, NUS 8-camera and Cube+ publish no license, so they are **UNCLEAR**.
- **Most model code is permissive.** HDRNet, Image-Adaptive 3D LUT, AdaInt, SepLUT, FFCC
  and C5 are Apache-2.0; NILUT, DeepLPF, FC4, Exposure and StarEnhancer are MIT. Every
  released checkpoint was trained on the NC datasets above, so all are **Fine-tune only**
  (retrain).
- **Recommendation for auto tone/WB: improve the heuristic now, then learn a small
  recipe-parameter predictor on our own expert-edited raws.** Do not use a pixel-output
  network for Auto.
  - The current heuristic (`ImageAnalysis.autoTone`: log-average exposure plus percentile
    tails; `autoWhiteBalance`: gray-world over well-exposed pixels blended with a
    bright-neutral estimate) is a sound base.
  - Phase 2–3: add a classical color-constancy ensemble (shades-of-gray, gray-edge,
    bright-pixels, FFCC-style histogram) and scene-aware tone rules.
  - Phase 4: a learned parameter head.
- **Personalization: build it on device with predicted slider values, not pixels.** Use
  Vision feature prints and image statistics as features, kernel-regression/kNN on the
  user's own edits for the first ~20 examples, then a per-slider residual regressor. Create
  ML's `MLBoostedTreeRegressor` and `MLLinearRegressor` are available on iOS 15+ and
  macOS 10.14+; Core ML `MLUpdateTask` is not deprecated. Everything stays local, and the
  output is ordinary recipe values.
- **Adaptive profile:**
  - Adobe's documented "Adaptive: Color / B&W" is image-adaptive, raw-only, has an Amount
    of 0–200, and "is most effective when used with raw HDR files". It must be "updated"
    after Remove/Heal, rotate/flip or Lens Blur, so it is a cached, image-computed
    result.
  - We can build an equivalent as a cached parameter set: local tone mapping strength,
    scene key, semantic-region adjustments via Vision/SAM masks, and learned global
    parameters.

## 1. Learned auto tone and auto white balance

### 1.1 Datasets (the binding constraint)

**MIT-Adobe FiveK** (Bychkovsky et al., CVPR 2011; https://data.csail.mit.edu/graphics/fivek/).
- 5,000 DNGs with five experts' Lightroom edits.
- Page: "You can use these photos for research under the terms of the following
  licenses". Both `legal/LicenseAdobe.txt` and `legal/LicenseAdobeMIT.txt` say: "You may
  only exercise these rights granted to you solely for your own research purposes, and you
  shall not exercise any of these rights in any manner that is intended for or directed
  toward commercial advantage or monetary compensation."
- Verdict: **Research-only**. Even internal benchmarking that informs a commercial product
  is arguably "directed toward commercial advantage", so ask counsel before using it even
  as a benchmark.

**PPR10K** (Liang et al., CVPR 2021, arXiv:2105.09180).
- README "Agreement": "All files in the PPR10K dataset are available for ***non-commercial
  research purposes*** only. You agree not to ... exploit for any commercial purposes, any
  portion of the images and any portion of derived data."
- The code is Apache-2.0, but the dataset terms govern.
- Verdict: **Research-only**. "Derived data" arguably includes trained weights.

**HDR+ burst dataset** (Hasinoff et al., SIGGRAPH Asia 2016; https://hdrplusdata.org/dataset.html).
- "The dataset is released under a Creative Commons license (CC-BY-SA)", linked to
  https://creativecommons.org/licenses/by-sa/4.0/.
- It adds a non-binding "our main intention is that the dataset be used for scientific
  purposes", and "subjects ... include the authors' friends and family".
- Contents: raw bursts, merged DNGs and Google's finished JPEGs. It is a usable
  input→"finished look" pair source.
- Verdict: **commercial OK with attribution, ShareAlike risk**. Whether trained weights
  are "Adapted Material" is unsettled, and BY-SA forbids applying "Effective Technological
  Measures", which is relevant to App Store DRM. Counsel needed.

**Cube++** (Ershov et al. 2020; https://github.com/Visillect/CubePlusPlus).
- 4,890 raw images with SpyderCube ground truth, Canon 550D/600D.
- README: "Data is avalilable on zenodo.org ... under CC BY 4.0". The Zenodo record
  4153431 API reports `license: cc-by-4.0`.
- Verdict: **Commercial OK** (attribution).

**Cube+** (https://ipg.fer.hr/ipg/resources/color_constancy).
- No license statement on the page.
- Verdict: **UNCLEAR**.

**INTEL-TAU** (Laakom et al., arXiv:1910.10404).
- The Fairdata/Metax record (id f0570a3f-3d77-4f44-9ef1-99ab4878f17c) lists "Creative
  Commons Attribution-ShareAlike 4.0 International (CC BY-SA 4.0)", with open access.
- Verdict: **commercial OK with ShareAlike caveat**. It is multi-camera and good for
  cross-camera WB.

**Gehler-Shi** (Shi & Funt reprocessing, https://www2.cs.sfu.ca/~colour/data/shi_gehler/).
- No license text on the page.
- Verdict: **UNCLEAR** (default all rights reserved).

**NUS 8-camera** (Cheng, Prasad, Brown 2014;
https://cvil.eecs.yorku.ca/projects/public_html/illuminant/illuminant.html).
- No license text found.
- Verdict: **UNCLEAR**.

**Unsplash Lite** (https://github.com/unsplash/datasets).
- Terms: license to "internally use the Commercial Licensed Data to train machine learning
  models or algorithms for your internal business purposes".
- Whether shipping a model to users counts as "internal" is **UNCLEAR**. The images are
  processed JPEGs, not raws.

**raw.pixls.us**.
- Uploaders declare "I own full rights to this file and I hereby release it under the
  [CC0] license into the public domain".
- Contents: one or a few raws per camera, low ISO, daylight.
- Verdict: **commercial OK**. Good for raw inputs and camera coverage, but there are no
  edit targets.

**PD12M / Megalith-10M**.
- Public-domain and CC0 photos (see D notes).
- Verdict: commercial OK after audit. These are rendered JPEGs: useful for aesthetic/scene
  priors and self-supervised pretraining, not for raw→edit pairs.

### 1.2 Models

| Model | Paper | Output type | Code license (source) | Released weights trained on |
|---|---|---|---|---|
| HDRNet | Gharbi et al. 2017, arXiv:1707.02880: "processes high-resolution images on a smartphone in milliseconds, provides a real-time viewfinder at 1080p" | per-pixel bilateral-grid affine | Apache-2.0 (google/hdrnet) | FiveK, HDR+ |
| Image-Adaptive 3D LUT | Zeng et al. 2020, arXiv:2009.14468: "less than **600K** parameters ... less than **2 ms** ... 4K ... Titan RTX" | global 3D LUT (image-weighted basis) | Apache-2.0 (HuiZeng/Image-Adaptive-3DLUT) | FiveK, PPR10K |
| AdaInt | arXiv:2204.13983 | 3D LUT, adaptive intervals | Apache-2.0 | FiveK, PPR10K |
| SepLUT | arXiv:2207.08351 | 1D + 3D LUT | Apache-2.0 | FiveK |
| CLUT-Net | ACM MM 2022 | compressed LUT | **no license file** (Xian-Bei/CLUT) | FiveK |
| NILUT | arXiv:2306.11920 | implicit neural LUT (styles) | MIT (mv-lab/nilut) | FiveK/styles |
| DeepLPF | arXiv:2003.13985 | parametric local filters | MIT (sjmoran/deeplpf-image-enhancement) | FiveK |
| CURL | Moran et al. 2021 | global curves | README says "BSD-3-Clause", no LICENSE file | FiveK |
| Exposure | Hu et al. 2018, arXiv:1709.09602 | **white-box filter parameters** via RL, trained unpaired | MIT (yuanming-hu/exposure) | FiveK (unpaired) |
| CSRNet | He et al. 2020, arXiv:2009.10390 | global modulation | **no license file** | FiveK |
| StarEnhancer | Song et al. 2021, arXiv:2107.12898: multi-style, "4K ... over 200 FPS" | curves/style embedding | MIT (IDKiro/StarEnhancer) | FiveK |
| FFCC (AWB) | Barron & Tsai 2017, arXiv:1611.07596: "lower error rates than the previous state-of-the-art by 13-20% while being 250-3000 times faster", "~700 frames per second on a mobile device" | illuminant posterior | Apache-2.0 (google/ffcc) | Gehler-Shi, others |
| CCC (AWB) | Barron 2015, arXiv:1507.00410 | illuminant | (in FFCC repo) | Gehler-Shi |
| FC4 (AWB) | Hu, Wang, Lin, CVPR 2017 | illuminant + confidence | MIT (yuanming-hu/fc4) | Gehler-Shi, NUS |
| C5 (AWB) | Afifi et al., arXiv:2011.11890: cross-camera; "~7 and ~90 ms per image on a GPU or CPU" | illuminant (hypernetwork over CCC) | Apache-2.0 (mahmoudnafifi/C5) | NUS, Cube+, Gehler, INTEL-TAU |
| Deep WB editing / WB_sRGB | Afifi 2020, arXiv:2004.01354 | sRGB re-render | **CC BY-NC-SA 4.0** (LICENSE.md) | own set |

Patent note: we could not check Google patents on CCC/FFCC or HDRNet. Google Patents
rate-limited us ("Sorry..." page) after the workstream-D searches. Open item: search
Google-assigned patents naming Barron (color constancy) and Gharbi/Chen/Hasinoff (bilateral
learning) before adopting FFCC-style histogram-convolution AWB. The Apache-2.0 patent grant
in `google/ffcc` covers contributions *as licensed in that repository*. Assessment: a
clean-room reimplementation from the paper might not be covered, so check.

### 1.3 Classical baselines

Assessment, citing the standard literature:
- **Gray-world** is what we have today. **Shades-of-Gray** (Finlayson & Trezzi 2004) uses
  the Minkowski p-norm, with p≈6 typical. **Gray-Edge** (van de Weijer, Gevers, Gijsenij
  2007) uses first/second-order derivatives. **White-patch / bright-pixels**, and
  **PCA-based** estimation (Cheng et al. 2014) are the other standards.
- Each fails differently: gray-world on dominant colors, white-patch on clipping, gray-edge
  on low texture. A **confidence-weighted ensemble** chosen by simple image statistics
  closes most of the gap to early learned methods on the standard benchmarks. The
  Gijsenij/Gevers survey line of work shows this.
- The raw advantage matters. We estimate in **camera-native linear space before the color
  matrix**, which is where FFCC and C5 operate. So a small learned model is data-cheap:
  per-camera it is a 2D chroma histogram problem.
- Auto exposure/tone: log-average key (Reinhard 2002), percentile clipping targets, and
  histogram equalization with limits (CLAHE-style constraints for local tone) remain strong.
  What heuristics miss is **intent**: backlit subjects, snow/beach high-key, night scenes
  that should stay dark, silhouettes. That is scene classification plus rules, or a learned
  head.

**Is learned auto worth it?** Assessment:
- **Auto WB: yes, modestly.** Specifically, a per-camera FFCC/CCC-style histogram model,
  or a C5-style cross-camera model trained on Cube++ (CC BY) + INTEL-TAU (BY-SA) + our own
  captures with a gray card or SpyderCube. It runs in microseconds on a 64×64 chroma
  histogram, so there is no Neural Engine cost.
- **Auto tone: learned helps mainly on "intent" scenes.** A parameter predictor (below)
  trained on ~2–5k of our own expert-edited raws should beat heuristics on the hard 20%
  and tie on the easy 80%.
- **Pixel-output networks (HDRNet, 3D LUT, CSRNet, StarEnhancer) are the wrong product
  shape for the Auto button.** Lightroom users expect Auto to *move sliders* they can
  tweak. A LUT or bilateral grid is opaque, not editable, and would need caching for
  reproducibility.

### 1.4 Recommended design: a recipe-parameter predictor

- **Inputs** (computed at open time from the existing analysis copy):
  - 64-bin log-luminance histogram and percentiles.
  - Chroma histogram in camera space.
  - As-shot WB.
  - EXIF: ISO, shutter, aperture, focal length, flash, and a derived scene brightness
    value.
  - `ClassifyImageRequest` scene labels.
  - `GenerateImageFeaturePrintRequest` embedding (iOS 18/macOS 15+).
  - Face/person presence and area.
  - Optional `CalculateImageAestheticsScoresRequest` as a weak signal.
- **Outputs:**
  - Exposure, Contrast, Highlights, Shadows, Whites, Blacks, Temp/Tint deltas relative
    to the classical estimate, Vibrance, Saturation, and optionally 3–5 tone-curve points.
  - Predict **residuals over the heuristic**. The model then degrades to today's behavior
    when uncertain, and we can shrink residuals by a confidence score.
- **Training loss:** parameter L1 plus **rendered-image loss** (ΔE2000/CIELAB on
  thumbnails) through a differentiable PyTorch replica of Redlamp's Basic-panel math. This
  is the "Exposure"/DeepLPF/CURL white-box idea, applied to *our* sliders.
- **Size:** an MLP or small gradient-boosted model over ~1k features, well under 1 MB.
  Inference runs in microseconds on CPU, and no Neural Engine is needed.
- **Reproducibility:** Auto writes ordinary slider values into the recipe, plus provenance
  metadata such as `auto: {source: "redlamp-auto-v2", confidence: 0.8}`. Renders never
  depend on the model.

### 1.5 Training data route (commercially clean)

1. **Own expert-edited set** (primary).
   - Acquire 2,000–5,000 raws with rights: our own and contributor captures under a CLA
     or paid license, plus raw.pixls.us CC0 for camera breadth.
   - Have 3–5 professional editors edit them in Redlamp itself, so targets are *native
     slider values*, not pixels.
   - Assessment of cost: ~2 min per photo per editor gives 2,000 × 3 × 2 min ≈ 200 hours
     of editing. With raw licensing (~US$1–5 per image) the order of magnitude is
     US$15–40k.
2. **WB ground truth:** Cube++ (CC BY 4.0), INTEL-TAU (CC BY-SA 4.0, pending counsel), and
   our own shots with a gray card or SpyderCube in frame across our supported cameras.
3. **Synthetic augmentation:** re-expose and re-white-balance our raws (exact in linear
   raw space) to create input variations with known targets. This multiplies data ~10× for
   exposure and WB, but not for aesthetic intent.
4. **Avoid** FiveK, PPR10K, WB_sRGB, and Deep WB checkpoints.

## 2. Personalization on device

### 2.1 Literature

- **Kang, Kapoor, Lischinski, "Personalization of image enhancement", CVPR 2010.** Users
  enhance a small training set, and a distance-metric-learned nearest-neighbor model
  transfers enhancement parameters to new photos. The key idea is to transfer
  *parameters*, not pixels.
- **Caicedo, Kapoor, Kang, "Collaborative personalization of image enhancement", CVPR
  2011.** Collaborative filtering across users. Not applicable (no cloud), except as a
  prior shipped with the app.
- **Bychkovsky et al., CVPR 2011 (FiveK).** Learned global tonal adjustment from
  input/output pairs, with five distinct expert styles. It shows styles differ
  systematically enough to learn.
- **PieNet** (Kim, Koh, Kim, "PieNet: Personalized Image Enhancement Network", ECCV
  2020). Embeds user preference from a few examples. We did not find an arXiv version to
  cite.
- **StarEnhancer** (arXiv:2107.12898). Style embeddings, with "a simple one-time setting,
  users can customize the model".
- **Kosugi & Yamasaki, "Personalized Image Enhancement Featuring Masked Style Modeling"**
  (arXiv:2306.09334). Content-aware personalization, since users' styles differ per scene.
- **"Personalized Image Filter: Mastering Your Photographic Style"** (arXiv:2510.16791).
  Diffusion plus textual inversion. Too heavy, and pixel output.
- **FedPAIE** (arXiv:2607.27659, July 2026). Federated preference learning with an
  on-device "lightweight CLUT enhancer". It supports the "learn locally" framing, but it
  outputs pixels.
- We could not locate a paper titled exactly "Learning Photographic Style from Few
  Examples". The nearest matches are PieNet, StarEnhancer and 2306.09334.

### 2.2 Recommended approach

- **Signal capture.** A "training example" is a photo whose Basic-panel values the user
  set and then kept. Criteria: they exported it, rated it, or left it after at least N
  seconds of editing without undo-to-zero.
  - Store the feature vector and the **final minus Auto** slider deltas.
  - Exclude photos where a creative preset or profile dominates, or keep them as a
    separate "style".
  - Weight by recency.
- **Stage 1 (n < ~20): kernel regression / kNN.** Predicted delta = Σ w_i·delta_i, with
  weights from cosine similarity of feature prints plus histogram distance. Shrink toward
  zero by n/(n+k). This is transparent: "Based on 12 of your edits of similar photos".
- **Stage 2 (n ≥ ~50): per-slider regressor on device.**
  - `MLBoostedTreeRegressor` or `MLLinearRegressor` (Create ML, available on iOS 15.0+
    and macOS 10.14+ per Apple docs), trained in a background task. Alternatively a tiny
    ridge/MLP trained in Swift/Accelerate.
  - Train to predict the residual over Stage 1. Retrain nightly while charging.
- **Core ML updatable models.** `MLUpdateTask` ("A task that updates a model with
  additional training data") is listed with no deprecation on iOS 13+/macOS 10.15+. It
  would work for an updatable NN head, but it is more machinery than we need.
  - The new **Core AI** framework (iOS/macOS 27) documents inference, specialization and
    caching topics, with no on-device training topic found.
  - Assessment: Create ML or plain Accelerate is simpler and keeps the 26 floor.
- **Scene-conditional styles.** Cluster the user's history by feature print (for example,
  portraits, landscapes, night, B&W) and fit per-cluster heads when each has ≥20 examples.
  Masked Style Modeling suggests content-aware styles beat a single global style.
- **Data needed** (assessment; no primary source gives a single number):
  - A global "brighter/warmer/punchier" bias is learnable from ~10–20 edits.
  - Scene-dependent behavior needs ~50–200.
  - Show a confidence meter and do nothing below a threshold.
- **Privacy.**
  - Features and deltas live in the local catalog, never in exported files.
  - Sync is opt-in via the user's iCloud only.
  - "Forget my style" deletes everything. No telemetry.
  - Feature prints are embeddings of the user's photos, so treat them as sensitive data.
- **UX.**
  - "Auto" gets a variant, "Auto (My Style)", or a toggle, with an intensity slider.
  - After applying it, show which sliders moved and why ("you usually lift shadows ~+18
    on backlit scenes").
  - Predictions are plain slider values, so they stay editable and reproducible.

**Why parameters, not pixels:**
- Parameters are editable and inspectable.
- They are reproducible: plain recipe values, with no cached bitmaps.
- They are tiny, both the model (KB) and the data (a vector per photo).
- They are learnable from tens of examples.
- They compose with every other tool.

Pixel models (3D LUT, HDRNet) need thousands of pairs, can't be explained, and
fight the Lightroom-style workflow.

## 3. Scene-aware "Adaptive" profile

Evidence (Adobe Lightroom Classic help "Image tone and color", Wayback capture
2025-12-31,
https://web.archive.org/web/20251231014850/https://helpx.adobe.com/lightroom-classic/help/image-tone-color.html):
- "The Adaptive profiles help with image-adaptive adjustments in color, tone, and contrast
  of raw images."
- Choose "Color or B&W"; "adjust the intensity with the slider in the range of 0 to 200".
- "Adaptive profiles are most effective when used with raw HDR files. The default version
  of the profile does not support Monochrome raw files."
- "You'll need to update the Adaptive profile if you perform one of the following actions
  after applying the profile: Remove or Heal ..., Rotating or flipping the image, Applying
  Lens blur."
- "It isn't recommended that the Auto setting and Adaptive profile be applied together."
- The Lightroom Classic April 2025 "What's new": "create an enhanced yet realistic
  starting point ... Try it on landscape or cityscape raw images in HDR mode for best
  results."
- The help page we fetched does **not** say "AI" or "machine learning". Descriptions of it
  as AI-driven come from marketing we could not fetch (helpx and blog pages return
  Akamai "Access Denied" to non-browser clients), so they are **not verified here**.

Assessment of what Adobe built: the invalidation list (geometry, heal, lens blur) implies an
image-content-dependent result computed once and cached, probably spatially varying. The
Auto warning implies it overlaps Auto's job (global tone).

**Redlamp design proposal: "Adaptive" as a cached, parameterized stage.**
1. **Analysis** at apply time, on a ~1–2 MP proxy:
   - Scene key and dynamic range from the log-luminance histogram.
   - Semantic masks: Vision person/foreground now; sky, vegetation and architecture from
     workstream C when available.
   - Saliency.
   - Optional feature-print scene class.
2. **Parameters** (small, stored in the recipe):
   - Local tone mapping strength and radius, using our local-contrast/local-Laplacian-lite
     operator.
   - Global exposure/contrast/curve.
   - Per-region deltas: sky darken/saturation protect, skin hue/saturation protect, subject
     lift, vegetation vibrance.
   - One learned "look" vector.
   - Amount 0–200 scales all deltas.
3. **Sources of parameters:**
   - v1: rules plus the heuristic Auto.
   - v2: the same recipe-parameter predictor as section 1.4, trained on our expert set
     with the targets "best natural starting point".
   - v3: personalized residual from section 2.
4. **Caching and versioning.** Store the parameters and the mask references (masks are
   already cached in the sidecar) plus `adaptive: {version, analysisHash}`. Mark it stale
   (UI "Update" button, like Adobe) when geometry or retouch changes invalidate the
   analysis hash.
5. **HDR.** Redlamp is scene-referred. Adaptive should produce an SDR rendering and an
   HDR/EDR headroom variant from the same parameters. This is where Adobe says it shines.

Effort for v1 (rules + masks + local tone mapping): 4–6 ew, assuming the local tone operator
and masks from other workstreams exist. The v2 learned version reuses the section 1.4 model.

## 4. Shortlist

| Candidate | Code license | Weights license | Data | Quality evidence | Apple Silicon fit | Verdict |
|---|---|---|---|---|---|---|
| Heuristic Auto (existing) + classical AWB ensemble | ours | n/a | none | classical literature | CPU, ms | **Build (P2–P3)** |
| FFCC/CCC-style per-camera AWB (clean-room) | ours (ref Apache-2.0) | ours | Cube++, INTEL-TAU, own gray-card set | FFCC: 13–20% lower error, ~700 fps mobile | CPU/Accelerate, µs | **Build (P3)**, pending patent check |
| C5 cross-camera AWB | Apache-2.0 | retrain | same | SOTA cross-camera, ~7 ms GPU | small CNN | Fine-tune only; alternative to FFCC |
| Recipe-parameter predictor (ours) | ours | ours | own expert-edited raws | Exposure/DeepLPF show parametric viability | CPU, <1 MB | **Build (P4)** |
| On-device personalization (kNN → boosted trees) | ours + Create ML | per-user | user's own edits | Kang 2010; Masked Style Modeling 2023 | Create ML iOS 15+ | **Build (P4)** |
| Adaptive profile v1 (rules + masks + LTM) | ours | n/a | none | Adobe feature parity | GPU stage | **Build (P3–P4)** |
| HDRNet | Apache-2.0 | FiveK/HDR+ trained | NC / BY-SA | real-time 1080p on phone | good | Fine-tune only; not for Auto |
| 3D LUT / AdaInt / SepLUT | Apache-2.0 | FiveK/PPR10K | NC | <600K params, <2 ms 4K | excellent | Fine-tune only; maybe for "looks" |
| NILUT / DeepLPF / StarEnhancer / Exposure | MIT | FiveK | NC | literature | good | Fine-tune only |
| CLUT-Net / CSRNet | none | FiveK | NC | literature | good | Research-only (no license) |
| Deep WB / WB_sRGB | CC BY-NC-SA 4.0 | same | own | sRGB re-render | — | Research-only |

## 5. License matrix

| Candidate | Code license (source) | Weights license (source) | Training data (terms) | Obligations (attribution, patents) | Verdict |
|---|---|---|---|---|---|
| MIT-Adobe FiveK (dataset) | — | — | "solely for your own research purposes ... not ... commercial advantage" (LicenseAdobe.txt, LicenseAdobeMIT.txt) | — | Research-only |
| PPR10K (dataset) | Apache-2.0 (repo) | pretrained on PPR10K | "non-commercial research purposes only ... any portion of derived data" (README) | — | Research-only |
| HDR+ (dataset) | — | — | CC BY-SA 4.0 (hdrplusdata.org) | attribution, ShareAlike, no ETMs | Commercial w/ caveat (UNCLEAR re SA) |
| Cube++ (dataset) | — | — | CC BY 4.0 (README; Zenodo 4153431) | attribution | Shippable (data) |
| Cube+ (dataset) | — | — | no license on page | — | UNCLEAR |
| INTEL-TAU (dataset) | — | — | CC BY-SA 4.0 (Fairdata/Metax) | attribution, SA | Commercial w/ caveat |
| Gehler-Shi (dataset) | — | — | no license on SFU page | — | UNCLEAR |
| NUS 8-camera (dataset) | — | — | no license found | — | UNCLEAR |
| raw.pixls.us | — | — | CC0 (upload declaration) | none | Shippable (data) |
| Unsplash Lite | — | — | "internally use ... to train ... for your internal business purposes" | no redistribution | UNCLEAR |
| HDRNet | Apache-2.0 (google/hdrnet) | trained on FiveK/HDR+ | NC / BY-SA | Google patents unchecked | Fine-tune only |
| Image-Adaptive 3D LUT | Apache-2.0 (API) | FiveK/PPR10K | NC | — | Fine-tune only |
| AdaInt / SepLUT | Apache-2.0 (API) | FiveK/PPR10K | NC | — | Fine-tune only |
| CLUT-Net | none (API null) | FiveK | NC | — | Research-only |
| NILUT | MIT (API) | FiveK | NC | — | Fine-tune only |
| DeepLPF | MIT (API) | FiveK | NC | — | Fine-tune only |
| CURL | README "BSD-3-Clause", no LICENSE file | FiveK | NC | — | Fine-tune only (confirm license) |
| Exposure | MIT (API) | FiveK | NC | — | Fine-tune only |
| CSRNet | none (API null) | FiveK | NC | — | Research-only |
| StarEnhancer | MIT (API) | FiveK | NC | — | Fine-tune only |
| FFCC | Apache-2.0 (google/ffcc) | per-dataset | Gehler-Shi etc. (UNCLEAR) | Apache patent grant; Google patents unchecked | Fine-tune only |
| FC4 | MIT (API) | Gehler-Shi/NUS | UNCLEAR | — | Fine-tune only |
| C5 | Apache-2.0 (API) | NUS/Cube+/Gehler/INTEL-TAU | mixed UNCLEAR/BY-SA | — | Fine-tune only |
| Deep WB editing / WB_sRGB | CC BY-NC-SA 4.0 (LICENSE.md) | same | own | NC | Research-only |
| Vision feature print / aesthetics / classify | Apple SDK | system | — | platform ≥ iOS 18 / macOS 15 for Swift API | Shippable (API) |
| Create ML regressors | Apple SDK | per-user | user data | iOS 15+/macOS 10.14+ | Shippable (API) |

## 6. Recommendations and effort (engineer-weeks)

| Item | Phase | Decision | Effort |
|---|---|---|---|
| Harden heuristic Auto: scene-intent rules (backlit, high-key, night), clipping-aware whites/blacks, Shift-double-click per-slider auto | P2–P3 | Build | 2–3 ew |
| Classical AWB ensemble (gray-world, shades-of-gray, gray-edge, bright-pixels, confidence weighting) + eval on Cube++ | P2–P3 | Build | 2 ew |
| Per-camera histogram AWB (FFCC-style, clean-room) trained on Cube++ + own gray-card set | P3 | Build (after patent check) | 3–4 ew + capture days |
| Expert-edited dataset program (rights, editors, tooling to record slider targets) | P3 start | Build | 3–4 ew of engineering + ~US$15–40k |
| Differentiable Basic-panel replica + parameter predictor + eval (ΔE, slider MAE, blind A/B vs heuristic and Lightroom Auto) | P4 | Build | 5–7 ew |
| On-device personalization (signal capture, kNN, Create ML regressor, UI, privacy controls) | P4 | Build | 4–6 ew |
| Adaptive profile v1 (rules + masks + local tone mapping, cached params, Amount 0–200, stale/update) | P3–P4 | Build | 4–6 ew |
| Adaptive v2 (learned parameters) | P4+ | Build | 2–3 ew on top of the predictor |
| Pixel-output enhancers (HDRNet/3D LUT) | — | Defer; maybe for "Looks" later | — |

## 7. Risks and open questions

1. **Benchmarks we can't use.** FiveK is the lingua franca. Without it we can't quote
   comparable PSNR numbers publicly. Mitigation: publish our own CC-licensed eval set
   (the photos we have rights to plus expert targets). That is also a community
   contribution.
2. **ShareAlike data** (HDR+, INTEL-TAU). Whether training on BY-SA data makes weights
   Adapted Material, and whether App Store DRM violates the "no Effective Technological
   Measures" term, is unresolved. Default: use only CC BY / CC0 / own data for shipped
   weights until counsel says otherwise.
3. **Patents on learned AWB and bilateral learning** (Google): unchecked because of rate
   limiting. Must check before shipping FFCC-style AWB.
4. **Personalization failure modes.**
   - The model learns from "bad" edits, or from edits made for a specific client.
   - Drift between cameras: store camera model as a feature and allow per-camera
     personalization.
   - Mitigations: confidence thresholds, "exclude this photo from learning", reset.
5. **Feature-print stability.** Vision feature prints can change with OS revisions
   (Vision request revisions exist, e.g. `VNGenerateImageFeaturePrintRequestRevision2`).
   Store the revision alongside vectors, and re-embed on revision change (a cheap
   background job).
6. **Reproducibility.** Auto and personalization write slider values, so they are safe.
   Adaptive must store parameters plus mask references and never recompute silently.
7. **Unverified in this pass:**
   - Adobe's exact disclosure that Adaptive Color is AI-based (marketing pages blocked).
   - Vision feature print dimensionality and latency on the A17 Pro.
   - Whether Create ML training APIs run acceptably in background tasks on iPhone.

## 8. Test data (with licenses)

| Set | Use | License | OK for us? |
|---|---|---|---|
| Cube++ (Zenodo 4153431) | AWB accuracy (angular error) | CC BY 4.0 | Yes (attribute) |
| INTEL-TAU | cross-camera AWB | CC BY-SA 4.0 | Eval yes; training pending counsel |
| Own gray-card/SpyderCube captures, all supported cameras, mixed light | AWB, per-camera | ours | Yes |
| raw.pixls.us | camera coverage, auto-tone smoke tests | CC0 | Yes |
| Own expert-edited raws (2–5k) | auto-tone targets, Adaptive tuning | ours (contract) | Yes |
| HDR+ bursts + finished JPEGs | "finished look" reference | CC BY-SA 4.0 | Eval yes; training pending counsel |
| MIT-Adobe FiveK | literature comparison only | research-only license | Avoid for product decisions |
| PPR10K | portrait retouch comparison | NC research only | Avoid |
| Gehler-Shi, NUS 8-camera, Cube+ | classic AWB benchmarks | no license stated | UNCLEAR; ask authors |
