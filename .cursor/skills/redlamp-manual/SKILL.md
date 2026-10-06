---
name: redlamp-manual
description: The Redlamp User Manual (docs/manual), a dense, book-style PDF for photographers, typeset from Markdown and a print style sheet by Chrome, with its ranges, defaults and shortcuts generated from the app's code. Knows the manual's sources, its Markdown additions, figures and generated tables, the build and its checks, its page design, and how a part is researched and written. Use when writing, editing, building or reviewing the user manual, adding a part, section, figure or table to it, changing its look, or bringing it up to date with the app.
---

# The Redlamp User Manual

The manual explains Redlamp to photographers, task by task: what each panel and tool is for, how to use it, and every control with its range, default and shortcut. It leaves out the engine's internals; that was the owner's choice. Its look and density follow a technical manual the owner liked, the *Pi Durable Technical Manual*, adapted to Redlamp's brand ([design.md](design.md)). Its rule is that manual's too: nothing is written from memory. Every label, range, default, shortcut and message comes from the code, each section ends with the files it was written from, and the slider and shortcut tables are generated when the manual is built.

## Where

| Path | What |
| --- | --- |
| `docs/manual/book.toml` | Every part and section, written or not. A section with a `file` is written; the rest show in the contents as the plan. Front matter is under `[[front]]` |
| `docs/manual/content/<part>/<section>.md` | A section: TOML front matter between `+++` lines (`deck`, `sources`), then Markdown |
| `docs/manual/facts/<part>.md` | The fact sheet a part was written from, a source for every fact |
| `docs/manual/figures/<name>.html` | A figure: `title:`, `tag:` and `caption:` lines, `---`, then its HTML or SVG |
| `docs/manual/cover.html` | The cover; `{{repo}}`, `{{parts}}`, `{{commit}}` and the like are filled in |
| `docs/manual/style/manual.css` | The print style sheet: pages, type, figures and the cover |
| `scripts/manual/` | The build: `build.py` (prints and pages), `layout.py` (the HTML), `markup.py` (the Markdown), `tables.py` and `catalog.py` (generated tables), `fonts.py`, and `grid.py` (screenshot coordinates) |
| `build/manual/` | Output, gitignored: `redlamp-manual.pdf`, its HTML, `pages/` previews, the fonts and the virtualenv |

The workstream canvas is `~/.cursor/projects/Users-pedrogomes-src-darkroom/canvases/ws-user-manual.canvas.tsx`. Read the owner's marks on its Needs you first, since the open design decisions are there, and keep it current as `.cursor/skills/workstream-canvas/SKILL.md` says.

## Build

The first time, from the checkout's root:

```bash
python3 -m venv build/manual/venv
build/manual/venv/bin/pip install markdown-it-py mdit-py-plugins playwright pymupdf
```

Then, with PNGs of the pages you're working on and contact sheets of the whole book:

```bash
build/manual/venv/bin/python scripts/manual/build.py --pages 7-10 --sheets
```

- A build takes about ten seconds. It downloads the fonts once and checks their hashes, then prints with the installed Chrome through Playwright, which downloads no browser. Chrome can't number pages in the contents or in cross-references, so the build prints again until no page moves: each measuring print ends with a page of links to every id, and the PDF's link targets give each one's page. The last print, without that page and with bookmarks, is `build/manual/redlamp-manual.pdf`.
- `--pages` writes PNGs at 110 dpi and `--sheets` contact sheets of 15 pages each, to `build/manual/pages/`. `--html` writes only the HTML, to open in Chrome.
- A warning about a font that isn't the manual's own means Chrome fell back to a system font for a character Inter doesn't have (`⋯` did): use another character. The PDF embeds Inter, Inter Display and JetBrains Mono and nothing else.
- The build stops on a cross-reference to an id nothing defines, a heading id used twice, or a generated table whose source in the app has changed shape.

## Writing a section

1. **Facts first.** Gather the part's facts from the code into `docs/manual/facts/<part>.md`, with a path and line for every fact, inferences marked, and every disagreement between the README and the code. A subagent does this well, given the prompt in [fact-sheet.md](fact-sheet.md). Check anything surprising in the code yourself before you write it.
2. **Plan it in `book.toml`.** Give the section a `file`. Numbers follow the order: the part's `number`, then 3.1, 3.2 and so on. A heading's id is the section's id, a dot and the heading's slug, as in `masking.ai.downloading-a-model`.
3. **Write it** by the rules below. Its front matter has `deck`, one or two sentences that summarise it in italics under the title, and `sources`, each file it was written from with what was used.
4. **Build, and look at every page it touches** as PNGs, with the [checklist](#checking).
5. **Commit** on your own branch, naming the part (`User manual: Part 2, white balance and tone`), and update the canvas.

### Rules for the text

- For photographers, and task-focused: what a tool is for, how to use it (numbered steps for a task), then each of its controls. No engine internals: kernels, caches, process versions and how a model works stay out; downloads, their sizes and licences go in.
- Every claim traces to the fact sheet or the code. Where the README and the code disagree, follow the code and add the disagreement to the canvas's Needs you. Never repeat a string the code has wrong; say what happens instead.
- Name labels exactly as the app shows them (click Create New Mask, choose Duplicate and Invert). Write menus with › (Settings › Models), and right-click for a context menu. Give values as the slider's field shows them (+0.30, 100), ranges from the slider's left end to its right, and negative numbers with − (U+2212).
- Write in the brand's voice (`docs/brand/README.md`): calm, plain and precise, without superlatives or exclamation marks. Spell in British English (colour, licence, grey), but keep the app's names as they are (Color Range, Color Overlay).
- Say where Redlamp differs from Lightroom Classic in a `::: lightroom` callout, and only as far as `docs/lightroom-comparison.md` supports. Claim nothing about Lightroom from memory.
- Never put a cross-reference inside parentheses, since its page number brings its own: write "see [](#masking.ranges)" or "described under [](#masking.manage.mask-presets)".

### Markdown additions

| Write | Get |
| --- | --- |
| `[[⇧W]]`, `[[Esc]]` | Keycaps, one per key with the modifiers first, as the app's Keyboard Shortcuts sheet draws them. The `[` and `]` keys need `<kbd>[</kbd>` |
| `::: note`, `::: tip`, `::: lightroom`, `::: caution`, `::: not-yet`, closed by `:::` | A callout. Words after the kind replace its label: `::: caution Pre-alpha` |
| `[](#id)` | The id's label (3.2, Fig. 3.1, Part 3, or a heading's words) with its page. `[words](#id)` keeps the words. A section that isn't written yet shows as its number, without a link |
| `{{figure: name}}` | `figures/name.html`, numbered in order within its part |
| `{{table: sliders id id …}}` | Each slider's range, default and arrow-key step from `ParameterCatalog`; the ids are `ParameterID` cases, such as `localExposure` |
| `{{table: shortcuts id … @Category}}` | Each action's keys and title from `ShortcutAction`. `@Masking` adds a whole `ShortcutCategory`; write a name with spaces with underscores, as in `@Rating_&_Flags` |
| `{{commit}}`, `{{date}}` | The last commit to change `packages/` or `apps/`: the commit the manual describes, also on the cover |
| A term, then `: what it does` on the next line | Rows of terms and their descriptions |
| A numbered list | Steps, numbered in circles |

## Figures

- A figure file starts with `title:`, `tag:` (one word at the top right, such as Panel or Model), `caption:` (inline Markdown, its first sentence in bold) and, if needed, `class:`, then `---` and the body. In the body, `{{repo}}` is the path from the HTML to the repository, for images. Blank lines in the body are removed, because a blank line would end the HTML block.
- **Diagrams** are inline SVG drawn with the classes in `manual.css` (`op-frame`, `op-fill`, `op-a`, `op-b`, `g-line`, `g-dash`, `g-handle`, `g-pin`, `g-text`, `g-note`, `g-mono` and the rest), so they take the part's accent. Ids inside an SVG, for a `<mask>`, `<clipPath>` or gradient, must be unique in the whole manual: begin them with the figure's name.
- **Screenshots** come from the app, never mock-ups: from `docs/images`, captured by `scripts/capture-hero.sh`, `capture-promo.sh` and `capture-screenshots.sh` with scripted edits, or a capture of your own made the same way. Show part of one with a `.crop`, its `--crop-*` and `--image-*` sizes given in the image's pixels. Number what matters with marks in the gutters beside it (`.shot.gutters`, `.mark.l` or `.mark.r`, `top` in percent), level with what they point at, and a `.key` list beside the image.
- Find where marks go with `build/manual/venv/bin/python scripts/manual/grid.py <image> <x0> <y0> <x1> <y1>`, which draws the image's own pixel coordinates over the crop.
- A list in a figure that isn't steps needs `class="key"`, or it gets circled step numbers of its own.

## Page design

Keep to [design.md](design.md): what the reference's look is made of, and how the manual adapts each part to the brand. In short: A4 pages; Inter for text, Inter Display for headings and JetBrains Mono for labels and code, and no other font; ink on the brand's paper; dark part openers in wall, lit by the website's lamp glow, which with the logo's disc and the screenshots is the only red in the manual; the logo files on the cover, never the wordmark retyped; and each part's accent taken from one Color Mixer band's hue. A change to the look is the owner's to make: show them pages before and after.

## Checking

At the pages you changed, as PNGs, and on the contact sheets:

- [ ] The build printed no warning, and the page count is what you expect.
- [ ] Every cross-reference has its page, and none sits inside parentheses.
- [ ] In figures, marks are level with what they point at and cover nothing, labels are clear of lines, and nothing runs past a frame.
- [ ] No heading is alone at the foot of a page, and no table is apart from its heading.
- [ ] Every value in the text matches the generated tables and the fact sheet.
- [ ] The contents and the part's opener list the section with its page.

## Keeping it current

The manual describes the commit on its cover. Generated tables follow the code at every build; the text doesn't. When a feature changes, find the sections whose `sources` name its files, check them against the code, and correct the fact sheet with them. Other sessions change the app all the time, so check a part's fact sheet against the code before you rely on it.

## Alongside other sessions

The manual has paths of its own (`docs/manual/`, `scripts/manual/` and this skill) and changes nothing else. Work on your own branch in a worktree, as `AGENTS.md` says. During an agent wave `web/` is off limits, so a web version of the manual waits until the owner opens it.
