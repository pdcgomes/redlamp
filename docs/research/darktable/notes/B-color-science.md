# B. Color science and tone pipeline

How darktable turns camera RGB into a displayed image: pipeline order, working space, white balance
and chromatic adaptation, tone mappers (display transforms), saturation and grading spaces, local
tone tools, color management, LUTs and chart-fitted looks. It also covers what users struggle with,
and what this means for Redlamp's fused kernel.

Sources: darktable master of 2026-09-29 (426d8ad, 5.8 release notes), dtdocs master, the
discuss.pixls.us threads linked below, and the papers and articles cited in darktable's source.
Rules as in [_conventions.md](_conventions.md): the source was read for understanding only. Nothing
here is code; algorithms are described in prose and one-line formulas.

---

## 1. Summary

1. **The default look is now sigmoid, not filmic.** *Evidence:* `data/darktableconfig.xml.in` sets
   `plugins/darkroom/workflow` to `scene-referred (sigmoid)` (sigmoid became the default in 5.2;
   AgX was added in 5.4 and spektrafilm in 5.8). New raws also get exposure +0.7 EV, color
   calibration (CAT16, "as shot") and white balance "as shot to reference". The manual still tells
   users to pick filmic (`overview/workflow/process.md`). **Adopt** the idea of a single,
   parametric, asymptotic scene-to-display curve as the always-on "rendering" stage; **skip**
   offering four competing tone mappers. *Phase 1–2.*
2. **Redlamp's current tone map clips at about +2.5 EV above middle grey and drops wide gamut.**
   This is our reading of `Develop.metal`, confirmed by hand calculation rather than a test render.
   The Narkowicz curve is normalized so that scene value 1.0 maps to display white. At the default
   Whites setting, that is log2(1/0.18) ≈ 2.47 EV above grey, and everything brighter clips to
   white at the end of the kernel. Separately, the final clamp happens in linear sRGB before the
   conversion to Display P3 or extended output, so every output is limited to the sRGB gamut.
   **Do better:** replace the curve with a hue-preserving, asymptotic curve that has a white point
   in EV, and gamut-map to the actual output gamut. *Phase 1 (now), before presets and golden
   images lock the look in.*
3. **White balance in two modules is darktable's most confusing design.** The white balance module
   does a technical balance (as-shot, then reset to D65 inside the input profile), and color
   calibration performs the perceptual chromatic adaptation (CAT16) toward a D50 pipeline white.
   This has spawned years of "white balance applied twice" and "why does CCT read 4000 K"
   threads. **Do better:** one Temp/Tint control that follows the DNG model (interpolated matrices
   plus a forward matrix). Keep darktable's good trick of feeding as-shot-balanced data to the
   pre-demosaic stages; Redlamp already does this. Offer CAT16 only as an advanced, maskable
   "illuminant" tool. *Phase 2 (DCP), Phase 3 (advanced CAT).*
4. **Hue-preserving tone application is the key numerical idea.** Filmic v7 blends per-channel and
   max-RGB curves and then forces the original hue in Kirk/Filmlight Yrg. Sigmoid re-interpolates
   the middle channel so that its position between min and max is preserved. AgX lerps HSV hue back
   60 % toward the original. **Adopt** a middle-channel hue preservation (the same idea the DNG SDK
   uses for profile tone curves, unverified) plus AgX-style primaries "inset" to tame
   saturated highlights. *Phase 1–2.*
5. **Gamut mapping at constant hue and lightness, with soft clipping.** darktable compresses chroma
   toward white in u′v′ (color calibration), clips chroma to the output gamut at constant Y and hue
   (filmic), and soft-clips saturation against a per-hue gamut boundary table (color balance rgb).
   **Adopt** one gamut-compression step before the final clamp, done in OKLCh against the output
   gamut. *Phase 1–2.*
6. **Saturation model: darktable UCS 22 versus OKLCh.** darktable's grading space has a
   Helmholtz–Kohlrausch-aware brightness and is valid for HDR. OKLab is cheaper and good for
   display-referred work. **Keep OKLCh** for the Lightroom-style Color Mixer, Grading and Vibrance.
   **Do better** by making saturation gamut-relative (scaled by the maximum chroma at that hue and
   lightness) and by smoothing the hue-band weights spatially, as darktable's color equalizer does
   with a guided filter. *Phase 2.*
7. **Local tone uses exposure-independent guided filters.** The tone equalizer and the new 5.8
   "contrast and texture" module both use EIGF (a guided filter whose edge threshold scales with
   pixel value squared, so shadows keep edges as well as highlights). **Adopt** EIGF on a luminance
   mask as the shared base for Lightroom's Highlights, Shadows, Whites, Blacks, Clarity and Texture.
   *Phase 2.*
8. **darktable has no DCP support and no macOS display profile.** DNG matrices are not interpolated
   (a `FIXME` in `src/common/exif.cc`). There is no HueSatMap or LookTable. The ColorSync display
   profile code is compiled out (`#if 0` in `src/common/colorspaces.c`), so macOS users get sRGB
   unless they pick a profile by hand, and there is no EDR. **Do better** on both, which is already
   planned. *Phase 2 (DCP), Phase 1 (display: CAMetalLayer color space), Phase 4 (EDR).*
9. **Chart and JPEG look fitting exists in two tools.** Color calibration solves a 3×3 matrix from a
   ColorChecker or Spyder chart, in LMS space, with weighting strategies and a ΔE report. The
   separate `darktable-chart` tool fits a raw-vs-camera-JPEG pair into a tone curve plus a sparse
   thin-plate-spline Lab LUT, exported as a style. **Adopt** both ideas for `redlamp-profiler`, but
   fit in scene-referred space and write DCP (HueSatMap and LookTable) and `.cube`. *Phase 3, with
   the chart matrix possibly in Phase 2.*
10. **Roadmap change: add a rendering process version now.** darktable survives five tone mappers
    because every module is versioned and old edits keep old math. Redlamp's sidecar has only a
    `formatVersion`. **Adopt** a `processVersion` in `EditRecipe` before the tone-curve rework
    lands, as Lightroom does. *Phase 1.*

---

## 2. Detailed findings

### 2.1 Pipeline order, working space, workflows and defaults

**Evidence.** `src/common/iop_order.c` defines five built-in orders: legacy, v3.0 raw, v3.0 JPEG,
v5.0 raw, and v5.0 JPEG (`DT_IOP_ORDER_VERSION 5`). In the v3/v5 tables the list position defines
the order; the float values are only used for old database migration. v3.0 and v5.0 differ only
in where `finalscale` sits: in v5.0 it runs before `colorout`. The JPEG orders move every module
that needs linear camera data (denoise, lens, exposure, tone equalizer, crop…) after `colorin`,
because JPEG input is non-linear until the input profile linearizes it.

The v5.0 raw order, condensed to the color and tone relevant stages:

`rawprepare → temperature (WB) → highlights → demosaic → denoise → lens → exposure →
toneequal → crop → colorin → color calibration (channelmixerrgb) → … → colorchecker (LUT) →
sharpen/local-contrast → color balance rgb → saturation curve → rgb curve → rgb levels → base
curve | filmic | sigmoid | AgX | filmic rgb | spektrafilm → lut3d → legacy display-referred
modules (tone curve, levels, shadows/highlights, bilat local contrast, velvia, vibrance, color
zones) → vignette, grain → colorout`.

Notable placements:
- **Exposure and tone equalizer run in camera RGB, before `colorin`.** The tone equalizer's
  header says it works "in scene-linear camera RGB, to behave as if light was physically added or
  removed", so its luminance estimate uses RGB norms (Euclidean, power, geometric mean) rather than
  CIE Y (`src/iop/toneequal.c`).
- **The camera matrix is applied in `colorin`** (input color profile). Its default profile type is
  `DT_COLORSPACE_ENHANCED_MATRIX`: darktable's own per-camera matrices, falling back to the
  embedded ICC, then the DNG's D65 matrix, then the Adobe standard matrix. The default working
  profile is `DT_COLORSPACE_LIN_REC2020` (`src/iop/colorin.c`). The working space is linear
  Rec.2020 **with ICC-style D50 matrices**. Modules that need D65 (color balance rgb, filmic v6+)
  pre-multiply a CAT16 D50↔D65 matrix (`D65_adapt_iccprofile` in
  `src/common/darktable_ucs_22_helpers.h`).
- **The display transform happens in the tone mapper, near the end.** `lut3d` sits right after it
  in v5.0, so creative LUTs see display-referred [0,1] data. `colorout` then does only a profile
  conversion (matrix fast path, or LittleCMS2 when intents are needed).

**Workflow preference.** Options: `scene-referred (sigmoid)` (default), `(filmic)`, `(AgX)`,
`(spektrafilm)`, `display-referred (legacy)` and `none`. The chosen value controls which built-in
"scene-referred default" presets auto-apply (`init_presets` in each module; `dt_is_scene_referred`
in `src/common/utility.c`). The display-referred workflow auto-applies base curve and a plain
white balance. The older separate "chromatic adaptation: modern/legacy" preference that the manual
still documents no longer exists in `darktableconfig.xml.in`; it was folded into the workflow
choice.

**Defaults for a new raw (scene-referred):**
- White balance: preset "as shot to reference" (`DT_IOP_TEMP_D65_LATE` in `src/iop/temperature.c`).
- Exposure: +0.7 EV plus a tiny negative black level, with "compensate camera exposure" on; 0 EV
  for monochrome raws. The comment in `src/iop/exposure.c` explains that filmic "doesn't brighten
  as base curve does".
- Color calibration: CAT16, illuminant "as shot in camera", gamut compression 1.0, clip negatives
  on.
- Sigmoid: contrast 1.5, skew 0, per-channel, 100 % hue preservation, target black 0.0152 %,
  target white 100 %, no primaries adjustment.
- Filmic (if chosen): auto-tunes white and black relative exposure from exposure. Its parameter
  defaults are white +4 EV, black −8 EV, "power norm" chroma preservation, color science v7,
  hardness 4 (auto).

**Assessment.** The structure (unbounded linear data, a wide-gamut working space, one late display
transform) is what Redlamp already has. The D50-flavored working space is ICC baggage that leaks
into the UI: see §2.7 on CCT readouts. Redlamp's D65 Rec.2020 is cleaner; keep it. darktable
states it will not try to match camera JPEGs by default ("_We do not intend to change this_",
`process.md`). Redlamp's goal is the opposite (Lightroom familiarity), so its defaults should look
finished.

### 2.2 White balance: temperature module versus color calibration

**Evidence: the two steps.**
1. `temperature` multiplies raw channels before demosaic. In the scene-referred workflow it uses
   **as-shot** coefficients. `colorin` then multiplies by `D65coeffs / as_shot` before its matrix,
   so the data entering the matrix is balanced for the camera's "D65 reference" white
   (`late_correction` in `src/develop/develop.h`, applied in `src/iop/colorin.c`). The manual
   explains the reason: highlight reconstruction, raw chromatic aberration correction, demosaic and
   profiled denoise all work better on data that is roughly neutral for the actual scene. The
   older "camera reference" mode applied D65 coefficients up front, which is worse for those
   modules. Discussion:
   [dual white balance confusion](https://discuss.pixls.us/t/darktables-dual-white-balance-confusion/52773).
2. `channelmixerrgb` ("color calibration") takes pipeline RGB to XYZ, then to an LMS cone space
   (Bradford or CAT16), divides by the illuminant's LMS, multiplies by the D50 LMS white (a von
   Kries-type adaptation), then applies an optional 3×3 channel mix, gamut compression, per-channel
   saturation and lightness, or a grey mix for monochrome (`_loop_switch` in
   `src/iop/channelmixerrgb.c`). The math is in `src/common/chromatic_adaptation.h`:
   - CAT16 with full adaptation: LMS_out = LMS_in ⊙ (LMS_D50 / LMS_illuminant), with D forced to 1.
   - Non-linear Bradford adds an exponent to the blue channel, p = (B_illuminant / B_ref)^0.0834,
     and falls back to linear when blue goes negative.
   - XYZ scaling and bypass are also offered. The default is CAT16. The manual recommends it over
     linear Bradford because it produces fewer imaginary colors on saturated cyans and purples.
3. The illuminant can be set as: as-shot (derived from the EXIF multipliers and the camera matrix),
   CIE D series or Planckian with a temperature slider, F or LED standards, or custom (hue and
   chroma in Luv). A picker uses gray-world averaging over the selected area. The UI reports
   whether the CCT is valid, daylight or black body. The "AI" illuminant detection from surfaces or
   edges is **disabled in code**: `AI_ACTIVATED` is commented out as "not good enough".
4. **Gamut compression** works in CIE 1976 u′v′. With Δ = Y·|uv_white − uv|², the chromaticity
   moves toward white by Δ^γ·(uv_white − uv), where γ is the user's "gamut compression". The move
   is clamped so it never crosses the white point. The manual pitches it for blue LED scenes.
5. **Chart calibration** in the same module works like this:
   - The user fits a homography to a photographed ColorChecker (2000 or 2014) or SpyderCheckr (24,
     48 or Photo).
   - Patches are averaged. The grey patch gives the illuminant.
   - A 3×3 matrix is solved by weighted least squares in the adaptation LMS space. The weighting
     strategies are none, low or high saturation, skin, foliage, sky, average ΔE and max ΔE; the hue
     weights center on fixed hue angles.
   - It reports average and maximum ΔE before WB, after WB and after the matrix
     (`_extract_color_checker`).

**Pros of the split (assessment).**
- Adaptation happens in a cone space designed for it. For non-Planckian or LED light this beats a
  camera-RGB multiplier: whites become neutral and other colors are predicted better.
- It can be masked and multi-instanced for mixed lighting, which Lightroom cannot do beyond local
  Temp and Tint.
- Pre-demosaic stages still get near-neutral data.

**Cons.**
- Two places to "fix white balance", with a warning when both are changed.
- Two different CCT scales, because the pipeline white is D50.
- The as-shot path depends on the camera's coefficients and matrix being consistent. Sony and
  Olympus often report "invalid" CCT; see the
  [123-post thread](https://discuss.pixls.us/t/best-practice-for-unexpected-white-balance-coefficients-in-darktable/34758).
- The Temp/Tint mental model users bring from Lightroom does not map onto an "illuminant" picker.

**Redlamp today.** Redlamp balances the pyramid with as-shot multipliers, then applies a ratio to
the requested Temp/Tint multipliers in camera RGB, then one fixed camera→sRGB matrix, converted to
Rec.2020 (`ImageSession.swift`, `CameraColorModel.swift`, `Develop.metal`). This is darktable's
"as shot to reference" idea done right, in one visible control. What's missing is the DNG part:
- The camera→XYZ matrix should be interpolated between the two calibration illuminants by inverse
  CCT.
- ForwardMatrix should map white-balanced camera RGB to XYZ D50 with an implicit Bradford
  adaptation.
- The profile's HueSatMap should be applied as well.

With those in place, Temp/Tint is also a correct chromatic adaptation for near-Planckian light. All
of this is in the public DNG specification and already on the Phase 2 list.

### 2.3 Tone mapping and display transforms

**filmic rgb (color science v7, spline v3)** — `src/iop/filmicrgb.c`; background in
[Aurélien Pierre's filmic article](https://eng.aurelienpierre.com/2018/11/30/filmic-darktable-and-the-quest-of-the-hdr-tone-mapping/).
- Log encoding: x = clamp((log2(v/g) − b)/DR, 0, 1), where g is middle grey (18.45 %), b is black
  relative exposure (EV, negative), w is white relative exposure, and DR = w − b.
- The spline has five nodes: black, toe, grey, shoulder, white. The central segment is straight,
  with slope = contrast·DR/8, divided by hardness·grey_display^(hardness−1) so the contrast at grey
  stays constant when hardness changes. Grey maps to 0.1845^(1/hardness).
- "Latitude" (linear region) places the toe and shoulder a fraction of the way from grey toward
  the x values where the straight line would hit display black and white. "Balance" slides both
  along the line.
- Toe and shoulder are 4th-order polynomials ("hard"), 3rd-order ("soft") or rationals ("safe"),
  constrained for C¹ continuity and to hit the endpoints. The output is raised to the "hardness"
  power (default 4) to return to linear display values.
- v7 chroma handling: out = (½ − s)·per_channel + (½ + s)·maxRGB_ratio, where s is the "extreme
  luminance saturation" slider. The result then goes to Kirk/Filmlight Yrg (built on CIE 2006 LMS):
  hue is forced back to the input hue, chroma is capped at the input chroma, Y is clamped to
  display black and white, and chroma is clipped to the largest value that keeps every output-RGB
  channel in range at that Y and hue (`gamut_mapping`, `Ych_max_chroma` in
  `src/common/gamut_mapping.h`).
- Earlier versions offered norms for ratio-preserving mapping: max RGB, luminance Y, power norm
  (Σc³/Σc²), and Euclidean.
- A "reconstruct" tab inpaints clipped highlights with wavelets. It has bloom↔reconstruct,
  gray↔colorful and structure↔texture sliders, and adds noise in highlights.

**sigmoid** — `src/iop/sigmoid.c`.
- Generalized log-logistic curve:
  f(x) = W·((x + fog)^p / (E + (x + fog)^p))^q, with q = 5^(−skew).
- p, E and fog are solved so that f(0) = target black, f(0.1845) = 0.1845, f(∞) → target white,
  and the slope at grey depends only on "contrast".
- It is **asymptotic**: nothing ever clips. Target white above 100 % is allowed (up to 1600), so
  the curve is HDR-ready in principle.
- Negative inputs are desaturated toward the pixel mean until the minimum channel is 0, keeping the
  mean.
- Per-channel mode (default): curve each channel, then correct the middle channel so that
  (mid − min)/(max − min) matches the input. This is blended by "preserve hue" and constrained to
  keep the per-channel sum ("energy").
- RGB-ratio mode: curve the channel mean, scale RGB, then apply a hyperbolic chroma compression
  toward the display gamut border.
- "Primaries" (4.6+): before the curve, shrink ("inset") and rotate the primaries of a base space
  (working, Rec.2020, P3, Adobe RGB or sRGB). After the curve, optionally invert the inset
  ("recover purity"). Because per-channel curves desaturate bright colors, the inset controls how
  fast saturated highlights go to white and bends hues (for example a "favorable shift towards
  yellow"). This is based on Troy Sobotka's AgX.

**AgX** (5.4+) — `src/iop/agx.c`.
- Log2 encoding relative to 0.18 between −10 EV and +6.5 EV (default, scaled by "dynamic range
  scaling").
- Curve: a straight line through a pivot (default grey maps to 0.18 linear output) with a
  "contrast" slope. Toe and shoulder are scaled generalized sigmoids x/(1 + x^p)^(1/p), with
  convex/concave fallbacks when the endpoints can't be reached.
- An ASC-CDL-like "look" (slope, lift, power, saturation) follows. The result is linearized with
  gamma 2.2.
- Hue restore: the HSV hue is lerped 60 % back to the pre-curve hue.
- Primaries: inset and rotation matrices with an outset and un-rotation afterwards. The defaults
  reproduce Blender's AgX base matrices under D50 (EaryChow's AgX_LUT_Gen). Extra presets
  replicate sigmoid's "smooth" primaries.
- The UI has three tabs and about 30 parameters. Users describe AgX as sitting between filmic and
  sigmoid in complexity ([thread](https://discuss.pixls.us/t/filmic-vs-sigmoid-vs-agx-some-thoughts/54716)).

**base curve** — `src/iop/basecurve.c`. A per-maker or per-camera spline "reverse-engineered on
camera JPEG default look", with a "preserve colors" norm (luminance by default) and optional
exposure fusion. It is the display-referred workflow's view transform. Its per-camera presets are
GPL data.

**spektrafilm** (5.8) — `src/iop/spektrafilm.c`. A spectral simulation of film exposure,
development, printing and scanning. Film and paper data are CC BY-SA 4.0 and the code is GPLv3.
It is interesting as a look engine, but heavy and spatial (it includes halation and grain).

**Which is default:** sigmoid (§2.1). The discussion threads show no consensus winner:
[filmic vs sigmoid, 93 posts](https://discuss.pixls.us/t/filmic-vs-sigmoid-when-to-use-which/41507)
and the AgX thread above.

**Redlamp today.** Exposure and the tone sliders act in log2 around grey on a luminance ratio.
Then f(x) = x(2.51x + 0.03)/(x(2.43x + 0.59) + 0.14), Narkowicz's fit of the ACES RRT+ODT, is
applied **per channel in Rec.2020** and normalized by f(1). Consequences, from our reading of the
code:
- **Hard clip at scene 1.0** (≈ +2.47 EV over grey at default Whites). Filmic defaults to +4 EV,
  AgX to +6.5 EV, and sigmoid never clips.
- **Hue skews.** A per-channel curve in a wide space bends hues (orange toward yellow, blue toward
  purple) with no hue correction.
- **No gamut mapping.** The Rec.2020→sRGB matrix after the curve creates negatives, which OKLab
  work carries until a per-channel clamp. On top of that, the clamp happens in sRGB before the
  conversion to P3, so wide gamut is never shown or exported.
- **Fixed mid-grey mapping.** f(0.18)/f(1) ≈ 0.33 linear (about 61 % sRGB-encoded). That is fine
  as a house look, but it isn't a parameter.

**Lightroom (assessment; Adobe's process version internals aren't public).** The public part is
the DNG profile model:
- ColorMatrix and ForwardMatrix, dual-illuminant interpolated.
- HueSatMap and LookTable (3D hue/saturation/value tables).
- A ProfileToneCurve, where the default "ACR3" curve applies when the profile has none.
- BaselineExposure.

The DNG SDK's reference code applies RGB tone curves with a hue-preserving scheme: curve the
largest and smallest channels, then place the middle channel at the same relative position. This
is the same idea as sigmoid's 100 % hue preservation (unverified against the current SDK; check
`dng_reference.cpp`). Highlights, Shadows, Whites and Blacks are local, edge-aware operations whose
exact form is unpublished.

**Recommendation.** Make Redlamp's display transform a single parametric curve in log2 space:
- A log-logistic or AgX-style spline, asymptotic to display white, with the white point in EV,
  never a hard clip.
- Apply it per channel in a slightly inset "rendering space" derived from Rec.2020, then re-seat
  the middle channel for hue (a partial blend, so bright saturated colors still roll to white).
- Gamut-compress into the output gamut (sRGB, P3, or Rec.2020/EDR) at constant OKLCh hue and
  lightness, with a soft knee.
- Expose none of it directly. Contrast becomes the slope at grey. Whites and Blacks become the
  curve's white and black EV plus a local component. Profiles select the curve shape, like Adobe's
  profile tone curves. Display peak is a parameter from day one, so Phase 4 EDR is the same curve
  with target white above 1.

### 2.4 Color grading, saturation and local tone

**Color balance rgb** — `src/iop/colorbalancergb.c`; spaces in
[the darktable UCS 22 article](https://eng.aurelienpierre.com/2022/02/color-saturation-control-for-the-21th-century/).
The processing order per pixel:
1. Clip negatives. Go RGB → XYZ D50 → CAT16 → D65 → CIE 2006 LMS → Kirk/Filmlight Yrg → Ych.
2. Luminance masks are logistic functions of Y^0.41 centered on a grey fulcrum: shadows = 1/(1 +
   e^{k(x−g)/g}), highlights mirrored, midtones a Gaussian bump times both complements.
3. Hue shift is a 2D rotation. Chroma is scaled by 1 + chroma_global + Σ(mask·chroma_band) +
   vibrance, where vibrance = v·(1 − C^|v|), so low-chroma pixels get more. It is then clipped to
   stay inside the LMS cone.
4. **Four ways** act in Filmlight "grading RGB": offset (global, added), shadows lift and
   highlights gain (masked multiplies), midtones power around a white fulcrum. Then a Y power and a
   fulcrum contrast Y ← g·(Y/g)^c.
5. **Perceptual saturation and brilliance** in darktable UCS 22 (default since v5 of the module;
   JzAzBz is the legacy option). UCS 22 has:
   - lightness L* = 2.0989·Y^0.6317/(Y^0.6317 + 1.1243), which saturates smoothly for HDR;
   - chroma from hyperbolically compressed u′v′-like coordinates, C = 15.93·L*^0.652·(M²)^0.601/L_white;
   - brightness B = J·(C^1.3365 + 1), a Helmholtz–Kohlrausch term, and saturation S = C/B.

   Saturation moves at constant brightness and is soft-clipped against a per-hue gamut boundary
   table of the working space (`dt_UCS_22_build_gamut_LUT`). The soft clip is
   t + (1 − e^{−(x−t)/(h−t)})(h−t) above t = 0.8·boundary.

Presets ("basic colorfulness") add saturation in shadows and remove it in highlights. Users find
the module powerful but can't reproduce simple contrast, brightness and saturation behavior with it
([thread](https://discuss.pixls.us/t/cannot-get-color-balance-rgb-to-replicate-contrast-brightness-saturation/38730)).

**Other color modules.**
- **Color equalizer** (`colorequal.c`): eight hue bands (red, orange, yellow, green, cyan, blue,
  lavender, magenta) for hue, saturation and brightness in darktable UCS. It includes a
  **guided-filter smoothing of the hue-selection weights** and a saturation threshold, so noisy or
  low-chroma pixels don't flip between bands. This is darktable's Lightroom-HSL analog.
- **Color zones** is the older Lab, display-referred curve editor.
- **rgb curve** and **rgb levels** are display-referred, with "preserve colors" norms: luminance
  (default), max, average, sum, Euclidean, power.
- **Saturation curve** (5.8) and **color harmonizer** (5.6) are new scene-referred additions.
- **rgb primaries** (4.6) rotates and scales primaries for grading. This is the equivalent of
  Lightroom's Calibration panel.
- **velvia** and **vibrance** are legacy. Vibrance is deprecated in favor of color balance rgb's
  vibrance slider. **basic adjustments** is deprecated ("mixing view/model/control at once").

**Local tone (Lightroom Highlights, Shadows, Whites, Blacks, Clarity, Texture).**
- **Tone equalizer**: nine exposure bands from −8 to 0 EV. The per-pixel gain is a Gaussian radial
  basis interpolation of the band gains over log2 of a luminance mask. The mask is edge-aware,
  filtered by the guided filter or **EIGF** (default).
- **EIGF** (`src/common/eigf.h`) replaces the guided filter's variance term with variance/pixel²,
  making the result exposure-invariant, and drops the final averaging of the linear coefficients
  to avoid bright halos.
- The new **contrast and texture** module (5.8) does local contrast in log space on top of EIGF.
  The older **local contrast** module (`bilat.c`) is Lab and display-referred (local Laplacian or
  bilateral grid). **diffuse or sharpen** covers dehaze and sharpening presets.

**Redlamp comparison.** Redlamp's OKLCh is a sound choice for the Lightroom-style panels: cheap,
display-referred and hue-linear enough, and it sits after the tone map, where Lightroom users'
intuitions live. What to borrow:
1. Gamut-relative saturation. Scale saturation boosts by headroom to the output gamut boundary at
   that hue and lightness, via a 1D per-hue lookup of maximum chroma (like the UCS gamut table).
   This avoids posterized clipping on already vivid colors.
2. Spatially smoothed band weights for the Color Mixer. They can be computed at a coarse pyramid
   level and sampled in the fused kernel.
3. Vibrance as a chroma-dependent gain in the v·(1 − C^|v|) spirit, which Redlamp's
   `lowChroma` term already approximates.
4. For HDR in Phase 4, OKLab's cube root isn't designed for values far above 1. Either keep grading
   after the tone map (in display space with peak > 1), or evaluate a UCS-22-like lightness.

### 2.5 Input and output color management, LUTs and chart looks

**Input.**
- ICC input profiles are supported through LittleCMS2 (matrix fast path, LUT profiles via lcms),
  with "gamut clipping" to sRGB, Adobe RGB, Rec.709 or Rec.2020.
- A "blue mapping" hack handles saturated blue LEDs.
- Camera matrices come from darktable's "enhanced" data, the vendor or alternate matrices, the
  embedded DNG matrix, or Adobe's standard matrix.
- **DCP is not supported.** Nothing parses HueSatMap or LookTable, and among the DNG
  `ColorMatrix1/2/3` tags only the one closest to D65 is picked; see the "FIXME interpolate the
  matrixes" in `src/common/exif.cc`.
- There is an "unbreak input profile" module for log or gamma input.

**Output.**
- `colorout` supports ICC output with perceptual, relative, saturation and absolute intents. The
  intent only takes effect with LittleCMS2; the default internal matrix path is about ten times
  faster and effectively relative colorimetric with clipping (`special-topics/color-management/rendering-method.md`).
- Soft proofing and gamut check are darkroom toggles with their own profile and intent.
- Display profiles come from X atoms or colord on Linux. **On macOS the ColorSync code is inside
  `#if 0`** (`src/common/colorspaces.c`), so darktable assumes sRGB unless the user picks a display
  profile manually. No EDR/HDR display path exists.

**3D LUTs** (`src/iop/lut3d.c`).
- Formats: `.cube` (1D or 3D, size up to 256; `DOMAIN_MIN/MAX` other than 0 and 1 are
  **rejected**), `.3dl`, HaldCLUT `.png` (8 or 16 bit), and G'MIC `.gmz` compressed LUTs. `.gmz`
  needs the G'MIC library; its keypoints are stored inside the edit parameters so the look travels
  with the sidecar.
- Application spaces: sRGB, Adobe RGB, gamma Rec.709, linear Rec.709, linear Rec.2020, linear
  ProPhoto. There are no log spaces, so scene-linear LUTs are effectively unusable.
- Interpolation: tetrahedral (default), trilinear or pyramid.
- There is no Amount slider (blend opacity is the substitute), and it is placed after the tone
  mapper.

**Chart-fitted looks.**
- *color look up table* (`colorchecker.c`): a Lab, display-referred module holding up to 49
  source→target patch pairs, interpolated with a thin-plate spline, φ(r) = r²·ln r, plus a linear
  polynomial.
- `darktable-chart` (`src/chart/`, manual `special-topics/darktable-chart/`) takes a raw exported
  as Lab PFM (base curve off, standard matrix) and the camera JPEG, also as Lab PFM, of an IT8 or
  ColorChecker. It then:
  1. fits a tone curve on the grey ramp's L;
  2. greedily selects a sparse subset of patches (orthogonal-matching-pursuit style, SVD solves,
     error measured in ΔE2000) for the TPS;
  3. writes a `.dtstyle` with colorin set to the standard matrix, the tone curve, and the color
     look up table. It reports average and maximum ΔE.

  The manual pitches it for replicating film simulations.

**Assessment for Redlamp.**
- *DCP/ICC.* Implement the DNG profile model natively in Metal: interpolated matrices, HueSatMap
  and LookTable as 3D textures in HSV, and the profile tone curve applied with hue preservation.
  This goes beyond darktable and matches Lightroom. Use lcms2 (MIT) only for ICC input and output,
  soft proofing and non-matrix profiles, with a matrix fast path.
- *Display.* On macOS and iOS, don't read the display ICC. Tag the `CAMetalLayer` with an extended
  linear color space (Display P3 or extended sRGB) and let ColorSync composite. That gives correct
  wide-gamut and EDR display for free. Fix the sRGB clamp first (§2.3).
- *LUTs.* Support `.cube` 1D and 3D (including non-unit domains via a shaper), `.3dl` and
  HaldCLUT. Offer input spaces including log encodings (ACEScct, Apple Log for iPhone, LogC,
  S-Log3), so scene-referred LUTs work before the tone map. Put display LUTs after the tone map
  with an Amount slider. Use tetrahedral interpolation in-kernel from a 3D texture (33³ or 65³).
  Skip `.gmz`, which depends on G'MIC.
- *Looks.* `redlamp-profiler` should fit in **scene-referred** space: camera→XYZ, then a DCP-style
  HueSatMap/LookTable plus tone curve, from RAW+JPEG pairs of charts **and** real scenes (dense
  correspondences after alignment). Use TPS/RBF or regularized lattice regression. Report ΔE2000
  like darktable does, and write DCP and `.cube`. darktable's Lab, display-referred fit breaks for
  highlights and for any exposure change, because the LUT sits after a fixed tone curve.

### 2.6 Numerical details worth adopting

- **Keep light positive, but desaturate negatives rather than clipping them.** Sigmoid moves a
  pixel toward its channel mean until min = 0, keeping the mean (luminance-ish) and hue. Color
  calibration clips negatives in XYZ, LMS and RGB. Color balance rgb clips negatives on input.
  Redlamp's `max(…, 0)` after the camera matrix is a hard per-channel clip; replace it with the
  desaturate-toward-mean step.
- **Treat pixels with Y = 0 and non-zero chroma as invalid.** The manual calls them a symptom of bad
  black level or profile, and they produce NaN in xyY or u′v′. Guard divisions (darktable uses
  `NORM_MIN` and white-point fallbacks).
- **Clamp the norm before tone mapping when preserving ratios.** Filmic clamps the norm to the
  curve's input domain before computing ratios. Otherwise clipped raw areas turn into colorful
  patches darker than their surroundings (comment in `norm_tone_mapping_v4`).
- **Constant-hue, constant-luminance chroma clipping.** Filmic computes, per output channel, the
  chroma at which that channel hits 0 or display white, given Y and hue in Yrg, and takes the
  minimum. That is a closed form: three divisions, no search. The same approach works in OKLab with
  a per-hue cusp table.
- **Soft knee instead of hard clip** at 80 % of the boundary: exponential soft clip in color
  balance rgb, hyperbolic compression in sigmoid's RGB-ratio mode.
- **Hue preservation by re-seating the middle channel** (sigmoid, DNG-style), with a user or profile
  blend. Partial preservation keeps the natural "bright colors bleach to white" behavior.
- **Primaries inset before per-channel curves** (sigmoid, AgX). Contracting the primaries by about
  10–30 % toward white makes saturated highlights desaturate smoothly instead of skewing. A small
  rotation adds pleasing hue bends, for example fire going yellow. This is cheap: a 3×3 before and
  after.
- **Adapt in CAT16 and keep adaptation full (D = 1)** for photographic white balance.
- **Exposure-invariant edge-aware filtering (EIGF)** for all luminance masks.
- **Gamut compression in u′v′ weighted by Y** (color calibration). Dark saturated pixels move less,
  which suits LED and neon scenes. It could be an optional part of Redlamp's input stage.

### 2.7 What users struggle with, and what Redlamp should do differently

**Evidence (discuss.pixls.us):**
- *White balance twice and confusing CCT.*
  [white balance applied twice (29 posts)](https://discuss.pixls.us/t/white-balance-applied-twice/34949),
  [dual white balance confusion](https://discuss.pixls.us/t/darktables-dual-white-balance-confusion/52773),
  and
  [why is color calibration in the workflow (2026)](https://discuss.pixls.us/t/why-is-color-calibration-automatically-included-in-scene-referred-filmic-workflow/57236).
  In the last one, a maintainer explains that "6500 K is mapped to 5000 K" because the pipeline is
  D50, and the user reads the module's warning as "only use one".
- *Tone mapper choice and tuning.* One user describes filmic as a loop where "I would tweak
  something to fix a problem, which created another problem…"
  ([AgX thread, 139 posts](https://discuss.pixls.us/t/filmic-vs-sigmoid-vs-agx-some-thoughts/54716)).
  Another reply: "It's actually four, if you include the good old base curve."
- *Translating Lightroom habits*
  ([translate Lightroom instructions to darktable, 68 posts](https://discuss.pixls.us/t/translate-lightroom-instructions-to-darktable/34943),
  [for people switching from Lightroom](https://discuss.pixls.us/t/for-people-switching-from-lightroom-or-similar-software/44821)).
- *Camera coefficient problems* (Sony, Olympus) making the as-shot CAT "invalid".
- *Documentation lag.* The manual recommends filmic and a removed preference; the code defaults to
  sigmoid.
- Reddit was not surveyed for this note (unverified). The pixls threads are representative of the
  recurring themes.

**Assessment: what Redlamp should do.**
1. **One rendering, no module choice.** The scene-referred engine sits under Lightroom's sliders.
   The "profile" (Color, Vivid, Neutral…) picks the matrix or DCP, the tone-curve shape and a look
   LUT, as Adobe's profiles do. No user ever sees "sigmoid" or "filmic".
2. **One white balance.** Temp/Tint and the eyedropper follow the DNG model. Readouts are in the
   camera's native CCT, with no D50 remap. Advanced mixed-light correction is an optional
   "Illuminant" tool, masked and CAT16, in the Calibration panel or local adjustments. It is never
   a second mandatory stage.
3. **Defaults that look finished.** Pick a baseline exposure and tone curve that roughly match
   Lightroom's Adobe Color brightness. darktable adds +0.7 EV plus compensation for camera exposure
   bias; Redlamp already honors `BaselineExposure`, and should calibrate against Lightroom renders
   in the Phase 2 slider-feel work.
4. **Few, orthogonal controls; the math stays hidden.** Exposure is pre-curve. Contrast is the
   slope at grey. Whites and Blacks set the curve's white and black EV. Highlights and Shadows use
   an EIGF-masked tone equalizer with fixed band shapes. Clarity and Texture are EIGF-based local
   contrast at two scales, in log space. Saturation and Vibrance are gamut-relative in OKLCh.
5. **Version the math.** darktable can evolve because every module carries a version and
   `legacy_params` migrations. Redlamp needs a recipe `processVersion` so the tone-curve rework
   (Phase 1) and later refinements don't silently change old edits.

---

## 3. Mapping: darktable → Lightroom → Redlamp

| darktable | Lightroom | Redlamp plan |
| --- | --- | --- |
| workflow pref (sigmoid, filmic, AgX, spektrafilm, legacy) | Process Version + profile | One built-in curve family, chosen by Profile; `processVersion` in the recipe [P1] |
| white balance (as shot to reference) | Temp/Tint (as-shot applied in the raw pipeline) | Already done: as-shot pyramid plus ratio [P1] |
| color calibration CAT tab | Temp/Tint, local Temp/Tint | DNG interpolated matrices [P2]; optional CAT16 "Illuminant" tool, maskable [P3] |
| color calibration gamut compression | none visible | Optional input gamut compression (u′v′, Y-weighted) [P2] |
| color calibration chart profiling | DNG Profile Editor / ColorChecker Camera Calibration (external) | `redlamp-profiler` chart mode: 3×3 in LMS, weighted, ΔE report [P2–P3] |
| input color profile (matrix, ICC) | DCP profiles | Native DCP (matrices, HueSatMap, LookTable, tone curve) + ICC via lcms2 [P2] |
| exposure (+0.7 EV default) | Exposure + BaselineExposure | Exposure (log2), BaselineExposure [P1] |
| filmic, sigmoid, AgX, base curve | profile tone curve + Basic tone | Parametric asymptotic curve, hue-preserving, primaries inset, gamut-mapped [P1–P2] |
| filmic reconstruct / highlights module | Highlights recovery (automatic) | Pre-demosaic highlight reconstruction from papers [P2] |
| tone equalizer (EIGF) | Highlights, Shadows, Whites, Blacks | EIGF luminance mask + band gains [P2] |
| contrast and texture / local contrast | Clarity, Texture | EIGF multi-scale local contrast in log2 [P2] |
| diffuse or sharpen (dehaze), haze removal | Dehaze | Dark-channel style dehaze from papers [P2] |
| color balance rgb (4 ways, chroma, saturation, vibrance) | Color Grading, Vibrance, Saturation | OKLCh grading (exists) + gamut-relative saturation [P2] |
| color equalizer / color zones | Color Mixer (HSL) | OKLCh mixer (exists) + smoothed band weights [P2] |
| rgb primaries / sigmoid primaries | Calibration (primaries hue/sat) | Calibration panel as a 3×3 primaries rotate/scale in linear Rec.2020 [P2] |
| rgb curve / rgb levels | Tone Curve (point, RGB) | Point and RGB curves with hue-preserving application [P2] |
| lut3d (cube, 3dl, png, gmz) | Creative profiles (LUT inside profile) | `.cube`/`.3dl`/HaldCLUT, log input spaces, Amount [P2]; skip `.gmz` |
| color look up table + darktable-chart | Camera Matching profiles | `redlamp-profiler` look matching → DCP + `.cube` [P3] |
| output color profile + intents | Export color space | Export sRGB/P3/AdobeRGB/ProPhoto/Rec.2020/ICC; intents via lcms2 [P1 basic, P4 full] |
| soft proof, gamut check | Soft proofing | lcms2 soft proof + gamut overlay [P4] |
| display profile (none on macOS) | ColorSync | CAMetalLayer extended linear P3 [P1]; EDR [P4] |
| spektrafilm | none | Skip; maybe later a film look via our own fitted LUTs |

---

## 4. Licensing notes

- **All darktable code is GPL-3.0**, including the math helpers (`chromatic_adaptation.h`,
  `darktable_ucs_22_helpers.h`, `gamut_mapping.h`). Implement from the papers: CAT16 (Li et al.
  2017, CIECAM16), Bradford, Kirk/Filmlight Yrg, darktable UCS 22 (Aurélien Pierre's article),
  JzAzBz (Safdar et al. 2017), guided filter (He et al.), and thin-plate splines (Bookstein). Our
  own derivations are fine. Don't port.
- **GPL data we can't ship:** `src/common/colormatrices.c` ("enhanced" matrices), base-curve
  per-camera presets, `wb_presets.json`, and the chart reference values as darktable typed them.
  Chart reference values themselves are published by X-Rite and Datacolor; take them from the
  vendors or measure them.
- **Adobe matrices** reach Redlamp through LibRaw (CDDL option), which is already in use. DNG
  **specification** algorithms are public. The DNG SDK is under Adobe's permissive license; verify
  its terms before reading it closely.
- **AgX:** Troy Sobotka's AgX-S2O3 and EaryChow's AgX_LUT_Gen licenses are unverified. The math
  (log encoding, a sigmoid spline, inset matrices) is generic, so derive our own inset values.
- **spektrafilm:** code GPL-3.0; film and paper data CC BY-SA 4.0 (share-alike). Treat as not
  shippable inside an MPL App Store binary without a separate analysis.
- **lcms2** is MIT (planned). **G'MIC** (`.gmz`) is CeCILL, GPL-compatible; skip it.

---

## 5. Open questions

1. What middle-grey display value and highlight roll-off does Lightroom's Adobe Color actually
   produce? Measure it with rendered grey ramps and a ColorChecker across exposures (Phase 2
   slider-feel work). The answer sets our default curve.
2. Should saturation and vibrance stay post-tone-map in OKLCh, where Lightroom's feel suggests they
   live, or move pre-tone-map as in darktable? Proposal: stay post-map, add gamut-relative scaling,
   and A/B test on skies, skin and LEDs.
3. How much primaries inset and hue re-seating do we want by default? It trades purity for smooth
   highlight desaturation. Profiles could differ (Vivid versus Neutral).
4. Is the DNG SDK's hue-preserving RGB tone method still current, and does Lightroom use it for
   profile tone curves only or also for the Tone Curve panel? Verify from the spec and SDK.
5. For HDR in Phase 4: one curve with a display-peak parameter (sigmoid-style target white) or a
   separate HDR curve family? And does OKLab grading hold up above 1.0, or do we need a UCS-22-like
   lightness?
6. Should the Phase 2 DCP work include ProfileLookTable encodings (sRGB-gamma value axis) exactly,
   so third-party DCPs (dcamprof, Lumariver) render identically? Presumably yes. Needs test DCPs
   with a CC0 license.
7. Confirm the two findings in Redlamp's kernel (the +2.47 EV clip and the sRGB-limited P3 output)
   with a rendered EV wedge and a P3 test pattern before scheduling the fix.
