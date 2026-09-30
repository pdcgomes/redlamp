# F. Architecture, performance and user experience

How darktable's pixelpipe, cache, tiling and GPU paths work; how its module API scales to about 100
modules; what Lightroom users find hard and what darktable's UX gets right; how it ships on macOS; its
scripting and MCP surfaces; and how the project tests itself. Each part says what Redlamp should
adopt, do better or skip.

Sources: darktable master of 2026-09-29 (`build/oss/darktable`, 426d8ad, 5.8 release notes), the manual
(`build/oss/dtdocs/content`), the GitHub API, discuss.pixls.us threads, and r/DarkTable threads read
through an archive API. Rules are in [`_conventions.md`](_conventions.md). No code is reproduced.
Evidence cites a path or URL, assessments are labelled, and unverified items are marked
**(unverified)**. Module catalog and masks are in [note C](C-modules-and-masking.md); sidecars, presets
and Lightroom import are in [note D](D-presets-styles-sidecars.md).

---

## 1. Summary

1. **darktable is slow interactively because of its structure, not its algorithms.** Every module
   reads and writes a full 4×float32 buffer, and a slider change re-runs everything from the changed
   module onwards. Well-configured Apple Silicon Macs report 0.1–0.6 s per exposure change, and up to
   1.8 s when misconfigured. Redlamp measures 0.6–3 ms at Fit. **Assessment:** keep the fused kernel,
   and break fusion only where a stage needs neighbouring pixels. **Do better; P1–P2.**
2. **Adopt region-of-interest (ROI) rendering before any spatial stage lands.** darktable renders only
   the viewport at display scale, plus a 20% margin, and paints a low-resolution whole-image preview
   underneath while it catches up. Redlamp renders the whole 26 MP frame at 1:1 (13 ms), which won't
   survive Clarity, noise reduction or sharpening. **Adopt; the P1 render scheduler or early P2.**
3. **Adopt a hash-chained cache per stage, but coarse.** darktable keys each module's output on the
   image, the profiles, the region and a chained hash of all upstream parameters, and it pins the input
   of the module being edited. Redlamp should do this for about five barrier stages, not 100 modules.
   **Adopt the idea, do it better; P2.**
4. **Preview must equal export, and CI must check it.** darktable's manual admits the darkroom can look
   over-sharpened compared with an export, because spatial filters run at display scale. Define every
   radius in full-resolution pixels and fail CI when Fit differs from a downscaled export.
   **Do better; P0 golden tests, enforced from P2.**
5. **Skip dual CPU/GPU paths, device tuning and automatic tile optimisation.** darktable keeps an
   OpenCL and a CPU version of modules, with per-device settings, three scheduling profiles and four
   resource levels. One user's M1 was 5× slower because of a single wrong profile. Redlamp is Metal-only
   on unified memory. Tile only for large exports on iPhone and iPad, with each stage declaring its
   overlap. **Skip; tiled export in P2.**
6. **Borrow darktable's precision and color-judgment aids, keep Lightroom's surface.** The ideas to
   borrow:
   - typing values beyond the drawn slider range, and arithmetic in the value field;
   - hover-scroll with step multipliers;
   - search with synonyms;
   - color assessment mode;
   - raw-channel clipping;
   - focus peaking.

   Skip the rest: overlapping modules, three tone mappers, two-step white balance and chorded
   shortcuts. **Adopt selectively; P2–P4.**
7. **Being native is Redlamp's biggest Mac advantage.** darktable's macOS build is unsigned, needs
   Gatekeeper overrides, doesn't auto-update, and renders in sRGB only because GTK3 on Quartz can't read
   the display's color space (pixls 58770). Redlamp gets Display P3 and EDR, per-screen ColorSync,
   native gestures, notarization, the App Store and a Photos extension. **Adopt; P1–P4.**
8. **Ship a small MCP server over the engine API.** darktable 5.8 adds `darktable-mcp`, 21 tools that let
   an AI agent read module schemas, render a parameter stack, measure statistics, and manage styles and
   ratings. Redlamp's value-type API and shared schema make this about a week of work, and it helps our
   own slider-feel calibration and look matching right away. **Adopt; P2 internal, P4 public.** End
   users get App Intents instead ([note D](D-presets-styles-sidecars.md)). Skip Lua and AppleScript.
9. **Copy darktable's integration-test layout, and run it in CI, which darktable doesn't.** Each test is
   a raw, a sidecar and a reference image, compared by ΔE2000 (max below 2.3, mean below 2.3/3) on the
   CPU and GPU paths, with a timing log. darktable's CI skips the submodule. **Adopt and do better; P0.**
10. **Study vkdt next.** vkdt is darktable's original author's GPU-only node-graph processor. He reports
    19 ms from raw to screen at full resolution. It is BSD-2-Clause, so its code can legally inform
    ours. **Follow-up research, before P2.**

---

## 2. Pixelpipe architecture and performance

### 2.1 Pipe types

**Evidence.** `src/develop/pixelpipe.h` defines export, full, preview, thumbnail and second-window
pipes, plus a "fast" modifier. The initialisers in `src/develop/pixelpipe_hb.c` size each cache
differently:

| Pipe | Input | Region | Cache lines | Memory cap |
| --- | --- | --- | --- | --- |
| Full (main view) | full raw | viewport at display scale | 64 | available RAM / 8 |
| Preview | 1440×900 float mip (1920×1200 as an option) | whole image | 12 | RAM / 32 |
| Second window | full raw | its viewport | 5 | RAM / 32 |
| Export, thumbnail | full raw or mip | whole image | 2, alternating | fixed |

The preview size comes from a fixed mip table in `src/common/mipmap_cache.c`, chosen to "fit at least a
quarter of a 6k monitor". Each on-screen pipe has its own reserved worker thread (`src/control/jobs.h`).
The manual (`darkroom/pixelpipe/the-pixelpipe-and-module-order.md`, "types of pixelpipe") describes two
more modes:

- a **cut-down pipe** that skips slow modules while crop, retouch or liquify has focus
  (`IOP_FLAGS_ALLOW_FAST_PIPE` in `src/develop/imageop.h`);
- **high-quality processing**, which runs the export pipe and downscales at the end, at a "significant
  performance degradation".

### 2.2 Region-of-interest processing

**Evidence.** Before a run, `modify_roi_out` is called from first to last module to find the output
size (crop and raw preparation change it). Then `modify_roi_in` is called from last to first to find the
input region each module needs. Spatial filters pad the region, and geometry modules map it back
through their inverse (`src/iop/iop_api.h` documents both passes). The recursion in
`_dev_pixelpipe_process_rec` requests regions going backwards and processes going forwards.

For the full pipe, `dt_dev_process_image_job` (`src/develop/develop.c`) sizes the region as the viewport
times `darkroom/ui/anticipate_move`, which defaults to 1.2 ("expand calculated area when moving
around"), centred on the zoom position. The pipe input cuts that region from the raw and resamples it
("clip and zoom").

**The cost, in the manual's words:** the ROI pipe "can mean that the image doesn't accurately reflect
the exported file, especially when using modules that rely on the properties of neighboring pixels…
the darkroom view appears over-sharpened compared to a full-sized export".

**Assessment.** ROI rendering is the most important idea to take, and its flaw can be avoided.
Specify spatial parameters in full-resolution pixels, and test that Fit, 1:1 and export agree.

### 2.3 One buffer per module, with declared color spaces

**Evidence.** Buffers are 4×32-bit float, about 300 MB per 20 MP image, and 600 MB–3 GB during
processing (`special-topics/mem-performance.md`). Modules declare their input, output and blend color
spaces from raw, Lab, RGB, LCh, HSL and JzCzhz (`iop_api.h`). The pipe converts between them as
needed, and invalidates cache lines after lossy Lab round trips (the "inspace transform" paths in
`pixelpipe_hb.c`).

**Assessment.** On Apple Silicon this design is limited by memory bandwidth. Twenty modules at 3 MP move
roughly 2 GB per slider event, 20–30 ms on an M1 before any arithmetic. The fused kernel avoids this
entirely, and a single linear Rec.2020 working space avoids the conversion cost.

### 2.4 The pixelpipe cache

**Evidence** (`src/develop/pixelpipe_cache.c`):

- **Key.** The image id, the pipe type, the detail-mask flag and the four color profiles, followed by
  the chained hash of every enabled, non-skipped module up to that position. The region, the detail
  mask's hash and any active color-picker area are added. A module's hash covers its parameters and
  blend parameters, so any upstream change makes every downstream line miss.
- **Lookup.** A hit needs a matching hash and buffer size. A matching hash with the wrong size is logged
  as a darktable bug.
- **Eviction.** Lines age on each lookup. Important lines are pinned: the input of the focused module,
  of the last history item, or of modules flagged `IOP_FLAGS_WRITE_PIPECACHE_IN`
  (`pixelpipe_hb.c`, `important_input`). That pin is why a drag re-runs only from the focused module.
- **Invalidation and trimming.** Invalidation drops every line at or after a module's position. After
  each run, invalid lines are freed and the cache is trimmed to its cap, or harder when free memory
  falls below 6 GB.
- **Recent fixes.** Three items in the 5.8 notes fix cache granularity: raster masks no longer
  invalidate on every commit; detail masks no longer discard everything from demosaic onwards; and
  demosaic's crop-and-scale step became a separate hidden module "to improve cache efficiency and UI
  responsiveness" (`RELEASE_NOTES.md`).

**Assessment.** Mirror the design: chained content hashes, size checks, a pinned input for the stage
being edited, and invalidation by position. The 5.8 fixes show that fine granularity is where the bugs
live. With about 100 cache points, every side channel has to be hashed correctly: detail masks, raster
masks, pickers and profiles. Five stages keep that manageable.

### 2.5 Scheduling and cancellation

**Evidence** (`src/develop/develop.c`, `src/views/view.c`):

- **Restart rule.** When a parameter changes during a run, the run continues if it started less than
  half of the 8-run average runtime ago. Otherwise a shutdown flag, checked between modules, stops and
  restarts it (`_inside_pipe_ui_frame`).
- **Early exit.** The pipe also exits when history, zoom or the image changes.
- **Preview underlay.** The preview pipe runs in parallel with the full pipe. The paint routine shows
  the upscaled preview whenever the full buffer doesn't cover the viewport or its scale is more than
  9% off. This is what users see during a pan: blurry, then sharp.
- **Narrow commits.** A slider move re-commits only the top history item (`dt_dev_pixelpipe_synch_top`).

**Assessment.** Redlamp should add the "let it finish if it's nearly done" rule alongside latest-wins,
once any render takes longer than a frame. Cancelling between modules is too coarse for long spatial
stages, so Redlamp's planned tile-level cancellation is the better granularity. The blurry-then-sharp
pan is acceptable only if the underlay is never more than one frame stale.

### 2.6 Tiling

**Evidence.** Each module's `tiling_callback` reports a memory factor for the CPU and GPU, a fixed
overhead, an overlap in pixels and an origin alignment (`src/develop/tiling.h`). `src/develop/tiling.c`
has a simple planner for modules whose input and output regions match, and a Nelder–Mead search for
modules that change the region. The manual says tiling "is always slower — sometimes up to 10x", is
impossible for some algorithms, and mostly happens on full-size export.

**Assessment.** Copy the declaration (memory factor, overlap, alignment) for iPhone and iPad exports.
Skip the optimiser: with one working format and five stages, the tile plan can be computed directly.

### 2.7 OpenCL, CPU fallback, and Apple Silicon

**Evidence.**

- **GPU or CPU per module.** `process_cl` is optional per module. The pipe picks the GPU or CPU per
  module from device memory, tiling ability and an estimated workload ratio (`pixelpipe_hb.c`;
  manual `mem-performance.md`).
- **Fallback.** On an OpenCL error or out-of-memory, the module falls back to its CPU code, so OpenCL
  code must never modify its input. A late error restarts the whole pipe on the CPU.
- **Tuning.** Per-device `darktablerc` lines set events, asynchronous mode, device on/off, a
  `unifraction` share of unified memory (default 0.25, with Apple Silicon named), a 600 MB headroom and
  a list of modules forced onto the CPU. Scheduling profiles and resource levels sit on top.
- **No Metal.** The tree contains no Metal code: a search finds only a Windows CMake file. On macOS
  darktable uses Apple's deprecated OpenCL, which still works on Apple Silicon (timings in 2.8). AI runs
  through ONNX Runtime's Core ML provider (`special-topics/ai/how-ai-works.md`).
- **User confusion.** Users are unsure OpenCL works at all: "Does the M4 Pro support OpenCL in
  Darktable?" (r/DarkTable 1tkonuz, May 2026).
- **CPU/GPU drift.** Integration tests carry a per-test tolerance for pixel differences between the CPU
  and GPU paths (section 7).

**Assessment.** darktable has no Mac plan if Apple removes OpenCL. Two code paths double maintenance and
create drift that needs its own tolerances. Redlamp's single Metal path is right. The idea worth keeping
is **graceful degradation**: fall back to tiles rather than fail when a large export can't allocate.

### 2.8 Latencies users report

| Source | Machine | What changed | Time |
| --- | --- | --- | --- |
| [pixls 44997](https://discuss.pixls.us/t/44997) #1 (2024) | M1 Mac mini | exposure, "very fast GPU" profile → default | 1.840 s → 0.378 s |
| same | M2 Max | same | 0.574 s → 0.225 s |
| same | M1 / M2 Max | late module (color balance), default | 0.212 s / 0.128 s |
| same, #4 | M2 Max | screen-size edit / 24 MP export | GPU 0.08 / 0.31 s; CPU 0.13 / 1.3 s |
| same, #15 and #20 | GTX 1060 | exposure drag: preview / full | 0.10–0.15 s / 0.2–0.7 s (demosaic was over half) |
| same, #12 (hanatos, vkdt) | his PC | 5792×3804, raw to screen | 19 ms |
| Redlamp README | M1 Ultra | Fit / 1:1 / export | 0.6–3 ms / ~13 ms / ~45 ms |

hanatos, who wrote darktable's original pipeline, says "there's something about the scheduling in
darktable that is so complicated that it's pretty much impossible to get good performance out of it".
Some users are happy: "DarkTable's speed is not praised enough" (r/DarkTable 1rdhgas, 2026) compares it
favourably with current Lightroom.

**Assessment.** A well-tuned darktable on Apple Silicon needs 10–40 frames per edit, and configuration
mistakes cost more than a hardware generation. A GPU-first graph (vkdt) closes most of the gap.
Redlamp's lead is real, but it was measured without spatial stages and must be re-measured once they
exist.

### 2.9 Adopt and avoid

- **Adopt:**
  - viewport ROI with a margin of about 1.2×, and a low-resolution underlay during pans;
  - chained hashes per stage, a pinned input for the edited stage, and invalidation by position;
  - the "nearly done" rule;
  - a cut-down path while crop or heal is active;
  - a per-stage moving average of runtime.
- **Avoid:**
  - a buffer per adjustment;
  - mixed color spaces between stages;
  - CPU twins of GPU code;
  - user-visible performance tuning;
  - a "high quality" toggle.

---

## 3. Module processing API, and a stage graph for Redlamp

### 3.1 How a darktable module declares its needs

**Evidence** (`src/iop/iop_api.h`). Only `name`, `default_colorspace` and `process` are required.
Everything else is optional or has a default:

- **Formats and color spaces:** input and output formats; input, output and blend color spaces.
- **Regions:** `modify_roi_in` and `modify_roi_out`.
- **Memory:** `tiling_callback` and tiled `process` variants.
- **GPU:** `process_cl`.
- **Geometry:** `distort_transform` and `distort_backtransform` for point lists, and `distort_mask`
  for raster masks.
- **Parameters:** `commit_params` turns user parameters into per-pipe data. `legacy_params` migrates
  old layouts (note D covers this). Introspection is generated from the parameter struct, so every
  field is addressable by name.
- **UI:** GUI, mouse and scroll callbacks for on-canvas tools.
- **Search and help:** `aliases` supplies search synonyms, and `description` a tooltip.
- **Flags and tags** (`src/develop/imageop.h`). Flags include: allows tiling, needs arbitrary regions,
  supports blending, one instance only, preview stays on the CPU, a *fence* other modules can't be
  moved past, allows the fast pipe, expands its input region, writes the detail or raster mask, and
  must be cached. Tags: distort, decoration, cropping, geometry.

**Masks through geometry.** When the user places a shape point, it is back-transformed through the
whole pipe into input-image coordinates. To rasterise the shape for a module, darktable
forward-transforms it through only the distorting modules before that module
(`dt_dev_distort_backtransform` and `dt_dev_distort_transform_plus` in `src/develop/masks/circle.c` and
`src/develop/develop.h`). Shapes therefore stay attached to image content when crop or lens correction
changes.

### 3.2 Why it scales, and what it costs

**Evidence.** `src/iop/` has 97 module sources, 16 of them deprecated (note C counts 74 current,
user-visible modules). 33 modules declare aliases. Module order is data (`iop_order`) that users can
change within the fences.

**Assessment.** It scales because a module only has to write `process`: the pipe handles regions, color
conversion, caching, tiling, the GPU, blending and masks generically. The costs are that every module
is a full-buffer pass, correctness depends on every module implementing the hooks consistently, and the
UI becomes what the Ansel fork calls "a pack of individual plugins" ([ansel.photos](https://ansel.photos/en/)).
Redlamp's shared schema, with panels as views over one recipe, is the right opposite choice for a
Lightroom-style UI.

### 3.3 Recommended Redlamp stage graph

Fuse everything that is per pixel. Break fusion only where a stage needs neighbours, changes geometry,
or is expensive enough to cache. Each stage declares:

- its input domain: CFA, camera-linear or working-linear;
- its region mapping in both directions, the equivalent of `modify_roi_in` and `modify_roi_out`;
- forward and inverse point maps, for geometry stages only;
- a footprint in full-resolution pixels, used as tile overlap and region padding;
- a memory factor;
- a content hash chained from upstream.

| # | Stage | Kind | Cached | Arrives |
| --- | --- | --- | --- | --- |
| 1 | Raw preparation: levels, raw denoise, hot pixels | CFA, spatial | yes | P2 classical NR, P3 AI |
| 2 | Demosaic, highlight reconstruction, CA | CFA → camera-linear | yes; feeds the pyramid | P1 done, P2 better demosaic |
| 3 | Geometry: lens, vignetting, transform, crop | resample | per region and scale | P2 |
| 4 | Spatial detail: edge-aware base/detail bands for Clarity, Texture, Dehaze and Highlights/Shadows; sharpening; noise reduction | working-linear, spatial | the bands are cached, and the amounts stay per pixel | P2 |
| 5 | Develop tail: WB, matrix, tone, color, masks, curve, effects, output | per pixel, **fused** | no | P1 done |

Design rules from darktable's experience:

- **Cache bands, not results.** If stage 4 caches detail bands, moving Clarity, even masked Clarity,
  re-runs only the fused tail. This is note C's "modulate precomputed detail bands by coverage", and it
  keeps masks analytic.
- **A quality ladder while dragging.** While a stage-4 parameter is being dragged, compute it one
  pyramid level coarser for the viewport, and refine on release or when idle, like darktable's fast
  pipe. Use the per-stage runtime average to decide.
- **Masks in pre-geometry coordinates.** Store shapes in stage-2 normalised coordinates, evaluate them
  in the tail through the geometry forward map, and draw handles through the same map. Brush and AI
  masks are stored at sensor resolution and resampled by stage 3.
- **Scale-invariant radii,** with golden tests that check them (2.2).

---

## 4. User experience

### 4.1 What Lightroom users struggle with

**Evidence:**

- **Overlapping modules.**
  - "Many modules that do the same or similar things in different ways… make a custom panel with only
    these modules" (r/DarkTable 1tia6ew, "Struggling to understand darktable as a beginner", 2026).
  - "Adding yet another mapping module next to base-curve, filmic and sigmoid. They're not solving a
    problem, they are adding algorithms" (1p7st9d, "darktable is not a free Lightroom replacement — why
    not?", 2025).
- **Scene-referred concepts.** The filmic FAQ thread runs to 222 posts
  ([pixls 20138](https://discuss.pixls.us/t/20138)). A top comment in 1p7st9d calls darktable "written
  by programmers, for color scientists".
- **Two-step white balance.** The white balance module defaults to "as shot to reference", and the real
  adaptation happens later in *color calibration* (`module-reference/processing-modules/white-balance.md`).
- **Speed for professionals.** "The results are beautiful, but the workflow feels slower, and
  deadlines don't wait" (1ona8op, a professional coming from Lightroom, 2025). The answers suggested
  styles, the quick access panel and Lua.
- **Different slider feel and look.** Sliders use soft limits and EV units, and the scene-referred
  default adds exposure. Migrants keep asking how to match Lightroom: "How to get darktable sharpness
  to match Lightroom" ([pixls 35125](https://discuss.pixls.us/t/35125), 139 posts); "Why does Darktable
  exhibit more chroma noise than Lightroom?" (1nwe86v).
- **Chorded shortcuts.** A shortcut can combine up to three presses of one key with mouse-button
  chords, modifiers and movement (`preferences-settings/shortcuts.md`). Lightroom uses single keys.
- **A catalog is required.** Even `darktable-mcp` has to import a file into a scratch library first
  (`src/mcp/README.md`). Note D covers the library.
- **Hurdles, even in simplified setups.** "The hurdles necessary to clear in order to use darktable…
  make it a non-starter for many" (a reply in [pixls 36987](https://discuss.pixls.us/t/36987), a
  "quick and simple settings" thread).
- **Active modules are hard to see.** In [pixls 56268](https://discuss.pixls.us/t/56268) ("Darktable UI
  work", 266 posts, 2026), a user's main complaint is telling which modules are switched on. That
  thread also links a slider rework pull request.
- **macOS problems.**
  - "Is handle dragging… reversed on MacOS??" (1qc0gcc)
  - "doesn't check for updates automatically?" (1q7k0dn)
  - "Macos Tahoe and windows problems!" (1nk21l7)
  - export colors that don't match Finder ([pixls 35038](https://discuss.pixls.us/t/35038))
  - a code fix for see-through dialogs on recent macOS (`src/osx/osx.mm`)

**Assessment.** Most of these follow from one decision. darktable exposes algorithms as modules, where
Lightroom exposes intents as sliders. Redlamp's schema-first design avoids them. The risk is
reintroducing them as power grows, for example by exposing several tone mappers or denoisers as
separate panels.

### 4.2 What darktable does well

**Evidence:**

- **Sliders** (`darkroom/processing-modules/module-controls.md`):
  - Click anywhere in the slider's height, including its label.
  - Hover and scroll to adjust, or use the arrow keys.
  - Right-click opens a popup whose precision grows with the pointer's distance, and which accepts
    typed values and arithmetic on the previous value "x".
  - Soft limits set the drawn range and hard limits cap typed values: exposure shows −3…+4 EV and
    accepts ±18.
  - Shift multiplies the step by 10 and Ctrl divides it by 10.
  - Double-click resets to default; Ctrl+double-click resets to the auto-applied preset.
- **Organisation:**
  - a quick access panel of widgets drawn from several modules;
  - workflow module groups, and an "active modules" group;
  - search by name, instance name and aliases: color balance rgb matches "vibrance", "saturation" and
    "color grading" (`src/iop/colorbalancergb.c`);
  - an option to keep a single module expanded.
- **Judging the image:**
  - Color assessment mode (ISO 12646 grey surround and white frame), drawn in `src/views/view.c`.
    Since 5.8 it dashes the frame where the image extends past the view.
  - A raw-overexposed indicator per sensor channel.
  - Gamut check and soft proof.
  - Focus peaking (`src/common/focus_peaking.h`), guides, and a second window.
- **Comparison:** snapshots with a movable split, and style previews in tooltips
  (`src/gui/styles_dialog.c`).
- **Input:** visual shortcut mapping (hover a control, press a key), and MIDI and game controllers.

**Assessment.** These beat Lightroom and fit its layout unchanged:

- typed values beyond the slider range;
- arithmetic in the value field;
- hover-scroll adjustment;
- search with synonyms;
- color assessment mode;
- raw clipping;
- focus peaking.

The quick access panel exists to patch module overload. Lightroom's Basic panel already fills that
role.

### 4.3 Redlamp UX principles, with a do and don't list

**Principles:**

1. **Expose intents, not algorithms.** One panel per job, with Lightroom's names. Alternative
   algorithms are a menu inside a panel, never a second panel.
2. **The UI never waits.** Every gesture changes the frame within 16 ms at some quality level, and full
   quality follows.
3. **What you see is what you export,** at every zoom, enforced by tests.
4. **Precision on demand.** Lightroom's gestures by default; typed values, expressions and step
   multipliers for users who want them.
5. **Color-judgment tools are one key away,** as view toggles rather than modules.
6. **Every control is findable** by Lightroom names, darktable names and synonyms.

**Do:**

- Accept typed values up to hard limits beyond the drawn range, and expressions such as "+0.3" and
  "x*2". **P2.**
- Adjust the hovered slider with scroll or a two-finger swipe: Shift for coarse, Option for fine.
  On iOS, use vertical-distance scrubbing, the platform idiom that matches darktable's popup. **P2.**
- A ⌘F "find adjustment" field with aliases, which jumps to and highlights the control. **P2.**
- A color assessment view mode in the `L` and `I` cycle. **P2.**
- Raw-channel clipping, distinct from display clipping, in the `J` overlay. **P2.**
- Focus peaking in culling and the loupe. **P3,** with focus stacking.
- Mark panels that have edits, with per-panel on/off like Lightroom's eye icon (the pixls 56268
  complaint). **P2.**
- Keep hover-to-preview on the main canvas. darktable's tooltip-only preview was called "not that
  useful unless the preview was shown on the main image" ([pixls 33910](https://discuss.pixls.us/t/33910)).

**Don't:**

- Add a second tone mapper, white-balance step or denoiser as separate panels.
- Add chorded shortcuts. Keep single keys from one registry, remappable in P4.
- Expose GPU or performance tuning.
- Add multiple instances of a panel. Masks cover the need.
- Add a customisable quick panel before 1.0. Revisit after usability tests.
- Let preview and export differ.

---

## 5. macOS integration and packaging

### 5.1 How darktable ships

**Evidence.**

- It is a GTK3 app, bundled with gtk-mac-bundler from MacPorts or Homebrew libraries
  (`packaging/macosx/BUILD.txt`, `3_make_hb_darktable_package.sh`, `4_make_hb_darktable_dmg.sh`).
- Signing and notarization happen only if a certificate is supplied. The Homebrew guide says "The DMG is
  not notarized… run `xattr -d com.apple.quarantine`" (`packaging/macosx/BUILD_hb.txt`).
- `Info.plist` is minimal: `org.darktable`, a viewer role for images and folders, no entitlements and
  no UTIs.
- In June 2026 a user published a signed, Display P3 build because official builds are "unsigned" and
  "limited to the sRGB color space". A tester on current macOS 26 still needed "Open Anyway"
  ([pixls 58770](https://discuss.pixls.us/t/58770)).
- There are separate arm64 and x86-64 DMGs. Apple Silicon has needed macOS 14 or later since 5.4
  (`RELEASE_NOTES.md`).
- In 2020 a core contributor described one volunteer maintaining macOS builds, "annoyed by Apple
  periodical backstabbing (no more OpenCL, use Metal…)", with GTK's macOS behaviour "already conflictual
  (font sizes, display color profiles…)" ([pixls 21290](https://discuss.pixls.us/t/21290)).

**Assessment.** It is not on the App Store and can't reasonably be: it is GPL-3.0 with hundreds of
copyright holders, is not sandboxed, and keeps its settings in `~/.config/darktable`
(`preferences-settings/config-directory.md`).

### 5.2 HiDPI, display color and gestures

**Evidence.**

- **HiDPI.** The scale factor is read from the main screen only (`dt_osx_get_ppd`, `src/osx/osx.mm`).
- **Display color.** The display profile comes from X atoms or colord (`src/common/colorspaces.c`),
  and neither exists on macOS. Forum users explain that darktable renders to sRGB and lets macOS
  convert, so colors outside sRGB clip (pixls 35038 and 58770).
- **Gestures.** Two-finger pan and pinch-to-zoom are on by default (`darkroom/ui/touchpad_gestures`,
  `src/views/darkroom.c`).
- **Other integration.** Trash, URL opening, locale, bundle paths and open-file events (`osx.mm`), plus
  a macOS theme stylesheet (`src/gui/gtk.c`).

### 5.3 What Redlamp gains by being native

- **Wide gamut and EDR.** A Metal layer in an extended linear color space, which ColorSync maps to each
  display, including external screens. EDR headroom follows for HDR in P4.
- **Trust.** Notarized App Store builds with automatic updates.
- **Sandboxing done properly.** Security-scoped bookmarks, file coordination for iCloud Drive, and the
  planned sandboxed decoder.
- **Input.** Pinch, smart zoom, rotation to straighten, momentum scrolling and Force Touch on the Mac;
  Pencil and multitouch on iPad from one engine.
- **Unified memory without OpenCL.** Zero-copy IOSurface frames, shared GPU and Core ML buffers, and no
  headroom settings.
- **System integration.** Native menus with Help-menu search, the Services menu, the Share sheet, a
  Photos extension (P2), App Intents, and possibly Quick Look and Spotlight for sidecars
  **(unverified value; P4)**.
- **Accessibility, localisation, and thermal and Low Power awareness.**

---

## 6. Scripting and extensibility

### 6.1 Lua

**Evidence.**

- darktable embeds Lua 5.4 (`lua/overview.md`).
- The bindings in `src/lua/` cover images, the database, film rolls, styles, tags, metadata,
  preferences, storage and format plug-ins, GUI widgets, guides, printing and AI.
- Scripts can react to events such as `darkroom-image-loaded`, `darkroom-image-history-changed`,
  `pixelpipe-processing-complete`, `pre-import`, `intermediate-export-image` and `shortcut`
  (`src/lua/events.c`).
- darktable can also be loaded headless as a Lua library, which the manual calls "very experimental"
  (`lua/darktable-from-lua.md`).
- A D-Bus method runs Lua in the running app (`lua/calling-from-dbus.md`).
- Community scripts come through a script manager (`src/external/lua-scripts`). Professionals use them
  to automate first steps (r/DarkTable 1ona8op).

### 6.2 `darktable-mcp`

**Evidence** (`src/mcp/README.md`, `data/mcp_tools.json`, `RELEASE_NOTES.md`). New in 5.8: a headless
stdio JSON-RPC Model Context Protocol server, a sibling of `darktable-cli` that links libdarktable.
It has 21 tools in four groups:

- **Introspection:** `list_modules`; `module_schema`, which gives field names, types, ranges, defaults,
  enum values and a manual link; and `decode_params` and `encode_params`.
- **Develop:** `render` returns a PNG. `image_stats` returns per-channel min, max, mean, p1, p50, p99
  and clip counts. Both accept a module stack placed with `before` and `after`, and an option to
  disable the default tone mapper.
- **Library:** import, list, film rolls, metadata, history, reset, rating, labels, four style tools,
  and export.
- **Configuration:** read-only. There is no `set_conf`, "because changing a setting mid-session would
  silently invalidate every result gathered before it".

Other design choices:

- `--read-only` refuses every tool that would write.
- The library defaults to in-memory, and path inputs are imported only temporarily.
- Parameters are addressed through introspection, never byte offsets.
- Tool descriptions live in JSON, so they can steer the model without a rebuild.
- All libdarktable calls sit in one bridge file (`src/mcp/dt_bridge.c`).

**A discrepancy:** the release notes say renders "run on a throwaway duplicate so the source image is
never modified", but the README says a stack given with an `imgid` "is written to the image… there is
no throwaway duplicate" **(unverified which is intended)**.

**Assessment.** Four design lessons transfer to Redlamp:

- address parameters by name through a schema;
- default to read-only, scratch state;
- give agents a statistics tool so they measure rather than guess;
- make settings a session boundary.

Redlamp's CLI already does `--set key=value` against the shared `ParameterSpec`.

### 6.3 Recommendation for Redlamp

- **`redlamp mcp`, a CLI subcommand.** Tools: `schema`, `render` (recipe and size), `stats` (histogram
  percentiles and clipping), `read_sidecar`, and `write_sidecar` (refused under `--read-only`). It works
  on sidecars, not a library. Use it internally in **P2** for agent-assisted slider-feel calibration
  against Lightroom and for look matching in `redlamp-profiler`. Make it public in **P4**, alongside
  the AI work in `docs/research/ai-findings.md`. About a week of work.
- **App Intents** for open, apply preset, rate, export, and render with a preset, surfaced through
  Shortcuts, Siri and Spotlight. **P4**, as note D also recommends.
- **Skip** Lua, AppleScript, D-Bus and third-party processing plug-ins. Plug-ins would break the stage
  graph's guarantees and complicate App Review. LUT and DCP import are the extension surface for looks.

---

## 7. Project health, camera support and regression testing

**Evidence.**

- **Cadence.** Two feature releases a year, on the solstices (21 June and 21 December since 4.2), plus
  point releases "that mostly provide bug fixes and camera support" (`README.md`, GitHub releases).
  5.6.1 is current, and master is heading for 5.8.0.
- **Scale** (GitHub API, 2026-09-30):
  - 13.2k stars and 672 open issues;
  - 364 contributor accounts, or 724 including anonymous commit identities;
  - 3,114 commits by 89 authors in the last 12 months, 60% of them by the top four (TurboGit 884,
    andriiryzhkov 348, jenshannoschwalm 342, victoryforce 327).

  The local clone is shallow, so these figures come from the API.
- **Camera support.** Decoding uses rawspeed, with LibRaw as a fallback; both are submodules
  (`.gitmodules`). The project asks users for CC0 samples on raw.pixls.us. New cameras ship in point
  releases.
- **Integration tests.** The separate [darktable-tests](https://github.com/darktable-org/darktable-tests)
  repository has about 190 numbered tests, such as `0001-exposure`, `0004-masks`, five
  orientation and flip tests, and `0014-filmic-rgb`.
  - Each test is a sidecar naming an image, plus an 8-bit `expected.png`, an optional `CONFIG` and an
    optional `test.sh`.
  - A test passes when max ΔE2000 is below 2.3 and the mean is below 2.3/3.
  - Both the CPU and OpenCL paths run, with a per-test CPU/GPU tolerance (`cpugpu.maxpix`).
  - Every run appends to a timing log, and a script flags performance regressions.
- **CI.** `.github/workflows/ci.yml` and `nightly.yml` disable the integration submodule and build a
  `skiptest` target. One Linux job runs the few unit tests (`src/tests/unittests/`: filmic, LUT
  bounds, curve drawing, HDR alignment, AI backend, MCP paths). How often the integration suite runs
  before releases is **(unverified)**.

**Lessons for Redlamp's golden tests (P0):**

1. **Copy the layout:** a directory per test with a recipe, a CC0 fixture reference, a reference image
   and optional settings, plus a filter to run one panel's tests.
2. **Tighter thresholds, deeper references.** Use ΔE2000 max and mean thresholds tighter than 2.3,
   since there is only one code path. Store references as 16-bit PNG or half-float EXR, because 8-bit
   hides drift.
3. **Run on every pull request** on Apple Silicon. Whether hosted runners give deterministic Metal
   output is **(unverified)**; if not, use a self-hosted runner.
4. **Add the gates darktable lacks:**
   - preview equals export;
   - tiled equals untiled;
   - viewport region equals the same crop of a full render;
   - per-process-version stability (note D).
5. **Add orientation and flip tests early.** They are cheap and catch mask and crop bugs once
   geometry lands.
6. **Keep a timing log per test** that feeds the planned performance lab's gates.

---

## 8. Mapping table

| darktable | Lightroom | Redlamp plan |
| --- | --- | --- |
| Full, preview and export pipes | interactive preview, export | one engine with viewport ROI and a low-resolution underlay; preview equals export (P1–P2) |
| Per-module pipe cache | internal | chained-hash cache over five stages (P2) |
| High-quality processing toggle | none | not needed; enforced by tests |
| Tiling | internal | stage overlap declarations; tiled export on iOS (P2) |
| OpenCL with CPU fallback and tuning | GPU preference | Metal only, no tuning (now) |
| Module groups, quick access panel | fixed panels, Basic | Lightroom panels (now); favourites after 1.0, maybe |
| Module search with aliases | none | ⌘F find adjustment (P2) |
| Typed values, expressions, hard limits | click to type | add expressions and beyond-range values (P2) |
| Scroll on slider with step multipliers | hover plus arrows | hover-scroll with Shift and Option (P2) |
| Snapshots with split | snapshots, before/after | have snapshots; split view (P2) |
| Color assessment mode | none | view mode (P2) |
| Raw overexposed indicator | none | raw clipping in `J` (P2) |
| Focus peaking | none | culling and loupe (P3) |
| Soft proof, gamut check | Soft Proofing | P4 |
| Second window | Secondary Display | later |
| Visual shortcut mapping, MIDI | fixed shortcuts | remappable registry (P4); controllers later |
| Lua | plug-in SDK | App Intents (P4); skip Lua |
| `darktable-mcp` | none | `redlamp mcp` (P2 internal, P4 public) |
| darktable-tests suite | none public | golden tests in CI (P0) |

---

## 9. Licensing notes

- **darktable is GPL-3.0.** Per the conventions (owner decision, 2026-09-30), it was read for
  understanding only; nothing is copied, and algorithms are described in prose.
- **Flag for the findings:** this overrides the README's clean-room wording, "if you have studied a
  GPL implementation of something, please don't write Redlamp's version of it". Update the README to
  match. The architecture observations here are general techniques: ROI propagation, hash-chained
  caches and tile overlap declarations.
- **GPL data we must not copy:** `data/mcp_tools.json` and the darktable-tests sidecars and
  references. The darktable-tests images are of unknown licence **(unverified)**; don't use them. Build
  our golden set from our own recipes on raw.pixls.us CC0 files.
- **vkdt is BSD-2-Clause** (GitHub API), which is compatible with MPL-2.0. Its code may be studied and
  adapted with attribution.
- **ISO 12646 is paywalled.** Implement its widely published summary (a neutral grey surround and a
  white frame), not the text.
- **MCP is an open specification,** so implementing a server raises no licensing issue.

---

## 10. Open questions

1. **Canvas color space.** Does the Metal canvas tag frames with an extended linear color space, so
   ColorSync handles each display? If it assumes sRGB, fix it in P1. This is exactly where darktable
   fails on the Mac.
2. **Lightroom's mask coordinates.** Does Lightroom keep local-adjustment geometry before or after lens
   correction and Transform, and what do users expect when they change Upright after drawing a
   gradient? Check before P2 geometry.
3. **Stage 4 layout.** One shared edge-aware band pyramid for Clarity, Texture, Dehaze and
   Highlights/Shadows, or separate stages? Measure at 1:1 on an iPhone-class GPU, together with note C.
4. **Quality ladder.** Is a one-level-coarser spatial stage visible during a drag? Run a blind test.
5. **CI on Metal.** Are hosted macOS arm64 runners deterministic enough for golden tests?
6. **MCP writes.** Should `redlamp mcp` write sidecars in P2, or only render and measure in-memory
   recipes?
7. **vkdt.** How does it schedule its graph, cache node outputs and handle regions? Does its 19 ms hold
   on Apple Silicon through MoltenVK? This is a candidate for the next research pass.
