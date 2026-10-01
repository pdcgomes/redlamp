# Command palette: design

The owner's goal: a Raycast-style command palette that lets you do anything from the keyboard, well beyond Lightroom's shortcuts. Commands document themselves, each shows its shortcut, and a selected command can open a page of its own, such as a keyboard slider for Exposure. Tracker row UX-07.

## What it finds

- **Every action** in the shortcut registry (`ShortcutAction`), with its keys shown as keycaps. The only exceptions are actions that make sense only as keys: Cancel, the four setting nudges, Find Adjustment and the palette itself.
- **Every live Develop slider**, by name, panel or the words people use for it (`AdjustmentSearch`'s synonyms), with its current value. Titles are unambiguous: "Orange Saturation", "Shadows Hue", "Grain Size".
- **Pickers:** White Balance, Treatment, Base Look, Recipes, Before / After, Snapshots and History. Their items can also be found from the top-level search ("portra", "daylight", "side by side"), except snapshots and history steps.
- **Typed values:** "exposure 0.7", "temp 5600k" and "contrast x+10" make a "Set Exposure to +0.70" row.

Search ranks a whole-word match above the start of a word, and that above part of one. Ties go to exact titles, then pickers, sliders, actions and choices, then catalogue order.

## Keys

The palette opens with **⌘K**. **⌘F** opens it limited to sliders (it replaces the Find Adjustment sheet), and ⌫ on the empty field removes the limit. ⌘K again, or a click outside, closes it.

In a list:

| Key | Does |
| --- | --- |
| ↑ ↓ | Move the highlight; in a picker, preview the highlighted choice on the photo |
| ↵ | Adjust a slider, run an action, open a picker, apply a choice or set a typed value |
| Esc | Back one level; at the top, close |

In the slider bar:

| Key | Does |
| --- | --- |
| ← → | Step by the slider's step (⇧ ×10, ⌥ ×0.1) |
| ↑ ↓ | The previous or next slider in the same panel |
| A number or `x+0.3`, then ↵ | Set it (the value fields' rules, UX-01) |
| ↵ with nothing typed | Done: close the palette |
| ⌘⌫ | Reset to the default |
| A letter, with nothing typed | Back to the search with that letter |
| ⌫ with nothing typed, or Esc | Back, with the previous search restored |

Key presses less than 500 ms apart make one history step, as ⌘-scroll does (UX-02). The step also ends when you leave the bar, close the palette or press ⌘Z. The slider becomes `focusedParameter`, so `,` `.` `-` `=` carry on with it after the palette closes.

## Key hints

Every state shows the keys that work in it.

- A glass capsule at the bottom right, like Raycast's action bar, lists hints as a name followed by its keys ("Adjust ↵", "Close Esc"). The first hint names what ↵ does for the highlighted row.
- A picker leads with "Preview ↑ ↓". Beside the capsule it shows where you are and what's previewing.
- The top level shows a tip beside the capsule, a different one each time the palette opens, for tricks no single row shows.
- In the slider bar, hints sit where they apply: ← and → at the ends of the track, ↑ and ↓ beside the neighbouring sliders, "type a value or a name" under the value. The capsule holds the rest (×10 ⇧, Fine ⌥, Reset ⌘⌫, Done ↵, Back Esc), and a held ⇧ or ⌥ lights up its hint.
- The ⌘/ sheet lists the palette's keys, from the same definitions.

## Look

About 620 pt wide, at the top centre, in the filmstrip's glass pane and the theme's colours. Nothing behind it is dimmed, because a dark backdrop changes how tones read. In the slider bar the palette shrinks in place to two lines, so the photo stays in view.

It follows the app's theme unless Settings ▸ Appearance ▸ Command Palette gives it one of its own, from the same families and tokens (`ThemeSettings.paletteSelection`). Its views read the override from the environment (`\.themeTokens`), so only the palette changes, and the other half of a theme (a light palette over a dark editor) sets the glass and text field's appearance too.

## Previews

The highlighted choice in a picker previews once the selection has rested for 150 ms. Esc or leaving the page reverts it; ↵ applies it. Base Looks and recipes preview through `previewRecipe`; white balance, treatment, snapshots and history through `previewingEdit`, a render-only edit beside it.

## Built in the harness first

Each milestone is built and tried in the component harness's **Command Palette** section before the next starts:

- **Live** (`--scene command-palette`): the palette over the sample photo on the real canvas, with an inspector showing its state, a log of every key and what it did, a checklist of every interaction that ticks itself as they happen, the conditions to try (photo, clipboard, Masking tool, transparency, tip), and knobs for the preview delay and history gap.
- **States** (`--scene command-palette-states`): each state as a still specimen, with a note on what would be wrong with it.

The palette goes into the editor window only once the checklist is complete. The harness opens it through the same `openCommandPalette(scope:)` the app uses, and the palette reports what it does as `PaletteEvent`s, which the log, the checklist and the tests read.

## Later

Masks (local sliders, new masks, overlay settings), going to a photo by filename, recent commands, per-row actions on ⌘↵, and Base Look and Recipe Amount in the slider bar.
