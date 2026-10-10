# Copy, paste and sync settings: design

Lightroom's model: choose which settings carry from one photo to others, then paste them onto one photo, sync them across a selection, or let Auto Sync repeat every change. Tracker: EDT-08 (the picker and its safe defaults), EDT-17 (a selection, Sync and batch AI mask updates), EDT-18 (Auto Sync), EDT-19 (the filmstrip's context menu) and EDT-20 (Auto Sync's undo, and batches that wait their turn).

**Status (2026-10-05):** built, all seven steps: the model (`SettingsSelection`), the checklist and Paste on the open photo, the filmstrip's selection, the worker (`SettingsSync`), Auto Sync, the filmstrip's context menu, and Auto Sync's undo. Heal and Clone spots are an item of their own, unticked the first time.

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

**Panel switches (UX-30, 2026-10-10).** Whether a panel is on or off (the eye on its header) travels with its settings: pasting any item of a switchable panel (Tone Curve, Color Mixer with Point Color, Color Grading, Detail, Lens Corrections, Transform, Effects, Calibration) gives the target that panel's switch as the source has it. That is the simplest rule under which what was copied looks the same on the target as on the source: the pasted values are the source's, and so is whether they apply. Its cost is that the target's other settings in that panel follow the switch too: pasting only Sharpening from a photo whose Detail is off turns the target's Detail off, its noise reduction with it. Process Version, though listed under Calibration, brings no switch. The checklist has no item for switches of their own.

## Model (`RedlampEngineAPI`)

- **`SettingsItem`:** a stable id (`basic.exposure`, `lens.manual`, `crop.frame`), a name, whether it is ticked the first time, and what it covers: parameters, and fields of `EditRecipe` (treatment, base look and applied recipe, white balance mode, point curve, crop, orientation, process version). Every parameter belongs to exactly one item; a test checks the catalog covers them all, and mask-scoped parameters none.
- **`SettingsGroup`:** a name and its items, in panel order. `SettingsGroup.all` is the catalog.
- **`SettingsSelection`** (`Codable`, remembered in user defaults): the ticked item ids, whether masks are ticked by default, and the source's masks left out by id.
- **`EditRecipe.pasting(_ source: EditRecipe, _ selection: SettingsSelection) -> EditRecipe`:** for each ticked item the target takes the source's values, defaults included, so an untouched slider resets the target's, and the source's switch for the item's panel (`SettingsItem.panel`). Masks merge by identity, at most `MaskLayer.maximumLayers`. Everything else stays the target's, including values and fields written by a newer Redlamp. Pure, so it is unit-tested exhaustively and the CLI can use it.
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

A toggle beside the filmstrip's selection count (⌥⇧⌘A). While it is on with several photos selected, each history step on the active photo is pasted onto the others: only what that step changed (the parameters, fields and masks that differ from the step before, and the panels switched off or on), through the worker, coalesced while steps arrive. A step that only turns a panel off or on carries the switch alone (`SettingsSelection.panelSwitches`), so the other photos keep their own settings in that panel. A slider drag syncs when it ends. Turning it on doesn't sync anything by itself.

## The filmstrip's context menu (step 6, decided 2026-10-04)

Right-click or Control-click a photo in the filmstrip, as in Lightroom and Finder:

- **A selected photo** (the open one, or one selected with it): the Photo menu's Copy Settings…, Copy Settings with Last Choice, Paste Settings, Paste Settings from Previous, Sync Settings…, Sync Settings with Last Choice, Undo Sync Settings and Auto Sync (with its checkmark), with their keys. They act on the selection as they do in the menu bar.
- **Any other photo:** Copy Settings…, Copy Settings with Last Choice and Paste Settings act on that photo alone, without opening it. Copying reads its sidecar (a photo with no edit copies the default edit; one whose edit can't be read copies nothing), and the checklist says which photo it's from. Pasting is a one-photo batch, with its AI masks computed for it and Undo Sync Settings to take it back. These items show no keys: the keys act on the open photo.
- Items that don't apply are left out. While the menu is open, the photo it acts on is ringed in the accent colour. VoiceOver's Show Menu opens the same menu.

## Auto Sync's undo (step 7, decided 2026-10-04)

- **Batches wait their turn.** One that arrives while another runs is queued, never dropped; Auto Sync's steps merge into an Auto Sync batch waiting at the end. So Paste reaches the whole selection even while a sync runs, and Paste from Previous reaches it too.
- **Deleted masks reach the other photos.** A step's changes list the masks it took away (`SettingsSelection.removedMasks`, never saved); a paste removes them from the target, unless the source has them again, with the components of other masks that reused them.
- **AI masks aren't computed twice.** A pasted AI mask that asks for what the target's own copy already answers (the same request, instance, Refine Edge strokes, provider, revision and OS build, computed for that photo) keeps the target's result. So a slider on an AI mask doesn't recompute it on every photo.
- **A run.** While Auto Sync is on with one open photo, the batches that follow its steps make a run. Each other photo keeps one history session for the run, its steps named after the open photo's ("Auto Sync: Exposure"). The run remembers what each step carried, and for each photo its edit before the run, the steps that reached it and what the run last wrote.
- **Undo, Redo and history clicks** on the open photo give each photo of the run its edit at that step, as Lightroom does: its edit before the run, with the open photo's edit pasted for what the steps not undone carried to it. A photo whose own exposure Auto Sync overwrote gets it back. A photo edited since the run last wrote it is left alone, and the filmstrip says so. A new step after an Undo forgets the steps it replaced.
- **Pastes while Auto Sync is on join the run,** so Undo takes them back on the other photos too. Other batches (Sync Settings, Update AI Masks, a paste onto one photo, Undo Sync Settings) take the photos they write out of the run. The run ends when Auto Sync is turned off, another photo opens, or history is cleared. With Auto Sync off, nothing changed: Undo after a paste onto several photos undoes only the open one, and Undo Sync Settings the rest.
- Photo ▸ Auto Sync shows a checkmark when it's on.

## Testing

- **Model:** every item's coverage; untouched groups reset the target; unticked groups keep the target's; masks replace by identity and are otherwise added; the layer limit; unknown values kept; process version only when ticked.
- **Open photo:** the checklist's remembered choice; Paste as one history step; only pasted AI masks recomputed; Previous with the last choice.
- **Selection and worker** (with the stub engine and a temporary folder): Sync writes each sidecar and history step; AI masks recomputed per photo; skipped newer sidecars; Undo restores all; Auto Sync carries only what changed.
- **Context menu:** the items on a selected photo and on another; pasting onto another photo leaves the open photo and the selection; copying from one reads its sidecar; a cell's right-click and its ring.
- **Auto Sync's undo:** a batch arriving mid-run waits; Paste from Previous reaches the selection; a deleted mask is carried and an AI mask's slider doesn't recompute it; one session per run; Undo gives B its own +0.3 back and Redo takes it to +1; a history click several steps back and a new step after Undo; a photo edited since is left alone; a paste made while Auto Sync is on is undone on B.
