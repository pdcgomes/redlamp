# UX-17: the Masks panel, task by task

The owner finds the Masks panel confusing at times (6 October 2026). This note walks fourteen common masking tasks through Redlamp's panel, step by step, and through Lightroom Classic's, and says where Redlamp's way is longer, hidden or unclear. It is the input to the panel's redesign, which comes back to the owner for approval before anything is built.

## In short

- **People gives no choice of who.** A People part applies to everyone found, as one component per person, with nothing to say which component is whom. Brightening one face of three takes deleting the others' components, found by selecting each in turn. Lightroom Classic shows a thumbnail of each person found, with checkboxes for their parts and an option to make a separate mask for each.
- **Making a mask starts in three places that look different:** the tile grid when the photo has no masks, the Create New Mask menu under the list once it has some, and the Add, Subtract and Intersect menus under the selected mask's components. Lightroom Classic starts every mask from one Create New Mask picker, and its Add and Subtract buttons open the same choices.
- **Actions are hidden in context menus:** changing a component from Add to Subtract, Refine Edges and the Refine Edge Brush are only there, and so are Rename, Duplicate and Save as Mask Preset for a mask. Nothing inverts a whole mask.
- **Seeing what a mask covers takes selecting it.** Nothing previews a mask on hover, the list has no thumbnails, and a mask's pin sits at its centre, not where it edits.
- **Messages are easy to miss.** Progress, a download's question, errors and the drawing hint share one status line under the list.

Four bugs found on the way are fixed (UX-17, e441000): People parts and Landscape classes that need SAM 3 now ask before downloading it, a 17th mask says why it isn't made, the People tile offers parts as the menu does, and Save as Mask Preset… asks for a name.

## How it was done

Redlamp: from the panel's code (`MaskingPanel.swift`, its AppKit host `MaskingPanelView.swift`, and `EditorModel`'s masking) at 046ff35, on 7 October 2026. Lightroom Classic: from Adobe's published help for its 2024 and 2025 releases, not from using it, so its column is unverified. Lightroom Mobile, which the owner can use, is still to be tried on the same tasks; where it differs from Classic, this note will say so. Photoshop, Capture One and Luminar Neo appear where they do something neither of the two does, also from published material and unverified.

## The panel today

From the top:

- **A header** with Show Overlay (`O`) and the overlay's mode, colour and opacity. Pins (`H`) are shown on the photo, one at each mask's centre.
- **With no masks,** a grid of tiles, one per kind; People and Landscape open menus of parts and classes.
- **With masks,** the list, newest first: each row has its first component's icon, its name (dimmed when hidden) and an eye button to hide it. A click selects, a double-click renames, a drag reorders, and the context menu holds Rename…, Duplicate, Duplicate and Invert, Reset Adjustments, Save as Mask Preset… and Delete. Under the list, a bar with Create New Mask (every kind, People's parts, Landscape's classes, and Existing Mask), Mask Presets, and a menu with Update AI Masks, Update AI Masks on N Photos and Delete All Masks; then a status line.
- **The selected mask:** its components, each with its operation's icon, its kind and number ("Face Skin 2"), Invert and Delete, plus Paint into this brush or Sample again for brushes and ranges. Changing the operation, Refine Edges and the Refine Edge Brush are in the component's context menu. Then the Add, Subtract and Intersect menus; the selected component's own settings (a radial gradient's Feather, the brush and Auto Mask, a range's samples, an AI mask's Feather and Edge); then the mask's Amount, Detail, local adjustments, Color swatch, Curves and Point Color.

## The tasks

| # | Task | Redlamp | Lightroom Classic (from Adobe's help) | Where Redlamp is harder |
| --- | --- | --- | --- | --- |
| 1 | Darken a sky without a halo | Sky tile, then Exposure. Process 14 keeps the twigs and the skyline free of a halo | Create New Mask ▸ Sky, then Exposure | Same steps; Redlamp applies the edit at the edge better (MSK-27) |
| 2 | Brighten the face of one person out of three | People ▸ Face Skin makes Face Skin 1 to 3 in one mask; select each to see whom it covers, delete the other two, then Exposure | People shows each person found; pick one, tick Face Skin, Create Mask, then Exposure | No choice of person; finding whom each component covers is trial and error |
| 3 | Take a person out of a sky mask | Select the Sky mask, Subtract ▸ People ▸ Entire Person | Subtract ▸ People, pick the person, Subtract | Subtracting takes out everyone at once; one person of several needs a brush |
| 4 | Fix a missed strand | Right-click the AI component ▸ Refine Edge Brush, paint over the strand | Add ▸ Brush with Auto Mask, paint; no tool for hair | Redlamp has the better tool, but only in a context menu |
| 5 | Find which mask changed an area | Turn on the pins (`H`) and select masks one by one with the overlay on | Hover each mask in the panel to see its overlay; pins | No preview on hover; a pin sits at the mask's centre, which may be far from the area |
| 6 | Change a component from Add to Subtract | Right-click it ▸ Set to Subtract; its icon only shows the operation | Not described in Adobe's help: delete and add again | Hidden, though Redlamp can do it |
| 7 | Invert a mask | Duplicate and Invert, then delete the original; inverting each component inverts only the components | Invert checkbox on the mask | No Invert for the whole mask |
| 8 | Make a mask from an existing one | Create New Mask ▸ Existing Mask ▸ the mask (a component that follows it), or Duplicate | Duplicate | Redlamp does more; Existing Mask is only in the bar's menu |
| 9 | Apply a mask preset to a set of photos | Save as Mask Preset… (context menu); apply it on one photo, Copy Settings, select the others, Paste: their AI masks are made again for each | A preset with masks (or an adaptive preset) applied to every selected photo | Applying it to several photos at once isn't offered |
| 10 | Hide every mask but one | Click the eye on each of the others | Each mask's eye; a switch for all masks | One click per mask; no way to show one alone |
| 11 | Brush with Auto Mask | Create New Mask ▸ Brush, turn on Auto Mask in the brush's settings, paint | Brush, Auto Mask checkbox (`A`) | No key for Auto Mask |
| 12 | Undo a wrong click | ⌘Z: every mask change is a named step ("Subtract People", "Hide Sky") | ⌘Z, the History panel | Same |
| 13 | A mask for each person | People ▸ Entire Person gives one mask with a component each; Duplicate it and delete components to split it | Tick Create separate masks | Not offered |
| 14 | Water and vegetation in a landscape | Landscape ▸ Water, then Add ▸ Landscape ▸ Vegetation | Landscape lists the regions found; tick both, as one mask or separate ones | No list of what was found; one class at a time |

Landscape needs SAM 3, an evaluation model in Redlamp (its licence isn't cleared for everyone).

## Other editors (from published material, unverified)

- **Photoshop's Select and Mask** has the Refine Edge Brush and Refine Hair (task 4), and views that show what a selection covers: overlay, on black, on white, black and white, and onion skin (task 5). Redlamp's overlay has similar modes.
- **Capture One** keeps each mask on a layer with its own adjustments, an opacity and a checkbox that turns it off (task 10), and shows a layer's mask with one key.
- **Luminar Neo's** AI masking lists only the kinds of region it found in the photo (people, sky, water, vegetation, architecture and others) as buttons to combine (task 14).

## Findings, ranked

1. **A People picker** (tasks 2, 3 and 13): after People, a thumbnail of each person found, with checkboxes for the parts and a Separate masks option; the same picker when subtracting or intersecting People. The engine has to report who it found before it makes the masks.
2. **One picker to start any mask** (tasks 3, 8, 11 and 14): the same Create New Mask choices at the top of the panel whether or not there are masks, and behind Add, Subtract and Intersect, laid out as the tiles are now, rather than a menu.
3. **Actions on screen** (tasks 4, 6 and 7): a menu button on each mask and each component; the operation's icon as a menu; Refine Edges and the Refine Edge Brush as buttons beside an AI component's Feather and Edge; and Invert for the whole mask, beside its Amount.
4. **Seeing what a mask covers** (task 5): its overlay while the pointer is over its row or a component, a small thumbnail of its coverage in the list, and pins where each mask covers most.
5. **One mask alone** (task 10): Option-click an eye to show only that mask, and again to show them all.
6. **Presets on several photos** (task 9): a mask preset applied to every selected photo, its AI masks made for each.
7. **A Landscape picker** (task 14): the regions found, with their share of the photo, as one mask or separate ones. For evaluation models only, while SAM 3 is.
8. **Messages in place:** a download's question by the tile that asked for it, an error by the mask it concerns, and the drawing hint at the top of the panel, naming the armed tool and how to stop.

## Limits

- Lightroom Classic's steps and the other editors' are from published material, not from using them; Lightroom Mobile's are still to come, from the owner.
- The tasks are common ones, not a study of how people mask. The owner's own tasks, where the panel confused him, should be added.
