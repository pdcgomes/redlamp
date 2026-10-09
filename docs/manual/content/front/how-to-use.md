+++
deck = "A map of one app at one commit. Every label, range, default and shortcut in it was read from Redlamp's own code, and every screenshot was captured from the app."
sources = [
  "`README.md`: Goals; Where we are; Using Redlamp",
  "`docs/lightroom-comparison.md`",
  "`scripts/manual/` (how this manual is built, and the tables it generates)",
]
+++

This manual explains how to develop raw photos with Redlamp: what each panel and tool is for, how to use it, and every control it has, with its range, its default and its shortcut. It describes Redlamp at commit `{{commit}}` ({{date}}), after the 0.2.4 pre-alpha release, on an Apple silicon Mac running macOS 26 or later.

::: caution Pre-alpha
Redlamp is pre-alpha: features are added and changed between releases. Everything here is true of the commit above. Where a later Redlamp differs, the app is right and this manual is out of date.
:::

## Who it's for

Photographers who want to know Redlamp well. You don't need to know how raw processing works. If you've used Lightroom Classic, most of what you read will be familiar: Redlamp keeps Lightroom's panel layout, slider names and ranges, and its keyboard shortcuts, and this manual says where the two differ.

Redlamp is an editor, not a catalogue. It works on folders of photos, as Lightroom Classic's Folders panel does, and keeps each photo's edit in a small file beside it. Nothing you do in Redlamp changes the original photo.

## How it was made

Nothing here was written from memory. Each section ends with a **Sources** line naming the files it was written from, which rank in this order:

| Source | Where | Used for |
| --- | --- | --- |
| Redlamp's code | `packages/`, `apps/` | every label, range, default, shortcut and message the app shows |
| The README | `README.md` | what each feature does, as the project describes it |
| The Lightroom comparison | `docs/lightroom-comparison.md` | where Redlamp differs from Lightroom Classic, and what isn't built yet |
| Screenshots | `docs/images/` | captured from the app by `scripts/capture-hero.sh` and `scripts/capture-screenshots.sh` |

Where the README and the code disagree, this manual follows the code. The tables of sliders and shortcuts in the Reference part aren't typed at all: the build reads them from the app's own definitions, `ParameterCatalog` for sliders and `ShortcutAction` for shortcuts, and each table names the commit it was read at.

## Conventions

Keys
: Shown as keycaps: [[⌘]] Command, [[⌥]] Option, [[⇧]] Shift, [[⌫]] Delete, [[Esc]] Escape. [[⇧W]] means hold Shift and press W. Shortcuts are Lightroom Classic's wherever Lightroom has one.

Labels
: Buttons, menus, sliders and messages are named exactly as the app shows them: click New Mask, choose Duplicate and Invert.

Menus
: A path through menus is written with ›, as in Settings › Models or Mask Presets › Delete Preset.

Right-click
: Also means Control-click, or a two-finger click on a trackpad.

Cross-references
: Give the section and its page, as in [](#masking.ai). A section that isn't written yet is named by its number alone.

Values
: Written as the slider's field shows them: +0.30 for Exposure, 100 for Amount. Ranges run from the slider's left end to its right end.

Four kinds of note stand apart from the text:

::: note
Something easy to miss, such as a control that only appears in one mode.
:::

::: tip
A quicker way, or a combination of tools that works well.
:::

::: lightroom
Where Redlamp differs from Lightroom Classic, for readers who know it.
:::

::: caution
Something that can surprise you, such as a download or a limit.
:::
