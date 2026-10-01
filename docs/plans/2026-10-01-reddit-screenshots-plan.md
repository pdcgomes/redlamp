# Plan: Reddit screenshot set

**Goal**: nine product-brief images at 2880 × 1800, rendered from code by `mise run video -- stills`, showing real captures of the app with the owner's photos ([design](2026-10-01-reddit-screenshots-design.md)).
**Architecture**: Remotion `Still`s in `video/`, sharing the video's `Stage`, palette and Inter. Each image places regions of window captures from `video/public/promo/`; until a capture exists it stands in a README screenshot from `public/synced/images/`, and failing that a labelled placeholder. Captures come from `scripts/capture-promo.sh`, which drives the Debug app through its `--script` launch option.
**Tech Stack**: TypeScript, React 19 and Remotion 4 (`video/`); Swift 6 (debug-only additions in `apps/RedlampMac`); bash and `screencapture`.

The video project has no unit tests: TypeScript steps are verified with `npm run typecheck` and by rendering the still and looking at it. The Swift additions are debug-only and verified by building, linting and running them.

Work in the checkout is shared with other in-progress changes, so every commit names its paths (`git commit -- <paths>`), and no step edits a file that already has uncommitted changes.

## Changes during implementation

- **Finding captures:** `getStaticFiles()` lists `public/` synchronously, so `Shot` checks for a capture without the `HEAD` request in step 4. Shots of other windows pass `captureWidth` (the Film Looks window is 1180 points wide), and the regions live in `src/stills/regions.ts`.
- **Stand-ins:** the README screenshots were taken at a 2560-point window, so their crops don't line up with 1600 × 1000 captures. Only the hero uses one; everything else shows a placeholder or a capture.
- **The window:** `NSWindowController` clears the editor's frame autosave name when it takes the window, so `--window-size` finds the visible window instead. It also moves the window, and windows a script opens, onto a Retina screen; on the owner's Mac the main display is 1×.
- **Captures:** the shortcut sheet is an overlay inside the editor, so it's in the editor's capture. The Camera Recipe group needs a taller window (`fujifilm-effects`, 1600 × 1410). The palette shot uses `action=commandPalette`. Image 8 draws its file list instead of capturing Finder.
- **Interim captures:** until the owner's photos arrive, `public/promo/` holds captures of CC0 look-development photos (no portrait and no focus stack, so those stay placeholders).

## Step 1: Keep captures and renders out of git

**File**: `video/.gitignore`. Add `public/promo/` (the captures contain the owner's photos). `out/` is already ignored.

Verify: `git check-ignore video/public/promo/hero.png` prints the path.

## Step 2: Let a still turn off the video's grain

**File**: `video/src/components/Stage.tsx`. Add `grain?: boolean` (default `true`) and render `<Grain />` only when it's set, so grain never lies over captured interface.

Verify: `cd video && npm run typecheck`.

## Step 3: The canvas

**File**: `video/src/stills/canvas.ts`

```ts
/** Stills are laid out in points at 1440 × 900 and rendered at 2×: 2880 × 1800. */
export const canvas = { width: 1440, height: 900, scale: 2 } as const;

/** The editor window every capture is taken at, in points; captures are 2× this in pixels. */
export const window = { width: 1600, height: 1000 } as const;

/** Nothing a reader needs is smaller than `text` (about 11 points on a phone). */
export const type = { headline: 88, sub: 44, text: 40, small: 22 } as const;
export const space = { margin: 96 } as const;

/** Where image `index` of the set puts its one light: it drifts left to right through the set. */
export function glowFor(index: number, count = 9) {
  return { x: 0.14 + (0.72 * index) / (count - 1), y: 0.06 };
}
```

Verify: typecheck.

## Step 4: Captures, stand-ins and placeholders

**File**: `video/src/stills/components/Shot.tsx`

- `Region = { x, y, width, height }` in window points.
- `useSource(name, standIn?)`: a `HEAD` request (inside `delayRender`) for `promo/<name>.png`; if it's missing, the stand-in `synced/images/<standIn>`; otherwise `null`.
- `<Shot name region width standIn? radius?>` draws the region at `width` canvas points: the image is scaled so the window's 1600 points span `width / region.width` each, and offset by the region's origin. A missing source draws a dashed placeholder naming the capture and region.
- `ShotContext` gives children the region and scale, so `Ring` and other marks are placed in window points.

Verify: typecheck; a still using `<Shot name="nothing-here">` renders the placeholder.

## Step 5: Shared pieces

**Files**, in `video/src/stills/components/`:
- `Headline.tsx`: title (Inter Display, `paper`, balanced wrap) and an optional sub (`mute`).
- `Footer.tsx`: the horizontal lockup (never retyped) and redlamp.app, bottom left, as small print.
- `Card.tsx`: a `Shot` with rounded corners, a hairline and a deep shadow, and a caption with a bold lead-in.
- `Marks.tsx`: `Ring` (a paper-white ring in window points, optionally dimming the rest of the card), `Leader` (a thin line between two canvas points) and `Chip`.
- `StillFrame.tsx`: `Stage` without grain, with the glow from `glowFor`, the children and the footer.

Verify: typecheck.

## Step 6: Register the stills and render them

**Files**:
- `video/src/stills/index.ts`: `stills: { id, component }[]`, ids `still-01-hero` … `still-09-try-it`.
- `video/src/Root.tsx`: map `stills` to `<Still id component width={canvas.width} height={canvas.height} />` after the video's compositions.
- `video/scripts/stills.mjs`: lists the compositions (`remotion compositions --quiet`), renders each `still-*` with `remotion still <id> out/stills/<id>.png --scale=2 --image-format=png`, then writes a JPEG beside it with `sips -s format jpeg -s formatOptions 92`. Arguments narrow it to some ids.
- `video/package.json`: `"prestills": "npm run sync-assets"`, `"stills": "node scripts/stills.mjs"`.
- `mise/tasks/video`: a `stills` case running `npm run stills`.

Verify: `mise run video -- stills still-01-hero`, then `sips -g pixelWidth -g pixelHeight video/out/stills/still-01-hero.png` reports 2880 × 1800.

Commit: `video/.gitignore`, `video/src/components/Stage.tsx`, `video/src/stills/`, `video/src/Root.tsx`, `video/scripts/stills.mjs`, `video/package.json`, `mise/tasks/video`, and both plan documents.

## Steps 7–15: The nine images

One file each in `video/src/stills/images/`, laid out on the canvas and checked by rendering it and looking at the PNG (and at a 780-pixel-wide copy, for phone legibility). Copy is exactly the design's.

| Step | File | Captures (stand-in) |
| --- | --- | --- |
| 7 | `01-hero.tsx` | `hero` (`hero.png`) |
| 8 | `02-familiar.tsx` | `panels` (`editor.png`), `shortcuts` |
| 9 | `03-masks.tsx` | `masks-people`, `masks-sky`, `masks-panel` (`masking.png`) |
| 10 | `04-film.tsx` | `film-looks` (`film-catalog.png`), the CineStill look sheet, film icons |
| 11 | `05-fujifilm.tsx` | `fujifilm` (`recipes.png`); the recipe card and ΔE table are drawn |
| 12 | `06-stacking.tsx` | `stack-banner`, `stack-depth`, `stack-merged` |
| 13 | `07-keyboard.tsx` | `palette`, `palette-slider` (`hero.png`, which shows the slider bar) |
| 14 | `08-originals.tsx` | `finder`, `hero` (`hero.png`) |
| 15 | `09-try-it.tsx` | none: the drawn lens, lockup and install lines |

Commit: `video/src/stills/`.

## Step 16: Debug-only capture options in the app

**File**: `apps/RedlampMac/Sources/DebugSnapshot.swift` (all under its existing `#if DEBUG || REDLAMP_PROFILING`).
- `--window-size <w>x<h>`: finds the window whose `frameAutosaveName` is `Redlamp Editor`, clears the autosave name (so the owner's saved frame isn't overwritten), sets the content size and centres it.
- `select=<file name>` in `--script`: when the value isn't a number, selects the photo with that file name (by passing its index on to `applyDebugCommand`).
- `mask=<kind>[:<part>]` in `--script`: `await model.createAIMask(kind, part:)`, for `subject`, `sky`, `background` and `people` (parts as `PersonPart` raw values, such as `people:faceSkin`).
- The type's doc comment lists the new options.

Verify: `mise run build`, `mise run lint`; launch with `--window-size 1600x1000 --script select=<file>,mask=sky` and see a Sky mask in the Masks panel.

Commit: `apps/RedlampMac/Sources/DebugSnapshot.swift`.

## Step 17: The capture script

**File**: `scripts/capture-promo.sh <photo folder>`, built from `capture-screenshots.sh`.
- Reads `promo.txt` in the folder: one `role = file name` line each for `hero`, `portrait`, `landscape`, `night`, `fujifilm` and `stack` (a subfolder of frames).
- Copies the folder to a temporary one, makes the stack document with the Debug CLI (`redlamp stack <frames> --save`), and runs one shot per capture in the table above, each launching the app with `--window-size 1600x1000` and a script, and keeping the full window capture in `video/public/promo/<name>.png` (`PROMO_OUT` overrides it).
- Restores the app's last folder and mask overlay colour afterwards; `ONLY="…"` runs some shots.

Verify: run it on the CC0 look-development set with `PROMO_OUT` pointing at a scratch folder; every capture is 3200 × 2000 and shows what its script asked for.

Commit: `scripts/capture-promo.sh`.

## Step 18: Documentation

**File**: `video/README.md`: a Stills section (what they are, `mise run video -- stills`, the capture script and `promo.txt`, stand-ins and placeholders).

Commit: `video/README.md`.

## Step 19: End-to-end verification

`mise run video -- stills` renders all nine to `video/out/stills/` as 2880 × 1800 PNGs and JPEGs. Each one passes the design's checks: legible at phone width, every claim traced to the README, one red light, nothing evaluation-only, nothing missing from the release.

## Order

| Group | Steps | Can parallelize |
| --- | --- | --- |
| 1 | 1–6 | No: shared files |
| 2 | 7–15 | Yes, but one person keeps them consistent |
| 3 | 16–17 | Independent of groups 1 and 2 |
| 4 | 18–19 | After everything else |
