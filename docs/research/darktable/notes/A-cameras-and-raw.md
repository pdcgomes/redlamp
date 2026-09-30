# A. Cameras and raw data

How darktable decodes raw files, adds and maintains camera support, prepares the sensor data, sets white
balance, chooses camera color matrices, demosaics, reconstructs highlights, cleans sensor defects and
noise, and (briefly) what its 5.8 AI features do. Written for Redlamp; see [_conventions.md](_conventions.md).

**Sources read:** darktable master 426d8ad (5.8.0 release notes), rawspeed c835b05, dtdocs master, the
darktable GitHub wiki (Camera-support page), the darktable-ai repository README and model cards
(fetched 2026-09-30), and Redlamp's own `RawDecoder.swift`, `RedlampColor`, `Demosaic.metal` and the
vendored LibRaw 0.22.2 headers. No darktable code is reproduced here; algorithms are described in prose.

---

## 1. Summary

| # | Lesson | Verdict | Phase |
| --- | --- | --- | --- |
| 1 | **Keep LibRaw; skip rawspeed.** darktable itself falls back to LibRaw for CR3, and rawspeed can't read ProRAW, JPEG XL DNG, Nikon HE, Fujifilm lossy or newer Sony compressed ARWs. As LGPL-2.1, rawspeed would also bring relinking duties an App Store binary can't meet cleanly. | Skip | — |
| 2 | **Build a per-camera decode regression suite on CC0 raw.pixls.us samples**, with golden metadata (CFA, black, white, crop, as-shot WB, matrix) per camera and mode. Adopt the policy "no sample, no support claim". | Adopt | P1 harness, P2 coverage |
| 3 | **Replace the per-image white-level heuristic** with a measured per-camera table plus clip-spike detection. rawspeed curates white levels below nominal (16300, not 16383, on the A7 III); a per-image heuristic mislabels unclipped highlights as clipped. | Do better | P2 |
| 4 | **Apply DNG GainMap (OpcodeList2) in the normalize kernel, on by default**, and OpcodeList3 in lens corrections. darktable does both, but its GainMap support covers only four full-frame RGGB maps. | Adopt, do better | P2 |
| 5 | **Keep Redlamp's camera-independent Temp/Tint.** darktable stores channel multipliers, its tint is a Y-scaling hack (its own comment says "baaad"), and settings don't transfer between cameras. Its "as shot to reference" idea (technical WB before demosaic, real WB after) is what Redlamp already does. | Do better | P1 done |
| 6 | **Dual-illuminant color is Redlamp's opening.** darktable has no DCP support. For DNGs it picks the single matrix nearest D65 ("FIXME interpolate") and ignores ForwardMatrix and HueSatMap. The planned DNG-spec interpolation and DCP import beat it outright. | Do better | P2 |
| 7 | **Demosaic from papers; drop AMaZE.** AMaZE and RCD exist only as GPL-3 code. Use LMMSE, Menon 2007 or adaptive residual interpolation; take Markesteijn from LibRaw's CDDL source. Adopt **dual demosaic** (blend a sharp and a smooth result by a local-contrast mask), with an automatic threshold. | Do better; skip AMaZE | P2 |
| 8 | **Highlight reconstruction on the CFA before demosaic.** darktable's default, "inpaint opposed", is cheap, GPU-friendly, and works on Bayer and X-Trans. Redlamp currently clips at 1 after WB, which is darktable's crudest mode. | Adopt | P2; segments P3 |
| 9 | **Noise profiles: build our own**, as ai-findings plans. darktable has 437 cameras in 1.8 MB (a and b per channel per ISO), interpolates linearly between ISOs, falls back to a weak generic profile, ignores the DNG NoiseProfile tag, and doesn't model banding or demosaic correlation. | Do better | P2 |
| 10 | **AI in 5.8:** ONNX Runtime with CoreML on macOS, on-demand model downloads, good model cards, and baked DNG or TIFF outputs. The raw-denoise weights are GPL-3.0, trained on ShareAlike data. Copy the model-card fields only. | Adopt the format, skip the models | P3 |

---

## 2. Detailed findings

### 2.1 Raw decoding: rawspeed and LibRaw in darktable today

**Evidence: dispatch.** `src/imageio/imageio.c` routes formats by magic bytes. Canon CR3 and Sigma X3F
go to LibRaw. CRW, CR2, IIQ, RAF, MRW, ORF and RW2 go to rawspeed. TIFF-based raws (NEF, ERF, PEF, SRW,
ARW, DNG) try the TIFF loader, then rawspeed. Unknown files fall through rawspeed, LibRaw, then
GraphicsMagick. A `libraw_extensions` config key can route more extensions to LibRaw
(`imageio_libraw.c`, which hard-codes "cr3 x3f").

darktable uses LibRaw for unpacking only, copying the same fields Redlamp's `RawDecoder.swift` does: raw
image, black and `cblack`, `linear_max` or `maximum`, `cam_mul`, `cam_xyz` and the margins. It also:
- keeps a 41-entry CR3 model map;
- warns "camera is not fully supported, colors could be misrepresented" for any CR3 not in that map;
- rejects results with `cam_mul[0] == 0`, "a bad method … but seems to be the best available".

`imageio_rawspeed.cc` loads `cameras.xml` once and decodes with `failOnUnknown = true`, so unknown cameras
are refused, not guessed. It copies black, per-CFA black, white, as-shot WB, the XML color matrix, crop,
CFA or X-Trans pattern, Fujifilm rotation and pixel aspect. It skips black-area sampling when per-channel
blacks exist, citing rawspeed issue 389. rawspeed has decoders for ARW, CR2, CRW, DCR, DCS, DNG, ERF, IIQ,
KDC, MEF, MOS, MRW, NEF, ORF, PEF, RAF, RW2, SRW, STI and 3FR, but **no CR3**.

**Evidence: gaps.** darktable 5.8's release notes list these compression modes as unsupported:
- ProRAW;
- CinemaDNG;
- DNG 1.7 with JPEG XL (Adobe enhanced, Samsung Expert RAW);
- Fujifilm lossy RAF;
- Nikon high-efficiency NEF;
- non-"L" Phase One IIQ;
- Sony downsized lossless ARW ("M" and "S");
- Sony ARW 6.0 compressed and compressed-HQ.

Nine cameras also had support "suspended because no samples are available on raw.pixls.us".

In Redlamp's vendored LibRaw 0.22.2:
- JPEG XL DNG hits a placeholder that throws "unsupported" ("real decoding implemented in DNG SDK",
  `src/decoders/dng.cpp`);
- Nikon HE and HE* are "not supported yet" (`cameralist.cpp`);
- there is a Sony YCC lossy decoder, and Fujifilm compressed decoding has lossy tables (full coverage
  unverified);
- ProRAW already works in Redlamp.

**Evidence: DNG, sRAW, monochrome, pixel shift.**
- rawspeed's `DngDecoder.cpp` accepts uncompressed, lossless JPEG, deflate (float DNG), VC-5 and lossy
  JPEG (34892), and it applies OpcodeList1.
- darktable parses OpcodeList2 **GainMap** (`src/common/dng_opcode.c`). It also parses OpcodeList3
  **WarpRectilinear** and **VignetteRadial**, which feed the lens module's "embedded metadata" method.
- Linear DNGs and Canon sRAW or mRAW (`sRaw1`/`sRaw2` modes, 19 cameras each) become 4-channel float with
  demosaic disabled. 1-channel data is flagged monochrome (Leica Monochrom, Pentax K-3 III Monochrome), and
  float DNGs are flagged HDR.
- There is **no pixel-shift or multi-shot handling** anywhere in darktable or rawspeed.

**Evidence: how support is added.** `rawspeed/data/README.md` defines one `<Camera>` per make, model and
**mode**. Common modes are `dng` (103), aspect-ratio crops, Nikon bit-depth and compression variants,
`sRaw1`/`sRaw2`, and `chdk`. Each entry holds:
- `ID`: the canonical name, equal to DNG `UniqueCameraModel`, "can be used to match the camera against DCP
  files";
- `CFA` or `CFA2`: the pattern, up to 6×6;
- `Crop`: a negative width or height trims from the right or bottom;
- `Sensor`: black and white, optionally per ISO range or list, first match wins;
- `BlackAreas`: masked strips whose per-channel median overrides black;
- `Aliases`;
- decoder `Hints`, such as `sraw_new`, `fuji_rotate` and `nikon_wb_adjustment`;
- `ColorMatrices`: D65 XYZ→camera × 10,000.

The format "is **not** stable" across rawspeed versions. The file is 716 KB with 1,391 entries (1,103 with
a matrix, 383 with aliases). Its support flags are `no` (49), `no-samples` (99) and `unknown-no-samples`
(80). A "sample beggary block" in `RawDecoder.cpp` asks for raw.pixls.us uploads, and darktable tags such
images `darktable|issue|no-samples`.

The wiki's Camera-support page sets the sample rules:
- well lit, detailed, low ISO, in focus, lens on;
- one shot per compression, bit-depth and crop mode;
- **CC0 only**;
- no people, no color targets, no Adobe-converted DNGs.

Contributors then open a GitHub issue. rawspeed's integration tests hash-check the CC0-only raw.pixls.us
"masterset" (`docs/ReferenceSampleArchive.rst`).

**Assessment.**
- The split is historical: rawspeed is fast and strict but trails new formats by years. Redlamp's
  LibRaw-only choice already reads more than darktable does.
- What's worth copying is the process:
  - a camera counts as supported only when a CC0 sample exists in a regression corpus;
  - every compression and crop mode is a separate test case;
  - untested cameras get a visible warning rather than silently wrong color.
- LibRaw 0.22.1 and 0.22.2 fixed a run of TALOS memory-safety bugs, and darktable decodes in-process with
  no sandbox. That confirms Redlamp's planned XPC decode helper on macOS; on iOS, fuzz our glue.

**rawspeed vs LibRaw for Redlamp.**

| | rawspeed | LibRaw 0.22 (Redlamp today) |
| --- | --- | --- |
| License | LGPL-2.1 only; `cameras.xml` CC BY-SA 3.0 | Dual LGPL-2.1 / **CDDL-1.0** (Redlamp uses CDDL) |
| CR3 | No | Yes |
| ProRAW | No (darktable 5.8) | Yes (tested in Redlamp) |
| JPEG XL DNG | No | No (placeholder; needs the Adobe DNG SDK) |
| Nikon HE | No | No |
| Camera data | External XML, version-locked | Compiled-in tables |
| Unknown cameras | Refused (`failOnUnknown`) | Best-effort |
| Extras | OpcodeList1, black areas | Makernote WB presets (`WB_Coeffs`, `WBCT_Coeffs`), DNG dual-illuminant fields (`dng_color[2]` with ColorMatrix, CameraCalibration and ForwardMatrix), raw opcode blobs |
| App Store | LGPL relinking burden (see section 4) | CDDL is file-level copyleft and compatible with an MPL app |

**Recommendation.** Neither library reads JPEG XL DNG. DNG 1.7 is a public specification and libjxl is
BSD-3-Clause, so a first-party tile reader for compression 52546 is a small, clean project. Pull it
forward from P4 to **P2**. Smartphone DNGs (Samsung Expert RAW, and reportedly newer iPhone ProRAW options;
verify) are where JPEG XL is showing up first.

### 2.2 Raw prepare: black and white levels, crop, flat field

**Evidence.** darktable's `rawprepare` module ("raw black/white point", `src/iop/rawprepare.c`) comes first
in the pipe and allows only one instance. Its parameters are four crop margins, four per-CFA-site black
levels, one white point, and a flat-field mode (off or "embedded GainMap"). It subtracts the per-site black
and divides by (white − black).

GainMap applies only when:
- there are exactly four maps, one per RGGB site;
- each map has pitch 2 and covers the full frame;
- all four maps share one grid.

Other layouts that are valid under the DNG spec are rejected. When the maps are present, correction
defaults to on "to avoid uneven color cast".

**What's cached.** The decoded, uncropped CFA buffer is held in the mipmap cache, and every module's output
is cached per pipe in hashed cache lines. The module order is:

rawprepare → invert → temperature → highlights → cacorrect → hotpixels → rawdenoise → demosaic →
demosaicscale → denoiseprofile → … → colorin (`iop_order.c`, v5.0 order)

5.8 split out a hidden `demosaicscale` module for cache efficiency. When zoomed out, demosaic runs a
half-size "clip and zoom" interpolation instead of the chosen algorithm (`_demosaic_full`). So the fit
view never shows the real demosaic, and any change upstream of demosaic, white balance included, re-runs
everything after it.

**Assessment.**
- Redlamp already carries a more general black pattern than darktable: global black, per-channel `cblack`,
  and LibRaw's spatial pattern.
- The weak spot is the **white level**. Redlamp lowers white to the image's data maximum whenever that
  maximum sits between 75% and 100% of nominal (LibRaw's `adjust_maximum`). On an unclipped bright frame,
  that marks real highlights as clipped.
- rawspeed instead curates measured per-camera white levels, for example 16300 rather than 16383 for the
  A7 III.
- Redlamp should **measure its own table from CC0 samples**, keyed by make, model, mode and ISO range. The
  heuristic should fire only on a histogram spike at the maximum.
- For **GainMap**, implement the general DNG form as a texture lookup in `rl_cfa_normalize`, on by default.
  The pyramid cache sits after this stage, so interactive cost is nil.

### 2.3 White balance

**Evidence: `temperature.c`.** The stored parameters are four channel multipliers plus a preset id;
temperature and tint are a UI view onto them. The manual warns that applying one camera's settings to
another "will, in general, not give consistent results".

The math:
- **Temperature to XYZ:** below 4000 K it integrates a blackbody spectrum against the CIE 1931 observer;
  above that it uses the CIE D-series daylight spectrum.
- **Tint:** divides Y by the tint value (code comment: "TODO: This is baaad!"). Tint is a factor clamped
  to 0.135–2.326, not a Duv offset.
- **Inverse:** bisects on Z/X and does not move orthogonally to the Planckian locus ("it lies!").
- **Range:** 1901–25000 K.
- **Multipliers:** 1 / (XYZ→camera matrix × illuminant XYZ), normalized to green.

The presets are:
- as shot;
- from image area;
- user modified;
- camera reference (D65 from the matrix);
- **as shot to reference** (the scene-referred default);
- camera-named presets from `wb_presets.json`, with a **finetune** slider across the camera's tuning
  steps.

"As shot to reference" applies the as-shot multipliers before demosaic, which helps highlight
reconstruction, CA correction, demosaic and denoise. `colorin` later swaps them for D65, and color
calibration does the real adaptation.

**Evidence: color calibration.** In the "modern" workflow (`color-calibration.md`):
1. white balance is set to camera reference;
2. the input profile applies the standard matrix;
3. `channelmixerrgb` adapts the as-shot or detected illuminant to D50 with **CAT16** by default (Bradford,
   XYZ and none are also offered).

Illuminants can be daylight, blackbody, fluorescent, LED, custom, or detected from surfaces or edges. The
module adds gamut compression and a ColorChecker fit with a ΔE report.

**Evidence: `wb_presets.json`.**
- 4.6 MB: 16 makers, 485 models, 20,284 rows, of which 16,218 are fine-tune steps.
- Each row holds the camera's own preset name, four multipliers and an optional `tuning` integer.
- It started as UFRaw's table (the loader's header: Udi Fuchs, GPL-2+). New data comes from users running
  `tools/extract_wb_from_images.sh` (exiftool over makernote WB tags); `extract_wb.py` normalizes names.
- **License: GPL.**

**Assessment.**
- Redlamp's model is already better on three counts: Robertson isotemperature lines with the matrix, tint
  perpendicular to the locus as in the DNG SDK, and Temp/Tint stored in the recipe. So recipes transfer
  between cameras, and the numbers land near Lightroom's.
- darktable's "as shot to reference" validates Redlamp's structure: a technical white balance before
  demosaic, and the user's white balance applied later as a ratio. This is why Redlamp never
  re-demosaics on a white balance drag.
- **Skip `wb_presets.json`.** Lightroom's presets are camera-independent Kelvin values. If camera-named
  presets are wanted later, LibRaw already parses each file's makernote tables into `WB_Coeffs[]` (by EXIF
  LightSource) and `WBCT_Coeffs[]`; coverage is unverified.
- **CAT-based adaptation** is darktable's better answer for odd light. In Redlamp it belongs as an advanced
  Calibration option (P3). The Lightroom-familiar default should follow the DNG spec: white balance in
  camera space, then an interpolated ForwardMatrix to D50.

### 2.4 Camera color matrices and input profiles

**Evidence.**
- **Where matrices come from.** There is **no `src/external/adobe_coeff.c`** in current master:
  - rawspeed files take the matrix from `cameras.xml` `<ColorMatrices>` (`imageio_rawspeed.cc`, "Grab the
    Adobe coeffs");
  - CR3 files use LibRaw's `cam_xyz`.

  Both descend from the D65 ColorMatrix2 values that Adobe DNG Converter writes, historically collected in
  dcraw's `adobe_coeff`.
- **darktable's own matrices.** `src/common/colormatrices.c` adds 93 "enhanced" matrices, 5 "vendor" and 4
  "alternate", all community-measured (ColorChecker, IT8 or CMP; strobe or daylight; mostly 2010–2014
  bodies). The enhanced matrices are the default input profile when present (`colorin.c`), described as
  "closer to that of the camera manufacturer".
- **DNG color.** `src/common/exif.cc` reads CalibrationIlluminant, ColorMatrix, CameraCalibration and
  ForwardMatrix 1–3, plus AnalogBalance. It then picks **one** illuminant, D65 or the nearest above it
  ("FIXME interpolate the matrixes"). It composes AnalogBalance × CameraCalibration × ColorMatrix and
  adapts the result to D65. When a ForwardMatrix exists or interpolation would be needed, it still uses
  that single ColorMatrix and just tags the image "no-samples". An "Other" illuminant is treated as D65.
  HueSatMap and LookTable appear only in the list of tags stripped on export.
- **DCP and ICC.** There is **no DCP reader** anywhere; the only "DCP" string is a JPEG 2000 cinema
  preset. ICC input profiles work, embedded or from `color/in`, with optional gamut clipping and an
  "unbreak input profile" helper module.

**Assessment.**
- Redlamp is at parity today: one Adobe-derived D65 matrix, or the DNG's own matrix with D65 preferred
  (`dngColorMatrix`). The P2 plan leapfrogs darktable:
  - interpolation between illuminants by inverse CCT;
  - ForwardMatrix to D50;
  - HueSatMap and LookTable;
  - DCP import.
- **DNGs:** LibRaw already exposes both illuminant sets (`dng_color[0..1]`: illuminant, colormatrix,
  calibration and forwardmatrix), so the data is in hand.
- **Native raws:** LibRaw has only the D65 matrix. A second illuminant must come from user DCPs, our own
  StdA and D65 chart captures (`redlamp-profiler`), or Adobe DNG Converter output; that last route is a
  legal question (section 5).
- Skip the dated GPL "enhanced" matrices.
- Adopt the "colors may be off" warning for cameras without a matrix, and a per-shot ColorChecker fit with
  a ΔE report (P3/P4). Lightroom has neither.

### 2.5 Demosaicing

**Evidence: methods (`src/iop/demosaic.c`, `src/iop/demosaicing/`).**
- **Bayer:** PPG, AMaZE, VNG4, RCD, LMMSE, and "dual" RCD or AMaZE (each blended with VNG4).
- **X-Trans:** VNG, Markesteijn 1-pass and 3-pass, frequency domain chroma (FDC), and Markesteijn 3-pass
  dual.
- **Special:** passthrough (monochrome), photosite color (debug), and "Monochrome" for true monochrome
  sensors.

Defaults are **RCD** for Bayer, **Markesteijn 1-pass** for X-Trans, VNG4 for 4-color CFAs, and
passthrough for monochrome.

Options: green equilibration, 0–5 color-smoothing median passes, a PPG median threshold, LMMSE refinement
steps, a dual threshold with a mask preview, and an FDC crossover ISO. 5.4 added **capture sharpening**
inside demosaic: iterative deconvolution with per-pixel Gaussian sigmas in 0–1.5, an auto-estimated radius,
and a noise-protecting contrast mask (`capture.c`, credited to Ingo Weyrich's RawTherapee algorithm).

Trade-offs, per the manual and tooltips:
- **Speed:** PPG and RCD are fast. AMaZE is "by far the slowest", and LMMSE, Markesteijn 3-pass and FDC
  are also slow.
- **Quality:**
  - AMaZE keeps the most detail but overshoots color;
  - LMMSE suits high ISO and moiré;
  - VNG4 is maze-stable but soft.
- **Dual modes** blend two demosaics using a blurred local-change mask with a manual threshold ("an
  automatically-calculated threshold is difficult to implement").
- **Preview pipes** skip dual demosaicing, capture sharpening, green equilibration and smoothing.

**Evidence: lineage, from the file headers.**

| Method | Origin | Paper? | Status for Redlamp |
| --- | --- | --- | --- |
| AMaZE | Emil Martinec 2008–10, optimized by Ingo Weyrich (RawTherapee), **GPL-3** | No | No specification to work from; **skip** |
| RCD | Luis Sanz Rodríguez, "Licensed under the GNU GPL version 3" (GitHub LuisSR/RCD-Demosaicing) | No | GPL-only; clean-room only from a written functional spec by someone who hasn't read the code |
| LMMSE | Ported from RawTherapee via librtprocess (GPL), refinement from Chang & Tan | **Yes:** Zhang & Wu, IEEE TIP 14, 2005 | Implement from the paper |
| VNG / VNG4 | dcraw 9.20 | **Yes:** Chang, Cheung & Pang 1999 | Implement from the paper |
| PPG | darktable (Chuan-kai Lin's pixel grouping) | Public web description | From the description |
| Markesteijn | dcraw 9.20 (Frank Markesteijn) | No | **LibRaw ships the same algorithm under CDDL** (`src/demosaic/xtrans_demosaic.cpp`, "LibRaw do not use RESTRICTED code from dcraw.c") |
| FDC | darktable, frequency-domain chroma for X-Trans | Attribution not in the header (unverified) | Build from the frequency-domain CFA literature (Condat, Hirakawa & Wolfe) |
| Capture sharpen | Ingo Weyrich (RawTherapee), GPL | Richardson–Lucy-style deconvolution is textbook | Implement from first principles |

**Assessment.**
- **Change the roadmap's "RCD and AMaZE"** to paper-based methods. Those two are the only candidates whose
  sole specification is GPL code, and the owner's decision to allow reading darktable weakens any
  clean-room claim for people who have read them. Candidates with good GPU fit:
  - Menon, Andriani & Calvagno 2007 (directional filtering with a posteriori decision);
  - Kiku et al.'s residual and adaptive residual interpolation (2013–2016);
  - LMMSE for high ISO.
- **For X-Trans,** port LibRaw's CDDL Markesteijn into a separate CDDL-labeled Metal file (confirm with
  counsel), or work from a written spec.
- **Adopt the dual-demosaic idea**, with the threshold set automatically from the noise model.
- **Keep Redlamp's advantage:** a full-resolution demosaic cached as a pyramid, so the fit view shows the
  real algorithm.
- Lightroom exposes no demosaic choice. Ship one default per CFA type, with learned "Raw Details" in P3 or
  later.

### 2.6 Highlight reconstruction

**Evidence (`src/iop/highlights.c`, `src/iop/hlreconstruct/`).** darktable offers six methods; **inpaint
opposed is the default**. The shared parameter is a clipping threshold (0–2, default 1.0), with a clipping
mask view and an optional raster mask. The module runs on CFA data after white balance and before demosaic.

| Method | How it works | Trade-off |
| --- | --- | --- |
| clip highlights | Clamps every channel to the white level | Safe for naturally neutral objects; loses data |
| reconstruct in LCh | Per 2×2 (Bayer) or 3×3 (X-Trans) block, rebuilds a clipped pixel in LCh from the block's other sites | Brighter and more detailed, but monochrome |
| reconstruct color | Magic Lantern (a1ex) color inpainting: interpolate by ratio to nearby unclipped pixels | Legacy |
| **inpaint opposed** (default) | A 3×3 "superpixel" estimates each channel; a clipped channel's reference is the **mean of the two opposing channels in cube-root space**. A global chroma correction is sampled from unclipped pixels morphologically adjacent to clipped regions | Fast, Bayer and X-Trans, OpenCL. Fails near differently colored neighbors, with a white balance far from D65, or with a wrong white point (the source's own list) |
| segmentation based | Flood-fills clipped segments per color plane and merges nearby ones ("combine", 0–8). Picks the best unclipped candidate per segment (weighted by 5×5 standard deviation and median), then inpaints pseudo-chroma (opponent-channel differences in cube-root space). Rebuilds regions where all channels are clipped from border gradients over a distance transform | Best on large or specular areas; slow, CPU-only, and the preview falls back to opposed. Came out of a pixls.us thread (Iain, garagecoder, Hanno Schwalm); no paper |
| guided laplacians | Multi-scale à trous diffusion copies Laplacians from valid channels into clipped ones (30 iterations, 128 px diameter by default; optional Poisson noise). Derived from diffuse or sharpen (Aurélien Pierre) | Smoothest and "immune to white balance discrepancies", but heavy and Bayer only |

filmic rgb and sigmoid add a later, color-aware reconstruction that can desaturate toward white. The manual
recommends guided laplacians capped at 512 px, then filmic for anything larger.

**Assessment.**
- The opposed idea is easy to state as math: in a cube-root domain, estimate a clipped channel from the
  mean of the other two, then add a chroma offset learned from the rim of the clipped region.
- In **P2**, implement it as a **CFA pre-pass before demosaic**, replacing today's clip at 1 after white
  balance. The cost is O(1) per pixel plus one dilation and one reduction, and it sits inside the cached
  stage.
- **Segment rebuilding** (P3) matches Lightroom's "pull Highlights down to reveal detail". It needs GPU
  connected components; share that work with the masking engine.
- Export the clipping mask for later stages, as darktable does with its raster mask. Denoise must
  zero-weight clipped samples (ai-findings §2.1), which only works with a correct white level.

### 2.7 Sensor defects, early noise, and profiled denoise

**Evidence: defect modules.** None of the three is enabled by default; highlight reconstruction is.
- **hot pixels** (`hotpixels.c`): a site is hot when 3 or 4 same-color neighbors (3 = "permissive") are
  below its value times a factor (threshold 0.05, strength 0.25). It is replaced by the neighbors' maximum,
  which "produces fewer artifacts".
- **raw denoise** (`rawdenoise.c`, dcraw lineage): per CFA plane, a square-root variance-stabilizing
  transform, then wavelet shrinkage with per-band curves, then squaring back.
- **raw chromatic aberrations** (`cacorrect.c`): Emil Martinec's RawTherapee algorithm, GPL, with Ingo
  Weyrich's 2018 iterations and "avoid colorshift". It estimates per-tile R and B shifts against G, fits a
  polynomial, and resamples before demosaic. It defaults to 2 iterations when enabled, is Bayer only, and
  conflicts with lens-profile TCA.

**Evidence: `denoiseprofile.c`.** The module runs after demosaic and before `colorin`, on camera RGB, "so
that the profile parameters are accurate". It offers non-local means and wavelets (default), each with an
"auto" variant, plus a hidden "compute variance" mode used for profiling.

- **Variance stabilization (v2):** each channel is first divided by its white-balance coefficient, because
  white balance scales each channel's variance. It is then mapped by
  T(x) = 2·(x + b)^(1 − p/2) / ((2 − p)·√a), a power-law generalization of Anscombe that assumes
  Var ∝ a·(x + b)^p. Here a and b are the profile values and p comes from the "preserve shadows" slider.
  The "bias correction" slider adds a term to the inverse transform to reduce back-transform bias.
- **Y0U0V0 mode** (the wavelet default): Y0 ∝ mean of R, G and B weighted by 1/WB, U0 ∝ (R − B)/2, and
  V0 ∝ (R − 2G + B)/4. Each row is normalized to unit noise variance, following Lebrun's thesis *From
  Theory to Practice, a Tour of Image Denoising* (§12.3.3). The UI offers one luma curve and one chroma
  curve over the wavelet bands.
- **Profile use:**
  - lookup is by EXIF make, model and ISO;
  - between ISOs, a and b are **linearly interpolated** (the code calls it "stupid linear interpolation");
  - "compensate highlight preservation" lowers the ISO for Canon HTP, ALO and dynamic-range modes;
  - unknown cameras get "generic poissonian" (a = 10⁻⁴, b = 0);
  - the **DNG NoiseProfile tag is never read**; `exif.cc` only strips it on export.

**Evidence: profile data.** `data/noiseprofiles.json` is 1.8 MB and GPL:
- 19 makers, **437 models**, 8,672 ISO entries (median 20 per model), about 4.2 KB per camera;
- each entry holds a name, an ISO, `a[3]`, `b[3]`, an optional `skip`, and a per-model contributor
  comment;
- coverage of current bodies is good: every recent Sony, Nikon Z and Fujifilm body we checked is present,
  but the EOS R5 Mark II is missing.

**Evidence: profiling tool** (`tools/noise/`):
1. The user shoots one **defocused** frame per ISO containing both blown and deep-shadow areas ("a sunny
   window … on half of the picture"). The script can shoot tethered via gphoto2 and checks the exposure
   spread.
2. `darktable-cli` exports each frame to PFM with a fixed style (white balance and input profile on;
   highlights, base curve and sharpening off) and denoiseprofile in variance mode.
3. `noiseprofile` bins per-channel mean against variance.
4. gnuplot fits a·x + b, weighted by bin counts, and writes PDF plots for human review.
5. The user submits the result in a GitHub issue.

**Assessment: where it falls short.** This adds to ai-findings §2.2.
- One frame from one unit measures temporal and fixed-pattern noise mixed together, after demosaic and
  white balance. Each profile therefore bakes in:
  - that demosaic's spatial correlation (the default moved from PPG to RCD, but old profiles remain);
  - that unit's fixed-pattern noise;
  - an unrecorded white balance.
- Nothing models banding, dual-gain breakpoints, read-noise shape or black-level bias.
- Linear interpolation in ISO is crude; log space would be better.
- The generic fallback is badly wrong for most sensors.
- **What to take:**
  - the tiny two-parameter per-channel profile as an interchange format;
  - the white-balance-adaptive variance-stabilizing transform and a Y0U0V0-style opponent space for NR v1;
  - the one-frame defocused capture as a **user self-profiling fallback**, next to Redlamp's lab protocol,
    the DNG tag and blind estimation.
- **Defects:** automatic hot-pixel removal in the cached cleanup stage, as Lightroom does silently (P2).
  Automatic CA correction should be built from papers (e.g. Kang 2007, "Automatic removal of chromatic
  aberration from a single image") and defer to lens-profile TCA when a profile exists.

### 2.8 AI features in 5.8 (brief)

**Evidence.**
- **Runtime:** ONNX Runtime, statically linked with the CoreML execution provider on macOS (Neural Engine
  and GPU), DirectML on Windows, CPU on Linux. `data/ort_gpu.json` describes optional GPU runtimes (CUDA
  12/13, MIGraphX, OpenVINO; ORT ≥ 1.18).
- **Models** (`data/ai_models.json`): SAM 2.1 small (default mask), SegNext (mask), NIND (RGB denoise),
  RawNIND (raw denoise) and RealPLKSR (upscale).
- **Delivery:** `.dtmodel` archives on darktable-ai GitHub releases, plus a `versions.json` for update
  checks. AI is opt-in, and nothing downloads automatically.
- **Model cards** record license, OSAID and MOF class, data license and provenance, training code and
  limitations. The stated licenses:

  | Model | Weights license | Training data |
  | --- | --- | --- |
  | RawNIND UtNet2 (Brummer & De Vleeschouwer 2025) | **GPL-3.0** | RawNIND |
  | NIND | **GPL-3.0** | NIND |
  | RealPLKSR | MIT | DF2K; the card notes Flickr2K has no license |
  | SegNext | MIT | COCO, LVIS, HQSeg-44K |
  | SAM 2.1 | Apache-2.0 | The card flags SA-1B as research-only |

- **Outputs** (neural restore):
  - Bayer raw denoise runs a joint denoise-and-demosaic model (packed 4-channel in, camera RGB at 2× out),
    then **re-mosaics** the result into a uint16 CFA DNG with a strength blend, so darktable's own demosaic
    still runs;
  - X-Trans is demosaiced first and denoised by a 3→3 linear Rec.2020 model into a LinearRaw DNG. The AI
    overview page says all raw output is LinearRaw, which contradicts the module page and the code;
  - RGB denoise and upscale write TIFFs.
- 5.8 also adds a `.dtdata` sidecar for per-pixel data such as raster masks.

**Assessment.** None of the denoise weights are usable: they are GPL-3.0 and the data is ShareAlike, as
ai-findings Appendix B already concludes. Reuse the model-card fields for Redlamp's manifest and license
gate (ai-findings §9.7). The re-mosaic trick suits a pipeline that can't add a stage; Redlamp's
non-destructive cached design is better.

---

## 3. Mapping: darktable → Lightroom → Redlamp

| darktable | Lightroom equivalent | Redlamp plan |
| --- | --- | --- |
| rawspeed + LibRaw (CR3, X3F) | Camera Raw's own decoder, DNG SDK | LibRaw (CDDL) only; add a first-party JPEG XL DNG reader (P2); XPC sandbox on macOS (P1) |
| `cameras.xml` support flags, "no-samples" tag and warning | Supported-camera list | CC0 sample corpus + golden-metadata tests (P1–P2); "untested camera" warning (P2) |
| raw black/white point (per-site black, white, crop) | Hidden | Hidden; measured per-camera white table + clip-spike detection (P2) |
| Flat field "embedded GainMap" | Applied silently | General DNG GainMap in normalize, on by default (P2) |
| white balance: as shot, spot, camera reference, as shot to reference, camera presets, finetune | Temp/Tint, As Shot / Auto / Kelvin presets, eyedropper | Done in P1 with camera-independent Temp/Tint; optional makernote presets via LibRaw (Later) |
| color calibration CAT (CAT16, Bradford), illuminant detection, ColorChecker fit | Calibration panel (primaries only) | DNG-spec WB + ForwardMatrix (P2); CAT option and ColorChecker fit (P3/P4) |
| input color profile: standard / enhanced / vendor / alternate matrices, embedded or user ICC | Profile Browser (DCP) | Adobe D65 matrix (P1); DCP dual/triple illuminant + ICC input (P2) |
| DNG dual illuminant: nearest to D65, no interpolation | Full DNG-spec interpolation | Full DNG-spec interpolation (P2) |
| demosaic: RCD default, AMaZE, LMMSE, VNG4, PPG, dual; Markesteijn 1/3, FDC | None exposed; Enhance: Raw Details | Paper-based Bayer demosaic + dual blend; Markesteijn from CDDL LibRaw (P2); learned demosaic (P3+) |
| capture sharpen (in demosaic) | Detail > Sharpening | Capture sharpening in P2, from first principles |
| highlight reconstruction: opposed (default), segmentation, laplacians, LCh, color, clip | Automatic | Opposed-style CFA pre-pass (P2); segment rebuild (P3) |
| hot pixels (off by default) | Automatic | Automatic in the sensor-cleanup stage (P2) |
| raw denoise (CFA wavelets) | None | Covered by NR v1 and AI raw denoise (ai-findings) |
| raw chromatic aberrations | Remove Chromatic Aberration | Lens-profile TCA + automatic CA from papers (P2) |
| denoise (profiled): wavelets / NLM, Y0U0V0, profiles for 437 cameras | Detail > Noise Reduction | NR v1 with own profiles, DNG NoiseProfile tag, blind estimation (P2) |
| neural restore raw denoise → DNG | Denoise → new DNG | Non-destructive AI denoise (P3) |
| neural restore upscale → TIFF | Super Resolution → new DNG | AI SR (P4) |
| AI object mask (SAM 2.1, SegNext) | Select Subject / Objects | Vision + SAM-class masks (P2/P3) |

---

## 4. Licensing notes

- **rawspeed (LGPL-2.1 only). Verdict: don't ship.**
  - §6 requires that users can relink against a modified library. That means shipping object files if we
    link statically, and App Store signing and FairPlay block swapping even a dynamic framework.
  - §10's "no further restrictions" also collides with the App Store usage rules.
  - Some App Store apps ship LGPL dylibs anyway, but it's a grey zone we don't need: LibRaw's CDDL option
    already covers more formats.
- **`cameras.xml` (CC BY-SA 3.0). Verdict: don't ship.**
  - ShareAlike would attach to our camera table.
  - CC 3.0 forbids distribution with "effective technological measures" and, unlike CC 4.0, has no
    parallel-distribution exception.
  - The facts it records can be re-measured from CC0 samples.
  - **The same concern applies to the README's plan to bundle the lensfun database** (listed as CC BY-SA
    3.0; verify). Consider downloading it at runtime, or get counsel.
- **`wb_presets.json` (GPL; UFRaw, GPL-2+). Verdict: can't ship, and not needed.** Use LibRaw's per-file
  makernote tables and Kelvin presets.
- **`noiseprofiles.json` (GPL). Verdict: can't ship.** Reimplement the format (a and b per channel per
  ISO) with our own measurements.
- **`colormatrices.c` (GPL). Verdict: skip.**
- **GPL-3 algorithms without papers** (AMaZE, RCD, cacorrect, capture sharpen, and the opposed and
  segmentation highlight methods): implement only from papers or a written functional spec.
  - **Flag for the findings:** the README's contributor rule ("if you have studied a GPL implementation …
    please don't write Redlamp's version") conflicts with the owner's 2026-09-30 decision to allow reading
    darktable. Settle the wording before Phase 2 algorithm work.
- **LibRaw (CDDL-1.0):** its dcraw-derived demosaics (Markesteijn, AHD, DCB, DHT, AAHD, VNG, PPG) are
  CDDL. A Metal port would be a CDDL-covered file inside an MPL-2.0 project; keep it separate, labeled, and
  cleared with counsel.
- **Adobe matrices:** Redlamp consumes LibRaw's, as darktable and rawspeed do. Extracting StdA matrices
  from DNG Converter output ourselves is common practice, but the terms are unverified.
- **raw.pixls.us:** CC0 except 146 files under CC BY-NC-SA; filter per file.
- **darktable-ai models:** nothing changes the verdicts in ai-findings Appendix B.

---

## 5. Open questions

1. Which JPEG XL DNG producers matter first (Adobe "enhanced" outputs, Samsung Expert RAW, iPhone ProRAW
   JXL options)? Collect samples and confirm the tile layout before sizing the P2 reader.
2. Does LibRaw 0.22 decode every Fujifilm lossy RAF and Sony ARW 6.0 "compressed HQ" variant? Test with
   raw.pixls.us samples, and record the result in the corpus.
3. How complete is LibRaw's `WB_Coeffs` / `WBCT_Coeffs` coverage per make? This decides whether
   camera-named presets are cheap.
4. Can Redlamp legally derive StdA ColorMatrix1 and ForwardMatrix values from Adobe DNG Converter output
   for native raws, or must dual-illuminant data come only from our own profiling and user DCPs?
5. Is a first-party Nikon HE decoder possible without a license for the codec, reportedly intoPIX's
   TicoRAW? Every open decoder currently lacks it.
6. Which demosaic default gives the best quality per millisecond on Apple GPUs: Menon 2007, adaptive
   residual interpolation, or LMMSE? Plan a Metal bake-off on the CC0 corpus, with the dual-blend mask
   driven by the noise model.
7. Should the per-camera white-level table ship in the app, or be generated at first decode from a
   clip-spike analysis and cached? A measured table needs samples at every ISO for dual-gain bodies.
8. Unverified: which demosaic the profiling style used for existing darktable noise profiles, and how much
   error that introduces when a different demosaic is used. This affects how Redlamp corrects its own
   profiles for demosaic correlation (ai-findings §2.1, step 1).
