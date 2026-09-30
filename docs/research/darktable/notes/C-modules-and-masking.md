# C. Processing modules, filters, masking and blending

Study of darktable's module catalog, its detail and local-contrast filters, its mask and blend system,
retouching, and how it organises modules. Sources: `build/oss/darktable` (master 426d8ad, 2026-09-29,
5.8 release notes), `build/oss/dtdocs` (master), and papers cited in the code. Rules are in
[`_conventions.md`](_conventions.md). No darktable code is reproduced here. Algorithms are described
in prose and math, with file paths. Unverified items are marked **(unverified)**.

---

## 1. Summary

1. **darktable has 74 current processing modules, and most users need about 30 of them.** The build
   registers 97 modules (`src/iop/CMakeLists.txt`). Of these, 17 are deprecated and 6 are internal and
   hidden (display encoding, the two scaling steps, the mask manager, and the two clipping overlays).
   That leaves 73 modules the user can see, plus *rotate pixels*, which is hidden but applied
   automatically for a few cameras. darktable's own "workflow: scene-referred" module-group preset
   curates about 45 of them (`src/libs/modulegroups.c`). **Assessment:** Lightroom's roughly 12
   panels cover what matters for most photos. Redlamp should copy Lightroom's surface and only add
   the handful of darktable capabilities listed below. **Do better, P1–P4.**
2. **The deprecations tell a clear story: display-referred Lab tools and overlapping modules failed.**
   Most came in 3.4–3.6, with the move to linear, scene-referred RGB. Zone system, fill light,
   global tonemap and Durand tone mapping gave way to the *tone equalizer* or *filmic rgb*. Lab
   levels, vibrance and contrast/brightness/saturation got RGB replacements. The monolithic *crop
   and rotate* was split into three modules, and *basic adjustments* became a UI-only *quick access
   panel*. **Assessment:** this confirms Redlamp's scene-referred pipeline and its panels as views
   over one parameter schema. **Adopt (already the design).**
3. **Every darktable module can be a local adjustment, because blending is generic.** Any module
   that supports blending (71 module files, deprecated ones included) mixes its output with its input using a per-pixel opacity. That
   opacity comes from drawn shapes, parametric (color-range) masks, or a raster mask reused from
   another module. Lightroom and Redlamp instead *modulate parameters* per pixel. **Assessment:**
   keep Lightroom's model, but plan the engine so that spatial adjustments (Clarity, Texture, Dehaze,
   Sharpness, Noise) are computed once as detail bands and scaled by mask coverage. That gives
   darktable's reach without its cost. **Do better, P2.**
4. **Add darktable's mask refinements that Lightroom lacks, behind Lightroom's mask UX.** There are
   three worth taking:
   - A *details threshold* that keeps only textured (or only flat) areas. It uses a Scharr edge map
     computed at demosaic.
   - Guided-filter *edge feathering* that snaps a rough mask to image edges.
   - *Raster reuse*, meaning using another mask's coverage as a component.

   **Adopt: details and reuse in P2, edge refinement in P3.** Parametric trapezoids are the natural
   implementation of Lightroom's Luminance Range and Color Range. **Adopt, P2.**
5. **The tone equalizer is the best idea to borrow for tone.** It builds an edge-aware luminance
   mask with an exposure-independent guided filter, then applies an exposure curve over nine EV zones.
   You can also scroll directly on the image to brighten or darken the zone under the cursor.
   **Adopt** the engine for edge-aware Highlights, Shadows, Whites and Blacks in **P2**, and consider
   a "Tone Equalizer" panel beyond Lightroom, with on-image scroll, in **P3**.
6. **Detail tools: darktable has five overlapping methods; Lightroom has four Sharpening sliders
   plus Texture and Clarity.** The five are sharpen (USM), local contrast (local Laplacian or
   bilateral grid), contrast & texture (guided filter, new in 5.8), contrast equalizer (edge-aware
   à-trous wavelets) and diffuse or sharpen (a multiscale anisotropic PDE solver), plus capture
   sharpening inside demosaic. **Assessment:** build Lightroom's controls on one multiscale
   decomposition (fast local Laplacian or a guided-filter pyramid), with deconvolution-flavoured
   capture sharpening. Skip the PDE solver's controls. **Do better, P2.** A single "Lens Deblur"
   slider could come **Later**.
7. **Retouch module: heal is a Laplace solve, and wavelet-scale retouching is a real
   beyond-Lightroom feature.** Heal matches the source patch to its target border by solving
   ΔI = 0 on the difference image. Retouching on a chosen wavelet scale is frequency separation
   done non-destructively. **Adopt** heal and clone as planned (P3, see ai-findings §6), and add
   frequency-separation retouching as a Healing option in **P4**.
8. **Don't let users reorder modules or create generic instances.** darktable's manual itself
   says it is "highly recommended that users not change the order" and tells novices to stick to two
   of its four mask-combine modes. **Skip** reordering, generic instances and blend modes. Mask layers
   are Redlamp's instances. **Skip (permanent).**
9. **Decide mask coordinate space before crop and lens correction land.** darktable stores shapes in
   original-image coordinates and pushes them forward through every distorting module, so a shape
   stays on the same content. Redlamp's `ImagePoint` is in *oriented* coordinates, and its radii are
   fractions of the *oriented* height. **Do better, P2 (before Crop, Transform and Lens):** store
   mask geometry in unoriented, pre-geometry (sensor) space and map it forward on the GPU.
10. **darktable's AI object masks are SAM-based and vectorised into Bézier paths.** The result is
    cheap, editable and model-independent afterwards, but a smooth outline by construction can't
    hold fine hair or fur (assessment). **Do better, P2–P3:** keep AI masks as rasters in a
    companion sidecar, which is what darktable 5.8's new `.dtdata` sidecar does for raster masks.
    Offer "Convert to Path" as an option.

---

## 2. Detailed findings

### 2.1 The module catalog and its evolution

**Evidence.** `src/iop/CMakeLists.txt` registers 97 modules. `useless.c` is a commented-out example,
and `watermark` depends on librsvg. `IOP_FLAGS_DEPRECATED` is set in 17 files and `IOP_FLAGS_HIDDEN`
in 7 (`src/develop/imageop.h` defines the flags; the module files set them). The internal hidden
modules are:

- `gamma` (display encoding)
- `finalscale` and `demosaicscale` (scaling; the latter was split out of demosaic in 5.8 for cache
  efficiency, per the release notes)
- `mask_manager`
- `overexposed` and `rawoverexposed` (clipping overlays)

`rotatepixels` is also hidden, but it is a real correction that is applied automatically for sensors
with diagonal photosites. Deprecated modules follow a stated policy
(`dtdocs/content/darkroom/processing-modules/deprecated.md`). A deprecated module stops being
searchable, sits in a read-only group for about a year, and is then only loaded for old edits. It is
never deleted, so old edits keep rendering.

Every module declares a default group (`default_group()` returning `IOP_GROUP_*`: basic, tone,
color, correct, effect, plus a second axis of technical, grading and effects). The canonical pipeline
position of every module is a table in `src/common/iop_order.c` (`v50_order` for raw files,
`v50_jpg_order` for non-raw files, plus legacy orders). That table carries unusually frank comments.
*basic adjustments* is described as "mixing view/model/control at once, usage should be discouraged",
the Lab tone modules are marked "edit contrast while damaging colour", and *local contrast* sits late
"after all the bad things we have done to it with tonemapping".

**The 17 deprecated modules and why** (from `deprecated_msg()` in each file and the manual pages):

| Deprecated module (file) | Since | Replaced by | Why it failed |
| --- | --- | --- | --- |
| zone system (`zonesystem.c`) | 3.4 | tone equalizer | Lab, display-referred; zones without edge awareness |
| fill light (`relight.c`) | 3.4 | tone equalizer | Lab, halos |
| global tonemap (`globaltonemap.c`) | 3.4 | filmic rgb | HDR compression in Lab |
| tone mapping, Durand 2002 (`tonemap.cc`) | 3.4 | local contrast / tone equalizer | Bilateral HDR tone mapping, halos |
| channel mixer (`channelmixer.c`) | 3.4 | color calibration | Superseded by CAT and mixer in linear RGB |
| invert (`invert.c`) | 3.4 | negadoctor | Naïve inversion without a film model |
| spot removal (`spots.c`) | 3.6 | retouch (clone) | Clone only |
| defringe (`defringe.c`) | 3.6 | chromatic aberrations | Lab desaturation of fringes |
| basic adjustments (`basicadj.c`) | 3.6 | quick access panel (UI) | Duplicated other modules' maths in one module |
| vibrance (`vibrance.c`) | 3.6 | color balance rgb | Lab |
| crop and rotate (`clipping.c`) | 3.8 | crop + rotate & perspective + orientation | Monolithic geometry module |
| contrast brightness saturation (`colisa.c`) | 4.4 | color balance rgb | Display-referred, damaged color |
| levels (`levels.c`) | 4.4 | rgb levels | Lab |
| filmic v1 (`filmic.c`) | — | filmic rgb | Superseded by v2+ |
| old local contrast, CLAHE (`clahe.c`) | — | local contrast | Histogram equalization artifacts |
| legacy equalizer (`equalizer.c`) | — | contrast equalizer | Non-edge-aware wavelets |
| color transfer (`colortransfer.c`) | — | color mapping | Rewritten |

Five more Lab modules are not deprecated but carry "no longer recommended" notes because they blur in
Lab: *sharpen*, *bloom*, *lowpass*, *highpass*, and *shadows and highlights* (their manual pages).

**Assessment.**
- **Linear, scene-referred maths wins.** Nearly everything that failed did spatial filtering or tone
  work in a perceptual space. Redlamp's pipeline is already linear Rec.2020. Keep every spatial
  filter (Clarity, Texture, Dehaze, sharpening, noise reduction) in linear or log-luminance space,
  never in gamma-encoded space.
- **UI convenience modules that duplicate maths rot.** darktable rebuilt a Lightroom-like Basic panel
  as a UI-only widget collection. Redlamp's schema-first design, where a panel is a view and the
  parameters are the model, is the right answer, and it already exists.
- **Keeping old modules forever is darktable's backward-compatibility strategy.** Redlamp needs the
  same promise via a process version (inventory §11, P2). Old recipes render with the old kernel
  path, and new edits get the new one.

### 2.2 Current modules by function (74)

One line each. Module names are darktable's UI names, with the file in parentheses. The Lightroom
mapping and Redlamp verdict are in the table in section 3.

**Raw-level and sensor (10):**
- raw black/white point (`rawprepare`): black and white levels.
- white balance (`temperature`): channel coefficients and temperature/tint.
- highlight reconstruction (`highlights`): fills clipped channels. Modes include inpaint
  opposed, segmentation and guided Laplacians.
- raw chromatic aberrations (`cacorrect`): Bayer CA correction before demosaic.
- hot pixels (`hotpixels`): detects and fixes stuck pixels.
- raw denoise (`rawdenoise`): wavelet denoise on CFA data.
- demosaic (`demosaic`): PPG, AMaZE, RCD, LMMSE, VNG and Markesteijn, dual demosaic blended by a
  detail mask, and capture sharpening since 5.4.
- rotate pixels (`rotatepixels`) and scale pixels (`scalepixels`): fix diagonal or non-square
  photosites.
- external raster masks (`rasterfile`): imports a PFM mask. In 5.8 it is stored in the `.dtdata`
  sidecar.

**Color management and calibration (7):**
- input color profile (`colorin`) and output color profile (`colorout`).
- unbreak input profile (`profile_gamma`): undoes a baked curve.
- color calibration (`channelmixerrgb`): CAT white balance, channel mixer, grey and colorfulness
  controls, and color-checker chart fitting.
- rgb primaries (`primaries`): hue and purity of the R, G and B primaries, leaving greys untouched.
- color look up table (`colorchecker`): Lab patch-to-patch mapping interpolated with splines, fitted
  with the `darktable-chart` tool.
- LUT 3D (`lut3d`): `.cube`, `.3dl`, PNG HaldCLUT, and G'MIC compressed LUTs.

**Tone (13):**
- exposure (`exposure`).
- filmic rgb (`filmicrgb`), sigmoid (`sigmoid`) and AgX (`agx`): scene-to-display view transforms.
- spektrafilm (`spektrafilm`, new in 5.8): a spectral film-and-print simulation used as the view
  transform, with data packs downloaded separately.
- base curve (`basecurve`): camera-JPEG-like curve, with exposure fusion.
- tone equalizer (`toneequal`): zone-based dodge and burn with a guided mask.
- tone curve (`tonecurve`) and rgb curve (`rgbcurve`).
- rgb levels (`rgblevels`).
- local contrast (`bilat`).
- contrast & texture (`contrastntexture`, new in 5.8).
- shadows and highlights (`shadhi`, Lab).

**Color and grading (14):**
- color balance rgb (`colorbalancergb`): 4-way grading plus vibrance, chroma, saturation and
  brilliance.
- color balance (`colorbalance`): ASC CDL-style lift, gamma and gain.
- color equalizer (`colorequal`): HSL by hue with guided-filter smoothing.
- color zones (`colorzones`): Lab/LCh curves of L, C and h against L, C or h.
- color harmonizer (`colorharmonizer`): pulls hues toward a harmony palette.
- saturation curve (`satcurvergb`, new in 5.8): saturation and brilliance as a function of
  saturation.
- color contrast (`colorcontrast`): Lab a/b contrast.
- color correction (`colorcorrection`): a/b split-tone.
- velvia (`velvia`).
- monochrome (`monochrome`): B&W through a variable color filter.
- colorize (`colorize`).
- split-toning (`splittoning`).
- color mapping (`colormapping`): Reinhard-style color transfer from a reference image.
- color reconstruction (`colorreconstruct`): fills color into blown areas.

**Correction, detail and denoise (13):**
- denoise (profiled) (`denoiseprofile`): per-camera, per-ISO profiled NLM or wavelets after variance
  stabilization.
- astrophoto denoise (`nlmeans`): non-local means.
- surface blur (`bilateral`): permutohedral bilateral filter.
- sharpen (`sharpen`): USM on Lab L.
- contrast equalizer (`atrous`): edge-aware à-trous wavelet equalizer for luma and chroma.
- diffuse or sharpen (`diffuse`): anisotropic multiscale PDE.
- haze removal (`hazeremoval`): dark channel prior.
- lens correction (`lens`): lensfun or embedded-metadata distortion, TCA and vignetting.
- chromatic aberrations (`cacorrectrgb`): guided CA correction after lens correction.
- rotate and perspective (`ashift`): automatic keystone correction from detected lines, plus
  rotation.
- liquify (`liquify`): point, line and curve warps.
- retouch (`retouch`): clone, heal, fill and blur, optionally on wavelet scales.
- dither or posterize (`dither`).

**Geometry and canvas (3):**
- crop (`crop`).
- orientation (`flip`).
- enlarge canvas (`enlargecanvas`).

**Effects and creative (14):**
- graduated density (`graduatednd`).
- vignetting (`vignette`).
- grain (`grain`).
- bloom (`bloom`).
- soften (`soften`): the Orton effect.
- lowpass (`lowpass`) and highpass (`highpass`).
- lowlight vision (`lowlight`).
- framing (`borders`).
- watermark (`watermark`): SVG with variables.
- composite (`overlay`): overlays another processed image.
- censorize (`censorize`): blur plus noise.
- blurs (`blurs`): lens, motion and gaussian point spread functions.
- negadoctor (`negadoctor`): film negative inversion on a Kodak Cineon density model
  (`negadoctor.c` header).

(darktable files many modules under two groups, so the per-group counts are indicative. The total
is exact: 74.)

### 2.3 Detail, sharpening and local contrast

**Evidence, per algorithm.**

- **sharpen (`src/iop/sharpen.c`).** A classic unsharp mask on Lab L. It blurs with a gaussian of
  radius *r*, computes the detail d = L − blur(L), zeroes |d| below a threshold, and adds
  amount·d. The manual now says it is "no longer recommended" and points to contrast equalizer
  presets for deblurring (`sharpen.md`).
- **capture sharpening (demosaic, 5.4+).** Iterative sharpening with gaussian kernels whose σ
  (0 to 1.5) varies per pixel. The radius and "contrast sensitivity" are estimated automatically from
  the raw data (`demosaic.md`). **Assessment:** this is a Richardson–Lucy-style deconvolution with a
  spatially varying PSF. It follows RawTherapee's capture sharpening (unverified lineage). Lightroom's
  default Sharpening (Amount 40, Radius 1.0) plays the same role implicitly.
- **local contrast (`src/iop/bilat.c`).** It has two modes, both on Lab L.
  - *Bilateral grid* (Chen, Paris, Durand 2007). It splats L into a coarse grid, blurs, slices, and
    amplifies L − base by a detail factor.
  - *Local Laplacian* (the default; `src/common/locallaplacian.c`). This is the fast approximation
    of Paris, Hasinoff and Kautz's local Laplacian filter (2011), in the style of Aubry et al.
    (2014). It evaluates a small set of remapping curves (6 gamma samples), builds a Laplacian
    pyramid for each, and interpolates per pixel between the two nearest remapped pyramids. The
    remapping curve is an S around the local value (*detail*), with separate slopes for the
    *shadows* and *highlights* ends and a *mid-tone range* width. So one module does
    Clarity-like detail and Highlights/Shadows-like range compression together, without halos or
    gradient reversal. The manual warns about banding at extreme mid-tone values, which comes from
    the coarse gamma sampling.
- **contrast & texture (`src/iop/contrastntexture.c`, new in 5.8).** Local contrast in log
  luminance. The base layer comes from the *exposure-independent guided filter* (EIGF,
  `src/common/eigf.h`), the same filter the tone equalizer uses for its mask. Its controls are
  strength, detail level (the filter scale), edge protection (the filter ε), iterations, and a
  *noise bias* added to luminance before the log so that shadow noise is not boosted. The code
  header credits pixls.us proof-of-concept threads. **Assessment:** this is the closest darktable
  analogue to Lightroom's Clarity and Texture. It is scene-referred, exposure-invariant, and cheap
  (box filters).
- **contrast equalizer (`src/iop/atrous.c`).** An edge-optimised à-trous wavelet transform (Hanika,
  Dammertz, Lensch 2011, "Edge-Optimized À-Trous Wavelets for Local Contrast Enhancement with Robust
  Denoising"). It decomposes into B-spline detail scales with an edge-stopping weight, and applies
  per-scale gain splines for luma and chroma, per-scale soft-threshold denoise splines, and an
  "edges" spline that tunes the edge-stopping strength. It is powerful but opaque: one curve does
  sharpening, clarity, bloom and denoise, depending on which end you drag.
- **diffuse or sharpen (`src/iop/diffuse.c`, `dtdocs/.../diffuse.md`).** Aurélien Pierre's
  darktable 4.0 module. It iterates a heat-type PDE, ∂u/∂t = Σₖ speedₖ · div(Aₖ ∇ …), up to fourth
  order, on à-trous wavelet bands. Each order has a speed (positive diffuses, negative sharpens) and
  an anisotropy: diffuse along isophotes to preserve edges, or along gradients. Aₖ is a 2×2 tensor
  rotated to the local gradient and applied as a 3×3 anisotropic Laplacian kernel. The code cites a
  ResearchGate paper (id 220663968, title unverified because the site was unreachable) and Witkin &
  Kass 1991 for the kernel. For the isotropic stencil it cites Pierre's post "Rotation-invariant
  Laplacian for 2D grids" (eng.aurelienpierre.com, 2021-03, verified). Local-variance terms damp the
  speed near edges. Presets cover demosaic sharpening, lens deblur, dehaze, local contrast, bloom,
  denoise and inpainting. The manual calls it "highly resource-intensive" (up to 500 iterations),
  recommends stacking instances coarse to fine, and guarantees output only at 100% or on export.
- **tone equalizer (`src/iop/toneequal.c`, `tone-equalizer.md`).** Not a detail tool, but it shares
  the machinery. It builds a monochrome luminance mask (RGB euclidean norm by default) and smooths
  it with a guided filter, an averaged variant, or EIGF (the default). The smoothing diameter is a
  percentage of the long side, with edge feathering, iterations and optional quantisation. Nine
  sliders from −8 to 0 EV (or a smoothed curve over the same range) set an exposure gain as a
  function of the mask value. "Mask exposure and contrast compensation" re-centre the mask
  histogram under the nodes, with auto buttons. Hovering the image shows the mask EV under the
  cursor, and scrolling there raises or lowers that zone. Because pixels in one smooth region share
  a gain, local contrast survives shadow lifting.
- **haze removal (`src/iop/hazeremoval.c`).** He, Sun and Tang's dark channel prior (TPAMI 2011) with
  a guided-filter-refined transmission (He et al., ECCV 2010). It has only two controls, strength
  and distance. The manual admits it "will fail on many images that do not contain actual haze".

**Comparison with Lightroom.** Lightroom's Texture boosts mid-to-high frequencies while sparing the
finest (noise) band. Clarity is a larger-radius, midtone-weighted local contrast. Dehaze is a haze
model plus contrast, and negative values add haze. Sharpening has four controls:
- Amount.
- Radius (0.5–3).
- Detail, which is halo suppression; reportedly it moves toward deconvolution at high values
  **(unverified)**.
- Masking, an edge mask. Alt-drag shows it.

Adobe's algorithms are unpublished. **Assessment:**
- darktable has every building block, spread over five modules with engineering-level controls,
  but none of them is "Lightroom Clarity" out of the box.
- Lightroom's **Masking** slider and darktable's **details threshold** (section 2.4) are the same
  idea: a gradient-magnitude mask that confines an effect to edges. darktable generalises it to
  every module. Redlamp should build it once and use it in both places.
- **Recommendation for Redlamp P2** (engine choice pending an in-house prototype):
  - One multiscale luminance decomposition in log space, computed on the GPU pyramid. The fast
    local Laplacian and a guided-filter or EIGF pyramid are the two candidates. Local Laplacian is
    halo-free but costs more. Guided filters are O(1) per pixel with box filters and fit the
    < 16 ms budget.
  - Texture is a gain on the fine-to-mid bands. Clarity is a gain on the coarse bands, weighted to
    midtones. Edge-aware Highlights, Shadows, Whites and Blacks become tone-equalizer-style gains
    over the smoothed luminance mask, with Lightroom's four sliders as fixed zone weights.
  - Dehaze is a dark-channel transmission estimate on a coarse level, refined with a guided filter
    and applied in linear RGB, with a contrast term. darktable's two-slider dehaze is not good
    enough to copy directly. **Do better.**
  - Sharpening is a small-radius deconvolution-flavoured USM with Detail as halo control and Masking
    as the Scharr detail mask. Radius is expressed in full-resolution pixels and scaled with the
    zoom in previews, so Fit matches export. darktable's diffuse module only guarantees its result
    at 100%.
- **Skip for now:** a user-facing PDE solver. It is slow, and its 13 controls are not a Lightroom
  concept. The *deblur* capability itself (undoing lens softness) is a credible beyond-Lightroom
  feature, but it competes with the planned AI "Raw Details" and denoise work (ai-findings §2).
  **Later**, as a single "Lens Deblur" slider if prototypes justify it.

### 2.4 Masking and blending

#### How darktable blends

**Evidence.** In `src/develop/blend.c`, `dt_develop_blend_process` does the following:
1. Builds a per-pixel mask in the module's output region of interest (ROI):
   - *uniform*: the mask is the global opacity everywhere;
   - *raster*: a mask stored by an earlier module, optionally inverted;
   - *drawn and/or parametric*: see below.
2. Refines the mask with the *details threshold*.
3. Runs up to three post-operations in a user-chosen order: guided-filter feathering (guided by
   module input or output, before or after blur), gaussian blur, and a mask "tone curve" for
   opacity and contrast.
4. Blends input and output in one of four blend color spaces: Lab, RGB display (HSL channels),
   RGB scene (JzCzhz channels), or raw.
5. Optionally stores the mask for later modules to reuse as a raster mask.

The blend formula is out = (1 − m)·in + m·f(in, out), where f is the blend mode. A "reverse" button
swaps the roles of input and output (`dtdocs/.../blend-modes.md`).

**Blend modes.** There are about 35: normal and bounded, the arithmetic modes (add, multiply,
divide, screen, difference, the means), the contrast modes (overlay, soft, hard, vivid, linear and
pin light), per-channel modes (Lab L/a/b/color, RGB R/G/B, HSV value/color) and lightness,
chromaticity, hue and color. In scene-referred RGB, the modes that assume a 50% grey are
unavailable, and arithmetic modes gain a user **blend fulcrum** for the neutral point, because
scene data has no natural "mid-grey = 0.5".

#### Drawn masks (`src/develop/masks/*.c`)

There are seven shape types (`src/develop/masks.h`): circle, ellipse, path, brush, gradient, group
and, new in master, **AI object** (`object.c`). Shapes are vectors stored in original-image
coordinates and transformed through all distorting modules (lens, perspective, liquify). Circles
therefore become ellipses and gradient lines bend after lens correction. The manual suggests
curving the gradient to compensate (`drawn.md`, "shape distortions").

Falloff profiles:
- **Circle:** full opacity inside radius r, then quadratic falloff to the feather edge R. With d
  the distance from the centre, f = clamp((R² − d²)/(R² − r²)), and opacity = f² (`circle.c`).
- **Ellipse:** the same idea. The feather can be "equidistant" (constant width) or "proportional"
  (scales with each axis), toggled with Alt-click (`ellipse.c`).
- **Gradient:** a line with a *compression* width. The profile is linear, or sigmoidal via
  0.5 + 0.5·erf(distance / compression). A *curvature* parameter bends the line into a parabola
  (`gradient.c`).
- **Path:** closed Bézier outline with per-node feather widths. The feather is rasterised on the
  CPU by drawing linear ramps from border points to feather points and taking the maximum
  (`path.c`).
- **Brush:** a stroke converted to nodes, each with its own size, hardness and density (opacity),
  with optional pen pressure mapping. Rendering is CPU-heavy, and the manual warns users about it.

Every shape has its own opacity, adjusted with Ctrl-scroll. Shapes can be shared across modules by
reference ("add existing shape") or copied as a group ("use same shapes as").

**Groups** (`group.c`) combine shapes in order with set operators. With *a* the running mask and
*b* the next shape (after its own inversion and opacity):
- union = max(a, b)
- intersection = min(a, b)
- difference = a·(1 − b)
- sum = min(1, a + b)
- exclusion = max((1 − a)·b, a·(1 − b))

The **mask manager** (a utility module) is where groups are built, in a separate panel from the
module that uses the mask. **Assessment:** splitting "draw" from "combine" across two panels is
the least Lightroom-like part of the design.

**AI object** (`object.c`, `dtdocs/.../ai-masking.md`). It is click-prompted segmentation with a
SAM-class encoder and decoder. Shift-click adds negative points. The encoder runs once per image;
its embedding is cached on disk and invalidated when geometry changes. The result is refined with a
guided or bilateral step, then **vectorised into a group of Bézier paths**. After that the model is
not involved, and the mask renders like any path. The default render size is 1536 px on the long
side; the encoder itself works at 1024.

#### Parametric masks (`blend.c`, `parametric.md`)

For each channel of the blend color space there is a **trapezoid** with four markers: an inner
range at full opacity, outer bounds at zero, and linear ramps between. The channels are:
- Lab: L, a, b, C, h;
- display RGB: grey, R, G, B, H, S, L;
- scene RGB: grey, R, G, B, Jz, Cz, hz.

Each trapezoid has a polarity toggle, and there is a *boost factor* for scene values above 1. The
channel masks are **multiplied**. They can be computed on the module's input *or output*. Pickers
set the ranges from a dragged rectangle. Pressing C over a slider shows that channel, and pressing
M shows the resulting mask.

Drawn and parametric masks combine through a "combine masks" setting with four modes: exclusive
(multiply), inclusive (invert, multiply, invert), and each of these followed by a final inversion.
Combined with per-mask polarity, this is complete but hard to reason about. The manual says: "For
novice users it is recommended that you stick to the above two use cases."

#### Refinement (`refinement-controls.md`, `blend.c`, `masks/detail.c`)

- **Details threshold** (−1 to 1). A Scharr gradient magnitude of luminance Y is computed once from
  the *demosaic* output (or rawprepare output for monochrome sensors). It passes through a sigmoid
  with the threshold, is lightly blurred, is then warped through the pipeline's distortions to the
  module's ROI, and multiplies the mask. Positive values keep detailed areas; negative values keep
  flat ones. Because the data comes from the demosaic stage, later edits don't change it, and it is
  not available for non-raw images. Typical uses: sharpen without touching bokeh, denoise only flat
  sky. 5.8 fixed a performance bug where editing a mask that used details re-ran the pipeline from
  demosaic onwards.
- **Feathering guide and radius.** A guided filter (He et al. 2010) with the module's input or
  output image as the guide pulls the mask edges onto image edges. It runs before or after the
  blur.
- **Blurring radius.** A gaussian blur of the mask.
- **Mask opacity and contrast.** An S-curve with an exp(3·contrast) slope and a brightness shift.
  It keeps fully opaque and fully transparent regions fixed, to recover opacity lost to feathering.
- **Display.** Mask shown as a yellow overlay on greyscale. There is also a temporary "mask off"
  toggle.

#### Raster masks and instances

**Raster masks** (`raster.md`). Any active module's final mask can be reused by a later module
(inverted if needed). This is how darktable does "same selection, different adjustment". The
external raster masks module imports a PFM from another application.

**"Every module is a local adjustment."** Local edits in darktable are typically a second instance
of *exposure*, *color balance rgb* or another module, with a mask
(`processing-modules/multiple-instances.md`). The manual's own example is two denoise instances,
one blended "lightness" and one "color", to treat luma and chroma noise separately.

#### Lightroom and Redlamp compared

**Lightroom's model.** Each mask is a set of components (Brush, Linear, Radial, range masks, AI)
combined by Add, Subtract and Intersect. Components can be inverted, and each mask carries a fixed
list of local sliders plus Amount. There are no blend modes and no per-component opacity (brush Flow
and Density aside). Auto Mask on the brush and the "Refine" slider on Color and Luminance Range are
the only refinement aids (verify against the newest releases).

**Redlamp today** (`packages/RedlampEngineAPI/Sources/Masks.swift`,
`packages/RedlampKernels/Sources/Shaders/Develop.metal`):
- `MaskLayer` holds components (linear, radial), an operation (add, subtract, intersect), an
  inversion flag, an Amount of 0–200, and local parameter deltas.
- The fused kernel evaluates each component analytically. Linear gradients use a smoothstep ramp;
  radial gradients use a smoothstep between the inner feather radius and the edge.
- Components combine in order: add = max, subtract = a·(1 − b), and intersect = a·b (a product).
  darktable's intersection is min(a, b). The product is softer where two feathers overlap, so check
  it against Lightroom.
- Local adjustments are coverage-weighted sums of parameter deltas, applied in the same pass.

**Assessment and the recommended hybrid.** Keep Lightroom's mask panel, component model and slider
list. That is the familiarity promise, and parameter modulation is far cheaper than darktable's
per-module blend. Add the following, each exposed in Lightroom-shaped UI:

1. **Range components as parametric trapezoids in OKLCh** (P2):
   - *Luminance Range* is a trapezoid on scene luminance in EV or perceptual lightness. Lightroom's
     range-plus-smoothness control is effectively a trapezoid (verify).
   - *Color Range* is a union of sampled swatches. Each swatch is a smooth ellipsoidal falloff in
     OKLab around the sample, with a Refine slider scaling it.
   - *Depth Range* (P3) is a trapezoid on depth.

   OKLCh is already Redlamp's color-work space. Parametric channels cost one evaluation per pixel in
   the fused kernel, but they need the pixel's color, so they must be evaluated after the camera
   matrix. That is already where coverage is used.
2. **A "Detail" refinement on every mask** (P2, alongside brush). Compute the Scharr (or Sobel)
   magnitude of luminance once per image on the pyramid base level and store it as a mip texture.
   A signed slider keeps textured or flat areas. It is darktable's details threshold and Lightroom's
   Sharpening Masking in one primitive, and it is cheap. Unlike darktable's, it also works for JPEG
   and HEIC, and it needs no warping because masks are evaluated in the same pre-geometry space
   (item 6). **Beyond Lightroom.**
3. **"Refine Edges" for brush and AI components** (P3, matches inventory's "mask refinement"). A
   guided-filter snap of the component to image edges, run on a coarse pyramid level and upsampled
   with the guide. This goes beyond Lightroom's brush Auto Mask, because it works after the fact on
   any component.
4. **Mask-reference component** (P2 engine, P3 UI as "new mask from existing"). A component that
   uses another layer's coverage. The kernel already computes coverage for every layer in order,
   so referencing an earlier layer is nearly free. This is darktable's raster reuse without its
   pipeline-ordering constraints.
5. **Keep shapes analytic; rasterise only brush and AI.** darktable renders every shape on the CPU
   per module and warns that brushes are slow. Redlamp should do better:
   - evaluate brush strokes as capsule signed-distance fields for small stroke counts, and
     rasterise into a per-layer coverage texture on the GPU when counts grow;
   - store AI masks as compressed rasters in a companion file next to the `.redlamp` JSON, the
     same move darktable made with `.dtdata` in 5.8;
   - offer darktable's vectorise-to-path as an explicit "Convert to Path" action for users who want
     editable outlines.
6. **Coordinate space** (P2, before crop and lens). Store components in unoriented, pre-geometry
   image coordinates, and map them forward through orientation, lens and transform in the kernel.
   Then masks stick to content through crop, rotate, Upright and lens changes. darktable's
   bendable gradients become unnecessary, because gradients are evaluated before distortion.
7. **Skip:**
   - blend modes: Lightroom users don't expect them, and the scene-referred fulcrum problem shows
     the cost;
   - the four "combine masks" modes: Add, Subtract and Intersect plus Invert already express them;
   - output-channel parametric masks;
   - per-shape opacity: use brush Density and Flow and layer Amount instead;
   - the separate mask manager.
8. **Optional later:** mask contrast and blur ("Feather" and "Contrast" in a mask's Refine
   section), useful for AI masks that are too hard-edged. **P3, decide after AI masks ship.**

### 2.5 Retouch, spot removal and liquify

**Evidence.**
- **retouch** (`src/iop/retouch.c`, `retouch.md`) replaced *spot removal* in 3.6. Each shape
  (circle, ellipse, path or brush) is a target with a source offset. The algorithms are:
  - **Clone**: a copy.
  - **Heal**: GIMP-derived (`src/common/heal.c`, credited to Jean-Yves Couleaud). It computes the
    difference between target and source, solves Laplace's equation ΔI = 0 inside the mask with
    that difference as the Dirichlet boundary, using red/black Gauss–Seidel with over-relaxation,
    then adds the solution back to the source. This is a membrane or Poisson-style correction
    (Pérez et al. 2003).
  - **Fill**: a color or "erase".
  - **Blur**: gaussian or bilateral.

  The source can be placed relative or absolute (Shift-click or Ctrl-Shift-click), and a single
  click-drag sets both target and source. Crucially, retouch can first decompose the image into
  à-trous wavelet scales. Edits apply to a chosen scale and, via "merge from", to a range of
  coarser scales. The residual is also editable. So you can heal a blotch on a coarse scale while
  fine pores stay intact, or blur a coarse scale to even skin tone. This is frequency separation
  without layers. The module shows the uncropped image while active, and its pipeline position is
  early (before exposure), so healed pixels flow through all later edits. It supports blending but
  not masks (`IOP_FLAGS_NO_MASKS`).
- **liquify** (`src/iop/liquify.c`, `liquify.md`) warps with nodes: points, lines and Bézier curves.
  Each node has a radius, a strength vector and optional two-circle feathering. Point modes are
  linear push, radial grow and radial shrink. Lines and curves interpolate the vectors along the
  path. There is a limit of 100 nodes per instance, and it is expensive. It resamples with bicubic
  or Lanczos kernels.

**Assessment.** ai-findings §6 already sets the plan: classical Poisson or multigrid heal and clone
in P3, exhaustive GPU source search (no PatchMatch), dust detection, and a trained inpainter later.
darktable adds two things to that plan:
- **Wavelet-scale retouching is the beyond-Lightroom feature.** Portrait retouchers do frequency
  separation in Photoshop because Lightroom can't. A Redlamp Healing option "Detail level: All /
  Fine / Coarse / Tone", with heal or blur on the chosen band, is a small extension once heal and
  the multiscale decomposition exist. **Adopt, P4** (P3 if heal lands early).
- **Heal should use a multigrid solve.** The original author's note in `heal.c` says the solver
  "could benefit from a multi-grid evaluation of an initial solution". Plain Gauss–Seidel converges
  slowly on large regions, and multigrid is already the ai-findings plan.
- **UX lessons:** placing the source first (a "+" follows the cursor), relative versus absolute
  source modes, click-drag to set target and source together, and showing the uncropped image
  while retouching are all worth copying. Lightroom already auto-picks the source, and Redlamp
  should keep that as the default.
- **liquify: skip.** It is a Photoshop-class tool with no Lightroom equivalent and little
  raw-editing value. **Later at most.**

### 2.6 Instances, ordering, groups and the quick access panel

**Evidence.**
- **Ordering.** Modules execute in UI order. Ctrl-Shift-drag reorders them. Named orders exist:
  legacy, v3.0 and v5.0, plus JPEG variants and user presets (`src/common/iop_order.c`,
  `the-pixelpipe-and-module-order.md`). The manual recommends against reordering: it "often worsen[s]
  the result", modules assume specific color spaces, and some orders are impossible. It is
  expected mainly for special cases, such as running diffuse-or-sharpen demosaic sharpening before
  the input profile.
- **Instances.** New or duplicate instance, rename, move up or down, and delete. Styles and
  copy/paste match instances by name. Instances add pipeline cost.
- **Module groups.** Configurable tabs, with presets such as "modules: all", "workflow: beginner",
  "workflow: scene-referred", "workflow: display-referred" and "search only"
  (`src/libs/modulegroups.c`). There is a search box.
- **Quick access panel.** A user-editable collection of widgets from many modules. The default is
  roughly a Basic panel: exposure, tone-mapper contrast, WB, chroma/vibrance/saturation, tone
  equalizer, rotation, denoise, lens and local contrast. It stops working for a module once that
  module has several instances.

**Assessment.**
- The quick access panel is darktable admitting that users want a Lightroom Basic panel. It is
  still a collection of other modules' widgets, so its contents change with the chosen workflow
  (filmic, sigmoid or AgX).
- Reordering and instances give real power: two denoise passes, a LUT before the tone mapper, a
  second tone equalizer. But they create failure modes Lightroom users never meet:
  - silent quality loss from bad orders;
  - copy/paste ambiguity between instances;
  - "which instance is active?" confusion.
- **Redlamp should expose:**
  - a **fixed pipeline order** (documented, versioned with the process version);
  - Lightroom's **panels in Lightroom's order**;
  - **mask layers as the only "instance" concept**;
  - a **command palette and panel search** (already an inventory candidate). darktable's module
    search is the closest analogue, and valuable once beyond-Lightroom panels exist.
- **Keep internal:** stage order, technical modules (rawprepare, hot pixels, demosaic choice with a
  sensible automatic default, highlight reconstruction mode, dithering), and color-space plumbing.
- **Beyond-Lightroom panels** (Tone Equalizer, a frequency-separation option) should live after
  their nearest Lightroom panel. Tone Equalizer would go after Tone Curve. Hide them by default
  behind a "Show Advanced Panels" preference, so Lightroom familiarity holds for everyone else.

---

## 3. Mapping: darktable module → Lightroom → Redlamp

Verdicts: **Adopt** (take the idea), **Better** (same capability, better design or UX), **Skip**,
**Done** (Redlamp already has it). "Internal" means it is not user-facing in Redlamp. Phases refer
to the README roadmap and the inventory.

### Raw-level, color management and calibration

| darktable module | Lightroom equivalent | Redlamp verdict, phase |
| --- | --- | --- |
| raw black/white point | implicit | Done (internal), P1 |
| white balance | Basic: WB, Temp, Tint | Done, P1 |
| highlight reconstruction | implicit in Highlights/Whites | Adopt (guided inpaint), P2 |
| raw chromatic aberrations | Remove Chromatic Aberration | Adopt, P2 |
| hot pixels | implicit | Adopt (internal, automatic), P2 |
| raw denoise | Noise Reduction (part) | Skip module; fold into classical NR, P2 |
| demosaic (+ dual demosaic, capture sharpen) | implicit; Enhance Raw Details | Adopt RCD/AMaZE/Markesteijn P2; capture sharpening inside Sharpening, P2 |
| rotate pixels, scale pixels | implicit | Skip (rare sensors; LibRaw's job) |
| external raster masks | none | Later (import a mask, e.g. from focus stacking) |
| input color profile | Profile (implicit), Calibration | Better: DCP/ICC, P2 |
| output color profile | Export color space | Done basic P1; full P4 |
| unbreak input profile | none | Skip |
| color calibration | Calibration panel + WB | Adopt CAT-based WB and primaries maths, P2; chart calibration via redlamp-profiler, P3 |
| rgb primaries | Calibration: R/G/B Hue and Saturation | Adopt (closest model of Calibration), P2 |
| color look up table | none (DCP editors outside) | Adopt via redlamp-profiler, P3 |
| LUT 3D | Creative profiles; LUT import beyond Lightroom | Adopt, P2 |

### Tone

| darktable module | Lightroom equivalent | Redlamp verdict, phase |
| --- | --- | --- |
| exposure | Basic: Exposure | Done, P1 |
| filmic rgb, sigmoid, AgX | profile base tone mapping | Done (own filmic map), P1; revisit curve shape, P2 |
| spektrafilm | none (Camera Matching / creative looks) | Skip module (GPL, CC BY-SA data); inspiration for looks, P3+ |
| base curve (+ exposure fusion) | profile tone | Skip |
| tone equalizer | Highlights/Shadows/Whites/Blacks; no zone EQ | Adopt engine P2; beyond-Lightroom panel with on-image scroll, P3 |
| tone curve, rgb curve | Tone Curve (parametric, point, RGB) | Done P1; RGB curves, P2 |
| rgb levels | Whites/Blacks | Skip (covered) |
| local contrast | Clarity (+ Highlights/Shadows) | Better (one multiscale engine), P2 |
| contrast & texture | Texture, Clarity | Adopt approach (EIGF, log space, noise bias), P2 |
| shadows and highlights | Highlights/Shadows | Skip module; edge-aware version, P2 |
| color reconstruction | implicit | Skip; fold into highlight reconstruction, P2 |

### Color and grading

| darktable module | Lightroom equivalent | Redlamp verdict, phase |
| --- | --- | --- |
| color balance rgb | Color Grading, Vibrance, Saturation | Done, P1 |
| color balance (CDL) | Color Grading | Skip |
| color equalizer | Color Mixer HSL | Done P1; adopt guided smoothing against HSL noise, P2 |
| color zones | Color Mixer, Point Color | Point Color, P3; skip module |
| color harmonizer | none | Later (beyond Lightroom, niche) |
| saturation curve | Refine Saturation (verify) | Later |
| color contrast, color correction, velvia, colorize | none / Color Grading / Vibrance | Skip |
| monochrome | B&W treatment, B&W Mix | Done P1; B&W Mix, P2 |
| split-toning | Color Grading (Shadows/Highlights) | Done, P1 |
| color mapping | none | Later: "Match Look to Reference", with Reference view, P4+ |

### Correction, detail and geometry

| darktable module | Lightroom equivalent | Redlamp verdict, phase |
| --- | --- | --- |
| denoise (profiled) | Noise Reduction (Luminance, Color) | Adopt the concept (own profiles; GPL data unusable), P2 |
| astrophoto denoise (NLM) | Noise Reduction | Skip module; NLM is a candidate kernel, P2 |
| surface blur | none (negative Texture) | Skip; skin smoothing via negative Texture in a mask, P2 |
| sharpen (USM) | Sharpening | Better (detail mask, halo control, deconvolution flavour), P2 |
| contrast equalizer | Texture, Clarity, Sharpening, NR | Skip module; wavelets internal, P2 |
| diffuse or sharpen | Sharpening, Dehaze; Lens Blur in reverse | Skip P2; single "Lens Deblur" slider, Later |
| haze removal | Dehaze | Better (scene-referred, guided, local), P2 |
| lens correction | Lens Corrections (profile, manual) | Adopt (lensfun, embedded), P2/P3 |
| chromatic aberrations (RGB) | Remove CA, Defringe | Adopt, P2 |
| rotate and perspective | Transform: Upright, Guided, sliders | Adopt (line detection and fit), P2 Guided, P3 Auto |
| crop | Crop and Straighten | Adopt, P2 |
| orientation | Rotate 90°, Flip | Adopt, P2 |
| enlarge canvas | none (Generative Expand) | Later |
| liquify | none | Skip (Later at most) |
| retouch (+ wavelet scales) | Healing, Clone, Remove | Adopt P3; frequency separation, P4 |
| dither or posterize | none (implicit) | Adopt (internal dithering at 8-bit output), P2 |
| graduated density | Linear Gradient mask | Done (covered), P1 |

### Effects and creative

| darktable module | Lightroom equivalent | Redlamp verdict, phase |
| --- | --- | --- |
| vignetting | Post-crop vignetting | Done, P1 (styles P2) |
| grain | Grain | Done, P1 |
| bloom, soften (Orton) | none (negative Clarity approximates) | Later: optional "Glow" in Effects, P4 |
| lowpass, highpass | none | Skip |
| lowlight vision | none | Skip |
| framing | none (Print module) | Later (export borders), P4 or Later |
| watermark | Export watermark | Adopt, P4 |
| composite | none | Skip |
| censorize | none | Skip |
| blurs (lens, motion, gaussian) | Lens Blur (AI depth) | Later (with depth maps) |
| negadoctor | none (third-party plugins) | Adopt the Cineon-density model, Later (candidate P4; see open questions) |

**Beyond-Lightroom shortlist, in priority order:**
1. Mask detail refinement (P2).
2. Tone Equalizer panel (P3, engine P2).
3. Guided edge refinement for masks (P3).
4. Frequency-separation retouch (P4).
5. Auto perspective (P3, already planned).
6. Film negative inversion (candidate P4).
7. Color-checker calibration via redlamp-profiler (P3).
8. Glow/Orton effect (P4, optional).
9. Lens Deblur (Later).
10. Reference color matching (Later).

Direct LUT import is already planned for P2.

---

## 4. Licensing notes

- **All darktable code is GPL-3.0**, including `heal.c` (itself derived from GIMP, GPL),
  `locallaplacian.c`, `eigf.h`, `guided_filter.h` and the mask code. Only the ideas are used, from
  these papers and descriptions:
  - Hanika et al. 2011 (edge-optimised à-trous wavelets)
  - Paris et al. 2011 and Aubry et al. 2014 (local Laplacian)
  - He et al. 2010 (guided filter) and 2011 (dark channel prior)
  - Pérez et al. 2003 (Poisson editing)
  - Reinhard et al. 2001 (color transfer)
  - Chen, Paris and Durand 2007 (bilateral grid)
  - Witkin & Kass 1991 (reaction-diffusion)
  - the Kodak Cineon sensitometry documentation (negadoctor)
- **EIGF** (the exposure-independent guided filter) is a darktable-original variant, with no paper
  found. It is described well enough in `tone-equalizer.md` and `contrast-texture.md` to implement
  from the description: a guided filter on log or exposure-normalised luminance, so that the blur
  strength does not depend on brightness. Treat it as an idea, not a spec.
- **Patents to check before shipping (unverified):** the dark channel prior (Microsoft, filed about
  2009–2010), the guided image filter (Microsoft), and local Laplacian filtering (the authors were
  at Adobe or MIT). ai-findings §6 already covers the healing and PatchMatch patents: Poisson
  editing and the Healing Brush patents have expired.
- **Data Redlamp cannot ship:** darktable's `noiseprofiles.json` (the denoise profiles), module
  presets and styles, and `darktable-chart` outputs (all GPL). Also spektrafilm's film and paper
  profiles (CC BY-SA 4.0, downloaded separately by darktable) and its GPL simulation code.
  CC BY-SA data might be usable as data with attribution, but its share-alike terms need legal
  review before any App Store use.
- **SAM-class models** for AI object masks: model licensing is covered in ai-findings §5.
  darktable's vectorisation step adds no licensing concern.

---

## 5. Open questions

1. **Intersect semantics.** Redlamp multiplies (a·b), while darktable takes min(a, b). Which does
   Lightroom use? Measure two overlapping feathered radials in Lightroom and match it (P2, with the
   UI for operations).
2. **Mask coordinate space.** Should components be stored in sensor-unoriented space, and should
   radial radii be defined relative to the unoriented short side? This must be settled, with a
   sidecar migration, before Crop and Transform land in P2.
3. **Clarity and Texture engine.** Fast local Laplacian or a guided-filter/EIGF pyramid? It needs
   a prototype measuring halos, gradient reversal, noise boost and milliseconds at Fit and 1:1 on M1
   and A-series chips. darktable's own move (contrast & texture in 5.8) suggests guided filters are
   "good enough" and much cheaper.
4. **Spatial local adjustments.** Is modulating precomputed detail bands by coverage visually
   equivalent to Lightroom's local Clarity, Texture and Dehaze at mask edges? Test with a hard-edged
   radial and Clarity at +100.
5. **Tone Equalizer panel.** Is a beyond-Lightroom panel worth the familiarity cost, or should the
   engine only power Highlights and Shadows, with a Targeted Adjustment-style "scroll on image"
   gesture? Decide at P3 with usability testing.
6. **Negative inversion.** There is real demand among film shooters (Negative Lab Pro's success in
   Lightroom is the evidence, unverified market size). Should it enter the roadmap (P4) or stay
   Later? It needs only a density-model inversion, film-base sampling, and a Treatment option.
7. **Blend modes for masks.** Is there any case (for example "Color only" or "Luminosity only" local
   adjustments) that justifies a single per-layer mode toggle? Default: no.
8. **AI mask storage.** Raster in a companion sidecar, as recommended, or vectorised paths like
   darktable? It affects iCloud sync size and copy/paste across photos (P2 decision alongside Vision
   masks).
