# Masking in Redlamp — fact sheet for the user manual

Every fact below cites a repository-relative path and line numbers. Facts marked **(inferred)** were
reasoned from the code rather than read as a literal string. Where `README.md` and the code disagree,
both are reported and the code's version is named.

Read from the code at commit `9675a809` (9 October 2026), where the new Masks panel's files are as
read here: `packages/RedlampUI/Sources/Inspector/MasksPanelNext.swift`,
`packages/RedlampUI/Sources/Inspector/AppKit/MasksPanelView.swift`,
`packages/RedlampUI/Sources/Inspector/MaskingPanel.swift`,
`packages/RedlampUI/Sources/Inspector/PeoplePickerView.swift`,
`packages/RedlampUI/Sources/DesignSystem/AutomationIdentifier.swift`,
`packages/RedlampUI/Sources/DesignSystem/ValueFieldControl.swift` and
`packages/RedlampAutomation/Sources/Scenarios/MasksPanelScenarios.swift`. Switching the editor to the
new panel renames `MasksPanelNext` to `MasksPanel` and removes the old panel's parts from
`MaskingPanel.swift`, so their line numbers move after that commit; check a fact against the code
before reusing it.

This sheet describes the **new Masks panel** (`MasksPanelNext` and its AppKit port `MasksPanelView`),
designed in `docs/plans/2026-10-07-masks-panel-design.md` and built as tracker rows UX-20 to UX-24.
The old panel's own parts (`MaskingPanel`'s body, `MasksHeaderBar`, `MaskActionsBar`, `MaskStatus`,
`CreateMaskGrid`, `CreateMaskMenu`, `ComponentOperationMenus`, and the `actionsOnScreen == false` /
`usesPicker == false` branches of the shared parts) are being retired and are **not** documented here
as current.

Conventions used below:
- "Label" means a string literal the app displays.
- Slider ranges and defaults come from `ParameterCatalog`
  (`packages/RedlampEngineAPI/Sources/ParameterSpec.swift`).
- A parameter declared without an explicit range/default/step/format uses the `ParameterSpec`
  initialiser's defaults: range `-100…100`, default `0`, step `1`, format `.signedInteger`
  (which displays `+25`, `0`, `-40`).
- "Automation identifier" is the string `.automationIdentifier(_:)` sets: it is both the VoiceOver
  accessibility identifier and what the regression suite clicks
  (`packages/RedlampUI/Sources/DesignSystem/AutomationIdentifier.swift:4-13`).

---

## 0. Changed for the new Masks panel

What the manual's current text (`docs/manual/content/masking/*.md`, `docs/manual/figures/masks-panel.html`)
says that is **no longer true**. One line each; the section that replaces it is named.

| Where the manual says it | What it says now | What the new panel does | §|
| --- | --- | --- | --- |
| `how-a-mask-works.md:19` | "Before a photo has any masks, the panel shows a grid of tiles under CREATE NEW MASK" | There is no CREATE NEW MASK heading; with no masks the **picker** takes the list's place, titled **New Mask** | §2.5 |
| `how-a-mask-works.md:19` | "Once there are masks, the same kinds are in the Create New Mask menu under the list of masks" | There is no menu and no bar under the list: **New Mask** is a button in the panel's header and opens the same picker in a popover | §2.2, §2.5 |
| `how-a-mask-works.md:26` | "Click Subject in the grid" | Click Subject in the picker's **AI** group | §2.5 |
| `how-a-mask-works.md:34`, `managing.md:12` | Components are listed under "COMPONENTS" | The header reads **Components, applied top to bottom** | §2.7 |
| `how-a-mask-works.md:45` | "To change it later, right-click the row and choose Set to Add…" | The operation's icon is itself a **menu** on the row (Set to Add / Set to Subtract / Set to Intersect); the context menu still has them | §2.7 |
| `how-a-mask-works.md:53` | "To invert a whole mask, right-click it in the list and choose Duplicate and Invert" | **Invert** inverts the whole mask: a checkbox beside the mask's name at the top of its settings, and **Invert** in the mask's own menu. Duplicate and Invert now inverts the *copy* as a whole | §1, §2.6, §2.7 |
| `how-a-mask-works.md:57` | "Add, Subtract and Intersect also list your other masks, under Existing Mask" | They open the **picker**, which lists the other masks under an **EXISTING MASK** heading at its foot | §2.5 |
| `how-a-mask-works.md:65` | "the mask's section is headed by its name, with a Reset button beside it" (below the components) | The mask's name, **Invert** and **Reset** now lead its settings, **above** the components, with **Amount** directly under them | §2.7 |
| `managing.md:12` | "Each row shows the icon of the mask's first component" | Each row shows a **thumbnail of the mask's coverage** (white on black); the first component's symbol shows only until the thumbnail is drawn | §2.6 |
| `managing.md:19-36` | Rename, Duplicate, Duplicate and Invert, Reset Adjustments, Save as Mask Preset, Delete are reached by right-click | The same items are on a **menu button** on the row (the selected row, and the one under the pointer), with **Invert** added and **Save as Mask Preset…** now ending in an ellipsis; the context menu keeps them too | §2.6 |
| `managing.md:38` | "The … menu at the end of the row of buttons under the list" | The … menu is in the panel's **header**, at its right | §2.2 |
| `managing.md:42` | "Every mask but the selected one shows as a white pin … at the centre of its first component" | A mask's pin goes at the point **furthest inside its coverage**; the first component's centre is only the fallback | §2.9 |
| `managing.md:46` | "Show Overlay, at the top of the panel" | The overlay is a **switch button** (a half-filled circle), not a checkbox labelled Show Overlay; its tooltip is still "Show Overlay (O)" | §2.2 |
| `managing.md:46` | Only the selected mask is shown, overlay on | The pointer over a **mask's row, a component's row or a pin** previews that mask (or that component alone) on the photo, **overlay on or off** | §7 |
| `managing.md:55` | Opacity: "How strongly the colour tints the photo" | Opacity now has a **value field** beside its slider: 0–100, shown with `%`, typed or scrubbed | §2.2, §2.10 |
| `managing.md:74` | "Presets, beside Create New Mask" | Presets is in the header, shown as its **symbol alone** (`wand.and.stars`), tooltip "Mask Presets" | §2.2 |
| `managing.md:76-85` | Eight built-in presets | **Nine**: **Even Skin Tone** was added (Face Skin and Body Skin, with a Point Color swatch) | §8 |
| `managing.md:89` | "Right-click a mask in the list and choose Save as Mask Preset. The preset takes the mask's name" | The item is **Save as Mask Preset…**, on the row's menu button or the context menu, and it opens an alert, **Save Mask Preset**, with a name field already holding the mask's name | §2.6, §8 |
| `ai-masks.md:28` | "Click the mask's tile, or choose it from Create New Mask" | Click its tile in the **picker** | §2.5 |
| `ai-masks.md:28` | "While the model works the panel says so … and every tile waits" | Progress now shows as a **row at the top of the list**, where the mask being made will appear; the tile itself shows a spinner | §2.4, §2.5 |
| `ai-masks.md:34` | "People opens a list of parts … In the grid of tiles, People makes an Entire Person mask straight away" | People opens the **People picker** in the panel, where the list was: the people found as crops to tick, the parts as checkboxes, Separate masks, and a create button | §2.8 |
| `ai-masks.md:39-41` (caution) | "These parts don't offer to download SAM 3: until it's downloaded they report that they need it" | Ticking a part that needs SAM 3 **asks to download it** in the panel; Not Now unticks the part | §2.8, §5 |
| `ai-masks.md:50` | "choose Brush beside Drag in the panel" | Drag is in the **strip under the header** while Objects is armed, not in the panel's body | §2.3 |
| `ai-masks.md:54` | "Choose Landscape, then one kind" | The Landscape tile in the picker opens the same menu of seven classes; the regions picker (UX-26) is **not built** | §2.5 |
| `ai-masks.md:71` | "choose Update AI Masks from the … menu beside Presets" | The … menu is at the right of the header, after Pins | §2.2 |
| `ai-masks.md:85-91` | "Right-click an AI component for two more ways to work on its edge" | **Refine Edges** and **Refine Edge Brush** are buttons under the component's Feather and Edge, as well as on the row's menu button and the context menu | §2.7, §5 |
| `ai-masks.md:91` | The Refine Edge Brush's "Size slider, from 1 to 100 and 12 to start, is in the panel" | It is in the **strip under the header**, with a **value field** beside the slider | §2.3, §2.10 |
| `ranges.md:22`, `:48` | Click Done | Unchanged, but the button is in the strip under the header, and reads **Cancel** until the tool's first stroke or sample | §2.3 |
| `ranges.md:34` | "The readout with the bar shows where the selection is full" | There are **four value fields** under the bar, one per handle, each with its own tooltip | §3 (Luminance Range), §2.10 |
| `adjustments.md:52` | "Reset, beside the mask's name" | Still true, but the mask's name now sits **above** the components, not below them | §2.7 |
| `masks-panel.html` (the whole figure and its eleven callouts) | Shot of the old panel: Show Overlay checkbox, Create New Mask · Presets buttons under the list, COMPONENTS, Invert · Delete, the mask's section below the components | Every callout but 2, 3, 6 and 8 is wrong for the new panel; the figure needs recapturing | §2 |
| Not said anywhere | — | **New:** the panel's title row holds New Mask, Presets, the overlay switch, overlay options, Pins and the … menu, in that order | §2.2 |
| Not said anywhere | — | **New:** Option-click a mask's eye shows that mask alone, and again shows them all, as one history step | §2.6 |
| Not said anywhere | — | **New:** a component's row names its person — "Face Skin · Person 2" | §2.7 |
| Not said anywhere | — | **New:** a mask's Point Color (TON-29) is in the panel, under Curve | §6 |

Also changed outside the panel but inside Part 3's subject:
- **ViTMatte (base)**, 108.9 MB, is a new downloadable model: stray hairs on Subject, Background and
  People mask edges (§5).
- `docs/lightroom-comparison.md:130` now marks **Point Color inside masks** as Done (TON-29); the old
  sheet listed it as the one masking row not done.

**Not built yet,** so the manual must not describe it: the **Landscape picker** (UX-26, the regions SAM 3
finds with their share of the photo) and **mask presets applied to every selected photo** (UX-25) are
both "Not started" (`docs/research/research-tracker.md:331-332`). **Effect presets** for a mask's
adjustments are UX-27, also not started (`:333`).

**One gap to be aware of:** at this commit the editor still builds the **old** panel —
`packages/RedlampUI/Sources/Inspector/AppKit/InspectorPanelsView.swift:32-33` returns
`MaskingPanelView(model: model)` for `.masking`. The new panel is reached only from the harness
(`apps/RedlampHarness/Sources/Scenes/MasksPanelScenes.swift:11-30`,
`apps/RedlampHarness/Sources/Scenes/ParityScenes.swift:182-190`). The switch is the work still to land;
every tracker row UX-20 to UX-24 reads "In progress"
(`docs/research/research-tracker.md:326-330`). Write the manual for the new panel, but don't publish it
before `InspectorPanelsView` points at `MasksPanelView`.

---

## 1. The model: what a mask is

### A mask = adjustments + components

- A mask (`MaskLayer`): `name`, `isVisible`, `components`, `inverted`, `amount`, `detail`,
  `adjustments`, `curves`, `pointColor` —
  `packages/RedlampEngineAPI/Sources/Masks.swift:840-867`.
- A component (`MaskComponent`) carries a `shape`, an `operation` and an `inverted` flag:
  `packages/RedlampEngineAPI/Sources/Masks.swift:797-812`.
- Component shapes available: linear, radial, brush, luminanceRange, colorRange, ai, depthRange,
  maskReference, unknown — `packages/RedlampEngineAPI/Sources/Masks.swift:608-617`.
- README summary of the same model: "Each mask is a layer: its own adjustments plus a mask built from
  components. Components combine with **Add**, **Subtract**, and **Intersect**, and each can be
  inverted, as can the whole mask (**Invert**, as Lightroom's)." — `README.md:123`.

### How components combine: Add, Subtract, Intersect

- The three operations and their exact display names: `Add`, `Subtract`, `Intersect` —
  `packages/RedlampEngineAPI/Sources/Masks.swift:777-786`. Doc comment: "How a component combines
  with the components before it" (`:776`).
- Their SF Symbols: `plus`, `minus`, `circle.lefthalf.filled` — `:788-795`.
- **Where they appear #1 — three buttons under the components list** (`ComponentOperationButtons`),
  in the order Add, Subtract, Intersect, each labelled with `operation.name` and its symbol, each
  opening the picker in a popover —
  `packages/RedlampUI/Sources/Inspector/MasksPanelNext.swift:361-393`. Automation identifiers
  `masks.add`, `masks.subtract`, `masks.intersect` (`:376`).
- **Where they appear #2 — the operation's icon on each component row, which is a menu**: "Set to Add",
  "Set to Subtract", "Set to Intersect" —
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:1289-1305`, `:1403-1407`. Its tooltip is
  `"<Operation>: choose how it combines"` (`:1302`) and its accessibility label is the operation's
  name (`:1303`).
- **Where they appear #3 — the component row's context menu**, which holds the same three items,
  then an AI component's refinements — `:1397-1400`.
- The first component of a new mask is always `Add`: `drawingTarget == nil ? .add : drawingOperation`
  — `packages/RedlampUI/Sources/Model/EditorModel+Masking.swift:72`, `:111`; AI masks the same at
  `packages/RedlampUI/Sources/Model/EditorModel+AIMasks.swift:61-66`.
- History step names: `"\(operation.name) Component"` —
  `packages/RedlampUI/Sources/Model/EditorModel+Masking.swift:160`; for a reused mask,
  `"\(operation.name) \(referenced.name)"` (`:171`); for an AI mask added to an existing mask,
  `"\(operation.name) \(title)"` (`EditorModel+AIMasks.swift:72`); for the People picker,
  the same (`EditorModel+PeoplePicker.swift:199`).

### Invert, per component and for the whole mask

Two separate things, both in the panel:

- **Per component:** `MaskComponent.inverted`
  (`packages/RedlampEngineAPI/Sources/Masks.swift:801`). UI: a checkbox labelled **Invert** on every
  component row — `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:1333-1340`, automation
  identifier `masks.component.<uuid>.invert`. History names: `"Invert Component"` /
  `"Uninvert Component"` — `packages/RedlampUI/Sources/Model/EditorModel+Masking.swift:147-157`.
- **For the whole mask (new, UX-24):** `MaskLayer.inverted`, "The whole mask inverted, once its
  components have combined (Lightroom's Invert); written only when set, so an older Redlamp keeps it
  but draws the mask uninverted" — `packages/RedlampEngineAPI/Sources/Masks.swift:848-850`. UI: a
  checkbox labelled **Invert** beside the mask's name at the top of its settings
  (`MaskHeaderControls`, `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:1227-1241`),
  tooltip **"Invert the whole mask"** (`:1237`), automation identifier `masks.mask.invert` (`:1238`);
  and **Invert** as a toggle in the mask row's menu and context menu (`:829`).
  History name: `"Invert <mask name>"` —
  `packages/RedlampUI/Sources/Model/EditorModel+Masking.swift:278-282`.
- **Duplicate and Invert** now toggles the copy's whole-mask flag, not each component's:
  `copy.inverted.toggle()` — `packages/RedlampUI/Sources/Model/EditorModel+Masking.swift:230-252`.
  History `"Duplicate and Invert <name>"` (`:251`).

### The mask's Amount

- Slider label **Amount**, range **0…200**, default **100**, step 1, format integer (so it reads
  `100`, not `+100`) — `packages/RedlampEngineAPI/Sources/ParameterSpec.swift:433`.
- What it does: "Scales every adjustment of the mask, 0...200 (Lightroom's mask Amount)" —
  `packages/RedlampEngineAPI/Sources/Masks.swift:851-852`.
- In the new panel it sits **directly under the mask's name**, above the components —
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:850-857`,
  `packages/RedlampUI/Sources/Inspector/AppKit/MasksPanelView.swift:145-149`.
- README states the same range: "plus the mask's Amount (0–200%)" — `README.md:134`. The README writes
  a percent sign; the slider's own format is a bare integer.
- Reset puts it back to 100 (`packages/RedlampEngineAPI/Sources/Masks.swift:902-909`).
- Amount is one of the two kinds of slider whose drag temporarily hides the overlay (§7):
  `packages/RedlampUI/Sources/Model/EditorModel.swift:1352-1356`.

### Existing Mask as a component

- `MaskKind.existingMask`, display name **Existing Mask**, symbol `square.on.square` —
  `packages/RedlampEngineAPI/Sources/Masks.swift:713-714`, `:741`, `:759`.
- It is **not** one of the picker's tiles: `MaskKind.creatable = allCases.filter { $0 != .existingMask }`
  (`:717`), and the picker's groups list the twelve kinds by hand
  (`packages/RedlampUI/Sources/Inspector/MasksPanelNext.swift:159-165`).
- It appears as the picker's last group, **EXISTING MASK**, and only when the picker was opened from
  Add, Subtract or Intersect and the photo has another mask —
  `packages/RedlampUI/Sources/Inspector/MasksPanelNext.swift:204-227`. Each other mask is a row with
  its first component's symbol and its name (`:217-219`), automation identifier
  `masks.picker.existing.<uuid>` (`:223`).
- Behaviour: "Another mask's coverage, used as a component ('new mask from existing'). A referenced
  mask's own references are ignored, so references never loop." —
  `packages/RedlampEngineAPI/Sources/Masks.swift:584-587`.
- A mask cannot reference itself: `guard referencedID != maskID` —
  `packages/RedlampUI/Sources/Model/EditorModel+Masking.swift:169`.

### The mask's Detail

- Slider label **Detail**, range **-100…100**, default **0**, step 1, signed integer —
  `packages/RedlampEngineAPI/Sources/ParameterSpec.swift:439`.
- What it does: "-100...100: above 0 keeps only textured areas of the mask, below 0 only flat ones."
  — `packages/RedlampEngineAPI/Sources/Masks.swift:853-854`.
- README calls it a beyond-Lightroom feature — `README.md:133`.
- In the new panel it sits **after** the component tools, at the head of the adjustments, not beside
  Amount — `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:911`,
  `packages/RedlampUI/Sources/Inspector/AppKit/MasksPanelView.swift:154`.
- Reset sets it to 0 (`packages/RedlampEngineAPI/Sources/Masks.swift:908`).
- Dragging Detail does **not** hide the overlay (only `isLocal` parameters and `maskAmount` do) —
  `packages/RedlampUI/Sources/Model/EditorModel.swift:1352-1356`.

### Limits on masks and components

- **16 masks per photo**: `MaskLayer.maximumLayers = 16`
  (`packages/RedlampEngineAPI/Sources/Masks.swift:841`). The limit now **says so**:
  `hasRoomForMask` sets the message **"A photo can have up to 16 masks: delete one to make another."**
  — `packages/RedlampUI/Sources/Model/EditorModel+Masking.swift:221-226`. (Fixed under UX-17; the old
  sheet recorded the silent refusal.)
- **64 components**: `MaskLayer.maximumComponents = 64`
  (`:842`), enforced only in the renderer
  (`packages/RedlampEngine/Sources/DevelopParameters.swift`,
  `packages/RedlampEngine/Sources/DetailStage.swift`), not in the masking UI **(inferred: no UI file
  references `maximumComponents`)**.
- **Color Range** is limited to **5 samples**: `ColorRangeMask.maximumSamples = 5`
  (`packages/RedlampEngineAPI/Sources/Masks.swift:170`), and `init` truncates to it (`:177`).
- README quotes the mask limit as a performance figure: "Up to 16 masks cost well under a
  millisecond extra at Fit" — `README.md:136`.

---

## 2. The Masking tool and the new Masks panel

### 2.1 Entering and leaving

- Shortcut **⇧W**, title **Masking** —
  `packages/RedlampUI/Sources/Shortcuts/ShortcutAction.swift:237`, `:343`. It toggles:
  `activeTool = activeTool == .masking ? .edit : .masking` —
  `packages/RedlampUI/Sources/Model/EditorModel+Shortcuts.swift:116`.
- Tool strip: "Click a tool to open it, click it again to go back to Edit" —
  `packages/RedlampUI/Sources/Inspector/AppKit/ToolStripView.swift:4-5`. The cell's accessibility
  label is the tool's title (`:122`), and its tooltip adds the shortcut as `"Masking (⇧W)"` (`:140`).
- Tool titles: `edit` = "Edit", `crop` = "Crop & Straighten", `heal` = "Healing",
  `redEye` = "Red Eye Correction", `masking` = "Masking", symbol `circle.dashed.inset.filled` —
  `packages/RedlampUI/Sources/Model/EditorTypes.swift:290-318`.
- Any mask-kind shortcut (`M`, `⇧M`, `K`, `⇧J`, `⇧Q`, `⇧Z`) switches into the tool on its own:
  `startDrawing` → `arm` sets `activeTool = .masking` —
  `packages/RedlampUI/Sources/Model/EditorModel+Masking.swift:48-54`; AI kinds do the same in
  `createAIMask` (`EditorModel+AIMasks.swift:43`), `armObjectSelection`
  (`EditorModel+Objects.swift:23-27`) and `openPeoplePicker`
  (`EditorModel+PeoplePicker.swift:29-33`).
- **Esc** leaves. Title **Cancel / Leave Tool**, key `Esc` —
  `packages/RedlampUI/Sources/Shortcuts/ShortcutAction.swift:251`, `:357`. Order of effect in
  `cancelCurrentMode` (`packages/RedlampUI/Sources/Model/EditorModel+Shortcuts.swift:290` onwards):
  the Keyboard Shortcuts sheet → drawing or Refine Edge brushing → the eyedropper → guides →
  straightening → presentation → Lights Out → back to Edit. README: "`Esc` finish drawing or leave
  the tool" — `README.md:1163`.
- Opening the panel warms the AI models up for the photo: `model.engine.warmUpMasks()` —
  `packages/RedlampUI/Sources/Inspector/AppKit/MasksPanelView.swift:78-79`.

### The panel's order, top to bottom

`packages/RedlampUI/Sources/Inspector/MasksPanelNext.swift:18-45`, and the AppKit port's
`rows(for:)` — `packages/RedlampUI/Sources/Inspector/AppKit/MasksPanelView.swift:108-125`:

1. the header (always);
2. the armed-tool strip, while `drawingKind != nil || isRefiningEdges`;
3. messages, while a mask is being computed, a model is downloading or pending, or a failure is shown;
4. then **one** of: the People picker (while it is open); the picker, with no masks; or the list, a
   1-pt divider, and the selected mask's settings (or "Select a mask to edit its adjustments.").

`NoMaskSelected` reads **"Select a mask to edit its adjustments."** —
`packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:322-329`.

### 2.2 The header (`MasksHeaderNext`)

`packages/RedlampUI/Sources/Inspector/MasksPanelNext.swift:50-117`. Left to right:

| # | Control | Label / symbol | Tooltip (`.help`) | Accessibility label | Identifier | Lines |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Title | **Masks** | — | — | — | `:58-60` |
| 2 | Button | **New Mask**, with `plus` | "Make a new mask" | (the label) | `masks.new` | `:62-74` |
| 3 | Menu | `wand.and.stars` alone | "Mask Presets" | **Mask Presets** | `masks.presets` | `MaskingPanel.swift:333-369` |
| 4 | Switch | `circle.lefthalf.filled` when on, `circle` when off | "Show Overlay (O)" | "Show Overlay (O)" | `masks.overlay` | `:76-79`, `:104-116` |
| 5 | Button | `slider.horizontal.3` | "Overlay mode, color and opacity" | **Overlay Options** | `masks.overlayOptions` | `:80-93` |
| 6 | Switch | `mappin.circle.fill` when on, `mappin.circle` when off | "Show Pins (H)" | "Show Pins (H)" | `masks.pins` | `:94-97`, `:104-116` |
| 7 | Menu | `ellipsis.circle` | "Update AI Masks, Delete All Masks" | — | `masks.actions` | `MaskingPanel.swift:296-320` |

- The header is 10 pt of vertical padding inside the panel's horizontal padding (`:100-101`).
- A switch (4 and 6) is drawn in the accent colour when on, in the label colour when off, and carries
  the `.isSelected` accessibility trait when on (`:111-114`).
- **New Mask** is disabled with no photo open (`model.info == nil`, `:68`). Its popover opens from the
  leading edge (`arrowEdge: .leading`, `:71`).

**The Presets menu** (`MaskPresetsMenu(compact: true)`,
`packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:331-369`):
- Compact means the symbol alone, with no "Presets" text (`:356-360`), tooltip **"Mask Presets"**
  (`:365`), accessibility label **Mask Presets** (`:366`).
- Items: every preset, built-in then the user's, each a plain button with its name (`:342-345`);
  a preset the photo can't make, or any preset while an AI mask is being computed, is disabled
  (`:344`).
- Below the user's own: a divider, then a submenu **Delete Preset** listing them, each destructive
  (`:347-354`).

**The overlay options popover** (`MaskOverlayOptions`,
`packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:94-141`). 250 pt wide (`:139`), three rows:

| Row | Control | Items / range | Identifier | Lines |
| --- | --- | --- | --- | --- |
| **Mode** | pop-up menu | Color Overlay, Color Overlay on B&W, Image on Black, Image on White, B&W, Image on B&W | `masks.overlay.mode` | `:102-111` |
| **Color** | pop-up menu | Red, Green, Blue, White | `masks.overlay.color` | `:112-122` |
| **Opacity** | slider 0…1, plus a value field | field: 0…100, unit `%`, step 1, no decimals | `masks.overlay.opacity` | `:123-134` |

- Mode names: `MaskOverlayStyle.menu` and `.name` —
  `packages/RedlampEngineAPI/Sources/Rendering.swift:81-99`. Colour names: `:120-127`.
- The Opacity field's spec is `FieldSpec(range: 0 ... 100, unit: "%")`
  (`MaskingPanel.swift:97`); the slider holds 0…1 and the field shows the value ×100, rounded
  (`:126-131`). Its width is sized for `"100%"` (`:131`).
- **Color and Opacity are disabled** in the modes that don't tint: only Color Overlay, Color Overlay
  on B&W and Luminance Map tint (`MaskOverlayStyle.tints`,
  `packages/RedlampEngineAPI/Sources/Rendering.swift:101-107`); the Color picker is disabled at
  `MaskingPanel.swift:120` and the Opacity row at `:133`.

**The … menu** (`MaskActionsMenu`, `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:296-320`),
in order:
- **Update AI Masks** — disabled when the edit has no AI masks, or one is being computed (`:301-302`).
- **Update AI Masks on N Photos** (literally `"Update AI Masks on \(count) Photos"`), shown only while
  more than one photo is selected (`isMultiSelecting`), and disabled while an AI mask is being
  computed or a sync is running (`:303-308`).
- a divider, then **Delete All Masks** (destructive) (`:309-310`). History step **Delete All Masks**
  (`packages/RedlampUI/Sources/Model/EditorModel+Masking.swift:303-308`).

### 2.3 The strip under the header while a tool is armed (`DrawingHint`)

`packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:448-504`. A rounded card in the selection
colour, 10 pt of padding, with the armed tool's symbol (or `wand.and.rays` while refining edges) and
the hint, then the button at its right (`:472-484`).

**The hints, by tool** (`:451-465`) — exact strings:

| Armed | Hint |
| --- | --- |
| Refine Edge Brush | "Paint over an edge to solve it again from the photo, hair by hair. [ and ] or ⌘-scroll change the size." |
| Radial Gradient | "Drag on the photo to draw the radial gradient. Shift keeps it circular." |
| Brush | "Paint on the photo. Hold Option to erase; [ and ] or ⌘-scroll change the size, with Shift the feather. Hold Space to move the photo." |
| Color Range | "Click or drag on the photo to sample a color. Shift-click adds a sample (up to 5)." |
| Luminance Range | "Click on the photo to select tones like the one there." |
| Objects, with Drag = Rectangle | "Click an object, or drag a box around it, to select it. Click again to add to it, Option-click to take away." |
| Objects, with Drag = Brush | "Click an object, or brush over it, to select it. Click or brush again to add to it, with Option to take away." |
| Anything else (Linear Gradient) | "Drag on the photo from full effect to no effect." |

**Done or Cancel** (`:479-483`): the button reads **Done** while refining edges, or while a tool that
stays armed has already made its component (`model.drawingComponentID != nil`); otherwise **Cancel**.
Tools that stay armed are brush, Color Range, Luminance Range and Objects (`:468-470`). Either way it
calls `cancelDrawing()`. Automation identifier `masks.hint.done` (`:483`).

**The Refine Edge brush's Size** (`EdgeBrushSize`, `:507-527`), shown only while refining edges
(`:485-487`): the label **Size**, a mini slider over **1…100**, and a **value field** of the same
range (`FieldSpec(range: 1 ... 100)`, `:509`), width sized for `"100"`, identifier
`masks.edgeBrush.size` (`:517-521`). A spinner beside it shows while a stroke is being solved
(`:522-524`). The default is **12** (`packages/RedlampUI/Sources/Model/EditorModel.swift:543`).

**Objects' Drag choice** (`:488-495`), shown only while Objects is armed: a `ControlRow` labelled
**Drag** with a pop-up menu of **Rectangle** and **Brush**
(`packages/RedlampUI/Sources/Model/EditorModel+Objects.swift:5-17`), tooltip
**"What a drag on the photo selects with: a box around the object, or a stroke over it"** (`:493`).
`ChoiceMenu` is a `.menu`-style `Picker` with its label hidden
(`packages/RedlampUI/Sources/DesignSystem/ChoiceMenu.swift:22-31`) — a pop-up, not a segmented control.

### 2.4 Messages at the top of the list (`MaskMessages`)

`packages/RedlampUI/Sources/Inspector/MasksPanelNext.swift:309-359`. One of four, in this priority
order, shown in the panel's horizontal padding with 8 pt below (`:343-344`):

1. **A model's download question** — `ModelDownloadNotice()`, while `pendingModel != nil` (`:316-317`).
2. **A download in progress** — a progress bar 60 pt wide and the text
   **"Downloading model… \<n>%"** (`:318-322`).
3. **A mask being computed** — a spinner and either **"Updating AI masks…"** (when the kind is
   `.subject` and the edit already has AI masks, i.e. Update AI Masks is running) or
   **"Finding \<kind, lowercased>…"**, e.g. "Finding sky…", "Finding people…" (`:323-328`).
4. **A failure** — a `NoticeCard` in the caution tone holding `model.maskMessage`, with an ✕ to
   dismiss it and a link **Report…**, tooltip **"Report a Bug about this message"** (`:329-341`).
   Report… opens Report a Bug prefilled with the message and the masking feature suggested from what
   you were doing (`:331-336`).

2 and 3 are drawn as **a row in the list's place**: 28 pt tall, 8 pt of horizontal padding, a rounded
well — "as the mask being made will have" (`:347-358`).

**The download question** (`ModelDownloadNotice`,
`packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:415-445`). Its doc comment names App Review
4.2.3: "the size is shown, and nothing downloads without consent" (`:415-416`). It is an info-tone
`NoticeCard` with the symbol `arrow.down.circle.fill` (`:423-427`), holding, as one sentence:

> **"\<Kind> masks use \<Model name>, a \<size> download. It runs on this Mac; your photos are never
> uploaded. You can remove it in Settings › Models."** — plus **" Its licence: \<licence>."** when the
> model declares one (`:424-426`).

For example: "Objects masks use Segment Anything 2.1 (tiny), a 79.6 MB download. It runs on this Mac;
your photos are never uploaded. You can remove it in Settings › Models. Its licence: Apache-2.0."

Below it (`:428-442`):
- a link **"Read the licence"**, only when the licence ships with the download (`:429-431`);
- **Not Now** — identifier `masks.download.notNow` (`:433-434`); it clears the pending model, and for
  a People part also unticks that part in the People picker
  (`packages/RedlampUI/Sources/Model/EditorModel+AIMasks.swift:129-135`);
- **Download** — the default action, so Return presses it; identifier `masks.download` (`:435-440`).
  It downloads and then carries straight on with the mask that was asked for
  (`EditorModel+AIMasks.swift:108-127`). If the download fails:
  **"\<name> couldn't be downloaded: …"** (`:125`).

When the question is raised from a **tile in the picker**, the notice shows **inside the picker**,
below the tiles (`MasksPanelNext.swift:228-230`), as well as in the messages area; choosing Download
there dismisses the picker (`:229`, and `choose(_:)` at `:291-307`, which does not dismiss while a
model is needed, `:294-298`).

### 2.5 The picker (`MaskPicker`)

`packages/RedlampUI/Sources/Inspector/MasksPanelNext.swift:171-307`. The same view in two places:
**inline**, in the list's place when the photo has no masks (`:27-30`, `inline: true`), and in a
**popover 300 pt wide** from New Mask, Add, Subtract and Intersect (`:231-233`).

**Its title** says where the mask goes (`MaskPickerMode.title(targetName:)`, `:139-146`):

| Opened from | Title |
| --- | --- |
| New Mask, or inline with no masks | **New Mask** |
| Add, on a mask named Sky | **Add to Sky** |
| Subtract, on a mask named Sky | **Subtract from Sky** |
| Intersect, on a mask named Sky | **Intersect with Sky** |

**The three groups**, each with its name in small uppercase letters, and a three-column grid of tiles
(`MaskKindGroup`, `:150-166`; the grid at `:178`, `:191-203`):

| Group heading | Tiles, in order |
| --- | --- |
| **AI** | Subject, Sky, Background, People, Objects, Landscape |
| **DRAWN** | Brush, Linear Gradient, Radial Gradient |
| **RANGE** | Color Range, Luminance Range, Depth Range |

Note the AI group's order differs from `MaskKind.creatable`: the picker puts **People before Objects**
(`:162`), while `MaskKind.allCases` has objects before people
(`packages/RedlampEngineAPI/Sources/Masks.swift:710`). The old grid used `creatable`'s order.

**A tile** (`face(_:)`, `:273-289`): the kind's symbol at 16 pt above its name at 9.5 pt, at least
52 pt tall, on a rounded well. While that kind is being computed the symbol is replaced by a spinner
(`:275-277`). A tile that can't work is drawn in the tertiary label colour (`:286`).

- **Names and symbols** are `MaskKind.name` and `.symbol` —
  `packages/RedlampEngineAPI/Sources/Masks.swift:727-761`:

  | Label | Symbol | Shortcut | AI? |
  | --- | --- | --- | --- |
  | Subject | `person.crop.rectangle` | — | yes |
  | Sky | `cloud.sun` | — | yes |
  | Background | `rectangle.dashed` | — | yes |
  | People | `person.2` | — | yes |
  | Objects | `cube` | — | yes |
  | Landscape | `mountain.2` | — | yes |
  | Brush | `paintbrush.pointed` | `K` | |
  | Linear Gradient | `square.split.1x2` | `M` | |
  | Radial Gradient | `circle.circle` | `⇧M` | |
  | Color Range | `eyedropper.halffull` | `⇧J` | |
  | Luminance Range | `sun.max` | `⇧Q` | |
  | Depth Range | `square.3.layers.3d` | `⇧Z` | yes |

  `isAI` set: subject, sky, background, objects, people, landscape, depthRange (`:720-725`).
  Shortcuts: `packages/RedlampUI/Sources/Shortcuts/ShortcutAction.swift:347-352`. There is **no**
  shortcut for Subject, Sky, Background, Objects, People or Landscape **(inferred: `ShortcutAction`
  has no cases for them)**.

- **Each tile's tooltip and disabling** (`:268-270`): the tooltip is the kind's name when it can be
  made, and **"\<Kind> isn't available for this photo"** when it can't. A tile is disabled when
  `!model.canCreateMask(kind)` or while any AI mask is being computed (`:268`).
  `canCreateMask` is true for non-AI kinds, and for an AI kind only when the engine offers it for this
  photo — `packages/RedlampUI/Sources/Model/EditorModel+AIMasks.swift:8-11`. Unlike the old grid, the
  picker has **no "arrives in \<phase>" tooltip**; no kind is planned anyway
  (`MaskKind.plannedPhase` returns nil for every case,
  `packages/RedlampEngineAPI/Sources/Masks.swift:763-770`) **(inferred)**.
- **The People tile** opens the People picker (§2.8) and closes the popover — it is not a menu
  (`:242-248`).
- **The Landscape tile is a menu** of the seven classes, as the old grid's was (`:249-258`):
  Water, Vegetation, Mountains, Architecture, Natural Ground, Artificial Ground, Snow
  (`packages/RedlampEngineAPI/Sources/Masks.swift:465-482`). The menu indicator is hidden, so the tile
  looks like the others (`:258`).
- **Every other tile is a button** (`:259-265`), whose action (`choose(_:)`, `:291-307`) does one of
  three things:
  1. an AI kind whose model isn't on this Mac: records the question and **leaves the picker open**, so
     the download notice appears inside it (`:294-298`);
  2. People or Landscape with their model ready: closes the picker and computes the mask (`:300-301`);
  3. anything else: closes the picker and **arms the tool** on the canvas (`:302-303`).
- Automation identifier per tile: `masks.picker.<rawValue>`, e.g. `masks.picker.radial`,
  `masks.picker.luminanceRange`, `masks.picker.people` (`:270`).

**Existing Mask** (`:204-227`): shown only when the picker was opened from Add, Subtract or Intersect
(`mode.target != nil`) and the photo has at least one other mask. Heading **EXISTING MASK**; each row
is the other mask's name with its first component's symbol (`circle.dashed` when it has none).
Choosing one adds a reference component with the picker's operation and closes the picker (`:213-216`).

**With no masks the picker takes the list's place** —
`packages/RedlampUI/Sources/Inspector/MasksPanelNext.swift:26-30` (SwiftUI) and
`packages/RedlampUI/Sources/Inspector/AppKit/MasksPanelView.swift:121-123` (AppKit). Inline, its title
is drawn in the section font and secondary colour rather than as a popover heading (`:188-190`), and
it has no fixed width (`:231-233`).

**New masks are named** **Mask 1**, **Mask 2**, … — `MaskLayer(name: "Mask \(nextMaskNumber)")`, one
past the highest existing `Mask N` —
`packages/RedlampUI/Sources/Model/EditorModel+Masking.swift:79`, `:119`, `:130-133`. AI masks are
named after what they found: the kind's name, the person part's name, or the Landscape class's name —
`packages/RedlampUI/Sources/Model/EditorModel+AIMasks.swift:67-78`. A mask made from a preset takes the
preset's name (`EditorModel+MaskPresets.swift:88`). A mask decoded with no name falls back to `"Mask"`
(`packages/RedlampEngineAPI/Sources/Masks.swift:930` region).

### 2.6 The list's rows (`MaskList`, `actionsOnScreen: true`)

`packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:668-840`. **Newest first**
(`ForEach(model.maskOutlines.reversed())`, `:682`). Each row is **28 pt** tall, 8 pt of horizontal
padding, a rounded rectangle in the selection colour when selected, 2 pt between rows (`:681`,
`:747-749`).

> The design asks for 36 pt rows and a 36 × 24 pt thumbnail
> (`docs/plans/2026-10-07-masks-panel-design.md:25-28`); the code keeps 28 pt rows and a 30 × 20 pt
> thumbnail. The code is what the app shows.

Left to right:

1. **The thumbnail** (`MaskThumbnail`, `packages/RedlampUI/Sources/Inspector/MasksPanelNext.swift:397-417`):
   the mask's coverage, white where it covers, on black, 30 × 20 pt with a 3-pt corner radius, fitted
   to the photo's shape. Until it is drawn, the first component's symbol at 11 pt in the secondary
   colour, on no background (`:402-415`).
2. **The name** (`MaskingPanel.swift:703-706`), in the value colour, or the **tertiary** colour when
   the mask is hidden (`:705`).
3. **The eye** (`:708-731`): `eye` when the mask is shown, `eye.slash` when hidden.
   - Accessibility label: **"Hide \<name>"** or **"Show \<name>"** (`:723`).
   - Tooltip: **"Hide mask. Option-click to show it alone"** or
     **"Show mask. Option-click to show it alone"** (`:725-730`).
   - Identifier `masks.row.<uuid>.eye` (`:724`).
   - A plain click toggles that mask; **Option-click** calls `showMaskAlone` (`:709-716`), reading the
     modifier from the click's own event or the keyboard's.
4. **The menu button** (`:731-745`), shown when the row is **selected or under the pointer**:
   `ellipsis.circle` at 11 pt, no menu indicator, tooltip
   **"Rename, Duplicate, Save as Mask Preset, Delete"**, accessibility label
   **"\<name>'s actions"**, identifier `masks.row.<uuid>.menu`.

**The menu's items, in order** (`actions(for:)`, `:823-839`) — the same items are the row's
**context menu** (`:785-787`):

1. **Rename…** — puts a text field in the row.
2. **Invert** — a toggle, bound to the whole mask's `inverted`.
3. **Duplicate** — history "Duplicate \<name>"; the copy is named `"<name> Copy"`
   (`EditorModel+Masking.swift:230-252`).
4. **Duplicate and Invert** — history "Duplicate and Invert \<name>" (`:251`).
5. **Reset Adjustments** — history "Reset \<name>" (`EditorModel+Masking.swift:296-301`).
6. **Save as Mask Preset…**
7. a divider
8. **Delete \<name>** (destructive; the label interpolates the mask's name).

**Option-click on the eye** (`showMaskAlone`,
`packages/RedlampUI/Sources/Model/EditorModel+Masking.swift:284-294`): "that mask alone, or every mask
again when it already is alone. One history step, so the export shows what the canvas does."
The two history step names it records are **"Show Only \<mask name>"** and **"Show All Masks"** (`:293`).

**Other row behaviour:**
- Single click selects (`:779`); **double-click renames in place** through a text field whose
  placeholder is `"Name"`, identifier `masks.row.<uuid>.name` (`:693-701`, `:775-778`). Return commits.
- Renaming trims whitespace and refuses an empty name; history step **Rename Mask** —
  `EditorModel+Masking.swift:265-271`.
- An unfinished rename is cancelled when the selected mask or the selected photo changes (`:796-797`).
- **Drag a row onto another to reorder** (`:780-784`); the drop target draws an accent border
  (`Reorderable`, `:145-172`). Dragging is disabled on a row being renamed (`:780`). Masks add up, so
  reordering changes only the list — `EditorModel+Masking.swift:254-263` ("Masks add up, so the order
  changes only the list"); history step **Reorder Masks** (`:262`).
- Showing and hiding also records history: `"Hide \<name>"` / `"Show \<name>"` —
  `EditorModel+Masking.swift:273-276`.
- **The pointer over a row shows that mask's overlay** on the photo, overlay switch on or off: the row
  sets `model.hoveredMaskID` (`:755-764`), which `maskOverlayShown` prefers over the selected mask
  (`packages/RedlampUI/Sources/Model/EditorModel.swift:1343-1349`). A row taken away under the pointer
  clears it (`:765-774`), and so does the whole list going away (`:790-794`).
- The row carries the accessibility label of the mask's name, the `.isSelected` trait when selected,
  and the identifier `masks.row.<uuid>` (`:751-754`).

**Save as Mask Preset… asks for a name** (`:798-815`): an alert titled **Save Mask Preset**, with a
text field (placeholder `"Name"`) already holding the mask's name, a **Save** button and a **Cancel**
button, and the message **"A preset with the same name is replaced."**

### 2.7 The selected mask (`SelectedMaskEditor`, `usesPicker: true`)

`packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:842-928`, and the AppKit port's
`editorColumn` — `packages/RedlampUI/Sources/Inspector/AppKit/MasksPanelView.swift:141-174`. In order:

1. **The mask's header** — a `SubsectionHeader` whose title is the **mask's name, uppercased**
   (`packages/RedlampUI/Sources/DesignSystem/ParameterSlider.swift:245-251`), with
   `MaskHeaderControls` beside it: the **Invert** checkbox (tooltip "Invert the whole mask",
   identifier `masks.mask.invert`) and a **Reset** button (identifier `masks.mask.reset`) —
   `MaskingPanel.swift:850-854`, `:1213-1241`.
   Option-clicking the title does nothing here: the header is given an empty parameter list, and
   `resetMode` needs `!parameters.isEmpty` (`ParameterSlider.swift:245`) **(inferred)**.
2. **Amount** (`:855`).
3. A 6-pt gap, then the header **Components, applied top to bottom** (`:858`), uppercased by
   `SubsectionHeader` to read **COMPONENTS, APPLIED TOP TO BOTTOM**.
4. **One `ComponentRow` per component**, in the order they apply (`:859-861`).
5. **Add, Subtract and Intersect** as three buttons (`:862-869`, `MasksPanelNext.swift:361-393`).
6. **The selected component's own settings** (`:871-901`; see below).
7. A 6-pt gap, **Detail**, a 4-pt gap (`:909-912`).
8. The local sliders, with extra gaps after Tint, Blacks, Dehaze and Defringe (`:913-919`; §6).
9. The **Color** swatch (`:920`).
10. **Curve** (`:921`).
11. **Point Color** (`:923`; §6).

**A component row** (`ComponentRow`, `actionsOnScreen: true`,
`packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:1267-1417`). 26 pt tall, 8 pt of horizontal
padding, selected rows on the selection colour (`:1368-1370`). Left to right:

1. **The operation's icon, which is a menu** (`:1289-1305`): `plus`, `minus` or
   `circle.lefthalf.filled` at 9 pt bold, in a 14-pt frame, no menu indicator. Items:
   **Set to Add**, **Set to Subtract**, **Set to Intersect** (`:1403-1407`). Tooltip
   **"\<Operation>: choose how it combines"**; accessibility label the operation's name; identifier
   `masks.component.<uuid>.operation`.
2. **The kind's symbol** at 11 pt (`:1312-1313`).
3. **The name** (`title(_:)`, `:1276-1283`):
   - A **People** component reads **"\<Part> · Person \<n>"** — "Face Skin · Person 2" — where the
     number is the person's place in the photo's list, left to right
     (`personNumber`, `packages/RedlampUI/Sources/Model/EditorModel+PeoplePicker.swift:86-95`). When
     the person isn't known yet, it reads the part's name alone (`:1282`).
   - Every other kind reads **"\<Kind name> \<index>"**, 1-based: "Radial Gradient 1", "Subject 1".
     A component this build doesn't know reads **"Newer Component \<index>"** (`:1278`).
4. **The brush or eyedropper button** (`:1317-1332`), only for brush, Color Range and Luminance Range
   components: `paintbrush.pointed` with tooltip **"Paint into this brush"**, or `eyedropper` with
   tooltip **"Sample again"**. Identifier `masks.component.<uuid>.edit`.
5. **Invert** — a mini checkbox, identifier `masks.component.<uuid>.invert` (`:1333-1340`).
6. **The menu button** (`:1341-1356`): `ellipsis.circle` at 10 pt, no menu indicator. Its items
   (`:1343-1344`, `refinements` at `:1409-1416`):
   - for an AI component other than Depth Range: **Refine Edges**, **Refine Edge Brush**, a divider,
     then **Delete**;
   - for everything else: **Delete** alone.
   Tooltip **"Refine Edges, Refine Edge Brush, Delete"** for an AI component, **"Delete"** otherwise;
   accessibility label **"\<row's name>'s actions"**; identifier `masks.component.<uuid>.menu`.
7. **The context menu** (`:1397-1400`) holds the three operations and then the refinements — it has
   **no Delete**.

Other row behaviour:
- A click selects the component (`:1376`).
- **The pointer over a row previews that component's own coverage** on the photo: it sets
  `model.hoveredComponentID` (`:1377-1384`), and `componentPreview` adds a temporary one-component
  mask with no adjustments, overlaid, so what you see is that component alone
  (`packages/RedlampUI/Sources/Model/EditorModel+MaskThumbnails.swift:60-75`). With all 16 mask slots
  taken it falls back to the component's own mask (`:63-67`). A row taken away under the pointer
  clears it (`:1385-1391`).
- **Drag a component row onto another to reorder** (`:1392-1396`). Unlike masks this can change what
  the mask covers — `EditorModel+Masking.swift:178-188`; history step **Reorder Components** (`:185`).
- Deleting the last component deletes the whole mask —
  `EditorModel+Masking.swift:190-202`; history step **Delete Component** (`:196`).
- The row carries the accessibility label of its title, the `.isSelected` trait when selected, and the
  identifier `masks.component.<uuid>` (`:1372-1375`).

**Which component settings show** (`MaskingPanel.componentTools`,
`packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:936-946`): the brush's whenever brushing;
otherwise the selected component's, for radial, brush, colorRange, luminanceRange, and any AI kind.
With nothing selected it falls back to the **last** component
(`EditorModel+Masking.swift:15-19`). Linear Gradient, Existing Mask and unknown components have none.

| Selected component | What shows | Lines (SwiftUI / AppKit) |
| --- | --- | --- |
| Radial Gradient | **Feather** | `:871-874` / `MasksPanelView.swift:182-183` |
| Brush | the **Brush** picker (A, B, Erase), then **Size**, **Feather**, **Flow**, **Density**, then **Auto Mask** | `:875-881` / `:184-187` |
| Color Range | **Refine**, then the samples line and **Remove Last** | `:882-885` / `:188-189` |
| Luminance Range | the **Luminance Range** bar with its four handles and four value fields, then **Show Luminance Map** | `:886-888` / `:190-195` |
| Depth Range | the **Depth Range** bar with its four handles, four value fields and the end labels Far and Near | `:889-891` / `:196-197` |
| Any other AI kind | **Feather**, **Edge**, then the **Refine Edges** and **Refine Edge Brush** buttons | `:892-898` / `:198-203` |

**The AI component's two buttons** (`AIComponentTools`, `:1245-1265`): **Refine Edges**, tooltip
**"Solve the mask's edge again from the photo"**, identifier `masks.refineEdges`; and
**Refine Edge Brush**, tooltip **"Paint over an edge to solve it again, hair by hair"**, identifier
`masks.refineEdgeBrush`. They act on the component selected when they are clicked (`:1250`).

### 2.8 The People picker (`PeoplePickerView`)

`packages/RedlampUI/Sources/Inspector/PeoplePickerView.swift`. It opens **in the panel, where the list
was** (`OpenPeoplePicker`, `:176-186`; the design's decision 4,
`docs/plans/2026-10-07-masks-panel-design.md:120`), reached from the picker's People tile, from New
Mask or from Add, Subtract or Intersect. Top to bottom:

**Its title** (`:16-19`), in the section font and secondary colour:

| Opened from | Title |
| --- | --- |
| New Mask (no target) | **New People Mask** |
| Add, on a mask named Sky | **People · Add to Sky** |
| Subtract, on Sky | **People · Subtract from Sky** |
| Intersect, on Sky | **People · Intersect with Sky** |

**Finding people** (`:78-85`): until the engine answers, a small spinner and **"Finding people…"**.

**Nobody found** (`:51-55`): **"No people were found in this photo."** in the secondary colour, and
nothing else but Cancel and the (disabled) create button — the parts list and Separate masks are shown
only when someone was found (`:21-32`).

**All** (`:58-70`): a checkbox labelled **All**, shown only when **more than one** person was found.
Ticking it ticks everyone; unticking it unticks everyone. Identifier `masks.people.all`.

**The crops** (`crop(_:)`, `:88-128`): a grid of square tiles, each 64 pt wide, adaptive up to 84 pt,
8 pt apart (`:11`, `:71-75`). Each shows:
- a **square crop of the photo around the person's face**, or around the person when no face was
  found, taken from the photo **as shot** (no edit) at up to 1200 px; a face's square is 1.8× the
  face's longer side — `packages/RedlampUI/Sources/Model/EditorModel+PeoplePicker.swift:112-131`.
  Until the crop is ready, a `person.crop.square` glyph (`:98-101`).
- a **tick box** at the top left: `checkmark.square.fill` in the accent colour when ticked, an empty
  `square` in white when not (`:108-112`); and the crop's border is the accent colour, 2 pt, when
  ticked (`:106-107`).
- the person's **name** below: **"Person 1"**, **"Person 2"**, … by their place in the photo's list,
  left to right; **"Everyone"** when Vision couldn't tell people apart
  (`PeoplePicker.name(of:)`, `packages/RedlampUI/Sources/Model/EditorModel+PeoplePicker.swift:17-21`).
- **Tooltip:** **"Include Person 2"** when not ticked, **"Leave out Person 2"** when ticked (`:124`).
  Accessibility label: the person's name, with the `.isSelected` trait when ticked (`:125-126`).
  Identifier `masks.people.person.<id>` (`:127`).
- **The pointer over a crop outlines that person on the photo**: an accent-coloured rounded rectangle,
  2 pt, around their box — `:121-123` and
  `packages/RedlampUI/Sources/Editor/MaskOverlayView.swift:38-46`. It clears when the picker closes
  (`:47`).

Someone **alone in the photo starts ticked**; with more than one, none does
(`packages/RedlampUI/Sources/Model/EditorModel+PeoplePicker.swift:48`).

**The parts** (`partsList`, `:130-161`): the heading **PARTS**, then a two-column grid of checkboxes,
one per part the engine offers, in `PersonPart.allCases` order
(`availablePersonParts`, `packages/RedlampUI/Sources/Model/EditorModel+AIMasks.swift:13-16`):

| # | Label |
| --- | --- |
| 1 | Entire Person |
| 2 | Face Skin |
| 3 | Body Skin |
| 4 | Eyebrows |
| 5 | Eye Sclera |
| 6 | Iris and Pupil |
| 7 | Lips |
| 8 | Teeth |
| 9 | Hair |
| 10 | Facial Hair |
| 11 | Clothes |

Names: `packages/RedlampEngineAPI/Sources/Masks.swift:442-457`. **Entire Person** is ticked to start
(`PeoplePicker.parts = [.entirePerson]`,
`packages/RedlampUI/Sources/Model/EditorModel+PeoplePicker.swift:11`). Identifier per part:
`masks.people.part.<rawValue>`, e.g. `masks.people.part.faceSkin` (`:157`).

**A part that needs a model is marked** (`:144-151`): a small pill beside its name holding the model's
name — **SAM 3** — with the tooltip **"Needs SAM 3, a 988.1 MB download"**
(`"Needs \(needed.name), a \(needed.formattedSize) download"`). Ticking such a part **asks to download
it**, through the same notice as everywhere else; **Not Now** unticks the part
(`togglePersonPart`, `packages/RedlampUI/Sources/Model/EditorModel+PeoplePicker.swift:67-76`;
`declinePendingModel`, `EditorModel+AIMasks.swift:129-135`). Today that is Body Skin, Facial Hair,
Clothes and (without an embedded hair matte) Hair.

**Separate masks** (`:22-31`): a checkbox labelled **"Separate masks, one for each person"**, shown
only when the picker is making a **new** mask (no target) and **more than one** person is ticked.
Identifier `masks.people.separate`.

**The buttons** (`:33-45`), on one row, at the small control size:
- **Cancel** at the left — the Escape key presses it; identifier `masks.people.cancel`.
- the create button at the right — the Return key presses it; identifier `masks.people.create`.
  It is disabled when nobody is ticked, no part is ticked, or an AI mask is being computed (`:42`).

**The create button's title** (`createTitle`, `:163-168`):

| Case | Title |
| --- | --- |
| New mask, one person ticked, or Separate masks off | **Create Mask** |
| New mask, Separate masks on and 3 people ticked | **Create 3 Masks** |
| Opened from Add | **Add** |
| Opened from Subtract | **Subtract** |
| Opened from Intersect | **Intersect** |

**What Create makes** (`createPeopleMasks`,
`packages/RedlampUI/Sources/Model/EditorModel+PeoplePicker.swift:133-219`):
- one component per person per part, each named for its person (`:185-191`);
- added to the target with the picker's operation, when opened from Add, Subtract or Intersect
  (`:193-199`), history `"\(operation.name) \(title)"`;
- one mask per person with Separate masks on (`:200-207`), history **"New \<title> Masks"**;
- otherwise one mask holding them all (`:208-217`), history **"New \<title>"**. The mask's name is the
  part's name for a single part, otherwise **People**; when one person of several is ticked, it is
  named for them ("Face Skin · Person 2").
- Parts the model found none of are reported as **"Not found: Teeth, Lips."** (`:181-183`); when none
  of the parts was found at all, the usual `"No <part> were found in this photo."` (`:177-180`).
- The picker closes when the masks are made (`:218`).

### 2.9 Pins on the canvas

- **H** toggles them. Title **Show / Hide Pins or Spots**, key `H` —
  `packages/RedlampUI/Sources/Shortcuts/ShortcutAction.swift:249`, `:355`; handled in the Masking tool,
  and in the Healing tool, where it hides and shows the spots —
  `packages/RedlampUI/Sources/Model/EditorModel+Shortcuts.swift:145-147`, `:259`. The header's Pins
  switch does the same (§2.2).
- Default: **shown** (`showMaskPins = true`) —
  `packages/RedlampUI/Sources/Model/EditorModel.swift:604`.
- What it hides is both things: every **other** mask's pin, and the **selected** mask's component
  handles and guides — `packages/RedlampUI/Sources/Editor/MaskOverlayView.swift:50-86`.
- **Where a mask's pin goes (UX-23):** the point of its coverage **furthest inside it**, found from
  the row's thumbnail and mapped back through the crop, straightening and transform
  (`model.maskPins`, `packages/RedlampUI/Sources/Model/EditorModel.swift:502-504`;
  `refreshMaskThumbnails`, `packages/RedlampUI/Sources/Model/EditorModel+MaskThumbnails.swift:28-59`;
  `innermostPoint(of:)`, `:77-133`). The algorithm is a chamfer distance to the nearest uncovered
  pixel; among the points nearly as deep it takes the one nearest the coverage's centre, "so a band's
  pin sits in its middle and a ring's on the ring" (`:77-79`). A mask with no thumbnail yet falls back
  to its **first component's centre**
  (`packages/RedlampUI/Sources/Editor/MaskOverlayView.swift:50-51`;
  `packages/RedlampUI/Sources/Model/EditorModel.swift:503-504`).
- Component centres, the fallback's source: a gradient's midpoint, a brush's first non-erase point, a
  Color Range's first sample, an AI mask's stored centre; a Luminance Range uses its sample point or
  the image centre, and Existing Mask and unknown components sit at the image centre —
  `packages/RedlampEngineAPI/Sources/Masks.swift:626-640` region.
- **The pointer over a pin** previews that mask on the photo, overlay on or off: the pin sets
  `model.hoveredMaskID` (`MaskOverlayView.swift:55-68`), the same thing a row under the pointer does.
  Its tooltip is the **mask's name** (`:69`).
- **A click on a pin selects that mask** (`:54`). README: "Pins select the other masks" —
  `README.md:127`.
- A pin is a filled circle: 11 pt and white at 85% when unselected, 14 pt and accent-coloured when
  selected, with a black border and a 6-pt invisible margin so it is easy to hit —
  `packages/RedlampUI/Sources/Editor/MaskOverlayView.swift:457-468`.
- The selected mask's component pins can be **dragged to move** the component, and clicking one selects
  that component — `:484-521` (the generic handles), `:526-575` (linear), `:580-625` (radial).
- Guides are drawn "while a shape is being drawn too, so its guides follow the drag" (`:73`).

### 2.10 Value fields (UX-28)

Four of the Masks panel's values are **value fields** rather than read-only readouts: the overlay's
**Opacity**, the Refine Edge brush's **Size**, and the four stops of the **Luminance Range** and
**Depth Range** bars. They are the same control a slider row's number is.

- SwiftUI hosts it as `ValueFieldControl`
  (`packages/RedlampUI/Sources/DesignSystem/ValueFieldControl.swift:7-40`), which wraps the AppKit
  `ValueFieldView` and gives it the accessibility identifier the suite clicks (`:24-28`).
  `ValueFieldControl.width(for:)` sizes a field for its widest text (`:18-20`).
- **Scrub:** press and drag left or right. A press becomes a scrub after **3 pt** of movement
  (`scrubThreshold`), and a drag of **500 pt** covers the whole range (`scrubSpan`); **Shift** makes it
  ten times finer — `packages/RedlampDesign/Sources/Controls/ValueFieldView.swift:9-11`, `:157-172`.
  The drag is one history step (`onBegin` … `onEnd`, `:53-57`).
- **Type:** a press that doesn't move opens a text field in place (`:174-182`, `:187-206`).
  **Return** commits, **Escape** cancels, and the **up and down arrows** step by the spec's step,
  ten times as much with Shift (`:220-250`). Typed text is parsed by `ParameterSpec.evaluate`, so
  arithmetic such as `x+10` works (`packages/RedlampDesign/Sources/Controls/ValueFieldSpec.swift:48-50`).
- **What it looks like:** the number is right-aligned; the pointer over it shows a faint well behind it
  and the left-right resize cursor (`ValueFieldView.swift:4-6`, `:99-118`, `:145-149`).
- README's own description: "Click a value to type a new one, and use the arrow keys to step it
  (Shift steps by ten)" and "Drag a value left or right to scrub it, Shift for fine control; a drag is
  one history step" — `README.md:1173-1174`; and `README.md:151`, which lists where values were added
  (the Color Grading wheels, the tone curve, Base Look Amount) but **not yet** the Masks panel's.
- Specs used in the Masks panel:

  | Field | Spec | Where |
  | --- | --- | --- |
  | Overlay Opacity | `FieldSpec(range: 0 ... 100, unit: "%")` | `MaskingPanel.swift:97`, `:126-132` |
  | Refine Edge brush Size | `FieldSpec(range: 1 ... 100)` | `MaskingPanel.swift:509`, `:517-521` |
  | Luminance / Depth Range stops | `FieldSpec(range: 0 ... 100)` | `MaskingPanel.swift:1065`, `:1148-1162` |

  A `FieldSpec` formats as `String(format: "%.<digits>f", value) + unit`, so Opacity reads `55%` and a
  stop reads `40` (`packages/RedlampDesign/Sources/Controls/ValueFieldSpec.swift:44-46`).

---

## 3. Each mask kind

### Linear Gradient (`M`)

- Make it: **drag on the photo from full effect to no effect.** The hint is the default branch —
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:463`.
- Geometry: "Full effect at `start`, fading to no effect at `end`" —
  `packages/RedlampEngineAPI/Sources/Masks.swift:21-35`.
- **A click without a drag** (movement under 4 pt) places a default gradient: from the click, 0.25 of
  the image height downwards — `packages/RedlampUI/Sources/Editor/MaskOverlayView.swift:117-126`.
- Handles: two round handles, one at each end, each dragging that end; a pin at the centre dragging the
  whole gradient — `:526-575`. Two solid lines mark start and end, and a dashed line the centre.
- **It has no controls of its own** in the panel: `componentTools` returns `nil` for `.linear`
  (`MaskingPanel.swift:944`), so only the mask's own settings show. There is no rotation handle;
  rotation is implicit in where the two ends are **(inferred from `LinearMask` having only `start` and
  `end`)**.
- History: **New Linear Gradient** / **Add Linear Gradient** (`"New \(kind.name)"` /
  `"Add \(kind.name)"`) — `packages/RedlampUI/Sources/Model/EditorModel+Masking.swift:84`, `:116`,
  `:122`.
- Cursor over the canvas while armed: crosshair — `MaskOverlayView.swift:28-35`.

### Radial Gradient (`⇧M`)

- Hint: "Drag on the photo to draw the radial gradient. Shift keeps it circular." —
  `MaskingPanel.swift:457`.
- The drag's start is the **centre**, and the drag sets the two radii —
  `MaskOverlayView.swift:129-145`. **A click without a drag** places an ellipse with `radiusX 0.22`,
  `radiusY 0.16` (`:122-123`).
- Radii are fractions of the image **height**, "so a circle stays round whatever the aspect ratio";
  rotation is in degrees clockwise; full effect inside by default —
  `packages/RedlampEngineAPI/Sources/Masks.swift:37-54`.
- Handles: one on each axis to resize, plus a smaller handle just outside the ellipse with tooltip
  **"Drag to rotate"**, plus the centre pin to move — `MaskOverlayView.swift:580-625`. The solid
  ellipse is the outer edge, the dashed one the inner, full-effect edge, drawn at `1 - feather/100`.
- Its one control: **Feather**, range **0…100**, default **50**, integer —
  `packages/RedlampEngineAPI/Sources/ParameterSpec.swift:434`; `RadialMask.feather` default 50
  (`Masks.swift:46`), documented "0...100, as in Lightroom" (`:43`).
- History: **New Radial Gradient** / **Add Radial Gradient**; dragging a handle records
  "Edit \<mask name>", and the rotate handle "Rotate \<mask name>" —
  `MaskOverlayView.swift:635-680` region.
- README: "Drag the handles to move, resize, and rotate; radial gradients also have a Feather
  control." — `README.md:126`.

### Brush (`K`)

Full detail in §4. In summary:

- Hint: "Paint on the photo. Hold Option to erase; [ and ] or ⌘-scroll change the size, with Shift the
  feather. Hold Space to move the photo." — `MaskingPanel.swift:459`.
- The tool **stays armed** until Done; every stroke goes into the same component —
  `MaskingPanel.swift:468-470`, `packages/RedlampUI/Sources/Model/EditorModel+Brush.swift:42-58`.
- Controls: the **Brush** picker (A / B / Erase), then **Size**, **Feather**, **Flow**, **Density**,
  then the **Auto Mask** checkbox — `MaskingPanel.swift:875-881`.
- History: **New Brush** on the first stroke, then **Brush Stroke**, or **Erase Brush** for an erase
  stroke — `EditorModel+Brush.swift:48`, `:89`.

### Color Range (`⇧J`)

- Hint: "Click or drag on the photo to sample a color. Shift-click adds a sample (up to 5)." —
  `MaskingPanel.swift:458`.
- Click samples a spot; **drag outwards to average over a disc** — the disc's radius is the drag
  distance, and a drag under 4 pt counts as a spot (radius 0) —
  `MaskOverlayView.swift:300-307`. The disc is previewed as a white circle while dragging (`:280-287`).
- **Shift** adds a sample rather than replacing the samples (`:306`, and the view's comment at `:263`).
- Samples are drawn on the canvas as white rings, at least 10 pt across, only while the component is
  selected — `MaskOverlayView.swift:500-510`.
- Controls: **Refine**, range **0…100**, default **50**, integer
  (`packages/RedlampEngineAPI/Sources/ParameterSpec.swift:440`; `ColorRangeMask.refine` default 50 at
  `Masks.swift:176`, documented "0...100: how far from the samples a colour may be and still be
  selected" at `:173-174`); then a line reading **"\<N> of 5 samples"** with a **Remove Last** button,
  shown only when more than one sample is left — `ColorSampleList`,
  `MaskingPanel.swift:982-999`; identifier `masks.colorRange.removeLast` (`:995`).
- To start again, the **eyedropper** on the component's row, tooltip "Sample again" (§2.7).
- The selection is read from the edited photo: "Colours are read from the photo every render, so the
  selection follows the global edit's white balance" — `Masks.swift:167-168`.
- The tool stays armed until Done (`MaskingPanel.swift:468-470`).

### Luminance Range (`⇧Q`)

- Hint: "Click on the photo to select tones like the one there." — `MaskingPanel.swift:460`.
- Controls (`LuminanceRangeBar` and `LuminanceMapToggle`, `MaskingPanel.swift:1011-1037`):
  - the heading **Luminance Range** above a black-to-white bar with **four handles**
    (`RangeBar`, `:1054-1178`);
  - **four value fields** under the bar, one per handle (`:1103-1110`, `:1148-1162`);
  - a checkbox **Show Luminance Map**, identifier `masks.luminanceMap` (`:1024-1037`).
- The four handles, left to right, and the tooltip of each field under them (`RangeBar.stopNames`,
  `:1066-1068`, applied at `:1161`):

  | # | What it is | Tooltip | Identifier |
  | --- | --- | --- | --- |
  | 1 | where the range starts (the lower feather's outer end) | **"Where the range starts"** | `masks.luminanceRange.stop1` |
  | 2 | where it becomes full | **"Where it's full from"** | `masks.luminanceRange.stop2` |
  | 3 | where it stops being full | **"Where it stops being full"** | `masks.luminanceRange.stop3` |
  | 4 | where it ends | **"Where it ends"** | `masks.luminanceRange.stop4` |

  The inner two handles are drawn wider (7 pt vs 5 pt) and brighter (`:1092-1098`). Each field is
  0…100, typed or scrubbed, and records one history step named **Luminance Range** (`:1148-1162`).
- Defaults when created directly: `lower 50`, `upper 100`, `lowerFeather 10`, `upperFeather 0` —
  `Masks.swift:121-127`.
- Defaults **after the eyedropper samples**: the range is centred on the sampled lightness, ±10, with
  both feathers 15 — `LuminanceRangeMask.sampled(lightness:at:)`, `Masks.swift:145-152`.
- Every bound is clamped to 0…100 and kept in order (`normalized`, `:136-143`).
- Lightness is OKLab L × 100 of the photo **with its global edit**, before local adjustments
  (`:111-112`).
- The tool stays armed until Done.
- README: "sample with the eyedropper, then shape the range with four handles (Show Luminance Map)…"
  — `README.md:129`.

### Depth Range (`⇧Z`)

- Controls: the same four-handle bar (`DepthRangeEditor`, `MaskingPanel.swift:1040-1051`), titled
  **Depth Range**, with the end labels **Far** (left) and **Near** (right) under it (`:1111-1119`), a
  dark-to-light grey gradient, and **no** luminance-map checkbox. Its fields' identifiers are
  `masks.depthRange.stop1` … `stop4`, with the same four tooltips. History name **Depth Range**.
- Defaults: `lower 60`, `upper 100`, `lowerFeather 15`, `upperFeather 0`; 0 is farthest, 100 nearest
  — `Masks.swift:404-419` region.
- Source of the depth map: the file's own (iPhone depth), else Depth Anything 3 if downloaded, else the
  Depth Anything V2 (small) estimator —
  `packages/RedlampEngine/Sources/RedlampEngine+Masks.swift` (the depth path).
- It is an AI kind (`isAI`), so it is computed and kept as a bitmap, and it has **no** Feather/Edge
  sliders: `componentTools` routes `.depthRange` to its own editor before the generic AI branch
  (`MaskingPanel.swift:889-891`).
- No Refine Edges or Refine Edge Brush: both are gated on `kind != .depthRange` —
  `MaskingPanel.swift:1411`, and `AIComponentTools` is reached only through the AI branch, which
  Depth Range doesn't take.

### Subject, Background

- Both come from Apple Vision's built-in models, with nothing to download:
  `VisionMaskProvider.supportedKinds = [.subject, .background, .people]` —
  `packages/RedlampMasking/Sources/VisionMasks.swift:46`.
- No model prompt: `modelID(for:)` returns `nil` for them —
  `packages/RedlampEngine/Sources/RedlampEngine+Models.swift:8-16`.
- Make them: one click on the tile; there is nothing to drag. Progress shows as
  **"Finding subject…"** / **"Finding background…"** in the messages row (§2.4).
- Failure messages: "No subject was found in this photo." / "No background was found in this photo."
  (`"No \(kind.name.lowercased()) was found in this photo."`) — `packages/RedlampEngineAPI/Sources/Masks.swift:584`.
- Controls: **Feather** and **Edge** (§5), with **Refine Edges** and **Refine Edge Brush** beside them.
- Mask name and history: "Subject" / "Background", history **New Subject** / **New Background** —
  `packages/RedlampUI/Sources/Model/EditorModel+AIMasks.swift:67-78`.

### Sky

- Available on every Mac with no download: `availableMaskKinds()` inserts `.sky` unconditionally —
  `packages/RedlampEngine/Sources/RedlampEngine+Masks.swift:259-261`. `modelID(for: .sky)` is `nil`,
  so Sky never shows the download prompt **(inferred)**.
- Quality improves once Depth Anything 3 is downloaded, but it is not required —
  `RedlampEngine+Masks.swift:52-56`; `docs/lightroom-comparison.md:114`.
- Failure message: "No sky was found in this photo." — `Masks.swift:584`.
- Controls: Feather and Edge (§5).
- README's description of how it is built is at `README.md:130`; it is engine internals and out of
  scope for the manual.

### People, and each part

- Make it: the **People** tile in the picker opens the **People picker** (§2.8). There is no longer a
  menu of parts on the tile, and no "entire person straight away" shortcut: Entire Person is simply the
  part ticked to start.
- The eleven parts and their sources:

  | # | Label | Source |
  | --- | --- | --- |
  | 1 | Entire Person | Apple Vision |
  | 2 | Face Skin | Apple Vision |
  | 3 | Body Skin | SAM 3 |
  | 4 | Eyebrows | Apple Vision |
  | 5 | Eye Sclera | Apple Vision |
  | 6 | Iris and Pupil | Apple Vision |
  | 7 | Lips | Apple Vision |
  | 8 | Teeth | Apple Vision |
  | 9 | Hair | the photo's own hair matte (iPhone portraits), else SAM 3 |
  | 10 | Facial Hair | SAM 3 |
  | 11 | Clothes | SAM 3 |

  The SAM 3 parts are `SAM3Concepts.partPrecedence = [.facialHair, .hair, .clothes, .bodySkin]` —
  `packages/RedlampMasking/Sources/SAM3Concepts.swift:30`; `availablePersonParts()` removes them and
  always adds Hair back, then adds them all when SAM 3 is offered —
  `packages/RedlampEngine/Sources/RedlampEngine+Masks.swift:277-283`. An iPhone's own hair matte beats
  SAM 3's (`:316-317`).
- **One component per person, per part.** The picker makes a component for each ticked person and each
  ticked part — `packages/RedlampUI/Sources/Model/EditorModel+PeoplePicker.swift:160-175`. Subtracting
  or intersecting puts them all into one target mask, the first carrying the operation (`:193-199`).
- **Each component names its person:** "Face Skin · Person 2" (§2.7). A face part is numbered by its
  face rather than by the person (`faceParts`, `EditorModel+PeoplePicker.swift:25`, `:86-95`).
- Failure messages:
  - no people at all: "No people were found in this photo." — `Masks.swift:582`
  - a part missing: `"No <part, lowercased> was/were found in this photo."` (plural for Eyebrows,
    Iris and Pupil, Lips, Teeth, Clothes) — `:458-461`, `:571-573`, `:585`
  - Hair with no matte and no SAM 3: "Hair masks need a photo with its own hair matte, such as an
    iPhone portrait." — `:586`
  - Body Skin / Facial Hair / Clothes with no SAM 3: `"<Part> masks need the SAM 3 evaluation
    model."` — `:587`. **Contradiction, see §10:** SAM 3 isn't evaluation-only in its manifest, and in
    the new panel ticking such a part asks to download it instead, so a photographer should rarely see
    this string.
- Controls: Feather and Edge (§5).

### Objects

- Make it, step by step:
  1. Pick **Objects** in the picker. A hover preview begins: moving the pointer tints what a click
     would select, in the accent colour at 45% —
     `packages/RedlampUI/Sources/Editor/MaskOverlayView.swift:316-400` region; the preview waits 40 ms
     after the pointer settles (`packages/RedlampUI/Sources/Model/EditorModel+Objects.swift:46`).
  2. **Click** the object, or **drag** — what a drag does is set by **Drag** in the strip under the
     header (§2.3).
  3. **Click or brush again to add**, **Option-click or Option-brush to take away**.
  4. **Done** in the strip.
- A box drag is drawn as a white dashed rectangle; a brush drag as a 16-pt accent-coloured stroke
  (`MaskOverlayView.swift:322-345` region). A drag needs 4 pt of movement to count.
- A brushed stroke becomes up to **8** prompt points spread evenly along it —
  `EditorModel+Objects.swift:110-126` region.
- History names: **New Objects** on the first selection, then **Add to Object**,
  **Remove from Object**, or **Box Around Object** — `EditorModel+Objects.swift:95`.
- Failure message: "Nothing was found to select there." — `Masks.swift:583`.
- Needs a download the first time: Segment Anything 2.1 (tiny), 79.6 MB — see §5.
- Controls: Feather and Edge (§5). The tool stays armed until Done.

### Landscape, its categories, and the adaptive presets

- **The Landscape tile opens a menu of classes** — there is no plain "Landscape" command —
  `packages/RedlampUI/Sources/Inspector/MasksPanelNext.swift:249-258`.
- Classes in menu order, with their exact labels — `LandscapeClass.allCases`,
  `packages/RedlampEngineAPI/Sources/Masks.swift:465-482`:
  1. **Water** 2. **Vegetation** 3. **Mountains** 4. **Architecture** 5. **Natural Ground**
  6. **Artificial Ground** 7. **Snow** (marked in the code as "Lightroom Classic 15's", `:468`)
- Sky is a mask kind of its own, not a Landscape class (`:464`). Each pixel belongs to exactly one
  class (`:464`).
- The mask is named after the class, e.g. "Mountains"; history **New Mountains** —
  `EditorModel+AIMasks.swift:67-78`.
- Failure message: `"No mountains were found in this photo."` — plural only for Mountains (`:490-493`).
- Needs SAM 3 (988.1 MB), and the picker asks for it in place — see §5.
- **The adaptive Landscape presets** are mask presets, in the Presets menu, not in the Landscape
  submenu: **Brighten Snow** and **Enhance Vegetation** — see §8.
- **The Landscape picker** of the design (the regions SAM 3 finds, with their share of the photo) is
  **not built**: UX-26 is "Not started" (`docs/research/research-tracker.md:332`).
- Controls: Feather and Edge (§5).

---

## 4. The brush in detail

### A, B and Erase

- Three brushes: `BrushChoice` with raw values **A**, **B**, **Erase** —
  `packages/RedlampUI/Sources/Model/BrushSettings.swift:5-10`. The picker is a `ControlRow` labelled
  **Brush** holding a pop-up menu, tooltip
  **"A, B and Erase each keep their own size, feather, flow and density; Erase takes paint away"** —
  `BrushChoicePicker`, `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:949-960`. (It is a
  pop-up, not a segmented control: `ChoiceMenu` uses `.pickerStyle(.menu)`,
  `packages/RedlampUI/Sources/DesignSystem/ChoiceMenu.swift:28`.)
- The active brush starts as **A** — `packages/RedlampUI/Sources/Model/EditorModel.swift:538`.
- **Option switches to Erase for as long as it is held**: `strokeBrush(erasing:)` returns `.erase`
  while Option is down or Erase is chosen —
  `packages/RedlampUI/Sources/Model/EditorModel+Brush.swift:21-26`.
- Erasing takes coverage away: `BrushStroke.erase` — "Removes coverage instead of adding it"
  (`packages/RedlampEngineAPI/Sources/Masks.swift:68-69`).
- You cannot start a mask with an erase stroke: "Nothing to erase from yet" —
  `EditorModel+Brush.swift:50-55`.
- The three brushes keep separate settings, saved across launches in `UserDefaults` under
  `app.redlamp.brushes` — `BrushSettings.swift:87`.
- Their **built-in starting settings** differ — `BrushSettings.swift:64-66` with the `BrushSettings`
  defaults at `:13-30`:

  | Brush | Size | Feather | Flow | Density | Auto Mask |
  | --- | --- | --- | --- | --- | --- |
  | A | 25 | 50 | 100 | 100 | off |
  | B | 8 | 20 | 100 | 100 | off |
  | Erase | 15 | 50 | 100 | 100 | off |

### The sliders

Shown in this order (`ParameterID.brushParameters`,
`packages/RedlampEngineAPI/Sources/ParameterID.swift:220-223`; rendered at
`MaskingPanel.swift:877-880` and `MasksPanelView.swift:185-186`):

| Label | Range | Default | Step | Format | Source |
| --- | --- | --- | --- | --- | --- |
| Size | 1…100 | 25 | 1 | integer | `ParameterSpec.swift:435` |
| Feather | 0…100 | 50 | 1 | integer | `:436` |
| Flow | 1…100 | 100 | 1 | integer | `:437` |
| Density | 1…100 | 100 | 1 | integer | `:438` |

The defaults above are the catalog's; the value a slider shows is the **active brush's** saved one
(`EditorModel+Masking.swift:335-340`), which for B and Erase starts differently (table above).

What each does, from the stroke model (`Masks.swift:56-71`):
- **Feather** — "0...100: the share of the radius that fades out" (`:62-63`).
- **Flow** — "0...100: how much each dab adds, so overlapping dabs build up" (`:64-65`).
- **Density** — "0...100: the most coverage the stroke can reach" (`:66-67`).
- **Size** is stored on the stroke as a radius in image heights, not as the 1–100 slider value:
  `radius = 0.003 + 0.3 × (size/100)²` — "from a few pixels to a third of it, finer at the small end
  where precision matters" — `BrushSettings.swift:33-37`, `Masks.swift:60-61`.

### Auto Mask

- Checkbox labelled **Auto Mask**, tooltip **"Keeps the brush to colors like the one under its
  center"**, identifier `masks.brush.autoMask` — `MaskingPanel.swift:962-979`.
- It is per brush (A, B and Erase each have their own) — the binding reads
  `model.brushes[model.activeBrush].autoMask` (`:966-969`).
- Model comment: "Keeps each dab to colours like the one under its centre (Lightroom's Auto Mask)" —
  `Masks.swift:70-71`.

### Pen pressure

- Recorded per point: `BrushStroke.pressures`, "Pen pressure at each point, 0...1. Empty when the
  input had none (full pressure)." — `Masks.swift:57-58`.
- Read only from tablet events; mice paint at full pressure — `MaskOverlayView.swift:213-262` region.

### Size and feather shortcuts

- **`[` and `]`**: size, or feather with **Shift**. The keys are the rating keys, redirected while a
  brush's tool is active: `case .decreaseRating where sizedBrush != nil` —
  `packages/RedlampUI/Sources/Model/EditorModel+Shortcuts.swift:163-164`. `sizedBrush` is `.mask` only
  while brushing — `packages/RedlampUI/Sources/Model/EditorModel+BrushSize.swift:24-36`.
- Step sizes: size moves by **15% of its value, at least 1**; feather by **10** —
  `EditorModel+Brush.swift:94-108`.
- **⌘-scroll** over the photo: size grows by about **15% a notch** (`pow(1.15, notches)`), or feather by
  **5 a notch** with Shift — `EditorModel+BrushSize.swift:56-76`.
- Both are clamped to the parameters' ranges (`EditorModel+Brush.swift:97`, `:100-104`).
- A ring shows the size as it changes: an outer solid circle at the full radius and an inner dashed
  circle at `radius × (1 − feather/100)`, with a readout **"Size \<n>  ·  Feather \<n>"**, and a `minus`
  glyph in the middle when Erase is active — `MaskOverlayView.swift:146-212`, readout at `:189-191`.
- README: "`[` and `]` or ⌘-scroll change the size, with Shift the feather; the brush's ring shows its
  size as it changes, also from the panel's sliders" — `README.md:128`.

### Space-drag to move the photo

- Hold **Space** and drag to pan while painting — `beginSpacePan` / `noteSpacePanUse` / `endSpacePan`
  in `EditorModel+BrushSize.swift:78-103`; the file's own summary is "Sizing brushes from the keyboard
  and pointer, and panning with Space, in every tool (UX-15)" (`:16`).
- A Space press with **no** click or drag toggles the zoom instead (`:91-99`).
- It applies in every tool that draws over the canvas: masking, crop, heal and guide placing (`:19-22`).
- README: "hold `Space` and drag to move the photo in a tool" — `README.md:1158` region; and
  "Space-drag moves the photo while you paint." — `README.md:128`.

### Painting into an existing brush component

- The `paintbrush.pointed` button on a brush component row re-arms the brush on that component,
  tooltip **"Paint into this brush"** — `MaskingPanel.swift:1317-1331`,
  `EditorModel+Brush.swift:11-21`.
- Points closer than a tenth of the radius to the last are skipped (`EditorModel+Brush.swift:63-75`
  region).
- Strokes are kept as vectors in the edit, so brush masks live in `edit.json` rather than as PNGs —
  `README.md:128`, and "Brush strokes and range masks are part of the JSON" at `README.md:1178`.

---

## 5. AI masks

### Which model each kind uses

| Mask kind | Model | Download | Asks on first use? |
| --- | --- | --- | --- |
| Subject | Apple Vision (built into macOS) | none | no |
| Background | Apple Vision | none | no |
| People — Entire Person, Face Skin, Eyebrows, Eye Sclera, Iris and Pupil, Lips, Teeth | Apple Vision | none | no |
| People — Hair | the photo's own hair matte; else SAM 3 | none / 988.1 MB | **yes**, when ticked in the People picker |
| People — Body Skin, Facial Hair, Clothes | SAM 3 | 988.1 MB | **yes**, when ticked in the People picker |
| Sky | Apple Vision + a classical estimate, improved by Depth Anything 3 when present | none (DA3 optional, 336.1 MB) | no |
| Objects | Segment Anything 2.1 (tiny) | 79.6 MB | **yes** |
| Landscape (all seven classes) | SAM 3 | 988.1 MB | **yes** |
| Depth Range | the photo's own depth map; else Depth Anything 3 if downloaded; else Depth Anything V2 (small) | none / 49.8 MB | **yes**, unless the photo has its own depth map |
| Subject, Background and People edges, with Refine Edges | ViTMatte (base), when downloaded | 108.9 MB, optional | no — it is never asked for; download it in Settings › Models |

Sources: the kind→model map `RedlampEngine.modelID(for:)` —
`packages/RedlampEngine/Sources/RedlampEngine+Models.swift:8-18` (objects → `sam2.1-tiny`,
depthRange → `depth-anything-v2-small`, landscape → `sam3`, everything else `nil`);
`modelNeeded(for:)` returns `nil` for a photo with an embedded depth map (`:28-38`);
`modelNeeded(for:part:)` answers SAM 3 for the four parts (`:40-46`);
Vision's kinds `packages/RedlampMasking/Sources/VisionMasks.swift:46`; Sky always available
`packages/RedlampEngine/Sources/RedlampEngine+Masks.swift:259-261`; person-part sources
`:277-283` and `packages/RedlampMasking/Sources/SAM3Concepts.swift:30`.

**The People parts now ask.** The People picker calls `modelNeeded(for:part:)` for every part it offers
and marks those that need one; ticking such a part sets `pendingModel`, so the download notice appears
(`packages/RedlampUI/Sources/Model/EditorModel+PeoplePicker.swift:67-84`), and Create asks again before
making anything (`:143-148`). The old panel's People submenu went straight to `createAIMask` and
skipped the prompt; that path is retired.

### The models, their sizes and licences

From the manifests in `packages/RedlampMasking/Resources/Models/` (sizes are the sum of each manifest's
`files[].bytes`, and the app formats them with `ByteCountFormatter` `.file`, i.e. decimal MB —
`packages/RedlampEngineAPI/Sources/Models.swift:61-63`):

| Manifest | `name` (shown) | `purpose` (shown) | Size | Weights licence | `LICENSE.txt` ships? |
| --- | --- | --- | --- | --- | --- |
| `sam2.1-tiny.json` | Segment Anything 2.1 (tiny) | "Objects masks: click an object to select it, click again to add or remove parts." | 79,644,968 B → **79.6 MB** | Apache-2.0 | no |
| `sam3.json` | SAM 3 | "Landscape masks (water, vegetation, mountains, architecture, natural and artificial ground) and the People parts Vision can't give: hair, facial hair, body skin and clothes." | 988,085,795 B → **988.1 MB** | SAM License | yes |
| `depth-anything-3-mono-large.json` | Depth Anything 3 (mono, large) | "Sky masks (with Segment Anything) and Depth Range masks, from one model." | 336,101,695 B → **336.1 MB** | Apache-2.0 | yes |
| `depth-anything-v2-small.json` | Depth Anything V2 (small) | "Depth Range masks for photos without an embedded depth map." | 49,819,122 B → **49.8 MB** | Apache-2.0 | no |
| `vitmatte-base.json` | ViTMatte (base) | "Stray hairs on the edges of Subject, Background and People masks." | 108,850,800 B → **108.9 MB** | Apache-2.0 (code MIT) | yes |
| `owlv2-base.json` | OWLv2 (base) | "Finding things named in words to remove: litter, signs, cables, cars, people, birds." | 365,102,113 B → **365.1 MB** | Apache-2.0 | yes |
| `flux2-klein-4b-fill.json` | FLUX.2 [klein] 4B | "Generative Remove: fills areas too large for content-aware Remove, labelled as generated fill." | 2,414,734,243 B → **2.41 GB** | Apache-2.0 | yes |

OWLv2 and FLUX.2 belong to removal, not masking, but they appear in the same Settings › Models list
**(inferred: the list shows every `ModelCatalog.offered` manifest,
`packages/RedlampEngine/Sources/RedlampEngine+Models.swift:20-26`)**.

- All seven manifests are `cleared: true, evaluationOnly: false`, so **none** is evaluation-only today;
  every one is offered by default (`ModelCatalog.offered`,
  `packages/RedlampMasking/Sources/Models/ModelManifest.swift:99-101`).
- FLUX.2 declares `testedMemory: 17179869184` (16 GiB); no masking model sets a memory limit. A Mac
  with less memory than a model's `minimumMemory` sees **"Not for this Mac"** and
  **"Needs 16 GB of memory; this Mac has 8 GB."** —
  `packages/RedlampEngineAPI/Sources/Models.swift:65-69`,
  `packages/RedlampUI/Sources/Settings/ModelsSettings.swift:90`. Below a model's `testedMemory` it is
  still offered, with **"Not tested on Macs with less than 16 GB of memory; it may be slow or not work
  on this one (8 GB)."** (`Models.swift:71-76`).

### Settings › Models

File: `packages/RedlampUI/Sources/Settings/ModelsSettings.swift`. Exact strings:
- Empty list: **"No downloadable models."** (`:16`).
- First section footer: **"Subject, Background, People and Sky masks use models built into macOS.
  Others are downloaded only when you first use them. Every model runs on this Mac: photos are never
  uploaded."** (`:23-26`).
- Per row: the model's `name`, its `purpose` in caption, then **"Licence: \<licence>"** with a
  **"Read it"** link when the licence ships with the download (`:56-58`). So **"Read it" appears for
  SAM 3, Depth Anything 3, ViTMatte, OWLv2 and FLUX.2**; `sam2.1-tiny` and `depth-anything-v2-small`
  show the licence name without a link **(inferred from the manifests' `files` lists)**.
- A model awaiting review: **"Awaiting licence review (\<decision>)."** (`:68`).
- Right-hand control, by state (`:84-92`): downloaded → **Remove**; downloading → a spinner or a
  progress bar; not published → **"Not published"**; doesn't fit → **"Not for this Mac"**; otherwise
  **"Download 988.1 MB"** (the label is `"Download \(model.formattedSize)"`).
- Second section: a toggle **"Offer models awaiting licence review"** (`:29`), stored as
  `app.redlamp.evaluationModels`
  (`packages/RedlampMasking/Sources/Models/ModelManifest.swift:90`); `REDLAMP_EVALUATION_MODELS=1` has
  the same effect.
- Failure: **"\<name> couldn't be downloaded: …"** or **"\<name> couldn't be removed: …"** (`:111`,
  `:121`).
- README: "Settings › Models lists the downloadable models with their size, and removes them…" —
  `README.md:137`.

### Update AI Masks

- Where: the header's `ellipsis.circle` menu — **Update AI Masks**, and
  **"Update AI Masks on N Photos"** while several photos are selected (§2.2).
- What it does: recomputes every AI mask of the edit with today's models, "keeping each component's
  place, operation and inversion. A person is matched by their index." —
  `packages/RedlampUI/Sources/Model/EditorModel+AIMasks.swift:147-160`. Refine Edge strokes are applied
  again to the new mask (`:193-200`).
- Why it exists: AI masks are computed from the photo without its edit and kept as bitmaps, so they
  never move as you edit (`README.md:131`).
- Pasted or synced settings recompute their AI masks for the new photo automatically —
  `packages/RedlampUI/Sources/Model/EditorModel+MaskPresets.swift` (the paste path),
  `packages/RedlampUI/Sources/Model/EditorModel+Sync.swift`.
- If some can't be updated: **"N AI masks couldn't be updated and kept their previous result."**
  (singular "mask" for one) — `EditorModel+AIMasks.swift:156-158`.
- History step: **Update AI Masks** (`:159`).
- Progress shows as **"Updating AI masks…"** in the messages row (§2.4).

### Refine Edges

- Where, in the new panel: a **button** under an AI component's Feather and Edge, tooltip
  **"Solve the mask's edge again from the photo"**, identifier `masks.refineEdges`
  (`MaskingPanel.swift:1252-1254`); and **Refine Edges** in the component row's menu button and context
  menu (`:1409-1416`). Not for Depth Range.
- What it does, for a photographer: it solves the mask's edge again from the photo, as masks of its
  kind are made now, bringing back stray hairs an older mask missed; a mask made recently comes back
  much as it was. With ViTMatte downloaded, Subject, Background and People also gain the strands it
  finds (`README.md:130`).
- It has no settings. History step: **Refine Edges** —
  `packages/RedlampUI/Sources/Model/EditorModel+MaskPresets.swift:110`.
- Failure: **"The edges couldn't be refined: …"** (`:113`).
- README: "**Refine Edges** solves their edges again from the photo, as masks of their kind are made
  now" — `README.md:131`.

### The Refine Edge Brush

- Where: a **button** beside Refine Edges, tooltip
  **"Paint over an edge to solve it again, hair by hair"**, identifier `masks.refineEdgeBrush`
  (`MaskingPanel.swift:1255-1257`); and in the component row's menu button and context menu.
- What it does: "paint over an AI mask's edge (hair, fur, a frayed sleeve) and the engine solves
  coverage there again, per pixel, from the photo, keeping the mask as it was elsewhere. Each stroke is
  one history step, and is kept with the mask so Update AI Masks applies it again." —
  `packages/RedlampUI/Sources/Model/EditorModel+EdgeBrush.swift:18-20`.
- Hint while armed: **"Paint over an edge to solve it again from the photo, hair by hair. [ and ] or
  ⌘-scroll change the size."** — `MaskingPanel.swift:452-453`. The strip's button reads **Done**
  (`:479`).
- Its one control, in the strip: a **Size** slider and **value field**, range **1…100**, default
  **12** — `MaskingPanel.swift:507-527`,
  `packages/RedlampUI/Sources/Model/EditorModel.swift:543`. It is **not** a `ParameterCatalog` entry,
  though `[`, `]` and ⌘-scroll clamp it to `maskBrushSize`'s 1…100
  (`EditorModel+EdgeBrush.swift:105-107`).
- Its strokes have **feather 0** — a hard-edged band (`EditorModel+EdgeBrush.swift:45`). The ring shows
  only **"Size \<n>"** (`MaskOverlayView.swift:189`), and painted strokes are shown as translucent
  white bands until their edge is solved (`:213-262`).
- A spinner beside the Size slider shows while a stroke is being solved (`MaskingPanel.swift:522-524`).
  Strokes are solved one at a time, in order (`EditorModel+EdgeBrush.swift:64-104`).
- History step per stroke: **Refine Edge Brush** (`EditorModel+EdgeBrush.swift:87`). Failure:
  **"The edge couldn't be refined: …"** (`:95`).
- Esc leaves it (`EditorModel+Shortcuts.swift:290` onwards).

### Feather and Edge for AI masks

Shown for any selected AI component except Depth Range — `MaskingPanel.swift:892-898`,
`packages/RedlampUI/Sources/Inspector/AppKit/MasksPanelView.swift:198-203`:

| Label | Range | Default | Step | Format | Source |
| --- | --- | --- | --- | --- | --- |
| Feather | 0…100 | 0 | 1 | integer | `ParameterSpec.swift:441` |
| Edge | -100…100 | 0 | 1 | signed integer | `:442` |

- What they do: "Feather (0...100) softens the mask's edge and Edge (-100...100) moves it out or in, as
  Lightroom's sliders for AI masks do; both leave the mask as it is at 0" — `Masks.swift:244-249`
  region.
- They are stored on the component, not as mask adjustments
  (`EditorModel+Masking.swift:375-379`, `:412-421`), and are omitted from the sidecar when 0.
- README: "**Feather** and **Edge** soften an AI mask's edge or move it out or in" — `README.md:131`.
- From process 14 they shape the mask's body only and add its fine partial coverage back (stray hairs,
  wisps a few pixels wide): whole for Feather and an outward Edge, faded by an inward Edge's share
  (Edge -50 keeps half) — `README.md:131`; `GrayMask.shaped`,
  `packages/RedlampMasking/Sources/GrayMask.swift` (MSK-31).
- `docs/lightroom-comparison.md:122` notes Lightroom Classic 15.5 added the same two sliders.

---

## 6. Local adjustments in a mask

Panel order, top to bottom, in the new panel (`MaskingPanel.swift:849-927`, and the AppKit port
`MasksPanelView.swift:145-174`, `:209-222`):

1. the mask's name as an uppercased section header, with **Invert** and **Reset**
2. **Amount**
3. the components, the Add/Subtract/Intersect buttons, and the selected component's settings
4. **Detail**
5. a gap
6. the sliders of `ParameterID.localParameters` minus the two swatch parameters, with extra gaps after
   Tint, Blacks, Dehaze and Defringe (`MaskingPanel.gapAfter`, `MaskingPanel.swift:932`)
7. the **Color** swatch
8. **Curve**
9. **Point Color**

`ParameterID.localParameters` order is declared at
`packages/RedlampEngineAPI/Sources/ParameterID.swift:193-199` ("The local adjustments, in Lightroom's
masking-panel order"); the swatch pair at `:202`.

| # | Label | Range | Default | Step | Format | Spec line |
| --- | --- | --- | --- | --- | --- | --- |
| — | Amount | 0…200 | 100 | 1 | integer | `ParameterSpec.swift:433` |
| — | Detail | -100…100 | 0 | 1 | signed int | `:439` |
| 1 | Temp | -100…100 | 0 | 1 | signed int | `:402` |
| 2 | Tint | -100…100 | 0 | 1 | signed int | `:403` |
| 3 | Exposure | -4…4 | 0 | 0.05 | signed, 2 decimals | `:404-407` |
| 4 | Contrast | -100…100 | 0 | 1 | signed int | `:408` |
| 5 | Highlights | -100…100 | 0 | 1 | signed int | `:409` |
| 6 | Shadows | -100…100 | 0 | 1 | signed int | `:410` |
| 7 | Whites | -100…100 | 0 | 1 | signed int | `:411` |
| 8 | Blacks | -100…100 | 0 | 1 | signed int | `:412` |
| 9 | Texture | -100…100 | 0 | 1 | signed int | `:413` |
| 10 | Clarity | -100…100 | 0 | 1 | signed int | `:414` |
| 11 | Dehaze | -100…100 | 0 | 1 | signed int | `:415` |
| 12 | Hue | -180…180 | 0 | 0.5 | signed, 1 decimal | `:416-423` |
| 13 | Saturation | -100…100 | 0 | 1 | signed int | `:424` |
| 14 | Sharpness | -100…100 | 0 | 1 | signed int | `:425` |
| 15 | Noise | -100…100 | 0 | 1 | signed int | `:426` |
| 16 | Moiré | 0…100 | 0 | 1 | integer | `:427` |
| 17 | Defringe | -100…100 | 0 | 1 | signed int | `:428` |
| 18 | Halation | -100…100 | 0 | 1 | signed int | `:429` |
| 19 | Bloom | -100…100 | 0 | 1 | signed int | `:430` |
| 20 | Color Hue | 0…360 | 0 | 1 | integer | `:431` |
| 21 | Color Saturation | 0…100 | 0 | 1 | integer | `:432` |

Notes:
- Temp and Tint here are **-100…100 relative sliders**, unlike the global Temp (kelvins) and Tint.
- Local Exposure's range is **-4…4**, narrower than the global **-5…5**.
- Halation and Bloom in a mask change how strongly the film glow applies where the mask covers; "the
  radii stay global" — `packages/RedlampEngineAPI/Sources/ParameterID.swift:185-187`.
- Only values that differ from the default are stored; setting a value back to its default removes it
  (`Masks.swift:895-901`). Writing to a non-local parameter on a mask is ignored
  (`guard parameter.isLocal`, `:896`).
- Sliders 20 and 21 are **not drawn as sliders** in the panel; they are the Color swatch (below).
- Slider gestures in general — `README.md:1169-1174`.
- `,` and `.` step through the selected mask's adjustments while the Masking tool is open, instead of
  the Basic panel's — `EditorModel+Shortcuts.swift:110-111` and `cycleFocusedParameter`.

### The Color swatch

- Row label **Color**, with a 34 × 16 pt rounded swatch button on the right —
  `MaskingPanel.swift:176-224`.
- When saturation is 0 the swatch is empty with a red diagonal line through it, and its tooltip is
  **"Color: none. Click to tint the mask"**; otherwise the tooltip reads
  **"Color: hue \<n>°, saturation \<n>"** (`:207-208`).
- Clicking opens a popover 240 pt wide with a 150-pt colour wheel labelled **Color**, then the
  **Color Hue** and **Color Saturation** sliders (`:209-221`).
- What it does: "The Color swatch: a tint of this hue (as on a color wheel) and strength over what the
  mask covers" — `ParameterID.swift:188-191`.
- History step name: `"<Mask name> Color"` (`:213`).

### Curves

- Row label **Curve**, with a channel pop-up and a reset button (`arrow.counterclockwise`, tooltip
  **"Reset the mask's Curves"**, disabled while every curve is straight) — `MaskingPanel.swift:228-260`.
- Channels, in order: **RGB**, **Red**, **Green**, **Blue** — `Masks.swift:982-996`.
- The graph is 210 pt tall (`MaskingPanel.swift:252-258`).
- What they are: "A mask's Curves, as Lightroom's masks have: a point curve for all three channels,
  then one for each, on the display-referred values the global Tone Curve works on" —
  `Masks.swift:979-981`.
- Curves are dropped from the edit once every channel is straight again (`Masks.swift:860-866`).
- History steps: `"<Mask name> Curve"`, and `"Reset <Mask name> Curves"` —
  `EditorModel+Masking.swift:320`, `:329`.

### Point Color in a mask (new; TON-29)

- Section header **Point Color**, then the swatch row, and once the mask has a swatch, the selected
  swatch's sliders and **Visualize Range** — `MaskPointColor`,
  `packages/RedlampUI/Sources/Inspector/PointColorControls.swift:125-142`; the AppKit port
  `packages/RedlampUI/Sources/Inspector/AppKit/MasksPanelView.swift:209-222`.
- **The swatch row** (`PointColorSwatches(ownColor: true)`, `PointColorControls.swift:44-120`):
  - an **eyedropper** button, identifier `pointColor.eyedropper`, tooltip
    **"Point Color Selector: click a colour on the photo to add a swatch"**, or, with all eight
    swatches taken, **"Point Color Selector: click the photo to pick the selected swatch's colour
    again"** (`:53-67`);
  - in a mask only, a `person.crop.circle.badge.plus` button, identifier `pointColor.maskColor`,
    tooltip **"Add a swatch of the mask's own colour: the median of the colours under it, for each
    photo"** (`:69-82`);
  - the swatches themselves, up to eight, the selected one ringed in white, tooltip
    **"A Point Color swatch: click to edit it"** (`:84-100`);
  - a **trash** button, identifier `pointColor.delete`, tooltip **"Delete the selected swatch"**
    (`:104-117`).
- **The sliders**, in three groups (`PointColorGroup.all`, `PointColorControls.swift:14-29`), each
  labelled Hue, Saturation and Luminance under its group's header (`label(_:)`, `:31-39`):

  | Group | Sliders | Range | Default | Spec lines |
  | --- | --- | --- | --- | --- |
  | **Shift** | Hue, Saturation, Luminance | -100…100 | 0 | `ParameterSpec.swift:447-449` |
  | **Uniformity** | Hue, Saturation, Luminance | -100…100 | 0 | `:450-452` |
  | **Range** | Hue, Saturation, Luminance, Smoothness | 0…100 | 50 | `:453-468` |

  (The catalog's own labels are "Hue Shift", "Saturation Shift" and so on; the panel shows the short
  form under each group's header.)
- **Visualize Range** — a checkbox, tooltip **"Show what the selected swatch selects in colour, and
  the rest of the photo in grey"**, disabled with no swatch selected
  (`PointColorVisualizeToggle`, `PointColorControls.swift:145-156`).
- Uniformity is Capture One's: "above 0 pulls the colours in the swatch's range towards its colour,
  below 0 pushes them apart" — `ParameterID.swift:235-237`.

### Reset

- The **Reset** button beside the mask's name, and **Reset Adjustments** in the mask row's menu, both
  call `resetMaskAdjustments` — `MaskingPanel.swift:1213-1222`, `:832`.
- It clears every adjustment, the curves, the Point Color swatches, and returns Amount to 100 and
  Detail to 0; the components are untouched — `Masks.swift:902-909`. History step
  `"Reset <Mask name>"` (`EditorModel+Masking.swift:300`).

---

## 7. The overlay

- **Show Overlay** — a switch button in the header, tooltip **"Show Overlay (O)"** (§2.2). Default
  **on** (`showMaskOverlay = true`, `packages/RedlampUI/Sources/Model/EditorModel.swift:486`).
- Shortcut **O**, title **Show / Hide Mask Overlay** —
  `packages/RedlampUI/Sources/Shortcuts/ShortcutAction.swift:247`, `:353`. It acts in the Masking or
  Crop tool; in Crop the same key cycles the crop overlay instead —
  `EditorModel+Shortcuts.swift:130-136`, `:258`.
- **Modes**, in menu order, with their exact names (`MaskOverlayStyle.menu`,
  `packages/RedlampEngineAPI/Sources/Rendering.swift:95-99`; names at `:81-92`):
  1. **Color Overlay** (the default — `EditorModel.swift:609`)
  2. **Color Overlay on B&W**
  3. **Image on Black**
  4. **Image on White**
  5. **B&W**
  6. **Image on B&W**
- A seventh mode, **Luminance Map**, is not in the menu: "the luminance map belongs to Luminance Range"
  (`Rendering.swift:93-94`). It is turned on by the **Show Luminance Map** checkbox in the Luminance
  Range editor and replaces the chosen mode while an overlay is shown
  (`EditorModel.swift:1213`). Default off (`:619`).
- **Colours**: **Red**, **Green**, **Blue**, **White** — `Rendering.swift:113-127`. Default **Red**
  (`EditorModel.swift:605`).
- **Cycling**: **⇧O**, title **Cycle Mask Overlay Color** —
  `ShortcutAction.swift:248`, `:354`; it steps to `.next`, wrapping red → green → blue → white → red
  (`Rendering.swift:116-118`, `EditorModel+Shortcuts.swift:137-143`).
- **Opacity**: a slider over **0…1** with a typed or scrubbed percentage beside it, default **0.55**,
  i.e. **55%** — `MaskingPanel.swift:123-134`, `Rendering.swift:109`, `EditorModel.swift:614`.
- **Color and Opacity are disabled in the modes that don't tint** (§2.2).
- **Automatic hiding.** While a mask's adjustment or its Amount is being dragged, the overlay steps
  aside so the edit itself shows — "Lightroom's automatic overlay toggle". Sliders that shape the mask
  (Feather, Detail, Refine) keep it — `EditorModel.swift:1338-1356`.
- The overlay also disappears while the before/original is shown, and only ever shows the **selected**
  mask (`:1344`).
- It steps aside too while a tool is armed for a new mask, until the tool's first stroke, click or
  sample has made it; a tool adding to the selected mask keeps its overlay (`isArmedForNewMask`,
  `EditorModel+Masking.swift:28-32`; `maskOverlayShown`, `EditorModel.swift:1343-1349`).
- **New: hover previews.** `maskOverlayShown` prefers `hoveredMaskID` over everything else
  (`EditorModel.swift:1345-1347`), so the mask under the pointer — in the list, or its pin on the photo
  — is overlaid **even with the overlay switched off**. A component under the pointer is previewed
  differently: `componentPreview` appends a temporary one-component mask with no adjustments, and the
  renderer overlays that instead (`EditorModel.swift:1198-1203`;
  `EditorModel+MaskThumbnails.swift:60-75`).
- README's list of modes: "a mask overlay (`O`) in Lightroom's modes…" — `README.md:135`.

---

## 8. Mask presets

### Where they are

- The **Presets** menu in the panel's header, shown as `wand.and.stars` alone, tooltip
  **"Mask Presets"** (§2.2).
- The menu lists the built-in presets then the user's, each as a plain button with its name; a preset
  whose AI masks this photo can't make is disabled
  (`canApply`, `packages/RedlampUI/Sources/Model/EditorModel+MaskPresets.swift:27-29`).
- Below the user's own, a divider and a **Delete Preset** submenu listing them (destructive) —
  `MaskingPanel.swift:347-354`.

### The built-in list

`MaskPreset.builtIn`, in menu order — `packages/RedlampEngineAPI/Sources/MaskPresets.swift:109-169`.
**Nine** presets; **Even Skin Tone** is new since the manual was written:

| # | Name | Mask it makes | Adjustments | Lines |
| --- | --- | --- | --- | --- |
| 1 | **Blue Sky** | Sky | Temp -12, Exposure -0.3, Highlights -25, Saturation +15 | `:111-115` |
| 2 | **Brighten Subject** | Subject | Exposure +0.35, Shadows +15, Clarity +8 | `:116-120` |
| 3 | **Darken Background** | Background | Exposure -0.5, Saturation -15 | `:121-125` |
| 4 | **Smooth Skin** | People → Face Skin | Texture -35, Clarity -10 | `:126-130` |
| 5 | **Even Skin Tone** | People → Face Skin **and** Body Skin (Body Skin optional) | none; a Point Color swatch of the mask's own colour, with Hue Uniformity 50, Saturation Uniformity 35, Hue Range 47, Saturation Range 64, Luminance Range 37 | `:131-146` |
| 6 | **Whiten Teeth** | People → Teeth | Exposure +0.25, Saturation -45 | `:147-151` |
| 7 | **Pop Eyes** | People → Iris and Pupil | Exposure +0.3, Clarity +20, Saturation +15 | `:152-156` |
| 8 | **Brighten Snow** | Landscape → Snow | Exposure +0.35, Whites +15, Temp -4, Clarity +5 | `:157-163` |
| 9 | **Enhance Vegetation** | Landscape → Vegetation | Saturation +12, Texture +10, Shadows +10 | `:164-169` |

Even Skin Tone's own comment: "Capture One's skin tone uniformity (TON-29): the skin's colours pulled
part of the way to its own median, hue more than saturation; lightness is left alone, which keeps the
face's shading and texture… Starting values, to tune on more faces." (`:131-134`). Body Skin is an
**optional part** (`optionalParts: [.bodySkin]`, `:145`), so the preset still applies on a photo whose
SAM 3 isn't downloaded **(inferred from the field's name and its single use)**.

- They are **adaptive**: "Adaptive presets in the spirit of Lightroom's: each recomputes its mask for
  the photo" (`:109`), and the applied mask takes the preset's name, amount, detail and adjustments
  (`EditorModel+MaskPresets.swift:77-88`). History step `"Apply <preset name>"` (`:88`).
- Applying one shows the same progress row as any AI mask, and on failure the message
  `"<Preset name>: <reason>"`.
- Brighten Snow and Enhance Vegetation both make a Landscape mask; which class each uses is carried
  beside the components in `landscapeClasses` (`MaskPresets.swift:23`, `:43-50`), defaulting to
  Vegetation for presets saved before that field existed (`:50`).

### Saving your own

- **Save as Mask Preset…** in a mask row's menu button or its context menu
  (`MaskingPanel.swift:833-836`). It opens an alert, **Save Mask Preset**, with a name field holding
  the mask's name, **Save** and **Cancel**, and the message
  **"A preset with the same name is replaced."** (`:798-815`).
- Saving a second preset with the same name replaces the first
  (`EditorModel+MaskPresets.swift:31-38`).
- **Brush strokes are not kept** — "everything but brush strokes (which belong to one photo) is kept";
  brush, Existing Mask and unknown components are dropped, AI components become requests, and gradients
  and ranges are kept as they are — `MaskPresets.swift:53-85` region.
- README: "**Mask presets:** Blue Sky, Brighten Subject, Darken Background, Smooth Skin, Whiten Teeth
  and Pop Eyes compute their masks for each photo; save your own from any mask." — `README.md:132`.

### Where saved presets are stored

- In macOS user defaults, under the key **`app.redlamp.maskPresets`**, as a JSON array of `MaskPreset`
  — `EditorModel+MaskPresets.swift:7-19`.
- They are therefore **not** `.redrecipe` files in `~/Library/Application Support/Redlamp/Recipes/`
  **(inferred: different storage path and type)**.
- Brush settings are stored the same way, under `app.redlamp.brushes`
  (`BrushSettings.swift:87`); the evaluation-models toggle under `app.redlamp.evaluationModels`
  (`ModelManifest.swift:90`).

---

## 9. Every masking-related shortcut

From `packages/RedlampUI/Sources/Shortcuts/ShortcutAction.swift` — the single registry the key monitor,
the menus and the ⌘/ sheet all read. `⌘/` opens the sheet (**Keyboard Shortcuts**), grouped by the
categories below.

### Category "Tools"

| Keys | Title shown | Lines |
| --- | --- | --- |
| `⇧W` | Masking | `:237`, `:343` |
| `K` | Brush Mask | `:241`, `:347` |
| `M` | Linear Gradient Mask | `:242`, `:348` |
| `⇧M` | Radial Gradient Mask | `:243`, `:349` |
| `⇧J` | Color Range Mask | `:244`, `:350` |
| `⇧Q` | Luminance Range Mask | `:245`, `:351` |
| `⇧Z` | Depth Range Mask | `:246`, `:352` |

### Category "Masking" (`ShortcutCategory.masking = "Masking"`, `:89`)

| Keys | Title shown | Lines |
| --- | --- | --- |
| `O` | Show / Hide Mask Overlay | `:247`, `:353` |
| `⇧O` | Cycle Mask Overlay Color | `:248`, `:354` |
| `H` | Show / Hide Pins or Spots | `:249`, `:355` |
| `⌫` | Delete Selected Mask or Spot | `:250`, `:356` |
| `Esc` | Cancel / Leave Tool | `:251`, `:357` |

### Masking-relevant keys that live in other categories

| Keys | Title / behaviour in masking | Lines |
| --- | --- | --- |
| `[` `]` | Registered as **Decrease Rating** / **Increase Rating**, but while a brush tool is active they size the brush (Shift: feather) | `:258-259`, `:364-365`; redirect at `EditorModel+Shortcuts.swift:163-164` |
| `D` | Edit — leaves masking | `:234`, `:340` |
| `Space` (hold) | Pan the photo while a tool draws; a press with no drag toggles the zoom | `EditorModel+BrushSize.swift:78-103` |
| `⌘-scroll` | Size the active brush (Shift: feather) — not a `ShortcutAction` | `EditorModel+BrushSize.swift:56-76` |
| `,` `.` | Select previous/next setting — the selected mask's adjustments while masking | `EditorModel+Shortcuts.swift:110-111` |
| `-` `=` | Decrease/Increase the selected setting (⇧ for larger steps) | `ShortcutAction.swift:232-233`, `:338-339` |
| `A` | **Not** bound to Auto Mask. The design asks for "`A` while brushing, as in Lightroom" (`docs/plans/2026-10-07-masks-panel-design.md:68`); no such case exists in `ShortcutAction` **(inferred)**. Auto Mask is the checkbox only. `A` is the crop aspect lock (`:122`) |

Availability: `O` and `⇧O` work in the Masking **or** Crop tool; `H` while masking or healing; `⌫`
while masking with a mask selected, or while healing with a spot selected
(`EditorModel+Shortcuts.swift:258-260`).

### README's own masking shortcut row

`README.md:1163`: "`O` show/hide overlay · `⇧O` cycle overlay color · `H` show/hide pins · `⌫` delete
selected mask · `Esc` finish drawing or leave the tool · brushing: `[` `]` or `⌘`-scroll size (`⇧`
feather), hold `⌥` to erase · Objects: drag a box or brush (the panel chooses), `⌥`-click or `⌥`-brush
to take away". Every key matches the registry; the README's wording is shorter than the titles the app
shows.

`README.md:1162` (Tools row) also matches: "`⇧W` Masking · `M` linear gradient · `⇧M` radial gradient ·
`K` brush · `⇧J` color range · `⇧Q` luminance range · `⇧Z` depth range".

---

## 10. Differences from Lightroom Classic, and what isn't available

### Beyond Lightroom

- **A mask's Detail** — keeps only the mask's textured or only its flat areas. No Lightroom equivalent.
  `README.md:133`; `docs/lightroom-comparison.md:132` marks the row "Beyond".
- **Any mask reusable as a component of another, in Add, Subtract or Intersect.**
  `docs/lightroom-comparison.md:132`.
- **Refine Edges and the Refine Edge Brush** are marked "Different" from Lightroom's —
  `docs/lightroom-comparison.md:121`.
- **Local Halation and Bloom** sliders in a mask (`docs/lightroom-comparison.md:102` region lists them
  as "Lightroom: No").
- **Point Color inside masks**, with Capture One's uniformity — `docs/lightroom-comparison.md:130`
  (Done, TON-29).
- **The mask's coverage thumbnail, the hover previews and the pin placed inside the mask** are
  Redlamp's own (UX-23); Lightroom has none of them **(inferred: no comparison row)**.

### Things a Lightroom user would notice as different

- **AI masks don't follow your edit.** Computed from the photo without its edit and kept as bitmaps,
  so they never move; you refresh them with **Update AI Masks**. `README.md:131`;
  `docs/lightroom-comparison.md:114`.
- **Models are downloaded on consent, with their size and licence shown**, and run only on the Mac.
  `README.md:137`.
- **Subject, Background, People face parts and Sky need nothing**, but **Objects (79.6 MB)**,
  **Landscape and the SAM 3 People parts (988.1 MB)** and **Depth Range (49.8 MB)** do; **ViTMatte
  (108.9 MB)** is optional and improves hair on Refine Edges.
- **Hair** comes from the photo's own hair matte (iPhone portraits) unless SAM 3 is downloaded —
  `README.md:130`.
- **Landscape has no plain "Landscape" command** — you pick a class
  (`MasksPanelNext.swift:249-258`).
- **People is a picker, not a menu:** you tick the people and the parts before anything is computed,
  and can make a mask each (`PeoplePickerView.swift`). Lightroom's People panel is close in spirit.
- **Mask presets are stored in user defaults**, not as files you can move between Macs
  (`EditorModel+MaskPresets.swift:7-19`) **(inferred as a difference)**.
- **Red Eye Correction is a separate tool and not built yet** (`EditorTypes.swift:295`); not part of
  masking, but it sits in the same tool strip and is dimmed.

### Listed as not yet available

- **The Landscape picker** (UX-26) and **mask presets applied to every selected photo** (UX-25) are
  "Not started" — `docs/research/research-tracker.md:331-332`.
- **Effect presets for a mask's adjustments** (UX-27, Lightroom's Effect menu) are "Not started" —
  `:333`.
- Every row of the Masking table in `docs/lightroom-comparison.md:107-132` is now marked **Done**,
  Point Color included.
- No mask **kind** is pending: `MaskKind.plannedPhase` returns `nil` for every case —
  `Masks.swift:763-770`.
- `docs/lightroom-feature-inventory.md` still carries phase tags for masking features that have since
  shipped; use `docs/lightroom-comparison.md` for current state.

### README / code / design disagreements

| Topic | The source says | The code says | Which to follow |
| --- | --- | --- | --- |
| Which panel the editor shows | The design and the tracker describe the new panel as what the app will show (`docs/plans/2026-10-07-masks-panel-design.md:98`) | `packages/RedlampUI/Sources/Inspector/AppKit/InspectorPanelsView.swift:32-33` still builds `MaskingPanelView`, the old panel | The code, today. The manual's new text should ship with the commit that switches this line |
| List row height and thumbnail size | Design: rows "36 pt high", thumbnail "36 × 24 pt at most" (`:25-28`) | 28 pt rows (`MaskingPanel.swift:748`), 30 × 20 pt thumbnails (`MasksPanelNext.swift:413`) | The code |
| Auto Mask's shortcut | Design: "Auto Mask (`A` while brushing, as in Lightroom)" (`:68`) | No `A` case for it in `ShortcutAction` | The code: there is no shortcut; don't document one |
| Where the armed tool's strip goes | Design's example text: "Painting into Brush 2. Option erases, [ and ] change the size. Done (Esc)" (`:20`) | The hints are the eight strings in §2.3, which name neither the brush number nor Esc | The code's strings |
| Progress's place | Design: "Progress shows on the row of the mask being made" (`:78`) | Progress is a row **in the list's place**, above the list, not on a mask's row (`MasksPanelNext.swift:318-328`, `:347-358`) | The code |
| Built-in mask presets | README: six, "Blue Sky, Brighten Subject, Darken Background, Smooth Skin, Whiten Teeth and Pop Eyes" (`README.md:132`); the manual: eight (`managing.md:76-85`) | **Nine**: those six plus **Even Skin Tone**, **Brighten Snow** and **Enhance Vegetation** (`MaskPresets.swift:109-169`) | The code |
| Local adjustment list | README lists Temp … Saturation, a Color swatch and Curves (`README.md:134`) | 21 local parameters: the README's list **plus Moiré, Defringe, Halation and Bloom**, and now Point Color too | The code |
| Objects download size | "an 80 MB download" — `README.md:130` | 79,644,968 bytes → **79.6 MB** (the button reads "Download 79.6 MB") | Both; the README rounds. Quote 79.6 MB |
| SAM 3 download size | "a 988 MB download" — `README.md:130` | 988,085,795 bytes → **988.1 MB** | Both; the README rounds |
| Depth Anything 3 size | "a 336 MB download" — `README.md:130` | 336,101,695 bytes → **336.1 MB** | Both; the README rounds |
| ViTMatte size | "Settings › Models, 109 MB" — `README.md:130` | 108,850,800 bytes → **108.9 MB** | Both; the README rounds |
| SAM 3's standing | README: cleared, "under Meta's SAM License, which comes with it" (`README.md:130`) | The manifest is `cleared: true, evaluationOnly: false`, so it is offered to everyone — but the **error message still calls it an evaluation model**: `"<Part> masks need the SAM 3 evaluation model."` (`Masks.swift:587`) | The manifest and the README. The error string is stale; don't repeat "evaluation model" in the manual |
| Depth Range model | "estimated by Depth Anything 3 (or V2 Small)" — `README.md:130` | The prompt offers **Depth Anything V2 (small), 49.8 MB**; DA3 is used only if already downloaded for Sky | The code |
| Mask Amount units | "the mask's Amount (0–200%)" — `README.md:134` | Range 0…200, format `.integer`, so the slider shows `100`, not `100%` | The code for the on-screen reading; the range is the same |
| "reset" in the mask list | "a mask list where you can show and hide, rename, duplicate, 'duplicate and invert', reset, delete, and drag to reorder" — `README.md:135` | The menu item is **Reset Adjustments** | The code; use the exact label |
| Whole-mask Invert | `README.md:123` has it ("each can be inverted, as can the whole mask (**Invert**, as Lightroom's)"), and so does `docs/lightroom-comparison.md:124`; but `README.md:135`'s mask-list sentence still lists only "duplicate and invert" | `MaskLayer.inverted`, reached from the **Invert** checkbox at the top of the mask's settings and **Invert** in the mask's menu | The code. The README agrees in substance; its mask-list sentence is the stale one |
| Value fields | `README.md:151` lists where values were added and does **not** include the Masks panel | The overlay's Opacity, the Refine Edge brush's Size and the four range stops are value fields | The code; the README is behind (UX-28's "Not done" note at `docs/research/research-tracker.md:335` is also now stale for these four) |

---

## 11. Figures and screenshots

### The manual's own figures

`docs/manual/figures/`: `masks-panel.html`, `mask-adjustments.html`, `combine.html`,
`gradients.html`, `luminance-range.html`.

**`masks-panel.html` is now wrong** and must be recaptured from the new panel. It crops
`docs/images/hero-masks.png` at 1935,350 465×410 and keys eleven callouts; of those, only 2 (Masks
list), 3 (Eye), 6 (Components) and 8 (Add · Subtract · Intersect) still describe something the new
panel has in that place. Callout 1 names a Show Overlay checkbox, 4 names "Create New Mask · Presets"
buttons under the list, 5 puts the More menu there, 7 says "Invert · Delete" on a component row (it is
now Invert and a menu button), and 9, 10 and 11 put the mask's section, Reset and Amount below the
components rather than above them.

New callouts the recaptured figure should carry, in the header's order: Masks, New Mask, Presets, the
overlay switch, Overlay Options, Pins, the … menu; then a row's thumbnail, name, eye and menu button;
then the mask's name with Invert and Reset, Amount, "Components, applied top to bottom", a component
row's operation menu and menu button, and the three operation buttons.

### Screenshots in `docs/images`

| File | Pixels | What is visible |
| --- | --- | --- |
| `docs/images/masking.png` | 1800 × 991 | The whole window with the **old** panel: Masks title, Show Overlay checked, a two-row list, the Create New Mask button, COMPONENTS with Radial Gradient 1, the Add / Subtract / Intersect buttons, Feather at 70, then the MASK 2 section with Reset, Amount 100 and the local sliders. On the canvas, a radial gradient in the red Color Overlay. Referenced from `README.md:793` |
| `docs/images/hero-masks.png` | 2400 × 1500 | The whole window with a **Subject** mask on a dancer: the **old** panel's layout, with the full local slider list. Referenced from `README.md:789`, and cropped by `masks-panel.html` and `mask-adjustments.html` |

Both show the old panel and will need recapturing (`scripts/capture-hero.sh`) once the editor shows the
new one. The local-adjustment list in `hero-masks.png` is still correct below the components, so
`mask-adjustments.html` survives the change **(inferred: it crops the slider list, which is unchanged
except for Point Color appearing after Curve)**.

### Research contact sheets — not app UI, not suitable as manual figures

`docs/images/masking-sky-bakeoff.jpg`, `-sky-disagreements.jpg`, `-sky-edges.jpg`,
`-landscape-bakeoff.jpg`; they belong to `docs/research/notes/MSK-17-sky-bakeoff.md`.

### The harness, for capturing states

The new panel's states can be shot from the harness without staging them in the app
(`mise run harness -- --scene masks-panel-states`,
`apps/RedlampHarness/Sources/Scenes/MasksPanelScenes.swift:28-30`): no masks; the picker; the People
picker with three people; a mask with an AI component selected; a brush armed; a download asked; an
error; sixteen masks. `--scene masks-panel` is the live panel beside the sample photo, with the
design's fourteen tasks as a checklist (`:11-24`).

---

## Appendix A: feedback feature IDs for the Masking area

`docs/feedback/areas.json` — area `masking`, label `component:masking`, summary "Masks and local
adjustments: AI masks, brushes, gradients and ranges.", trackers `MSK` and `INF`. Its features, in
order, are a ready-made chapter outline:

`masking.subject` Subject · `masking.sky` Sky · `masking.background` Background · `masking.objects`
Objects · `masking.people` People · `masking.landscape` Landscape · `masking.depth-range` Depth Range ·
`masking.brush` Brush · `masking.linear` Linear Gradient · `masking.radial` Radial Gradient ·
`masking.color-range` Color Range · `masking.luminance-range` Luminance Range · `masking.combining`
Combining Masks · `masking.refine` Refine Edges and Edge Brush · `masking.overlay` Overlay and Mask
List · `masking.local-adjustments` Local Adjustments · `masking.presets` Mask Presets ·
`masking.update-ai` Update AI Masks · `masking.models` AI Model Downloads · `masking.other` Something
else in Masking.

The same titles appear in the in-app feedback catalog
(`packages/RedlampUI/Sources/Feedback/FeedbackAreaCatalog.swift`).

## Appendix B: which automation scenario exercises which control

Both files are registered in `packages/RedlampAutomation/Sources/Catalogue.swift:10`.

### The new panel: `packages/RedlampAutomation/Sources/Scenarios/MasksPanelScenarios.swift`

Three scenarios, worked "by its own controls, as a person works it: clicks on its buttons, tiles, rows
and checkboxes, choices in its menus, and drags on its value fields" (`:7-10`). Hovers are **not**
among them — SwiftUI reads them from the real pointer, so the previews they start are covered by
`PointerPreviewTests` and `packages/RedlampUI/Tests/MasksPanelViewTests.swift` instead (`:9-10`).

| Scenario ID | What it clicks | Features claimed | Lines |
| --- | --- | --- | --- |
| `masking.panel` | the inline picker (`masks.picker.radial`); New Mask's popover; a mask row's menu (Duplicate, Duplicate and Invert, Invert, Reset Adjustments, Delete \<name>, Rename…); `masks.mask.invert` and `masks.mask.reset`; a row chosen by click; the eye, and Option-click on the eye both ways; Subtract, Add (with **Existing Mask**) and Intersect through the picker; a component row, its operation menu (Set to Intersect, Set to Subtract), its Invert and its menu's Delete; the header's overlay switch, Pins switch and Delete All Masks | `masking.overlay`, `masking.combining`, `masking.radial`, `masking.linear`, the Existing Mask kind | `:14-130` |
| `masking.panel-tools` | a Luminance Range from the picker, its **four stop value fields scrubbed**, Show Luminance Map, Done; the brush from Add and `masks.brush.autoMask`; the overlay options popover — Mode and Color from their menus and **Opacity scrubbed**; Subject from New Mask, then `masks.refineEdges`, `masks.refineEdgeBrush` and the **Refine Edge brush's Size scrubbed** | `masking.luminance-range`, `masking.brush`, `masking.overlay`, `masking.refine` | `:132-234` |
| `masking.panel-people` | the People tile; Cancel; People from New Mask; a person's crop ticked and unticked; a part ticked and unticked (`masks.people.part.faceSkin`); Create | `masking.people`, the People kind | `:236-287` |

Not reached by any scenario, worth knowing when writing: the Presets menu from the new header (the old
`masking.presets` scenario applies presets through the model), the Landscape tile's class menu, the
Depth Range stops, **Separate masks**, **All** in the People picker, and the download notice's
**Download** / **Not Now** buttons **(inferred from the three claim lists and the identifiers each
scenario taps)**.

### The kinds themselves: `packages/RedlampAutomation/Sources/Scenarios/MaskingScenarios.swift`

| Scenario ID | Description | Features claimed | Lines |
| --- | --- | --- | --- |
| `masking.gradients` | "Linear and radial gradients, and every local slider dragged on the selected mask" | `masking.linear`, `masking.radial`, `masking.local-adjustments` | `:21-62` |
| `masking.brush` | "The brush paints a stroke, and its settings move" | `masking.brush` | `:64-105` |
| `masking.ranges` | "Color, luminance and depth ranges sampled from the photo" | `masking.color-range`, `masking.luminance-range`, `masking.depth-range` | `:107-159` |
| `masking.ai` | "Subject, Sky, Background and People from Apple Vision; Update AI Masks; Refine Edges" | `masking.subject`, `masking.sky`, `masking.background`, `masking.people`, `masking.update-ai`, `masking.refine`, `masking.models` | `:161-221` |
| `masking.objects-and-landscape` | "Objects (Segment Anything) by a click, a box and a stroke, and Landscape (SAM 3)" | `masking.objects`, `masking.landscape` | `:223-276` |
| `masking.combining` | "Add, subtract and intersect components, invert, and reuse a mask in another" | `masking.combining`, the Existing Mask kind, the Detail parameter | `:278-315` |
| `masking.list-and-overlay` | "The mask list's operations, reordering masks and components, the overlay in every style and opacity, and the pins" | `masking.overlay` | `:317-382` |
| `masking.brush-sizes` | "[ and ] size the Masking and Healing brushes, and never the rating" | `masking.brush`, `healing.remove` | `:384-421` |
| `masking.presets` | "Every built-in mask preset, and saving one" | `masking.presets` | `:430-452` |

### Unit tests that cover the new panel's behaviour

- `packages/RedlampUI/Tests/MasksPanelViewTests.swift` — the AppKit panel keeps its rows as masks are
  drawn and selected (`:53`); the drawing hint, messages and the People picker go where the design has
  them (`:115`); the column is re-measured when a mask comes back (`:151`); a mask's or a component's
  preview ends with its row (`:184`).
- `packages/RedlampUI/Tests/MaskPickerTests.swift` — the picker's groups hold every kind once (`:8`);
  the picker's title says where its mask goes (`:14`).
- `packages/RedlampUI/Tests/PeoplePickerTests.swift` — who is in the photo, with a crop of each, none
  ticked (`:54`); a person ticked gets a mask named for them (`:67`); Separate masks (`:81`); several
  parts make one mask with a component each (`:96`); one part of one person is named for both (`:111`);
  subtracting people from a mask (`:123`); ticking a part whose model isn't here asks for it, and Not
  Now unticks it (`:141`); with nobody found the picker says so (`:162`).
- `packages/RedlampUI/Tests/MaskPinTests.swift` — where pins go.
