# UX-30 and UX-41: switching Develop panels off, and choosing which show

The owner asked (10 October 2026) whether photographers should be able to turn Develop panels on and off, and whether other editors let them. That covers two features: switching a panel's settings off while keeping them, and choosing which panels the Develop column shows. This note records what other editors do, what Redlamp has, what the owner decided, and the questions each build has to answer.

## In short

- **Nearly every editor can switch a panel's settings off.** Lightroom Classic has done it with a switch on eight panel headers; since 12.3 (April 2023) it shows an eye instead, held to see the photo without the panel, and keeps the switch behind ⌥. Apple Photos has a checkmark on each adjustment, darktable an on/off button on each module.
- **Choosing which panels show is less common.** Lightroom Classic hides a panel from a panel header's right-click menu and, since 8.1 (December 2018), reorders them after a restart. darktable lets photographers build whole layouts. Apple's Photos guide describes no way to hide an adjustment.
- **Decision:** Lightroom's panel switches (UX-30) first, then choosing which panels show (UX-41), where a hidden panel that holds edits shows anyway. Reordering and saved layouts are left until people ask.

## How it was done

Sources fetched on 10 October 2026: The Lightroom Queen's release posts and tutorials for Lightroom Classic (Adobe's own help pages refuse requests from the agent sandbox), Apple's Photos User Guide, and darktable's user manual. DxO's and Capture One's sites refused the requests too; what this note says about them comes from their published material as remembered, and is marked unverified. Redlamp: from its code at 5171eebd.

## What other editors do

### Switching a panel's settings off

- **Lightroom Classic.** Each panel but Basic had a switch at the left of its header; Lightroom Queen suggests it for speed too, turning Detail or Lens Corrections off while editing and back on when done ([performance tweaks](https://www.lightroomqueen.com/lightroom-performance-workflow-tweaks/)). Since 12.3 each panel header shows an eye, lit when the panel has settings that differ from the defaults; holding it disables the panel's adjustments for as long as it's held. The switches are still there, shown while ⌥ (Alt) is held, "as the new eyeball icons are better for temporary previews" ([12.3 notes](https://www.lightroomqueen.com/whats-new-in-lightroom-classic-12-3/)). Mask slider groups got the same held eye in 12.1 ([12.1 notes](https://www.lightroomqueen.com/whats-new-in-lightroom-classic-12-1/)).
- **Apple Photos.** A blue checkmark appears beside an adjustment once it's changed; deselecting it turns the adjustment off "temporarily and see how it affects the photo" ([Photos User Guide](https://support.apple.com/guide/photos/adjust-light-exposure-and-color-pht806aea6a6/mac)).
- **darktable.** Every module header has an on/off button; modules essential to processing can't be turned off ([module header](https://docs.darktable.org/usermanual/development/en/darkroom/processing-modules/module-header/)).
- **DxO PhotoLab** (unverified): an on/off control on each correction.
- **Capture One** (unverified): no switch on its tools; its layers turn on and off.

### Choosing which panels show

- **Lightroom Classic.** Right-clicking a panel header lists the panels with checkmarks; a panel unticked there disappears, and Lightroom Queen keeps a tutorial, "Where have my panels gone?", for photographers who did it by accident ([tutorial](https://www.lightroomqueen.com/panels-gone/)). Customize Develop Panel, from the same menu, arrived in 8.1: drag the panels into an order, then restart Lightroom to apply it ([8.1 notes](https://www.lightroomqueen.com/whats-new-in-lightroom-classic-81/)).
- **darktable.** Module groups are presets the photographer can duplicate and edit: groups of modules with their own icons and order, a quick access panel of chosen controls from many modules, a search line, and presets applied automatically by the type of photo. An option shows every module in the photo's history within the active group, whether it's on or not ([manage module layouts](https://docs.darktable.org/usermanual/development/en/darkroom/organization/manage-module-layouts/)).
- **Capture One** (unverified): tools added to and removed from tool tabs, tabs of the photographer's own, and saved workspaces.
- **DxO PhotoLab** (unverified): saved workspaces.
- **Apple Photos.** The guide describes no way to hide an adjustment.

## What Redlamp has

- Nine Develop panels in a fixed list: `InspectorPanelsView.content(for:model:)` in AppKit, and its SwiftUI reference, `InspectorView`, which the AppKit column is checked against.
- A panel header expands the panel on a click, gives Solo Mode on ⌥-click and resets the panel on a double-click; a dot shows the panel has edits (`EditorModel.isEdited`). Its right-click menu holds Reset, Solo Mode, Expand All Panels and Collapse All Panels.
- A shortcut for each panel (`panelBasic` to `panelCalibration`, through `revealPanel`), and `,` and `.`, which step through Basic's sliders and open Basic.
- ⌘K reaches every slider.
- Masks save an `isVisible` with each mask in the sidecar, the pattern a panel switch can follow.
- No panel switch, and nothing hides a panel.

## Assessment

- **Panel switches are worth building.** They answer a question photographers ask of every panel (what is this adding?), every editor above that was checked has a form of them, and Lightroom users will look for them. Lightroom Classic's move to a held eye in 12.3 suggests the common use is a quick look rather than leaving a panel off; UX-30 as written is the lasting switch, so its build should settle which Redlamp shows first.
- **Hiding panels pays off less.** Redlamp has nine panels, not darktable's dozens of modules, and Solo Mode, Collapse All Panels and ⌘K already shorten the column. The cost is small, but a hidden panel can hold edits from a preset, a recipe card or pasted settings, and then the photo changes with nothing on screen to explain it; Lightroom's tutorial and darktable's option exist for that reason.
- **Reordering costs more than hiding:** a sheet to arrange the panels, and both columns and the shortcuts following the order.

## Decision (the owner, 10 October 2026)

1. Build Lightroom's panel switches (UX-30) first.
2. Then let photographers choose which Develop panels show (UX-41), where a hidden panel that holds edits shows anyway.
3. Leave reordering panels and saved layouts until people ask for them.

## Questions for the builds

UX-30, panel switches:

- A lasting switch, a held preview, or both, and which the header shows; Lightroom Classic now shows the held eye and keeps the switch behind ⌥.
- Which panels: Lightroom's eight, without Basic, as the row says.
- What Copy and Paste, Sync, presets, recipes and the MCP server do with a panel that's off: whether its settings carry over, and whether its being off does.
- How a panel that's off looks, and what its edited dot says.
- Whether Lightroom presets and sidecars carry a panel switched off, for the preset import (EDT-11) and sidecar import (EDT-12) to honour. Today the import reports any setting it doesn't read as ignored, and none of the preset test files carries one.
- The new sidecar field defaults to on, so existing edits render as before (`ProcessStabilityTests`), with the sidecar schema and its document updated.

UX-41, choosing which panels show:

- Whether Basic can be hidden, since `,` and `.` open it.
- How a hidden panel that holds edits is marked, and whether it hides again once reset.
- Whether a panel's shortcut shows a hidden panel for the moment or unhides it, and what ⌘K does with a hidden panel's sliders.
- Whether Report a Bug's diagnostics list the hidden panels, so a report about a missing panel can be answered.
- A panel that's hidden and switched off (UX-30) still holds settings, so it shows.
- Both columns, `InspectorPanelsView` and `InspectorView`, follow the same rule, with a regression scenario through the header's menu.
