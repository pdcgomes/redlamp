# Workstream C: Masking and segmentation

Research notes for `docs/research/ai-findings.md`. Checked 2026-09-29. Scope: brief section 3.C.
Follows `_conventions.md`: every license is quoted from its primary source. Items marked **UNCLEAR** have
missing, contradictory or data-dependent terms. "Evidence" means something we fetched or measured.
"Assessment" means our judgement.

**How the numbers were produced.** Apple documentation was read from the DocC JSON under
`developer.apple.com/tutorials/data/documentation/…`, plus WWDC transcripts. Licenses came from the GitHub
license API (`gh api repos/<r>/license`), repo READMEs and the Hugging Face model API. Two small Swift
harnesses ran on the **M1 Ultra test machine** (macOS 26.6.2, Xcode 26.6, Swift 6.3.3). The harnesses and test
images live in `/tmp/cm/`, not in the repo. Timings are wall clock and warm (the first call is excluded) unless
marked otherwise.

---

## 0. Executive summary

| Sub-area | Recommendation | Why | Effort (eng-weeks) |
|---|---|---|---|
| Subject / Background / People (whole) / face parts from landmarks | **Adopt Apple Vision** (Phase 2) | Free, no license risk, fast. Measured 10–130 ms warm on M1 Ultra. The masks are low resolution, so we need our own edge refinement. | 3–4 |
| Objects (box/scribble/hover) | **Adopt Vision tap-to-segment on OS 27** and **adopt SAM 2.1 (Apple Core ML packages, Apache-2.0) as the OS 26 path and quality baseline** (Phase 3) | OS 27 adds `GenerateIterativeSegmentationRequest` (points, box, scribble). SAM 2.1 tiny/small prompt decode measured at **9–12 ms on the GPU**, well within the hover budget. | Vision: 1–2. SAM 2.1: 4–6 (+2–3 for an ANE-optimised re-export) |
| Sky, Landscape categories, People parts (hair, skin, clothes, teeth, sclera) | **Build**: a small semantic head of our own on a commercially licensed backbone (DINOv2 ViT-S/14, Apache-2.0, or the SAM 2.1 encoder we already run), trained on data we have rights to | Vision has no sky/landscape/hair request. The capture-time mattes (hair/skin/teeth/glasses) exist only in camera captures. Every open semantic-segmentation checkpoint is trained on NC data (ADE20K, Cityscapes) or data with mixed licenses (COCO). | Sky: 6–8. Landscape + people parts: 12–20, plus a labelling budget |
| Depth (Depth Range mask, lens blur) | **Read embedded depth for free**, then **adopt Depth Anything V2 Small** (Apple Core ML package, Apache-2.0 weights) **subject to a legal decision on training-data provenance**. Evaluate DA3-Small/Base and MoGe-2. Do **not** use Depth Pro (weights research-only). | Small, fast (Apple publishes 25–34 ms on iPhone/Mac), the only mainstream depth net with a first-party Core ML conversion. But its teacher was trained on Virtual KITTI 2 (CC BY-NC-SA). | 2–3 |
| Edge refinement / hair and fur | **Build classical first** (guided-filter joint upsampling plus a trimap-band "Refine edge" brush). **Defer learned matting** (fine-tune only: every checkpoint is data-tainted). | Guided filtering is cheap and deterministic on Metal. The learned matting weights are all trained on research-only or NC matting sets. | Classical: 2–3. Learned: 8–12 (Phase 4) |
| Mask storage | 8-bit single-channel **PNG at 1536 px long edge** (2048 for people parts), computed from a canonical "analysis render", with full provenance. **Never silently recompute.** SAM embeddings go in a purgeable cache dir, not the sidecar. | Measured 37–47 KiB per subject mask at 1536 px. SAM 2.1 encoder outputs are about 8 MiB per image. | 2 (included in the Vision item above) |

**The biggest license finding:** outside Apple's system frameworks and Meta's own SAM/SAM 2/DINOv2 releases,
almost every usable checkpoint has a training-data chain that includes research-only or NC datasets
(SA-1B used by third parties, ADE20K, Cityscapes, Virtual KITTI 2, DIS5K, Adobe matting data). Redlamp needs an
explicit legal policy on "publisher-granted commercial weights trained on third-party data" before shipping
any of them (see §9).

---

## 1. Apple Vision and related system frameworks

### 1.1 Mask-relevant capability table (macOS/iOS 26, plus what is new in 27)

Availability comes from the DocC `platforms` field of each symbol. The Swift-native `…Request` structs are
listed as iOS 18 / macOS 15. The older `VN…` classes are older still: person segmentation dates from iOS 15 /
macOS 12, and foreground and person instance masks from iOS 17 / macOS 14. Measured values come from
`vbench.swift` on four CC0 Commons images (see §10). The inputs were full resolution (24–26 MP) and a 2048 px
downscale. Output sizes did not change with input size.

| Request | OS (Swift API) | Output | Measured output resolution | Measured warm time, M1 Ultra | Notes and limits (evidence) |
|---|---|---|---|---|---|
| `GenerateForegroundInstanceMaskRequest` (subject lifting) | iOS 18 / macOS 15 (VN: iOS 17 / macOS 14) | `InstanceMaskObservation`: UInt8 instance-label map. `generateScaledMask` gives a float soft mask at input resolution. | Label map **512×512** (`L008`). Scaled mask = input size (`L00f`). | 29–45 ms detect. Scale: 22–29 ms at 2 MP; 344 ms at 26 MP (cold). | "Class agnostic". Background = index 0 (WWDC23-10176). Found **no subject** in the crowd and the mountain-landscape test images. Vision "produces SDR outputs" (WWDC23-10176). |
| `GeneratePersonSegmentationRequest` | iOS 18 / macOS 15 (VN: iOS 15 / macOS 12) | Matte (`PixelBufferObservation`) covering all people | fast **256×192**, balanced **512×384**, accurate **2016×1512**. These are fixed 4:3 sizes, even for 3:2 and portrait inputs. | fast 8–12 ms, balanced 17–28 ms, accurate 51–74 ms | Apple recommends accurate "for computational photography" (WWDC21-10040). Also exposed as a Core Image filter (`CIPersonSegmentation`). |
| `GeneratePersonInstanceMaskRequest` | iOS 18 / macOS 15 (VN: iOS 17 / macOS 14) | Instance mask, one index per person | **512×384** | 128–135 ms (1 person), 508–515 ms (crowd) | "Up to four individual person masks". "When scenes contain many people, returned observations may miss people or combine them" (WWDC23-111241). The crowd image returned 4. |
| `GenerateAttentionBasedSaliencyImageRequest` / `…ObjectnessBased…` | iOS 18 / macOS 15 | Float heat map plus salient boxes | **68×68** | 5–16 ms | "fairly low resolution and as such, not suitable for segmentation" (WWDC23-10176). The VN docs say 64×64 in real time and 68×68 deferred. Good for auto-crop and for seeding prompts. |
| `DetectFaceLandmarksRequest` | iOS 18 / macOS 15 | 2D landmark regions (contour, eyes, brows, nose, lips outer/inner, pupils) | 76 points (rev 3) | 9–116 ms | "76-point constellation … accurate pupil detection" (WWDC21-10040). Basis for polygon masks of lips, eyes and brows. |
| `DetectFaceCaptureQualityRequest` | iOS 18 / macOS 15 | Scalar per face | – | not measured | "a comparative measure of the same subject" (WWDC21-10040). Useful for culling, not masks. |
| `DetectHumanBodyPoseRequest`, `DetectHumanBodyPose3DRequest`, `DetectHumanHandPoseRequest` | iOS 18 / macOS 15 (not watchOS) | Joint positions | – | not measured | Useful to split people into parts (e.g. separating arm/leg skin) and to seed prompts. Not masks. |
| `RecognizeAnimalsRequest`, `DetectAnimalBodyPoseRequest` | iOS 18 / macOS 15 | Labelled boxes / joints | – | 4–9 ms | Recognised "Dog" in the fur test image. The only mask for an animal comes from the foreground request. |
| `DetectHorizonRequest` | iOS 18 / macOS 15 | Angle plus transform | – | 7–11 ms | Returned **no result** for the CC0 mountain landscape. Treat it as a straighten hint only. |
| `CalculateImageAestheticsScoresRequest` | iOS 18 / macOS 15 | `overallScore`, `isUtility` | – | 8–60 ms | Culling aid, not masking. |
| `ClassifyImageRequest` | iOS 18 / macOS 15 | Image-level labels | – | 9–32 ms | Returns "sky", "blue_sky", "hill" and similar as **image-level labels only**. Useful to decide whether a Sky mask is offered. |
| `DetectLensSmudgeRequest` | **iOS/macOS 26** | Smudge score | – | not measured | The only new image-analysis request in the OS 26 release, besides `RecognizeDocumentsRequest` (26). Could feed dust/smudge warnings (workstream D). |
| **`GenerateIterativeSegmentationRequest`** ("tap-to-segment") | **iOS/iPadOS/macOS 27 only** | `PixelBufferObservation?` gray mask | Three `QualityLevel`s: fast = "low-resolution", balanced (default), accurate = "high-resolution". Exact sizes not documented. | not testable (this Mac runs 26.6) | Seeded by a point, box or scribble buffer. Refined with `addIncludedPoint` / `addExcludedPoint`. "maximum of 13 points when seeded with a point or scribble, or 11 points when seeded with a box". Lasso stroke "at least 1% of the total image width". Conforms to the new `DownloadableAssetsRequest`, so "before you perform a segmentation request for the first time on a device, you'll have to download the model" (WWDC26-237 transcript). Only `revision1` exists. |
| VisionKit `ImageAnalysisInteraction.subjects` (iOS 16) / `ImageAnalysisOverlayView.subjects` (macOS 13) | – | System subject-lift UI | – | – | "happens out-of-process … means the image size is limited" (WWDC23-10176). A UI convenience, not suitable for the engine. |

Sources: `vision.json` and per-symbol pages such as
<https://developer.apple.com/tutorials/data/documentation/vision/generateiterativesegmentationrequest.json>;
WWDC26 session 237 "What's new in image understanding"
(<https://developer.apple.com/videos/play/wwdc2026/237/>); WWDC23-10176 "Lift subjects from images in your app";
WWDC23-111241 "Explore 3D body pose and person segmentation in Vision"; WWDC21-10040 "Detect people, faces,
and poses using Vision". The sample code "Segmenting objects using taps, scribbles or rectangles" also
requires OS 27.

**Verified: Vision has no sky segmentation request.** None of the roughly 40 request types in `vision.json`
(OS 27 index) produces a sky, landscape, hair or clothing mask. The closest is `ClassifyImageRequest`'s
image-level "sky" label.

**Cold-start cost.** The first call of each request type in a process includes model load. We observed
1.7 s (person segmentation, fast) and 4.1 s (person instances). Warm them up on a background queue when the
develop module opens.

### 1.2 Running Vision on a high-resolution linear image

- **Evidence.** Every request takes a URL, `Data`, `CGImage`, `CVPixelBuffer`, `CMSampleBuffer` or `CIImage`
  (the `perform(on:orientation:)` overloads). Output sizes are fixed by the model (table above), whatever the
  input size. Full 24–26 MP input gave the same masks as a 2048 px input and costs extra decode time. Apple
  says outputs are SDR, and that compositing in Core Image "preserves the high dynamic range of the input"
  (WWDC23-10176).
- **Assessment.** Feed Vision a **display-referred 8-bit sRGB/P3 BGRA render, about 2048 px long edge**, from
  a canonical *analysis render*: default develop, as-shot white balance, baseline exposure, default tone
  curve, no user edits, uncropped. Do not pass scene-linear float. The models were almost certainly trained on
  display-referred images, and Apple does not document how linear half-float buffers are handled. Because the
  analysis render ignores user edits, masks do not shift when the user changes Exposure. That matches
  Lightroom's behaviour, where AI masks only change on an explicit "Update". Whether Vision colour-manages a
  linear `CIImage` correctly is an **open question** to test.

### 1.3 Capture-time mattes and auxiliary data we can read for free

| Source | What | Availability | Evidence |
|---|---|---|---|
| `AVSemanticSegmentationMatte` types **hair, skin, teeth, glasses** | 8-bit mattes (`OneComponent8`) stored as auxiliary images | **Produced only at capture**: `AVCapturePhotoOutput.enabledSemanticSegmentationMatteTypes` (iOS 13; no macOS entry). Reading them from files works on macOS 10.15+ through `init(fromImageSourceAuxiliaryDataType:…)`. | DocC `avsemanticsegmentationmatte`, `…/enabledsemanticsegmentationmattetypes`: "Enabling semantic segmentation matte delivery requires a lengthy reconfiguration of the capture render pipeline." |
| ImageIO `kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte` | Sky matte auxiliary type | Defined since iOS 14.1 / macOS 11. **No public AVFoundation matte type for sky**: `AVSemanticSegmentationMatte.MatteType` lists only hair/skin/teeth/glasses. | DocC `imageio/kcgimageauxiliarydatatypesemanticsegmentationskymatte`. **Unverified** whether Apple's Camera writes sky mattes into HEIC or ProRAW files. Needs self-shot samples. |
| `kCGImageAuxiliaryDataTypePortraitEffectsMatte` | Person matte from Portrait mode | iOS 12 / macOS 10.14 | DocC ImageIO |
| `kCGImageAuxiliaryDataTypeDepth` / `…Disparity` (`AVDepthData`) | Depth or disparity map | iOS 11 / macOS 10.13 | "Images captured by Camera app, like Portrait images in photos, always store Depth as disparity maps with camera calibration metadata" (WWDC23-111241) |

**Assessment.** Implement an "embedded auxiliary data" reader in Phase 2. When a file already carries hair,
skin, teeth, glasses, sky, portrait or depth data, the corresponding Lightroom mask is free and
capture-accurate. It will cover a minority of files, mostly iPhone HEIC. Whether ProRAW DNGs carry depth or
mattes needs self-shot test files (**open question**).

### 1.4 Gap analysis against Lightroom mask types

The Lightroom taxonomy is taken from our `docs/lightroom-feature-inventory.md` §14. Adobe's help pages
returned "Access Denied" to our fetch, so we could **not** re-verify the exact Landscape and People-parts lists.

| Lightroom mask | Apple coverage (OS 26) | OS 27 | Gap / our plan |
|---|---|---|---|
| Subject | ✅ Foreground instance mask. 512² label map, soft scaled mask. | – | Edge refinement (§5). Fails on crowds and landscapes (measured). |
| Background | ✅ Invert of Subject | – | – |
| Sky | ❌ No request. Only the image-level label. The ImageIO sky matte helps only if embedded. | ❌ | **Build** a sky head (§3) |
| Objects (brush/rectangle select) | ❌ | ✅ Iterative segmentation (box, scribble, points) | SAM 2.1 on OS 26 (§2) |
| People: individual persons | ⚠️ Up to 4 instances at 512×384. Single all-people matte at 2016×1512. | – | Beyond 4 people: fall back to the all-people matte, or SAM prompts seeded from face/body boxes |
| Face skin | ⚠️ Derived: face-contour polygon ∩ person matte, minus eye/brow/lip polygons | – | Heuristic in Phase 2. Learned head in Phase 3. |
| Body skin | ❌ Skin matte is capture-only | – | Build (people-parts head) |
| Eyebrows | ⚠️ Landmark polylines, dilated | – | Heuristic |
| Eye sclera | ⚠️ Eye polygon minus iris disc (pupil landmark plus estimated radius) | – | Heuristic. Learned later. |
| Iris and pupil | ⚠️ Pupil landmarks plus radius | – | Heuristic |
| Lips | ✅ (derived) outer/inner lip polygons | – | – |
| Teeth | ⚠️ Inner-lip polygon ∩ bright/low-saturation pixels. The teeth matte is capture-only. | – | Heuristic, then learned |
| Hair | ❌ Hair matte is capture-only | – | Build plus matting (§5) |
| Clothes | ❌ | – | Build: person − skin − hair, or learned |
| Landscape: Mountains, Water, Vegetation, Natural ground, Artificial ground, Architecture, Sky | ❌ | ❌ | **Build** a multi-class head (§3) |
| Depth Range | ⚠️ Only when depth is embedded | – | Monocular depth (§4) |

---

## 2. SAM-class "hover to select any object"

### 2.1 Shortlist

Params are taken from the repos. "SA-1B use" says who trained on SA-1B, which matters for the risk in §2.3.

| Candidate | Code license | Weights license | Training data | Params / quality evidence | Apple Silicon evidence | Verdict |
|---|---|---|---|---|---|---|
| **SAM 2.1** (Hiera T/S/B+/L) — facebookresearch/sam2, arXiv 2408.00714 | Apache-2.0 | README: "The SAM 2 model checkpoints … are licensed under Apache 2.0" | SA-1B + SA-V (CC BY 4.0), trained **by Meta** (the data owner) | 38.9 / 46 / 80.8 / 224.4 M. SA-V test J&F 76.5 / 76.6 / 78.2 / 79.5 (README, A100). | **Official Core ML packages**: `apple/coreml-sam2.1-{tiny,small,baseplus,large}`, Apache-2.0, fp16. Encoder packages are 67 / 82 / 153 / 445 MB; prompt encoder 2.1 MB; mask decoder 10.3 MB. **Our timings in §2.2.** | **Shippable** (with the publisher-grant caveat in §9). **Top pick.** |
| SAM (v1) — segment-anything, arXiv 2304.02643 | Apache-2.0 | README: "The model is licensed under the Apache 2.0 license" | SA-1B (by Meta) | ViT-H encoder 632M | RepViT-SAM repo: ViT-B-SAM encoder **6249.5 ms on an M1 Pro MacBook** and OOM on iPhone 12 | Shippable but obsolete. Superseded by SAM 2.1. |
| SAM 3 / 3.1 — facebookresearch/sam3, arXiv 2511.16719 | **SAM License** (custom, 2025-11-19) | Same. HF `facebook/sam3` is **gated (manual)**. | SA-Co data engine ("4M unique concept labels") | 848M params (README). Text/concept prompts, which enables "sky", "water" etc. | None published. Far too large for iPhone. | **UNCLEAR.** Commercial use is granted, but there are pass-through terms ("you may only do so under the terms of this Agreement"), a restriction that use "will not involve or encourage others to reverse engineer, decompile or discover the underlying components", trade-control clauses and gating. Possible **offline labelling tool** (legal review needed). Not for shipping. |
| EfficientSAM — yformer/EfficientSAM, arXiv 2312.00863 | Apache-2.0 | HF card apache-2.0 | SAMI pre-training on ImageNet-1K, then "finetune the models on SA-1B" (abstract) | ViT-T/ViT-S | ONNX split encoder/decoder exists. No Apple timing. | **UNCLEAR** (ImageNet terms; third-party SA-1B use) |
| MobileSAM — ChaoningZhang/MobileSAM, arXiv 2306.14289 | Apache-2.0 | Repo Apache-2.0, but the third-party HF mirror `dhkim2810/MobileSAM` says MIT (contradiction) | 1% SA-1B distillation (EdgeSAM table) by a third party | Encoder 5M. "8ms on the image encoder and 4ms on the mask decoder" on a GPU (README). | RepViT-SAM repo: **OOM on iPhone 12, 482.2 ms on M1 Pro** via Core ML | **UNCLEAR** (third-party SA-1B use) |
| EdgeSAM — chongzhou96/EdgeSAM, arXiv 2312.06660 | **S-Lab License 1.0**: "Redistribution and use for non-commercial purpose" | Same (no license on the HF repo) | 1–10% SA-1B | 9.6M. "first SAM variant that can run at over 30 FPS on an iPhone 14" (38.7 FPS table) | Best published iPhone number | **Research-only** (cannot ship). Useful as a latency reference. |
| EfficientViT-SAM — mit-han-lab/efficientvit, arXiv 2402.05008 | Apache-2.0 | HF apache-2.0 | SA-1B (plus COCO/LVIS for evaluation) by MIT | L0 34.8M (512²) … XL1 203.3M (1024²). COCO mAP 45.7–47.8. | Only Jetson/A100 TensorRT numbers | **UNCLEAR** (third-party SA-1B use) |
| RepViT-SAM — THU-MIG/RepViT, arXiv 2312.05760 | Apache-2.0 | Repo releases | SA-1B distillation (MobileSAM recipe) | – | **Encoder 48.9 ms on iPhone 12, 44.8 ms on M1 Pro; decoder 11.6 / 11.8 ms** (Core ML, 1024²; repo table). The best published Apple numbers. | **UNCLEAR** (third-party SA-1B use). Architecture is a good template for our own ANE-friendly encoder. |
| TinySAM — xinghaochen/TinySAM, arXiv 2312.13789 | Apache-2.0 | Apache-2.0 (README) | SA-1B distillation (third party) | – | – | **UNCLEAR** |
| SAM-HQ / Light HQ-SAM — SysCV/sam-hq, arXiv 2306.01567 | Apache-2.0 | HF apache-2.0 | HQSeg-44K, which includes **DIS5K ("non-commercial use in research or educational purpose")** | Light HQ-SAM 41.2 FPS (GPU) | – | **Fine-tune only** (the HQ token idea is reusable, not the weights) |

Sources: the license API and READMEs for each repo; the HF API for each model; EdgeSAM README table; RepViT
`sam/README.md` latency table.

### 2.2 Measured: Apple's SAM 2.1 Core ML packages on the M1 Ultra

Package I/O, read from `model.mlmodel` with coremltools. The input is a 1024×1024 RGB image. The encoder
outputs `image_embedding` [1,256,64,64], `feats_s0` [1,32,256,256] and `feats_s1` [1,64,128,128], all fp16.
The prompt encoder accepts 1–16 points. The decoder outputs `low_res_masks` [1,3,256,256] plus 3 scores. The
packages were converted with coremltools 7.2 from TorchScript (torch 2.4.0). `bench.swift` used a synthetic
1024² image. We report the median of 7 encoder runs and of 20 prompt runs (moving point).

| Variant | Compute units | Encoder median | Prompt enc + mask dec | First load |
|---|---|---|---|---|
| tiny | cpuAndGPU | **57.8 ms** | **0.66 + 10.95 = 11.6 ms** | 0.35 s |
| tiny | cpuAndNeuralEngine | 163.1 ms | 0.68 + 57.75 = 58.4 ms | **302 s** (ANE compile) |
| tiny | all | 196.9 ms | 15.2 ms | 11 s |
| small | cpuAndGPU | **68.3 ms** | **0.63 + 8.42 = 9.1 ms** | 0.48 s |
| small | cpuAndNeuralEngine | 188.9 ms | 60.2 ms | **353 s** |
| small | all | 255.5 ms | 15.5 ms | 12 s |

Findings:
- **The hover budget (<50 ms per prompt) is met on the GPU** with a wide margin: 9–12 ms on M1 Ultra.
- **These packages are not ANE-friendly.** The ANE is 3× slower than the GPU for the encoder. The decoder on
  the ANE logs `E5RT … Failed to PropagateInputTensorShapes … conv_transpose` and takes 58 ms. `.all` is worse
  than GPU-only. The first ANE load spent 5–6 minutes compiling. Caveat: our harness recompiled each run to a
  fresh temp path, which may have defeated the OS's ANE cache (**to re-test**).
- **Assessment:** for Phase 3, ship the GPU path (`cpuAndGPU`) for both halves. Put an ANE-optimised re-export
  of the encoder on the backlog (static shapes, ANE-friendly attention layout, int8/palettised weights), mainly
  for iPhone power and thermals. iPhone A17 Pro timings are **unmeasured**. RepViT-SAM's 48.9 ms encoder on an
  iPhone 12 suggests an ANE-first encoder can reach well under 100 ms on phones.

### 2.3 SA-1B / SA-V data risk

- **Evidence.** The SA-1B data card says "Intended Use Cases: Research purposes only" and "The images are
  licensed from a large photo company". The segment-anything README says: "By downloading the datasets you
  agree that you have read and accepted the terms of the SA-1B Dataset Research License"
  (<https://ai.meta.com/datasets/segment-anything/>). The full license page is JavaScript-rendered and we
  **could not retrieve its text**. SA-V: "The videos and annotations in SA-V Dataset are released under
  CC BY 4.0" (`sam2/sav_dataset/README.md`).
- **Assessment.** For **SAM / SAM 2 / SAM 2.1**, Meta is both the data licensee and the model publisher, and
  it chose to release the checkpoints as Apache-2.0. The research-only terms bind people who *download
  SA-1B*, not users of Meta's checkpoints. That is a low, publisher-assumed risk. For **third-party
  distillations** (MobileSAM, EfficientViT-SAM, RepViT-SAM, TinySAM, EdgeSAM), the authors trained on SA-1B
  *as licensees under research-only terms* and then released Apache weights. Whether they were entitled to do
  that is doubtful, so we mark them **UNCLEAR**. If we distil our own small encoder, we should distil **from
  SAM 2.1 on images we have rights to** (our own captures, CC BY/CC0 sets), not on SA-1B.

### 2.4 Can the image embedding be cached?

- SAM 2.1 needs all three encoder outputs for the decoder:
  256·64·64·2 B = **2 MiB** (`image_embedding`), plus 32·256·256·2 B = **4 MiB**, plus
  64·128·128·2 B = **2 MiB**, so **8 MiB per image** in fp16. SAM v1-style models (MobileSAM, RepViT-SAM,
  EfficientSAM) need only the 2 MiB embedding.
- **Recommendation.** Do **not** put embeddings in the sidecar. They are derived, large, model-specific and
  recomputable in about 60–70 ms on an M-series GPU. Keep them in memory for the open image, plus an LRU
  cache in `Caches/` (purgeable, capped at around 1–2 GB), keyed by `analysisRenderHash + modelId`. The
  sidecar stores only the **prompts** (normalised points/box/scribble) and the **resulting mask bitmap**
  (§6).

### 2.5 Recommendation (Objects mask)

1. On OS 27, use `GenerateIterativeSegmentationRequest` for box/scribble/click selection. Handle
   `assetStatus` and `downloadAssets(progress:)`. The download comes from Apple, and inference stays
   on-device, so it is consistent with our privacy stance. Pin `revision1`.
2. On OS 26, and as a quality benchmark on 27, use **SAM 2.1 tiny** (or small) from `apple/coreml-sam2.1-*`.
   The encoder runs at P3 when an image opens. The decoder runs on each hover or tap on the GPU.
3. Run a Phase 3 bake-off: Vision iterative vs SAM 2.1 tiny/small on our test set (IoU, boundary F-score,
   clicks-to-90%-IoU, latency on A17 Pro and M1). If Vision is as good, SAM becomes the OS 26 fallback only.

---

## 3. Sky, background and landscape categories

### 3.1 Shortlist

| Candidate | Code license | Weights license | Training data (terms) | Quality evidence | Apple fit | Verdict |
|---|---|---|---|---|---|---|
| **DINOv2** ViT-S/B/L/g (facebookresearch/dinov2, arXiv 2304.07193) + our head | Apache-2.0 | README: "DINOv2 code and model weights are released under the Apache License 2.0" | LVD-142M, curated by Meta, not released | Frozen features + **linear head, ADE20K mIoU: ViT-S 44.3 (47.2 +ms), ViT-B 47.3 (51.3), ViT-L 47.7 (53.1)**. With Mask2Former + ViT-Adapter on ViT-g: 60.2 (paper Table 10). | ViT-S/14 is 22M params, small enough for the ANE. Core ML conversion is routine (Apple's DA-V2 Small package is DINOv2-S + DPT). | **Shippable backbone** (publisher grant). **Recommended.** |
| SAM 2.1 Hiera encoder (already computed for hover) + our head | Apache-2.0 | Apache-2.0 | As §2 | No published semantic-segmentation probe results | Zero extra encoder cost if hover is enabled | **Shippable.** Prototype against DINOv2-S. |
| DINOv3 (arXiv 2508.10104) | **DINOv3 License** (custom, 2025-08-19). Same shape as the SAM License: commercial grant, pass-through, "will not … reverse engineer", trade controls. | Same. HF gated (manual). | LVD-1689M | – | – | **UNCLEAR.** Evaluate only after legal review. |
| Mask2Former (arXiv 2112.01527) | MIT | HF `facebook/mask2former-*` cards say "other". No separate weights license. | ADE20K ("non-commercial research and educational purposes"), COCO (Flickr ToU), Cityscapes ("non-commercial purposes") | SOTA-class | Heavy (Swin-L) | **Fine-tune only** (architecture) |
| OneFormer (arXiv 2211.06220) | MIT | HF card says MIT, but it is trained on ADE20K/Cityscapes/COCO. **Contradiction.** | NC datasets | – | Heavy | **Fine-tune only** |
| SegFormer (arXiv 2105.15203) | **NVIDIA Source Code License**: "may be used or intended for use non-commercially … 'non-commercially' means for research or evaluation purposes only" | HF "other" (same) | ADE20K/Cityscapes | – | Light | **Avoid** (code NC). A clean-room reimplementation from the paper would be possible. |
| SegGPT (BAAI/Painter) | MIT | HF MIT | ADE20K, COCO, etc. | – | Heavy | **Fine-tune only** |
| Grounded-SAM / OpenSeeD / SAN / CAT-Seg / FC-CLIP | Apache / Apache / MIT / MIT / Apache | Various | COCO panoptic plus CLIP/Grounding-DINO training sets | Open vocabulary | Too heavy for interactive on-device use | **Fine-tune only / UNCLEAR**. Not a product path. |
| OWL-ViT / OWLv2 (arXiv 2306.09683) | Apache-2.0 (scenic) | HF apache-2.0 | WebLI (Google internal) plus detection sets | Boxes only | Medium | **UNCLEAR**. Boxes only, so it would need SAM behind it. |
| Florence-2 base/large (arXiv 2311.06242) | – | HF MIT | FLD-5B (Microsoft-built from public images) | Captioning, grounding, polygon segmentation | 0.23B / 0.77B | **UNCLEAR data.** Candidate **offline labelling assistant**. |
| DA3MONO-LARGE / DA3METRIC-LARGE (Depth Anything 3) | Apache-2.0 | HF apache-2.0, **with a sky-segmentation output** | "trained exclusively on public academic datasets" (README) | Sky mask comes free with depth | 0.35B, a Mac-class model | **UNCLEAR data.** Useful as a teacher or benchmark. |

### 3.2 Datasets

| Dataset | Terms (verbatim) | Usable for training? |
|---|---|---|
| ADE20K | "Researcher shall use the Database only for non-commercial research and educational purposes." Plus: "If Researcher is employed by a for-profit, commercial entity, Researcher's employer shall also be bound." Annotations BSD-3. (groups.csail.mit.edu/vision/datasets/ADE20K/terms) | **No** (not even internal evaluation without legal OK) |
| Cityscapes | "freely available to academic and non-academic entities for non-commercial purposes" (cityscapes-dataset.com/license) | **No** |
| COCO / COCO-Stuff | COCO: "annotations … licensed under a Creative Commons Attribution 4.0 License … Use of the images must abide by the Flickr Terms of Use". COCO-Stuff: annotations "Creative Commons Attribution 4.0". The COCO format carries a **per-image `license` id** (cocodataset.org format-data). | **Maybe.** Filter to images whose per-image license is CC BY / CC BY-SA / public domain. The stuff classes (sky, clouds, mountain, water, sea, river, grass, tree, dirt, sand, road, pavement, building…) map well onto Lightroom Landscape. Legal to confirm. |
| Open Images V7 | "The annotations are licensed by Google LLC under CC BY 4.0 license. The images are listed as having a CC BY 2.0 license" (with a no-warranty caveat). 2.8M instance masks, 350 classes. 66.4M point labels, 5,827 classes. | **Yes, with per-image attribution** (object classes. Whether stuff classes such as sky appear in the point labels is unverified). |
| SA-V | CC BY 4.0 | Yes (video frames. Masks are class-agnostic.) |
| SkyFinder (WACV 2016) | Site states no license. Images come from AMOS webcams. 53 static cameras with one mask per camera. | **UNCLEAR** and low diversity |
| Mapillary Vistas | Could not fetch terms (JS page) | **Unverified.** Believed NC; do not assume. |

### 3.3 Recommendation

**Build** (Phase 3, with Sky first because the inventory marks it P2):
1. A **sky head**: binary plus soft edge, on DINOv2 ViT-S/14 (or the SAM 2.1 encoder, whichever wins a
   2-week probe). Use a DPT-lite decoder at 1/4 resolution, then guided refinement (§5). Sky edges against
   trees and hair need matting-quality refinement.
2. **Data:** 3–5k of our own and CC-licensed images (Open Images V7, COCO-Stuff CC BY subset, Commons
   CC0/CC BY). Labels are drafted by SAM 2.1 point prompts plus a human pass. SAM 3 or Florence-2 could
   pre-label concepts only if legal clears using their outputs as training labels.
3. **Extend** the same head to the Landscape classes and to the people parts (hair, skin, clothes, teeth,
   sclera) in Phase 3/4. This is data-bound: people parts need consented portraits, since popular face-parsing
   sets are typically NC (not audited here).
4. **Interim** for a Phase 2 "Sky" if needed: use the embedded ImageIO sky matte when present. Otherwise use a
   classical sky estimator (blue/bright, low-texture region grown from the top edge, gated by
   `ClassifyImageRequest` "sky") with a SAM prompt fallback. **Assessment:** fine for clear skies, poor at
   tree lines.

---

## 4. Depth (Depth Range mask and lens blur)

### 4.1 Shortlist

| Candidate | Code license | Weights license (source) | Training data | Evidence | Apple fit | Verdict |
|---|---|---|---|---|---|---|
| **Depth Anything V2 Small** (arXiv 2406.09414) | Apache-2.0 | README: "Depth-Anything-V2-Small model is under the Apache-2.0 license. Depth-Anything-V2-Base/Large/Giant models are under the CC-BY-NC-4.0 license." HF Small `apache-2.0`, Base/Large `cc-by-nc-4.0`. | Teacher trained on 595K synthetic images, **including VKITTI 2 ("non-commercial purposes only … CC BY-NC-SA 3.0")**. Student trained on 62M pseudo-labelled real images, including SA-1B, ImageNet-21K, Places365, LSUN, BDD100K and Open Images (paper Table 7). | 24.8M params | **Apple Core ML package** `apple/coreml-depth-anything-v2-small` (Apache-2.0; F16 49.8 MB, palettised 19–25 MB). Apple-published: **31.1 ms iPhone 12 Pro Max, 33.9 ms iPhone 15 Pro Max, 32.8 ms M1 Max, 24.6 ms M3 Max, "Dominant compute unit: Neural Engine"**, input 518×396. | **UNCLEAR data → ship only under a publisher-grant policy.** Best practical choice. |
| DA-V2 Base/Large | Apache-2.0 | CC-BY-NC-4.0 | – | – | – | **Research-only** |
| DA-V2 Metric Hypersim/VKITTI (S/L) | Apache-2.0 | HF cards say `apache-2.0` even for **Large**, which is fine-tuned from the NC Large model, and VKITTI is NC | – | – | – | **UNCLEAR (contradiction)** |
| **Depth Anything 3** (ByteDance-Seed, arXiv 2511.10647) | Apache-2.0 | README table: DA3-Small 0.08B **Apache 2.0**, DA3-Base 0.12B **Apache 2.0**, DA3MONO-LARGE / DA3METRIC-LARGE 0.35B **Apache 2.0** (with sky seg), DA3-Large/Giant **CC BY-NC 4.0**. HF `DA3-LARGE-1.1` says `apache-2.0` while the README says CC BY-NC 4.0 (**contradiction**). | "public academic datasets" | Claims to beat DA2 on monocular depth (README) | No Core ML conversion found | **UNCLEAR data.** Evaluate DA3-Small/Base against DA2-S. |
| Depth Pro (apple-aiml-research/ml-depth-pro, arXiv 2410.02073) | Apple sample-code-style license (permissive: "use, reproduce, modify and redistribute") | HF `apple/DepthPro`: `apple-amlr`: "exclusively for Research Purposes … 'Research Purposes' does not include any commercial exploitation, product development or use in any commercial product" | Real plus synthetic | "2.25-megapixel depth map in 0.3 seconds on a standard GPU" (abstract). Best boundary sharpness. | Heavy (ViT-L multi-scale) | **Research-only.** Even internal benchmarking for product development appears excluded; ask legal first. |
| MoGe-2 (microsoft/MoGe, arXiv 2507.02546) | MIT (plus Apache parts) | HF `Ruicheng/moge-2-vit{s,b,l}-normal`: MIT | "large corpus of mixed" real plus synthetic (abstract; not audited) | Metric point maps, sharp details | ViT-S variant is feasible | **UNCLEAR data.** Evaluate. |
| MiDaS v3.x (isl-org) | MIT | Intel/dpt-* on HF: apache-2.0 | Multi-dataset mix (not audited) | Older | Light | **UNCLEAR** |
| ZoeDepth | MIT | HF MIT | MiDaS plus NYU/KITTI | – | – | **Fine-tune only** (KITTI is NC) |
| Metric3D v2 | BSD-2-Clause | Not stated on HF | 16M images from many datasets (not audited) | – | Heavy | **UNCLEAR** |
| UniDepth | **CC BY-NC 4.0** | – | – | – | – | **Avoid** |
| Marigold (prs-eth, arXiv 2312.02145) | Apache-2.0 | HF v1.1 `openrail++` (Stable Diffusion 2 lineage), LCM v1.0 `apache-2.0` | SD2 base (LAION) plus synthetic | Diffusion, multi-step | ~1B params, seconds per image | **UNCLEAR** and too heavy |
| Lotus (arXiv 2409.18124) | Apache-2.0 | HF apache-2.0, but SD2-derived | – | – | Heavy | **UNCLEAR** |
| DepthCrafter (Tencent) | "only for academic, research and education purposes" | Same | – | – | – | **Avoid** |
| Video Depth Anything | Apache-2.0 | HF Small apache-2.0, Base/Large cc-by-nc-4.0 | – | Video | – | Not needed (stills) |

### 4.2 Recommendation

1. **Phase 2/3: read embedded depth** (`AVDepthData` disparity/depth) plus portrait mattes. These drive the
   Depth Range mask exactly as Lightroom's "images with depth maps" does.
2. **Phase 3: add DA-V2 Small** (Apple Core ML package) for images without depth. Run it on the
   ~518 px analysis render, then guided-upsample it against full-resolution luminance. It supports Depth Range
   (relative depth is enough) and rough lens blur. **Gate on legal sign-off** (§9).
3. **Evaluate** DA3-Small/Base and MoGe-2-ViT-S for edge sharpness at depth discontinuities, which matters
   most for lens blur. Depth Pro serves only as a research reference if legal allows.
4. Owning a depth model outright would need a synthetic dataset we render ourselves (teacher and student).
   Distilling from any tainted teacher inherits the taint. **Defer.**

---

## 5. Edge refinement and matting (hair and fur)

### 5.1 Classical

- **Guided filter** (He, Sun, Tang, ECCV 2010 / TPAMI 2013, DOI 10.1109/TPAMI.2012.213): O(N) edge-aware
  filter. Used for **joint upsampling** of low-resolution masks against the full-resolution guide, and for
  alpha refinement in an uncertain band. Maps well to Metal (box filters). Deterministic.
- **Fast bilateral solver** (Barron & Poole, arXiv 1511.03296): "10-1000 times faster than competing
  approaches", with semantic-segmentation refinement demonstrated. It is more complex (bilateral grid plus
  preconditioned conjugate gradient).
- **Patents: not verified.** The Google Patents endpoints were not reachable from our environment. A
  freedom-to-operate check is needed for both methods, the guided filter (Microsoft Research) and the bilateral
  solver (Google), before we ship either. **Open question.**
- **Assessment / recommendation: build.** Phase 2 needs three pieces:
  1. Render-time guided joint upsampling of every AI mask, with radius and epsilon tied to image scale.
  2. A "Refine edge" brush that builds a trimap by eroding and dilating the coarse mask, then solves alpha in
     the band with a guided filter on colour. The upgrade path is a closed-form-matting-style local solve.
  3. Decontamination is **not** needed. We adjust in place, we do not composite.

### 5.2 Learned matting shortlist

| Candidate | Code | Weights | Training data (terms) | Verdict |
|---|---|---|---|---|
| ViTMatte (hustvl, arXiv 2305.15272) | MIT | HF apache-2.0 | Composition-1k (Adobe Deep Image Matting set; distributed on request, terms not published on the project page, commonly research-only) / Distinctions-646 ("If you use it for non-commercial uses, please send us an email") | **Fine-tune only** (a good architecture for a trimap-band refiner) |
| BiRefNet (ZhengPeng7, arXiv 2401.03407) | MIT | HF MIT (all variants) | General models trained on **DIS5K ("non-commercial use in research or educational purpose")**, DUTS, HRSOD, P3M-10k, AM-2k, Distinctions-646 and others (README) | **Fine-tune only** |
| RMBG-1.4 / 2.0 (BRIA) | – | 1.4: "source-available model for non-commercial use", with a paid commercial license. 2.0: CC BY-NC 4.0 (gated) | BRIA-licensed data | **Research-only**, unless we buy a commercial license (which conflicts with open-source redistribution) |
| MODNet (arXiv 2011.11961) | Apache-2.0 | Xenova/modnet apache-2.0 | "trained on the datasets mentioned in our paper" (Adobe matting data) | **Fine-tune only** |
| MatAnyone (arXiv 2501.14677) | **S-Lab License 1.0 (non-commercial)** | – | – | **Avoid** |
| Matting Anything (arXiv 2306.05399) | MIT | – | Matting sets (not audited) | **UNCLEAR** |
| Matte-Anything (arXiv 2306.04121) | MIT | Uses SAM plus ViTMatte weights | Inherits ViTMatte's data | **Fine-tune only** |

Dataset terms: **P3M-10k** and **AM-2k** agreements say "The Dataset is under MIT license", but also that
"The copyright of the images in the Dataset belongs to the original owners" and that the set is "aimed to aid
research". That makes image rights **UNCLEAR**, so use them for evaluation at most. **DIS5K**: "commercial use
of this dataset is prohibited even after copying, editing, processing".

**Recommendation.** Defer learned matting to Phase 4. When we do it, train a small ViTMatte-style band
refiner on our own data: studio/greenscreen captures of hair and fur we shoot, plus synthetic composites of
licensed foregrounds. Effort: 8–12 eng-weeks plus data capture.

---

## 6. Mask storage, caching and re-derivation

Measured with `msize.swift`: Vision subject masks (soft float, converted to 8-bit) encoded with ImageIO.

| Mask | Size | PNG | HEIC q=1.0 | HEIC q=0.9 |
|---|---|---|---|---|
| Dog (fur) | 1536×1024 | 37 KiB | 30 KiB | 12 KiB |
| Dog | 3072×2048 | 118 KiB | 93 KiB | 24 KiB |
| Portrait (hair) | 1536×1289 | 47 KiB | 36 KiB | 14 KiB |
| Portrait | 3072×2577 | 149 KiB | 108 KiB | 29 KiB |

Recommendations:
1. **Compute AI masks on the analysis render** (§1.2): uncropped, in sensor orientation, stored in normalised
   coordinates, so crop and rotate never invalidate them.
2. **Store 8-bit single-channel PNG** (lossless, deterministic decode). Use a 1536 px long edge by default and
   2048 px for people parts and sky. HEIC q=1.0 is not guaranteed lossless, and lossy HEIC rings at soft edges.
   None of Apple's native mask outputs exceeds 2016×1512 anyway.
3. **Refine at render time**: bilinear upsample, then a guided filter against full-resolution luminance at
   the render scale. Store only the refinement parameters. A 24 MP mask never goes in the sidecar.
4. **Sidecar placement**: prefer a sidecar *bundle*, with JSON plus `masks/<sha256>.png`. If the sidecar must
   be one JSON file, embed base64 PNG. That adds 33%, roughly 50–65 KiB per mask at 1536 px.
5. **Provenance per AI mask**: `{kind, provider ("apple.vision" | "redlamp.sam2.1-tiny" | …),
   request/revision or modelId + modelVersion + weightsSHA, OS build (Vision), qualityLevel, prompts
   (normalised points/box/scribble), analysisRenderHash, maskSHA, createdAt}`.
6. **Model-change policy**:
   - If the cached bitmap exists, **always use it**. This keeps renders reproducible across devices and OS
     versions.
   - If it is missing but the same model version is available, recompute.
   - If only a newer model is available, recompute, mark the mask "regenerated", and show a badge.
   - Offer "Update AI masks" (single or batch) as an explicit user action, mirroring Lightroom's
     update-on-sync.
   - Vision models can change with OS updates even at the same `revision`, so treat the OS build as part of
     the version.
7. **SAM embeddings**: in the cache directory only (§2.4).

---

## 7. License matrix

| Candidate | Code license (source) | Weights license (source) | Training data (terms) | Obligations (attribution, patents) | Verdict |
|---|---|---|---|---|---|
| Apple Vision / VisionKit / AVFoundation / ImageIO / Core Image | System SDK | System SDK | Apple | Apple SDK agreement. OS 27 iterative segmentation downloads an Apple model. | **Shippable** |
| SAM 2.1 (facebookresearch/sam2) | Apache-2.0 (license API) | Apache-2.0 (README "model checkpoints … Apache 2.0") | SA-1B (Meta-owned, research terms for third parties) + SA-V CC BY 4.0 | Apache NOTICE and attribution. Apache patent grant. | **Shippable** (publisher grant) |
| apple/coreml-sam2.1-* | – | Apache-2.0 (HF card) | as SAM 2.1 | as above | **Shippable** (publisher grant) |
| SAM v1 | Apache-2.0 | Apache-2.0 (README) | SA-1B (Meta) | as above | Shippable (publisher grant). Too heavy. |
| SAM 3 / 3.1 | SAM License (LICENSE, 2025-11-19) | SAM License. HF gated. | SA-Co | Pass-through of the agreement. "acknowledge the use of SAM Materials in your publication". No-reverse-engineering clause. Trade controls. | **UNCLEAR** |
| EfficientSAM | Apache-2.0 | Apache-2.0 (HF) | ImageNet-1K + SA-1B | Apache | **UNCLEAR** |
| MobileSAM | Apache-2.0 | Apache-2.0 (repo), MIT (third-party HF mirror) | 1% SA-1B (third party) | Apache | **UNCLEAR** |
| EdgeSAM | S-Lab 1.0 ("non-commercial purpose") | same | SA-1B | – | **Research-only** |
| EfficientViT-SAM | Apache-2.0 | Apache-2.0 (HF) | SA-1B (third party) | Apache | **UNCLEAR** |
| RepViT-SAM | Apache-2.0 | repo releases (Apache) | SA-1B (third party) | Apache | **UNCLEAR** |
| TinySAM | Apache-2.0 | Apache-2.0 (README) | SA-1B (third party) | Apache | **UNCLEAR** |
| SAM-HQ | Apache-2.0 | Apache-2.0 (HF) | HQSeg-44K incl. DIS5K (NC) | – | **Fine-tune only** |
| DINOv2 | Apache-2.0 | Apache-2.0 (README) | LVD-142M (Meta) | Apache | **Shippable** (publisher grant) |
| DINOv3 | DINOv3 License | DINOv3 License (HF gated) | LVD-1689M | Same clauses as the SAM License | **UNCLEAR** |
| Mask2Former | MIT | HF "other" | ADE20K / Cityscapes (NC), COCO (Flickr) | – | **Fine-tune only** |
| OneFormer | MIT | HF MIT (contradicts the data) | ADE20K / Cityscapes / COCO | – | **Fine-tune only** |
| SegFormer | NVIDIA SCL (NC) | NVIDIA SCL | ADE20K / Cityscapes | – | **Avoid** |
| SegGPT | MIT | MIT (HF) | ADE20K, COCO … | – | **Fine-tune only** |
| OWLv2 | Apache-2.0 | Apache-2.0 (HF) | WebLI + detection sets | – | **UNCLEAR** |
| Florence-2 | – | MIT (HF LICENSE) | FLD-5B | MIT notice | **UNCLEAR** (labelling tool only) |
| Grounded-SAM / OpenSeeD / SAN / CAT-Seg / FC-CLIP | Apache / Apache / MIT / MIT / Apache | various | COCO + CLIP data | – | **Fine-tune only / UNCLEAR** |
| Depth Anything V2 Small | Apache-2.0 | Apache-2.0 (README + HF) | VKITTI 2 (CC BY-NC-SA), SA-1B, ImageNet-21K, … | Apache | **UNCLEAR** (policy decision) |
| Depth Anything V2 Base/Large | Apache-2.0 | CC-BY-NC-4.0 | – | – | **Research-only** |
| apple/coreml-depth-anything-v2-small | – | Apache-2.0 (HF) | as DA-V2 Small | Apache | **UNCLEAR** (policy decision) |
| Depth Anything 3 Small/Base/Mono-L/Metric-L | Apache-2.0 | Apache-2.0 (README table + HF) | "public academic datasets" | Apache | **UNCLEAR** |
| Depth Anything 3 Large/Giant | Apache-2.0 | CC BY-NC 4.0 (README). HF 1.1 says apache (contradiction). | – | – | **Research-only** |
| Depth Pro | Apple sample-code-style license (LICENSE) | Apple ML Research Model License (HF `apple-amlr`, research only) | real + synthetic | Attribution notice required | **Research-only** |
| MoGe-2 | MIT | MIT (HF) | mixed 3D datasets (not audited) | MIT | **UNCLEAR** |
| MiDaS | MIT | Apache-2.0 (Intel/dpt-*) | multi-dataset | – | **UNCLEAR** |
| ZoeDepth | MIT | MIT (HF) | + KITTI/NYU | – | **Fine-tune only** |
| Metric3D v2 | BSD-2-Clause | not stated | multi-dataset | – | **UNCLEAR** |
| UniDepth | CC BY-NC 4.0 | – | – | – | **Avoid** |
| Marigold | Apache-2.0 | openrail++ (v1.1) / apache (LCM) | SD2 / LAION + synthetic | RAIL use restrictions | **UNCLEAR** |
| Lotus | Apache-2.0 | apache-2.0 (HF, SD2-derived) | SD2 lineage | – | **UNCLEAR** |
| DepthCrafter | Tencent academic-only | same | – | – | **Avoid** |
| Video Depth Anything | Apache-2.0 | Small Apache, Base/Large CC-BY-NC-4.0 | – | – | Small: UNCLEAR. Others: Research-only. |
| ViTMatte | MIT | Apache-2.0 (HF) | Composition-1k / Distinctions-646 | – | **Fine-tune only** |
| BiRefNet | MIT | MIT (HF) | DIS5K (NC) + others | – | **Fine-tune only** |
| RMBG-1.4 / 2.0 | – | BRIA NC / CC BY-NC 4.0 | BRIA-licensed | Paid commercial license | **Research-only** |
| MODNet | Apache-2.0 | Apache-2.0 (Xenova mirror) | Adobe matting data (per paper) | – | **Fine-tune only** |
| MatAnyone | S-Lab 1.0 (NC) | – | – | – | **Avoid** |
| Guided filter / fast bilateral solver | our clean-room implementation | – | – | **Patent status not verified** | Build after an FTO check |

---

## 8. Effort estimates (engineer-weeks)

| Item | Phase | Estimate |
|---|---|---|
| Analysis render, Vision wrappers (subject, person, instances, landmarks, saliency), warm-up, Background = invert | 2 | 2 |
| Face-part heuristics (lips, brows, eyes/iris/sclera, face skin, teeth) from landmarks plus person matte | 2 | 1–2 |
| Embedded auxiliary data reader (depth, portrait matte, hair/skin/teeth/glasses/sky mattes) | 2 | 1 |
| Mask storage, provenance, "Update AI masks" | 2 | 2 |
| Guided joint upsampling plus "Refine edge" brush (Metal) | 2 | 2–3 |
| Vision tap-to-segment integration (OS 27, asset download UX) | 3 | 1–2 |
| SAM 2.1 Core ML path (GPU), hover UX, embedding cache, A17 Pro profiling | 3 | 4–6 |
| ANE-optimised SAM encoder re-export (or distil our own encoder from SAM 2.1 on owned images) | 3–4 | 2–3 (re-export) / 6–10 (distil) |
| Sky head: probe DINOv2-S vs SAM 2.1 features, label 3–5k images, train, convert, evaluate | 3 | 6–8 (+ labelling cost) |
| Landscape classes plus people-parts head | 3–4 | 12–20 (+ labelling / consented capture) |
| Depth: DA-V2-S integration, guided upsampling, Depth Range mask | 3 | 2–3 |
| Learned matting refiner (own data) | 4 | 8–12 |

---

## 9. Risks and open questions

**Risks**
1. **Training-data provenance (highest).** Only Apple frameworks and Meta's own SAM/SAM 2/DINOv2 releases
   have a publisher that also owns or licensed the data. Everything else, including DA-V2 Small (VKITTI 2 is
   NC), carries NC/research data in its lineage. Decision needed: do we accept publisher-granted commercial
   weights (the publisher assumes the data risk), or apply the brief's strict "training data must be
   commercial" rule? Under the strict rule, only Vision, SAM 2.1 and DINOv2 are safe, and depth must be
   self-trained.
2. **Custom Meta licenses (SAM 3, DINOv3).** Commercial use is allowed, but the pass-through requirement and
   the "no reverse engineering" clause sit awkwardly with an MPL-2.0 open-source distribution. Legal review is
   needed before even using them as labelling tools.
3. **Tap-to-segment is OS 27 only**, needs a model download, and is not testable on our OS 26 machines.
   Phase 3 has to carry SAM for OS 26 regardless.
4. **Vision output resolution is low** (512² subject, 512×384 instances, 2016×1512 best person matte).
   Hair and fur quality depends on our refinement. Vision may also change silently across OS updates, so
   cached bitmaps are mandatory.
5. **ANE behaviour.** The Apple SAM packages run slower on the ANE than on the GPU, log shape-propagation
   errors, and take minutes to compile on first ANE load. Model loads must be background tasks, and the GPU
   must be the default.
6. **Patents** on the guided filter and the bilateral solver are unverified.
7. **The Lightroom category lists are unverified.** Adobe's help site blocked our fetch.

**Open questions**
- A17 Pro (8 GB) timings and memory for SAM 2.1 tiny/small and for Vision iterative segmentation. Also, does
  each `perform` of the iterative request re-encode the image? That determines per-click latency.
- How does Vision handle 16-bit, half-float or linear `CIImage` inputs? Does colour management happen?
- Does the iPhone Camera write sky mattes (the ImageIO type exists) into HEIC? Do ProRAW DNGs embed depth or
  semantic mattes?
- What share of COCO images carry CC BY / CC BY-SA / PD licenses (for COCO-Stuff training)?
- Are stuff classes (sky, water) among the Open Images V7 point-label classes?
- Do DINOv2-S features or SAM 2.1 Hiera features make the better sky/landscape probe?
- Would the ANE compile cost disappear with a stable compiled-model path (OS cache)?

---

## 10. Test data list (segmentation)

| Set | Use | License (source) | Notes |
|---|---|---|---|
| Commons "Throngs of people walking towards Himeji Castle, 2016" (6016×4000) | crowd, >4 people, sky | CC0 (Commons API `LicenseShortName`) | Used in §1 measurements |
| Commons "Portrait of a labrador retriever" (6240×4160, Fujifilm X-T3) | fur, animal subject | CC0 | Used in §1 and §6 |
| Commons "Seated woman with blonde hair-3177506" (3891×3264) | hair, face landmarks | CC0 | Used in §1 and §6 |
| Commons "Langdale Pikes – Flickr – Terry Kearney" (4888×2748) | mountains, sky, vegetation | CC0 | Used in §1 |
| Open Images V7 validation (instance masks) | Objects/People IoU | Annotations CC BY 4.0. Images "listed as" CC BY 2.0. | Attribution per image |
| COCO-Stuff val, filtered by per-image license to CC BY / CC BY-SA / PD | Sky and Landscape classes | Annotations CC BY 4.0. Images Flickr ToU plus per-image CC. | Legal to confirm |
| SA-V frames | class-agnostic masks, hover evaluation | CC BY 4.0 | – |
| P3M-500-P, AM-2k test | hair and fur matting evaluation | Labels "under MIT license". Image copyright stays with the owners. | Internal evaluation only (UNCLEAR) |
| Own captures | RAW (Sony/Canon/Nikon/Fuji), iPhone HEIC with depth and mattes, ProRAW, backlit hair, pets, foliage/sky edges, water, architecture | Ours (model releases for people) | **Required.** The only fully clean source for training. |
| ADE20K, Cityscapes, DIS5K, SA-1B, Mapillary Vistas | – | NC / research-only / unverified | **Do not use** without legal OK |

---

## 11. Reproduction notes

- Scripts live in `/tmp/cm/` (outside the repo): `sam/bench.swift` (Core ML SAM 2.1 timing), `vbench.swift`
  (Vision requests), `msize.swift` (mask encoding sizes).
- SAM packages were downloaded from `https://huggingface.co/apple/coreml-sam2.1-{tiny,small}`. No gating,
  plain `huggingface-cli download` / HTTPS.
- Key URLs:
  <https://github.com/facebookresearch/sam2> ·
  <https://huggingface.co/apple/coreml-sam2.1-tiny> ·
  <https://github.com/facebookresearch/sam3/blob/main/LICENSE> ·
  <https://github.com/facebookresearch/dinov2> ·
  <https://github.com/facebookresearch/dinov3/blob/main/LICENSE.md> ·
  <https://github.com/DepthAnything/Depth-Anything-V2> ·
  <https://huggingface.co/apple/coreml-depth-anything-v2-small> ·
  <https://github.com/ByteDance-Seed/Depth-Anything-3> ·
  <https://huggingface.co/apple/DepthPro> ·
  <https://github.com/chongzhou96/EdgeSAM/blob/master/LICENSE> ·
  <https://github.com/NVlabs/SegFormer/blob/master/LICENSE> ·
  <https://github.com/THU-MIG/RepViT/tree/main/sam> ·
  <https://groups.csail.mit.edu/vision/datasets/ADE20K/terms/> ·
  <https://www.cityscapes-dataset.com/license/> ·
  <https://storage.googleapis.com/openimages/web/factsfigures_v7.html> ·
  <https://github.com/xuebinqin/DIS/blob/main/DIS5K-Dataset-Terms-of-Use.pdf> ·
  <https://developer.apple.com/videos/play/wwdc2026/237/>.
