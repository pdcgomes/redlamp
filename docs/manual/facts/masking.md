# Masking in Redlamp — fact sheet for the user manual

Every fact below cites a repository-relative path and line numbers. Facts marked **(inferred)** were
reasoned from the code rather than read as a literal string. Where `README.md` and the code disagree,
both are reported and the code's version is named.

Read from the code at commit `0e22a3e` (6 October 2026); line numbers refer to that commit. Part 3 of
the manual, Masking, was written from this sheet. Check a fact against the code before reusing it.

Conventions used below:
- "Label" means a string literal the app displays.
- Slider ranges and defaults come from `ParameterCatalog` (`packages/RedlampEngineAPI/Sources/ParameterSpec.swift`).
- A parameter declared without an explicit range/default/step/format uses the `ParameterSpec`
  initialiser's defaults: range `-100…100`, default `0`, step `1`, format `.signedInteger`
  (which displays `+25`, `0`, `-40`) — `packages/RedlampEngineAPI/Sources/ParameterSpec.swift:63-83`,
  `132-147`.

---

## 1. The model: what a mask is

### A mask = adjustments + components

- A mask (`MaskLayer`) is "A local adjustment: a mask built from components, plus its own
  adjustments": `packages/RedlampEngineAPI/Sources/Masks.swift:819-832`.
- Its fields: `name`, `isVisible`, `components`, `amount`, `detail`, `adjustments`, `curves`
  — `packages/RedlampEngineAPI/Sources/Masks.swift:824-840`.
- A component (`MaskComponent`) carries a `shape`, an `operation` and an `inverted` flag:
  `packages/RedlampEngineAPI/Sources/Masks.swift:777-791`. Defaults when created: `operation = .add`,
  `inverted = false` (`:785`).
- Component shapes available: linear, radial, brush, luminanceRange, colorRange, ai, depthRange,
  maskReference, unknown — `packages/RedlampEngineAPI/Sources/Masks.swift:580-589`.
- README summary of the same model: "Each mask is a layer: its own adjustments plus a mask built from
  components. Components combine with **Add**, **Subtract**, and **Intersect**, and each can be
  inverted." — `README.md:104`.

### How components combine: Add, Subtract, Intersect

- The three operations and their exact display names: `Add`, `Subtract`, `Intersect` —
  `packages/RedlampEngineAPI/Sources/Masks.swift:757-766`. Doc comment: "How a component combines
  with the components before it" (`:756`).
- Their SF Symbols (used on the buttons and in each component row): `plus`, `minus`,
  `circle.lefthalf.filled` — `packages/RedlampEngineAPI/Sources/Masks.swift:768-774`.
- **Where they appear #1 — three buttons under the Components list.** `ComponentOperationMenus`
  renders one `CreateMaskMenu` per operation, in the order Add, Subtract, Intersect, each labelled
  with `operation.name` and its symbol:
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:969-999`. Each button opens the full
  mask-kind menu, so the new component is created with that operation
  (`:994-996`, and `startDrawing(kind, operation:addingTo:)` at
  `packages/RedlampUI/Sources/Model/EditorModel+Masking.swift:29-41`).
- **Where they appear #2 — each component row's context menu.** "Set to Add", "Set to Subtract",
  "Set to Intersect" (built as `"Set to \(operation.name)"`):
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:1073-1076`.
- **Where they appear #3 — the icon at the left of each component row**, with the operation's name as
  its tooltip: `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:1021-1025`.
- The first component of a new mask is always `Add`: a drawn component gets
  `drawingTarget == nil ? .add : drawingOperation` —
  `packages/RedlampUI/Sources/Model/EditorModel+Masking.swift:55`, `:84`; AI masks the same at
  `packages/RedlampUI/Sources/Model/EditorModel+AIMasks.swift:44-49`.
- History step names produced: `"Add Component"` style strings are built as
  `"\(operation.name) Component"` — `packages/RedlampUI/Sources/Model/EditorModel+Masking.swift:133`;
  for a reused mask, `"\(operation.name) \(referenced.name)"` (`:144`); for an AI mask added to an
  existing mask, `"\(operation.name) \(title)"` (`EditorModel+AIMasks.swift:55`).

### Invert

- Per component, not per mask: `MaskComponent.inverted`
  (`packages/RedlampEngineAPI/Sources/Masks.swift:781`).
- UI: a checkbox labelled **Invert** on every component row —
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:1046-1052`.
- History names: `"Invert Component"` / `"Uninvert Component"` —
  `packages/RedlampUI/Sources/Model/EditorModel+Masking.swift:120-130`.
- Whole-mask inversion is reached through the mask list's **Duplicate and Invert**, which toggles
  `inverted` on every component of the copy —
  `packages/RedlampUI/Sources/Model/EditorModel+Masking.swift:194-211`.

### The mask's Amount

- Slider label **Amount**, range **0…200**, default **100**, step 1, format integer (so it reads
  `100`, not `+100`) — `packages/RedlampEngineAPI/Sources/ParameterSpec.swift:425`.
- What it does: "Scales every adjustment of the mask, 0...200 (Lightroom's mask Amount)" —
  `packages/RedlampEngineAPI/Sources/Masks.swift:828-829`.
- README states the same range: "plus the mask's Amount (0–200%)" — `README.md:115`. Note the README
  writes a percent sign; the slider's own value format is a bare integer
  (`ParameterSpec.swift:425`, `:137-139`).
- Reset puts it back to 100: `resetAdjustments()` sets `amount = 100`
  (`packages/RedlampEngineAPI/Sources/Masks.swift:876-882`).
- Amount is one of the two sliders whose drag temporarily hides the overlay (see §7):
  `packages/RedlampUI/Sources/Model/EditorModel.swift:993-996`.

### Existing Mask as a component

- `MaskKind.existingMask`, display name **Existing Mask**, symbol `square.on.square` —
  `packages/RedlampEngineAPI/Sources/Masks.swift:693-694`, `:721`, `:739`.
- It is **not** in Create New Mask: `MaskKind.creatable = allCases.filter { $0 != .existingMask }`
  — `packages/RedlampEngineAPI/Sources/Masks.swift:697`.
- It appears only inside the Add / Subtract / Intersect menus, as a submenu named **Existing Mask**
  listing the other masks by name, followed by a divider:
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:586-593`, fed by
  `others: model.maskOutlines.filter { $0.id != mask.id }` (`:979`).
- Behaviour: "Another mask's coverage, used as a component ('new mask from existing'). A referenced
  mask's own references are ignored, so references never loop." —
  `packages/RedlampEngineAPI/Sources/Masks.swift:564-567`.
- A mask cannot reference itself: `guard referencedID != maskID` —
  `packages/RedlampUI/Sources/Model/EditorModel+Masking.swift:142`.

### The mask's Detail

- Slider label **Detail**, range **-100…100**, default **0**, step 1, signed integer —
  `packages/RedlampEngineAPI/Sources/ParameterSpec.swift:431`.
- What it does: "-100...100: above 0 keeps only textured areas of the mask, below 0 only flat ones."
  — `packages/RedlampEngineAPI/Sources/Masks.swift:830-831`.
- README calls it a beyond-Lightroom feature: "a mask's **Detail** keeps only its textured (or only
  its flat) areas" — `README.md:114`.
- It sits directly under Amount in the panel, above the local adjustments:
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:754-755` and the AppKit port
  `packages/RedlampUI/Sources/Inspector/AppKit/MaskingPanelView.swift:142`.
- Reset sets it to 0 (`packages/RedlampEngineAPI/Sources/Masks.swift:881`).
- Dragging Detail does **not** hide the overlay (only `isLocal` parameters and `maskAmount` do) —
  `packages/RedlampUI/Sources/Model/EditorModel.swift:986-996`.

### Limits on masks and components

- **16 masks per photo**: `MaskLayer.maximumLayers = 16`
  (`packages/RedlampEngineAPI/Sources/Masks.swift:821`). Enforced in the UI at every creation point:
  drawing (`EditorModel+Masking.swift:61`), tools that stay armed
  (`EditorModel+Masking.swift:91`), AI masks (`EditorModel+AIMasks.swift:57`), duplicate
  (`EditorModel+Masking.swift:195`), applying a preset (`EditorModel+MaskPresets.swift:74`).
  When the limit is reached the action silently does nothing — there is no message **(inferred:
  each site is a `guard … else { return }` with no `maskMessage` set)**.
- **64 components**: `MaskLayer.maximumComponents = 64`
  (`packages/RedlampEngineAPI/Sources/Masks.swift:822`). This is enforced only in the renderer
  (`packages/RedlampEngine/Sources/DevelopParameters.swift:330`,
  `packages/RedlampEngine/Sources/DetailStage.swift:241`), not in the masking UI **(inferred: no UI
  file references `maximumComponents`)**. For the manual: treat 64 as the number of components that
  render, per photo across all masks **(inferred from `DevelopParameters.swift:330`, which counts
  into one shared `encoder.components` list)**.
- README quotes the mask limit as a performance figure: "Up to 16 masks cost well under a
  millisecond extra at Fit" — `README.md:117`.
- **Color Range** is limited to **5 samples**: `ColorRangeMask.maximumSamples = 5`
  (`packages/RedlampEngineAPI/Sources/Masks.swift:170`), and `init` truncates to it (`:177`).

---

## 2. The Masking tool and the Masks panel

### Entering and leaving masking

- Shortcut **⇧W**, title **Masking** —
  `packages/RedlampUI/Sources/Shortcuts/ShortcutAction.swift:234`, `:338`. It toggles:
  `activeTool = activeTool == .masking ? .edit : .masking` —
  `packages/RedlampUI/Sources/Model/EditorModel+Shortcuts.swift:109`.
- Tool strip: Redlamp's equivalent of Lightroom's tool strip, "Click a tool to open it, click it
  again to go back to Edit" — `packages/RedlampUI/Sources/Inspector/AppKit/ToolStripView.swift:5-6`,
  `:95-97`. The cell's accessibility label and tooltip are the tool's title, and the tooltip adds the
  shortcut as `"Masking (⇧W)"` (`:123`, `:140`).
- Tool titles, symbols and shortcut strings: `edit` = "Edit"/`D`, `crop` = "Crop & Straighten"/`R`,
  `heal` = "Healing"/`Q`, `redEye` = "Red Eye Correction"/(none), `masking` = "Masking"/`⇧W`, symbol
  `circle.dashed.inset.filled` — `packages/RedlampUI/Sources/Model/EditorTypes.swift:283-318`.
- Any mask-kind shortcut (`M`, `⇧M`, `K`, `⇧J`, `⇧Q`, `⇧Z`) switches into the tool on its own:
  `startDrawing` sets `activeTool = .masking` —
  `packages/RedlampUI/Sources/Model/EditorModel+Masking.swift:35`; AI kinds do the same in
  `createAIMask` (`EditorModel+AIMasks.swift:27`) and `armObjectSelection`
  (`EditorModel+Objects.swift:26`).
- **Esc** leaves. Title **Cancel / Leave Tool**, key `Esc` —
  `packages/RedlampUI/Sources/Shortcuts/ShortcutAction.swift:248`, `:352`. Its order of effect:
  close the Keyboard Shortcuts sheet → cancel drawing or Refine Edge brushing → the eyedropper →
  guides → straightening → presentation → Lights Out → back to the Edit tool —
  `packages/RedlampUI/Sources/Model/EditorModel+Shortcuts.swift:278-299`. So in the Masking tool with
  a tool armed, the first Esc finishes drawing and the second leaves the tool. README phrases it as
  "`Esc` finish drawing or leave the tool" — `README.md:1133`.
- Opening the panel warms the AI models up for the photo:
  `packages/RedlampUI/Sources/Inspector/AppKit/MaskingPanelView.swift:68-69`.

### Creating a new mask

- **Empty state** (no masks yet): a 3-column grid of tiles under the uppercased heading
  **CREATE NEW MASK** (the view is given `title: "Create New Mask"` and renders
  `title.uppercased()`) — `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:14-20`, `:518-522`,
  and `packages/RedlampUI/Sources/Inspector/AppKit/MaskingPanelView.swift:18-23`.
  The grid is `LazyVGrid` with 3 flexible columns, 6-pt spacing; each tile is at least 52 pt tall
  and shows the kind's symbol above its name at 9.5 pt
  (`MaskingPanel.swift:514`, `:522`, `:552-568`).
- **With masks present**: a button labelled **Create New Mask** with a `plus` symbol, in the actions
  bar under the mask list — `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:277-283`,
  `:623-625`.
- **The kinds it offers, in UI order** (`MaskKind.creatable`, which is `allCases` minus
  `existingMask` — `packages/RedlampEngineAPI/Sources/Masks.swift:690-697`; the grid and the menu both
  iterate it, `MaskingPanel.swift:523`, `:594`):

  | # | Label | Symbol | Shortcut | Notes |
  | --- | --- | --- | --- | --- |
  | 1 | Subject | `person.crop.rectangle` | — | AI |
  | 2 | Sky | `cloud.sun` | — | AI |
  | 3 | Background | `rectangle.dashed` | — | AI |
  | 4 | Objects | `cube` | — | AI |
  | 5 | People | `person.2` | — | AI; submenu of parts in the menu form |
  | 6 | Landscape | `mountain.2` | — | AI; submenu of classes everywhere |
  | 7 | Brush | `paintbrush.pointed` | `K` | |
  | 8 | Linear Gradient | `square.split.1x2` | `M` | |
  | 9 | Radial Gradient | `circle.circle` | `⇧M` | |
  | 10 | Color Range | `eyedropper.halffull` | `⇧J` | |
  | 11 | Luminance Range | `sun.max` | `⇧Q` | |
  | 12 | Depth Range | `square.3.layers.3d` | `⇧Z` | AI |

  Names: `packages/RedlampEngineAPI/Sources/Masks.swift:707-723`. Symbols: `:725-741`.
  `isAI` set: subject, sky, background, objects, people, landscape, depthRange — `:700-705`.
  Shortcuts: `packages/RedlampUI/Sources/Shortcuts/ShortcutAction.swift:342-347`. There is no
  shortcut for Subject, Sky, Background, Objects, People or Landscape **(inferred: `ShortcutAction`
  has no cases for them)**.
- **People behaves differently in the grid and in the menu.** The grid is built without an
  `onPersonPart` handler, so its People tile makes an entire-person mask; the menu form (actions bar
  and the Add/Subtract/Intersect buttons) gives People a submenu of parts —
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:15-18` and `:277-283` versus `:595-602`.
  Landscape has a class submenu in both (`:525-534`, `:603-610`).
- **Unavailable kinds are visible but disabled**, with a tooltip. The tooltip is
  `"\(kind.name) arrives in \(phase)"` when the kind is planned, otherwise the kind's name, or
  `"\(kind.name) isn't available for this photo"` —
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:544-547`. Every kind is currently live:
  `plannedPhase` returns `nil` for all of them
  (`packages/RedlampEngineAPI/Sources/Masks.swift:744-749`), so the "arrives in" tooltip cannot
  appear today **(inferred)**.
- `canCreateMask(kind)` is what greys a tile: true for non-AI kinds, and for AI kinds only when the
  kind is in `availableAIMaskKinds` — `packages/RedlampUI/Sources/Model/EditorModel+AIMasks.swift:8-11`.
  While an AI mask is being computed every tile is disabled
  (`MaskingPanel.swift:544`), and the computing tile shows a spinner instead of its icon (`:554-556`).
- New masks are named **Mask 1**, **Mask 2**, … — `MaskLayer(name: "Mask \(nextMaskNumber)")`,
  where `nextMaskNumber` is one past the highest existing `Mask N` —
  `packages/RedlampUI/Sources/Model/EditorModel+Masking.swift:62`, `:92`, `:103-106`.
  AI masks are named after what they found instead: the kind's name, or the person part's name, or
  the Landscape class's name — `packages/RedlampUI/Sources/Model/EditorModel+AIMasks.swift:50-51`,
  `:58`. A mask made from a preset takes the preset's name
  (`EditorModel+MaskPresets.swift:75-76`).
- Decoding a mask with no name falls back to `"Mask"`
  (`packages/RedlampEngineAPI/Sources/Masks.swift:904`).

### The actions bar

Left to right: **Create New Mask** (plus), **Presets** (`wand.and.stars`, tooltip "Apply a mask
preset"), spacer, then an `ellipsis.circle` menu —
`packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:272-306`, `:340-346`.

The ellipsis menu contains, in order:
- **Update AI Masks** — disabled when the edit has no AI masks or one is being computed (`:287-288`).
- **Update AI Masks on N Photos** (literally `"Update AI Masks on \(count) Photos"`), only while more
  than one photo is selected (`:289-294`).
- a divider, then **Delete All Masks** (destructive) (`:295-296`).

### The mask list

- Heading row: the title **Masks**, a checkbox **Show Overlay** with tooltip
  `"Show Overlay (O)"`, and a button with symbol `circle.lefthalf.striped.horizontal` whose tooltip
  is `"Overlay mode, color and opacity"` —
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:56-86`.
- **Rows are listed newest first**: `ForEach(model.maskOutlines.reversed())` —
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:639`.
- Each row: the first component's kind symbol, the mask's name, and an eye button on the right
  (`eye` / `eye.slash`) with tooltip "Hide mask" or "Show mask" — `:641-669`. A hidden mask's name is
  drawn in the tertiary label colour (`:657`). Row height 28 pt (`:671`).
- Single click selects (`:678`); **double-click renames in place** via a text field whose placeholder
  is `"Name"` (`:647-653`, `:674-677`).
- **Drag a row onto another to reorder** (`:679-683`); the drop target draws an accent border
  (`:150-153`). Masks add up, so reordering changes only the list —
  `packages/RedlampUI/Sources/Model/EditorModel+Masking.swift:213-222` ("Masks add up, so the order
  changes only the list"); history step **Reorder Masks** (`:221`).
- **Row context menu**, in order —
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:684-695`:
  1. **Rename…**
  2. **Duplicate** → history "Duplicate \<name>"; the copy is named `"<name> Copy"`
     (`EditorModel+Masking.swift:194-211`)
  3. **Duplicate and Invert** → history "Duplicate and Invert \<name>" (`:210`)
  4. **Reset Adjustments** → history "Reset \<name>" (`EditorModel+Masking.swift:237-242`)
  5. **Save as Mask Preset** (see §8)
  6. divider
  7. **Delete \<name>** (destructive; the label interpolates the mask's name)
- Showing/hiding is also the eye button; history names are `"Hide \<name>"` / `"Show \<name>"` —
  `packages/RedlampUI/Sources/Model/EditorModel+Masking.swift:232-235`.
- Renaming trims whitespace and refuses an empty name; history step **Rename Mask** —
  `packages/RedlampUI/Sources/Model/EditorModel+Masking.swift:224-230`.
- An unfinished rename is cancelled when the selected mask or the selected photo changes
  (`MaskingPanel.swift:698-706`).
- When no mask is selected the panel says **Select a mask to edit its adjustments.** —
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:309-315`.

### The components list

- Section heading **COMPONENTS** (the header uppercases its title) —
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:715`,
  `packages/RedlampUI/Sources/DesignSystem/ParameterSlider.swift:247`.
- Each row reads `"<Kind name> <index>"`, 1-based, e.g. `Radial Gradient 1`, `Subject 1`; a component
  this build doesn't know reads `"Newer Component <index>"` —
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:1019`, `:1026-1029`.
- Row contents, left to right: the operation symbol (tooltip = operation name), the kind symbol, the
  name and index, a spacer, an optional action button, the **Invert** checkbox, and a `trash` button
  with tooltip "Delete component" — `:1020-1060`.
- The optional action button appears for brush, Color Range and Luminance Range components:
  `paintbrush.pointed` with tooltip **"Paint into this brush"**, or `eyedropper` with tooltip
  **"Sample again"** — `:1031-1045`.
- **Component context menu**: "Set to Add", "Set to Subtract", "Set to Intersect"; then, for AI
  components that are not Depth Range, a divider and **Refine Edges** and **Refine Edge Brush** —
  `:1073-1081`.
- **Drag a component row onto another to reorder.** Unlike masks, this changes what the mask covers:
  "The components combine in order, so this can change what the mask covers" —
  `packages/RedlampUI/Sources/Model/EditorModel+Masking.swift:151-161`; history step
  **Reorder Components** (`:158`).
- Deleting the last component deletes the whole mask —
  `packages/RedlampUI/Sources/Model/EditorModel+Masking.swift:163-168`.
- Below the component rows: the Add / Subtract / Intersect buttons, then the selected component's own
  controls (§3), then the mask's own section —
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:719-755`.
- The mask's section header is the mask's **name**, uppercased, with a **Reset** button beside it —
  `:751-752`, `:1002-1010`. (In `docs/images/hero-masks.png` this reads `SUBJECT`; in
  `docs/images/masking.png`, `MASK 2`.)
- **Which component controls show**: the brush's settings whenever brushing; otherwise the selected
  component's, for radial, brush, colorRange, luminanceRange, and any AI kind —
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:773-789`. With nothing selected the panel
  falls back to the **last** component (`EditorModel+Masking.swift:16-19`).

### Pins on the canvas

- **H** toggles them. Title **Show / Hide Pins**, key `H` —
  `packages/RedlampUI/Sources/Shortcuts/ShortcutAction.swift:246`, `:350`; handled only in the Masking
  tool — `packages/RedlampUI/Sources/Model/EditorModel+Shortcuts.swift:137-139`, `:247`.
- Default: **shown** (`showMaskPins = true`) —
  `packages/RedlampUI/Sources/Model/EditorModel.swift:454`.
- What `H` hides is both things: every **other** mask's pin, and the **selected** mask's component
  handles and guides — `packages/RedlampUI/Sources/Editor/MaskOverlayView.swift:38-61`.
- An unselected mask's pin sits at its first component's centre, its tooltip is the mask's name, and
  clicking it selects that mask — `packages/RedlampUI/Sources/Editor/MaskOverlayView.swift:39-45`.
  README: "Pins select the other masks" — `README.md:108`.
- A pin is a filled circle: 11 pt and white at 85% when unselected, 14 pt and accent-coloured when
  selected, with a 6-pt invisible margin so it is easy to hit —
  `packages/RedlampUI/Sources/Editor/MaskOverlayView.swift:430-441`.
- The selected mask's component pins can be **dragged to move** the component, and clicking one
  selects that component — `:541-549` (linear), `:592-599` (radial), `:488-495` (Color Range and
  everything else).
- Component centres: a gradient's midpoint, a brush's first non-erase point, a Color Range's first
  sample, an AI mask's stored centre; a Luminance Range uses its sample point or the image centre,
  and Existing Mask and unknown components sit at the image centre —
  `packages/RedlampEngineAPI/Sources/Masks.swift:606-617`.
- Guides are drawn "while a shape is being drawn too, so its guides follow the drag" —
  `packages/RedlampUI/Sources/Editor/MaskOverlayView.swift:48-49`.

---

## 3. Each mask kind

### Linear Gradient (`M`)

- Make it: **drag on the photo from full effect to no effect.** The on-screen hint is the default
  branch: "Drag on the photo from full effect to no effect." —
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:443`.
- Geometry: "Full effect at `start`, fading to no effect at `end`" —
  `packages/RedlampEngineAPI/Sources/Masks.swift:20-28`.
- **A click without a drag** (movement under 4 pt) places a default gradient: from the click, 0.25 of
  the image height downwards — `packages/RedlampUI/Sources/Editor/MaskOverlayView.swift:92-100`.
- Handles: two round handles, one at each end, each dragging that end; a pin at the centre dragging
  the whole gradient — `packages/RedlampUI/Sources/Editor/MaskOverlayView.swift:529-549`. The two
  solid lines mark start and end, and a dashed line marks the centre (`:510-527`).
- **It has no controls of its own** in the panel: `componentTools` returns `nil` for `.linear`
  (`packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:787`), so only the mask's Amount, Detail
  and local adjustments show. There is no rotation handle; rotation is implicit in where the two ends
  are **(inferred from `LinearMask` having only `start` and `end`,
  `packages/RedlampEngineAPI/Sources/Masks.swift:21-23`)**.
- History: **New Linear Gradient** / **Add Linear Gradient**
  (`"New \(kind.name)"` / `"Add \(kind.name)"`) —
  `packages/RedlampUI/Sources/Model/EditorModel+Masking.swift:67`, `:89`, `:95`.
- Cursor over the canvas while armed: crosshair —
  `packages/RedlampUI/Sources/Editor/MaskOverlayView.swift:28-34`.

### Radial Gradient (`⇧M`)

- Make it: **drag on the photo. Shift keeps it circular.** Exact hint string: "Drag on the photo to
  draw the radial gradient. Shift keeps it circular." —
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:437`. Shift is read at
  `packages/RedlampUI/Sources/Editor/MaskOverlayView.swift:109-112`.
- The drag's start is the **centre**, and the drag sets the two radii (not a corner-to-corner box) —
  `packages/RedlampUI/Sources/Editor/MaskOverlayView.swift:104-112`. Minimum radius 0.01 (`:110-111`).
- **A click without a drag** places an ellipse with `radiusX 0.22`, `radiusY 0.16` —
  `packages/RedlampUI/Sources/Editor/MaskOverlayView.swift:97-98`.
- Radii are fractions of the image **height**, "so a circle stays round whatever the aspect ratio";
  rotation is in degrees clockwise; full effect inside by default —
  `packages/RedlampEngineAPI/Sources/Masks.swift:36-52`.
- Handles: one on each axis to resize, plus a smaller 7-pt handle 18 pt outside the ellipse with
  tooltip **"Drag to rotate"**, plus the centre pin to move —
  `packages/RedlampUI/Sources/Editor/MaskOverlayView.swift:579-599`. The solid ellipse is the outer
  edge, the dashed one the inner, full-effect edge, drawn at `1 - feather/100` (`:564`, `:565-577`).
- Its one control: **Feather**, range **0…100**, default **50**, integer —
  `packages/RedlampEngineAPI/Sources/ParameterSpec.swift:426`;
  `RadialMask.feather` default 50 at `packages/RedlampEngineAPI/Sources/Masks.swift:46`, documented as
  "0...100, as in Lightroom" (`:43`). Shown via `ParameterSlider(parameter: .maskFeather)` —
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:722-725`.
- History: **New Radial Gradient** / **Add Radial Gradient**; dragging a handle records
  "Edit \<mask name>", and the rotate handle "Rotate \<mask name>" —
  `packages/RedlampUI/Sources/Editor/MaskOverlayView.swift:623`, `:645`, `:664`.
- README: "Drag the handles to move, resize, and rotate; radial gradients also have a Feather
  control." — `README.md:107`.

### Brush (`K`)

Full detail in §4. In summary:

- Hint: "Paint on the photo. Hold Option to erase; [ and ] or ⌘-scroll change the size, with Shift
  the feather. Hold Space to move the photo." —
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:439`.
- The tool **stays armed** until Done; every stroke goes into the same component —
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:448-450`,
  `packages/RedlampUI/Sources/Model/EditorModel+Brush.swift:42-58`.
- Controls: the A/B/Erase picker, then Size, Feather, Flow, Density, then the Auto Mask checkbox —
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:726-732`.
- History: **New Brush** on the first stroke, then **Brush Stroke**, or **Erase Brush** for an erase
  stroke — `packages/RedlampUI/Sources/Model/EditorModel+Brush.swift:51`, `:57`, `:92`.

### Color Range (`⇧J`)

- Hint: "Click or drag on the photo to sample a color. Shift-click adds a sample (up to 5)." —
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:438`.
- Click samples a spot; **drag outwards to average over a disc** — the disc's radius is the drag
  distance, and a drag under 4 pt counts as a spot (radius 0) —
  `packages/RedlampUI/Sources/Editor/MaskOverlayView.swift:273-280`. The disc is previewed as a white
  circle while dragging (`:256-264`).
- **Shift** adds a sample rather than replacing the samples —
  `packages/RedlampUI/Sources/Editor/MaskOverlayView.swift:279`, and the view's own comment at
  `:237-238`.
- Samples are drawn on the canvas as white rings, at least 10 pt across, only while the component is
  selected — `packages/RedlampUI/Sources/Editor/MaskOverlayView.swift:473-487`.
- Controls: **Refine**, range **0…100**, default **50**, integer
  (`packages/RedlampEngineAPI/Sources/ParameterSpec.swift:432`;
  `ColorRangeMask.refine` default 50 at `packages/RedlampEngineAPI/Sources/Masks.swift:176`,
  documented "0...100: how far from the samples a colour may be and still be selected" at `:173-174`);
  then a line reading `"<N> of 5 samples"` with a **Remove Last** button, shown only when more than
  one sample is left — `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:733-735`, `:824-840`.
- The selection is read from the edited photo: "Colours are read from the photo every render, so the
  selection follows the global edit's white balance" —
  `packages/RedlampEngineAPI/Sources/Masks.swift:167-168`.
- The tool stays armed until Done (`MaskingPanel.swift:448-450`).

### Luminance Range (`⇧Q`)

- Hint: "Click on the photo to select tones like the one there." —
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:439` (case `.luminanceRange`).
- Controls: a **Luminance Range** bar with **four handles**, a value readout `"<lower> – <upper>"`,
  and a checkbox **Show Luminance Map** —
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:843-860`, `:877-937`.
- The four handles are, left to right: where the range starts (lower feather), where it becomes full,
  where it stops being full, where it ends (upper feather) — `:876`, `:889`, `:939-966`. The inner two
  handles are drawn wider (7 pt vs 5 pt) and brighter (`:917-920`). History name **Luminance Range**
  (`:852`).
- The bar's gradient runs black → white (`:850`).
- Defaults when created directly: `lower 50`, `upper 100`, `lowerFeather 10`, `upperFeather 0` —
  `packages/RedlampEngineAPI/Sources/Masks.swift:121-127`.
- Defaults **after the eyedropper samples**: the range is centred on the sampled lightness, ±10, with
  both feathers 15 — `LuminanceRangeMask.sampled(lightness:at:)`,
  `packages/RedlampEngineAPI/Sources/Masks.swift:145-152`.
- Every bound is clamped to 0…100 and kept in order (`normalized`, `:136-143`).
- Lightness is OKLab L × 100 of the photo **with its global edit**, before local adjustments —
  `packages/RedlampEngineAPI/Sources/Masks.swift:111-112`.
- The tool stays armed until Done (`MaskingPanel.swift:448-450`).
- README: "sample with the eyedropper, then shape the range with four handles (Show Luminance Map)
  … They select on the photo with its global edit, so the selection follows white balance and
  exposure." — `README.md:110`.

### Depth Range (`⇧Z`)

- Controls: the same four-handle bar, titled **Depth Range**, with the end labels **Far** (left) and
  **Near** (right), and a dark-to-light grey gradient — no luminance-map checkbox —
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:862-874`, `:927-935`. History name
  **Depth Range** (`:870`).
- Defaults: `lower 60`, `upper 100`, `lowerFeather 15`, `upperFeather 0`; 0 is farthest, 100 nearest
  — `packages/RedlampEngineAPI/Sources/Masks.swift:404-419`.
- Source of the depth map: "the depth map comes from the file (iPhone depth) or a depth model" —
  `packages/RedlampEngineAPI/Sources/Masks.swift:405-406`. The engine uses the embedded map when the
  photo has one; otherwise Depth Anything 3 if downloaded, else the Depth Anything V2 (small)
  estimator — `packages/RedlampEngine/Sources/RedlampEngine+Masks.swift:265-283`.
- It is an AI kind (`isAI`), so it is computed and kept as a bitmap, and it has **no** Feather/Edge
  sliders: `componentTools` routes `.depthRange` to its own editor before the generic AI branch —
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:740-746`.
- No Refine Edges or Refine Edge Brush in its context menu: those are gated on
  `kind != .depthRange` — `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:1077`.

### Subject, Background

- Both come from Apple Vision's built-in models, with nothing to download:
  `VisionMaskProvider.supportedKinds = [.subject, .background, .people]` —
  `packages/RedlampMasking/Sources/VisionMasks.swift:46`; Background is the Subject mask inverted in
  kind (`:52-54`).
- No model prompt: `modelID(for:)` returns `nil` for them —
  `packages/RedlampEngine/Sources/RedlampEngine+Models.swift:8-15`.
- Make them: one click on the tile or the menu item; there is nothing to drag. Progress shows as
  `"Finding subject…"` / `"Finding background…"` (`"Finding \(kind.name.lowercased())…"`) —
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:395-398`.
- Failure messages: "No subject was found in this photo." / "No background was found in this photo."
  (`"No \(kind.name.lowercased()) was found in this photo."`) —
  `packages/RedlampEngineAPI/Sources/Masks.swift:556`.
- Controls: **Feather** (0…100, default 0) and **Edge** (-100…100, default 0) — see §5.
- Mask name and history: "Subject" / "Background", history **New Subject** / **New Background** —
  `packages/RedlampUI/Sources/Model/EditorModel+AIMasks.swift:50-61`.

### Sky

- Available on every Mac with no download: `availableMaskKinds()` inserts `.sky` unconditionally —
  `packages/RedlampEngine/Sources/RedlampEngine+Masks.swift:231-233`. `modelID(for: .sky)` is `nil`
  (`RedlampEngine+Models.swift:8-15`), so Sky never shows the download prompt **(inferred)**.
- Quality improves once Depth Anything 3 is downloaded, but it is not required:
  `packages/RedlampEngine/Sources/RedlampEngine+Masks.swift:28-29`, `:265-283`;
  `docs/lightroom-comparison.md:112` ("Sky also uses Depth Anything 3").
- Failure message: "No sky was found in this photo." —
  `packages/RedlampEngineAPI/Sources/Masks.swift:556`.
- Controls: Feather and Edge (§5).
- README's description of how it is built (classical estimate + Segment Anything + Depth Anything 3 +
  per-pixel edges) is at `README.md:111`; it is engine internals and out of scope for the manual.

### People, and each part

- Make it: the **People** menu item opens a submenu of parts; the grid tile makes an entire-person
  mask (see §2).
- Parts offered, in order, with their exact labels —
  `packages/RedlampEngineAPI/Sources/Masks.swift:439-455`, ordered by
  `PersonPart.allCases.filter(available.contains)` at
  `packages/RedlampUI/Sources/Model/EditorModel+AIMasks.swift:13-17`:

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
  `packages/RedlampEngine/Sources/RedlampEngine+Masks.swift:248-256`. An iPhone's own hair matte beats
  SAM 3's (`RedlampEngine+Masks.swift:287-291`).
- **One component per person.** "People adds one component per person (one for all of them when
  subtracting or intersecting)" —
  `packages/RedlampUI/Sources/Model/EditorModel+AIMasks.swift:19-20`, `:31-33`, `:44-49`.
- Names: an entire-person mask is named "People"; a part mask takes the part's name, e.g. "Teeth" —
  `packages/RedlampUI/Sources/Model/EditorModel+AIMasks.swift:50-51`.
- Failure messages:
  - no people at all: "No people were found in this photo." —
    `packages/RedlampEngineAPI/Sources/Masks.swift:554`
  - a part missing: `"No <part, lowercased> was/were found in this photo."` (plural for Eyebrows,
    Iris and Pupil, Lips, Teeth, Clothes) — `:457-461`, `:543-545`, `:557`
  - Hair with no matte and no SAM 3: "Hair masks need a photo with its own hair matte, such as an
    iPhone portrait." — `:558`
  - Body Skin / Facial Hair / Clothes with no SAM 3: `"<Part> masks need the SAM 3 evaluation
    model."` — `:559`. **Contradiction, see §10:** SAM 3 is no longer evaluation-only in its manifest.
- Controls: Feather and Edge (§5).

### Objects

- Make it, step by step:
  1. Pick **Objects**. A hover preview begins: moving the pointer tints what a click would select, in
     the accent colour at 45% — `packages/RedlampUI/Sources/Editor/MaskOverlayView.swift:297-304`,
     `:373-384`; the preview waits 40 ms after the pointer settles
     (`packages/RedlampUI/Sources/Model/EditorModel+Objects.swift:42-56`).
  2. **Click** the object, or **drag** — what a drag does is set by the panel's picker.
  3. **Click or brush again to add**, **Option-click or Option-brush to take away** —
     `packages/RedlampUI/Sources/Editor/MaskOverlayView.swift:333-336`, `:357-359`.
- The panel's picker is labelled **Drag** (segmented, in the drawing hint box) with options
  **Rectangle** and **Brush**, and tooltip "What a drag on the photo selects with: a box around the
  object, or a stroke over it" —
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:467-477`; option names at
  `packages/RedlampUI/Sources/Model/EditorModel+Objects.swift:5-17`.
- Hints, chosen by the picker —
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:440-442`:
  - Rectangle: "Click an object, or drag a box around it, to select it. Click again to add to it,
    Option-click to take away."
  - Brush: "Click an object, or brush over it, to select it. Click or brush again to add to it, with
    Option to take away."
- A box drag is drawn as a white dashed rectangle; a brush drag as a 16-pt accent-coloured stroke —
  `packages/RedlampUI/Sources/Editor/MaskOverlayView.swift:305-323`. A drag needs 4 pt of movement to
  count (`:338`).
- A brushed stroke becomes up to **8** prompt points spread evenly along it —
  `packages/RedlampUI/Sources/Model/EditorModel+Objects.swift:110-126`.
- History names: **New Objects** on the first selection, then **Add to Object**,
  **Remove from Object**, or **Box Around Object** —
  `packages/RedlampUI/Sources/Model/EditorModel+Objects.swift:96-103`.
- Failure message: "Nothing was found to select there." —
  `packages/RedlampEngineAPI/Sources/Masks.swift:555`.
- Needs a download the first time: Segment Anything 2.1 (tiny) — see §5.
- Controls: Feather and Edge (§5). The tool stays armed until Done
  (`MaskingPanel.swift:448-450`).

### Landscape, its categories, and the adaptive presets

- **Landscape always opens a submenu of classes** — there is no plain "Landscape" command —
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:525-534` (grid) and `:603-610` (menu).
- Classes in menu order, with their exact labels — `LandscapeClass.allCases` at
  `packages/RedlampEngineAPI/Sources/Masks.swift:465-479`:
  1. **Water**
  2. **Vegetation**
  3. **Mountains**
  4. **Architecture**
  5. **Natural Ground**
  6. **Artificial Ground**
  7. **Snow** (marked in the code as "Lightroom Classic 15's", `:468`)
- Sky is a mask kind of its own, not a Landscape class —
  `packages/RedlampEngineAPI/Sources/Masks.swift:464`.
- Each pixel belongs to exactly one class (`:464`).
- The mask is named after the class, e.g. "Mountains"; history **New Mountains** —
  `packages/RedlampUI/Sources/Model/EditorModel+AIMasks.swift:50-61`.
- Failure message: `"No mountains were found in this photo."` — plural only for Mountains
  (`packages/RedlampEngineAPI/Sources/Masks.swift:482-485`, `:557`).
- Needs SAM 3 (988.1 MB) — see §5.
- **The adaptive Landscape presets** are mask presets, in the Presets menu, not in the Landscape
  submenu: **Brighten Snow** and **Enhance Vegetation** — see §8.
- Controls: Feather and Edge (§5).

---

## 4. The brush in detail

### A, B and Erase

- Three brushes: `BrushChoice` with raw values **A**, **B**, **Erase** —
  `packages/RedlampUI/Sources/Model/BrushSettings.swift:4-9`. The picker is segmented and shows the
  raw values as its labels — `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:791-805`.
- The active brush starts as **A** — `packages/RedlampUI/Sources/Model/EditorModel.swift:392`.
- **Option switches to Erase for as long as it is held**: `strokeBrush(erasing:)` returns `.erase`
  while Option is down or Erase is chosen —
  `packages/RedlampUI/Sources/Model/EditorModel+Brush.swift:23-26`, read from the event's modifier
  flags at `packages/RedlampUI/Sources/Editor/MaskOverlayView.swift:130`, `:147`, `:220`.
- Erasing takes coverage away: `BrushStroke.erase` — "Removes coverage instead of adding it"
  (`packages/RedlampEngineAPI/Sources/Masks.swift:68-69`); erase strokes take coverage from earlier
  ones (`:98`).
- You cannot start a mask with an erase stroke: "Nothing to erase from yet" —
  `packages/RedlampUI/Sources/Model/EditorModel+Brush.swift:52-55`.
- The three brushes keep separate settings, saved across launches in `UserDefaults` under
  `app.redlamp.brushes` — `packages/RedlampUI/Sources/Model/BrushSettings.swift:62-98`,
  `packages/RedlampUI/Sources/Model/EditorModel.swift:389-391`.
- Their **built-in starting settings** differ —
  `packages/RedlampUI/Sources/Model/BrushSettings.swift:63-67` with the `BrushSettings` defaults at
  `:19-25`:

  | Brush | Size | Feather | Flow | Density | Auto Mask |
  | --- | --- | --- | --- | --- | --- |
  | A | 25 | 50 | 100 | 100 | off |
  | B | 8 | 20 | 100 | 100 | off |
  | Erase | 15 | 50 | 100 | 100 | off |

### The sliders

Shown in this order (`ParameterID.brushParameters`,
`packages/RedlampEngineAPI/Sources/ParameterID.swift:220-223`, rendered at
`packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:729-731`):

| Label | Range | Default | Step | Format | Source |
| --- | --- | --- | --- | --- | --- |
| Size | 1…100 | 25 | 1 | integer | `ParameterSpec.swift:427` |
| Feather | 0…100 | 50 | 1 | integer | `ParameterSpec.swift:428` |
| Flow | 1…100 | 100 | 1 | integer | `ParameterSpec.swift:429` |
| Density | 1…100 | 100 | 1 | integer | `ParameterSpec.swift:430` |

The defaults above are the catalog's; the actual value a slider shows is the active brush's saved one
(`packages/RedlampUI/Sources/Model/EditorModel+Masking.swift:276-281`,
`packages/RedlampUI/Sources/Model/BrushSettings.swift:39-59`), which for B and Erase starts
differently (table above).

What each does, from the stroke model
(`packages/RedlampEngineAPI/Sources/Masks.swift:55-71`):
- **Feather** — "0...100: the share of the radius that fades out" (`:62-63`).
- **Flow** — "0...100: how much each dab adds, so overlapping dabs build up" (`:64-65`).
- **Density** — "0...100: the most coverage the stroke can reach" (`:66-67`).
- **Size** is stored on the stroke as a radius in image heights, not as the 1–100 slider value:
  `radius = 0.003 + 0.3 × (size/100)²` — "from a few pixels to a third of it, finer at the small end
  where precision matters" — `packages/RedlampUI/Sources/Model/BrushSettings.swift:33-37`,
  `packages/RedlampEngineAPI/Sources/Masks.swift:60-61`.

### Auto Mask

- Checkbox labelled **Auto Mask**, with tooltip "Keeps the brush to colors like the one under its
  center" — `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:808-821`.
- It is per brush (A, B and Erase each have their own) — the binding reads
  `model.brushes[model.activeBrush].autoMask` (`:812-815`).
- Model comment: "Keeps each dab to colours like the one under its centre (Lightroom's Auto Mask)" —
  `packages/RedlampEngineAPI/Sources/Masks.swift:70-71`.

### Pen pressure

- Recorded per point: `BrushStroke.pressures`, "Pen pressure at each point, 0...1. Empty when the
  input had none (full pressure)." — `packages/RedlampEngineAPI/Sources/Masks.swift:57-58`,
  and `pressure(at:)` clamps and defaults to 1 (`:93-95`).
- Read only from tablet events: "The pen's pressure when the stroke comes from a tablet; mice paint at
  full pressure" — `packages/RedlampUI/Sources/Editor/MaskOverlayView.swift:230-234`.

### Size and feather shortcuts

- **`[` and `]`**: size, or feather with **Shift**. The keys are the rating keys, redirected while a
  brush's tool is active: `case .decreaseRating where sizedBrush != nil` —
  `packages/RedlampUI/Sources/Model/EditorModel+Shortcuts.swift:153-155`. `sizedBrush` is `.mask`
  only while brushing — `packages/RedlampUI/Sources/Model/EditorModel+BrushSize.swift:24-36`.
- Step sizes: size moves by **15% of its value, at least 1**; feather by **10** —
  `packages/RedlampUI/Sources/Model/EditorModel+Brush.swift:96-108`.
- **⌘-scroll** over the photo: size grows by about **15% a notch** (`pow(1.15, notches)`), or feather
  by **5 a notch** with Shift — `packages/RedlampUI/Sources/Model/EditorModel+BrushSize.swift:56-76`.
- Both are clamped to the parameters' ranges (`EditorModel+Brush.swift:100`, `:103`).
- A ring shows the size as it changes: an outer solid circle at the full radius and an inner dashed
  circle at `radius × (1 − feather/100)`, with a readout
  `"Size <n>  ·  Feather <n>"`, and a `minus` glyph in the middle when the Erase brush is active —
  `packages/RedlampUI/Sources/Editor/MaskOverlayView.swift:131-184`.
- README: "`[` and `]` or ⌘-scroll change the size, with Shift the feather; the brush's ring shows its
  size as it changes, also from the panel's sliders" — `README.md:109`.

### Space-drag to move the photo

- Hold **Space** and drag to pan while painting — `beginSpacePan` / `noteSpacePanUse` /
  `endSpacePan` in `packages/RedlampUI/Sources/Model/EditorModel+BrushSize.swift:78-98`; the file's
  own summary is "Sizing brushes from the keyboard and pointer, and panning with Space, in every tool
  (UX-15)" (`:16`).
- A Space press with **no** click or drag toggles the zoom instead, as Space does outside a tool —
  `packages/RedlampUI/Sources/Model/EditorModel+BrushSize.swift:91-98`.
- It applies in every tool that draws over the canvas: masking, crop, heal and guide placing —
  `packages/RedlampUI/Sources/Model/EditorModel+BrushSize.swift:19-22`.
- README: "hold `Space` and drag to move the photo in a tool" — `README.md:1128`; and "Space-drag
  moves the photo while you paint. In every tool the wheel and pinch zoom." — `README.md:109`.

### Painting into an existing brush component

- The `paintbrush.pointed` button on a brush component row re-arms the brush on that component,
  tooltip "Paint into this brush" —
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:1031-1044`,
  `packages/RedlampUI/Sources/Model/EditorModel+Brush.swift:10-21`.
- Points closer than a tenth of the radius to the last are skipped
  (`packages/RedlampUI/Sources/Model/EditorModel+Brush.swift:63-75`).
- Strokes are kept as vectors in the edit, so brush masks live in `edit.json` rather than as PNGs —
  `README.md:109`, `README.md:1147`.

---

## 5. AI masks

### Which model each kind uses

| Mask kind | Model | Download | Prompt on first use? |
| --- | --- | --- | --- |
| Subject | Apple Vision (built into macOS) | none | no |
| Background | Apple Vision | none | no |
| People — Entire Person, Face Skin, Eyebrows, Eye Sclera, Iris and Pupil, Lips, Teeth | Apple Vision | none | no |
| People — Hair | the photo's own hair matte; else SAM 3 | none / 988.1 MB | no prompt (see note) |
| People — Body Skin, Facial Hair, Clothes | SAM 3 | 988.1 MB | no prompt (see note) |
| Sky | Apple Vision + a classical estimate, improved by Depth Anything 3 when present | none (DA3 optional, 336.1 MB) | no |
| Objects | Segment Anything 2.1 (tiny) | 79.6 MB | **yes** |
| Landscape (all seven classes) | SAM 3 | 988.1 MB | **yes** |
| Depth Range | the photo's own depth map; else Depth Anything 3 if downloaded; else Depth Anything V2 (small) | none / 49.8 MB | **yes**, unless the photo has its own depth map |

Sources: the kind→model map `RedlampEngine.modelID(for:)` —
`packages/RedlampEngine/Sources/RedlampEngine+Models.swift:8-18` (objects → `sam2.1-tiny`,
depthRange → `depth-anything-v2-small`, landscape → `sam3`, everything else `nil`);
`modelNeeded(for:)` returns `nil` for a photo with an embedded depth map (`:28-37`);
Vision's kinds `packages/RedlampMasking/Sources/VisionMasks.swift:46`; Sky always available
`packages/RedlampEngine/Sources/RedlampEngine+Masks.swift:231-233`; person-part sources
`packages/RedlampEngine/Sources/RedlampEngine+Masks.swift:248-256`,
`packages/RedlampMasking/Sources/SAM3Concepts.swift:30`.

**Note on the People parts that need SAM 3:** the People submenu calls `createAIMask` directly, not
`startAIMask`, so it does **not** show the download prompt —
`packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:597-599`, `:981-983` versus
`packages/RedlampUI/Sources/Model/EditorModel+AIMasks.swift:70-84`. If SAM 3 is offered but not
downloaded, the mask fails with the message
`"<Part> masks need the SAM 3 evaluation model."`
(`packages/RedlampEngine/Sources/RedlampEngine+Masks.swift:326-327`,
`packages/RedlampEngineAPI/Sources/Masks.swift:559`). The practical route for a photographer is to
download SAM 3 by making a Landscape mask, or from Settings › Models **(inferred)**.

### The models, their sizes and licences

From the manifests in `packages/RedlampMasking/Resources/Models/` (sizes are the sum of each
manifest's `files[].bytes`, and the app formats them with `ByteCountFormatter` `.file`, i.e. decimal
MB — `packages/RedlampEngineAPI/Sources/Models.swift:52-54`):

| Manifest | `name` (shown) | `purpose` (shown) | Size | Weights licence | Compute |
| --- | --- | --- | --- | --- | --- |
| `sam2.1-tiny.json` | Segment Anything 2.1 (tiny) | "Objects masks: click an object to select it, click again to add or remove parts." | 79,644,968 B → **79.6 MB** | Apache-2.0 | `cpuAndGPU` |
| `sam3.json` | SAM 3 | "Landscape masks (water, vegetation, mountains, architecture, natural and artificial ground) and the People parts Vision can't give: hair, facial hair, body skin and clothes." | 988,085,795 B → **988.1 MB** | SAM License (ships as `LICENSE.txt`) | `cpuAndGPU` |
| `depth-anything-3-mono-large.json` | Depth Anything 3 (mono, large) | "Sky masks (with Segment Anything) and Depth Range masks, from one model." | 336,101,695 B → **336.1 MB** | Apache-2.0 (ships `LICENSE.txt`) | `cpuAndGPU` |
| `depth-anything-v2-small.json` | Depth Anything V2 (small) | "Depth Range masks for photos without an embedded depth map." | 49,819,122 B → **49.8 MB** | Apache-2.0 (no `LICENSE.txt` in the files list) | `all` |
| `owlv2-base.json` | OWLv2 (base) | "Finding things named in words to remove: litter, signs, cables, cars, people, birds." | 365,102,113 B → **365.1 MB** | Apache-2.0 | `cpuAndGPU` |
| `flux2-klein-4b-fill.json` | FLUX.2 [klein] 4B | "Generative Remove: fills areas too large for content-aware Remove, labelled as generated fill." | 2,414,734,243 B → **2.41 GB** | Apache-2.0 | `cpuAndGPU` |

OWLv2 and FLUX.2 belong to removal, not masking, but they appear in the same Settings › Models list
**(inferred: the list shows every `ModelCatalog.offered` manifest,
`packages/RedlampEngine/Sources/RedlampEngine+Models.swift:20-26`)**.

- All six manifests are `cleared: true, evaluationOnly: false`, so **none** is evaluation-only today;
  every one is offered by default. (`ModelCatalog.offered` filter:
  `packages/RedlampMasking/Sources/Models/ModelManifest.swift:97-99`.)
- FLUX.2 has `minimumMemory: 17179869184` (16 GiB); no masking model sets one. A Mac with too little
  memory sees **"Not for this Mac"** and a note
  `"Needs 16 GB of memory; this Mac has 8 GB."` —
  `packages/RedlampUI/Sources/Settings/ModelsSettings.swift:82-83`,
  `packages/RedlampEngineAPI/Sources/Models.swift:57-64`,
  `packages/RedlampMasking/Sources/Models/ModelManifest.swift:47-50`.

### Settings › Models

File: `packages/RedlampUI/Sources/Settings/ModelsSettings.swift`. Doc comment: "Settings › Models:
the models Redlamp downloads on first use, with their size and state" (`:4`).

Exact strings:
- Empty list: **"No downloadable models."** (`:16`).
- First section footer: **"Subject, Background, People and Sky masks use models built into macOS.
  Others are downloaded only when you first use them. Every model runs on this Mac: photos are never
  uploaded."** (`:22-26`).
- Per row: the model's `name`, then its `purpose` in caption, then
  **"Licence: \<licence>"** with a **"Read it"** link when the licence ships with the download
  (`:52-61`). The link's URL is the manifest's `LICENSE.txt`
  (`packages/RedlampEngine/Sources/RedlampEngine+Models.swift:67`), so **"Read it" appears only for
  SAM 3, Depth Anything 3, OWLv2 and FLUX.2** — the two whose file lists have no `LICENSE.txt`
  (`sam2.1-tiny`, `depth-anything-v2-small`) show the licence name without a link **(inferred from the
  manifests' `files` lists)**.
- A model awaiting review: **"Awaiting licence review (\<decision>)."** in orange (`:63-67`).
- Right-hand control, by state (`:72-87`):
  - downloaded → **Remove**
  - downloading → a spinner, or a progress bar while this pane started the download
  - not published → **"Not published"**
  - doesn't fit this Mac → **"Not for this Mac"**
  - otherwise → **"Download 988.1 MB"** (the button label is `"Download \(model.formattedSize)"`)
- Second section: a toggle **"Offer models awaiting licence review"**, footer **"For evaluation:
  models whose training data's terms are still being reviewed. Masks made with them are kept in your
  edits either way."** (`:28-37`). It is stored as `app.redlamp.evaluationModels` (`:10`,
  `packages/RedlampMasking/Sources/Models/ModelManifest.swift:87`), and
  `REDLAMP_EVALUATION_MODELS=1` has the same effect (`:89-95`).
- Failure: a warning row with the message
  **"\<name> couldn't be downloaded: …"** or **"\<name> couldn't be removed: …"** (`:104`, `:114`).
- README: "Settings › Models lists the downloadable models with their size, and removes them. Every
  model runs on the Mac; photos are never uploaded. Each shows its licence, which comes with the
  download. Models still under licence review are offered only when you turn on evaluation models." —
  `README.md:118`.

### When a needed model isn't downloaded yet

The Masking panel shows a prompt in place of the status line
(`MaskStatus`, `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:350-382`), triggered by
`startAIMask` finding a model is needed
(`packages/RedlampUI/Sources/Model/EditorModel+AIMasks.swift:70-78`; the comment names App Review
4.2.3: "the size is shown and nothing downloads without consent"). Its exact contents:

1. **"\<Kind> masks use \<Model name>, a \<size> download."** — e.g. "Objects masks use Segment
   Anything 2.1 (tiny), a 79.6 MB download." (`:357`)
2. **"It runs on this Mac; your photos are never uploaded. You can remove it in Settings › Models."**,
   plus **" Its licence: \<licence>."** when the model declares one (`:360-363`)
3. a link **"Read the licence"**, when the licence ships with the download (`:367-370`)
4. two buttons: **Not Now** and **Download** — Download is the default action (Return) (`:372-377`)

- **Not Now** clears the prompt and the pending target
  (`packages/RedlampUI/Sources/Model/EditorModel+AIMasks.swift:108-111`).
- **Download** downloads, then carries straight on with the mask that was asked for
  (`:87-106`). While downloading the panel shows a progress bar and
  **"Downloading model… \<n>%"** (`MaskingPanel.swift:383-391`).
- Other status lines in the same place: **"Finding \<kind>…"** with a spinner while a mask is being
  computed, and **"Updating AI masks…"** when Update AI Masks is running (`:392-402`).
- An error shows with a warning triangle, a **Report…** link (tooltip "Report a Bug about this
  message") and an ✕ to dismiss (`:403-424`).

### Update AI Masks

- Where: the actions bar's `ellipsis.circle` menu — **Update AI Masks**, and
  **"Update AI Masks on N Photos"** while several photos are selected —
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:286-294`.
- What it does for the photographer: recomputes every AI mask of the edit with today's models,
  "keeping each component's place, operation and inversion. A person is matched by their index." —
  `packages/RedlampUI/Sources/Model/EditorModel+AIMasks.swift:123-135`. Refine Edge strokes are
  applied again to the new mask (`:169-175`).
- Why it exists: AI masks are computed from the photo without its edit and kept as bitmaps, so they
  never move as you edit (`packages/RedlampEngineAPI/Sources/Masks.swift:225-227`;
  `README.md:112`).
- Pasted or synced settings recompute their AI masks for the new photo automatically —
  `packages/RedlampUI/Sources/Model/EditorModel+MaskPresets.swift:86-91`,
  `packages/RedlampUI/Sources/Model/EditorModel+Sync.swift:32`.
- If some can't be updated: **"N AI masks couldn't be updated and kept their previous result."**
  (singular "mask" for one) — `packages/RedlampUI/Sources/Model/EditorModel+AIMasks.swift:132-134`.
- History step: **Update AI Masks** (`:135`).

### Refine Edges

- Where: a component row's context menu, for AI components other than Depth Range — **Refine Edges**
  — `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:1077-1079`.
- What it does: "Solves an AI mask's edges again from the photo, as masks of its kind are made
  now" — `packages/RedlampUI/Sources/Model/EditorModel+MaskPresets.swift`. The engine solves the
  edge per pixel at the size masks are stored at: the sky's matte for Sky, closed-form matting with
  ViTMatte's strands for Subject, Background and whole people, closed-form for Objects and
  Landscape; People's parts keep a guided filter (`refineMaskEdges`,
  `packages/RedlampEngine/Sources/RedlampEngine+Masks.swift`; MSK-31). For the photographer: it
  solves the mask's edge again from the photo, bringing back stray hairs an older mask missed; a
  mask made recently comes back much as it was.
- It has no settings. History step: **Refine Edges** (`:109`).
- Failure: **"The edges couldn't be refined: …"** (`:112`).
- README: "**Refine Edges** solves their edges again from the photo, as masks of their kind are made now" — `README.md:120`.

### The Refine Edge Brush

- Where: the same component context menu — **Refine Edge Brush** —
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:1080`.
- What it does: "paint over an AI mask's edge (hair, fur, a frayed sleeve) and the engine solves
  coverage there again, per pixel, from the photo, keeping the mask as it was elsewhere. Each stroke
  is one history step, and is kept with the mask so Update AI Masks applies it again." —
  `packages/RedlampUI/Sources/Model/EditorModel+EdgeBrush.swift:18-20`.
- Hint while armed: **"Paint over an edge to solve it again from the photo, hair by hair. [ and ] or
  ⌘-scroll change the size."** — `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:432-433`.
  The hint box's button reads **Done** (`:459`).
- Its one control, inside the hint box: a **Size** slider, range **1…100**, default **12** —
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:488-503`
  (`Slider(value: $model.edgeBrushSize, in: 1 ... 100)`),
  `packages/RedlampUI/Sources/Model/EditorModel.swift:396-397`. It is **not** a `ParameterCatalog`
  entry, though `[`, `]` and ⌘-scroll clamp it to `maskBrushSize`'s 1…100
  (`packages/RedlampUI/Sources/Model/EditorModel+EdgeBrush.swift:108-113`,
  `packages/RedlampUI/Sources/Model/EditorModel+BrushSize.swift:67`).
- Its strokes have **feather 0** — a hard-edged band —
  `packages/RedlampUI/Sources/Model/EditorModel+EdgeBrush.swift:48-50`. The ring shows only
  `"Size <n>"` (`packages/RedlampUI/Sources/Editor/MaskOverlayView.swift:163-166`), and painted
  strokes are shown as translucent white bands until their edge is solved (`:135-139`, `:187-208`).
- A spinner beside the Size slider shows while a stroke is being solved
  (`MaskingPanel.swift:497-500`). Strokes are solved one at a time, in order
  (`EditorModel+EdgeBrush.swift:64-104`).
- History step per stroke: **Refine Edge Brush** (`EditorModel+EdgeBrush.swift:91`). Failure:
  **"The edge couldn't be refined: …"** (`:99`).
- Esc leaves it (`packages/RedlampUI/Sources/Model/EditorModel+Shortcuts.swift:281-282`).

### Feather and Edge for AI masks

Shown for any selected AI component except Depth Range —
`packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:743-746`,
`packages/RedlampUI/Sources/Inspector/AppKit/MaskingPanelView.swift:135-137`:

| Label | Range | Default | Step | Format | Source |
| --- | --- | --- | --- | --- | --- |
| Feather | 0…100 | 0 | 1 | integer | `ParameterSpec.swift:433` |
| Edge | -100…100 | 0 | 1 | signed integer | `ParameterSpec.swift:434` |

- What they do: "Feather (0...100) softens the mask's edge and Edge (-100...100) moves it out or in,
  as Lightroom's sliders for AI masks do; both leave the mask as it is at 0" —
  `packages/RedlampEngineAPI/Sources/Masks.swift:244-249`.
- They are stored on the component, not as mask adjustments
  (`packages/RedlampUI/Sources/Model/EditorModel+Masking.swift:316-320`, `:353-362`), and are omitted
  from the sidecar when 0 (`packages/RedlampEngineAPI/Sources/Masks.swift:349-354`).
- README: "**Feather** and **Edge** soften an AI mask's edge or move it out or in" — `README.md:112`.
- `docs/lightroom-comparison.md:120` notes Lightroom Classic 15.5 added the same two sliders.

---

## 6. Local adjustments in a mask

Panel order, top to bottom
(`packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:751-766`, and the AppKit port
`packages/RedlampUI/Sources/Inspector/AppKit/MaskingPanelView.swift:141-150`):

1. the mask's name as an uppercased section header, with a **Reset** button
2. **Amount**
3. **Detail**
4. a gap
5. the sliders of `ParameterID.localParameters` minus the two swatch parameters, with extra gaps
   after Tint, Blacks, Dehaze and Defringe (`MaskingPanel.gapAfter`,
   `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:775`)
6. the **Color** swatch
7. **Curve**

`ParameterID.localParameters` order is declared at
`packages/RedlampEngineAPI/Sources/ParameterID.swift:193-199` ("The local adjustments, in Lightroom's
masking-panel order"); the swatch pair at `:201-202`.

| # | Label | Range | Default | Step | Format | Spec line |
| --- | --- | --- | --- | --- | --- | --- |
| — | Amount | 0…200 | 100 | 1 | integer | `ParameterSpec.swift:425` |
| — | Detail | -100…100 | 0 | 1 | signed int | `:431` |
| 1 | Temp | -100…100 | 0 | 1 | signed int | `:394` |
| 2 | Tint | -100…100 | 0 | 1 | signed int | `:395` |
| 3 | Exposure | -4…4 | 0 | 0.05 | signed, 2 decimals | `:396-399` |
| 4 | Contrast | -100…100 | 0 | 1 | signed int | `:400` |
| 5 | Highlights | -100…100 | 0 | 1 | signed int | `:401` |
| 6 | Shadows | -100…100 | 0 | 1 | signed int | `:402` |
| 7 | Whites | -100…100 | 0 | 1 | signed int | `:403` |
| 8 | Blacks | -100…100 | 0 | 1 | signed int | `:404` |
| 9 | Texture | -100…100 | 0 | 1 | signed int | `:405` |
| 10 | Clarity | -100…100 | 0 | 1 | signed int | `:406` |
| 11 | Dehaze | -100…100 | 0 | 1 | signed int | `:407` |
| 12 | Hue | -180…180 | 0 | 0.5 | signed, 1 decimal | `:408-415` |
| 13 | Saturation | -100…100 | 0 | 1 | signed int | `:416` |
| 14 | Sharpness | -100…100 | 0 | 1 | signed int | `:417` |
| 15 | Noise | -100…100 | 0 | 1 | signed int | `:418` |
| 16 | Moiré | 0…100 | 0 | 1 | integer | `:419` |
| 17 | Defringe | -100…100 | 0 | 1 | signed int | `:420` |
| 18 | Halation | -100…100 | 0 | 1 | signed int | `:421` |
| 19 | Bloom | -100…100 | 0 | 1 | signed int | `:422` |
| 20 | Color Hue | 0…360 | 0 | 1 | integer | `:423` |
| 21 | Color Saturation | 0…100 | 0 | 1 | integer | `:424` |

Notes:
- Temp and Tint here are **-100…100 relative sliders**, unlike the global Temp (2000–50000 K) and
  Tint (-150…150) — compare `ParameterSpec.swift:394-395` with `:233-237`.
- Local Exposure's range is **-4…4**, narrower than the global **-5…5** (`:396-399` vs `:241-244`).
- Halation and Bloom in a mask change how strongly the film glow applies where the mask covers; "the
  radii stay global" — `packages/RedlampEngineAPI/Sources/ParameterID.swift:185-187`.
- Only values that differ from the default are stored; setting a value back to its default removes it
  (`packages/RedlampEngineAPI/Sources/Masks.swift:867-874`).
- Writing to a non-local parameter on a mask is ignored (`guard parameter.isLocal`, `:870`).
- Sliders 20 and 21 are **not drawn as sliders** in the panel; they are the Color swatch (below).
- Slider gestures in general (double-click to reset, Shift-drag for fine control, Option-drag for a
  clipping preview on Exposure/Highlights/Shadows/Whites/Blacks, click a value to type one, arrow
  keys to step, Shift for ten) — `README.md:1140-1143`.
- `,` and `.` step through the selected mask's adjustments while the Masking tool is open, instead of
  the Basic panel's — `packages/RedlampUI/Sources/Model/EditorModel+Shortcuts.swift:314-318`.

### The Color swatch

- Row label **Color**, with a 34 × 16 pt rounded swatch button on the right —
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:168-215`.
- When saturation is 0 the swatch is empty with a red diagonal line through it (`:186-193`), and its
  tooltip is **"Color: none. Click to tint the mask"**; otherwise the tooltip reads
  **"Color: hue \<n>°, saturation \<n>"** (`:199-200`).
- Clicking opens a popover (240 pt wide) with a 150-pt colour wheel labelled **Color**, then the
  **Color Hue** and **Color Saturation** sliders — `:201-213`.
- What it does: "The Color swatch: a tint of this hue (as on a color wheel) and strength over what
  the mask covers" — `packages/RedlampEngineAPI/Sources/ParameterID.swift:188-191`. The panel's own
  comment: "a tint of a hue and saturation over what the mask covers, picked on a wheel as Color
  Grading's are" — `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:166-167`.
- History step name: `"<Mask name> Color"` (`:205`).

### Curves

- Row label **Curve**, with a segmented channel picker and a reset button
  (`arrow.counterclockwise`, tooltip **"Reset the mask's Curves"**, disabled while every curve is
  straight) — `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:218-258`.
- Channels, in order: **RGB**, **Red**, **Green**, **Blue** —
  `packages/RedlampEngineAPI/Sources/Masks.swift:947-958`.
- The graph is 210 pt tall (`MaskingPanel.swift:250-257`); channel tints are near-white for RGB and
  red/green/blue for the others (`:261-270`).
- What they are: "A mask's Curves, as Lightroom's masks have: a point curve for all three channels,
  then one for each, on the display-referred values the global Tone Curve works on" —
  `packages/RedlampEngineAPI/Sources/Masks.swift:944-946`.
- Curves are dropped from the edit once every channel is straight again
  (`packages/RedlampEngineAPI/Sources/Masks.swift:834-840`, `:989-991`).
- History steps: `"<Mask name> Curve"`, and `"Reset <Mask name> Curves"` —
  `packages/RedlampUI/Sources/Model/EditorModel+Masking.swift:261`, `:270`.

### Reset

- The **Reset** button beside the mask's name, and **Reset Adjustments** in the mask list's context
  menu, both call `resetMaskAdjustments` —
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:691`, `:1002-1010`.
- It clears every adjustment, the curves, and returns Amount to 100 and Detail to 0; the components
  are untouched — `packages/RedlampEngineAPI/Sources/Masks.swift:876-882`. History step
  `"Reset <Mask name>"` (`packages/RedlampUI/Sources/Model/EditorModel+Masking.swift:241`).
- Option-clicking the section title turns it into **"RESET \<NAME>"** and resets with one click —
  `packages/RedlampUI/Sources/DesignSystem/ParameterSlider.swift:244-258`. Note the mask's own section
  header is given an **empty** parameter list
  (`packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:751`), so Option-click does nothing there
  **(inferred: `resetMode` requires `!parameters.isEmpty`, `ParameterSlider.swift:245`)**.

---

## 7. The overlay

- **Show Overlay** — a checkbox in the Masks header, tooltip **"Show Overlay (O)"** —
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:67-71`. Default **on**
  (`showMaskOverlay = true`, `packages/RedlampUI/Sources/Model/EditorModel.swift:376`).
- Shortcut **O**, title **Show / Hide Mask Overlay** —
  `packages/RedlampUI/Sources/Shortcuts/ShortcutAction.swift:244`, `:348`. It only acts in the Masking
  tool; in the Crop tool the same key cycles the crop overlay instead —
  `packages/RedlampUI/Sources/Model/EditorModel+Shortcuts.swift:122-129`.
- The options popover is opened by the `circle.lefthalf.striped.horizontal` button, tooltip
  **"Overlay mode, color and opacity"**, and is 250 pt wide with three rows: **Mode**, **Color**,
  **Opacity** — `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:72-86`, `:89-132`.
- **Modes**, in menu order, with their exact names
  (`MaskOverlayStyle.menu`, `packages/RedlampEngineAPI/Sources/Rendering.swift:91-96`; names at
  `:78-88`):
  1. **Color Overlay** (the default — `packages/RedlampUI/Sources/Model/EditorModel.swift:459`)
  2. **Color Overlay on B&W**
  3. **Image on Black**
  4. **Image on White**
  5. **B&W**
  6. **Image on B&W**
- A seventh mode, **Luminance Map**, is not in the menu: "the luminance map belongs to Luminance
  Range" (`packages/RedlampEngineAPI/Sources/Rendering.swift:89-90`). It is turned on by the
  **Show Luminance Map** checkbox in the Luminance Range editor
  (`packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:854-858`) and replaces the chosen mode
  while an overlay is shown (`packages/RedlampUI/Sources/Model/EditorModel.swift:913`). Default off
  (`:469`).
- **Colours**: **Red**, **Green**, **Blue**, **White** —
  `packages/RedlampEngineAPI/Sources/Rendering.swift:110-125`. Default **Red**
  (`packages/RedlampUI/Sources/Model/EditorModel.swift:455`).
- **Cycling**: **⇧O**, title **Cycle Mask Overlay Color** —
  `packages/RedlampUI/Sources/Shortcuts/ShortcutAction.swift:245`, `:349`; it steps `maskOverlayColor`
  to `.next`, wrapping red → green → blue → white → red
  (`packages/RedlampEngineAPI/Sources/Rendering.swift:113-115`,
  `packages/RedlampUI/Sources/Model/EditorModel+Shortcuts.swift:130-136`). In the Crop tool ⇧O turns
  the crop overlay instead (`:131-134`).
- **Opacity**: a slider over **0…1** with a percent readout, default **0.55**, i.e. **55%** —
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:117-126`,
  `packages/RedlampEngineAPI/Sources/Rendering.swift:106-107`,
  `packages/RedlampUI/Sources/Model/EditorModel.swift:463-464`.
- **Color and Opacity are disabled in the modes that don't tint.** Only Color Overlay, Color Overlay
  on B&W and Luminance Map tint (`MaskOverlayStyle.tints`,
  `packages/RedlampEngineAPI/Sources/Rendering.swift:98-104`); the two rows are disabled otherwise
  (`MaskingPanel.swift:115`, `:125`).
- **Automatic hiding.** While a mask's adjustment or its Amount is being dragged, the overlay steps
  aside so the edit itself shows — "Lightroom's automatic overlay toggle". Sliders that shape the
  mask (Feather, Detail, Refine) keep it —
  `packages/RedlampUI/Sources/Model/EditorModel.swift:986-996`. It comes back when the drag ends
  (`:1046-1054`).
- The overlay also disappears while the before/original is shown (`!isShowingOriginal`, `:988`), and
  only ever shows the **selected** mask (`:989`).
- README's list of modes: "a mask overlay (`O`) in Lightroom's modes (Color Overlay, on B&W, Image on
  Black or White, B&W, Image on B&W), colors and opacity" — `README.md:116`.

---

## 8. Mask presets

### Where they are

- A **Presets** button (`wand.and.stars`) in the actions bar, and in the empty state beneath the
  Create New Mask grid; tooltip **"Apply a mask preset"** —
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:21-24`, `:284`, `:320-348`.
- The menu lists the built-in presets then the user's, each as a plain button with its name; a preset
  whose AI masks this photo can't make is disabled
  (`canApply`, `packages/RedlampUI/Sources/Model/EditorModel+MaskPresets.swift:27-29`,
  `MaskingPanel.swift:327-330`).
- Below the user's own, a divider and a **Delete Preset** submenu listing them (destructive) —
  `MaskingPanel.swift:331-339`.

### The built-in list

`MaskPreset.builtIn`, in menu order —
`packages/RedlampEngineAPI/Sources/MaskPresets.swift:93-136`:

| # | Name | Mask it makes | Adjustments |
| --- | --- | --- | --- |
| 1 | **Blue Sky** | Sky | Temp -12, Exposure -0.3, Highlights -25, Saturation +15 |
| 2 | **Brighten Subject** | Subject | Exposure +0.35, Shadows +15, Clarity +8 |
| 3 | **Darken Background** | Background | Exposure -0.5, Saturation -15 |
| 4 | **Smooth Skin** | People → Face Skin | Texture -35, Clarity -10 |
| 5 | **Whiten Teeth** | People → Teeth | Exposure +0.25, Saturation -45 |
| 6 | **Pop Eyes** | People → Iris and Pupil | Exposure +0.3, Clarity +20, Saturation +15 |
| 7 | **Brighten Snow** | Landscape → Snow | Exposure +0.35, Whites +15, Temp -4, Clarity +5 |
| 8 | **Enhance Vegetation** | Landscape → Vegetation | Saturation +12, Texture +10, Shadows +10 |

(Lines: Blue Sky `:94-98`, Brighten Subject `:99-103`, Darken Background `:104-108`, Smooth Skin
`:109-113`, Whiten Teeth `:114-118`, Pop Eyes `:119-123`, Brighten Snow `:124-129`, Enhance
Vegetation `:130-135`.)

- They are **adaptive**: "Adaptive presets in the spirit of Lightroom's: each recomputes its mask for
  the photo" (`:92`), and the applied mask takes the preset's name, amount, detail and adjustments
  (`packages/RedlampUI/Sources/Model/EditorModel+MaskPresets.swift:74-83`). History step
  `"Apply <preset name>"` (`:83`).
- Applying one shows the same progress line as any AI mask, and on failure the message
  `"<Preset name>: <reason>"` (`:69`).
- Brighten Snow and Enhance Vegetation both make a Landscape mask; which class each uses is carried
  beside the components in `landscapeClasses`
  (`packages/RedlampEngineAPI/Sources/MaskPresets.swift:20-23`, `:38-41`), defaulting to Vegetation
  for presets saved before that field existed (`:40`).

### Saving your own

- **Exact menu label: "Save as Mask Preset"** — in a mask row's context menu in the mask list —
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:692`. It saves with the mask's current
  name, with no dialog (`model.saveMaskPreset(from: mask.id, name: mask.name)`).
- Saving a second preset with the same name replaces the first
  (`packages/RedlampUI/Sources/Model/EditorModel+MaskPresets.swift:31-38`).
- **Brush strokes are not kept** — "everything but brush strokes (which belong to one photo) is
  kept"; brush, Existing Mask and unknown components are dropped, AI components become requests, and
  gradients and ranges are kept as they are —
  `packages/RedlampEngineAPI/Sources/MaskPresets.swift:43-73`.
- README: "**Mask presets:** Blue Sky, Brighten Subject, Darken Background, Smooth Skin, Whiten Teeth
  and Pop Eyes compute their masks for each photo; save your own from any mask." — `README.md:113`.

### Where saved presets are stored

- In macOS user defaults, under the key **`app.redlamp.maskPresets`**, as a JSON array of
  `MaskPreset` — `packages/RedlampUI/Sources/Model/EditorModel+MaskPresets.swift:7-19`.
- They are therefore **not** `.redrecipe` files in `~/Library/Application Support/Redlamp/Recipes/`,
  which is where Develop recipes live (`README.md:1157`) **(inferred: different storage path and
  type)**. The concrete file is the app's preferences plist for the `app.redlamp` domain
  **(inferred: `UserDefaults.standard` with no explicit suite)**.
- Brush settings are stored the same way, under `app.redlamp.brushes`
  (`packages/RedlampUI/Sources/Model/BrushSettings.swift:87`); the evaluation-models toggle under
  `app.redlamp.evaluationModels`
  (`packages/RedlampMasking/Sources/Models/ModelManifest.swift:87`).

---

## 9. Every masking-related shortcut

From `packages/RedlampUI/Sources/Shortcuts/ShortcutAction.swift` — the single registry the key
monitor, the menus and the ⌘/ sheet all read (`:94-98`). `⌘/` opens the sheet
(**Keyboard Shortcuts**, `:269`, `:372`), grouped by the categories below (`:412-416`).

### Category "Tools" (`ShortcutCategory.tools`, `:87`, `:159-162`)

| Keys | Title shown | Lines |
| --- | --- | --- |
| `⇧W` | Masking | `:234`, `:338` |
| `K` | Brush Mask | `:238`, `:342` |
| `M` | Linear Gradient Mask | `:239`, `:343` |
| `⇧M` | Radial Gradient Mask | `:240`, `:344` |
| `⇧J` | Color Range Mask | `:241`, `:345` |
| `⇧Q` | Luminance Range Mask | `:242`, `:346` |
| `⇧Z` | Depth Range Mask | `:243`, `:347` |

### Category "Masking" (`ShortcutCategory.masking = "Masking"`, `:89`, `:163-164`)

| Keys | Title shown | Lines |
| --- | --- | --- |
| `O` | Show / Hide Mask Overlay | `:244`, `:348` |
| `⇧O` | Cycle Mask Overlay Color | `:245`, `:349` |
| `H` | Show / Hide Pins | `:246`, `:350` |
| `⌫` | Delete Selected Mask or Spot | `:247`, `:351` |
| `Esc` | Cancel / Leave Tool | `:248`, `:352` |

Modifier glyphs are drawn in the order ⌥ ⇧ ⌘ (`:39-48`); `⌫` is `KeyCombo(.delete)` (`:53`), `Esc` is
`KeyCombo(.escape)` (`:52`).

### Masking-relevant keys that live in other categories

| Keys | Title / behaviour in masking | Lines |
| --- | --- | --- |
| `[` `]` | Registered as **Decrease Rating** / **Increase Rating**, but while a brush tool is active they size the brush (Shift: feather) | `:255-256`, `:359-360`; redirect at `packages/RedlampUI/Sources/Model/EditorModel+Shortcuts.swift:153-155` |
| `D` | Edit — leaves masking | `:231`, `:335` |
| `Space` (hold) | Pan the photo while a tool draws; a press with no drag toggles the zoom | `packages/RedlampUI/Sources/Model/EditorModel+BrushSize.swift:78-98` |
| `⌘-scroll` | Size the active brush (Shift: feather) — not a `ShortcutAction` | `packages/RedlampUI/Sources/Model/EditorModel+BrushSize.swift:56-76` |
| `,` `.` | Select previous/next setting — the selected mask's adjustments while masking | `:228-229`, `:331-332`; `EditorModel+Shortcuts.swift:314-318` |
| `-` `=` | Decrease/Increase the selected setting (⇧ for larger steps) | `:229-230`, `:333-334` |

Availability: `O` and `⇧O` work in the Masking **or** Crop tool; `H` only while masking; `⌫` while
masking with a mask selected, or while healing with a spot selected
(`packages/RedlampUI/Sources/Model/EditorModel+Shortcuts.swift:246-248`).

### README's own masking shortcut row

`README.md:1133`: "`O` show/hide overlay · `⇧O` cycle overlay color · `H` show/hide pins · `⌫`
delete selected mask · `Esc` finish drawing or leave the tool · brushing: `[` `]` or `⌘`-scroll size
(`⇧` feather), hold `⌥` to erase · Objects: drag a box or brush (the panel chooses), `⌥`-click or
`⌥`-brush to take away". Every key matches the registry; the README's wording is shorter than the
titles the app shows (e.g. `⌫` is titled "Delete Selected Mask or Spot" in the app).

`README.md:1132` (Tools row) also matches: "`⇧W` Masking · `M` linear gradient · `⇧M` radial gradient
· `K` brush · `⇧J` color range · `⇧Q` luminance range · `⇧Z` depth range".

---

## 10. Differences from Lightroom Classic, and what isn't available

### Beyond Lightroom

- **A mask's Detail** — keeps only the mask's textured or only its flat areas. No Lightroom
  equivalent. `README.md:114`; `docs/lightroom-comparison.md:130` marks the row "Beyond".
- **Any mask reusable as a component of another, in Add, Subtract or Intersect.**
  `docs/lightroom-comparison.md:130`: "Lightroom can start a new mask from an existing one; Redlamp
  also adds, subtracts or intersects one inside another". README: `README.md:114`.
- **Refine Edges and the Refine Edge Brush** are marked "Different" from Lightroom's —
  `docs/lightroom-comparison.md:119`: "Refine Edges, which solves a mask's whole edge again per
  pixel, and a Refine Edge brush that solves an edge again where you paint".
- **Local Halation and Bloom** sliders in a mask (film-glow effects Lightroom has no equivalent of —
  `docs/lightroom-comparison.md:102` lists halation and bloom as "Lightroom: No").

### Things a Lightroom user would notice as different

- **AI masks don't follow your edit.** They are computed from the photo without its edit and kept as
  bitmaps, so they never move while you edit; you refresh them deliberately with **Update AI Masks**.
  `README.md:112`; `docs/lightroom-comparison.md:112` ("Edges are solved when a mask is made, not
  refined again as you edit").
- **Models are downloaded on consent, with their size and licence shown**, and run only on the Mac.
  Lightroom's AI masks have no download step. `README.md:118`;
  `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:350-382`.
- **Subject, Background, People face parts and Sky need nothing**, but **Objects (79.6 MB)**,
  **Landscape and the SAM 3 People parts (988.1 MB)** and **Depth Range (49.8 MB)** do —
  `docs/lightroom-comparison.md:113-118`.
- **Hair** comes from the photo's own hair matte (iPhone portraits) unless SAM 3 is downloaded —
  `README.md:111`; `packages/RedlampEngineAPI/Sources/Masks.swift:538-539`, `:558`.
- **Landscape has no plain "Landscape" command** — you pick a class.
  (`packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:525-534`.)
- **Mask presets are stored in user defaults**, not as files you can move between Macs
  (`packages/RedlampUI/Sources/Model/EditorModel+MaskPresets.swift:7-19`) **(inferred as a
  difference)**.
- **Local Whites and Blacks move the end points** as the global sliders do, for new edits
  (process 13) — `docs/lightroom-comparison.md:124-125`. Process versions are out of the manual's
  scope but the behaviour is visible.
- **Red Eye Correction is a separate tool and not built yet** (Phase 3) —
  `packages/RedlampUI/Sources/Model/EditorTypes.swift:321-326`. It is not part of masking, but it
  sits in the same tool strip and is dimmed.

### Listed as not yet available

- **Point Color inside masks** — the only masking row not Done:
  `docs/lightroom-comparison.md:128`, "In progress", Phase P2, tracker `TON-29`, note "With an Even
  Skin Tone preset on Face Skin and Body Skin". The Masking panel has no Point Color control today
  **(inferred: no such string in `MaskingPanel.swift`)**.
- Everything else in the Masking table of `docs/lightroom-comparison.md:105-130` is marked **Done**.
- No mask **kind** is pending: `MaskKind.plannedPhase` returns `nil` for every case —
  `packages/RedlampEngineAPI/Sources/Masks.swift:744-749`.
- The older `docs/lightroom-feature-inventory.md:116-150` still carries phase tags (P1–P3) for
  masking features that have since shipped; it is a planning inventory, not a statement of what is
  available. Use `docs/lightroom-comparison.md` for current state.

### README / code disagreements

| Topic | README says | The code says | Which the code supports |
| --- | --- | --- | --- |
| Built-in mask presets | "Blue Sky, Brighten Subject, Darken Background, Smooth Skin, Whiten Teeth and Pop Eyes" — `README.md:113` | **Eight** presets: those six plus **Brighten Snow** and **Enhance Vegetation** — `packages/RedlampEngineAPI/Sources/MaskPresets.swift:93-136` | The code. (README does mention Brighten Snow elsewhere, in the Landscape sentence at `README.md:111`, but not Enhance Vegetation anywhere.) |
| Local adjustment list | "Temp, Tint, Exposure, Contrast, Highlights, Shadows, Whites, Blacks, Texture, Clarity, Dehaze, Hue, Saturation, Sharpness, Noise, a Color swatch … and Curves" — `README.md:115` | 21 local parameters: the README's list **plus Moiré, Defringe, Halation and Bloom** — `packages/RedlampEngineAPI/Sources/ParameterID.swift:193-199`; sliders at `ParameterSpec.swift:419-422` | The code. Both `docs/images/hero-masks.png` and `docs/images/masking.png` show Moiré, Defringe, Halation and Bloom in the panel. |
| Objects download size | "an 80 MB download" — `README.md:111`; "an 80 MB download" — `docs/lightroom-comparison.md:114` | 79,644,968 bytes, which the app formats as **79.6 MB** (the button reads "Download 79.6 MB") — `packages/RedlampMasking/Resources/Models/sam2.1-tiny.json`, `packages/RedlampEngineAPI/Sources/Models.swift:52-54` | Both; the README rounds. Quote 79.6 MB in the manual if you quote the app. |
| SAM 3 download size | "a 988 MB download" — `README.md:111` | 988,085,795 bytes → **988.1 MB** | Both; the README rounds. |
| Depth Anything 3 size | "a 336 MB download" — `README.md:111` | 336,101,695 bytes → **336.1 MB** | Both; the README rounds. |
| SAM 3's standing | `README.md:118`: "Models still under licence review are offered only when you turn on evaluation models" (implying SAM 3 is cleared, which `README.md:111` confirms: "under Meta's SAM License, which comes with it") | The manifest is `cleared: true, evaluationOnly: false` (`packages/RedlampMasking/Resources/Models/sam3.json`), so it is offered to everyone — but the **error message still calls it an evaluation model**: `"<Part> masks need the SAM 3 evaluation model."` (`packages/RedlampEngineAPI/Sources/Masks.swift:559`) | The manifest and the README: SAM 3 is cleared. The error string is stale. Don't repeat "evaluation model" in the manual; describe it as a download the app offers. |
| Depth Range model | "estimated by Depth Anything 3 (or V2 Small)" — `README.md:111` | The prompt offers **Depth Anything V2 (small), 49.8 MB** (`modelID(for: .depthRange) == "depth-anything-v2-small"`, `packages/RedlampEngine/Sources/RedlampEngine+Models.swift:8-15`); DA3 is used only if already downloaded for Sky (`packages/RedlampEngine/Sources/RedlampEngine+Masks.swift:265-273`) | The code; the README's parenthesis understates which one you are offered. |
| Mask Amount units | "the mask's Amount (0–200%)" — `README.md:115` | Range 0…200, format `.integer`, so the slider shows `100`, not `100%` — `packages/RedlampEngineAPI/Sources/ParameterSpec.swift:425`, `:137-139` | The code for the on-screen reading; the range is the same. |
| "reset" in the mask list | "a mask list where you can show and hide, rename, duplicate, 'duplicate and invert', reset, delete, and drag to reorder" — `README.md:116` | The menu item is **Reset Adjustments** — `packages/RedlampUI/Sources/Inspector/MaskingPanel.swift:691` | The code; use the exact label. |

---

## 11. Screenshots in `docs/images` that show masking

Sizes from `sips -g pixelWidth -g pixelHeight`.

### Usable as manual figures

| File | Pixels | What is visible |
| --- | --- | --- |
| `docs/images/masking.png` | 1800 × 991 | The whole window. Right panel: histogram, tool strip, then the Masks panel — the **Masks** title with **Show Overlay** checked, a two-row mask list (**Mask 2** selected, **Mask 1** below, each with its eye button), the **Create New Mask** button, the **COMPONENTS** heading with one row **Radial Gradient 1** and its **Invert** checkbox, the **Add / Subtract / Intersect** buttons, a **Feather** slider at 70, then the **MASK 2** section with its **Reset** button, **Amount** 100 and the local sliders (Temp +30, Exposure +0.90, and the rest at 0, down to Moiré, Defringe and Halation). On the canvas: a **radial gradient in the red Color Overlay**, with its ellipse, its axis handles and its centre pin. Left panel: Navigator, Recipes, Snapshots and History (showing mask history steps such as "Mask 2 Temp +30", "New Radial Gradient"). Filmstrip along the bottom. Referenced from `README.md:772`. |
| `docs/images/hero-masks.png` | 2400 × 1500 | The whole window with a **Subject** mask on a dancer in red. Masks panel: **Masks**, **Show Overlay** checked, one list row **Subject**, the **Create New Mask** and **Presets** buttons with the ellipsis menu, **COMPONENTS** with **Subject 1** and its **Invert** checkbox, the **Add / Subtract / Intersect** buttons, then the **SUBJECT** section with **Reset**, **Amount** 100, **Detail** 0 and the **full local slider list** — Temp, Tint, Exposure +0.30, Contrast, Highlights, Shadows, Whites, Blacks, Texture, Clarity +15, Dehaze, Hue 0.0, Saturation, Sharpness, Noise, Moiré, Defringe, Halation, Bloom. No overlay tint is drawn on the photo in this frame. Best figure for the local-adjustment list. Referenced from `README.md:768` with the alt text "The dancer selected by a Subject mask, shown in the red mask overlay, with the mask's Exposure and Clarity raised in the Masks panel on the right". |

### Research contact sheets — not app UI, not suitable as manual figures

These show masks as grey/black-and-white coverage maps beside the photo, with no panel or overlay.
They belong to `docs/research/notes/MSK-17-sky-bakeoff.md`.

| File | Pixels | What is visible | Referenced from |
| --- | --- | --- | --- |
| `docs/images/masking-sky-bakeoff.jpg` | 1046 × 1400 | Contact sheet comparing sky-mask methods: render, OneFormer, classical, DA3, Florence-2, auto-prompted SAM 2.1, SAM 3 | `docs/research/notes/MSK-17-sky-bakeoff.md:42` |
| `docs/images/masking-sky-disagreements.jpg` | 1800 × 480 | Two Panasonic photos: render, OneFormer, DA3, SAM 2.1, SAM 3 | `MSK-17-sky-bakeoff.md:53` |
| `docs/images/masking-sky-edges.jpg` | 1549 × 1385 | Four tree/willow photos at 4096 px, each as render, mask without SkyMatte, mask with it — three columns, grey vs hard black-and-white coverage through bare branches | `MSK-17-sky-bakeoff.md:110` |
| `docs/images/masking-landscape-bakeoff.jpg` | 1100 × 1591 | Six photos: render, OneFormer, SAM 3 by text | `MSK-17-sky-bakeoff.md:201` |

There are no other masking screenshots in `docs/images` (the remaining `hero-*.png` files cover
compare, film looks, the palette, shortcuts and sliders).

---

## Appendix A: feedback feature IDs for the Masking area

`docs/feedback/areas.json:86-180` — area `masking`, label `component:masking`, summary "Masks and
local adjustments: AI masks, brushes, gradients and ranges.", trackers `MSK` and `INF`. Its features,
in order, are a ready-made chapter outline:

`masking.subject` Subject · `masking.sky` Sky · `masking.background` Background · `masking.objects`
Objects · `masking.people` People · `masking.landscape` Landscape · `masking.depth-range` Depth
Range · `masking.brush` Brush · `masking.linear` Linear Gradient · `masking.radial` Radial Gradient ·
`masking.color-range` Color Range · `masking.luminance-range` Luminance Range · `masking.combining`
Combining Masks · `masking.refine` Refine Edges and Edge Brush · `masking.overlay` Overlay and Mask
List · `masking.local-adjustments` Local Adjustments · `masking.presets` Mask Presets ·
`masking.update-ai` Update AI Masks · `masking.models` AI Model Downloads · `masking.other`
Something else in Masking.

The same titles appear in the in-app feedback catalog
(`packages/RedlampUI/Sources/Feedback/FeedbackAreaCatalog.swift:97`, `:142`).

## Appendix B: which automation scenario exercises which feature

`packages/RedlampAutomation/Sources/Scenarios/MaskingScenarios.swift`. Each scenario's ID, its
one-line description and the features it claims:

| Scenario ID | Description | Features claimed | Lines |
| --- | --- | --- | --- |
| `masking.gradients` | "Linear and radial gradients, and every local slider dragged on the selected mask" | `masking.linear`, `masking.radial`, `masking.local-adjustments` | `:21-62` |
| `masking.brush` | "The brush paints a stroke, and its settings move" | `masking.brush` | `:64-105` |
| `masking.ranges` | "Color, luminance and depth ranges sampled from the photo" | `masking.color-range`, `masking.luminance-range`, `masking.depth-range` | `:107-159` |
| `masking.ai` | "Subject, Sky, Background and People from Apple Vision; Update AI Masks; Refine Edges" | `masking.subject`, `masking.sky`, `masking.background`, `masking.people`, `masking.update-ai`, `masking.refine`, `masking.models` | `:161-221` |
| `masking.objects-and-landscape` | "Objects (Segment Anything) by a click, a box and a stroke, and Landscape (SAM 3)" | `masking.objects`, `masking.landscape` | `:223-276` |
| `masking.combining` | "Add, subtract and intersect components, invert, and reuse a mask in another" | `masking.combining` (plus the Existing Mask kind and the Detail parameter) | `:278-315` |
| `masking.list-and-overlay` | "The mask list's operations, reordering masks and components, the overlay in every style and opacity, and the pins" | `masking.overlay` | `:317-375` |
| `masking.brush-sizes` | "[ and ] size the Masking and Healing brushes, and never the rating" | `masking.brush`, `healing.remove` | `:377-421` |
| `masking.presets` | "Every built-in mask preset, and saving one" | `masking.presets` | `:423-445` |

Gap worth noting: no masking scenario claims `masking.local-adjustments` beyond the gradients one,
and none claims `masking.other` **(inferred from the claim lists above)**.
