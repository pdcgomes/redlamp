---
name: screen-wireframes
description: Draws a complex screen or feature's UI as an annotated wireframe canvas, with tabs for an overview of the user's flow, one per area of the screen, and the questions left for the owner. Every region is numbered and marked built, being built, planned or later, with notes keyed to the numbers and each question giving what's there now, the options and a lean. Use when designing a screen, a window or a set of panels before building them, when asked for wireframes or mockups, when showing what's built and what's planned in a UI, or when collecting the owner's decisions on a UI.
---

# Screen wireframes

A wireframes canvas shows how a complex screen looks and works before all of it exists: each region drawn where it sits, marked with where it stands, explained in a note, and the choices only the owner can make set out as questions. It is the design's picture, kept true to the code as the work lands. The library's (`library-ui-wireframes.canvas.tsx` in this project's canvases) is the example to follow.

## Where

- `~/.cursor/projects/<workspace>/canvases/<feature>-wireframes.canvas.tsx`: `<workspace>` is the Cursor project folder for this repository (list `~/.cursor/projects/` if it isn't in the environment), `<feature>` a short kebab-case name (`library-ui-wireframes`, `import-wireframes`).
- One canvas per feature or screen family. A workstream's board links to it, and its open questions also go on the board's Needs you (`.cursor/skills/workstream-canvas/SKILL.md`).
- Read `~/.cursor/skills-cursor/canvas/SKILL.md` once per session before the first write: its rules apply (theme tokens only, no empty states, no gradients, emojis or shadows).

## Start

1. Gather what it's drawn from: the design document, the tracker rows, the code as merged (`git log`), and the app it follows, if any (Lightroom Classic for the library). Note what each region's status rests on.
2. Copy [template.tsx](template.tsx) to the path above.
3. Replace the data at its top: `WIREFRAMES` (title, a line saying what it's drawn from and the date, the reading note), the meanings in `STATUS`, `FLOW`, `PRINCIPLES` and `QUESTIONS`. Keep the building blocks and the Overview and Questions tabs as they are.
4. Replace the example tab with one tab per area of the screen, listed in `TABS` between Overview and Questions.
5. Link the canvas in your reply: `[Feature wireframes](/absolute/path/<feature>-wireframes.canvas.tsx)`.

## The tabs

- **Overview:** the user's path through the screen as three to six numbered steps, each with its status; what makes the design work, three to six points with a title and a sentence; how to read the wireframes, the statuses and what each means; and a callout to the questions while any are open.
- **One tab per area:** a window, a panel set, a sheet, a flow (the library's are The window, Finding photos, Culling, Keywords and metadata, and Import, files and health). Each opens with a heading and a sentence, then the wireframe, then its notes, then what doesn't draw well: a table of keys, the tokens a field takes, the states a control goes through.
- **Questions:** each choice the wireframes leave open, and below them the ones answered.

## Drawing a wireframe

- **The real layout, in proportion.** A `Window` with its toolbar, regions laid out on a CSS grid with the screen's real columns and widths (`"170px minmax(0, 1fr) 230px"`). Draw what the user sees, not the code's structure.
- **Every region a `Box`:** a number (`n`), a short label and a status. The notes under the wireframe use the same numbers: what the region does and why, the tracker ID or decision it comes from (LIB-27, DEC-48), and its status. A wireframe with more than about ten regions splits into two.
- **Real content.** Real labels, menu names, keys (`Kbd`), templates and values, and plausible counts, saying once in the reading note that counts are made up. No placeholder text, no "TBD" box: a region not yet designed isn't drawn, it's a question.
- **Dashed boxes** for what shows on demand: a sheet, a popover, a panel opened from a menu.
- **The building blocks:** `Box`, `Window`, `ListSection` (a sidebar's rows with counts), `Tile` (a cell of content), `Field` (a labelled value), `Segmented`, `Chip`, `Kbd`, `Slider`, `Mini`, `Caption`, `Notes`, `StatusTag`. Add a block the screen needs (a domain's cell, such as the library's photo with stars and flags) beside them, in the same style.
- **A playground** where a behaviour is easier to feel than to read: the library's query bar narrows a made-up million photos as terms are clicked. Keep it self-contained (`useState`, data inline) and say it's illustrative.

## Statuses

Each region, step and note carries one of four, and each must be true when written:

- **Built:** merged where it ships and tested; checked in `git log` and the tracker.
- **Being built:** an agent is building it now.
- **Planned:** in the tracker for this release; its engine may exist without its panel, and the note says so.
- **Later:** after the release, or waiting on a measurement or the owner, the note saying which.

Never mark built what isn't merged, and say plainly what hasn't been tried in the app.

## Questions

- **Only choices whose answer changes what's built next:** a layout, a default, what a key does. Not taste, and not what the design already settles.
- **Each one:** the question as the title; `now`, what's built or designed today; two or three `options`, shown as A, B and C; and `lean`, your recommendation and why, in a sentence.
- **When the owner answers:** set the question's `answer` to what they chose, in a sentence, so it moves under Answered. Record the decision where it belongs (the design document, the tracker row's text, a `DEC-` row when it's a product decision, the board's decisions) and brief the agents building those parts. Redraw the regions it changes.

## Keep it current

- When work lands, in the same turn as the merge: the regions' and notes' statuses, any region that came out differently from its drawing, and the date in the intro.
- A region added to the design gets its box and note; one dropped is taken out, its note saying where it went if it moved.
- After each edit the tool result shows a `Canvas TypeScript check` line: fix errors until it reports none.

## Style

Plain, complete sentences in the project's voice, calm and precise, with no superlatives. Status colours come from `theme.category`, and the accent goes on the region markers only. Neutral boxes, structural borders, the canvas skill's rules throughout.
