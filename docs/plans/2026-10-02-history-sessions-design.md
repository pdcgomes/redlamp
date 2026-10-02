# History panel and sessions: design

The owner's requests (2 October 2026):

1. Choosing a history step mustn't scroll the left panel back to the top.
2. History should survive leaving a photo. Each time a photo is opened, a new session starts, and earlier sessions stay available to go back to.
3. Each step shows an icon for the kind of operation, keeps its name apart from the value it changed, and shows the value before and after.

Until now history lived only in memory, and it was lost on quitting and every time you went to another photo and back.

## Steps

A step records what was done and the edit it left:

- an **action**, the kind of operation, which picks the icon;
- a **title**: "Exposure", "Brush Stroke", "Treatment";
- the value **before** and **after**, when the step changed one value: "+0.50 → +1.00", "Color → B&W". Steps that change many values at once (Auto Settings, Paste Settings, a snapshot) have neither, and a few show only the new value ("Recipe  Teal Cinema 2");
- the **edit** itself, which choosing the step goes back to.

| Action | Icon | Steps |
| --- | --- | --- |
| A slider | Its panel's glyph (Basic's sun, Detail's magnifier…) | Every Develop slider, typed values, ⌘-scroll, the palette's slider bar, the Color Grading wheels |
| Reset | `arrow.counterclockwise` | Reset Exposure, Reset (all), Reset Point Curve, Reset Crop |
| Auto | `wand.and.rays` | Auto Settings |
| Treatment | `circle.lefthalf.filled` | Color or B&W |
| Base Look | `camera.filters` | Base Look, Base Look Amount |
| White balance | `thermometer.medium` | Presets, Auto, the selector |
| Point curve | Tone Curve's glyph | Point Curve |
| Recipe | `wand.and.stars` | Recipe, Recipe Amount |
| Snapshot | `camera.viewfinder` | Applying a snapshot |
| Paste | `doc.on.clipboard` | Paste Settings, Paste from Previous |
| Crop, rotate, flip, straighten, Upright | `crop`, `rotate.right`, flip arrows, `level`, `perspective` | The Crop & Straighten tool |
| Mask | The mask type's glyph, or Masking's | New and added components, strokes, samples, mask sliders, renaming, deleting |
| Opened | `photo` | The photo as it was opened (the first step of a session) |
| Restored | `clock.arrow.circlepath` | A step brought back from an earlier session |

The command palette's History page and its event log use the step's plain-text form: "Exposure: 0.00 → +0.50".

## Sessions

- **Opening a photo starts a session.** Its first step is "Opened", or "Import" when the photo has no sidecar yet.
- **Inside a session nothing changes.** Choosing a step goes back to it, an edit made from an earlier step discards the later ones, and ⌘Z and ⇧⌘Z move through it. Undo stops at the session's first step.
- **Earlier sessions** are listed under the current session's steps, newest first and collapsed. Each is titled by when it started ("Yesterday at 18:40") and shows its number of steps. Choosing one of their steps applies its edit as a new step of the current session, "Restored", so earlier sessions never change: that also lets sessions made on two Macs merge without conflicts.
- **A session is kept only if it has edits.** Its saved steps end at the step that was current when it was saved, so undone steps aren't kept.
- **Clear History** removes every session, the current one included, and leaves a single "History Cleared" step.

## Storage

- Each session is a file in the sidecar package, beside the edit: `IMG_1234.CR3.redlamp/history/<session id>.json`.
- The first step holds the whole edit. Each later step holds a [JSON Patch](https://www.rfc-editor.org/rfc/rfc6902) (`add`, `remove` and `replace`) from the step before it, so a slider step stores one value and a brush stroke stores one stroke, however long the session.
- The open session's file is written with the edit, in the same coordinated write, and skipped when unchanged. Earlier sessions' files are never rewritten.
- The 20 most recent sessions are kept; older files are removed when a new session is first written. A session keeps up to 500 steps, as before.
- A session lists the mask bitmaps its steps use, and `masks/` keeps them, so an AI mask in an old step can still be restored.
- A sidecar whose edit is back to defaults is kept while it holds history. The filmstrip's "edited" badge still reads only the edit.
- iCloud Drive conflicts keep the sessions of every copy, with the bitmaps they use. Sessions have their own files and ids, so they never collide.
- Earlier sessions load off the main thread after the photo opens, so going to another photo stays as fast as before.
- Older Redlamp builds ignore `history/`. They can remove bitmaps that only history uses, which leaves those AI masks empty if an old step is restored.

## The panel

- **Rows:** the action's icon, the title, then `before → after` right-aligned in the value font, dimmer than the title. The current step is highlighted instead of carrying a checkmark, so the values have room; undone steps are dimmed.
- **Narrow panel:** the title comes first. The value before is dropped first; if the value after still doesn't fit, the title keeps 60% of the row and both truncate. The tooltip always has the whole step.
- **Scroll position:** the list keeps its place when it reloads (stepping through history, finishing an edit, applying a recipe or making a snapshot). Typing a recipe search still goes back to the top, where the results are.

## Built in the harness

The **History** scene (`--scene history`) drives the harness's real editor through a scripted set of steps covering every action, then opens the photo again so an earlier session appears, and shows the AppKit sidebar list at the sidebar's normal (250 pt) and narrowest (220 pt) widths, scrolled to History with the earlier session expanded. `--history-height` sets the lists' height for taller captures.

## Later

Previewing a step on hover (the inventory's History panel), deleting one session, showing which Mac made a session, and earlier sessions in the command palette.
