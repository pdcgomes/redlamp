# Redlamp promo video

A 24-second promotional film for photographers who know Lightroom, built in React with [Remotion](https://www.remotion.dev) and rendered to MP4, plus a 20-second cut for 9:16 and 1:1 social feeds.

```bash
mise run video             # open Remotion Studio to preview and scrub every scene
mise run video -- render   # render every cut into video/out/
```

`npm run render -- Social9x16` renders a single cut. Rendering writes:

| File | Format |
| --- | --- |
| `out/redlamp-explainer-16x9.mp4` | 1920 × 1080, the full film |
| `out/redlamp-explainer-9x16.mp4` | 1080 × 1920, for Stories, Reels and Shorts |
| `out/redlamp-explainer-1x1.mp4` | 1080 × 1080, for feeds |
| `out/*-poster.jpg` | A poster still for each |
| `../web/public/video/redlamp-explainer.mp4` and its poster | A 720p copy the website embeds |

## How it's built

- `src/Explainer.tsx` lists the scenes in each cut, their lengths, and whether each arrives with a zoom or a whip pan (`src/transitions.tsx`).
- `src/scenes/` holds the eight beats: the hook, the editor with a cursor making slider moves, speed, masks, film, originals, the essentials, and the end card. Each lays itself out for 16:9, 9:16 or 1:1 from the composition's size.
- Motion uses three springs in `src/layout.ts`: `pop` for arrivals (with overshoot), `snap` for exits and travel, and `drag` for slider thumbs. Beats sit on a 120 BPM grid (a beat every 15 frames), and the red light flares on them.
- Everything on screen is drawn: `src/components/Landscape.tsx` is a vector landscape whose palette runs through the small colour grade in `src/grade.ts`, so slider edits, masks and film looks all change the same drawing. Interface that isn't the point of a shot is skeleton bars.
- The brand comes from `docs/brand/README.md`: Inter Display (bundled in `public/fonts`, SIL Open Font License), the wall, steel and ruby colours, and one light per frame. The only address shown is redlamp.app.

## Stills

Nine product-brief images for the Reddit announcement, at 2880 × 1800 (a Mac App Store size), each a headline and a few words over real captures of the app. The [design](../docs/plans/2026-10-01-reddit-screenshots-design.md) has their copy and which posts use them.

```bash
mise run video -- stills                    # render every still into video/out/stills/
mise run video -- stills still-04-film      # or just some
scripts/capture-promo.sh ~/Pictures/promo   # capture the app from a folder of your photos
```

- `src/stills/images/` holds one component per image and `src/stills/components/` the pieces they share. They appear in Remotion Studio under **Stills**. Each render writes a PNG master and a JPEG for uploading.
- The captures come from `scripts/capture-promo.sh`. It opens the Debug app on a copy of the folder at a 1600 × 1000 window on a Retina screen, applies a script per shot, and saves the window into `public/promo/`, which is never committed. A `promo.txt` in the folder names the photo for each role; the script's header lists them.
- `src/stills/regions.ts` says where things sit in a 1600 × 1000 capture, such as the photo at Fit or the Masks panel, so crops survive new photos.
- A capture that doesn't exist yet shows as a labelled placeholder with its name and region. The hero falls back to the README's `hero.png`.

## Assets

The logo, the app icon's lens and the film icons are copied from `docs/` by `../web/scripts/sync-assets.mjs` before every studio session and render.

## Music

The film is silent until you add a track. Pick one at 120 BPM so the cuts land on the beat, put the licensed file in `public/audio/`, and set `musicSrc` (for example `"audio/music.mp3"`) in the compositions' `defaultProps` in `src/Root.tsx`, or pass `--props='{"cut":"explainer","musicSrc":"audio/music.mp3"}'` to `remotion render`.

## Licence

Remotion is free for individuals and companies of up to three people; larger teams need a [company licence](https://www.remotion.dev/license).
