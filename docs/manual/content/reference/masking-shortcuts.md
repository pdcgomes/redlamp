+++
deck = "Every key the Masking tool answers to: the shortcuts as the app lists them under ⌘/, and the keys that work while you draw."
sources = [
  "`packages/RedlampUI/Sources/Shortcuts/ShortcutAction.swift` (the table, generated)",
  "`packages/RedlampUI/Sources/Model/EditorModel+Shortcuts.swift`, `EditorModel+BrushSize.swift`",
  "`packages/RedlampUI/Sources/Editor/MaskOverlayView.swift`",
]
+++

The table below is read from `ShortcutAction`, the list the app itself uses for its menus, its keys and the Keyboard Shortcuts sheet ([[⌘]][[/]]). The titles are the ones that sheet shows.

{{table: shortcuts maskingTool brushMask linearMask radialMask colorRangeMask luminanceRangeMask depthRangeMask @Masking}}

[[O]] and [[⇧O]] also work in the Crop tool, where [[O]] cycles the crop's overlay and [[⇧O]] turns it. [[H]] also works in the Healing tool, where it hides and shows the spots, and [[⌫]] works only with a mask, or a healing spot, selected.

## Keys while you draw

These aren't in the Keyboard Shortcuts sheet: they change what a drag or a stroke does.

| Keys | While | What they do |
| --- | --- | --- |
| <kbd>[</kbd> <kbd>]</kbd> | Brushing | Make the brush smaller or larger, by 15% a press |
| [[⇧]] <kbd>[</kbd> <kbd>]</kbd> | Brushing | Change the brush's feather by 10 |
| [[⌘]]-scroll | Brushing | Change the size by about 15% a notch; with [[⇧]], the feather by 5 |
| Hold [[⌥]] | Brushing | Erase, with whichever brush is chosen |
| Hold [[Space]] and drag | Any tool that draws | Move the photo; a press without a drag toggles the zoom |
| Hold [[⇧]] while dragging | Radial Gradient | Keep it a circle |
| [[⇧]]-click | Color Range | Add a colour sample, up to five |
| [[⌥]]-click, [[⌥]]-drag | Objects | Take away from the selection |
| [[,]] [[.]] | Masking tool | Select the previous or next of the mask's sliders |
| [[-]] [[=]] | Masking tool | Move the selected slider; with [[⇧]], in larger steps |
| [[Esc]] | Drawing | Finish drawing; pressed again, leave the tool |
