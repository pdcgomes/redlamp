# D. Edit storage, presets, styles, versioning and library

How darktable stores edits (sidecars and the library database), keeps old edits rendering the same,
packages settings as presets and styles, imports Lightroom edits, and exports, with what Redlamp should
adopt, do better, or skip.

Sources: darktable master of 2026-09-29 (`build/oss/darktable`), the darktable user manual
(`build/oss/dtdocs/content`), and Redlamp's `EditRecipe.swift`, `ParameterSpec.swift`, `Sidecar.swift`,
`Presets.swift` and `Library.swift`. The source was read for understanding only; no code or darktable
data file is reproduced. Adobe's process-version page didn't load headlessly, so Lightroom
process-version details are marked **(verify)**.

---

## 1. Summary

1. **Add a process version now, before Phase 2 changes the pipeline.** *Adopt the idea, do it better; Phase 1.*
   darktable keeps old edits stable because every module versions its parameter layout, converts old
   layouts forward, and keeps old algorithms selectable through a "version" field in its parameters.
   Redlamp stores sparse values against *unversioned* defaults and one shared pipeline. Phase 2's
   edge-aware Highlights and Shadows, new demosaics and dual-illuminant DCPs would silently change every
   existing sidecar. The proposal is in section 2.6.
2. **The sidecar should be the source of truth, and any library only a cache.** *Do better; all phases.*
   darktable's SQLite library is authoritative and the XMP is a backup. That causes its sync problems:
   a startup crawler, "keep XMP or keep database" dialogs, and no multi-computer support.
3. **Fix three latent sidecar bugs darktable learned the hard way.** *Adopt; Phase 1.*
   Unknown keys are dropped on the next save, so an older Redlamp erases a newer edit (darktable has the
   same flaw). `formatVersion` is written but never read. `modified` changes on every save, while
   darktable skips rewriting a sidecar whose bytes haven't changed, which keeps sync services quiet.
4. **Keep named, sparse JSON values; don't adopt darktable's parameter blobs.** *Skip; Phase 1.*
   darktable stores raw C structs as hex or `gz`+base64. They can't be read, diffed or merged without its
   GPL module code. Redlamp's format is better; publish it as a documented schema.
5. **Presets need rules, "use this image's default" values, and an Amount slider.** *Adopt and do better; Phase 2.*
   darktable's auto-apply presets match maker, model, lens, ISO, shutter, aperture, focal length and
   format. They're applied **once**, on first open, and baked into the edit. That's the right model for
   Lightroom-style per-camera raw defaults.
6. **darktable styles are Lightroom presets under another name.** *Adopt with Lightroom naming; Phase 2.*
   A style is a multi-module bundle captured from a history. It's applied in append or overwrite mode,
   optionally onto a new duplicate, with a hover preview, and can also be applied temporarily at export.
7. **darktable's Lightroom import is a warning, not a template.** *Do better; Phases 2 and 4.*
   It maps about ten settings through hand-typed tables into mostly deprecated modules, and ignores white
   balance, the Basic tone sliders except Exposure and Blacks, Color Grading, Detail, lens, masks and
   Adobe's process version. Redlamp's sliders copy Lightroom's, so most `crs:` keys map one-to-one; it
   should read `crs:ProcessVersion` and calibrate by measurement.
8. **Persist snapshots and versions; keep history optional.** *Do better; Phase 2.*
   darktable persists the full history, but snapshots last only for the session, and duplicates are extra
   `name_NN.ext.xmp` files. Keep all versions in one sidecar and store the current recipe, not a replay.
9. **Copy/paste needs safe defaults and a remembered category picker.** *Adopt; Phase 2.*
   darktable's plain copy leaves out image-specific modules such as orientation, lens correction and white
   balance. Selective copy and paste have a per-item "reset" and an append or overwrite mode.
10. **Export at full resolution, downscale last, and embed the recipe.** *Adopt; Phases 2 and 4.*
    darktable's "high quality resampling" exists because its default export downsamples early. Its
    "develop history" option lets you recover the edit from an exported JPEG.

---

## 2. Detailed findings

### 2.1 darktable's edit model

**Evidence.** An edit is a **history stack**. Each entry records:

- the module operation name;
- the module's parameter-layout version;
- whether the module is enabled;
- the parameters, as a blob holding the module's C struct;
- the blend and mask parameters, with their own version;
- `multi_priority` and `multi_name`, which identify the instance when a module is used more than once.

`images.history_end` points at the active top. Entries above it stay stored for redo until the next
change discards them. Shapes live in `masks_history`, and the per-image pipeline order in
`module_order`, as one of legacy, v3.0, v5.0 (each with a JPEG variant) or a custom list
(`src/common/iop_order.h`).

`library.db` holds images, film rolls, history, masks, tags, labels, metadata and history hashes;
`data.db` holds presets and styles, so those are shared across libraries (schema in
`src/common/database.c`: library version 57, data version 13). Three history hashes per image, "basic"
(mandatory modules), "auto" (plus auto presets) and "current", tell a truly edited image apart from one
that was only opened (`dt_history_hash_get_status`, `src/common/history.c`).

**Assessment.** Because the current edit is a *replay* of blobs, darktable needs multi-instance
bookkeeping, order lists, `history_end` arithmetic and renumbering hacks. Redlamp's current-state recipe
is simpler and should stay authoritative. The "defaults only versus edited" distinction is worth
copying for the filmstrip badge.

### 2.2 The XMP sidecar

**Evidence** (`src/common/exif.cc`: `dt_exif_xmp_write`, `_exif_xmp_read_data`, `_set_xmp_dt_history`,
`dt_exif_xmp_read`, `dt_exif_xmp_encode`).

- **Keys.** `darktable:xmp_version` (currently 5), `history_end`, `auto_presets_applied`,
  `iop_order_version`, and `iop_order_list` (only for custom orders or multiple instances).
  `darktable:history` is an `rdf:Seq` of the entry fields above, plus `masks_history` and the three
  hashes. Standard fields go alongside: `xmp:Rating`, `xmpMM:DerivedFrom`, `exif:DateTimeOriginal`, GPS,
  `dc:subject` and `lr:hierarchicalSubject`.
- **Encoding.** Blobs are lowercase hex, or zlib+base64 prefixed with `gz` and a two-digit compression
  factor that sizes the decompression buffer. The `compress_xmp_tags` preference defaults to compressing
  entries over 100 bytes, so the history fits in a JPEG's 64 KB XMP segment on export.
- **Writing.** darktable reads the existing file, strips only its own keys (so other apps' keys
  survive), re-serializes, and **skips the write if the MD5 is unchanged**. The code comment cites NAS
  setups shared by several computers. Sidecars are written "on import" (default), "after edit" or
  "never", and the darkroom auto-saves every 10 s (`preferences-settings/storage.md`).
- **Duplicates.** `IMG.CR3.xmp` holds version 0, and `IMG_01.CR3.xmp` and so on hold the others. Each is
  its own library row with a version number and a shared group.
- **Which side wins.** The database. The manual says changes made to the XMP by other software "will be
  overwritten the next time darktable synchronizes the file". An optional "look for updated XMP files on
  startup" crawler (`src/control/crawler.c`) compares file modification times with the database's
  `write_timestamp`, allowing for clock skew. It then lets you reload or overwrite per image. Multiple
  machines are "not natively supported" and there's "no built-in functionality for resolving
  edit-conflicts" (`special-topics/multiple-computers.md`).
- **Lightroom's sidecars.** darktable also reads `IMG.xmp` (Lightroom's naming) but never writes it
  (`overview/sidecar-files/sidecar-import.md`).
- **Recovery.** Exports can embed the history, and "load sidecar file" accepts an exported JPEG.
  Embedding "may fail without notice" when size limits are exceeded.

**Assessment.**

- The blob encoding ties the format to C struct layouts and GPL code, so in practice no other tool reads
  darktable edits. Redlamp's keyed JSON is diffable, mergeable per key, and implementable clean-room,
  which is the "open recipe format" differentiator in the inventory.
- **Adopt** skip-if-unchanged writes, and update `modified` only when content changes.
- **Adopt** "never write Lightroom's `basename.xmp`" and "preserve keys you don't own".
- **Do better** on conflicts. For the Phase 1 coordinated I/O (`NSFileCoordinator`, `NSFileVersion`),
  keyed values allow a per-parameter three-way merge. Fall back to a per-photo "this Mac / other device /
  newest" choice with thumbnails of both.

### 2.3 Compressing and truncating history

**Evidence** (`history-stack.md` in the darkroom and lighttable docs; `dt_history_compress_on_image`).

- "Compress history stack" rewrites the history as the shortest stack that reproduces the image, and
  drops everything above the selected step.
- Ctrl-click truncates without compressing.
- Editing after selecting an earlier step silently discards the later steps; the manual warns "it is
  easy to lose development work".
- Hovering a step shows a per-field diff, generated from introspection.

**Assessment.** Users need compress only because the history *is* the persisted model. Redlamp should
persist history, if at all, as a capped log of labeled sparse diffs with Lightroom's "Clear History",
and copy the hover-to-see-changes tooltip.

### 2.4 Keeping old edits rendering the same

**Evidence.**

- **Layout versions and converter chains.** Each module declares
  `DT_MODULE_INTROSPECTION(version, params_type)` and may implement a legacy converter.
  `dt_iop_legacy_params` (`src/develop/imageop.c`) chains it from version *n* to *n+1* until the current
  version. About 60 of darktable's roughly 110 modules have a converter. Versions reach 12
  (`denoiseprofile`) and 7 (`exposure`, `demosaic`, `colorin`, `agx`). Blend parameters have their own
  chain. A converter may answer "auto-init", meaning "use this image's computed defaults", which is
  stored as empty parameters.
- **Presets and styles migrate too.** `_init_presets` upgrades stored presets at startup and writes
  them back; styles convert on apply.
- **Behavior is pinned inside the parameters.** When the math changes, the parameters gain a field that
  selects the algorithm, and the converter pins old edits to the old value. Examples are filmic rgb's
  color science (v3 of 2019 through v7 of 2023) and spline version, and color balance rgb's saturation
  formula, JzAzBz (2021) or darktable UCS (2022), in `src/iop/filmicrgb.c` and
  `src/iop/colorbalancergb.c`. In effect this is a per-module process version.
- **Defaults are frozen into the edit.** Since XMP version 5, every default-enabled module is written
  into the history on first open (`_dev_add_default_modules`), together with the matching auto presets
  (`_dev_auto_apply_presets`), so later changes to defaults can't alter the edit. Older files get
  special-case patches:
  - a clip-mode highlights entry is inserted into pre-v5 XMPs, because the default changed to
    "opposed";
  - old edits get legacy white-balance defaults under modern chromatic adaptation;
  - an old disabled `flip` is forced on.

  These are in `dt_exif_xmp_read` and `develop.c`.
- **Introspection.** `tools/introspection/` parses the parameter structs and their comment annotations
  (default, min, max, description). darktable uses the result to generate GUIs, show history diffs, and
  let Lua and presets address fields by name.
- **Deprecated modules** (about 16, for example `spots`, `clipping`, `levels` and `vibrance`) become
  read-only. They're hidden after about a year but "never fully removed ... in order to retain old
  edits" (`darkroom/processing-modules/deprecated.md`).
- **Where it breaks.**
  - *Newer edits in an older build.* An entry with a newer module version than the build knows gets
    **default parameters** with a log message, and the history is written back
    (`dt_dev_read_history_ext`). An older build silently destroys a newer edit, and the manual's advice
    is to run the same version on every machine.
  - *Missing modules.* Entries for modules that aren't installed are dropped.
  - *Unversioned changes.* Bug fixes, OpenCL versus CPU differences, updated camera matrices, noise
    profiles and lensfun data aren't versioned **(the code shows no pinning mechanism; not tested)**.

**Assessment.** It works (decade-old edits still open), but at high cost: every module keeps every
layout and code path forever, and the compatibility patches are scattered special cases. Take two
ideas: *pin behavior explicitly in the edit*, and *chain converters from each version to the next*.
Don't take the per-module granularity. Redlamp has one fused kernel and Lightroom's flat parameter set,
so one global **process version** is the natural unit. That's Lightroom's model: process versions 1 to
6 **(verify)**, where old versions keep rendering and updating is explicit.

### 2.5 Redlamp's recipe measured against these lessons

**Evidence.** `EditRecipe` stores the treatment, a profile (id, name, amount, content hash), the
white-balance mode, the point curve, sparse `values` and masks. On decode it ignores unknown keys,
drops values that equal the default, and clamps to the *current* `ParameterSpec` range.
`formatVersion` is never checked. `Preset` holds values plus an optional treatment, profile and curve,
with no amount, masks, rules or "included settings".

**Gaps.**

1. Missing keys mean "today's default", so changing a default (for example `sharpenAmount` 40)
   rewrites old edits.
2. Clamping against today's range rewrites old values if a range narrows.
3. Phase 2 changes to Highlights and Shadows, the demosaic, color and the tone map aren't versioned.
4. Unknown keys are lost when an older build saves.
5. `.auto` white balance and profile ids must resolve the same way forever, or their result must be
   stored.

### 2.6 Recommended process-version strategy for Redlamp

1. **Keep two numbers apart.** `format` covers syntax (key names, structure) and is migrated silently
   and losslessly on read. `processVersion` covers meaning and rendering and is **never migrated
   silently**.
2. **Stamp a PV on every recipe, snapshot, version and preset**, starting now with PV 1. A missing
   field means PV 1. New photos get the current PV; existing ones keep theirs.
3. **Make defaults, ranges and parameter availability a function of PV.** `ParameterCatalog` becomes
   "the catalog for PV *n*", and a missing key means that PV's default. Parameters introduced by a PV
   are disabled under older ones, as Lightroom hides Texture under old process versions **(verify)**.
4. **Keep old engine behavior at no runtime cost.** Specialize the fused Metal kernel with function
   constants (one pipeline state per PV). Code outside the kernel (demosaic, camera color model, auto
   analyses) switches on PV. This is filmic's color-science field applied to the whole pipeline.
5. **Updating is explicit.** An "Update to current process" control in Calibration, with before/after,
   a batch option and one undo step, runs a chain of pure Swift converters (PV *n* to *n+1*) that remap
   values to keep the look close.
6. **Materialize anything that depends on the image or an algorithm.** Raw-defaults rules, Auto Tone,
   Auto WB and AI masks write their resolved values into the recipe, with provenance (for example "Auto
   WB, PV 1"). Rendering must never depend on re-running an analysis.
7. **Handle newer files safely.** Write a `minimumReaderFormat`. A build that sees a newer format or an
   unknown PV opens the photo read-only with a banner and never overwrites it. Always round-trip
   unknown keys.
8. **Set a bug-fix policy.** A fix that moves PV *n* output beyond a ΔE2000 tolerance ships only if the
   old output was clearly broken, and is noted in the release notes. Anything else needs a new PV.
9. **Enforce it in CI.** Make the planned golden-image tests a per-PV corpus of recipes and reference
   renders that is never regenerated for a shipped PV.
10. **Bump rarely.** Land PV 2 once, with the Phase 2 pipeline. Version built-in profile ids (for example
    `redlamp.color.v1`) so a retuned look gets a new id; imported profiles already pin `contentHash`.

**Roadmap impact.** Move "Process version selector [P2]" to **Phase 1** as "stamp PV 1, the format and
reader versions, round-trip unknown keys, freeze a golden corpus". It's cheap now and very expensive
after Phase 2 ships.

### 2.7 Presets

**Evidence** (`darkroom/processing-modules/presets.md`, `preferences-settings/presets.md`,
`src/gui/presets.h`, `src/common/presets.c`, `_dev_auto_apply_presets`).

- **Scope.** A preset belongs to one module and stores all of its parameters plus its enabled state, so
  a disabled preset works as an on-demand default.
- **Rules.** Presets can be auto-applied or auto-shown for matching images: maker, model and lens
  patterns (with `%` as the wildcard); ISO, exposure, aperture and focal-length ranges; and a format
  mask (LDR, raw, HDR, not-mono, not-color, matrix).
- **Auto-apply.** Rules are evaluated in SQL once per history, on first open, and the results are
  prepended to the history. User presets beat built-ins, and longer (more specific) patterns sort
  first. Several matches for one module create several instances, and an `ioporder` preset can set the
  pipeline order.
- **The "workflow" preference** (scene-referred with filmic, sigmoid or AgX; display-referred; or none)
  works through write-protected built-in auto presets, for example exposure's "scene-referred default"
  (`src/iop/exposure.c`).
- **"Reset all module parameters"** stores empty parameters, so values are computed from the image at
  apply time.
- **Storage.** Presets live in `data.presets` and export as `.dtpreset` XML (the encoded parameters,
  the op version and the rule fields). `|` in a name creates a hierarchy, and a user preset shadows a
  built-in with the same name.
- **Where users struggle.** Auto presets apply only on first open, so overwrite-pasting onto a
  never-opened image "may seem" not to duplicate the history. Auto-naming of modules sticks. Shadowed
  built-ins are confusing.

**Compared with Lightroom.** Lightroom develop presets are partial settings across panels (darktable
styles), with groups, favorites, hover preview and Amount. They are XMP files with `crs:` settings plus
metadata such as `crs:Group`, `SupportsAmount`, `SupportsColor`, `SupportsMonochrome`, HDR and SDR
flags, and `CameraModelRestriction` **(verify)**. Adaptive presets add AI masks. Raw defaults (Adobe
Default, Camera Settings, or a preset per model, serial number and ISO) apply at import **(verify)**.
darktable's rules are richer; Lightroom's UX is simpler.

**Recommendations.**

- **Adopt** darktable's rule set for Raw Defaults (Phase 2): maker, model, serial number, lens, ISO,
  shutter, aperture, focal length, and raw, non-raw, HDR or monochrome, behind Lightroom's
  Preferences-level UI. Apply once on the first edit, materialize the values (2.6), and show "raw
  defaults applied" in History.
- **Adopt** "use this image's default" preset values: Auto WB, As Shot, Auto Tone, the camera profile.
- **Do better** by storing an explicit *included settings* set. A preset that includes Clarity 0 must
  reset Clarity, and a sparse dictionary can't say that. Add Amount, which interpolates from the
  photo's pre-preset state, including profile amount and curves. Stamp a PV and convert on apply.
- **Skip** per-module preset menus; keep panel presets only where Lightroom has them (curves, crop
  aspects, masks, export).

### 2.8 Styles

**Evidence** (`shared/styles.md`, `src/common/styles.c`, `data/styles/`).

- **Creating.** A style is built from chosen history items. Each item is kept or "reset" (stored as
  auto-init), and the pipeline order can optionally be included.
- **Applying.** Double-click or a shortcut applies a style in **append** mode (replace or add instances
  on top) or **overwrite** mode, optionally onto a new duplicate, through the same converters. The image
  is tagged `darktable|style|<name>` as provenance. Hovering renders a live preview. A style can also be
  applied temporarily at export.
- **`.dtstyle` format.** XML: `darktable_style` holds `info` (name, description, `iop_list`) and `style`,
  a list of `plugin` elements (num, module version, operation, the encoded parameters, enabled, blend
  parameters and version, multi_priority, multi_name). `tools/dtstyle_to_xmp.py` converts one into an
  XMP.
- **Shipped camera styles.** There are 535 `.dtstyle` files ("darktable camera styles") that
  "approximate the out-of-camera JPEG look". Nearly all combine a per-camera `basecurve` with
  `exposure`, `colorbalancergb`, `bilat` and disabled `filmicrgb` and `sigmoid` entries. The curves come
  from `tools/basecurve/darktable-curve-tool`, which fits from raw and camera-JPEG pairs (its README
  notes it uses the green channel only and assumes sRGB). A Lua script applies them on import.
- **darktable-chart** (`special-topics/darktable-chart/`) fits a tone curve, input profile and
  *N*-patch color LUT from a chart shot as raw plus JPEG, reporting mean and max ΔE, to reproduce film
  simulations.

**How this relates to Lightroom.** Styles correspond to Lightroom presets. Input profiles, LUTs and
camera styles correspond to Lightroom *profiles*. Redlamp already separates `ProfileReference` (with
amount and hash) from presets, as Lightroom does.

**Recommendations.**

- **Adopt** styles as Lightroom presets (Phase 2): hover preview, apply to many, "apply to a new
  version". Add an export look in Phase 4.
- Record provenance in the recipe (preset id and hash) rather than as tags.
- **Do better** than camera styles. `redlamp-profiler` (Phase 3) should emit *profiles* (DCP or LUT with
  Amount), so a camera look never overwrites the user's sliders. darktable-chart's ΔE report and patch
  count are prior art.

### 2.9 Lightroom interoperability

**Evidence** (`src/develop/lightroom.c`, `overview/sidecar-files/sidecar-import.md`).

- **When it runs.** Automatically the first time an image is opened (from `dt_dev_read_history_ext`,
  when auto presets run), or manually, using `<basename>.xmp` or `.XMP`. A file counts as Lightroom's
  if `stEvt:softwareAgent` mentions Lightroom or Camera Raw; others are still parsed. Both the
  attribute form (Lightroom 6 and earlier) and the element form (Lightroom 7 and later) are handled.
- **Metadata:** tags, hierarchical tags, rating, color label, GPS, title, description, creator,
  publisher and rights.
- **Develop settings and how each maps:**
  - crop and angle, into the deprecated `clipping` module, with orientation handled;
  - `Exposure2012`, one-to-one;
  - `Blacks2012`, through a five-point table into the exposure black level;
  - `PostCropVignette*`, through tables, with roundness approximated through the aspect ratio and the
    style mapped to fixed constants;
  - `GrainAmount` and `GrainFrequency`, through tables;
  - the parametric curve (by nudging five fixed nodes), or `ToneCurvePV2012` points, into an L-channel
    `tonecurve`;
  - the eight HSL bands, into `colorzones`, as 0.5 plus value/200;
  - `SplitToning*`, into `splittoning`;
  - `Clarity2012`, into `bilat` (±100 becoming ±0.65);
  - `RetouchInfo` circles, into the deprecated `spots` module (up to 32);
  - `colorin` forced to the Adobe-derived matrix.
- **Not mapped:** Temperature and Tint, Contrast, Highlights, Shadows, Whites, Texture, Dehaze,
  Vibrance, Saturation, Color Grading, the per-channel curves, Detail, lens, Transform, Calibration,
  profiles, masks and `crs:ProcessVersion`.
- **Pattern.** The importer writes private copies of *old* parameter layouts at their old versions
  (for example exposure v2, tonecurve v3) and lets the converters upgrade them, which decouples it from
  module changes.
- **Accuracy.** The manual says it "will never give identical results ... further adjustment will be
  required".

**Assessment for Redlamp.**

- The mapping is shallow because darktable's modules don't share Lightroom's semantics. Redlamp's do,
  so the hard part is appearance, not the mapping.
- **Phase 2, preset import.** Import from `crs:`:
  - the `*2012` Basic keys;
  - Temperature and Tint (absolute kelvin for raw, relative −100…+100 for non-raw);
  - Vibrance and Saturation, HSL, Color Grading (`ColorGrade*` **(verify)**);
  - the parametric and point curves, including the per-channel `ToneCurvePV2012Red`/`Green`/`Blue`;
  - vignette, grain, Texture, Clarity, Dehaze, Detail and Calibration;
  - the preset metadata.

  Map Adobe profile names to the nearest built-in profile, with a visible note. Show an **import
  report** of mapped, approximated and ignored keys. `.lrtemplate` support is an open question.
- **Phase 4, sidecar import.** Also crop and angle, orientation, masks (gradients and brushes; AI masks
  flagged "regenerate"), healing, lens and Transform. Read `crs:ProcessVersion` (PV2012 is "6.7";
  "11.0" and "15.4" for later versions **(verify)**) and choose mappings per Adobe PV, because a PV2010
  Fill Light isn't a Version 5 Shadows. Convert once into a recipe at the current Redlamp PV, record the
  source file and its hash, and never write to `basename.xmp`.
- **Calibrate by measurement.** Replace hand-typed tables with per-slider response curves fitted from
  sweeps rendered in Lightroom and in Redlamp. It's the same black-box method `redlamp-profiler` and the
  Phase 2 slider-feel calibration need, and the fitted curves are data Redlamp owns.

### 2.10 Copy/paste, snapshots, history UI, duplicates and undo

**Evidence** (`shared/copy-paste.md`, `darkroom/snapshots.md`, `darkroom/duplicate-manager.md`,
`src/libs/copy_history.c`, `snapshots.c`, `duplicate.c`).

- **Copy and paste.** Copy excludes by default: orientation, lens correction, raw black and white
  point, rotate and scale pixels, white balance, and deprecated modules. Selective copy and paste use a
  dialog with a per-item "reset". Paste appends (replacing same-named modules); overwrite wipes the
  target first. Paste uses the source's *current* state, not its state at copy time. Ctrl+X copies the
  last changed module to all selected images.
- **Snapshots** are session-only. They show as a movable, rotatable split or side by side, can come from
  another image, and can be restored into the history.
- **Duplicates** are separate library images with their own XMP, a version number and a "version name".
  Holding a thumbnail previews one.
- **Undo** is an in-memory stack. Compress, discard and load-sidecar are documented as not undoable.

**Recommendations.**

- **Adopt** (Phase 2) Lightroom's category dialog with darktable's safe defaults: exclude white balance,
  crop, Transform, healing, image-positioned masks and lens profile, and remember the last choice. Offer
  Paste (partial) and a separate "Replace all settings".
- **Adopt** "sync the last change to the selection" (Phase 4, alongside Auto Sync).
- **Do better:** snapshots are already persisted. Keep versions as named recipes in the same sidecar so
  one atomic file travels with the photo. Make every bulk operation undoable by snapshotting the
  sidecar first.

### 2.11 Library (brief; Redlamp is an editor)

**Evidence.** darktable's library has:

- film rolls, one per folder;
- rule-based collections;
- hierarchical tags with synonyms, categories and a private flag;
- ratings, with reject as a flag;
- *multiple* color labels per image;
- metadata fields (title, description, creator, rights, notes, version name);
- grouping and local copies;
- import in place or as a copy with rename patterns;
- map, timeline, print and slideshow views;
- a Lua API for storage targets, events and actions (`src/lua/`).

**Worth copying later.**

- A catalog that *indexes* sidecars and never owns data.
- Smart collections.
- `dc:subject` and `lr:hierarchicalSubject` for keywords.
- One variables system shared by filenames, metadata and watermarks.
- Local copies, which map to iCloud's "keep downloaded".
- App Intents and Shortcuts instead of embedded Lua.

**Skip:** multiple labels per image, and the map, print and slideshow views.

### 2.12 Export

**Evidence** (`shared/export.md`, `src/imageio/format/`, `src/imageio/storage/`).

- **Formats:** JPEG, PNG, TIFF (8, 16 or 32-bit float), WebP, AVIF, HEIF, JPEG XL, JPEG 2000, EXR, PFM,
  PPM, PDF, XCF, and a copy of the original.
- **Storage targets:** disk, email, web gallery, a LaTeX book, and Piwigo.
- **Size:** in pixels, cm or inches (with dpi), or by scale, with "allow upscaling" and **"high quality
  resampling"**, which processes at full resolution and downscales last ("always slower").
- **Color:** output profile and intent.
- **Presets:** an export-time style (append or overwrite) and multi-preset export.
- **Filenames:** templates with variables, and conflict handling (unique, overwrite, overwrite if
  changed, skip).
- **Metadata:** per-group control (Exif, metadata, geo tags, tags, hierarchical tags, **develop
  history**) plus per-field formulas.
- **Watermarks and frames** are pipeline modules (`watermark` with SVG templates, `borders`).

**Recommendations.**

- **Adopt** full-resolution-then-downscale as the only mode. Define scale-dependent parameters (grain,
  sharpening radius, noise reduction) in image-relative units so the Fit preview matches the export.
- **Adopt** multi-preset export, conflict policies, filename variables, and per-group metadata with
  "remove location" (metadata in Phase 2, the rest in Phase 4).
- **Adopt** embedding the recipe: a Redlamp XMP namespace in exports holding the JSON recipe and the
  source hash, which also prepares for C2PA.
- Offer Lightroom's output sharpening plus an optional export-look preset, without darktable's
  append/overwrite choice.

---

## 3. Mapping: darktable, Lightroom and Redlamp

| darktable | Lightroom | Redlamp plan |
| --- | --- | --- |
| History stack with `history_end`, persisted | History panel (catalog only) | Current-state recipe, undo in memory, optional capped log (P2) |
| XMP `IMG.CR3.xmp`, hex or gz parameter blobs | `crs:` XMP or catalog | JSON `IMG.CR3.redlamp`, sparse named values. Add PV, reader version and unknown-key round-trip (**move to P1**) |
| Database authoritative, startup XMP crawler | Catalog authoritative | Sidecar authoritative, coordinated I/O and merge (P1) |
| Skip writes when unchanged | n/a | Adopt (P1) |
| Module versions, converters, algorithm-version fields | Process Version 1 to 6 **(verify)** | Global PV, per-PV defaults and kernels, explicit update, per-PV golden corpus (stamp in P1, first bump in P2) |
| Deprecated modules kept | Old PV controls kept | Old PV paths via function constants |
| Module presets | Panel presets (curve, crop, mask) | Only where Lightroom has them (P2 and P3) |
| Auto-apply presets with EXIF and format rules | Raw defaults per camera, serial number, ISO | Raw Defaults rules, applied once, materialized (P2) |
| "Reset" (auto-init) items | Auto settings in presets | "Use image default" preset values (P2) |
| Styles (append or overwrite, hover preview) | Develop presets (Amount, groups) | Presets with included settings, Amount and PV (P2) |
| `.dtstyle` and `.dtpreset` | `.xmp` presets, `.lrtemplate` | Redlamp preset JSON; Lightroom `.xmp` import (P2); export (P4) |
| Camera styles (535) and darktable-chart | Camera Matching profiles | `redlamp-profiler` producing profiles (P3) |
| Lightroom import (about 10 settings, tables) | n/a | Full `crs:` import, per Adobe PV, measured calibration, report (P2 and P4) |
| Copy, selective, append or overwrite, Ctrl+X | Copy Settings, Sync, Previous | Category dialog, safe defaults, Paste or Replace (P2), sync last change (P4) |
| Session-only snapshots | Snapshots (catalog) | Persisted in sidecar (done) |
| Duplicates as `IMG_01.CR3.xmp` | Virtual copies, Versions | Named recipes in one sidecar (P2) |
| History hash (basic, auto, current) | n/a | "Defaults only" versus "edited" badge (P2) |
| Export: formats, high quality, style, multi-preset, metadata, history embed | Export dialog and presets | Full resolution always; presets, templates, metadata, recipe embed (P2 and P4) |
| Tags, collections, film rolls, Lua | Library module | Catalog track (Later); App Intents |

---

## 4. Licensing notes

- **Code.** darktable is GPL-3.0; nothing here is derived code. Format descriptions (XMP keys, hex or
  gz encoding, `.dtstyle` layout) are interoperability facts. Reading darktable edits would still
  require its GPL per-module struct layouts, so **don't build a darktable edit importer** without a
  separate clean-room effort and legal review.
- **Data.** Camera styles, built-in presets, base-curve fits and chart outputs are GPL data. Don't ship
  them and don't use them as fitting targets.
- **Lightroom.** The `crs:` namespace is documented through Adobe's XMP SDK and the DNG specification,
  and reading it for interoperability is established practice. Import *settings* only. Never bundle or
  imitate Adobe profiles; mark imported Adobe profile references as unavailable.
- **The recipe format.** Publish Redlamp's JSON schema under a permissive license (for example CC0 for
  the schema) so other tools can adopt it.

---

## 5. Open questions

1. **Persisted history.** Should Redlamp persist history at all? Lightroom keeps it in the catalog,
   not the XMP **(verify)**. A capped log costs size and sync conflicts. *Decided (2 October 2026):*
   yes, as sessions, one file each in the sidecar package, every step a JSON Patch from the one before,
   the last 20 kept ([design](../../../plans/2026-10-02-history-sessions-design.md)).
2. **PV granularity.** Is one global PV enough? AI denoise and AI masks have model versions that change
   faster than the tone pipeline, so they probably need per-feature pins inside the recipe (see
   `docs/research/ai-findings.md`).
3. **Recipe size in exports.** Brush-stroke masks can be large: cap the embedded recipe or compress
   strokes?
4. **Standard XMP.** Should Redlamp write `xmp:Rating`, `xmp:Label` and `dc:subject` for Bridge and
   Photo Mechanic, given `basename.xmp` is Lightroom's and a second file adds clutter?
5. **Adobe PV coverage.** Phase 4 could support PV2003 and PV2010 (Fill Light, Recovery), or only PV2012
   and later with a warning.
6. **`.lrtemplate`.** Is legacy preset support worth it?
7. **Lightroom Amount semantics.** Does Amount interpolate from the photo's current values or from
   defaults, and how does it treat curves and profiles? This needs verifying before Redlamp's Amount
   behavior is fixed.
8. **Adaptive presets.** They need a mask component of kind "semantic, regenerate on apply" with a
   pinned model version.
