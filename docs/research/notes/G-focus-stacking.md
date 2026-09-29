# G. Focus stacking: research notes

Workstream G of `docs/research/ai-and-computational-photography-brief.md`. All sources were checked on
2026-09-29 unless stated otherwise. Conventions follow `_conventions.md`: **Evidence** is what a primary
source says; **Assessment** is our opinion. Items that could not be verified are marked as such.

## 0. Summary of recommendations

1. **Build classical first (Phase 3), in-house, on Metal.** Every commercial tool that users praise
   (Helicon Focus, Zerene Stacker) is classical: depth-map selection plus pyramid fusion plus a
   retouch brush. The deep models available in 2026 are either unlicensed, trained on tainted data, limited to
   2–4 frames, or generative (they invent detail). None can ship as they are.
2. **Offer three strategies:** **Auto** (a hybrid, the default), **Smooth** (depth map, similar to Zerene
   DMap and Helicon B) and **Detail** (pyramid, similar to Zerene PMax and Helicon C). Include a
   Zerene-style "paint from source frame" retouch brush in v1, because both market leaders treat retouching
   as essential rather than optional.
3. **Place stacking after demosaicing, in camera-native linear RGB, before any user edit.** Store
   the result as a **virtual raw**: a small JSON stack recipe (source list with hashes, alignment, strategy,
   parameters, retouch strokes and algorithm version) plus an evictable cached fused image in linear
   half-float. The user's normal `EditRecipe` then applies on top. Offer a "Bake to linear DNG" export
   for portability, but don't make it the storage format.
4. **Detection:** use maker-note tags where they exist (Canon, Nikon Z, Panasonic, and OM System/Olympus
   are good; Sony and Fujifilm are weak), with a heuristic fallback (identical exposure, time gaps, image
   similarity, and a monotonic sharpness peak). Present it as a *suggestion* ("Focus stack detected: 32
   frames"), never an automatic merge.
5. **Performance:** fifty 45 MP frames in under 60 s is realistic on every Apple Silicon Mac when
   reading from an internal SSD. The estimate is about 4–10 s on an M1 Ultra and 10–30 s on a base M4.
   Raw decoding and I/O dominate, not the GPU fusion. Fusion must stream frames, so memory is O(1)
   frames plus one accumulator pyramid (about 1.5–2.5 GB at 45 MP). iPad M-series is feasible.
   iPhone is feasible for its own 12–48 MP stacks.
6. **AI in Phase 4 is assistive, not a replacement:** motion and occlusion masks, halo and boundary
   refinement, noise-robust fusion for high-ISO phone bursts, and an optional depth prior. The only
   near-shippable learned component found is **FOSSA ViT-S** (depth from defocus; code and weights
   BSD-3-Clause), and it still needs legal review of its training data. Anything we ship that is learned
   and affects pixels should be trained by us, on our own captured stacks.

---

## 1. Competitive analysis

### 1.1 Helicon Focus (Helicon Soft)

**Evidence** ([Helicon Focus 8 User Guide](https://www.heliconsoft.com/focus/help/english/HeliconFocus.html)):
- **Method A** "computes the weight for each pixel based on its contrast and then forms the weighted
  average of all pixels from all source images. This method works better for short stacks and preserves
  contrast and color."
- **Method B** "selects the source image containing the sharpest pixel and uses this information to form
  the 'depth map'… imposes strict requirements on the order of images – it should always be consecutive.
  Perfectly renders textures on smooth surfaces." Method B changed significantly in version 7. The legacy
  B mode "may produce more artifacts on uniform background, especially if … brightness variations".
- **Method C** "uses pyramid approach … dividing image signals into high and low frequencies. Gives good
  results in complex cases (intersecting objects, deep stacks), though increases contrast and glare."
- **Radius** (A and B only) sets the analysis window. Low values of about 3–5 suit fine details and hair,
  but give "more noise or halo effects". High values (the guide shows 22) "almost eliminate the halo effect"
  but cost detail. **Smoothing**: for A and C it controls how the sharp areas are blended; for B it smooths
  the depth map.
- **Alignment** ("Autoadjustments") covers vertical and horizontal shift, rotation, scale (all as limits
  between consecutive frames) and brightness equalization. There is also a dust map (a defocused
  white-field frame) to avoid dust trails.
- **Retouching**: a "Copy from source" brush (size, hardness, *color tolerance*, brightness). F9 jumps
  to the source frame under the cursor. There are also Clone and Erase brushes, and "Use another output
  as a source" (Pro), which combines outputs from different methods. Projects are saved as `.hproj`
  with the retouch history.
- **Output**: JPEG, TIFF or DNG. The Pro edition has a "Raw-in-DNG-out" mode. It can also save a depth
  map, a 3D model and layers. Batch processing can split stacks by image count, time gap, exposure or focus.
- **GPU**: OpenCL. The guide recommends "4GB graphics processing units for 20-40 megapixels".

**Platforms.** Helicon Focus itself does not appear in App Store searches for iOS or Mac (iTunes Search
API, `term=helicon`). Only **Helicon Remote** (tethered focus bracketing for Canon and Nikon, plus selected
Sony bodies, on iOS/Android/Win/Mac;
[product page](https://www.heliconsoft.com/heliconsoft-products/helicon-remote/),
[App Store](https://apps.apple.com/us/app/helicon-remote/id957334044)) and **Helicon FBT** (a controller
app for their focus-bracketing extension tube) are on iOS. Helicon Focus is a Windows/macOS desktop app.

**Assessment.** The quality leader for many users. Its weaknesses are that the method choice is an
expert decision; that B needs consecutive order; that C raises contrast, glare and noise; that A blurs
long stacks; and the workflow cost of export, stack, re-import and the loss of raw editability, unless
you use DNG-out.

### 1.2 Zerene Stacker (Zerene Systems)

**Evidence** ([How To Use It](https://zerenesystems.com/cms/stacker/docs/howtouseit),
[FAQ](https://zerenesystems.com/cms/stacker/docs/faqlist)):
- **PMax** is "a 'pyramid' method… very good at finding and preserving detail even in low contrast or
  slightly blurred areas… handling overlapping structures like mats of hair and crisscrossing bristles,
  nicely avoiding the loss-of-detail halos typical of other stacking programs. But PMax tends to increase
  noise and contrast, it can alter colors somewhat, and it's liable to produce fuzzy 'inversion halos'
  around strongly contrasting objects."
- **DMap** is "a 'depth map' method… better job keeping the original smoothness and colors, but … not as good
  at finding and preserving detail." It runs in three steps: a draft depth map; a user-set **contrast
  threshold** (a percentile slider, with areas below it shown black as noise); then a refine-and-render
  step. Its parameters are Estimation Radius and Smoothing Radius, with smoothing "about half the
  estimation radius".
- **Retouching** is "one of its strongest features". The source can be any input frame *or any output*,
  so PMax detail can be painted into a DMap result. It has synchronized panes, hold "s" to flash the
  source, and Shift+drag to scrub through the stack in depth.
- **Stack Selected** stacks a subset of frames. This is the documented fix for **"transparent
  foreground"**: "wide aperture lenses will 'look around' opaque parts of your subject". Stack only the
  foreground frames, then retouch that result into the full stack.
- **Slabbing**: stack sub-stacks of 10–15 frames with overlap (for example, 200 frames become 30 slabs),
  then stack the slabs. Retouching then reaches back only to slabs. PMax slabs followed by DMap also
  speeds up DMap experiments.
- **Ordering and alignment.** Processing starts from the *narrow-FOV end* to avoid edge streaks. Frames
  are registered by "rotate/shift/scale" against a master. Out-of-order stacks cause "echoes" and, with
  DMap, "nasty halos". There is a PMax "grit suppression" option that trades a little fine detail for
  less noise. "Retain UDR image" exists because PMax pushes the dynamic range beyond the output range.
- **Raw files**: "The structure of data in a typical raw image file … is fundamentally incompatible with
  the image alignment process that is required for stacking". Zerene expects TIFFs converted by the
  user, or it goes through the Lightroom plugin.
- A native Apple Silicon build exists (T2026-05-04, bundled Java 25;
  [downloads](https://zerenesystems.com/cms/stacker/softwaredownloads)). It has no iOS version.

**Assessment.** It is the benchmark for difficult macro (hair, bristles, deep stacks). The price is a
steep learning curve, a Java UI, a TIFF round trip, and retouching that is manual and skill-heavy.

### 1.3 Photoshop: Auto-Align plus Auto-Blend "Stack Images"

**Evidence** (helpx.adobe.com returned "Access Denied" to curl, so these come from Wayback 2025
snapshots of [Auto-Blend](https://helpx.adobe.com/photoshop/using/combine-images-auto-blend-layers.html)
and [Auto-Align](https://helpx.adobe.com/photoshop/using/aligning-layers.html)). Auto-Blend "applies
layer masks as needed to each layer… Stack Images blends the best details in each corresponding area…
(you must auto-align the images first)". It has an option for "Seamless Tones and Colors". Auto-Align
offers Auto, Perspective, Cylindrical, Spherical, Collage and Reposition projections, plus "Lens
Correction: Vignette Removal, Geometric Distortion".

**Assessment.** It produces hard per-layer masks, which is effectively a depth-map method. It is slow
for more than about 20 layers of 45 MP, gives halos at edges, has no dedicated retouch-from-source
workflow beyond manual mask painting, and the output is a flattened, display-referred document.

### 1.4 Affinity Photo (Canva): Focus Merge

**Evidence** ([Focus merging](https://www.affinity.studio/help/focus-merging-focusmerging/),
[Source cloning](https://www.affinity.studio/help/focus-merging-focusmerge-sourcecloning/)): File > New
Image Process > Focus Merge, with an optional raw development preset applied to every raw. It shows
three stages: "initial alignment, image blending, and final merging". The Sources panel lists the result
and all sources for Clone-Brush retouching. **Source cloning "is only available in Affinity for
desktop."** It has no user-selectable method.

**Assessment.** This is the closest existing thing to "one click inside an editor", but it bakes raws
through a preset before merging, and the result is a pixel document rather than an editable raw.

### 1.5 In-camera stacking and bracketing

| Vendor | What the camera does (evidence) | Merge in camera? |
|---|---|---|
| **OM System / Olympus** | OM-1 manual v1.7, p.160 ([PDF](https://download.omsystem.com/pages/inst/om1/manual_om1_v1.7_ENU.pdf)): Focus Stacking, 3–15 shots, focus differential 1–10, electronic shutter; "The composite image is recorded in JPEG format… enlarged 7%". The [OM-1 Q&A](https://support.jp.omsystem.com/en/support/imsg/digicamera/qa/products/om1/index.html) says OM Workspace merges up to 999 frames and lists the supported lenses. | **Yes**, JPEG only, with a crop |
| **Canon** | EOS R7 manual ([Focus Bracketing](https://cam.start.canon/en/C005/manual/html/UG-04_Shooting-1_0320.html)): 2–999 shots, Focus increment, Exposure smoothing, **Depth composite** Enable/Disable, "Crop depth comp."; composite saved as JPEG/HEIF; "Not all of the shots are combined". The same page exists for the R3, R5 II, R1, R8, R50, R10, R6 II and PowerShot V1 (cam.start.canon C010/C017/C018/C013/C011/C006/C012/C016). DPP can also depth-composite. | **Yes** on those bodies, JPEG/HEIF |
| **Nikon** | Z8 manual ([Focus Shift Shooting](https://onlinemanual.nikonimglib.com/z8/en/psm_focus_shift_shooting_153.html)): up to 300 shots, step width (≤5 recommended), interval, exposure lock, "Starting storage folder: New folder" — "photos that will later be combined using focus stacking". | **No** (none found) |
| **Sony** | α7R V Help Guide ([Focus Bracket](https://helpguide.sony.net/ilc/2230/v1/en/contents/TP1000669436.html)): Step Width 1–10, 2–299 shots, order 0→+ or 0→−→+, Exposure Smoothing, "Focus Brckt Saving Dest". Also on the α7 V (help guide 2540). | **No** (none found) |
| **Fujifilm** | X-H2 manual ([Bracketing](https://fujifilm-dsc.com/en/manual/x-h2/taking_photo/bracketing/)): FOCUS BKT with MANUAL (FRAMES/STEP/INTERVAL) or AUTO (pick near and far, and the camera computes frames and step). | **No** (none found) |
| **Panasonic** | [Post Focus / Focus Stacking](https://help.na.panasonic.com/answers/how-to-use-the-post-focus-focus-stacking-feature/): records a 4K/6K burst while sweeping focus, then in playback "Merge multiple pictures… into a single picture" (JPEG). Stills focus bracketing is separate. | **Yes**, from a video burst (8/18 MP JPEG) |

**Assessment.** In-camera merges are JPEG, limited in frame count, cropped and not retouchable. They
prove the demand for "one click", but they are not competition for raw quality. What matters for
Redlamp is that every vendor now writes *bracketed raw sequences*, often into a dedicated folder, and
that most tag them.

### 1.6 Open-source tools

- **enfuse / enblend (Hugin project):** GPL-2.0. I verified the COPYING file on the GitHub mirror
  [jackmitch/enblend-enfuse](https://github.com/jackmitch/enblend-enfuse). Hugin is GPL-2.0-or-later,
  which is widely documented but was not re-verified here because the SourceForge raw file was
  unreachable. **Verdict: Avoid. Do not read the source.**
- **[PetteriAimonen/focus-stack](https://github.com/PetteriAimonen/focus-stack):** **MIT** (LICENSE.md,
  per GitHub API). It uses OpenCV `findTransformECC` for neighbour-to-neighbour chained alignment against
  the middle frame (at most 2048 px by default), a least-squares exposure and white-balance fit, PCA
  grayscale, and complex-wavelet max-abs merging with neighbour and subband consistency (after Forster et
  al. 2004, DOI 10.1002/jemt.20092). It then does wavelet denoising and **colour reassignment**: it picks
  a real source pixel that matches the fused gray value. Its docs say this "has some trouble with halo
  effects… color reassignment tends to make these artefacts more visible". Memory is about 100 MB per MP,
  processed in batches ([docs/Algorithms.md](https://github.com/PetteriAimonen/focus-stack/blob/master/docs/Algorithms.md)).
  **Verdict: Shippable as a reference.** We may read it, but we should still implement in Metal.
- **[Xinzhe99/OpenFocus](https://github.com/Xinzhe99/OpenFocus):** **MIT** app (PyQt6, v1.28 on
  2026-09-30 per README). It offers guided-filter, DCT, DTCWT and GFG-FGF classical fusion, ECC
  registration, and bundles **StackMFF-V4** weights (`weights/stackmffv4.pth`, 3.97 MB). The README
  warns: "please follow each algorithm's original license terms". The weights inherit StackMFF's
  training-data problems (see §3).

### 1.7 "AI-first" newcomers, 2023–2026

- **Research:** Araujo, Ponce & Mairal, "Towards Real-World Focus Stacking with Deep Learning"
  (arXiv 2311.17846). This is the first learned stacker for long (30-frame) **raw** bursts, trained on
  Helicon-generated pseudo ground truth. There is also the StackMFF series (N-frame fusion; V4 in 2025),
  GMFF (arXiv 2512.21495, a diffusion "generative restoration" stage), and ReDiffuse (arXiv 2603.21129).
  Details are in §3.
- **Consumer apps (App Store, via the iTunes lookup API):**
  - [Zeus Focus Stacking](https://apps.apple.com/us/app/zeus-focus-stacking/id6471365204) (v2.2.0,
    updated 2026-09-29) does iPhone capture with focus sweeps of 10 or 20 frames, including "Ultra 48 MP",
    "per-iPhone calibration profile", handheld alignment, and claims of "no glow around bright points".
  - [iFocus Stacking](https://apps.apple.com/us/app/ifocus-stacking/id6752693470) ($39.99, imports
    JPEG/HEIC).
  - [TASO Focus AI for microscopes](https://apps.apple.com/us/app/taso-focus-ai-for-microscopes/id6753968836).
  - Several "Macro Camera" apps.

  None of them take raw input or disclose their methods.
- **[Luminar Neo Focus Stacking extension](https://skylum.com/luminar/focus-stacking)** handles "up to
  100 images", and "The AI algorithm inside Focus Stacking chooses the crispest parts… corrects lens and
  chromatic aberration in raw files". It uses keypoint alignment and "divides the image into small tiles".
  There is no technical disclosure.
- **Assessment.** No shipping product has shown learned fusion beating Helicon or Zerene on real macro.
  "AI" is mostly marketing. The real 2023–2026 advance is *mobile*: handheld phone focus sweeps are now a
  product category, which validates the brief's casual-user thesis.

### 1.8 Comparison table

| Tool | Methods | Strengths | Failure modes | Workflow cost |
|---|---|---|---|---|
| Helicon Focus | A (weighted avg), B (depth map), C (pyramid); radius and smoothing | Fast (OpenCL); B clean on smooth surfaces; C on crossings and deep stacks; DNG out (Pro); good retouch | A: blur on long stacks. B: halos at small radius, needs consecutive order, artifacts on uniform background. C: contrast, glare and noise increase | Separate app; export and re-import; method choice is expert-level |
| Zerene Stacker | PMax (pyramid), DMap (depth map + threshold); slabbing; Stack Selected | Best on hair and bristles (PMax); cleanest colours (DMap); most powerful retouch (from outputs or sources) | PMax: noise, contrast and colour shifts, inversion halos. DMap: loses detail, needs threshold tuning. Transparent foreground | Separate Java app; TIFF conversion; heavy manual retouch |
| Photoshop | Auto-Align + Auto-Blend "Stack Images" (layer masks) | Already installed for many users; lens-correction-aware alignment | Hard-mask seams, halos, slow for large N, hair loss | Layers in PS; flattened output |
| Affinity Photo | Focus Merge (one method) + source cloning | One-click inside an editor; raw preset | No strategy choice; raw baked first; retouch is desktop-only | Low, but the result is not raw |
| In-camera (OM, Canon, Panasonic) | Proprietary | Zero effort | JPEG only, crop (OM 7%), limited N (OM ≤15), moving subjects fail; Canon warns on "patterned… flat and uniform" subjects | None, but the result is not editable |
| focus-stack (MIT) | Complex-wavelet max + colour reassignment; depth map | Free, fast, low memory (batches) | Halos, made more visible by colour reassignment | CLI, JPEG/TIFF in |
| Phone apps (Zeus etc.) | Undisclosed | Handheld capture, one tap | JPEG/HEIC only; quality unknown | Capture tied to the app |

---

## 2. Classical pipeline, stage by stage

### 2a. Stack detection

**Evidence: maker-note tags** (ExifTool tag docs:
[Sony](https://exiftool.org/TagNames/Sony.html), [Nikon](https://exiftool.org/TagNames/Nikon.html),
[Canon](https://exiftool.org/TagNames/Canon.html), [FujiFilm](https://exiftool.org/TagNames/FujiFilm.html),
[Olympus](https://exiftool.org/TagNames/Olympus.html), [Panasonic](https://exiftool.org/TagNames/Panasonic.html),
[Apple](https://exiftool.org/TagNames/Apple.html); ExifTool 13.59, May 2026). These are documentation
facts; we did not read ExifTool source.

| Vendor | Tag (table / ID) | Meaning | Strength |
|---|---|---|---|
| Canon | `FocusBracketingInfo` (main 0x4053) → `FocusBracketing` (idx 1, 0/1), `FocusBracketingImageCount` (2), `FocusBracketingFocusIncrement` (3), `FocusBracketingExposureSmoothing` (4), `FocusBracketingDepthComposite` (5), `FocusBracketingCropDepthComposite` (6), `FocusBracketingFlashInterval` (7) | The frame is part of a bracket; planned count; step | **Strong.** Decoding added in ExifTool 13.33, 2025-07-25 |
| Canon | `CameraSettings` idx 50 `FocusBracketing` (0 Disable / 1 Enable); `FileInfo` idx 5 `BracketShotNumber`; `ShotInfo` idx 9 `SequenceNumber`; `FocusDistanceUpper/Lower` | Enable flag; per-frame index (documented for brackets generally; that it applies to focus brackets must be checked on samples); approximate distance | Medium |
| Nikon (Z8, Z9) | `ShotInfoZ8/Z9` idx 48 `SequenceOffset` → `SeqInfoZ9` idx 32 **`FocusShiftShooting`** (int8u, converted) | Focus-shift sequence information. Value semantics (frame number?) are not documented on the TagNames page, so they need sample files | **Strong, once decoded** |
| Nikon (Z6III, Z7II, Z8, Z9 fw v3/v4, D6) | `MenuSettings*` / `IntervalInfoD6`: `FocusShiftNumberShots`, `FocusShiftStepWidth`, `FocusShiftInterval`, `FocusShiftExposureLock`, `FocusShiftAutoReset?` | Menu *settings* (present even when not shooting a sequence) | Weak alone |
| Nikon | 0x0085 `ManualFocusDistance`; `LensData0800` `FocusDistance`, `FocusStepsFromInfinity?` | Focus distance; lens-step proxy | Supporting |
| OM System / Olympus | `CameraSettings` 0x0600 **`DriveMode`** (numbers: "1. Mode, 2. Shot number, 3. Mode bits, 5. Shutter mode, 6. Shooting mode"); 0x0308 **`FocusBracketStepSize`**; 0x0804 **`StackedImage`** ('9 *' = "Focus-stacked (* images)") | Bracket mode plus per-frame shot number; step; marks an *in-camera composite* (exclude it from inputs, or offer it as a reference) | **Strong** |
| OM System / Olympus | `FocusInfo` 0x0305 `FocusDistance`, 0x0301 `FocusStepCount`, 0x0303 `FocusStepInfinity`, 0x0304 `FocusStepNear` | Monotonic focus position | **Strong ordering signal** |
| Panasonic | 0x002a **`BurstMode`** (3 = Focus Bracketing); 0x002b `SequenceNumber`; 0x0096 `TimerRecording` (3 = Focus Bracketing); 0x00bd **`FocusBracket`** ("positive is further, negative is closer"); 0x00bb `VideoBurstMode` (0x4 Post Focus, 0x408 Focus Stacking); 0x00bf `PostFocusMerging` | Bracket flag, index, step, and marks for Post Focus video bursts | **Strong** |
| Sony | `Tag9400a/b/c` `SequenceImageNumber`, `SequenceFileNumber`, `SequenceLength`; `Tag9416` idx 29 `SequenceImageNumber`; `ReleaseMode2` / `ReleaseMode3` (3: "2 = Bracketing"); `Tag9402` idx 45 / `Tag9404b` idx 32 `FocusPosition2`; `ShotNumberSincePowerUp` | Burst index and length. The documented `ReleaseMode2` values have **no focus-bracket code**. Whether `FocusPosition2` is valid on current bodies is unknown | **Weak.** Needs sample-driven reverse engineering |
| Fujifilm | 0x1100 `AutoBracketing` (documented values: Off, On, Pre-shot, flash, Pixel Shift; **no focus BKT value**); 0x1101 `SequenceNumber`; 0x1103 `DriveSettings`; 0x1150 `CompositeImageMode` (2 = "Pro Focus", a compact-camera mode, not stacking) | Sequence index only | **Weak** |
| Apple (iPhone) | 0x000b `BurstUUID`; 0x000c `FocusDistanceRange`; 0x002f `FocusPosition`; 0x0038 `AFMeasuredDepth`; 0x0014 `ImageCaptureType` (11 = Manual Focus) | Group ID (bursts); focus position (monotonic across a sweep) | Medium |

**LibRaw already parses some of these.** Per `libraw/libraw_types.h` at LibRaw master, it has Fujifilm
`AutoBracketing`, `SequenceNumber`, `SeriesLength` and `ImageCount`; Olympus `DriveMode[5]`,
`FocusStepCount/Infinity/Near`, `FocusDistance` and `StackedImage[2]`; Panasonic `FocusStepNear/Count`;
and Sony `FocusPosition` and `ShotNumberSincePowerUp`. For the other tags, LibRaw exposes
`set_makernotes_handler(exif_parser_callback, …)` (`libraw.h`), so we can capture Canon 0x4053, Panasonic
0x002a/0x00bd and the Nikon ShotInfo offsets during the open we already do. That avoids a second parser.
**Assessment:** the extra work is small, but building test fixtures per camera is the real cost.

**Heuristic fallback** (required for Sony, Fujifilm, JPEG/HEIC and phone input):
1. **Candidate runs:** consecutive files (sorted by capture time and then file number) from the same body
   serial and lens. Require the same focal length (±0.5 mm), aperture, ISO and shutter time. Allow
   shutter drift of ±1/3 EV when "exposure smoothing" is on, because Canon and Sony both have that
   option. Also require a gap of at most `max(3 s, 4 × median gap)`, or the camera's recorded interval
   setting.
2. **Content check** on the 256 px thumbnails we already build: similarity-align neighbours. Require
   normalized cross-correlation above about 0.7, a global scale change per step below about 2%, and
   translation below about 5% of width.
3. **Focus signature:** a per-frame sharpness map (coarse focus measure at 1/16 scale) whose *peak
   location moves* monotonically. This separates a focus stack from a burst of a static scene, where the
   peak doesn't move.
4. **Exclusions:** exposure brackets (EV differs), panoramas (large translation), pixel-shift sets
   (Fujifilm `AutoBracketing` = Pixel Shift, Sony `PixelShiftInfo`), in-camera composites (Olympus
   `StackedImage`, Canon composite JPEGs), and Nikon or Sony "new folder per bracket" boundaries. These
   folder boundaries are a *strong* split cue.

**Precision and recall.** **Assessment:** tag-based detection should be close to 100% precise. The
main recall losses are handheld manual "ring-racking", Sony and Fujifilm, and tethered captures (Helicon
Remote, or StackShot rails that move the camera, so focus distance is constant but the thumbnails change
scale). The heuristic will have false positives on static bursts (the focus signature filters most of
them) and on time-lapses (they fail the peak-motion test). Because we only *suggest*, a false positive
costs one dismissed banner. Measure precision and recall on a labelled corpus from each vendor
(§7) before tuning the thresholds.

### 2b. Alignment

**The problem.** Frames differ by (1) **focus breathing**, a scale change of about 0.1–2% per step in
macro; (2) camera shake or rail drift (translation and rotation); (3) perspective parallax when the
camera moves on a rail, which a global model cannot fix; (4) brightness and colour flicker; and (5) the
blur difference itself, which biases intensity-based methods. Zerene and Helicon both model
scale, shift and rotation with limits between consecutive frames (see §1).

**Options compared.**

| Method | Evidence | Fit |
|---|---|---|
| **ECC** (Evangelidis & Psarakis 2008, DOI 10.1109/TPAMI.2008.113) | Intensity-based, invariant to photometric gain and bias, and supports translation, Euclidean, affine and homography models. Used by focus-stack and Araujo 2023 (§3). | **Default.** Dense, sub-pixel, robust to blur differences when both images are pre-smoothed. Maps well to GPU reductions. |
| Feature homography (ORB, DOI 10.1109/ICCV.2011.6126544; AKAZE, BMVC 2013, DOI 10.5244/C.27.13; SIFT) | SIFT patent US 6,711,293 **expired March 2020** (OpenCV commit df10411e05, 2020-04-21: "Patent US6711293 expired in March 2020"). | **Fallback** for large motion and handheld shots, where ECC's basin of convergence is too small. Features are sparse on defocused frames, so match neighbours only. |
| Model: similarity (4 DoF), affine (6), homography (8) | Zerene uses rotate, shift and scale. | Similarity by default (tripod or rail); affine as an option; homography only when handheld and far-field. More degrees of freedom overfit blur differences. |
| Dense residual flow: DIS (Kroeger et al., arXiv 1603.03590), RAFT (arXiv 2003.12039, BSD-3), SEA-RAFT (arXiv 2405.14793, BSD-3), Apple Vision `VNGenerateOpticalFlowRequest` (iOS 14 / macOS 11) | Brightness constancy is violated between differently focused frames, so flow latches onto blur edges. | Use only for **diagnosis** ("movement detected") and for local warping of *moving-subject* regions in Phase 4. Don't use it as primary alignment. |
| Apple Vision `VNHomographicImageRegistrationRequest` / `VNTranslationalImageRegistrationRequest` (macOS 10.13 / iOS 11) | A system API. | A cheap first guess on iPhone. It is a black box, and its results are not guaranteed to be reproducible across OS versions. Don't store it as the recipe's source of truth. |

**Recommendations (defaults).**
1. **Undistort first** if a lens profile exists. A similarity model is only valid on a
   distortion-corrected image. Apply per-frame *lateral CA* correction as well, because CA scales with
   focus. Record "distortion corrected" on the virtual raw so it is not applied twice.
2. **Alignment space:** luma computed from *linear* camera RGB, then a `log(Y+ε)` or `sqrt` encoding
   (so dark and bright regions weigh equally), at long edge 2048. Use a coarse-to-fine pyramid of 512,
   1024 and 2048 px, with Gaussian pre-smoothing σ≈1.5 px at each level so both frames look equally
   blurred.
3. **ECC, similarity model**, 50 iterations per level, ε=1e-4. Mask low-gradient and clipped pixels.
4. **Chain neighbour to neighbour** (as in focus-stack), but re-anchor against the reference every 8 frames
   to stop drift. Zerene notes that accumulated error causes "echoes".
5. **Reference = the narrowest-FOV end** (Zerene's rule), so every other frame is *down*-scaled into
   it. That means no extrapolated edges and no streaks. Offer "keep widest framing" as an option.
6. **Photometric normalization in linear light:** a per-frame, per-channel gain fitted by robust
   regression (median of ratios) on pixels that are mid-tone, unclipped, and similarly sharp in both
   frames. In linear space exposure flicker is a pure gain, which is a real advantage of our pipeline.
7. **Failure handling:** if ECC correlation stays below about 0.85, retry with AKAZE+RANSAC similarity or
   homography, then refine with ECC. After alignment, run DIS at 1/4 scale on neighbours. If the 95th
   percentile of residual motion is above about 1.5 px, flag "subject or camera movement" and point the user to
   the retouch brush.
8. **Resampling:** apply the full-resolution warp once per frame with a separable Lanczos-3 or bicubic
   filter in fp16/fp32. Composition of transforms is exact because they are matrices, so we never
   resample twice.

### 2c. Focus measures

**Evidence.** Nayar & Nakagawa 1994 introduce the **sum-modified-Laplacian** (SML) for shape from focus
(DOI 10.1109/34.308479). Pertuz, Puig & García 2013 compare a large set of focus-measure operators in
families: gradient, Laplacian, wavelet, statistical, DCT and miscellaneous
(DOI 10.1016/j.patcog.2012.11.011). *Not verified:* the paper is paywalled and its abstract was not
retrievable through Crossref, Semantic Scholar or OpenAlex. The commonly cited conclusion, that
Laplacian-based operators perform best in normal conditions and statistical ones are more robust to
noise, is from memory and should be confirmed from the full text. Pertuz et al. 2013 (TIP,
DOI 10.1109/TIP.2012.2231087) add a *selectivity* measure and noise-adaptive fusion for all-in-focus
images. Their abstract says "most current approaches… rely on maximizing the spatial frequency… sensitive
to noise".

| Measure | Cost on GPU | Notes |
|---|---|---|
| Energy of Laplacian / **SML** (\(|2I-I_{x-1}-I_{x+1}| + |2I-I_{y-1}-I_{y+1}|\), summed over a window) | 2 passes | **Default.** Sharp peak across depth, cheap, separable window. |
| Tenengrad (Sobel² energy) | 2 passes | Similar performance, slightly smoother. focus-stack's depth map uses Sobel. |
| Local variance (statistical) | 2 box filters | More robust to noise, less selective. Use at the finest scale in high-ISO stacks. |
| Wavelet / DCT energy | Pyramid | This is what the pyramid strategy uses implicitly. |
| Multi-scale (per-level coefficient energy) | Free in pyramid fusion | Needed for "Detail". |

**Recommendations.**
- Compute the measure on **encoded** luma (`log` or `sqrt`), not linear Y. A Laplacian on linear data
  scales with brightness, so a defocused specular highlight would outscore in-focus mid-tones. The `sqrt`
  encoding also roughly stabilizes Poisson noise variance.
- Use a **noise-aware threshold**: subtract `k·σ_n` from the measure, with k≈3, where σ_n comes from the
  per-ISO noise profile of workstream A. This is the analogue of Zerene DMap's contrast threshold, but
  automatic.
- Default window radius r≈4 px at 24 MP, scaled by `sqrt(MP/24)`, so about 5.5 px at 45 MP. Expose it as
  **Radius** in the pro panel, mirroring Helicon.
- Pre-denoise the *measure input* only, with a light bilateral filter or the workstream A denoiser.
  Zerene's FAQ notes that better SNR "helps Zerene Stacker to make better decisions".

### 2d. Fusion strategies

| Family | Key references | Best at | Fails at |
|---|---|---|---|
| **Depth map** (per-pixel argmax of the focus volume, then regularization) | Nayar 1994; photomontage with graph cuts + gradient-domain fusion, which includes an extended-DOF example (Agarwala et al. 2004, DOI 10.1145/1186562.1015718); graph cuts (Boykov, Veksler & Zabih, ICCV 1999 DOI 10.1109/ICCV.1999.791245; TPAMI 2001); **cost-volume filtering** with a guided filter (Hosni et al. CVPR 2011, DOI 10.1109/CVPR.2011.5995372; guided filter He, Sun & Tang, DOI 10.1109/TPAMI.2012.213) | Clean colour and tone (every pixel is a real source pixel); smooth surfaces; low noise; landscapes and products | Overlapping hairs and bristles (one label per pixel); halos at occlusion boundaries; textureless areas need regularization; banding if the step is too large |
| **Pyramid max-selection** | Laplacian pyramid (Burt & Adelson 1983, IEEE Trans. Comm. 31(4), DOI 10.1109/TCOM.1983.1095851); salience and match rule (Burt & Kolczynski, ICCV 1993, DOI 10.1109/ICCV.1993.378222); complex wavelets (Forster et al. 2004) | Maximum detail at every scale; crossing structures; low-contrast detail | Contrast and "glare" boost, noise accumulation ("grit"), colour shifts, inversion halos (Zerene, Helicon) |
| **Weighted average** | Helicon A; exposure fusion (Mertens, Kautz & Van Reeth 2007, DOI 10.1109/PG.2007.17), with the sharpness weight as the only term | Short stacks (2–5 frames), landscapes, preserving colour | Blur and ghosting on long stacks (defocused frames always contribute) |
| **Guided-filter fusion (GFF)** | Li, Kang & Hu 2013 (DOI 10.1109/TIP.2013.2244222) | Fast, smooth weight maps, two-scale (base/detail) | Designed for pairs; halos when the blur spread is large |
| **Multi-scale weighted gradient (MWGF)** | Zhou, Li & Wang 2014 (DOI 10.1016/j.inffus.2013.11.005) | Handles defocus-spread boundaries better than per-pixel methods | Heavier; gradient-domain reconstruction needs a Poisson solve |
| **DCT domain** | Haghighat et al. 2011 (DOI 10.1016/j.compeleceng.2011.04.016) | Very cheap | Block artifacts |
| **Hybrids** | Zerene's recommended workflow (PMax painted into DMap); Helicon's "another output as source" | The best results in practice | Manual today |

**Recommended user-facing strategies.**

| Redlamp name | What it does | Closest equivalent | Default for |
|---|---|---|---|
| **Auto** (default) | A hybrid in the Laplacian domain. Base and coarse levels come from depth-map-weighted blending (clean tone and colour). At fine levels, the max-saliency selection is **constrained to frames within ±Δ of the regularized depth estimate** (Δ = 2 frames). It is released outside the window only when an out-of-window frame's saliency exceeds the in-window best by τ=1.5×, which is typical of crossing hairs and occluders. The finest level uses grit suppression (below). | An automated "PMax retouched into DMap" | Everything, unless the user chooses otherwise |
| **Smooth** | A depth map: cost volume, guided-filter regularization, winner-takes-all with sub-frame interpolation, then a soft two-frame blend at full resolution | Zerene DMap, Helicon B | Landscapes, products, smooth surfaces, high ISO |
| **Detail** | Pyramid max-saliency with region energy, base level averaged, and optional grit suppression | Zerene PMax, Helicon C | Insects, fur, bristles, microscopy |

Helicon A-style weighted averaging is used inside **Auto** when N ≤ 4, for example for landscape
foreground/infinity pairs. **Assessment:** the constrained hybrid is our own design, not a published
method. Validate it against Zerene and Helicon on the §7 stacks in the Phase 3 prototype.

**Default parameters (pro panel, 45 MP).**

| Parameter | Default | Range | Notes |
|---|---|---|---|
| Radius (focus window) | 5 px | 1–30 | Helicon's "Radius". Lower means sharper hairs and more halo and noise |
| Smoothing (depth regularization) | guided filter r=8 at 1/4 res, ε=1e-3 | r 0–32 | Helicon "Smoothing", Zerene "Smoothing Radius" |
| Noise threshold | 3·σ_n(ISO) | 0–10 σ | Automatic analogue of the Zerene DMap threshold |
| Pyramid levels | ⌊log2(min(W,H))⌋−5 (≈8 at 45 MP) | — | Coarsest level ≥ 32 px |
| Saliency window | 3×3 Gaussian (σ=1) region energy | 1–5 | Burt & Kolczynski salience |
| Grit suppression | On: at levels 0–1, if max saliency < 3σ_n, use the depth-map frame's coefficient | On/Off | Zerene's "grit suppression" |
| Constraint window Δ (Auto) | ±2 frames | 0–∞ | 0 gives pure depth map; ∞ gives pure pyramid |
| Alignment model | Similarity | Translation / Similarity / Affine / Homography | |
| Crop | Intersection of all frames | Intersection / Reference framing | |

### 2e. Artifact handling

- **Halos at high-contrast edges.** *Why:* a defocused foreground edge spreads its blur disc *beyond*
  its geometric boundary. The literature calls this the defocus spread effect (MFFW, arXiv 2002.04780).
  In the frame where the background is sharp, that band is covered by foreground blur. In the frame where
  the foreground is sharp, the band shows blurred background. So neither frame has correct pixels in a
  band about one blur radius wide. Magnification changes with focus shift edges further. Selection
  methods pick the high-contrast *blurred edge*, which gives a bright or dark rim. Pyramid methods
  amplify it into Zerene's "inversion halos".
  *Mitigations:*
  1. focus-stack's **halo removal**: subtract a dilated contrast map, so that less-sharp features next to
     a sharp one are masked.
  2. Larger radius or smoothing near strong edges (Helicon: radius 22 "almost eliminate[s]" halos).
  3. The Auto constraint window, which stops far-depth frames from contributing fine detail.
  4. Edge-aware depth regularization guided by the sharp composite, not by any single frame.
  5. Retouch.
  6. Phase 4: a learned boundary refiner.
- **Occlusion, "transparent foreground" and "look-around".** Wide apertures see *behind* thin
  foreground objects (Zerene tutorial). *Mitigation:* depth ordering, which prefers the nearest
  sharp surface when two depths both score high. Detect it through bimodal focus curves. Offer a
  one-click "Stack selected frames" sub-stack as a retouch source (Zerene's documented fix).
- **Moving subjects** (antennae, flowers in wind). Helicon's guide shows an output that combines
  antennae "from all the source images". *Mitigation:* the flow-residual check (§2b). In regions with
  motion, use single-frame selection (depth map) instead of pyramid mixing, and suggest retouch.
- **Exposure and flicker normalization:** per-frame, per-channel linear gain (§2b.6). Canon and Sony
  "exposure smoothing" and Nikon "exposure lock" reduce but don't remove it, and flash recycle varies.
- **Colour shifts:** select all channels from the same frame (depth map) or fuse the chroma of the
  *selected* frames (pyramid: fuse luma coefficients, then take chroma from the winning frame at each
  level). Keep the base level as an average.
- **Noise accumulation (pyramid):** max-abs selection at the finest scales picks noise peaks, which
  gives "grit". *Mitigation:* noise-aware saliency and grit suppression; optionally fuse frames that
  were denoised by the workstream A denoiser. Our scene-referred pipeline makes Zerene's "UDR" squash
  unnecessary: we keep values above 1.0 and let the tone mapper handle them.
- **Edge streaks** from frames that don't cover the reference field of view: reference the narrowest
  end, then crop (Zerene FAQ).
- **Dust and hot-pixel trails:** static sensor defects "move" relative to the aligned subject. Detect
  pixels that are constant in *sensor* coordinates across the stack (for example, a per-pixel temporal
  minimum or maximum outlier in raw space) and in-paint them before alignment. This is an automatic version
  of the dust maps in Helicon and Zerene.
- **Clipped highlights:** treat any channel at or above the white level as zero-confidence, so an
  unclipped frame wins where possible. Carry a clip mask into the virtual raw so highlight
  reconstruction still works.
- **Demosaic artifacts:** pyramid fusion *selects* high-frequency zipper and maze patterns. Use the best
  demosaic we have (RCD or AMaZE, planned) for stacking inputs, even if the interactive path uses
  Malvar-He-Cutler.

### 2f. Retouching (paint from source)

**Model:** the brush reveals an **aligned source** (any frame, a sub-stack, or another strategy's output)
over the fused result, the way Zerene and Helicon do. Controls are size, hardness and opacity, plus
Helicon's *colour tolerance* (only paints pixels similar to the brush-centre colour in the source). The
UI adds hover to show the frame under the cursor (Helicon F9, which our depth map makes free),
scroll or drag to scrub depth (Zerene Shift+drag), and hold S to flash the source.

**Non-destructive representation** (in the stack recipe; coordinates are normalized to the *reference
frame after alignment*, so they survive re-alignment only when the reference is unchanged):

```json
{
  "retouch": [
    { "id": "3F2A…", "source": { "kind": "frame", "index": 17 },
      "radius": 0.004, "hardness": 0.6, "opacity": 1.0, "colorTolerance": 1.0,
      "points": [[0.4121, 0.2873, 1.0], [0.4130, 0.2880, 0.9]] },
    { "id": "9C1B…", "source": { "kind": "substack", "frames": [3, 9], "strategy": "detail" },
      "radius": 0.010, "hardness": 0.3, "opacity": 0.8, "points": [[0.61, 0.52, 1.0]] }
  ]
}
```

Re-rendering rasterizes each stroke mask at full resolution and composites the aligned source in order.
The stroke masks are cached as a tiled 8-bit bitmap in the render cache. This follows the same pattern
as the AI mask bitmaps in the sidecar.

### 2g. Recommended classical pipeline (v1)

1. **Detect and group** (§2a). The user confirms and can reorder or exclude frames.
2. **Pass 0 (preview, about 1–2 s):** run the full pipeline on the 1/8-scale mip of each frame, reusing
   thumbnails and low mips. Show it immediately.
3. **Pass 1 (low resolution, parallel with decoding):** decode (LibRaw, CPU, several in parallel), GPU
   demosaic, dust and hot-pixel check, lens undistortion and lateral CA correction, and a 2048 px encoded
   luma. Then run chained ECC similarity alignment, the photometric gain fit, the 1/4-resolution focus
   volume (SML) and the flow residual check. Keep the raw CFA (uint16) in RAM or in the disk cache for
   pass 2.
4. **Depth solve** at 1/4 resolution: noise threshold, guided-filter cost-volume regularization,
   winner-takes-all, sub-frame parabolic refinement, confidence, and edge-aware fill of low-confidence
   areas.
5. **Pass 2 (full resolution, streaming):** for each frame, demosaic it, warp it once (Lanczos-3), apply
   gains, compute the full-res focus measure and a tiled Laplacian pyramid, then update the accumulators:
   - **Smooth:** a two-frame soft blend by fractional depth.
   - **Detail:** max-saliency per level.
   - **Auto:** max-saliency constrained to the depth window.
   Then free the frame.
6. **Finalize:** collapse the pyramid, clamp negatives, apply retouch strokes, write the cache, and
   register the virtual raw.

---

## 3. AI assistance

### 3.1 Survey of deep multi-focus fusion and depth from focus

**Benchmark realism.** **Evidence:**
- MFFW (arXiv 2002.04780): methods are "evaluated on simulated image sets or Lytro dataset… defocus
  spread effect is not obvious in simulated or Lytro datasets, where popular methods perform very
  similar". On their 19 real pairs, "most state-of-the-art methods… cannot robustly generate
  satisfactory fusion images".
- Araujo et al. (arXiv 2311.17846): existing deep approaches "are designed for very short image
  sequences (two to four images), and are typically trained on small, low-resolution datasets"; "only
  one approach… can take more than two images". They also note that Lytro has no ground truth and that
  papers report up to 19 different metrics. The benchmark paper MFIFB (arXiv 2005.01116) makes the same
  point about arbitrary metric choice.

**Assessment:** leaderboard numbers on Lytro, MFI-WHU or Real-MFF say almost nothing about 30–200
frame macro stacks.

| Candidate | What | N>2? | Code licence | Weights | Training data |
|---|---|---|---|---|---|
| IFCNN (DOI 10.1016/j.inffus.2019.07.011) | Supervised CNN, general fusion | Element-wise max over features lets it take N inputs, per the paper; not verified for long stacks | **No LICENSE** in [uzeful/IFCNN](https://github.com/uzeful/IFCNN) | Same | Synthetic multi-focus data built by the authors ("large-scale… dataset") |
| U2Fusion (DOI 10.1109/TPAMI.2020.3012548) | Unsupervised unified fusion | Pairs | **No LICENSE** ([hanna-xu/U2Fusion](https://github.com/hanna-xu/U2Fusion)) | Same | Baidu-hosted set |
| SwinFusion (DOI 10.1109/JAS.2022.105686) | Swin transformer | Pairs | **No LICENSE** (based on SwinIR, Apache-2.0) | Same | MFI-WHU (for multi-focus) |
| MFF-GAN (DOI 10.1016/j.inffus.2020.08.022) | Unsupervised GAN | Pairs | **MIT** | In repo (MIT) | MFI-WHU (MIT repo, but "full-clear source images come from some public datasets", which are unnamed) |
| SESF-Fuse (DOI 10.1007/s00521-020-05358-9) | Unsupervised, spatial frequency | Pairs | **LGPL-2.1** | — | — |
| DRPL (DOI 10.1109/TIP.2020.2976190) | Regression pair learning | Pairs | **No LICENSE** | Same | Synthetic |
| ZMFF (DOI 10.1016/j.inffus.2022.11.014) | Zero-shot (deep-image-prior style, per-image optimization) | Pairs | **No LICENSE** | None needed | **None** |
| DeFusion (ECCV 2022, DOI 10.1007/978-3-031-19797-0_41) | Self-supervised decomposition | Pairs | **MIT** | Google Drive, no stated licence | COCO (Flickr images under mixed licences, some NC) |
| MUFusion (Information Fusion 2023) | Memory-unit unsupervised | Pairs | **MIT** | — | Mixed (TNO, RoadScene, SICE, and a multi-focus set) |
| FusionDiff (DOI 10.1016/j.eswa.2023.121664) | DDPM for multi-focus fusion | Pairs | Repo not found | — | — |
| ReDiffuse (arXiv 2603.21129) | Rotation-equivariant diffusion | Pairs | **No LICENSE** ([MorvanLi/ReDiffuse](https://github.com/MorvanLi/ReDiffuse)) | `weights/model.pt`, no licence | Real-MFF |
| **StackMFF V1–V4** (Research Square 10.21203/rs.3.rs-5315538/v1; V2–V4 repos) | **N-frame stack fusion**, focal-depth regression (V2) | **Yes** | README badge says MIT, but **there is no LICENSE file** (GitHub API: none) | In repo | V1: synthetic stacks from **Open Images V7**. V3/V4: **NYU-V2, DUTS, DIODE, Cityscapes, ADE** (StackMFF-V3 README) |
| GMFF (arXiv 2512.21495) | StackMFF-V4 plus IFControlNet on **Stable Diffusion 2.1** ("reconstruct content from missing focal planes") | Yes | Badge MIT, no LICENSE file | IFControlNet + `v2-1_512-ema-pruned.ckpt` (CreativeML Open RAIL++-M) | LAION-derived SD base |
| **Araujo et al. FocusDeep** (arXiv 2311.17846) | Raw-burst joint demosaic, fusion and denoise; 30-frame bursts | **Yes** (30) | **No LICENSE** ([araujoalexandre/FocusStackingDataset](https://github.com/araujoalexandre/FocusStackingDataset)) | Not released | **LSFD:** 94 bursts × 30 raw frames from a Panasonic GX9 (Leica 25/1.4 and Olympus 60/2.8 Macro), about 96 GB on Google Drive, **no licence stated**. The pseudo ground truth is **Helicon Focus output**. |
| DDFF 12-Scene / DDFFNet (arXiv 1704.01085) | Depth from focus with a light-field-generated focal stack | Yes | **GPL-3.0** ([soyers/ddff-pytorch](https://github.com/soyers/ddff-pytorch)) | — | DDFF 12-Scene (terms not verified) |
| AiFDepthNet (arXiv 2108.10843) | Depth plus all-in-focus from a focal stack | Yes | **No LICENSE** | Released | FlyingThings3D_FS, DefocusNet, 4D LF, Mobile Depth |
| DFV (arXiv 2112.01712) | Differential focus volume depth from focus | Yes | LICENSE: **"All contributions from DDFF… GPLv3"** plus MIT for its own parts | — | DDFF12, FoD500 |
| HybridDepth (arXiv 2407.18443) | Depth from focus plus a mono-depth prior; the *phone focal stack* use case | Yes | **GPL-3.0** | — | NYU v2 and others |
| **FOSSA** (arXiv 2603.26658, ECCV 2026) | Zero-shot depth from defocus; stack attention with a focus-distance embedding | **Yes** | **BSD-3-Clause** ([princeton-vl/FOSSA](https://github.com/princeton-vl/FOSSA)) | **BSD-3-Clause** (HF [venkatsubra/fossa-vits](https://huggingface.co/venkatsubra/fossa-vits), `cardData.license`) | Synthetic stacks from **Hypersim (CC BY-SA 3.0)** and **TartanAir (CC BY 4.0)**. ViT-S backbone: Depth-Anything-V2-Small (Apache-2.0). ViT-B backbone: DAv2-Base (**CC-BY-NC-4.0**) |

**Quality on real macro and landscape stacks.**
- Araujo et al. is the only source with real long raw bursts. On their test set, measured against
  Helicon ground truth: Laplace 26.88 dB PSNR / 0.712 SSIM, Wavelets 27.65 / 0.828, U-Net RGB
  36.29 / 0.922, FocusDeep RGB 38.47 / 0.965, FocusDeep raw 32.89 / 0.898 (Table 3). **Caveat:** the
  ground truth *is* Helicon, so this measures imitation of Helicon, not truth. Their qualitative claim is
  being "on par with existing commercial solutions" and "significantly more tolerant to noise",
  including a 30-frame iPhone 12 burst at ISO 1000 (Fig. 1).
- The StackMFF and GMFF papers evaluate mostly on synthetic and light-field data. GMFF's generative
  stage deliberately invents content for missing focal planes. **Assessment:** that is unacceptable for a
  photographer's tool, for the same reason as the "hallucination risk" named in workstream B.
- FOSSA reports "reducing errors by up to 55.7%" on its new real-world ZEDD benchmark (depth, not
  fusion).

### 3.2 Where learning actually helps (Phase 4 candidates)

1. **Noise-robust fusion for high-ISO and phone bursts.** This is the strongest evidence (Araujo). Train
   our own on stacks we capture ourselves, with pseudo ground truth from our classical Auto strategy
   *computed on low-ISO repeats*, not from Helicon (see Risks).
2. **Halo and boundary refinement:** a small CNN that predicts per-pixel frame weights near depth
   discontinuities, trained on our own stacks (captured with and without backdrops, or synthesized with a
   thin-lens model on our all-in-focus captures). Classical halo removal ships first.
3. **Motion and occlusion masks:** start with classical DIS or Apple Vision flow residuals. A learned
   model is only worth it if the classical version fails in user testing.
4. **Depth prior for textureless regions:** FOSSA ViT-S (true depth from defocus, uses the whole stack)
   is a better fit than a monocular model. Depth Anything V2 Small (Apache-2.0 on its HF card) or Depth
   Pro could serve as a segmentation-like smoothness guide only. Depth Pro's GitHub README says "The model
   weights are released under the LICENSE terms" (Apple sample-code licence), but its HF card says
   `apple-amlr`, so it is **UNCLEAR**. Mono depth is relative and scene-level, and is unreliable at macro
   scale.
5. **Subject and matting masks** from workstream C (Vision or SAM-class) to snap depth labels to object
   boundaries, which helps with hair.

**Fewer or sloppier frames.** **Assessment:** learning cannot recover detail that no frame recorded
without inventing it. It *can*:
- tolerate handheld misalignment (dense alignment);
- tolerate larger focus steps, by using mild non-blind deconvolution of regions between focal planes,
  with the point-spread function estimated from the depth map and step size (a classical option, worth a
  Phase 4 spike);
- denoise high-ISO phone frames.

Casual users will get good results from about 8–20 frame handheld phone sweeps, as Zeus and the Araujo
iPhone example suggest, not from 3 frames.

**iPhone capture.** **Evidence:** `AVCapturePhotoBracketSettings` supports only the manual and auto
*exposure* bracket subclasses ([Apple docs](https://developer.apple.com/documentation/avfoundation/avcapturephotobracketsettings)).
A focus bracket must be built by calling `setFocusModeLocked(lensPosition:completionHandler:)` before
each capture. `lensPosition` runs 0…1, "doesn't correspond to an exact physical distance, nor… a
consistent focus distance from device to device", and 1.0 "doesn't represent focus at infinity".
`minimumFocusDistance` is in mm (iOS 15+). Zeus Focus Stacking shows this works in practice, with 10–20
frames at up to 48 MP. **Assessment:** in-app capture is a Phase 4 option. Phase 3 should import phone
sweeps, grouped by `BurstUUID` or time and `FocusPosition`.

### 3.3 AI shortlist

| Candidate | Code license | Weights license | Data | Quality evidence | Apple Silicon fit | Verdict |
|---|---|---|---|---|---|---|
| FOSSA ViT-S (depth prior) | BSD-3 | BSD-3 | Hypersim CC BY-SA 3.0; TartanAir CC BY 4.0; DAv2-S backbone | 55.7% error reduction (ZEDD, their paper) | ViT-S; Core ML plausible (not tested) | **UNCLEAR, leaning Shippable** after legal review of BY-SA and DAv2-S data. Phase 4 spike |
| StackMFF V3/V4 architecture (N-frame fusion) | UNCLEAR (badge only) | UNCLEAR | NC-tainted (Cityscapes, ADE, DUTS, NYU) | Synthetic benchmarks only | Small (V4 about 4 MB) | **Fine-tune only:** re-implement from the paper, retrain on our data |
| Araujo FocusDeep (raw bursts) | None | Not released | LSFD, unlicensed, Helicon ground truth | Best real-world evidence | Burst-SR-style CNN, tiled | **Research-only.** Method inspires our Phase 4 model |
| OpenFocus (app + StackMFF-V4) | MIT | MIT claimed; data tainted | As StackMFF | None published | Python | **Reference only.** Weights: Fine-tune only |
| ZMFF (zero-shot) | None | n/a | none | Lytro, MFI-WHU, Real-MFF | Per-image optimization is too slow (seconds to minutes per pair; not measured) | **Shippable as a clean-room method in principle, but not useful** (pairs, slow) |
| MFF-GAN, DeFusion, MUFusion | MIT | Various | Unclear or NC | Pair benchmarks | Small CNNs | **Fine-tune only; low priority** (pair-based) |
| IFCNN, U2Fusion, SwinFusion, DRPL, ReDiffuse | None | None | Various | Pair benchmarks | — | **Research-only** |
| SESF-Fuse; DDFF; DFV (code); HybridDepth | LGPL / GPL | — | — | — | — | **Avoid** |
| GMFF (diffusion) | UNCLEAR | SD 2.1 RAIL++-M | LAION | Generative | Heavy | **Avoid** (hallucination and data) |
| DIS flow (paper) / Apple Vision flow | Paper; system API | n/a | n/a | Standard | Fast | **Shippable** (classical motion masks) |
| RAFT / SEA-RAFT | BSD-3 | No separate licence | FlyingChairs, Things, Sintel, KITTI (terms not verified; KITTI is commonly NC) | Standard flow SOTA | Core ML feasible | **Fine-tune only** (for motion masks, if DIS proves insufficient) |

---

## 4. Placement in Redlamp and the result format

### 4.1 Pipeline stage

**Recommendation: after demosaicing, in camera-native linear RGB (the space `SessionBuilder` writes into
the `rgba16Float` pyramid), before white balance, the colour matrix and any user edit.**

- **Why not in the raw/CFA domain?** Alignment needs sub-pixel warps with scale. Warping a mosaic breaks
  the CFA pattern, so you must interpolate per colour plane, which *is* demosaicing, done badly. Zerene
  states that no stacker works directly on raw for this reason. Araujo's raw model has to learn joint
  demosaic, fusion and denoise, and it scores *lower* (32.9 dB) than their RGB variant (38.5 dB).
- **Why linear?** Exposure flicker is a pure gain, so normalization is physically exact. Pyramid
  fusion in linear light is not perceptually uniform, but we fuse *values* in linear light while
  computing *saliency* on encoded luma (§2c). There is no display-referred clipping, so Zerene's "UDR"
  problem disappears.
- **Why before WB and colour?** The virtual raw must behave like a raw. Changing WB or profile later
  must be identical to doing so on a single frame. Store the fused data unbalanced, together with the
  reference frame's as-shot multipliers and `xyzToCamera` matrix. The existing `DecodedImage.layout ==
  .linearRGB` path in `SessionBuilder.encodeLinearRGB` already consumes exactly this, so the stack
  becomes a new *decode source*, not a new pipeline.
- Lens distortion and lateral CA are applied *per frame before fusion* (§2b) and flagged as consumed,
  so the lens-correction panel on the virtual raw starts at "already applied" for geometry and keeps
  vignetting user-adjustable.

### 4.2 Result: virtual raw versus baked DNG

| | Virtual raw (recipe + cache) | Baked linear DNG (Lightroom HDR/pano style; Helicon Pro "Raw-in-DNG-out") |
|---|---|---|
| Storage | Recipe of about 10–100 KB plus an **evictable** cache (45 MP half-float RGB is 272 MB raw; estimate 120–200 MB losslessly compressed) | 150–270 MB per result, permanent |
| Reproducibility | Deterministic given sources + algorithm version + cached transforms. GPU float ordering can differ slightly across chips, so the cache is authoritative when present | Frozen pixels, fully reproducible |
| Re-editing the stack | Yes: change strategy, radius, frame subset, or retouch strokes, then re-render | No: restack from sources |
| Portability | Redlamp only, unless exported | Any DNG-capable app |
| Re-render cost | About 5–30 s on a Mac after cache eviction or on a new device (needs sources present) | None |
| Sources missing | Falls back to the cache; if the cache is also gone, the stack is unrenderable (warn) | Unaffected |

**Recommendation:** use the **virtual raw as the primary format**, with **"Bake to linear DNG"** as an
explicit export or convert action (also used when sources are about to be deleted), and a setting to
keep the cache pinned. This fits the brief's reproducibility rule (model or algorithm output affecting
pixels is versioned and cached) and Redlamp's non-destructive identity. Sketch of the recipe:

```json
{
  "format": "app.redlamp.stack", "version": 1,
  "engine": { "focusStack": "classical-1.0.0", "demosaic": "rcd-1" },
  "sources": [
    { "path": "../DSC_0412.NEF", "sha256": "…", "size": 51234567, "captureTime": "…",
      "transform": [1.0012, 0.0003, -2.1, -0.0003, 1.0012, 3.4], "gain": [1.002, 0.999, 1.001] }
  ],
  "reference": 0, "order": "near-to-far",
  "strategy": "auto",
  "params": { "radius": 5, "smoothing": 8, "noiseK": 3.0, "levels": 8, "window": 2, "grit": true,
              "model": "similarity", "crop": "intersection", "lensCorrected": true },
  "retouch": [],
  "cache": { "key": "sha256(recipe-without-retouch)+sha256(retouch)", "depthMap": "…", "fused": "…" }
}
```

The stack appears in the Library as one item (stack badge) whose normal sidecar (`Sidecar` /
`EditRecipe`) holds user edits. For hashing, use a full SHA-256 at import (multi-GB stacks are fine in
the background) and verify with size and mtime afterwards.

---

## 5. Performance

**Assumptions** (all **Estimates**, to be validated with the Phase 3 prototype on the M1 Ultra):
- 45.4 MP (8256×5504), lossless-compressed raw of about 50 MB per frame, N=50.
- Redlamp opens 24–26 MP in 70–250 ms today (brief), scaled ×1.8 for 45 MP. The CPU entropy decode is
  the dominant part of that.
- Bandwidth: M1 Ultra 800 GB/s ([Apple](https://www.apple.com/newsroom/2022/03/apple-unveils-m1-ultra-the-worlds-most-powerful-chip-for-a-personal-computer/)),
  M4 120 GB/s and M4 Pro 273 GB/s ([Apple](https://www.apple.com/newsroom/2024/10/apple-introduces-m4-pro-and-m4-max/)).
  Assume about 50–60% is achievable.
- GPU full-resolution per-frame traffic (warp + luma + measure + Laplacian pyramid + accumulator
  read/write, fp16) is about 4–6 GB.

| Stage (50 × 45 MP) | M1 Ultra (20 CPU cores, 800 GB/s) | M4 base Mac / iPad Pro M4 (120 GB/s) | Notes |
|---|---|---|---|
| Read files (2.5 GB) | ~0.5 s internal SSD | ~0.5–1 s | **SD card (UHS-II, about 250 MB/s): about 10 s.** Recommend importing first |
| Raw decode (CPU, LibRaw) | ~1.5–3 s (8 in parallel) | ~3–6 s (4 in parallel) | 125–450 ms per frame single-threaded |
| GPU demosaic | ~0.3–0.8 s | ~1–2 s | 5–40 ms per frame |
| Low-res alignment (ECC, 3 levels) + gain + 1/4-res focus volume | ~1 s | ~2–4 s | Overlaps with decoding |
| Depth solve (1/4 res cost volume, 50 slices) | <0.5 s | ~1 s | Guided filter per slice |
| Full-res warp + pyramid + fuse | ~0.6–1 s | ~4–6 s | Bandwidth-bound |
| Second decode (if the CFA is not cached) | +1.5–3 s | +3–6 s | CFA cache: 50 × 91 MB = 4.5 GB RAM or disk |
| **Total, Detail (1 pass)** | **~4–6 s** | **~10–18 s** | |
| **Total, Auto or Smooth (2 passes)** | **~5–10 s** | **~12–25 s** | Add about 1.5× for thermal throttling on fanless devices |
| Preview (1/8 scale, from mips and thumbnails) | <1 s after decode | ~1–2 s | |

**Verdict:** **realistic** on all M-series Macs from internal storage. The target of 60 s holds with a
margin of 3–10×, even on a base M1 or M2, where bandwidth is about 70–100 GB/s. Memory card I/O and
raw decoding are the bottlenecks, so the priorities are parallel decoding, overlapping decode with GPU
work, and importing before stacking.

**Memory strategy** (45 MP, fp16):
- Per in-flight frame: CFA uint16 91 MB, working RGBA16F 363 MB, and its Laplacian pyramid 484 MB (built
  **per tile with margins**, so bounded at about 150 MB).
- Accumulator pyramid (RGBA16F coefficients + r16F saliency): about 605 MB.
- Depth solve: cost volume at 1/4 res, 50 × 2.84 MP × 2 B = 284 MB.
- Total GPU working set is about **1.5–2.5 GB, independent of N**, with two frames in flight to
  overlap decoding and GPU work.
- Avoid holding N full frames: that would take 50 × 363 MB = 18 GB.
- Replace today's `r32Float` CFA texture with `r16Unorm` for stacking (halves it to 91 MB).
- Use slabbing (Zerene) internally for N>100 only as a *retouch aid*. It is not needed for memory.

**iPad (M-series).** Compute is similar to the M4 Mac. Memory is 8 GB on base iPad Pro models (16 GB on
the 1–2 TB configurations; not re-verified). Use the `com.apple.developer.kernel.increased-memory-limit`
entitlement (iOS/iPadOS 15+, [Apple docs](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit)),
keep the CFA cache on disk, and run as a background task with checkpoints. Feasible.

**iPhone (A17 Pro floor, 8 GB).** Native stacks are 12–48 MP and typically 10–20 frames. Scale the
numbers above: roughly 5–20 s for 20 × 48 MP (Estimate; A17 bandwidth is not published by Apple). Feasible
for phone stacks. Importing 50 × 45 MP camera stacks on iPhone is possible but slow (about 1–2 min) and
thermally limited, so gate it behind a warning.

**Scheduler integration:** run fusion as a background job, cancellable per frame, with checkpointing
(accumulator state per K frames) so thermal back-off or app suspension doesn't lose work. GPU passes run
on the P3-equivalent lane; the Phase 4 AI stages are P3.

---

## 6. UX outline

1. **Filmstrip detection:** a subtle badge on the first frame and a banner: "Focus stack detected: 32
   frames (Nikon focus shift)". Clicking selects the group. The banner has *Merge to Focus Stack* and
   *Dismiss*. Manual path: select any frames, then Photo > Merge to Focus Stack (⌥⌘F).
2. **Merge sheet** (one click works with defaults):
   - Strategy segmented control: Auto (default) · Smooth · Detail. Each has a one-line explanation, for
     example "Detail: best for hair and bristles; may add grain".
   - Frame strip with sharpness sparkline (per-frame focus peak position); exclude, include and reverse
     buttons; "keep widest framing" toggle.
   - Live low-res preview renders in about 1–2 s and updates with the strategy.
   - A **Merge** button. It runs in the background with a progress toast; the user can keep editing.
3. **Result:** a new stacked item in the filmstrip with a stack badge, positioned after the sources. The
   sources collapse under it (expand with a disclosure arrow). It opens like a raw: every Develop slider
   works.
4. **Stack panel** (in the Develop inspector, only for stack items):
   - Strategy picker and a **Re-render** button.
   - **Depth map preview** toggle: a colour-coded overlay by frame index, with a confidence overlay that
     highlights low-confidence areas.
   - **Retouch brush:** size, hardness, opacity, colour tolerance. The source is picked by hover-sample
     (the frame under the cursor), scrolling or dragging through depth, or choosing "Detail output",
     "Smooth output" or "Sub-stack…". Hold S to flash the source.
   - Warnings: "Subject movement detected in 3 regions", "Frames 1–4 don't cover the full frame
     (cropped)".
5. **Pro disclosure:** Radius, Smoothing, Noise threshold, Pyramid levels, Constraint window, Grit
   suppression, Alignment model, Brightness normalization on/off, Crop mode, Export depth map, Export
   aligned frames, Bake to DNG.

---

## 7. Test data

| Dataset | Content | Format | License (source, checked 2026-09-29) | Use |
|---|---|---|---|---|
| **focus-stack `examples/`** ([repo](https://github.com/PetteriAimonen/focus-stack/tree/master/examples)) | `depthmap/`: 10 frames of a PCB macro (`pcb_000–009.JPG`, about 1 MB each); `pcb/`: 7 frames + `expected.jpg` | JPEG | **MIT** (repo LICENSE.md; the images are not licensed separately) | Unit tests, CI golden image |
| **Figshare: Rovnopholcomma amber spider** (DOI 10.6084/m9.figshare.30771638) | About 20 microscope stacks of 11–72 frames (for example, `02_10x_dorsal` has 66); 1,014 JPEGs; `_d2` means downscaled 2×. Camera Olympus E-M10 on microscope (per scalebar file name) | JPEG | **CC BY 4.0** (figshare API) | Hard case: transparent medium, low contrast, deep stacks |
| **Figshare: mesostigmatic mite in Burmese amber** (DOI 10.6084/m9.figshare.14707077) | 18 stack zips, for example `26E_tubercules_dorsal_100x.zip` with 109 frames at 2304×1728 (verified by download) | JPEG | **CC BY 4.0** | Microscopy, long stacks |
| **Figshare: Histiogaster mites, Rovno amber** (DOI 10.6084/m9.figshare.28632650) | 13 zips, 5 GB | JPEG (not inspected) | **CC BY 4.0** | Microscopy |
| **ZEDD** ([HF](https://huggingface.co/datasets/venkatsubra/ZEDD)) | 100 indoor and outdoor scenes; 9 focus distances (0.82–8.10 m) × apertures F1.4–F5.6, plus an **F16 all-in-focus reference** and LiDAR depth (val split); 8.5 GB | JPEG | **CC BY 4.0** (`cardData.license`) | Near ground truth for room and landscape-scale stacks (compare against the F16 frame); depth-map accuracy |
| **raw.pixls.us** | Per-camera raw samples | Raw | **CC0** (upload declaration on the site) | Maker-note parser fixtures, but these are not stacks |
| Araujo **LSFD** ([repo](https://github.com/araujoalexandre/FocusStackingDataset)) | 94 bursts × 30 raw frames, Panasonic GX9, macro and normal lens; about 96 GB | RW2 raw | **UNCLEAR** (no licence; paper is CC BY 4.0 on arXiv, not the data; ground truth = Helicon output) | **Ask the authors** for evaluation rights. It is the best real raw set found |
| Lytro MFF (Nejati et al. 2015, DOI 10.1016/j.inffus.2014.10.004) | 20 pairs + 4 triples | JPEG | **UNCLEAR** (terms page unreachable) | Benchmark comparison only |
| MFI-WHU / Real-MFF / MFFW / MFIFB | 120 / 710 / 19 / 105 pairs | — | MFI-WHU and Real-MFF repos are MIT, but the source images are unnamed, "from public datasets" or light-field; MFFW was "collected on the Internet"; MFIFB has no licence: **UNCLEAR** | Evaluation-only, pending terms; never for training |
| Mobile Depth (Suwajanakorn et al. CVPR 2015, DOI 10.1109/CVPR.2015.7298972) | Phone focal stacks | JPEG | **UNCLEAR** (download page shows no terms) | Phone-sweep evaluation, if cleared |
| Wikimedia Commons "Focus stacking" / "Focus bracketing" | Mostly *results* (74 files) plus a few montages of bracket series | JPEG | Per file | Not useful as inputs |

**Recommendation.** The best public CC0/CC-BY *macro* stacks with source frames are the **figshare amber
microscope stacks (CC BY 4.0)**. For camera macro, only the MIT focus-stack PCB set is clearly licensed.
**Commission our own stacks** as the primary test and eval corpus:
- 6 vendors × about 10 subjects (insect, fur or feather, flower, jewellery, product, landscape
  foreground/infinity, handheld phone sweep);
- raw;
- with a small-aperture reference frame where diffraction is acceptable (ZEDD-style), plus
  Helicon and Zerene outputs for side-by-side comparison. Those outputs are for evaluation only; check
  both EULAs.

---

## 8. License matrix

| Candidate | Code license (source) | Weights license (source) | Training data (terms) | Obligations (attribution, patents) | Verdict |
|---|---|---|---|---|---|
| focus-stack (PetteriAimonen) | MIT (GitHub LICENSE.md) | n/a | n/a | MIT notice if code is copied; Forster 2004 method (no known patent) | Shippable (reference) |
| OpenCV (if used) | Apache-2.0 (GitHub API) | n/a | n/a | NOTICE; Apache patent grant | Shippable |
| SIFT / ORB / AKAZE / ECC / DIS (papers) | n/a | n/a | n/a | SIFT US6711293 expired March 2020 (OpenCV commit df10411e05) | Shippable (clean-room) |
| enblend/enfuse | GPL-2.0 (COPYING, GitHub mirror) | n/a | n/a | Copyleft | **Avoid; do not read source** |
| Hugin | GPL-2.0-or-later (not re-verified) | n/a | n/a | Copyleft | **Avoid** |
| OpenFocus | MIT (LICENSE) | StackMFF-V4 `.pth` in the MIT repo; no separate terms | Per StackMFF-V3: NYU-V2, DUTS, DIODE, Cityscapes, ADE (includes NC) | README: follow each algorithm's original licence | Code: reference. Weights: **Fine-tune only** |
| StackMFF V1–V4 | UNCLEAR (README badge MIT; no LICENSE file) | UNCLEAR | V1: Open Images V7; V3/V4: as above | — | **Fine-tune only** (re-implement architecture) |
| GMFF | UNCLEAR (badge only) | IFControlNet + SD 2.1 (CreativeML Open RAIL++-M) | LAION (SD base) | RAIL use restrictions | **Avoid** |
| IFCNN | None (no LICENSE) | None | Authors' synthetic set | — | Research-only |
| U2Fusion | None | None | Baidu set | — | Research-only |
| SwinFusion | None (SwinIR base Apache-2.0) | None | MFI-WHU | — | Research-only |
| MFF-GAN | MIT (GitHub API) | MIT (in repo) | MFI-WHU (UNCLEAR sources) | MIT notice | Fine-tune only |
| SESF-Fuse | LGPL-2.1 (GitHub API) | — | — | Copyleft | **Avoid** |
| DRPL | None | None | Synthetic | — | Research-only |
| ZMFF | None | n/a (zero-shot) | None | — | Method: Shippable as clean-room; code: Research-only |
| DeFusion | MIT | Google Drive, no licence | COCO (mixed Flickr licences) | — | Fine-tune only |
| MUFusion | MIT | — | Mixed datasets | — | Fine-tune only |
| ReDiffuse | None | `model.pt`, no licence | Real-MFF (UNCLEAR) | — | Research-only |
| Araujo FocusDeep / LSFD | None | Not released | LSFD: no licence; Helicon-generated ground truth | Possible Helicon EULA issue for training on its outputs | Research-only (ask authors) |
| DDFF (ddff-pytorch) | GPL-3.0 | — | DDFF 12-Scene (not verified) | Copyleft | **Avoid** |
| DFV | GPL-3.0 (DDFF parts) + MIT (LICENSE text) | — | DDFF12, FoD500 | Copyleft contamination | **Avoid code**; paper OK |
| AiFDepthNet | None | Released, no licence | FlyingThings3D etc. | — | Research-only |
| HybridDepth | GPL-3.0 | — | NYU v2 etc. | Copyleft | **Avoid** |
| FOSSA ViT-S | BSD-3 (GitHub API) | BSD-3 (HF card) | Hypersim CC BY-SA 3.0 (ml-hypersim README); TartanAir CC BY 4.0 (site); DAv2-S Apache-2.0 | Attribution; ShareAlike question for derived weights | **UNCLEAR, leaning Shippable** (legal review) |
| FOSSA ViT-B | BSD-3 | BSD-3 | DAv2-Base backbone CC-BY-NC-4.0 (HF) | NC | **Avoid** |
| RAFT / SEA-RAFT | BSD-3 | No separate licence | FlyingChairs, Things, Sintel, KITTI (not verified) | — | Fine-tune only |
| Apple Vision (registration, optical flow) | System framework | Apple | n/a | Platform terms | Shippable |
| Depth Anything V2 Small | Apache-2.0 | Apache-2.0 (HF card) | Synthetic + pseudo-labelled real (see workstream C) | NOTICE | Shippable-candidate (workstream C) |
| Depth Pro | Apple sample-code licence (GitHub LICENSE) | README: same LICENSE; HF card: `apple-amlr` | See paper | Contradictory | **UNCLEAR** |
| ZEDD dataset | n/a | n/a | CC BY 4.0 (HF) | Attribution | Shippable for eval and training |
| Figshare amber stacks | n/a | n/a | CC BY 4.0 | Attribution | Shippable for eval and training |

---

## 9. Effort estimates (engineer-weeks)

**Phase 3: Focus stacking v1 (classical)**

| Item | Weeks |
|---|---|
| Detection: LibRaw makernote callback, vendor tag table, heuristics, labelled fixtures per vendor | 2–3 |
| Alignment: GPU ECC coarse-to-fine, chaining and re-anchoring, gain fit, lens and CA pre-correction, feature fallback | 3–4 |
| Focus measure, depth solve (cost-volume guided filter), streaming pyramid, and Auto/Smooth/Detail fusion; tiling | 4–5 |
| Artifacts: halo removal, dust and hot pixels, clip handling, motion flagging | 2 |
| Virtual raw: stack recipe in `RedlampEngineAPI`, decode-source integration, cache, hashing, Bake to DNG | 2–3 |
| Retouch brush: stroke model, rendering, source picker, depth-scrub UI | 2–3 |
| UX: banner, merge sheet, stack panel, depth overlay, filmstrip stack grouping | 2–3 |
| Performance: parallel decode, overlap, iPad and iPhone memory, cancellation and checkpoints, scheduler | 1.5–2 |
| Evaluation: capture corpus, comparison against Helicon and Zerene, blind A/B | 1.5–2 |
| **Total** | **~20–27** (for example, 2 engineers for about 3 months) |

**Phase 4: AI-assisted**

| Item | Weeks |
|---|---|
| Own dataset: 150–300 stacks × vendors, low- and high-ISO pairs, pseudo ground truth pipeline | 4–6 |
| Learned boundary and halo refiner plus noise-robust fusion head (train, Core ML, tiled inference) | 6–10 |
| FOSSA-S depth prior spike (after legal) | 2–3 |
| Motion and occlusion masks (DIS or Vision first; learned if needed) | 2–3 |
| Handheld phone sweeps: dense local alignment and robust fusion; optional in-app capture | 5–8 |
| **Total** | **~19–30** |

---

## 10. Risks and open questions

1. **Sony and Fujifilm tag gaps.** ExifTool documents no focus-bracket code for them, so detection
   depends on heuristics. *Action:* collect sample brackets (α7R V, α1 II, X-H2/X-T5) and diff the maker
   notes against normal bursts.
2. **Nikon `FocusShiftShooting` semantics** are undocumented. *Action:* collect sample NEFs from a Z8 or
   Z9.
3. **The hybrid "Auto" strategy is unproven.** It could underperform PMax on hair if Δ is too tight.
   *Action:* the prototype should include blind comparison against Zerene and Helicon.
4. **Reproducibility across GPUs:** floating-point reduction order and argmax ties can flip labels. Make
   the cache authoritative, keep reductions deterministic, and document an acceptable tolerance.
5. **Source availability:** a virtual raw is unrenderable if the sources move or are deleted and the
   cache is evicted. Needs Library relinking and a "Bake before delete" prompt.
6. **Legal:** training on Helicon or Zerene outputs as pseudo ground truth may breach their EULAs (not
   checked). For FOSSA-S, the Hypersim CC BY-SA question needs an answer; Depth Pro's licence is
   contradictory.
7. **Demosaic quality** matters more for stacking (the pyramid selects artifacts). This depends on the
   RCD or AMaZE roadmap item.
8. **Memory on iPad and iPhone** with 45 MP camera stacks and jetsam limits. The actual
   increased-memory-limit ceiling for each device was not measured.
9. **Pertuz 2013's conclusions** were not verified from the full text (paywall).
10. **Open question:** should the *retouch* stroke coordinates survive re-alignment? Proposal: invalidate
    strokes when the reference or transform changes, and warn.
11. **Open question:** should we ship in-app phone capture (Phase 4) or only import sweeps from other
    apps? That depends on the product's camera strategy.

---

## 11. Sources checked (2026-09-29)

- Vendors: Helicon Focus 8 User Guide; Helicon Remote page; Zerene How To Use It, FAQ, Tutorials index
  and Downloads; Adobe Auto-Blend and Auto-Align (via web.archive.org 2025, because the live site
  returned 403); Affinity help (2 pages); Skylum Focus Stacking page; OM-1 manual v1.7 and OM-1 Q&A; Canon
  cam.start.canon Focus Bracketing pages (R7, R3, R5 II, R1, R8, R50, R10, R6 II, PowerShot V1); Sony α7R V
  Help Guide; Nikon Z8 online manual; Fujifilm X-H2 manual; Panasonic support article; App Store (iTunes
  Search and Lookup API).
- Metadata: exiftool.org TagNames (Sony, Nikon, Canon, FujiFilm, Olympus, Panasonic, Apple) and
  history pages; LibRaw `libraw_types.h` and `libraw.h` (GitHub master).
- Code and licences: via authenticated `gh api` (the unauthenticated GitHub API was rate-limited) for
  every repo listed; Hugging Face API for FOSSA, Depth Anything V2 and Depth Pro; the figshare and Zenodo
  APIs.
- Papers: arXiv API abstracts (2311.17846, 2512.21495, 2603.21129, 2005.01116, 2002.04780, 2003.12779,
  2407.18443, 2603.26658, 1704.01085, 2108.10843, 2112.01712, 1603.03590, 2003.12039, 2405.14793);
  arXiv HTML of 2311.17846 (dataset and table details); Crossref DOIs for the classical papers.
- Apple: AVFoundation (`AVCapturePhotoBracketSettings`, `setFocusModeLocked(lensPosition:)`,
  `lensPosition`, `minimumFocusDistance`), Vision (`VNHomographicImageRegistrationRequest`,
  `VNGenerateOpticalFlowRequest`), the increased-memory-limit entitlement, and newsroom bandwidth figures.
- **Could not verify:** the Lytro dataset terms (site timeout), the Pertuz 2013 abstract (paywall), the
  SceneFlow/FlyingThings terms (site timeout), the Hugin COPYING file, Nikon NX Studio and Sony desktop
  stacking features, and Helicon and Zerene sample downloads (search engines rate-limited; none found on
  the vendor pages visited).
