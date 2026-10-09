# What Redlamp Can Learn from RAWmakase

**Date:** 7 October 2026. **Subject:** RAWmakase v0.2.0 (`main` at `cfe010d`, 7 October 2026), the LibRaw commit its releases ship (master at `4f01440`, 2 October 2026), its documentation, release notes and issues.
**Decisions and status:** on 7 October 2026 the owner accepted the slider work (UX-28, UX-29) and asked for the study's other lessons as Proposed rows in the [research intake tracker](research-tracker.md), for a decision later ([section 8](#8-decisions-and-tracker-rows)). On 9 October 2026 the owner chose to move LibRaw to master's head (`7bfffe2`), and CAM-13 is done.

RAWmakase is an open-source raw editor by Piotr Chmolowski, written in Rust, for macOS, Linux and Windows. It was started on 26 September 2026 and shipped 17 releases in its first eleven days; on 7 October it had 249 stars, 1,327 commits and 296 pull requests, almost all from agent branches. Its aim is "close, not exact, Lightroom parity": Lightroom Classic's Develop module rebuilt control by control, its responses fitted to Camera Raw's renders, with a way in for a Lightroom user's catalog, presets and profiles. This study asked how it compares with Redlamp, what it does differently or better, how it uses LibRaw, and what Redlamp should take from it.

## How this was done

- RAWmakase was read from a clone at `cfe010d` in `build/oss/rawmakase` (gitignored), with its documentation, release notes and issues on GitHub. It is MIT-licensed, so its source may be read and, with attribution, adapted; none was copied into Redlamp.
- LibRaw's master branch, its 0.22.2 tag and pull request [#826](https://github.com/LibRaw/LibRaw/pull/826) were read on GitHub on 7 October 2026.
- Nothing was run: RAWmakase wasn't built or installed. Its figures come from its own documents, on an Apple M1 Pro; Redlamp's come from its README, on an M1 Ultra, so speeds compare only roughly.
- Licences were read from GitHub's licence API and the repository's `licenses/` folder on 7 October 2026.
- Redlamp's side was checked against the README, the tracker and the code on 7 October 2026.

## Contents

1. [Executive summary](#1-executive-summary)
2. [RAWmakase at a glance](#2-rawmakase-at-a-glance)
3. [How RAWmakase chases Lightroom](#3-how-rawmakase-chases-lightroom)
4. [Compared with Redlamp](#4-compared-with-redlamp)
5. [What to adopt](#5-what-to-adopt)
6. [What not to follow](#6-what-not-to-follow)
7. [Licensing](#7-licensing)
8. [Decisions and tracker rows](#8-decisions-and-tracker-rows)

---

## 1. Executive summary

**RAWmakase's lesson for Redlamp is in the details of the Develop module, and in measuring Lightroom rather than guessing it.** Its raw processing is simpler than Redlamp's, it works and exports in sRGB, it has no AI tools and no accessibility support. What it does better is the last few per cent of Lightroom Classic's interface: numbers you can drag as well as type, a switch on each panel, Before/After with Copy and Swap, the pixel's values under the histogram, and a way in for everything a Lightroom user already has. It also shows the way to EDT-11's unfinished half: slider responses fitted to Camera Raw's renders of synthetic charts, checked in CI.

**Lessons, in priority order:**

| # | Lesson | Verdict | Phase |
| --- | --- | --- | --- |
| 1 | **A value on every control, and numbers that read as fields and scrub.** Redlamp's slider rows already take typed values with arithmetic (UX-01); seven other controls show no value or can't be typed into, and no number shows it's editable or can be dragged | Adopt | P2 |
| 2 | **Pin LibRaw master `4f01440` for CAM-13 now,** as RAWmakase's releases do: it opens the Sony A7 V and the A1 II's compressed files, and needn't wait for Nikon's High Efficiency decoder (CAM-12), which isn't merged | Adopt | P2 |
| 3 | **A Lightroom parity corpus for EDT-11:** synthetic chart DNGs of an invented camera, rendered by Camera Raw, reduced to patch means; conversions fitted to them, and a CI check that fails when one drifts | Do better | P2–P3 |
| 4 | **Import a Lightroom Classic catalog,** read-only: develop settings through EDT-11's converter, ratings, flags and labels | Adopt | P4 |
| 5 | **Lightroom's panel on/off switches,** each a History step saved with the edit | Adopt | P2 |
| 6 | **Before/After as Lightroom has it:** left/right or top/bottom by choice, Copy Before's and After's settings, Swap | Adopt | P2 |
| 7 | **The pixel's R, G and B under the histogram,** and a clipping preview while the pointer is over a triangle | Adopt | P2 |
| 8 | **The embedded JPEG while a slow raw opens,** labelled as a preview, instead of a spinner | Adopt | P2 |
| 9 | **Save a recipe as a Lightroom preset,** with EDT-11's report in reverse | Adopt | P3 |
| 10 | **Match Total Exposures** | Adopt | P2 |
| 11 | **MIDI controllers** through Core MIDI | Adopt | P4 |
| 12 | **Rows for Lightroom features planned without one:** Reference View, the Targeted Adjustment Tool, watermarks | Adopt | P2, P4 |
| 13 | **VoiceOver for slider rows,** found while auditing them: they carry identifiers but no role, value or actions | Build | P4 |

**What Redlamp already does better, and should keep:** edits that render the same in every release, against recorded references (applying a preset in RAWmakase can move an old edit to a newer engine); a linear Rec. 2020 working space with sRGB or Display P3 output at up to 16 bits; a stronger demosaic; the whole pipeline on the GPU, at 0.6–3 ms per interactive render at Fit; AI masks and Generative Remove; no telemetry; typed arithmetic in value fields; and AppKit's accessibility for every standard control.

---

## 2. RAWmakase at a glance

| | RAWmakase | Redlamp |
| --- | --- | --- |
| Licence | MIT; two Adobe DNG SDK tables under the SDK's licence | MPL-2.0 |
| Platforms | macOS 15 (Apple Silicon and Intel), Linux (DEB, RPM, Arch), Windows 10 | macOS 26 on Apple Silicon; iPad and iPhone in Phase 5 |
| Stack | Rust, egui (eframe 0.36.2), wgpu 30 on Metal, Vulkan or DirectX 12 | Swift, AppKit and Metal |
| Raw decoding | LibRaw (master `4f01440` in releases) to unpack; its own demosaic; Little CMS | LibRaw 0.22.2 to unpack, in a sandboxed service; Redlamp's own demosaic and colour |
| Colour | LibRaw's Adobe-derived matrix as a D50 forward matrix, with the DNG SDK's ACR3 tone curve; the photographer's own DCPs | Linear Rec. 2020 from camera RGB; Redlamp's own looks; DNG profiles (CAM-04, TON-09) |
| Output | JPEG (8-bit) or TIFF (16-bit), sRGB only | JPEG, HEIC, AVIF, PNG or TIFF, at 8, 10 or 16 bits, sRGB or Display P3 |
| Where edits live | A SQLite catalog (`.rawmakase`), with previews in a second database | A `.redlamp` package beside each photo |
| Old edits after an update | An engine number (2, 3 or 4) and a model flag per operator; Calibration › Process › Update moves an edit on | Never change: each process version renders as it did, checked against recorded references |
| GPU | Previews' colour and tone stage; exports on the CPU | Every stage, previews and exports |
| Preview speed | 11–17 ms per change at Fit on the GPU, 95–166 ms on the CPU (M1 Pro) | 0.6–3 ms per change at Fit (M1 Ultra) |
| AI | None yet; masks and removal are "coming soon" | Vision, SAM 2.1 and 3, Depth Anything, FLUX.2 Generative Remove |
| Library | A catalog: grid, filters, collections, keywords, Survey, Compare, metadata | A working set of folders with ratings, flags and labels; a catalog is Later |
| Accessibility | None: eframe is built without AccessKit | AppKit's; custom slider rows carry identifiers only |
| Telemetry | An opt-in weekly report that shows its exact contents | None |
| Cadence and reach | 17 releases from 26 September to 6 October 2026; 249 stars, 31 issues, 296 pull requests | — |

---

## 3. How RAWmakase chases Lightroom

### 3.1 Responses fitted to Camera Raw

Nearly every Develop control in RAWmakase's current engine was fitted to Camera Raw's output, not designed from a description. Camera Raw 18.6 and 18.7, driven from Photoshop by scripts in `scripts/corpus/`, render the same inputs with each setting; RAWmakase renders them too and its operator is fitted until the two agree. The fitted results ship as tables in the source: colour grading curves from about 740 Camera Raw renders (`color_grade_curves.bin`), the parametric curve from about 380, the Color Mixer from a 1,728-colour chart at 60 settings, and models for Clarity, Texture, sharpening, colour noise reduction, vignettes, grain, Point Color and calibration. Auto Tone is fitted to 452 Auto Settings steps in 439 photos of the author's own Lightroom catalog, and Auto white balance to 133 photos.

`docs/parity-gaps.md` keeps the result honest: each control's distance from Camera Raw, and what isn't measured. On the synthetic chart, the default render is a mean ΔE2000 0.66 from Camera Raw's (0.91 before out-of-gamut colours were clipped per channel, as Camera Raw clips them); single Color Mixer bands sit at 0.64–1.31 and colour grading at 0.56–1.43. The worst are Highlights at +100 (8.66) and Dehaze at ±100. On real photos, Lightroom's X100F exports and Camera Raw's A7 II renders differ from RAWmakase's by a mean of 0.009 and 0.0065 (encoded sRGB, 0 to 1).

### 3.2 The chart corpus and its check

The inputs are synthetic: 970 × 742 mosaic DNGs (`tests/corpus/charts/`) with a grey ramp from −8 to +3.5 EV, 24 hues at three lightnesses and chromas, a ColorChecker, skin tones and near-neutrals. Most are of an invented camera with its own matrices ("no manufacturer or Adobe data"), the rest one per camera from LibRaw's matrix. `cases.json` holds about 360 settings cases as Camera Raw XMP attributes. Camera Raw's renders are reduced to patch means (`tests/corpus/camera-raw/*.json`) and `baseline.json` records RAWmakase's accepted distance per case.

Every `cargo test` renders the charts on the CPU and fails when a patch moves more than ΔE2000 0.5 against its snapshot, or when a case moves further from Camera Raw than its baseline (mean +0.1, 95th percentile +0.3). Raising a baseline is a reviewed decision: "accepting a larger distance should be a decision, not a side effect." A private tier, outside the repository, adds 1,305 photo references. The corpus's own README lists what it doesn't cover: the tolerances are guesses, the GPU preview path isn't checked, and content-adaptive controls (Shadows, Highlights, Dehaze, Clarity) say little on flat patches.

### 3.3 Lightroom's data, in

- **Catalogs.** Catalog › Import Lightroom catalog takes a snapshot of a closed `.lrcat` under 2 GB and imports, in one transaction: folders, photos and virtual copies, ratings, flags, colour labels, collections, keywords, descriptive metadata, each photo's develop settings and its history steps. A byte-exact copy of the source catalog is kept inside RAWmakase's, so nothing it doesn't read yet is lost. Develop settings convert through the same XMP path as presets; masks and spots convert, AI and colour range masks are reported and left out. It was checked on an 8,115-photo catalog, every rating, flag and label compared with the source. "No Lightroom file or RAW is modified."
- **Presets and curves.** Lightroom XMP presets import into a library of their own (the author's archive held 921); 26 MIT-licensed presets ship with the app.
- **Profiles and lenses.** DCP and Adobe XMP look profiles, and LCP lens profiles, import from files the photographer chooses. On a Mac or PC, the Profile menu looks in Camera Raw's profile folder for the current camera and offers to import what it finds. No Adobe file is bundled.
- **What it never does:** write XMP sidecars, or write to a Lightroom catalog.

### 3.4 Lightroom's data, out

Settings › New Develop Preset writes an XMP preset "laid out as Lightroom writes presets", so Lightroom and Camera Raw can read it (checked with ExifTool, not yet in Lightroom). Exports carry the edit as `crs:` settings, as Lightroom's exports do. Saved tone curves are XMP files in Lightroom's layout.

---

## 4. Compared with Redlamp

### 4.1 Raws, LibRaw and cameras

**Both use LibRaw the same way: to unpack the sensor data, and nothing after it.** RAWmakase's C++ shim (`native/raw.cpp`) copies the mosaic out of LibRaw with its black levels subtracted, and RAWmakase demosaics it; LibRaw's own development (`dcraw_process`) remains for half-size drafts, for layouts its demosaic doesn't handle, and as a choice in Preferences.

| | RAWmakase | Redlamp |
| --- | --- | --- |
| LibRaw | Master `4f01440` (2 October 2026) in release builds, which still calls itself 0.22.0; a system LibRaw 0.22 or later for source builds | 0.22.2, pinned by hash in `config/vendored-libs.json`; a commit can be pinned by its SHA |
| Bayer demosaic | Hamilton–Adams green, blended by inverse gradient, then red and blue from colour differences; LibRaw's AHD as an option | Menon, Andriani and Calvagno (2007), with a dual pass where neighbours differ only by noise |
| X-Trans demosaic | The same two passes; LibRaw's one-pass Markesteijn as an option | A first-generation interpolation; Markesteijn is CAM-07, ported under CDDL (DEC-40) |
| Highlights | Clipped channels estimated from nearby unclipped ratios, neutral when there's no evidence | Clipped photosites rebuilt on the mosaic from unclipped neighbours |
| Canon's black levels | LibRaw reads 0 for the EOS R6 Mark III and PowerShot V1; RAWmakase takes the left optical-black border's median when LibRaw's is below a quarter of it | The same bug, found separately: the masked photosites the CR3 declares replace the stated levels (CAM-21) |
| Not opened | Foveon, monochrome sensors, linear DNGs | Monochrome sensors (CAM-20), High Efficiency NEFs (CAM-12), bodies newer than 0.22.2 (CAM-13) |
| Per-camera exposure | A table of 180 bodies' baseline exposure, mostly from Adobe DNG Converter's BaselineExposure plus the white-level difference, so renders aren't 0.3 EV darker than Lightroom's | A DNG's BaselineExposure; none for other raws |

**The LibRaw commit is the useful find.** LibRaw's master at `4f01440` is 106 commits ahead of the 0.22.2 tag and 58 behind it (0.22.2 was cut from a stable branch, and its fixes were applied to master separately). Its additions include Sony's ARW6 decoder and the A7 V (ILCE-7M5), the A1 II's compressed files, the Canon EOS R50 V and the Hasselblad X2D II 100C, and a run of decoder hardening, among them fixes for TALOS-2026-2330, -2331, -2358, -2359, -2363 and -2364. CAM-13 waits for LibRaw's next public snapshot, expected this autumn with Nikon's High Efficiency decoder, but that decoder ([#826](https://github.com/LibRaw/LibRaw/pull/826)) is still an open pull request, and RAWmakase shows the master commit is fit to ship on three platforms. Pinning it now, apart from CAM-12, gives the A7 V without waiting. The camera bench and the decode regression set would show what else it changes; whether it fixes the A1 II's black strip has to be checked.

**The per-camera exposure table** comes from Adobe DNG Converter's output, and stays out for the reason rawler's camera files did in the [RapidRAW study](rapidraw-findings.md#42-raws-cameras-and-colour). Whether Redlamp's default renders differ in brightness between bodies is a question for the camera bench, which compares each body with its own JPEG.

### 4.2 Colour, tone and edit stability

RAWmakase renders a raw as Camera Raw would render a DNG carrying only a colour matrix: LibRaw's matrix (the Adobe-derived coefficients) adapted to D50, the ACR3 default tone curve from the DNG SDK, and tone applied as the DNG SDK applies it. Its colour operators work in ProPhoto primaries as Camera Raw's do, and it clips to sRGB at output; there's no wide-gamut export. Redlamp keeps its own look, splits a DNG profile into calibration and a Base Look (TON-09), and keeps colours outside sRGB until the output.

On stability the two differ in kind. RAWmakase records an engine number and a model flag for each operator it has fitted (`contrast_model`, `gamut_model` and a dozen more), so an older edit keeps its earlier operators until the photographer runs Calibration › Process › Update; older releases refuse newer files rather than misreading them. But applying any preset moves an edit older than its process 3 to process 3, "so an old edit can change appearance beyond the settings applied". Redlamp's process versions keep every edit rendering as it did, and the process-stability gate checks it against recorded references.

### 4.3 The Develop interface

RAWmakase's interface is close to a copy of Lightroom Classic's, in a Lightroom-like palette of nine greys. Most of it Redlamp already has; the rest is the lesson.

| | RAWmakase | Redlamp |
| --- | --- | --- |
| Slider values | An egui `DragValue` 52 points wide: drag it to scrub, click to type; values beyond the range kept as imported | Every slider row shows its value and takes typed values with arithmetic (`x+15`), clamped as Lightroom clamps them (UX-01). No hover state, and the number can't be dragged |
| Controls without a value | None found | The 3-way Color Grading Luminance sliders and the wheels' Hue and Saturation; the tone curve's split handles and point Input and Output; Base Look Amount (shown, not typeable); mask overlay Opacity (shown, not typeable); the Refine Edge brush Size; the Luminance and Depth range stops |
| Nudging | Hover a slider and press Up or Down, Shift for ten | ⌘-scroll over a slider (UX-02); `,` and `.` choose a slider, `-` and `=` nudge it |
| Rails | Fill from zero for sliders that start at zero, else from the default with a tick; Temp, Tint and hue rails coloured | The same: fill from the origin, a tick on bipolar sliders, coloured Temp, Tint and Color Mixer rails |
| History | Each step names its value ("Exposure +0.35") | The same |
| Panel headers | Lightroom's on/off switch on eight panels, a reset button, Solo Mode | Solo Mode, the edited dot, reset from the header; no on/off switch |
| Histogram | Five drag regions; triangles toggle and preview clipping on hover; the pointer's R, G, B in Melissa RGB below | Five drag regions; triangles toggle clipping; no hover preview; the capture summary below, no readout |
| Tone curve | A readout of the point's Input and Output, typeable; the parametric regions dragged on the graph | Neither readout; region sliders and split handles |
| Before/After | Before alone, left/right, top/bottom, split; Copy Before's Settings to After, After's to Before, Swap; Before set from a History step or snapshot | Full frame, side by side (oriented automatically), a diagonal split; no Copy or Swap |
| Reference View, Targeted Adjustment Tool, Match Total Exposures, Red Eye, watermarks | All built | Reference View and the Targeted Adjustment Tool are planned in the Lightroom comparison without tracker rows; Red Eye is OTH-01; watermarks are planned without a row; Match Total Exposures appears nowhere |
| Opening a raw | The camera's embedded JPEG at once, while the raw develops | A spinner until the raw is ready |
| Status line | The render stage ("Draft • refining", "Fit • full quality"), GPU or CPU, and the time | Not needed: Fit renders are final in milliseconds |
| Masks and removal | Brush, linear, radial and range masks, Heal and Clone, all marked experimental | AI masks, content-aware Remove, Generative Remove, Remove Dust, edges solved per pixel |
| Accessibility | None | AppKit's controls; the custom slider rows have identifiers, no VoiceOver semantics |

The value field is where the two meet. Redlamp's is the more capable (arithmetic, units accepted, arrow-key stepping, a scenario that types `x+15`), but nothing about it says it can be edited, and it can't be dragged. RAWmakase's number does both: a drag scrubs it, a click types into it.

### 4.4 Interoperability and automation

| | RAWmakase | Redlamp |
| --- | --- | --- |
| Lightroom presets | Read; written in Lightroom's layout | Read, with a report of what maps (EDT-11, in progress); not written |
| Lightroom catalogs | Imported, read-only, with develop history | Not tracked |
| Lightroom sidecars | Read for metadata; never written | Import planned, never writing (EDT-12) |
| Adobe profiles | The photographer's own DCP and XMP looks, found in Camera Raw's folder | DNG profiles; the photographer's own DCPs deferred on 2 October |
| Lens profiles | The photographer's own LCP files | The same (LNS-04) |
| Agents | A local control socket (off by default, a token in an owner-only file) and an MCP server of 16 tools inside the app; every edit can name the photo, generation and revision it expects, and is refused when they've moved | An internal MCP server for look development (EXT-01); a public one and App Intents planned (EXT-02) |
| MIDI | Core MIDI on macOS: controls mapped to sliders and actions, absolute and relative encoders, a Loupedeck+ profile, following the selected mask | None |

### 4.5 Positioning

RAWmakase competes as Lightroom Classic rebuilt in the open: free, on every desktop, measured against Camera Raw, with a catalog importer as the way out of Adobe. Redlamp competes as a native Mac app that a Lightroom user already knows how to use, whose edits never change, with private AI. RAWmakase makes one gap plain: a Lightroom user can bring their whole catalog to it and to no other open editor, and Redlamp can't take even their develop settings yet. Lessons 3 and 4 address that.

---

## 5. What to adopt

### 5.1 Value fields everywhere (lesson 1)

**Every control with a value shows it and takes a typed one** (UX-28): a value beside each 3-way Color Grading Luminance slider, each wheel's Hue and Saturation readable and typeable, the tone curve's selected point (Input and Output) and split positions in a readout row, Base Look Amount, mask overlay Opacity, the Refine Edge brush Size, and the four stops of the Luminance and Depth ranges. UI-only values (Opacity, brush Size) take a value field with a spec of their own, so the parameter catalogue, the MCP server and the sidecar schema don't change.

**The number reads as a field, and scrubs** (UX-29): with the pointer over it, a faint well and the left-right cursor; a drag scrubs it in the slider's own scale (mireds for Temp), Shift for fine control as on the track, one History step per drag; a click without movement types, as today. Size S–M for both.

### 5.2 LibRaw master for CAM-13 (lesson 2)

Pin `4f01440` by its SHA in `config/vendored-libs.json`, as the raw pipeline document already allows, and run the camera bench and the decode regression set: the A7 V and the other new bodies should open, and any other moved file has to be explained. The A7 V's decoder was written to "match Adobe highlight handling", which the camera bench's comparison with the body's own JPEG will show. CAM-12 stays on its own: Nikon's High Efficiency decoder isn't in master. Size S.

### 5.3 A Lightroom parity corpus (lesson 3)

EDT-11 imports Lightroom presets today, but its "response curves fitted by rendering in both apps" wait on the owner's Lightroom renders. RAWmakase's corpus shows how to get them without photos anyone owns: synthetic chart DNGs of an invented camera, written by a script, rendered by Camera Raw or exported from Lightroom Classic with each setting, reduced to patch means. EDT-11's conversion of each Lightroom setting into Redlamp's is then fitted to those means, and a CI check fails when a conversion drifts from its recorded distance. Redlamp's sliders keep their own feel; what's fitted is the conversion, so a Lightroom preset looks the same in Redlamp. Size M, plus the owner's time to run the renders.

Whether Camera Raw's patch means may sit in the repository, as RAWmakase keeps them, is DEC-41. DEC-17 and DEC-19 let measurements of other software's output into Redlamp's tables, never their files.

### 5.4 Lightroom Classic catalog import (lesson 4)

Read a closed `.lrcat` (SQLite) without changing it, and write what it holds as Redlamp edits beside each photo: develop settings through EDT-11's converter, with its report, and ratings, flags and colour labels, which Redlamp already stores. Keywords, collections and virtual copies wait for the library track. Lightroom keeps develop settings as serialized Lua tables; RAWmakase reads them as data, never as code, which Redlamp must do too. Size L, after EDT-11.

### 5.5 Smaller Lightroom features (lessons 5 to 12)

- **Panel switches** (UX-30): the switch in the header of Tone Curve, Color Mixer, Color Grading, Detail, Lens Corrections, Transform, Effects and Calibration. Each toggle is a History step, stored with the edit in a new sidecar field that defaults to on, so existing edits render as before; a change in a switched-off panel turns it back on. Size M.
- **Before/After** (UX-31): the side-by-side's orientation by choice (`Y` left/right, `⌥Y` top/bottom, as the README's shortcut table already lists), Copy Before's Settings to After, Copy After's Settings to Before and Swap, and Before set from a History step or a snapshot. Size S.
- **Histogram** (UX-32): the R, G and B percentages of the pixel under the pointer, read from the render (not the screen), and a clipping preview while the pointer is over a triangle. Size S.
- **Opening** (UX-33): when a raw takes more than a moment to open (a large file, a slow disk), show its embedded JPEG, labelled Preview, until the develop is ready. Redlamp already decodes it for the filmstrip. Size S.
- **Lightroom presets out** (EDT-22): save a recipe as a Lightroom XMP preset, the settings that map converted back, with the same report EDT-11 gives on import. Size M.
- **Match Total Exposures** (EDT-21): set the other selected photos' Exposure so their aperture, shutter speed and ISO come out as bright as the open photo's, as one Undo step. Size S.
- **MIDI controllers** (EXT-03): Core MIDI input mapped to sliders and actions, absolute and relative encoders (64 as zero for bipolar sliders), a profile for a common controller, one History step per gesture, following the selected mask. Lightroom users drive Lightroom this way through [MIDI2LR](https://github.com/rsjaffe/MIDI2LR), a plug-in. Size M.
- **Rows for features already planned:** Reference View (UX-34, P4), the Targeted Adjustment Tool (UX-35, P2) and watermarks on export (EDT-25, P4) are in the Lightroom comparison as Planned, without a row to deliver them.

### 5.6 Smaller points

- **VoiceOver** (UX-36): slider rows as accessibility sliders, with their label, value and increment and decrement actions, as the command palette's slider bar already has. RAWmakase has nothing here; it is Redlamp's to win.
- **Target guards for EXT-02:** every mutating command names the photo, generation and revision it expects, and is refused when they've moved. It lets an agent and a person share one editor safely; it belongs in EXT-02's design.
- **Quit while work is pending:** RAWmakase routes ⌘Q, the Dock and logout through one guard that waits for exports and saves, and brings a minimised window forward to ask. Worth checking Redlamp does the same.
- **Measurement conditions:** RAWmakase's performance pages state the load average and the spread of every run, as `.cursor/rules/performance.mdc` asks of Redlamp's.
- **Opt-in usage statistics:** RAWmakase asks once, shows the exact report and sends it weekly, with no identifier. Not proposed: the README says Redlamp sends nothing about its users.

---

## 6. What not to follow

- **Adobe DNG SDK code in the app.** RAWmakase compiles the ACR3 tone table and the temperature table from the SDK's sources; Redlamp implements from the DNG specification, and the SDK's licence asks a commercial distributor to indemnify Adobe.
- **RAWmakase's fitted tables and camera exposures.** They are MIT-licensed, but derived from Camera Raw's renders and Adobe DNG Converter's output. Redlamp measures its own (5.3, under DEC-41).
- **Importing Adobe's profiles from Camera Raw's folder.** The photographer's own DCPs were deferred on 2 October; TON-09 keeps Redlamp's own look for new edits.
- **sRGB-only output,** and colours clipped to sRGB before the photographer sees them.
- **Edits that move to a newer engine when a preset is applied.**
- **Keyboard control that only works under the pointer,** and an interface without an accessibility tree.

---

## 7. Licensing

Read from GitHub's licence API and the repository's `licenses/` folder on 7 October 2026.

| Piece | Licence | Verdict for Redlamp |
| --- | --- | --- |
| RAWmakase | MIT | Could be adapted with attribution; it is Rust and egui, so its ideas carry over and its code doesn't |
| Its fitted tables (`src/develop/*.bin`, `*_data.rs`) | MIT, derived from Camera Raw's renders | Not used: Redlamp fits its own (DEC-41) |
| Its camera table (`data/cameras.toml`) | MIT, derived from Adobe DNG Converter's output | Not used |
| The ACR3 tone table and temperature table | Adobe DNG SDK licence: permissive, with notices, and indemnification for commercial distribution | Not used; Redlamp works from the DNG specification |
| LibRaw | LGPL-2.1 or CDDL-1.0 | Already Redlamp's decoder; the master commit changes nothing about its licence |
| Little CMS | MIT | Not needed: Redlamp uses ColorSync |
| Inter, Lucide | OFL-1.1, ISC | Not needed |

---

## 8. Decisions and tracker rows

**Decided by the owner on 7 October 2026:**

1. **The slider work, now** (UX-28, UX-29): a value on every control that lacks one, a field that shows it's editable, and a drag that scrubs. Nudging with Up and Down over a hovered slider stays out (UX-02's ⌘-scroll remains), and so does VoiceOver (UX-36, Proposed).
2. **The other lessons as Proposed rows,** for a decision later.

**Open:** DEC-41, whether Camera Raw's renders of Redlamp's own charts may be kept in the repository as patch means.

**Tracker rows:**

| ID | Item | Recommended | Phase | Size | Depends on |
| --- | --- | --- | --- | --- | --- |
| UX-28 | A value on every control that lacks one (accepted 7 October) | Adopt | P2 | M | UX-01 |
| UX-29 | Value fields that show they're editable and scrub when dragged (accepted 7 October) | Adopt | P2 | S | UX-01 |
| UX-30 | Panel on/off switches, saved with the edit | Adopt | P2 | M | — |
| UX-31 | Before/After: orientation by choice, Copy and Swap, Before from History or a snapshot | Adopt | P2 | S | — |
| UX-32 | The pixel's R, G and B under the histogram; clipping preview on hover | Adopt | P2 | S | — |
| UX-33 | The embedded JPEG while a slow raw opens | Adopt | P2 | S | — |
| UX-34 | Reference View | Adopt | P4 | M | — |
| UX-35 | Targeted Adjustment Tool | Adopt | P2 | M | — |
| UX-36 | VoiceOver for slider rows and value fields | Build | P4 | S | — |
| EDT-21 | Match Total Exposures | Adopt | P2 | S | EDT-08 |
| EDT-22 | Save a recipe as a Lightroom XMP preset | Adopt | P3 | M | EDT-11 |
| EDT-23 | Import a Lightroom Classic catalog, read-only | Adopt | P4 | L | EDT-11 |
| EDT-24 | A Lightroom parity corpus for EDT-11's conversions | Do better | P2–P3 | M | EDT-11, DEC-41 |
| EDT-25 | Watermarks on export | Adopt | P4 | M | — |
| EXT-03 | MIDI controllers | Adopt | P4 | M | — |

CAM-13 keeps its row, with the LibRaw master commit as its recommended route.
