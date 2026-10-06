# UX-17: the Masks panel, task by task

The owner finds the Masks panel confusing at times (6 October 2026). This note walks twelve common masking tasks through Redlamp's panel, step by step, and through Lightroom Classic's, and says where Redlamp's way is longer, hidden or unclear. It is the input to the panel's redesign, which comes back to the owner for approval before anything is built.

## In short

- **Making a mask starts in three places that look different:** the tile grid when the photo has no masks, the Create New Mask menu under the list once it has some, and the Add, Subtract and Intersect menus under the selected mask's components. Lightroom Classic starts every mask from one Create New Mask picker, and its Add and Subtract buttons open the same picker.
- **People and Landscape give no choice of who or what.** A People part applies to every person found, as one component each, and a Landscape class is picked blind from a menu. Lightroom Classic shows a thumbnail of each person found, with checkboxes for their parts and an option to make a separate mask for each, and lists the Landscape regions it found.
- **The tools that matter most for an AI mask are hidden.** Refine Edges and the Refine Edge Brush are only in a component's context menu; Feather and Edge appear only when the component is selected.
- **The list says little about each mask:** an icon for its first component's kind and its name, with Rename, Duplicate, Duplicate and Invert, Reset Adjustments, Save as Mask Preset and Delete in a context menu. Lightroom Classic shows a thumbnail of each mask and a menu button beside it, and previews a mask's overlay when the pointer is over it.
- **Messages are easy to miss.** Progress, a download's question and errors appear in one status line under the list.

Four bugs found on the way are fixed (UX-17, e441000): People parts and Landscape classes that need SAM 3 now ask before downloading it, a 17th mask says why it isn't made, the People tile offers parts as the menu does, and Save as Mask Preset… asks for a name.

## How it was done

Redlamp: from the panel's code (`MaskingPanel.swift` and its AppKit host, `MaskingPanelView.swift`) and the app, on 6 October 2026, at e441000. Lightroom Classic: from Adobe's published help on masking for its 2024 and 2025 releases, not from using it. Lightroom Mobile, which the owner can use, is still to be tried on the same tasks; where it differs from Classic, this note will say so.

## The panel today

From the top: a header with Show Overlay (`O`) and the overlay's mode, colour and opacity. Then, with no masks, a grid of tiles, one per kind; with masks, the list (newest first), a bar with Create New Mask, Mask Presets and a menu (Update AI Masks, Delete All Masks), and a status line. Under the list, the selected mask's editor: its components, each with its operation, kind, Invert and Delete, then Add, Subtract and Intersect menus; the selected component's own settings (a radial gradient's Feather, the brush, a range's samples, an AI mask's Feather and Edge); then the mask's Amount, Detail, local adjustments, Color swatch, Curves and Point Color.

## The tasks

| # | Task | Redlamp | Lightroom Classic | Where Redlamp is harder |
| --- | --- | --- | --- | --- |
| 1 | Darken the sky | Sky tile (or Create New Mask ▸ Sky), then Exposure | Create New Mask ▸ Sky, then Exposure | Same steps |
| 2 | Brighten one person's face in a group | Create New Mask ▸ People ▸ Face Skin makes a component for every person; delete the others' components one by one | People shows each person found; pick one, tick Face Skin, Create Mask | No choice of person; the other people's components have to be found and deleted |
| 3 | A mask per person | People ▸ Entire Person gives one mask with a component each; Duplicate it and delete components to split | Tick Create separate masks | Not offered |
| 4 | Water and vegetation in a landscape | Create New Mask ▸ Landscape ▸ Water, then again for Vegetation | Landscape lists the regions found; tick both, separate masks or one | No list of what was found; one class at a time |
| 5 | Brighten the subject, keep the background | Subject tile, then the sliders | Same | Same steps |
| 6 | Take a brushed area out of a Subject mask | Subtract ▸ Brush under the components, then paint | Subtract ▸ Brush | Same steps; the Subtract menu sits under the component list, below the fold on small screens |
| 7 | Darken only the top of the sky | Sky, then Intersect ▸ Linear Gradient | Sky, then Subtract with Option ▸ Linear Gradient (Intersect) | Easier in Redlamp: Intersect is a menu of its own |
| 8 | Fix a hair edge | Right-click the Subject component ▸ Refine Edge Brush, then paint | Not offered in Classic (Photoshop's Refine Hair) | Redlamp leads, but the tool is in a context menu only |
| 9 | Soften an AI mask's edge | Select the component, then Feather and Edge | Not described in Adobe's help for Classic | The sliders appear only when the component is selected |
| 10 | See what a mask covers | Select it; the overlay shows with Show Overlay on | Hover a mask or component; the overlay shows | No preview on hover; one global toggle |
| 11 | Reuse a mask on other photos | Save as Mask Preset… (the list's context menu), then Mask Presets ▸ the preset on each photo; or Sync, then Update AI Masks | Adaptive presets in the Presets panel; or Sync, then Update | Saving is in a context menu; presets sit in the actions bar, not with the other presets |
| 12 | Invert a mask | Duplicate and Invert (context menu), or Invert on each component | Invert checkbox on the mask | No Invert for the whole mask on screen |

## Findings, ranked

1. **One way to start a mask.** The same Create New Mask picker at the top of the panel whether or not there are masks, and the same picker behind Add, Subtract and Intersect. It shows every kind with its icon, as the tile grid does now, rather than a menu.
2. **People and Landscape pickers.** After People: a thumbnail of each person found, with checkboxes for the parts and a Separate masks option. After Landscape: the regions found, with their share of the photo. Both need the engine to report what it found before the masks are made (`computeMasks` returns them, so only the order changes).
3. **Actions on screen.** A menu button on each mask row (Rename, Duplicate, Duplicate and Invert, Save as Mask Preset…, Delete), an Invert toggle on the mask, and Refine Edges and the Refine Edge Brush as buttons under an AI component, beside Feather and Edge.
4. **Thumbnails and hover.** A small thumbnail of each mask's coverage in the list, and its overlay while the pointer is over its row or a component, as Lightroom does; Show Overlay stays for keeping it on.
5. **Messages in place.** A download's question, progress and errors next to what caused them (the mask or the tile), not only in the status line.
6. **One order.** The list newest first, as now, and components in the order they apply, which they are; say so in the components' header.

## Limits

- Lightroom Classic's steps are from Adobe's help, not from using it; Lightroom Mobile's are still to come, from the owner.
- The tasks are common ones, not a study of how people mask: the owner's own tasks, where the panel confused him, should be added.
