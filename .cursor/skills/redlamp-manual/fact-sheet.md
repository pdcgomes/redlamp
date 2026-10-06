# Gathering a part's facts

Each part is written from a fact sheet in `docs/manual/facts/<part>.md`: every label, range, default, shortcut and message the part will mention, each with the file and line it was read from. `docs/manual/facts/masking.md` is the model. It has eleven sections, a source for every fact, its inferences marked, and the README's disagreements with the code in a table.

Ask an `explore` subagent for the sheet with this prompt, filling in what's in angle brackets. Run it in the background while you work on the part's outline and figures, and check anything surprising in its sheet against the code yourself.

```text
Thoroughness: very thorough.

You are gathering facts for the part of Redlamp's user manual about <the topic>. Redlamp is a raw
photo editor for the Mac, written in Swift; the repository is at <the checkout's absolute path>.
Don't edit, build, test or commit anything: the only file you write is the fact sheet. The manual is
for photographers and task-focused. It explains how to use each tool, with the exact labels the app
shows, its shortcuts, ranges and defaults, and leaves out the engine's internals, so don't research
those.

Every fact must be traceable: give the repository-relative path and line numbers for each one.
Mark anything you inferred rather than read as "inferred". Where the README and the code disagree,
report both and say which one the code supports.

Write the sheet as Markdown to <the checkout>/docs/manual/facts/<part>.md. Begin it with the commit
you read (`git rev-parse --short HEAD`) and its date. Then return a short summary: what you covered,
the gaps you couldn't fill, and any contradictions.

Starting points:
- README.md: <the lines about the topic>
- packages/RedlampEngineAPI/Sources/ParameterSpec.swift and ParameterID.swift: ParameterCatalog,
  the labels, ranges, defaults and steps of the sliders
- packages/RedlampUI/Sources/Shortcuts/ShortcutAction.swift: the shortcuts
- <the panels, views and models for the topic>
- docs/lightroom-comparison.md: <its rows for the topic>
- docs/feedback/areas.json: the area's features, a ready outline
- packages/RedlampAutomation/Sources/Scenarios/: which scenario exercises which feature
- docs/images: screenshots, with their sizes (`sips -g pixelWidth -g pixelHeight <file>`)

Cover, in this order:
<numbered topics, for example:
1. What the tool is for, and how to get to it (tool strip, shortcut, menus).
2. The panel, top to bottom: every control's label, range, default and step.
3. Each task step by step: clicks, drags, handles and modifier keys, with the hints the app shows.
4. Anything downloaded: its name, size and licence as Settings › Models shows them.
5. Every shortcut, with its keys and the title the app shows.
6. Differences from Lightroom Classic, and anything listed as not built yet.
7. Screenshots usable as figures: file, size, and what's visible in each.>

Read the UI code for the exact strings the app displays, not paraphrases.
```
