# E. Lenses and geometry

Scope: lens corrections (lensfun, Adobe LCP, manufacturer data embedded in raw files, DNG opcodes),
chromatic aberration, rotate and perspective (Upright), crop, orientation, liquify, scaling, and
where geometry sits in the pipeline relative to masks. Sources: darktable master 426d8ad, lensfun
master bbd4332 (database timestamp 2026-09-24), dtdocs master, LibRaw 0.22.2 as vendored by
Redlamp, and the web pages cited inline. Rules in [_conventions.md](_conventions.md) apply: no code
was copied, algorithms are described in prose and one-line formulas.

## 1. Summary

1. **One lens-correction engine fed by every source. Adopt and do better, Phase 2.** darktable
   reduces every embedded vendor format to a per-channel radius multiplier plus a vignetting gain,
   both 1-D splines over normalised radius (`src/iop/lens.cc`, `_init_coeffs_md_v2`). Redlamp should
   bake *every* source (lensfun, LCP, embedded data, DNG opcodes, manual sliders) into per-image 1-D
   tables of that kind, plus an optional optical centre and tangential terms, and sample them in the
   fused kernel.
2. **Move embedded manufacturer corrections from Phase 3 to Phase 2. Adopt, Phase 2.** Each parser
   is under 100 lines, and embedded data removes lens identification from the problem. Redlamp's
   Sony A7 III fixture carries all three Sony tags, and LibRaw already delivers the bytes through
   its tag callbacks. Make it the default when present, as darktable does.
3. **lensfun as data only, with our own parser and maths. Adopt, Phase 2.** The LGPL-3 library
   can't reasonably go into an App Store binary. The models are simple published polynomials. The
   CC BY-SA 3.0 database can ship as a separate resource with attribution; converted forms stay
   BY-SA.
4. **Compose all geometry into one inverse map. Do better, Phase 2.** darktable resamples once per
   distorting module. Redlamp should evaluate crop, then Transform, then orientation, then lens
   analytically per output pixel, and sample the pyramid once per channel with the mip level taken
   from the map's Jacobian. That gives one interpolation, and geometry edits never touch the
   pyramid.
5. **Fix the mask coordinate space before crop lands. Adopt the principle, do better on shapes;
   Phase 2, blocking.** darktable stores shapes in input-image coordinates and pushes them forward
   through the distorting modules, so masks stick to content. Redlamp's `ImagePoint` already means
   oriented source space, so existing sidecars stay valid. Store gradient *anchors* in source space
   and build the shape in corrected space, so ellipses stay ellipses on screen.
6. **Upright as a virtual camera rotation (H = K·R·K⁻¹), not ShiftN's parameter chain. Do better,
   Phase 2.** It gives Level, Vertical, Full and Guided in closed form from vanishing points, and it
   maps onto Lightroom's Manual Transform sliders.
7. **Our own line detector, written from the LSD paper. Skip darktable's code (AGPL-3); late
   Phase 2.** Every Upright mode needs the same detector and solver. The inventory's split (Level
   and Vertical in P2, Auto and Full in P3) doesn't hold, because Level and Vertical detect lines
   too.
8. **Chromatic aberration in three parts. Adopt the ideas, Phase 2.** Profile and embedded TCA go
   in the warp. Automatic lateral CA comes from estimated R/G and B/G radial scale. Defringe follows
   Lightroom's hue-range controls. A guided "auto fringe" like `cacorrectrgb` can come in Phase 3.
   Skip `cacorrect` (GPL, Bayer-only).
9. **Crop, orientation and guides: copy Lightroom, not darktable's three modules. Adopt, Phase 2.**
   Store parameters that map 1:1 onto Lightroom's `crs:` fields for Phase 4 XMP import.
10. **Skip liquify, projection changes and "simulate lens" mode.** Lightroom has none of them.

## 2. Detailed findings

### 2.1 lensfun

**Evidence: database structure** (`data/db/*.xml`, `data/db/lensfun-database.xsd`,
`docs/manual-main.txt`)

- **Files and format.** 59 XML files split by class and maker (`slr-canon.xml`, `mil-sony.xml`,
  `compact-*.xml`, `generic.xml`) under `<lensdatabase version="2">`, the lensfun-master format.
  darktable refuses lensfun 0.3.95 and later at compile time (`src/iop/lens.cc`), so its users run
  the stable 0.3.x library and the older format. The update server still publishes formats 0–2.
- **Mounts and cameras.** A `<mount>` defines a name and its `<compat>` mounts; a lowercase first
  letter marks a fixed-lens compact. A `<camera>` has maker, model, variant, mount and crop factor.
- **Lenses.** A `<lens>` has maker, models (several allowed), mounts, focal and aperture ranges, a
  type (rectilinear or one of several fisheye and panoramic projections), the crop factor and aspect
  ratio of the *calibration* body, an optional optical-centre offset, and a `<calibration>`.
- **Calibration entries.** A `<calibration>` holds distortion and TCA entries per focal length, and
  vignetting entries per focal length, aperture and distance. A lens calibrated on two sensor sizes
  appears twice: the Sony FE 24-70 f/4 is listed with crop 1.534 (from an A6000) and 1.0 (from an
  A7 II).

**Evidence: coverage** (a script over `data/db`, 2026-09-30)

- **Totals.** 1,569 lens entries (274 fixed-lens compacts), 1,057 cameras and 52 mounts.
  Distortion data exists for 1,527 lenses, TCA for 1,013, and vignetting for only 712.
- **Models in use.** Distortion entries are ptlens 5,572, poly3 873 and poly5 5. TCA is poly3 3,788
  and linear 5. Vignetting is pa 29,594. There are **no `acm` entries**; the maintainers refuse Adobe
  data (see 2.2).
- **Unique lenses per modern mount.**

  | Mount | Unique lenses | Native lenses | Distortion / TCA / vignetting | Notes |
  | --- | --- | --- | --- | --- |
  | Sony E | 211 | 58 Sony | 209 / 157 / 118 | Sigma 38, Samyang 22, Tamron 18, Viltrox 17 |
  | Fujifilm X | 94 | 38 Fujifilm | | |
  | Nikon Z | 95 | 35 Nikon | | |
  | Canon RF | 56 | 36 Canon | | |
  | L-mount | 70 | | | |
  | Micro Four Thirds | 120 | | | |

  For comparison, Canon EF has 292 and Nikon F AF 272.
- **Thin areas.** Fujifilm G (7), Hasselblad X (5) and Leica M (8) are thin, as are native RF and Z
  lenses and anything recent. Vignetting covers only about 45% of lenses; the lensfun site itself
  says "only for distortion correction, the coverage is at almost 100%".

**Evidence: models** (`include/lensfun/lensfun.h.in`, `libs/lensfun/modifier.cpp`)

All models map the *undistorted* (output) radius to the *distorted* (source) radius. That is the
direction you need for an inverse-mapping resampler.

- poly3: r_d = r_u·(1 − k1 + k1·r_u²).
- poly5: r_d = r_u·(1 + k1·r_u² + k2·r_u⁴).
- ptlens (Hugin): r_d = r_u·(a·r_u³ + b·r_u² + c·r_u + 1 − a − b − c).
- TCA linear: r_d,c = k_c·r_u,c. TCA poly3: r_d,c = r_u,c·(b_c·r² + c_c·r + v_c) for c ∈ {R, B}.
  G is the reference.
- Vignetting pa (D'Angelo): C_d = C_s / (1 + k1·r² + k2·r⁴ + k3·r⁶).
- ACM (the Adobe camera model, from Adobe's published "lensprofile_creator_cameramodel.pdf"):
  radial k1..k3 plus tangential k4, k5 on x and y, measured in units of the focal length. The ACM
  TCA and vignetting variants follow the same pattern.
- **Coordinate systems differ per model, and this is the main source of bugs.** For
  Hugin-derived models (ptlens, poly3, poly5, linear), r = 1 at half the *shorter* image side. For
  pa vignetting, r = 1 at the image *corner*. For ACM, r is in units of the focal length. lensfun
  converts everything into a focal-length-normalised system with the scale
  √(36² + 24²) / crop / diag_px / f_real. It rescales polynomial coefficients when the image's
  crop factor or aspect ratio differs from the calibration body's (`modifier.cpp` header comment,
  `rescale_polynomial_coefficients`).
- The documented order ("How it is really done", `docs/manual-main.txt`) is:
  1. Devignette the source first; it is separable.
  2. For each output pixel, apply scale, perspective, projection change, undistortion and
     anti-TCA to get a source coordinate.
  3. Look up the vignetting-corrected source at that coordinate.

**Evidence: interpolation** (`libs/lensfun/lens.cpp`, `libs/lensfun/auxfun.cpp`)

- **Calibration set choice.** lensfun picks the calibration set whose crop factor is closest while
  satisfying image_crop / calib_crop ≥ 0.96. A full-frame calibration can serve an APS-C body, but
  not the reverse, because that would extrapolate past the calibrated radius.
- **Distortion and TCA:** interpolated over focal length only, with a cubic Hermite spline through
  the two neighbours on each side. Before interpolating, coefficients are pre-conditioned by
  multiplying by focal length because they fall roughly as 1/f. ACM coefficients get extra
  powers of f.
- **Vignetting:** inverse-distance weighting with power 3.5 in a transformed space. The axes are
  focal length normalised to the lens's focal range, 4 / aperture, and 0.1 / distance. It gives up
  if the nearest sample is more than 1 unit away.
- Distortion therefore **never depends on focus distance**, even though real lenses breathe.
  Embedded vendor data, computed by the camera for the actual focus position, can capture that.
  That is an assessment; I haven't measured it.

**Evidence: lens identification** (`libs/lensfun/database.cpp` `MatchScore`, `src/iop/lens.cc`
`reload_defaults`)

- Matching is by **name string**, not by numeric lens ID. A fuzzy word matcher splits names into
  digit, punctuation and other runs and ignores single punctuation marks and a lone "f"
  (`docs/manual-main.txt`, `<lens>` section). Points are awarded for:
  - focal and aperture range agreement within 1%,
  - the camera mount (+10) or a compatible mount (+9),
  - the maker (+10),
  - the fuzzy model score,
  - and the crop factor relative to the calibration crop (2–10 points).

  A mount mismatch or maker mismatch disqualifies the lens.
- darktable first looks up the **camera** in the database to get the mount and crop factor. If the
  body is missing, lens lookup fails. For fixed-lens compacts with no lens name it picks the
  shortest model name in the list.
- **Failure modes:**
  - New bodies aren't in the database, so there's no mount and no crop factor.
  - The database is tuned to exiv2's lens names, but Redlamp reads names through LibRaw (`rl_lens`
    in `vendor/shims/redlamp_libraw.h`), and the strings can differ.
  - Third-party lenses may report a native lens-type ID that collides with a first-party lens.
  - Adapted lenses aren't found without an explicit adapter entry (`lensfun-add-adapter`, per the
    dtdocs lens-correction page), and manual lenses report nothing.
  - APS-C crop mode on a full-frame body changes the crop factor.
  - Many bodies don't record focus distance; darktable defaults it to 1000 m.

**Evidence: calibration and updates**

- Calibration (`docs/calibration_tutorial/lens_calibration_tutorial.rst`,
  `tools/calibrate/calibrate.py`): distortion is fitted in Hugin (ptlens a, b, c) from shots of
  straight lines at several focal lengths, and TCA with Hugin's `tca_correct` on high-contrast edges
  shot from 8 m or more. Vignetting is shot through a diffuser flush with the lens at five apertures
  (and five focal lengths for zooms), focused at infinity. Users can instead upload raws to the
  calibration service at wilson.bronger.org, whose toolchain rejects CR3
  ([lensfun issue 2045](https://github.com/lensfun/lensfun/issues/2045)).
- `apps/lensfun-update-data` (**GPL-3**, Python) downloads `versions.json` and
  `version_<n>.tar.bz2`. Live now:
  [lensfun.github.io/db/versions.json](https://lensfun.github.io/db/versions.json) returns
  timestamp 1790258417 (2026-09-24) with versions 0, 1 and 2.

**Assessment**

- The data is good for distortion and uneven for TCA and vignetting. Its main weakness is name
  matching, which Redlamp can improve:
  - derive the crop factor from EXIF (35mm-equivalent focal length ÷ focal length) instead of
    requiring the camera in the database;
  - keep our own MPL-licensed alias table from LibRaw lens names and IDs to lensfun names;
  - always show the match and let the user override it, like Lightroom's Make/Model/Profile menus.
- **Interpolate evaluated curves, not coefficients.** Evaluating each calibration's radial curve
  on a grid and interpolating the curve samples across focal length is model-agnostic. It avoids
  odd results when neighbouring entries use different models or poorly conditioned bases.
- **Ship a snapshot and update it with app releases.** An optional in-app refresh from
  `version_2.tar.bz2` is allowed (it's data, not code) but isn't needed for 1.0.
- **Skip the calibration assistant for 1.0.** An in-app assistant (straight-line target plus flat
  field) that contributes back to lensfun is a nice idea for later.

### 2.2 Adobe LCP

**Evidence**

- `apps/lensfun-convert-lcp` (GPL-3, Python) reads `stCamera:` XMP/RDF entries keyed by
  SensorFormatFactor, FocalLength, FocusDistance and ApertureValue. It reads the
  PerspectiveModel/FisheyeModel radial parameters, the red-green and blue-green chromatic models
  with their ScaleFactor, and the VignetteModel parameters, emits `acm` models, and writes them into
  the user's *personal* database, never the shipped one.
- The maintainers' page on the converter
  ([wilson.bronger.org](https://wilson.bronger.org/lensfun/lensfun-convert-lcp.html)) says anyone
  can create LCPs with Adobe's Lens Profile Creator, and that a library ships with Adobe DNG
  Converter, "but pay attention to the licence agreement associated with this software". Adobe
  profiles tend to undercorrect distortion and vignetting, newer ones carry little TCA data, and ACM
  data isn't accepted into the official database. Issue
  [#2554](https://github.com/lensfun/lensfun/issues/2554) shows the project declining to convert a
  lens maker's LCP.

**Assessment**

Implement our own LCP reader (XMP parsing plus the ACM maths) as a **user import** in Phase 2.

- LCP entries come in raw and JPEG variants, marked by the `CameraRawProfile` flag. Only raw
  profiles should apply; the lensfun converter also skips entries where the flag is false.
- Several lens makers (Viltrox, Sigma, Samyang and others) publish LCPs for their own lenses. Those
  are a legitimate import source.

### 2.3 Embedded manufacturer corrections and DNG opcodes

**Evidence: formats and maths** (`src/common/exif.cc` `_check_lens_correction_data` and
`_check_dng_opcodes`, `src/common/image.h`, `src/common/dng_opcode.c`, and the "embedded metadata"
version 2 algorithm in `src/iop/lens.cc`)

darktable turns every vendor model into at most 16 knots over normalised radius r (r = 1 at half
the diagonal), carrying a per-channel multiplier m_c(r), so the source radius is m_c(r)·r, and a
vignetting attenuation. It interpolates linearly between knots.

- **Sony**: three int16 tags in the raw SubIFD, `VignettingCorrParams` (0x7032),
  `ChromaticAberrationCorrParams` (0x7035, 2N values: red then blue) and `DistortionCorrParams`
  (0x7037). Each starts with a knot count N ≤ 16; I confirmed N = 16 and all three tags on
  `tests/fixtures/raw/_DSC0009.ARW` (A7 III). Knots sit at (i + 0.5)/(N − 1), a reverse-engineered
  spacing. Distortion m = 1 + d·2⁻¹⁴, CA multiplies R and B by 1 + c·2⁻²¹, and the pixel is divided
  by 2^(0.5 − 2^(v·2⁻¹³ − 1)).
- **Fujifilm**: MakerNote `GeometricDistortionParams`, `ChromaticAberrationParams` and
  `VignettingParams`, float arrays of knot positions then values. X-Trans IV/V use 9 knots and
  X-Trans I–III use 11 (the older CA array omits the knot at 0). Knot positions must agree across
  the arrays and scale by 1.25 in the 1.25× crop mode. The spline is over *source* radius with
  m = 1 + d/100; darktable resamples it to a destination-radius spline. CA is additive, and the
  vignetting attenuation v/100 is evaluated at the source radius.
- **OM System / Olympus**: ImageProcessing tag 0x150a (4 floats) gives
  r_in = s·r·(1 + k2·(s·r)² + k4·(s·r)⁴ + k6·(s·r)⁶). Tag 0x150c (6 floats) gives
  r_in,c = r_in·((1 + c0) + c2·r_in² + c4·r_in⁴) for R and B. There is no vignetting data.
- **Panasonic**: RW2 IFD0 tag 0x0119, 16 little-endian int16 values (layout from ExifTool and
  [trou/panasonic-rw2](https://github.com/trou/panasonic-rw2); index 7 is the enable flag). The
  model runs from distorted to undistorted, R_u = R_d + s·(a·R_d³ + b·R_d⁵ + c·R_d⁷), so darktable
  inverts it with two fixed-point iterations. Distortion only.
- **DNG**: OpcodeList3 (after demosaic) holds WarpRectilinear (opcode 1) with 1 or 3 planes, where
  m = kr0 + kr1·r² + kr2·r⁴ + kr3·r⁶, plus tangential kt0 and kt1 and an optical centre. It also
  holds FixVignetteRadial (opcode 3), where the pixel is divided by 1 + k0·r² + … + k4·r¹⁰, with a
  centre. OpcodeList2 (before demosaic) holds GainMap (opcode 9), applied in
  `src/iop/rawprepare.c`. darktable **ignores the tangential terms and both optical centres**.
- **Controls and defaults**: 0–2 fine-tune sliders (distortion, vignetting, TCA red, TCA blue) apply
  m′ = 1 + t·(m − 1). That is Lightroom's Amount (0–200). An image-scale slider with auto-scale
  removes empty borders. The method defaults to embedded metadata whenever data exists
  (`reload_defaults`). A version-1 algorithm kept for old edits squared the Sony and Fujifilm
  vignetting, which shows the formats were reverse-engineered and revised.

**Evidence: accuracy reports**

- On pixls.us, a user reports that embedded data for a Tamron 17-70 on Fujifilm is wrong at some
  focal lengths ([thread 59034](https://discuss.pixls.us/t/59034)).
- A Leica Q2 Monochrom DNG keeps its corner vignetting under "embedded metadata" until the user
  switches to lensfun (same thread). The cause isn't established; it may be vignetting stored in a
  form darktable ignores (unverified).
- Embedded Olympus support arrived after Sony, Fujifilm and DNG
  ([thread 38554](https://discuss.pixls.us/t/38554)).

**Evidence: what LibRaw gives Redlamp** (`vendor/cache/LibRaw-0.22.2`)

- **DNG opcode lists** come out raw: `imgdata.color.dng_levels.rawopcodes[0..2]` hold the length
  and bytes of lists 1–3, parsed in `src/metadata/tiff.cpp`.
- **Vendor coefficients are not decoded**, but two callbacks deliver every tag with the file
  handle positioned at its data:
  - `libraw_set_exifparser_handler` fires for every TIFF IFD entry, with the IFD index encoded
    in the high bits; Panasonic RW2 tags are tagged 0x30000 (`tiff.cpp`).
  - `libraw_set_makernotes_handler` fires for every makernote entry, with the sub-IFD "uptag"
    prefixed. For example, Olympus ImageProcessing arrives as 0x2040xxxx (`makernotes.cpp`,
    `olympus.cpp`).
- Redlamp's shim exposes only `rl_lens`. Two small additions are needed: opcode accessors and a
  C-convention callback that copies the handful of tags above.
- LibRaw's `lens` struct also carries values that help lensfun matching: LensID, LensMount,
  Adapter, FocalLengthIn35mmFormat, CurFocal, CurAp and FocusDistance.
- It hasn't been verified that the Fujifilm makernote goes through the generic callback path.
  Test it on the RAF fixture.

**Assessment**

Embedded data is the maker's own correction, matched to the exact lens, focal length and
(presumably) focus distance of each shot, including third-party lenses that talk to the body. On
Sony, Fujifilm, OM and Panasonic bodies it makes lensfun a fallback.

Because the formats are reverse-engineered, validate them against a ground truth we already have:
**the camera's own corrected JPEG**. Feature-match our render against raw plus JPEG pairs shot with
in-camera corrections on, and keep the pairs as golden tests.

Do better than darktable in three ways:

- honour the DNG optical centre and tangential terms;
- support the remaining DNG warp opcodes (verify the list against DNG 1.7);
- apply GainMap before demosaic, which phone DNGs depend on.

Canon and Nikon raws seem to carry correction flags rather than coefficients (unverified), so those
users, the largest group, still need lensfun. The ProRAW fixture (`IMG_1361.DNG`) has no opcode
lists; Apple bakes its corrections in.

### 2.4 Rotate and perspective (ashift) and Lightroom Upright

**Evidence** (`src/iop/ashift.c`, `rotate-perspective.md`)

- **Parameters:** rotation (±10° soft, ±180° hard), vertical and horizontal lens shift, shear,
  focal length (default 28 mm), crop factor, "lens dependence" (orthocorr, 0–100%), aspect adjust
  (for anamorphic lenses), lens model (generic or specific), auto-crop mode (off, largest area,
  original format), the crop box, up to 50 user-drawn lines, and a perspective quad.
- **Homography** (`_homography`): a chain of 3×3 matrices inherited from ShiftN (Marcus Hebel's
  program, credited in the source). It rotates about the centre, shears, applies a vertical "lens
  shift" (a projective term driven by exp(shift)) and a focal-length-dependent compression to
  offset the stretch, repeats both horizontally, scales the aspect, and translates so no output
  coordinate is negative. Forward and inverse matrices serve point transforms and pixel lookup.
- **Line detection** (`line_detect`): LSD runs on the downscaled preview buffer after gamma 0.45
  and conversion to grey (Shift- and Ctrl-click add contrast or edge enhancement). Segments along
  the image borders are dropped. Each line is weighted by length × width × angle precision and
  classed as vertical or horizontal if within 30° of the axis; lines of 5 px or less are ignored.
- **Outlier removal** (`ransac`): repeatedly take two random lines. Their intersection is a
  vanishing-point hypothesis, rejected if it lies inside the frame. Lines are counted as inliers
  when |V·L| < ε (normalised homogeneous point and line). The quality score mixes count, weight
  and closeness. ε self-tunes towards eliminating about 60% of lines. Because the search is random,
  the manual warns that line colours change on every click.
- **Fitting** (`model_fitness`, `nmsfit`): Nelder–Mead over the enabled parameters, bounded by
  logit transforms. The objective transforms each selected line's endpoints, forms the line
  vector, and measures its dot product with the perpendicular axis (zero when perfectly vertical
  or horizontal). Vertical and horizontal sums are combined as √(1 − (1 − v)(1 − h)).

  Fit buttons: vertical, horizontal, or both (both adds shear). Ctrl-click fits rotation only;
  Shift-click fits lens shift only.
- **Structure sources:** automatic LSD; user-drawn lines, auto-classified as vertical or
  horizontal and selectable with a brush; or a 4-corner "perspective rectangle". Right-drag
  anywhere straightens rotation, even while the module is off.
- **Auto-crop** (`crop_fitness`, `do_crop`): for a candidate centre (and, in largest-area mode,
  aspect), intersect the rectangle's diagonals with the warped image edges; the nearest hit
  bounds the area. Nelder–Mead maximises the area.
- The manual suggests correcting verticals to 80–90% for a natural look. lensfun's own
  control-point perspective correction has a parameter d that does the same thing: −1 is no
  change, 0 is full correction, +1 is 24% over-correction (`docs/manual-main.txt`).

**Assessment: a cleaner design for Redlamp**

- **Model.** H = S·K·R·K⁻¹, where:
  - K holds f in pixels = focal_mm × diag_px / (43.27 / crop) and the principal point at the
    optical centre;
  - R = R_roll·R_pitch·R_yaw;
  - S is a similarity (Scale, X/Y Offset) plus an Aspect stretch.

  This is physically meaningful (a virtual camera rotation) and needs no "lens dependence" or
  "compression" fudge. It maps directly onto Lightroom's Manual Transform: Vertical ≈ pitch,
  Horizontal ≈ yaw, Rotate = roll, plus Aspect, Scale and X/Y Offset.
- **Vanishing points to R, in closed form.** Take the vertical vanishing point v and form the 3-D
  direction d_v = K⁻¹·v. Rotate it onto the image y axis: that fixes pitch and roll (Upright
  "Vertical"). For "Full", also take the horizontal vanishing point h, orthogonalise d_h against
  d_v, and use (d_h, d_v, d_h × d_v) as the rows of R. When focal length is unknown and both
  vanishing points exist, estimate it from orthogonality: (v − c)·(h − c) = −f². Otherwise fall
  back to a 28 mm full-frame equivalent, as darktable does.
- **Modes.**
  - **Level:** roll only, from the length-weighted dominant near-horizontal and near-vertical
    angles. Apple Vision's horizon request can seed it.
  - **Vertical:** roll plus pitch.
  - **Full:** roll, pitch and yaw.
  - **Guided:** 2–4 user lines (Lightroom allows 4). Two verticals fix Vertical; adding
    horizontals fixes Full.
  - **Auto:** Full, backed off per axis toward Level when the lines are weak or the correction is
    extreme. A strength of about 0.8 on large tilts matches the manual's advice. Tune it against
    Lightroom.
  - **Beyond Lightroom, a 4-corner mode:** a direct 8-DOF quad-to-rectangle homography, with the
    aspect ratio taken from K.
- **Refinement.** A few Levenberg–Marquardt steps on length-weighted angular residuals, instead of
  Nelder–Mead over bounded parameters.
- **Deterministic RANSAC.** Use a fixed seed, or J-Linkage-style vanishing-point clustering, so
  pressing Auto twice gives the same answer.
- **Detector.** Run on a lens-corrected proxy of about 1 MP, on the CPU. Candidates are our own LSD
  written from the IPOL paper, or a Canny-plus-segment-fitting detector (MPS provides GPU Canny).
  Store the detected lines in the sidecar (darktable keeps drawn lines in its parameters) so the
  result is reproducible.
- **Constrain Crop.** Forward-map the source boundary, sampling each edge because lens correction
  curves it, and find the largest axis-aligned rectangle of the required aspect inside it. For a
  convex region with fixed aspect this is a linear program in (centre x, centre y, width): each
  corner lies inside each edge. Lens-corrected boundaries can be slightly concave, so fall back to
  bisecting the scale with an exact containment test.

### 2.5 Crop, orientation, liquify, scaling

**Evidence**

- **`src/iop/crop.c`:** normalised margins (left, top, right, bottom) plus an aspect ratio stored as
  numerator/denominator. It sits late in the pipe (after exposure) so retouch can still use the
  full image. The aspect menu offers freehand, original, square, golden cut, typed "x:y" ratios,
  and custom ratios via `darktablerc`, with an orientation toggle and Shift to keep the ratio in
  freehand. In-camera aspect ratios from Canon and Olympus raws auto-enable the crop
  (`crop.md`).
- **Guides** are a global darkroom overlay (`src/gui/guides.c`): grid, thirds, diagonal,
  triangles, golden sections and spiral, and more. **`clipping.c`**, the old crop and rotate with
  keystone, is deprecated.
- **`flip.c`** (orientation) sits after rotate and perspective. EXIF orientation is its default,
  and the crop survives orientation changes.
- **`liquify.c`** warps with points, lines and Bézier curves (up to 100 nodes, feathered) through
  a global distortion map and an approximate inverse. **`finalscale.c`** is a hidden module that
  downscales to export size just before output colour. `scalepixels` and `rotatepixels` handle
  non-square-pixel and 45°-rotated sensors.
- **Pipe order** (`src/common/iop_order.c`, `v50_order`): rawprepare with gain maps (1), raw CA
  (6), demosaic (9), denoise (11), **lens** (15), cacorrectrgb (16), **ashift** (18), **flip**
  (19), **liquify** (23), retouch (25), exposure (26), **crop** (30), input colour (34), defringe
  (45), sharpen (49), creative vignette (88), finalscale (90). Geometry corrections come after
  demosaic and denoise, on linear scene-referred RGB.
- **Masks.** Shapes are stored normalised to the pipe's input image (`src/develop/masks/circle.c`
  divides by `iwidth`). Drawing back-transforms screen points through *all* distorting modules
  (`dt_dev_distort_backtransform`). Rendering forward-transforms the shape's border points through
  every distorting module up to and including the masked module (`DT_DEV_TRANSFORM_DIR_BACK_INCL`),
  and raster masks pass through each module's `distort_mask`. Every distorting module must implement
  `distort_transform`, `distort_backtransform` and `distort_mask`; lens correction inverts
  analytically via its spline, liquify through an approximate inverse map. The consequence: a circle
  drawn after a strong perspective correction is a circle in *input* space, so it renders as a
  skewed blob.

**Assessment**

- **Geometry order for Redlamp.** As an inverse map from an output pixel: crop (with the crop
  angle), then the Transform homography (Upright plus manual sliders), then user orientation
  (rotate 90°, flip), then lens correction per channel, then a sample in source space. Putting user
  orientation *before* Transform does better than darktable, where ashift runs before flip and has
  to compensate; "Vertical" then always means the displayed vertical. Evaluate vignetting gain and
  raster masks at the source coordinate. Neighbourhood filters (denoise, sharpening, perhaps the
  Clarity, Texture and Dehaze bases) can also live in source space, so geometry edits never
  invalidate their caches.
- **Analytic masks.** Store the anchors in source space. For each render, map the anchors forward
  and build the ellipse or line in "corrected, pre-crop" space. Handles need the forward map;
  dragging needs the inverse. The lens inverse comes from a tabulated inversion of the monotonic
  radial function, and the homography inverse is exact.
- **Post-crop vignette must follow the crop rectangle.** Redlamp's existing Effects vignette is
  full-frame today because there is no crop yet.
- **Crop UI:** Lightroom's. Aspect presets and Lock, `X` to swap, `O` / `⇧O` to cycle overlays and
  their orientation, an Angle slider plus a Straighten tool, Auto straighten (the Level solver),
  and Constrain to Image. Keep Crop Angle and Transform Rotate as separate parameters, as
  Lightroom does.
- **Export scaling:** render at full resolution and downscale at the end in linear light.
  Interactive renders use the pyramid, with the level of detail taken from the warp's Jacobian
  (Metal gradient sampling).
- **Skip liquify** (not in Lightroom, expensive). **Skip `scalepixels`/`rotatepixels`**; LibRaw's
  pixel aspect covers the rare sensors that need them.

### 2.6 Chromatic aberration

**Evidence**

- **`src/iop/cacorrect.c`** works on the raw CFA and only on Bayer sensors. It is credited to Emil
  Martinec (RawTherapee), with speed-ups by Ingo Weyrich. It estimates the R and B shift against G
  per tile, fits an order-4 2-D polynomial to the shift field, and resamples. The manual warns that
  combining it with lensfun TCA over-corrects.
- **`cacorrectrgb.c`** runs after demosaic, on any sensor. It models each non-guide channel as a
  guide-dependent ratio of the guide channel (G by default), using two "manifolds": local
  log-ratio averages over pixels above and below the local guide mean. It blends them per pixel,
  so it fixes channel misalignment *and* channel blur (header comment). Parameters: radius,
  strength, darken/brighten-only, and "very large CA".
- **`defringe.c`**, an edge-gated chroma replacement also from RawTherapee, is deprecated in favour
  of cacorrectrgb.

**Assessment**

- Profile and embedded TCA come free in the unified warp, at the cost of three pyramid samples per
  pixel.
- For Lightroom's automatic "Remove Chromatic Aberration", estimate R/G and B/G radial scale (plus
  a centre offset) by block-matching edges on a proxy, feed the result into the same per-channel
  tables, and cache it per image. Applying that shift field to R and B *before* demosaic could
  improve demosaic quality; measure it as a Phase 3 experiment.
- Defringe should follow Lightroom: Purple and Green amount and hue range with an eyedropper,
  implemented as edge- and luminance-gated chroma suppression. A guided "auto fringe" in the style
  of cacorrectrgb can follow in Phase 3.

## 3. Mapping: darktable → Lightroom → Redlamp

| darktable | Lightroom | Redlamp plan |
| --- | --- | --- |
| lens: Lensfun database | Profile Corrections (auto lens lookup, Make/Model/Profile) | P2, data-only lensfun with our own parser and maths, alias table, EXIF-derived crop factor |
| lens: embedded metadata (Sony, Fujifilm, OM, Panasonic) | "Built-in lens profile" (verify) | **P2 (moved from P3)**, default when present |
| lens: DNG WarpRectilinear / FixVignetteRadial; rawprepare GainMap | Applied automatically | P2, full spec (centre and tangential terms), GainMap before demosaic |
| lens fine-tune (0–2) | Amount: Distortion and Vignetting (0–200) | P2 |
| lens manual vignette (strength, radius, steepness) | Manual Lens Vignetting: Amount, Midpoint | P2 |
| (none; workaround via a generic lens) | Manual Distortion | P2 (one radial term) |
| lens TCA override | (none) | P2, advanced disclosure |
| lens target geometry / "distort" mode | (none) | Skip |
| cacorrect (raw, Bayer) | Remove Chromatic Aberration | P2 as auto lateral CA in the warp; pre-demosaic variant P3 |
| cacorrectrgb | partly Defringe | P3 "auto fringe" |
| defringe (deprecated) | Defringe Purple/Green, eyedropper | P2 |
| ashift rotation and right-drag line | Transform Rotate; crop Angle and Straighten | P2 |
| ashift lens shift v/h, shear | Transform Vertical / Horizontal | P2 (camera-rotation model) |
| ashift aspect adjust | Transform Aspect | P2 |
| (none) | Transform Scale, X/Y Offset | P2 |
| ashift structure auto + fit | Upright Auto / Level / Vertical / Full | Late P2 (one detector and solver for all) |
| ashift drawn lines | Upright Guided (≤ 4 lines) with loupe | P2 |
| ashift perspective rectangle | (none) | P2, beyond Lightroom |
| ashift auto-crop | Constrain Crop | P2 |
| crop + global guides | Crop overlay, aspects, overlays `O` / `⇧O` | P2 |
| flip | Rotate 90°, Flip H/V | P2 |
| clipping (deprecated) | (none) | Skip |
| liquify | (none; Photoshop) | Skip or Later |
| finalscale | Export resize | Exists; linear-light downscale |
| vignette (creative) | Post-crop vignetting | P1 done; crop-relative in P2 |
| scalepixels / rotatepixels | (none) | Skip |
| masks via distort_transform / backtransform | Masks follow geometry | P2 decision, blocking: source-space anchors |

## 4. Licensing notes

- **lensfun library: LGPL-3.0** (`README.md`). The applications `lensfun-update-data`,
  `lensfun-convert-lcp`, `lensfun-add-adapter` and `lenstool` are **GPL-3.0**. Documentation is
  LGPL-3. Tools and tests are public domain unless their headers say otherwise.
  - Linking the library into a Redlamp App Store binary is not workable. Static linking requires
    letting users relink with a modified library. On iPhone and iPad, LGPL-3 §4(e) pulls in GPL-3
    §6 "Installation Information" for User Products, which the App Store can't satisfy. The
    library also drags in GLib.
  - **Verdict: don't link it. Reimplement from the published models.** Those are the PTLens/Hugin
    polynomials, D'Angelo's vignetting model and Adobe's camera-model PDF.
  - The README's clean-room wording conflicts with the owner's 2026-09-30 decision to allow
    reading source, and that includes lensfun's LGPL interpolation code described in 2.1. Flag
    this in the findings. When writing our version, test against lensfun's output rather than
    mirroring its structure.
- **lensfun database: CC BY-SA 3.0**, verified in `README.md` and `data/COPYING.CC_BY-SA_3.0`. The
  XML files have no per-file headers. The database grew from the PTLens database with its author's
  permission (README).
  - Shipping the database inside the app makes the app a "Collection", which CC 3.0 says is not
    an Adaptation. **The MPL code is unaffected.**
  - Converting it to a binary or JSON pack, pre-evaluating LUTs, or merging entries creates an
    **Adaptation**. It must carry CC BY-SA 3.0, or a later BY-SA version (4.0 is allowed and
    explicitly covers database rights).
  - Keep Redlamp-made profiles in a **separate file** so they aren't forced into BY-SA, unless we
    want to contribute them upstream, which we should.
  - **Attribution (§4(c)):** credit "the Lensfun project and contributors", give the title and URI
    (lensfun.github.io), link the licence, and say adapted data was converted or modified. Put this
    in About/Acknowledgements, the data file's header, and the repository.
  - **§4(a) forbids technological measures or extra terms that restrict recipients.** FairPlay
    encrypts only the executable, so ship the data as a plain bundle resource rather than compiled
    into the binary, publish the converted file in the repo, and state in the listing and licence
    notices that the data is CC BY-SA and freely available. Ask counsel about the App Store standard
    EULA versus "no additional terms".
  - **Verdict: data-only use is fine**, with attribution, a plain resource, and a published,
    BY-SA-licensed converted file.
- **Adobe LCP files** are Adobe's copyrighted content under the Camera Raw / DNG Converter licence.
  lensfun itself warns users to check that licence.
  - Reading the format for files the *user* supplies is interoperability. The format is documented
    by Adobe's camera-model PDF.
  - **Verdict:** support user import. **Never ship, bundle, convert into the shipped database, or
    host Adobe's LCPs.** Don't use `lensfun-convert-lcp` (GPL-3); write our own reader.
  - LCPs that lens makers publish themselves, or that users create in Lens Profile Creator, are
    fine to import. Their terms vary.
- **LSD in darktable** (`src/iop/ashift_lsd.c`) is the IPOL LSD 1.6 code, **AGPL-3.0** (header
  verified). Don't use it. The algorithm is published openly (IPOL 2012,
  DOI 10.5201/ipol.2012.gjmr-lsd). No patent is known, but that is unverified.
  - OpenCV's `lsd.cpp` now carries the OpenCV BSD-style licence, but its history is contested and
    it's being moved to opencv_contrib ([PR 29349](https://github.com/opencv/opencv/pull/29349)).
    Prefer our own.
  - `ashift_nmsimplex.c` (Nelder–Mead, Michael Hutt) is **MIT**. It could be reused, but the
    closed-form solver doesn't need it.
- **Embedded-correction formats** are facts about file layouts. Implement them from ExifTool's tag
  tables, DNG spec 1.7 and our own fixture measurements. darktable's `exif.cc`/`lens.cc` are GPL
  and are cited only for understanding. We don't use exiv2, which is GPL; we use LibRaw callbacks
  under CDDL.

## 5. Open questions

1. **Canon and Nikon.** Do CR3 or Nikon Z NEF makernotes contain decodable distortion or vignetting
   coefficients, or only on/off flags? This decides how much Canon and Nikon users depend on
   lensfun. Check ExifTool's Canon and Nikon tables and our fixtures.
2. **Lightroom's mask space.** How do Lightroom masks behave when Upright or Lens Corrections change
   after masking, and in which space are `crs:Crop*` and mask coordinates stored? Needed for Phase 4
   XMP import and to decide the analytic-mask evaluation space.
3. **Lightroom's built-in profiles.** Does Lightroom force the built-in profile on Micro Four Thirds
   and Fujifilm, with distortion not switchable? Should Redlamp let users turn embedded distortion
   off?
4. **Embedded accuracy.** How accurate is embedded data against lensfun and against the camera
   JPEG, per vendor? Build the raw-versus-JPEG golden test and measure Sony, Fujifilm, OM and
   Panasonic, including third-party lenses (the Tamron 17-70 Fujifilm report).
5. **Fujifilm on LibRaw.** Do Fujifilm makernote tags arrive through LibRaw's generic makernote
   callback, and what exactly are the tag IDs?
6. **Filters and geometry.** Should Clarity, Texture and Dehaze bases be computed in source space
   (cheap geometry edits) or output space (filter radii stay isotropic under strong Upright)?
   Prototype both on a strong keystone image.
7. **Remaining decisions.**
   - When geometry exposes empty areas, fill with transparency or grey, and should export
     constrain the crop by default?
   - Tune Auto's back-off against Lightroom on about 50 architectural images.
   - Update the database only with app releases, or add an in-app refresh? Track the format 2
     schema, since darktable's 0.3.x format is legacy.
