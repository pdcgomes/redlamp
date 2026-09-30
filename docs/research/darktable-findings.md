# What Redlamp Can Learn from darktable

**Date:** 30 September 2026. **Subject:** darktable 5.8 (master of 29 September 2026), with rawspeed and lensfun.
**Detail:** six notes in [darktable/notes/](darktable/notes/), about 37,000 words with every source path and citation.

darktable is the most complete open-source raw developer: 74 current processing modules, a scene-referred pipeline, profiled denoise, lensfun corrections, drawn and parametric masks, styles, Lightroom import, an AI model pipeline and, as of 5.8, an MCP server. This study asked how it handles cameras, lenses, color science, modules, masks, presets, styles, profiles, sidecars, performance and UX, and what Redlamp should **adopt**, **do better** or **skip** as it packages the same capabilities in a native, Lightroom-familiar app.

## How this was done

- darktable, its user manual, rawspeed and lensfun were read from local clones, together with the papers their modules cite, discuss.pixls.us threads and the darktable blog. **The project owner decided on 30 September 2026 that reading darktable's source is allowed for understanding.** That conflicts with the clean-room wording in the README's Contributing section, which should be updated to match (see [section 10](#10-decisions-needed)).
- No darktable code, data file, preset or style was copied into Redlamp or into these notes. Algorithms are described in prose and short formulas, with file paths.
- Several findings are about **Redlamp's own code**. Those were checked against the source on 30 September 2026 and are marked as such.

## Contents

1. [Executive summary](#1-executive-summary)
2. [Phase 1 issues found in Redlamp](#2-phase-1-issues-found-in-redlamp)
3. [Cameras and raw data](#3-cameras-and-raw-data)
4. [Color science and tone](#4-color-science-and-tone)
5. [Modules, filters and masks](#5-modules-filters-and-masks)
6. [Edits, presets, styles and versioning](#6-edits-presets-styles-and-versioning)
7. [Lenses and geometry](#7-lenses-and-geometry)
8. [Architecture, performance and UX](#8-architecture-performance-and-ux)
9. [Licensing of reusable pieces](#9-licensing-of-reusable-pieces)
10. [Decisions needed](#10-decisions-needed)
11. [Roadmap changes](#11-roadmap-changes)

---

## 1. Executive summary

**darktable already solves most of the image-processing problems on Redlamp's roadmap. What it doesn't solve is the experience.** Its algorithms are good and often state of the art. Its pain points are structural: too many overlapping modules, concepts that leak into the UI (two-step white balance, a choice of four tone mappers, module order), an interactive pipeline that takes 0.1–0.6 s per slider change on a well-configured Apple Silicon Mac, and a macOS build that is unsigned, sRGB-only and not native. Those are exactly the areas where Redlamp's design (Lightroom's surface, one fused Metal kernel, native frameworks) already points the other way.

**The most useful lessons, in priority order:**

| # | Lesson | Verdict | Phase |
| --- | --- | --- | --- |
| 1 | **Add a rendering process version to every edit now.** darktable keeps five generations of tone mappers rendering old edits identically because every module versions its parameters and keeps old math selectable. Redlamp has only a file-format version, so Phase 2's pipeline changes would silently change every existing edit. | Adopt | **1** |
| 2 | **Replace the tone map before looks get locked in.** Redlamp's current curve clips at about +2.5 EV above middle grey and its output is limited to sRGB colors (section 2). darktable's defaults (sigmoid, AgX) never hard-clip and preserve hue. | Do better | **1** |
| 3 | **One asymptotic, hue-preserving display transform, hidden behind Lightroom's sliders.** Contrast is its slope, Whites and Blacks its endpoints, profiles its shape. Never offer a choice of tone mappers. | Adopt the idea, skip the choice | 1–2 |
| 4 | **Keep white balance as one Temp/Tint control**, with DNG-style dual-illuminant matrices. darktable's split of white balance into two modules is its most complained-about design, and its matrices aren't interpolated between illuminants. | Do better | 2 |
| 5 | **DCP support and a real display color space are open goals:** darktable has neither on macOS. | Do better | 1 (display), 2 (DCP) |
| 6 | **Edge-aware local tone from exposure-independent guided filters** (the tone equalizer's EIGF), as the shared base for Highlights, Shadows, Whites, Blacks, Clarity and Texture. | Adopt | 2 |
| 7 | **Stage graph with coarse, hash-chained caches and viewport-only rendering**, before any spatial adjustment lands. Keep the fused kernel for everything per-pixel. | Adopt, do better | 1–2 |
| 8 | **One lens-correction engine** fed by embedded vendor data, lensfun data, user-supplied LCPs, DNG opcodes and manual sliders, all baked into small per-image tables and applied in one geometry pass. Move embedded manufacturer corrections to Phase 2. | Adopt, do better | 2 |
| 9 | **Lightroom's mask UX with three darktable powers:** a Detail (texture) refinement, range masks as trapezoids, and reusing one mask's coverage in another. | Adopt | 2–3 |
| 10 | **Per-camera raw defaults as rules** (camera, lens, ISO, aperture, focal length, file type), applied once and written into the edit, plus presets with Amount and safe copy/paste defaults. | Adopt | 2 |
| 11 | **A Lightroom XMP importer calibrated by measurement**, not hand-typed tables. darktable maps about ten settings into deprecated modules; Redlamp's sliders already mirror Lightroom's, so most keys map one-to-one. | Do better | 2 (presets), 4 (sidecars) |
| 12 | **A small MCP server over the engine API**, like darktable 5.8's 21-tool `darktable-mcp`, first as an internal tool for slider-feel calibration and look matching. | Adopt | 2 internal, 4 public |

**Where Redlamp should not follow darktable:** user-reorderable modules, generic module instances, blend modes, four tone mappers, two white-balance steps, database-first storage, raw C-struct parameter blobs in sidecars, chorded keyboard shortcuts, exposed performance and OpenCL tuning, and liquify.

**What darktable has that Lightroom lacks, worth offering later:** a tone equalizer panel with on-image scroll (P3), frequency-separation retouching (P4), film negative inversion (P4 candidate), chart-based color calibration through `redlamp-profiler` (P3), focus peaking and a color-assessment view (P2–P3), a 4-corner rectangle mode for perspective (P2), and a lens deblur slider (Later).

---

## 2. Phase 1 issues found in Redlamp

These came out of comparing darktable's handling with Redlamp's current code. Each was checked against the source.

| Issue | Where | Why it matters | Fix |
| --- | --- | --- | --- |
| **Highlights clip at about +2.5 EV above middle grey** | `Develop.metal`: the filmic curve (Narkowicz fit) is normalized so scene value 1.0 maps to white, then the result is clamped | A raw's highlight headroom above +2.5 EV is thrown away at default Whites; darktable's sigmoid never clips and AgX reaches about +6.5 EV | A log-space asymptotic curve with an EV white point (section 4). Confirm first with an exposure-wedge render |
| **Output is limited to sRGB colors** | `Develop.metal`: the color work clamps to linear sRGB before the output encoding | Display P3 and extended outputs can't show wide-gamut color | Gamut-compress into the actual output gamut before the final clamp. Confirm with a P3 test pattern |
| **No rendering process version** | `EditRecipe` stores only `formatVersion` | Any change to rendering math silently changes old edits | Add `processVersion` (section 6) |
| **Unknown recipe keys are dropped on save** | `EditRecipe.init(from:)` keeps only known `ParameterID`s, so re-encoding loses the rest | Opening a sidecar in an older Redlamp and saving erases settings a newer version wrote | Preserve unknown keys and write them back; an older build opening a newer file should open it read-only |
| **`formatVersion` is written but never read** | `EditRecipe` decoding | No way to migrate or refuse newer formats | Read it; migrate older, refuse to overwrite newer |
| **`modified` is rewritten on every save** | `Library.swift` / `Sidecar.swift` | Unchanged edits still touch the file, which wakes iCloud sync | Skip the write when the encoded bytes are unchanged (as darktable does) |
| **The white level can drop to the image's own maximum** | `RawDecoder.swift` applies LibRaw's `adjust_maximum` heuristic: if the brightest pixel is between 75% and 100% of the nominal white level, that pixel becomes the white level | An unclipped but bright highlight is then treated as clipped; rawspeed instead curates per-camera white levels (for example 16300, not 16383, on the A7 III) | Per-camera measured white levels, plus clip detection that requires a spike of pixels at the maximum (P2) |
| **Mask Intersect multiplies coverages** | `evaluateMaskLayer` in `Develop.metal` | darktable takes the minimum; the product is softer where feathers overlap. Which one Lightroom uses is unknown | Measure against Lightroom and match it |
| **Mask coordinates need a contract before crop and lens land** | `Masks.swift` stores points in oriented image space and radii as fractions of oriented height | Once crop, Transform and lens correction exist, masks must stay on the same content | See section 5: keep today's space as the canonical "source" space and map it forward through every geometry change |

---

## 3. Cameras and raw data

Detail: [note A](darktable/notes/A-cameras-and-raw.md).

- **Decoding: keep LibRaw, skip rawspeed.** darktable itself falls back to LibRaw for CR3, and rawspeed can't read ProRAW, JPEG XL DNG, Nikon HE, Fujifilm lossy or newer Sony compressed ARWs. As LGPL-2.1, it would also bring relinking obligations a signed App Store binary can't meet cleanly.
- **Camera support is a process, not code.** rawspeed's `cameras.xml` records crop, black and white levels and sensor modes per camera, and the project refuses to claim support without a sample on raw.pixls.us. **Adopt the policy:** a per-camera decode regression suite on CC0 raw.pixls.us files, with golden metadata (CFA pattern, black, white, crop, as-shot WB, matrix), and a visible warning for untested cameras. P1 harness, P2 coverage.
- **White balance: Redlamp is already better.** darktable stores per-camera channel multipliers (from `wb_presets.json`, inherited from UFRaw), its tint is a green-channel scaling, and settings don't transfer between cameras. Redlamp's camera-independent Temp/Tint via Robertson's method is the right model. darktable's good idea, a technical "as shot to reference" balance before demosaicing, is what Redlamp already does.
- **Color matrices: dual-illuminant is the opening.** darktable has **no DCP support**, picks the single DNG matrix nearest D65 (a `FIXME interpolate` in `exif.cc`), and ignores ForwardMatrix and HueSatMap. Redlamp's planned DNG-spec interpolation plus DCP import beats it outright. P2.
- **Demosaic: drop AMaZE and RCD from the roadmap.** Both exist only as GPL-3 code with no published paper, so there is nothing to implement clean-room from. Use LMMSE, Menon 2007 or adaptive residual interpolation for Bayer, and Markesteijn for X-Trans from LibRaw's CDDL source (counsel to confirm). **Adopt darktable's dual demosaic:** blend a sharp and a smooth result by a local-contrast mask, with an automatic threshold. P2.
- **Highlight reconstruction on the CFA before demosaicing.** darktable's default, "inpaint opposed", estimates a clipped channel from the unclipped ones around it; it is cheap, GPU-friendly and works for Bayer and X-Trans. Redlamp currently clips, which is darktable's crudest mode. P2, with segmentation-based reconstruction of fully blown areas in P3.
- **Gain maps:** apply the DNG GainMap (OpcodeList2) by default in normalization; darktable only handles the simplest layout. P2.
- **Noise profiles:** darktable's cover 437 cameras in 1.8 MB, measured from one defocused frame per ISO, interpolated linearly between ISOs, with no banding model and no use of the DNG NoiseProfile tag. The plan in [ai-findings.md](ai-findings.md) section 2.2 already does better; darktable's one-frame capture is still a good idea for letting users profile their own camera.
- **JPEG XL DNG:** neither LibRaw 0.22 nor darktable 5.8 reads it. A reader built on libjxl (BSD) and the DNG spec is small; move it from P4 to P2.
- **AI in darktable 5.8:** ONNX Runtime (CoreML execution provider on macOS), on-demand model downloads, model cards, outputs baked to DNG or TIFF. The raw-denoise weights are GPL-3.0 and trained on ShareAlike data, so they're unusable; copy only the model-card fields into Redlamp's model manifest ([ai-findings.md](ai-findings.md) section 9.7).

---

## 4. Color science and tone

Detail: [note B](darktable/notes/B-color-science.md).

- **darktable's defaults:** a scene-referred pipeline in linear Rec.2020, **sigmoid as the default display transform since 5.2** (AgX added in 5.4, spektrafilm in 5.8, filmic still available), +0.7 EV exposure on new raws, and color calibration (CAT16) set to "as shot". Four competing tone mappers is the kind of choice Lightroom users should never see.
- **Recommended display transform for Redlamp (Phase 1):** one parametric curve in log2 space, asymptotic so it never hard-clips, with its white point expressed in EV and the display peak as a parameter (so Phase 4 HDR/EDR uses the same curve). Apply it per channel after insetting the primaries slightly toward white (as AgX and sigmoid do, to tame saturated highlights). Then restore hue by keeping the middle channel's relative position between min and max (sigmoid's trick). Finish with gamut compression at constant hue and lightness into the real output gamut. Users see only Lightroom's sliders: Contrast is the slope at middle grey, Whites and Blacks move the endpoints, profiles set the shape.
- **Saturation and grading: keep OKLCh.** darktable UCS 22 (used by color balance rgb) models Helmholtz–Kohlrausch brightness and is HDR-valid, but OKLab is cheaper and fine for Lightroom-style controls. **Do better:** make Saturation and Vibrance gamut-relative (scaled by the chroma headroom at that hue and lightness), and smooth the Color Mixer's hue-band weights spatially, as darktable's color equalizer does with a guided filter. P2.
- **White balance: don't copy the two-module split.** darktable separates a technical balance (white balance module) from perceptual adaptation (color calibration, CAT16 toward a D50 pipeline white). The result is years of "white balance applied twice" and "why does the CCT read differently in each module" threads. One Temp/Tint control following the DNG model, with a maskable CAT16 "illuminant" tool for mixed lighting as an optional P3 extra.
- **Local tone:** the tone equalizer and 5.8's "contrast and texture" both use an exposure-independent guided filter, whose edge threshold scales with the pixel value so shadows keep their edges as well as highlights. **Adopt** this as the base for Highlights, Shadows, Whites, Blacks, Clarity and Texture. P2.
- **Color management:** darktable's macOS display-profile code is compiled out, so Mac users see sRGB unless they pick a profile by hand, and there is no EDR. Redlamp should tag its Metal layer with an extended linear Display P3 color space and let ColorSync handle each screen (P1), use lcms2 for ICC input, output and soft proofing (P2), and implement DCPs natively: matrices, HueSatMap and LookTable as 3D textures, and the profile tone curve (P2). LUT import (`.cube`, `.3dl`, HaldCLUT) with log input spaces and an Amount slider, as planned (P2).
- **Look fitting for `redlamp-profiler`:** darktable's color calibration solves a weighted 3×3 matrix from a ColorChecker with a ΔE report, and the separate `darktable-chart` tool fits a raw-versus-camera-JPEG pair into a tone curve plus a sparse Lab LUT. **Adopt both ideas**, but fit in scene-referred space from charts and real scenes and write DCP and `.cube` outputs. P3, with the chart matrix possibly in P2.

---

## 5. Modules, filters and masks

Detail: [note C](darktable/notes/C-modules-and-masking.md), which maps every darktable module to its Lightroom equivalent and a Redlamp phase.

- **The catalog:** 97 registered modules, of which 74 are current, 6 internal and 17 deprecated. darktable's own scene-referred module-group preset curates about 45. **The deprecations tell the story:** display-referred Lab tools (zone system, fill light, Lab levels, vibrance) and overlapping modules (the old crop and rotate, basic adjustments, spot removal) failed. darktable replaced *basic adjustments* with a UI-only quick access panel, which is effectively a Lightroom Basic panel over the underlying modules. That validates Redlamp's design of panels as views over one parameter schema.
- **Detail tools:** darktable has five overlapping methods (sharpen, local contrast, contrast and texture, contrast equalizer, diffuse or sharpen) plus capture sharpening in demosaic. **Do better:** build Lightroom's Sharpening, Texture and Clarity controls on one multiscale decomposition (a fast local Laplacian or guided-filter pyramid), with deconvolution-style capture sharpening. Skip exposing diffuse-or-sharpen's PDE controls. P2.
- **Masking model:** in darktable every module can be a local adjustment, because any module's output is blended with its input through a per-pixel opacity. Lightroom and Redlamp instead scale adjustment values per pixel, which is much cheaper and fits the fused kernel. **Keep Lightroom's model and UX**, and add:
  - **Detail refinement** (P2): keep only textured or only flat areas of a mask, from an edge map computed once per image; the same idea as Lightroom's Sharpening Masking slider, for every mask.
  - **Range masks as trapezoids in OKLCh** (P2): Luminance Range as a trapezoid with smoothness, Color Range as soft falloffs around sampled colors.
  - **Reuse of another mask's coverage** as a component (P2): nearly free, since the kernel already evaluates every layer in order.
  - **Guided-filter edge refinement** for brush and AI masks (P3), cross-referenced with [ai-findings.md](ai-findings.md) section 5.5.
- **Spatial local adjustments:** Clarity, Texture, Dehaze, Sharpness and Noise inside masks should be computed once as detail bands and scaled by mask coverage in the fused kernel. That gives darktable's reach without re-running a spatial filter per mask. Plan it in P2.
- **Mask coordinates (reconciling notes C and E):** darktable stores shapes in input-image coordinates and pushes them forward through every distorting module, so masks stay on the content. **Recommendation:** keep Redlamp's current space (the image as oriented by its EXIF orientation, before crop, Transform and lens correction) as the canonical "source" space, which keeps existing sidecars valid. Treat a user's 90° rotation or flip as geometry applied after that space, like crop. Store gradient anchors in source space but construct the shape in corrected space, so an ellipse stays an ellipse on screen. Decide and document this before crop ships.
- **Retouching:** darktable's heal matches a source patch to the target's border by solving a Laplace equation on the difference image, the same classical approach planned in [ai-findings.md](ai-findings.md) section 6. Its wavelet-scale retouching (heal or blur on one frequency band) is non-destructive frequency separation, worth adding as a Healing option in P4.
- **Skip permanently:** module reordering (darktable's own manual says users should not change the order), generic module instances (mask layers are Redlamp's instances), blend modes, and darktable's four mask-combination modes (its manual tells novices to use two).

---

## 6. Edits, presets, styles and versioning

Detail: [note D](darktable/notes/D-presets-styles-sidecars.md).

- **How darktable keeps old edits stable:** every module versions its parameter struct, converts older layouts forward on load, and keeps old algorithms selectable through a version field in its parameters. Deprecated modules still render old edits. It works, but the parameters are raw C structs stored as hex or gzip+base64 in XMP, which can't be read, diffed or merged without darktable's GPL module code.
- **Recommended Redlamp strategy (Phase 1):**
  1. Two numbers: a **format version** for file syntax, migrated silently, and a **process version** for how edits render, never migrated silently.
  2. Defaults, ranges and which sliders exist are defined per process version, so a missing key means that process version's default.
  3. Old rendering stays available through Metal function constants, one pipeline variant per process version.
  4. Updating is an explicit "Update to current process" action with before/after, using chained converters (darktable's approach, but global rather than per module, like Lightroom's Process Version).
  5. Auto results (Auto WB, Auto Tone, raw defaults, AI masks) are stored as resolved values, never recomputed.
  6. A build that meets a newer file opens it read-only.
  7. CI keeps a golden-image corpus per shipped process version that is never regenerated.
  8. Plan all of Phase 2's pipeline changes (edge-aware Highlights and Shadows, new demosaics, dual-illuminant color, the new tone curve if it lands after Phase 1) as one process-version-2 release. Give built-in profiles versioned ids (for example `redlamp.color.v1`).
- **Storage: sidecar first.** darktable's SQLite library is authoritative and the XMP is a backup, which causes its startup crawler, "keep XMP or keep database" conflict dialogs and lack of multi-computer support. Redlamp's sidecar should stay the source of truth, with any future library as a cache. Keep named, sparse JSON values and publish the format as a documented schema.
- **Presets and raw defaults (P2):** darktable's auto-apply presets match maker, model, lens, ISO, shutter, aperture, focal length and file type, and are applied once on first open and written into the edit. That is the right model for Lightroom-style per-camera raw defaults. Presets should list the settings they include, support "use this image's default" values, and have an Amount slider.
- **Styles are Lightroom presets under another name:** multi-module bundles captured from a history, applied in append or overwrite mode, optionally to a new duplicate, with hover preview. Redlamp's presets already cover this with Lightroom naming.
- **Versions and snapshots:** darktable persists history but snapshots last only for the session, and duplicates are extra `name_NN.ext.xmp` files. Keep versions as named recipes inside one sidecar, persist snapshots, and store the current recipe rather than a replayable history.
- **Copy and paste:** darktable's plain copy leaves out image-specific settings such as orientation, lens correction and white balance. Adopt safe default exclusions and a remembered category picker. P2.
- **Lightroom import is the clearest "do better":** darktable maps about ten settings through hand-typed tables into mostly deprecated modules and ignores white balance, most Basic sliders, Color Grading, Detail, lens, masks and Adobe's process version; its manual says results "will never be identical". Redlamp's importer should read `crs:ProcessVersion` and choose mappings per Adobe process version, fit response curves by rendering the same photos in both apps, show a report of mapped, approximated and ignored settings, convert once, and never write Lightroom's own XMP. Adobe's process-version details still need verifying.
- **Export:** darktable's "high quality resampling" option exists because its default export downsamples early. Always process at full resolution and downscale last. Its option to embed the develop history in exported files is worth copying (P4).

---

## 7. Lenses and geometry

Detail: [note E](darktable/notes/E-lenses-and-geometry.md).

- **One lens-correction engine (P2).** darktable reduces every embedded vendor format to a per-channel radius multiplier plus a vignetting gain, both 1-D curves over normalized radius. Redlamp should bake every source (lensfun, user-supplied LCP, embedded vendor data, DNG opcodes, manual sliders) into small per-image tables of that kind, plus optical center and tangential terms (which darktable ignores for DNG), and sample them in the geometry pass.
- **Embedded manufacturer corrections move to Phase 2.** Sony, Fujifilm, OM System/Olympus, Panasonic and DNG parsers are each small, the data needs no lens identification, and it also covers third-party lenses that talk to the body. LibRaw's tag callbacks already expose the bytes, and Redlamp's own Sony A7 III fixture carries all three Sony tags. Validate the reverse-engineered formats against each camera's own corrected JPEGs.
- **lensfun:** reimplement its published distortion (poly3, poly5, PTLens), TCA and vignetting models ourselves; use its database as data (licensing in section 9). Coverage is thin for native Canon RF, Nikon Z and medium-format lenses, so Canon and Nikon users depend on lensfun most; whether their raws carry usable correction coefficients is an open question.
- **All geometry in one pass (P2).** darktable resamples once per distorting module. Redlamp should map each output pixel back through crop, Transform, user orientation and lens correction analytically, and sample the mip pyramid once, choosing the mip level from how much the map stretches that pixel. Geometry edits then never rebuild the pyramid.
- **Upright as a virtual camera rotation (P2).** Model the correction as H = K·R·K⁻¹ from the focal length and pitch, yaw and roll. Level, Vertical, Full and Guided come out in closed form from vanishing points, and the parameters map directly onto Lightroom's Manual Transform sliders. Make the robust fit deterministic, so pressing Auto twice gives the same result (darktable's changes on every click). A 4-corner rectangle mode goes beyond Lightroom. Write our own line detector from the LSD paper (darktable's embedded copy is AGPL-3). The inventory's split of Upright across Phases 2 and 3 doesn't hold, because Level and Vertical need the same line detection as Auto and Full; ship all modes together in late Phase 2.
- **Chromatic aberration (P2):** profile and embedded TCA inside the geometry warp; automatic lateral CA from estimated red and blue radial scale; Lightroom-style Defringe by hue range. A guided automatic defringe can follow in P3. Skip darktable's raw CA module (GPL, Bayer-only).
- **Crop and guides:** copy Lightroom, with parameters that map one-to-one onto Lightroom's `crs:` crop fields for the Phase 4 importer. The post-crop vignette must follow the crop. Skip liquify and projection changes.

---

## 8. Architecture, performance and UX

Detail: [note F](darktable/notes/F-architecture-performance-ux.md).

### 8.1 Architecture

- **Why darktable is slow:** every module reads and writes a full 4×float32 buffer, and a slider change re-runs everything from that module onward. Users report 0.1–0.6 s per exposure change on well-configured Apple Silicon Macs, up to 1.8 s misconfigured. On macOS it depends on Apple's deprecated OpenCL; it has no Metal code. Redlamp measures 0.6–3 ms at Fit.
- **Adopt viewport rendering before spatial stages land.** darktable renders the visible region at display scale plus a 20% margin, with a low-resolution whole image underneath while panning. Redlamp renders the full 26 MP frame at 1:1 (about 13 ms), which won't survive Clarity, noise reduction and sharpening. Put it in the Phase 1 render scheduler or early Phase 2.
- **Adopt coarse, hash-chained stage caches:** about five barrier stages (raw preparation, demosaic, geometry, spatial detail bands, then the fused per-pixel kernel), each keyed on a chained hash of upstream parameters as darktable does. Cached detail bands mean Clarity and Texture sliders, even inside masks, only re-run the fused kernel.
- **Preview must equal export, enforced in CI.** darktable's manual admits the darkroom can look over-sharpened compared with an export, because spatial filters run at display scale. Define every filter radius in full-resolution pixels and add CI gates: preview equals downscaled export, tiled equals untiled, viewport equals a crop of a full render, and per-process-version stability. Run them on every pull request on Apple Silicon (darktable's CI skips its own integration suite).
- **Skip** separate CPU and GPU code paths, device tuning and automatic tile optimization. Tile only for large exports on iPhone and iPad, with each stage declaring its overlap.

### 8.2 UX

**Do:**
- Allow typed values beyond the drawn slider range, and simple arithmetic in value fields.
- Adjust the hovered slider with scroll, Shift for coarse and Option for fine steps.
- Add a ⌘F adjustment search that matches synonyms ("clarity" finds local contrast).
- Mark which panels contain edits.
- Add a color-assessment view (grey surround, white frame) and raw-channel clipping (P2), and focus peaking (P3).

**Don't:**
- Offer a second tone mapper, a second white-balance step or a second denoiser as separate panels.
- Use multi-key shortcut chords or expose performance settings.
- Split the app into separate "lighttable" and "darkroom" worlds for editing tasks.

**Native advantages to make visible:** darktable's official macOS build is unsigned (Gatekeeper override needed), doesn't auto-update, and shows sRGB only because GTK on Quartz can't read the display's color space. Redlamp gets Display P3 and EDR, per-screen ColorSync, native gestures, notarization, the App Store, iCloud sidecars and a Photos editing extension.

### 8.3 Extensibility

- **MCP:** darktable 5.8 ships `darktable-mcp`, 21 tools that let an AI agent read module schemas, render a parameter stack, measure statistics and manage styles. Redlamp's value-type engine API, shared parameter schema and headless CLI make a `redlamp mcp` command about a week of work. Use it internally in P2 for slider-feel calibration and look matching; make it public in P4. End users get App Intents and Shortcuts; skip Lua and AppleScript.
- **Study vkdt next.** It is a GPU-only raw editor by darktable's original author, reporting about 19 ms raw-to-screen at full resolution, and it is **BSD-2-Clause** (verified from its repository), so its code can legally inform Redlamp's, subject to the usual attribution.

---

## 9. Licensing of reusable pieces

| Piece | License | Verdict for Redlamp |
| --- | --- | --- |
| darktable code, manual | GPL-3.0 | Read for understanding only (owner decision); never copy |
| darktable data: `noiseprofiles.json`, `wb_presets.json`, styles, presets | GPL-3.0 (`wb_presets` inherited from UFRaw) | Can't ship; not needed. Reuse format ideas only |
| darktable's line segment detector | AGPL-3.0 | Avoid; write our own from the LSD paper |
| darktable AI raw-denoise weights | GPL-3.0; ShareAlike training data | Unusable |
| rawspeed | LGPL-2.1 | Skip: relinking obligations don't fit a signed App Store binary, and LibRaw covers more formats |
| rawspeed `cameras.xml` | CC BY-SA 3.0 (verified in the file header) | Don't ship (ShareAlike plus the 3.0 anti-DRM clause); re-measure the facts from CC0 samples |
| lensfun library | LGPL-3.0 | Don't link (installation-information rule can't be met on iOS; pulls in GLib); reimplement the published models |
| lensfun database | CC BY-SA 3.0 (verified in lensfun's README) | Shippable as a separate, unmodified resource file with attribution, if counsel accepts the ShareAlike and anti-DRM terms for an App Store bundle. Any converted form stays BY-SA and should be published; keep Redlamp's own profiles in a separate file |
| Adobe LCP profiles | Adobe's terms | Import files the user already has; never ship, host or convert them into the shipped database. lensfun's converter is GPL-3, so write our own reader |
| AMaZE, RCD demosaics | GPL-3.0 code only, no paper | Drop from the roadmap; use paper-based methods |
| Markesteijn X-Trans demosaic | In LibRaw under its CDDL-1.0 option | Usable with counsel's sign-off |
| libjxl (for JPEG XL DNG) | BSD-3-Clause | Usable |
| lcms2 (ICC) | MIT | Usable (already planned) |
| vkdt | BSD-2-Clause | Code can inform Redlamp's, with attribution where adapted |

---

## 10. Decisions needed

1. **Update the README's clean-room policy.** It currently says not to port from darktable and that anyone who has studied a GPL implementation shouldn't write Redlamp's version. The owner's decision allows reading darktable's source for understanding. A clear replacement: "Reading GPL projects to understand behavior is allowed; copying or translating their code or data is not; implementations are written from papers, specifications and our own design."
2. **The lensfun database under CC BY-SA 3.0.** The same ShareAlike and anti-DRM question as in the AI research, now for data. If counsel says no, lens corrections rely on embedded vendor data (moving to Phase 2 anyway), user-supplied LCPs and our own measured profiles.
3. **The mask coordinate contract** in section 5, before crop ships.
4. **Intersect semantics** (product or minimum), decided by measuring Lightroom.
5. **Whether the tone-map replacement lands in Phase 1** (recommended), or ships as part of process version 2.

## 11. Roadmap changes

**Phase 1 (now):**
- Add `processVersion` to `EditRecipe`; move the inventory's "Process version selector" from Phase 2 to Phase 1.
- Fix the sidecar issues in section 2: preserve unknown keys, read `formatVersion`, skip unchanged writes, open newer files read-only.
- Replace the tone map with an asymptotic, hue-preserving curve and gamut-map into the real output gamut, before golden-image tests and presets lock in the current look.
- Tag the Metal canvas with a wide-gamut color space.
- Extend the render-scheduler item with a stage graph, per-stage caches and viewport-only rendering.
- Build the per-camera decode regression suite on raw.pixls.us CC0 samples.

**Phase 2:**
- Plan the pipeline changes as one process-version-2 release.
- Replace "RCD and AMaZE" with paper-based Bayer demosaics plus dual demosaic; Markesteijn for X-Trans.
- Add CFA-domain highlight reconstruction, measured per-camera white levels and GainMap support.
- Move embedded manufacturer lens corrections from Phase 3 to Phase 2, in one lens engine and one geometry pass.
- Ship all Upright modes together in late Phase 2, with our own line detector.
- Lock the mask and geometry coordinate contract before crop.
- Build local tone (Highlights, Shadows, Whites, Blacks, Clarity, Texture) on exposure-independent guided filters, and spatial local adjustments as cached detail bands scaled by mask coverage.
- Add Detail refinement, trapezoid range masks and mask reuse.
- Move JPEG XL DNG reading from Phase 4 to Phase 2.
- Add per-camera raw-default rules, presets with Amount, safe copy/paste defaults, and persisted snapshots and versions.
- Add the CI gates in section 8.1.
- Add an internal `redlamp mcp` tool.

**Phase 3:** tone equalizer panel with on-image scroll, guided edge refinement for masks, segmentation-based highlight reconstruction, `redlamp-profiler` chart and JPEG-look fitting writing DCP and `.cube`, optional maskable CAT16 illuminant tool, guided automatic defringe, focus peaking.

**Phase 4:** frequency-separation retouching, film negative inversion (candidate), a public MCP server and App Intents, embedded develop history in exports, and the measured Lightroom XMP sidecar importer.
