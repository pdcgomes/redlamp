# Research Intake Tracker

The single place where every recommendation from Redlamp's research gets a decision, a phase and a status. It covers both studies:

- [AI and computational photography findings](ai-findings.md) (source tag **AI**)
- [darktable study](darktable-findings.md) (source tag **DT**)

Where both studies recommend the same thing, the row is merged and cites both. *Last updated: 30 September 2026.*

## How to use this tracker

- **Every row starts as `Proposed`.** A row moves to `Accepted`, `Rejected` or `Deferred` only when the project owner decides, and the decision date goes in the Notes column. Items in the "Recommended" column are the research's suggestion, not a commitment.
- **Status** is tracked separately from the decision: `Not started`, `In progress`, `Blocked` (name the blocking row), `Done` (name the commit).
- **Change the tracker in the same pull request as the work.** A row is `Done` when the code, tests and docs land.
- **Review cadence:** walk the `Proposed` rows at each phase planning, and the `Blocked` rows weekly.
- **Adding rows:** new research or new ideas get a new ID in the right section; never reuse an ID.

**Columns**

| Column | Meaning |
| --- | --- |
| ID | Stable identifier, prefixed by area |
| Item | What to do |
| Recommended | The research verdict: **Adopt** (take the idea), **Do better** (same capability, our own design), **Build** (no usable prior art), **Skip** |
| Phase | Recommended roadmap phase (P1 is now) |
| Size | **S** ≤ 1 engineer-week, **M** 1–3, **L** 3–6, **XL** > 6. Figures in engineer-weeks (ew) come from the AI findings; sizes without figures are estimates made for this tracker |
| Depends on | Rows that must be done or decided first |
| Decision | `Proposed` / `Accepted` / `Rejected` / `Deferred` |
| Status | `Not started` / `In progress` / `Blocked` / `Done` |
| Source | Where the evidence is |

---

## 1. Decisions and legal questions

These block other rows. Most need the project owner; the ones marked *counsel* need legal advice.

| ID | Question | Recommended | Blocks | Decision | Source |
| --- | --- | --- | --- | --- | --- |
| DEC-01 | Update the README's clean-room policy to match the decision to allow reading GPL projects for understanding (never copying code or data) | Update the wording | — | Proposed | [DT §10](darktable-findings.md#10-decisions-needed) |
| DEC-02 | Accept Apache-licensed weights whose publisher trained on data we couldn't use (SAM 2.1, DINOv2; borderline: Depth Anything V2 Small) *(counsel)* | Accept for SAM 2.1 and DINOv2 | MSK-12, MSK-14 | Proposed | [AI §11.2](ai-findings.md#112-decisions-needed) |
| DEC-03 | Allow CC BY-SA (ShareAlike) data for training shipped models (RawNIND, HDR+, INTEL-TAU, Hypersim) *(counsel)* | Not until counsel answers | DN-07, FS-14 | Proposed | [AI §11.2](ai-findings.md#112-decisions-needed) |
| DEC-04 | Ship the lensfun database (CC BY-SA 3.0) as a separate resource file in an App Store bundle *(counsel)* | Yes, if counsel accepts the ShareAlike and anti-DRM terms | LNS-03 | Proposed | [DT §9](darktable-findings.md#9-licensing-of-reusable-pieces) |
| DEC-05 | Freedom-to-operate patent search: guided filter, BM3D, HDR+ merge, fast bilateral solver, LSD, FFCC/HDRNet, Adobe Upright and distractor-detection patents *(counsel)* | Run before Phase 2 ships | TON-05, DN-02, MSK-07, LNS-07 | Proposed | [AI §11.1](ai-findings.md#111-risks) |
| DEC-06 | Does a loss network trained on non-commercial data (LaMa's ADE20K segmenter) taint the weights it helps train? *(counsel)* | Replace the loss network unless counsel says no | RM-05 | Proposed | [AI §6](ai-findings.md#6-d-object-removal-healing-and-distraction-removal) |
| DEC-07 | Mask coordinate contract: canonical space is the EXIF-oriented image before crop, Transform and lens; user rotation is downstream geometry; gradient anchors in source space | Adopt as proposed | MSK-01, LNS-05 | Proposed | [DT §5](darktable-findings.md#5-modules-filters-and-masks) |
| DEC-08 | Mask Intersect: product (today) or minimum (darktable)? | Measure Lightroom, then match it | MSK-02 | Proposed | [DT §2](darktable-findings.md#2-phase-1-issues-found-in-redlamp) |
| DEC-09 | Ship the new tone map in Phase 1 (process version 1) or as part of process version 2 | Phase 1, before looks lock in | TON-02 | Proposed | [DT §10](darktable-findings.md#10-decisions-needed) |
| DEC-10 | Allow Mac-only larger models (an "XD" denoiser the iPhone can't run)? | Decide before DN-08 | DN-08 | Proposed | [AI §11.2](ai-findings.md#112-decisions-needed) |
| DEC-11 | Where mask and AI result blobs live: a companion directory or a sidecar package | Decide with iCloud sidecar coordination | EDT-12, INF-06 | Proposed | [AI §11.2](ai-findings.md#112-decisions-needed) |
| DEC-12 | Budget: one ML engineer from Phase 2, a capture program, expert editing (about US$15–40k), cloud training (about US$26–71k per year at full scale) | Approve | DN-06, DN-07, AUT-04 | Proposed | [AI §1](ai-findings.md#1-executive-summary) |
| DEC-13 | Get written confirmation of SIDD's MIT terms; ask LSFD and DND authors for evaluation rights; check Helicon, Zerene and DxO EULAs before publishing comparisons | Do all four | DN-09, FS-12 | Proposed | [AI §11.3](ai-findings.md#113-open-questions-to-verify) |

---

## 2. Phase 1: now

| ID | Item | Recommended | Size | Depends on | Decision | Status | Source |
| --- | --- | --- | --- | --- | --- | --- | --- |
| P1-01 | Add `processVersion` to `EditRecipe` (legacy sidecars read as version 1) | Adopt | S | — | Accepted (2026-09-30) | Done (`382f1ac`) | [DT §6](darktable-findings.md#6-edits-presets-styles-and-versioning) |
| P1-02 | Preserve unknown recipe values and fields, and unknown top-level sidecar fields, through load and save | Do better | S | — | Accepted (2026-09-30) | Done (`382f1ac`) | [DT §2](darktable-findings.md#2-phase-1-issues-found-in-redlamp) |
| P1-03 | Never overwrite or delete a sidecar written with a newer format or process version | Adopt | S | — | Accepted (2026-09-30) | Done (`382f1ac`) | [DT §6](darktable-findings.md#6-edits-presets-styles-and-versioning) |
| P1-04 | Skip sidecar writes when only `modified` would change | Adopt | S | — | Accepted (2026-09-30) | Done (`382f1ac`) | [DT §2](darktable-findings.md#2-phase-1-issues-found-in-redlamp) |
| P1-05 | Show that a photo's edit is read-only because a newer Redlamp wrote it | Adopt | S | P1-03 | Proposed | Not started | [DT §6](darktable-findings.md#6-edits-presets-styles-and-versioning) |
| P1-06 | Move "Process version selector" in the Lightroom inventory from Phase 2 to Phase 1; document the format-versus-process-version rules | Adopt | S | P1-01 | Proposed | Not started | [DT §11](darktable-findings.md#11-roadmap-changes) |
| TON-01 | Confirm the +2.5 EV highlight clip and the sRGB-only output with an exposure-wedge render and a Display P3 test pattern | Adopt | S | — | Proposed | Not started | [DT §2](darktable-findings.md#2-phase-1-issues-found-in-redlamp) |
| TON-02 | Replace the tone map: asymptotic log-space curve, EV white point, display peak as a parameter, primaries inset, middle-channel hue preservation; Contrast, Whites and Blacks drive it | Do better | M | TON-01, DEC-09 | Proposed | Not started | [DT §4](darktable-findings.md#4-color-science-and-tone) |
| TON-03 | Gamut-compress at constant hue and lightness into the real output gamut before the final clamp | Adopt | M | TON-01 | Proposed | Not started | [DT §4](darktable-findings.md#4-color-science-and-tone) |
| TON-04 | Tag the Metal canvas with extended linear Display P3 so ColorSync manages each screen | Do better | S | — | Proposed | Not started | [DT §8](darktable-findings.md#8-architecture-performance-and-ux) |
| ARC-01 | Stage graph with about five barrier stages and hash-chained per-stage caches; the fused kernel stays for all per-pixel work | Adopt, do better | L | — | Proposed | Not started | [DT §8](darktable-findings.md#8-architecture-performance-and-ux) |
| ARC-02 | Viewport-only rendering (visible region plus margin, low-resolution whole image underneath while panning) | Adopt | M | ARC-01 | Proposed | Not started | [DT §8](darktable-findings.md#8-architecture-performance-and-ux) |
| CAM-01 | Per-camera decode regression suite on CC0 raw.pixls.us samples (CFA, black, white, crop, as-shot WB, matrix); "no sample, no support claim" | Adopt | M | — | Proposed | Not started | [DT §3](darktable-findings.md#3-cameras-and-raw-data) |

---

## 3. Cameras and raw data

| ID | Item | Recommended | Phase | Size | Depends on | Decision | Status | Source |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| CAM-02 | Measured per-camera white levels, plus clip detection that needs a spike of pixels at the maximum (replaces LibRaw's per-image heuristic) | Do better | P2 | M | CAM-01 | Proposed | Not started | [DT §3](darktable-findings.md#3-cameras-and-raw-data) |
| CAM-03 | Apply DNG GainMap (OpcodeList2) by default in normalization | Adopt | P2 | S | — | Proposed | Not started | [DT §3](darktable-findings.md#3-cameras-and-raw-data) |
| CAM-04 | Dual-illuminant color: interpolated DNG matrices plus ForwardMatrix | Do better | P2 | M | P1-01 | Proposed | Not started | [DT §3](darktable-findings.md#3-cameras-and-raw-data) |
| CAM-05 | Paper-based Bayer demosaics (LMMSE, Menon 2007 or adaptive residual interpolation) instead of RCD and AMaZE | Do better | P2 | L | P1-01 | Proposed | Not started | [DT §3](darktable-findings.md#3-cameras-and-raw-data) |
| CAM-06 | Dual demosaic: blend a sharp and a smooth result by local contrast, with an automatic threshold | Adopt | P2 | S | CAM-05 | Proposed | Not started | [DT §3](darktable-findings.md#3-cameras-and-raw-data) |
| CAM-07 | Markesteijn X-Trans demosaic from LibRaw's CDDL source *(counsel to confirm)* | Adopt | P2 | M | — | Proposed | Not started | [DT §9](darktable-findings.md#9-licensing-of-reusable-pieces) |
| CAM-08 | CFA-domain highlight reconstruction (estimate clipped channels from unclipped neighbors) | Adopt | P2 | M | P1-01 | Proposed | Not started | [DT §3](darktable-findings.md#3-cameras-and-raw-data) |
| CAM-09 | Segmentation-based reconstruction of fully blown highlights | Adopt | P3 | M | CAM-08 | Proposed | Not started | [DT §3](darktable-findings.md#3-cameras-and-raw-data) |
| CAM-10 | JPEG XL DNG reading via libjxl (moved from P4) | Adopt | P2 | M | — | Proposed | Not started | [DT §3](darktable-findings.md#3-cameras-and-raw-data) |
| CAM-11 | Keep LibRaw for decoding; don't adopt rawspeed | Skip rawspeed | — | — | — | Proposed | — | [DT §3](darktable-findings.md#3-cameras-and-raw-data) |

---

## 4. Color, tone and detail

| ID | Item | Recommended | Phase | Size | Depends on | Decision | Status | Source |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| TON-05 | Exposure-independent guided filter (EIGF) as the base for edge-aware Highlights, Shadows, Whites, Blacks | Adopt | P2 | L | ARC-01, DEC-05 | Proposed | Not started | [DT §4](darktable-findings.md#4-color-science-and-tone) |
| TON-06 | Clarity, Texture and Sharpening on one multiscale decomposition, with deconvolution-style capture sharpening | Do better | P2 | L | ARC-01 | Proposed | Not started | [DT §5](darktable-findings.md#5-modules-filters-and-masks) |
| TON-07 | Gamut-relative Saturation and Vibrance in OKLCh | Do better | P2 | S | TON-03 | Proposed | Not started | [DT §4](darktable-findings.md#4-color-science-and-tone) |
| TON-08 | Spatially smoothed hue-band weights in the Color Mixer | Adopt | P2 | S | — | Proposed | Not started | [DT §4](darktable-findings.md#4-color-science-and-tone) |
| TON-09 | Native DCP support: matrices, HueSatMap and LookTable as 3D textures, profile tone curve | Do better | P2 | L | CAM-04 | Proposed | Not started | [DT §4](darktable-findings.md#4-color-science-and-tone) |
| TON-10 | ICC input, output and soft proofing through lcms2 (MIT) | Adopt | P2 | M | — | Proposed | Not started | [DT §4](darktable-findings.md#4-color-science-and-tone) |
| TON-11 | LUT import (`.cube`, `.3dl`, HaldCLUT) with log input spaces and an Amount slider | Adopt | P2 | M | — | Proposed | Not started | [DT §4](darktable-findings.md#4-color-science-and-tone) |
| TON-12 | Tone Equalizer panel with on-image scroll (beyond Lightroom) | Adopt | P3 | M | TON-05 | Proposed | Not started | [DT §5](darktable-findings.md#5-modules-filters-and-masks) |
| TON-13 | Maskable CAT16 "illuminant" tool for mixed lighting (advanced) | Adopt | P3 | M | MSK-03 | Proposed | Not started | [DT §4](darktable-findings.md#4-color-science-and-tone) |
| TON-14 | `redlamp-profiler`: chart matrix solve with ΔE report, and raw-versus-camera-JPEG look fitting in scene-referred space, writing DCP and `.cube` | Adopt | P3 (chart matrix possibly P2) | L | TON-09 | Proposed | Not started | [DT §4](darktable-findings.md#4-color-science-and-tone) |
| TON-15 | Frequency-separation retouching (heal or blur on one detail band) | Adopt | P4 | M | RM-01 | Proposed | Not started | [DT §5](darktable-findings.md#5-modules-filters-and-masks) |
| TON-16 | Film negative inversion | Adopt (candidate) | P4 | M | — | Proposed | Not started | [DT §1](darktable-findings.md#1-executive-summary) |

---

## 5. Masks

| ID | Item | Recommended | Phase | Size | Depends on | Decision | Status | Source |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| MSK-01 | Implement and document the mask coordinate contract; migrate sidecars if needed | Adopt | P2 (before crop) | M | DEC-07 | Proposed | Not started | [DT §5](darktable-findings.md#5-modules-filters-and-masks) |
| MSK-02 | Match Lightroom's Intersect semantics | Adopt | P2 | S | DEC-08 | Proposed | Not started | [DT §2](darktable-findings.md#2-phase-1-issues-found-in-redlamp) |
| MSK-03 | Spatial local adjustments (Clarity, Texture, Dehaze, Sharpness, Noise inside masks) as cached detail bands scaled by mask coverage | Do better | P2 | L | ARC-01, TON-06 | Proposed | Not started | [DT §5](darktable-findings.md#5-modules-filters-and-masks) |
| MSK-04 | Detail refinement: keep only textured or flat areas of a mask | Adopt | P2 | S | — | Proposed | Not started | [DT §5](darktable-findings.md#5-modules-filters-and-masks) |
| MSK-05 | Luminance and Color Range masks as trapezoids in OKLCh | Adopt | P2 | M | — | Proposed | Not started | [DT §5](darktable-findings.md#5-modules-filters-and-masks) |
| MSK-06 | Reuse another mask's coverage as a component | Adopt | P2 | S | — | Proposed | Not started | [DT §5](darktable-findings.md#5-modules-filters-and-masks) |
| MSK-07 | Guided-filter edge refinement and a Refine Edge brush for brush and AI masks | Adopt | P2–P3 | 2–3 ew | DEC-05 | Proposed | Not started | [AI §5.5](ai-findings.md#55-edge-refinement-matting-and-mask-storage), [DT §5](darktable-findings.md#5-modules-filters-and-masks) |
| MSK-08 | Apple Vision masks: analysis render, Subject, Background, People, face-part heuristics, embedded auxiliary mattes and depth | Adopt | P2 | 6–7 ew | — | Proposed | Not started | [AI §5](ai-findings.md#5-c-masking-and-segmentation) |
| MSK-09 | AI mask storage: 8-bit PNG at 1536 px, provenance including OS build, never recompute silently, explicit "Update AI masks" | Adopt | P2 | S | DEC-11 | Proposed | Not started | [AI §5.5](ai-findings.md#55-edge-refinement-matting-and-mask-storage) |
| MSK-10 | SAM 2.1 object selection on the GPU (Apple Core ML packages), hover UX, embedding cache | Adopt | P3 | 4–6 ew | DEC-02, INF-03 | Proposed | Not started | [AI §5.2](ai-findings.md#52-objects-sam-21) |
| MSK-11 | Vision tap-to-segment on OS 27, and a bake-off against SAM 2.1 | Adopt | P3 | 1–2 ew | — | Proposed | Not started | [AI §5.2](ai-findings.md#52-objects-sam-21) |
| MSK-12 | Sky mask head on DINOv2 or SAM 2.1 features, trained on data we have rights to | Build | P3 | 6–8 ew | DEC-02, INF-01 | Proposed | Not started | [AI §5.3](ai-findings.md#53-sky-landscape-people-parts) |
| MSK-13 | Landscape classes and people-parts head | Build | P3–P4 | 12–20 ew | MSK-12 | Proposed | Not started | [AI §5.3](ai-findings.md#53-sky-landscape-people-parts) |
| MSK-14 | Depth Range mask from embedded depth; Depth Anything V2 Small only after the legal decision | Adopt, gated | P3 | 2–3 ew | DEC-02 | Proposed | Not started | [AI §5.4](ai-findings.md#54-depth) |
| MSK-15 | Learned matting refiner on our own studio hair and fur captures | Build | P4 | 8–12 ew | MSK-07 | Proposed | Not started | [AI §5.5](ai-findings.md#55-edge-refinement-matting-and-mask-storage) |

---

## 6. Edits, presets, interop and export

| ID | Item | Recommended | Phase | Size | Depends on | Decision | Status | Source |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| EDT-01 | Plan Phase 2's rendering changes as one process-version-2 release, with old pipelines kept via Metal function constants | Adopt | P2 | M | P1-01 | Proposed | Not started | [DT §6](darktable-findings.md#6-edits-presets-styles-and-versioning) |
| EDT-02 | Golden-image corpus per shipped process version, never regenerated | Adopt | P1–P2 | M | P1-01 | Proposed | Not started | [DT §6](darktable-findings.md#6-edits-presets-styles-and-versioning) |
| EDT-03 | Explicit "Update to current process" with before/after, using chained converters | Adopt | P2 | M | EDT-01 | Proposed | Not started | [DT §6](darktable-findings.md#6-edits-presets-styles-and-versioning) |
| EDT-04 | Versioned ids for built-in profiles (for example `redlamp.color.v1`) | Adopt | P1–P2 | S | — | Proposed | Not started | [DT §6](darktable-findings.md#6-edits-presets-styles-and-versioning) |
| EDT-05 | Store auto results (Auto WB, Auto Tone, raw defaults, AI masks) as resolved values | Adopt | P2 | S | — | Proposed | Not started | [DT §6](darktable-findings.md#6-edits-presets-styles-and-versioning) |
| EDT-06 | Per-camera raw-default rules (camera, lens, ISO, aperture, focal length, file type), applied once and written into the edit | Adopt | P2 | M | — | Proposed | Not started | [DT §6](darktable-findings.md#6-edits-presets-styles-and-versioning) |
| EDT-07 | Presets with an explicit settings list, "use this image's default" values and an Amount slider | Do better | P2 | M | — | Proposed | Not started | [DT §6](darktable-findings.md#6-edits-presets-styles-and-versioning) |
| EDT-08 | Copy/paste with safe default exclusions (orientation, lens, white balance) and a remembered category picker | Adopt | P2 | S | — | Proposed | Not started | [DT §6](darktable-findings.md#6-edits-presets-styles-and-versioning) |
| EDT-09 | Versions as named recipes inside one sidecar; persisted snapshots | Do better | P2 | M | P1-02 | Proposed | Not started | [DT §6](darktable-findings.md#6-edits-presets-styles-and-versioning) |
| EDT-10 | Publish the sidecar format as a documented schema | Adopt | P2 | S | P1-01 | Proposed | Not started | [DT §6](darktable-findings.md#6-edits-presets-styles-and-versioning) |
| EDT-11 | Lightroom XMP preset import: read `crs:ProcessVersion`, response curves fitted by rendering in both apps, a mapped/approximated/ignored report | Do better | P2 | L | EDT-07 | Proposed | Not started | [DT §6](darktable-findings.md#6-edits-presets-styles-and-versioning) |
| EDT-12 | Lightroom XMP sidecar import, converting once and never writing Lightroom's XMP | Do better | P4 | L | EDT-11 | Proposed | Not started | [DT §6](darktable-findings.md#6-edits-presets-styles-and-versioning) |
| EDT-13 | Export processes at full resolution and downscales last | Adopt | P2 | S | — | Proposed | Not started | [DT §6](darktable-findings.md#6-edits-presets-styles-and-versioning) |
| EDT-14 | Embed the edit recipe in exported files | Adopt | P4 | S | EDT-10 | Proposed | Not started | [DT §6](darktable-findings.md#6-edits-presets-styles-and-versioning) |

---

## 7. Lenses and geometry

| ID | Item | Recommended | Phase | Size | Depends on | Decision | Status | Source |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| LNS-01 | One lens-correction engine: every source baked into per-image 1-D tables (distortion per channel, vignetting, optical center, tangential terms) | Do better | P2 | L | — | Proposed | Not started | [DT §7](darktable-findings.md#7-lenses-and-geometry) |
| LNS-02 | Embedded manufacturer corrections (Sony, Fujifilm, OM System, Panasonic, DNG opcodes), moved from P3; validated against in-camera JPEGs | Adopt | P2 | M | LNS-01 | Proposed | Not started | [DT §7](darktable-findings.md#7-lenses-and-geometry) |
| LNS-03 | lensfun models reimplemented from their published math; database shipped as data | Adopt | P2 | M | LNS-01, DEC-04 | Proposed | Not started | [DT §7](darktable-findings.md#7-lenses-and-geometry) |
| LNS-04 | Import user-supplied Adobe LCP files with our own reader; never ship or convert Adobe's | Adopt | P2 | S | LNS-01 | Proposed | Not started | [DT §9](darktable-findings.md#9-licensing-of-reusable-pieces) |
| LNS-05 | All geometry (crop, Transform, orientation, lens) as one inverse map, sampling the pyramid once | Do better | P2 | L | LNS-01, MSK-01 | Proposed | Not started | [DT §7](darktable-findings.md#7-lenses-and-geometry) |
| LNS-06 | Crop and guides copied from Lightroom, parameters mapping to Lightroom's crop fields; post-crop vignette follows the crop | Adopt | P2 | M | LNS-05 | Proposed | Not started | [DT §7](darktable-findings.md#7-lenses-and-geometry) |
| LNS-07 | Our own line detector from the LSD paper | Build | P2 | M | DEC-05 | Proposed | Not started | [DT §7](darktable-findings.md#7-lenses-and-geometry) |
| LNS-08 | Upright as a virtual camera rotation (Level, Vertical, Full, Guided all in late P2, deterministic Auto), mapping to Lightroom's Transform sliders; optional 4-corner rectangle mode | Do better | P2 | L | LNS-05, LNS-07 | Proposed | Not started | [DT §7](darktable-findings.md#7-lenses-and-geometry) |
| LNS-09 | Chromatic aberration: profile and embedded TCA in the warp, automatic lateral CA, Lightroom-style Defringe | Adopt | P2 | M | LNS-01 | Proposed | Not started | [DT §7](darktable-findings.md#7-lenses-and-geometry) |
| LNS-10 | Guided automatic defringe | Adopt | P3 | M | LNS-09 | Proposed | Not started | [DT §7](darktable-findings.md#7-lenses-and-geometry) |

---

## 8. Architecture, testing, UX and extensibility

| ID | Item | Recommended | Phase | Size | Depends on | Decision | Status | Source |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| ARC-03 | CI gates: preview equals downscaled export, tiled equals untiled, viewport equals a crop of a full render, per-process-version stability; run on every pull request on Apple Silicon | Do better | P0–P2 | M | EDT-02 | Proposed | Not started | [DT §8](darktable-findings.md#8-architecture-performance-and-ux) |
| ARC-04 | Define every filter radius in full-resolution pixels | Adopt | P2 | S | — | Proposed | Not started | [DT §8](darktable-findings.md#8-architecture-performance-and-ux) |
| ARC-05 | Tiled rendering for large exports on iPhone and iPad, each stage declaring its overlap | Adopt | P2 | M | ARC-01 | Proposed | Not started | [DT §8](darktable-findings.md#8-architecture-performance-and-ux) |
| UX-01 | Typed values beyond the slider range, and arithmetic in value fields | Adopt | P2 | S | — | Proposed | Not started | [DT §8](darktable-findings.md#8-architecture-performance-and-ux) |
| UX-02 | Hover-scroll to adjust sliders, with Shift (coarse) and Option (fine) | Adopt | P2 | S | — | Proposed | Not started | [DT §8](darktable-findings.md#8-architecture-performance-and-ux) |
| UX-03 | ⌘F adjustment search with synonyms | Adopt | P2 | S | — | Proposed | Not started | [DT §8](darktable-findings.md#8-architecture-performance-and-ux) |
| UX-04 | Mark which panels contain edits | Adopt | P2 | S | — | Proposed | Not started | [DT §8](darktable-findings.md#8-architecture-performance-and-ux) |
| UX-05 | Color-assessment view and raw-channel clipping | Adopt | P2 | S | — | Proposed | Not started | [DT §8](darktable-findings.md#8-architecture-performance-and-ux) |
| UX-06 | Focus peaking | Adopt | P3 | S | — | Proposed | Not started | [DT §8](darktable-findings.md#8-architecture-performance-and-ux) |
| EXT-01 | Internal `redlamp mcp` command over the engine API, for slider-feel calibration and look matching | Adopt | P2 | S | — | Proposed | Not started | [DT §8.3](darktable-findings.md#83-extensibility) |
| EXT-02 | Public MCP server and App Intents / Shortcuts | Adopt | P4 | M | EXT-01 | Proposed | Not started | [DT §8.3](darktable-findings.md#83-extensibility) |

---

## 9. AI denoise and focus stacking (product priorities)

| ID | Item | Recommended | Phase | Size | Depends on | Decision | Status | Source |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| DN-01 | Noise profiles: DNG NoiseProfile tag, calibrated per-camera profiles, blind estimation; calibration tool and the first 10 bodies | Build | P2 | 5 ew | — | Proposed | Not started | [AI §2.2](ai-findings.md#22-noise-profiles-and-calibration), [DT §3](darktable-findings.md#3-cameras-and-raw-data) |
| DN-02 | Classical NR v1: luma pyramid shrinkage, luma-guided chroma, HQ non-local means pass, Lightroom Detail-panel mapping | Build | P2 | 8–11 ew | DN-01, DEC-05 | Proposed | Not started | [AI §2.1](ai-findings.md#21-classical-denoiser-nr-v1) |
| DN-03 | Sensor cleanup stage: hot pixels, banding, color bias | Build | P2 | 2 ew | DN-01 | Proposed | Not started | [AI §2.1](ai-findings.md#21-classical-denoiser-nr-v1) |
| DN-04 | Core ML timing on an A17 Pro iPhone for NAFNet raw variants and SAM 2.1 | Adopt | P2 | S | — | Proposed | Not started | [AI Appendix A](ai-findings.md#appendix-a-prototype-results) |
| DN-05 | Capture program: calibration frames, high-ISO series per vendor incl. X-Trans, clean base-ISO library, raw focus stacks | Build | P2 | 4–5 ew | DEC-12 | Proposed | Not started | [AI Appendix C](ai-findings.md#appendix-c-test-data) |
| DN-06 | Synthetic noise and training pipeline | Build | P3 | 3–4 ew | DN-01, DN-05 | Proposed | Not started | [AI §2.3](ai-findings.md#23-ai-denoise) |
| DN-07 | Train the NAFNet-style raw denoiser (Bayer raw-to-raw; X-Trans in linear RGB) | Build | P3 | 6–8 ew + US$5–20k | DN-06, DEC-03 | Proposed | Not started | [AI §2.3](ai-findings.md#23-ai-denoise) |
| DN-08 | AI denoise integration: cached non-destructive stage, tiling, loupe preview, Amount, DNG bake | Build | P3 | 4–5 ew | DN-07, INF-03 | Proposed | Not started | [AI §2.4](ai-findings.md#24-product-integration) |
| DN-09 | Denoise evaluation harness and blind study against Lightroom, DxO and Topaz | Build | P3 | 3 ew | INF-05 | Proposed | Not started | [AI §2.5](ai-findings.md#25-evaluation) |
| FS-01 | Stack detection: maker-note callback, vendor tag tables, heuristics, labelled fixtures | Build | P2–P3 | 2–3 ew | — | Proposed | Not started | [AI §3.2](ai-findings.md#32-stack-detection) |
| FS-02 | Focus stacking v1: GPU alignment, focus measure, depth solve, streaming Auto/Smooth/Detail fusion, artifacts | Build | P3 | 9–11 ew | CAM-05, LNS-01, DN-01 | Proposed | Not started | [AI §3.3](ai-findings.md#33-classical-pipeline-and-defaults) |
| FS-03 | Virtual raw result format and bake to linear DNG | Build | P3 | 2–3 ew | FS-02 | Proposed | Not started | [AI §3.5](ai-findings.md#35-placement-and-result-format) |
| FS-04 | Retouch brush and focus-stacking UX (banner, merge sheet, stack panel, depth overlay) | Build | P3 | 4–6 ew | FS-02 | Proposed | Not started | [AI §3.7](ai-findings.md#37-ux-outline) |
| FS-12 | Commercial comparison: run the test stacks through Helicon Focus (owner has a copy) and compare | Adopt | Now | S | DEC-13 | Proposed | Not started | [AI Appendix A.3](ai-findings.md#a3-classical-focus-stacking) |
| FS-14 | AI-assisted stacking: own dataset, boundary and halo refiner, noise-robust fusion, FOSSA depth prior spike, handheld sweeps | Build | P4 | 19–30 ew | FS-02, DEC-03 | Proposed | Not started | [AI §3.4](ai-findings.md#34-ai-assistance-phase-4) |

---

## 10. Other AI workstreams

| ID | Item | Recommended | Phase | Size | Depends on | Decision | Status | Source |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| RM-01 | Classical Heal and Clone (Poisson blending, exhaustive GPU source search, no PatchMatch) | Build | P3 | 5–7 ew | — | Proposed | Not started | [AI §6](ai-findings.md#6-d-object-removal-healing-and-distraction-removal) |
| RM-02 | Dust detection and removal, Visualize Spots | Build | P3 | 3–4 ew | — | Proposed | Not started | [AI §6](ai-findings.md#6-d-object-removal-healing-and-distraction-removal) |
| RM-03 | Content Credentials (C2PA) export and "Generated fill" badge | Adopt | P3 | 2–3 ew | — | Proposed | Not started | [AI §6](ai-findings.md#6-d-object-removal-healing-and-distraction-removal) |
| RM-04 | Inpainting data pipeline (PD12M, Megalith-10M) and mask generator | Build | P3 | 2–3 ew | — | Proposed | Not started | [AI §6](ai-findings.md#6-d-object-removal-healing-and-distraction-removal) |
| RM-05 | Train a LaMa-class inpainter; integrate crop-around-mask, caching and versioning | Build | P3→P4 | 9–12 ew + 1–3k GPU-hours | RM-04, DEC-06 | Proposed | Not started | [AI §6](ai-findings.md#6-d-object-removal-healing-and-distraction-removal) |
| RM-06 | iPhone inpainting student, Remove People, wire removal | Build | P4 | 10–14 ew | RM-05 | Proposed | Not started | [AI §6](ai-findings.md#6-d-object-removal-healing-and-distraction-removal) |
| SR-01 | Super Resolution 2x on Apple's VideoToolbox scaler, with a fidelity guard | Adopt | P4 (P3 stretch) | 3–4 ew | — | Proposed | Not started | [AI §4](ai-findings.md#4-b-super-resolution-and-upscaling) |
| SR-02 | 2x output on the AI denoise raw network | Build | P4 | 10–16 ew | DN-07 | Proposed | Not started | [AI §4](ai-findings.md#4-b-super-resolution-and-upscaling) |
| AUT-01 | Harden heuristic Auto and add a classical white-balance ensemble, evaluated on Cube++ | Build | P2–P3 | 4–5 ew | — | Proposed | Not started | [AI §7](ai-findings.md#7-e-auto-adjustments-and-personalization) |
| AUT-02 | Per-camera histogram auto white balance (after the patent check) | Build | P3 | 3–4 ew | DEC-05 | Proposed | Not started | [AI §7](ai-findings.md#7-e-auto-adjustments-and-personalization) |
| AUT-03 | Adaptive profile v1 as a cached parameter set with Amount 0–200 | Build | P3–P4 | 4–6 ew | TON-05, MSK-08 | Proposed | Not started | [AI §7](ai-findings.md#7-e-auto-adjustments-and-personalization) |
| AUT-04 | Expert-edited dataset, learned slider predictor, on-device personalization | Build | P3–P4 | 12–17 ew + US$15–40k | DEC-12 | Proposed | Not started | [AI §7](ai-findings.md#7-e-auto-adjustments-and-personalization) |
| OTH-01 | Face and eye detection for masks, healing, red-eye and pet eye | Adopt | P2–P3 | 2–3 ew | — | Proposed | Not started | [AI §8](ai-findings.md#8-f-other-opportunities) |
| OTH-02 | AI-assisted culling | Adopt | With the library track | 4–6 ew | — | Proposed | Not started | [AI §8](ai-findings.md#8-f-other-opportunities) |
| OTH-03 | Lens blur on depth | Adopt | P3–P4 | 6–10 ew | MSK-14 | Proposed | Not started | [AI §8](ai-findings.md#8-f-other-opportunities) |
| OTH-04 | HDR merge with deghosting and panorama, reusing focus-stacking alignment | Adopt | P3–P4 | 6–10 ew | FS-02 | Proposed | Not started | [AI §8](ai-findings.md#8-f-other-opportunities) |

---

## 11. AI infrastructure

| ID | Item | Recommended | Phase | Size | Depends on | Decision | Status | Source |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| INF-01 | Model manifest, registry, `ModelReference` in recipes, CI license gate (dataset license wins) | Build | P2 | 2–3 ew | P1-01 | Proposed | Not started | [AI §9.7](ai-findings.md#97-model-manifest-and-license-gate) |
| INF-02 | Conversion and compression pipeline with an `MLComputePlan` placement check in CI; compute units chosen per device class from measurements | Build | P2 | 2–3 ew | — | Proposed | Not started | [AI §9.1](ai-findings.md#91-runtime) |
| INF-03 | `TiledRunner` with the Core ML backend, P0–P3 lanes, thermal and Low Power budget | Build | P2–P3 | 6–9 ew | ARC-01 | Proposed | Not started | [AI §9.5](ai-findings.md#95-tiled-inference-and-scheduling) |
| INF-04 | Prototype Core ML and the Neural Engine inside a sandboxed XPC service, then `RedlampInference.xpc` | Build | P3 | 3–4 ew | — | Proposed | Not started | [AI §9.5](ai-findings.md#95-tiled-inference-and-scheduling) |
| INF-05 | Shared evaluation harness: metrics, golden sets, device benchmarks, pairwise study tooling | Build | P2 | 4–6 ew | — | Proposed | Not started | [AI §9.8](ai-findings.md#98-training-and-evaluation) |
| INF-06 | AI result cache, sidecar blob store, model-update UX | Build | P3 | 3–4 ew | DEC-11 | Proposed | Not started | [AI §9.3](ai-findings.md#93-determinism-versioning-and-caching) |
| INF-07 | Apple-hosted Background Assets delivery, one immutable pack per model version | Build | P3 | 2–3 ew | INF-01 | Proposed | Not started | [AI §9.4](ai-findings.md#94-model-delivery-verified) |
| INF-08 | Training infrastructure (data manifests, synthetic noise shared with DN-01, cloud runner) | Build | P2–P3 | 4–6 ew | DEC-12 | Proposed | Not started | [AI §9.8](ai-findings.md#98-training-and-evaluation) |

---

## 12. Recorded skips

Decisions not to do something, kept so they aren't reopened without new evidence.

| ID | Skip | Why | Source |
| --- | --- | --- | --- |
| SKIP-01 | User-reorderable processing modules | darktable's own manual recommends against changing the order | [DT §5](darktable-findings.md#5-modules-filters-and-masks) |
| SKIP-02 | Generic module instances and blend modes | Mask layers are Redlamp's instances | [DT §5](darktable-findings.md#5-modules-filters-and-masks) |
| SKIP-03 | Multiple tone mappers, a second white-balance step or a second denoiser as separate panels | darktable's most confusing designs | [DT §4](darktable-findings.md#4-color-science-and-tone) |
| SKIP-04 | Database-first edit storage | Causes darktable's sync crawler and conflict dialogs | [DT §6](darktable-findings.md#6-edits-presets-styles-and-versioning) |
| SKIP-05 | Binary parameter blobs in sidecars | Unreadable and unmergeable | [DT §6](darktable-findings.md#6-edits-presets-styles-and-versioning) |
| SKIP-06 | Chorded shortcuts, exposed performance and GPU tuning, separate CPU code paths | Complexity without user value on unified-memory Apple Silicon | [DT §8](darktable-findings.md#8-architecture-performance-and-ux) |
| SKIP-07 | Liquify, projection changes, lens "simulate" mode | Not in Lightroom; low value | [DT §7](darktable-findings.md#7-lenses-and-geometry) |
| SKIP-08 | rawspeed, the lensfun library, darktable data files, AMaZE and RCD | Licenses don't fit an MPL-2.0 App Store app | [DT §9](darktable-findings.md#9-licensing-of-reusable-pieces) |
| SKIP-09 | PatchMatch-based healing | Adobe patents active to about 2031 | [AI §6](ai-findings.md#6-d-object-removal-healing-and-distraction-removal) |
| SKIP-10 | Diffusion upscalers and generative fill | Hallucination risk; non-commercial or restrictive licenses | [AI §4](ai-findings.md#4-b-super-resolution-and-upscaling) |
| SKIP-11 | Sky replacement and relighting | Not in Lightroom; conflicts with truthful editing | [AI §8](ai-findings.md#8-f-other-opportunities) |
| SKIP-12 | Studying vkdt for now | Owner decision, 30 September 2026 | Conversation |
