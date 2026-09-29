# F. Other opportunities — landscape survey

Author: research agent, 2026-09-29. Scope: brief section 3.F. Licenses verified 2026-09-29
from the primary source cited inline. Apple API availability was checked against the
developer documentation JSON (`https://developer.apple.com/tutorials/data/documentation/...`).
Our floor is OS 26, so an API "available" below means it is introduced in OS 26 or earlier.

## TL;DR

| Item | Verdict | When | Effort (eng-weeks) |
|---|---|---|---|
| Face and eye detection (masks, healing, red-eye, pet eye) | **Pursue now** | Phase 2–3 | 2–3 |
| Smart crop and straighten, Upright Auto/Full | **Pursue now** (classical + Vision) | Phase 2–3 | 5–8 |
| AI-assisted culling | **Pursue** (Apple Vision + classical focus measures) | Phase 3 | 4–6 |
| Lens blur (synthetic DoF + bokeh shapes) | **Pursue later** (classical renderer on depth from C) | Phase 3–4 | 6–10 |
| ML demosaic ("Raw Details") | **Pursue later, as part of A/B's joint raw network**, not standalone | Phase 3–4 | incremental 2–4 on top of A |
| Sky replacement | **Skip for now** (not in Lightroom; licence and "truth" issues) | Later / never | 6–8 if ever |
| Content Credentials (C2PA) | **Pursue** (Apache/MIT SDKs) | Phase 3 | 2–3 |
| Dust-spot detection | **Pursue**, classical, with healing (D) | Phase 3 | 1–2 |
| HDR merge with deghosting, panorama | **Pursue later**, classical, reusing G's alignment | Phase 3–4 | 6–10 total |
| CA and defringe, moiré, dehaze | **Classical now; ML skip** | Phase 2 | 2–4 |
| Lens deblur / "lens sharpening" | **Later**; watch Lightroom's June 2026 "AI Sharpen" | Phase 4+ | 6–12 |
| Relighting | **Skip** | — | — |

## 1. Lens blur (synthetic depth of field with bokeh shapes)

Evidence:

- **Adobe's feature.** The Lens Blur post
  (https://blog.adobe.com/en/publish/2024/06/26/inside-lens-blur) says mirrorless and DSLR
  cameras "don't measure depth" and that Adobe uses Adobe Research depth estimation to
  "produce depth information that's more sophisticated than a basic depth map image … to
  increase precision and detail along subject edges". The pipeline has "a dedicated step for
  detecting out-of-focus light sources", which the Bokeh Boost slider drives. There are five
  bokeh styles: "modern circular, bubble, 5-blade, ring, and cat eye". The repo's
  `docs/lightroom-feature-inventory.md` lists the remaining controls: focal range, refine
  brushes and depth visualisation.
- **BokehMe** (Peng et al., CVPR 2022, arXiv 2206.12614; https://github.com/JuewenPeng/BokehMe,
  **Apache-2.0**): a hybrid of a classical scatter renderer and a neural renderer that fixes
  errors at depth discontinuities. Its BLB evaluation set is synthesized in Blender. The
  weights and training-data licence are not separately stated, so the weights are
  **UNCLEAR**.
- **Dr.Bokeh** (Sheng et al., arXiv 2308.08843): differentiable, occlusion-aware rendering.
  The code repo https://github.com/ShengCN/DrBokeh has **no licence** (GitHub API returns
  none), which means all rights reserved. **Avoid**, except reading the paper.
- **Depth sources** (details in workstream C):
  - **Depth Anything V2 Small:** weights **Apache-2.0**. The README says "Depth-Anything-V2-Small
    model is under the Apache-2.0 license. Depth-Anything-V2-Base/Large/Giant models are under
    the CC-BY-NC-4.0 license", and the HF card `depth-anything/Depth-Anything-V2-Small` says
    apache-2.0. Training data is synthetic plus pseudo-labelled public real images (arXiv
    2406.09414). The per-set terms were not verified here, so the data is **UNCLEAR**.
  - **Depth Pro:** **contradictory licences.** The GitHub LICENSE is Apple's permissive sample
    code licence, and the README says "The model weights are released under the LICENSE
    terms". But the Hugging Face checkpoint `apple/DepthPro` carries `license: apple-amlr`,
    whose text grants use "exclusively for Research Purposes … does not include any
    commercial exploitation, product development or use in any commercial product". Mark it
    **UNCLEAR, and treat it as research-only** until Apple clarifies.
  - **iPhone Portrait / depth-captured HEIC:** embedded depth (AVDepthData) is free and exact.
    The Adobe post notes phones increasingly capture depth "even when the image is not
    captured in portrait mode". Whether ProRAW DNGs carry depth is **not verified**.

Assessment:

- Lens blur is **~70% classical rendering**:
  - a layered or scatter-as-gather disc blur driven by a circle-of-confusion map from depth
    and focal plane;
  - aperture-shaped kernels for the bokeh styles;
  - highlight "boost", done by detecting and brightening clipped or near-clipped points
    before blurring, in linear light. Our scene-referred pipeline is an advantage here,
    because physically correct bokeh needs linear radiance;
  - occlusion handling at depth edges, which is where BokehMe and Dr.Bokeh add value.
- The **hard part is depth quality at hair and fine edges**. That is the same problem as C's
  matting and edge refinement, so reuse C's refinement (guided filter or learned matting) on
  the depth map.
- It is not a pixel-inventing feature, so hallucination risk is low. It needs cached depth
  (sidecar) plus a model version, like masks.
- Effort: renderer and bokeh shapes 3–4 weeks; focus-range UI, refine brushes and depth
  visualisation 2–3 weeks; edge-aware depth refinement 1–3 weeks (partly C). The depth
  model itself is counted in C.
- **Verdict: pursue later (Phase 3–4, after C ships depth).** It is a visible Lightroom
  parity feature ("[Later]" in the inventory).

## 2. Sky replacement

Evidence:

- Lightroom has a Sky *mask* but no sky replacement. The inventory lists "Sky [P2]" as a
  mask only. Photoshop and Luminar have replacement.
- Research reference: **SkyAR** ("Castle in the Sky", arXiv 2010.11800;
  https://github.com/jiupinjia/SkyAR). Its README says it "is licensed under a Creative
  Commons Attribution-NonCommercial-ShareAlike 4.0 International License", so it is
  **Research-only**.
- The pipeline is sky segmentation (from C), sky-edge matting, relighting and colour
  harmonisation of the foreground to the new sky, and optionally reflections in water.

Assessment:

- Shipping sky images requires a library we own or license for redistribution: our own
  captures or commissioned work with a written licence. Generic "CC0 from the web" images
  carry model- and property-release and provenance risk.
- The feature cuts against a raw editor's "photographic truth" positioning, and it overlaps
  with generative-content labelling (C2PA).
- The segmentation is a by-product of the Sky mask anyway. A "sky mask + gradient +
  colour-harmonise" preset gets 80% of the use case for 10% of the effort.
- **Verdict: skip for now.** Revisit only if users ask. If built: 6–8 weeks plus sky-library
  production.

## 3. AI-assisted culling

Evidence:

- **Lightroom.** Adobe's 2026-06-15 post
  (https://blog.adobe.com/en/publish/2026/06/15/from-culling-to-compositing-new-creative-cloud-innovations-across-every-stage-of-your-workflow)
  says: "Assisted Culling is now generally available". It lists "Face View which isolates
  each person in a photo and analyzes Eyes Open and Eye Sharpness" and "Stacking
  automatically groups similar images and recommends the strongest one". The brief's
  "Assisted Culling 2025" was an earlier early-access release; I did not verify its date, but
  GA as of June 2026 is confirmed.
- **Aftershoot** (https://aftershoot.com/): "Works Offline No Internet needed and your files
  never leave your machine", plus "Duplicate Grouping". **Narrative Select**
  (https://narrative.so/select): "Eye and focus assessments … if their eyes are open or
  closed". **FilterPixel** (https://filterpixel.com/): tags "duplicates, blur, blinks, and
  weaker frames". These come from marketing pages; their accuracy is not verified.
- **Apple Vision building blocks.** All of these are available on macOS 15 / iOS 18 or earlier
  unless stated, and are OS APIs, so no licence risk:
  - `CalculateImageAestheticsScoresRequest` → `ImageAestheticsScoresObservation`.
    `overallScore` "incorporates aesthetic score, failure score, and utility labels", and
    `isUtility` marks "images that are not necessarily of poor image quality, but may not
    have memorable or exciting content". `VNCalculateImageAestheticsScoresRequest` also
    exists (the same OS versions).
  - `DetectFaceCaptureQualityRequest`: a 0–1 value where faces "closer to 1 are better lit,
    sharper, and more centrally positioned".
  - `DetectFaceLandmarksRequest` / `FaceObservation`: landmarks, roll, yaw and pitch. There
    is **no blink or eyes-closed attribute** (verified: `FaceObservation` exposes only
    `captureQuality`, `landmarks`, `pitch`, `roll`, `yaw`). Eyes-closed must be derived from
    eye landmarks, for example with an eye-aspect-ratio threshold.
  - `GenerateImageFeaturePrintRequest` → `FeaturePrintObservation.distance(to:)`, for
    near-duplicate grouping.
  - `DetectLensSmudgeRequest` (**new in OS 26**): a smudge "confidence" from 0 to 1, requiring
    A14 or M1 and later. Useful for phone imports.
  - `GenerateAttentionBasedSaliencyImageRequest` and `GenerateObjectnessBasedSaliencyImageRequest`
    locate the subject region for focus checks.

Assessment:

- A strong v1 can be built **entirely from Vision plus classical measures**:
  - group by capture time and EXIF burst data plus feature-print distance;
  - within a group, rank by a sharpness measure on the face, eye or salient region (the same
    Laplacian or wavelet energy code as G's focus measures), eyes-open (from landmarks),
    face capture quality, exposure clipping and aesthetics score;
  - flag smudge and utility shots.
- It runs on the embedded JPEG preview or a low mip, so it is fast. It does not affect pixels,
  so reproducibility is not critical, but store scores with the Vision revision.
- Risks: aesthetics scoring is opaque and culturally biased, so present it as a hint, not a
  verdict, and never auto-delete (FilterPixel's "never deletes" is the right principle).
  Eyes-closed from landmarks is brittle on profiles and sunglasses. The feature also needs
  the Grid, Survey and Compare views, which the inventory marks "[Later]".
- **Verdict: pursue, Phase 3.** 4–6 weeks for the engine plus about 2 weeks of UI. Against Lightroom
  it is mostly parity: Face View, Eyes Open and Stacking already exist there. Our
  differentiator would be integration with the editor and, if Lightroom's culling uses the
  cloud (not verified), privacy. Aftershoot already runs offline.

## 4. Face and eye detection for masks and healing

Evidence:

- Vision provides `DetectFaceRectanglesRequest`, `DetectFaceLandmarksRequest`,
  `GeneratePersonInstanceMaskRequest`, `GeneratePersonSegmentationRequest`,
  `RecognizeAnimalsRequest`, and `DetectAnimalBodyPoseRequest`, whose joint names include
  `leftEye`, `rightEye` and `nose` (macOS 15 / iOS 18; VN variant macOS 14).
- Core Image has a built-in red-eye path: `CIImageAutoAdjustmentOption.redEye` (macOS 10.8+),
  which returns red-eye correction filters.
- Note for C: `GenerateIterativeSegmentationRequest` (points, box or scribble prompts) is
  **OS 27.0**, so it is above our OS 26 floor and needs an availability check.

Assessment:

- Face and eye landmarks give People-mask sub-parts (eyes, iris, brows, lips) by
  rasterising landmark polygons and refining with C's edge refinement. They also give
  targets for healing (D).
- Red-eye: detect pupils from landmarks, then do a classical redness test and desaturate or
  darken. Use our own linear-light implementation rather than the Core Image filter, because
  of determinism and the linear pipeline.
- Pet eye: animal pose eye joints give the location. The pet-eye fix (green or yellow
  tapetum glare) is a classical "replace with dark pupil and specular highlight" operation.
- **Verdict: pursue now (Phase 2–3), 2–3 weeks.** No licence risk; Vision results are cached
  as mask bitmaps in the sidecar, as already planned.

## 5. Smart crop and straighten (Auto Upright)

Evidence:

- `DetectHorizonRequest` → `HorizonObservation.angle` and `transform` (macOS 15 / iOS 18).
  `DetectContoursRequest` and `DetectRectanglesRequest` exist. The saliency requests are
  listed above.
- **LSD (Line Segment Detector)**, Grompone von Gioi et al., TPAMI 2010
  (DOI 10.1109/TPAMI.2008.300). The IPOL reference code v1.6 is
  **AGPL-3.0-or-later**; the IPOL citation block for
  https://www.ipol.im/pub/art/2012/gjmr-lsd/ reads `license = {AGPL-3.0-or-later}`.
  OpenCV 4.x ships `modules/imgproc/src/lsd.cpp` under OpenCV's BSD-style header (verified
  header), but I could not verify that file's provenance history. There is also an open
  OpenCV PR proposing to move `LineSegmentDetector` to opencv_contrib
  (https://github.com/opencv/opencv/pull/29349). **Do not copy either.** Clean-room from the
  TPAMI and IPOL article text.
- **Patents:** I could not reach a patent search. Not verified: any LSD patent; Adobe
  Upright patents (the related research is Lee et al., "Automatic Upright Adjustment of
  Photographs", CVPR 2012).

Assessment:

- **Level:** horizon from Vision plus dominant near-horizontal lines.
- **Vertical, Auto and Full:** line segments (LSD-style or edge + Hough), vanishing-point
  estimation (RANSAC or J-Linkage over segments), then a homography that makes verticals
  parallel and horizons level, with Lightroom-style constraints. Guided Upright (user lines)
  needs none of the detection.
- **Smart crop:** saliency plus a rule-of-thirds or subject-margin heuristic, with an
  aesthetics re-score over candidate crops.
- All classical and deterministic. The lens-profile correction must be applied before line
  detection.
- **Verdict: pursue now.** Guided, Level and Vertical in Phase 2 (2–3 weeks); Auto and Full
  with vanishing points in Phase 3 (3–4 weeks); smart crop 1 week. Run a patent check on
  "automatic upright" before Auto/Full.

## 6. ML-based demosaicing

Evidence:

- **Adobe Raw Details** (formerly Enhance Details) is a CNN demosaic for Bayer and X-Trans
  targeting "false colors and zippering"
  (https://blog.adobe.com/en/publish/2019/02/12/enhance-details). Adobe now folds it into
  Denoise and Super Resolution ("you're also getting Raw Details as part of the deal", from
  the Denoise and SR posts cited in B).
- **Gharbi et al. 2016**, "Deep Joint Demosaicking and Denoising" (SIGGRAPH Asia, DOI
  10.1145/2980179.2982399). Code https://github.com/mgharbi/demosaicnet is **MIT**
  ("Copyright (c) 2016 Michael Gharbi"). The pretrained weights come from their mined-patch
  dataset; its source-image terms were not verified here, so the weights are
  **Fine-tune only**.
- **Newer work:** Qian et al. 2019, arXiv 1905.02538 (joint DM, DN and SR; pipeline order
  matters only for sequential solutions); Ehret et al. 2019, arXiv 1905.05092 (self-supervised
  joint demosaicking and denoising by fine-tuning on bursts of raw images, which is
  interesting because it trains on the user's own data); Guo et al. 2020, arXiv 2009.06205
  (two-stage training); the NTIRE 2024 and 2025 RAW challenges (arXiv 2404.16223,
  2506.02197).
- **Classical options and their licences:**
  - **RCD:** the reference repo https://github.com/LuisSR/RCD-Demosaicing is **GPL-3.0**
    (GitHub API). I know of no formal paper, so a clean-room implementation needs a written
    spec that doesn't come from the GPL code.
  - **AMaZE:** GPL code in RawTherapee.
  - **Markesteijn X-Trans:** originates in dcraw (site unreachable today). LibRaw ships
    `src/demosaic/xtrans_demosaic.cpp` under **LGPL-2.1 or CDDL-1.0** at the user's choice
    (LibRaw README: "you can choose the license that better suits your needs").
  - **Residual interpolation (RI, MLRI, ARI)** and **LMMSE** are published papers (Kiku et
    al.; Zhang & Wu 2005) and are clean-room-friendly.

Assessment:

- As a *standalone* stage, ML demosaic gains are real but mostly visible at 200% on
  near-Nyquist detail, X-Trans worms and false colour in fine textures. A good classical
  method (RCD or ARI for Bayer, Markesteijn-style 3-pass for X-Trans) gets most of the way.
- The compelling version is **joint**: one raw network doing demosaic, denoise and optional
  2x SR, as Adobe does. Its incremental cost on top of workstream A's AI denoise is small
  (a 1x-output, low-noise training mode).
- For clean-room purposes:
  - RCD is the problematic one. Its only precise description is GPL code, so either write a
    clean-room spec from secondary descriptions (legal review) or prefer ARI or MLRI, which
    have papers.
  - For X-Trans, LibRaw's CDDL option makes its code usable as a reference or CPU fallback.
    CDDL is file-level copyleft like MPL, so modified files must stay CDDL. That is
    compatible with MPL-2.0 distribution, but confirm with legal.
  - Clean-room still applies to the GPU port: do not read GPL sources.
- **Verdict:**
  - Classical demosaic now (Phase 2, as planned: add ARI or MLRI next to RCD after a
    clean-room review).
  - ML demosaic **later, as a head of A's raw network** (Phase 3–4), 2–4 weeks incremental.
    Do not build a standalone ML demosaic project.

## 7. Other items worth tracking (short)

- **Chromatic aberration and defringe.** Lateral CA is geometric and belongs in the
  lens-profile warp: per-channel radial scale, plus auto-estimation by cross-channel edge
  alignment. Defringe (purple and green hue-range suppression near high-contrast edges) is
  classical. ML adds little. Lensfun's database is **CC BY-SA 3.0** and its libraries are
  **LGPL-3.0** (lensfun README). The database could be used with attribution and ShareAlike
  on the data file; the library cannot. **Classical, Phase 2.**
- **Moiré removal.** Lightroom offers it only as a local brush. Classical chroma-moiré
  suppression (low-pass on chroma within the brush, luminance untouched) covers most cases.
  Learned demoiréing (UHDM, arXiv 2207.09935; https://github.com/CVMI-Lab/UHDM
  **Apache-2.0**) targets screen-photo moiré. Its dataset terms were not verified; skip.
  **Classical brush, Phase 2–3.**
- **Dehaze.** Classical options: dark-channel prior (He et al. 2009) or atmospheric-light and
  transmission estimation with guided-filter refinement, in linear light. Patent status of
  dark-channel dehazing is **not verified**, so check before shipping. ML skip. **Phase 2.**
- **Lens deblur and "lens sharpening".** DxO's approach uses per-lens and per-body measured
  optical modules. Lightroom's June 2026 update added "AI Sharpen", which "brings Topaz Labs'
  Noise-Aware Sharpen model directly into Lightroom" (same Adobe post as §3). A credible
  Redlamp version is a learned or classical non-blind deconvolution with PSFs, either from
  our own lens calibration or estimated blind. It could share A's raw network as a
  "sharpen" head trained on synthetic lens PSFs. Dual-pixel defocus deblur (DPDD, arXiv
  2005.00305, MIT code) needs dual-pixel data that consumer raws rarely expose. **Later
  (Phase 4+), 6–12 weeks.** It has hallucination risk similar to SR, so use the same
  fidelity guard.
- **Dust-spot detection.** Lightroom has "Visualize Spots". Classical approach: detect small,
  low-contrast, dark, blurred disks in smooth regions (difference-of-Gaussians on a flattened
  luminance), and confirm across frames of the same session. A sensor spot recurs at the
  same position, which is a strong cue that ML lacks. Feed the result to D's healing.
  **Phase 3, 1–2 weeks.**
- **HDR merge with deghosting, and panorama.** Lightroom's Photo Merge outputs DNG. Classical:
  register frames (reuse G's alignment; Vision's `TrackHomographicImageRegistrationRequest`
  exists as a helper), merge in linear raw or linear RGB with noise-optimal weights, and
  deghost with a reference frame plus a motion mask. Panorama needs feature matching, bundle
  adjustment, a spherical or cylindrical projection, and seam finding with multi-band
  blending. There are no licence issues if clean-room. **Phase 3–4**: HDR 3–4 weeks, panorama
  4–6 weeks. Output a "virtual raw", consistent with G's recommendation.
- **Relighting (portrait or scene).** This needs normals or depth plus a generative prior, it
  invents content, and Lightroom doesn't have it. **Skip.**
- **Content Credentials (C2PA).** The `c2pa-ios` Swift SDK
  (https://github.com/contentauth/c2pa-ios) is **Apache-2.0** (GitHub API). `c2pa-rs` is dual
  **MIT** (LICENSE-MIT, "© Copyright 2020 Adobe") and **Apache-2.0** (LICENSE-APACHE). Writing
  C2PA manifests on export records edits and AI-assisted steps (SR, denoise, healing), which
  addresses the brief's generative-content-policy question and builds user trust. Certificate
  and trust-list requirements for signing were **not verified**. **Pursue, Phase 3, 2–3
  weeks.**

## 8. Shortlist

| Candidate | Code license | Weights license | Data | Quality evidence | Apple Silicon fit | Verdict |
|---|---|---|---|---|---|---|
| Vision face/landmarks/animal pose | Apple OS API | Apple | n/a | production API | ANE, milliseconds | **Adopt now** |
| Vision aesthetics / face quality / feature print / smudge | Apple OS API | Apple | n/a | undocumented accuracy | ANE, fast | **Adopt (culling)** |
| Vision horizon / saliency / contours | Apple OS API | Apple | n/a | production API | fast | **Adopt** |
| LSD line detector | AGPL-3.0-or-later (IPOL) | n/a | n/a | standard parameterless detector | CPU/GPU, fast | **Clean-room from paper** |
| BokehMe | Apache-2.0 | UNCLEAR | synthetic (Blender) | CVPR 2022 oral | small CNN + classical | Reference; clean-room renderer |
| Dr.Bokeh | none (all rights reserved) | — | — | CVPR (arXiv 2308.08843) | — | Avoid (read paper only) |
| Depth Anything V2 Small | Apache-2.0 | Apache-2.0 | UNCLEAR (see C) | NeurIPS 2024 | ~25 M params, convertible | Candidate for depth (C decides) |
| Depth Pro | Apple sample code (GitHub) | **apple-amlr: research only** (HF) | undisclosed | arXiv 2410.02073 | 2.25 MP in 0.3 s on GPU (card) | UNCLEAR → treat as Research-only |
| SkyAR | CC BY-NC-SA 4.0 | same | — | arXiv 2010.11800 | — | Research-only |
| demosaicnet (Gharbi 2016) | MIT | Fine-tune only | mined patches (UNCLEAR) | SIGGRAPH Asia 2016 | small CNN | Architecture reference |
| RCD reference | GPL-3.0 | n/a | n/a | popular in RT/darktable | GPU-friendly | Avoid code; clean-room spec only |
| LibRaw X-Trans demosaic | LGPL-2.1 / **CDDL-1.0** | n/a | n/a | dcraw Markesteijn lineage | CPU | Usable under CDDL (legal check) |
| UHDM demoiré | Apache-2.0 | UNCLEAR | UHDM (terms unverified) | arXiv 2207.09935 | moderate | Skip |
| c2pa-ios / c2pa-rs | Apache-2.0 / MIT+Apache-2.0 | n/a | n/a | industry standard | native | **Adopt** |
| Lensfun | LGPL-3.0 libs; CC BY-SA 3.0 DB | n/a | lens DB | community profiles | — | Avoid libs; DB possible with attribution |

## 9. License matrix

| Candidate | Code license (source) | Weights license (source) | Training data (terms) | Obligations (attribution, patents) | Verdict |
|---|---|---|---|---|---|
| Apple Vision requests (all listed) | OS API (developer.apple.com Vision docs) | Apple | n/a | Apple Developer Program terms | **Shippable** |
| Core Image red-eye | OS API (coreimage docs) | Apple | n/a | — | Shippable (we prefer our own linear version) |
| LSD | AGPL-3.0-or-later (IPOL gjmr-lsd citation block) | n/a | n/a | patents: not verified | **Avoid code**; clean-room from TPAMI paper |
| OpenCV `lsd.cpp` | OpenCV BSD-style header (opencv 4.x source) | n/a | n/a | provenance history unverified | Avoid (don't copy) |
| BokehMe | Apache-2.0 (api.github.com, via gh) | not stated: **UNCLEAR** | BLB synthetic (Blender) | Apache NOTICE | Fine-tune only / reference |
| Dr.Bokeh | none: all rights reserved (GitHub API: no license) | — | — | — | Avoid |
| Depth Anything V2 Small | Apache-2.0 (GitHub API) | Apache-2.0 (README; HF card) | mixed public sets: **UNCLEAR** | Apache NOTICE | Fine-tune only until C verifies data |
| Depth Anything V2 Base/Large/Giant | Apache-2.0 | CC-BY-NC-4.0 (README) | same | NC | Research-only |
| Depth Pro | Apple sample-code licence (GitHub LICENSE) | **apple-amlr**: "exclusively for Research Purposes" (HF LICENSE) vs README "weights … under the LICENSE" | undisclosed | "no … patent rights" granted (GitHub LICENSE) | **UNCLEAR → Research-only** |
| SkyAR | CC BY-NC-SA 4.0 (README) | same | — | NC-SA | Research-only |
| demosaicnet | MIT (LICENSE) | not stated | mined patches: UNCLEAR | MIT notice | Fine-tune only |
| RCD-Demosaicing | GPL-3.0 (GitHub API) | n/a | n/a | copyleft | Avoid (clean-room spec only) |
| LibRaw demosaic (incl. X-Trans) | LGPL-2.1 or CDDL-1.0 (LibRaw README) | n/a | n/a | CDDL file-level copyleft | Shippable under CDDL (legal confirm) |
| UHDM | Apache-2.0 (GitHub API) | UNCLEAR | UHDM dataset (unverified) | Apache | Skip |
| DPDD dual-pixel deblur | MIT (GitHub API) | UNCLEAR | Canon DP dataset (unverified) | MIT | Skip |
| c2pa-ios | Apache-2.0 (GitHub API) | n/a | n/a | Apache NOTICE; signing certificate needed (unverified) | **Shippable** |
| c2pa-rs | MIT and Apache-2.0 (LICENSE-MIT, LICENSE-APACHE) | n/a | n/a | notices | **Shippable** |
| Lensfun | LGPL-3.0 libs / GPL-3.0 apps / CC BY-SA 3.0 DB (README) | n/a | lens DB | attribution + ShareAlike on DB | Avoid libs; DB with legal review |
| Dark-channel dehaze | paper (He et al. 2009) | n/a | n/a | **patent not verified** | Check before shipping |

## 10. Recommendations and sequencing

1. **Phase 2.** Face and eye landmarks into masks; Level and Vertical and Guided Upright (on
   Vision horizon plus a clean-room line detector); classical CA, defringe, dehaze and moiré
   brush; classical demosaic additions (ARI or MLRI after clean-room review). About 8–12
   weeks in total, overlapping with existing Phase 2 plans.
2. **Phase 3.**
   - Culling (Vision + G's focus measures + feature-print stacking), 6–8 weeks with UI.
   - Auto/Full Upright and smart crop, 4–5 weeks.
   - Red-eye and pet eye, 1 week.
   - Dust spots, 1–2 weeks.
   - C2PA export, 2–3 weeks.
   - The ML-demosaic head of A's raw network, 2–4 weeks incremental.
3. **Phase 3–4.** Lens blur after C's depth, 6–10 weeks. HDR merge and panorama on G's
   alignment, 6–10 weeks.
4. **Skip or defer.** Sky replacement, relighting, learned demoiré. Lens deblur waits for
   Phase 4+ and the SR fidelity guard.

## 11. Risks and open questions

- **Depth licensing is the gating risk for lens blur.** The Depth Pro licence conflict must be
  resolved with Apple or avoided. Depth Anything V2 Small's training-data provenance needs a
  decision in C. Fallback: train our own depth model (large effort) or support only captured
  depth (iPhone HEIC).
- **Vision score drift.** Aesthetics and face-quality scores can change with OS revisions.
  Store the revision and never let them silently re-rank a culled set.
- **Clean-room hygiene.** RCD (GPL, no paper) and LSD (AGPL reference) both have attractive
  reference code. Engineers must not read it. Write specs from papers and have legal review
  any secondary description we rely on.
- **Patents: unverified.** LSD, Adobe Upright, dark-channel dehaze, and Google burst merge
  (in B). Needs a proper freedom-to-operate search before the Auto features ship.
- **Culling accuracy** for eyes-closed from landmarks (profiles, glasses, small faces) needs an
  evaluation set of our own event captures with consent.
- **OS 27 features** (iterative segmentation) tempt a floor bump. Keep them availability-gated.
- **Open question.** Does iPhone ProRAW (DNG) carry a depth map? If yes, lens blur on iPhone
  raws gets exact depth for free.
- **Open question.** C2PA signing: which certificate authority and trust list, the cost, and
  how to sign on-device without a server, given the privacy stance.
