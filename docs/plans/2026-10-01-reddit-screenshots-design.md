# Reddit screenshot set: design

The owner's goal: a set of images to go with the Reddit announcement posts, each one a small product brief, with a headline, a line of copy and annotated crops of the real app, so a reader understands Redlamp without reading the post. The set should carry over to the Mac App Store later.

## Decisions

- **Format:** 16:10 landscape at 2880 × 1800, one of the Mac App Store's screenshot sizes. Reddit's mobile feed shows landscape images about half as tall as 4:5 ones, so the type is sized for a phone instead.
- **Photos:** the owner's own, in every image: finished JPEG edits from a Sony A7R V, and one raw for the hero, so the title bar names a raw. There's no focus-bracketed sequence, so image 6 waits for one. There's no Fujifilm raw either, so image 5 shows its recipe on one of the street photos.
- **Direction:** the brand's dark: the `wall` colour lit by one safelight glow per image ([brand](../brand/README.md)).
- **Approach:** Remotion stills in `video/`, built on real Retina captures of the app. Pages in `web/` captured with Playwright would duplicate the video's theme work and ship with the site; composing in Figma can't be regenerated when the UI changes.
- **Voice:** the brand's: calm and plain, with no exclamation marks or superlatives, and only claims the README makes.

## The set

Nine images, in this order. Each shows only what's in the release a tester downloads.

1. **The raw editor you already know.** "Lightroom's panels, sliders and shortcuts, native on the Mac. Free and open source." The full editor on the hero photo, bleeding off the bottom edge, under the app icon and wordmark.
2. **Nothing to relearn.** "Lightroom's panel order, slider names and ranges, and Lightroom Classic's shortcuts." Two cards: Basic's Tone sliders ("The same sliders, in the same order.") and the ⌘/ shortcut overlay ("⌘/ lists all 83 of Lightroom Classic's shortcuts.").
3. **Masks that know what's in the photo.** "Subject, Sky, Background and People, down to eyes and teeth. All on your Mac." The portrait's People mask shown as Image on Black beside the Masks panel, the face-skin part in green, and the Subject mask as Image on Black. None of the photos has a big sky, so Sky is named but not shown. Objects (SAM 2.1) and estimated depth stay out: they're only offered with the switch for models awaiting licence review.
4. **36 film looks, built from the datasheets.** "Each stock's own curves and grain, with halation and bloom." The Film Looks window on the night scene, a row of film icons, and the night scene before and after CineStill 800T, side by side.
5. **Fujifilm recipes, setting for setting.** "Dynamic Range, Color Chrome and WB shift, on looks measured against Fujifilm's own JPEGs." A drawn recipe card next to the bundled recipe built from it (Chrome Street) on a street photo, the Effects panel's camera-recipe controls, and the README's measured ΔE figures. The app can't take a typed-in card yet (only the harness's Recipe Lab can), so the image doesn't claim it.
6. **Focus stacking, found for you.** "Redlamp finds the sequence and merges it. The result develops like a raw." Three cards: the "Focus stack detected" banner ("Detected. Merge is one click."), the depth map ("Merged with a depth map.") and the merged result in the Stack workspace ("Still a raw. Every slider works."). Held back until there's a focus-bracketed sequence to capture: its layout renders with placeholders as `held-06-stacking`.
7. **Every control from the keyboard.** "⌘K finds any action or slider. Typing `exposure 0.7` sets it." Drawn ⌘ and K keys beside the palette over the photo. Held back until a release includes the command palette; 0.1.0-prealpha doesn't.
8. **Your photos stay yours.** "Edits live in a small file next to each photo." Chips for no subscription, no cloud and open source, the editor, and a drawn file list: `IMG_1234.ARW` ("Your original, never touched") above `IMG_1234.ARW.redlamp` ("Your edit").
9. **Try it.** "Pre-alpha for Apple Silicon Macs on macOS 26 or later." The glowing app icon, redlamp.app, the two Homebrew lines, the GitHub address and the licence.

Small print carries the trademark notes: on image 9, that Lightroom is a trademark of Adobe Inc. and Redlamp isn't affiliated with Adobe; on images 4 and 5, the same for the film and Fujifilm names.

### Per post

Each post uses five to seven images, led by the one that suits the sub. Every image has the footer, so any of them can lead.

| Post | Images |
| --- | --- |
| r/macapps | 1, 2, 3, 4, 8, 9, and 7 once the palette ships |
| r/postprocessing | 3, 1, 4, 2, 9 |
| r/fujifilm | 5, 4, 1, 3, 9 |
| r/macrophotography, once image 6 has a stack | 6, 1, 3, 8, 9 |

## Photos

One folder of the owner's photos, outside the repo, with a `promo.txt` naming the photo for each role:
- `hero`: a raw, for images 1, 2, 7 and 8. A raw with no sidecar in the folder takes its edit from a `hero.edit` line; this one has Teal Cinema 2 and the adjustments from the README hero's history.
- `portrait`: a clear face, for the People masks
- `subject`: a clear subject, for the Subject mask
- `landscape`: a big sky, for the Sky mask, when there is one
- `night`: bright lights, to show CineStill's halation
- `fujifilm`: a photo for the Chrome Street recipe
- `stack`: a subfolder of 10 to 30 focus-bracketed frames, when there is one

## Visual system

- **Canvas:** each image is laid out at 1440 × 900 points and rendered at 2×. Reddit shows it about 390 points wide on a phone, so nothing on the canvas is smaller than 40 points (about 11 on the phone), except the small print: the footer and the trademark notes. Headlines are about 88 points and sublines 44.
- **Background:** `wall`, lit by one safelight glow that moves a little from image to image, so swiping through a gallery reads as one strip.
- **Type:** headlines in Inter Display SemiBold in `paper`, about six words; sublines in the video palette's `mute`, fifteen words at most.
- **The app:** real captures, either as one large window bleeding off an edge (images 1 and 4) or as two to four cropped cards with a bold lead-in caption under each. Cards have rounded corners, a hairline edge and a soft, deep shadow.
- **Callouts:** thin `paper` rings and leader lines, with the rest of a crop dimmed. Never red: red appears once per image, as light, and the glow is that light. Masks show as Image on Black, or in one of the overlay's other colours, for the same reason.
- **Drawn elements:** only what isn't the app: the recipe card, the ΔE chart, the file list, the ⌘ and K keys, the feature chips and the footer.
- **Footer:** the mark, "Redlamp" and redlamp.app, bottom left.

## Pipeline

### Captures

`scripts/capture-promo.sh <photo folder>` is built from `capture-screenshots.sh`. It copies the folder to a temporary location, launches the Debug app with a fixed 1600 × 1000 window, runs one `--script` per shot, and keeps the full 3200 × 2000 window capture in `video/public/promo/<shot>.png`, with no downscale. Shots use the app's default theme (Neutral) and only the models testers get; the script saves the app's preferences first and puts them all back afterwards. The Film Looks window is captured by title through `scripts/window-id.swift`. The Camera Recipe group sits below Effects' other groups, so its shot uses a 1600 × 1410 window.

Debug-only additions to the app:
- `--window-size <w>x<h>` sets the editor window's content size and centres it on a Retina screen if there is one, so captures are 2×; windows a script opens join it there. The owner's saved frame is left alone.
- `select=<file name>` in `--script` selects a photo by name, so shots don't depend on the folder's order.
- `mask=subject|sky|background|people` in `--script` creates that AI mask on the selected photo and waits for it to finish (`people:faceSkin` and the other parts too), and `overlay=<style>` shows it in one of the overlay's modes, such as `overlay=imageOnBlack`.
- Image 7 opens the palette with `action=commandPalette`. A `palette=<query>` key, to capture a typed query, comes with the release that has the palette.

The existing keys cover the rest: `panel`, `tool`, `recipe`, `compare`, `window=film-looks`, `stack=open` and `stack=depth`, and `action=` for the mask overlay, its colour and the shortcut sheet.

### Composition

- `video/src/stills/` holds one component per image and the shared pieces (glow, headline, window, card, callout, chip and footer), registered as Remotion `Still`s in `src/Root.tsx` beside the video's compositions.
- A capture that doesn't exist yet renders as a labelled placeholder, so layouts can be built before the photos arrive. The hero falls back to the README's `hero.png`.
- `mise run video -- stills` (`npm run stills`, through `scripts/stills.mjs`) renders every image with `remotion still --scale=2` into `video/out/stills/`, as a PNG master and a JPEG for uploading.

### Git

The code is committed. Captures and renders aren't: `out/` is already ignored, and `video/.gitignore` gains `public/promo/`. The owner's raw files stay outside the repo.

## Checks

Before a post goes up:
- **Legibility:** every image viewed at phone width, about 390 points, with all its text readable.
- **Claims:** every headline and subline traced to a line in the README.
- **Brand:** one red light per image, no red callouts or overlays, and no exclamation marks.
- **Availability:** nothing from evaluation-only models in view, and nothing that isn't in the release testers download.

## Later: the Mac App Store

The layouts carry over at the same size. App Store review tends to reject screenshots that name other apps or mention prices, so images 1, 2 and 9 (Lightroom) and 1 and 8 (free, no subscription) need variants.

## Not in this set

A speed image (the owner dropped it), portrait or square cuts, animation (the explainer video covers that), and iPad and iPhone, which arrive in Phase 5.
