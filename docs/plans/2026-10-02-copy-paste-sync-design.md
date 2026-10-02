# Copy, paste and sync settings: design

Lightroom's model: choose which settings carry from one photo to others, then paste them onto one photo, sync them across a selection, or let Auto Sync repeat every change. Tracker: EDT-08 (the picker and its safe defaults), EDT-17 (a selection, Sync and batch AI mask updates) and EDT-18 (Auto Sync).

## Decisions (2026-10-02, the owner)

- **The choice is made when copying,** as in Lightroom: Copy Settings… opens a checklist, remembered between uses; Paste applies what was copied; Sync… shows the same checklist. Option skips the dialog and reuses the last choice.
- **Two levels:** groups in panel order, each with sub-items, and each mask by name.
- **Ticked the first time:** everything except Crop and Straighten, Rotate and Flip, Transform, and the manual Lens Corrections (distortion and vignetting sliders). White Balance is ticked: shots in a series usually share their light. (darktable leaves white balance out; EDT-08 began from that.)
- **Masks merge by identity:** the photo keeps its own masks; a pasted mask replaces one with the same identity (pasted before from the same source) and is otherwise added, so syncing twice changes nothing. Pasted AI masks are recomputed for the photo they land on.
- **With several photos selected:** Sync… (the active photo's settings go to the others), Paste onto every selected photo, Update AI Masks across the selection, then Auto Sync. Built in that order.
- **Architecture:** the categories and the merge are a pure model in `RedlampEngineAPI`; photos that aren't open are updated by a background worker with an engine of its own.

## The checklist

| Group | Items (ticked first time, unless marked off) |
| --- | --- |
| Treatment and Base Look | Treatment; Base Look (with its Amount and the applied recipe's provenance) |
| White Balance | Temperature, Tint and mode (one item) |
| Basic Tone | Exposure, Contrast, Highlights, Shadows, Whites, Blacks (one item each) |
| Presence | Texture, Clarity, Dehaze, Vibrance, Saturation |
| Tone Curve | Parametric Curve; Point Curve |
| Color Mixer | Hue; Saturation; Luminance |
| Color Grading | Color Grading (one item) |
| Detail | Sharpening; Noise Reduction |
| Lens Corrections | Profile Corrections; Remove Chromatic Aberration; Defringe; Manual Distortion and Vignetting (off) |
| Transform | Upright and Transform sliders (off) |
| Effects | Vignette; Grain; Halation and Bloom; Light Leak; Dust and Scratches; Frame; Camera Recipe Settings (Dynamic Range, Color Chrome, white balance shift) |
| Calibration | Calibration sliders; Process Version |
| Crop | Crop and Straighten (off); Rotate and Flip (off) |
| Masks | Each of the source's masks, by name |

Check All and Check None. A group's checkbox ticks or clears its items, and shows mixed when only some are ticked. A group the source leaves at defaults still shows: pasting it resets the target's.

## Model (`RedlampEngineAPI`)

- **`SettingsItem`:** a stable id (`basic.exposure`, `lens.manual`, `crop.frame`), a name, whether it is ticked the first time, and what it covers: parameters, and fields of `EditRecipe` (treatment, base look and applied recipe, white balance mode, point curve, crop, orientation, process version). Every parameter belongs to exactly one item; a test checks the catalog covers them all, and mask-scoped parameters none.
- **`SettingsGroup`:** a name and its items, in panel order. `SettingsGroup.all` is the catalog.
- **`SettingsSelection`** (`Codable`, remembered in user defaults): the ticked item ids, whether masks are ticked by default, and the source's masks left out by id.
- **`EditRecipe.pasting(_ source: EditRecipe, _ selection: SettingsSelection) -> EditRecipe`:** for each ticked item the target takes the source's values, defaults included, so an untouched slider resets the target's. Masks merge by identity, at most `MaskLayer.maximumLayers`. Everything else stays the target's, including values and fields written by a newer Redlamp. Pure, so it is unit-tested exhaustively and the CLI can use it.
- **`CopiedSettings`:** the source edit, its selection and the source photo's URL: the clipboard.

## The open photo (step 2)

- **Copy Settings… (⇧⌘C)** opens the checklist sheet for the open photo; **Copy (⌥⇧⌘C)** copies with the last choice. **Paste (⇧⌘V)** applies the clipboard as one history step, "Paste Settings". **Paste from Previous (⌥⌘V)** applies the previous photo's edit with the last choice.
- After a paste, only the pasted AI masks are recomputed for this photo (today every AI mask is), with their Refine Edge strokes.

## A selection (steps 3 and 4)

- **The filmstrip selects several photos:** ⌘-click adds or removes one, ⇧-click a range, ⌘A all; a plain click selects one. The active photo is the one open, and is always part of the selection. `EditorModel.selection` stays the active photo; `selectedPhotos` is the ordered set.
- **Sync… (⇧⌘S)** shows the checklist for the active photo, then pastes onto the others; ⌥ uses the last choice. **Paste** with several photos selected pastes onto each. **Update AI Masks** recomputes every AI mask of every selected photo.
- **The batch worker** (`SettingsSync`, in `RedlampUI`) runs one photo at a time, in the background, with progress in the status bar and Cancel. For each photo it loads the sidecar (coordinated, through `SidecarStore`), pastes, opens the photo in its own engine to recompute the pasted AI masks, saves the sidecar with their bitmaps, and records a history step in that photo's history. A photo whose sidecar was written by a newer Redlamp is skipped and reported. The worker's engine is made by a factory the app passes in, so tests use a stub.
- **Undo Sync Settings:** the worker keeps each photo's edit before the batch, so Undo straight after a sync or multi-photo paste reverts all of them (one level, while the app is open; each photo's own history keeps its step).

## Auto Sync (step 5)

A toggle beside the filmstrip's selection count (⌥⇧⌘A). While it is on with several photos selected, each history step on the active photo is pasted onto the others: only what that step changed (the parameters, fields and masks that differ from the step before), through the worker, coalesced while steps arrive. A slider drag syncs when it ends. Turning it on doesn't sync anything by itself.

## Testing

- **Model:** every item's coverage; untouched groups reset the target; unticked groups keep the target's; masks replace by identity and are otherwise added; the layer limit; unknown values kept; process version only when ticked.
- **Open photo:** the checklist's remembered choice; Paste as one history step; only pasted AI masks recomputed; Previous with the last choice.
- **Selection and worker** (with the stub engine and a temporary folder): Sync writes each sidecar and history step; AI masks recomputed per photo; skipped newer sidecars; Undo restores all; Auto Sync carries only what changed.
