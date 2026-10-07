# Masks panel: design (UX-17)

Approved by the owner on 7 October 2026, with the decisions below. It answers the task audit ([`UX-17-masks-panel-audit.md`](../research/notes/UX-17-masks-panel-audit.md)): every task there should take no more steps than in Lightroom Classic, with nothing reachable only from a context menu. It is built in the harness first, then in the app as rows UX-20 to UX-26.

## What changes

1. **One picker starts every mask,** at the top of the panel, and the same picker opens from Add, Subtract and Intersect.
2. **People and Landscape pickers** say what the photo holds before anything is made: the people found, and the regions found.
3. **Every action is on screen:** a menu button on each mask and each component, the operation's icon as a menu, and an AI component's tools beside its sliders.
4. **Masks preview themselves:** a coverage thumbnail on each row, and the overlay while the pointer is over a mask or a component.
5. **Invert and Amount lead a mask's settings,** and an eye can show one mask alone.
6. **Messages appear where they belong,** and the armed tool is named at the top of the panel.

## The panel, top to bottom

### Header

Masks, then New Mask (opens the picker), Mask Presets, the overlay's switch (`O`) and options, Pins (`H`), and a menu with Update AI Masks, Update AI Masks on N Photos and Delete All Masks. These are the controls of the bar under the list today, moved up so they don't move as the list grows.

While a tool is armed, a strip under the header names it and says how to stop: "Painting into Brush 2. Option erases, [ and ] change the size. Done (Esc)". It replaces the drawing hint in the status line.

### The list

Newest first, as now. Each row, 36 pt high:

- **A thumbnail** of the mask's coverage, white on black, in the photo's shape (36 × 24 pt at most).
- **The name,** dimmed when hidden. A double-click renames it.
- **The eye:** hides or shows the mask. Option-click shows this mask alone and hides the others, as one history step ("Show Only Sky"); Option-click again shows them all.
- **A menu button** (on the selected row, and on others under the pointer): Rename…, Duplicate, Duplicate and Invert, Invert, Reset Adjustments, Save as Mask Preset…, Delete.

The pointer over a row shows that mask's overlay on the photo, even with the overlay switched off, in the overlay's colour and mode. Dragging still reorders, and the context menu stays, with the same items as the menu button.

With no masks, the picker takes the list's place, so the first mask is one click away, as the tile grid is today.

### The picker

A popover of tiles, in three groups, as the tile grid is laid out today:

- **AI:** Subject, Sky, Background, People, Objects, Landscape.
- **Drawn:** Brush, Linear Gradient, Radial Gradient.
- **Range:** Color Range, Luminance Range, Depth Range.

Then Existing Mask, a list of the photo's other masks. Its title says what it does: "New Mask", "Add to Sky", "Subtract from Sky", "Intersect with Sky".

A tile whose model isn't downloaded shows its size; choosing it asks in the picker ("SAM 3, 1.2 GB. Download / Not Now"), not in the status line. A tile that can't work on this photo is dimmed, with the reason on hover.

### The People picker

Choosing People, from New Mask or from Add, Subtract or Intersect, opens it in the panel, where the list was:

- **The people found,** as square crops around each face (or each person, when no face is found), each with a checkbox, and All. The pointer over a crop outlines that person on the photo.
- **The parts:** Entire Person, Face Skin, Body Skin, Eyebrows, Eye Sclera, Iris and Pupil, Lips, Teeth, Hair, Facial Hair and Clothes, as checkboxes. Parts that need SAM 3 say so, and ask to download it when ticked.
- **Separate masks,** when more than one person is ticked: a mask for each person rather than one for all.
- **Create Mask** (or "Create 3 Masks", "Subtract", "Intersect"), and Cancel.

Each component made names its person: "Face Skin · Person 2". When nobody is found, the picker says so in place of the crops.

### The Landscape picker

The same for Landscape: the regions SAM 3 finds, each with its share of the photo ("Vegetation, 34%"), as checkboxes; Separate masks; Create. Landscape needs SAM 3, an evaluation model, so this is offered only with evaluation models turned on, as Landscape is today.

### The selected mask

Its settings, in this order:

1. **The mask's header:** its name, Invert (the whole mask), Amount, and Reset.
2. **Its components,** in the order they apply (the header says "applied top to bottom"). Each row: the operation's icon, which is a menu (Add, Subtract, Intersect); the kind and its person or class; Invert; a menu button (Duplicate, Delete, and for AI components Refine Edges and Refine Edge Brush). The pointer over a row shows that component's own coverage.
3. **The selected component's own settings,** always in place under the components: for an AI component, Feather and Edge with Refine Edges and Refine Edge Brush as buttons beside them; for a brush, its size, feather, flow, density and Auto Mask (`A` while brushing, as in Lightroom); for a range, its samples; for a radial gradient, its feather.
4. **Add, Subtract and Intersect** as three buttons in a row, each opening the picker.
5. **The adjustments:** Detail, the local sliders, Color, Curves and Point Color, as now.

### Pins

A mask's pin goes where the mask covers most, inside it (the point furthest from its edge), rather than at its centre, which can be outside a crescent or a ring. The pointer over a pin shows the mask's overlay, and a click selects it, as now.

### Messages

Progress shows on the row of the mask being made ("Finding people…"); a failure shows under that row, or under the tile that was chosen, and clears with the next action. The status line under the list goes.

## What the engine and the edit need

- **Who is in the photo:** a new `EditingEngine` call (`peopleFound`) returning each person Vision finds, left to right (their box, and their face's box when there is one), cached per photo as the masks are. `MaskRequest` gains the people to make (`people`), so a picker's choice makes only theirs; a face part goes with the person whose mask covers most of its face, as faces are numbered on their own.
- **Which regions:** SAM 3's classes with their share of the photo, from the same encoding Landscape masks use.
- **Thumbnails:** a mask's coverage at thumbnail size, rendered by the engine and cached by the mask's contents.
- **Pins:** the point furthest inside a mask's coverage, computed with the thumbnail.
- **Invert for a whole mask:** a decision for the owner, below.

Nothing here changes how an existing edit renders.

## Built in the harness first

As the command palette was:

- **Live** (`--scene masks-panel`): the new panel beside the sample photo on the real canvas, with a checklist of the audit's fourteen tasks that ticks itself as each is done, and a log of every action.
- **States** (`--scene masks-panel-states`): each state as a still specimen: no masks; the picker; the People picker with three people; the Landscape picker; a mask with an AI component selected; a brush armed; a download asked; an error; sixteen masks.

The panel replaces today's in the app only once every task in the checklist has been done through it.

## Then, in the app

In these rows of the tracker:

1. **UX-20:** the picker, the header and messages in place.
2. **UX-21:** the People picker, with the engine's people and `MaskRequest.instances`.
3. **UX-22:** actions on screen: the menu buttons, the operation menu, an AI component's tools.
4. **UX-23:** thumbnails, previews on hover, and pins inside the mask.
5. **UX-24:** Invert for a whole mask, and Option-click to show one mask alone.
6. **UX-25:** mask presets applied to every selected photo.
7. **UX-26:** the Landscape picker (evaluation models).

Each is built in the SwiftUI reference and the AppKit panel, with parity scenes, and with regression scenarios that reach every control through the UI, menus and pickers included (no scenario reaches these today). Part 3 of the manual is updated with each, and `mise run e2e` is run.

## Decisions (7 October 2026)

The owner chose:

1. **Invert for a whole mask** is a flag stored with the mask, as Lightroom has: a new field in the sidecar. An older Redlamp keeps it but draws the mask uninverted.
2. **Option-click on an eye** is a history step that changes the edit, so the export matches what's shown.
3. **Effect presets** for a mask's adjustments come later, after the panel (UX-27).
4. **The People picker** opens in the panel, where the list was, so the photo stays clear with the people outlined on it.
